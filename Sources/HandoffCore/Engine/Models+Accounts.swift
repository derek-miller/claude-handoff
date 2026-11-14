import Foundation

// Views over sidecar trees, the analysis cache, Desktop record folders, scheduled task families, login labels and the
// claude.ai client's requests and responses.

// treeFingerprint() also lists the tree's files with the stat identity each had when read.
extension SidecarTree {
    var files: Value { raw["files"] }
    var signatures: Value { raw["signatures"] }
}

// One file in a sidecar manifest; a symlink records where it pointed.
struct SidecarFile {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var rel: Value { raw["rel"] }
    var bytes: Value { raw["bytes"] }
    var sha: Value { raw["sha"] }
    var isSymlink: Bool { raw["type"] === "symlink" }
    var resolved: Value { raw["resolved"] }
}

extension EngineCache {
    var file: Value { raw["file"] }
    var writable: Value { raw["writable"] }
    var fingerprints: Value { raw["fingerprints"] }
}

// A cached value under the signature of the inputs it was computed from.
struct CacheEntry {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var signature: Value { raw["signature"] }
    var value: Value { raw["value"] }
}

// A Desktop record folder as folderRecords() last read it: the folder's signature and each record under its own.
struct FolderSnapshot {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var signature: Value { raw["signature"] }
    var records: Value { raw["records"] }
}

struct SnapshotRecord {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var signature: Value { raw["signature"] }
    var record: Value { raw["record"] }
}

// An account/org folder of Desktop records, with the record files in it.
struct RecordFolder: AccountKey {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var dir: Value { raw["dir"] }
    var files: Value { raw["files"] }
}

// A scheduled-tasks.json file as Desktop writes it.
struct TaskRegistryFile {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var scheduledTasks: Value { raw["scheduledTasks"] }
}

extension ScheduledTask {
    var enabled: Value { raw["enabled"] }
}

extension TaskFamily {
    var error: Value {
        get { raw["error"] }
        nonmutating set { raw["error"] = newValue }
    }
}

extension MoveSource {
    var deletedTask: Value { raw["deletedTask"] }
}

extension DesktopRecord {
    var priorCliSessionIds: Value { raw["priorCliSessionIds"] }
}

// The emails and org names known for account and org ids, and the account/org pairs seen signed in.
struct LoginLabels {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var emails: Value { raw["emails"] }
    var orgs: Value { raw["orgs"] }
    var pairs: Value { raw["pairs"] }
    // labels.json's "account/org" keys: every real login seen, and the ones removed from the list.
    var accounts: Value { raw["accounts"] }
    var removed: Value { raw["removed"] }
}

// The oauthAccount block of a Claude Code .claude.json.
struct OAuthAccount {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var accountUuid: Value { raw["accountUuid"] }
    var emailAddress: Value { raw["emailAddress"] }
    var organizationUuid: Value { raw["organizationUuid"] }
    var organizationName: Value { raw["organizationName"] }
    var organizationType: Value { raw["organizationType"] }
}

// A claude.ai account as /api/account and Desktop's query cache return it.
struct ClaudeProfile {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var uuid: Value { raw["uuid"] }
    var emailAddress: Value { raw["email_address"] }
    var memberships: Value { raw["memberships"] }
}

struct ClaudeMembership {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var organization: ClaudeOrganization { ClaudeOrganization(raw["organization"]) }
}

// A claude.ai organization as /api/organizations and account memberships return it.
struct ClaudeOrganization {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var uuid: Value { raw["uuid"] }
    var name: Value { raw["name"] }
    var capabilities: Value { raw["capabilities"] }
    var ravenType: Value { raw["raven_type"] }
}

// The running Desktop app's process id and launch time.
struct DesktopLaunch {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var started: Value { raw["started"] }
}

// What cloudClient() is handed instead of reading Desktop's own state, mostly by tests.
struct CloudIO {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var memory: Value { raw["memory"] }
    var active: Value { raw["active"] }
    var cookies: Value { raw["cookies"] }
    var userAgent: Value { raw["userAgent"] }
}

// The operation's memory budget: a check between requests and a reader that bounds each response body.
struct OperationMemory {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var check: Value { raw["check"] }
    var read: Value { raw["read"] }
}

// A fetch request to claude.ai.
struct CloudRequest {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var url: Value { raw["url"] }
    var method: Value { raw["method"] }
    var headers: Value { raw["headers"] }
    var body: Value { raw["body"] }
    var signal: Value { raw["signal"] }
    var timeout: Value {
        get { raw["timeout"] }
        nonmutating set { raw["timeout"] = newValue }
    }
}

struct CloudResponse {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var status: Value { raw["status"] }
    var ok: Value { raw["ok"] }
    var headers: Value { raw["headers"] }
    var body: Value { raw["body"] }
}

// A page of a Remote Control API response.
struct RemotePage {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var data: Value { raw["data"] }
    var resumeCursor: Value { raw["resume_cursor"] }
    var responseShape: Value { raw["response_shape"] }
}

extension RemoteEventRow {
    var sequenceNum: Value { raw["sequence_num"] }
}
