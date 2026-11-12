import Foundation
import Testing
@testable import HandoffCore

extension Engine.Cloud {
    // A client for one Remote Control session titled like SOURCE's record, whose status the test owns.
    final class StatusCloud {
        var status = "active"
        var archived = false
        var unarchived = false
        private(set) var client: Value = .undefined

        init(_ h: Home, id: String, entries: Value, session: Value? = nil, archive: (() throws -> Void)? = nil) {
            client = [
                "account": Value(h.acct.P), "org": Value(h.org.P),
                "list": fn { [unowned self] _ in [remoteSession(["id": Value(id), "title": Value("Session \(SOURCE.suffix(3))"), "status": Value(self.status)])] },
                "eventRows": fn { _ in remoteRows(entries) },
                "session": fn { [unowned self] _ in session ?? remoteState(self.status) },
                "archive": fn { [unowned self] () in
                    self.archived = true
                    self.status = "archived"
                    try archive?()
                },
                "unarchive": fn { [unowned self] () in self.unarchived = true; self.status = "active" },
            ]
        }
    }

    @Test("a local verification failure keeps its Remote Control source active")
    func verificationFailureKeepsSource() throws {
        let h = try home()
        let entries: Value = [entry("user", 1, nil, SOURCE), entry("assistant", 2, 1, SOURCE)]
        try h.write(SOURCE, entries)
        try h.record("P", SOURCE, rehomeRecord())
        let remote = StatusCloud(h, id: "cse_verify", entries: entries)
        let all = try accounts(h.paths)
        let from = Engine.Cloud.pick(all, h, "P"), to = Engine.Cloud.pick(all, h, "Z")
        touchPlaced(h.recordFile("Z", SOURCE))
        let result = try move(try inventory([from], to, h.paths, NOOP, ["cloud": remote.client]), to, h.paths)
        fs = FileSystem()
        eq(result["ok"], false)
        eq(remote.archived, false)
        match(result["receipt"]["failed"].elements.last { !$0["cloudAccount"].truthy }?["error"] ?? .undefined, "desktop changed during the move")
        ok(exists(h.recordFile("P", SOURCE)))
        deq(.strings(try readdir(h.dir("Z"))), [])
    }

    @Test("Undo stages the matching cloud identity before changing local records")
    func undoStagesCloudIdentity() throws {
        let h = try home()
        let entries: Value = [entry("user", 1, nil, SOURCE)]
        try h.write(SOURCE, entries)
        try h.record("Z", SOURCE, rehomeRecord())
        let remote = StatusCloud(h, id: "cse_identity", entries: entries)
        let all = try accounts(h.paths)
        let from = Engine.Cloud.pick(all, h, "P"), to = Engine.Cloud.pick(all, h, "Z")
        let result = try move(try inventory([from], to, h.paths, NOOP, ["cloud": remote.client]), to, h.paths)
        eq(result["ok"], true)
        let wrong = Value.spread(remote.client, ["account": Value(h.acct.Q), "org": Value(h.org.Q)])
        let staged = try undo(h.paths, ["cloud": wrong])
        deq(staged["pendingUndo"], [from["email"]])
        eq(remote.status, "archived")
        ok(exists(h.recordFile("Z", SOURCE)))
    }

    @Test("Undo checks an activated target before restoring its cloud mirror")
    func undoChecksActivatedTarget() throws {
        let h = try home()
        let entries: Value = [entry("user", 1, nil, SOURCE)]
        try h.write(SOURCE, entries)
        try h.record("Z", SOURCE, rehomeRecord(["isArchived": true]))
        let remote = StatusCloud(h, id: "cse_changed", entries: entries)
        let all = try accounts(h.paths)
        let from = Engine.Cloud.pick(all, h, "P"), to = Engine.Cloud.pick(all, h, "Z")
        _ = try move(try inventory([from], to, h.paths, NOOP, ["cloud": remote.client]), to, h.paths)
        let targetFile = h.recordFile("Z", SOURCE)
        let changed = try readJSON(targetFile)
        changed["permissionMode"] = "changed after move"
        try writeJSON(targetFile, changed)
        let refused = try undo(h.paths, ["cloud": remote.client])
        match(refused["restoreProblems"][0], "activated target record changed")
        eq(remote.unarchived, false)
        eq(remote.status, "archived")
    }

    @Test("a connected Remote Control session is never archived or locally activated")
    func connectedNeverArchived() throws {
        let h = try home()
        let entries: Value = [entry("user", 1, nil, SOURCE)]
        try h.write(SOURCE, entries)
        try h.record("Z", SOURCE, rehomeRecord(["isArchived": true]))
        let remote = StatusCloud(h, id: "cse_busy", entries: entries, session: remoteState("active", ["connection_status": "connected"]))
        let all = try accounts(h.paths)
        let from = Engine.Cloud.pick(all, h, "P"), to = Engine.Cloud.pick(all, h, "Z")
        let result = try move(try inventory([from], to, h.paths, NOOP, ["cloud": remote.client]), to, h.paths)
        eq(result["ok"], true)
        eq(result["pendingCloud"], 1)
        eq(result["receipt"]["failed"].length, 0)
        eq(result["receipt"]["cloudChecks"][0]["status"], "waiting")
        eq(remote.archived, false)
        eq(try readJSON(h.recordFile("Z", SOURCE))["isArchived"], true)
    }

    @Test("an interrupted Remote Control archive is recovered from server state")
    func interruptedArchiveRecovered() throws {
        let h = try home()
        let entries: Value = [entry("user", 1, nil, SOURCE)]
        try h.write(SOURCE, entries)
        try h.record("Z", SOURCE, rehomeRecord(["isArchived": true]))
        var first = true
        let remote = StatusCloud(h, id: "cse_interrupted", entries: entries, archive: {
            if first { first = false; throw EngineError("connection lost after archive") }
        })
        let all = try accounts(h.paths)
        let from = Engine.Cloud.pick(all, h, "P"), to = Engine.Cloud.pick(all, h, "Z")
        let inv = try inventory([from], to, h.paths, NOOP, ["cloud": remote.client])
        let interrupted = try move(inv, to, h.paths)
        eq(interrupted["ok"], false)
        ok(interrupted["receipt"]["remotePending"])
        eq(try readJSON(h.recordFile("Z", SOURCE))["isArchived"], false)
        let recovered = try move(inv, to, h.paths)
        eq(recovered["recoveryRequired"], true)
        let receipt = try readJSON(interrupted["file"].str)
        eq(receipt["remotePending"], .undefined)
        eq(receipt["remote"].length, 1)
        ok(try undo(h.paths, ["cloud": remote.client])["dest"])
        eq(remote.status, "active")
        eq(try readJSON(h.recordFile("Z", SOURCE))["isArchived"], true)
    }
}
