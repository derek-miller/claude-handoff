import Darwin
import Foundation
import Testing
@testable import HandoffCore

extension Engine.Cloud {
    static let gib = 1024.0 * 1024 * 1024

    static func presentation(_ receipt: Value, _ check: Value) throws -> Value {
        try pendingPresentation(receipt, check, ["signedIn": true], "cloud")
    }

    // A clock the engine reads through process.now, starting at the real time.
    final class Clock {
        var now = dateNow()
        init() { process.now = { [unowned self] in self.now } }
    }

    @Test("Darwin pressure uses dispatch flags and samples at a bounded cadence without capping healthy free pages")
    func darwinPressureCadence() throws {
        var now = 0.0, probes = 0
        var level: Value = 1
        let budget = try memoryBudget(["platform": "darwin", "total": Value(48 * Self.gib), "heap": Value(8 * Self.gib),
                                       "usage": fn { _ in ["rss": Value(Self.gib), "heapUsed": Value(Self.gib)] },
                                       "available": fn { _ in Value(2.4 * Self.gib) }, "now": fn { _ in Value(now) },
                                       "pressure": fn { _ in probes += 1; return level }])
        for _ in 0..<100 {
            try budget.check.call(Value(3 * Self.gib))
            eq(try budget.parallel.call(), 8)
        }
        eq(probes, 1)
        level = 4; now = 999
        try budget.check.call(Value(3 * Self.gib))
        now = 1000
        throwsError(where: ["code": "CLOUD_MEMORY_PRESSURE"]) { try budget.check.call() }
        eq(probes, 2)
        level = 2; now = 2000
        try budget.check.call(Value(3 * Self.gib))
        eq(try budget.parallel.call(), 1)
        let invalid: [Value] = [.null, 0, 3, "1", .number(.nan)]
        for value in invalid {
            level = value; now += 1000
            eq(try budget.parallel.call(), 1, show(value))
            throwsError(where: ["code": "CLOUD_MEMORY_PRESSURE"]) { try budget.check.call(Value(3 * Self.gib)) }
            try budget.check.call(1024)
        }
        level = 1; now += 1000
        eq(try budget.parallel.call(), 8)
    }

    @Test("Darwin pressure probes the read-only sysctl and falls back conservatively when unavailable")
    func darwinPressureSysctl() throws {
        var raw: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let live: Value = sysctlbyname("kern.memorystatus_vm_pressure_level", &raw, &size, nil, 0) == 0 && [1, 2, 4].contains(raw) ? Value(Int(raw)) : .null
        var now = 0.0
        let io: Value = ["platform": "darwin", "total": Value(16 * Self.gib), "heap": Value(4 * Self.gib),
                         "usage": fn { _ in ["rss": 0, "heapUsed": 0] }, "available": fn { _ in 0 }, "now": fn { _ in Value(now) }]
        let probed = try memoryBudget(io)
        if live == 4 || live.isNull {
            throwsError(where: ["code": "CLOUD_MEMORY_PRESSURE"]) { try probed.check.call(1024) }
        } else {
            try probed.check.call(1024)
        }
        eq(try probed.parallel.call(), live == 1 ? 8 : 1, "live pressure level \(show(live))")

        var calls = 0, unavailable = false
        let fallback = try memoryBudget(.spread(io, ["pressure": fn { _ in
            calls += 1
            if unavailable { throw EngineError("sysctl unavailable") }
            return 2
        }]))
        try fallback.check.call(1024)
        eq(try fallback.parallel.call(), 1)
        eq(calls, 1)
        unavailable = true; now = 1000
        throwsError(where: ["code": "CLOUD_MEMORY_PRESSURE"]) { try fallback.check.call() }
        eq(calls, 2)
    }

    @Test("pressure and deterministic parser failures release shared parsing reservations")
    func pressureReleasesReservations() throws {
        var now = 0.0, usageCalls = 0
        var level: Value = 1
        var during: () throws -> Void = {}
        var budget: Value = .undefined
        budget = try memoryBudget(["platform": "darwin", "total": 10000, "heap": 10000, "available": fn { _ in 0 }, "now": fn { _ in Value(now) },
                                   "pressure": fn { _ in level },
                                   "usage": fn { _ in
                                       usageCalls += 1
                                       // The third probe of a read checks its second chunk, after the first is reserved.
                                       if usageCalls == 3 { try during() }
                                       return ["rss": 0, "heapUsed": 0]
                                   }])
        var refused: Value = .undefined
        during = {
            level = 4; now = 1000
            refused = throwsError(where: ["code": "CLOUD_MEMORY_PRESSURE"]) { try budget.read.call(Engine.Cloud.json("x")) }
            level = 1; now = 2000
        }
        let first = try budget.read.call(["body": [Value(Data(("\"" + String(repeating: "x", count: 150)).utf8)), Value(Data("\"".utf8))]])
        ok(!refused.isUndefined, "the second read never ran while the first held its reservation")
        eq(first, Value(String(repeating: "x", count: 150)))
        usageCalls = 0
        during = { throw EngineError(Value.spread(errorObject(EngineError.range("synthetic string limit")), ["code": "ERR_STRING_TOO_LONG"])) }
        throwsError(where: ["code": "CLOUD_PARSER_LIMIT"]) {
            try budget.read.call(["body": [Value(Data(("\"" + String(repeating: "x", count: 150)).utf8)), Value(Data("\"".utf8))]])
        }
        during = {}
        eq(try budget.read.call(Engine.Cloud.json(Value(String(repeating: "x", count: 300)))), Value(String(repeating: "x", count: 300)))
    }

    @Test("event-limited mirrors stay excluded while connected work clears and keep their failure afterward")
    func eventLimitedExcluded() throws {
        let f = try limitRetryFixture(["event", "connected"]), clock = Clock()
        let first = try finishPending(f.h.paths, f.options), source = first.receipt.cloudChecks[0]
        eq(source.waiting.length, 1)
        eq(try Self.presentation(first.receipt, source).pendingAutomatic, true)
        eq(f.rows[0].reads, 1)
        eq(f.rows[1].reads, 0)
        clock.now += 60000
        let stillWaiting = try finishPending(f.h.paths, f.options)
        eq(stillWaiting.receipt.failed[0].code, "CLOUD_HISTORY_LIMIT")
        eq(f.rows[0].reads, 1)
        f.rows[1].mode = "ok"; clock.now += 60000
        let cleared = try finishPending(f.h.paths, f.options)
        eq(f.rows[1].status, "archived")
        eq(f.rows[0].reads, 1)
        eq(cleared.complete, false)
        eq(cleared.receipt.failed.length, 1)
        eq(cleared.receipt.cloudChecks[0].failures[0].code, "CLOUD_HISTORY_LIMIT")
        eq(try Self.presentation(cleared.receipt, cleared.receipt.cloudChecks[0]).pendingState, "limit")
        clock.now += 120000
        eq(try finishPending(f.h.paths, f.options).pending, true)
        eq(f.rows[0].reads, 1)
        f.rows[0].mode = "ok"
        let manual = try finishPending(f.h.paths, .spread(f.options, ["automatic": false]))
        eq(manual.complete, true)
        eq(manual.receipt.failed.length, 0)
    }

    @Test("operation budget failures get one shared-budget serial retry that clears state on success")
    func budgetSerialRetry() throws {
        let f = try limitRetryFixture(["budget", "budget"]), clock = Clock()
        let first = try finishPending(f.h.paths, f.options)
        eq(first.receipt.failed.length, 2)
        ok(first.receipt.failed.every { $0.code == "CLOUD_MEMORY_BUDGET" })
        eq(f.peak, 2)
        for row in f.rows { row.mode = "ok" }
        f.resetPeak()
        clock.now += 60000
        let retried = try finishPending(f.h.paths, f.options)
        eq(f.peak, 1)
        eq(retried.complete, false)
        eq(retried.receipt.failed.length, 0)
        eq(retried.receipt.cloudChecks[0].failures, .undefined)
        eq(retried.receipt.cloudChecks[0].attemptBudget, f.memory.signature)
        eq(retried.receipt.cloudChecks[0].waiting.length, 1)
        clock.now += 60000
        let completed = try finishPending(f.h.paths, f.options)
        eq(completed.complete, true)
        eq(completed.receipt.failed.length, 0)
        eq(completed.receipt.cloudChecks[0].waiting.length, 0)
        eq(f.peak, 1)
        ok(f.rows.allSatisfy { $0.status == "archived" })
    }

    @Test("serial budget limits pause unchanged work but manual, engine and budget changes permit another attempt")
    func serialBudgetLimits() throws {
        let clock = Clock()
        for reset in ["manual", "engine", "budget"] {
            let f = try limitRetryFixture(["budget"])
            _ = try finishPending(f.h.paths, f.options)
            clock.now += 60000
            let limited = try finishPending(f.h.paths, f.options)
            eq(limited.receipt.failed[0].code, "CLOUD_BUDGET_LIMIT", reset)
            let presentation = try Self.presentation(limited.receipt, limited.receipt.cloudChecks[0])
            eq(presentation.pendingState, "budget-limit")
            eq(presentation.pendingAction, "blocked")
            eq(presentation.pendingAutomatic, false)
            let reads = f.rows[0].reads
            clock.now += 120000
            eq(try finishPending(f.h.paths, f.options).pending, true)
            eq(f.rows[0].reads, reads)
            f.rows[0].mode = "ok"
            if reset == "engine" {
                limited.receipt.cloudChecks[0].attemptEngine = "synthetic-previous-engine"
                try writeJSON(f.moved.file.str, limited.receipt)
            }
            if reset == "budget" { f.memory.signature = Value(f.memory.signature.str + ":increased") }
            let recovered = try finishPending(f.h.paths, .spread(f.options, ["automatic": Value(reset != "manual")]))
            eq(recovered.complete, true, reset)
            eq(recovered.receipt.failed.length, 0, reset)
            ok(f.rows[0].reads > reads, reset)
        }
    }

    @Test("transient pressure recovers while deterministic parser limits remain scoped to their mirror")
    func transientPressureRecovers() throws {
        let clock = Clock()
        let f = try limitRetryFixture(["parser", "pressure"])
        let first = try finishPending(f.h.paths, f.options)
        deq(first.receipt.failed.map { $0.code }.sorted(), ["CLOUD_MEMORY_PRESSURE", "CLOUD_PARSER_LIMIT"])
        let parserReads = f.rows[0].reads
        clock.now += 60000
        f.rows[1].mode = "ok"
        let recovered = try finishPending(f.h.paths, f.options)
        eq(f.rows[0].reads, parserReads)
        eq(f.rows[1].status, "archived")
        eq(recovered.receipt.failed.length, 1)
        eq(recovered.receipt.failed[0].code, "CLOUD_PARSER_LIMIT")
        eq(try Self.presentation(recovered.receipt, recovered.receipt.cloudChecks[0]).pendingState, "parser-limit")
        clock.now += 120000
        eq(try finishPending(f.h.paths, f.options).pending, true)
        eq(f.rows[0].reads, parserReads)
    }

    @Test("limited budget work does not starve other source organizations or revive cancelled checks")
    func limitedBudgetFairOrganizations() throws {
        let f = try pendingOrganizations(orgs: ["P", "T", "Q"])
        let clock = Clock()
        var failures = 0
        let receipt = try readJSON(f.moved.file.str)
        receipt.cloudChecks[2].status = "cancelled"
        try writeJSON(f.moved.file.str, receipt)
        let options = Value.spread(f.options, ["cloud": fn { args in
            if args[0].org.str == f.rows[0].org {
                failures += 1
                throw makeError("Synthetic budget exhausted", code: "CLOUD_MEMORY_BUDGET")
            }
            return try f.client.call(args[0])
        }])
        _ = try sweep(f.h.paths, options)
        let other = try sweep(f.h.paths, options)
        eq(other.result.receipt.remote[0].org, Value(f.rows[1].org))
        eq(f.rows[1].status, "archived")
        clock.now += 60000
        let limited = try sweep(f.h.paths, options)
        eq(limited.result.receipt.failed[0].code, "CLOUD_BUDGET_LIMIT")
        clock.now += 120000
        eq(try sweep(f.h.paths, options).pending, true)
        eq(failures, 2)
        eq(try readJSON(f.moved.file.str).cloudChecks[2].status, "cancelled")
        eq(f.rows[2].status, "active")
    }

    @Test("a serial budget limit stays excluded while a connected mirror clears")
    func serialLimitWhileConnectedClears() throws {
        let f = try limitRetryFixture(["budget", "connected"]), clock = Clock()
        _ = try finishPending(f.h.paths, f.options)
        clock.now += 60000
        let limited = try finishPending(f.h.paths, f.options)
        eq(limited.receipt.failed[0].code, "CLOUD_BUDGET_LIMIT")
        eq(limited.receipt.cloudChecks[0].waiting.length, 1)
        eq(try Self.presentation(limited.receipt, limited.receipt.cloudChecks[0]).pendingAutomatic, true)
        let reads = f.rows[0].reads
        f.rows[1].mode = "ok"; clock.now += 60000
        let cleared = try finishPending(f.h.paths, f.options)
        eq(f.rows[0].reads, reads)
        eq(f.rows[1].status, "archived")
        eq(cleared.receipt.failed[0].code, "CLOUD_BUDGET_LIMIT")
        eq(cleared.receipt.cloudChecks[0].waiting.length, 0)
        eq(cleared.complete, false)
        clock.now += 120000
        eq(try finishPending(f.h.paths, f.options).pending, true)
        eq(f.rows[0].reads, reads)
    }

    @Test("budget fairness isolates a previously failed history through archival while another mirror becomes idle")
    func fairnessIsolatesFailedHistory() throws {
        let f = try limitRetryFixture(["connected", "budget"]), clock = Clock()
        var competingHistory = false, retrying = false
        let read = f.cloud.eventRows
        var trace: [String] = []
        f.cloud.eventRows = fn { args in
            let id = args[0].str
            trace.append(id)
            if retrying && id == f.rows[0].id { competingHistory = true }
            if retrying && id == f.rows[1].id && competingHistory { throw makeError("Synthetic earlier history used this operation budget", code: "CLOUD_MEMORY_BUDGET") }
            return try read.call(args[0])
        }
        let first = try finishPending(f.h.paths, f.options), scope = first.receipt.cloudChecks[0].sessionIds
        eq(first.receipt.cloudChecks[0].waiting[0].id, Value(f.rows[0].id))
        eq(first.receipt.failed[0].id, Value(f.rows[1].id))
        for row in f.rows { row.mode = "ok" }
        retrying = true; trace = []; clock.now += 60000
        let second = try finishPending(f.h.paths, f.options)
        eq(f.rows[1].status, "archived", JSON.text(second.receipt.failed))
        ok(trace.allSatisfy { $0 == f.rows[1].id }, "the selected history must keep the pass through its final rechecks")
        eq(second.complete, false)
        eq(second.receipt.cloudChecks[0].waiting[0].id, Value(f.rows[0].id))
        deq(second.receipt.cloudChecks[0].sessionIds, scope)
        competingHistory = false; clock.now += 60000
        let third = try finishPending(f.h.paths, f.options)
        eq(third.complete, true)
        ok(f.rows.allSatisfy { $0.status == "archived" })
        eq(third.receipt.failed.length, 0)
    }

    @Test("budget fairness stops an oversized history while a second initial budget failure gets a fresh pass")
    func fairnessStopsOversized() throws {
        let f = try limitRetryFixture(["budget", "budget"]), clock = Clock()
        var spent = false, retrying = false
        let read = f.cloud.eventRows
        f.cloud.eventRows = fn { args in
            let id = args[0].str
            if retrying && id == f.rows[0].id { spent = true }
            if retrying && id == f.rows[1].id && spent { throw makeError("Synthetic budget was already consumed", code: "CLOUD_MEMORY_BUDGET") }
            return try read.call(args[0])
        }
        _ = try finishPending(f.h.paths, f.options)
        retrying = true; f.rows[1].mode = "ok"; clock.now += 60000
        let second = try finishPending(f.h.paths, f.options)
        deq(second.receipt.failed.map { [$0.id, $0.code] }, [[Value(f.rows[0].id), "CLOUD_BUDGET_LIMIT"]])
        eq(second.receipt.cloudChecks[0].waiting[0].id, Value(f.rows[1].id))
        let oversizedReads = f.rows[0].reads
        spent = false; clock.now += 60000
        let third = try finishPending(f.h.paths, f.options)
        eq(f.rows[1].status, "archived")
        eq(f.rows[0].reads, oversizedReads)
        eq(third.complete, false)
        deq(third.receipt.failed.map { [$0.id, $0.code] }, [[Value(f.rows[0].id), "CLOUD_BUDGET_LIMIT"]])
        clock.now += 120000
        eq(try finishPending(f.h.paths, f.options).pending, true)
        eq(f.rows[0].reads, oversizedReads)
    }

    @Test("budget fairness discovers remaining work without narrowing scope or dropping permanent failures")
    func fairnessDiscoversRemaining() throws {
        let f = try limitRetryFixture(["event", "parser", "budget", "budget", "connected"])
        let receipt = try readJSON(f.moved.file.str)
        receipt.cloudChecks[0].removeKey("sessionIds")
        try writeJSON(f.moved.file.str, receipt)
        let clock = Clock()
        let first = try finishPending(f.h.paths, f.options)
        eq(first.receipt.cloudChecks[0].sessionIds, .undefined)
        let extra = LimitRow(mode: "ok", id: "cse_discovered", sid: id(8799), title: "Discovered synthetic history", entries: branchEntries(4, id(8799), 8990))
        f.rows.append(extra)
        try f.h.write(extra.sid, extra.entries)
        try f.h.record("Z", extra.sid, rehomeRecord(["title": Value(extra.title)]))
        f.rows[3].mode = "ok"
        var latest: Value = .undefined
        for pass in 0..<5 {
            clock.now += 60000
            if pass == 4 { f.rows[4].mode = "ok" }
            latest = try finishPending(f.h.paths, f.options)
            eq(latest.receipt.cloudChecks[0].sessionIds, .undefined, "pass \(pass)")
            eq(latest.complete, false, "pass \(pass)")
            deq(latest.receipt.failed.map { $0.code }.sorted(), ["CLOUD_BUDGET_LIMIT", "CLOUD_HISTORY_LIMIT", "CLOUD_PARSER_LIMIT"], "pass \(pass)")
            if pass == 0 {
                #expect(Set(latest.receipt.cloudChecks[0].waiting.elements.map { $0.id.str }) == Set([f.rows[3].id, f.rows[4].id, extra.id]))
            }
        }
        ok(f.rows.dropFirst(3).allSatisfy { $0.status == "archived" })
        eq(latest.receipt.cloudChecks[0].waiting.length, 0)
        #expect(f.rows.prefix(3).map(\.reads) == [1, 1, 2])
        clock.now += 120000
        eq(try finishPending(f.h.paths, f.options).pending, true)
        let reads = f.rows.map(\.reads)
        eq(try keepLocal(f.h.paths).ok, true)
        _ = try finishPending(f.h.paths, f.options)
        #expect(f.rows.map(\.reads) == reads)
        eq(try readJSON(f.moved.file.str).cloudChecks[0].status, "cancelled")
    }

    @Test("budget fairness preserves deferred work when an isolated history exhausts memory after analysis")
    func fairnessPreservesDeferred() throws {
        let clock = Clock()
        for mode in ["ok", "budget"] {
            let f = try limitRetryFixture(["budget", "connected"])
            var exhausted = false, retrying = false
            let first = try finishPending(f.h.paths, f.options), scope = first.receipt.cloudChecks[0].sessionIds
            f.rows[0].mode = mode
            let read = f.cloud.eventRows
            f.cloud.eventRows = fn { args in
                defer { if retrying && args[0].str == f.rows[0].id { exhausted = true } }
                return try read.call(args[0])
            }
            f.memory.check = fn { () in
                if exhausted { throw makeError("Synthetic post-analysis budget exhaustion", code: "CLOUD_MEMORY_BUDGET") }
            }
            retrying = true; clock.now += 60000
            let limited = try finishPending(f.h.paths, f.options)
            eq(limited.receipt.failed[0].code, "CLOUD_BUDGET_LIMIT", mode)
            eq(Value(limited.receipt.failed[0].id.str.replacingOccurrences(of: "session_", with: "cse_")), Value(f.rows[0].id), mode)
            deq(limited.receipt.cloudChecks[0].waiting.map { $0.id }, [Value(f.rows[1].id)], mode)
            deq(limited.receipt.cloudChecks[0].sessionIds, scope, mode)
            eq(limited.receipt.remote.length, 0, mode)
            exhausted = false; retrying = false; f.rows[1].mode = "ok"; clock.now += 60000
            let completed = try finishPending(f.h.paths, f.options)
            eq(completed.complete, false, mode)
            eq(f.rows[1].status, "archived", mode)
            eq(completed.receipt.failed.length, 1, mode)
            deq(completed.receipt.cloudChecks[0].sessionIds, scope, mode)
        }
    }

    @Test("native string-size errors during final verification become scoped parser limits")
    func stringSizeParserLimits() throws {
        let f = try limitRetryFixture(["ok", "connected"]), clock = Clock()
        var ready = false, thrown = 0
        let before = try fixtureSnapshot(f.h, [f.h.paths.records.str, f.h.paths.pool.str])
        let read = f.cloud.eventRows
        // The third read of row 0 is its final verification; the history it returns is too large to serialize.
        f.cloud.eventRows = fn { args in
            let rows = try read.call(args[0])
            if ready && thrown == 0 && args[0].str == f.rows[0].id && f.rows[0].reads == 3 {
                thrown += 1
                let error = EngineError.range("Invalid string length")
                eq(error.code, .undefined)
                throw error
            }
            return rows
        }
        let failed = try finishPending(f.h.paths, .spread(f.options, ["report": fn { args in
            let extra = Engine.Cloud.arg(args, 2)
            if Engine.Cloud.arg(args, 0) == "cloud" && extra.completed == 0 && (extra.total.asNumber ?? 0) > 0 { ready = true }
            return .undefined
        }]))
        f.cloud.eventRows = read
        eq(ready, true)
        eq(thrown, 1)
        eq(failed.ok, false)
        eq(failed.receipt.failed[0].id, Value(f.rows[0].id))
        eq(failed.receipt.failed[0].code, "CLOUD_PARSER_LIMIT")
        eq(failed.receipt.failed[0].localId, Value(f.rows[0].sid))
        eq(f.rows[0].status, "active")
        eq(failed.receipt.remote.length, 0)
        eq(failed.receipt.sessions.length, f.moved.receipt.sessions.length)
        for key in ["pending", "remotePending", "finalizing", "retiring", "undoing"] { ok(!failed.receipt[key].truthy, key) }
        deq(try fixtureSnapshot(f.h, [f.h.paths.records.str, f.h.paths.pool.str]), before)
        let reads = f.rows[0].reads
        clock.now += 60000
        let waiting = try finishPending(f.h.paths, f.options)
        eq(waiting.receipt.failed[0].code, "CLOUD_PARSER_LIMIT")
        eq(f.rows[0].reads, reads)
        f.rows[1].mode = "ok"; clock.now += 60000
        let independent = try finishPending(f.h.paths, f.options)
        eq(f.rows[1].status, "archived")
        eq(f.rows[0].status, "active")
        eq(f.rows[0].reads, reads)
        eq(independent.complete, false)
        eq(independent.receipt.failed[0].code, "CLOUD_PARSER_LIMIT")
        clock.now += 60000
        eq(try finishPending(f.h.paths, f.options).pending, true)
        eq(f.rows[0].reads, reads)
    }
}
