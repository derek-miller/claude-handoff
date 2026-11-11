import Foundation

// Typed views over the engine's objects. Each keeps the object as its storage: Desktop's records carry fields the
// engine never reads and must write back unchanged, and results go out as JSON with their keys in a fixed order.

// A Desktop session record, `local_<id>.json` in an account's records folder.
struct DesktopRecord {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var sessionId: String? { raw["sessionId"].asString }
    var cliSessionId: String? { raw["cliSessionId"].asString }
    var cwd: String? { raw["cwd"].asString }
    var title: String? { raw["title"].asString }
    var isArchived: Bool { raw["isArchived"] === true }
    var forkedFromSessionId: String? { raw["forkedFromSessionId"].asString }
    var scheduledTaskId: String? { raw["scheduledTaskId"].asString }
    var notifySessionId: String? { raw["notifySessionId"].asString }
}

// A Desktop session as accounts() lists it: the record file, the record and the fields read from it.
struct DesktopSession {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }

    init(file: Value, record: Value) {
        raw = [
            "file": file,
            "id": UUID.test((record["cliSessionId"] ?? "").description) ? record["cliSessionId"] : .null,
            "cwd": record["cwd"] ?? "",
            "title": record["title"] ?? "",
            "archived": Value(record["isArchived"] === true),
            "createdAt": record["createdAt"] ?? 0,
            "activeAt": record["lastActivityAt"] ?? 0,
            "focusedAt": record["lastFocusedAt"] ?? 0,
            "record": record,
        ]
    }

    var file: String { raw["file"].description }
    // The Claude Code session id, when the record names a valid one.
    var id: String? { raw["id"].asString }
    var cwd: Value { raw["cwd"] }
    var title: Value { raw["title"] }
    var activeAt: Double { toNumber(raw["activeAt"]) }
    var focusedAt: Double { toNumber(raw["focusedAt"]) }
    var record: DesktopRecord { DesktopRecord(raw["record"]) }
    var workingDirectories: [String] { [raw["cwd"], raw["record"]["originCwd"]].compactMap(\.asString).filter { !$0.isEmpty } }
}

// Anything that names an account and org pair.
protocol AccountKey {
    var raw: Value { get }
}

extension AccountKey {
    var accountId: Value { raw["account"] }
    var orgId: Value { raw["org"] }
    func same(_ other: some AccountKey) -> Bool { raw.truthy && other.raw.truthy && accountId === other.accountId && orgId === other.orgId }
}

// An account and org pair as accounts() lists it.
struct Account: AccountKey {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var dir: String { raw["dir"].description }
    var label: String {
        get { raw["label"].description }
        nonmutating set { raw["label"] = Value(newValue) }
    }
    var stats: String {
        get { raw["stats"].description }
        nonmutating set { raw["stats"] = Value(newValue) }
    }
    var active: Bool {
        get { raw["active"].truthy }
        nonmutating set { raw["active"] = Value(newValue) }
    }
    var orgName: Value { raw["orgName"] }
    var activeAt: Double { toNumber(raw["activeAt"]) }
    var sessions: [DesktopSession] { raw["sessions"].elements.map(DesktopSession.init) }
    var unreadable: [Value] { raw["unreadable"].elements }
    var isEmpty: Bool { raw["sessions"].length == 0 && raw["unreadable"].length == 0 }
    var taskError: Value { raw["taskError"] }
    var taskRegistry: TaskRegistry { TaskRegistry(raw["taskSessions"]) }
    var taskFile: Value { raw["taskFile"] }
    // Every session in the folder, when accounts() narrowed `sessions`.
    var allSessions: Value { raw["allSessions"] ?? raw["sessions"] }
}

// An account and org pair that is not a full account row: a folder found on disk, a login, a receipt's namespace.
struct AccountPair: AccountKey {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
}

// Who Desktop is signed in as, read from its log: a known account and org, or why it is not known.
struct Identity: AccountKey {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    // known, unknown or logged-out.
    var state: Value { raw["state"] }
    var isKnown: Bool { state === "known" }
    func isLogin(of account: some AccountKey) -> Bool { account.accountId.truthy && account.accountId === accountId && (state.nullish || isKnown) }
}

// A scheduled-task registry (scheduled-tasks.json). taskSessions() returns it as the set of record ids its tasks
// notify, with the parsed file, or null when there is none, attached as `registry`.
struct TaskRegistry {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var data: Value { raw["registry"] }
    var tasks: Value { data["scheduledTasks"] ?? Value.newArray() }
    // One of the per-task state maps (TASK_STATE_KEYS), keyed by task id.
    func state(_ key: String) -> Value { data[key] ?? Value.newObject() }
    func notifies(_ recordId: Value) -> Bool { raw.has(recordId) }
}

// A row that belongs to a Desktop record: a session, an inventory source (which carries the session's fields) or an
// inventory target (which nests the session and keeps only the record's id in `record`).
protocol RecordHolder {
    var raw: Value { get }
}

extension RecordHolder {
    var desktopRecord: DesktopRecord { DesktopRecord(raw["session"]["record"] ?? raw["record"] ?? Value.newObject()) }
    var desktopFile: Value { raw["session"]["file"] ?? raw["file"] }
}

extension DesktopSession: RecordHolder {}

// A source session in an inventory: the DesktopSession's fields merged with its account, transcript and history
// analysis, plus the fields planning adds. Copies of one history are grouped as one row listing them in `members`.
struct MoveSource: RecordHolder {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var id: Value { raw["id"] }
    var file: Value { raw["file"] }
    var account: Account { Account(raw["account"]) }
    var transcript: Value { raw["transcript"] }
    var sidecar: Value { raw["sidecar"] }
    var roots: Value { raw["roots"] }
    var isInvalid: Bool { raw["invalid"].truthy }
    // Every copy in this row's group, or the row alone when it is not grouped.
    var members: [MoveSource] { (raw["members"].nullish ? [raw] : raw["members"].elements).map(MoveSource.init) }
    var taskFamily: Value {
        get { raw["taskFamily"] }
        nonmutating set { raw["taskFamily"] = newValue }
    }
    var schedulerBusy: Value {
        get { raw["schedulerBusy"] }
        nonmutating set { raw["schedulerBusy"] = newValue }
    }
    var cloudTargetId: Value {
        get { raw["cloudTargetId"] }
        nonmutating set { raw["cloudTargetId"] = newValue }
    }
}

// A destination session that already holds history: its DesktopSession in `session`, its record id in `record`.
struct MoveTarget: RecordHolder {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var id: Value { raw["id"] }
    var recordId: Value { raw["record"] }
    var session: DesktopSession { DesktopSession(raw["session"]) }
    var account: Account { Account(raw["account"]) }
}
