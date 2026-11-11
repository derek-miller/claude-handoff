import Foundation
import Testing
@testable import HandoffCore

extension Engine.Moves {
    static func offline(_ h: Home) -> Value {
        cloudFixture(h, ["account": Value(h.acct.T), "org": Value(h.org.T), "list": fn { _ in throw EngineError("offline") }])
    }

    @Test("completed local movement suppresses speculative pending")
    func completedLocalSuppressesPending() throws {
        let h = try home()
        let cloudError = "authentication unavailable"
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE, rehomeRecord())
        let from = try h.account("P"), to = try h.account("Z")
        let inv = try inventory([from], to, h.paths, NOOP, ["cloudRequested": true, "cloudError": Value(cloudError)])
        deq(inv.cloudCheckAccounts, [])
        let result = try move(inv, to, h.paths)
        eq(result.ok, true)
        eq(result.complete, true)
        eq(result.pendingCloud, 0)
        deq(result.receipt.cloudChecks, [])
        eq(result.receipt.sessions[0].strategy, "rehome")
        deq(try Self.names(h.dir("P")), [])
        deq(try Self.names(h.dir("Z")), [Value("local_\(SOURCE).json")])
        eq(result.receipt.cloudError, Value(cloudError))
        let idle = try finishPending(h.paths), swept = try sweep(h.paths)
        deq(Value([idle, swept].map { ["ok": $0.ok, "complete": $0.complete] as Value }), [["ok": true, "complete": true], ["ok": true, "complete": true]])
        eq(idle.nothing, true)
        eq(try readJSON(result.file.str).cloudError, Value(cloudError))
    }

    @Test("Keep local accepts a valid rehome record used after the move")
    func keepLocalAcceptsUsedRecord() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("T", SOURCE, rehomeRecord(["title": "Original title", "titleSource": "auto"]))
        let from = try h.account("T"), to = try h.account("Z")
        _ = try move(try inventory([from], to, h.paths, NOOP, ["cloud": Self.offline(h), "cloudRequested": true]), to, h.paths)
        let record = h.recordFile("Z", SOURCE)
        try writeJSON(record, .spread(try readJSON(record), ["title": "Continued title", "titleSource": "user", "completedTurns": 2]))
        let kept = try keepLocal(h.paths)
        eq(kept.ok, true)
        eq(kept.cancelled, 1)
    }

    @Test("Keep local tolerates independent Desktop metadata and destination bridges")
    func keepLocalToleratesMetadata() throws {
        let extras: [Value] = [
            ["bridgeSessionIds": ["session_destination"]],
            ["toolSurfaceSnapshot": ["familyHashes": ["builtin": "changed"], "recordedAt": 123]],
            ["bridgeSessionIds": ["session_destination"], "toolSurfaceSnapshot": ["recordedAt": 456]],
            ["lastActivityAt": 999, "completedTurns": 8, "futureMetadata": ["display": true]],
        ]
        for extra in extras {
            let h = try home()
            try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
            try h.record("T", SOURCE, rehomeRecord())
            let all = try accounts(h.paths), from = all.find { $0.account.str == h.acct.T }, to = all.find { $0.account.str == h.acct.Z }
            let moved = try moveWithPending(h, [from], to)
            let row = moved.receipt.sessions[0]
            try writeJSON(row.record.str, .spread(try readJSON(row.record.str), extra))
            let kept = try keepLocal(h.paths)
            eq(kept.ok, true)
            eq(kept.cancelled, 1)
            deq(try readJSON(row.record.str).bridgeSessionIds, extra.bridgeSessionIds ?? [])
            if extra.bridgeSessionIds.truthy { match(try undo(h.paths).changed[0], "desktop record") }
        }
    }

    @Test("Keep local refuses structural rehome record drift")
    func keepLocalRefusesStructuralDrift() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("T", SOURCE, rehomeRecord(["cwd": "/tmp/original"]))
        let from = try h.account("T"), to = try h.account("Z")
        _ = try move(try inventory([from], to, h.paths, NOOP, ["cloud": Self.offline(h), "cloudRequested": true]), to, h.paths)
        let record = h.recordFile("Z", SOURCE)
        try writeJSON(record, .spread(try readJSON(record), ["cwd": "/tmp/changed"]))
        let kept = try keepLocal(h.paths)
        match(kept.refused[0], "desktop record changed")
    }

    @Test("Keep local refuses when a moved destination record disappeared")
    func keepLocalRefusesVanishedRecord() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("T", SOURCE, rehomeRecord(["title": "Vanished local target"]))
        let from = try h.account("T"), to = try h.account("Z")
        _ = try moveWithPending(h, [from], to)
        try unlink(h.recordFile("Z", SOURCE))
        let result = try keepLocal(h.paths)
        match(result.refused[0], "desktop record changed")
        eq(result.receipt.cloudChecks[0].status, "pending")
        eq(try undo(h.paths).changed.length > 0, true)
    }

    @Test("Keep local refuses when an existing carrier no longer contains the retired source")
    func keepLocalRefusesChangedCarrier() throws {
        let h = try home()
        let target = id(711), sourceEntries: Value = [entry("user", 42, nil, SOURCE)]
        try h.write(SOURCE, sourceEntries)
        try h.write(target, fork(sourceEntries, SOURCE, target, "Carrier"))
        try h.record("T", SOURCE, rehomeRecord(["title": "Contained source"]))
        try h.record("Z", target, rehomeRecord(["title": "Carrier"]))
        let from = try h.account("T"), to = try h.account("Z")
        let moved = try moveWithPending(h, [from], to)
        eq(moved.receipt.sessions.length, 0)
        try h.write(target, [entry("user", 43, nil, target, ["message": ["role": "user", "content": "unrelated replacement"]])])
        let kept = try keepLocal(h.paths)
        match(kept.refused[0], "no longer contains source history")
        eq(kept.receipt.cloudChecks[0].status, "pending")
    }

    @Test("Keep local rejects a quarantined source record changed after retirement")
    func keepLocalRejectsChangedQuarantine() throws {
        let h = try home()
        let target = id(712), sourceEntries: Value = [entry("user", 44, nil, SOURCE)]
        try h.write(SOURCE, sourceEntries)
        try h.write(target, fork(sourceEntries, SOURCE, target, "Carrier"))
        try h.record("T", SOURCE, rehomeRecord(["title": "Tamper source"]))
        try h.record("Z", target, rehomeRecord(["title": "Tamper carrier"]))
        let from = try h.account("T"), to = try h.account("Z")
        let moved = try moveWithPending(h, [from], to)
        try h.write(target, [entry("user", 45, nil, target, ["message": ["role": "user", "content": "replacement history"]])])
        let sourcePlan = moved.receipt.superseded.find { $0.source.truthy }
        let parkedRecord = sourcePlan.moved[0][1].str
        try writeJSON(parkedRecord, .spread(try readJSON(parkedRecord), ["cliSessionId": Value(target)]))
        let kept = try keepLocal(h.paths)
        match(kept.refused[0], "recovery artifact changed")
        eq(kept.receipt.cloudChecks[0].status, "pending")
    }

    @Test("Keep local validates quarantine for a source rehomed by this move")
    func keepLocalValidatesRehomedQuarantine() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 46, nil, SOURCE)])
        try h.record("T", SOURCE, rehomeRecord(["title": "Moved quarantine source"]))
        let from = try h.account("T"), to = try h.account("Z")
        let moved = try moveWithPending(h, [from], to)
        let parked = moved.receipt.superseded.find { $0.source.truthy }.moved[0][1].str
        try writeText(parked, try readText(parked) + " ")
        let kept = try keepLocal(h.paths)
        match(kept.refused[0], "recovery artifact changed")
        eq(kept.receipt.cloudChecks[0].status, "pending")
    }
}
