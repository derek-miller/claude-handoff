import Foundation
import Testing
@testable import HandoffCore

extension Engine.Receipts {
    @Test("Keep local recognizes recorded rewinds without changing histories or relaxing Undo")
    func keepLocalRewinds() throws {
        for scenario in ["rewind", "repeated rewind", "unrelated id", "malformed lineage", "invalid id", "missing current history", "missing old history", "changed folder", "changed record"] {
            let h = try home(), current = id(796), earlier = id(795)
            try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
            try h.record("T", SOURCE, rehomeRecord())
            let all = try accounts(h.paths), from = all.find { $0.account.str == h.acct.T }, to = all.find { $0.account.str == h.acct.Z }
            let moved = try moveWithPending(h, [from], to), row = moved.receipt.sessions[0]
            try h.write(current, [entry("user", 2, nil, current)])
            let record = Value.spread(try readJSON(row.record.str), ["cliSessionId": Value(current), "priorCliSessionIds": [Value(SOURCE)]])
            if scenario == "repeated rewind" {
                try h.write(earlier, [entry("user", 3, nil, earlier)])
                record.priorCliSessionIds.push(Value(earlier))
            }
            if scenario == "unrelated id" { record.priorCliSessionIds = [Value(earlier)] }
            if scenario == "malformed lineage" { record.priorCliSessionIds = Value(SOURCE) }
            if scenario == "invalid id" { record.cliSessionId = "../invalid" }
            if scenario == "missing current history" { try unlink(h.transcript(current)) }
            if scenario == "missing old history" { try unlink(row.targetTranscript.str) }
            if scenario == "changed folder" { record.cwd = "/tmp/different" }
            if scenario == "changed record" { record.sessionId = Value("local_\(current)") }
            try writeJSON(row.record.str, record)
            let before = try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str]), receiptBefore = try readData(moved.file.str)
            let kept = try keepLocal(h.paths)
            deq(try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str]), before, scenario)
            if ["rewind", "repeated rewind"].contains(scenario) {
                eq(kept.ok, true, scenario)
                eq(kept.cancelled, 1)
                eq(kept.receipt.cloudChecks[0].status, "cancelled")
                eq(kept.receipt.sessions[0].targetId, Value(SOURCE))
                ok(try undo(h.paths).changed.some { JSRegExp.cached("desktop record").test($0.str) })
                deq(try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str]), before)
            } else {
                ok(kept.refused.length > 0, scenario)
                #expect(try readData(moved.file.str) == receiptBefore, "\(scenario)")
            }
        }
    }

    @Test("Keep local keeps strict validation for older receipts")
    func keepLocalOlderReceipts() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("T", SOURCE, rehomeRecord(["cwd": "/tmp/original"]))
        let from = try h.account("T"), to = try h.account("Z")
        let moved = try moveWithPending(h, [from], to)
        let receipt = try readJSON(moved.file.str)
        receipt.sessions[0].removeKey("recordSnapshot")
        try writeJSON(moved.file.str, receipt)
        let record = h.recordFile("Z", SOURCE)
        try writeJSON(record, .spread(try readJSON(record), ["cwd": "/tmp/changed"]))
        match(try keepLocal(h.paths).refused[0], "desktop record changed")
    }

    @Test("a unique bridge link selects a fully verified Desktop fork and Undo restores its archive state")
    func uniqueBridgeLinkFork() throws {
        for location in ["P", "T"] {
            let h = try home(), child = id(777), base = branchEntries(4, SOURCE, 1)
            try h.write(SOURCE, base)
            try h.record("T", SOURCE, rehomeRecord(["title": "Parent", "isArchived": true]))
            try h.write(child, fork(base, SOURCE, child, "Fork").concat([["type": "bridge-session", "sessionId": Value(child), "bridgeSessionId": "cse_linked_fork"]]))
            try h.record(location, child, rehomeRecord(["title": "Fork", "isArchived": true, "forkedFromSessionId": Value("local_\(SOURCE)"), "bridgeSessionIds": ["session_linked_fork"]]))
            let parentFile = h.recordFile("T", SOURCE), targetFile = h.recordFile("T", child)
            let originalParent = try readData(parentFile), originalFork = try readJSON(h.recordFile(location, child))
            var status = "active"
            let cloud = cloudFixture(h, [
                "list": fn { _ in [remoteSession(["id": "cse_linked_fork", "title": "Renamed remote fork", "status": Value(status)])] },
                "eventRows": fn { _ in remoteRows(base) },
                "session": fn { _ in remoteState(status) },
                "archive": fn { () in ok(exists(targetFile)); status = "archived" },
                "unarchive": fn { () in status = "active" },
            ])
            let from = try h.account("P"), to = try h.account("T")
            let inv = try inventory([from], to, h.paths, NOOP, ["cloud": cloud])
            deq(inv.cloud.blocked, [])
            deq(inv.cloud.matches.map { [$0.target.kind, $0.target.id] }, [[Value(location == "P" ? "move" : "existing"), Value(child)]])
            let moved = try move(inv, to, h.paths)
            eq(moved.ok, true)
            eq(status, "archived")
            deq(moved.receipt.remote.map { $0.targetId }, [Value(child)])
            deq(.strings(try readdir(h.dir("P"))), [])
            let placed = try readJSON(targetFile)
            eq(placed.isArchived, false)
            eq(placed.forkedFromSessionId, Value("local_\(SOURCE)"))
            deq(placed.bridgeSessionIds, location == "P" ? [] : ["session_linked_fork"])
            #expect(try readData(parentFile) == originalParent)
            ok(try undo(h.paths, ["cloud": cloud]).dest)
            eq(status, "active")
            #expect(try readData(parentFile) == originalParent)
            deq(try readJSON(h.recordFile(location, child)), originalFork)
        }
    }

    @Test("activation rollback restores receipt hashes for Keep local and Undo")
    func activationRollback() throws {
        let h = try home()
        let entries: Value = [entry("user", 1, nil, SOURCE), entry("assistant", 2, 1, SOURCE)]
        try h.write(SOURCE, entries)
        try h.record("P", SOURCE, rehomeRecord(["isArchived": true]))
        var reads = 0
        let cloud = cloudFixture(h, [
            "list": fn { _ in [remoteSession(["id": "cse_rollback", "title": Value("Session \(SOURCE.suffix(3))")])] },
            "eventRows": fn { _ in remoteRows(entries) },
            "session": fn { _ in reads += 1; return remoteState("active", ["last_event_at": reads >= 6 ? "changed" : "stable"]) },
            "archive": fn { () in throw JSError("archive should not run") },
        ])
        let all = try accounts(h.paths)
        let from: Value = [
            all.find { $0.account.str == h.acct.P && $0.org.str == h.org.P },
            all.find { $0.account.str == h.acct.T && $0.org.str == h.org.T },
        ]
        let to = all.find { $0.account.str == h.acct.Z && $0.org.str == h.org.Z }
        _ = try moveWithPending(h, from, to, cloud)
        let target = h.recordFile("Z", SOURCE)
        eq(try readJSON(target).isArchived, true)
        eq(try keepLocal(h.paths).ok, true)
        ok(try undo(h.paths, ["cloud": cloud]).dest)
    }

    @Test("interrupted target activation restoration resumes when the prior state is already present")
    func activationRestorationResumes() throws {
        let h = try home()
        let entries: Value = [entry("user", 1, nil, SOURCE)]
        try h.write(SOURCE, entries)
        try h.record("Z", SOURCE, rehomeRecord(["isArchived": true]))
        var status = "active"
        let cloud: Value = [
            "account": Value(h.acct.P),
            "org": Value(h.org.P),
            "list": fn { _ in [remoteSession(["id": "cse_activation_resume", "title": Value("Session \(SOURCE.suffix(3))"), "status": Value(status)])] },
            "eventRows": fn { _ in remoteRows(entries) },
            "session": fn { _ in remoteState(status) },
            "archive": fn { () in status = "archived" },
            "unarchive": fn { () in status = "active" },
        ]
        let from = try h.account("P"), to = try h.account("Z")
        let moved = try move(try inventory([from], to, h.paths, NOOP, ["cloud": cloud]), to, h.paths)
        let targetFile = h.recordFile("Z", SOURCE)
        let target = try readJSON(targetFile)
        try writeJSON(targetFile, .spread(target, ["isArchived": true]))
        let receipt = try readJSON(moved.file.str)
        receipt.undoing = []
        receipt.removeKey("remoteUndoing")
        status = "active"
        try writeJSON(moved.file.str, receipt)
        let recovered = try undo(h.paths, ["cloud": cloud])
        ok(recovered.dest)
        eq(try readJSON(targetFile).isArchived, true)
    }

    @Test("an interrupted unapplied archive leaves a tagged failure that retry clears")
    func unappliedArchive() throws {
        let h = try home()
        let entries: Value = [entry("user", 41, nil, SOURCE)]
        try h.write(SOURCE, entries)
        try h.record("Z", SOURCE, rehomeRecord(["isArchived": true]))
        var status = "active", interrupt = true
        let cloud: Value = [
            "account": Value(h.acct.P),
            "org": Value(h.org.P),
            "list": fn { _ in [remoteSession(["id": "cse_unapplied", "title": Value("Session \(SOURCE.suffix(3))"), "status": Value(status)])] },
            "eventRows": fn { _ in remoteRows(entries) },
            "session": fn { _ in remoteState(status, ["id": "cse_unapplied"]) },
            "archive": fn { () in
                if interrupt { throw JSError("connection failed before archive") }
                status = "archived"
            },
            "unarchive": fn { () in status = "active" },
        ]
        let from = try h.account("P"), to = try h.account("Z")
        let inv = try inventory([from], to, h.paths, NOOP, ["cloud": cloud, "cloudRequested": true])
        let interrupted = try move(inv, to, h.paths)
        ok(interrupted.receipt.remotePending)
        let recovered = try move(inv, to, h.paths)
        eq(recovered.recoveryRequired, true)
        interrupt = false
        let retried = try finishPending(h.paths, ["cloud": cloud])
        eq(retried.ok, true)
        eq(retried.complete, true)
        eq(retried.receipt.failed.length, 0)
        eq(status, "archived")
    }

    @Test("deleted task history recovers interrupted retirement with one record per run and moves again cold")
    func deletedTaskHistoryRecovers() throws {
        let h = try taskHistoryFixture(), before = try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str])
        try interruptTaskFamily(h, "move", "retiring")
        ok(try finishWorkflow(h.paths, ["processes": []]).reconciled)
        deq(try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str]), before)
        let settled = try finishWorkflow(h.paths, ["processes": []])
        eq(settled.ok, true, JSON.text(settled.reason))
        eq(settled.summary.notMoved.length, 2)
        let (from, to) = try h.selection(), moved = try executeMove([from], to, h.paths, ["processes": []])
        eq(moved.ok, true)
        eq(moved.receipt.sessions.length, 2)
        ok(try undo(h.paths, ["processes": []]).dest)
        deq(try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str]), before)
    }

    @Test("Undo validates every supplied approval before changing records or receipts")
    func undoValidatesApprovals() throws {
        for scenario in ["stale receipt", "invalid", "empty", "wrong operation", "consumed", "stopped scheduler", "pending recovery"] {
            let h = try taskFamilyFixture(), (from, to) = try h.selection()
            let moved = try executeMove([from], to, h.paths, ["processes": []])
            let mock = taskHarness(), io = mock.io
            let planned = scenario == "wrong operation" ? try executeMove(nil, nil, h.paths, ["io": io]) : try undo(h.paths, ["io": io])
            ok(planned.plan, scenario)
            eq(planned.plan.receiptFile, scenario == "wrong operation" ? nil : moved.file)
            if scenario == "consumed" { ok(try undo(h.paths, ["io": io, "approve": planned.plan.token]).dest) }
            if ["stale receipt", "consumed"].contains(scenario) {
                let sid = id(798)
                try h.write(sid, branchEntries(1, sid, 600))
                try h.record("Q", sid, rehomeRecord())
                let all = try accounts(h.paths, [])
                eq(try executeMove([all.find { $0.account.str == h.acct.Q }], all.find { $0.account.str == h.acct.T }, h.paths, ["processes": []]).ok, true)
            }
            if scenario == "pending recovery" {
                let receipt = try readJSON(moved.file.str)
                receipt.finalizing = true
                try writeJSON(moved.file.str, receipt)
            }
            if scenario == "stopped scheduler" { mock.rows = [] }
            mock.calls = []
            let before = try fixtureSnapshot(h)
            let approve: Value = scenario == "empty" ? "" : scenario == "invalid" || scenario == "pending recovery" ? Value(String(repeating: "0", count: 64)) : planned.plan.token
            let refused = try undo(h.paths, ["io": io, "approve": approve])
            eq(refused.ok, false, scenario)
            match(refused.reason, "approval|receipt changed|Open Claude sessions changed")
            deq(try fixtureSnapshot(h), before, scenario)
            eq(mock.calls.contains { $0.hasSuffix("osascript") }, false, scenario)
        }
    }

    @Test("task checkpoint integrity keeps interrupted Undo scoped to the whole receipt")
    func checkpointUndoScope() throws {
        let h = try taskCheckpointFixture(), all = try accounts(h.paths, [])
        let moved = try executeMove([all.find { $0.account.str == h.acct.P }], all.find { $0.account.str == h.acct.T }, h.paths, ["processes": []])
        eq(moved.ok, true)
        eq(moved.receipt.taskTransfers.length, 2)
        try interruptTaskFamily(h, "undo", "target")
        let receipt = try readJSON(moved.file.str)
        ok(receipt.undoing)
        receipt.appendCheckpoint = ["sessions": 1, "superseded": 1, "taskTransfers": 1, "held": []]
        try writeJSON(moved.file.str, receipt)
        ok(try finishWorkflow(h.paths, ["processes": []]).dest)
        deq(try readJSON(h.sourceFile), h.sourceRegistry)
        #expect(try h.sessions.map { try readData(h.recordFile("P", $0)) } == h.originalRecords)
        ok(!exists(h.targetFile))
        deq(.strings(try readdir(h.dir("T"))), [])
    }

    @Test("task families preserve registration state, generated records and registry fields through Undo")
    func taskFamiliesPreserveState() throws {
        for enabled in [false, true] {
            let h = try taskFamilyFixture(enabled), (from, to) = try h.selection()
            let prompts = try h.tasks.elements.map { try readData($0.filePath.str) }
            let inv = try inventory([from], to, h.paths, NOOP, ["processes": []])
            eq(inv.move.length, 4)
            let moved = try executeMove([from], to, h.paths, ["processes": []])
            eq(moved.ok, true)
            eq(moved.receipt.sessions.length, 4)
            deq(try readJSON(h.sourceFile), h.sourceAfter)
            deq(try readJSON(h.targetFile), h.targetAfter)
            #expect(try h.tasks.elements.map { try readData($0.filePath.str) } == prompts)
            deq(moved.receipt.taskTransfers[0].state, [
                "recordedSkips": ["task_0": h.sourceRegistry.recordedSkips.task_0, "task_1": h.sourceRegistry.recordedSkips.task_1],
                "runRetries": ["task_0": h.sourceRegistry.runRetries.task_0],
            ])
            for sid in [SOURCE, h.run, h.second] {
                let record = try readJSON(h.recordFile("T", sid))
                eq(record.cliSessionId, Value(sid))
                eq(record.sessionId, Value("local_\(sid)"))
                if sid != SOURCE { eq(record.notifySessionId, Value("local_\(SOURCE)")) }
            }
            if !enabled {
                let legacy = moved.receipt.deepClone()
                for family in legacy.taskTransfers.elements { family.removeKey("replaced") }
                try writeJSON(moved.file.str, legacy)
            }
            let undone = try undo(h.paths, ["processes": []])
            ok(undone.dest)
            deq(try readJSON(h.sourceFile), h.sourceRegistry)
            deq(try readJSON(h.targetFile), h.targetRegistry)
            #expect(try h.tasks.elements.map { try readData($0.filePath.str) } == prompts)
            for sid in [SOURCE, h.run, h.second, h.cold] { ok(exists(h.recordFile("P", sid))) }
        }
    }

    @Test("task family preflight errors cannot modify an earlier completed receipt")
    func preflightErrorsKeepEarlierReceipt() throws {
        let h = try taskFamilyFixture(), (from, to) = try h.selection()
        let ordinary = Value.spread(from, ["sessions": from.sessions.filter { $0.id.str == h.cold }])
        let first = try executeMove([ordinary], to, h.paths, ["processes": []])
        let before = try readData(first.file.str)
        let fresh = try h.selection()
        let inv = try inventory([fresh.from], fresh.to, h.paths, NOOP, ["processes": []])
        h.sourceRegistry.scheduledTasks[0].notifySessionId = Value("local_\(h.cold)")
        try writeJSON(h.sourceFile, h.sourceRegistry)
        let result = try move(inv, fresh.to, h.paths)
        eq(result.ok, false)
        ne(result.file, first.file)
        #expect(try readData(first.file.str) == before)
        eq(result.receipt.sessions.length, 0)
        eq(result.added ?? 0, 0)
        eq(result.targetChanged ?? false, false)
        match(Value(result.receipt.failed.elements.map { $0.error.str }.joined(separator: " ")), "changed since inventory|family member missing")
    }

    @Test("task Undo preserves identical pre-existing selected destination state")
    func identicalDestinationState() throws {
        let h = try taskFamilyFixture(), (from, to) = try h.selection()
        let target = Value.spread(h.targetRegistry, ["recordedSkips": .spread(h.targetRegistry.recordedSkips, ["task_0": h.sourceRegistry.recordedSkips.task_0])])
        try writeJSON(h.targetFile, target)
        let moved = try executeMove([from], to, h.paths, ["processes": []])
        eq(moved.ok, true)
        ok(try undo(h.paths, ["processes": []]).dest)
        deq(try readJSON(h.targetFile), target)
        deq(try readJSON(h.sourceFile), h.sourceRegistry)
    }

    @Test("task registry and record interruptions recover moves and Undo in the existing receipt")
    func registryAndRecordInterruptions() throws {
        for twins in [false, true] {
            for (operation, stage) in [("move", "source"), ("move", "record"), ("move", "target"), ("move", "receipt"), ("undo", "target"), ("undo", "source")] {
                let label = "\(twins)/\(operation)/\(stage)"
                let h = try taskFamilyFixture(true, 2, 1, twins), (from, to) = try h.selection()
                if operation == "undo" { _ = try executeMove([from], to, h.paths, ["processes": []]) }
                if stage == "receipt" && !twins { try unlink(h.targetFile) }
                try interruptTaskFamily(h, operation, stage)
                if operation == "undo" {
                    let pending = lines(cli(h.root, ["accounts", "--json"]).stdout)[0].filter { $0.pending.truthy }
                    deq(pending.map { [$0.pending, $0.pendingAction] }, [["undo", "finish"]], label)
                }
                let files = receiptFiles(h)
                eq(files.count, 1, label)
                let file = files[0], interrupted = try readJSON(file)
                if stage == "receipt" && !twins {
                    eq(interrupted.finalizing, true)
                    eq(interrupted.taskTransfers.length, 1)
                    eq(interrupted.taskTransfers[0].targetExisted, false)
                    throwsError(where: ["code": "ENOENT"]) { try NodeFS.nativeReadFile(h.targetFile) }
                    deq(try readJSON(h.sourceFile), h.sourceRegistry)
                }
                let result = try finishWorkflow(h.paths, ["processes": []])
                if operation == "undo" { ok(result.dest, label) }
                else {
                    eq(result.recoveryRequired, true, label)
                    #expect(receiptFiles(h) == files)
                    let receipt = try readJSON(file)
                    eq(receipt.finalizing, false)
                    deq(receipt.sessions.map { $0.id }, [Value(h.cold)], label)
                    deq(receipt.taskTransfers, [])
                }
                deq(try readJSON(h.sourceFile), h.sourceRegistry, label)
                deq(exists(h.targetFile) ? try readJSON(h.targetFile) : .null, stage == "receipt" && !twins ? .null : h.targetRegistry, label)
                for sid in [SOURCE, h.run, h.second] {
                    ok(exists(h.recordFile("P", sid)), label)
                    ok(!exists(h.recordFile("T", sid)), label)
                }
                if operation == "move" { ok(try undo(h.paths, ["processes": []]).dest, label) }
            }
        }
    }

    @Test("task edits and dependencies block Undo and interrupted recovery without overwriting registries")
    func taskEditsBlockUndo() throws {
        for recovery in [false, true] {
            for change in ["task", "dependency", "skip", "retry", "skip removed", "retry removed", "retry added", "source skip", "source retry"] {
                let label = "\(recovery)/\(change)"
                let h = try taskFamilyFixture(), (from, to) = try h.selection()
                if recovery { try interruptTaskFamily(h, "move", "target") }
                else { _ = try executeMove([from], to, h.paths, ["processes": []]) }
                let source = change.hasPrefix("source"), file = source ? h.sourceFile : h.targetFile
                let before = try readData(file), target = try readData(h.targetFile), changed = try JSON.parse(before)
                switch change {
                case "task": changed.scheduledTasks.find { $0.id == h.tasks[0].id }.enabled = true
                case "dependency": changed.scheduledTasks.push(["id": "new_task", "notifySessionId": Value("local_\(SOURCE)"), "enabled": false])
                case "skip": changed.recordedSkips.task_0[0].reason = "edited"
                case "retry": changed.runRetries.task_0.attempts = Value(changed.runRetries.task_0.attempts.asNumber! + 1)
                case "skip removed": changed.recordedSkips.removeKey("task_0")
                case "retry removed": changed.runRetries.removeKey("task_0")
                case "retry added": changed.runRetries.task_1 = ["slot": "2026-09-05T00:00:00Z", "attempts": 1, "notBefore": "2026-09-05T00:00:00Z"]
                case "source skip": changed.recordedSkips.task_0 = [["at": "2026-09-09T00:00:00Z", "reason": "missed"]]
                default: changed.runRetries.task_0 = ["slot": "2026-09-09T00:00:00Z", "attempts": 1, "notBefore": "2026-09-09T00:05:00Z"]
                }
                try writeJSON(file, changed)
                let result = recovery ? try finishWorkflow(h.paths, ["processes": []]) : try undo(h.paths, ["processes": []])
                let problems = result.reconciled.problems.nullish ? (result.restoreProblems.nullish ? result.changed : result.restoreProblems) : result.reconciled.problems
                match(Value(problems.join(" ")), source ? "scheduled task state changed" : "scheduled task")
                deq(try readJSON(file), changed, label)
                if source { #expect(try readData(h.targetFile) == target, "\(label)") }
                ok(exists(h.recordFile("T", SOURCE)), label)
                try writeData(file, before)
                let retried = recovery ? try finishWorkflow(h.paths, ["processes": []]) : try undo(h.paths, ["processes": []])
                ok(recovery ? retried.recoveryRequired : retried.dest, label)
                deq(try readJSON(h.sourceFile), h.sourceRegistry, label)
            }
        }
    }

    @Test("a saved 4.1.6 capacity-blocked receipt and bound plan remain finishable")
    func capacityBlockedReceipt() throws {
        let h = try taskFamilyFixture(), (from, to) = try h.selection(), mock = taskHarness()
        let partial = try executeMove([from], to, h.paths, ["io": mock.io, "moveOnly": true])
        eq(partial.receipt.sessions.length, 1)
        let planned = try finishWorkflow(h.paths, ["io": mock.io])
        let saved = Value.spread(planned.plan, ["capacity": ["records": 226, "recordBytes": 20798433, "availableMs": 22000, "estimatedMs": 90000, "fits": false, "code": "RESTART_CAPACITY"]])
        saved.removeKey("token")
        saved.token = Value(sha(stable(saved)))
        try writeJSON(path.join(h.paths.state.str, "restart-plan.json"), saved)
        let finished = try finishWorkflow(h.paths, ["io": mock.io, "approve": saved.token])
        eq(finished.ok, true, finished.reason.description)
        eq(finished.file, partial.file)
        eq(finished.receipt.sessions.length, 4)
        #expect(mock.calls == ["/usr/bin/osascript", "/usr/bin/open"])
        ok(try undo(h.paths, ["processes": []]).dest)
    }

    @Test("publication recovery retries once and cleans failed ordinary or task units before continuing")
    func publicationRecovery() throws {
        for family in [false, true] {
            for transient in [true, false] {
                for resume in [false, true] {
                    let label = "family \(family) transient \(transient) resume \(resume)"
                    let tf: TaskFamily? = family ? try taskFamilyFixture() : nil
                    let h: Home = try tf ?? home()
                    let other = id(710), healthy = id(711)
                    let ids = tf.map { [SOURCE, $0.run, $0.second, $0.cold, other, healthy] } ?? [SOURCE, other, healthy]
                    for (index, sid) in (family ? [other, healthy] : ids).enumerated() {
                        try h.write(sid, [entry("user", 810 + index, nil, sid)])
                        try h.record("P", sid, rehomeRecord(family ? ["scheduledTaskId": Value("independent_\(index)")] : [:]))
                    }
                    if let tf {
                        tf.sourceRegistry.scheduledTasks = tf.tasks.concat([["id": "independent_0", "enabled": true], ["id": "independent_1", "enabled": true]])
                        try writeJSON(tf.sourceFile, tf.sourceRegistry)
                    }
                    try h.record("P", id(799), rehomeRecord())
                    let mock = taskHarness(family ? [desktopFixture()[0]] : desktopFixture())
                    if !family { mock.rows[1].ids = .strings(ids) }
                    let all = try accounts(h.paths, []), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
                    let before = try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str])
                    let first: Value = resume ? try executeMove([from], to, h.paths, ["io": mock.io, "moveOnly": true]) : nil
                    let run = { (options: Value) throws -> Value in resume ? try finishWorkflow(h.paths, options) : try executeMove([from], to, h.paths, options) }
                    let planned = try run(["io": mock.io])
                    var reports: [Value] = [], attempts: [String: Int] = [:], order: [String] = []
                    let failedIds = [tf?.run ?? SOURCE, other]
                    let link = fs.link
                    fs.link = { a, b in
                        if path.dirname(b) == h.dir("T") {
                            let name = path.basename(b), sid = String(name.dropFirst(6).dropLast(5)), count = (attempts[sid] ?? 0) + 1
                            if attempts[sid] == nil { order.append(sid) }
                            attempts[sid] = count
                            if sid == failedIds[0] && (!transient || count == 1) || !transient && sid == other { throw JSError("Synthetic publication failure \(sid)") }
                        }
                        try link(a, b)
                    }
                    let result = try run(["io": mock.io, "approve": planned.plan.token, "report": fn { args in reports.append(.spread(["stage": Engine.Receipts.arg(args, 0)], Engine.Receipts.arg(args, 2))); return .undefined }])
                    fs = NodeFS()
                    eq(result.recoveryRequired, .undefined, "\(label) \(result.reason)")
                    eq(result.ok, Value(transient), "\(label) \(JSON.text(result.summary))")
                    eq(result.complete, Value(transient), label)
                    eq(attempts[failedIds[0]], 2, label)
                    eq(attempts[other], transient && !family ? 1 : 2, label)
                    eq(reports.filter { $0.stage == "recovery" }.count, 1, label)
                    eq(result.receipt.finalizing, false)
                    eq(result.receipt.pending, nil)
                    eq(result.receipt.held.length, 0)
                    ok(!exists("\(result.file.str).journal"), label)
                    let unmoved: [String] = transient ? [] : tf.map { [SOURCE, $0.run, $0.second, other] } ?? [SOURCE, other]
                    deq(result.receipt.sessions.map { $0.id }.sorted(), .strings(ids.filter { !unmoved.contains($0) }.sorted(by: utf16Less)), label)
                    deq(result.summary.notMoved.map { $0.id }.sorted(), .strings(unmoved.sorted(by: utf16Less)), label)
                    if transient { deq(result.receipt.failed, [], label); ok(!result.receipt.localStopped.truthy, label) }
                    let counts = reports.filter { $0.stage == "sessions" }
                    let total = ids.count - (resume && family ? 1 : 0)
                    eq(planned.plan.remainingCount, Value(total), label)
                    ok(!counts.isEmpty && counts.allSatisfy { $0.sessionTotal == Value(total) }, JSON.text(Value(counts)))
                    eq(counts.last?.remainingCount ?? .undefined, Value(result.summary.notMoved.length), label)
                    #expect(mock.calls == ["/usr/bin/osascript", "/usr/bin/open"], "\(label)")
                    if resume { eq(result.file, first.file, label) }
                    if !transient {
                        let snapshot = try fixtureSnapshot(h), published = attempts
                        for _ in 0..<2 {
                            let output = cli(h.root, ["accounts", "--json"]) { processSetup(list: "", commands: "") }
                            let rows = lines(output.stdout)[0].filter { $0.pending.truthy }
                            deq(rows.map { [$0.account, $0.pending, $0.pendingCount, $0.pendingAction] }, [[Value(h.acct.P), "partial", Value(unmoved.count), "blocked"]], label)
                            let pending = try finishWorkflow(h.paths, ["processes": []])
                            eq(pending.summary.notMoved.length, unmoved.count, label)
                            deq(try fixtureSnapshot(h), snapshot, label)
                        }
                        #expect(attempts == published)
                        let kept = try keepLocal(h.paths)
                        eq(kept.ok, true, label)
                        eq(kept.complete, true, label)
                        eq(kept.summary.notMoved.length, unmoved.count, label)
                    }
                    ok(try undo(h.paths, ["processes": []]).dest, label)
                    let after = try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str])
                    if let tf {
                        for file in [tf.sourceFile, tf.targetFile] { before.removeKey(file); after.removeKey(file) }
                        deq(try readJSON(tf.sourceFile), tf.sourceRegistry, label)
                        deq(try readJSON(tf.targetFile), tf.targetRegistry, label)
                    }
                    deq(after, before, label)
                }
            }
        }
    }

    @Test("retirement recovery unwinds unfinished copies and isolates the exact dependency unit")
    func retirementRecoveryUnwinds() throws {
        for shape in ["ordinary", "parent", "task", "boundary"] {
            for resume in [false, true] {
                for transient in shape == "boundary" ? [true] : [true, false] {
                    let label = "\(shape)/\(resume)/\(transient)"
                    let family = shape == "task" || shape == "boundary"
                    let tf: TaskFamily? = family ? try taskFamilyFixture() : nil
                    let h: Home = try tf ?? home()
                    let other = id(710), child = id(711), cold = id(720)
                    let failed: String? = shape == "task" ? tf!.run : shape == "boundary" ? nil : other
                    var ids: [String]
                    if let tf {
                        try h.write(other, [entry("user", 810, nil, other)])
                        try h.record("P", other, rehomeRecord(shape == "task" ? ["scheduledTaskId": "independent"] : [:]))
                        if shape == "task" {
                            tf.sourceRegistry.scheduledTasks = tf.tasks.concat([["id": "independent", "enabled": true]])
                            try writeJSON(tf.sourceFile, tf.sourceRegistry)
                        }
                        ids = [SOURCE, tf.run, tf.second, tf.cold, other]
                    } else {
                        ids = [SOURCE, other] + (shape == "parent" ? [child] : []) + (resume ? [cold] : [])
                        for (index, sid) in ids.enumerated() {
                            try h.write(sid, [entry("user", 810 + index, nil, sid)])
                            try h.record("P", sid, rehomeRecord(sid == child ? ["forkedFromSessionId": Value("local_\(other)")] : [:]))
                        }
                    }
                    let mock = taskHarness(shape == "task" ? [desktopFixture()[0]] : desktopFixture(other))
                    if !family { mock.rows[1].ids = .strings(ids.filter { $0 != cold }) }
                    let all = try accounts(h.paths, []), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
                    let before = try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str])
                    let seed: Value = resume ? try executeMove([from], to, h.paths, ["io": mock.io, "moveOnly": true]) : nil
                    let run = { (options: Value) throws -> Value in resume ? try finishWorkflow(h.paths, options) : try executeMove([from], to, h.paths, options) }
                    let planned = try run(["io": mock.io])
                    var reports: [Value] = [], refusals = 0, stalled = false
                    let inspect = mock.io.inspect
                    mock.io.inspect = fn { _ in
                        if shape == "boundary" && !stalled && reports.last?.stage == "sessions" && reports.contains(where: { $0.stage == "move" && $0.completed.truthy && !$0.preparatory.truthy }) {
                            stalled = true
                            mock.time += 61_000
                        }
                        return try inspect.call()
                    }
                    let rename = fs.rename
                    fs.rename = { a, b in
                        if let failed, a == h.recordFile("P", failed) {
                            refusals += 1
                            if refusals == 1 || !transient { throw JSError("Synthetic retirement refusal \(failed)") }
                        }
                        try rename(a, b)
                    }
                    let result = try run(["io": mock.io, "approve": planned.plan.token, "report": fn { args in reports.append(.spread(["stage": Engine.Receipts.arg(args, 0)], Engine.Receipts.arg(args, 2))); return .undefined }])
                    fs = NodeFS()
                    eq(result.recoveryRequired, .undefined, "\(label) \(result.reason)")
                    eq(result.ok, Value(transient), "\(label) \(JSON.text(result.summary))")
                    eq(result.complete, Value(transient), label)
                    #expect(refusals == (shape == "boundary" ? 0 : 2), "\(label)")
                    #expect(stalled == (shape == "boundary"), "\(label)")
                    eq(reports.filter { $0.stage == "recovery" }.count, 1, label)
                    let notMoved: [String] = transient ? [] : shape == "task" ? [SOURCE, tf!.run, tf!.second] : shape == "parent" ? [other, child] : [other]
                    eq(result.summary.moved, Value(ids.count - notMoved.count), label)
                    deq(result.summary.notMoved.map { $0.id }.sorted(), .strings(notMoved.sorted(by: utf16Less)), label)
                    deq(result.receipt.sessions.map { $0.id }.sorted(), .strings(ids.filter { !notMoved.contains($0) }.sorted(by: utf16Less)), label)
                    eq(result.receipt.finalizing, false)
                    eq(result.receipt.retiring, nil)
                    eq(result.receipt.held.length, 0)
                    if resume { eq(result.file, seed.file, label) }
                    for sid in ids {
                        eq(exists(h.recordFile("P", sid)), notMoved.contains(sid), "\(label)/\(sid)")
                        eq(exists(h.recordFile("T", sid)), !notMoved.contains(sid), "\(label)/\(sid)")
                    }
                    eq(reports.filter { $0.stage == "sessions" }.last?.remainingCount ?? .undefined, Value(notMoved.count), label)
                    #expect(mock.calls == ["/usr/bin/osascript", "/usr/bin/open"], "\(label)")
                    if !transient { eq(try keepLocal(h.paths).complete, true, label) }
                    ok(try undo(h.paths, ["processes": []]).dest, label)
                    let after = try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str])
                    if let tf {
                        for file in [tf.sourceFile, tf.targetFile] { before.removeKey(file); after.removeKey(file) }
                        deq(try readJSON(tf.sourceFile), tf.sourceRegistry, label)
                        deq(try readJSON(tf.targetFile), tf.targetRegistry, label)
                    }
                    deq(after, before, label)
                }
            }
        }
    }

    @Test("failed retirement restoration retains its journal and cannot continue independent writes")
    func failedRetirementRestoration() throws {
        let h = try home(), other = id(710), mock = taskHarness(desktopFixture())
        mock.rows[1].ids = [Value(SOURCE), Value(other)]
        for (index, sid) in [SOURCE, other].enumerated() {
            try h.write(sid, [entry("user", 810 + index, nil, sid)])
            try h.record("P", sid, rehomeRecord())
        }
        let all = try accounts(h.paths, []), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
        let planned = try executeMove([from], to, h.paths, ["io": mock.io]), source = h.recordFile("P", other)
        var attempts = 0
        let rename = fs.rename
        fs.rename = { a, b in
            if a == source { attempts += 1; try rename(a, b); throw JSError("Synthetic retirement failure") }
            if b == source { throw JSError("Synthetic restore failure") }
            try rename(a, b)
        }
        let result = try executeMove([from], to, h.paths, ["io": mock.io, "approve": planned.plan.token])
        fs = NodeFS()
        eq(attempts, 1)
        eq(result.code, "LOCAL_RECOVERY_BLOCKED")
        match(result.reason, "restore failure")
        let receipt = try readReceipt(result.file)
        ok(receipt.retiring.truthy && receipt.finalizing.truthy && receipt.localRecovery.blocked.truthy)
        eq(result.summary.moved, 0)
        eq(try keepLocal(h.paths).recoveryRequired, true)
        eq(try sweep(h.paths, ["processes": []]).ok, false)
        _ = try finishWorkflow(h.paths, ["processes": []])
        let recovered = try readReceipt(result.file)
        eq(recovered.sessions.length, 0)
        eq(recovered.finalizing, false)
        eq(try readdir(h.dir("T")).count, 0)
        eq(try readdir(h.dir("P")).count, 2)
    }
}
