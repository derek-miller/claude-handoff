import Foundation
import Testing
@testable import HandoffCore

extension Engine.Restarts {
    @Test("a thousand source records finish one restart with bounded polling and a linear journal")
    func thousandSourceRecords() throws {
        let h = try home(), amount = 1000
        for i in 0..<amount {
            let session = id(10000 + i)
            try h.write(session, [entry("user", 20000 + i, nil, session)])
            try h.record("P", session, rehomeRecord(["sessionSettings": ["fixture": Value(String(repeating: "x", count: 4096))]]))
        }
        let (from, to) = try Self.pair(h)
        var rows = desktopFixture(id(10000)), inspections = 0, journalBytes = 0, checkpointBytes = 0
        let io: Value = ["inspect": fn { _ in inspections += 1; return rows }, "command": fn { args in
            rows = args[0].str.hasSuffix("osascript") ? [] : Self.reopened()
            return ["status": 0]
        }]
        let planned = try executeMove([from], to, h.paths, ["io": io])
        let state = h.paths["state"].str
        let result = try executeMove([from], to, h.paths, ["io": io, "approve": planned["plan"]["token"], "report": fn { args in
            let progress = Self.arg(args, 2)
            if args[0] != "move" || !progress["live"].truthy || (progress["total"].asNumber ?? 0) < Double(amount - 1) || progress["completed"] !== progress["total"] { return .undefined }
            let log = try readdir(state).first { $0.hasSuffix(".journal") }!
            journalBytes = try readData(path.join(state, log)).count
            checkpointBytes = try readData(path.join(state, String(log.dropLast(8)))).count
            return .undefined
        }])
        eq(result["ok"], true)
        eq(result["receipt"]["sessions"].length, amount)
        eq(result["receipt"]["superseded"].length, amount)
        #expect(try readdir(h.dir("P")) == [])
        eq(try readdir(h.dir("T")).count, amount)
        ok(inspections < 150, "Unexpected process scans: \(inspections)")
        ok(checkpointBytes < 5000, "Receipt was rewritten during placement: \(checkpointBytes)")
        ok(journalBytes > 0)
        ok(journalBytes < 12_000 * amount, "Journal grew beyond its per-record bound: \(journalBytes)")
        ok(!(try readdir(state)).contains { $0.hasSuffix(".journal") })
        ok(try undo(h.paths)["dest"])
        eq(try readdir(h.dir("P")).count, amount)
        eq(try readdir(h.dir("T")).count, 0)
    }

    @Test("a thousand records in one task family finish one restart with linear reads")
    func thousandTaskFamilyRecords() throws {
        let h = try home(), amount = 1000, first = id(10000)
        let registry: Value = ["scheduledTasks": [["id": "large_task", "notifySessionId": Value("local_\(first)"), "enabled": false, "fireAt": 123456]],
                               "recordedSkips": ["large_task": [["at": "2026-09-02T00:00:00Z", "reason": "app_closed"]]],
                               "runRetries": ["large_task": ["slot": "2026-09-02T00:00:00Z", "attempts": 2, "notBefore": "2026-09-02T00:05:00Z"]]]
        for i in 0..<amount {
            let sid = id(10000 + i)
            try h.write(sid, [entry("user", 20000 + i, nil, sid)])
            try h.record("P", sid, rehomeRecord(i > 0 ? ["scheduledTaskId": "large_task", "notifySessionId": Value("local_\(first)")] : [:]))
        }
        let sourceFile = path.join(h.dir("P"), "scheduled-tasks.json"), targetFile = path.join(h.dir("T"), "scheduled-tasks.json")
        try writeJSON(sourceFile, registry)
        let (from, to) = try Self.pair(h, "P", "T", [])
        var rows: Value = [desktopFixture()[0]], recordReads = 0, namespaceReads = 0, calls: [String] = []
        let io: Value = ["inspect": fn { _ in rows }, "command": fn { args in
            calls.append(args[0].str)
            rows = args[0].str.hasSuffix("osascript") ? [] : Self.reopened("reopened")
            return ["status": 0]
        }]
        let planned = try executeMove([from], to, h.paths, ["io": io])
        eq(planned["plan"]["held"].length, amount)
        let read = fs.readFile, list = fs.readdir
        fs.readFile = { p in
            if TextPattern.cached(#"^local_.*\.json$"#).test(path.basename(p)) { recordReads += 1 }
            return try read(p)
        }
        fs.readdir = { p in
            if [h.dir("P"), h.dir("T")].contains(p) { namespaceReads += 1 }
            return try list(p)
        }
        let result = try executeMove([from], to, h.paths, ["io": io, "approve": planned["plan"]["token"]])
        fs.readFile = read
        fs.readdir = list
        eq(result["ok"], true, result["reason"].description)
        eq(result["restarted"], true)
        #expect(calls == ["/usr/bin/osascript", "/usr/bin/open"])
        eq(result["receipt"]["sessions"].length, amount)
        eq(result["receipt"]["superseded"].length, amount)
        eq(result["receipt"]["taskTransfers"].length, 1)
        eq(result["receipt"]["finalizing"], false)
        deq(try readJSON(sourceFile), ["scheduledTasks": [], "recordedSkips": [:], "runRetries": [:]])
        deq(try readJSON(targetFile), registry)
        #expect(try readdir(h.dir("P")) == ["scheduled-tasks.json"])
        eq(try readdir(h.dir("T")).filter { $0.hasPrefix("local_") }.count, amount)
        ok(recordReads < 80 * amount, "Unexpected record reads: \(recordReads)")
        ok(namespaceReads < 80, "Unexpected namespace scans: \(namespaceReads)")
        let receipt = try readJSON(result["file"].str)
        eq(receipt["taskTransfers"][0]["links"].length, amount)
        eq(receipt["taskTransfers"][0]["recordIds"].length, amount)
        ok(try undo(h.paths, ["processes": []])["dest"])
        deq(try readJSON(sourceFile), registry)
        eq(try readdir(h.dir("P")).filter { $0.hasPrefix("local_") }.count, amount)
        #expect(try readdir(h.dir("T")) == [])
    }

    @Test("one restart batches the 361 record seven family shape and multiple registry pairs")
    func restartBatchesFamilyShape() throws {
        let shapes: [(ordinary: Int, sizes: [Int], pairs: Int, padding: Int)] = [(243, [11, 1, 1, 3, 96, 2, 4], 1, 30000), (3, [2, 1, 3, 2], 2, 0)]
        for (ordinary, sizes, pairs, padding) in shapes {
            let h = try home(), sources = Array(["P", "Q"].prefix(pairs))
            var registries: [String: Value] = [:]
            for key in sources { registries[key] = ["scheduledTasks": [], "recordedSkips": [:], "runRetries": [:]] }
            var index = 0
            let add = { (key: String, extra: Value) throws -> String in
                let sid = id(10000 + index)
                index += 1
                try h.write(sid, [entry("user", 20000 + index, nil, sid)])
                try h.record(key, sid, rehomeRecord(.spread(["fixturePadding": Value(String(repeating: "x", count: padding))], extra)))
                return sid
            }
            for _ in 0..<ordinary { _ = try add("P", [:]) }
            for (n, size) in sizes.enumerated() {
                let key = sources[n % pairs], anchor = id(10000 + index), taskId = "fixture_task_\(n)", registry = registries[key]!
                registry["scheduledTasks"].push(["id": Value(taskId), "notifySessionId": Value("local_\(anchor)"), "enabled": false, "fireAt": Value(123456 + n)])
                registry["recordedSkips"][taskId] = [["reason": "closed", "at": Value(n)]]
                registry["runRetries"][taskId] = ["attempts": Value(n)]
                for j in 0..<size { _ = try add(key, j > 0 ? ["scheduledTaskId": Value(taskId), "notifySessionId": Value("local_\(anchor)")] : [:]) }
            }
            for key in sources { try writeJSON(path.join(h.dir(key), "scheduled-tasks.json"), registries[key]!) }
            let all = try accounts(h.paths, []), from = Value(sources.map { key in all.find { $0["account"].str == h.acct[key] } }), to = all.find { $0["account"].str == h.acct.T }
            let mock = taskHarness()
            mock.io.removeKey("now")
            var beforeReceipt = ""
            let held = sizes.reduce(0, +)
            mock.beforeQuit = {
                eq(try readdir(h.dir("T")).filter { $0.hasPrefix("local_") }.count, ordinary)
                let names = receiptFiles(h)
                eq(names.count, 1)
                beforeReceipt = names[0]
                let receipt = try readJSON(beforeReceipt)
                eq(receipt["finalizing"], false)
                eq(receipt["sessions"].length, ordinary)
                eq(receipt["held"].length, held)
            }
            let planned = try executeMove(from, to, h.paths, ["io": mock.io])
            eq(planned["plan"]["remainingCount"], Value(index))
            eq(Set(planned["plan"]["held"].flatMap { $0["sources"].map { $0["file"] } }.elements.map(\.str)).count, held)
            var recordReads = 0, receiptWrites = 0, namespaceScans = 0
            let records = h.paths["records"].str, state = h.paths["state"].str
            let read = fs.readFile, write = fs.writeFile, list = fs.readdir
            fs.readFile = { p in
                let result = try read(p)
                if p.hasPrefix(records) && TextPattern.cached(#"^local_.*\.json$"#).test(path.basename(p)) { recordReads += 1 }
                return result
            }
            fs.writeFile = { p, d, flag, m in
                if p.hasPrefix(state) && !p.contains("cache.json") { receiptWrites += 1 }
                try write(p, d, flag, m)
            }
            fs.readdir = { p in if p.hasPrefix(records) { namespaceScans += 1 }; return try list(p) }
            let result = try executeMove(from, to, h.paths, ["io": mock.io, "approve": planned["plan"]["token"]])
            fs.readFile = read
            fs.writeFile = write
            fs.readdir = list
            eq(result["ok"], true, result["reason"].description)
            eq(result["receipt"]["sessions"].length, index)
            eq(result["receipt"]["superseded"].length, index)
            eq(result["receipt"]["taskTransfers"].length, pairs)
            eq(result["file"], Value(beforeReceipt))
            eq(result["added"], Value(index))
            #expect(mock.calls == ["/usr/bin/osascript", "/usr/bin/open"])
            ok(recordReads < 25 * index, "record reads \(recordReads)")
            ok(receiptWrites < 12 + 10 * pairs, "receipt writes \(receiptWrites)")
            ok(namespaceScans < 40 + 10 * pairs, "namespace scans \(namespaceScans)")
            let events = try Self.restartEvents(h)
            deq(events.map { $0["event"] }, ["start", "exited", "outcome"])
            eq(Set(events.elements.map { $0["attemptId"].str }).count, 1)
            ok(events.every { $0["receiptId"].str == path.basename(result["file"].str) })
            eq(events.at(-1)["stopCode"], "COMPLETE")
            let targetFile = path.join(h.dir("T"), "scheduled-tasks.json"), target = try readJSON(targetFile)
            #expect(target["scheduledTasks"].elements.map { $0["id"].str }.sorted() == sources.flatMap { registries[$0]!["scheduledTasks"].elements.map { $0["id"].str } }.sorted())
            target["later"] = "unrelated edit"
            target["scheduledTasks"].push(["id": "later_task", "enabled": false])
            try writeJSON(targetFile, target)
            let later = id(99000)
            try h.record("T", later, rehomeRecord())
            ok(try undo(h.paths, ["processes": []])["dest"])
            deq(try readJSON(targetFile), ["scheduledTasks": [["id": "later_task", "enabled": false]], "later": "unrelated edit"])
            ok(exists(h.recordFile("T", later)))
            for key in sources { deq(try readJSON(path.join(h.dir(key), "scheduled-tasks.json")), registries[key]!) }
        }
    }
}
