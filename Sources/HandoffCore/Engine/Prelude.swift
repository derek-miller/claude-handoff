import Foundation

// Constants and glue from the top of engine.js (lines 1-47).

public let VERSION = HandoffVersion.current
let OLDER_MOVE = "An older version started this move and must finish it"
let TYPES: Set<String> = ["user", "assistant", "attachment", "system", "progress"]
let UUID_PATTERN = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
let UUID = JSRegExp("^\(UUID_PATTERN)$", "i")
let UUIDS = JSRegExp(UUID_PATTERN, "gi")
let LOCAL_RECORD = JSRegExp("^local_\(UUID_PATTERN)$", "i")
let RECEIPT_FILE = JSRegExp(#"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}\.json$"#)
let NOTE = "restart Claude Desktop to see them"
let WORKER_OWNS = "running worker owns the session"
let SCHEDULER_OWNS = "Desktop scheduler requires an approved restart"
let TASK_STATE_KEYS = ["recordedSkips", "runRetries"]
let PARENT_MISSING = "parent Desktop record is absent from the target and move"
let TASK_FAMILY_BLOCKED = "scheduled task family blocked by"
func desktopExecutable(_ file: Value = .undefined) -> Value { Value(file.asString?.hasSuffix("/Claude.app/Contents/MacOS/Claude") ?? false) }
let SHUTDOWN_WAIT = 30_000.0
let REOPEN_RESERVE = 8_000.0
let STALL_WAIT = 60_000.0
let LABEL = "io.github.derek-miller.claude-handoff"
let SEMANTIC_VERSION = 3
// The native engine keeps its own analysis cache generation so it never trusts entries the Node engine wrote.
var CACHE_VERSION = 1013
let ARTIFACT_BYTES = 512.0 * 1024 * 1024
let ARTIFACT_LINE_BYTES = 16.0 * 1024 * 1024
let RESTART_LOG_BYTES = 1024.0 * 1024
let RUNTIME_KEYS = ["slug", "promptId", "parentUuid", "version", "cwd", "gitBranch"]
let MESSAGE_RUNTIME_KEYS = ["id", "usage", "diagnostics", "stop_reason", "stop_sequence", "stop_details"]
let ACCOUNT_ERROR_KEYS = ["error", "errorAt", "priorErrorMark"]
let RECORD_RUNTIME_KEYS = ["lastActivityAt", "lastFocusedAt", "completedTurns"] + ACCOUNT_ERROR_KEYS +
    ["lastSpawnRootDetected", "promptAppendSnapshot", "reportFindingsCard", "scratchPromptRecents", "writtenBranches", "prs"]
let DURABLE_RECORD_KEYS = ["title", "isArchived", "isStarred"]
func recordSnapshot(_ record: Value = .undefined) -> Value {
    .fromEntries((["sessionId", "cliSessionId", "cwd", "originCwd"] + DURABLE_RECORD_KEYS).filter { record.hasOwn($0) }.map { ($0, record[$0]) })
}
let REMOTE_TAGS: Set<String> = ["remote-control-sdk", "remote-control-repl"]

// AsyncLocalStorage stand-in: the engine runs synchronously, so the active store is a stack.
final class LocalActivity {
    var stack: [Value] = []
    func getStore() -> Value { stack.last ?? .undefined }
    func run<T>(_ store: Value, _ work: () throws -> T) rethrows -> T {
        stack.append(store)
        defer { stack.removeLast() }
        return try work()
    }
}
let localActivity = LocalActivity()
@discardableResult
func productive() -> Value {
    let progress = localActivity.getStore()["progress"]
    if progress.isFunction { return (try? progress.call()) ?? .undefined }
    return .undefined
}

// readFile(file) → bytes; readFile(file, 'utf8') → text. Each read counts as progress for the stall watchdog.
func readFile(_ file: Value) throws -> Value {
    let data = try fs.readFile(file.description)
    productive()
    return .bytes(JSBytes(data))
}
func readFile(_ file: Value, _ encoding: Value) throws -> Value {
    let data = try fs.readFile(file.description)
    productive()
    return .string(String(decoding: data, as: UTF8.self))
}
func readFileData(_ file: String) throws -> Data {
    let data = try fs.readFile(file)
    productive()
    return data
}
func readFileText(_ file: String) throws -> String { String(decoding: try readFileData(file), as: UTF8.self) }

// const exists = (p) => stat(p).then(() => true, () => false)
func exists(_ p: Value) -> Bool { fs.exists(p.description) }
// const readJson = async (p) => JSON.parse(await readFile(p, 'utf8'))
func readJson(_ p: Value) throws -> Value { try JSON.parse(readFileText(p.description)) }

// Value-typed helper overloads used by ported code.
func sortKeysValue(_ v: Value) -> Value { sortKeys(v) }
func stableValue(_ v: Value) -> Value { .string(stable(v)) }
func shaValue(_ v: Value) -> Value { .string(sha(v)) }
func noop() -> Value { Value { _ in .undefined } }
// Use the given callback, or a no-op where JS defaulted it to `() => {}`.
func fnOr(_ f: Value, _ fallback: Value = .undefined) -> Value { f.isUndefined ? (fallback.isUndefined ? noop() : fallback) : f }
