import Foundation
import Testing
@testable import HandoffCore

extension Engine.Cloud {
    @Test("an approved plan moves held records only after shutdown and keeps cloud calls outside its window")
    func approvedPlanKeepsCloudOutside() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE)
        let from = try h.account("P"), to = try h.account("T")
        var rows = desktopFixture(), time = 0.0, calls: [String] = []
        let io: Value = ["inspect": fn { _ in rows }, "now": fn { _ in Value(time) }, "shutdownWait": 400, "reserve": 200,
                         "wait": fn { args in time += args[0].asNumber!; return .undefined },
                         "command": fn { args in
                             calls.append(args[0].str)
                             rows = args[0].str.hasSuffix("osascript") ? [] : Engine.Restarts.reopened()
                             return ["status": 0]
                         }]
        let planned = try executeMove([from], to, h.paths, ["io": io, "cloudRequested": true, "cloud": cloudFixture(h)])
        ok(planned.plan.token)
        #expect(calls == [])
        ok(exists(h.recordFile("P", SOURCE)))
        eq(readOrNil(h.recordFile("T", SOURCE)), nil)
        let result = try executeMove([from], to, h.paths, ["io": io, "approve": planned.plan.token, "cloudRequested": true, "report": fn { args in
            if Self.arg(args, 0) == "move" { ok(calls.contains("/usr/bin/osascript")) }
            return .undefined
        }])
        eq(result.restarted, true)
        eq(result.receipt.sessions.length, 1)
        #expect(calls == ["/usr/bin/osascript", "/usr/bin/open"])
        eq(result.receipt.cloudChecks[0].status, "pending")
        eq(result.receipt.startedAt, planned.plan.requestedAt)
        eq(result.receipt.restart.outcome, "reopened")
    }

    @Test("undo refuses before removing the destination when a source recovery artifact is missing")
    func undoRefusesMissingArtifact() throws {
        let h = try home()
        try h.write(id(921), [entry("user", 921, nil, id(921))])
        try h.record("P", id(921))
        let by = Self.byAccount(try accounts(h.paths))
        let result = try move(try inventory([by[h.acct.P]], by[h.acct.Z], h.paths), by[h.acct.Z], h.paths)
        let pair = result.receipt.superseded.find { $0.source.truthy }.moved[0]
        let original = pair[0].str, parked = pair[1].str
        try unlink(parked)
        let refused = try undo(h.paths)
        match(refused.restoreProblems[0], "recovery artifact missing")
        ok(exists(result.receipt.sessions[0].record.str))
        deq(.strings(try readdir(h.dir("P"))), [])
        try writeText(original, "{broken")
        let corrupt = try undo(h.paths)
        match(corrupt.restoreProblems[0], "recovery artifact changed")
        ok(exists(result.receipt.sessions[0].record.str))
    }

    @Test("cloud bridges rehome while destination task ownership stays locked")
    func bridgesRehomeTaskLocked() throws {
        let h = try home()
        let base: Value = [entry("user", 922, nil, id(922))]
        try h.write(id(922), base.concat([entry("assistant", 923, 922, id(922)), ["type": "bridge-session", "sessionId": Value(id(922)), "bridgeSessionId": "remote"]]))
        try h.record("P", id(922), ["bridgeSessionIds": ["remote"]])
        try h.write(id(924), fork(base, id(922), id(924), "Owned"))
        try h.record("Z", id(924))
        try writeJSON(path.join(h.dir("Z"), "scheduled-tasks.json"), ["scheduledTasks": [["id": "task", "notifySessionId": Value("local_\(id(924))")]]])
        let by = Self.byAccount(try accounts(h.paths))
        let result = try move(try inventory([by[h.acct.P]], by[h.acct.Z], h.paths), by[h.acct.Z], h.paths)
        eq(result.ok, false)
        deq(result.receipt.failed.map { $0.error }, ["scheduled task registry kept in destination"])
        deq(try readJSON(result.receipt.sessions[0].record.str).bridgeSessionIds, [])
        deq(.strings(try readdir(h.dir("P"))), [])
        ok(try readdir(h.dir("Z")).contains("local_\(id(924)).json"))
    }

    @Test("interrupted retirement keeps its journal when a required artifact vanished")
    func interruptedRetirementKeepsJournal() throws {
        let h = try home()
        let at = "2099-01-01T00-00-00-000"
        let original = path.join(h.project, "missing.json")
        let parked = path.join(h.paths.state.str, "quarantine", at, "sources", "missing.json")
        let receipt: Value = ["at": Value(at), "from": [], "to": "x", "sessions": [], "failed": [], "superseded": [], "finalizing": true,
                              "retiring": [["id": "x", "title": "x", "by": "y", "required": [Value(original)], "moved": [[Value(original), Value(parked)]]]]]
        let file = path.join(h.paths.state.str, "\(at).json")
        try mkdirp(h.paths.state)
        try writeJSON(file, receipt)
        let result = try undo(h.paths)
        match(result.reconciled.error, "recovery artifact missing")
        let unresolved = try readJSON(file)
        ok(unresolved.retiring)
        eq(unresolved.finalizing, true)
    }

    @Test("cloud identity rejects a stale authenticated account even when both logins share the organization")
    func staleAuthenticatedAccount() throws {
        let h = try home()
        var requested: [String] = []
        mockFetch { url, _ in
            requested.append(url.path)
            if requested.last == "/api/account" { return response(["uuid": Value(h.acct.T)]) }
            return response([["uuid": Value(h.org.P)]])
        }
        throwsError("login is still updating") {
            try cloudClient(h.paths, nil, [
                "active": ["account": Value(h.acct.P), "org": Value(h.org.P), "state": "known"],
                "cookies": .newMap([("sessionKey", "fixture"), ("lastActiveOrg", Value(h.org.P))]),
                "userAgent": "fixture",
            ])
        }
        #expect(requested == ["/api/account"])
    }

    @Test("cloud identity retains verified cookie fallback for unknown Desktop state and rejects an explicit logout")
    func cookieFallback() throws {
        let h = try home()
        var requested: [String] = []
        mockFetch { url, _ in
            requested.append(url.path)
            return response(requested.last == "/api/account" ? ["uuid": Value(h.acct.P)] : [["uuid": Value(h.org.P)], ["uuid": Value(h.org.T)]])
        }
        let io: Value = ["active": ["state": "unknown", "account": nil, "org": nil], "cookies": .newMap([("sessionKey", "fixture"), ("lastActiveOrg", Value(h.org.P))]), "userAgent": "fixture"]
        eq(try cloudClient(h.paths, nil, io).org, Value(h.org.P))
        eq(try cloudClient(h.paths, ["account": Value(h.acct.P), "org": Value(h.org.T), "label": "Team"], io).org, Value(h.org.T))
        requested = []
        throwsError("signed out") { try cloudClient(h.paths, nil, .spread(io, ["active": ["state": "logged-out"]])) }
        #expect(requested == [])
        throwsError("sign Claude Desktop into Other login") { try cloudClient(h.paths, ["account": Value(h.acct.T), "org": Value(h.org.T), "label": "Other login"], io) }
        #expect(requested == ["/api/account"])
    }

    @Test("cloud history reads past 10000 events and refuses incomplete or oversized pagination",
          arguments: ["large", "full last page", "exact event limit", "repeated cursor", "repeated sequence", "oversized page", "event limit", "memory pressure"])
    func historyPagination(scenario: String) throws {
        let h = try home(), limit = scenario == "exact event limit" ? 1_000_000 : scenario == "full last page" ? 10000 : 10501
        var pages = 0
        mockFetch { url, _ in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let param = { (name: String) in items.first { $0.name == name }?.value }
            if url.path == "/api/account" { return response(["uuid": Value(h.acct.P)]) }
            if url.path == "/api/organizations" { return response([["uuid": Value(h.org.P)]]) }
            eq(url.path, "/v1/code/sessions/session_large/events")
            eq(param("limit"), "500")
            eq(param("sort_order"), "asc")
            let start = pages * 500
            pages += 1
            if pages > 1 { eq(param("cursor"), scenario == "repeated cursor" ? "same" : String(start)) }
            let length = scenario == "oversized page" ? 501 : scenario == "event limit" || scenario == "memory pressure" ? 500 : min(500, limit - start)
            let payload: Value = scenario == "memory pressure" ? ["content": Value(String(repeating: "x", count: 2000))] : [:]
            let data = Value((0..<length).map { i -> Value in ["event_type": "user", "sequence_num": Value(scenario == "repeated sequence" ? i : start + i), "payload": payload] })
            return response(["data": data, "resume_cursor": Value(scenario == "repeated cursor" ? "same" : String(start + length))], headers: ["anthropic-organization-id": Value(h.org.P)])
        }
        let memory: Value = scenario == "memory pressure"
            ? try memoryBudget(["total": Value(10 * 1024 * 1024), "heap": Value(GiB), "usage": fn { _ in ["rss": 0, "heapUsed": 0] }, "available": fn { _ in Value(GiB) }])
            : .undefined
        let cloud = try cloudClient(h.paths, nil, ["active": ["state": "known", "account": Value(h.acct.P), "org": Value(h.org.P)], "cookies": .newMap([("sessionKey", "fixture")]), "userAgent": "fixture", "memory": memory])
        let errors = ["repeated cursor": "cursor did not advance", "repeated sequence": "sequence changed", "oversized page": "response changed", "event limit": "exceeded 1,000,000 events", "memory pressure": "memory budget"]
        if let error = errors[scenario] {
            throwsError(error) { try cloud.eventRows.call("cse_large") }
        } else {
            let rows = try cloud.eventRows.call("cse_large")
            eq(rows.length, limit)
            eq(rows.at(-1).sequence_num, Value(limit - 1))
            eq(pages, limit / 500 + 1)
        }
        if scenario == "event limit" { eq(pages, 2001) }
        if scenario == "memory pressure" || scenario == "oversized page" { eq(pages, 1) }
    }

    @Test("operation memory scales to RAM and reduces concurrency before its ceiling")
    func operationMemoryScales() throws {
        for gib in [16.0, 48.0] {
            var rss = 0.0, heapUsed = 0.0, available = 8 * GiB
            let budget = try memoryBudget(["platform": "linux", "total": Value(gib * GiB), "heap": Value(4 * GiB),
                                           "usage": fn { _ in ["rss": Value(rss), "heapUsed": Value(heapUsed)] }, "available": fn { _ in Value(available) }])
            eq(budget.limit, Value((gib * GiB * 0.2).rounded(.down)))
            eq(try budget.parallel.call(), 8)
            rss = budget.limit.asNumber! * 0.6
            eq(try budget.parallel.call(), 2)
            rss = budget.limit.asNumber! * 0.8
            eq(try budget.parallel.call(), 1)
            rss = budget.limit.asNumber!
            throwsError(where: ["code": "CLOUD_MEMORY_BUDGET"]) { try budget.check.call() }
            rss = 0; heapUsed = 4 * GiB
            throwsError(where: ["code": "CLOUD_MEMORY_BUDGET"]) { try budget.check.call() }
            heapUsed = 0; available = 0
            throwsError(where: ["code": "CLOUD_MEMORY_PRESSURE"]) { try budget.check.call() }
            available = GiB
            #expect(throws: Never.self) { try budget.check.call() }
        }
    }

    // Node paused an async body mid-read and started a second read. The Swift budget reads a whole body at
    // once, but checks usage before each chunk: the second read runs from that check, while the first
    // read holds the reservation for its first chunk.
    @Test("concurrent cloud bodies share reservations and return them after refusal")
    func concurrentBodiesShareReservations() throws {
        var usageCalls = 0
        var budget: Value = .undefined
        var concurrent: Value = .undefined
        budget = try memoryBudget(["total": 10000, "heap": 10000, "available": fn { _ in 10000 }, "usage": fn { _ in
            usageCalls += 1
            // Calls 1 and 2 check the first read before its first chunk is reserved; call 3 comes after.
            if usageCalls == 3 { concurrent = throwsError(where: ["code": "CLOUD_MEMORY_BUDGET"]) { try budget.read.call(Self.json(Value(String(repeating: "x", count: 300)))) } }
            return ["rss": 0, "heapUsed": 0]
        }])
        let first = try budget.read.call(["body": [Value(Data(("\"" + String(repeating: "x", count: 150)).utf8)), Value(Data("\"".utf8))]])
        ok(!concurrent.isUndefined, "the second read never ran while the first held its reservation")
        eq(first, Value(String(repeating: "x", count: 150)))
        eq(try budget.read.call(Self.json(Value(String(repeating: "x", count: 300)))), Value(String(repeating: "x", count: 300)))
        throwsError(where: ["name": "SyntaxError"]) { try budget.read.call(["body": [Value(Data("{bad".utf8))]]) }
        deq(try budget.read.call(Self.json(["recovered": true])), ["recovered": true])
    }

    @Test("memory pressure during final cloud proof keeps its source active until a complete retry")
    func memoryPressureFinalProof() throws {
        let h = try home(), entries = branchEntries(4, SOURCE, 1)
        try h.write(SOURCE, entries)
        try h.record("P", SOURCE, rehomeRecord(["title": "Memory history", "bridgeSessionIds": ["session_memory"]]))
        var pressure = false, reads = 0, status = "active"
        let memory = try memoryBudget(["platform": "darwin", "total": Value(16 * GiB), "heap": Value(4 * GiB), "usage": fn { _ in ["rss": 0, "heapUsed": 0] },
                                       "pressure": fn { _ in pressure ? 4 : 1 }, "now": fn { _ in pressure ? 2000 : 0 }])
        let cloud = cloudFixture(h, ["memory": memory, "list": fn { _ in [remoteSession(["id": "cse_memory", "title": "Memory history", "status": Value(status)])] },
                                     "session": fn { _ in remoteState(status) }, "archive": fn { () in status = "archived" },
                                     "eventRows": fn { _ in
                                         reads += 1
                                         if reads == 2 { pressure = true }
                                         return try memory.read.call(Self.json(remoteRows(entries)))
                                     }])
        let all = try accounts(h.paths, []), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.Z }
        let result = try move(try inventory([from], to, h.paths, NOOP, ["cloud": cloud, "processes": []]), to, h.paths)
        eq(result.receipt.sessions.length, 1)
        eq(result.receipt.remote.length, 0)
        eq(result.receipt.failed[0].code, "CLOUD_MEMORY_PRESSURE")
        eq(status, "active")
        pressure = false
        let retried = try finishPending(h.paths, ["cloud": cloud, "active": ["state": "known", "account": Value(h.acct.P), "org": Value(h.org.P)], "processes": []])
        eq(retried.complete, true)
        eq(retried.ok, true)
        eq(status, "archived")
    }
}

private let GiB = 1_073_741_824.0
