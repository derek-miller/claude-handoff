import Foundation
import Testing
@testable import HandoffCore

extension Engine.Cloud {
    static func reopenedDesktop() -> Value { [.spread(desktopFixture()[0], ["pid": 700, "desktopPid": 700, "started": "new"])] }

    @Test("connected Remote Control is waiting, not failed, and completes in the same receipt after disconnect")
    func connectedWaiting() throws {
        let h = try home()
        let entries: Value = [entry("user", 1, nil, SOURCE)]
        try h.write(SOURCE, entries)
        try h.record("P", SOURCE, ["bridgeSessionIds": ["session_live"]])
        var connected = true, status = "active", historyReads = 0
        let cloud = cloudFixture(h, [
            "list": fn { _ in [remoteSession(["id": "cse_live", "title": "Session 001", "status": Value(status)])] },
            "session": fn { _ in remoteState(status, ["connection_status": connected ? "connected" : "disconnected"]) },
            "eventRows": fn { _ in historyReads += 1; return remoteRows(entries) },
            "archive": fn { () in status = "archived" },
        ])
        let all = try accounts(h.paths), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
        let inv = try inventory([from], to, h.paths, NOOP, ["cloud": cloud, "processes": []])
        eq(inv.cloud.blocked.length, 0)
        eq(inv.cloud.waiting.length, 1)
        eq(inv.cloud.waiting[0].localId, Value(SOURCE))
        eq(inv.pendingCloud, 1)
        eq(historyReads, 0)
        let moved = try move(inv, to, h.paths)
        eq(moved.receipt.failed.length, 0)
        eq(moved.receipt.cloudChecks[0].status, "waiting")
        eq(moved.pendingCloud, 1)
        connected = false
        let finished = try finishPending(h.paths, ["cloud": cloud])
        eq(finished.file, moved.file)
        eq(finished.complete, true)
        eq(finished.receipt.failed.length, 0)
        eq(status, "archived")
    }

    @Test("Finish pending offers a receipt-bound restart for a connected mirror and completes after reopen")
    func finishOffersRestart() throws {
        let h = try home(), entries: Value = [entry("user", 1, nil, SOURCE)]
        try h.write(SOURCE, entries)
        try h.record("P", SOURCE, ["bridgeSessionIds": ["session_open"]])
        var connected = true, status = "active", rows = desktopFixture(), quits = 0
        let cloud = cloudFixture(h, [
            "list": fn { _ in [remoteSession(["id": "cse_open", "title": "Session 001", "status": Value(status)])] },
            "session": fn { _ in remoteState(status, ["connection_status": connected ? "connected" : "disconnected"]) },
            "eventRows": fn { _ in remoteRows(entries) },
            "archive": fn { () in status = "archived" },
        ])
        let all = try accounts(h.paths), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
        let moved = try move(try inventory([from], to, h.paths, NOOP, ["cloud": cloud, "processes": []]), to, h.paths)
        let io: Value = ["inspect": fn { _ in rows }, "command": fn { args in
            if args[0].str.hasSuffix("osascript") { quits += 1; rows = []; connected = false } else { rows = Engine.Cloud.reopenedDesktop() }
            return ["status": 0]
        }]
        let planned = try finishWorkflow(h.paths, ["cloud": cloud, "io": io])
        eq(planned.plan.kind, "finish")
        eq(planned.plan.receiptFile, moved.file)
        eq(quits, 0)
        let completed = try finishWorkflow(h.paths, ["cloud": cloud, "io": io, "approve": planned.plan.token])
        eq(completed.complete, true)
        eq(completed.file, moved.file)
        eq(completed.receipt.remote.length, 1)
        eq(completed.receipt.failed.length, 0)
        eq(quits, 1)
        let stale = try finishWorkflow(h.paths, ["cloud": cloud, "io": io, "approve": planned.plan.token])
        eq(stale.ok, false)
        eq(quits, 1)
    }

    @Test("mixed cloud Finish keeps its first pass preparatory until the restart decision")
    func mixedFinishPreparatory() throws {
        let h = try home(), other = id(300)
        let histories: [String: Value] = ["cse_ready": [entry("user", 1, nil, SOURCE)], "cse_open": [entry("user", 300, nil, other)]]
        var connected = ["cse_ready": true, "cse_open": true], status = ["cse_ready": "active", "cse_open": "active"]
        for (session, remote) in [(SOURCE, "ready"), (other, "open")] {
            try h.write(session, histories["cse_\(remote)"]!)
            try h.record("P", session, rehomeRecord(["bridgeSessionIds": [Value("session_\(remote)")]]))
        }
        let cloud = cloudFixture(h, [
            "list": fn { _ in Value(["cse_ready", "cse_open"].map { remoteSession(["id": Value($0), "title": Value($0), "status": Value(status[$0]!)]) }) },
            "session": fn { args in let id = args[0].str; return remoteState(status[id]!, ["connection_status": connected[id]! ? "connected" : "disconnected"]) },
            "eventRows": fn { args in remoteRows(histories[args[0].str]!) },
            "archive": fn { args in status[args[0].str] = "archived"; return .undefined },
        ])
        let all = try accounts(h.paths), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
        let moved = try move(try inventory([from], to, h.paths, NOOP, ["cloud": cloud, "processes": []]), to, h.paths)
        connected["cse_ready"] = false
        var rows = desktopFixture(other)
        let io: Value = ["inspect": fn { _ in rows }, "command": fn { args in
            if args[0].str.hasSuffix("osascript") { rows = []; connected["cse_open"] = false } else { rows = Engine.Cloud.reopenedDesktop() }
            return ["status": 0]
        }]
        let before = Box<[Value]>([]), after = Box<[Value]>([])
        let plan = try finishWorkflow(h.paths, ["cloud": cloud, "io": io, "report": Engine.Cloud.recorder(before)])
        eq(plan.plan.kind, "finish")
        eq(status["cse_ready"], "archived")
        eq(status["cse_open"], "active")
        ok(before.value.contains { $0.stage == "cloud" && $0.completed == 1 })
        ok(before.value.filter { $0.live.truthy }.allSatisfy { $0.preparatory == true })
        let completed = try finishWorkflow(h.paths, ["cloud": cloud, "io": io, "approve": plan.plan.token, "report": Engine.Cloud.recorder(after)])
        eq(completed.file, moved.file)
        eq(completed.complete, true)
        eq(completed.receipt.remote.length, 2)
        ok(after.value.contains { $0.stage == "reopen" })
        ok(after.value.filter { $0.live.truthy }.allSatisfy { !$0.preparatory.truthy })
    }

    @Test("a local move explicitly reports that no cloud phase remains")
    func noCloudPhase() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE, rehomeRecord())
        let all = try accounts(h.paths), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
        var cloud: [Value] = []
        let result = try move(try inventory([from], to, h.paths), to, h.paths, fn { args in
            if Engine.Cloud.arg(args, 0) == "cloud" { cloud.append(Engine.Cloud.arg(args, 2)) }
            return .undefined
        })
        eq(result.ok, true)
        deq(Value(cloud), [["live": true, "completed": 0, "total": 0]])
    }
}
