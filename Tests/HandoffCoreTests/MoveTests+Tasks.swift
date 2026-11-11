import Darwin
import Foundation
import Testing
@testable import HandoffCore

extension Engine.Moves {
    @Test("deleted task history rechecks its registration and state before each run moves")
    func deletedTaskHistoryRechecks() throws {
        for scenario in ["source task", "target task", "new retry"] {
            let h = try taskHistoryFixture(), (from, to) = try h.selection()
            let inv = try inventory([from], to, h.paths, NOOP, ["processes": []])
            eq(inv.move.length, 2)
            if scenario.hasSuffix("task") { try writeJSON(scenario == "source task" ? h.sourceFile : h.targetFile, ["scheduledTasks": [["id": Value(h.taskId), "enabled": true]]]) }
            if scenario == "new retry" {
                let retries = Value.newObject()
                retries[h.taskId] = .newObject()
                try writeJSON(h.sourceFile, .spread(h.registry, ["runRetries": retries]))
            }
            let before = try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str])
            let result = try move(inv, to, h.paths)
            if scenario == "source task" {
                eq(result.ok, true, scenario)
                eq(result.receipt.taskTransfers.length, 1, scenario)
                continue
            }
            eq(result.ok, false, scenario)
            eq(result.receipt.sessions.length, 0, scenario)
            deq(try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str]), before, scenario)
        }
    }

    @Test("stale task twins replace once and restore their positions and state without losing later edits")
    func staleTaskTwinsReplace() throws {
        for identical in [false, true] {
            let h = try taskFamilyFixture(!identical, 2, 1, true)
            if identical { h.targetRegistry.scheduledTasks.asArray!.items.replaceSubrange(0..<2, with: h.tasks.elements) }
            h.targetRegistry.recordedSkips.task_0 = h.sourceRegistry.recordedSkips.task_0
            try writeJSON(h.targetFile, h.targetRegistry)
            let (from, to) = try h.selection(), result = try executeMove([from], to, h.paths, ["processes": []])
            eq(result.ok, true, JSON.text(["failed": result.receipt.failed, "recovery": result.reconciled, "verification": result.receipt.verification]))
            eq(result.receipt.taskTransfers[0].replaced.length, 2)
            deq(result.receipt.taskTransfers[0].replaced[0], [
                "task": h.targetRegistry.scheduledTasks[0], "index": 0,
                "state": ["recordedSkips": ["task_0": h.sourceRegistry.recordedSkips.task_0], "runRetries": [:]],
                "stateFields": ["recordedSkips", "runRetries"],
            ])
            deq(try readJSON(h.targetFile), h.targetAfter)
            let before = try readData(h.targetFile)
            _ = try finishWorkflow(h.paths, ["processes": []])
            #expect(try readData(h.targetFile) == before)
            let target = try JSON.parse(before)
            target.future.later = "kept"
            target.scheduledTasks.push(["id": "later_task", "enabled": false])
            try writeJSON(h.targetFile, target)
            ok(try undo(h.paths, ["processes": []]).dest)
            deq(try readJSON(h.targetFile), .spread(h.targetRegistry, ["future": target.future, "scheduledTasks": h.targetRegistry.scheduledTasks.concat([target.scheduledTasks.at(-1)])]))
            deq(try readJSON(h.sourceFile), h.sourceRegistry)
        }
    }

    @Test("stale task twins refuse each unsafe condition and recheck changes before publication")
    func staleTaskTwinsRefuse() throws {
        for reason in ["enabled", "cronExpression", "notification record exists", "record dependency", "records unreadable", "recordedSkips", "runRetries"] {
            let h = try taskFamilyFixture(true, 1, 1, true), twin = h.targetRegistry.scheduledTasks[0]
            if reason == "enabled" { twin.enabled = true }
            if reason == "cronExpression" { twin.cronExpression = "changed" }
            if reason == "notification record exists" { try h.record("T", id(799)) }
            if reason == "record dependency" { try h.record("T", id(798), ["notifySessionId": twin.notifySessionId]) }
            if reason == "records unreadable" { try writeText(h.recordFile("T", id(798)), "{broken") }
            if ["recordedSkips", "runRetries"].contains(reason) { h.targetRegistry[reason]["task_0"] = ["different": true] }
            try writeJSON(h.targetFile, h.targetRegistry)
            let (from, to) = try h.selection(), inv = try inventory([from], to, h.paths, NOOP, ["processes": []])
            deq(inv.move.map { $0.id }, [Value(h.cold)], reason)
            ok(inv.blocked.every { $0.error.str.contains(reason) }, reason)
        }
        for late in ["enabled", "record"] {
            let h = try taskFamilyFixture(true, 1, 1, true), (from, to) = try h.selection()
            let inv = try inventory([from], to, h.paths, NOOP, ["processes": []])
            if late == "enabled" { h.targetRegistry.scheduledTasks[0].enabled = true }
            else { try h.record("T", h.run, rehomeRecord(["scheduledTaskId": h.tasks[0].id, "notifySessionId": h.tasks[0].notifySessionId])) }
            try writeJSON(h.targetFile, h.targetRegistry)
            let result = try move(inv, to, h.paths)
            eq(result.ok, false, late)
            deq(try readJSON(h.sourceFile), h.sourceRegistry, late)
            deq(try readJSON(h.targetFile), h.targetRegistry, late)
        }
    }

    @Test("4.1.0 refusal projection requires unique current identity and bridge ownership with a fresh consistency check")
    func legacyRefusalProjection() throws {
        let scenarios = ["unchanged", "missing directory", "ambiguous", "unreadable", "unreadable directory", "vanished record", "foreign bridge",
                         "malformed foreign bridge", "malformed transcript bridge", "changed while reading"]
        for scenario in scenarios {
            let f = try refusalFixture(), h = f.h, receipt = try readJSON(f.result.file.str)
            for failure in receipt.failed.elements {
                failure.removeKey("sources")
                failure.removeKey("blockedByLocal")
                if failure.code == "CLOUD_UNPROVEN" { failure.removeKey("code") }
            }
            receipt.cloudChecks[0].status = "failed"
            receipt.fromAccounts.push(["account": Value(h.acct.Q), "org": Value(h.org.Q), "label": "Other source"])
            let investorTranscript = h.transcript(f.investor)
            if scenario == "missing directory" { try rmrf(h.dir("Q")) }
            if scenario == "ambiguous" { try h.record("Q", f.investor, rehomeRecord(["bridgeSessionIds": ["session_investor"]])) }
            if scenario == "unreadable" { try writeText(h.recordFile("P", id(799)), "{broken") }
            if scenario == "vanished record" { try h.record("Q", id(799)) }
            if scenario.contains("foreign bridge") {
                try appendText(investorTranscript, JSON.text(["type": "bridge-session", "bridgeSessionId": "session_investor", "ownerAccountUuid": Value(h.acct.Q), "ownerOrganizationUuid": Value(h.org.Q)]) + "\n")
            }
            if scenario == "malformed transcript bridge" {
                try writeJSON(f.investorFile, .spread(try readJSON(f.investorFile), ["bridgeSessionIds": []]))
                try appendText(investorTranscript, JSON.text(["type": "bridge-session", "bridgeSessionId": "session_investor", "ownerAccountUuid": Value(h.acct.P), "ownerOrganizationUuid": Value(h.org.P)]) + "\n")
            }
            if scenario.hasPrefix("malformed") { try appendText(investorTranscript, "{broken\n") }
            try writeJSON(f.result.file.str, receipt)
            let original = fs.readFile, originalReaddir = fs.readdir
            var reads = 0
            let vanished = h.recordFile("Q", id(799))
            fs.readFile = { file in
                if scenario == "vanished record" && file == vanished { throw fsError(ENOENT, "open", file) }
                if scenario == "changed while reading" && file == f.investorFile {
                    reads += 1
                    if reads == 2 { try writeJSON(f.investorFile, .spread(try readJSON(f.investorFile), ["title": "Changed during projection"])) }
                }
                return try original(file)
            }
            fs.readdir = { dir in
                if scenario == "unreadable directory" && dir == h.dir("Q") { throw fsError(EACCES, "scandir", dir) }
                return try originalReaddir(dir)
            }
            let result: Value
            do {
                defer { fs.readFile = original; fs.readdir = originalReaddir }
                result = try verifyPlaced(h.paths)
            }
            let projected = ["unchanged", "missing directory"].contains(scenario)
            eq(result.ok, Value(projected), scenario)
            let saved = try readJSON(f.result.file.str), failure = saved.failed.find { $0.id.str == f.investor }
            eq(failure.sources[0].recordSha, .undefined, scenario)
            if projected {
                ok(failure.sources[0].observedRecordSha, scenario)
                eq(failure.sources[0].sessionId, Value(f.recordId), scenario)
                eq(saved.cloudChecks[0].status, "blocked-local", scenario)
                eq(result.summary.notMoved.length, 10, scenario)
            } else {
                eq(saved.failed.find { $0.id == "cse_investor" }.blockedByLocal, .undefined, scenario)
            }
        }
    }

    @Test("one refusal preserves multiple source record identities without guessing missing evidence")
    func refusalPreservesSourceIdentities() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        for account in ["P", "Q"] { try h.record(account, SOURCE, rehomeRecord(["title": "Same title"])) }
        let otherOrg = path.join(h.paths.records.str, h.acct.P, h.org.Q)
        try mkdirp(otherOrg)
        try writeData(path.join(otherOrg, "local_\(SOURCE).json"), try readData(h.recordFile("P", SOURCE)))
        try h.record("T", SOURCE, rehomeRecord(["sessionId": Value("local_\(id(888))")]))
        let all = try accounts(h.paths), to = all.find { $0.account.str == h.acct.T }
        let inv = try inventory(all.filter { [h.acct.P, h.acct.Q].contains($0.account.str) }, to, h.paths, NOOP, ["processes": []])
        let result = try move(inv, to, h.paths)
        eq(result.summary.notMoved.length, 3)
        eq(Set(result.summary.notMoved.elements.map { "\($0.account)/\($0.org)/\($0.sessionId)" }).count, 3)
        eq(result.receipt.failed.find { $0.sources.length == 3 && $0.sources.isArray }.sources.length, 3)
        let summary = try receiptSummary(["failed": [["id": Value(SOURCE), "title": "Same title", "error": "unreadable"]]])
        eq(summary.notMoved.length, 0)
        eq(summary.attention.length, 1)
    }

    @Test("unsafe task families leave ordinary records movable")
    func unsafeTaskFamilies() throws {
        for reason in ["missing record", "missing history", "task collision", "source collision", "record collision", "omitted member"] {
            let h = try taskFamilyFixture()
            _ = try h.selection()
            if reason == "missing record" { try unlink(h.recordFile("P", SOURCE)) }
            if reason == "missing history" { try unlink(h.transcript(h.run)) }
            if reason == "task collision" {
                try writeJSON(h.targetFile, .spread(h.targetRegistry, ["scheduledTasks": h.targetRegistry.scheduledTasks.concat([.spread(h.tasks[0], ["enabled": true])])]))
            }
            if reason == "source collision" {
                try h.record("Q", h.run, rehomeRecord(["scheduledTaskId": h.tasks[0].id]))
                try writeJSON(path.join(h.dir("Q"), "scheduled-tasks.json"), ["scheduledTasks": [h.tasks[0]]])
            }
            if reason == "record collision" { try h.record("T", h.run, rehomeRecord(["scheduledTaskId": h.tasks[0].id])) }
            let fresh = try h.selection()
            if reason == "omitted member" { fresh.from.sessions = fresh.from.sessions.filter { $0.id.str != h.run } }
            var sources = [fresh.from]
            if reason == "source collision" { sources.append(try accounts(h.paths).find { $0.account.str == h.acct.Q }) }
            let inv = try inventory(Value(sources), fresh.to, h.paths, NOOP, ["processes": []])
            deq(inv.move.map { $0.id }, [Value(h.cold)], reason)
            let moved = try move(inv, fresh.to, h.paths)
            eq(moved.receipt.sessions.length, 1, reason)
            deq(try readJSON(h.sourceFile), h.sourceRegistry, reason)
        }
    }

    @Test("resumed mixed ordinary and task work counts every newly placed record")
    func resumedMixedWork() throws {
        let h = try taskFamilyFixture(), (_, to) = try h.selection(), firstId = id(705)
        try h.write(firstId, branchEntries(1, firstId, 405))
        try h.record("P", firstId, rehomeRecord())
        let fresh = try h.selection()
        let rows = desktopFixture(h.cold).concat([.spread(desktopFixture(SOURCE)[1], ["pid": 502, "started": "family worker"])])
        let first = try executeMove([fresh.from], to, h.paths, ["processes": rows, "moveOnly": true])
        deq(first.receipt.sessions.map { $0.id }, [Value(firstId)])
        let finished = try finishHeld(h.paths, ["processes": []])
        eq(finished.file, first.file)
        eq(finished.ok, true)
        eq(finished.added, 4)
        eq(finished.receipt.sessions.length, 5)
        eq(finished.targetChanged, true)
        eq(finished.complete, true)
    }

    @Test("task transfer uses final registration state and preserves later unrelated registry edits")
    func taskTransferFinalState() throws {
        let h = try taskFamilyFixture(), (from, to) = try h.selection()
        let inv = try inventory([from], to, h.paths, NOOP, ["processes": []])
        h.sourceRegistry.scheduledTasks[0].lastRunAt = "2026-09-02T00:00:00Z"
        h.sourceRegistry.scheduledTasks[0].enabled = true
        h.sourceRegistry.recordedSkips.task_0[0].reason = "missed before transfer"
        h.sourceRegistry.runRetries.task_0.attempts = 4
        try writeJSON(h.sourceFile, h.sourceRegistry)
        var changed = false
        let result = try move(inv, to, h.paths, fn { args in
            if Self.arg(args, 0) != "move" || !(Self.arg(args, 2)["completed"] == 1) || changed { return .undefined }
            let source = try readJSON(h.sourceFile)
            if source.scheduledTasks.length > 0 { return .undefined }
            changed = true
            for file in [h.sourceFile, h.targetFile] { try writeJSON(file, .spread(try readJSON(file), ["futureDuringMove": ["intact": true]])) }
            return .undefined
        })
        eq(result.ok, true)
        #expect(changed)
        eq(try readJSON(h.targetFile).scheduledTasks.find { $0.id === h.tasks[0].id }.enabled, true)
        deq(try readJSON(h.targetFile).recordedSkips.task_0, h.sourceRegistry.recordedSkips.task_0)
        deq(try readJSON(h.targetFile).runRetries.task_0, h.sourceRegistry.runRetries.task_0)
        for file in [h.sourceFile, h.targetFile] { try writeJSON(file, .spread(try readJSON(file), ["futureDuringUndo": [1, 2]])) }
        ok(try undo(h.paths, ["processes": []]).dest)
        deq(try readJSON(h.sourceFile), .spread(h.sourceRegistry, ["futureDuringMove": ["intact": true], "futureDuringUndo": [1, 2]]))
        deq(try readJSON(h.targetFile), .spread(h.targetRegistry, ["futureDuringMove": ["intact": true], "futureDuringUndo": [1, 2]]))
    }

    @Test("a failed task-family placement rolls back the family and keeps ordinary moves")
    func failedTaskFamilyPlacement() throws {
        let h = try taskFamilyFixture(true), (from, to) = try h.selection()
        let original = fs.link, blocked = h.recordFile("T", SOURCE)
        fs.link = { a, b in
            if b == blocked { throw JSError("fixture publication failure") }
            try original(a, b)
        }
        let result: Value
        do {
            defer { fs.link = original }
            result = try executeMove([from], to, h.paths, ["processes": []])
        }
        eq(result.ok, false)
        eq(result.receipt.localStopped, true)
        deq(result.receipt.sessions.map { $0.id }, [Value(h.cold)])
        deq(try readJSON(h.sourceFile), h.sourceRegistry)
        deq(try readJSON(h.targetFile), h.targetRegistry)
        eq(try keepLocal(h.paths).ok, true)
        let fresh = try h.selection()
        eq(try executeMove([fresh.from], fresh.to, h.paths, ["processes": []]).receipt.sessions.length, 3)
    }

    @Test("a late destination alias cannot take a task family through an id collision")
    func lateDestinationAlias() throws {
        let h = try taskFamilyFixture(), (from, to) = try h.selection(), alias = id(715)
        let inv = try inventory([from], to, h.paths, NOOP, ["processes": []])
        try h.record("T", SOURCE, rehomeRecord(["sessionId": Value("local_\(alias)")]))
        try rename(h.recordFile("T", SOURCE), h.recordFile("T", alias))
        let result = try move(inv, to, h.paths)
        eq(result.ok, false)
        deq(result.receipt.sessions.map { $0.id }, [Value(h.cold)])
        deq(try readJSON(h.sourceFile), h.sourceRegistry)
        match(result.receipt.failed.at(-1).error, "session id collision")
    }

    @Test("a changed trusted project alias cannot authorize a move through identical file inodes")
    func changedTrustedProjectAlias() throws {
        let h = try home()
        try h.write(SOURCE, branchEntries(4, SOURCE, 1))
        try h.record("P", SOURCE, rehomeRecord())
        try mkdirp(path.join(h.project, SOURCE))
        try writeText(path.join(h.project, SOURCE, "ordinary"), "Synthetic sidecar")
        let change = try mappedProjectFixture(h)
        let all = try accounts(h.paths, []), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.Z }
        let inv = try inventory([from], to, h.paths, NOOP, ["processes": []])
        try change()
        var reports: [String] = []
        let moved = try move(inv, to, h.paths, fn { args in reports.append(Self.arg(args, 0).str); return .undefined })
        #expect(reports.contains("recovery"))
        eq(moved.ok, true)
        deq(try Self.names(h.dir("P")), [])
    }
}
