import Foundation
import Testing
@testable import HandoffCore

extension Engine.Inventory {
    @Test("source parent retention follows ancestry within the affected account")
    func sourceParentRetention() throws {
        for location in ["P", "Q"] {
            let h = try home(), parent = id(776), child = id(777), base = branchEntries(2, SOURCE, 1)
            try h.write(SOURCE, base)
            try h.write(parent, fork(base, SOURCE, parent, "Parent"))
            for account in location == "P" ? ["P", "T"] : ["P", "T", location] {
                try h.record(account, SOURCE, rehomeRecord())
                try h.record(account, parent, rehomeRecord(["forkedFromSessionId": Value("local_\(SOURCE)")]))
            }
            try h.record(location, child, rehomeRecord(["isArchived": true, "forkedFromSessionId": Value("local_\(parent)")]))
            let all = try accounts(h.paths), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
            let inv = try inventory([from], to, h.paths)
            eq(inv.there.length, 2)
            let moved = try move(inv, to, h.paths)
            if location == "P" {
                eq(moved, nil)
            } else {
                eq(moved.ok, true)
                deq(moved.receipt.failed, [])
                eq(moved.receipt.superseded.length, 2)
            }
            deq(.strings(try readdir(h.dir(location)).sorted()), .strings([SOURCE, parent, child].map { "local_\($0).json" }.sorted()))
            if location == "Q" {
                deq(try Self.names(h.dir("P")), [])
                ok(try undo(h.paths).dest)
            }
        }
    }

    @Test("destination parents survive forks added after inventory or during final preparation")
    func destinationParentsSurviveLateForks() throws {
        for stage in ["inventory", "finalize"] {
            let h = try home(), richer = id(776), child = id(777), base = branchEntries(2, SOURCE, 1)
            try h.write(SOURCE, base)
            try h.record("T", SOURCE, rehomeRecord())
            try h.write(richer, fork(base, SOURCE, richer, "Richer").concat([entry("user", 3, nil, richer)]))
            try h.record("P", richer, rehomeRecord())
            let all = try accounts(h.paths), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
            let inv = try inventory([from], to, h.paths)
            let addFork = {
                try writeJSON(h.recordFile("T", child), ["sessionId": Value("local_\(child)"), "cliSessionId": Value(child), "isArchived": true, "forkedFromSessionId": Value("local_\(SOURCE)")])
            }
            if stage == "inventory" { try addFork() }
            let moved = try move(inv, to, h.paths, fn { args in
                if stage == "finalize" && Self.arg(args, 0).str == stage { try addFork() }
                return .undefined
            })
            eq(moved.ok, true)
            deq(moved.receipt.failed, [])
            eq(moved.receipt.superseded.some { !$0.source.truthy }, false)
            ok(exists(h.recordFile("T", SOURCE)))
            ok(try undo(h.paths).dest)
            deq(.strings(try readdir(h.dir("T")).sorted()), .strings([SOURCE, child].map { "local_\($0).json" }.sorted()))
        }
    }

    @Test("identical Desktop parent and fork histories are reported as overlapping versions")
    func identicalParentAndForkOverlap() throws {
        let h = try home(), child = id(777), base = branchEntries(2, SOURCE, 1)
        try h.write(SOURCE, base)
        try h.write(child, fork(base, SOURCE, child, "Fork"))
        try h.record("P", SOURCE, rehomeRecord())
        try h.record("P", child, rehomeRecord(["forkedFromSessionId": Value("local_\(SOURCE)")]))
        let result = cli(h.root, ["--from", "p@example.com personal", "--to", "z@example.com personal", "--dry-run"])
        eq(result.code, 0, result.stderr)
        match(result.stdout, "2 overlapping versions, kept separate")
        noMatch(result.stdout, "grew apart")
    }

    @Test("progress begins before analysis and every counted phase reaches its total")
    func progressReachesTotals() throws {
        let h = try home()
        try mkdirp(path.join(h.paths.records.str, h.acct.P, h.org.T))
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE), entry("assistant", 2, 1, SOURCE)])
        try h.record("P", SOURCE, rehomeRecord())
        let from = try h.account("P"), to = try h.account("P", org: "T")
        var progress: [Value] = []
        let report = fn { args in
            let extra = Self.arg(args, 2).nullish ? Value.newObject() : Self.arg(args, 2)
            if extra.live.truthy { progress.append(["stage": Self.arg(args, 0), "text": Self.arg(args, 1), "completed": extra.completed, "total": extra.total]) }
            return .undefined
        }
        let inv = try inventory([from], to, h.paths, report)
        _ = try move(inv, to, h.paths, report)
        deq(progress.first ?? .undefined, ["stage": "scan", "text": "0/1", "completed": 0, "total": 1])
        for stage in ["scan", "move", "verify", "retire"] {
            let rows = progress.filter { $0.stage.str == stage && $0.completed.asInt != nil && $0.total.asInt != nil }
            ok(rows.count >= 2, "\(stage) did not report a counted phase")
            guard let first = rows.first, let last = rows.last else { continue }
            eq(first.completed, 0)
            eq(last.completed, last.total)
            ok(rows.indices.allSatisfy { $0 == 0 || rows[$0].completed.asNumber! >= rows[$0 - 1].completed.asNumber! })
        }
    }

    @Test("the planning cache skips unchanged analysis but never authorizes a move")
    func planningCacheNeverAuthorizes() throws {
        let h = try home()
        let teamDir = path.join(h.paths.records.str, h.acct.P, h.org.T)
        try mkdirp(teamDir)
        let transcript = h.transcript(SOURCE)
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE), entry("assistant", 2, 1, SOURCE)])
        try h.record("P", SOURCE, rehomeRecord())
        let from = try h.account("P"), to = try h.account("P", org: "T")
        let cold = try inventory([from], to, h.paths, NOOP, ["writeCache": true])
        ok(cold.cacheStats.historyMisses.asNumber! > 0)
        let cache = try readJSON(path.join(h.paths.state.str, "cache.json"))
        ok(cache.histories.valuesArray.every { $0.value.result.contentSha.isString })
        let warm = try inventory([from], to, h.paths)
        ok(warm.cacheStats.historyHits.asNumber! > 0)
        eq(warm.cacheStats.historyMisses, 0)
        ok(warm.cacheStats.manifestHits.asNumber! > 0)

        try appendText(transcript, "\(JSON.text(entry("user", 3, 2, SOURCE)))\n")
        var reports: [String] = []
        let retried = try move(warm, to, h.paths, fn { args in reports.append("\(Self.arg(args, 0)) \(Self.arg(args, 1))"); return .undefined })
        ok(reports.contains("recovery Retrying unfinished sessions once"))
        eq(retried.receipt.sessions.length, 1)
        deq(try Self.names(h.dir("P")), [])
        deq(try Self.names(teamDir), [Value("local_\(SOURCE).json")])
    }

    @Test("rehome verification catches transcript and sidecar drift after placement")
    func rehomeVerificationCatchesDrift() throws {
        let h = try home()
        let teamDir = path.join(h.paths.records.str, h.acct.P, h.org.T)
        try mkdirp(teamDir)
        let transcript = h.transcript(SOURCE)
        let sidecar = path.join(h.project, SOURCE, "subagents", "agent.jsonl")
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try mkdirp(path.dirname(sidecar))
        try writeText(sidecar, "{\"before\":true}\n")
        try h.record("P", SOURCE, rehomeRecord())
        let from = try h.account("P"), to = try h.account("P", org: "T")
        let inv = try inventory([from], to, h.paths)
        var reports: [String] = []
        let result = try move(inv, to, h.paths, fn { args in
            reports.append("\(Self.arg(args, 0)) \(Self.arg(args, 1))")
            if Self.arg(args, 0) != "verify" || Self.arg(args, 2).completed != 0 { return .undefined }
            try appendText(transcript, "\(JSON.text(entry("assistant", 2, 1, SOURCE)))\n")
            try appendText(sidecar, "{\"after\":true}\n")
            return .undefined
        })
        ok(reports.contains("recovery Retrying unfinished sessions once"))
        eq(result.ok, true)
        deq(try Self.names(h.dir("P")), [])
        deq(try Self.names(teamDir), [Value("local_\(SOURCE).json")])
    }

    @Test("rehome retirement allows shared growth without duplicate records")
    func rehomeRetirementSharedGrowth() throws {
        let h = try home()
        let teamDir = path.join(h.paths.records.str, h.acct.P, h.org.T)
        try mkdirp(teamDir)
        let transcript = h.transcript(SOURCE)
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE, rehomeRecord())
        let from = try h.account("P"), to = try h.account("P", org: "T")
        var changed = false
        let result = try move(try inventory([from], to, h.paths), to, h.paths, fn { args in
            if Self.arg(args, 0) != "retire" || Self.arg(args, 1) != "checking" || changed { return .undefined }
            changed = true
            try appendText(transcript, "\(JSON.text(entry("assistant", 2, 1, SOURCE)))\n")
            return .undefined
        })
        eq(result.ok, true)
        #expect(changed)
        deq(try Self.names(h.dir("P")), [])
        deq(try Self.names(teamDir), [Value("local_\(SOURCE).json")])
        ok(try readText(transcript).contains("message 2"))
    }

    @Test("corrupt and legacy planning caches refresh replay analysis")
    func corruptAndLegacyCaches() throws {
        for state in ["corrupt", "legacy"] {
            let h = try home()
            try mkdirp(path.join(h.paths.records.str, h.acct.P, h.org.T))
            let parent = entry("assistant", 1, nil, SOURCE)
            let image: Value = ["base64": Value(Data("synthetic image bytes".utf8).base64EncodedString()), "dimensions": ["width": 1, "height": 1], "originalSize": 21, "type": "image/png"]
            let full = entry("user", 2, 1, SOURCE, ["toolUseResult": ["type": "image", "file": image]])
            let replay = Value.spread(full, ["toolUseResult": .spread(full.toolUseResult, ["file": .spread(full.toolUseResult.file, ["base64": ""])])])
            let edits: [Value] = [3, 4, 5, 6].flatMap { k -> [Value] in
                let original = entry("attachment", k, 2, SOURCE, ["attachment": ["type": "edited_text_file", "filename": Value("/tmp/fixture-\(k).txt"), "snippet": Value("synthetic edit \(k)")]])
                return [original, .spread(original, ["attachment": .spread(original.attachment, ["displayPath": Value("fixture-\(k).txt")])])]
            }
            let entries = Value([parent, full, replay] + edits)
            eq(try normalize(entries).replays, 5)
            try h.write(SOURCE, entries)
            try h.record("P", SOURCE, rehomeRecord())
            let transcript = h.transcript(SOURCE), before = try readData(transcript)
            let from = try h.account("P"), to = try h.account("P", org: "T")
            _ = try inventory([from], to, h.paths, NOOP, ["writeCache": true, "processes": []])
            let file = path.join(h.paths.state.str, "cache.json"), stored = try readJSON(file)
            stored.version = 10
            for row in stored.histories.valuesArray.elements {
                row.value.result.conflicts = 10
                row.value.result.comparable = false
            }
            try writeText(file, state == "corrupt" ? "{broken" : JSON.text(stored))
            let inv = try inventory([from], to, h.paths, NOOP, ["writeCache": true, "processes": []])
            eq(inv.blocked.length, 0)
            eq(inv.move.length, 1)
            eq(inv.cacheStats.historyHits, 0)
            ok(inv.cacheStats.historyMisses.asNumber! > 0)
            let refreshed = try readJSON(file)
            eq(refreshed.version, Value(CACHE_VERSION))
            eq(refreshed.semanticVersion, 3)
            ok(refreshed.histories.valuesArray.every { $0.value.result.conflicts == 0 && $0.value.result.comparable.truthy })
            let warm = try inventory([from], to, h.paths, NOOP, ["processes": []])
            eq(warm.blocked.length, 0)
            eq(warm.move.length, 1)
            ok(warm.cacheStats.historyHits.asNumber! > 0)
            eq(warm.cacheStats.historyMisses, 0)
            #expect(try readData(transcript) == before)
        }
    }

    @Test("inventory interrupts preparation at record boundaries when its deadline is spent")
    func inventoryDeadlineAtRecordBoundaries() throws {
        let h = try home()
        for session in [SOURCE, id(2)] {
            try h.write(session, [entry("user", Int(String(session.suffix(1)))!, nil, session)])
            try h.record("P", session)
        }
        let all = try accounts(h.paths), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
        var completed: Value = 0
        throwsError("fixture deadline spent") {
            try inventory([from], to, h.paths, fn { args in
                if Self.arg(args, 0) == "scan" { completed = Self.arg(args, 2).completed }
                return .undefined
            }, ["processes": [], "check": fn { () in if completed.asNumber ?? 0 > 0 { throw EngineError("fixture deadline spent") } }])
        }
        eq(completed, 1)
        eq(try readdir(h.dir("T")).count, 0)
    }

    @Test("cold moves tolerate unrelated runtime writes while still catching new parent dependencies")
    func coldMovesToleratesRuntimeWrites() throws {
        for change in ["runtime", "parent"] {
            let h = try home(), other = id(2)
            for sid in [SOURCE, other] {
                try h.write(sid, [entry("user", sid == SOURCE ? 101 : 102, nil, sid)])
                try h.record("P", sid, rehomeRecord())
            }
            let all = try accounts(h.paths, []), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
            from.sessions = from.sessions.filter { $0.id.str == SOURCE }
            let read = fs.readFile, file = h.recordFile("P", other)
            var armed = false, changed = false
            fs.readFile = { name in
                let result = try read(name)
                if armed && !changed && name == file {
                    changed = true
                    let record = try JSON.parse(result)
                    if change == "runtime" { record.completedTurns = 7 } else { record.forkedFromSessionId = Value("local_\(SOURCE)") }
                    try writeJSON(file, record)
                }
                return result
            }
            let result: Value
            do {
                defer { fs.readFile = read }
                result = try executeMove([from], to, h.paths, ["processes": [], "report": fn { args in
                    if Self.arg(args, 0) == "retire" { armed = true }
                    return .undefined
                }])
            }
            #expect(changed)
            eq(result.ok, true)
            eq(result.receipt.sessions.length, 1)
            deq(result.receipt.failed, [])
            if change == "runtime" {
                eq(result.receipt.superseded.length, 1)
                eq(try readJSON(file).completedTurns, 7)
            } else {
                eq(result.receipt.superseded.length, 0)
                ok(exists(h.recordFile("P", SOURCE)))
                ok(exists(h.recordFile("T", SOURCE)))
            }
        }
    }

    @Test("missing and unreadable moved records remain distinct from informational field changes")
    func missingAndUnreadableMovedRecords() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE)
        let from = try h.account("P"), to = try h.account("T")
        let moved = try move(try inventory([from], to, h.paths), to, h.paths)
        let file = moved.receipt.sessions[0].record.str
        try unlink(file)
        deq(try verifyPlaced(h.paths).changed[0].fields, ["record unavailable"])
        try writeText(file, "{")
        deq(try verifyPlaced(h.paths).changed[0].fields, ["record unavailable"])
    }
}
