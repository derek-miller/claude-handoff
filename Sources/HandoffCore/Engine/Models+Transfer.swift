import Foundation

// Typed views for the objects transfers, Finish and Keep local read. Each keeps the object as its storage.

// What a transfer carries between its units: the receipt it appends to, the stamp it files under, and the hooks it calls.
@dynamicMemberLookup
struct TransferContext {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    // The receipt being appended to, as {file, receipt}.
    var existing: Value { raw["existing"] }
    var at: Value { raw["at"] }
    var restart: Value { raw["restart"] }
    var check: Value { raw["check"] }
    var progress: Value { raw["progress"] }
    var sources: Value { raw["sources"] }
    var snapshots: Value { raw["snapshots"] }
    var taskFamily: TaskFamily { TaskFamily(raw["taskFamily"]) }
    var refreshCloudChecks: Value { raw["refreshCloudChecks"] }
    var wholeOperation: Value { raw["wholeOperation"] }
    var sessionProgress: Value { raw["sessionProgress"] }

    @available(*, unavailable, message: "declare the field on TransferContext")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// The third argument of a progress report.
@dynamicMemberLookup
struct ProgressExtra {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var live: Value { raw["live"] }
    var total: Value { raw["total"] }
    var completed: Value { raw["completed"] }
    var sourceId: Value { raw["sourceId"] }
    var sourceLabel: Value { raw["sourceLabel"] }
    var moved: Value { raw["moved"] }

    @available(*, unavailable, message: "declare the field on ProgressExtra")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// What verify returns for the sessions it checked.
@dynamicMemberLookup
struct VerifyResult {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var ok: Value { raw["ok"] }
    var lines: Value { raw["lines"] }
    var problems: Value { raw["problems"] }

    @available(*, unavailable, message: "declare the field on VerifyResult")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A receipt's verification block.
@dynamicMemberLookup
struct ReceiptVerification {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var ok: Value {
        get { raw["ok"] }
        nonmutating set { raw["ok"] = newValue }
    }
    var problems: Value {
        get { raw["problems"] }
        nonmutating set { raw["problems"] = newValue }
    }

    @available(*, unavailable, message: "declare the field on ReceiptVerification")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A receipt's cloudLinks entry: a moved session and the cloud sessions bridged to it.
@dynamicMemberLookup
struct CloudLink {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var targetId: Value { raw["targetId"] }
    var bridgeIds: Value { raw["bridgeIds"] }

    @available(*, unavailable, message: "declare the field on CloudLink")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

extension TaskFamily {
    var isPresent: Bool { raw.truthy }
    var key: Value { raw["key"] }
    var routes: Value { raw["routes"] }
    var files: Value { raw["files"] }
}

extension RetirementItem {
    // The source record a retirement moved aside; superseded target copies carry by instead.
    var source: Value { raw["source"] }
    var by: Value { raw["by"] }
}

extension PlacedSession {
    var events: Value { raw["events"] }
    var archived: Value { raw["archived"] }
}

extension FailedSession {
    var retained: Value { raw["retained"] }
}

extension CloudCheck {
    var label: Value { raw["label"] }
    var later: Value { raw["later"] }
    var sessionIds: Value {
        get { raw["sessionIds"] }
        nonmutating set { raw["sessionIds"] = newValue }
    }
    var loginAt: Value {
        get { raw["loginAt"] }
        nonmutating set { raw["loginAt"] = newValue }
    }
    var authRetries: Value {
        get { raw["authRetries"] }
        nonmutating set { raw["authRetries"] = newValue }
    }
}

extension CloudPlan {
    var isolatedId: Value { raw["isolatedId"] }
}

extension Receipt {
    var restart: Value {
        get { raw["restart"] }
        nonmutating set { raw["restart"] = newValue }
    }
}

extension RecoveryOptions {
    var processes: Value { raw["processes"] }
    var report: Value { raw["report"] }
    var artifactLimit: Value { raw["artifactLimit"] }
}

extension LatestReceipt {
    var projected: Value { raw["projected"] }
}

extension DeferredWorkflow {
    var file: Value { raw["file"] }
}

extension Identity {
    var at: Value { raw["at"] }
}

extension ThrownError {
    var budgetWork: Value { raw["budgetWork"] }
}

extension WorkflowResult {
    var undo: Value { raw["undo"] }
}
