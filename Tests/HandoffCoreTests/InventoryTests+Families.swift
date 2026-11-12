import Foundation
import Testing
@testable import HandoffCore

extension Engine.Inventory {
    @Test("task state conflicts preserve pre-existing destination entries before and after planning")
    func taskStateConflicts() throws {
        for key in ["recordedSkips", "runRetries"] {
            for late in [false, true] {
                let h = try taskFamilyFixture(), (from, to) = try h.selection()
                let planned: Value = late ? try inventory([from], to, h.paths, NOOP, ["processes": []]) : .null
                let conflict = Value.spread(h.targetRegistry, [key: .spread(h.targetRegistry[key], ["task_0": ["conflict": true]])])
                try writeJSON(h.targetFile, conflict)
                let fresh = try h.selection()
                let plan = planned.isNull ? try inventory([fresh.from], fresh.to, h.paths, NOOP, ["processes": []]) : planned
                let result = try move(plan, fresh.to, h.paths)
                eq(result["ok"], false)
                deq(result["receipt"]["sessions"].map { $0["id"] }, [Value(h.cold)])
                match(result["receipt"]["failed"].map { $0["error"] }.join(" "), "task state collision")
                deq(try readJSON(h.targetFile), conflict)
                deq(try readJSON(h.sourceFile), h.sourceRegistry)
            }
        }
    }

    @Test("replay metadata moves a notification family and genuine conflicts identify dependent runs")
    func notificationFamilyReplayMetadata() throws {
        for conflict in [nil, "message", "producer"] as [String?] {
            let h = try taskFamilyFixture(), child = id(705)
            let original = entry("assistant", 1, nil, SOURCE, ["origin": ["producer": "desktop"], "message": ["role": "assistant", "content": "same answer", "usage": ["output_tokens": 42]]])
            let replay = Value.spread(original, ["origin": [:], "message": .spread(original["message"], ["usage": ["output_tokens": 0]])])
            if conflict == "message" { replay["message"]["content"] = "different answer" }
            if conflict == "producer" { replay["origin"]["producer"] = "other" }
            try h.write(SOURCE, [original, replay])
            try h.record("P", SOURCE, rehomeRecord(["title": "Notification conversation"]))
            try h.write(child, fork([original, replay], SOURCE, child, "Notification fork"))
            try h.record("P", child, rehomeRecord(["title": "Notification fork", "forkedFromSessionId": Value("local_\(SOURCE)"), "isArchived": true]))
            let (from, to) = try h.selection(), before = try fixtureSnapshot(h, [h.paths["pool"].str])
            let processes: Value = conflict != nil ? desktopFixture(SOURCE) : []
            let inv = try inventory([from], to, h.paths, NOOP, ["processes": processes])
            if conflict != nil {
                deq(inv["move"].map { $0["id"] }, [Value(h.cold)])
                for row in inv["blocked"].elements {
                    match(row["error"], [SOURCE, child].contains(row["id"].str) ? "^1 conflicting duplicate uuids$" : "^scheduled task family blocked by ")
                }
                ok(inv["blocked"].filter { [h.run, h.second].contains($0["id"].str) }.every { $0["conflicts"] == 0 })
            } else {
                eq(inv["move"].filter { $0["taskFamily"].truthy }.length, 4)
            }
            let result = try executeMove([from], to, h.paths, ["processes": processes, "moveOnly": true])
            eq(result["receipt"]["sessions"].length, conflict != nil ? 1 : 5)
            eq(result["receipt"]["held"].length, 0)
            deq(try fixtureSnapshot(h, [h.paths["pool"].str]), before)
            if conflict != nil {
                deq(.fromEntries(result["summary"]["groups"].elements.map { ($0["cause"].str, Value($0["records"].length)) }), ["history check": 2, "waiting on task family": 2])
                deq(try readJSON(h.sourceFile), h.sourceRegistry)
            } else {
                eq(result["ok"], true)
                eq(result["receipt"]["superseded"].filter { $0["source"].truthy }.length, 5)
                deq(try readJSON(h.targetFile), h.targetAfter)
                eq(try readJSON(h.recordFile("T", child))["forkedFromSessionId"], Value("local_\(SOURCE)"))
                ok(try undo(h.paths, ["processes": []])["dest"])
                deq(try readJSON(h.sourceFile), h.sourceRegistry)
            }
        }
    }

    @Test("task families include parent and fork closure without merging matching history")
    func taskFamilyClosure() throws {
        let h = try taskFamilyFixture(), parent = id(704), child = id(705)
        try h.write(parent, [entry("user", 90, nil, parent)])
        try h.record("P", parent, rehomeRecord())
        try h.record("P", SOURCE, rehomeRecord(["forkedFromSessionId": Value("local_\(parent)")]))
        try h.write(child, [entry("user", 91, nil, child)])
        try h.record("P", child, rehomeRecord(["forkedFromSessionId": Value("local_\(SOURCE)"), "isArchived": true]))
        try h.record("Q", SOURCE, rehomeRecord())
        let (from, to) = try h.selection()
        let inv = try inventory([from], to, h.paths, NOOP, ["processes": []])
        eq(inv["move"].filter { $0["taskFamily"].truthy }.length, 5)
        let result = try move(inv, to, h.paths)
        eq(result["ok"], true)
        eq(result["receipt"]["sessions"].length, 6)
        ok(exists(h.recordFile("Q", SOURCE)))
        ok(try undo(h.paths, ["processes": []])["dest"])
    }

    @Test("progress excludes no-history placeholders and retains meaningful grouped refusals")
    func progressExcludesPlaceholders() throws {
        for shape in ["ordinary", "grouped", "partial"] {
            let h: Home = shape == "grouped" ? try taskFamilyFixture() : try home()
            let empty = id(799)
            var reports: [Value] = []
            if shape != "grouped" { try h.write(SOURCE, [entry("user", 801, nil, SOURCE)]); try h.record("P", SOURCE, rehomeRecord()) }
            try h.record("P", empty, rehomeRecord())
            if shape == "partial" {
                let refused = id(790)
                try h.write(refused, [entry("user", 802, nil, refused), entry("user", 802, nil, refused, ["message": ["role": "user", "content": "Conflicting history"]])])
                try h.record("P", refused, rehomeRecord())
                try h.record("Q", refused, rehomeRecord())
            }
            let all = try accounts(h.paths, []), from = all.find { $0["account"].str == h.acct.P }, to = all.find { $0["account"].str == h.acct.T }
            let result = try executeMove([from], to, h.paths, ["processes": [], "report": fn { args in
                if Self.arg(args, 0) == "sessions" { reports.append(Self.arg(args, 2)) }
                return .undefined
            }])
            let expected = shape == "grouped" ? 4 : shape == "partial" ? 2 : 1
            ok(!reports.isEmpty && reports.allSatisfy { $0["sessionTotal"] == Value(expected) }, JSON.text(Value(reports)))
            eq(reports.last?["remainingCount"] ?? .undefined, Value(result["summary"]["notMoved"].length))
            eq(result["summary"]["notMoved"].length, shape == "partial" ? 1 : 0)
            eq(result["summary"]["moved"], Value(shape == "grouped" ? 4 : 1))
            eq(result["complete"], true)
            ok(exists(h.recordFile("P", empty)))
            ok(!exists(h.recordFile("T", empty)))
        }
    }

    @Test("rehome eligibility stays narrow around ownership locks")
    func rehomeEligibilityNarrow() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE), entry("assistant", 2, 1, SOURCE)])
        try h.record("P", SOURCE, rehomeRecord())
        try mkdirp(path.join(h.paths["records"].str, h.acct.P, h.org.T))
        let sourceRecord = try readJSON(h.recordFile("P", SOURCE))
        try writeJSON(h.recordFile("P", SOURCE), .spread(sourceRecord, ["scheduledTaskId": "task_fixture"]))
        let from = try h.account("P"), to = try h.account("P", org: "T")
        let inv = try inventory([from], to, h.paths)
        eq(inv["move"].length, 0)
        eq(inv["blocked"].length, 1)
        match(inv["blocked"][0]["error"], "scheduled task")
    }

    @Test("an unresolved parent is named and left untouched")
    func unresolvedParent() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE, ["forkedFromSessionId": Value("local_\(id(778))")])
        let from = try h.account("P"), to = try h.account("Z")
        let inv = try inventory([from], to, h.paths)
        deq(inv["move"], [])
        eq(inv["blocked"].length, 1)
        match(inv["blocked"][0]["error"], "parent Desktop record is absent")
        let result = try move(inv, to, h.paths)
        eq(result["ok"], false)
        eq(result["validationOnly"], true)
        ok(exists(h.recordFile("P", SOURCE)))
        deq(try Self.names(h.dir("Z")), [])
    }

    @Test("same-account rehome preserves a parent link when both records move")
    func sameAccountRehomeParentLink() throws {
        let h = try home()
        let teamDir = path.join(h.paths["records"].str, h.acct.P, h.org.T)
        try mkdirp(teamDir)
        let child = id(778)
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.write(child, [entry("user", 2, nil, child)])
        try h.record("P", SOURCE, rehomeRecord())
        try h.record("P", child, rehomeRecord(["forkedFromSessionId": Value("local_\(SOURCE)")]))
        let from = try h.account("P"), to = try h.account("P", org: "T")
        let inv = try inventory([from], to, h.paths)
        deq(inv["move"].map { $0["strategy"] }, ["rehome", "rehome"])
        let result = try move(inv, to, h.paths)
        eq(result["ok"], true)
        eq(result["receipt"]["sessions"].every { $0["strategy"] == "rehome" }, true)
        let childRecord = try readJSON(path.join(teamDir, "local_\(child).json"))
        eq(childRecord["forkedFromSessionId"], Value("local_\(SOURCE)"))
        deq(.strings(try readdir(h.project).sorted()), .strings(["\(SOURCE).jsonl", "\(child).jsonl"].sorted()))
    }

    @Test("a Desktop fork is preserved when its parent already covers its history in the destination")
    func forkPreservedWhenParentCovers() throws {
        let h = try home(), child = id(777)
        let base: Value = [entry("user", 1, nil, SOURCE), entry("assistant", 2, 1, SOURCE)]
        try h.write(SOURCE, base)
        try h.write(child, fork(base, SOURCE, child, "Archived fork"))
        try h.record("T", SOURCE, rehomeRecord(["title": "Parent"]))
        try h.record("P", child, rehomeRecord(["title": "Archived fork", "isArchived": true, "forkedFromSessionId": Value("local_\(SOURCE)")]))
        let all = try accounts(h.paths), from = all.find { $0["account"].str == h.acct.P }, to = all.find { $0["account"].str == h.acct.T }
        let inv = try inventory([from], to, h.paths)
        eq(inv["there"].length, 0)
        deq(inv["move"].map { $0["id"] }, [Value(child)])
        let moved = try move(inv, to, h.paths)
        eq(moved["ok"], true)
        eq(moved["receipt"]["superseded"].some { !$0["source"].truthy }, false)
        deq(try Self.names(h.dir("P")), [])
        deq(.strings(try readdir(h.dir("T")).sorted()), .strings(["local_\(SOURCE).json", "local_\(child).json"].sorted()))
        let archived = try readJSON(h.recordFile("T", child))
        eq(archived["isArchived"], true)
        eq(archived["forkedFromSessionId"], Value("local_\(SOURCE)"))
    }

    @Test("destination parents survive richer replacements while Desktop forks still refer to them")
    func destinationParentsSurvive() throws {
        for location in ["source", "destination", "without history"] {
            for isArchived in [false, true] {
                let h = try home(), richer = id(776), child = id(777)
                let base = branchEntries(2, SOURCE, 1)
                try h.write(SOURCE, base)
                try h.record("T", SOURCE, rehomeRecord(["title": "Parent"]))
                try h.write(richer, fork(base, SOURCE, richer, "Richer copy").concat([entry("user", 3, nil, richer)]))
                try h.record("P", richer, rehomeRecord(["title": "Richer copy"]))
                if location != "without history" { try h.write(child, fork(base, SOURCE, child, "Fork")) }
                try h.record(location == "source" ? "P" : "T", child, rehomeRecord(["title": "Fork", "isArchived": Value(isArchived), "forkedFromSessionId": Value("local_\(SOURCE)")]))
                let all = try accounts(h.paths), from = all.find { $0["account"].str == h.acct.P }, to = all.find { $0["account"].str == h.acct.T }
                let originals = try (from["sessions"].elements + to["sessions"].elements).map { ($0["file"].str, try readData($0["file"].str)) }
                let inv = try inventory([from], to, h.paths)
                deq(inv["move"].map { $0["id"] }, location == "source" ? [Value(richer), Value(child)] : [Value(richer)])
                let moved = try move(inv, to, h.paths)
                eq(moved["ok"], true)
                eq(moved["receipt"]["superseded"].some { !$0["source"].truthy }, false)
                deq(try Self.names(h.dir("P")), [])
                deq(.strings(try readdir(h.dir("T")).sorted()), .strings([SOURCE, richer, child].map { "local_\($0).json" }.sorted()))
                let placed = try readJSON(h.recordFile("T", child))
                eq(placed["forkedFromSessionId"], Value("local_\(SOURCE)"))
                eq(placed["isArchived"], Value(isArchived))
                ok(try undo(h.paths)["dest"])
                deq(.strings(try readdir(h.dir("T")).sorted()), .strings(to["sessions"].elements.map { path.basename($0["file"].str) }.sorted()))
                for (file, bytes) in originals { #expect(try readData(file) == bytes) }
            }
        }
    }

    @Test("required Desktop parents move by exact id despite richer compatible histories")
    func requiredParentsMoveByExactId() throws {
        for location in ["P", "T"] {
            let h = try home(), richer = id(776), child = id(777), base = branchEntries(2, SOURCE, 1)
            try h.write(SOURCE, base)
            try h.record("P", SOURCE, rehomeRecord())
            try h.write(richer, fork(base, SOURCE, richer, "Richer").concat([entry("user", 3, nil, richer)]))
            try h.record(location, richer, rehomeRecord())
            try h.write(child, fork(base, SOURCE, child, "Fork"))
            try h.record("P", child, rehomeRecord(["isArchived": true, "forkedFromSessionId": Value("local_\(SOURCE)")]))
            let all = try accounts(h.paths), from = all.find { $0["account"].str == h.acct.P }, to = all.find { $0["account"].str == h.acct.T }
            let originals = try from["sessions"].elements.map { ($0["file"].str, try readData($0["file"].str)) }
            let inv = try inventory([from], to, h.paths)
            deq(inv["blocked"], [])
            deq(inv["there"], [])
            ok(inv["move"].findIndex { $0["id"].str == SOURCE } < inv["move"].findIndex { $0["id"].str == child })
            let moved = try move(inv, to, h.paths)
            eq(moved["ok"], true)
            deq(moved["receipt"]["failed"], [])
            deq(try Self.names(h.dir("P")), [])
            let placed = try readJSON(h.recordFile("T", child))
            eq(placed["forkedFromSessionId"], Value("local_\(SOURCE)"))
            eq(placed["isArchived"], true)
            ok(exists(h.recordFile("T", SOURCE)))
            ok(try undo(h.paths)["dest"])
            for (file, bytes) in originals { #expect(try readData(file) == bytes) }
            deq(try Self.names(h.dir("T")), location == "T" ? [Value("local_\(richer).json")] : [])
        }
    }
}
