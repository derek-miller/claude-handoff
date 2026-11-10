import Foundation
import Testing
@testable import HandoffCore

extension Engine.Restarts {
    // A callback argument, undefined when the engine passes fewer, as in JS.
    static func arg(_ args: [Value], _ i: Int) -> Value { i < args.count ? args[i] : .undefined }

    // all.find(row => row.account === h.acct[a]) for the source and target accounts.
    static func pair(_ h: Home, _ a: String = "P", _ b: String = "T", _ processes: Value = .undefined) throws -> (from: Value, to: Value) {
        let all = try accounts(h.paths, processes)
        return (all.find { $0.account.str == h.acct[a] }, all.find { $0.account.str == h.acct[b] })
    }

    // A source session and an unrelated cold session in P.
    static func sourceAndCold(_ h: Home, _ cold: String = id(300)) throws {
        for session in [SOURCE, cold] {
            try h.write(session, [entry("user", session == SOURCE ? 1 : 300, nil, session)])
            try h.record("P", session)
        }
    }

    @Test("wrong, modified, and malformed restart approvals never quit Desktop")
    func wrongApprovals() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE)
        let (from, to) = try Self.pair(h)
        var calls: [String] = []
        let io: Value = ["inspect": fn { _ in desktopFixture() }, "command": fn { args in calls.append(args[0].str); return ["status": 0] }]
        let planned = try executeMove([from], to, h.paths, ["io": io])
        eq(try executeMove([from], to, h.paths, ["io": io, "approve": Value(String(repeating: "0", count: 64))]).ok, false)
        let file = path.join(h.paths.state.str, "restart-plan.json"), changed = try readJSON(file)
        changed.held = []
        try writeJSON(file, changed)
        eq(try executeMove([from], to, h.paths, ["io": io, "approve": planned.plan.token]).ok, false)
        #expect(calls == [])
        let malformed = cli(h.root, ["restart", "--restart-approved", "invalid", "--json"])
        eq(malformed.code, 1)
        match(malformed.stderr, "approval token")
        ok(exists(h.recordFile("P", SOURCE)))
    }

    @Test("failed source authentication stays pending after an approved restart")
    func failedSourceAuthentication() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE)
        let (from, to) = try Self.pair(h)
        var rows = desktopFixture()
        let io: Value = ["inspect": fn { _ in rows }, "command": fn { args in
            rows = args[0].str.hasSuffix("osascript") ? [] : Self.reopened()
            return ["status": 0]
        }]
        let planned = try executeMove([from], to, h.paths, ["io": io, "cloudRequested": true, "cloudError": "authentication unavailable"])
        let result = try executeMove([from], to, h.paths, ["io": io, "cloudRequested": true, "approve": planned.plan.token])
        eq(result.receipt.cloudChecks[0].account, from.account)
        eq(result.receipt.cloudChecks[0].status, "pending")
        eq(result.complete, false)
    }

    @Test("held continuation shares one receipt and Undo restores both phases")
    func heldContinuationSharesReceipt() throws {
        let h = try home(), cold = id(300)
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.write(cold, [entry("user", 300, nil, cold)])
        try h.record("P", SOURCE)
        try h.record("P", cold)
        let (from, to) = try Self.pair(h)
        var rows = desktopFixture()
        let first = try executeMove([from], to, h.paths, ["processes": rows, "moveOnly": true])
        eq(first.ok, true)
        eq(first.receipt.sessions.length, 1)
        eq(first.receipt.sessions[0].id, Value(cold))
        eq(first.receipt.held.length, 1)
        eq(first.complete, false)
        rows = []
        let finished = try finishHeld(h.paths, ["processes": rows])
        eq(finished.file, first.file)
        eq(finished.receipt.sessions.length, 2)
        eq(finished.receipt.held.length, 0)
        eq(finished.ok, true)
        let result = try undo(h.paths)
        ok(result.dest)
        #expect(try readdir(h.dir("P")).sorted() == ["local_\(SOURCE).json", "local_\(cold).json"].sorted())
        #expect(try readdir(h.dir("T")) == [])
    }

    @Test("a stale held continuation cannot start a new move after Undo")
    func staleHeldContinuation() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE)
        let (from, to) = try Self.pair(h)
        let first = try executeMove([from], to, h.paths, ["processes": desktopFixture(), "moveOnly": true])
        _ = try undo(h.paths)
        let stale = try executeMove([from], to, h.paths, ["processes": [], "resume": true, "resumeFile": first.file])
        eq(stale.ok, false)
        match(stale.reason, "pending move changed")
        ok(exists(h.recordFile("P", SOURCE)))
        #expect(try readdir(h.dir("T")) == [])
    }

    @Test("held parents retain workerless children in the same continuation")
    func heldParentsRetainChildren() throws {
        let h = try home(), child = id(701)
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE)
        try h.write(child, [entry("user", 701, nil, child)])
        try h.record("P", child, ["forkedFromSessionId": Value("local_\(SOURCE)")])
        let (from, to) = try Self.pair(h)
        let first = try executeMove([from], to, h.paths, ["processes": desktopFixture(), "moveOnly": true])
        deq(first.receipt.held.map { $0.id }, [Value(SOURCE), Value(child)])
        let finished = try finishHeld(h.paths, ["processes": []])
        eq(finished.ok, true)
        deq(finished.receipt.sessions.map { $0.id }, [Value(SOURCE), Value(child)])
        #expect(try readdir(h.dir("P")) == [])
    }

    @Test("completed cold records may grow before the held phase finishes")
    func coldRecordsMayGrow() throws {
        let h = try home(), cold = id(300)
        try Self.sourceAndCold(h, cold)
        let (from, to) = try Self.pair(h)
        let first = try executeMove([from], to, h.paths, ["processes": desktopFixture(), "moveOnly": true])
        let row = first.receipt.sessions[0]
        let record = try readJSON(row.record.str)
        try writeJSON(row.record.str, .spread(record, ["lastFocusedAt": 1000, "completedTurns": 2, "bridgeSessionIds": ["session_new"]]))
        try appendText(row.targetTranscript.str, JSON.text(entry("assistant", 301, 300, cold)) + "\n")
        let result = try finishHeld(h.paths, ["processes": []])
        eq(result.ok, true)
        eq(result.receipt.sessions.length, 2)
    }

    @Test("a successful held phase cannot hide an earlier placement verification failure")
    func heldPhaseKeepsVerificationFailure() throws {
        let h = try home(), cold = id(300)
        try Self.sourceAndCold(h, cold)
        let (from, to) = try Self.pair(h)
        let link = fs.link
        touchPlaced(h.recordFile("T", cold))
        let first = try executeMove([from], to, h.paths, ["processes": desktopFixture(), "moveOnly": true])
        fs.link = link
        deq(first.receipt.sessions, [])
        match(first.summary.notMoved.find { $0.id.str == cold }.error, "desktop changed during the move")
        let result = try finishHeld(h.paths, ["processes": []])
        deq(result.receipt.sessions.map { $0.id }, [Value(SOURCE)])
        ok(result.summary.notMoved.some { $0.id.str == cold })
    }

    @Test("Keep local reports earlier verification failure while cancelling held work")
    func keepLocalReportsVerificationFailure() throws {
        let h = try home(), cold = id(300)
        try Self.sourceAndCold(h, cold)
        let (from, to) = try Self.pair(h)
        let link = fs.link
        touchPlaced(h.recordFile("T", cold))
        _ = try executeMove([from], to, h.paths, ["processes": desktopFixture(), "moveOnly": true])
        fs.link = link
        let kept = try keepLocal(h.paths)
        eq(kept.heldCancelled, 1)
        ok(kept.notMoved.some { $0.id.str == cold })
        deq(kept.receipt.held, [])
    }

    @Test("Keep local can abandon held work without undoing completed cold moves")
    func keepLocalAbandonsHeldWork() throws {
        let h = try home(), cold = id(300)
        try Self.sourceAndCold(h, cold)
        let (from, to) = try Self.pair(h)
        let first = try executeMove([from], to, h.paths, ["processes": desktopFixture(), "moveOnly": true])
        let kept = try keepLocal(h.paths)
        eq(kept.file, first.file)
        eq(kept.heldCancelled, 1)
        deq(kept.receipt.held, [])
        ok(exists(h.recordFile("T", cold)))
        ok(exists(h.recordFile("P", SOURCE)))
    }

    @Test("automatic retries never request a restart and leave held workers alone")
    func automaticRetriesNeverRestart() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE)
        let (from, to) = try Self.pair(h)
        let rows = desktopFixture()
        let partial = try executeMove([from], to, h.paths, ["processes": rows, "moveOnly": true])
        eq(partial.receipt.held.length, 1)
        let checked = try sweep(h.paths, ["processes": rows])
        eq(checked.result.pendingLocal, true)
        eq(readOrNil(path.join(h.paths.state.str, "restart-plan.json")), nil)
        ok(exists(h.recordFile("P", SOURCE)))
    }
}
