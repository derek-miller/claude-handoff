import Foundation

// Stand-ins for the machine's memory, its pressure level and the clock that a memory budget reads.
@dynamicMemberLookup
struct MemoryIO {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var total: Value { raw["total"] }
    var heap: Value { raw["heap"] }
    var usage: Value { raw["usage"] }
    var available: Value { raw["available"] }
    var platform: Value { raw["platform"] }
    var now: Value { raw["now"] }
    var pressure: Value { raw["pressure"] }

    @available(*, unavailable, message: "declare the field on MemoryIO")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// One sample of the process's memory use.
@dynamicMemberLookup
struct MemoryUsage {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var rss: Value { raw["rss"] }
    var heapUsed: Value { raw["heapUsed"] }

    @available(*, unavailable, message: "declare the field on MemoryUsage")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A memory budget as memoryBudget returns it, or as a caller supplies one.
@dynamicMemberLookup
struct MemoryBudget {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var limit: Value { raw["limit"] }
    var heap: Value { raw["heap"] }
    var signature: Value { raw["signature"] }

    @available(*, unavailable, message: "declare the field on MemoryBudget")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// Options that may carry a memory budget, directly or in their cloud options.
@dynamicMemberLookup
struct MemoryOwner {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var memory: Value { raw["memory"] }
    var cloud: MemoryOwner { MemoryOwner(raw["cloud"]) }

    @available(*, unavailable, message: "declare the field on MemoryOwner")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A session waiting on a cloud check or held for its worker, as the pending views list it.
@dynamicMemberLookup
struct WaitingRow {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var id: Value { raw["id"] }
    var localId: Value { raw["localId"] }
    var recordId: Value { raw["recordId"] }
    var code: Value { raw["code"] }

    @available(*, unavailable, message: "declare the field on WaitingRow")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// One source session a held row stands for.
@dynamicMemberLookup
struct HeldSource: AccountKey {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var id: Value { raw["id"] }
    var file: Value { raw["file"] }

    @available(*, unavailable, message: "declare the field on HeldSource")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A session registration Claude Code writes under ~/.claude/sessions for each running worker.
@dynamicMemberLookup
struct SessionRegistration {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var pid: Value { raw["pid"] }
    var pidDomain: Value { raw["pidDomain"] }
    var procStart: Value { raw["procStart"] }
    var sessionId: Value { raw["sessionId"] }
    var cwd: Value { raw["cwd"] }
    var name: Value { raw["name"] }

    @available(*, unavailable, message: "declare the field on SessionRegistration")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A transcript line, as far as telling messages from bookkeeping needs.
@dynamicMemberLookup
struct TranscriptEntry {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var type: Value { raw["type"] }
    var uuid: Value { raw["uuid"] }
    var isSidechain: Value { raw["isSidechain"] }

    @available(*, unavailable, message: "declare the field on TranscriptEntry")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A line of restart-events.jsonl.
@dynamicMemberLookup
struct RestartEvent {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var event: Value { raw["event"] }
    var receiptId: Value { raw["receiptId"] }
    var attemptId: Value { raw["attemptId"] }

    @available(*, unavailable, message: "declare the field on RestartEvent")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

extension HeldRow {
    var id: Value { raw["id"] }
    var title: Value { raw["title"] }
    var recordId: Value { raw["recordId"] }
    // The source record file the row holds.
    var record: Value { raw["record"] }
    var heldSources: [HeldSource] { raw["sources"].elements.map(HeldSource.init) }
    var workers: Value { raw["workers"] }
}

extension AccountRef {
    var accountLabel: Value { raw["accountLabel"] }
}

extension PendingSource {
    var sessionIds: Value { raw["sessionIds"] }
}

extension CloudCheck {
    var cancelledWaiting: Value {
        get { raw["cancelledWaiting"] }
        nonmutating set { raw["cancelledWaiting"] = newValue }
    }
    var cancelledAt: Value {
        get { raw["cancelledAt"] }
        nonmutating set { raw["cancelledAt"] = newValue }
    }
}

extension DesktopSession {
    var archived: Value { raw["archived"] }
    // Set when a session is listed together with its account.
    var account: Value { raw["account"] }
}

extension RecoveryOptions {
    var inspect: Value { raw["inspect"] }
}

extension ProcessRow {
    var started: Value { raw["started"] }
    // From the worker's session registration, when it has one.
    var cwd: Value { raw["cwd"] }
    var sessionName: Value { raw["sessionName"] }
}

extension RestartIO {
    var reserve: Value { raw["reserve"] }
    var shutdownWait: Value { raw["shutdownWait"] }
    var stallWait: Value { raw["stallWait"] }
}

extension ThrownError {
    // An error object errorObject() already produced, or nothing when no error was caught.
    init(object raw: Value) { self.raw = raw }
}

extension CommandResult {
    var timedOut: Value { raw["timedOut"] }
}
