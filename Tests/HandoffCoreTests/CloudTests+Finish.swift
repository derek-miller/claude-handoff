import Foundation
import Testing
@testable import HandoffCore

extension Engine.Cloud {
    static func receiptNames(_ h: Home) throws -> [String] { try readdir(h.paths.state.str).filter { re(#"^\d.*\.json$"#).test($0) } }

    @Test("Finish cloud success retains historical local refusals as information")
    func finishRetainsHistoricalRefusals() throws {
        for failure in ["none", "verification", "verification without details", "cloud"] {
            let h = try home()
            try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
            try h.record("T", SOURCE, rehomeRecord())
            let all = try accounts(h.paths), from = all.find { $0.account.str == h.acct.T }, to = all.find { $0.account.str == h.acct.Z }
            let moved = try moveWithPending(h, [from], to)
            let receipt = try readJSON(moved.file.str)
            receipt.failed.push(["id": Value(id(998)), "title": "Unmoved task", "error": "scheduled task family missing"])
            if failure.hasPrefix("verification") { receipt.verification = ["ok": false, "problems": failure == "verification" ? [["id": Value(SOURCE), "check": "transcript"]] : []] }
            try writeJSON(moved.file.str, receipt)
            let cloud = cloudFixture(h, ["account": from.account, "org": from.org, "list": fn { _ in
                if failure == "cloud" { throw EngineError("fixture offline") }
                return []
            }])
            let result = try finishPending(h.paths, ["cloud": cloud])
            eq(result.ok, Value(failure == "none"), failure)
            eq(result.complete, Value(failure != "cloud"), failure)
            ok(result.receipt.failed.some { $0.title == "Unmoved task" })
            eq(result.failed.length, failure == "cloud" ? 1 : 0)
            if failure != "cloud" { eq(cli(h.root, ["finish", "--json"]).code, failure == "none" ? 0 : 1, failure) }
        }
    }

    @Test("a source cloud outage never blocks its eligible local move")
    func cloudOutageNeverBlocks() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE, rehomeRecord(["title": "Cloud outage source"]))
        let cloud = cloudFixture(h, ["list": fn { _ in throw EngineError("service unavailable") }])
        let all = try accounts(h.paths)
        let from = all.find { $0.account.str == h.acct.P && $0.org.str == h.org.P }
        let to = all.find { $0.account.str == h.acct.Z && $0.org.str == h.org.Z }
        let inv = try inventory([from], to, h.paths, NOOP, ["cloud": cloud, "cloudRequested": true])
        let result = try move(inv, to, h.paths)
        eq(result.ok, false)
        eq(result.pendingCloud, 1)
        eq(result.receipt.cloudChecks[0].status, "failed")
        match(result.receipt.failed[0].error, "service unavailable")
        deq(.strings(try readdir(h.dir("P"))), [])
        deq(.strings(try readdir(h.dir("Z"))), [Value("local_\(SOURCE).json")])
    }

    @Test("Finish pending closes the same logical receipt under the matching source login")
    func finishPendingClosesSameReceipt() throws {
        let h = try home()
        let first = id(703), second = id(704)
        let firstEntries: Value = [entry("user", 3, nil, first)]
        let secondEntries: Value = [entry("user", 4, nil, second), entry("assistant", 5, 4, second)]
        try h.write(first, firstEntries)
        try h.write(second, secondEntries)
        try h.record("P", first, rehomeRecord(["title": "First deferred source"]))
        try h.record("T", second, rehomeRecord(["title": "Second deferred source", "isArchived": true]))
        let emptyCloud = cloudFixture(h)
        let all = try accounts(h.paths)
        let from: Value = [all.find { $0.account.str == h.acct.P && $0.org.str == h.org.P }, all.find { $0.account.str == h.acct.T && $0.org.str == h.org.T }]
        let to = all.find { $0.account.str == h.acct.Z && $0.org.str == h.org.Z }
        let moved = try moveWithPending(h, from, to, emptyCloud)
        var status = "active"
        let deferredCloud = cloudFixture(h, [
            "account": Value(h.acct.T), "org": Value(h.org.T),
            "list": fn { _ in [remoteSession(["id": "cse_deferred", "title": "Second deferred source", "status": Value(status)])] },
            "eventRows": fn { _ in remoteRows(secondEntries) },
            "session": fn { _ in remoteState(status, ["id": "cse_deferred"]) },
            "archive": fn { () in status = "archived" },
            "unarchive": fn { () in status = "active" },
        ])
        let finished = try finishPending(h.paths, ["cloud": deferredCloud])
        eq(finished.file, moved.file)
        eq(finished.ok, true)
        eq(finished.complete, true)
        eq(finished.pendingCloud, 0)
        ok(finished.receipt.cloudChecks.every { $0.status == "complete" })
        eq(finished.receipt.remote.length, 1)
        eq(finished.restart, true)
        eq(try readJSON(h.recordFile("Z", second)).isArchived, false)
        eq(status, "archived")
        #expect(try Self.receiptNames(h) == [path.basename(moved.file.str)])
    }

    @Test("automatic cloud follow-up waits for its named source login and completes the same receipt")
    func automaticFollowUpWaitsForLogin() throws {
        let h = try home(), f = try identityFixture(h)
        let entries: Value = [entry("user", 1, nil, SOURCE)]
        try h.write(SOURCE, entries)
        try h.record("T", SOURCE, rehomeRecord(["title": "Automatic source"]))
        let all = try accounts(h.paths)
        let from = all.find { $0.account.str == h.acct.T }, to = all.find { $0.account.str == h.acct.Z }
        let moved = try moveWithPending(h, [from], to)
        var reads = 0, status = "active"
        let cloud = cloudFixture(h, [
            "account": Value(h.acct.T), "org": Value(h.org.T),
            "list": fn { _ in reads += 1; return [remoteSession(["id": "cse_auto", "title": "Automatic source", "status": Value(status)])] },
            "eventRows": fn { _ in remoteRows(entries) }, "session": fn { _ in remoteState(status) },
            "archive": fn { () in status = "archived" },
        ])
        _ = try sweep(h.paths, ["processes": f.processes, "cloud": cloud])
        eq(reads, 0)
        try writeJSON(h.paths.desktop.str, ["lastKnownAccountUuid": from.account])
        try f.write(f.`init`() + f.event(1, "[account] Login-state transition (loggedOut: false \u{2192} false, uuid: \(h.acct.P) \u{2192} \(from.account)), clearing oauth cache"))
        _ = try sweep(h.paths, ["processes": f.processes, "cloud": cloud])
        eq(reads, 0)
        try appendText(path.join(h.paths.logs.str, "main.log"), f.`init`(2, from.account.str, from.org.str))
        let finished = try sweep(h.paths, ["processes": f.processes, "cloud": cloud])
        eq(status, "archived")
        eq(finished.result.file, moved.file)
        eq(finished.result.complete, true)
        eq(finished.result.receipt.remote.length, 1)
        eq(readOrNil(path.join(h.paths.state.str, "restart-plan.json")), nil)
        deq(try verifyPlaced(h.paths).changed, [])
    }

    @Test("automatic cloud retries bind their receipt and claim backoff under the mutation lock")
    func automaticRetriesBindReceipt() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("T", SOURCE)
        let all = try accounts(h.paths), from = all.find { $0.account.str == h.acct.T }, to = all.find { $0.account.str == h.acct.Z }
        let first = try moveWithPending(h, [from], to)
        var calls = 0
        let cloud = cloudFixture(h, ["account": Value(h.acct.T), "org": Value(h.org.T), "list": fn { _ in calls += 1; throw EngineError("fixture offline") }])
        let stale = try finishPending(h.paths, ["cloud": cloud, "receiptFile": Value(first.file.str + ".old"), "automatic": from])
        eq(stale.nothing, true)
        eq(calls, 0)
        _ = try sweep(h.paths, ["active": from, "cloud": cloud])
        eq(calls, 1)
        _ = try sweep(h.paths, ["active": from, "cloud": cloud])
        eq(calls, 1)
        let receipt = try readJSON(first.file.str)
        eq(receipt.cloudChecks[0].status, "failed")
        ok((receipt.cloudAttempts["\(from.account)/\(from.org)"].asNumber ?? 0) > 0)
    }

    @Test("a successful cloud phase preserves an earlier local verification failure")
    func cloudPhasePreservesVerificationFailure() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("T", SOURCE)
        try h.record("T", id(997))
        let all = try accounts(h.paths), from = all.find { $0.account.str == h.acct.T }, to = all.find { $0.account.str == h.acct.Z }
        let link = fs.link
        touchPlaced(h.recordFile("Z", SOURCE))
        let first: Value
        do {
            defer { fs.link = link }
            first = try move(try inventory([from], to, h.paths, NOOP, ["cloudRequested": true]), to, h.paths)
        }
        ok(first.summary.notMoved.some { $0.id == Value(SOURCE) })
        let result = try finishPending(h.paths, ["cloud": cloudFixture(h, ["account": from.account, "org": from.org])])
        ok(result.summary.notMoved.some { $0.id == Value(SOURCE) })
        eq(result.receipt.sessions.length, 0)
    }

    @Test("Finish pending preserves a record-only bridge identity after local rehome")
    func recordOnlyBridgeAfterRehome() throws {
        let h = try home()
        let session = id(709)
        let local: Value = [entry("user", 31, nil, session, ["message": ["role": "user", "content": "local history"]])]
        let remote: Value = [entry("user", 32, nil, "cse_record_only", ["message": ["role": "user", "content": "remote branch"]])]
        try h.write(session, local)
        try h.record("T", session, rehomeRecord(["title": "Original local title", "bridgeSessionIds": ["session_record_only"]]))
        let all = try accounts(h.paths)
        let from = all.find { $0.account.str == h.acct.T && $0.org.str == h.org.T }
        let to = all.find { $0.account.str == h.acct.Z && $0.org.str == h.org.Z }
        let moved = try moveWithPending(h, [from], to)
        var status = "active"
        let cloud = cloudFixture(h, [
            "account": Value(h.acct.T), "org": Value(h.org.T),
            "list": fn { _ in [remoteSession(["id": "cse_record_only", "title": "Renamed remote title", "status": Value(status)])] },
            "eventRows": fn { _ in remoteRows(remote) },
            "session": fn { _ in remoteState(status, ["id": "cse_record_only"]) },
            "archive": fn { () in status = "archived" },
            "unarchive": fn { () in status = "active" },
        ])
        let finished = try finishPending(h.paths, ["cloud": cloud])
        ok(moved.receipt.cloudLinks[0].bridgeIds.includes("session_record_only"))
        eq(finished.ok, true)
        deq(finished.failed, [])
        deq(finished.summary.kept.map { $0.code }, ["CLOUD_UNPROVEN"])
        eq(status, "active")
    }

    @Test("Finish pending preserves a record-only bridge identity when history was already there")
    func recordOnlyBridgeAlreadyThere() throws {
        let h = try home()
        let local: Value = [entry("user", 33, nil, SOURCE, ["message": ["role": "user", "content": "local history"]])]
        let remote: Value = [entry("user", 34, nil, "cse_existing_record_only", ["message": ["role": "user", "content": "remote branch"]])]
        try h.write(SOURCE, local)
        try h.record("T", SOURCE, rehomeRecord(["title": "Already there source", "bridgeSessionIds": ["session_existing_record_only"]]))
        try h.record("Z", SOURCE, rehomeRecord(["title": "Already there target"]))
        let all = try accounts(h.paths)
        let from = all.find { $0.account.str == h.acct.T && $0.org.str == h.org.T }
        let to = all.find { $0.account.str == h.acct.Z && $0.org.str == h.org.Z }
        let moved = try moveWithPending(h, [from], to)
        eq(moved.receipt.sessions.length, 0)
        var status = "active"
        let cloud = cloudFixture(h, [
            "account": Value(h.acct.T), "org": Value(h.org.T),
            "list": fn { _ in [remoteSession(["id": "cse_existing_record_only", "title": "Renamed remote title", "status": Value(status)])] },
            "eventRows": fn { _ in remoteRows(remote) },
            "session": fn { _ in remoteState(status, ["id": "cse_existing_record_only"]) },
            "archive": fn { () in status = "archived" },
            "unarchive": fn { () in status = "active" },
        ])
        let finished = try finishPending(h.paths, ["cloud": cloud])
        eq(finished.ok, true)
        deq(finished.failed, [])
        deq(finished.summary.kept.map { $0.code }, ["CLOUD_UNPROVEN"])
        eq(status, "active")
    }

    @Test("Finish pending never sweeps in a Remote Control session created after Move")
    func neverSweepsLaterSession() throws {
        let h = try home()
        let session = id(708)
        let entries: Value = [entry("user", 30, nil, session)]
        try h.write(session, entries)
        try h.record("T", session, rehomeRecord(["title": "Later remote source"]))
        let all = try accounts(h.paths)
        let from = all.find { $0.account.str == h.acct.T && $0.org.str == h.org.T }
        let to = all.find { $0.account.str == h.acct.Z && $0.org.str == h.org.Z }
        let moved = try moveWithPending(h, [from], to)
        var archived = false
        let createdAt = isoString(dateParse(moved.receipt.startedAt.str) + 60_000)
        let cloud = cloudFixture(h, [
            "account": Value(h.acct.T), "org": Value(h.org.T),
            "list": fn { _ in [remoteSession(["id": "cse_created_later", "title": "Later remote source", "created_at": Value(createdAt)])] },
            "eventRows": fn { _ in remoteRows(entries) },
            "session": fn { _ in remoteState("active", ["id": "cse_created_later"]) },
            "archive": fn { () in archived = true },
            "unarchive": NOOP,
        ])
        let finished = try finishPending(h.paths, ["cloud": cloud])
        eq(finished.ok, true)
        eq(finished.complete, true)
        eq(finished.pendingCloud, 0)
        eq(finished.receipt.remote.length, 0)
        eq(finished.newerCloud, 1)
        eq(finished.receipt.cloudChecks[0].later[0].title, "Later remote source")
        #expect(archived == false)
    }

    @Test("the first cloud attempt uses the same creation cutoff as its retry")
    func firstAttemptSameCutoff() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 39, nil, SOURCE)])
        try h.record("P", SOURCE, rehomeRecord(["title": "Cutoff source"]))
        let all = try accounts(h.paths)
        let from = all.find { $0.account.str == h.acct.P && $0.org.str == h.org.P }
        let to = all.find { $0.account.str == h.acct.Z && $0.org.str == h.org.Z }
        var archived = false
        let requestedAt = isoNow()
        let cloud = cloudFixture(h, [
            "list": fn { _ in [remoteSession(["id": "cse_after_click", "title": "Cutoff source", "created_at": Value(isoString(dateParse(requestedAt) + 60_000))])] },
            "eventRows": fn { _ in remoteRows([entry("user", 40, nil, "cse_after_click")]) },
            "session": fn { _ in remoteState("active") },
            "archive": fn { () in archived = true },
            "unarchive": NOOP,
        ])
        let result = try move(try inventory([from], to, h.paths, NOOP, ["cloud": cloud, "cloudRequested": true, "requestedAt": Value(requestedAt)]), to, h.paths)
        eq(result.ok, true)
        eq(result.pendingCloud, 0)
        eq(result.receipt.remote.length, 0)
        eq(result.newerCloud, 1)
        #expect(archived == false)
    }

    @Test("Finish pending refuses an undated remote row instead of widening the move")
    func refusesUndatedRemoteRow() throws {
        let h = try home()
        let all = try accounts(h.paths)
        let from = all.find { $0.account.str == h.acct.T && $0.org.str == h.org.T }
        let to = all.find { $0.account.str == h.acct.Z && $0.org.str == h.org.Z }
        _ = try moveWithPending(h, [from], to)
        var archived = false
        let cloud = cloudFixture(h, [
            "account": Value(h.acct.T), "org": Value(h.org.T),
            "list": fn { _ in [remoteSession(["id": "cse_undated", "title": "Undated remote", "created_at": .undefined])] },
            "eventRows": fn { _ in [] },
            "session": fn { _ in remoteState("active") },
            "archive": fn { () in archived = true },
            "unarchive": NOOP,
        ])
        let result = try finishPending(h.paths, ["cloud": cloud])
        eq(result.ok, false)
        eq(result.pendingCloud, 1)
        match(result.receipt.failed[0].error, "creation time is missing")
        #expect(archived == false)
    }

    @Test("a failed deferred cloud session remains explicit and retryable")
    func failedDeferredSessionRetryable() throws {
        let h = try home()
        let session = id(705)
        let shared = branchEntries(8, session, 10)
        let local = shared.concat([entry("assistant", 18, 17, session, ["message": ["role": "assistant", "content": "local branch"]])])
        try h.write(session, local)
        try h.record("T", session, rehomeRecord(["title": "Retryable cloud source"]))
        let all = try accounts(h.paths)
        let from = all.find { $0.account.str == h.acct.T && $0.org.str == h.org.T }
        let to = all.find { $0.account.str == h.acct.Z && $0.org.str == h.org.Z }
        let moved = try moveWithPending(h, [from], to)
        var supported = false, status = "active"
        let cloud = cloudFixture(h, [
            "account": Value(h.acct.T), "org": Value(h.org.T),
            "list": fn { _ in [remoteSession(["id": "cse_retryable", "title": "Retryable cloud source", "status": Value(status)])] },
            "eventRows": fn { _ in
                if !supported { throw EngineError("Remote Control history contains an unsupported content block") }
                return remoteRows(local)
            },
            "session": fn { _ in remoteState(status, ["id": "cse_retryable"]) },
            "archive": fn { () in status = "archived" },
            "unarchive": fn { () in status = "active" },
        ])
        let failed = try finishPending(h.paths, ["cloud": cloud])
        eq(failed.file, moved.file)
        eq(failed.ok, false)
        eq(failed.pendingCloud, 1)
        eq(failed.receipt.cloudChecks[0].status, "failed")
        match(failed.receipt.failed.at(-1).error, "unsupported content block")
        eq(status, "active")
        supported = true
        let retried = try finishPending(h.paths, ["cloud": cloud])
        eq(retried.ok, true)
        eq(retried.complete, true)
        eq(retried.pendingCloud, 0)
        eq(retried.receipt.failed.length, 0)
        eq(status, "archived")
    }

    @Test("Undo cancels unchecked cloud sources and completes across source logins")
    func undoCancelsUncheckedSources() throws {
        let h = try home()
        let first = id(706), second = id(707)
        let firstEntries: Value = [entry("user", 20, nil, first), entry("assistant", 21, 20, first)]
        let secondEntries: Value = [entry("user", 22, nil, second), entry("assistant", 23, 22, second)]
        try h.write(first, firstEntries)
        try h.write(second, secondEntries)
        try h.record("P", first, rehomeRecord(["title": "First undo source"]))
        try h.record("T", second, rehomeRecord(["title": "Second undo source"]))
        let states: Value = ["first": "active", "second": "active"]
        func makeCloud(_ account: String, _ org: String, _ key: String, _ remote: String, _ title: String, _ entries: Value) -> Value {
            cloudFixture(h, [
                "account": Value(account), "org": Value(org),
                "list": fn { _ in [remoteSession(["id": Value(remote), "title": Value(title), "status": states[key]])] },
                "eventRows": fn { _ in remoteRows(entries) },
                "session": fn { _ in remoteState(states[key].str, ["id": Value(remote)]) },
                "archive": fn { () in states[key] = "archived" },
                "unarchive": fn { () in states[key] = "active" },
            ])
        }
        let firstCloud = makeCloud(h.acct.P, h.org.P, "first", "cse_first_undo", "First undo source", firstEntries)
        let secondCloud = makeCloud(h.acct.T, h.org.T, "second", "cse_second_undo", "Second undo source", secondEntries)
        let all = try accounts(h.paths)
        let from: Value = [all.find { $0.account.str == h.acct.P && $0.org.str == h.org.P }, all.find { $0.account.str == h.acct.T && $0.org.str == h.org.T }]
        let to = all.find { $0.account.str == h.acct.Z && $0.org.str == h.org.Z }
        _ = try moveWithPending(h, from, to, firstCloud)
        _ = try finishPending(h.paths, ["cloud": secondCloud])
        deq(states, ["first": "archived", "second": "archived"])
        let staged = try undo(h.paths, ["cloud": firstCloud])
        deq(states, ["first": "active", "second": "archived"])
        deq(staged.pendingUndo, [from[1].email])
        eq(staged.dest, .undefined)
        ok(staged.receipt.cloudChecks.every { $0.status == "cancelled" || $0.status == "complete" })
        #expect(try readdir(h.dir("Z")).sorted() == ["local_\(first).json", "local_\(second).json"].sorted())
        let finished = try finishPending(h.paths, ["cloud": secondCloud])
        deq(states, ["first": "active", "second": "active"])
        ok(finished.dest)
        #expect(try readdir(h.dir("P")) == ["local_\(first).json"])
        #expect(try readdir(h.dir("T")) == ["local_\(second).json"])
        #expect(try readdir(h.dir("Z")) == [])
    }

    @Test("a verified target archives its source Remote Control mirror and Undo restores it")
    func verifiedTargetArchivesMirror() throws {
        let h = try home()
        let entries: Value = [entry("user", 1, nil, SOURCE), entry("assistant", 2, 1, SOURCE)]
        try h.write(SOURCE, Value([entry("user", 50, nil, SOURCE)]).concat(entries))
        try h.record("Z", SOURCE, rehomeRecord(["isArchived": true]))
        var status = "active", calls: [String] = []
        let remoteEntries = entries.map { row -> Value in
            let uuid = Int(String(row.uuid.str.suffix(12)))! + 100
            return ["type": row.type, "uuid": Value(id(uuid)), "session_id": "cse_fixture",
                    "message": row.type == "assistant" ? .spread(row.message, ["usage": ["output_tokens": 999], "stop_reason": nil]) : row.message]
        }
        let cloud = cloudFixture(h, [
            "list": fn { _ in [remoteSession(["id": "cse_fixture", "title": Value("Session \(SOURCE.suffix(3))"), "status": Value(status)])] },
            "eventRows": fn { _ in remoteRows(remoteEntries) },
            "session": fn { _ in remoteState(status, ["id": "cse_fixture"]) },
            "archive": fn { () in calls.append("archive"); status = "archived" },
            "unarchive": fn { () in calls.append("unarchive"); status = "active" },
        ])
        let all = try accounts(h.paths)
        let from = all.find { $0.account.str == h.acct.P && $0.org.str == h.org.P }
        let to = all.find { $0.account.str == h.acct.Z && $0.org.str == h.org.Z }
        let inv = try inventory([from], to, h.paths, NOOP, ["cloud": cloud])
        eq(inv.move.length, 0)
        eq(inv.cloud.matches.length, 1)
        eq(inv.cloud.blocked.length, 0)
        let result = try move(inv, to, h.paths)
        eq(result.ok, true, JSON.text(result.receipt.failed))
        #expect(calls == ["archive"])
        eq(result.receipt.remote.length, 1)
        eq(status, "archived")
        let targetFile = h.recordFile("Z", SOURCE)
        let activated = try readJSON(targetFile)
        eq(activated.isArchived, false)
        activated.lastFocusedAt = Value(dateNow())
        activated.promptAppendSnapshot = ["append": "current Desktop prompt", "cliVersion": "fixture"]
        try writeJSON(targetFile, activated)
        let undone = try undo(h.paths, ["cloud": cloud])
        ok(undone.dest)
        #expect(calls == ["archive", "unarchive"])
        eq(status, "active")
        let restored = try readJSON(targetFile)
        eq(restored.isArchived, true)
        deq(restored.promptAppendSnapshot, activated.promptAppendSnapshot)
    }

    @Test("attachment prompts and tiny ordering drift prove semantic Remote Control containment")
    func attachmentPromptsProveContainment() throws {
        let h = try home()
        let remote = Value((0..<100).map { index in entry(index % 2 == 1 ? "assistant" : "user", index + 100, index > 0 ? index + 99 : nil, SOURCE) })
        var local = remote.deepClone().elements
        let prompt = local[80].message.content
        local[80] = ["type": "attachment", "uuid": Value(id(800)), "sessionId": Value(SOURCE), "attachment": ["prompt": prompt]]
        local.swapAt(20, 21)
        try h.write(SOURCE, Value(local))
        try h.record("Z", SOURCE, rehomeRecord())
        let cloud = cloudFixture(h, [
            "list": fn { _ in [remoteSession(["id": "cse_equivalent", "title": Value("Session \(SOURCE.suffix(3))")])] },
            "eventRows": fn { _ in remoteRows(remote) },
            "session": fn { _ in remoteState("active") },
            "archive": NOOP, "unarchive": NOOP,
        ])
        let all = try accounts(h.paths)
        let from = all.find { $0.account.str == h.acct.P && $0.org.str == h.org.P }
        let to = all.find { $0.account.str == h.acct.Z && $0.org.str == h.org.Z }
        let inv = try inventory([from], to, h.paths, NOOP, ["cloud": cloud])
        eq(inv.cloud.matches.length, 1)
        eq(inv.cloud.matches[0].target.kind, "existing")
        eq(inv.cloud.matches[0].target.matchMode, "equivalent")
    }
}
