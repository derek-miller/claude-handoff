import Foundation
import Testing
@testable import HandoffCore

extension Engine.Cloud {
    // A progress report callback that records { stage, text, ...extra }.
    static func recorder(_ reports: Box<[Value]>) -> Value {
        fn { args in
            let extra = arg(args, 2)
            reports.value.append(.spread(["stage": arg(args, 0), "text": arg(args, 1)], extra.isPlainObject ? extra : [:]))
            return .undefined
        }
    }

    @Test("receipt summaries count source records by cause and cloud links only by bridge identity")
    func refusalSummaries() throws {
        for mixed in [false, true] {
            let f = try refusalFixture(mixed), h = f.h, result = f.result
            eq(result.summary.moved, 1)
            eq(result.summary.notMoved.length, 10)
            deq(.fromEntries(result.summary.groups.elements.map { ($0.cause.str, Value($0.records.length)) }),
                ["history check": 1, "waiting on parent": 6, "task collision": 3])
            let investor = result.summary.notMoved.find { $0.id.str == f.investor }
            eq(investor.sessionId, Value(f.recordId))
            deq(investor.remoteIds, ["session_investor"])
            eq(result.receipt.failed.find { $0.id == "cse_investor" }.blockedByLocal[0], Value("\(h.acct.P)/\(h.org.P)/\(f.recordId)"))
            eq(result.receipt.failed.find { $0.id == "cse_unrelated" }.blockedByLocal, .undefined)
            eq(result.pendingCloud, 0)
            deq(result.summary.kept.map { $0.id }, mixed ? ["cse_unrelated"] : [])
            let listed = lines(cli(h.root, ["accounts", "--json"]).stdout)[0]
            eq(Set(listed.elements.map { show($0.receipt) }).count, 1)
            deq(listed[0].receiptSummary, result.summary)
            eq(listed.filter { $0.pending.truthy }.length, 0)
            let refreshed = try verifyPlaced(h.paths)
            deq(refreshed.summary, result.summary)
            let finished = try finishPending(h.paths, ["cloud": .spread(f.cloud, ["list": fn { _ in
                Issue.record("blocked mirror must wait for Move")
                throw EngineError("blocked mirror must wait for Move")
            }])])
            eq(finished.nothing, true)
            eq(finished.receipt.failed.filter { $0.cloudAccount.truthy }.length, mixed ? 2 : 1)
        }
    }

    @Test("mixed cloud checks keep unproven mirrors final while blocked mirrors survive Finish, Keep and Undo")
    func mixedBlockedMirrors() throws {
        for action in ["finish", "keep", "undo"] {
            let f = try refusalFixture(true), h = f.h
            var calls: [Value] = []
            eq(f.result.receipt.cloudChecks[0].status, "blocked-local", action)
            if action == "finish" {
                let cloud = Value.spread(f.cloud, [
                    "list": fn { _ in [remoteSession(["id": "cse_investor", "title": "Same title"])] },
                    "eventRows": fn { args in calls.append(Engine.Cloud.arg(args, 0)); return [] },
                ])
                let result = try finishPending(h.paths, ["cloud": cloud])
                eq(result.nothing, true)
                #expect(calls.isEmpty)
                deq(result.receipt.failed.filter { $0.cloudAccount.truthy }.map { $0.id }.sorted(), ["cse_investor", "cse_unrelated"])
                eq(result.receipt.cloudChecks[0].status, "blocked-local")
            } else if action == "keep" {
                let result = try keepLocal(h.paths)
                eq(result.nothing, true)
                eq(result.receipt.failed.filter { $0.cloudAccount.truthy }.length, 2)
                ok(!result.receipt.cloudChecks[0].failures.some { $0.id == "cse_unrelated" })
                try writeJSON(f.investorFile, .spread(try readJSON(f.investorFile), ["bridgeSessionIds": []]))
                let next = try verifyPlaced(h.paths)
                eq(next.ok, false)
                eq(next.failed[0].id, "cse_investor")
            } else {
                let result = try undo(h.paths, ["processes": []])
                ok(result.dest)
                let saved = try readJSON(path.join(result.dest.str, "receipt.json"))
                eq(saved.failed.filter { $0.cloudAccount.truthy }.length, 2)
            }
        }
    }

    @Test("Finish preserves locally blocked legacy busy mirrors while retrying independent work")
    func legacyBusyMirrors() throws {
        for mixed in [false, true] {
            let f = try refusalFixture(mixed), h = f.h, receipt = try readJSON(f.result.file.str)
            let mirror = receipt.failed.find { $0.id == "cse_investor" }
            mirror.error = "Remote Control history unreadable: Remote Control session is not proven disconnected and idle"
            receipt.cloudChecks[0].failures.find { $0.id === mirror.id }.error = mirror.error
            try writeJSON(f.result.file.str, receipt)
            var listed = 0, queried = 0, archived = 0
            let cloud = Value.spread(f.cloud, [
                "list": fn { _ in listed += 1; return [remoteSession(["id": mirror.id, "title": "Same title"])] },
                "eventRows": fn { _ in queried += 1; return [] },
                "session": fn { _ in queried += 1; return remoteState("active") },
                "archive": fn { () in archived += 1 },
            ])
            let result = try finishWorkflow(h.paths, ["processes": [], "cloud": cloud])
            eq(result.complete, true)
            eq(listed, 0)
            eq(queried, 0)
            eq(archived, 0)
            deq(result.receipt.failed.filter { $0.cloudAccount.truthy && $0.id === mirror.id }, [mirror])
            eq(result.receipt.cloudChecks[0].status, "blocked-local")
            eq(result.summary.notMoved.length, 10)
        }
    }

    @Test("task family cloud work follows all local placements and reports the entire operation")
    func taskFamilyCloudWork() throws {
        for scenario in ["match", "remote changed", "family refused"] {
            let h = try taskFamilyFixture(false, 1, 8), (from, to) = try h.selection(), anchor = SOURCE
            let remote = lines(try readText(h.transcript(anchor)))
            var status = "active", archived = 0, changed = false
            let reports = Box<[Value]>([])
            let cloud = cloudFixture(h, [
                "list": fn { _ in [remoteSession(["id": "cse_task_family", "title": Value("Session \(anchor.suffix(3))"), "status": Value(status)])] },
                "eventRows": fn { _ in remoteRows(changed ? remote.concat([entry("user", 301, 87, "cse_task_family")]) : remote) },
                "session": fn { _ in remoteState(status) },
                "archive": fn { () in
                    deq(try readJSON(h.targetFile), h.targetAfter)
                    for sid in [SOURCE, h.run, h.cold] {
                        ok(exists(h.recordFile("T", sid)), "\(sid) placed in T before archive")
                        ok(!exists(h.recordFile("P", sid)), "\(sid) retired from P before archive")
                    }
                    archived += 1
                    status = "archived"
                },
            ])
            let inv = try inventory([from], to, h.paths, NOOP, ["processes": [], "cloud": cloud])
            eq(inv.move.length, 3)
            eq(inv.cloud.matches.length, 1)
            deq(inv.cloud.blocked, [])
            if scenario == "remote changed" { changed = true }
            if scenario == "family refused" {
                try writeJSON(h.sourceFile, .spread(h.sourceRegistry, ["scheduledTasks": [.spread(h.tasks[0], ["notifySessionId": Value("local_\(id(799))")])]]))
            }
            let moved = try move(inv, to, h.paths, Engine.Cloud.recorder(reports))
            eq(receiptFiles(h).count, 1)
            let succeeds = scenario == "match"
            eq(moved.ok, Value(succeeds), scenario)
            eq(archived, succeeds ? 1 : 0, scenario)
            eq(moved.pendingCloud, Value(succeeds ? 0 : 1), scenario)
            eq(moved.receipt.sessions.length, scenario == "family refused" ? 1 : 3, scenario)
            if succeeds {
                let moves = reports.value.filter { $0.stage == "move" && !$0.live.truthy }
                eq(moves.count, 1)
                match(moves.first?.text ?? .undefined, "3 ✓ \\| 24 events")
                for stage in ["move", "verify", "retire"] {
                    let progress = reports.value.filter { $0.stage.str == stage && !$0.completed.isUndefined }
                    let total = stage == "retire" ? 3 : moved.receipt.sessions.length
                    ok(!progress.isEmpty, stage)
                    ok(progress.enumerated().allSatisfy { index, row in
                        row.total == Value(total) && (row.completed.asNumber ?? -1) >= (index > 0 ? progress[index - 1].completed.asNumber ?? 0 : 0)
                    }, stage)
                    eq(progress.last?.completed ?? .undefined, Value(total), stage)
                }
            } else {
                ok(moved.receipt.failed.some { $0.cloudAccount.str == h.acct.P })
                match(Value(moved.receipt.failed.elements.map { $0.error.str }.joined(separator: " ")),
                      scenario == "family refused" ? "changed since inventory|family member missing" : "Remote Control history changed")
                if scenario == "family refused" { ok(exists(h.recordFile("P", SOURCE))) }
            }
        }
    }
}
