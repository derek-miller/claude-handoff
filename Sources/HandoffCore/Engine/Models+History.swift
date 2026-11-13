import Foundation

// Views over transcript lines, the history analysis built from them, and the supplemental cloud coverage indexes.

extension TranscriptEntry {
    var sessionId: Value { raw["sessionId"] }
    var parentUuid: Value { raw["parentUuid"] }
    var timestamp: Value { raw["timestamp"] }
    var agentId: Value { raw["agentId"] }
    var message: TranscriptMessage { TranscriptMessage(raw["message"]) }
    var attachment: TranscriptAttachment { TranscriptAttachment(raw["attachment"]) }
    var toolUseResult: ToolUseResult { ToolUseResult(raw["toolUseResult"]) }
    var forkedFrom: ForkPoint { ForkPoint(raw["forkedFrom"]) }
    // A user line's command identity, or a queue operation's.
    var commandUuid: Value { raw["commandUuid"] }
    var deliveryId: Value { raw["deliveryId"] }
    // A queue-operation line's operation, its reason and the content it carried.
    var operation: Value { raw["operation"] }
    var reason: Value { raw["reason"] }
    var content: Value { raw["content"] }
    // A content-replacement line's replacements, and a relocated line's new working directory.
    var replacements: Value { raw["replacements"] }
    var relocatedCwd: Value { raw["relocatedCwd"] }
    // A bridge-session line: its id under either spelling, and the account that owns it.
    var bridgeSessionId: Value { raw["bridgeSessionId"] ?? raw["bridge_session_id"] }
    var ownerAccountUuid: Value { raw["ownerAccountUuid"] }
    var ownerOrganizationUuid: Value { raw["ownerOrganizationUuid"] }
}

struct TranscriptMessage {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var role: Value { raw["role"] }
    var content: Value { raw["content"] }
}

struct TranscriptAttachment {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var type: Value { raw["type"] }
    var prompt: Value { raw["prompt"] }
    var commandUuid: Value { raw["commandUuid"] }
    var sourceUuid: Value { raw["source_uuid"] }
    var deliveryId: Value { raw["delivery_id"] }
}

struct ToolUseResult {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var stdout: Value { raw["stdout"] }
    var stderr: Value { raw["stderr"] }
    var file: Value { raw["file"] }
}

// Where a forked line came from.
struct ForkPoint {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var messageUuid: Value { raw["messageUuid"] }
    var sessionId: Value { raw["sessionId"] }
}

// A transcript line with its position, as duplicate resolution ranks copies.
struct TranscriptRow {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var entry: TranscriptEntry { TranscriptEntry(raw["entry"]) }
    var line: Value { raw["line"] }
    var detail: Value { raw["detail"] }
    var size: Value { raw["size"] }
}

extension TranscriptLoad {
    var sha: Value { raw["sha"] }
}

// A transcript's lines after normalize() drops replayed copies, and the duplicates it could not resolve.
struct NormalizedTranscript {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var entries: Value { raw["entries"] }
    var conflicts: Value { raw["conflicts"] }
}

// Each message's original uuid across forks, and the transcripts read to trace them.
struct TranscriptLineage {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var origin: Value { raw["origin"] }
    var dependencies: Value { raw["dependencies"] }
}

// What scan() records about a transcript.
struct TranscriptScan {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var ids: Value { raw["ids"] }
    var forked: Value { raw["forked"] }
}

// The shared state history analysis reads: the transcript index, the scans so far and the cache.
struct HistoryContext {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var index: Value { raw["index"] }
    var scans: Value { raw["scans"] }
    var cache: EngineCache { EngineCache(raw["cache"]) }
}

// The analysis cache: what was loaded, which entries this run used, and its hit counts.
struct EngineCache {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var data: Value { raw["data"] }
    var used: Value { raw["used"] }
    var stats: Value { raw["stats"] }
}

// A cached history: its dependency fingerprints and the encoded result, under a signature of the fingerprints.
struct CachedHistory {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var signature: Value { raw["signature"] }
    var dependencies: Value { raw["value"]["dependencies"] }
    var result: HistoryResult { HistoryResult(raw["value"]["result"]) }
}

// What history() reports about one transcript.
struct HistoryResult {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var events: Value { raw["events"] }
    var bridgeOwners: Value { raw["bridgeOwners"] }
    var contentSha: Value { raw["contentSha"] }
}

// A message reduced to what lineage comparison needs: a hash of the line and the details of its tool output.
struct LineageEvent {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var base: Value { raw["base"] }
    var detail: Value { raw["detail"] }
}

// The hashes a queued prompt's content is compared by: the whole content, its text alone, and the content when it
// also carries images.
protocol QueuedHashes {
    var raw: Value { get }
}

extension QueuedHashes {
    var hash: Value {
        get { raw["hash"] }
        nonmutating set { raw["hash"] = newValue }
    }
    var textHash: Value {
        get { raw["textHash"] }
        nonmutating set { raw["textHash"] = newValue }
    }
    var richHash: Value {
        get { raw["richHash"] }
        nonmutating set { raw["richHash"] = newValue }
    }
}

struct QueuedContent: QueuedHashes {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
}

// One user turn while conversation() merges the copies that share a command or delivery id.
struct ConversationNode: QueuedHashes {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var parent: Value {
        get { raw["parent"] }
        nonmutating set { raw["parent"] = newValue }
    }
    var bad: Value {
        get { raw["bad"] }
        nonmutating set { raw["bad"] = newValue }
    }
    var mixed: Value {
        get { raw["mixed"] }
        nonmutating set { raw["mixed"] = newValue }
    }
    var userHash: Value {
        get { raw["userHash"] }
        nonmutating set { raw["userHash"] = newValue }
    }
    var userFirst: Value {
        get { raw["userFirst"] }
        nonmutating set { raw["userFirst"] = newValue }
    }
    var consumedHash: Value {
        get { raw["consumedHash"] }
        nonmutating set { raw["consumedHash"] = newValue }
    }
    var command: Value {
        get { raw["command"] }
        nonmutating set { raw["command"] = newValue }
    }
    var delivery: Value {
        get { raw["delivery"] }
        nonmutating set { raw["delivery"] = newValue }
    }
    var first: Value {
        get { raw["first"] }
        nonmutating set { raw["first"] = newValue }
    }
}

// A Remote Control event row as claude.ai returns it.
struct RemoteEventRow {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var eventType: Value { raw["event_type"] }
    var payload: Value { raw["payload"] }
    var createdAt: Value { raw["created_at"] }
}

// A message as coverage compares it, from a remote event or a local transcript line.
struct ArtifactEvent {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var uuid: Value { raw["uuid"] }
    var type: Value { raw["type"] }
    var role: Value { raw["role"] }
    var hash: Value { raw["hash"] }
    var timestamp: Value { raw["timestamp"] }
    var agentId: Value { raw["agentId"] }
    var isSidechain: Value { raw["isSidechain"] }
    var sessionId: Value { raw["sessionId"] }
}

// A queued prompt a local transcript recorded as an attachment.
struct QueuedPrompt: QueuedHashes {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var uuid: Value { raw["uuid"] }
    var delivery: Value { raw["delivery"] }
    var sessionId: Value { raw["sessionId"] }
    var isSidechain: Value { raw["isSidechain"] }
}

// A queue operation a local transcript recorded.
struct QueueOperation: QueuedHashes {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var uuid: Value { raw["uuid"] }
    var delivery: Value { raw["delivery"] }
    var sessionId: Value { raw["sessionId"] }
    var consumed: Value { raw["consumed"] }
    var cancelled: Value { raw["cancelled"] }
    var hasContent: Value { raw["hasContent"] }
}

// What artifactIndex() reads from one transcript.
struct ArtifactIndex {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var main: Value { raw["main"] }
    var events: Value { raw["events"] }
    var queued: Value { raw["queued"] }
    var operations: Value { raw["operations"] }
    var timestamp: Value { raw["timestamp"] }
}

// The bytes coverage analysis may still read, and the indexes it has finished.
struct ArtifactBudget {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var limit: Value { raw["limit"] }
    var used: Value {
        get { raw["used"] }
        nonmutating set { raw["used"] = newValue }
    }
    var indexes: Value { raw["indexes"] }
}

// A session's transcript, its subagent transcripts, and the fingerprints that must not change during analysis.
struct ArtifactInputs {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var transcript: Value { raw["transcript"] }
    var fingerprints: Value { raw["fingerprints"] }
    var files: Value { raw["files"] }
}

// A subagent transcript and the order coverage reads it in.
struct ArtifactFile {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var file: Value { raw["file"] }
    var agent: Value { raw["agent"] }
    var modified: Value { raw["modified"] }
    var priority: Value {
        get { raw["priority"] }
        nonmutating set { raw["priority"] = newValue }
    }
}

// The local session whose artifacts coverage checks: its record, transcript, sidecar and conversation.
struct CoveredSession: RecordHolder {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var id: Value { raw["id"] }
    var transcript: Value { raw["transcript"] }
    var sidecar: SidecarTree { SidecarTree(raw["sidecar"]) }
    var conversation: Value { raw["conversation"] }
}

// The account a bridge-session line names as its owner.
struct BridgeOwner: AccountKey {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var id: Value { raw["id"] }
}

extension MoveSource {
    var state: Value { raw["state"] }
    var events: Value { raw["events"] }
    var bridgeIds: Value { raw["bridgeIds"] }
    var bridgeOwners: Value { raw["bridgeOwners"] }
}

extension SidecarTree {
    var set: Value { raw["set"] }
    var rows: Value { raw["rows"] }
}

extension DesktopRecord {
    var originCwd: Value { raw["originCwd"] }
}
