import Foundation
import Testing
@testable import HandoffCore

// SOURCE's record lists a prior Claude Code session (`prior`) whose transcript carries the Remote Control
// bridge for cse_native_prior. The local prior history is the remote history with two prompts consumed
// from the queue and two neighbours swapped. A scenario breaks one part of that proof.
final class NativePrior {
    let h: Home
    let prior = id(8200), other = id(8201)
    let remote: Value
    let priorFile: String
    var status = "active"
    var archives = 0
    var reads = 0
    private(set) var cloud: Value = .undefined
    private(set) var from: Value = .undefined
    private(set) var to: Value = .undefined

    init(_ scenario: String = "valid") throws {
        h = try home()
        remote = branchEntries(200, prior, 1000)
        let local = remote.deepClone()
        for at in [80, 180] {
            local[at] = ["type": "queue-operation", "operation": "remove", "reason": "absorbed_mid_turn", "sessionId": Value(prior),
                         "commandUuid": remote[at]["uuid"], "deliveryId": Value("delivery-\(at)"), "content": remote[at]["message"]["content"]]
        }
        let swapped = local[20]
        local[20] = local[21]
        local[21] = swapped
        let bridge: Value = ["type": "bridge-session", "sessionId": Value(prior), "bridgeSessionId": "session_native_prior",
                             "ownerAccountUuid": Value(h.acct.P), "ownerOrganizationUuid": Value(h.org.P)]
        if scenario == "wrong owner" { bridge["ownerAccountUuid"] = Value(h.acct.T) }
        if scenario == "wrong org" { bridge["ownerOrganizationUuid"] = Value(h.org.T) }
        if scenario == "wrong session" { bridge["sessionId"] = Value(SOURCE) }
        if scenario == "wrong mirror" { bridge["bridgeSessionId"] = "session_foreign" }
        try h.write(SOURCE, branchEntries(4, SOURCE, 5000))
        try h.write(prior, local.concat([bridge]).concat(scenario == "conflicting bridge" ? [.spread(bridge, ["ownerAccountUuid": Value(h.acct.T)])] : []))
        priorFile = h.transcript(prior)
        if scenario == "symlink" {
            try rename(priorFile, "\(priorFile).saved")
            try symlink("\(priorFile).saved", priorFile)
        }
        if scenario == "other project" {
            let project = path.join(h.paths["pool"].str, "-tmp-other")
            try mkdirp(project)
            try rename(priorFile, path.join(project, "\(prior).jsonl"))
        }
        if scenario == "split priors" {
            try h.write(prior, local.slice(0, 100).concat([bridge]))
            try h.write(other, local.slice(100).map { .spread($0, ["sessionId": Value(self.other)]) }.concat([.spread(bridge, ["sessionId": Value(other)])]))
        }
        if scenario == "invalid prior" { try appendText(priorFile, "{broken}\n") }
        let priors: [String] = scenario == "unrecorded" ? [] : scenario == "split priors" ? [prior, other] : [prior]
        try h.record("P", SOURCE, rehomeRecord(["title": "Current generation", "priorCliSessionIds": .strings(priors)]))
        let all = try accounts(h.paths, [])
        from = all.find { $0["account"].str == h.acct.P }
        to = all.find { $0["account"].str == h.acct.Z }
        let late: Value = scenario == "after cutoff" ? ["created_at": "2099-01-01T00:00:00.000Z"] : [:]
        cloud = cloudFixture(h, [
            "list": fn { [unowned self] _ in [remoteSession(.spread(["id": "cse_native_prior", "title": "Old generation", "status": Value(self.status)], late))] },
            "eventRows": fn { [unowned self] _ in self.reads += 1; return remoteRows(self.remote) },
            "session": fn { [unowned self] _ in remoteState(self.status) },
            "archive": fn { [unowned self] () in self.archives += 1; self.status = "archived" },
            "unarchive": fn { [unowned self] () in self.status = "active" },
        ])
    }
}

func nativePriorFixture(_ scenario: String = "valid") throws -> NativePrior { try NativePrior(scenario) }

final class LimitRow {
    var mode: String
    let id: String, sid: String, title: String
    let entries: Value
    var status = "active"
    var reads = 0
    init(mode: String, id: String, sid: String, title: String, entries: Value) {
        self.mode = mode; self.id = id; self.sid = sid; self.title = title; self.entries = entries
    }
}

// One P session per mode, moved to Z with its cloud check deferred. Each mirror's history read fails
// with its mode's code (event, budget, pressure, parser) or succeeds ("ok"); "connected" mirrors wait.
// The budget always has room and answers parallel() with 8.
final class LimitRetry {
    let h: Home
    var rows: [LimitRow]
    private(set) var moved: Value = .undefined
    private(set) var from: Value = .undefined
    private(set) var to: Value = .undefined
    private(set) var memory: Value = .undefined
    private(set) var cloud: Value = .undefined
    // The most reads in one analysis batch. A parallel() call opens a batch of up to 8 reads; reads
    // outside a batch are serial.
    private(set) var peak = 0
    private var batchRoom = 0, batchReads = 0

    init(_ modes: [String]) throws {
        h = try home()
        rows = modes.enumerated().map { index, mode in
            LimitRow(mode: mode, id: "cse_limit\(index)", sid: id(8700 + index), title: "Synthetic limit \(index)", entries: branchEntries(4, id(8700 + index), 8800 + index * 10))
        }
        for row in rows {
            try h.write(row.sid, row.entries)
            try h.record("P", row.sid, rehomeRecord(["title": Value(row.title), "bridgeSessionIds": [Value(row.id.replacingOccurrences(of: "cse_", with: "session_"))]]))
        }
        let all = try accounts(h.paths, [])
        from = all.find { $0["account"].str == h.acct.P }
        to = all.find { $0["account"].str == h.acct.Z }
        moved = try move(try inventory([from], to, h.paths, NOOP, ["cloudRequested": true, "processes": []]), to, h.paths)
        memory = .spread(try memoryBudget(), ["check": NOOP, "parallel": fn { [unowned self] _ in
            self.batchRoom = 8
            self.batchReads = 0
            return 8
        }])
        let codes = ["event": "CLOUD_HISTORY_LIMIT", "budget": "CLOUD_MEMORY_BUDGET", "pressure": "CLOUD_MEMORY_PRESSURE", "parser": "ERR_STRING_TOO_LONG"]
        cloud = cloudFixture(h, [
            "memory": memory,
            "list": fn { [unowned self] _ in Value(self.rows.map { remoteSession(["id": Value($0.id), "title": Value($0.title), "status": Value($0.status)]) }) },
            "session": fn { [unowned self] args in
                let row = try self.lookup(args[0])
                return remoteState(row.status, row.mode == "connected" ? ["connection_status": "connected"] : [:])
            },
            "eventRows": fn { [unowned self] args in
                let row = try self.lookup(args[0])
                row.reads += 1
                if self.batchRoom > 0 { self.batchRoom -= 1; self.batchReads += 1 } else { self.batchReads = 1 }
                self.peak = max(self.peak, self.batchReads)
                if let code = codes[row.mode] { throw makeError("Synthetic \(row.mode) refusal", code: code) }
                eq(self.cloud["memory"], self.memory)
                return remoteRows(row.entries)
            },
            "archive": fn { [unowned self] args in try self.lookup(args[0]).status = "archived"; return .undefined },
            "unarchive": fn { [unowned self] args in try self.lookup(args[0]).status = "active"; return .undefined },
        ])
    }

    func lookup(_ id: Value) throws -> LimitRow {
        guard let row = rows.first(where: { $0.id == id.str }) else {
            Issue.record("no limit row for \(id)")
            throw EngineError("no limit row for \(id)")
        }
        return row
    }

    func resetPeak() { peak = 0; batchRoom = 0; batchReads = 0 }

    var options: Value {
        ["cloud": cloud, "memory": memory, "active": ["state": "known", "account": Value(h.acct.P), "org": Value(h.org.P)], "processes": [], "automatic": true]
    }
}

func limitRetryFixture(_ modes: [String]) throws -> LimitRetry { try LimitRetry(modes) }
