import Foundation
import Testing
@testable import HandoffCore

extension Engine.Cloud {
    // A report callback that records each event as { stage, text, ...extra }.
    static func collect(_ progress: Box<[Value]>) -> Value {
        fn { args in
            progress.value.append(.spread(["stage": arg(args, 0), "text": arg(args, 1)], arg(args, 2).nullish ? [:] : arg(args, 2)))
            return .undefined
        }
    }

    @Test("pending same-login sources progress fairly past waits and transient failures")
    func pendingSourcesProgressFairly() throws {
        for mode in ["waiting", "transient"] {
            let f = try pendingOrganizations(orgs: ["P", "T", "Q"]), h = f.h
            f.rows[0].mode = mode
            var now = dateNow()
            process.now = { now }
            let progress = Box<[Value]>([])
            let first = try sweep(h.paths, .spread(f.options, ["report": Self.collect(progress)]))
            #expect((progress.value.count > 0) == (mode != "transient"))
            ok(progress.value.allSatisfy { $0.sourceId.str == "\(h.acct.P)/\(f.rows[0].org)" })
            eq(first.result.complete, false)
            eq(f.rows[0].status, "active")
            if mode == "transient" { eq(first.result.failed[0].code, "FIXTURE_UNAVAILABLE") }
            try f.identity.write(f.identity.`init`(2, h.acct.P, h.org.Q))
            for row in f.rows.dropFirst() {
                let progress = Box<[Value]>([])
                let next = try sweep(h.paths, .spread(f.options, ["report": Self.collect(progress)]))
                ok(progress.value.contains { $0.stage == "cloud" && $0.completed == 0 && ($0.total.asNumber ?? 0) > 0 })
                ok(progress.value.allSatisfy { $0.sourceId.str == "\(h.acct.P)/\(row.org)" })
                eq(next.result.file, f.moved.file)
                eq(next.result.complete, false)
                eq(row.status, "archived")
            }
            #expect(f.calls.value == f.rows.map(\.org))
            _ = try sweep(h.paths, f.options)
            eq(f.calls.value.count, 3)
            let receipt = try readJSON(f.moved.file.str)
            eq(receipt.cloudAttempts.ownKeys.count, 3)
            deq(receipt.cloudChecks.map { $0.sessionIds }, f.moved.receipt.cloudChecks.map { $0.sessionIds })
            eq(receipt.startedAt, f.moved.receipt.startedAt)
            f.rows[0].mode = "ready"
            f.rows[0].updated = "2026-09-02T00:00:00.000Z"
            now += 60_001
            let completed = try sweep(h.paths, f.options)
            eq(completed.result.complete, true)
            eq(completed.result.ok, true)
            eq(completed.result.receipt.failed.length, 0)
            eq(completed.result.receipt.remote.length, 3)
            #expect(f.calls.value == f.rows.map(\.org) + [f.rows[0].org])
            process.now = Host().now
        }
    }

    @Test("source cooldowns do not starve another organization or reopen cancelled checks")
    func sourceCooldowns() throws {
        let f = try pendingOrganizations(orgs: ["P", "T", "Q"]), receipt = try readJSON(f.moved.file.str)
        receipt.cloudAttempts = .fromEntries([("\(f.h.acct.P)/\(f.rows[0].org)", Value(dateNow()))])
        receipt.cloudChecks[2].status = "cancelled"
        try writeJSON(f.moved.file.str, receipt)
        let completed = try sweep(f.h.paths, f.options)
        eq(completed.result.complete, false)
        #expect(f.calls.value == [f.rows[1].org])
        _ = try sweep(f.h.paths, f.options)
        #expect(f.calls.value == [f.rows[1].org])
        eq(try readJSON(f.moved.file.str).cloudChecks[2].status, "cancelled")
        let manual = try finishPending(f.h.paths, f.options)
        eq(manual.complete, true)
        eq(f.rows[0].status, "archived")
        eq(f.rows[2].status, "active")
    }

    @Test("login updates retry promptly, use brief backoff and then return to normal pacing")
    func loginUpdatesRetry() throws {
        let f = try pendingOrganizations(orgs: ["P"])
        var now = dateNow(), attempts = 0, ready = false
        process.now = { now }
        let active: Value = ["account": Value(f.h.acct.P), "org": Value(f.h.org.P), "state": "known", "at": Value(isoString(now - 1000))]
        let options = Value.spread(f.options, ["active": active, "cloud": fn { args in
            attempts += 1
            if !ready { throw jsThrow("Claude Desktop login is still updating", code: "CLOUD_AUTH_PENDING") }
            return try f.client.call(Self.arg(args, 0))
        }])
        let first = try sweep(f.h.paths, options)
        let source = first.result.receipt.cloudChecks[0]
        eq(try pendingPresentation(first.result.receipt, source, ["signedIn": true], "cloud", [], false, .newMap(), active).pendingRetryAt, Value(now + 15000))
        for (elapsed, expected) in [(0.0, 1), (14999, 1), (1, 2), (15000, 3), (59000, 3)] {
            now += elapsed
            _ = try sweep(f.h.paths, options)
            eq(attempts, expected, "after \(elapsed) ms")
        }
        active["at"] = Value(isoString(now))
        _ = try sweep(f.h.paths, options)
        eq(attempts, 4)
        ready = true
        now += 15000
        let complete = try sweep(f.h.paths, options)
        eq(complete.result.complete, true)
        eq(complete.result.receipt.failed.length, 0)
        eq(attempts, 5)
    }

    @Test("unchanged event-limit refusals do not redownload and a new engine can retry them")
    func eventLimitRefusals() throws {
        let f = try pendingOrganizations(orgs: ["P"])
        var now = dateNow(), attempts = 0
        process.now = { now }
        let options = Value.spread(f.options, ["cloud": fn { _ in attempts += 1; throw jsThrow("history exceeds the event limit", code: "CLOUD_HISTORY_LIMIT") }])
        let first = try sweep(f.h.paths, options), receipt = first.result.receipt, source = receipt.cloudChecks[0]
        let presentation = try pendingPresentation(receipt, source, ["signedIn": true], "cloud")
        eq(presentation.pendingState, "limit")
        eq(presentation.pendingAutomatic, false)
        eq(presentation.pendingRetryAt, nil)
        now += 120000
        eq(try sweep(f.h.paths, options).pending, true)
        eq(attempts, 1)
        source.attemptEngine = "previous-engine"
        try writeJSON(f.moved.file.str, receipt)
        let complete = try sweep(f.h.paths, f.options)
        eq(complete.result.complete, true)
        eq(f.rows[0].status, "archived")
    }

    @Test("same-login cleanup retains server account, organization membership and response organization checks")
    func sameLoginRetainsChecks() throws {
        for mismatch in ["server account", "membership", "response org", "Desktop login", "logout"] {
            let f = try pendingOrganizations(orgs: ["T"]), h = f.h
            var requests: [String] = []
            mockFetch { url, options in
                let endpoint = url.path
                requests.append(endpoint)
                eq(options.method.nullish ? "GET" : options.method.str, "GET")
                if endpoint == "/api/account" { return response(["uuid": Value(mismatch == "server account" ? h.acct.T : h.acct.P)]) }
                if endpoint == "/api/organizations" { return response(Value((mismatch == "membership" ? [h.org.P] : [h.org.P, h.org.T]).map { ["uuid": Value($0)] })) }
                eq(endpoint, "/v1/code/sessions")
                eq(options.headers["x-organization-uuid"], Value(h.org.T))
                return response(["data": []], headers: ["anthropic-organization-id": Value(h.org.P)])
            }
            let cloud = fn { args in
                try cloudClient(h.paths, Self.arg(args, 0), [
                    "active": ["account": Value(mismatch == "Desktop login" ? h.acct.T : h.acct.P), "org": Value(h.org.P), "state": Value(mismatch == "logout" ? "logged-out" : "known")],
                    "cookies": .newMap([(Value("sessionKey"), Value("fixture")), (Value("lastActiveOrg"), Value(h.org.P))]), "userAgent": "fixture",
                ])
            }
            let result = try finishPending(h.paths, .spread(f.options, ["cloud": cloud]))
            eq(result.ok, false, mismatch)
            eq(result.complete, false)
            ok(result.failed.length > 0)
            eq(f.rows[0].status, "active")
            eq(result.receipt.remote.length, 0)
            eq(requests.count, mismatch == "response org" ? 3 : mismatch == "membership" ? 2 : mismatch == "server account" ? 1 : 0, mismatch)
        }
    }

    @Test("local Undo continuation stays explicit after its last remote restoration checkpoint")
    func undoContinuationExplicit() throws {
        let f = try pendingOrganizations(orgs: ["T"])
        _ = try sweep(f.h.paths, f.options)
        _ = try undo(f.h.paths, .spread(f.options, ["active": ["account": Value(f.h.acct.T), "org": Value(f.h.org.T)]]))
        let receipt = try readJSON(f.moved.file.str)
        receipt.remoteUndoing = []
        f.rows[0].status = "active"
        try writeJSON(f.moved.file.str, receipt)
        let before = try readData(f.moved.file.str), count = f.calls.value.count
        eq(try sweep(f.h.paths, f.options).complete, false)
        eq(f.calls.value.count, count)
        #expect(try readData(f.moved.file.str) == before)
        let listed = cli(f.h.root, ["accounts", "--json"])
        eq(listed.code, 0, listed.stderr)
        let pending = try JSON.parse(listed.stdout).filter { $0.pending == "undo" }
        eq(pending.length, 1)
        eq(pending[0].pendingAction, "finish")
        let finished = try finishPending(f.h.paths, f.options)
        eq(finished.complete, true)
        ok(finished.dest)
        eq(f.calls.value.count, count)
        deq(try fixtureSnapshot(f.h, [f.h.paths.records.str, f.h.paths.pool.str]), f.before)
    }
}
