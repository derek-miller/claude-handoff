import Foundation

// Views over retirement plans, Remote Control archival and the receipt's bookkeeping of cloud attempts.

extension RetirementItem {
    var isSource: Bool { raw["source"].truthy }
    // The file the item moves aside, which also keys the row it was planned from.
    var retiredFile: Value { raw["moved"][0][0] }
}

// A destination history and the session id that carries it, as retire() pairs them.
struct CarriedHistory {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var by: Value { raw["by"] }
    var history: Value { raw["history"] }
}

// The DesktopSession a target row keeps in `session`, as the row stores it.
struct TargetSession {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var file: Value { raw["file"] }
    var title: Value { raw["title"] }
    var record: Value {
        get { raw["record"] }
        nonmutating set { raw["record"] = newValue }
    }
    var archived: Value {
        get { raw["archived"] }
        nonmutating set { raw["archived"] = newValue }
    }
}

extension MoveTarget {
    var session: TargetSession { TargetSession(raw["session"]) }
}

extension PlacedSession {
    var session: TargetSession { TargetSession(raw["session"]) }
}

extension RemoteSession {
    var connectionStatus: Value { raw["connection_status"] }
    var clientPresence: Value { raw["client_presence"] }
    var workerStatus: Value { raw["worker_status"] }
    var lastEventAt: Value { raw["last_event_at"] }
    var externalMetadata: Value { raw["external_metadata"] }
    var requiresActionDetailsList: Value { raw["requires_action_details_list"] }
}

// A Remote Control session's event rows, read between two idle checks that saw the same event marker.
struct StableRemoteRows {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var rows: Value { raw["rows"] }
    var marker: Value { raw["marker"] }
    var stateSha: Value { raw["stateSha"] }
    var session: RemoteSession { RemoteSession(raw["session"]) }
}

// A claude.ai client for one account: functions that read and archive its Remote Control sessions.
struct CloudClient {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var session: Value { raw["session"] }
    var eventRows: Value { raw["eventRows"] }
    var archive: Value { raw["archive"] }
    var unarchive: Value { raw["unarchive"] }
}

extension CloudPlan {
    var client: CloudClient { CloudClient(raw["client"]) }
    var source: Value { raw["source"] }
    var artifacts: Value { raw["artifacts"] }
}

// A Remote Control session that local history covers, and the local target that covers it.
struct CloudMatch {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var session: RemoteSession { RemoteSession(raw["session"]) }
    var account: AccountRef { AccountRef(raw["account"]) }
    var conversationSha: Value { raw["conversationSha"] }
    var target: MatchTarget { MatchTarget(raw["target"]) }
}

// The local side of a cloud match: a target the move made, or an existing row matched by its artifacts.
struct MatchTarget {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var id: Value { raw["id"] }
    var kind: Value { raw["kind"] }
    var matchMode: Value { raw["matchMode"] }
    var artifactCounts: Value { raw["artifactCounts"] }
    var artifactSignature: Value { raw["artifactSignature"] }
    var row: Value { raw["row"] }
    var failed: Value { raw["failed"] }
    var retained: RetainedTranscript { RetainedTranscript(raw["retained"]) }
}

// A retained local transcript a match relies on, with what it held when matched.
struct RetainedTranscript {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var transcript: Value { raw["transcript"] }
    var canonicalTranscript: Value { raw["canonicalTranscript"] }
    var fingerprint: Value { raw["fingerprint"] }
    var contentSha: Value { raw["contentSha"] }
}

// An archived target record un-archived before its Remote Control session is archived, with both versions' hashes.
struct TargetActivation {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var record: Value { raw["record"] }
    var beforeSha: Value { raw["beforeSha"] }
    var beforeSemantic: Value { raw["beforeSemantic"] }
    var afterSha: Value { raw["afterSha"] }
    var afterSemantic: Value { raw["afterSemantic"] }
    var after: Value { raw["after"] }
}

extension PendingArchive: AccountKey {
    var lastEventAt: Value { raw["lastEventAt"] }
    var stateSha: Value { raw["stateSha"] }
}

extension CloudCheck {
    var isPresent: Bool { raw.truthy }
    var failures: Value {
        get { raw["failures"] }
        nonmutating set { raw["failures"] = newValue }
    }
    var attemptEngine: Value {
        get { raw["attemptEngine"] }
        nonmutating set { raw["attemptEngine"] = newValue }
    }
    var attemptBudget: Value {
        get { raw["attemptBudget"] }
        nonmutating set { raw["attemptBudget"] = newValue }
    }
}

extension FailedSession {
    var localId: Value { raw["localId"] }
    var limitEngine: Value {
        get { raw["limitEngine"] }
        nonmutating set { raw["limitEngine"] = newValue }
    }
    var limitBudget: Value {
        get { raw["limitBudget"] }
        nonmutating set { raw["limitBudget"] = newValue }
    }
}

extension RecoveryOptions {
    var active: Value { raw["active"] }
}
