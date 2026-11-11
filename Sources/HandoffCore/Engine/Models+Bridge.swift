import Foundation

// Typed views for the bridge, rehome and failure objects. Each keeps the object as its storage: plans and rows are
// saved in receipts, and transcripts and records are written back unchanged.

// A planned bridge-metadata append to a transcript, or its undo: where it goes, what the file held before, the exact
// bytes and what the file hashes to after. Receipts keep it as bridgeAppend or bridgeUndo on a session row.
struct BridgePlan {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var transcript: Value {
        get { raw["transcript"] }
        nonmutating set { raw["transcript"] = newValue }
    }
    var canonical: Value {
        get { raw["canonical"] }
        nonmutating set { raw["canonical"] = newValue }
    }
    var sessionId: Value {
        get { raw["sessionId"] }
        nonmutating set { raw["sessionId"] = newValue }
    }
    var recordIds: Value {
        get { raw["recordIds"] }
        nonmutating set { raw["recordIds"] = newValue }
    }
    var dev: Value {
        get { raw["dev"] }
        nonmutating set { raw["dev"] = newValue }
    }
    var ino: Value {
        get { raw["ino"] }
        nonmutating set { raw["ino"] = newValue }
    }
    var length: Value {
        get { raw["length"] }
        nonmutating set { raw["length"] = newValue }
    }
    var sha: Value {
        get { raw["sha"] }
        nonmutating set { raw["sha"] = newValue }
    }
    var afterSha: Value {
        get { raw["afterSha"] }
        nonmutating set { raw["afterSha"] = newValue }
    }
    var fingerprint: Value {
        get { raw["fingerprint"] }
        nonmutating set { raw["fingerprint"] = newValue }
    }
    var bytes: Value {
        get { raw["bytes"] }
        nonmutating set { raw["bytes"] = newValue }
    }
    var original: Value {
        get { raw["original"] }
        nonmutating set { raw["original"] = newValue }
    }
    var continuation: Value {
        get { raw["continuation"] }
        nonmutating set { raw["continuation"] = newValue }
    }
    var applied: Value {
        get { raw["applied"] }
        nonmutating set { raw["applied"] = newValue }
    }
}

// How far a partly written append got, so recovery can finish it.
struct BridgeContinuation {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var length: Value {
        get { raw["length"] }
        nonmutating set { raw["length"] = newValue }
    }
    var sha: Value {
        get { raw["sha"] }
        nonmutating set { raw["sha"] = newValue }
    }
    var fingerprint: Value {
        get { raw["fingerprint"] }
        nonmutating set { raw["fingerprint"] = newValue }
    }
    var bytes: Value {
        get { raw["bytes"] }
        nonmutating set { raw["bytes"] = newValue }
    }
}

// What bridgeRead found in a transcript: its size, fingerprint and hashes, the last bridge entry, and the bytes after
// the planned offset.
struct BridgeState {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var length: Value {
        get { raw["length"] }
        nonmutating set { raw["length"] = newValue }
    }
    var fingerprint: Value {
        get { raw["fingerprint"] }
        nonmutating set { raw["fingerprint"] = newValue }
    }
    var sha: Value {
        get { raw["sha"] }
        nonmutating set { raw["sha"] = newValue }
    }
    var hash: Value {
        get { raw["hash"] }
        nonmutating set { raw["hash"] = newValue }
    }
    var prefixHash: Value {
        get { raw["prefixHash"] }
        nonmutating set { raw["prefixHash"] = newValue }
    }
    var intendedSha: Value {
        get { raw["intendedSha"] }
        nonmutating set { raw["intendedSha"] = newValue }
    }
    var prefixSha: Value {
        get { raw["prefixSha"] }
        nonmutating set { raw["prefixSha"] = newValue }
    }
    var prefixLast: Value {
        get { raw["prefixLast"] }
        nonmutating set { raw["prefixLast"] = newValue }
    }
    var tail: Value {
        get { raw["tail"] }
        nonmutating set { raw["tail"] = newValue }
    }
    var last: Value {
        get { raw["last"] }
        nonmutating set { raw["last"] = newValue }
    }
    var invalid: Value {
        get { raw["invalid"] }
        nonmutating set { raw["invalid"] = newValue }
    }
    var newline: Value {
        get { raw["newline"] }
        nonmutating set { raw["newline"] = newValue }
    }
}

// A bridge-session line in a Claude Code transcript.
struct BridgeEntry {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    // Older entries spell the key bridge_session_id.
    var bridgeSessionId: Value { raw["bridgeSessionId"] ?? raw["bridge_session_id"] }
    var type: Value {
        get { raw["type"] }
        nonmutating set { raw["type"] = newValue }
    }
    var sessionId: Value {
        get { raw["sessionId"] }
        nonmutating set { raw["sessionId"] = newValue }
    }
    var ownerAccountUuid: Value {
        get { raw["ownerAccountUuid"] }
        nonmutating set { raw["ownerAccountUuid"] = newValue }
    }
    var ownerOrganizationUuid: Value {
        get { raw["ownerOrganizationUuid"] }
        nonmutating set { raw["ownerOrganizationUuid"] = newValue }
    }
}

// What a bridge recovery check found: the plan, the transcript state, and whether to restore or to finish a partial
// append.
struct BridgeRecovery {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var plan: Value {
        get { raw["plan"] }
        nonmutating set { raw["plan"] = newValue }
    }
    var state: Value {
        get { raw["state"] }
        nonmutating set { raw["state"] = newValue }
    }
    var restoring: Value {
        get { raw["restoring"] }
        nonmutating set { raw["restoring"] = newValue }
    }
    var partial: Value {
        get { raw["partial"] }
        nonmutating set { raw["partial"] = newValue }
    }
}

// A session a move placed in the destination, as the receipt records it.
struct PlacedSession {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var id: Value {
        get { raw["id"] }
        nonmutating set { raw["id"] = newValue }
    }
    var targetId: Value {
        get { raw["targetId"] }
        nonmutating set { raw["targetId"] = newValue }
    }
    var title: Value {
        get { raw["title"] }
        nonmutating set { raw["title"] = newValue }
    }
    var strategy: Value {
        get { raw["strategy"] }
        nonmutating set { raw["strategy"] = newValue }
    }
    var record: Value {
        get { raw["record"] }
        nonmutating set { raw["record"] = newValue }
    }
    var recordSha: Value {
        get { raw["recordSha"] }
        nonmutating set { raw["recordSha"] = newValue }
    }
    var recordSemantic: Value {
        get { raw["recordSemantic"] }
        nonmutating set { raw["recordSemantic"] = newValue }
    }
    var recordSnapshot: Value {
        get { raw["recordSnapshot"] }
        nonmutating set { raw["recordSnapshot"] = newValue }
    }
    var targetRecordId: Value {
        get { raw["targetRecordId"] }
        nonmutating set { raw["targetRecordId"] = newValue }
    }
    var recordId: Value {
        get { raw["recordId"] }
        nonmutating set { raw["recordId"] = newValue }
    }
    var made: Value {
        get { raw["made"] }
        nonmutating set { raw["made"] = newValue }
    }
    var transcript: Value {
        get { raw["transcript"] }
        nonmutating set { raw["transcript"] = newValue }
    }
    var targetTranscript: Value {
        get { raw["targetTranscript"] }
        nonmutating set { raw["targetTranscript"] = newValue }
    }
    var targetDir: Value {
        get { raw["targetDir"] }
        nonmutating set { raw["targetDir"] = newValue }
    }
    var sidecars: Value {
        get { raw["sidecars"] }
        nonmutating set { raw["sidecars"] = newValue }
    }
    var taskFile: Value {
        get { raw["taskFile"] }
        nonmutating set { raw["taskFile"] = newValue }
    }
    var taskOwned: Value {
        get { raw["taskOwned"] }
        nonmutating set { raw["taskOwned"] = newValue }
    }
    var taskFamily: Value {
        get { raw["taskFamily"] }
        nonmutating set { raw["taskFamily"] = newValue }
    }
    var transcriptFingerprint: Value {
        get { raw["transcriptFingerprint"] }
        nonmutating set { raw["transcriptFingerprint"] = newValue }
    }
    var bridgeAppend: Value {
        get { raw["bridgeAppend"] }
        nonmutating set { raw["bridgeAppend"] = newValue }
    }
    var bridgeUndo: Value {
        get { raw["bridgeUndo"] }
        nonmutating set { raw["bridgeUndo"] = newValue }
    }
    var targetSemantic: Value {
        get { raw["targetSemantic"] }
        nonmutating set { raw["targetSemantic"] = newValue }
    }
    var targetSemanticVersion: Value {
        get { raw["targetSemanticVersion"] }
        nonmutating set { raw["targetSemanticVersion"] = newValue }
    }
}

// What a move checks while it rehomes sessions: the inventory rows, task registries, live workers and created records.
struct RehomeGuard {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var sources: Value {
        get { raw["sources"] }
        nonmutating set { raw["sources"] = newValue }
    }
    var targets: Value {
        get { raw["targets"] }
        nonmutating set { raw["targets"] = newValue }
    }
    var taskSessions: Value {
        get { raw["taskSessions"] }
        nonmutating set { raw["taskSessions"] = newValue }
    }
    var workers: Value {
        get { raw["workers"] }
        nonmutating set { raw["workers"] = newValue }
    }
    var check: Value {
        get { raw["check"] }
        nonmutating set { raw["check"] = newValue }
    }
    var created: Value {
        get { raw["created"] }
        nonmutating set { raw["created"] = newValue }
    }
    var inspect: Value {
        get { raw["inspect"] }
        nonmutating set { raw["inspect"] = newValue }
    }
}

// A session a move could not move, as the receipt records it in failed[].
struct FailedSession {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var id: Value {
        get { raw["id"] }
        nonmutating set { raw["id"] = newValue }
    }
    var title: Value {
        get { raw["title"] }
        nonmutating set { raw["title"] = newValue }
    }
    var error: Value {
        get { raw["error"] }
        nonmutating set { raw["error"] = newValue }
    }
    var code: Value {
        get { raw["code"] }
        nonmutating set { raw["code"] = newValue }
    }
    var cloudAccount: Value {
        get { raw["cloudAccount"] }
        nonmutating set { raw["cloudAccount"] = newValue }
    }
    var cloudOrg: Value {
        get { raw["cloudOrg"] }
        nonmutating set { raw["cloudOrg"] = newValue }
    }
    var sources: Value {
        get { raw["sources"] }
        nonmutating set { raw["sources"] = newValue }
    }
    var blockedByLocal: Value {
        get { raw["blockedByLocal"] }
        nonmutating set { raw["blockedByLocal"] = newValue }
    }
}

// One local source of a failed session: the account, org and record it came from.
struct FailureSource {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var account: Value {
        get { raw["account"] }
        nonmutating set { raw["account"] = newValue }
    }
    var org: Value {
        get { raw["org"] }
        nonmutating set { raw["org"] = newValue }
    }
    var sessionId: Value {
        get { raw["sessionId"] }
        nonmutating set { raw["sessionId"] = newValue }
    }
    var id: Value {
        get { raw["id"] }
        nonmutating set { raw["id"] = newValue }
    }
    var file: Value {
        get { raw["file"] }
        nonmutating set { raw["file"] = newValue }
    }
    var title: Value {
        get { raw["title"] }
        nonmutating set { raw["title"] = newValue }
    }
    var recordSha: Value {
        get { raw["recordSha"] }
        nonmutating set { raw["recordSha"] = newValue }
    }
    var observedRecordSha: Value {
        get { raw["observedRecordSha"] }
        nonmutating set { raw["observedRecordSha"] = newValue }
    }
    var remoteIds: Value {
        get { raw["remoteIds"] }
        nonmutating set { raw["remoteIds"] = newValue }
    }
    var error: Value {
        get { raw["error"] }
        nonmutating set { raw["error"] = newValue }
    }
    var cause: Value {
        get { raw["cause"] }
        nonmutating set { raw["cause"] = newValue }
    }
}

// A session's sidecar folder as a fingerprint or manifest records it.
struct SidecarTree {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var fingerprint: Value {
        get { raw["fingerprint"] }
        nonmutating set { raw["fingerprint"] = newValue }
    }
    var canonicalRoot: Value {
        get { raw["canonicalRoot"] }
        nonmutating set { raw["canonicalRoot"] = newValue }
    }
    var count: Value {
        get { raw["count"] }
        nonmutating set { raw["count"] = newValue }
    }
    var bytes: Value {
        get { raw["bytes"] }
        nonmutating set { raw["bytes"] = newValue }
    }
    var sha: Value {
        get { raw["sha"] }
        nonmutating set { raw["sha"] = newValue }
    }
}

// What a receipt knew about a merged target transcript.
struct KnownTarget {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var semantic: Value {
        get { raw["semantic"] }
        nonmutating set { raw["semantic"] = newValue }
    }
    var semanticVersion: Value {
        get { raw["semanticVersion"] }
        nonmutating set { raw["semanticVersion"] = newValue }
    }
    var bridge: Value {
        get { raw["bridge"] }
        nonmutating set { raw["bridge"] = newValue }
    }
}

// Files a retirement moved aside, with what each held, so recovery can check them before restoring.
struct RetirementItem {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var id: Value {
        get { raw["id"] }
        nonmutating set { raw["id"] = newValue }
    }
    var title: Value {
        get { raw["title"] }
        nonmutating set { raw["title"] = newValue }
    }
    var moved: Value {
        get { raw["moved"] }
        nonmutating set { raw["moved"] = newValue }
    }
    var hashes: Value {
        get { raw["hashes"] }
        nonmutating set { raw["hashes"] = newValue }
    }
    var trees: Value {
        get { raw["trees"] }
        nonmutating set { raw["trees"] = newValue }
    }
    var semantics: Value {
        get { raw["semantics"] }
        nonmutating set { raw["semantics"] = newValue }
    }
    var required: Value {
        get { raw["required"] }
        nonmutating set { raw["required"] = newValue }
    }
}

// A transcript as load() parses it.
struct TranscriptLoad {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var entries: Value {
        get { raw["entries"] }
        nonmutating set { raw["entries"] = newValue }
    }
    var invalid: Value {
        get { raw["invalid"] }
        nonmutating set { raw["invalid"] = newValue }
    }
}

extension MoveSource {
    var transcript: Value {
        get { raw["transcript"] }
        nonmutating set { raw["transcript"] = newValue }
    }
    var sidecar: Value {
        get { raw["sidecar"] }
        nonmutating set { raw["sidecar"] = newValue }
    }
    var contentSha: Value {
        get { raw["contentSha"] }
        nonmutating set { raw["contentSha"] = newValue }
    }
    var transcriptFingerprint: Value {
        get { raw["transcriptFingerprint"] }
        nonmutating set { raw["transcriptFingerprint"] = newValue }
    }
    var bridge: Value {
        get { raw["bridge"] }
        nonmutating set { raw["bridge"] = newValue }
    }
    var bridgeAppend: Value {
        get { raw["bridgeAppend"] }
        nonmutating set { raw["bridgeAppend"] = newValue }
    }
    var record: Value {
        get { raw["record"] }
        nonmutating set { raw["record"] = newValue }
    }
    var recordSemantic: Value {
        get { raw["recordSemantic"] }
        nonmutating set { raw["recordSemantic"] = newValue }
    }
    var recordSha: Value {
        get { raw["recordSha"] }
        nonmutating set { raw["recordSha"] = newValue }
    }
    var error: Value {
        get { raw["error"] }
        nonmutating set { raw["error"] = newValue }
    }
    var code: Value {
        get { raw["code"] }
        nonmutating set { raw["code"] = newValue }
    }
    var strategy: Value {
        get { raw["strategy"] }
        nonmutating set { raw["strategy"] = newValue }
    }
    var roots: Value {
        get { raw["roots"] }
        nonmutating set { raw["roots"] = newValue }
    }
    var title: Value { raw["title"] }
    var worker: Value { raw["worker"] }
}

extension Account {
    var taskFile: Value { raw["taskFile"] }
}

extension DesktopRecord {
    var bridgeSessionIds: Value { raw["bridgeSessionIds"] }
    var sshConfig: Value { raw["sshConfig"] }
    var sshRemoteTranscriptPath: Value { raw["sshRemoteTranscriptPath"] }
}
