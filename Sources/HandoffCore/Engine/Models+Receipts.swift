import Foundation

// Typed views for the objects receipts, journals, Undo and recovery read. Each keeps the object as its storage, since
// receipts and task registries are written back unchanged.

// A scheduled-task family a move carries between two task namespaces, as the receipt records it in taskTransfers.
@dynamicMemberLookup
struct TaskFamily {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var ids: Value { raw["ids"] }
    var recordIds: Value { raw["recordIds"] }
    var links: Value { raw["links"] }
    var from: Value { raw["from"] }
    var to: Value { raw["to"] }
    var sourceFile: Value { raw["sourceFile"] }
    var targetFile: Value { raw["targetFile"] }
    var sourceOrder: Value { raw["sourceOrder"] }
    var tasks: Value { raw["tasks"] }
    var replaced: Value {
        get { raw["replaced"] }
        nonmutating set { raw["replaced"] = newValue }
    }
    var state: Value { raw["state"] }
    var targetState: Value { raw["targetState"] }
    var targetStateFields: Value { raw["targetStateFields"] }
    var targetHadTasks: Value { raw["targetHadTasks"] }
    var targetExisted: Value { raw["targetExisted"] }

    @available(*, unavailable, message: "declare the field on TaskFamily")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A target task a family's move replaced, and where it sat in the target registry.
@dynamicMemberLookup
struct ReplacedTask {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var task: Value { raw["task"] }
    var index: Value { raw["index"] }

    @available(*, unavailable, message: "declare the field on ReplacedTask")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// An entry in a scheduled-task registry.
@dynamicMemberLookup
struct ScheduledTask {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var id: Value { raw["id"] }
    var notifySessionId: Value { raw["notifySessionId"] }

    @available(*, unavailable, message: "declare the field on ScheduledTask")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A Desktop record file and what it parsed to, as folderRecords lists them.
@dynamicMemberLookup
struct FolderRecord {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var file: Value { raw["file"] }
    var record: DesktopRecord { DesktopRecord(raw["record"]) }

    @available(*, unavailable, message: "declare the field on FolderRecord")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// The options reconcile, recovery and Undo take.
@dynamicMemberLookup
struct RecoveryOptions {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var check: Value { raw["check"] }
    var background: Value { raw["background"] }
    var automatic: Value { raw["automatic"] }
    var receiptFile: Value { raw["receiptFile"] }
    var io: Value { raw["io"] }
    var cloud: Value { raw["cloud"] }

    @available(*, unavailable, message: "declare the field on RecoveryOptions")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// Stand-ins for the clock, process table, commands and waiting that reopening Desktop uses.
@dynamicMemberLookup
struct RestartIO {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var now: Value { raw["now"] }
    var inspect: Value { raw["inspect"] }
    var command: Value { raw["command"] }
    var wait: Value { raw["wait"] }

    @available(*, unavailable, message: "declare the field on RestartIO")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// How a command exited.
@dynamicMemberLookup
struct CommandResult {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var status: Value { raw["status"] }

    @available(*, unavailable, message: "declare the field on CommandResult")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// Where a rollback found one of a placed session's files: in place, parked, or neither.
@dynamicMemberLookup
struct ArtifactLocation {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var error: Value { raw["error"] }
    var original: Value { raw["original"] }
    var parked: Value { raw["parked"] }
    var file: Value { raw["file"] }
    // True while the file is still in place and has to be parked.
    var move: Value { raw["move"] }

    @available(*, unavailable, message: "declare the field on ArtifactLocation")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A receipt's local recovery state: why recovery is blocked, and the rollback folder.
@dynamicMemberLookup
struct LocalRecovery {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var blocked: Value { raw["blocked"] }
    var rollback: Value { raw["rollback"] }

    @available(*, unavailable, message: "declare the field on LocalRecovery")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// How far a move's finalization got: how many sessions, superseded items and task families were already final, and
// the verification and held sessions to put back when it is rolled back.
@dynamicMemberLookup
struct AppendCheckpoint {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var sessions: Value { raw["sessions"] }
    var superseded: Value { raw["superseded"] }
    var taskTransfers: Value { raw["taskTransfers"] }
    var verification: Value { raw["verification"] }
    var held: Value { raw["held"] }

    @available(*, unavailable, message: "declare the field on AppendCheckpoint")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// One line of a move journal.
@dynamicMemberLookup
struct JournalPatch {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var sequence: Value { raw["sequence"] }
    var pending: Value { raw["pending"] }

    @available(*, unavailable, message: "declare the field on JournalPatch")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// What restoring Remote Control sessions for an undo did, and what still waits on a sign-in.
@dynamicMemberLookup
struct RemoteRestore {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var problems: Value { raw["problems"] }
    var pending: Value { raw["pending"] }
    var restored: Value { raw["restored"] }

    @available(*, unavailable, message: "declare the field on RemoteRestore")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A Remote Control session a move was archiving when it stopped.
@dynamicMemberLookup
struct PendingArchive {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var id: Value { raw["id"] }
    var title: Value { raw["title"] }
    var activation: Value { raw["activation"] }
    var activationRecord: Value { raw["activation"]["record"] }

    @available(*, unavailable, message: "declare the field on PendingArchive")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A source another session's history carries: the carrier's id and the target that carries it.
@dynamicMemberLookup
struct Carrier {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var history: MoveTarget { MoveTarget(raw["history"]) }

    @available(*, unavailable, message: "declare the field on Carrier")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// What a recovery step reports: what it acted on and what happened.
@dynamicMemberLookup
struct RecoveryNote {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var title: Value { raw["title"] }
    var error: Value { raw["error"] }
    var restoreProblems: Value { raw["restoreProblems"] }

    @available(*, unavailable, message: "declare the field on RecoveryNote")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A file's device and inode, which tell a file a move created from one made later at the same path.
@dynamicMemberLookup
struct FileIdentity {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var dev: Value { raw["dev"] }
    var ino: Value { raw["ino"] }

    @available(*, unavailable, message: "declare the field on FileIdentity")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

extension PlacedSession {
    var creationRequired: Value { raw["creationRequired"] }
    var created: FileIdentity { FileIdentity(raw["created"]) }
}

extension MoveSource {
    var sidecars: Value { raw["sidecars"] }
    var snapshot: Value { raw["snapshot"] }
    // taskOwned as stored, which Bool-valued MoveSource.taskOwned flattens.
    var taskOwnedValue: Value {
        get { raw["taskOwned"] }
        nonmutating set { raw["taskOwned"] = newValue }
    }
}

extension MoveTarget {
    var id: Value { raw["id"] }
    var transcript: Value { raw["transcript"] }
    var roots: Value { raw["roots"] }
    var members: Value { raw["members"] }
}

extension LatestReceipt {
    var name: Value { raw["name"] }
}

extension PendingRecovery {
    var file: Value { raw["file"] }
}

extension RestartAttempt {
    var recoveredAt: Value {
        get { raw["recoveredAt"] }
        nonmutating set { raw["recoveredAt"] = newValue }
    }
}

extension ThrownError {
    var path: Value { raw["path"] }
}

extension ReceiptSummary {
    var notMoved: Value { raw["notMoved"] }
}
