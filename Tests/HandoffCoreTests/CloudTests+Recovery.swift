import Foundation
import Testing
@testable import HandoffCore

extension Engine.Cloud {
    @Test("restart retry and cleanup preserve pending cloud checks until verification finishes")
    func restartRetryPreservesPending() throws {
        for transient in [true, false] {
            let h = try home(), other = id(710), mock = taskHarness(desktopFixture())
            mock.rows[1].ids = [Value(SOURCE), Value(other)]
            for (index, sid) in [SOURCE, other].enumerated() {
                try h.write(sid, [entry("user", 810 + index, nil, sid)])
                try h.record("P", sid, rehomeRecord())
            }
            let all = try accounts(h.paths, []), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
            let options: Value = ["io": mock.io, "cloudRequested": true]
            let planned = try executeMove([from], to, h.paths, options)
            let native = fs.link, target = h.recordFile("T", SOURCE)
            var attempts = 0
            fs.link = { a, b in
                if b == target {
                    attempts += 1
                    if attempts == 1 || !transient { throw JSError("Synthetic publication failure") }
                }
                try native(a, b)
            }
            defer { fs.link = native }
            let result = try executeMove([from], to, h.paths, .spread(options, ["approve": planned.plan.token]))
            fs.link = native
            eq(attempts, 2, "transient \(transient)")
            eq(result.receipt.cloudChecks.length, 1)
            eq(result.receipt.cloudChecks[0].status, "pending")
            eq(result.receipt.held.length, 0)
            eq(result.summary.notMoved.length, transient ? 0 : 1)
            let cloud = cloudFixture(h), checked = try finishPending(h.paths, ["processes": [], "cloud": cloud, "active": cloud])
            eq(checked.complete, Value(transient))
            eq(checked.receipt.cloudChecks[0].status, "complete")
            #expect(mock.calls == ["/usr/bin/osascript", "/usr/bin/open"])
        }
    }

    @Test("terminal local failures stay stable across account refresh with cloud and held work")
    func terminalFailuresStable() throws {
        for mode in ["partial", "held", "cloud", "both"] {
            let h = try home(), failed = [id(710), id(711)], held = id(712)
            try h.write(SOURCE, [entry("user", 800, nil, SOURCE)])
            try h.record("P", SOURCE, rehomeRecord())
            var all = try accounts(h.paths, [])
            let from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
            let moved = try executeMove([from], to, h.paths, ["processes": []]), receipt = moved.receipt
            for (index, sid) in failed.enumerated() {
                try h.write(sid, [entry("user", 810 + index, nil, sid)])
                try h.record(index > 0 ? "Q" : "P", sid, rehomeRecord())
            }
            let hasHeld = ["held", "both"].contains(mode), hasCloud = ["cloud", "both"].contains(mode)
            if hasHeld { try h.write(held, [entry("user", 812, nil, held)]); try h.record("Z", held, rehomeRecord()) }
            all = try accounts(h.paths, [])
            receipt.fromAccounts = all.filter { $0.account.str != h.acct.T }.map { ["account": $0.account, "org": $0.org, "label": $0.label] }
            receipt.failed = Value(failed.map { sid -> Value in
                let account = all.find { $0.sessions.some { $0.id.str == sid } }, session = account.sessions.find { $0.id.str == sid }
                return ["id": Value(sid), "title": session.title, "error": "Synthetic permanent failure", "sources": [[
                    "account": account.account, "org": account.org, "label": account.label,
                    "id": Value(sid), "sessionId": session.record.sessionId, "file": session.file, "title": session.title,
                ]]]
            })
            receipt.localStopped = true
            receipt.localRecovery = ["attempted": true]
            receipt.held = hasHeld ? [["id": Value(held), "recordId": Value("local_\(held)"), "title": "Healthy held session", "release": "worker", "workers": [],
                                       "sources": [["id": Value(held), "account": Value(h.acct.Z), "org": Value(h.org.Z), "file": Value(h.recordFile("Z", held))]]]] : []
            let cloud = cloudFixture(h, ["account": Value(h.acct.Q), "org": Value(h.org.Q)])
            receipt.cloudChecks = hasCloud ? [["account": Value(h.acct.Q), "org": Value(h.org.Q), "label": "Cloud source", "status": "pending", "sessionIds": ["session_missing"]]] : []
            try writeJSON(moved.file.str, receipt)
            let refresh = { () throws -> Value in
                let output = cli(h.root, ["accounts", "--json"]) { processSetup(list: "", commands: "") }
                eq(output.code, 0, output.stderr)
                let rows = lines(output.stdout)[0]
                ok(rows.filter { $0.pending.truthy }.every { $0.pendingCount != 0 })
                eq(rows[0].receiptSummary.notMoved.length, 2)
                return rows
            }
            func sortedTriples(_ rows: [Value]) -> String { rows.map { JSON.text($0) }.sorted().joined(separator: ",") }
            for _ in 0..<2 {
                let rows = try refresh()
                let partial = rows.filter { $0.pending == "partial" }.elements.map { Value([$0.account, $0.pendingCount, $0.pendingAction]) }
                let expected: [Value] = mode == "partial" ? [[Value(h.acct.P), 1, "blocked"], [Value(h.acct.Q), 1, "blocked"]] : []
                eq(sortedTriples(partial), sortedTriples(expected), mode)
            }
            let native = fs.link
            var published: [String] = []
            fs.link = { a, b in published.append(b); try native(a, b) }
            defer { fs.link = native }
            let result = try finishWorkflow(h.paths, .spread(["processes": []], hasCloud ? ["cloud": cloud, "active": cloud] : [:]))
            eq(result.complete, false, mode)
            for check in try readReceipt(moved.file).cloudChecks.elements where ["pending", "failed"].contains(check.status.str) {
                let finished = try finishPending(h.paths, ["processes": [], "cloud": cloudFixture(h, check), "active": check])
                eq(finished.complete, false, mode)
            }
            for _ in 0..<2 {
                let rows = try refresh()
                let pending = rows.filter { $0.pending.truthy }.elements.map { Value([$0.account, $0.pending, $0.pendingCount]) }
                eq(sortedTriples(pending), sortedTriples([[Value(h.acct.P), "partial", 1], [Value(h.acct.Q), "partial", 1]]), mode)
                eq(try sweep(h.paths, ["processes": [], "cloud": cloud, "active": cloud]).complete, false, mode)
            }
            fs.link = native
            #expect(published == (hasHeld ? [h.recordFile("T", held)] : []), "\(mode)")
            let after = try readReceipt(moved.file)
            deq(after.failed, receipt.failed, mode)
            eq(after.sessions.length, hasHeld ? 2 : 1, mode)
            eq(try keepLocal(h.paths).complete, true, mode)
            ok(try undo(h.paths, ["processes": []]).dest, mode)
        }
    }

    @Test("Undo refuses new destination forks before cloud or local changes and on every recovery entry")
    func undoRefusesNewForks() throws {
        for staged in [false, true] {
            for unreadable in [false, true] {
                let label = "staged \(staged) unreadable \(unreadable)"
                let h = try home(), child = id(777), cold = id(778), base = branchEntries(2, SOURCE, 1)
                try h.write(SOURCE, base)
                try h.record("P", SOURCE, rehomeRecord(["title": "Parent"]))
                try h.write(cold, branchEntries(2, cold, 300))
                try h.record("P", cold, rehomeRecord())
                var calls: [String] = []
                var status = "active"
                let cloud = cloudFixture(h, [
                    "list": fn { _ in [remoteSession(["id": "cse_undo_parent", "title": "Parent", "status": Value(status)])] },
                    "eventRows": fn { _ in remoteRows(base) },
                    "session": fn { _ in calls.append("session"); return remoteState(status) },
                    "archive": fn { () in calls.append("archive"); status = "archived" },
                    "unarchive": fn { () in calls.append("unarchive"); status = "active" },
                ])
                let all = try accounts(h.paths), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
                let originals = try from.sessions.elements.map { ($0.file.str, try readData($0.file.str)) }
                let moved = try move(try inventory([from], to, h.paths, NOOP, ["cloud": cloud]), to, h.paths)
                eq(moved.ok, true, label)
                eq(status, "archived", label)
                if staged { deq(try undo(h.paths, ["cloud": .spread(cloud, ["account": Value(h.acct.Q), "org": Value(h.org.Q)])]).pendingUndo, [from.email], label) }
                let childFile = h.recordFile("T", child)
                if unreadable { try writeText(childFile, "{broken") } else { try h.record("T", child, rehomeRecord(["isArchived": true, "forkedFromSessionId": Value("local_\(SOURCE)")])) }
                let receiptBytes = try readData(moved.file.str)
                let destination = try readdir(h.dir("T")).map { name in (path.join(h.dir("T"), name), try readData(path.join(h.dir("T"), name))) }
                calls = []
                let operations: [(String, (Value, Value) throws -> Value)] = staged
                    ? [("undo", { try undo($0, $1) }), ("finishPending", { try finishPending($0, $1) }), ("finishWorkflow", { try finishWorkflow($0, $1) }), ("sweep", { try sweep($0, $1) })]
                    : [("undo", { try undo($0, $1) })]
                for (name, operation) in operations {
                    let result = try operation(h.paths, ["cloud": cloud, "processes": []])
                    let recovery = result.reconciled ?? result.recovered
                    let problems = result.restoreProblems ?? recovery.problems
                    if name == "sweep" { eq(result.pending, true, "\(label) \(name)") }
                    else { match(problems[0], unreadable ? "unreadable Desktop record:" : "parent Desktop record would be removed by Undo") }
                    eq(result.dest, .undefined, "\(label) \(name)")
                    #expect(calls.isEmpty, "\(label) \(name)")
                    eq(status, "archived", "\(label) \(name)")
                    #expect(try readData(moved.file.str) == receiptBytes, "\(label) \(name)")
                    deq(.strings(try readdir(h.dir("P"))), [], "\(label) \(name)")
                    for (file, bytes) in destination { #expect(try readData(file) == bytes, "\(label) \(name) \(file)") }
                }
                try unlink(childFile)
                let undone = try undo(h.paths, ["cloud": cloud])
                ok(undone.dest, label)
                eq(status, "active", label)
                for (file, bytes) in originals { #expect(try readData(file) == bytes, "\(label) \(file)") }
                deq(.strings(try readdir(h.dir("T"))), [], label)
            }
        }
    }

    @Test("Undo rechecks destination forks after cloud restoration before removing any local record")
    func undoRechecksForksAfterCloud() throws {
        let h = try home(), child = id(777), base = branchEntries(2, SOURCE, 1)
        try h.write(SOURCE, base)
        try h.record("P", SOURCE, rehomeRecord(["title": "Parent"]))
        var status = "active"
        let cloud = cloudFixture(h, [
            "list": fn { _ in [remoteSession(["id": "cse_undo_parent", "title": "Parent", "status": Value(status)])] },
            "eventRows": fn { _ in remoteRows(base) },
            "session": fn { _ in remoteState(status) },
            "archive": fn { () in status = "archived" },
            "unarchive": fn { () in
                try h.record("T", child, rehomeRecord(["forkedFromSessionId": Value("local_\(SOURCE)")]))
                status = "active"
            },
        ])
        let all = try accounts(h.paths), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
        let moved = try move(try inventory([from], to, h.paths, NOOP, ["cloud": cloud]), to, h.paths)
        eq(moved.ok, true)
        let parentFile = h.recordFile("T", SOURCE), parentBytes = try readData(parentFile)
        let refused = try undo(h.paths, ["cloud": cloud])
        match(refused.restoreProblems[0], "parent Desktop record would be removed by Undo")
        eq(status, "active")
        #expect(try readData(parentFile) == parentBytes)
        #expect(try readdir(h.dir("T")).sorted() == [SOURCE, child].map { "local_\($0).json" }.sorted())
        deq(.strings(try readdir(h.dir("P"))), [])
        ok(try readJSON(moved.file.str).undoing)
        try unlink(h.recordFile("T", child))
        ok(try undo(h.paths, ["cloud": cloud]).dest)
        ok(exists(h.recordFile("P", SOURCE)))
        deq(.strings(try readdir(h.dir("T"))), [])
    }
}
