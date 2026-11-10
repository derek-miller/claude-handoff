import Foundation
import Testing
@testable import HandoffCore

extension Engine.Restarts {
    // The receipt in the state directory (the only one these fixtures write).
    static func receiptFile(_ h: Home) throws -> String {
        let name = try readdir(h.paths.state.str).first { JSRegExp.cached(#"^\d.*\.json$"#).test($0) }!
        return path.join(h.paths.state.str, name)
    }

    @Test("task recovery scopes validation, restart and accounts to the unfinished family")
    func taskRecoveryScopes() throws {
        for active in ["T", "Q"] {
            let h = try taskFamilyFixture()
            h.tasks[1].notifySessionId = Value("local_\(h.second)")
            try h.record("P", h.second, rehomeRecord(["scheduledTaskId": h.tasks[1].id, "notifySessionId": Value("local_\(h.second)")]))
            for sid in [SOURCE, h.run] { try rename(h.recordFile("P", sid), h.recordFile("Q", sid)) }
            let firstRegistry: Value = ["scheduledTasks": [h.tasks[0]], "recordedSkips": ["task_0": h.sourceRegistry.recordedSkips.task_0], "runRetries": ["task_0": h.sourceRegistry.runRetries.task_0]]
            try writeJSON(path.join(h.dir("Q"), "scheduled-tasks.json"), firstRegistry)
            h.sourceRegistry.scheduledTasks = [h.tasks[1]]
            h.sourceRegistry.recordedSkips.removeKey("task_0")
            h.sourceRegistry.runRetries.removeKey("task_0")
            try writeJSON(h.sourceFile, h.sourceRegistry)
            h.sourceAccounts = [h.acct.Q, h.acct.P]
            try interruptTaskFamily(h, "move", "source")
            let file = try Self.receiptFile(h)
            let interrupted = try readJSON(file)
            eq(interrupted.taskTransfers.length, 2)
            eq(interrupted.appendCheckpoint.taskTransfers, 1)
            let target = try readJSON(h.targetFile), completed = target.scheduledTasks.find { $0.id == "task_0" }
            completed.enabled = true
            completed.lastRunAt = "2026-09-10T00:00:00Z"
            try writeJSON(h.targetFile, target)
            let originals = try [SOURCE, h.run].map { try readData(h.recordFile("T", $0)) }
            let badge = lines(cli(h.root, ["accounts", "--json"]).stdout).at(-1)
            deq(badge.filter { $0.pending.truthy }.map { $0.account }, [Value(h.acct.P)])
            let f = try identityFixture(h)
            try writeJSON(h.paths.desktop.str, ["lastKnownAccountUuid": Value(h.acct[active])])
            try f.write(f.`init`(1, h.acct[active], h.org[active]))
            let harness = taskHarness(f.processes, f.processes)
            var result = try finishWorkflow(h.paths, ["io": harness.io])
            if active == "T" {
                ok(result.plan)
                eq(result.plan.kind, "recover")
                result = try finishWorkflow(h.paths, ["io": harness.io, "approve": result.plan.token])
                eq(result.restarted, true)
            } else {
                eq(result.plan, .undefined)
                #expect(harness.calls == [])
            }
            eq(result.recoveryRequired, true)
            deq(try readJSON(h.targetFile), target)
            deq(try readJSON(h.sourceFile), h.sourceRegistry)
            #expect(try [SOURCE, h.run].map { try readData(h.recordFile("T", $0)) } == originals)
            ok(exists(h.recordFile("P", h.second)))
            let receipt = try readJSON(file)
            eq(receipt.taskTransfers.length, 1)
            eq(receipt.finalizing, false)
            let before = try fixtureSnapshot(h)
            let refused = try undo(h.paths, ["processes": []])
            match(refused.restoreProblems.join(" "), "registrations changed")
            deq(try fixtureSnapshot(h), before)
        }
    }

    static let checkpointPatches: [(String, Value)] = [
        ("inconsistent zero", ["taskTransfers": 0]),
        ("missing offset", ["taskTransfers": .undefined]),
        ("null offset", ["taskTransfers": nil]),
        ("negative offset", ["taskTransfers": -1]),
        ("fractional offset", ["taskTransfers": 0.5]),
        ("out-of-range offset", ["taskTransfers": 3]),
        ("uncommitted family offset", ["taskTransfers": 2]),
        ("missing committed records", ["sessions": 0]),
        ("missing committed retirement", ["superseded": 0]),
        ("valid checkpoint", [:]),
    ]

    @Test("task checkpoint integrity refuses corruption before recovery writes or restart", arguments: ["stopped Desktop", "approved restart"], checkpointPatches.map { $0.0 })
    func checkpointIntegrity(mode: String, scenario: String) throws {
        let patch = Self.checkpointPatches.first { $0.0 == scenario }!.1
        let h = try taskCheckpointFixture(), sessions = h.sessions, tasks = h.tasks, sourceFile = h.sourceFile, targetFile = h.targetFile
        let sourceRegistry = h.sourceRegistry, originalRecords = h.originalRecords
        try interruptTaskFamily(h, "move", "source", interruptAfter: 2)
        let file = try Self.receiptFile(h)
        let interrupted = try readJSON(file), checkpoint = interrupted.appendCheckpoint
        eq(interrupted.finalizing, true)
        deq([checkpoint.sessions, checkpoint.superseded, checkpoint.taskTransfers], [1, 1, 1])
        eq(interrupted.taskTransfers.length, 2)
        let targetBefore = try readData(targetFile), firstRecord = try readData(h.recordFile("T", sessions[0]))
        deq(try JSON.parse(targetBefore).scheduledTasks, [tasks[0]])
        deq(try readJSON(sourceFile).scheduledTasks, [])
        let harness = taskHarness(mode == "approved restart" ? [desktopFixture()[0]] : [])
        let planned = mode == "approved restart" ? try finishWorkflow(h.paths, ["io": harness.io]) : Value.null
        if planned.truthy { eq(planned.plan.kind, "recover") }
        let options = Value.spread(["io": harness.io, "processes": []], planned.truthy ? ["approve": planned.plan.token] : [:])
        let planFile = path.join(h.paths.state.str, "restart-plan.json"), planBefore = readDataOrNil(planFile)
        if scenario != "valid checkpoint" {
            try writeJSON(file, .spread(interrupted, ["appendCheckpoint": .spread(checkpoint, patch)]))
            let before = try fixtureSnapshot(h)
            var writes: [String] = []
            let saved = (fs.writeFile, fs.open, fs.rename, fs.link, fs.unlink, fs.rm)
            fs.writeFile = { p, d, flag, m in writes.append(flag.hasPrefix("a") ? "appendFile" : "writeFile"); try saved.0(p, d, flag, m) }
            // The engine opens state/lock itself to flock it.
            let lock = path.join(h.paths.state.str, "lock")
            fs.open = { p, flags, m in if Self.mutatingOpen(flags) && p != lock { writes.append("open \(p)") }; return try saved.1(p, flags, m) }
            fs.rename = { a, b in writes.append("rename"); try saved.2(a, b) }
            fs.link = { a, b in writes.append("link"); try saved.3(a, b) }
            fs.unlink = { a in writes.append("unlink"); try saved.4(a) }
            fs.rm = { a, r, f in writes.append("rm"); try saved.5(a, r, f) }
            throwsError("invalid append checkpoint") { try finishWorkflow(h.paths, options) }
            throwsError("invalid append checkpoint") {
                planned.truthy
                    ? try executeMove(nil, nil, h.paths, .spread(options, ["recover": true, "receiptFile": Value(file)]))
                    : try finishPending(h.paths, options)
            }
            (fs.writeFile, fs.open, fs.rename, fs.link, fs.unlink, fs.rm) = saved
            #expect(writes == [], "\(writes)")
            #expect(harness.calls == [])
            deq(try fixtureSnapshot(h), before)
            #expect(readDataOrNil(planFile) == planBefore)
            let retained = try readJSON(file)
            eq(retained.finalizing, true)
            eq(retained.taskTransfers.length, 2)
            retained.appendCheckpoint = checkpoint
            try writeJSON(file, retained)
        }
        let recovered = try finishWorkflow(h.paths, options)
        eq(recovered.recoveryRequired, true)
        #expect(harness.calls == (planned.truthy ? ["/usr/bin/osascript", "/usr/bin/open"] : []))
        if planned.truthy { eq(recovered.restarted, true) }
        let receipt = try readJSON(file)
        eq(receipt.finalizing, false)
        eq(receipt.appendCheckpoint, .undefined)
        deq(receipt.sessions.map { $0.id }, [Value(sessions[0])])
        eq(receipt.superseded.length, 1)
        eq(receipt.taskTransfers.length, 1)
        #expect(try readData(targetFile) == targetBefore)
        deq(try readJSON(sourceFile), ["scheduledTasks": [tasks[1]],
                                       "recordedSkips": ["task_2": sourceRegistry.recordedSkips.task_2], "runRetries": ["task_2": sourceRegistry.runRetries.task_2]])
        #expect(try readData(h.recordFile("T", sessions[0])) == firstRecord)
        #expect(try readData(h.recordFile("P", sessions[1])) == originalRecords[1])
        ok(!exists(h.recordFile("P", sessions[0])))
        ok(!exists(h.recordFile("T", sessions[1])))
        ok(try undo(h.paths, ["processes": []]).dest)
        deq(try readJSON(sourceFile), sourceRegistry)
        #expect(try sessions.map { try readData(h.recordFile("P", $0)) } == originalRecords)
        ok(!exists(targetFile))
    }

    @Test("task schedulers require an explicit restart for active or unknown namespaces")
    func schedulersRequireRestart() throws {
        for identity in ["active", "unknown", "inactive"] {
            let h = try taskFamilyFixture(), f = try identityFixture(h)
            if identity == "unknown" { try f.write(f.event(1, "[LocalSessionManager] Org changed")) }
            if identity == "inactive" {
                try writeJSON(h.paths.desktop.str, ["lastKnownAccountUuid": Value(h.acct.Z)])
                try f.write(f.`init`(1, h.acct.Z, h.org.Z))
            }
            let (from, to) = try h.selection()
            let result = try executeMove([from], to, h.paths, ["processes": f.processes])
            if identity == "inactive" { eq(result.receipt.sessions.length, 4, identity); continue }
            ok(result.plan, identity)
            eq(Set(result.plan.held.flatMap { $0.sources.map { $0.id } }.elements.map(\.str)).count, 3)
            deq(try readJSON(h.sourceFile), h.sourceRegistry)
            let partial = try executeMove([from], to, h.paths, ["processes": f.processes, "moveOnly": true])
            eq(partial.receipt.sessions.length, 1)
            eq(partial.complete, false)
            let background = try sweep(h.paths, ["processes": f.processes])
            eq(background.result.pendingLocal, true)
            let completed = try finishHeld(h.paths, ["processes": []])
            eq(completed.receipt.sessions.length, 4)
            eq(completed.complete, true)
        }
    }

    @Test("a Desktop worker holds the entire task family in the exact source namespace")
    func workerHoldsTaskFamily() throws {
        for sameLogin in [false, true] {
            let h = try taskFamilyFixture(false, 1), f = try identityFixture(h), other = id(704)
            if sameLogin { h.acct.Q = h.acct.P; try mkdirp(h.dir("Q")) }
            try writeJSON(h.paths.desktop.str, ["lastKnownAccountUuid": Value(h.acct.Z)])
            try f.write(f.`init`(1, h.acct.Z, h.org.Z))
            try h.write(other, branchEntries(1, other, 400))
            try h.record("Q", other, rehomeRecord(["notifySessionId": Value("local_\(SOURCE)")]))
            let all = try accounts(h.paths, f.processes)
            let from = all.filter { [h.org.P, h.org.Q].contains($0.org.str) }, to = all.find { $0.account.str == h.acct.T }
            let rows: Value = [.spread(f.processes[0], ["desktopPid": 500]), desktopFixture()[1]]
            let inv = try inventory(from, to, h.paths, NOOP, ["processes": rows])
            ok(inv.sources.filter { $0.account.org.str == h.org.P }.every { !$0.schedulerBusy.truthy })
            let plan = try restartPlan(inv, h.paths, rows)
            #expect(Set(plan.held.flatMap { $0.sources.map { $0.id } }.elements.map(\.str)) == [SOURCE, h.run])
            ok(plan.held.every { $0.sources.every { $0.account.str == h.acct.P && $0.org.str == h.org.P } })
            let partial = try executeMove(from, to, h.paths, ["processes": rows, "moveOnly": true])
            deq(partial.receipt.sessions.map { $0.id }, [Value(h.cold)])
            eq(partial.receipt.failed.length, 1)
            eq(partial.receipt.failed[0].id, Value(other))
            ok(!partial.receipt.failed.some { [SOURCE, h.run].contains($0.id.str) })
            eq(Set(partial.receipt.failed.elements.map { JSON.text($0) }).count, partial.receipt.failed.length)
            let finished = try finishHeld(h.paths, ["processes": f.processes])
            eq(finished.ok, true)
            eq(finished.complete, true)
            eq(finished.receipt.sessions.length, 3)
            eq(finished.added, 2)
            eq(finished.targetChanged, true)
            eq(finished.file, partial.file)
            eq(finished.notMoved.length, 1)
            deq(finished.failed, [])
            deq(try readJSON(h.targetFile), h.targetAfter)
            ok(exists(h.recordFile("Q", other)))
        }
    }
}
