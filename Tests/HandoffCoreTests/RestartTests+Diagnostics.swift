import Foundation
import Testing
@testable import HandoffCore

extension Engine.Restarts {
    static func restartEvents(_ h: Home) throws -> Value { lines(try readText(path.join(h.paths.state.str, "restart-events.jsonl"))) }

    @Test("preflight refusals stay informational on cold, restarted and successfully retried moves")
    func preflightRefusalsInformational() throws {
        for mode in ["cold", "restart", "retry", "retry refusal"] {
            let h = try home(), other = id(710), mock = taskHarness(desktopFixture())
            let good: Value = [entry("user", 810, nil, SOURCE)], bad = entry("user", 811, nil, other)
            try h.write(SOURCE, good)
            try h.write(other, mode == "retry refusal" ? [bad] : [bad, .spread(bad, ["message": ["role": "user", "content": "Conflicting history"]])])
            for key in ["P", "Q"] { for session in [SOURCE, other] { try h.record(key, session, rehomeRecord()) } }
            let (from, to) = try Self.pair(h, "P", "T", [])
            let options: Value = mode == "cold" ? ["processes": []] : ["io": mock.io]
            let planned = mode == "cold" ? Value.null : try executeMove([from], to, h.paths, options)
            let native = fs.link
            var attempts = 0
            fs.link = { a, b in
                if mode.hasPrefix("retry") && b == h.recordFile("T", SOURCE) {
                    attempts += 1
                    if attempts == 1 { throw EngineError("Synthetic temporary failure") }
                }
                try native(a, b)
            }
            let result = try executeMove([from], to, h.paths, .spread(options, ["approve": planned.plan.token, "report": fn { args in
                if mode == "retry refusal" && args[0] == "recovery" {
                    try appendText(h.transcript(SOURCE), JSON.text(.spread(good[0], ["message": ["role": "user", "content": "New conflicting history"]])) + "\n")
                }
                return .undefined
            }]))
            fs.link = native
            eq(result.summary.moved, 1, mode)
            eq(result.summary.notMoved.length, 1, mode)
            eq(result.receipt.localStopped.truthy, mode == "retry refusal", mode)
            eq(result.complete, Value(mode != "retry refusal"), mode)
            let finished = cli(h.root, ["finish", "--json"]) { processSetup(list: "", commands: "") }
            eq(finished.code, mode == "retry refusal" ? 1 : 0, finished.stdout)
            let event = lines(finished.stdout).at(-1)
            eq(event.nothing == true, mode != "retry refusal", mode)
            let listed = cli(h.root, ["accounts", "--json"]) { processSetup(list: "", commands: "") }
            let pending = lines(listed.stdout)[0].filter { $0.pending.truthy }
            eq(pending.length, mode == "retry refusal" ? 1 : 0, mode)
            if pending.length > 0 { eq(pending[0].pendingAction, "blocked") }
        }
    }

    @Test("one real stall retries the unfinished family and completes without another shutdown")
    func oneRealStall() throws {
        let h = try taskFamilyFixture(), (from, to) = try h.selection(), mock = taskHarness()
        var reports: [String] = []
        let planned = try executeMove([from], to, h.paths, ["io": mock.io])
        var stalled = false
        let result = try executeMove([from], to, h.paths, ["io": mock.io, "approve": planned.plan.token, "report": fn { args in
            reports.append(args[0].str)
            if args[0] == "move" && Self.arg(args, 2).completed == 1 && !Self.arg(args, 2).preparatory.truthy && !stalled { stalled = true; mock.time += 61_000 }
            return .undefined
        }])
        #expect(stalled)
        eq(result.ok, true, result.reason.description)
        eq(result.complete, true)
        eq(reports.filter { $0 == "recovery" }.count, 1)
        eq(result.receipt.sessions.length, 4)
        deq(result.receipt.failed, [])
        ok(!result.receipt.localStopped.truthy)
        deq(try readJSON(h.targetFile), h.targetAfter)
        #expect(mock.calls == ["/usr/bin/osascript", "/usr/bin/open"])
    }

    @Test("restart diagnostics never recreate a refused receipt or displace the previous move for Undo")
    func diagnosticsNeverRecreateRefusedReceipt() throws {
        let h = try home(), refused = id(710)
        try h.write(SOURCE, branchEntries(4, SOURCE, 1))
        try h.record("P", SOURCE, rehomeRecord())
        var (from, to) = try Self.pair(h, "P", "T", [])
        let moved = try move(try inventory([from], to, h.paths, NOOP, ["processes": []]), to, h.paths)
        eq(moved.ok, true)
        try h.write(refused, branchEntries(4, refused, 20))
        try h.record("P", refused, rehomeRecord())
        try h.record("Q", refused, rehomeRecord())
        (from, to) = try Self.pair(h, "P", "T", [])
        let mock = taskHarness(desktopFixture(refused)), planned = try executeMove([from], to, h.paths, ["io": mock.io])
        let prior = try readData(moved.file.str)
        let result = try executeMove([from], to, h.paths, ["io": mock.io, "approve": planned.plan.token, "summary": fn { () in
            eq(mock.rows.length, 0)
            try appendText(h.transcript(refused), JSON.text(entry("user", 20, nil, refused, ["message": ["role": "user", "content": "Conflicting source edit"]])) + "\n")
        }])
        eq(result.validationOnly, true)
        eq(result.file, nil)
        eq(result.restarted, true)
        #expect(receiptFiles(h).map { path.basename($0) } == [path.basename(moved.file.str)])
        #expect(try readData(moved.file.str) == prior)
        let outcome = try Self.restartEvents(h).at(-1)
        eq(outcome.stopCode, "WORK_REFUSED")
        ne(outcome.receiptId, Value(path.basename(moved.file.str)))
        ok(!exists(path.join(h.paths.state.str, outcome.receiptId.str)))
        let undone = try undo(h.paths, ["processes": []])
        ok(undone.dest)
        eq(undone.receipt["at"], moved.receipt["at"])
        ok(exists(h.recordFile("P", SOURCE)))
        ok(!exists(h.recordFile("T", SOURCE)))
    }

    @Test("restart diagnostic updates read existing receipts and journals instead of detached results")
    func diagnosticsReadExistingReceipts() throws {
        for scenario in ["missing", "pending journal", "complete journal", "invalid name"] {
            let h = try home(), mock = taskHarness(), plan = try restartPlan(nil, h.paths, mock.rows)
            try mkdirp(h.paths.state)
            let file = path.join(h.paths.state.str, scenario == "invalid name" ? "2026-10-10T12-00.json" : "2026-10-10T12-00-00-000.json")
            let original: Value = ["sessions": [], "failed": [], "remote": [], "finalizing": false]
            if scenario != "missing" { try writeJSON(file, original) }
            if scenario.hasSuffix("journal") {
                try writeText("\(file).journal", JSON.text(["sequence": 1, "pending": scenario == "pending journal" ? ["id": Value(SOURCE)] : nil,
                                                             "sessions": [["id": Value(SOURCE)]], "failed": [], "retained": []]) + "\n")
            }
            let before = readDataOrNil(file), journal = readDataOrNil("\(file).journal")
            let detached = Value.spread(original, ["detached": true])
            let result = try withDesktopRestart(.spread(plan, ["receiptFile": Value(file)]), h.paths, fn { _ in ["file": Value(file), "receipt": detached, "ok": true] }, NOOP, mock.io)
            eq(result.ok, true, scenario)
            #expect(readDataOrNil("\(file).journal") == journal, "\(scenario)")
            if scenario == "complete journal" {
                let saved = try readJSON(file)
                deq(saved.sessions, [["id": Value(SOURCE)]])
                eq(saved.journalSequence, 1)
                eq(saved.detached, .undefined)
                eq(saved.restartHistory.length, 1)
                deq(result.result.receipt.restartHistory, saved.restartHistory)
                deq(result.result.receipt.sessions, saved.sessions)
            } else {
                #expect(readDataOrNil(file) == before, "\(scenario)")
                eq(detached.restartHistory, .undefined)
            }
        }
    }

    @Test("restart diagnostics never rewrite a failed family receipt or journal and fold outcomes once after recovery")
    func diagnosticsNeverRewriteFailedReceipt() throws {
        let h = try taskFamilyFixture(), (from, to) = try h.selection(), mock = taskHarness()
        let planned = try executeMove([from], to, h.paths, ["io": mock.io])
        var snapshot: [Data]?, file = ""
        let failed = try executeMove([from], to, h.paths, ["io": mock.io, "approve": planned.plan.token, "report": fn { args in
            if args[0] != "move" || Self.arg(args, 2).completed != 2 || snapshot != nil { return .undefined }
            file = receiptFiles(h)[0]
            snapshot = [try readData(file), try readData("\(file).journal")]
            mock.time += 200
            mock.rows = [.spread(desktopFixture()[0], ["pid": 700, "desktopPid": 700, "started": "unexpected"])]
            return .undefined
        }])
        ok(snapshot != nil)
        eq(failed.ok, false)
        match(failed.reason, "reopened before")
        #expect(try [readData(file), readData("\(file).journal")] == snapshot)
        let log = path.join(h.paths.state.str, "restart-events.jsonl"), first = lines(try readText(log))
        deq(first.map { $0.event }, ["start", "exited", "outcome"])
        eq(first.at(-1).stopCode, "RESTART_REOPENED")
        eq(first.at(-1).receiptCounts, nil)
        ok(["moved", "failed", "archived"].allSatisfy { !first.at(-1).hasOwn($0) })
        ok(first.every { $0.kind == "move" })
        eq(first.at(-1).receiptId, Value(path.basename(file)))
        eq(first[0].planNonce, planned.plan.nonce)
        ok(first.every { $0.selectionId === first[0].selectionId })
        ok(!JSON.text(first).contains(planned.plan.token.str))
        mock.time = 0
        let recovery = try finishWorkflow(h.paths, ["io": mock.io])
        eq(recovery.plan.receiptFile, Value(file))
        _ = try finishWorkflow(h.paths, ["io": mock.io, "approve": recovery.plan.token])
        let recovered = try readJSON(file)
        eq(recovered.finalizing, false)
        eq(recovered.restartHistory.length, 2)
        eq(recovered.restartHistory[0].stopCode, "RESTART_REOPENED")
        eq(recovered.restartHistory[0].receiptCounts, nil)
        eq(recovered.restartHistory[1].kind, "finish")
        let continuation = try finishWorkflow(h.paths, ["io": mock.io])
        let completed = try finishWorkflow(h.paths, ["io": mock.io, "approve": continuation.plan.token])
        eq(completed.ok, true)
        eq(completed.receipt.restartHistory.length, 3)
        eq(completed.receipt.restartHistory.at(-1).stopCode, "COMPLETE")
        eq(completed.receipt.restartHistory.at(-1).kind, "finish")
        eq(completed.added, 3)
        deq(completed.receipt.restartHistory.at(-1).receiptCounts, ["sessions": 4, "failed": Value(completed.receipt.failed.length), "remote": 0])
        eq(completed.receipt.restart.outcome, "reopened")
        _ = try finishWorkflow(h.paths, ["processes": []])
        let final = try readJSON(file)
        eq(Set(final.restartHistory.elements.map { $0.attemptId.str }).count, 3)
        eq(final.restartHistory.length, 3)
        eq((try stat(log).mode.asInt ?? 0) & 0o777, 0o600)
    }
}
