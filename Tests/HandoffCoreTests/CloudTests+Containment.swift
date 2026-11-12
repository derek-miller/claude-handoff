import Foundation
import Testing
@testable import HandoffCore

extension Engine.Cloud {
    // The accounts() row for a fixture account in its own organization.
    static func pick(_ all: Value, _ h: Home, _ a: String) -> Value {
        all.find { $0["account"].str == h.acct[a] && $0["org"].str == h.org[a] }
    }

    @Test("artifact indexes reparse identical bytes on a new inode before archival")
    func artifactNewInode() throws {
        let f = try artifactFixture(), inv = try f.inventory(), before = inv["cloud"]["artifacts"]["used"].asNumber ?? 0
        let file = path.join(f.directory, "agent-a0.jsonl"), raw = try readData(file)
        try unlink(file)
        try writeData(file, raw)
        let result = try move(inv, f.to, f.h.paths)
        eq(result["ok"], true)
        eq(f.calls, 1)
        ok((inv["cloud"]["artifacts"]["used"].asNumber ?? 0) > before)
    }

    @Test("artifact ownership rejects symlink entries introduced after the ordinary sidecar scan")
    func artifactSymlinkEntries() throws {
        for kind in ["file", "root", "subagents"] {
            let f = try artifactFixture(), original = f.cloud["list"], outside = path.join(f.h.root, "unrelated-artifacts")
            try mkdirp(outside)
            try writeText(path.join(outside, "agent-a0.jsonl"), f.agents[0].elements.map { JSON.text($0) }.joined(separator: "\n") + "\n")
            f.cloud["list"] = fn { _ in
                if kind == "file" {
                    try symlink(path.join(outside, "agent-a0.jsonl"), path.join(f.directory, "agent-escape.jsonl"))
                } else {
                    let directory = kind == "root" ? path.dirname(f.directory) : f.directory
                    try rename(directory, "\(directory).original")
                    try symlink(outside, directory)
                }
                return try original.call()
            }
            let inv = try f.inventory()
            deq(inv["cloud"]["matches"], [], kind)
            eq(inv["cloud"]["blocked"][0]["code"], "CLOUD_ARTIFACT_UNCERTAIN", kind)
        }
    }

    @Test("artifact coverage also revalidates a rehomed target through normal archival")
    func artifactRehomedTarget() throws {
        let f = try artifactFixture(), h = f.h
        try unlink(f.taskFile)
        try unlink(h.recordFile("Z", SOURCE))
        try h.record("P", SOURCE, rehomeRecord(["bridgeSessionIds": ["session_artifacts"]]))
        let all = try accounts(h.paths, [])
        f.from = all.find { $0["account"].str == h.acct.P }
        f.to = all.find { $0["account"].str == h.acct.Z }
        let before = try fixtureSnapshot(h, [h.paths["pool"].str])
        let moved = try move(try f.inventory(), f.to, h.paths)
        eq(moved["ok"], true)
        deq(moved["receipt"]["sessions"].map { $0["strategy"] }, ["rehome"])
        eq(moved["receipt"]["remote"][0]["matchMode"], "artifacts")
        deq(try fixtureSnapshot(h, [h.paths["pool"].str]), before)
    }

    @Test("uncertain owned artifacts never authorize a source archive")
    func uncertainArtifacts() throws {
        for change in ["unreadable", "ownership", "budget"] {
            let f = try artifactFixture(), h = f.h
            f.remote.push(entry("assistant", 8900, nil, SOURCE))
            if change == "unreadable" { try appendText(path.join(f.directory, "agent-a0.jsonl"), "{\"type\":\"assistant\",broken\n") }
            if change == "ownership" { f.agents[0][0]["sessionId"] = Value(id(9999)); try f.write() }
            let before = try fixtureSnapshot(h, [h.paths["records"].str, h.paths["pool"].str])
            let inv = try f.inventory(change == "budget" ? ["artifactLimit": 100] : [:])
            deq(inv["cloud"]["matches"], [], change)
            eq(inv["cloud"]["blocked"][0]["code"], Value(change == "budget" ? "CLOUD_ARTIFACT_BUDGET" : "CLOUD_ARTIFACT_UNCERTAIN"), change)
            noMatch(inv["cloud"]["blocked"][0]["error"], "unsupported")
            let moved = try move(inv, f.to, h.paths)
            eq(moved["ok"], false, change)
            eq(moved["receipt"]["sessions"].length, 0)
            eq(moved["receipt"]["remote"].length, 0)
            eq(f.calls, 0)
            eq(f.status, "active")
            deq(try fixtureSnapshot(h, [h.paths["records"].str, h.paths["pool"].str]), before, change)
        }
    }

    @Test("an unproven Remote Control mirror stays in its account, is named once and is never retried")
    func unprovenMirrorKept() throws {
        let h = try home()
        let sharedLocal = branchEntries(8, SOURCE, 20)
        try h.write(SOURCE, sharedLocal.concat([entry("user", 28, 27, SOURCE, ["message": ["role": "user", "content": "local branch"]])]))
        try h.record("Z", SOURCE, rehomeRecord())
        let remote = branchEntries(8, "cse_divergent", 20).concat([entry("user", 28, 27, "cse_divergent", ["message": ["role": "user", "content": "remote branch"]])])
        var status = "active", listed = 0
        let cloud = cloudFixture(h, [
            "list": fn { _ in listed += 1; return [remoteSession(["id": "cse_divergent", "title": Value("Session \(SOURCE.suffix(3))"), "status": Value(status)])] },
            "eventRows": fn { _ in remoteRows(remote) },
            "session": fn { _ in remoteState(status) },
            "archive": fn { () in status = "archived" },
        ])
        let all = try accounts(h.paths)
        let from = Engine.Cloud.pick(all, h, "P"), to = Engine.Cloud.pick(all, h, "Z")
        let inv = try inventory([from], to, h.paths, NOOP, ["cloud": cloud])
        deq(inv["cloud"]["matches"], [])
        eq(inv["cloud"]["blocked"][0]["code"], "CLOUD_UNPROVEN")
        let alone = try move(inv, to, h.paths)
        deq([alone["ok"], alone["file"]], [true, nil])
        deq(alone["summary"]["kept"].map { [$0["id"], $0["error"]] }, [["cse_divergent", Value("not proven to be on this Mac, kept in \(from["label"])")]])
        deq(alone["summary"]["attention"], [])
        let selection = { () throws -> (Value, Value) in
            let current = try accounts(h.paths)
            return (Engine.Cloud.pick(current, h, "P"), Engine.Cloud.pick(current, h, "Z"))
        }
        let local = id(750)
        try h.write(local, [entry("user", 750, nil, local)])
        try h.record("P", local, rehomeRecord())
        let (source, target) = try selection()
        let result = try move(try inventory([source], target, h.paths, NOOP, ["cloud": cloud]), target, h.paths)
        deq([result["ok"], result["complete"]], [true, true])
        deq(result["receipt"]["sessions"].map { $0["id"] }, [Value(local)])
        eq(status, "active")
        deq(result["receipt"]["failed"].filter { $0["cloudAccount"].truthy }.map { $0["id"] }, ["cse_divergent"])
        deq(result["summary"]["kept"].map { $0["id"] }, ["cse_divergent"])
        eq(result["receipt"]["cloudChecks"][0]["status"], "complete")
        let active: Value = ["account": Value(h.acct.P), "org": Value(h.org.P), "state": "known"]
        let before = listed
        try appendText(h.transcript(SOURCE), "\(JSON.text(entry("assistant", 29, 28, SOURCE)))\n")
        for automatic in [true, false] {
            ne(try finishPending(h.paths, ["cloud": cloud, "automatic": Value(automatic), "active": active])["pending"], true)
        }
        eq(listed, before)
        eq(status, "active")
        let next = id(751)
        try h.write(next, [entry("user", 751, nil, next)])
        try h.record("P", next, rehomeRecord())
        let (laterSource, laterTarget) = try selection()
        let later = try move(try inventory([laterSource], laterTarget, h.paths), try selection().1, h.paths)
        deq(later["receipt"]["sessions"].map { $0["id"] }, [Value(next)])
    }

    @Test("an unrelated same-title local session cannot prove a remote copy")
    func unrelatedSameTitle() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("Z", SOURCE, rehomeRecord())
        let remote: Value = [
            entry("user", 10, nil, "cse_unrelated", ["message": ["role": "user", "content": "unrelated question"]]),
            entry("assistant", 11, 10, "cse_unrelated", ["message": ["role": "assistant", "content": "unrelated answer"]]),
        ]
        var archived = false
        let cloud: Value = [
            "account": Value(h.acct.P), "org": Value(h.org.P),
            "list": fn { _ in [remoteSession(["id": "cse_unrelated", "title": Value("Session \(SOURCE.suffix(3))")])] },
            "eventRows": fn { _ in remoteRows(remote) },
            "session": fn { _ in remoteState("active") },
            "archive": fn { () in archived = true },
            "unarchive": NOOP,
        ]
        let all = try accounts(h.paths)
        let from = Engine.Cloud.pick(all, h, "P"), to = Engine.Cloud.pick(all, h, "Z")
        let inv = try inventory([from], to, h.paths, NOOP, ["cloud": cloud])
        eq(inv["cloud"]["matches"].length, 0)
        eq(inv["cloud"]["blocked"][0]["code"], "CLOUD_UNPROVEN")
        let result = try move(inv, to, h.paths)
        eq(result["ok"], true)
        deq(result["summary"]["kept"].map { $0["id"] }, ["cse_unrelated"])
        eq(archived, false)
    }

    @Test("an exact bridge id to a divergent remote session never archives it")
    func exactBridgeDivergent() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE), ["type": "bridge-session", "sessionId": Value(SOURCE), "bridgeSessionId": "session_exact"]])
        try h.record("Z", SOURCE, rehomeRecord(["title": "Renamed local session"]))
        let remote: Value = [
            entry("user", 10, nil, "cse_exact", ["message": ["role": "user", "content": "remote-only question"]]),
            entry("assistant", 11, 10, "cse_exact", ["message": ["role": "assistant", "content": "remote-only answer"]]),
        ]
        var status = "active"
        let cloud: Value = [
            "account": Value(h.acct.P), "org": Value(h.org.P),
            "list": fn { _ in [remoteSession(["id": "cse_exact", "title": "Remote renamed session", "status": Value(status)])] },
            "eventRows": fn { _ in remoteRows(remote) },
            "session": fn { _ in remoteState(status) },
            "archive": fn { () in status = "archived" },
            "unarchive": fn { () in status = "active" },
        ]
        let all = try accounts(h.paths)
        let from = Engine.Cloud.pick(all, h, "P"), to = Engine.Cloud.pick(all, h, "Z")
        let inv = try inventory([from], to, h.paths, NOOP, ["cloud": cloud])
        deq(inv["cloud"]["matches"], [])
        eq(inv["cloud"]["blocked"][0]["code"], "CLOUD_UNPROVEN")
        _ = try move(inv, to, h.paths)
        eq(status, "active")
    }

    @Test("a short remote history is not matched to a differently titled local session")
    func shortRemoteHistory() throws {
        let h = try home()
        let remote: Value = [entry("user", 1, nil, SOURCE), entry("assistant", 2, 1, SOURCE)]
        try h.write(SOURCE, remote)
        try h.record("Z", SOURCE, rehomeRecord(["title": "Renamed local session"]))
        let cloud: Value = [
            "account": Value(h.acct.P), "org": Value(h.org.P),
            "list": fn { _ in [remoteSession(["id": "cse_short", "title": "Different remote title"])] },
            "eventRows": fn { _ in remoteRows(remote) },
            "session": fn { _ in remoteState("active") },
            "archive": NOOP, "unarchive": NOOP,
        ]
        let all = try accounts(h.paths)
        let from = Engine.Cloud.pick(all, h, "P"), to = Engine.Cloud.pick(all, h, "Z")
        let inv = try inventory([from], to, h.paths, NOOP, ["cloud": cloud])
        eq(inv["cloud"]["matches"].length, 0)
        eq(inv["cloud"]["blocked"][0]["code"], "CLOUD_UNPROVEN")
    }

    @Test("an unreadable assistant payload cannot disappear from remote containment checks")
    func unreadableAssistantPayload() throws {
        let h = try home(), entries: Value = [entry("user", 1, nil, SOURCE)]
        try h.write(SOURCE, entries)
        try h.record("P", SOURCE)
        var archived = false
        let cloud = cloudFixture(h, [
            "list": fn { _ in [remoteSession(["id": "cse_unreadable_message", "title": "Session 001"])] },
            "eventRows": fn { _ in remoteRows(entries).concat([["event_type": "assistant", "sequence_num": 2, "payload": ["type": "assistant", "unknown_body": "new data"]]]) },
            "session": fn { _ in remoteState("active") },
            "archive": fn { () in archived = true },
        ])
        let all = try accounts(h.paths), from = all.find { $0["account"].str == h.acct.P }, to = all.find { $0["account"].str == h.acct.Z }
        let result = try move(try inventory([from], to, h.paths, NOOP, ["cloud": cloud]), to, h.paths)
        eq(archived, false)
        eq(result["ok"], false)
        ok(result["receipt"]["failed"].some { $0["error"].str.contains("payload is unreadable") })
    }

    @Test("pending remote actions are refused even when worker status says idle")
    func pendingRemoteActions() throws {
        let extras: [Value] = [
            ["requires_action_details_list": [["request_id": "queued"]]],
            ["external_metadata": ["pending_action": ["request_id": "queued"]]],
            ["external_metadata": ["pending_actions": "[{\"request_id\":\"queued\"}]"]],
        ]
        for extra in extras {
            let h = try home(), entries: Value = [entry("user", 1, nil, SOURCE)]
            try h.write(SOURCE, entries)
            try h.record("P", SOURCE)
            var archived = false
            let cloud = cloudFixture(h, [
                "list": fn { _ in [remoteSession(["id": "cse_queued", "title": "Session 001"])] },
                "eventRows": fn { _ in remoteRows(entries) },
                "session": fn { _ in remoteState("active", extra) },
                "archive": fn { () in archived = true },
            ])
            let all = try accounts(h.paths), from = all.find { $0["account"].str == h.acct.P }, to = all.find { $0["account"].str == h.acct.Z }
            let result = try move(try inventory([from], to, h.paths, NOOP, ["cloud": cloud]), to, h.paths)
            eq(archived, false)
            eq(result["ok"], false)
            ok(result["receipt"]["failed"].some { $0["error"].str.contains("pending actions") }, JSON.text(extra))
        }
    }

    @Test("changed remote history or input is refused even when its event marker is unchanged")
    func changedRemoteInput() throws {
        let additions: [Value] = [
            ["event_type": "assistant", "sequence_num": 2, "payload": entry("assistant", 2, 1, SOURCE)],
            ["event_type": "control_request", "sequence_num": 2, "payload": ["type": "control_request", "request_id": "new", "request": ["subtype": "interrupt"]]],
        ]
        for added in additions {
            let h = try home(), entries: Value = [entry("user", 1, nil, SOURCE)]
            try h.write(SOURCE, entries)
            try h.record("P", SOURCE)
            var reads = 0, archived = false
            let cloud = cloudFixture(h, [
                "list": fn { _ in [remoteSession(["id": "cse_input", "title": "Session 001"])] },
                "eventRows": fn { _ in reads += 1; return remoteRows(entries).concat(reads >= 3 ? [added] : []) },
                "session": fn { _ in remoteState("active") },
                "archive": fn { () in archived = true },
            ])
            let all = try accounts(h.paths), from = all.find { $0["account"].str == h.acct.P }, to = all.find { $0["account"].str == h.acct.Z }
            let result = try move(try inventory([from], to, h.paths, NOOP, ["cloud": cloud]), to, h.paths)
            eq(archived, false)
            eq(result["ok"], false)
            ok(result["receipt"]["failed"].some { $0["error"].str.contains("history or input changed") }, added["event_type"].str)
        }
    }

    @Test("missing Remote Control readiness fields fail closed")
    func missingReadinessFields() throws {
        let h = try home()
        let entries: Value = [entry("user", 1, nil, SOURCE)]
        try h.write(SOURCE, entries)
        try h.record("Z", SOURCE, rehomeRecord())
        var archived = false
        let cloud: Value = [
            "account": Value(h.acct.P), "org": Value(h.org.P),
            "list": fn { _ in [remoteSession(["id": "cse_unknown", "title": Value("Session \(SOURCE.suffix(3))")])] },
            "eventRows": fn { _ in remoteRows(entries) },
            "session": fn { _ in ["status": "active", "last_event_at": "2026-09-01T00:01:00.000Z"] },
            "archive": fn { () in archived = true },
            "unarchive": NOOP,
        ]
        let all = try accounts(h.paths)
        let from = Engine.Cloud.pick(all, h, "P"), to = Engine.Cloud.pick(all, h, "Z")
        let inv = try inventory([from], to, h.paths, NOOP, ["cloud": cloud])
        eq(inv["cloud"]["matches"].length, 0)
        match(inv["cloud"]["blocked"][0]["error"], "not proven disconnected and idle")
        let result = try move(inv, to, h.paths)
        eq(result["ok"], false)
        eq(archived, false)
        match(result["receipt"]["failed"][0]["error"], "not proven disconnected and idle")
    }

    @Test("a Remote Control mirror stays active when no local target shares its title")
    func noSharedTitle() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("Z", SOURCE, rehomeRecord(["title": "Different local session"]))
        var archived = false
        let cloud: Value = [
            "account": Value(h.acct.P), "org": Value(h.org.P),
            "list": fn { _ in [remoteSession(["id": "cse_other", "title": Value("Session \(SOURCE.suffix(3))")])] },
            "eventRows": fn { _ in remoteRows([entry("user", 9, nil, "cse_other", ["message": ["role": "user", "content": "different history"]])]) },
            "session": fn { _ in remoteState(archived ? "archived" : "active", ["id": "cse_other"]) },
            "archive": fn { () in archived = true },
            "unarchive": fn { () in archived = false },
        ]
        let all = try accounts(h.paths)
        let from = Engine.Cloud.pick(all, h, "P"), to = Engine.Cloud.pick(all, h, "Z")
        let inv = try inventory([from], to, h.paths, NOOP, ["cloud": cloud])
        eq(inv["cloud"]["matches"].length, 0)
        eq(inv["cloud"]["blocked"].length, 1)
        eq(inv["cloud"]["blocked"][0]["error"], Value("not proven to be on this Mac, kept in \(from["label"])"))
        let result = try move(inv, to, h.paths)
        deq([result["ok"], result["file"]], [true, nil])
        eq(result["receipt"]["cloudChecks"][0]["status"], "complete")
        eq(archived, false)
    }

    @Test("a local move lands before its matching Remote Control mirror archives")
    func localMoveBeforeArchive() throws {
        let h = try home()
        let entries: Value = [entry("user", 1, nil, SOURCE), entry("assistant", 2, 1, SOURCE)]
        try h.write(SOURCE, entries)
        try h.record("P", SOURCE, rehomeRecord(["isArchived": true]))
        var status = "active"
        let targetRecord = h.recordFile("Z", SOURCE)
        let cloud: Value = [
            "account": Value(h.acct.P), "org": Value(h.org.P),
            "list": fn { _ in [remoteSession(["id": "cse_move", "title": Value("Session \(SOURCE.suffix(3))"), "tags": ["remote-control-repl"], "status": Value(status)])] },
            "eventRows": fn { _ in remoteRows(entries) },
            "session": fn { _ in remoteState(status, ["id": "cse_move"]) },
            "archive": fn { () in ok(exists(targetRecord), "target record placed before archive"); status = "archived" },
            "unarchive": fn { () in status = "active" },
        ]
        let all = try accounts(h.paths)
        let from = Engine.Cloud.pick(all, h, "P"), to = Engine.Cloud.pick(all, h, "Z")
        let inv = try inventory([from], to, h.paths, NOOP, ["cloud": cloud])
        eq(inv["move"].length, 1)
        eq(inv["cloud"]["matches"][0]["target"]["kind"], "move")
        let result = try move(inv, to, h.paths)
        eq(result["ok"], true)
        eq(result["receipt"]["remote"].length, 1)
        eq(status, "archived")
        deq(.strings(try readdir(h.dir("P"))), [])
        eq(try readJSON(targetRecord)["isArchived"], false)
        ok(try undo(h.paths, ["cloud": cloud])["dest"])
        eq(status, "active")
        eq(try readJSON(h.recordFile("P", SOURCE))["isArchived"], true)
    }

    @Test("Keep local accepts a rehome target activated by cloud archival")
    func keepLocalActivatedTarget() throws {
        let h = try home()
        let entries: Value = [entry("user", 1, nil, SOURCE), entry("assistant", 2, 1, SOURCE)]
        try h.write(SOURCE, entries)
        try h.record("P", SOURCE, rehomeRecord(["isArchived": true]))
        var status = "active"
        let cloud = cloudFixture(h, [
            "list": fn { _ in [remoteSession(["id": "cse_keep_activation", "title": Value("Session \(SOURCE.suffix(3))"), "status": Value(status)])] },
            "eventRows": fn { _ in remoteRows(entries) },
            "session": fn { _ in remoteState(status) },
            "archive": fn { () in status = "archived" },
            "unarchive": fn { () in status = "active" },
        ])
        let all = try accounts(h.paths)
        let from: Value = [Engine.Cloud.pick(all, h, "P"), Engine.Cloud.pick(all, h, "T")]
        let to = Engine.Cloud.pick(all, h, "Z")
        let moved = try moveWithPending(h, from, to, cloud)
        eq(moved["pendingCloud"], 1)
        eq(try readJSON(h.recordFile("Z", SOURCE))["isArchived"], false)
        eq(try keepLocal(h.paths)["ok"], true)
    }
}
