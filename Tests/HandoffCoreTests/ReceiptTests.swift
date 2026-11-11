import Foundation
import Testing
@testable import HandoffCore

extension Engine {
    @Suite("receipts and recovery")
    struct Receipts {
        // A callback argument, undefined when the engine passed fewer.
        static func arg(_ args: [Value], _ i: Int) -> Value { i < args.count ? args[i] : .undefined }

        // accounts() rows keyed by account uuid.
        static func byAccount(_ h: Home) throws -> [String: Value] {
            var out: [String: Value] = [:]
            for row in try accounts(h.paths).elements { out[row.account.str] = row }
            return out
        }

        // Runs `action` just before the engine's second read or open of `file`.
        static func duringSecondRead(_ file: String, _ action: @escaping () throws -> Void) -> Box<Bool> {
            let ran = Box(false), readFile = fs.readFile, open = fs.open
            var reads = 0
            let next = {
                reads += 1
                if reads == 2 { ran.value = true; try action() }
            }
            fs.readFile = { p in if p == file { try next() }; return try readFile(p) }
            fs.open = { p, flags, mode in if p == file { try next() }; return try open(p, flags, mode) }
            return ran
        }

        // Two cold P sessions moving to T.
        static func unwindFixture() throws -> (h: Home, from: Value, to: Value) {
            let h = try home(), sessions = [SOURCE, id(720)]
            for (index, sid) in sessions.enumerated() {
                try h.write(sid, [entry("user", 820 + index, nil, sid)])
                try h.record("P", sid, rehomeRecord())
            }
            let all = try accounts(h.paths, [])
            return (h, all.find { $0.account.str == h.acct.P }, all.find { $0.account.str == h.acct.T })
        }

        // After each record the engine links into `dir`, rewrite it with `change(count)` merged in.
        static func placedRecords(_ dir: String, _ change: @escaping (Int) -> Value) -> Box<[String]> {
            let placed = Box<[String]>([]), link = fs.link
            fs.link = { a, b in
                try link(a, b)
                if path.dirname(b) == dir {
                    placed.value.append(path.basename(b))
                    try writeJSON(b, .spread(try readJSON(b), change(placed.value.count)))
                }
            }
            return placed
        }

        static func localRecords(_ dir: String) -> Value {
            .strings(readdirOrEmpty(dir).filter { $0.hasPrefix("local_") }.sorted(by: utf16Less))
        }

        @Test("independent destination arrivals preserve Undo for successfully moved siblings")
        func independentArrivals() throws {
            for identical in [false, true] {
                let h = try home(), sibling = id(300)
                for session in [SOURCE, sibling] {
                    try h.write(session, [entry("user", session == SOURCE ? 1 : 300, nil, session)])
                    try h.record("P", session)
                }
                let from = try h.account("P"), to = try h.account("T")
                let target = h.recordFile("T", SOURCE)
                let record = try readJSON(h.recordFile("P", SOURCE))
                let foreign = identical ? JSON.text(record, space: 2) + "\n" : "{\"title\":\"foreign sibling\"}\n"
                let result = try executeMove([from], to, h.paths, ["processes": [], "summary": fn { () in try writeText(target, foreign) }])
                eq(result.ok, Value(identical))
                eq(result.receipt.sessions.length, 1)
                eq(readOrNil(target), Value(foreign))
                eq(result.receipt.retained, .undefined)
                ok(try undo(h.paths).dest)
                eq(readOrNil(target), Value(foreign))
                ok(exists(h.recordFile("P", sibling)))
            }
        }

        @Test("an interrupted 4.1.6 continuation recovers while an older interrupted receipt is left to its own version")
        func interruptedContinuation() throws {
            for writer in ["4.1.6", "older"] {
                let h = try home()
                let cold = id(300)
                try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
                try h.write(cold, [entry("user", 300, nil, cold)])
                try h.record("P", SOURCE)
                try h.record("P", cold)
                let from = try h.account("P"), to = try h.account("T")
                let first = try executeMove([from], to, h.paths, ["processes": desktopFixture(), "moveOnly": true])
                eq(first.receipt.writer, Value(VERSION))
                throwsError("interrupted append") {
                    try finishHeld(h.paths, ["processes": [], "report": fn { args in
                        if Engine.Receipts.arg(args, 0) == "retire" && Engine.Receipts.arg(args, 1) == "checking" { throw JSError("interrupted append") }
                        return .undefined
                    }])
                }
                let interrupted = try readJSON(first.file.str)
                eq(interrupted.appendCheckpoint.taskTransfers, 0)
                interrupted.removeKey("writer")
                if writer == "older" { interrupted.appendCheckpoint.removeKey("taskTransfers"); interrupted.removeKey("taskTransfers") }
                try writeJSON(first.file.str, interrupted)
                if writer == "older" {
                    let before = try fixtureSnapshot(h), line = "An older version started this move and must finish it"
                    for command in ["finish", "undo", "sweep", "keep-local"] {
                        let output = cli(h.root, [command, "--json"])
                        eq(output.code, 1, command)
                        eq(lines(output.stdout).at(-1).reason, Value(line), command)
                    }
                    eq(cli(h.root, ["finish"]).stderr, "claude-handoff: \(line)\n")
                    ok(try JSON.parse(cli(h.root, ["accounts", "--json"]).stdout).every { $0.recoveryProblem.error.str == line && $0.recoveryProblem.code == "OLDER_MOVE" })
                    deq(try fixtureSnapshot(h), before)
                    continue
                }
                let recovered = try undo(h.paths)
                ok(recovered.reconciled)
                let receipt = try readJSON(first.file.str)
                eq(receipt.sessions.length, 1)
                eq(receipt.sessions[0].id, Value(cold))
                eq(receipt.held.length, 1)
                ok(exists(h.recordFile("T", cold)))
                ok(exists(h.recordFile("P", SOURCE)))
                eq(readOrNil(h.recordFile("T", SOURCE)), nil)
                let retry = try finishHeld(h.paths, ["processes": []])
                eq(retry.ok, true)
                deq(retry.receipt.failed, [])
                ok(try undo(h.paths).dest)
            }
        }

        @Test("replay metadata preserves complete copies, content checks and existing receipt hashes")
        func replayMetadata() throws {
            let parent = entry("user", 1, nil, SOURCE)
            let richMessage: Value = ["role": "assistant", "content": "same response", "usage": ["input_tokens": 2, "output_tokens": 42, "cache_read_input_tokens": 100]]
            let rich = entry("assistant", 2, 1, SOURCE, ["message": richMessage, "origin": ["kind": "local", "producer": "desktop"], "toolUseResult": ["originalFile": "full file"]])
            let poorMessage = Value.spread(rich.message, ["usage": ["input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 0]])
            let poor = Value.spread(rich, ["message": poorMessage, "origin": ["kind": "local"], "toolUseResult": ["originalFile": ""]])
            let snapshots = ["9b73e0209da9afbaf4cdc9db54bfe2e80481455c906e278b3a1931e81cc45b33", "13f7544b251996252fcac3d0954cf42e25cecb13c55eafadd51504f2c68f0692"]
            for (index, copies) in [[rich, poor], [poor, rich]].enumerated() {
                let rows = Value([parent] + copies), before = rows.deepClone(), result = try normalize(rows)
                eq(result.conflicts, 0)
                eq(result.entries[1], rich)
                eq(try semantic(rows, Value(SOURCE)), Value(snapshots[index]))
                deq(rows, before)
            }
            let origins: [Value] = [["kind": "local"], ["kind": "local", "producer": nil], ["kind": "local", "producer": ""]]
            for origin in origins {
                let replay = Value.spread(rich, ["origin": origin])
                for copies in [[rich, replay], [replay, rich]] { eq(try normalize(Value([parent] + copies)).entries[1], rich) }
            }
            for origin in [Value.undefined, Value.newObject()] {
                let full = Value.spread(rich, ["origin": ["producer": "desktop"]]), replay = Value.spread(full, ["origin": origin])
                eq(try normalize([parent, replay, full]).entries[1], full)
            }
            let changes: [Value] = [
                .spread(poor, ["origin": ["kind": "local", "producer": "other"]]),
                .spread(poor, ["origin": ["kind": "remote"]]),
                .spread(poor, ["message": .spread(poor.message, ["content": "different response"])]),
                .spread(poor, ["message": .spread(poor.message, ["role": "user"])]),
                .spread(poor, ["toolUseResult": ["originalFile": "different file"]]),
                .spread(poor, ["parentUuid": Value(id(999))]),
                .spread(rich, ["message": .spread(rich.message, ["futureContent": "different"])]),
            ]
            for changed in changes {
                for copies in [[rich, changed], [changed, rich]] { eq(try normalize(Value([parent] + copies)).conflicts, 1) }
            }
            let producerOnly = Value.spread(rich, ["toolUseResult": poor.toolUseResult]), contentOnly = Value.spread(rich, ["origin": poor.origin])
            eq(try normalize([parent, producerOnly, contentOnly]).conflicts, 1)
        }

        @Test("fallback lock releases after an interrupted move so recovery can run")
        func fallbackLockReleases() throws {
            let h = try home()
            try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
            try h.record("P", SOURCE)
            let crashed = try crashing(on: .link, when: { _ in true }) {
                _ = cli(h.root, ["--from", "p@example.com", "--to", "z@example.com", "--json"])
            }
            ok(crashed)
            let recovered = cli(h.root, ["finish", "--json"])
            ok(lines(recovered.stdout).at(-1).reconciled, recovered.stderr)
            eq(try readdir(h.dir("P")).count, 1)
            eq(readOrNil(h.recordFile("Z", SOURCE)), nil)
            let moved = cli(h.root, ["--from", "p@example.com", "--to", "z@example.com", "--json"])
            eq(moved.code, 0, moved.stderr)
        }

        @Test("undo allows shared sidecar growth but refuses Desktop record changes")
        func sidecarGrowth() throws {
            let h = try home()
            try h.write(id(925), [entry("user", 925, nil, id(925))])
            try mkdirp(path.join(h.project, id(925), "subagents"))
            try writeText(path.join(h.project, id(925), "subagents", "before.jsonl"), "before\n")
            try h.record("P", id(925))
            let by = try Receipts.byAccount(h)
            let result = try move(try inventory([by[h.acct.P]!], by[h.acct.Z]!, h.paths), by[h.acct.Z]!, h.paths)
            let row = result.receipt.sessions[0]
            try writeText(path.join(row.targetDir.str, "subagents", "after.jsonl"), "after\n")
            let changedRecord = try readJSON(row.record.str)
            changedRecord.title = "changed after move"
            try writeJSON(row.record.str, changedRecord)
            let refused = try undo(h.paths)
            match(refused.changed[0], "desktop record changed")
            ok(exists(row.record.str))
        }

        @Test("undo allows harmless Desktop focus drift")
        func focusDrift() throws {
            let h = try home()
            try h.write(id(928), [entry("user", 928, nil, id(928))])
            try h.record("P", id(928))
            let by = try Receipts.byAccount(h)
            let result = try move(try inventory([by[h.acct.P]!], by[h.acct.Z]!, h.paths), by[h.acct.Z]!, h.paths)
            let row = result.receipt.sessions[0]
            let focused = try readJSON(row.record.str)
            focused.lastFocusedAt = Value(focused.lastFocusedAt.asNumber! + 1)
            try writeJSON(row.record.str, focused)
            ok(try undo(h.paths).dest)
        }

        @Test("a Desktop record changing inside the final guard stays visible and undoable")
        func changeInsideFinalGuard() throws {
            let h = try home()
            let session = id(936)
            let record = h.recordFile("P", session)
            let taskFile = path.join(h.dir("P"), "scheduled-tasks.json")
            let validTasks = JSON.text(["scheduledTasks": []])
            try h.write(session, [entry("user", 936, nil, session)])
            try h.record("P", session)
            try writeText(taskFile, validTasks)
            let by = try Receipts.byAccount(h)
            let inv = try inventory([by[h.acct.P]!], by[h.acct.Z]!, h.paths)
            let ran = Receipts.duringSecondRead(taskFile) {
                let current = try readJSON(record)
                try writeJSON(record, .spread(current, ["title": "changed inside final guard"]))
            }
            var reports: [Value] = []
            let result = try move(inv, by[h.acct.Z]!, h.paths, fn { args in reports.append(Engine.Receipts.arg(args, 0)); return .undefined })
            ok(ran.value, "the engine never read the task registry")
            ok(reports.contains("recovery"))
            eq(result.ok, true)
            eq(try readJSON(h.recordFile("Z", session)).title, "changed inside final guard")
            ok(try undo(h.paths).dest)
            eq(try readJSON(record).title, "changed inside final guard")
        }

        @Test("interrupted undo resumes from its journal")
        func interruptedUndoResumes() throws {
            let h = try home()
            try h.write(id(918), [entry("user", 918, nil, id(918))])
            try h.record("P", id(918))
            let by = try Receipts.byAccount(h)
            let result = try move(try inventory([by[h.acct.P]!], by[h.acct.Z]!, h.paths), by[h.acct.Z]!, h.paths)
            let receipt = try readJSON(result.file.str)
            let row = receipt.sessions[0]
            let dest = path.join(h.paths.state.str, "quarantine", receipt["at"].str)
            let items: Value = [row.record]
            receipt.undoing = [[
                "id": row.targetId,
                "title": row.title,
                "required": items,
                "hashes": [],
                "trees": [],
                "semantics": [[row.record, row.recordSemantic]],
                "moved": items.map { file in [file, Value(path.join(dest, path.basename(file.str)))] },
            ]]
            try writeJSON(result.file.str, receipt)
            let source = receipt.superseded.find { $0.source.truthy }.moved[0]
            try rename(source[1].str, source[0].str)
            try mkdirp(dest)
            try rename(row.record.str, path.join(dest, path.basename(row.record.str)))
            let resumed = try undo(h.paths)
            eq(resumed.dest, Value(dest))
            ok(exists(source[0].str))
            eq(readOrNil(row.record.str), nil)
            ok(exists(path.join(dest, path.basename(row.record.str))))
        }

        @Test("a corrupt latest receipt stops undo before the previous batch")
        func corruptLatestReceipt() throws {
            let h = try home()
            try h.write(id(905), [entry("user", 905, nil, id(905))])
            try h.record("P", id(905))
            let by = try Receipts.byAccount(h)
            let moved = try move(try inventory([by[h.acct.P]!], by[h.acct.Z]!, h.paths), by[h.acct.Z]!, h.paths)
            let target = moved.receipt.sessions[0].targetTranscript
            let corrupt = path.join(h.paths.state.str, "2099-12-31T23-59-59-999.json")
            try writeText(corrupt, "{broken")
            let result = try undo(h.paths)
            match(result.reconciled.error, "corrupt receipt")
            ok(exists(target.str))
            ok(exists("\(corrupt).corrupt"))
        }

        @Test("a changed interrupted copy stays tracked and blocks undo")
        func changedInterruptedCopy() throws {
            let h = try home()
            let targetId = id(899)
            let target = h.transcript(targetId)
            try h.write(targetId, [entry("user", 899, nil, targetId)])
            try mkdirp(h.paths.state)
            let pending: Value = ["strategy": "remote", "id": Value(id(898)), "title": "Changed", "targetId": Value(targetId), "made": [Value(target)],
                                  "targetSemantic": try semantic([entry("user", 898, nil, targetId)], Value(targetId)), "targetSemanticVersion": 3]
            let receipt: Value = ["at": "2099-01-01T00-00-00-000", "from": [], "to": "x", "sessions": [], "failed": [], "pending": pending]
            let file = path.join(h.paths.state.str, "\(receipt["at"].str).json")
            try writeJSON(file, receipt)
            ok(try undo(h.paths).reconciled)
            let recovered = try readJSON(file)
            eq(recovered.retained[0].targetId, Value(targetId))
            deq(recovered.retained[0].artifacts, [Value(target)])
            eq(try undo(h.paths).retained[0].targetId, Value(targetId))
            ok(exists(target))
        }

        @Test("dry-run describes interrupted retirement without changing it")
        func dryRunInterruptedRetirement() throws {
            let h = try home()
            try mkdirp(h.paths.state)
            let receipt: Value = ["at": "2099-01-01T00-00-00-000", "from": [], "to": "x", "sessions": [], "failed": [], "superseded": [], "finalizing": true,
                                  "retiring": [["id": "x", "title": "x", "by": "y", "moved": []]]]
            let file = path.join(h.paths.state.str, "\(receipt["at"].str).json")
            try writeJSON(file, receipt)
            let result = cli(h.root, ["--from", "p@example.com", "--to", "z@example.com", "--dry-run", "--json"])
            eq(result.code, 1)
            match(result.stdout, "interrupted retirement")
            eq(try JSON.parse(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last!).planned, nil)
            deq(try readJSON(file), receipt)
        }

        @Test("interrupted retirement restores partially parked entries")
        func partiallyParkedEntries() throws {
            let h = try home()
            let at = "2099-01-01T00-00-00-000"
            let original = path.join(h.project, "retired.json")
            let parked = path.join(h.paths.state.str, "quarantine", at, "sources", "retired.json")
            try writeText(original, "{}")
            try mkdirp(path.dirname(parked))
            try rename(original, parked)
            let receipt: Value = ["at": Value(at), "from": [], "to": "x", "sessions": [], "failed": [], "superseded": [], "finalizing": true,
                                  "retiring": [["id": "x", "title": "x", "by": "y", "required": [Value(original)], "moved": [[Value(original), Value(parked)]]]]]
            let file = path.join(h.paths.state.str, "\(at).json")
            try writeJSON(file, receipt)
            let result = try undo(h.paths)
            match(result.reconciled.error, "retirement rolled back")
            eq(readOrNil(original), "{}")
            eq(readOrNil(parked), nil)
            let recovered = try readJSON(file)
            eq(recovered.retiring, nil)
            eq(recovered.finalizing, false)
        }

        @Test("retirement recovery after a crash leaves exactly one record per session")
        func retirementRecoveryAfterCrash() throws {
            let h = try home()
            for (index, sid) in [SOURCE, id(710)].enumerated() {
                try h.write(sid, [entry("user", 810 + index, nil, sid)])
                try h.record("P", sid, rehomeRecord())
            }
            let all = try accounts(h.paths, []), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
            let moved = try executeMove([from], to, h.paths, ["processes": []]), receipt = moved.receipt
            receipt.finalizing = true
            receipt.retiring = receipt.superseded
            receipt.superseded = []
            try writeJSON(moved.file.str, receipt)
            let result = try finishWorkflow(h.paths, ["processes": []])
            eq(result.recoveryRequired, true)
            match(result.reconciled.error, "retirement rolled back")
            let recovered = try readReceipt(moved.file)
            eq(recovered.finalizing, false)
            eq(recovered.sessions.length, 0)
            eq(try readdir(h.dir("P")).count, 2)
            eq(try readdir(h.dir("T")).count, 0)
            let summary = try finishWorkflow(h.paths, ["processes": []]).summary
            deq([summary.moved, Value(summary.notMoved.length)], [0, 2])
        }

        @Test("a crash between two units' unwinds recovers to one record per session without ghost rows")
        func crashBetweenUnwinds() throws {
            let (h, from, to) = try Receipts.unwindFixture()
            _ = Receipts.placedRecords(h.dir("T")) { _ in ["lastFocusedAt": 1000] }
            var parked = 0
            let original = fs.rename
            fs.rename = { a, b in
                if path.dirname(a) == h.dir("T") && b.contains("/failed/") { parked += 1; if parked == 2 { throw JSError("simulated crash between unwinds") } }
                try original(a, b)
            }
            throwsError("simulated crash between unwinds") { try executeMove([from], to, h.paths, ["processes": []]) }
            fs = NodeFS()
            eq(parked, 2)
            let recovery = try finishWorkflow(h.paths, ["processes": []])
            eq(recovery.recoveryRequired, true)
            let receipt = try readReceipt(Value(receiptFiles(h)[0]))
            eq(receipt.finalizing, false)
            deq(receipt.sessions, [])
            ok(!receipt.failed.some { JSRegExp.cached("missing|changed since").test($0.error.str) }, JSON.text(receipt.failed))
            let sources = Value.strings([SOURCE, id(720)].map { "local_\($0).json" }.sorted(by: utf16Less))
            deq(Receipts.localRecords(h.dir("P")), sources)
            deq(Receipts.localRecords(h.dir("T")), [])
            ok(try undo(h.paths, ["processes": []]).dest)
            deq(Receipts.localRecords(h.dir("P")), sources)
            deq(Receipts.localRecords(h.dir("T")), [])
        }

        @Test("a changed copy in a later unit is kept with its failure while earlier units unwind")
        func changedLaterUnit() throws {
            let (h, from, to) = try Receipts.unwindFixture()
            let placed = Receipts.placedRecords(h.dir("T")) { count in count == 2 ? ["title": "Renamed in the destination"] : ["lastFocusedAt": 1000] }
            let result = try executeMove([from], to, h.paths, ["processes": []])
            fs = NodeFS()
            let first = placed.value[0], second = placed.value[1]
            ne(result.code, "LOCAL_RECOVERY_BLOCKED")
            eq(result.recoveryRequired, .undefined)
            deq(Receipts.localRecords(h.dir("T")), [Value(second)])
            deq(Receipts.localRecords(h.dir("P")), Value.strings([first, second].sorted(by: utf16Less)))
            deq(result.receipt.sessions.map { Value("local_\($0.id).json") }, [Value(second)])
            ok(result.receipt.failed.some { "local_\($0.id).json" == second && JSRegExp.cached("changed after placement").test($0.error.str) }, JSON.text(result.receipt.failed))
            ok(result.summary.notMoved.some { "local_\($0.id).json" == first })
            eq(Set(result.receipt.failed.elements.map { JSON.text($0) }).count, result.receipt.failed.length)
        }

        @Test("bridge review Undo preserves a newer pointer while retaining the Desktop record guard", arguments: [false, true])
        func bridgeReviewNewerPointer(recordChanged: Bool) throws {
            let h = try bridgeFixture(), transcript = h.transcriptPath
            let moved = try move(try inventory([h.from], h.to, h.paths, NOOP, ["processes": []]), h.to, h.paths)
            try appendText(transcript, "\(JSON.text(.spread(h.bridge, ["bridgeSessionId": "cse_newer", "ownerAccountUuid": h.to.account, "ownerOrganizationUuid": h.to.org])))\n")
            let record = moved.receipt.sessions[0].record.str
            if recordChanged { try writeJSON(record, .spread(try readJSON(record), ["bridgeSessionIds": ["session_newer"]])) }
            let before = try readData(transcript), desktop = try readData(record)
            let result = try undo(h.paths, ["processes": []])
            eq(result.dest.truthy, !recordChanged)
            eq(try readData(transcript), before)
            if recordChanged { eq(try readData(record), desktop) }
            else { deq(try readJSON(h.recordFile("P", SOURCE)).bridgeSessionIds, ["session_prior"]) }
        }

        @Test("bridge review Undo cannot discard a message arriving immediately before mutation")
        func bridgeReviewArrivingMessage() throws {
            let h = try bridgeFixture(), transcript = h.transcriptPath
            _ = try move(try inventory([h.from], h.to, h.paths, NOOP, ["processes": []]), h.to, h.paths)
            let before = try readData(transcript), write = fs.handleWrite
            var injected = false
            fs.handleWrite = { handle, data in
                if handle.path == transcript && !injected {
                    injected = true
                    try appendText(transcript, "\(JSON.text(entry("user", 3, 2, SOURCE)))\n")
                }
                try write(handle, data)
            }
            do { _ = try undo(h.paths, ["processes": []]) } catch { match(jsErrorValue(error).message, "bridge") }
            fs = NodeFS()
            let after = try readData(transcript)
            #expect(injected)
            ok(lines(String(decoding: after, as: UTF8.self)).some { $0.uuid.str == id(3) })
            #expect(after.prefix(before.count) == before)
        }

        @Test("a rehome clears the source bridge and Undo restores its original attachment")
        func rehomeClearsBridge() throws {
            let h = try home()
            let transcript = h.transcript(SOURCE)
            try h.write(SOURCE, [
                entry("user", 1, nil, SOURCE),
                entry("assistant", 2, 1, SOURCE),
                ["type": "bridge-session", "sessionId": Value(SOURCE), "bridgeSessionId": "cse_prior", "lastSequenceNum": 7, "ownerAccountUuid": Value(h.acct.P), "ownerOrganizationUuid": Value(h.org.P)],
            ])
            try h.record("P", SOURCE, rehomeRecord(["bridgeSessionIds": ["session_prior"]]))
            let targetDir = path.join(h.paths.records.str, h.acct.Z, h.org.Z)
            try mkdirp(targetDir)
            let before = try readData(transcript)
            let clearedBridge: Value = ["type": "bridge-session", "sessionId": Value(SOURCE), "bridgeSessionId": "", "lastSequenceNum": 0]
            let cleared = before + Data("\(JSON.text(clearedBridge))\n".utf8)
            func moveOnce() throws -> Value {
                let all = try accounts(h.paths)
                let from = all.find { $0.account.str == h.acct.P && $0.org.str == h.org.P }
                let to = all.find { $0.account.str == h.acct.Z && $0.org.str == h.org.Z }
                let inv = try inventory([from], to, h.paths)
                eq(inv.move[0].strategy, "rehome")
                return try move(inv, to, h.paths)
            }
            let first = try moveOnce()
            eq(first.ok, true)
            eq(try readData(transcript), cleared)
            deq(try readJSON(path.join(targetDir, "local_\(SOURCE).json")).bridgeSessionIds, [])
            ok(try undo(h.paths).dest)
            deq(.strings(try readdir(targetDir)), [])
            let restored = try readData(transcript)
            assertBridgeRestored(before, restored, lines(String(decoding: before, as: UTF8.self)).at(-1))
            eq(try moveOnce().ok, true)
            assertBridgeRestored(restored, try readData(transcript), clearedBridge)
        }

        @Test("a move to another account drops the source account error and Undo restores it")
        func dropsAccountError() throws {
            let h = try home()
            let saved: Value = ["error": "You've hit your weekly limit · resets Oct 31 at 8am", "errorAt": 1793385600000, "priorErrorMark": 1793385600000]
            try h.write(SOURCE, [entry("user", 1, nil, SOURCE), entry("assistant", 2, 1, SOURCE)])
            try h.record("P", SOURCE, rehomeRecord(saved))
            let source = h.recordFile("P", SOURCE), original = try readData(source)
            let from = try h.account("P"), to = try h.account("T")
            let moved = try move(try inventory([from], to, h.paths), to, h.paths)
            eq(moved.ok, true)
            let placed = try readJSON(h.recordFile("T", SOURCE))
            for key in saved.ownKeys { eq(placed.hasOwn(key), false, key) }
            eq(try readData(moved.receipt.superseded.find { $0.source.truthy }.moved[0][1].str), original)
            ok(try undo(h.paths).dest)
            eq(try readData(source), original)
            deq(.strings(try readdir(h.dir("T"))), [])
        }

        @Test("bridge append crash checkpoints recover through the placement receipt",
              arguments: ["intent", "partial", "synced", "applied", "settled", "synced with later messages", "ack failed with later messages", "unacknowledged newer bridge"])
        func bridgeAppendCheckpoints(checkpoint: String) throws {
            let h = try bridgeFixture(), transcript = h.transcriptPath, inv = try inventory([h.from], h.to, h.paths, NOOP, ["processes": []])
            var injected = false
            let synthetic = { jsThrow("Synthetic crash checkpoint", code: "JOURNAL_WRITE") }
            let write = fs.handleWrite, sync = fs.handleSync
            let watched = { (handle: HandoffCore.FileHandle) in handle.path.hasSuffix(".journal") || handle.path == transcript }
            fs.handleWrite = { handle, data in
                guard watched(handle) else { return try write(handle, data) }
                let patch: Value = handle.path.hasSuffix(".journal") ? try JSON.parse(data) : .null
                if checkpoint == "ack failed with later messages" && patch.pending.bridgeAppend.applied.truthy && !injected {
                    injected = true
                    throw synthetic()
                }
                let matches: Bool
                switch checkpoint {
                case "intent": matches = patch.pending.bridgeAppend.truthy && !patch.pending.bridgeAppend.applied.truthy
                case "applied": matches = patch.pending.bridgeAppend.applied.truthy
                case "settled": matches = patch.sessions.some { $0.bridgeAppend.truthy }
                default: matches = checkpoint == "partial" && handle.path == transcript
                }
                try write(handle, matches && checkpoint == "partial" ? data.prefix(25) : data)
                if matches && !injected { injected = true; throw synthetic() }
            }
            fs.handleSync = { handle in
                try sync(handle)
                if ["synced", "synced with later messages", "unacknowledged newer bridge"].contains(checkpoint) && handle.path == transcript && !injected {
                    injected = true
                    throw synthetic()
                }
            }
            throwsError("Synthetic crash checkpoint") { try move(inv, h.to, h.paths) }
            fs = NodeFS()
            #expect(injected)
            let receipt = try readReceipt(Value(receiptFiles(h)[0]))
            let plan = receipt.pending.bridgeAppend.nullish ? receipt.sessions[0].bridgeAppend : receipt.pending.bridgeAppend
            eq(plan["length"], Value(h.before.count))
            eq(plan.sha, Value(sha(h.before)))
            deq(plan.original, h.bridge)
            let later = checkpoint.hasSuffix("later messages") || checkpoint == "unacknowledged newer bridge"
            if later {
                eq(plan.applied, .undefined)
                eq(lines(try readText(transcript)).at(-1).bridgeSessionId, "")
                try appendText(transcript, "\(JSON.text(entry("user", 3, 2, SOURCE)))\n")
                if checkpoint == "unacknowledged newer bridge" {
                    try appendText(transcript, "\(JSON.text(.spread(h.bridge, ["bridgeSessionId": "cse_newer", "ownerAccountUuid": h.to.account, "ownerOrganizationUuid": h.to.org])))\n")
                }
            }
            let beforeRecovery = try readData(transcript)
            eq(try keepLocal(h.paths).recoveryRequired, true)
            let recovered = try undo(h.paths, ["processes": []])
            if checkpoint == "unacknowledged newer bridge" {
                match(recovered.reconciled.error, "transcript restoration witness changed")
                eq(try readData(transcript), beforeRecovery)
                ok(exists(h.recordFile("Z", SOURCE)))
                return
            }
            match(recovered.reconciled.error, "interrupted")
            let after = try readData(transcript)
            if later {
                #expect(after.prefix(beforeRecovery.count) == beforeRecovery)
                eq(lines(String(decoding: after, as: UTF8.self)).filter { MESSAGES.contains($0.type.str) }.length, 3)
            } else { assertBridgeRestored(h.before, after, h.bridge) }
            #expect(after.prefix(beforeRecovery.count) == beforeRecovery)
            deq(lines(String(decoding: after, as: UTF8.self)).at(-1), h.bridge)
            ok(exists(h.recordFile("P", SOURCE)))
            deq(.strings(try readdir(h.dir("Z"))), [])
            _ = try undo(h.paths, ["processes": []])
            eq(try readData(transcript), after)
        }

        @Test("bridge Undo preserves later messages, newer bridges and replaced transcripts", arguments: ["later messages", "newer bridge", "rewritten prefix", "replacement"])
        func bridgeUndoPreserves(mode: String) throws {
            let h = try bridgeFixture(), transcript = h.transcriptPath
            eq(try move(try inventory([h.from], h.to, h.paths, NOOP, ["processes": []]), h.to, h.paths).ok, true)
            try appendText(transcript, "\(JSON.text(entry("user", 3, 2, SOURCE)))\n")
            if mode == "newer bridge" { try appendText(transcript, "\(JSON.text(.spread(h.bridge, ["bridgeSessionId": "cse_newer", "ownerAccountUuid": h.to.account, "ownerOrganizationUuid": h.to.org])))\n") }
            if mode == "rewritten prefix" { try writeText(transcript, try readText(transcript).replacingOccurrences(of: "message 1", with: "changed history")) }
            if mode == "replacement" { try rename(transcript, "\(transcript).old"); try writeData(transcript, try readData("\(transcript).old")) }
            let before = try readData(transcript), undone = try undo(h.paths, ["processes": []]), after = try readData(transcript)
            ok(undone.dest)
            if mode != "later messages" {
                #expect(after == before)
                deq(.strings(try readdir(h.dir("Z"))), [])
                ok(exists(h.recordFile("P", SOURCE)))
                return
            }
            #expect(after.prefix(before.count) == before)
            let rows = lines(String(decoding: after, as: UTF8.self))
            deq(rows.at(-1), h.bridge)
            eq(rows.filter { MESSAGES.contains($0.type.str) }.length, 3)
            deq(try readJSON(h.recordFile("P", SOURCE)).bridgeSessionIds, ["session_prior"])
            deq(.strings(try readdir(h.dir("Z"))), [])
        }

        // The receipt phase a corruption case runs in.
        static func corruptionPhase(_ name: String) -> String {
            switch name {
            case "missing original during retirement", "invalid length during retirement": return "retirement"
            case "missing original during placement", "message append during placement", "wrong-session append during placement": return "pending"
            case "missing shared record alias": return "shared"
            case "invalid Undo append", "wrong-session Undo original": return "interrupted undo"
            default: return "undo"
            }
        }

        static func corrupt(_ name: String, _ row: Value) {
            let append: Value = row.bridgeAppend
            switch name {
            case "missing original", "missing original during retirement", "missing original during placement": append.removeKey("original")
            case "null original": append.original = nil
            case "wrong-session original": append.original.sessionId = Value(id(799))
            case "message original": append.original = entry("user", 4, 3, SOURCE)
            case "substituted original owner": append.original.ownerAccountUuid = Value(id(999))
            case "invalid appended metadata": append.bytes = "undefined\n"
            case "invalid length during retirement": append["length"] = -1
            case "message append during placement": append.bytes = Value(JSON.text(entry("user", 4, 3, SOURCE)) + "\n")
            case "wrong-session append during placement":
                let bytes: String = append.bytes.str
                if let range = bytes.range(of: SOURCE) { append.bytes = Value(bytes.replacingCharacters(in: range, with: id(799))) }
            case "malformed content hash": append.sha = nil
            case "inconsistent append hash": append.afterSha = Value(String(repeating: "0", count: 64))
            case "missing identity witness": append.removeKey("fingerprint")
            case "missing worker aliases": append.removeKey("recordIds")
            case "invalid worker alias": append.recordIds = ["not-a-record"]
            case "missing owning record alias": append.recordIds = [Value("local_" + id(799))]
            case "missing shared record alias": append.recordIds = [Value("local_" + SOURCE)]
            case "invalid Undo append": row.bridgeUndo.bytes = "undefined\n"
            case "wrong-session Undo original": row.bridgeUndo.original.sessionId = Value(id(799))
            default: Issue.record("unknown corruption \(name)")
            }
        }

        @Test("bridge recovery refuses corrupt receipt metadata before changing transcripts or records", arguments: [
            "missing original", "null original", "wrong-session original", "message original", "substituted original owner", "invalid appended metadata",
            "missing original during retirement", "invalid length during retirement", "missing original during placement", "message append during placement",
            "wrong-session append during placement", "malformed content hash", "inconsistent append hash", "missing identity witness", "missing worker aliases",
            "invalid worker alias", "missing owning record alias", "missing shared record alias", "invalid Undo append", "wrong-session Undo original",
        ])
        func corruptBridgeMetadata(name: String) throws {
            let phase = Receipts.corruptionPhase(name)
            let h = try bridgeFixture(), transcriptPath = h.transcriptPath
            var from = h.from
            if phase == "shared" {
                try h.record("P", id(799), rehomeRecord(["cliSessionId": Value(SOURCE), "forkedFromSessionId": Value("local_\(SOURCE)")]))
                from = try accounts(h.paths, []).find { $0.account.str == h.acct.P }
            }
            let moved = try move(try inventory([from], h.to, h.paths, NOOP, ["processes": []]), h.to, h.paths)
            eq(moved.ok, true)
            try appendText(transcriptPath, "\(JSON.text(entry("user", 3, 2, SOURCE)))\n")
            if phase == "interrupted undo" {
                let rename = fs.rename, file = moved.file.str
                fs.rename = { a, b in
                    if b == file, try readJSON(a).sessions[0].bridgeUndo.truthy {
                        try rename(a, b)
                        throw JSError("Synthetic receipt corruption checkpoint")
                    }
                    try rename(a, b)
                }
                throwsError("Synthetic receipt corruption checkpoint") { try undo(h.paths, ["processes": []]) }
                fs = NodeFS()
            }
            let receipt = try readReceipt(moved.file), row = receipt.sessions[0]
            Receipts.corrupt(name, row)
            if phase == "retirement" {
                receipt.finalizing = true
                receipt.retiring = receipt.superseded
                receipt.superseded = []
            }
            if phase == "pending" {
                receipt.finalizing = true
                receipt.pending = .spread(row, ["made": [row.record]])
                receipt.sessions = []
            }
            try writeJSON(moved.file.str, receipt)
            let roots = [h.paths.records.str, h.paths.pool.str, path.join(h.paths.state.str, "quarantine")]
            let before = try fixtureSnapshot(h, roots), transcript = try readData(transcriptPath)
            let result = try undo(h.paths, ["processes": []])
            eq(result.dest.truthy, false)
            ok(result.restoreProblems.length > 0 || result.changed.length > 0 || result.reconciled.error.truthy)
            eq(try readData(transcriptPath), transcript)
            deq(try fixtureSnapshot(h, roots), before)
        }

        @Test("bridge Undo append checkpoints resume without dropping later content", arguments: ["intent", "partial", "partial twice", "synced", "restored"])
        func bridgeUndoAppendCheckpoints(checkpoint: String) throws {
            let h = try bridgeFixture(), transcript = h.transcriptPath
            let moved = try move(try inventory([h.from], h.to, h.paths, NOOP, ["processes": []]), h.to, h.paths)
            let file = moved.file.str
            try appendText(transcript, "\(JSON.text(entry("user", 3, 2, SOURCE)))\n")
            let before = try readData(transcript), write = fs.handleWrite, sync = fs.handleSync, rename = fs.rename
            var injected = false
            fs.handleWrite = { handle, data in
                guard handle.path == transcript else { return try write(handle, data) }
                try write(handle, checkpoint.hasPrefix("partial") && !injected ? data.prefix(25) : data)
                if checkpoint.hasPrefix("partial") && !injected { injected = true; throw JSError("Synthetic Undo interruption") }
            }
            fs.handleSync = { handle in
                try sync(handle)
                if handle.path == transcript && checkpoint == "synced" && !injected { injected = true; throw JSError("Synthetic Undo interruption") }
            }
            fs.rename = { a, b in
                if checkpoint == "intent" && b == file && !injected, try readJSON(a).sessions[0].bridgeUndo.truthy {
                    try rename(a, b); injected = true; throw JSError("Synthetic Undo interruption")
                }
                if checkpoint == "restored" && a == file && !injected { injected = true; throw JSError("Synthetic Undo interruption") }
                try rename(a, b)
            }
            throwsError("Synthetic Undo interruption") { try undo(h.paths, ["processes": []]) }
            fs = NodeFS()
            #expect(injected)
            if checkpoint == "partial twice" {
                let partial = try readData(transcript)
                var repeated = false
                let write = fs.handleWrite
                fs.handleWrite = { handle, bytes in
                    guard handle.path == transcript && !repeated else { return try write(handle, bytes) }
                    let plan = try readReceipt(Value(file)).sessions[0].bridgeUndo
                    eq(plan.continuation.bytes, Value(bytes.base64EncodedString()))
                    eq(plan.continuation["length"], Value(partial.count))
                    repeated = true
                    try write(handle, bytes.prefix(7))
                    throw JSError("Synthetic continuation interruption")
                }
                throwsError("Synthetic continuation interruption") { try undo(h.paths, ["processes": []]) }
                fs = NodeFS()
                #expect(repeated)
                eq(try readData(transcript).prefix(partial.count), partial)
            }
            if checkpoint == "synced" || checkpoint == "restored" { try appendText(transcript, "\(JSON.text(entry("assistant", 4, 3, SOURCE)))\n") }
            let recovered = try undo(h.paths, ["processes": []])
            ok(recovered.dest)
            let after = try readData(transcript), rows = lines(String(decoding: after, as: UTF8.self))
            #expect(after.prefix(before.count) == before)
            deq(rows.filter { $0.type == "bridge-session" }.at(-1), h.bridge)
            eq(rows.filter { MESSAGES.contains($0.type.str) }.length, ["synced", "restored"].contains(checkpoint) ? 4 : 3)
            eq(rows.filter { $0.type == "bridge-session" }.length, 3)
            deq(.strings(try readdir(h.dir("Z"))), [])
            ok(exists(h.recordFile("P", SOURCE)))
            _ = try undo(h.paths, ["processes": []])
            eq(try readData(transcript), after)
        }
    }
}
