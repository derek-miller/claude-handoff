import Darwin
import Foundation
import Testing
@testable import HandoffCore

extension Engine.Inventory {
    @Test("a malformed source already present in the target is named and left untouched")
    func malformedSourceInTarget() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE, rehomeRecord(["sessionId": nil, "title": "Malformed source"]))
        try h.record("Z", SOURCE, rehomeRecord(["title": "Valid target"]))
        let from = try h.account("P"), to = try h.account("Z")
        let inv = try inventory([from], to, h.paths)
        let result = try move(inv, to, h.paths)
        eq(inv["there"].length, 0)
        match(inv["rejected"][0]["error"], "Desktop record identity is invalid")
        eq(result["ok"], false)
        ok(exists(h.recordFile("P", SOURCE)))
    }

    @Test("an unreadable scheduled task registry fails closed")
    func unreadableTaskRegistry() throws {
        let h = try home()
        try h.write(id(929), [entry("user", 929, nil, id(929))])
        try h.record("P", id(929))
        let taskFile = path.join(h.dir("P"), "scheduled-tasks.json")
        try writeText(taskFile, "[]")
        var by = try Self.byAccount(h)
        match(by[h.acct.P]!["taskError"], "invalid scheduled task registry")
        match(by[h.acct.P]!["stats"], "task registry unreadable")
        let blocked = try inventory([by[h.acct.P]!], by[h.acct.Z]!, h.paths)
        eq(blocked["move"].length, 0)
        match(blocked["blocked"][0]["error"], "invalid scheduled task registry")
        try writeJSON(taskFile, ["scheduledTasks": []])
        by = try Self.byAccount(h)
        let inv = try inventory([by[h.acct.P]!], by[h.acct.Z]!, h.paths)
        throwsError("unreadable scheduled task registry") {
            try move(inv, by[h.acct.Z]!, h.paths, fn { args in
                if Self.arg(args, 0) == "verify" && Self.arg(args, 2)["completed"] == 0 { try writeText(taskFile, "{broken") }
                return .undefined
            })
        }
        eq(try readdir(h.dir("P")).filter { $0.hasPrefix("local_") }.count, 1)
    }

    @Test("duplicate source records for one transcript move once and retire every owner")
    func duplicateSourceRecords() throws {
        let h = try home()
        try h.write(id(926), [entry("user", 926, nil, id(926))])
        try h.record("P", id(926))
        try h.record("T", id(926))
        let by = try Self.byAccount(h)
        let inv = try inventory([by[h.acct.P]!, by[h.acct.T]!], by[h.acct.Z]!, h.paths)
        eq(inv["sources"].length, 2)
        eq(inv["move"].length, 1)
        eq(inv["blocked"].length, 0)
        let result = try move(inv, by[h.acct.Z]!, h.paths)
        eq(result["ok"], true)
        eq(result["receipt"]["sessions"].length, 1)
        eq(result["receipt"]["superseded"].filter { $0["source"].truthy }.length, 2)
        deq(try Self.names(h.dir("P")), [])
        deq(try Self.names(h.dir("T")), [])
        deq(try Self.names(h.dir("Z")), [Value("local_\(id(926)).json")])
    }

    @Test("unsupported sidecar entries name the path instead of looking like drift")
    func unsupportedSidecarEntries() throws {
        let h = try home()
        try h.write(id(984), [entry("user", 984, nil, id(984))])
        let dir = path.join(h.project, id(984))
        try mkdirp(dir)
        #expect(Darwin.mkfifo(path.join(dir, "linked"), 0o644) == 0)
        try h.record("P", id(984))
        let by = try Self.byAccount(h)
        let inv = try inventory([by[h.acct.P]!], by[h.acct.Z]!, h.paths)
        match(inv["rejected"][0]["error"], "unsupported entry .*linked")
        let result = try move(inv, by[h.acct.Z]!, h.paths)
        eq(result["validationOnly"], true)
        eq(result["receipt"]["failed"][0]["id"], Value(id(984)))
    }

    @Test("versions that grew apart both move and are counted")
    func versionsGrewApart() throws {
        let h = try home()
        let m1: Value = [entry("user", 980, nil, id(980)), entry("assistant", 981, 980, id(980))]
        try h.write(id(980), m1.concat([entry("user", 982, 981, id(980))]))
        try h.record("P", id(980))
        try h.write(id(990), fork(m1, id(980), id(990), "M").concat([entry("user", 983, nil, id(990))]))
        try h.record("T", id(990))
        let by = try Self.byAccount(h)
        let inv = try inventory([by[h.acct.P]!, by[h.acct.T]!], by[h.acct.Z]!, h.paths)
        eq(inv["apart"], 2)
        deq(inv["move"].map { $0["id"] }.sorted(), [Value(id(980)), Value(id(990))])
    }

    @Test("real-shape sync replays collapse without conflicts")
    func realShapeSyncReplays() throws {
        let shaped = try normalize(try fixture("replay.jsonl"))
        eq(shaped["replays"], 20)
        eq(shaped["conflicts"], 0)
    }

    @Test("bridge byte verification parses history only when inventory found metadata", arguments: ["no bridge metadata", "bridge metadata", "shared transcript records"])
    func bridgeByteVerification(mode: String) throws {
        let bridge = mode != "no bridge metadata"
        let h = try bridgeFixture()
        let messages = branchEntries(48, SOURCE, 1).map { .spread($0, ["message": .spread($0["message"], ["content": Value(String(repeating: "synthetic history ", count: 128))])]) }
        try h.write(SOURCE, messages.concat(bridge ? [h.bridge] : []))
        var from = h.from
        if mode == "shared transcript records" {
            try h.record("P", id(777), rehomeRecord(["cliSessionId": Value(SOURCE), "forkedFromSessionId": Value("local_\(SOURCE)")]))
            from = try accounts(h.paths, []).find { $0["account"].str == h.acct.P }
        }
        let before = try readData(h.transcriptPath), inv = try inventory([from], h.to, h.paths, NOOP, ["processes": []])
        let result = try move(inv, h.to, h.paths)
        eq(result["ok"], true)
        #expect(try readData(h.transcriptPath).prefix(before.count) == before)
    }

    @Test("bridge append is shared by distinct parent and child Desktop records")
    func bridgeAppendShared() throws {
        let h = try bridgeFixture(), child = id(777)
        try h.record("P", child, rehomeRecord(["cliSessionId": Value(SOURCE), "forkedFromSessionId": Value("local_\(SOURCE)")]))
        let from = try accounts(h.paths, []).find { $0["account"].str == h.acct.P }
        let inv = try inventory([from], h.to, h.paths, NOOP, ["processes": []])
        eq(inv["move"].length, 2)
        let moved = try move(inv, h.to, h.paths)
        eq(moved["ok"], true)
        eq(moved["receipt"]["sessions"].length, 2)
        eq(moved["receipt"]["sessions"].filter { $0["bridgeAppend"].truthy }.length, 1)
        eq(lines(try readText(h.transcriptPath)).filter { $0["type"] == "bridge-session" }.length, 2)
        deq(try Self.names(h.dir("P")), [])
        eq(try readJSON(h.recordFile("Z", child))["forkedFromSessionId"], Value("local_\(SOURCE)"))
        ok(try undo(h.paths, ["processes": []])["dest"])
        assertBridgeRestored(h.before, try readData(h.transcriptPath), h.bridge)
        deq(.strings(try readdir(h.dir("P")).sorted()), .strings([SOURCE, child].map { "local_\($0).json" }.sorted()))
    }

    @Test("an unreadable source record prevents an empty-source assumption")
    func unreadableSourceRecord() throws {
        let h = try home()
        try writeText(h.recordFile("T", SOURCE), "{")
        let from = try h.account("T"), to = try h.account("Z")
        let inv = try inventory([from], to, h.paths, NOOP, ["cloudRequested": true])
        eq(inv["cloudCheckAccounts"].length, 1)
    }

    @Test("duplicate owners keep record-only bridge identities scoped to each source account")
    func duplicateOwnersBridgeIdentities() throws {
        let h = try home()
        let local: Value = [entry("user", 37, nil, SOURCE, ["message": ["role": "user", "content": "shared local history"]])]
        let remote: Value = [entry("user", 38, nil, "cse_second_owner", ["message": ["role": "user", "content": "second owner remote branch"]])]
        try h.write(SOURCE, local)
        try h.record("P", SOURCE, rehomeRecord(["title": "First owner", "bridgeSessionIds": ["session_first_owner"]]))
        try h.record("T", SOURCE, rehomeRecord(["title": "Second owner", "bridgeSessionIds": ["session_second_owner"]]))
        let from: Value = [try h.account("P"), try h.account("T")]
        let to = try h.account("Z")
        let moved = try moveWithPending(h, from, to)
        eq(moved["receipt"]["cloudLinks"].some { $0["account"].str == h.acct.T && $0["bridgeIds"].includes("session_second_owner") }, true)
        var status = "active"
        let cloud = cloudFixture(h, [
            "account": Value(h.acct.T),
            "org": Value(h.org.T),
            "list": fn { _ in [remoteSession(["id": "cse_second_owner", "title": "Renamed second owner", "status": Value(status)])] },
            "eventRows": fn { _ in remoteRows(remote) },
            "session": fn { _ in remoteState(status, ["id": "cse_second_owner"]) },
            "archive": fn { () in status = "archived" },
            "unarchive": fn { () in status = "active" },
        ])
        let finished = try finishPending(h.paths, ["cloud": cloud])
        eq(finished["ok"], true)
        deq(finished["failed"], [])
        deq(finished["summary"]["kept"].map { $0["code"] }, ["CLOUD_UNPROVEN"])
        eq(status, "active")
    }

    @Test("fork-linked runs of a deleted routine keep the historical family route")
    func forkLinkedDeletedRoutine() throws {
        let h = try taskHistoryFixture(), first = h.sessions[0], second = h.sessions[1], mock = taskHarness()
        try h.record("P", second, rehomeRecord(["scheduledTaskId": Value(h.taskId), "isArchived": true, "forkedFromSessionId": Value("local_\(first)")]))
        let (from, to) = try h.selection(), before = try fixtureSnapshot(h, [h.paths["records"].str, h.paths["pool"].str])
        let registries = try [h.sourceFile, h.targetFile].map(readData)
        let planned = try executeMove([from], to, h.paths, ["io": mock.io])
        eq(planned["plan"]["held"].length, 2)
        let result = try executeMove([from], to, h.paths, ["io": mock.io, "approve": planned["plan"]["token"]])
        eq(result["ok"], true, JSON.text(result["receipt"]["failed"]))
        deq(result["receipt"]["sessions"].map { $0["id"] }.sorted(), Value([Value(first), Value(second)]).sorted())
        deq(result["receipt"]["taskTransfers"][0]["tasks"], [])
        #expect(try [h.sourceFile, h.targetFile].map(readData) == registries)
        deq(.strings(try readdir(h.dir("P")).filter { $0.hasPrefix("local_") }), [])
        ok(try undo(h.paths, ["processes": []])["dest"])
        deq(try fixtureSnapshot(h, [h.paths["records"].str, h.paths["pool"].str]), before)
    }

    @Test("task preflight refuses absent sources and unreadable destination data")
    func taskPreflightRefuses() throws {
        for scenario in ["missing source", "unreadable source", "unreadable target", "denied target"] {
            let h = try taskFamilyFixture(), (from, to) = try h.selection()
            let source = Value.spread(from, ["sessions": from["sessions"].filter { $0["id"].str != h.cold }])
            let inv = try inventory([source], to, h.paths, NOOP, ["processes": []])
            if scenario == "missing source" { try rmrf(h.dir("P")) }
            if scenario.hasPrefix("unreadable") { try writeText(path.join(h.dir(scenario == "unreadable source" ? "P" : "T"), "local_\(id(796)).json"), "{broken") }
            let before = try fixtureSnapshot(h, [h.paths["records"].str, h.paths["pool"].str]), original = fs.readdir
            if scenario == "denied target" {
                let target = h.dir("T")
                fs.readdir = { dir in
                    if dir == target { throw makeError("fixture target access denied", code: "EACCES") }
                    return try original(dir)
                }
            }
            let result: Value
            do { defer { fs.readdir = original }; result = try move(inv, to, h.paths) }
            eq(result["ok"], false, scenario)
            eq(result["receipt"]["sessions"].length, 0, scenario)
            ok(result["receipt"]["failed"].length > 0, scenario)
            deq(try fixtureSnapshot(h, [h.paths["records"].str, h.paths["pool"].str]), before, scenario)
        }
    }

    @Test("malformed history keeps its verified record bridge dependency and remains refused")
    func malformedHistoryKeepsBridgeDependency() throws {
        let f = try refusalFixture(), h = f.h, transcript = h.transcript(f.investor)
        try appendText(transcript, "{broken\n")
        let before = try readData(transcript), source = try readData(f.investorFile)
        let result = try verifyPlaced(h.paths)
        eq(result["ok"], true)
        let receipt = try readJSON(f.result["file"].str)
        deq(receipt["failed"].find { $0["id"] == "cse_investor" }["blockedByLocal"], [Value("\(h.acct.P)/\(h.org.P)/\(f.recordId)")])
        eq(receipt["cloudChecks"][0]["status"], "blocked-local")
        ok(result["summary"]["notMoved"].some { $0["sessionId"].str == f.recordId })
        let (from, to) = try h.selection()
        let inv = try inventory([from], to, h.paths, NOOP, ["processes": []])
        ok(inv["blocked"].some { $0["id"].str == f.investor && TextPattern.cached("unparseable lines").test($0["error"].str) })
        ok(!inv["move"].some { $0["id"].str == f.investor })
        #expect(try readData(transcript) == before)
        #expect(try readData(f.investorFile) == source)
        ok(!exists(path.join(h.dir("T"), "\(f.recordId).json")))
    }
}
