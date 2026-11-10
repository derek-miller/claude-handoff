import Foundation
import Testing
@testable import HandoffCore

extension Engine.Inventory {
    @Test("unreadable Desktop records are counted and fail the move")
    func unreadableRecordsCounted() throws {
        let h = try home()
        let file = path.join(h.dir("P"), "local_\(id(934)).json")
        let target = path.join(h.dir("Z"), "local_\(id(933)).json")
        try writeText(file, "{broken")
        try writeText(target, "{broken")
        let by = try Self.byAccount(h)
        deq(by[h.acct.P]!.unreadable, [Value(file)])
        match(by[h.acct.P]!.stats, "1 unreadable")
        let inv = try inventory([by[h.acct.P]!], by[h.acct.Z]!, h.paths)
        eq(inv.total, 1)
        eq(inv.unreadable.length, 2)
        let result = try move(inv, by[h.acct.Z]!, h.paths)
        eq(result.ok, false)
        deq(result.receipt.failed.map { $0.error }, ["unreadable Desktop record", "unreadable Desktop record"])
    }

    @Test("an invalid duplicate is refused, never hidden behind a valid twin")
    func invalidDuplicateRefused() throws {
        let h = try home()
        let k1: Value = [entry("user", 950, nil, id(950)), entry("assistant", 951, 950, id(950))]
        try h.write(id(950), k1)
        try h.record("P", id(950))
        try h.write(id(960), fork(k1, id(950), id(960), "K"))
        try appendText(h.transcript(id(960)), "{\"type\":\"user\",\"uuid\":\"broken\n")
        try h.record("T", id(960))
        let by = try Self.byAccount(h)
        let inv = try inventory([by[h.acct.P]!, by[h.acct.T]!], by[h.acct.Z]!, h.paths)
        deq(inv.move.map { $0.id }, [Value(id(950))])
        deq(inv.blocked.map { $0.id }, [Value(id(960))])
        match(inv.blocked[0].error, "1 unparseable lines")
        let result = try move(inv, by[h.acct.Z]!, h.paths)
        deq(result.receipt.failed.map { $0.error }, ["1 unparseable lines"])
        eq(result.receipt.sessions.length, 1)
    }

    @Test("same-root histories with different content are never folded together")
    func sameRootDifferentContent() throws {
        let h = try home()
        let source: Value = [entry("user", 940, nil, id(940)), entry("assistant", 941, 940, id(940))]
        try h.write(id(940), source)
        try h.record("P", id(940))
        let changed = fork(source, id(940), id(945), "Changed")
        changed.push(["type": "content-replacement", "sessionId": Value(id(945)), "replacements": [["uuid": Value(id(940)), "text": "different"]],
                      "uuid": Value(id(946)), "timestamp": "2026-09-01T00:00:46.000Z"])
        try h.write(id(945), changed)
        try h.record("T", id(945))
        let by = try Self.byAccount(h)
        let inv = try inventory([by[h.acct.P]!, by[h.acct.T]!], by[h.acct.Z]!, h.paths)
        eq(inv.twice, 0)
        eq(inv.apart, 2)
        deq(inv.move.map { $0.id }.sorted(), [Value(id(940)), Value(id(945))])
    }

    @Test("compatible source versions that need merging are blocked")
    func compatibleVersionsBlocked() throws {
        let h = try home()
        let source: Value = [entry("user", 942, nil, id(942), ["toolUseResult": ["stdout": "", "stderr": ""]])]
        try h.write(id(942), source)
        try h.record("P", id(942))
        let richer = fork(source, id(942), id(943), "Richer")
        richer[0].toolUseResult = ["stdout": "finished", "stderr": ""]
        try h.write(id(943), richer)
        try h.record("T", id(943))
        let by = try Self.byAccount(h)
        let inv = try inventory([by[h.acct.P]!, by[h.acct.T]!], by[h.acct.Z]!, h.paths)
        deq(inv.move, [])
        eq(inv.blocked.length, 1)
        match(inv.blocked[0].error, "multiple compatible source versions require merging")
        eq(inv.twice, 1)
    }

    @Test("runtime latch drift remains one blocked history")
    func runtimeLatchDrift() throws {
        let h = try home()
        let source: Value = [entry("user", 944, nil, id(944)), ["type": "atis-latch", "sessionId": Value(id(944)), "atis": "first"]]
        try h.write(id(944), source)
        try h.record("P", id(944))
        let copy = fork(source, id(944), id(947), "Latch").concat([["type": "atis-latch", "sessionId": Value(id(947)), "atis": "second"]])
        try h.write(id(947), copy)
        try h.record("T", id(947))
        let by = try Self.byAccount(h)
        let inv = try inventory([by[h.acct.P]!, by[h.acct.T]!], by[h.acct.Z]!, h.paths)
        eq(inv.move.length, 0)
        eq(inv.blocked.length, 1)
        eq(inv.twice, 1)
    }

    @Test("different relocation state keeps both histories")
    func differentRelocationState() throws {
        let h = try home()
        let source: Value = [entry("user", 948, nil, id(948)), ["type": "relocated", "sessionId": Value(id(948)), "relocatedCwd": "/first"]]
        try h.write(id(948), source)
        try h.record("P", id(948))
        let copy = fork(source, id(948), id(949), "Relocated").concat([["type": "relocated", "sessionId": Value(id(949)), "relocatedCwd": "/second"]])
        try h.write(id(949), copy)
        try h.record("T", id(949))
        let by = try Self.byAccount(h)
        let inv = try inventory([by[h.acct.P]!, by[h.acct.T]!], by[h.acct.Z]!, h.paths)
        deq(inv.move.map { $0.id }.sorted(), [Value(id(948)), Value(id(949))])
    }

    @Test("a conflicting same-root history is refused instead of hidden")
    func conflictingSameRootRefused() throws {
        let h = try home()
        let source: Value = [entry("user", 935, nil, id(935)), entry("assistant", 936, 935, id(935))]
        try h.write(id(935), source)
        try h.record("P", id(935))
        let conflict = fork(source, id(935), id(937), "Conflict")
        let repeated = conflict.find { $0.type == "assistant" }
        conflict.push(.spread(repeated, ["message": ["role": "assistant", "content": "different"]]))
        try h.write(id(937), conflict)
        try h.record("T", id(937))
        let by = try Self.byAccount(h)
        let inv = try inventory([by[h.acct.P]!, by[h.acct.T]!], by[h.acct.Z]!, h.paths)
        deq(inv.move.map { $0.id }, [Value(id(935))])
        deq(inv.blocked.map { $0.id }, [Value(id(937))])
        let result = try move(inv, by[h.acct.Z]!, h.paths)
        match(result.receipt.failed[0].error, "conflicting duplicate uuids")
    }

    @Test("new sidecars remain visible through a shared transcript")
    func newSidecarsVisible() throws {
        let h = try home()
        let n1: Value = [entry("user", 985, nil, id(985)), entry("assistant", 986, 985, id(985))]
        try h.write(id(985), n1)
        try h.record("P", id(985))
        let pick = { () throws -> (from: Value, to: Value) in let by = try Self.byAccount(h); return ([by[h.acct.P]!], by[h.acct.Z]!) }
        var p = try pick()
        let first = try move(try inventory(p.from, p.to, h.paths), p.to, h.paths)
        let older = first.receipt.sessions[0].targetId
        try mkdirp(path.join(h.project, id(985), "subagents"))
        try writeText(path.join(h.project, id(985), "subagents", "agent-n.jsonl"), "{\"agent\":\"n\"}\n")
        try h.record("P", id(985))
        p = try pick()
        let inv = try inventory(p.from, p.to, h.paths)
        eq(inv.there.length, 1)
        deq(inv.move, [])
        let second = try move(inv, p.to, h.paths)
        eq(second.ok, true)
        eq(second.receipt.sessions.length, 0)
        deq(try Self.names(h.dir("P")), [])
        deq(Value(try readdir(h.dir("Z")).map { Value(jsSlice($0, 6, $0.utf16.count - 5)) }), [older])
    }

    @Test("nested histories with split sidecars are blocked instead of copied")
    func nestedSplitSidecarsBlocked() throws {
        let h = try home()
        let base: Value = [entry("user", 860, nil, id(860)), entry("assistant", 861, 860, id(860))]
        try h.write(id(860), base)
        try h.record("P", id(860))
        try mkdirp(path.join(h.project, id(860), "subagents"))
        try writeText(path.join(h.project, id(860), "subagents", "old.jsonl"), "{\"old\":true}\n")
        try h.write(id(870), fork(base, id(860), id(870), "Merged").concat([entry("user", 862, nil, id(870))]))
        try h.record("T", id(870))
        try mkdirp(path.join(h.project, id(870), "subagents"))
        try writeText(path.join(h.project, id(870), "subagents", "new.jsonl"), "{\"new\":true}\n")
        let by = try Self.byAccount(h)
        let inv = try inventory([by[h.acct.P]!, by[h.acct.T]!], by[h.acct.Z]!, h.paths)
        eq(inv.twice, 1)
        deq(inv.move, [])
        eq(inv.blocked.length, 1)
        match(inv.blocked[0].error, "multiple compatible source versions require merging")
        eq(try readdir(h.dir("P")).count, 1)
        eq(try readdir(h.dir("T")).count, 1)
    }

    @Test("a conflicting sidecar path keeps both nested histories")
    func conflictingSidecarPath() throws {
        let h = try home()
        let base: Value = [entry("user", 880, nil, id(880)), entry("assistant", 881, 880, id(880))]
        try h.write(id(880), base)
        try h.record("P", id(880))
        try mkdirp(path.join(h.project, id(880), "subagents"))
        try writeText(path.join(h.project, id(880), "subagents", "agent.jsonl"), "{\"version\":1}\n")
        try h.write(id(890), fork(base, id(880), id(890), "Conflict").concat([entry("user", 882, nil, id(890))]))
        try h.record("T", id(890))
        try mkdirp(path.join(h.project, id(890), "subagents"))
        try writeText(path.join(h.project, id(890), "subagents", "agent.jsonl"), "{\"version\":2}\n")
        let by = try Self.byAccount(h)
        let inv = try inventory([by[h.acct.P]!, by[h.acct.T]!], by[h.acct.Z]!, h.paths)
        eq(inv.twice, 0)
        deq(inv.move.map { $0.id }.sorted(), Value([Value(id(880)), Value(id(890))]).sorted())
    }

    @Test("target sidecar drift after inventory keeps the source record")
    func targetSidecarDrift() throws {
        let h = try home()
        let source: Value = [entry("user", 987, nil, id(987)), entry("assistant", 988, 987, id(987))]
        try h.write(id(987), source)
        let sidecar = path.join(h.project, id(987), "subagents", "agent.jsonl")
        try mkdirp(path.dirname(sidecar))
        try writeText(sidecar, "{\"agent\":true}\n")
        try h.record("P", id(987))
        let pick = { () throws -> (from: Value, to: Value) in let by = try Self.byAccount(h); return ([by[h.acct.P]!], by[h.acct.Z]!) }
        var p = try pick()
        let first = try move(try inventory(p.from, p.to, h.paths), p.to, h.paths)
        let older = first.receipt.sessions[0].targetId
        try appendText(h.transcript(id(987)), JSON.text(entry("user", 989, 988, id(987))) + "\n")
        try h.record("P", id(987))
        p = try pick()
        let inv = try inventory(p.from, p.to, h.paths)
        try unlink(sidecar)
        let second = try move(inv, p.to, h.paths)
        eq(second.ok, false)
        match(second.receipt.failed[0].error, "destination changed since inventory")
        deq(second.receipt.superseded, [])
        ok(try readdir(h.dir("Z")).contains("local_\(older.str).json"))
    }
}
