import Darwin
import Foundation
import Testing
@testable import HandoffCore

extension Engine.Cloud {
    // Sets both access and modification times, like fs.utimes.
    static func utimes(_ file: String, _ iso: String) throws {
        let seconds = dateParse(iso) / 1000
        var times = [timeval(tv_sec: Int(seconds), tv_usec: 0), timeval(tv_sec: Int(seconds), tv_usec: 0)]
        if Darwin.utimes(file, &times) != 0 { throw fsError(errno, "utime", file) }
    }

    static func size(_ file: String) throws -> Int { try stat(file)["size"].asInt! }

    @Test("artifact coverage archives all 470 events through explicit links or task titles with optional wrappers")
    func artifactCoverageArchivesAll() throws {
        for wrappers in [false, true] {
            for linked in [false, true] {
                let f = try artifactFixture(large: true, wrappers: wrappers), h = f.h
                if !linked {
                    try h.record("Z", SOURCE, rehomeRecord(["title": "Renamed synthetic mirror", "scheduledTaskId": "artifact_task"]))
                    f.to = try accounts(h.paths, []).find { $0["account"].str == h.acct.Z }
                }
                f.extra.push(["type": "progress", "data": Value(String(repeating: "x", count: 1_200_000))])
                try f.write()
                ok(JSON.text(f.queued).utf8.count > 1024 * 1024)
                let files = [f.transcript, f.taskFile, h.recordFile("Z", SOURCE)] + (0..<3).map { path.join(f.directory, "agent-a\($0).jsonl") }
                let before = try files.map(readData)
                let inv = try f.inventory(["writeCache": true])
                deq(inv["cloud"]["blocked"], [])
                eq(inv["cloud"]["matches"][0]["target"]["matchMode"], "artifacts")
                deq(inv["cloud"]["matches"][0]["target"]["artifactCounts"], ["main": 365, "subagent": 104, "queued": 1])
                let used = inv["cloud"]["artifacts"]["used"]
                let moved = try move(inv, f.to, h.paths)
                eq(moved["ok"], true, JSON.text(moved["receipt"]["failed"]))
                eq(f.calls, 1)
                eq(moved["receipt"]["sessions"].length, 0)
                eq(moved["receipt"]["remote"][0]["matchMode"], "artifacts")
                deq(moved["receipt"]["remote"][0]["artifactCounts"], ["main": 365, "subagent": 104, "queued": 1])
                eq(inv["cloud"]["artifacts"]["used"], used)
                #expect(try files.map(readData) == before)
                ok(try undo(h.paths, ["cloud": f.cloud, "processes": []])["dest"])
                eq(f.status, "active")
            }
        }
    }

    @Test("artifact coverage refuses ownership, identity, order, multiplicity and delivery failures",
          arguments: ["parent", "agent", "collision", "conflicting copy", "main identity", "order", "changed", "duplicate event", "replay", "delivery", "undelivered", "remove content", "cancelled copy", "empty"])
    func artifactCoverageRefuses(change: String) throws {
        let f = try artifactFixture()
        if change == "parent" { f.agents[0][0]["sessionId"] = Value(id(999)) }
        if change == "agent" { f.agents[0][0]["agentId"] = "another" }
        if change == "collision" { f.agents[1].push(.spread(f.agents[0][0], ["agentId": "a1"])) }
        if change == "conflicting copy" { f.agents[0].push(.spread(f.agents[0][0], ["message": ["role": "user", "content": "Conflicting copy"]])) }
        if change == "main identity" { f.remote[0] = .spread(f.remote[0], ["message": f.agents[0][1]["message"]]) }
        if change == "order" { f.agents[0].asArray!.items.reverse() }
        if change == "changed" { f.agents[0][0] = .spread(f.agents[0][0], ["message": ["role": "user", "content": "Changed synthetic content"]]) }
        if change == "duplicate event" { f.remote.push(f.remote[365]) }
        if change == "delivery" { f.removal["deliveryId"] = "another-delivery" }
        if change == "undelivered" { f.removal["reason"] = "cancelled" }
        if change == "remove content" { f.removal["content"] = "Conflicting consumed prompt" }
        if change == "cancelled copy" { f.extra.push(.spread(f.removal, ["reason": "cancelled"])) }
        if change == "empty" { f.remote = [] }
        try f.write()
        if change == "replay" {
            try appendText(f.transcript, JSON.text(.spread(f.queued, ["attachment": .spread(f.queued["attachment"], ["prompt": "Conflicting replay"])])) + "\n")
        }
        let inv = try f.inventory()
        deq(inv["cloud"]["matches"], [], change)
        if change == "empty" { eq(inv["cloud"]["blocked"][0]["code"], "CLOUD_UNPROVEN") }
        else { eq(inv["cloud"]["blocked"][0]["code"], "CLOUD_ARTIFACT_UNCERTAIN", change) }
        eq(f.calls, 0)
    }

    @Test("artifact time hints never prove absence and ordinary queue delivery consumes one event")
    func artifactTimeHints() throws {
        let f = try artifactFixture()
        for (index, stream) in f.agents.elements.enumerated() {
            for event in stream.elements {
                if index == 0 { event.removeKey("timestamp") } else { event["timestamp"] = "2099-01-01T00:00:00.000Z" }
            }
        }
        f.main.push(f.remote.at(-1))
        try f.write()
        let inv = try f.inventory()
        deq(inv["cloud"]["blocked"], [])
        deq(inv["cloud"]["matches"][0]["target"]["artifactCounts"], ["main": 366, "subagent": 104, "queued": 0])
        f.remote = f.remote.slice(365, -1)
        deq(try f.inventory()["cloud"]["matches"][0]["target"]["artifactCounts"], ["main": 0, "subagent": 104, "queued": 0])
        f.agents[0].push(f.agents[0][0])
        f.remote.push(f.agents[0][0])
        try f.write()
        deq(try f.inventory()["cloud"]["matches"][0]["target"]["artifactCounts"], ["main": 0, "subagent": 105, "queued": 0])
    }

    @Test("artifact queued string prompts retain delivery identity and stream order")
    func artifactQueuedStringPrompts() throws {
        for reverse in [false, true] {
            let f = try artifactFixture()
            f.queued["attachment"]["prompt"] = "First queued string"
            f.remote[f.remote.length - 1] = entry("user", 8000, nil, SOURCE, ["message": ["role": "user", "content": "First queued string"]])
            try f.write()
            let second: Value = [
                .spread(f.queued, ["uuid": Value(id(8200)), "attachment": .spread(f.queued["attachment"], ["source_uuid": Value(id(8001)), "delivery_id": "second-delivery", "prompt": "Second queued string"])]),
                .spread(f.removal, ["commandUuid": Value(id(8001)), "deliveryId": "second-delivery"]),
            ]
            try appendText(f.transcript, second.elements.map { JSON.text($0) }.joined(separator: "\n") + "\n")
            f.remote.push(entry("user", 8001, nil, SOURCE, ["message": ["role": "user", "content": "Second queued string"]]))
            if reverse { f.remote.asArray!.items.swapAt(f.remote.length - 2, f.remote.length - 1) }
            let inv = try f.inventory()
            if reverse { eq(inv["cloud"]["blocked"][0]["code"], "CLOUD_ARTIFACT_UNCERTAIN") }
            else { deq(inv["cloud"]["matches"][0]["target"]["artifactCounts"], ["main": 365, "subagent": 104, "queued": 2]) }
        }
    }

    @Test("artifact optional outer wrappers validate hints and reject contradictions")
    func artifactOuterWrappers() throws {
        for contradict in [false, true] {
            let f = try artifactFixture(wrappers: true), original = f.cloud["eventRows"]
            f.cloud["eventRows"] = fn { args in
                try original.call(Self.arg(args, 0)).map { row in
                    if !row["payload"]["agentId"].truthy { return row }
                    let copy = Value.spread(row, ["agentId": row["payload"]["agentId"], "isSidechain": row["payload"]["isSidechain"]])
                    if contradict { copy["agentId"] = "different" } else { copy["payload"].removeKey("agentId"); copy["payload"].removeKey("isSidechain") }
                    return copy
                }
            }
            let inv = try f.inventory()
            if contradict { eq(inv["cloud"]["blocked"][0]["code"], "CLOUD_ARTIFACT_UNCERTAIN") }
            else { eq(inv["cloud"]["matches"][0]["target"]["matchMode"], "artifacts") }
        }
    }

    @Test("artifact legacy cache upgrades preserve warm history and manifest hits")
    func artifactLegacyCacheUpgrades() throws {
        let f = try artifactFixture(), file = path.join(f.h.paths["state"].str, "cache.json"), unrelated = id(9000)
        try f.h.write(unrelated, branchEntries(12, unrelated, 12000))
        try f.h.record("Z", unrelated, rehomeRecord())
        f.to = try accounts(f.h.paths, []).find { $0["account"].str == f.h.acct.Z }
        _ = try f.inventory(["writeCache": true])
        let cache = try readJSON(file)
        eq(cache["histories"].ownKeys.count, 2)
        ok(cache["histories"].ownEntries.allSatisfy { !$0.1["value"]["result"].hasOwn("mainIdentities") })
        for (_, item) in cache["remote"].ownEntries { item["value"].removeKey("events") }
        try writeJSON(file, cache)
        let open = fs.open
        var indexed: [String] = []
        fs.open = { file, flags, mode in
            if file.hasSuffix(".jsonl") { indexed.append(file) }
            return try open(file, flags, mode)
        }
        let prior = f.reads
        let inv: Value
        do {
            defer { fs.open = open }
            inv = try f.inventory(["writeCache": true])
        }
        eq(inv["cacheStats"]["historyMisses"], 0)
        eq(inv["cacheStats"]["historyHits"], 2)
        ok((inv["cacheStats"]["manifestHits"].asNumber ?? 0) > 0)
        eq(f.reads, prior + 1)
        eq(inv["cloud"]["matches"][0]["target"]["matchMode"], "artifacts")
        ok(indexed.contains { path.basename($0) == "\(SOURCE).jsonl" })
        ok(indexed.allSatisfy { path.basename($0) == "\(SOURCE).jsonl" || path.basename(path.dirname(path.dirname($0))) == SOURCE })
        let saved = try readJSON(file)
        deq(saved["histories"], cache["histories"])
        eq(saved["version"], Value(1013))
        eq(saved["semanticVersion"], 3)
        f.remote = f.main
        f.updated = "2026-09-02T00:00:00.000Z"
        let mainOnly = try f.inventory(["writeCache": true])
        eq(mainOnly["cacheStats"]["historyHits"], 2)
        eq(mainOnly["cacheStats"]["historyMisses"], 0)
        eq(mainOnly["cloud"]["matches"][0]["target"]["matchMode"], "ordered")
        eq(mainOnly["cloud"]["artifacts"]["used"], 0)
        deq(try readJSON(file)["histories"], cache["histories"])
    }

    // The engine hash lives in artifactEngineHash: unset until a cloud check needs it, then reused. A sentinel
    // left in place after the first cloud check shows the second check did not compute it again.
    @Test("artifact engine hashing is lazy for local analysis and memoized for cloud checks")
    func artifactEngineHashing() throws {
        let saved = artifactEngineHash
        defer { artifactEngineHash = saved }
        artifactEngineHash = .undefined
        let f = try artifactFixture()
        _ = try inventory([f.from], f.to, f.h.paths, NOOP, ["processes": []])
        eq(artifactEngineHash, .undefined)
        for attempt in 0..<2 {
            let inv = try inventory([f.from], f.to, f.h.paths, NOOP, ["processes": [], "cloud": f.cloud])
            eq(inv["cloud"]["matches"][0]["target"]["matchMode"], "artifacts")
            if attempt == 0 {
                ok(artifactEngineHash.isString)
                artifactEngineHash = "memoized-sentinel"
            } else {
                eq(artifactEngineHash, "memoized-sentinel")
            }
        }
    }

    @Test("artifact limits count probes, skip unrelated large lines and suppress unchanged automatic failures")
    func artifactLimitsCountProbes() throws {
        let f = try artifactFixture()
        let prefix = (f.main.elements.map { JSON.text($0) }.joined(separator: "\n") + "\n" + JSON.text(["type": "progress", "data": ""]) + "\n").utf8.count
        f.extra.push(["type": "progress", "data": Value(String(repeating: "x", count: (65534 - prefix % 65536 + 65536) % 65536))])
        f.extra.push(["type": "progress", "data": Value(String(repeating: "x", count: 17 * 1024 * 1024))])
        try f.write()
        let complete = try f.inventory(["writeCache": true])
        eq(complete["cloud"]["matches"][0]["target"]["matchMode"], "artifacts")
        let mainBytes = try Self.size(f.transcript)
        ok((complete["cloud"]["artifacts"]["used"].asNumber ?? 0) > Double(mainBytes))
        let options: Value = ["writeCache": true, "artifactLimit": Value(mainBytes + 100)]
        let first = try f.inventory(options)
        eq(first["cloud"]["blocked"][0]["code"], "CLOUD_ARTIFACT_BUDGET")
        eq(first["cloud"]["artifacts"]["used"], Value(mainBytes))
        let second = try f.inventory(.spread(options, ["automatic": true]))
        eq(second["cloud"]["blocked"][0]["code"], "CLOUD_ARTIFACT_BUDGET")
        eq(second["cloud"]["artifacts"]["used"], 0)
        eq(second["cacheStats"]["historyMisses"], 0)
        f.updated = "2026-09-02T00:00:00.000Z"
        let changed = try f.inventory(.spread(options, ["automatic": true]))
        ok((changed["cloud"]["artifacts"]["used"].asNumber ?? 0) > 0)
        try appendText(path.join(f.directory, "agent-a0.jsonl"), "\n")
        ok((try f.inventory(.spread(options, ["automatic": true]))["cloud"]["artifacts"]["used"].asNumber ?? 0) > 0)
    }

    @Test("automatic pending cloud retries retain typed artifact limits without rescanning unchanged files")
    func automaticRetriesRetainLimits() throws {
        let f = try artifactFixture(), artifactLimit = Value(try Self.size(f.transcript) + 100)
        let moved = try move(try f.inventory(["writeCache": true, "artifactLimit": artifactLimit]), f.to, f.h.paths)
        eq(moved["receipt"]["failed"][0]["code"], "CLOUD_ARTIFACT_BUDGET")
        let open = fs.open
        var reads = 0
        fs.open = { file, flags, mode in
            if file.hasSuffix(".jsonl") { reads += 1 }
            return try open(file, flags, mode)
        }
        defer { fs.open = open }
        let key = "\(f.from["account"])/\(f.from["org"])"
        for _ in 0..<2 {
            let receipt = try readJSON(moved["file"].str)
            if receipt["cloudAttempts"].truthy { receipt["cloudAttempts"][key] = 0 }
            try writeJSON(moved["file"].str, receipt)
            let result = try finishPending(f.h.paths, ["cloud": f.cloud, "automatic": f.from, "artifactLimit": artifactLimit])
            eq(result["failed"][0]["code"], "CLOUD_ARTIFACT_BUDGET")
        }
        eq(reads, 0)
        try appendText(path.join(f.directory, "agent-a0.jsonl"), "\n")
        let receipt = try readJSON(moved["file"].str)
        receipt["cloudAttempts"][key] = 0
        try writeJSON(moved["file"].str, receipt)
        _ = try finishPending(f.h.paths, ["cloud": f.cloud, "automatic": f.from, "artifactLimit": artifactLimit])
        ok(reads > 0)
    }

    @Test("artifact relevant lines over 16 MiB are typed uncertainty and cannot authorize an archive")
    func artifactLinesOver16MiB() throws {
        let f = try artifactFixture()
        f.queued["padding"] = ""
        let image = f.queued["attachment"]["prompt"][1]["source"]
        let available = 16 * 1024 * 1024 - JSON.text(f.queued).utf8.count + image["data"].str.utf8.count
        image["data"] = Value(String(repeating: "YWJj", count: available / 4))
        f.queued["padding"] = Value(String(repeating: "x", count: available % 4))
        eq(JSON.text(f.queued).utf8.count, 16 * 1024 * 1024)
        try f.write()
        eq(try f.inventory()["cloud"]["matches"][0]["target"]["matchMode"], "artifacts")
        f.queued["padding"] = Value(f.queued["padding"].str + "x")
        try f.write()
        let inv = try f.inventory()
        deq(inv["cloud"]["matches"], [])
        eq(inv["cloud"]["blocked"][0]["code"], "CLOUD_ARTIFACT_LINE_LIMIT")
        let used: Double = inv["cloud"]["artifacts"]["used"].asNumber ?? .infinity
        ok(used <= 16 * 1024 * 1024 + 256 * 1024)
    }

    @Test("artifact search stops after complete proof but still reads required files outside the time window")
    func artifactSearchStopsAfterProof() throws {
        let f = try artifactFixture(), file = path.join(f.directory, "agent-unrelated.jsonl")
        try writeText(file, JSON.text(entry("user", 9999, nil, SOURCE, ["agentId": "unrelated", "isSidechain": true, "timestamp": "2000-01-01T00:00:00.000Z",
                                                                       "message": ["role": "user", "content": Value(String(repeating: "x", count: 17 * 1024 * 1024))]])) + "\n")
        try Self.utimes(file, "2001-01-01T00:00:00.000Z")
        let inv = try f.inventory()
        eq(inv["cloud"]["matches"][0]["target"]["matchMode"], "artifacts")
        let used: Double = inv["cloud"]["artifacts"]["used"].asNumber ?? .infinity
        ok(used < 1024 * 1024)
        try unlink(file)
        let required = path.join(f.directory, "agent-a0.jsonl")
        try writeText(required, f.agents[0].elements.map { JSON.text(.spread($0, ["timestamp": "2000-01-01T00:00:00.000Z"])) }.joined(separator: "\n") + "\n")
        try Self.utimes(required, "2001-01-01T00:00:00.000Z")
        eq(try f.inventory()["cloud"]["matches"][0]["target"]["matchMode"], "artifacts")
    }

    // Cloud analyses run in batches sized by memory.parallel(); the analyses in a batch share one artifact
    // budget. One parallel() call covers all 8 sessions at a size of 8, and a throttled budget needs 8 calls.
    @Test("artifact budget reservations remain shared across concurrent and throttled cloud analyses",
          arguments: ["together", "throttled", "alone", "refused first"])
    func artifactBudgetReservationsShared(scenario: String) throws {
        let h = try home(), sources = (0..<8).map { id(9000 + $0) }
        let histories = Value.newObject()
        var costs: [Int] = []
        for (index, sid) in sources.enumerated() {
            let main = branchEntries(4, sid, 10000 + index * 10), agent = entry("assistant", 11000 + index, nil, sid, ["agentId": "fixture", "isSidechain": true])
            histories["cse_parallel\(index)"] = main.concat([agent])
            try h.write(sid, main)
            try h.record("Z", sid, rehomeRecord(["bridgeSessionIds": [Value("session_parallel\(index)")]]))
            let directory = path.join(h.project, sid, "subagents")
            try mkdirp(directory)
            let text = JSON.text(.spread(agent, ["sessionId": Value(scenario == "refused first" && index == 0 ? id(9999) : sid)])) + "\n"
            try writeText(path.join(directory, "agent-fixture.jsonl"), text)
            costs.append(try Self.size(h.transcript(sid)) + 2 * text.utf8.count)
        }
        var selected = histories.ownKeys, batches = 0
        let cloud = cloudFixture(h, [
            "memory": ["check": NOOP, "parallel": fn { _ in batches += 1; return scenario == "throttled" ? 1 : 8 }],
            "list": fn { _ in Value(selected.map { remoteSession(["id": Value($0), "title": Value($0)]) }) },
            "eventRows": fn { args in remoteRows(histories[Self.arg(args, 0).str]) },
        ])
        let all = try accounts(h.paths, []), from = all.find { $0["account"].str == h.acct.P }, to = all.find { $0["account"].str == h.acct.Z }
        let artifactLimit = scenario == "refused first" ? costs.max()! : 4000
        ok(costs.allSatisfy { $0 <= artifactLimit })
        ok(costs.reduce(0, +) > artifactLimit)
        let run = { (automatic: Bool) in
            try inventory([from], to, h.paths, NOOP, ["cloud": cloud, "processes": [], "artifactLimit": Value(artifactLimit), "automatic": Value(automatic), "writeCache": true])
        }
        let before = try fixtureSnapshot(h, [h.paths["pool"].str])
        let first = try run(false)
        eq(batches, scenario == "throttled" ? 8 : 1)
        ok((first["cloud"]["artifacts"]["used"].asNumber ?? .infinity) <= Double(artifactLimit))
        ok((first["cloud"]["artifacts"]["used"].asNumber ?? 0) > 0)
        if scenario == "refused first" {
            eq(first["cloud"]["matches"].length, 0)
            eq(first["cloud"]["blocked"][0]["code"], "CLOUD_ARTIFACT_UNCERTAIN")
        } else {
            ok(first["cloud"]["matches"].length > 0 && first["cloud"]["matches"].length < 8)
        }
        let deferred = first["cloud"]["blocked"].filter { $0["code"] == "CLOUD_ARTIFACT_BUDGET" }
        ok(deferred.length > 0)
        let cache = try readJSON(path.join(h.paths["state"].str, "cache.json"))
        for row in deferred.elements {
            let value = cache["remote"][row["id"].str]["value"]
            eq(value["artifactFailure"], .undefined)
            ok(isSafeInteger(value["artifactDeferred"]) && (value["artifactDeferred"].asNumber ?? 0) > 0)
        }
        var completed = Set(first["cloud"]["matches"].elements.map { $0["session"]["id"].str })
        let refused: String? = scenario == "refused first" ? "cse_parallel0" : nil
        selected = scenario == "alone" ? [deferred[0]["id"].str] : selected.filter { !completed.contains($0) }
        var pass = 0
        while selected.contains(where: { $0 != refused }) && pass < 8 {
            let next = try run(true)
            ok((next["cloud"]["artifacts"]["used"].asNumber ?? .infinity) <= Double(artifactLimit))
            ok(next["cloud"]["matches"].length > 0, "\(scenario): \(JSON.text(next["cloud"]["blocked"]))")
            ok(next["cloud"]["matches"].every { $0["target"]["matchMode"] == "artifacts" })
            for row in next["cloud"]["matches"].elements { completed.insert(row["session"]["id"].str) }
            selected = selected.filter { !completed.contains($0) }
            pass += 1
        }
        ok(selected.allSatisfy { $0 == refused }, scenario)
        if scenario != "alone" { eq(completed.count, refused != nil ? 7 : 8) }
        deq(try fixtureSnapshot(h, [h.paths["pool"].str]), before)
    }

    @Test("artifact checks that establish missing history keep the mirror in its account")
    func artifactChecksKeepMirror() throws {
        let f = try artifactFixture(), h = f.h
        try unlink(f.taskFile)
        try h.record("Z", SOURCE, rehomeRecord(["bridgeSessionIds": ["session_artifacts"]]))
        f.to = try accounts(h.paths, []).find { $0["account"].str == h.acct.Z }
        f.agents[0].asArray!.items.removeFirst()
        try f.write()
        let before = try fixtureSnapshot(h, [h.paths["pool"].str]), inv = try f.inventory()
        deq(inv["cloud"]["matches"], [])
        eq(inv["cloud"]["blocked"][0]["code"], "CLOUD_UNPROVEN")
        let result = try move(inv, f.to, h.paths)
        eq(result["ok"], true)
        deq(result["summary"]["kept"].map { $0["code"] }, ["CLOUD_UNPROVEN"])
        eq(f.calls, 0)
        deq(result["receipt"]["sessions"], [])
        for (file, hash) in before.ownEntries { eq(Value(sha(try readData(file))), hash) }
    }

    @Test("artifact final proof rejects changed UUIDs, roles and fresh file fingerprints", arguments: ["uuid", "role", "payload", "sidecar"])
    func artifactFinalProofRejects(change: String) throws {
        let f = try artifactFixture(), inv = try f.inventory()
        eq(inv["cloud"]["matches"][0]["target"]["matchMode"], "artifacts")
        let original = f.cloud["eventRows"]
        f.cloud["eventRows"] = fn { args in
            let id = Self.arg(args, 0)
            if change == "sidecar" {
                f.agents[0][0]["sessionId"] = Value(id == "cse_artifacts" ? String(SOURCE.dropLast()) + "2" : SOURCE)
                try f.write()
            }
            let rows = try original.call(id)
            if change == "uuid" { rows[365]["payload"]["uuid"] = "00000000-0000-4000-8000-000000099999" }
            if change == "role" { rows[365]["payload"]["message"]["role"] = "assistant" }
            if change == "payload" { rows[365]["payload"]["message"]["content"] = "Changed after inventory" }
            return rows
        }
        let moved = try move(inv, f.to, f.h.paths)
        eq(f.calls, 0, change)
        eq(moved["ok"], false, change)
        eq(moved["receipt"]["remote"].length, 0, change)
        eq(moved["receipt"]["remotePending"], .undefined, change)
    }
}
