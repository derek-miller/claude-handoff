import Foundation
import Testing
@testable import HandoffCore

// Fixtures used by more than one group of the behaviour suite.

// MARK: - Scheduled tasks

// A home with scheduled-task registries in P (source) and T (target).
class TaskHome: Home {
    var sourceFile: String { path.join(dir("P"), "scheduled-tasks.json") }
    var targetFile: String { path.join(dir("T"), "scheduled-tasks.json") }
    // How interruptTaskFamily runs: which matching mutation crashes, the notification id, restart, sources.
    var interruptAfter = 1
    var notificationId: String?
    var restart = false
    var sourceAccounts: [String]?

    func selection() throws -> (from: Value, to: Value) {
        let all = try accounts(paths, [])
        return (all.find { $0.account.str == acct.P }, all.find { $0.account.str == acct.T })
    }
}

// A source session with scheduled-task runs (run, second) and an unrelated cold session.
final class TaskFamily: TaskHome {
    let run = id(701), second = id(702), cold = id(703)
    private(set) var tasks: Value = []
    private(set) var sourceRegistry: Value = .undefined
    private(set) var targetRegistry: Value = .undefined
    private(set) var sourceAfter: Value = .undefined
    private(set) var targetAfter: Value = .undefined

    init(enabled: Bool = false, taskCount: Int = 2, eventCount: Int = 1, twins: Bool = false) throws {
        try super.init()
        let runs = Array([run, second].prefix(taskCount))
        tasks = Value(runs.indices.map { index -> Value in
            ["id": Value("task_\(index)"), "notifySessionId": Value("local_\(SOURCE)"), "enabled": Value(enabled), "fireAt": Value(123456 + index),
             "filePath": Value(path.join(root, ".claude", "scheduled-tasks", "task_\(index)", "SKILL.md")), "createdAt": 123,
             "lastRunAt": "2026-09-01T00:00:00Z", "lastScheduledFor": "2026-09-01T00:00:00Z"]
        })
        for task in tasks.elements {
            try mkdirp(path.dirname(task.filePath.str))
            try writeText(task.filePath.str, "---\nname: \(task.id)\n---\nSynthetic reminder prompt\n")
        }
        for (index, sid) in ([SOURCE] + runs + [cold]).enumerated() {
            try write(sid, branchEntries(eventCount, sid, 80 + index * eventCount))
            try record("P", sid, rehomeRecord(runs.contains(sid) ? ["scheduledTaskId": tasks[index - 1].id, "notifySessionId": Value("local_\(SOURCE)")] : [:]))
        }
        let skips = Value.fromEntries(tasks.elements.map { ($0.id.str, Value([["at": "2026-09-02T00:00:00Z", "reason": "app_closed"]])) })
        let retries: Value = ["task_0": ["slot": "2026-09-02T00:00:00Z", "attempts": 2, "notBefore": "2026-09-02T00:05:00Z"]]
        let unrelatedSkips: Value = ["unrelated_task": [["at": "2026-09-01T01:00:00Z", "reason": "missed"]]]
        let unrelatedRetries: Value = ["unrelated_task": ["slot": "2026-09-01T01:00:00Z", "attempts": 1, "notBefore": "2026-09-01T01:05:00Z"]]
        sourceRegistry = ["scheduledTasks": tasks, "recordedSkips": .spread(skips, unrelatedSkips), "runRetries": .spread(retries, unrelatedRetries),
                          "sundayAliasBoundaryStamped": true, "dayFieldsOrBoundaryStamped": false, "future": ["preserved": "source"]]
        targetRegistry = ["scheduledTasks": [["id": "unrelated_task", "enabled": true, "cronExpression": "0 0 * * *", "filePath": "/tmp/fixture/other.md"]],
                          "recordedSkips": ["other_task": [["at": "2026-09-03T00:00:00Z", "reason": "disabled"]]],
                          "runRetries": ["other_task": ["slot": "2026-09-03T00:00:00Z", "attempts": 3, "notBefore": "2026-09-03T00:10:00Z"]],
                          "future": ["preserved": "target"]]
        sourceAfter = .spread(sourceRegistry, ["scheduledTasks": [], "recordedSkips": unrelatedSkips, "runRetries": unrelatedRetries])
        targetAfter = .spread(targetRegistry, [
            "scheduledTasks": targetRegistry.scheduledTasks.concat(tasks),
            "recordedSkips": .spread(targetRegistry.recordedSkips, skips),
            "runRetries": .spread(targetRegistry.runRetries, retries),
        ])
        if twins {
            let stale = tasks.map { .spread($0, ["enabled": false, "notifySessionId": Value("local_\(id(799))"), "lastRunAt": "2026-08-24T00:00:00Z"]) }
            targetRegistry.scheduledTasks.asArray!.items.insert(contentsOf: stale.elements, at: 0)
        }
        try writeJSON(sourceFile, sourceRegistry)
        try writeJSON(targetFile, targetRegistry)
    }
}

func taskFamilyFixture(_ enabled: Bool = false, _ taskCount: Int = 2, _ eventCount: Int = 1, _ twins: Bool = false) throws -> TaskFamily {
    try TaskFamily(enabled: enabled, taskCount: taskCount, eventCount: eventCount, twins: twins)
}

// Archived runs of a deleted routine: records name a scheduledTaskId no registry lists.
final class TaskHistory: TaskHome {
    let taskId = "deleted-task"
    private(set) var sessions: [String] = []
    let registry: Value = ["scheduledTasks": [["id": "unrelated-task", "enabled": true]], "future": ["preserved": true]]

    init(count: Int = 2) throws {
        try super.init()
        sessions = (0..<count).map { id(1000 + $0) }
        for (index, sid) in sessions.enumerated() {
            try write(sid, [entry("user", 2000 + index, nil, sid)])
            try record("P", sid, rehomeRecord(["scheduledTaskId": Value(taskId), "isArchived": true]))
        }
        for file in [sourceFile, targetFile] { try writeJSON(file, registry) }
    }
}

func taskHistoryFixture(_ count: Int = 2) throws -> TaskHistory { try TaskHistory(count: count) }

// Two sessions each notified by a task, with skips and retries for both.
final class TaskCheckpoint: TaskHome {
    let sessions = [SOURCE, id(791)]
    private(set) var tasks: Value = []
    private(set) var sourceRegistry: Value = .undefined
    private(set) var originalRecords: [Data] = []

    override init() throws {
        try super.init()
        tasks = Value(sessions.enumerated().map { index, sid -> Value in
            ["id": Value("task_\(index + 1)"), "notifySessionId": Value("local_\(sid)"), "enabled": true, "fireAt": Value(123456 + index)]
        })
        sourceRegistry = [
            "scheduledTasks": tasks,
            "recordedSkips": .fromEntries(tasks.elements.map { ($0.id.str, Value([["at": "2026-09-02T00:00:00Z", "reason": "app_closed"]])) }),
            "runRetries": .fromEntries(tasks.elements.map { (task: Value) -> (String, Value) in
                let retry: Value = ["slot": "2026-09-02T00:00:00Z", "attempts": 2, "notBefore": "2026-09-02T00:05:00Z"]
                return (task.id.str, retry)
            }),
        ]
        for (index, sid) in sessions.enumerated() {
            try write(sid, [entry("user", 810 + index, nil, sid)])
            try record("P", sid, rehomeRecord())
        }
        originalRecords = try sessions.map { try readData(recordFile("P", $0)) }
        try writeJSON(sourceFile, sourceRegistry)
    }
}

func taskCheckpointFixture() throws -> TaskCheckpoint { try TaskCheckpoint() }

// A Desktop that quits on osascript and reopens on open, with a clock that advances 100 ms per command.
final class TaskHarness {
    var rows: Value
    var reopened: Value
    var calls: [String] = []
    var time = 0.0
    var beforeQuit: (() throws -> Void)?
    private(set) var io: Value = .undefined

    init(_ rows: Value = [desktopFixture()[0]], reopened: Value? = nil) {
        self.rows = rows
        self.reopened = reopened ?? [.spread(desktopFixture()[0], ["pid": 700, "desktopPid": 700, "started": "reopened"])]
        io = ["inspect": fn { [unowned self] _ in self.rows }, "now": fn { [unowned self] _ in Value(self.time) }, "command": fn { [unowned self] args in
            let file = args[0].str
            self.calls.append(file)
            self.time += 100
            if file.hasSuffix("osascript") { try self.beforeQuit?() }
            self.rows = file.hasSuffix("osascript") ? [] : self.reopened
            return ["status": 0]
        }]
    }
}

func taskHarness(_ rows: Value = [desktopFixture()[0]], _ reopened: Value? = nil) -> TaskHarness { TaskHarness(rows, reopened: reopened) }

// Runs a move or Undo of the task fixture and crashes it right after the chosen mutation:
// stage record = the target Desktop record link, source/target = that registry's rename,
// receipt = a receipt rename with task transfers, retiring = a receipt rename with a retiring journal.
func interruptTaskFamily(_ h: TaskHome, _ operation: String, _ stage: String, interruptAfter: Int? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let hook: CrashHook = stage == "record" ? .link : .rename
    let destination = stage == "record" ? path.join(h.dir("T"), "local_\(h.notificationId ?? SOURCE).json") : stage == "source" ? h.sourceFile : h.targetFile
    let state = h.paths.state.str, limit = interruptAfter ?? h.interruptAfter
    var mutations = 0
    let crashed = try crashing(on: hook, when: { args in
        let matches: Bool
        if stage == "receipt" || stage == "retiring" {
            guard args[1].hasPrefix(state + "/") else { return false }
            let receipt = try readJSON(args[1])
            matches = stage == "retiring" ? receipt.retiring.truthy : receipt.taskTransfers.length > 0
        } else {
            matches = args[1] == destination
        }
        if matches { mutations += 1 }
        return matches && mutations == limit
    }) {
        let paths = try layout(Value(h.root))
        let all = try accounts(paths, [])
        if operation == "undo" { _ = try undo(paths, ["processes": []]); return }
        let from = Value((h.sourceAccounts ?? [h.acct.P]).map { account in all.find { $0.account.str == account } })
        let to = all.find { $0.account.str == h.acct.T }
        if h.restart {
            var rows: Value = [desktopFixture()[0]]
            let io: Value = ["inspect": fn { _ in rows }, "command": fn { args in rows = args[0].str.hasSuffix("osascript") ? [] : [desktopFixture()[0]]; return ["status": 0] }]
            let planned = try executeMove(from, to, paths, ["io": io])
            _ = try executeMove(from, to, paths, ["io": io, "approve": planned.plan.token])
        } else {
            _ = try executeMove(from, to, paths, ["processes": []])
        }
    }
    ok(crashed, "the \(operation) never reached its \(stage) interruption point", sourceLocation: sourceLocation)
}

// MARK: - Refusals

// A task family whose target twin is enabled, plus an investor session with conflicting replay copies and six forks.
struct Refusal {
    let h: TaskFamily
    let investor: String
    let recordId: String
    let investorFile: String
    let cloud: Value
    let result: Value
}

func refusalFixture(_ mixed: Bool = false) throws -> Refusal {
    let h = try taskFamilyFixture(true, 2, 1, true), investor = id(750), recordId = "local_\(id(751))"
    h.targetRegistry.scheduledTasks[0].enabled = true
    try writeJSON(h.targetFile, h.targetRegistry)
    let rich = entry("user", 750, nil, investor, ["toolUseResult": ["invented": "first"]])
    try h.write(investor, [rich, .spread(rich, ["toolUseResult": ["invented": "different"]])])
    try h.record("P", investor, rehomeRecord(["sessionId": Value(recordId), "title": "Same title", "bridgeSessionIds": ["session_investor"]]))
    let record = path.join(h.dir("P"), "\(recordId).json")
    try rename(h.recordFile("P", investor), record)
    for at in 0..<6 {
        let sid = id(760 + at)
        try h.write(sid, [entry("user", 760 + at, nil, sid)])
        try h.record("P", sid, rehomeRecord(["forkedFromSessionId": Value(recordId)]))
    }
    let ids: [String] = ["cse_investor"] + (mixed ? ["cse_unrelated"] : [])
    let cloud = cloudFixture(h, ["list": fn { _ in Value(ids.map { remoteSession(["id": Value($0), "title": "Same title"]) }) }, "eventRows": fn { _ in remoteRows([rich]) }])
    let (from, to) = try h.selection()
    let result = try executeMove([from], to, h.paths, ["processes": [], "cloud": cloud, "cloudRequested": true])
    return Refusal(h: h, investor: investor, recordId: recordId, investorFile: record, cloud: cloud, result: result)
}

// MARK: - Bridges

// A source transcript attached to Remote Control session cse_prior, moving from P to Z.
final class BridgeHome: Home {
    private(set) var transcriptPath = ""
    private(set) var bridge: Value = .undefined
    private(set) var from: Value = .undefined
    private(set) var to: Value = .undefined
    private(set) var before = Data()

    override init() throws {
        try super.init()
        bridge = ["type": "bridge-session", "sessionId": Value(SOURCE), "bridgeSessionId": "cse_prior", "lastSequenceNum": 7,
                  "ownerAccountUuid": Value(acct.P), "ownerOrganizationUuid": Value(org.P)]
        try write(SOURCE, branchEntries(2, SOURCE, 1).concat([["type": "history-suppression", "sessionId": Value(SOURCE)], bridge]))
        try record("P", SOURCE, rehomeRecord(["bridgeSessionIds": ["session_prior"]]))
        let all = try accounts(paths, [])
        from = all.find { $0.account.str == acct.P }
        to = all.find { $0.account.str == acct.Z }
        transcriptPath = try NodeFS.nativeRealpath(transcript(SOURCE))
        before = try readData(transcriptPath)
    }
}

func bridgeFixture() throws -> BridgeHome { try BridgeHome() }

func assertBridgeRestored(_ before: Data, _ after: Data, _ bridge: Value, sourceLocation: SourceLocation = #_sourceLocation) {
    ok(after.prefix(before.count) == before, "the original transcript bytes are no longer a prefix", sourceLocation: sourceLocation)
    func parse(_ bytes: Data) -> [(String, Value)] {
        String(decoding: bytes, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { ($0, (try? JSON.parse($0)) ?? .undefined) }
    }
    let original = parse(before), current = parse(after)
    let messages = { (rows: [(String, Value)]) in Value.strings(rows.filter { MESSAGES.contains($0.1.type.str) }.map(\.0)) }
    deq(messages(current), messages(original), sourceLocation: sourceLocation)
    deq(current.filter { $0.1.type == "bridge-session" && $0.1.sessionId === bridge.sessionId }.last?.1 ?? .undefined, bridge, sourceLocation: sourceLocation)
}

// MARK: - Pending cloud checks across organizations

final class PendingRow {
    let sid: String, org: String, entries: Value, remote: String
    var status = "active", mode = "ready"
    var updated: Value = .undefined
    init(sid: String, org: String, entries: Value, remote: String) { self.sid = sid; self.org = org; self.entries = entries; self.remote = remote }
}

struct PendingOrganizations {
    let h: Home
    let identity: IdentityFixture
    let rows: [PendingRow]
    let from: Value
    let to: Value
    let before: Value
    let moved: Value
    let calls: Box<[String]>
    let requested: Box<[(String, String)]>
    let client: Value
    var options: Value { ["cloud": client, "processes": identity.processes] }
}

final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

// One P session in each named organization, moved to Z (or to the P login's `to` organization), with a
// scoped cloud client per source organization whose rows a test can switch between ready, waiting and transient.
func pendingOrganizations(orgs: [String] = ["P", "T"], to targetOrg: String? = nil) throws -> PendingOrganizations {
    let h = try home(), identity = try identityFixture(h)
    var rows: [PendingRow] = []
    for (index, name) in orgs.enumerated() {
        let sid = id(9200 + index), org = h.org[name], directory = path.join(h.paths.records.str, h.acct.P, org)
        let entries = branchEntries(4, sid, 9300 + index * 10)
        try mkdirp(directory)
        try h.write(sid, entries)
        try h.record("P", sid, rehomeRecord(["title": Value("Organization \(index)"), "bridgeSessionIds": [Value("session_org\(index)")]]))
        if directory != h.dir("P") { try rename(h.recordFile("P", sid), path.join(directory, "local_\(sid).json")) }
        rows.append(PendingRow(sid: sid, org: org, entries: entries, remote: "cse_org\(index)"))
    }
    if let targetOrg { try mkdirp(path.join(h.paths.records.str, h.acct.P, h.org[targetOrg])) }
    let all = try accounts(h.paths, identity.processes)
    let from = Value(rows.map { row in all.find { $0.account.str == h.acct.P && $0.org.str == row.org } })
    let to = all.find { $0.account.str == (targetOrg != nil ? h.acct.P : h.acct.Z) && $0.org.str == (targetOrg.map { h.org[$0] } ?? h.org.Z) }
    let before = try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str])
    let moved = try move(try inventory(from, to, h.paths, NOOP, ["cloudRequested": true, "processes": []]), to, h.paths)
    let calls = Box<[String]>([]), requested = Box<[(String, String)]>([])
    let client = fn { args in
        let source = args[0]
        eq(source.account, Value(h.acct.P))
        guard let row = rows.first(where: { $0.org == source.org.str }) else {
            Issue.record("no pending row for organization \(source.org)")
            return .undefined
        }
        calls.value.append(source.org.str)
        if row.mode == "transient" { throw jsThrow("Fixture source unavailable", code: "FIXTURE_UNAVAILABLE") }
        let check = { (id: Value) in eq(id, Value(row.remote)); requested.value.append((source.org.str, id.str)) }
        let index = rows.firstIndex { $0 === row }!
        return cloudFixture(h, [
            "org": Value(row.org),
            "list": fn { _ in [remoteSession(["id": Value(row.remote), "title": Value("Organization \(index)"), "status": Value(row.status), "updated_at": row.updated]),
                               remoteSession(["id": "cse_unselected", "title": "Unselected source"])] },
            "session": fn { args in check(args[0]); return remoteState(row.status, row.mode == "waiting" ? ["connection_status": "connected"] : [:]) },
            "eventRows": fn { args in check(args[0]); return remoteRows(row.entries) },
            "archive": fn { args in check(args[0]); row.status = "archived"; return .undefined },
            "unarchive": fn { args in check(args[0]); row.status = "active"; return .undefined },
        ])
    }
    return PendingOrganizations(h: h, identity: identity, rows: rows, from: from, to: to, before: before, moved: moved, calls: calls, requested: requested, client: client)
}

// MARK: - Misc

// After the engine links `file` into place, its record gains focus as if Desktop touched it.
func touchPlaced(_ file: String) {
    let native = fs.link
    fs.link = { a, b in
        try native(a, b)
        if b == file { try writeJSON(file, .spread(try readJSON(file), ["lastFocusedAt": 1000])) }
    }
}

func queuedImagePrompt(_ text: String) -> Value {
    [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "c3ludGhldGljLWltYWdl"]], ["type": "text", "text": Value(text)]]
}

// Moves the project directory behind a symlink and prepares a hard-linked replacement; the returned
// closure repoints the symlink at the replacement.
func mappedProjectFixture(_ h: Home) throws -> () throws -> Void {
    let original = path.join(h.root, "original-project"), replacement = path.join(h.root, "replacement-project")
    try rename(h.project, original)
    try symlink(original, h.project)
    try mkdirp(replacement)
    for name in try readdir(original) {
        let source = path.join(original, name), target = path.join(replacement, name)
        let type = try FileManager.default.attributesOfItem(atPath: source)[.type] as? FileAttributeType
        if type == .typeRegular {
            if Darwin.link(source, target) != 0 { throw fsError(errno, "link", source, target) }
        } else if type == .typeDirectory {
            try mkdirp(target)
            for child in try readdir(source) {
                if Darwin.link(path.join(source, child), path.join(target, child)) != 0 { throw fsError(errno, "link", source, target) }
            }
        }
    }
    return { try unlink(h.project); try symlink(replacement, h.project) }
}
