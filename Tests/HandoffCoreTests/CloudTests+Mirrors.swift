import Foundation
import Testing
@testable import HandoffCore

extension Engine.Cloud {
    // A cloud call that must never happen: records an issue and throws.
    static func fail(_ message: String) -> Value {
        fn { _ in Issue.record(Comment(rawValue: message)); throw JSError(message) }
    }

    @Test("bridge recovery of remote-only work leaves unrelated completed metadata alone")
    func bridgeRecoveryRemoteOnly() throws {
        let h = try bridgeFixture()
        let moved = try move(try inventory([h.from], h.to, h.paths, NOOP, ["processes": []]), h.to, h.paths)
        try appendText(h.transcriptPath, "\(JSON.text(.spread(h.bridge, ["bridgeSessionId": "cse_newer", "ownerAccountUuid": h.to.account, "ownerOrganizationUuid": h.to.org])))\n")
        let receipt = try readReceipt(moved.file)
        receipt.remotePending = ["id": "cse_pending", "title": "Synthetic source mirror", "account": h.from.account, "org": h.from.org]
        try writeJSON(moved.file.str, receipt)
        let before = try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str])
        var reads = 0
        let cloud = cloudFixture(h, ["session": fn { args in reads += 1; eq(Self.arg(args, 0), "cse_pending"); return remoteState("archived") }])
        let result = try undo(h.paths, ["processes": [], "cloud": cloud])
        match(result.reconciled.error, "interrupted Remote Control archive completed")
        eq(reads, 1)
        deq(try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str]), before)
    }

    static let sshModes: [(String, Value)] = {
        let sshConfig: Value = ["sshHost": "fixture.invalid"], sshRemoteTranscriptPath = Value("/home/fixture/.claude/projects/-home-fixture/\(SOURCE).jsonl")
        return [
            ("remote path", ["sshRemoteTranscriptPath": sshRemoteTranscriptPath]),
            ("configuration and remote path", ["sshConfig": sshConfig, "sshRemoteTranscriptPath": sshRemoteTranscriptPath]),
            ("configuration without cached path", ["sshConfig": sshConfig]),
            ("configuration with empty cached path", ["sshConfig": sshConfig, "sshRemoteTranscriptPath": ""]),
            ("shared configuration", ["sshConfig": sshConfig]),
            ("shared remote path", ["sshRemoteTranscriptPath": sshRemoteTranscriptPath]),
            ("native mirror location", [:]),
            ("native mirror alias", [:]),
        ]
    }()

    @Test("bridge rehome preserves SSH mirrors and records through Move and Undo", arguments: ["remote path", "configuration and remote path", "configuration without cached path", "configuration with empty cached path",
                     "shared configuration", "shared remote path", "native mirror location", "native mirror alias"])
    func bridgeRehomePreservesSSH(mode: String) throws {
        let extra = Self.sshModes.first { $0.0 == mode }!.1
        let h = try bridgeFixture(), shared = mode.hasPrefix("shared")
        var transcript = h.transcriptPath
        try h.record("P", shared ? id(777) : SOURCE, rehomeRecord(.spread(["bridgeSessionIds": ["session_prior"]], extra,
            shared ? ["cliSessionId": Value(SOURCE), "forkedFromSessionId": Value("local_\(SOURCE)")] : [:])))
        if mode.hasPrefix("native mirror") {
            let project = path.join(h.paths.pool.str, "ssh-\(SOURCE)")
            try rename(h.project, project)
            if mode == "native mirror alias" { try symlink(project, h.project) }
            transcript = try NodeFS.nativeRealpath(path.join(project, "\(SOURCE).jsonl"))
        }
        let originals = try readdir(h.dir("P")).map { ($0, try readData(path.join(h.dir("P"), $0))) }
        let from = try accounts(h.paths, []).find { $0.account.str == h.acct.P }
        let inv = try inventory([from], h.to, h.paths, NOOP, ["processes": []])
        eq(inv.move.length, originals.count)
        eq(inv.move[0].record.sessionId, Value("local_\(SOURCE)"))
        if mode == "native mirror alias" { eq(inv.move[0].transcript, Value(path.join(h.project, "\(SOURCE).jsonl"))) }
        ok(inv.move.every { $0.strategy == "rehome" })
        let moved = try move(inv, h.to, h.paths)
        eq(moved.ok, true)
        ok(moved.receipt.sessions.every { !$0.bridgeAppend.truthy })
        #expect(try readData(transcript) == h.before)
        for (name, bytes) in originals {
            deq(try readJSON(path.join(h.dir("Z"), name)), .spread(try JSON.parse(bytes), ["bridgeSessionIds": []]))
        }
        deq(.strings(try readdir(h.dir("P"))), [])
        ok(try undo(h.paths, ["processes": []]).dest)
        #expect(try readData(transcript) == h.before)
        for (name, bytes) in originals { #expect(try readData(path.join(h.dir("P"), name)) == bytes) }
        deq(.strings(try readdir(h.dir("Z"))), [])
    }

    @Test("local moves finish while inaccessible source cloud checks stay pending")
    func inaccessibleSourceStaysPending() throws {
        let h = try home()
        let first = id(701), second = id(702)
        try h.write(first, [entry("user", 1, nil, first)])
        try h.record("P", first, rehomeRecord(["title": "First source"]))
        try h.record("T", second, rehomeRecord(["title": "Second source"]))
        let cloud = cloudFixture(h)
        let all = try accounts(h.paths)
        let from: Value = [all.find { $0.account.str == h.acct.P && $0.org.str == h.org.P }, all.find { $0.account.str == h.acct.T && $0.org.str == h.org.T }]
        let to = all.find { $0.account.str == h.acct.Z && $0.org.str == h.org.Z }
        let inv = try inventory(from, to, h.paths, NOOP, ["cloud": cloud, "cloudRequested": true])
        let result = try move(inv, to, h.paths)
        eq(result.ok, true)
        eq(result.complete, false)
        eq(result.pendingCloud, 1)
        deq(result.receipt.cloudChecks.map { ["label": $0.label, "status": $0.status] }, [["label": from[0].label, "status": "complete"], ["label": from[1].label, "status": "pending"]])
        deq(.strings(try readdir(h.dir("Z"))), [Value("local_\(first).json")])
        deq(.strings(try readdir(h.dir("P"))), [])
        deq(.strings(try readdir(h.dir("T"))), [Value("local_\(second).json")])
        let blocked = cli(h.root, ["--from", "z@example.com personal", "--to", "p@example.com personal", "--json"])
        eq(blocked.code, 1)
        match(try JSON.parse(blocked.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last!).reason, "pending move")
    }

    @Test("a zero-record source creates no speculative cloud check")
    func zeroRecordSource() throws {
        let h = try home()
        let all = try accounts(h.paths)
        let from = all.find { $0.account.str == h.acct.T && $0.org.str == h.org.T }
        let to = all.find { $0.account.str == h.acct.Z && $0.org.str == h.org.Z }
        let result = try move(try inventory([from], to, h.paths, NOOP, ["cloudRequested": true]), to, h.paths)
        eq(result, nil)
        eq(try readdir(h.paths.state.str).filter { re(#"^\d.*\.json$"#).test($0) }.count, 0)
    }

    @Test("known source mirrors stay queued after local retirement and only finish under their source login")
    func knownSourceMirrorsQueued() throws {
        for source in ["record", "transcript", "local-only"] {
            let h = try home(), entries = branchEntries(2, SOURCE, 1)
            try h.write(SOURCE, entries.concat(source == "transcript" ? [["type": "bridge-session", "sessionId": Value(SOURCE), "bridgeSessionId": "cse_known"]] : []))
            try h.record("T", SOURCE, rehomeRecord(["bridgeSessionIds": source == "transcript" ? [] : ["session_known"]]))
            let all = try accounts(h.paths), from = all.find { $0.account.str == h.acct.T }, to = all.find { $0.account.str == h.acct.Z }
            let inv = try inventory([from], to, h.paths, NOOP, ["cloudRequested": Value(source != "local-only"),
                "cloud": source == "local-only" ? .null : cloudFixture(h, ["account": to.account, "org": to.org, "list": Self.fail("destination login must not list the source")])])
            let moved = try move(inv, to, h.paths)
            eq(moved.ok, true)
            deq(.strings(try readdir(h.dir("T"))), [])
            if source == "local-only" { eq(moved.pendingCloud, 0); continue }
            eq(moved.pendingCloud, 1)
            eq(moved.complete, false)
            deq(moved.receipt.cloudChecks[0].sessionIds, ["session_known"])
            let placed = moved.receipt.sessions[0].record.str
            try writeJSON(placed, .spread(try readJSON(placed), ["isArchived": true]))
            let snapshot = try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str])
            let pending = lines(cli(h.root, ["accounts", "--json"]).stdout)[0].find { $0.account === from.account }
            eq(pending.pendingAction, "sign-in")
            var reads = 0, status = "active"
            let cloud = cloudFixture(h, ["account": from.account, "org": from.org,
                "list": fn { _ in reads += 1; return Value(["cse_known", "cse_unrelated"].map { remoteSession(["id": Value($0), "title": "Remote title", "status": Value(status)]) }) },
                "eventRows": fn { args in eq(Self.arg(args, 0), "cse_known"); return remoteRows(entries) },
                "session": fn { args in eq(Self.arg(args, 0), "cse_known"); return remoteState(status) },
                "archive": fn { args in eq(Self.arg(args, 0), "cse_known"); status = "archived"; return .undefined },
            ])
            let waiting = try sweep(h.paths, ["active": to, "processes": [], "cloud": cloud])
            eq(waiting.pending, true)
            eq(reads, 0)
            let finished = try sweep(h.paths, ["active": from, "processes": [], "cloud": cloud])
            eq(finished.ok, true)
            eq(finished.result.complete, true)
            eq(finished.result.file, moved.file)
            eq(finished.result.cloudArchived, 1)
            eq(status, "archived")
            deq(try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str]), snapshot)
        }
    }

    @Test("held continuations merge new mirror scopes without reopening unchanged or cancelled checks")
    func heldContinuationsMergeScopes() throws {
        for (status, scoped, added) in [("pending", true, true), ("complete", true, true), ("pending", false, true), ("complete", false, true), ("complete", true, false), ("cancelled", true, true)] {
            let h = try home(), cold = id(809), coldEntries = branchEntries(2, cold, 501), heldEntries = branchEntries(2, SOURCE, 511)
            try h.write(cold, coldEntries)
            try h.write(SOURCE, heldEntries)
            try h.record("P", cold, rehomeRecord(["bridgeSessionIds": ["session_cold"]]))
            try h.record("P", SOURCE, rehomeRecord(["isArchived": true, "bridgeSessionIds": [Value(added ? "session_held" : "session_cold")]]))
            let all = try accounts(h.paths), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
            let moved = try executeMove([from], to, h.paths, ["cloudRequested": true, "moveOnly": true, "processes": desktopFixture()])
            eq(moved.receipt.held.length, 1)
            let check = moved.receipt.cloudChecks[0]
            deq(check.sessionIds, ["session_cold"])
            check.status = Value(status)
            if !scoped { check.removeKey("sessionIds") }
            try writeJSON(moved.file.str, moved.receipt)
            let resumed = try finishHeld(h.paths, ["processes": []])
            eq(resumed.receipt.sessions.length, 2)
            let pending = status == "pending" || status == "complete" && added
            eq(resumed.receipt.cloudChecks[0].status, Value(pending ? "pending" : status))
            deq(resumed.receipt.cloudChecks[0].sessionIds, scoped ? Value.strings(["session_cold"] + (added && status != "cancelled" ? ["session_held"] : [])) : .undefined)
            if !pending { eq(resumed.pendingCloud, 0); continue }
            let states: Value = ["cse_cold": Value(status == "complete" ? "archived" : "active"), "cse_held": "active"]
            let cloud = cloudFixture(h, [
                "list": fn { _ in Value(states.ownEntries.map { remoteSession(["id": Value($0.0), "status": $0.1]) } + (scoped ? [remoteSession(["id": "cse_unrelated"])] : [])) },
                "eventRows": fn { args in ok(states.hasOwn(Self.arg(args, 0).str)); return remoteRows(Self.arg(args, 0) == "cse_cold" ? coldEntries : heldEntries) },
                "session": fn { args in ok(states.hasOwn(Self.arg(args, 0).str)); return remoteState(states[Self.arg(args, 0).str].str) },
                "archive": fn { args in ok(states.hasOwn(Self.arg(args, 0).str)); states[Self.arg(args, 0).str] = "archived"; return .undefined },
            ])
            let finished = try finishPending(h.paths, ["cloud": cloud])
            eq(finished.ok, true)
            eq(finished.complete, true)
            deq(states.valuesArray, ["archived", "archived"])
        }
    }

    @Test("round trips keep transcript mirrors with their explicit account and organization across cache generations")
    func roundTripsKeepMirrors() throws {
        for sameLogin in [false, true] {
            for cache in ["cold", "warm", "legacy"] {
                let h = try home(), entries = branchEntries(2, SOURCE, 1)
                if sameLogin { h.acct.T = h.acct.P; try mkdirp(h.dir("T")) }
                try h.write(SOURCE, entries.concat([["type": "bridge-session", "sessionId": Value(SOURCE), "bridgeSessionId": "session_prior_owner", "ownerAccountUuid": Value(h.acct.P), "ownerOrganizationUuid": Value(h.org.P)]]))
                try h.record("P", SOURCE, rehomeRecord(["bridgeSessionIds": ["session_prior_owner"]]))
                let all = try accounts(h.paths)
                let from = all.find { $0.account.str == h.acct.P && $0.org.str == h.org.P }, to = all.find { $0.account.str == h.acct.T && $0.org.str == h.org.T }
                var status = "active"
                let cloud = cloudFixture(h, [
                    "list": fn { _ in [remoteSession(["id": "cse_prior_owner", "title": "Old source", "status": Value(status)])] },
                    "session": fn { _ in remoteState(status) }, "eventRows": fn { _ in remoteRows(entries) }, "archive": fn { () in status = "archived" },
                ])
                let first = try move(try inventory([from], to, h.paths, NOOP, ["cloudRequested": true, "cloud": cloud, "writeCache": Value(cache != "cold")]), to, h.paths)
                eq(first.pendingCloud, 0)
                eq(status, "archived")
                let current = try accounts(h.paths)
                let source = current.find { $0.account === to.account && $0.org === to.org }, target = current.find { $0.account === from.account && $0.org === from.org }
                if cache != "cold" {
                    _ = try inventory([source], target, h.paths, NOOP, ["cloudRequested": true, "cloud": cloud, "writeCache": true])
                    let warm = try inventory([source], target, h.paths, NOOP, ["cloudRequested": true, "cloud": cloud])
                    ok((warm.cacheStats.historyHits.asNumber ?? 0) > 0)
                    eq(warm.cacheStats.historyMisses, 0)
                }
                if cache == "legacy" {
                    let file = path.join(h.paths.state.str, "cache.json"), stored = try readJSON(file)
                    for (_, row) in stored.histories.ownEntries { row.value.result.removeKey("bridgeOwners") }
                    try writeJSON(file, stored)
                }
                let inv = try inventory([source], target, h.paths, NOOP, ["cloudRequested": true, "cloud": cloud])
                ok((inv.cacheStats[cache == "warm" ? "historyHits" : "historyMisses"].asNumber ?? 0) > 0, "\(sameLogin) \(cache)")
                let second = try move(inv, target, h.paths)
                eq(second.ok, true)
                eq(second.pendingCloud, 0)
                deq(second.receipt.cloudLinks, [])
            }
        }
    }

    @Test("task and restarted moves retain known mirror cleanup and Keep completed can cancel it")
    func taskMovesRetainMirrorCleanup() throws {
        for restart in [false, true] {
            let h = try taskFamilyFixture(), harness = taskHarness(), io = harness.io
            defer { withExtendedLifetime(harness) {} }
            try h.record("P", SOURCE, rehomeRecord(["bridgeSessionIds": ["session_task_mirror"]]))
            let (from, to) = try h.selection()
            let cloud = cloudFixture(h, ["account": to.account, "org": to.org, "list": Self.fail("wrong source login")])
            let options = Value.spread(["cloudRequested": true, "cloud": cloud], restart ? ["io": io] : ["processes": []])
            var moved = try executeMove([from], to, h.paths, options)
            if restart {
                deq(moved.plan.deferredCloudSources, [])
                moved = try executeMove([from], to, h.paths, .spread(options, ["approve": moved.plan.token]))
                eq(moved.restarted, true)
            }
            eq(moved.ok, true)
            eq(moved.receipt.sessions.length, 4)
            eq(moved.pendingCloud, 1)
            deq(moved.receipt.cloudChecks[0].sessionIds, ["session_task_mirror"])
            eq(moved.complete, false)
            let kept = try keepLocal(h.paths)
            eq(kept.cancelled, 1)
            eq(kept.complete, true)
            eq(try sweep(h.paths, ["active": from, "processes": [], "cloud": cloud]).complete, true)
        }
    }

    @Test("deferred mirror links follow a recorded rewind and keep a remote-only branch unarchived")
    func deferredLinksFollowRewind() throws {
        let h = try home(), current = id(797), oldEntries = branchEntries(2, SOURCE, 1)
        try h.write(SOURCE, oldEntries)
        try h.record("T", SOURCE, rehomeRecord(["bridgeSessionIds": ["session_rewound"]]))
        let all = try accounts(h.paths), from = all.find { $0.account.str == h.acct.T }, to = all.find { $0.account.str == h.acct.Z }
        let moved = try move(try inventory([from], to, h.paths, NOOP, ["cloudRequested": true]), to, h.paths)
        let row = moved.receipt.sessions[0], original = try readData(row.targetTranscript.str)
        try h.write(current, branchEntries(1, current, 51))
        try writeJSON(row.record.str, .spread(try readJSON(row.record.str), ["cliSessionId": Value(current), "priorCliSessionIds": [Value(SOURCE)], "bridgeSessionIds": [], "title": "Renamed after rewind"]))
        let record = try readData(row.record.str), transcript = try readData(h.transcript(current))
        var status = "active"
        let cloud = cloudFixture(h, ["account": from.account, "org": from.org,
            "list": fn { _ in [remoteSession(["id": "cse_rewound", "title": "Remote title", "status": Value(status)])] },
            "eventRows": fn { _ in remoteRows(oldEntries.concat([entry("assistant", 4, 2, SOURCE)])) },
            "session": fn { _ in remoteState(status) }, "archive": fn { () in status = "archived" },
        ])
        let finished = try finishPending(h.paths, ["cloud": cloud])
        eq(finished.ok, true)
        deq(finished.failed, [])
        deq(finished.summary.kept.map { $0.code }, ["CLOUD_UNPROVEN"])
        eq(finished.cloudArchived, 0)
        eq(status, "active")
        #expect(try readData(row.record.str) == record)
        #expect(try readData(row.targetTranscript.str) == original)
        #expect(try readData(h.transcript(current)) == transcript)
    }

    @Test("recorded retained histories allow mirror cleanup without cloning task-owned rewinds",
          arguments: ["retained", "changed", "uncached-analysis", "cached-analysis", "missing", "unrecorded", "malformed"])
    func retainedHistoriesAllowCleanup(scenario: String) throws {
        let h = try home(), current = id(798), entries = branchEntries(2, SOURCE, 1)
        try h.write(SOURCE, entries)
        try h.record("T", SOURCE, rehomeRecord(["bridgeSessionIds": ["session_retained"]]))
        let all = try accounts(h.paths), from = all.find { $0.account.str == h.acct.T }, to = all.find { $0.account.str == h.acct.Z }
        let moved = try move(try inventory([from], to, h.paths, NOOP, ["cloudRequested": true, "writeCache": Value(scenario == "cached-analysis")]), to, h.paths)
        let row = moved.receipt.sessions[0], targetTranscript = row.targetTranscript.str
        try h.write(current, branchEntries(1, current, 51))
        let prior: Value = scenario == "unrecorded" ? [] : scenario == "malformed" ? Value(SOURCE) : [Value(SOURCE)]
        try writeJSON(row.record.str, .spread(try readJSON(row.record.str), ["cliSessionId": Value(current), "bridgeSessionIds": [], "priorCliSessionIds": prior]))
        try writeJSON(to.taskFile.str, ["scheduledTasks": [["id": "retained-task", "enabled": true, "notifySessionId": row.targetRecordId]]])
        if scenario == "missing" { try unlink(targetTranscript) }
        let record = try readData(row.record.str), tasks = try readData(to.taskFile.str)
        var status = "active", reads = 0
        let cloud = cloudFixture(h, ["account": from.account, "org": from.org,
            "list": fn { _ in [remoteSession(["id": "cse_retained", "title": "Older remote title", "status": Value(status)])] },
            "eventRows": fn { _ in
                reads += 1
                if reads == 3 && scenario == "changed" { try appendText(targetTranscript, "{}\n") }
                return remoteRows(entries)
            },
            "session": fn { _ in remoteState(status) }, "archive": fn { () in status = "archived" },
        ])
        var changedDuringAnalysis = false, transcriptReads = 0
        let readFile = fs.readFile, statFile = fs.stat
        fs.readFile = { file in
            let bytes = try readFile(file)
            if file == targetTranscript {
                transcriptReads += 1
                if transcriptReads == 2 && scenario == "uncached-analysis" {
                    try h.write(SOURCE, [entry("user", 777, nil, SOURCE)])
                    changedDuringAnalysis = true
                }
            }
            return bytes
        }
        fs.stat = { file, big in
            let detail = try statFile(file, big)
            if file == targetTranscript && scenario == "cached-analysis" && !changedDuringAnalysis {
                try h.write(SOURCE, [entry("user", 777, nil, SOURCE)])
                changedDuringAnalysis = true
            }
            return detail
        }
        let result = try finishPending(h.paths, ["cloud": cloud])
        fs.readFile = readFile
        fs.stat = statFile
        #expect(changedDuringAnalysis == scenario.hasSuffix("-analysis"))
        let final = ["retained", "unrecorded", "malformed"].contains(scenario)
        eq(result.ok, Value(final), scenario)
        eq(result.complete, Value(final), scenario)
        eq(status, scenario == "retained" ? "archived" : "active")
        if ["unrecorded", "malformed"].contains(scenario) { deq(result.summary.kept.map { $0.code }, ["CLOUD_UNPROVEN"], scenario) }
        if scenario == "changed" { match(result.failed[0].error, "Retained local history changed") }
        if scenario == "missing" { eq(result.failed[0].code, "CLOUD_ARTIFACT_UNCERTAIN") }
        #expect(try readData(row.record.str) == record)
        #expect(try readData(to.taskFile.str) == tasks)
        #expect(try readdir(h.dir("Z")).sorted() == [path.basename(row.record.str), "scheduled-tasks.json"].sorted())
    }

    @Test("a late move failure restores the source cloud check")
    func lateMoveFailureRestoresCheck() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("T", SOURCE, rehomeRecord())
        let all = try accounts(h.paths)
        let from = all.find { $0.account.str == h.acct.T && $0.org.str == h.org.T }
        let to = all.find { $0.account.str == h.acct.Z && $0.org.str == h.org.Z }
        let inv = try inventory([from], to, h.paths, NOOP, ["cloudRequested": true, "cloudError": "authentication unavailable"])
        let result = try move(inv, to, h.paths, fn { args in
            if Self.arg(args, 0) == "move" && Self.arg(args, 2).completed == 0 { try appendText(h.transcript(SOURCE), "\(JSON.text(entry("assistant", 2, 1, SOURCE)))\n") }
            return .undefined
        })
        eq(result.ok, false)
        eq(result.pendingCloud, 1)
        eq(result.receipt.cloudChecks[0].status, "pending")
        eq(result.receipt.cloudError, "authentication unavailable")
        deq(result.receipt.verification, ["ok": true, "problems": []])
        eq(try verifyPlaced(h.paths).ok, false)
        ok(exists(h.recordFile("T", SOURCE)))
    }

    @Test("a refused retirement restores the source cloud check")
    func refusedRetirementRestoresCheck() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("T", SOURCE, rehomeRecord(["scheduledTaskId": "task_fixture"]))
        try h.record("Z", SOURCE, rehomeRecord())
        let all = try accounts(h.paths)
        let from = all.find { $0.account.str == h.acct.T && $0.org.str == h.org.T }
        let to = all.find { $0.account.str == h.acct.Z && $0.org.str == h.org.Z }
        let inv = try inventory([from], to, h.paths, NOOP, ["cloudRequested": true])
        eq(inv.cloudCheckAccounts.length, 1)
        let result = try move(inv, to, h.paths)
        eq(result.pendingCloud, 1)
        ok(exists(h.recordFile("T", SOURCE)))
    }

    @Test("Keep local retains a verified bridge rehome while its remote check is unavailable")
    func keepLocalRetainsBridgeRehome() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("T", SOURCE, rehomeRecord(["title": "Keep local source", "bridgeSessionIds": ["session_keep_local"]]))
        let all = try accounts(h.paths)
        let from = all.find { $0.account.str == h.acct.T && $0.org.str == h.org.T }
        let to = all.find { $0.account.str == h.acct.Z && $0.org.str == h.org.Z }
        let moved = try moveWithPending(h, [from], to)
        let kept = try keepLocal(h.paths)
        eq(kept.cancelled, 1)
        eq(kept.receipt.cloudChecks[0].status, "cancelled")
        deq(.strings(try readdir(h.dir("T"))), [])
        deq(.strings(try readdir(h.dir("Z"))), [Value("local_\(SOURCE).json")])
        eq(cli(h.root, ["--dry-run", "--from", "z@example.com personal", "--to", "p@example.com personal", "--json"]).code, 0)
        ok(try undo(h.paths).dest)
        eq(moved.file, kept.file)
    }
}
