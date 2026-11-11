import Foundation
import Testing
@testable import HandoffCore

extension Engine {
    // The claude-handoff CLI run in process through runCLI, with HOME at the fixture.
    @Suite("CLI output")
    struct CLI {
        static func arg(_ args: [Value], _ i: Int) -> Value { i < args.count ? args[i] : .undefined }

        // The last JSON line a --json command printed.
        static func last(_ output: String) throws -> Value {
            try JSON.parse(output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? "")
        }

        // A Date string rearranged into /bin/ps lstart form: "Fri Sep 04 18:00:00 2026".
        static func lstart(_ ms: Double) -> String {
            re(#"^(\w+ \w+ \d+) (\d+) ([\d:]+).*$"#).replace(dateString(ms), "$1 $3 $2")
        }

        static func checkpointAccountsFixture(sourceLocation: SourceLocation = #_sourceLocation) throws -> (corrupted: String, repaired: String) {
            let h = try taskCheckpointFixture()
            try interruptTaskFamily(h, "move", "source", interruptAfter: 2)
            let state = h.paths.state.str
            let file = path.join(state, try readdir(state).first { re(#"^\d.*\.json$"#).test($0) }!)
            let original = try readData(file), receipt = try JSON.parse(original)
            eq(receipt.taskTransfers.length, 2, sourceLocation: sourceLocation)
            deq([receipt.appendCheckpoint.sessions, receipt.appendCheckpoint.superseded, receipt.appendCheckpoint.taskTransfers], [1, 1, 1], sourceLocation: sourceLocation)
            receipt.appendCheckpoint.taskTransfers = 0
            try writeJSON(file, receipt)
            let before = try fixtureSnapshot(h)
            let discovered = try accounts(h.paths, []).map { row in [row.account, row.org, Value(row.sessions.length), Value(row.unreadable.length)] }
            let corrupted = cli(h.root, ["accounts", "--json"])
            eq(corrupted.code, 0, corrupted.stderr, sourceLocation: sourceLocation)
            eq(lines(corrupted.stdout).length, 1, sourceLocation: sourceLocation)
            let listed = lines(corrupted.stdout)[0]
            eq(listed.length, 4, sourceLocation: sourceLocation)
            deq(listed.map { [$0.account, $0.org, $0.sessions, $0.unreadable] }, discovered, sourceLocation: sourceLocation)
            for row in listed.elements {
                deq(row.recoveryProblem, ["receipt": Value(file), "error": "invalid append checkpoint"], sourceLocation: sourceLocation)
                eq(row.pending, nil, sourceLocation: sourceLocation)
                eq(row.pendingAction, nil, sourceLocation: sourceLocation)
            }
            deq(try fixtureSnapshot(h), before, sourceLocation: sourceLocation)
            try writeData(file, original)
            let repairedBefore = try fixtureSnapshot(h)
            let repaired = cli(h.root, ["accounts", "--json"])
            eq(repaired.code, 0, repaired.stderr, sourceLocation: sourceLocation)
            let restored = lines(repaired.stdout)[0]
            ok(restored.every { $0.recoveryProblem === .null }, sourceLocation: sourceLocation)
            deq(restored.filter { $0.pending.truthy }.map { [$0.account, $0.pending, $0.pendingAction, $0.receipt] }, [[Value(h.acct.P), "recovery", "finish", Value(file)]], sourceLocation: sourceLocation)
            deq(try fixtureSnapshot(h), repairedBefore, sourceLocation: sourceLocation)
            return (corrupted.stdout.trimmingCharacters(in: .whitespacesAndNewlines), repaired.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Two sessions moved P → T over the CLI with no Desktop running; returns the JSON lines.
        static func cliProgressFixture(sourceLocation: SourceLocation = #_sourceLocation) throws -> [String] {
            let h = try home()
            for (index, sid) in [SOURCE, id(710)].enumerated() {
                try h.write(sid, [entry("user", 810 + index, nil, sid)])
                try h.record("P", sid, rehomeRecord())
            }
            try h.record("P", id(799), rehomeRecord())
            let output = cli(h.root, ["--from", "p@example.com", "--to", "t@example.com", "--json"]) { processSetup(list: "", commands: "") }
            eq(output.code, 0, output.stderr, sourceLocation: sourceLocation)
            let events = lines(output.stdout), counts = events.filter { $0.stage == "sessions" }
            deq(counts.map { [$0.sessionTotal, $0.remainingCount] }, [[2, 2], [2, 0]], sourceLocation: sourceLocation)
            ok(counts.every { row in
                row.live.truthy && isSafeInteger(row.sessionTotal) && isSafeInteger(row.remainingCount)
                    && toNumber(row.remainingCount) >= 0 && toNumber(row.remainingCount) <= toNumber(row.sessionTotal)
            }, sourceLocation: sourceLocation)
            eq(events.at(-1).summary.moved, 2, sourceLocation: sourceLocation)
            eq(events.at(-1).summary.notMoved.length, 0, sourceLocation: sourceLocation)
            return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        }

        @Test("cli exits nonzero on partial failure and undoes over json")
        func partialFailureAndUndo() throws {
            let h = try home()
            try h.write(SOURCE, [entry("user", 1, nil, SOURCE), entry("assistant", 2, 1, SOURCE)])
            try h.record("P", SOURCE)
            try h.write(id(600), [entry("user", 600, nil, id(600))])
            try appendText(h.transcript(id(600)), "{\"type\":\"user\",\"uuid\":\"broken\n")
            try h.record("P", id(600))
            try h.record("Q", id(600))
            let run = { (args: [String]) in cli(h.root, args) }
            let orphan = h.transcript(id(900))
            let orphanEntry = Value.spread(entry("user", 900, nil, id(900)), ["forkedFrom": ["sessionId": Value(id(1)), "messageUuid": Value(id(901))]])
            try writeText(orphan, JSON.text(orphanEntry) + "\n")
            let state = h.paths.state.str
            try mkdirp(state)
            let pending: Value = ["strategy": "remote", "id": Value(id(900)), "title": "Orphan", "targetId": Value(id(900)), "made": [Value(orphan)],
                                  "targetSemantic": try semantic([orphanEntry], Value(id(900))), "targetSemanticVersion": 3]
            let interrupted: Value = ["at": "2026-01-01T00-00-00-000", "from": [], "to": "x", "sessions": [], "failed": [], "pending": pending]
            try writeJSON(path.join(state, "\(interrupted["at"]).json"), interrupted)
            let dry = run(["--from", "p@example.com", "--to", "z@example.com", "--dry-run", "--json"])
            eq(dry.code, 1)
            ok(dry.stdout.contains("\"stage\":\"pending\""))
            eq(try CLI.last(dry.stdout).recoveryRequired, true)
            ok(exists(orphan))
            ok(!exists(path.join(state, "quarantine")))
            let list = try JSON.parse(run(["accounts", "--json"]).stdout)
            #expect(list.some { $0.active.truthy } == false)
            #expect(list.every { $0.identityState == "unknown" })
            ok(exists(orphan))
            let recovered = run(["--from", "p@example.com", "--to", "z@example.com", "--json"])
            eq(recovered.code, 1)
            let recovery = lines(recovered.stdout)
            ok(recovery.some { $0.stage == "reconciled" })
            eq(recovery.at(-1).recoveryRequired, true)
            ok(!exists(orphan))
            let moved = run(["--from", "p@example.com", "--to", "z@example.com", "--json"])
            eq(moved.code, 1)
            let done = lines(moved.stdout).at(-1)
            eq(done.ok, false)
            eq(done.complete, true)
            eq(done.moved, 1)
            eq(done.failed.length, 1)
            eq(done.restart, false)
            let rejected = run(["undo", "--dry-run"])
            eq(rejected.code, 1)
            match(rejected.stderr, "undo accepts only --json")
            let undone = run(["undo", "--json"])
            eq(undone.code, 0)
            eq(try CLI.last(undone.stdout).sessions, 1)
        }

        @Test("menubar-style cloud moves do not invent pending work for a cleared source")
        func clearedSourceHasNoPending() throws {
            let h = try home()
            try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
            try h.record("P", SOURCE, rehomeRecord(["title": "Offline source"]))
            let moved = cli(h.root, ["--from", "p@example.com personal", "--to", "z@example.com personal", "--cloud", "--json"])
            eq(moved.code, 0, moved.stderr)
            let result = try CLI.last(moved.stdout)
            eq(result.moved, 1)
            eq(result.pendingCloud, 0)
            eq(result.complete, true)
            deq(.strings(try readdir(h.dir("P"))), [])
            deq(.strings(try readdir(h.dir("Z"))), [Value("local_\(SOURCE).json")])

            let accountRows = try JSON.parse(cli(h.root, ["accounts", "--json"]).stdout)
            eq(accountRows.find { $0.account.str == h.acct.P && $0.org.str == h.org.P }.pending, nil)
            ok(accountRows.every { $0.receiptDone === result.destinationLabel })
            let done = { () throws -> Value in Value(unique(try JSON.parse(cli(h.root, ["accounts", "--json"]).stdout).map { $0.receiptDone }.elements)) }
            let saved = try readJSON(result.receipt.str)
            try writeJSON(result.receipt.str, .spread(saved, ["cloudChecks": [["account": Value(h.acct.P), "org": Value(h.org.P), "label": "P", "sessionIds": ["session_old"], "status": "pending"]]]))
            deq(try done(), [nil])
            try writeJSON(result.receipt.str, .spread(saved, ["verification": ["ok": false, "problems": [["id": Value(SOURCE), "check": "transcript"]]]]))
            deq(try done(), [nil])
            try writeJSON(result.receipt.str, saved)
            deq(try done(), [result.destinationLabel])

            let undone = cli(h.root, ["undo", "--json"])
            eq(undone.code, 0)
            deq(.strings(try readdir(h.dir("P"))), [Value("local_\(SOURCE).json")])
            deq(.strings(try readdir(h.dir("Z"))), [])
            ok(try JSON.parse(cli(h.root, ["accounts", "--json"]).stdout).every { $0.receiptDone === .null })
        }

        @Test("human CLI names staged Undo instead of printing false success")
        func stagedUndo() throws {
            let h = try home()
            let at = "2099-01-03T00-00-00-000"
            let receipt: Value = [
                "at": Value(at), "from": ["source"], "to": "target", "sessions": [], "failed": [], "superseded": [], "undoing": [],
                "remoteUndoing": [["id": "cse_pending_undo", "title": "Pending undo", "account": Value(h.acct.T), "org": Value(h.org.T), "accountLabel": "t@example.com · Team T"]],
            ]
            try mkdirp(h.paths.state)
            try writeJSON(path.join(h.paths.state.str, "\(at).json"), receipt)
            let result = cli(h.root, ["undo"])

            eq(result.code, 1)
            match(result.stdout, "pending.*t@example.com", "i")
            noMatch(result.stdout, #"quarantine\s+undefined"#)
            noMatch(result.stdout, "chat messages (?:unchanged|preserved)")
            let continued = cli(h.root, ["finish", "--json"])
            eq(continued.code, 1)
            eq(try CLI.last(continued.stdout).pendingUndo.length, 1)
        }

        @Test("human CLI reports Finish recovery without an undefined pending count")
        func finishRecoveryWording() throws {
            let h = try home()
            let at = "2099-01-04T00-00-00-000"
            let receipt: Value = [
                "at": Value(at), "from": ["source"], "to": "target", "sessions": [], "failed": [], "superseded": [], "finalizing": true,
                "cloudChecks": [["account": Value(h.acct.T), "org": Value(h.org.T), "label": "t@example.com · Team T", "status": "pending"]],
            ]
            try mkdirp(h.paths.state)
            try writeJSON(path.join(h.paths.state.str, "\(at).json"), receipt)
            let result = cli(h.root, ["finish"])

            eq(result.code, 1)
            match(result.stdout, "recovered.*finalization rolled back", "i")
            noMatch(result.stdout, "undefined cloud checks")
        }

        @Test("picker reducer")
        func pickerReducer() throws {
            var s: Value = ["cursor": 0, "chosen": .newSet(), "size": 3, "multi": true]
            s = try step(s, "up")
            eq(s.cursor, 2)
            s = try step(try step(s, "down"), "space")
            deq(Value(s.chosen.elements), [0])
            eq(try step(.spread(s, ["chosen": .newSet()]), "return").done, .undefined)
            eq(try step(s, "return").done, true)
            let single = try step(["cursor": 1, "chosen": .newSet(), "size": 3, "multi": false], "return")
            deq(Value(single.chosen.elements), [1])
            eq(single.done, true)
        }

        @Test("menubar snapshot renders live accounts without installing")
        func menubarSnapshot() throws {
            let h = try home()
            let output = path.join(h.root, "snapshot", "panel.png")
            let result = cli(h.root, ["menubar", "--snapshot", output])

            eq(result.code, 1)
            match(result.stderr, "ships as Claude Handoff.app")
            ok(!exists(output))
            ok(!exists(path.join(h.paths.state.str, "Claude Handoff.app")))
            ok(!exists(path.join(h.root, "Library/LaunchAgents/io.github.derek-miller.claude-handoff.plist")))
        }

        @Test("CLI accounts reports checkpoint corruption without changing recovery data")
        func checkpointCorruption() throws {
            _ = try CLI.checkpointAccountsFixture()
        }

        @Test("task approval tokens reject empty and malformed values without file mutations through API and CLI")
        func approvalTokens() throws {
            for operation in ["move", "finish", "undo", "restart", "idle finish", "held finish"] {
                let h = try taskFamilyFixture(), (from, to) = try h.selection(), harness = taskHarness([])
                if operation == "finish" { try interruptTaskFamily(h, "move", "target") }
                if operation == "undo" || operation == "held finish" {
                    _ = try executeMove([from], to, h.paths, ["processes": operation == "undo" ? [] : desktopFixture(), "moveOnly": true])
                }
                let command = operation == "move" ? ["--from", "p@example.com", "--to", "t@example.com"] : [operation.hasSuffix("finish") ? "finish" : operation]
                let before = try fixtureSnapshot(h, [h.root])
                for approve in ["", "invalid"] {
                    let options: Value = ["io": harness.io, "processes": [], "approve": Value(approve)]
                    let result = operation.hasSuffix("finish") ? try finishWorkflow(h.paths, options)
                        : operation == "undo" ? try undo(h.paths, options)
                        : try executeMove(operation == "move" ? [from] : nil, operation == "move" ? to : nil, h.paths, options)
                    deq(result, ["ok": false, "code": "RESTART_APPROVAL_CHANGED", "reason": "Restart approval is missing or does not match the saved plan"], operation)
                    deq(try fixtureSnapshot(h, [h.root]), before, operation)
                    let rejected = cli(h.root, command + ["--restart-approved", approve, "--json"])
                    eq(rejected.code, 1, operation)
                    match(rejected.stderr, "restart approval token must be the one displayed by the engine")
                    eq(lines(rejected.stdout).find { $0.done.truthy }.code, "COMMAND_FAILED", operation)
                    deq(try fixtureSnapshot(h, [h.root]), before, operation)
                    #expect(harness.calls == [], "\(operation)")
                }
            }
        }

        @Test("CLI accounts exposes task recovery through Finish without selecting historical refusals")
        func taskRecoveryThroughFinish() throws {
            let h = try taskFamilyFixture(true, 1)
            let desktop = Value.spread(desktopFixture()[0], ["started": "Fri Sep 4 18:00:00 2026"])
            let running = { processSetup(list: "\(desktop.pid) 1 \(desktop.started) \(desktop.executable)", commands: "\(desktop.pid) 1 \(desktop.started) Claude") }
            let stopped = { processSetup(list: "", commands: "") }
            try interruptTaskFamily(h, "move", "target")
            let state = h.paths.state.str
            let file = path.join(state, try readdir(state).first { re(#"^\d.*\.json$"#).test($0) }!)
            let receipt = try readJSON(file)
            eq(receipt.finalizing, true)
            deq(receipt.held, [])
            eq(receipt.taskTransfers.length, 1)
            receipt.fromAccounts.push(["account": Value(h.acct.Q), "org": Value(h.org.Q), "label": "Unrelated source"])
            receipt.failed.push(["id": Value(id(799)), "title": "Historical refusal", "error": "scheduled task family member missing"])
            try writeJSON(file, receipt)
            let before = try readData(file)
            let listed = cli(h.root, ["accounts", "--json"], setup: running)
            eq(listed.code, 0, listed.stderr)
            let pending = lines(listed.stdout)[0].filter { $0.pending.truthy }
            eq(pending.length, 1)
            eq(pending[0].account, Value(h.acct.P))
            eq(pending[0].org, Value(h.org.P))
            eq(pending[0].pending, "recovery")
            eq(pending[0].pendingAction, "finish")
            eq(pending[0].receipt, Value(file))
            deq(pending[0].pendingFailures, [])
            #expect(try readData(file) == before)
            let harness = taskHarness()
            let plan = try finishWorkflow(h.paths, ["io": harness.io])
            ok(plan.plan)
            eq(plan.plan.kind, "recover")
            eq(plan.plan.receiptFile, Value(file))
            #expect(harness.calls == [])
            let recovered = try finishWorkflow(h.paths, ["io": harness.io, "approve": plan.plan.token])
            eq(recovered.restarted, true)
            eq(recovered.recoveryRequired, true)
            #expect(harness.calls == ["/usr/bin/osascript", "/usr/bin/open"])
            deq(try readJSON(h.sourceFile), h.sourceRegistry)
            deq(try readJSON(h.targetFile), h.targetRegistry)
            let recoveredBytes = try readData(file)
            for (setup, action) in [(stopped, "finish"), (running, "restart")] {
                let result = cli(h.root, ["accounts", "--json"], setup: setup)
                eq(result.code, 0, result.stderr)
                let again = lines(result.stdout)[0].filter { $0.pending.truthy }
                deq(again.map { [$0.account, $0.pending, $0.pendingAction] }, [[Value(h.acct.P), "local", Value(action)]])
                #expect(try readData(file) == recoveredBytes)
            }
            let finished = try finishWorkflow(h.paths, ["processes": []])
            eq(finished.file, Value(file))
            eq(finished.ok, true)
            eq(finished.complete, true)
            eq(finished.receipt.sessions.length, 3)
            ok(finished.notMoved.some { $0.title == "Historical refusal" })
            ok(lines(cli(h.root, ["accounts", "--json"], setup: stopped).stdout)[0].every { $0.pending === .null })
        }

        @Test("panel idle timing joins distinct record and CLI IDs without timing stopped, unrelated or scheduler-held workers")
        func panelIdleTiming() throws {
            let h = try home(), f = try identityFixture(h), second = id(2), cold = id(3)
            let recordIds = [SOURCE: id(101), second: id(102), cold: id(103)]
            let started = CLI.lstart(f.started)
            let list = "500 1 \(started) /Applications/Claude.app/Contents/MacOS/Claude\n501 500 \(started) /tmp/claude\n502 500 \(started) /tmp/claude"
            let commands = "500 1 \(started) Claude\n501 500 \(started) claude --resume \(SOURCE)\n502 500 \(started) claude --resume \(second)"
            let table = try parseProcesses(Value(list), Value(commands))
            for session in [SOURCE, second, cold] {
                try h.write(session, [entry("user", Int(session.suffix(3))!, nil, session)])
                try h.record("P", recordIds[session]!, rehomeRecord(["cliSessionId": Value(session)]))
            }
            let all = try accounts(h.paths, table), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
            let moved = try executeMove([from], to, h.paths, ["processes": table, "moveOnly": true])
            eq(moved.receipt.held.length, 2)
            for held in moved.receipt.held.elements {
                eq(held.recordId, Value("local_\(recordIds[held.id.str]!)"))
                ne(held.recordId, Value("local_\(held.id)"))
            }
            let idle = { (session: String, seconds: Int, offset: Double) in
                f.event(offset, "[WarmLifecycle:session] Starting idle timeout for local_\(recordIds[session] ?? session): \(seconds)s")
            }
            let cases: [(String, String, Value)] = [
                ("matching", idle(SOURCE, 900, 1) + idle(second, 900, 1), 900),
                ("different duration", idle(SOURCE, 120, 1) + idle(second, 120, 1), 120),
                ("stale launch", idle(SOURCE, 900, -1) + idle(second, 900, 1), nil),
                ("other worker", idle(id(99), 900, 1) + idle(second, 900, 1), nil),
                ("unknown shape", f.event(1, "[WarmLifecycle:session] Idle timeout: 900s"), nil),
                ("mixed duration", idle(SOURCE, 900, 1) + idle(second, 600, 1), nil),
                ("ambiguous duration", idle(SOURCE, 900, 1) + idle(second, 900, 1) + idle(SOURCE, 600, 1), nil),
                ("partial line", idle(SOURCE, 900, 1) + idle(second, 900, 1).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression), nil),
                ("future line", idle(SOURCE, 900, 172800) + idle(second, 900, 1), nil),
                ("outside bounded tail", idle(SOURCE, 900, 1) + String(repeating: "x", count: 4 * 1024 * 1024) + "\n" + idle(second, 900, 1), nil),
            ]
            for (name, text, expected) in cases {
                try f.write(f.`init`() + text)
                let result = try pendingPresentation(moved.receipt, from, from, "local", table, false, try idleTimeouts(h.paths, table))
                eq(result.pendingIdleSeconds, expected, name)
                eq(result.pendingAutomatic, true, name)
                if name == "matching" {
                    let listed = cli(h.root, ["accounts", "--json"]) { processSetup(list: list, commands: commands) }
                    eq(listed.code, 0, listed.stderr)
                    eq(lines(listed.stdout)[0].find { $0.account === from.account }.pendingIdleSeconds, 900)
                    let variants: [(String, Value)] = [
                        ("stopped", table.slice(0, 1)),
                        ("unrelated", table.map { .spread($0, ["ids": [Value(id(99))]]) }),
                        ("external", table.map { $0.pid == 501 ? .spread($0, ["desktopPid": nil]) : $0 }),
                    ]
                    for (name, workers) in variants {
                        let timeouts = try idleTimeouts(h.paths, workers)
                        eq(timeouts.get("local_\(recordIds[SOURCE]!)"), 900, name)
                        eq(try pendingPresentation(moved.receipt, from, from, "local", workers, false, timeouts).pendingIdleSeconds, nil, name)
                    }
                    for scheduler in [false, true] {
                        let receipt = moved.receipt.deepClone()
                        if !scheduler { receipt.held[0].release = "scheduler" }
                        let protectedState = try pendingPresentation(receipt, from, from, "local", table, Value(scheduler), try idleTimeouts(h.paths, table))
                        eq(protectedState.pendingAutomatic, false)
                        eq(protectedState.pendingIdleSeconds, nil)
                    }
                    eq(try idleTimeouts(h.paths, []).size, 0)
                    eq(try idleTimeouts(h.paths, table.concat([.spread(table[0], ["pid": 999])])).size, 0)
                }
            }
            try unlink(path.join(h.paths.logs.str, "main.log"))
            eq(try idleTimeouts(h.paths, table).size, 0)
            deq(try readJSON(moved.file.str).held, moved.receipt.held)
        }

        @Test("panel states distinguish typed waiting, ownership and login scopes")
        func panelStates() throws {
            let source: Value = ["account": Value(id(901)), "org": Value(id(911)), "sessionIds": ["session_one"]], receipt: Value = ["remote": []]
            let engine = try artifactEngine()
            let signedIn: Value = ["active": true, "signedIn": true]
            for (code, state, action) in [("CLOUD_HISTORY_UNREADABLE", "waiting", "wait"), ("CLOUD_ARTIFACT_UNCERTAIN", "waiting", "wait"),
                                          ("CLOUD_ARTIFACT_BUDGET", "waiting", "wait"), (nil, "waiting", "wait")] as [(String?, String, String)] {
                let failure: Value = ["id": "cse_one", "code": code.map { Value($0) } ?? .undefined, "error": "not proven to be on this Mac"]
                let current = try pendingPresentation(receipt, .spread(source, ["attemptEngine": engine, "failures": [failure]]), signedIn, "cloud")
                eq(current.pendingState, Value(state))
                eq(current.pendingAction, Value(action))
                eq(current.pendingAutomatic, true)
            }
            let waiting: Value = [["id": "cse_two", "localId": Value(SOURCE), "recordId": Value("local_\(id(99))")]]
            let mixed = try pendingPresentation(receipt, .spread(source, ["failures": [["id": "cse_one", "code": "CLOUD_HISTORY_UNREADABLE"]], "waiting": waiting]), signedIn, "cloud", desktopFixture())
            eq(mixed.pendingState, "waiting")
            eq(mixed.pendingAction, "restart")
            eq(mixed.pendingCount, 2)
            eq(mixed.pendingAutomatic, true)
            eq(try pendingPresentation(receipt, .spread(source, ["waiting": waiting]), signedIn, "cloud", desktopFixture()).pendingState, "cloud-open")
            eq(try pendingPresentation(receipt, source, ["active": false, "signedIn": true], "cloud").pendingAction, "wait")
            eq(try pendingPresentation(receipt, source, ["active": false, "signedIn": false], "cloud").pendingAction, "sign-in")
            for (remaining, signedIn, action) in [(true, true, "finish"), (true, false, "sign-in"), (false, false, "finish")] {
                let pending = try pendingPresentation(["remoteUndoing": remaining ? [["id": "cse_one"]] : []], source, ["active": false, "signedIn": Value(signedIn)], "undo")
                eq(pending.pendingAction, Value(action))
                eq(pending.pendingState, remaining ? "undo-login" : "undo")
            }
            for release in ["worker", "scheduler", nil] as [String?] {
                let held: Value = ["id": Value(SOURCE), "recordId": Value("local_\(SOURCE)"), "release": release.map { Value($0) } ?? .undefined,
                                   "sources": [.spread(source, ["id": Value(SOURCE), "file": "/synthetic/held.json"])]]
                let current = try pendingPresentation(["held": [held]], source, [:], "local", desktopFixture(), Value(release == "scheduler"))
                eq(current.pendingAutomatic, Value(release == "worker"))
                eq(current.pendingState, release == "worker" ? "open" : "held")
                eq(current.pendingAction, "restart")
                let external = try pendingPresentation(["held": [held]], source, [:], "local", [.spread(desktopFixture()[1], ["desktopPid": nil])])
                eq(external.pendingAction, "wait")
                eq(external.pendingAutomatic, false)
            }
        }

        @Test("panel leave tokens survive sweep bookkeeping and reject changed receipt or selection while preserving other work")
        func panelLeaveTokens() throws {
            for change in ["none", "retry", "selection", "receipt", "source"] {
                let h = try home()
                try h.write(SOURCE, branchEntries(4, SOURCE, 1))
                try h.record("P", SOURCE, rehomeRecord(["bridgeSessionIds": ["session_scope"]]))
                let all = try accounts(h.paths, []), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.Z }
                let moved = try move(try inventory([from], to, h.paths, NOOP, ["cloudRequested": true, "processes": []]), to, h.paths)
                let failure: Value = [["id": "cse_scope", "code": "CLOUD_ARTIFACT_UNCERTAIN", "error": "Waiting for a complete check"]]
                if change == "retry" {
                    let initial = try readJSON(moved.file.str)
                    initial.cloudChecks[0].checkedAt = "2026-10-10T00:00:00.000Z"
                    initial.cloudChecks[0].status = "failed"
                    initial.cloudChecks[0].failures = failure
                    try writeJSON(moved.file.str, initial)
                }
                let listed = cli(h.root, ["accounts", "--json"])
                eq(listed.code, 0, listed.stderr)
                let selected = lines(listed.stdout)[0].find { $0.account === from.account }
                match(selected.pendingCancel, "^[a-f0-9]{64}$")
                eq(selected.receiptDone, nil, change)
                let receipt = try readJSON(moved.file.str)
                let other: Value = ["account": Value(h.acct.Q), "org": Value(h.org.Q), "label": "Other source", "status": "pending", "sessionIds": ["session_other"]]
                receipt.cloudChecks.push(other)
                receipt.held = [["id": Value(id(998)), "title": "Unrelated held work", "sources": [["account": Value(h.acct.T), "org": Value(h.org.T), "id": Value(id(998)), "file": "/synthetic/held.json"]], "workers": []]]
                if change == "retry" {
                    receipt.cloudChecks[0].checkedAt = Value(isoNow())
                    receipt.cloudChecks[0].status = "failed"
                    receipt.cloudChecks[0].failures = failure.deepClone()
                }
                if change == "selection" { receipt.cloudChecks[0].sessionIds.push("session_later") }
                if change == "source" { receipt.cloudChecks[0].org = Value(h.org.T) }
                try writeJSON(moved.file.str, receipt)
                if change == "receipt" { try writeJSON(path.join(h.paths.state.str, "2099-01-01T00-00-00-000.json"), receipt) }
                let before = try readData(moved.file.str), result = try keepLocal(h.paths, ["checks": [selected.pendingCancel]])
                if ["selection", "receipt", "source"].contains(change) {
                    eq(result.code, "PENDING_CHANGED", change)
                    #expect(try readData(moved.file.str) == before, "\(change)")
                } else {
                    eq(result.cancelled, 1, change)
                    eq(result.complete, false, change)
                    eq(result.heldCancelled, 0, change)
                    deq(result.receipt.held, receipt.held, change)
                    deq(result.receipt.cloudChecks[1], other, change)
                    eq(result.receipt.localCancelledAt, .undefined, change)
                }
            }
        }

        @Test("CLI JSON forwards validated whole-move session counters")
        func sessionCounters() throws { _ = try CLI.cliProgressFixture() }

        @Test("synthetic menubar installation reports the package version without invoking app actions")
        func syntheticMenubarInstallation() throws {
            let h = try home()
            for _ in 0..<2 {
                var actions: [String] = []
                let result = cli(h.root, ["menubar"]) {
                    let spawn = childProcess.spawnSync, command = childProcess.command
                    let watched = { (file: String) in file.contains(".app/") || ["launchctl", "pkill", "/bin/launchctl", "/usr/bin/open", "/usr/bin/osascript", "swiftc"].contains(file) }
                    childProcess.spawnSync = { file, args, options in
                        if watched(file) { actions.append(file); return SpawnResult(status: nil, error: EngineError("unexpected app action")) }
                        return spawn(file, args, options)
                    }
                    childProcess.command = { file, args, timeout in
                        if watched(file) { actions.append(file); return SpawnResult(status: nil, error: EngineError("unexpected app spawn")) }
                        return command(file, args, timeout)
                    }
                }
                eq(result.code, 1)
                match(result.stderr, "ships as Claude Handoff.app; install it from the release DMG")
                #expect(actions == [])
                ok(!exists(path.join(h.paths.state.str, "Claude Handoff.app")))
                ok(!exists(path.join(h.paths.state.str, "menubar.json")))
            }
        }

        @Test("menubar heap calculations never reduce the installing Node heap on 8, 16 or 48 GiB Macs")
        func menubarHeap() throws {
            let heap = 4.0 * 1_073_741_824.0 + 48 * 1024 * 1024
            for gib in [8.0, 16, 48] {
                let setting = try menubarHeapMiB(Value(gib * 1_073_741_824.0), Value(heap))
                ok(toNumber(setting) * 1024 * 1024 >= heap)
                eq(setting, Value(max((heap / 1024 / 1024).rounded(.up), (gib * 1_073_741_824.0 * 0.2 * 0.65 / 1024 / 1024).rounded(.down))))
            }
            ok(toNumber(try menubarHeapMiB(Value(48 * 1_073_741_824.0), Value(heap))) > toNumber(try menubarHeapMiB(Value(8 * 1_073_741_824.0), Value(heap))))
        }
    }
}
