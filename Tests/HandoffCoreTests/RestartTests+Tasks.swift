import Darwin
import Foundation
import Testing
@testable import HandoffCore

extension Engine.Restarts {
    // Whether open() flags can change the file.
    static func mutatingOpen(_ flags: Int32) -> Bool { flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC | O_APPEND) != 0 }

    @Test("bridge review recovery leaves committed rows outside a held continuation alone")
    func bridgeReviewRecovery() throws {
        let h = try bridgeFixture(), cold = id(300)
        try h.write(cold, [entry("user", 300, nil, cold), .spread(h.bridge, ["sessionId": Value(cold)])])
        try h.record("P", cold, rehomeRecord())
        let from = try accounts(h.paths, []).find { $0["account"].str == h.acct.P }
        let first = try executeMove([from], h.to, h.paths, ["processes": desktopFixture(), "moveOnly": true])
        deq(first["receipt"]["sessions"].map { $0["id"] }, [Value(cold)])
        throwsError("Synthetic interrupted continuation") {
            try finishHeld(h.paths, ["processes": [], "report": fn { args in
                if args[0] == "retire" && Self.arg(args, 1) == "checking" { throw EngineError("Synthetic interrupted continuation") }
                return .undefined
            }])
        }
        let transcript = h.transcript(cold)
        try appendText(transcript, "\(JSON.text(.spread(h.bridge, ["sessionId": Value(cold), "bridgeSessionId": "cse_newer", "ownerAccountUuid": h.to["account"], "ownerOrganizationUuid": h.to["org"]])))\n")
        let before = try readData(transcript)
        _ = try undo(h.paths, ["processes": []])
        let recovered = try readReceipt(first["file"])
        deq(recovered["sessions"].map { $0["id"] }, [Value(cold)])
        #expect((recovered["finalizing"].truthy || recovered["appendCheckpoint"].truthy || recovered["pending"].truthy) == false)
        #expect(try readData(transcript) == before)
        ok(exists(h.recordFile("P", SOURCE)))
        eq(readOrNil(h.recordFile("Z", SOURCE)), nil)
    }

    @Test("bridge review final worker guard includes distinct Desktop aliases", arguments: ["record only", "shared child", "external worker"])
    func bridgeReviewWorkerGuard(mode: String) throws {
        let h = try bridgeFixture(), recordUuid = id(9001), recordId = "local_\(recordUuid)"
        if mode == "shared child" {
            try h.record("P", recordUuid, rehomeRecord(["cliSessionId": Value(SOURCE), "forkedFromSessionId": Value("local_\(SOURCE)")]))
        } else {
            try h.record("P", SOURCE, rehomeRecord(["sessionId": Value(recordId)]))
            try rename(h.recordFile("P", SOURCE), path.join(h.dir("P"), "\(recordId).json"))
        }
        var active = false, injected = false
        let inspect = fn { _ in active ? [["worker": true, "pid": 123, "desktopPid": mode == "external worker" ? nil : 100, "ids": [Value(recordUuid)]]] : [] }
        let from = try accounts(h.paths, []).find { $0["account"].str == h.acct.P }
        let inv = try inventory([from], h.to, h.paths, NOOP, ["inspect": inspect])
        let realOpen = fs.open
        fs.open = { file, flags, mode in
            if file == h.transcriptPath && Self.mutatingOpen(flags) { active = true; injected = true }
            return try realOpen(file, flags, mode)
        }
        let result = try move(inv, h.to, h.paths)
        fs.open = realOpen
        #expect(injected)
        eq(result["ok"], false)
        #expect(try readData(h.transcriptPath) == h.before)
        #expect(try readdir(h.dir("Z")) == [])
    }

    @Test("archived runs of a deleted routine move cold before any restart and undo without recreating it")
    func deletedRoutineMovesCold() throws {
        let h = try taskHistoryFixture(167), (from, to) = try h.selection(), mock = taskHarness()
        let before = try fixtureSnapshot(h, [h.paths["records"].str, h.paths["pool"].str])
        let registries = try [h.sourceFile, h.targetFile].map(readData)
        let result = try executeMove([from], to, h.paths, ["io": mock.io])
        eq(result["plan"], .undefined)
        eq(result["ok"], true, JSON.text(result["receipt"]["failed"]))
        eq(result["receipt"]["sessions"].length, 167)
        eq(result["receipt"]["superseded"].filter { $0["source"].truthy }.length, 167)
        eq(result["receipt"]["taskTransfers"], .undefined)
        #expect(mock.calls == [])
        #expect(try [h.sourceFile, h.targetFile].map(readData) == registries)
        #expect(try readdir(h.dir("P")).filter { $0.hasPrefix("local_") } == [])
        for sid in h.sessions {
            let record = try readJSON(h.recordFile("T", sid))
            eq(record["scheduledTaskId"], Value(h.taskId))
            eq(record["isArchived"], true)
        }
        ok(try undo(h.paths, ["processes": []])["dest"])
        deq(try fixtureSnapshot(h, [h.paths["records"].str, h.paths["pool"].str]), before)
    }

    @Test("deleted task history retains missing-member, scheduler-state and ownership guards")
    func deletedTaskHistoryGuards() throws {
        for scenario in ["unarchived", "notification", "missing history", "unreadable source", "unreadable target", "source registry", "target registry", "target task", "target notification", "mixed registration", "source skips", "target retries", "worker"] {
            let h = try taskHistoryFixture(), first = h.sessions[0]
            if scenario == "unarchived" { try h.record("P", first, rehomeRecord(["scheduledTaskId": Value(h.taskId)])) }
            if scenario == "notification" { try h.record("P", first, rehomeRecord(["scheduledTaskId": Value(h.taskId), "isArchived": true, "notifySessionId": Value("local_\(h.sessions[1])")])) }
            if scenario == "missing history" { try unlink(h.transcript(first)) }
            if scenario.hasPrefix("unreadable") { try writeText(path.join(h.dir(scenario == "unreadable source" ? "P" : "T"), "local_\(id(799)).json"), "{broken") }
            if scenario.hasSuffix("registry") { try writeText(scenario == "source registry" ? h.sourceFile : h.targetFile, "{broken") }
            if scenario == "target task" { try writeJSON(h.targetFile, ["scheduledTasks": [["id": Value(h.taskId), "enabled": false]]]) }
            if scenario == "target notification" { try writeJSON(h.targetFile, ["scheduledTasks": [["id": "other-task", "notifySessionId": Value("local_\(first)")]]]) }
            if scenario == "mixed registration" {
                try writeJSON(h.sourceFile, ["scheduledTasks": [["id": "active-task", "enabled": true]]])
                try h.record("P", first, rehomeRecord(["scheduledTaskId": "active-task", "isArchived": true, "forkedFromSessionId": Value("local_\(h.sessions[1])")]))
            }
            if scenario == "source skips" { try writeJSON(h.sourceFile, .spread(h.registry, ["recordedSkips": [h.taskId: []]])) }
            if scenario == "target retries" { try writeJSON(h.targetFile, .spread(h.registry, ["runRetries": [h.taskId: [:]]])) }
            let (from, to) = try h.selection(), before = try fixtureSnapshot(h, [h.paths["records"].str, h.paths["pool"].str])
            let processes: Value = scenario == "worker" ? [.spread(desktopFixture(first)[1], ["desktopPid": nil])] : []
            let inv = try inventory([from], to, h.paths, NOOP, ["processes": processes])
            if scenario.hasPrefix("unreadable") {
                let result = try move(inv, to, h.paths)
                eq(result["ok"], false, scenario)
                eq(result["receipt"]["sessions"].length, scenario == "unreadable target" ? 2 : 0, scenario)
                if scenario == "unreadable target" { continue }
            } else if ["missing history", "worker", "unarchived", "target notification"].contains(scenario) {
                deq(inv["move"].map { $0["id"] }, [Value(h.sessions[1])], scenario)
                ok(inv["missing"].concat(inv["blocked"]).some { $0["id"].str == first }, scenario)
            } else {
                eq(inv["move"].length, 0, scenario)
                ok(inv["blocked"].length > 0, scenario)
            }
            deq(try fixtureSnapshot(h, [h.paths["records"].str, h.paths["pool"].str]), before, scenario)
        }
    }

    @Test("Undo rechecks its receipt under the lock between preflight and restart planning")
    func undoRechecksReceiptUnderLock() throws {
        let h = try taskFamilyFixture(), (from, to) = try h.selection(), sid = id(798)
        _ = try executeMove([from], to, h.paths, ["processes": []])
        try h.write(sid, branchEntries(1, sid, 600))
        try h.record("Q", sid, rehomeRecord())
        let all = try accounts(h.paths, []), original = fs.mkdir
        var entries = 0, before: Value = .undefined, rows: Value = [desktopFixture()[0]]
        fs.mkdir = { p, recursive, mode in
            if p == h.paths["state"].str {
                entries += 1
                if entries == 2 {
                    let next = try executeMove([all.find { $0["account"].str == h.acct.Q }], all.find { $0["account"].str == h.acct.T }, h.paths, ["processes": []])
                    eq(next["ok"], true)
                    before = try fixtureSnapshot(h)
                    rows = []
                }
            }
            try original(p, recursive, mode)
        }
        let result = try undo(h.paths, ["io": ["inspect": fn { _ in rows }, "command": fn { _ in
            Issue.record("stale receipt must not restart")
            throw EngineError("stale receipt must not restart")
        }]])
        fs.mkdir = original
        ok(before)
        eq(result["ok"], false)
        match(result["reason"], "receipt changed")
        deq(try fixtureSnapshot(h), before)
    }
}
