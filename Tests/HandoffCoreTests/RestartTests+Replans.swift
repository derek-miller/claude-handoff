import Foundation
import Testing
@testable import HandoffCore

extension Engine.Restarts {
    @Test("restart batches restore task twins at every existing checkpoint", arguments: ["receipt", "source", "record", "retiring", "target"])
    func restartBatchesRestoreTwins(stage: String) throws {
        let h = try taskCheckpointFixture()
        h.restart = true
        let disabled = h.tasks.map { .spread($0, ["enabled": false, "notifySessionId": nil]) }
        let targetRegistry: Value = [
            "scheduledTasks": Value([["id": "before", "enabled": false]] + disabled.elements + [["id": "after", "enabled": false]]),
            "recordedSkips": ["task_1": h.sourceRegistry["recordedSkips"]["task_1"]], "future": "preserved",
        ]
        try writeJSON(h.targetFile, targetRegistry)
        h.notificationId = h.sessions[0]
        try interruptTaskFamily(h, "move", stage)
        let file = try Self.receiptFile(h)
        let interrupted = try readJSON(file)
        eq(interrupted["taskTransfers"].length, 1)
        eq(interrupted["taskTransfers"][0]["ids"].length, 2)
        deq(interrupted["taskTransfers"][0]["replaced"].map { $0["index"] }, [1, 2])
        let mock = taskHarness([])
        let recovered = try finishWorkflow(h.paths, ["io": mock.io, "processes": []])
        eq(recovered["recoveryRequired"], true, stage)
        #expect(mock.calls == ["/usr/bin/open"])
        deq(try readJSON(h.sourceFile), h.sourceRegistry)
        deq(try readJSON(h.targetFile), targetRegistry)
        for (n, sid) in h.sessions.enumerated() {
            #expect(try readData(h.recordFile("P", sid)) == h.originalRecords[n])
            ok(!exists(h.recordFile("T", sid)))
        }
    }

    @Test("restart replans scheduler closure after quit without widening the approved files")
    func restartReplansSchedulerClosure() throws {
        for change in ["new task", "new run", "new run with another family", "unrelated record"] {
            let h = try taskFamilyFixture(), mixed = change == "new run with another family"
            if mixed {
                h.sourceRegistry["scheduledTasks"][1]["notifySessionId"] = Value("local_\(h.second)")
                try h.record("P", h.second, rehomeRecord(["scheduledTaskId": h.tasks[1]["id"], "notifySessionId": Value("local_\(h.second)")]))
                try writeJSON(h.sourceFile, h.sourceRegistry)
            }
            let (from, to) = try h.selection(), mock = taskHarness()
            let plan = try executeMove([from], to, h.paths, ["io": mock.io])
            let later = id(798)
            mock.beforeQuit = {
                ok(exists(h.recordFile("T", h.cold)), change)
                if change == "new task" {
                    h.sourceRegistry["scheduledTasks"].push(["id": "new_task", "notifySessionId": Value("local_\(SOURCE)"), "enabled": true])
                    try writeJSON(h.sourceFile, h.sourceRegistry)
                } else {
                    try h.write(later, [entry("user", 798, nil, later)])
                    try h.record("P", later, rehomeRecord(change.hasPrefix("new run") ? ["scheduledTaskId": h.tasks[0]["id"], "notifySessionId": Value("local_\(SOURCE)")] : [:]))
                }
            }
            let result = try executeMove([from], to, h.paths, ["io": mock.io, "approve": plan["plan"]["token"]])
            #expect(mock.calls == ["/usr/bin/osascript", "/usr/bin/open"], "\(change)")
            eq(result["restarted"], true, change)
            if change.hasPrefix("new run") {
                eq(result["ok"], false, change)
                eq(result["receipt"]["sessions"].length, mixed ? 2 : 1, change)
                eq(result["receipt"]["held"].length, mixed ? 2 : 3, change)
                eq(result["receipt"]["startedAt"], plan["plan"]["requestedAt"])
                ok(result["receipt"]["failed"].some { TextPattern.cached("family member missing").test($0["error"].description) }, change)
                if !mixed { deq(try readJSON(h.sourceFile), h.sourceRegistry) }
            } else {
                eq(result["ok"], true, result["reason"].description)
                eq(result["receipt"]["sessions"].length, 4, change)
                if change == "new task" { deq(try readJSON(h.targetFile)["scheduledTasks"].slice(1), h.sourceRegistry["scheduledTasks"]) }
            }
            if change != "new task" {
                ok(exists(h.recordFile("P", later)), change)
                ok(!exists(h.recordFile("T", later)), change)
            }
        }
    }

    @Test("restart batches keep their receipt on native quit veto and reopen failure without retrying")
    func restartBatchesKeepReceiptOnFailure() throws {
        for failure in ["quit", "reopen"] {
            let h = try taskFamilyFixture(), (from, to) = try h.selection(), mock = taskHarness(), command = mock.io["command"]
            mock.io["wait"] = fn { args in mock.time += args[0].asNumber ?? 0; return .undefined }
            mock.io["command"] = fn { args in
                let file = args[0].str
                if failure == "quit" && file.hasSuffix("osascript") || failure == "reopen" && file.hasSuffix("/open") {
                    mock.calls.append(file)
                    return ["status": 1]
                }
                return try command.call(args[0])
            }
            let plan = try executeMove([from], to, h.paths, ["io": mock.io])
            let result = try executeMove([from], to, h.paths, ["io": mock.io, "approve": plan["plan"]["token"]])
            eq(result["ok"], false, failure)
            eq(result["restarted"], false, failure)
            eq(result["restartOutcome"]["outcome"], Value(failure == "quit" ? "quit-not-confirmed" : "reopen-failed"))
            #expect(mock.calls == (failure == "quit" ? ["/usr/bin/osascript"] : ["/usr/bin/osascript", "/usr/bin/open"]))
            ok(mock.time <= 30000, failure)
            let receipt = try readJSON(result["file"].str)
            eq(receipt["finalizing"], false)
            eq(receipt["sessions"].length, failure == "quit" ? 1 : 4, failure)
            eq(receipt["held"].length, failure == "quit" ? 3 : 0, failure)
            let events = try Self.restartEvents(h)
            eq(Set(events.elements.map { $0["attemptId"].str }).count, 1)
            eq(events.at(-1)["stopCode"], Value(failure == "quit" ? "QUIT_UNCONFIRMED" : "REOPEN_FAILED"))
            ok(try undo(h.paths, ["processes": []])["dest"])
            deq(try readJSON(h.sourceFile), h.sourceRegistry)
            deq(try readJSON(h.targetFile), h.targetRegistry)
        }
    }

    @Test("a worker appearing during an approved warm scan returns a typed plan change without moving or quitting")
    func workerDuringWarmScan() throws {
        let h = try taskFamilyFixture(), (from, to) = try h.selection(), mock = taskHarness()
        let planned = try executeMove([from], to, h.paths, ["io": mock.io])
        let file = path.join(h.paths["state"].str, "restart-plan.json"), planBytes = try readData(file), before = try fixtureSnapshot(h)
        var changed = false
        let result = try executeMove([from], to, h.paths, ["io": mock.io, "approve": planned["plan"]["token"], "report": fn { args in
            if args[0] != "scan" || changed { return .undefined }
            changed = true
            mock.rows = mock.rows.concat([.spread(desktopFixture(h.run)[1], ["pid": 701])])
            return .undefined
        }])
        #expect(changed)
        eq(result["ok"], false)
        eq(result["code"], "RESTART_PLAN_CHANGED")
        match(result["reason"], "Open Claude sessions changed")
        eq(result["receipt"], .undefined)
        #expect(mock.calls == [])
        deq(try fixtureSnapshot(h), before)
        #expect(try readData(file) == planBytes)
    }

    @Test("a changed pre-quit inventory preserves completed ordinary work and the held selection")
    func changedPreQuitInventory() throws {
        let h = try taskFamilyFixture(), (from, to) = try h.selection(), mock = taskHarness()
        let plan = try executeMove([from], to, h.paths, ["io": mock.io])
        var changed = false
        let result = try executeMove([from], to, h.paths, ["io": mock.io, "approve": plan["plan"]["token"], "report": fn { args in
            if changed || args[0] != "move" || Self.arg(args, 2)["completed"] != 1 { return .undefined }
            changed = true
            mock.rows = mock.rows.concat([.spread(desktopFixture(h.run)[1], ["pid": 701])])
            return .undefined
        }])
        #expect(changed)
        eq(result["ok"], false)
        match(result["reason"], "sessions changed")
        #expect(mock.calls == [])
        deq(result["receipt"]["sessions"].map { $0["id"] }, [Value(h.cold)])
        eq(result["receipt"]["held"].length, 3)
        eq(try readJSON(path.join(h.paths["state"].str, "restart-plan.json"))["token"], plan["plan"]["token"])
        let next = try finishHeld(h.paths, ["io": mock.io])
        ok(next["plan"])
        eq(next["plan"]["receiptFile"], result["file"])
        eq(next["plan"]["requestedAt"], plan["plan"]["requestedAt"])
        #expect(next["plan"]["selection"]["from"][0]["files"].elements.map(\.str).sorted() == result["receipt"]["held"].flatMap { $0["sources"].map { $0["file"] } }.elements.map(\.str).sorted())
        ne(next["plan"]["token"], plan["plan"]["token"])
        #expect(mock.calls == [])
    }

    @Test("scheduler changes before approval move into the fresh restart batch")
    func schedulerChangesBeforeApproval() throws {
        let h = try taskFamilyFixture(), (from, to) = try h.selection(), mock = taskHarness()
        let plan = try executeMove([from], to, h.paths, ["io": mock.io])
        h.sourceRegistry["scheduledTasks"].push(["id": "new_task", "notifySessionId": Value("local_\(h.cold)"), "enabled": true])
        try writeJSON(h.sourceFile, h.sourceRegistry)
        mock.beforeQuit = {
            let names = try readdir(h.dir("T"))
            #expect(names == ["scheduled-tasks.json"])
        }
        let result = try executeMove([from], to, h.paths, ["io": mock.io, "approve": plan["plan"]["token"]])
        eq(result["ok"], true, result["reason"].description)
        eq(result["receipt"]["sessions"].length, 4)
        eq(result["receipt"]["taskTransfers"].length, 1)
        deq(try readJSON(h.targetFile)["scheduledTasks"].slice(1), h.sourceRegistry["scheduledTasks"])
        #expect(mock.calls == ["/usr/bin/osascript", "/usr/bin/open"])
    }

    @Test("a partial restart batch publication restores the failed twin and completes the independent family")
    func partialBatchPublication() throws {
        let h = try taskCheckpointFixture()
        let target: Value = ["scheduledTasks": h.tasks.map { .spread($0, ["enabled": false, "notifySessionId": nil]) }]
        try writeJSON(h.targetFile, target)
        let (from, to) = try Self.pair(h, "P", "T", []), mock = taskHarness()
        let plan = try executeMove([from], to, h.paths, ["io": mock.io]), link = fs.link
        fs.link = { a, b in
            if b == h.recordFile("T", h.sessions[1]) { throw EngineError("fixture second placement failed") }
            try link(a, b)
        }
        let result = try executeMove([from], to, h.paths, ["io": mock.io, "approve": plan["plan"]["token"]])
        fs.link = link
        eq(result["ok"], false)
        eq(result["receipt"]["sessions"].length, 1)
        eq(result["receipt"]["sessions"][0]["id"], Value(h.sessions[0]))
        eq(result["receipt"]["finalizing"], false)
        let source = try readJSON(h.sourceFile), destination = try readJSON(h.targetFile)
        deq(source["scheduledTasks"], [h.tasks[1]])
        deq(destination["scheduledTasks"], [target["scheduledTasks"][1], h.tasks[0]])
        deq(source["recordedSkips"], ["task_2": h.sourceRegistry["recordedSkips"]["task_2"]])
        deq(source["runRetries"], ["task_2": h.sourceRegistry["runRetries"]["task_2"]])
        #expect(try readdir(h.dir("T")).filter { $0.hasPrefix("local_") } == ["local_\(h.sessions[0]).json"])
        #expect(try readData(h.recordFile("P", h.sessions[1])) == h.originalRecords[1])
        eq(result["summary"]["notMoved"].length, 1)
        ok(try undo(h.paths, ["processes": []])["dest"])
        deq(try readJSON(h.sourceFile), h.sourceRegistry)
        deq(try readJSON(h.targetFile), target)
    }
}
