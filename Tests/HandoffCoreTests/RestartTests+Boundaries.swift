import Foundation
import Testing
@testable import HandoffCore

extension Engine.Restarts {
    @Test("restart diagnostics preserve an unconfirmed quit after Desktop exits and reopens")
    func diagnosticsPreserveUnconfirmedQuit() throws {
        let h = try home(), mock = taskHarness(), plan = try restartPlan(nil, h.paths, mock.rows)
        let command = mock.io.command
        mock.io.command = fn { args in
            let result = try command.callArgs(args)
            return args[0].str.hasSuffix("osascript") ? ["status": 1] : result
        }
        var worked = false
        let result = try withDesktopRestart(plan, h.paths, fn { () in worked = true }, NOOP, mock.io)
        #expect(worked == false)
        eq(result.ok, false)
        eq(result.result, .undefined)
        eq(result.restart.outcomeBeforeReopen, "quit-not-confirmed")
        eq(result.restart.outcome, "reopened")
        #expect(mock.calls == ["/usr/bin/osascript", "/usr/bin/open"])
        let events = try Self.restartEvents(h)
        deq(events.map { $0.event }, ["start", "outcome"])
        eq(events.at(-1).outcome, "reopened")
        eq(events.at(-1).stopCode, "QUIT_UNCONFIRMED")
        eq(events.at(-1).receiptCounts, nil)
    }

    @Test("restart diagnostic retention, no-op outcomes and failures expose no content or raw errors")
    func diagnosticRetention() throws {
        let h = try home(), mock = taskHarness(), plan = try restartPlan(nil, h.paths, mock.rows)
        try mkdirp(h.paths.state)
        let file = path.join(h.paths.state.str, "restart-events.jsonl")
        try FileSystem.nativeWriteFile(file, Data(String(repeating: "{}\n", count: 1024 * 1024 / 3).utf8), "w", 0o600)
        for attempt in 0..<3 {
            mock.rows = [desktopFixture()[0]]
            _ = try withDesktopRestart(.spread(plan, ["kind": Value(attempt == 1 ? "user@example.com" : attempt == 2 ? "undo" : "refresh")]), h.paths, fn { _ in
                if attempt == 1 { throw EngineError("Synthetic private title user@example.com prompt approval-token server-response") }
                return nil
            }, NOOP, mock.io)
        }
        for name in [file, "\(file).1"] { ok((try stat(name).size.asNumber ?? .infinity) <= 1024 * 1024, name) }
        let text = try readText(file), outcomes = lines(text).filter { $0.event == "outcome" }
        deq(outcomes.map { $0.stopCode }, ["NO_WORK", "WORK_FAILED", "NO_WORK"])
        deq(outcomes.map { $0.kind }, ["restart", "restart", "undo"])
        ok(outcomes.every { $0.receiptCounts.isNull })
        noMatch(text, "private|user@|prompt|approval-token|server-response")
    }

    @Test("restart diagnostic write failures leave successful moves and task recovery outcomes intact")
    func diagnosticWriteFailures() throws {
        let h = try taskFamilyFixture(), (from, to) = try h.selection(), mock = taskHarness()
        let planned = try executeMove([from], to, h.paths, ["io": mock.io])
        let original = fs.open
        let failing: (String, Int32, Int) throws -> HandoffCore.FileHandle = { file, flags, mode in
            if file.contains("restart-events.jsonl") { throw EngineError("fixture diagnostic storage unavailable") }
            return try original(file, flags, mode)
        }
        fs.open = failing
        let completed = try executeMove([from], to, h.paths, ["io": mock.io, "approve": planned.plan.token])
        fs.open = original
        eq(completed.ok, true)
        eq(completed.receipt.sessions.length, 4)
        eq(completed.receipt.restartHistory, .undefined)
        eq(completed.receipt.restart.outcome, "reopened")
        eq(readOrNil(path.join(h.paths.state.str, "restart-events.jsonl")), nil)
        let broken = try taskFamilyFixture(true, 1)
        try interruptTaskFamily(broken, "move", "target")
        let recoveryMock = taskHarness(), recovery = try finishWorkflow(broken.paths, ["io": recoveryMock.io])
        fs.open = failing
        _ = try finishWorkflow(broken.paths, ["io": recoveryMock.io, "approve": recovery.plan.token])
        fs.open = original
        deq(try readJSON(broken.sourceFile), broken.sourceRegistry)
        deq(try readJSON(broken.targetFile), broken.targetRegistry)
        eq(try readJSON(recovery.plan.receiptFile.str).finalizing, false)
    }

    @Test("restart diagnostic folding preserves corrupt receipts and readable log outcomes")
    func diagnosticFolding() throws {
        let h = try home(), mock = taskHarness(), plan = try restartPlan(nil, h.paths, mock.rows)
        try mkdirp(h.paths.state)
        let file = path.join(h.paths.state.str, "2026-10-10T12-00-00-000.json"), log = path.join(h.paths.state.str, "restart-events.jsonl")
        try writeText(file, "unreadable fixture receipt\n")
        let raw = try readData(file)
        _ = try withDesktopRestart(.spread(plan, ["receiptFile": Value(file)]), h.paths, fn { _ in nil }, NOOP, mock.io)
        #expect(try readData(file) == raw)
        try appendText(log, "null\n{broken\n")
        mock.rows = [desktopFixture()[0]]
        let receipt: Value = ["sessions": [], "failed": [], "remote": [], "restartHistory": []]
        let result = try withDesktopRestart(.spread(plan, ["receiptFile": Value(file)]), h.paths, fn { _ in
            try writeJSON(file, receipt)
            return ["file": Value(file), "receipt": receipt, "ok": true]
        }, NOOP, mock.io)
        eq(result.ok, true)
        eq(receipt.restartHistory.length, 2)
        eq(receipt.restartHistory.at(-1).stopCode, "COMPLETE")
    }

    @Test("task transaction boundaries retain late dependencies, worker and record edits for recovery")
    func taskTransactionBoundaries() throws {
        for phase in ["placement", "retirement", "publication"] {
            for change in ["registration", "route", "external worker", "source edit", "target edit", "account switch"] {
                let label = "\(phase): \(change)"
                let h = try taskFamilyFixture(false, 1), f = try identityFixture(h)
                try writeJSON(h.paths.desktop.str, ["lastKnownAccountUuid": Value(h.acct.Z)])
                try f.write(f.`init`(1, h.acct.Z, h.org.Z))
                let (from, to) = try h.selection()
                var rows = f.processes, injected = 0
                var editedFile: String?, editedBefore: Data?, editedAfter = ""
                let source = h.recordFile("P", h.run), target = h.recordFile("T", SOURCE)
                let inject = { (args: [String]) throws in
                    let matches = phase == "placement" ? args[1] == target : phase == "retirement" ? args[0] == h.recordFile("P", SOURCE) : args[0].hasPrefix(h.targetFile + ".")
                    if !matches { return }
                    if change == "external worker" {
                        if injected == 0 { rows = rows.concat([["pid": 600, "worker": true, "ids": [Value(h.run)], "desktopPid": nil]]) }
                        injected += 1
                    } else if change == "account switch" {
                        editedFile = path.join(h.paths.logs.str, "main.log")
                        if injected == 0 { editedBefore = try readData(editedFile!) }
                        injected += 1
                        editedAfter = f.event(2, "[LocalSessionManager] Org changed")
                    } else {
                        editedFile = change == "registration" ? h.sourceFile : change == "source edit" ? (phase == "publication" ? h.recordFile("P", id(797)) : source) : target
                        if injected == 0 { editedBefore = readDataOrNil(editedFile!) }
                        injected += 1
                        let value = editedBefore.map { (try? JSON.parse($0)) ?? .undefined } ?? ["sessionId": Value("local_\(id(797))"), "cliSessionId": Value(id(797)), "scheduledTaskId": h.tasks[0].id]
                        if change == "registration" { value.scheduledTasks.push(["id": "new_dependency", "notifySessionId": Value("local_\(SOURCE)"), "enabled": false]) }
                        else if change == "route" { value.notifySessionId = Value("local_\(id(797))") }
                        else { value.title = Value("Edited during transfer \(injected)") }
                        editedAfter = JSON.text(value)
                    }
                    if let editedFile { try writeText(editedFile, editedAfter) }
                }
                let saved = (fs.link, fs.rename, fs.writeFile)
                switch phase {
                case "placement": fs.link = { a, b in try saved.0(a, b); try inject([a, b]) }
                case "retirement": fs.rename = { a, b in try saved.1(a, b); try inject([a, b]) }
                default: fs.writeFile = { p, d, flag, m in try saved.2(p, d, flag, m); try inject([p]) }
                }
                let result = try executeMove([from], to, h.paths, ["io": ["inspect": fn { _ in rows }], "processes": f.processes])
                (fs.link, fs.rename, fs.writeFile) = saved
                ok(injected > 0, label)
                eq(result.ok, false, label)
                if let editedFile { eq(try readText(editedFile), editedAfter, label) }
                deq(try readJSON(h.targetFile), h.targetRegistry, label)
                if let editedFile {
                    if let editedBefore { try writeData(editedFile, editedBefore) } else { try unlink(editedFile) }
                }
                rows = []
                if result.recoveryRequired.truthy { _ = try finishWorkflow(h.paths, ["processes": []]) }
                deq(try readJSON(h.sourceFile), h.sourceRegistry, label)
                _ = try keepLocal(h.paths)
                let fresh = try h.selection(), finished = try executeMove([fresh.from], fresh.to, h.paths, ["processes": []])
                eq(finished.ok, true, label)
                eq(finished.receipt.sessions.length, 2, label)
                ok(try undo(h.paths, ["processes": []]).dest, label)
                deq(try readJSON(h.sourceFile), h.sourceRegistry, label)
            }
        }
    }

    @Test("Keep local validates target identity and recovery even when only held work remains")
    func keepLocalValidatesTargetIdentity() throws {
        for change in ["sessionId", "cliSessionId", "cwd", "missing transcript", "missing record"] {
            let h = try home()
            try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
            try h.record("P", SOURCE, rehomeRecord())
            try h.write(id(710), [entry("user", 2, nil, id(710))])
            try h.record("P", id(710), rehomeRecord())
            let (from, to) = try Self.pair(h)
            let moved = try executeMove([from], to, h.paths, ["processes": desktopFixture(id(710)), "moveOnly": true])
            let row = moved.receipt.sessions[0]
            if change == "missing transcript" { try unlink(row.targetTranscript.str) }
            else if change == "missing record" { try unlink(row.record.str) }
            else {
                let value: Value = change == "sessionId" ? Value("local_\(id(711))") : change == "cliSessionId" ? Value(id(711)) : "/tmp/changed"
                try writeJSON(row.record.str, .spread(try readJSON(row.record.str), [change: value]))
            }
            let kept = try keepLocal(h.paths)
            ok(kept.refused.length > 0, change)
            eq(kept.receipt.held.length, 1, change)
        }
    }

    @Test("Finish of held local work treats an earlier refusal as information")
    func finishHeldEarlierRefusal() throws {
        let h = try home(), cold = id(712)
        for (index, sid) in [SOURCE, cold].enumerated() {
            try h.write(sid, [entry("user", index + 1, nil, sid)])
            try h.record("P", sid, rehomeRecord())
        }
        let (from, to) = try Self.pair(h)
        let first = try executeMove([from], to, h.paths, ["processes": desktopFixture(), "moveOnly": true])
        first.receipt.failed.push(["id": Value(id(713)), "title": "Earlier refusal", "error": "scheduled task family member missing"])
        try writeJSON(first.file.str, first.receipt)
        let finished = try finishWorkflow(h.paths, ["processes": []])
        eq(finished.ok, true)
        eq(finished.complete, true)
        deq(finished.failed, [])
        eq(finished.notMoved.length, 1)
    }

    @Test("task scheduler safety uses the exact organization and rechecks account switches")
    func schedulerSafetyExactOrganization() throws {
        for switching in [false, true] {
            let h = try taskFamilyFixture(), f = try identityFixture(h)
            try f.write(f.`init`(1, h.acct.P, h.org.Q))
            let (from, to) = try h.selection()
            var switched = false
            let result = try executeMove([from], to, h.paths, ["processes": f.processes, "report": fn { args in
                if !switching || switched || args[0] != "move" || Self.arg(args, 2).completed != 1 { return .undefined }
                if try readJSON(h.sourceFile).scheduledTasks.length > 0 { return .undefined }
                switched = true
                try writeText(path.join(h.paths.logs.str, "main.log"), f.event(2, "[LocalSessionManager] Org changed"))
                return .undefined
            }])
            if !switching { eq(result.receipt.sessions.length, 4); continue }
            #expect(switched)
            eq(result.recoveryRequired, true)
            deq(try readJSON(h.targetFile), h.targetRegistry)
            let swept = try sweep(h.paths, ["processes": f.processes])
            eq(swept.ok, false)
            match(swept.error, "scheduler requires")
            _ = try finishWorkflow(h.paths, ["processes": []])
            deq(try readJSON(h.sourceFile), h.sourceRegistry)
        }
    }
}
