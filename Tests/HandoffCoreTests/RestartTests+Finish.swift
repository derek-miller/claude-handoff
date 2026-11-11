import Foundation
import Testing
@testable import HandoffCore

extension Engine.Restarts {
    @Test("a non-Claude process mentioning a session id is not a worker")
    func nonClaudeProcess() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE)
        let child = Foundation.Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import time; time.sleep(10)", SOURCE]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let all = try accounts(h.paths)
        let by = { (a: String) in all.find { $0.account.str == h.acct[a] } }
        let inv = try inventory([by("P")], by("Z"), h.paths)
        eq(inv.move.length, 1)
        eq(try move(inv, by("Z"), h.paths).ok, true)
    }

    @Test("idle Finish reports refused sessions quietly while verification errors remain failures")
    func idleFinishReportsRefusals() throws {
        let h = try home()
        let bad = entry("user", 1, nil, SOURCE)
        try h.write(SOURCE, [bad, .spread(bad, ["message": ["role": "user", "content": "conflicting body"]])])
        try h.record("P", SOURCE, rehomeRecord(["title": "Needs attention"]))
        try h.record("Q", SOURCE, rehomeRecord(["title": "Needs attention"]))
        try h.write(id(994), [entry("user", 2, nil, id(994))])
        try h.record("P", id(994), rehomeRecord(["title": "Good history"]))
        let (from, to) = try Self.pair(h)
        let moved = try move(try inventory([from], to, h.paths), to, h.paths)
        eq(moved.receipt.sessions.length, 1)
        eq(moved.receipt.failed.length, 1)
        let result = cli(h.root, ["finish", "--json"])
        eq(result.code, 0)
        let idle = lines(result.stdout).find { $0.nothing.truthy }
        match(idle.failed[0].error, "conflicting duplicate uuids")
        let text = cli(h.root, ["finish"])
        eq(text.code, 0)
        match(text.stdout, "nothing pending\\n.*not moved.*conflicting duplicate uuids", "s")
        let refused = lines(cli(h.root, ["sweep", "--json"]).stdout)[0]
        eq(refused.receipt, moved.file)
        eq(refused.complete, true)
        eq(refused.failed.length, 0)
        eq(refused.notMoved.length, 1)
        let file = moved.file.str
        let receipt = try readJSON(file)
        receipt.failed = []
        try writeJSON(file, receipt)
        let clean = lines(cli(h.root, ["sweep", "--json"]).stdout)[0]
        eq(clean.complete, true)
        eq(clean.receipt, moved.file)
        receipt.verification = ["ok": false, "problems": [["id": Value(id(994)), "check": "transcript"]]]
        try writeJSON(file, receipt)
        let unverified = cli(h.root, ["finish", "--json"])
        eq(unverified.code, 1)
        deq(lines(unverified.stdout).find { $0.done.truthy }.problems, receipt.verification.problems)
        let details = cli(h.root, ["finish"])
        eq(details.code, 1)
        ok(details.stdout.contains("\(id(994)) | transcript verification failed"))
        let checked = lines(cli(h.root, ["sweep", "--json"]).stdout)[0]
        eq(checked.ok, false)
        match(checked.error, "transcript verification failed")
        try writeText(file, "{")
        let corrupt = lines(cli(h.root, ["sweep", "--json"]).stdout)[0]
        eq(corrupt.ok, false)
        match(corrupt.error, "corrupt receipt")
    }

    @Test("an existing bridge makes target supersession a separate refusal, not a restart")
    func existingBridgeRefusal() throws {
        let h = try home()
        let entries: Value = [entry("user", 940, nil, id(940)), entry("assistant", 941, 940, id(940))]
        try h.write(id(940), entries.concat([entry("user", 942, 941, id(940))]))
        try h.record("P", id(940))
        try h.write(id(945), fork(entries, id(940), id(945), "Q"))
        try h.record("Z", id(945), ["bridgeSessionIds": ["session_existing"]])
        let (from, to) = try Self.pair(h, "P", "Z")
        let rows = desktopFixture(id(945))
        let inv = try inventory([from], to, h.paths, NOOP, ["processes": rows])
        eq(try restartPlan(inv, h.paths, rows), nil)
    }

    @Test("Finish uses the active Desktop organization when its saved cookie still names the previous organization")
    func finishUsesActiveOrganization() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE, rehomeRecord(["title": "Switched organization"]))
        try h.record("P", id(997), rehomeRecord(["title": "Pending source"]))
        let (from, to) = try Self.pair(h)
        let moved = try move(try inventory([from], to, h.paths, NOOP, ["cloudRequested": true]), to, h.paths)
        eq(moved.pendingCloud, 1)
        try unlink(h.recordFile("P", id(997)))
        var requestedOrgs: [Value] = []
        mockFetch { url, options in
            let endpoint = url.path
            if endpoint == "/api/account" { return response(["uuid": Value(h.acct.P)]) }
            if endpoint == "/api/organizations" { return response([["uuid": Value(h.org.P)], ["uuid": Value(h.org.T)]]) }
            eq(Value(endpoint), "/v1/code/sessions")
            eq(options.method.nullish ? "GET" : options.method, "GET")
            requestedOrgs.append(options.headers["x-organization-uuid"])
            return response(["data": []], headers: ["anthropic-organization-id": options.headers["x-organization-uuid"]])
        }
        let cloud = try cloudClient(h.paths, nil, [
            "active": ["account": Value(h.acct.P), "org": Value(h.org.P), "state": "known"],
            "cookies": .newMap([(Value("sessionKey"), Value("fixture")), (Value("lastActiveOrg"), Value(h.org.T))]),
            "userAgent": "fixture",
        ])
        let finished = try finishPending(h.paths, ["cloud": cloud])
        eq(finished.ok, true)
        eq(finished.complete, true)
        eq(finished.pendingCloud, 0)
        deq(Value(requestedOrgs), [Value(h.org.P)])
    }

    @Test("explicit Undo restores all available organizations and sweep never advances a staged Undo")
    func explicitUndoAllOrganizations() throws {
        let f = try pendingOrganizations()
        for _ in f.rows { _ = try sweep(f.h.paths, f.options) }
        ok(f.rows.allSatisfy { $0.status == "archived" })
        let wrong = Value.spread(f.options, ["active": ["account": Value(f.h.acct.T), "org": Value(f.h.org.T), "state": "known"]])
        let pending = try undo(f.h.paths, wrong)
        deq(pending.pendingUndo, [f.from[0].email])
        let before = try readData(f.moved.file.str), count = f.calls.value.count
        eq(try sweep(f.h.paths, f.options).complete, false)
        eq(try finishPending(f.h.paths, .spread(f.options, ["automatic": true])).complete, false)
        eq(f.calls.value.count, count)
        #expect(try readData(f.moved.file.str) == before)
        let listing = Engine.Cloud.desktopListing(f.identity)
        let shown = cli(f.h.root, ["accounts", "--json"]) { processSetup(list: listing, commands: listing) }
        eq(shown.code, 0, shown.stderr)
        ok(try JSON.parse(shown.stdout).filter { $0.pending == "undo" }.every { $0.signedIn.truthy && $0.pendingAction == "finish" })
        let finished = try finishPending(f.h.paths, f.options)
        eq(finished.complete, true)
        ok(finished.dest)
        ok(f.rows.allSatisfy { $0.status == "active" })
        deq(try fixtureSnapshot(f.h, [f.h.paths.records.str, f.h.paths.pool.str]), f.before)
    }

    @Test("background Undo preserves its checkpoint while recovering an interrupted approved reopen")
    func backgroundUndoPreservesCheckpoint() throws {
        for remote in [false, true] {
            for state in ["absent", "running", "failed", "stale receipt"] {
                let f = try pendingOrganizations(orgs: ["T"]), h = f.h
                _ = try sweep(h.paths, f.options)
                try writeJSON(f.to.taskFile.str, ["scheduledTasks": [], "runRetries": [:]])
                _ = try undo(h.paths, .spread(f.options, ["active": ["account": Value(h.acct.T), "org": Value(h.org.T)]]))
                let file = f.moved.file.str
                let receipt = try readJSON(file)
                ok(receipt.undoing.length > 0, "\(remote) \(state)")
                if !remote { receipt.remoteUndoing = []; f.rows[0].status = "active" }
                try writeJSON(file, receipt)
                let journal = "\(file).journal"
                try writeText(journal, JSON.text(["sequence": Value((receipt.journalSequence.asNumber ?? 0) + 1), "pending": nil, "sessions": [], "failed": [], "retained": []]) + "\n")
                let before = try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str]), bytes = try readData(file), journalBytes = try readData(journal), cloudCalls = f.calls.value.count
                let restartFile = path.join(h.paths.state.str, "restart.json")
                try writeJSON(restartFile, ["outcome": "moving", "app": h.paths.claudeApp, "receiptFile": f.moved.file, "desktop": ["pid": 500, "started": "prior"]])
                var rows: Value = state == "running" ? [desktopFixture()[0]] : []
                var calls: [String] = []
                let io: Value = ["inspect": fn { _ in rows }, "command": fn { args in
                    calls.append(args[0].str)
                    eq(args[0], "/usr/bin/open")
                    deq(Self.arg(args, 1), ["-g", "-a", h.paths.claudeApp])
                    eq(Self.arg(args, 2), 8000)
                    if state != "failed" { rows = [desktopFixture()[0]] }
                    return ["status": state == "failed" ? 1 : 0]
                }]
                if remote && state != "stale receipt" {
                    let options = Value.spread(f.options, ["io": io, "automatic": true, "receiptFile": f.moved.file])
                    if state == "failed" {
                        throwsError(where: ["code": "REOPEN_FAILED", "message": regex("Reopen Claude Desktop manually")]) { try finishPending(h.paths, options) }
                    } else {
                        let pending = try finishPending(h.paths, options)
                        eq(pending.pending, true)
                        eq(pending.complete, false)
                    }
                }
                let sweeping = { try sweep(h.paths, .spread(f.options, ["io": io, "receiptFile": Value(state == "stale receipt" ? "\(file).old" : file)])) }
                if state == "failed" && !remote {
                    throwsError(where: ["code": "REOPEN_FAILED", "message": regex("Reopen Claude Desktop manually")]) { try sweeping() }
                } else {
                    let result = try sweeping()
                    if state == "stale receipt" { match(result.error, "operation receipt changed") } else {
                        eq(result.pending, true)
                        eq(result.complete, false)
                        deq(result.pendingUndo, remote ? [f.from[0].email] : [])
                    }
                    ne(result.complete, true)
                }
                #expect(calls == (state == "running" ? [] : ["/usr/bin/open"]), "\(remote) \(state)")
                let restart = try readJSON(restartFile)
                eq(restart.outcome, Value(state == "running" ? "interrupted-app-running" : state == "failed" ? "reopen-failed" : "interrupted-reopened"))
                ok(restart.recoveredAt)
                eq(f.calls.value.count, cloudCalls)
                eq(f.rows[0].status, remote ? "archived" : "active")
                #expect(try readData(file) == bytes)
                #expect(try readData(journal) == journalBytes)
                deq(try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str]), before)
                eq(try sweep(h.paths, .spread(f.options, ["io": io])).complete, false)
                #expect(calls == (state == "running" ? [] : ["/usr/bin/open"]))
                #expect(try readData(file) == bytes)
                #expect(try readData(journal) == journalBytes)
            }
        }
    }
}
