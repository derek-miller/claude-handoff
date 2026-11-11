import Foundation
import Testing
@testable import HandoffCore

// The synthetic HOME and the record, transcript and cloud builders the behaviour suite shares.

let SOURCE = "00000000-0000-4000-8000-000000000001"
let MESSAGES: Set<String> = ["user", "assistant", "attachment", "system"]

func id(_ k: Int) -> String { "00000000-0000-4000-8000-\(padStart(String(k), 12, "0"))" }

func rehomeRecord(_ extra: Value = [:]) -> Value { .spread(["forkedFromSessionId": nil], extra) }

// Parses JSON lines, skipping blank and malformed ones.
func lines(_ text: String) -> Value {
    Value(text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
        line.trimmingCharacters(in: .whitespaces).isEmpty ? nil : try? JSON.parse(String(line))
    })
}
func lines(_ text: Value) -> Value { lines(text.description) }

func fixture(_ name: String) throws -> Value {
    lines(try readText(path.join(path.dirname(#filePath), "../Fixtures", name)))
}

func entry(_ type: String, _ k: Int, _ parent: Int?, _ session: String, _ extra: Value = [:]) -> Value {
    .spread([
        "type": Value(type),
        "uuid": Value(id(k)),
        "parentUuid": parent.map { Value(id($0)) } ?? .null,
        "sessionId": Value(session),
        "timestamp": Value("2026-09-01T00:00:\(padStart(String(k % 60), 2, "0")).000Z"),
        "cwd": "/tmp/fixture",
        "isSidechain": false,
        "message": ["role": Value(type), "content": Value("message \(k)")],
    ], extra)
}

func branchEntries(_ count: Int, _ session: String, _ start: Int) -> Value {
    Value((0..<count).map { index in entry(index % 2 == 1 ? "assistant" : "user", start + index, index > 0 ? start + index - 1 : nil, session) })
}

func remoteState(_ status: String, _ extra: Value = [:]) -> Value {
    .spread([
        "status": Value(status),
        "connection_status": "disconnected",
        "worker_status": "WORKER_STATUS_UNSPECIFIED",
        "client_presence": [],
        "last_event_at": "2026-09-01T00:01:00.000Z",
    ], extra)
}

func remoteRows(_ entries: Value) -> Value {
    Value(entries.elements.enumerated().map { sequence, payload in
        ["event_type": payload.type, "payload": payload, "sequence_num": Value(sequence), "created_at": payload.timestamp]
    })
}

func remoteSession(_ extra: Value = [:]) -> Value {
    .spread(["created_at": "2026-09-01T00:00:00.000Z", "environment_kind": "bridge", "tags": ["remote-control-sdk"], "status": "active"], extra)
}

func cloudFixture(_ h: Home, _ extra: Value = [:]) -> Value {
    .spread([
        "account": Value(h.acct.P),
        "org": Value(h.org.P),
        "list": fn { _ in [] },
        "eventRows": fn { _ in [] },
        "session": fn { _ in remoteState("active") },
        "archive": NOOP,
        "unarchive": NOOP,
    ], extra)
}

func desktopFixture(_ session: String = SOURCE) -> Value {
    [
        ["pid": 500, "ppid": 1, "started": "first", "executable": "/Applications/Claude.app/Contents/MacOS/Claude", "ids": [], "worker": true, "desktopPid": 500],
        ["pid": 501, "ppid": 500, "started": "worker", "executable": "/tmp/claude", "ids": [Value(session)], "worker": true, "desktopPid": 500],
    ]
}

// A fork of a transcript as Claude Code writes it: fresh uuids linked back to the source messages.
func fork(_ entries: Value, _ sourceId: String, _ targetId: String, _ title: String) -> Value {
    let kept = entries.elements.filter { MESSAGES.contains($0.type.description) && $0.uuid.isString && !$0.isSidechain.truthy }
    var fresh: [String: String] = [:]
    for entry in kept { fresh[entry.uuid.description] = randomUUID() }
    func mapped(_ uuid: Value) -> Value {
        guard let fresh = fresh[uuid.description] else { return .null }
        return Value(fresh)
    }
    var moved: [Value] = kept.map { entry -> Value in
        let logical: Value = entry.logicalParentUuid
        let changes = Value.newObject()
        changes["uuid"] = mapped(entry.uuid)
        changes["parentUuid"] = mapped(entry.parentUuid)
        changes["logicalParentUuid"] = logical.nullish ? logical : mapped(logical)
        changes["sessionId"] = Value(targetId)
        changes["isSidechain"] = false
        changes["forkedFrom"] = ["sessionId": Value(sourceId), "messageUuid": entry.uuid]
        return .spread(entry, changes)
    }
    let title: Value = ["type": "custom-title", "sessionId": Value(targetId), "customTitle": Value(title), "uuid": Value(randomUUID()), "timestamp": Value(isoNow())]
    moved.append(title)
    return Value(moved)
}

struct Four {
    let P: String, T: String, Z: String, Q: String
    subscript(_ key: String) -> String {
        switch key { case "P": P; case "T": T; case "Z": Z; case "Q": Q; default: fatalError("no fixture account \(key)") }
    }
}

// Four accounts with one organization each: P is the Desktop login, T a login backup, Z a .claude-x
// profile, and Q only a Desktop folder.
class Home {
    let root: String
    let paths: Value
    let project: String
    let acct = Four(P: id(901), T: id(902), Z: id(903), Q: id(904))
    let org = Four(P: id(911), T: id(912), Z: id(913), Q: id(914))

    init() throws {
        root = temporaryDirectory("ct-home-")
        process.homedir = { [root] in root }
        paths = try layout(Value(root))
        project = path.join(paths.pool.str, "-tmp-fixture")
        for a in ["P", "T", "Z", "Q"] { try mkdirp(dir(a)) }
        try mkdirp(path.join(root, ".claude-x"))
        try writeJSON(path.join(root, ".claude-x", ".claude.json"), ["oauthAccount": [
            "accountUuid": Value(acct.Z), "organizationUuid": Value(org.Z), "emailAddress": "z@example.com",
            "organizationName": "Zed Person", "organizationType": "claude_max",
        ]])
        try mkdirp(project)
        try mkdirp(paths.backups.str)
        try writeJSON(paths.desktop.str, ["lastKnownAccountUuid": Value(acct.P)])
        try writeJSON(paths.login.str, ["oauthAccount": ["accountUuid": Value(acct.P), "organizationUuid": Value(org.P), "emailAddress": "p@example.com", "organizationName": "Personal P"]])
        try writeJSON(path.join(paths.backups.str, ".claude.json.backup.1"), ["oauthAccount": [
            "accountUuid": Value(acct.T), "organizationUuid": Value(org.T), "emailAddress": "t@example.com", "organizationName": "Team T",
        ]])
    }

    func dir(_ a: String) -> String { path.join(paths.records.str, acct[a], org[a]) }

    func recordFile(_ a: String, _ sid: String) -> String { path.join(dir(a), "local_\(sid).json") }

    func record(_ a: String, _ sid: String, _ extra: Value = [:]) throws {
        try writeText(recordFile(a, sid), JSON.text(.spread([
            "sessionId": Value("local_\(sid)"),
            "cliSessionId": Value(sid),
            "cwd": "/tmp/fixture",
            "originCwd": "/tmp/fixture",
            "createdAt": 1,
            "lastActivityAt": 2,
            "lastFocusedAt": 2,
            "model": "x",
            "isArchived": false,
            "title": Value("Session \(String(sid.suffix(3)))"),
            "titleSource": "user",
            "permissionMode": "auto",
            "bridgeSessionIds": [],
            "spawnSeed": ["a": 1],
        ], extra), space: 2))
    }

    func transcript(_ sid: String) -> String { path.join(project, "\(sid).jsonl") }

    func write(_ sid: String, _ entries: Value) throws {
        try writeText(transcript(sid), entries.elements.map { JSON.text($0) }.joined(separator: "\n") + "\n")
    }

    // The accounts() row for a fixture account, in its own organization unless another is named.
    func account(_ a: String, org o: String? = nil, _ processes: Value = .undefined) throws -> Value {
        let all = try accounts(paths, processes)
        return all.find { $0.account.str == acct[a] && $0.org.str == org[o ?? a] }
    }
}

func home() throws -> Home { try Home() }

func moveWithPending(_ h: Home, _ from: Value, _ to: Value, _ cloud: Value = .null) throws -> Value {
    let pending = id(997)
    try h.record("T", pending, rehomeRecord(["title": "Pending local source"]))
    let current = try accounts(h.paths)
    let source = from.map { row in current.find { $0.account === row.account && $0.org === row.org } }
    let target = current.find { $0.account === to.account && $0.org === to.org }
    let result = try move(try inventory(source, target, h.paths, NOOP, ["cloud": cloud, "cloudRequested": true]), target, h.paths)
    try unlink(path.join(h.dir("T"), "local_\(pending).json"))
    return result
}

// SHA-256 of every file under the given directories; receipts and journals only under state.
func fixtureSnapshot(_ h: Home, _ directories: [String]? = nil) throws -> Value {
    let out = Value.newObject()
    let state = h.paths.state.str
    func visit(_ dir: String) throws {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in names.sorted() {
            let file = path.join(dir, name)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: file, isDirectory: &isDir)
            if isDir.boolValue { try visit(file) }
            else if dir != state || JSRegExp.cached(#"^\d.*\.json(?:\.journal)?$"#).test(name) { out[file] = Value(sha(try readData(file))) }
        }
    }
    for dir in directories ?? [h.paths.records.str, h.paths.pool.str, state] { try visit(dir) }
    return out
}

// The Desktop log and running app the signed-in identity checks read.
struct IdentityFixture {
    let started: Double
    let processes: Value
    let logs: String
    let h: Home

    func event(_ offset: Double, _ text: String) -> String { "\(localTime(started + offset * 1000)) [info] \(text)\n" }
    func `init`(_ offset: Double = 0, _ account: String? = nil, _ org: String? = nil) -> String {
        event(offset, "[LocalSessionManager] Initialization succeeded \u{2014} accountId=\(account ?? h.acct.P), orgId=\(org ?? h.org.P), existingSessions=0")
    }
    func write(_ text: String, _ name: String = "main.log") throws { try writeText(path.join(logs, name), text) }
}

func identityFixture(_ h: Home) throws -> IdentityFixture {
    let started = ((dateNow() - 24 * 60 * 60 * 1000) / 1000).rounded(.down) * 1000
    let processes: Value = [["pid": 500, "started": Value(dateString(started)), "executable": "/Applications/Claude.app/Contents/MacOS/Claude"]]
    try mkdirp(h.paths.logs.str)
    let f = IdentityFixture(started: started, processes: processes, logs: h.paths.logs.str, h: h)
    try f.write(f.`init`())
    return f
}

// new Date(ms).toString(), e.g. "Fri Sep 04 2026 18:00:00 GMT-0700 (Pacific Daylight Time)".
func dateString(_ ms: Double) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT'xx (zzzz)"
    return f.string(from: Date(timeIntervalSince1970: ms / 1000))
}

// The Desktop log's local "YYYY-MM-DD HH:MM:SS".
func localTime(_ ms: Double) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: Date(timeIntervalSince1970: ms / 1000))
}
