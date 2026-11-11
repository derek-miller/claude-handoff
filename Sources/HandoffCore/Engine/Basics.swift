import Darwin
import Foundation

// Help text, memory budget, small helpers, the process table, Desktop restart and the data layout.

public let HELP = """
claude-handoff   move Claude Code history between accounts

  claude-handoff             pick from → to, move, retire the source entries, print receipt
  claude-handoff --dry-run   plan only, write nothing, refuses while a move or recovery is pending
  claude-handoff undo        restore source entries and task registrations, with restart approval if needed
  claude-handoff finish      recover interrupted transfers, finish held records or active-source cloud work
  claude-handoff keep-local  cancel held work and cloud checks, keep completed moves
  claude-handoff accounts    list accounts
  claude-handoff restart     plan an explicit Desktop restart
  claude-handoff sweep       verify placed metadata and retry the active pending source
  claude-handoff tidy        set aside empty folders Desktop left for mismatched account/org pairs,
                                or with --pair <account>/<org> one account that holds no sessions
  claude-handoff menubar     install the menubar app, --snapshot <png>, --remove uninstalls

  --from <match> --to <match>   skip the picker, match on email, org name, or uuid prefix
  --cloud                       reconcile active source, queue remaining local work and known source mirrors
  --move-only                   move eligible records without restarting Desktop
  --restart-approved <token>    execute the exact restart plan previously displayed
  --json                        machine-readable output
  --version

"""

// MARK: - File-private helpers

// max and min that return NaN when any argument is NaN.
fileprivate func nanMax(_ xs: Double...) -> Double {
    if xs.contains(where: { $0.isNaN }) { return .nan }
    return xs.max() ?? -.infinity
}
fileprivate func nanMin(_ xs: Double...) -> Double {
    if xs.contains(where: { $0.isNaN }) { return .nan }
    return xs.min() ?? .infinity
}
// Rounds half up; infinities and NaN pass through.
fileprivate func roundHalfUp(_ x: Double) -> Double { x.isFinite ? (x + 0.5).rounded(.down) : x }
// The length, or undefined when v is null or undefined.
fileprivate func optLength(_ v: Value) -> Value { v.nullish ? .undefined : v["length"] }
// The lowercased string, or undefined when v is null or undefined.
fileprivate func lowerOpt(_ v: Value) -> Value { v.nullish ? .undefined : .string(v.description.lowercased()) }
fileprivate func arg(_ args: [Value], _ i: Int) -> Value { i < args.count ? args[i] : .undefined }

// Date.parse(`${procStart} UTC`): ps lstart text read as UTC.
fileprivate func parseUTC(_ s: String) -> Double {
    guard s.hasSuffix(" UTC") else { return dateParse(s) }
    var body = String(s.dropLast(4))
    while body.contains("  ") { body = body.replacingOccurrences(of: "  ", with: " ") }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    if let d = f.date(from: body.trimmingWhitespace) { return (d.timeIntervalSince1970 * 1000).rounded() }
    return dateParse(s)
}

// Resident set size of this process (task_info MACH_TASK_BASIC_INFO).
fileprivate func residentBytes() -> Double {
    var info = mach_task_basic_info()
    var size = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &size) }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) : 0
}

// Free plus inactive pages (host_statistics64).
fileprivate func availableBytes() -> Double {
    var stats = vm_statistics64()
    var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size) }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    var page: vm_size_t = 0
    host_page_size(mach_host_self(), &page)
    return Double(UInt64(stats.free_count) + UInt64(stats.inactive_count)) * Double(page)
}

// MARK: - Memory

func memoryTarget(_ total: Value = .undefined) throws -> Value { Value((toNumber(total) * 0.2).rounded(.down)) }

public func menubarHeapMiB(_ total: Value = .undefined, _ heap: Value = .undefined) throws -> Value {
    let total = total.isUndefined ? Value(process.totalmem()) : total
    let heap = heap.isUndefined ? try memoryTarget(total) : heap
    return Value(nanMax((toNumber(heap) / 1024 / 1024).rounded(.up), (toNumber(try memoryTarget(total)) * 0.65 / 1024 / 1024).rounded(.down)))
}

func memoryErrorCode(_ error: Value = .undefined) throws -> Value {
    error["code"] === "ERR_STRING_TOO_LONG" || error["name"] === "RangeError" && error["message"] === "Invalid string length" ? "CLOUD_PARSER_LIMIT" : error["code"]
}

public func memoryBudget(_ io: Value = .undefined) throws -> Value {
    let limitValue = try memoryTarget(io.total ?? Value(process.totalmem()))
    let limit = toNumber(limitValue)
    // There is no separate heap limit: it equals the memory target.
    let heapValue = io.heap ?? limitValue
    let heap = toNumber(heapValue)
    let usage: () throws -> Value = io.usage.isUndefined
        ? { let rss = residentBytes(); return ["rss": Value(rss), "heapUsed": Value(rss)] }
        : { try io.usage.call() }
    let available: () throws -> Double = io.available.isUndefined ? { availableBytes() } : { toNumber(try io.available.call()) }
    let platform = io.platform ?? "darwin"
    let now: () throws -> Double = io.now.isUndefined ? { dateNow() } : { toNumber(try io.now.call()) }
    let probe: () throws -> Value = io.pressure.isUndefined ? {
        // `sysctl -n kern.memorystatus_vm_pressure_level`, read in-process.
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? Value(Int(level)) : .null
    } : { try io.pressure.call() }
    var sampledAt = -Double.infinity
    var level: Value = .null
    func pressure() throws -> Value {
        if platform !== "darwin" { return .null }
        let at = try now()
        if at < sampledAt || at - sampledAt >= 1000 {
            sampledAt = at
            do {
                let value = try probe()
                level = [Value(1), Value(2), Value(4)].contains(value) ? value : .null
            } catch { level = .null }
            sampledAt = try now()
        }
        return level
    }
    var reserved = 0.0
    func remaining() throws -> Double {
        let used = try usage()
        let rss = toNumber(used.rss), heapUsed = toNumber(used.heapUsed)
        return nanMax(0, nanMin(limit - rss, heap - heapUsed) * 0.8 - reserved)
    }
    func check(_ bytes: Double = 0) throws {
        let level = try pressure()
        if try level === 4 || level.isNull && bytes >= nanMax(0, available() * 0.8 - reserved) {
            throw makeError("Waiting for memory to verify history", code: "CLOUD_MEMORY_PRESSURE")
        }
        let room = try remaining()
        if bytes > room || room == 0 { throw makeError("This operation exceeded its memory budget", code: "CLOUD_MEMORY_BUDGET") }
    }
    let checkValue = Value { args in
        let bytes = arg(args, 0)
        try check(bytes.isUndefined ? 0 : toNumber(bytes))
        return .undefined
    }
    let parallel = Value { _ in
        let used = try usage()
        let rss = toNumber(used.rss), heapUsed = toNumber(used.heapUsed)
        let level = try pressure(), fraction = nanMax((rss + reserved) / limit, (heapUsed + reserved) / heap)
        if level === 2 || level === 4 || platform === "darwin" && level.isNull { return 1 }
        return try fraction < 0.5 && (level === 1 || available() > nanMin(512 * 1024 * 1024, limit / 4)) ? 8 : fraction < 0.75 ? 2 : 1
    }
    let read = Value { args in
        let response = arg(args, 0)
        var collected = Data()
        var bytes = 0.0
        defer { reserved -= bytes * 4 }
        do {
            try check()
            let body = response["body"]
            if body.truthy {
                // The native client fetches the whole body; cloudClient passes it as an array of chunks.
                var chunks: [Data] = []
                for part in body.isArray ? body.elements : [body] {
                    if let data = part.asData { if !data.isEmpty { chunks.append(data) } } else if let text = part.asString { chunks.append(Data(text.utf8)) }
                }
                for chunk in chunks {
                    try check(Double(chunk.count) * 4)
                    reserved += Double(chunk.count) * 4
                    bytes += Double(chunk.count)
                    collected.append(chunk)
                }
            }
            let text = String(decoding: collected, as: UTF8.self)
            let value = text.isEmpty ? Value.null : try JSON.parse(text)
            try check()
            return value
        } catch {
            let error = errorObject(error)
            if try memoryErrorCode(error) === "CLOUD_PARSER_LIMIT" { error["code"] = "CLOUD_PARSER_LIMIT" }
            throw EngineError(error)
        }
    }
    return ["limit": limitValue, "heap": heapValue, "signature": Value("\(limitValue):\(heapValue):native"), "check": checkValue,
            "parallel": parallel, "read": read]
}

var sharedMemory: Value = .undefined
func operationMemory() throws -> Value {
    if sharedMemory.nullish {
        sharedMemory = try memoryBudget()
    }
    return sharedMemory
}
func selectedMemory(_ options: Value = .undefined) throws -> Value {
    if !options.memory.nullish { return options.memory }
    if !options.cloud.memory.nullish { return options.cloud.memory }
    return try operationMemory()
}
func memorySignature(_ memory: Value = .undefined) throws -> Value {
    if !memory.signature.nullish { return memory.signature }
    let limit = memory.limit.nullish ? try operationMemory().limit : memory.limit
    let heap = memory.heap.nullish ? try operationMemory().heap : memory.heap
    return Value("\(limit):\(heap):native")
}
var artifactEngineHash: Value = .undefined
// Identifies the engine build in artifact retry signatures and cloud attempt records, so a new version retries
// what an older one gave up on.
func artifactEngine() throws -> Value {
    if artifactEngineHash.nullish { artifactEngineHash = .string(sha("native-\(VERSION)")) }
    return artifactEngineHash
}

// MARK: - One-line helpers

func accountRef(_ arg0: Value = .undefined) throws -> Value {
    if arg0.nullish { throw EngineError.type("Cannot destructure '\(arg0)' as it is \(arg0).") }
    return ["account": arg0.account, "org": arg0.org, "label": arg0.label]
}
public func sameAccount(_ a: Value = .undefined, _ b: Value = .undefined) throws -> Value {
    Value(a.truthy && b.truthy && a.account === b.account && a.org === b.org)
}
func sameLogin(_ a: Value = .undefined, _ b: Value = .undefined) throws -> Value {
    Value(a.account.truthy && a.account === b.account && (b.state.nullish || b.state === "known"))
}
func localCloudPending(_ account: Value = .undefined, _ retiring: Value = .undefined) throws -> Value {
    let retiring = retiring.isUndefined ? Value.newSet() : retiring
    return Value(account.truthy && (account.unreadable["length"].truthy ||
        account.sessions.elements.contains { session in !session.archived.truthy && !retiring.has(session.file) }))
}
func accountLabel(_ row: Value = .undefined) throws -> Value {
    row.accountLabel ?? row.label ?? Value("\(short(row.account)) · \(short(row.org))")
}
func sourceProgress(_ source: Value = .undefined) throws -> Value {
    source.truthy ? ["sourceId": Value("\(source.account)/\(source.org)"), "sourceLabel": try accountLabel(source)] : Value.newObject()
}
public func retryableCode(_ code: Value = .undefined) throws -> Value {
    Value((["RESTART_PLAN_CHANGED", "RESTART_APPROVAL_CHANGED", "QUIT_UNCONFIRMED", "REOPEN_FAILED"] as [Value]).contains(code))
}
func loginLabel(_ row: Value = .undefined) throws -> Value {
    Value(try accountLabel(row).description.components(separatedBy: " · ")[0])
}
func openCloudChecks(_ receipt: Value = .undefined) throws -> Value {
    (receipt.cloudChecks ?? []).elements.filter { check in !(["complete", "cancelled", "blocked-local"] as [Value]).contains(check.status) }.value
}
func actionableCloudFailure(_ receipt: Value = .undefined, _ row: Value = .undefined) throws -> Value {
    if !row.cloudAccount.truthy { return row.cloudAccount }
    if try keptCopy(receipt).call(row).truthy { return false }
    if optLength(row.blockedByLocal).truthy { return false }
    return Value(try receiptCloudCheck(receipt, ["account": row.cloudAccount, "org": row.cloudOrg])["status"] !== "cancelled")
}
func cloudCheckLabels(_ receipt: Value = .undefined) throws -> Value {
    unique(try openCloudChecks(receipt).elements.map { $0.label }).value
}
public func waitingSessions(_ receipt: Value = .undefined) throws -> Value {
    var rows: [Value] = (receipt.held ?? []).elements.map { row in
        ["id": row.id, "title": row.title, "localId": row.id, "recordId": row.recordId]
    }
    rows += try openCloudChecks(receipt).elements.flatMap { check in (check.waiting ?? []).elements }
    let map = ValueMap()
    for row in rows {
        let key = row.localId.nullish ? (try remoteId(row.id) ?? row.id) : row.localId
        map.set(key, row)
    }
    return map.values.value
}
public func heldCount(_ held: Value = .undefined) throws -> Value {
    let held = held.isUndefined ? [] : held
    let set = ValueSet()
    for row in held.elements {
        if row.sources.nullish { set.add(row.id); continue }
        for source in row.sources.elements { set.add(source.file ?? Value("\(source.account)/\(source.org)/\(source.id)")) }
    }
    return Value(set.size)
}
public func cloudCancelToken(_ file: Value = .undefined, _ check: Value = .undefined) throws -> Value {
    let sessionIds: Value = check.sessionIds.truthy ? defaultSorted(unique(check.sessionIds.elements)).value : .null
    return Value(sha(stable(["file": file, "account": check.account, "org": check.org, "sessionIds": sessionIds])))
}

public func pendingPresentation(_ receipt: Value = .undefined, _ source: Value = .undefined, _ account: Value = .undefined, _ mode: Value = .undefined, _ table: Value = .undefined, _ scheduler: Value = .undefined, _ timeouts: Value = .undefined, _ identity: Value = .undefined) throws -> Value {
    let table = table.isUndefined ? [] : table
    let scheduler = scheduler.isUndefined ? false : scheduler
    let timeouts = timeouts.isUndefined ? Value.newMap() : timeouts
    let identity = identity.isUndefined ? .null : identity
    let empty: Value = ["pendingState": .null, "pendingAction": .null, "pendingCount": .null, "pendingAutomatic": false]
    if !source.truthy { return empty }
    if mode === "partial" {
        let notMoved = try receiptSummary(receipt).notMoved.elements.filter { row in try sameAccount(row, source).truthy }
        return Value.spread(empty, ["pendingState": "partial", "pendingAction": "blocked", "pendingCount": Value(notMoved.count)])
    }
    if mode === "recovery" { return Value.spread(empty, ["pendingState": "interrupted", "pendingAction": "finish"]) }
    if mode === "undo" {
        let undoing = optLength(receipt.remoteUndoing)
        let partial = toNumber(undoing ?? 0) < toNumber(optLength(receipt.remote) ?? 0)
        return Value.spread(empty, ["pendingState": undoing.truthy ? "undo-login" : "undo",
                                    "pendingAction": undoing.truthy && !account.signedIn.truthy ? "sign-in" : "finish",
                                    "pendingPartial": Value(partial)])
    }
    if mode === "local" {
        let held = try (receipt.held ?? []).elements.filter { row in try row.sources.elements.contains { member in try sameAccount(member, source).truthy } }
        let owned = try table.elements.filter { worker in
            try worker.worker.truthy && worker.pid !== worker.desktopPid &&
                held.contains { row in try ownsWorker(Value.newSet(worker.ids.elements), row.id, row.recordId).truthy }
        }
        let external = owned.contains { worker in !worker.desktopPid.truthy }
        let automatic = held.count > 0 && held.allSatisfy { row in row.release === "worker" } && !scheduler.truthy && !external
        let open = try held.filter { row in try owned.contains { worker in try ownsWorker(Value.newSet(worker.ids.elements), row.id, row.recordId).truthy } }
        let seconds = ValueSet(open.map { row in timeouts.get(lowerOpt(row.recordId)) })
        let openIds = ValueSet(open.map { $0.id })
        let pendingState: Value = external ? "external" : automatic && owned.count > 0 ? "open" : "held"
        let pendingCount: Value = held.count > 0 ? try heldCount(held.value) : .null
        let pendingIdleSeconds: Value = automatic && open.count == held.count && seconds.size == 1 ? (seconds.values[0] ?? .null) : .null
        let pendingAction: Value = external ? "wait" : owned.count > 0 || scheduler.truthy ? "restart" : "finish"
        return Value.spread(empty, ["pendingState": pendingState, "pendingCount": pendingCount, "pendingAutomatic": Value(automatic),
                                    "pendingOpenCount": Value(openIds.size), "pendingIdleSeconds": pendingIdleSeconds, "pendingAction": pendingAction])
    }
    let failures = source.failures ?? [], waiting = source.waiting ?? []
    let pending = failures.elements + waiting.elements
    let ids = unique(pending.map { $0.id }.filter { $0.truthy })
    let archived = ValueSet(try (receipt.remote ?? []).elements.filter { row in try sameAccount(row, source).truthy }.map { row in try remoteId(row.id) })
    let countValue: Value
    if failures.elements.contains(where: { !$0.id.truthy }) {
        countValue = .null
    } else if !ids.isEmpty {
        countValue = Value(ids.count)
    } else {
        countValue = source.sessionIds.truthy ? Value(try source.sessionIds.elements.filter { id in !archived.has(try remoteId(id)) }.count) : .null
    }
    let blocked = try historyLimited(source)
    let state: Value
    if blocked.truthy {
        state = failures.elements.contains { $0.code === "CLOUD_BUDGET_LIMIT" } ? "budget-limit" : failures.elements.contains { $0.code === "CLOUD_PARSER_LIMIT" } ? "parser-limit" : "limit"
    } else if failures.length > 0 && failures.elements.allSatisfy({ $0.code === "CLOUD_AUTH_PENDING" }) {
        state = "login"
    } else if failures.length > 0 && failures.elements.allSatisfy({ $0.code === "CLOUD_MEMORY_PRESSURE" }) {
        state = "memory"
    } else {
        state = failures.length > 0 || waiting.elements.contains { $0.code === "CLOUD_MEMORY_DEFERRED" } ? "waiting" : waiting.length > 0 ? "cloud-open" : "cleanup"
    }
    let action: Value
    if blocked.truthy { action = "blocked" } else if !account.signedIn.truthy { action = "sign-in" } else if try waiting.length > 0 && canRestartWaiting(["cloudChecks": [source]], table).truthy { action = "restart" } else { action = "wait" }
    let retryAt: Value = account.signedIn.truthy && !blocked.truthy && state !== "cloud-open" ? try cloudRetryAt(receipt, source, identity) : .null
    return ["pendingState": state, "pendingAction": action, "pendingCount": countValue, "pendingAutomatic": Value(!blocked.truthy), "pendingRetryAt": retryAt]
}

public func needsRecovery(_ receipt: Value = .undefined) throws -> Value {
    Value(receipt.pending.truthy || receipt.retiring.truthy || receipt.finalizing.truthy || receipt.undoing.truthy || receipt.remotePending.truthy || optLength(receipt.remoteUndoing).truthy)
}

func recoveryFamilies(_ receipt: Value = .undefined) throws -> Value {
    let transfers = receipt.taskTransfers ?? [], checkpoint = receipt.appendCheckpoint
    if !checkpoint.truthy { return transfers }
    if ["sessions", "superseded"].contains(where: { key in
        !isSafeInteger(checkpoint[key]) || toNumber(checkpoint[key]) < 0 || toNumber(checkpoint[key]) > toNumber(optLength(receipt[key]) ?? 0)
    }) || !checkpoint.held.isArray { throw EngineError("invalid append checkpoint") }
    if receipt.undoing.truthy { return transfers }
    let offset = checkpoint.taskTransfers
    if !isSafeInteger(offset) || toNumber(offset) < 0 || toNumber(offset) > Double(transfers.length) { throw EngineError("invalid append checkpoint") }
    let offsetInt = offset.asInt!
    let committed: [Value] = sliceArray((receipt.sessions ?? []).elements, 0, checkpoint.sessions.asInt!)
        .filter { $0.taskFamily.truthy }.map { row in [row.taskFamily, row.targetRecordId] }
    let expected: [Value] = sliceArray(transfers.elements, 0, offsetInt).flatMap { family in family.recordIds.elements.map { id in [family.key, id] as Value } }
    let retired = ValueSet(sliceArray((receipt.superseded ?? []).elements, 0, checkpoint.superseded.asInt!).filter { $0.source.truthy }
        .flatMap { row in row.moved.elements.map { $0[0] } })
    if stable(defaultSorted(committed).value) != stable(defaultSorted(expected).value) ||
        transfers.elements.enumerated().contains(where: { index, family in family.files.elements.contains { file in retired.has(file) != (index < offsetInt) } }) {
        throw EngineError("invalid append checkpoint")
    }
    return sliceArray(transfers.elements, offsetInt).value
}

func inspector(_ paths: Value = .undefined, _ options: Value = .undefined) throws -> Value {
    options.inspect ?? options.io.inspect ?? Value { _ in try options.processes ?? processTable(paths.claudeApp) }
}
public func keptCopy(_ receipt: Value = .undefined) throws -> Value {
    let linked = ValueSet(try (receipt.failed ?? []).elements.filter { !$0.cloudAccount.truthy }
        .flatMap { row in (row.sources ?? []).elements.flatMap { source in (source.remoteIds ?? []).elements } })
    return Value { args in
        let row = arg(args, 0)
        return Value(try row.code === "CLOUD_UNPROVEN" && !optLength(row.blockedByLocal).truthy && !linked.has(remoteId(row.id)))
    }
}
func receiptOkay(_ receipt: Value = .undefined) throws -> Value {
    let kept = try keptCopy(receipt)
    return Value(try receipt.verification.ok !== false && (receipt.failed ?? []).elements.allSatisfy { try kept.call($0).truthy })
}
public func finishOkay(_ receipt: Value = .undefined) throws -> Value {
    Value(try receipt.verification.ok !== false && !optLength(receipt.verification.problems).truthy &&
        !(receipt.failed ?? []).elements.contains { row in try actionableCloudFailure(receipt, row).truthy } &&
        !(receipt.cloudError.truthy && openCloudChecks(receipt).length > 0))
}
public func problemText(_ problem: Value = .undefined) throws -> Value {
    Value("\(problem.title ?? problem.id) | \(problem.check) verification failed")
}
func cancelCloudChecks(_ receipt: Value = .undefined, _ checks: Value = .undefined) throws -> Value {
    let checks = checks.isUndefined ? try openCloudChecks(receipt) : checks
    for check in checks.elements {
        check.status = try (receipt.failed ?? []).elements.contains { row in try cloudTagged(row, check).truthy && optLength(row.blockedByLocal).truthy } ? "blocked-local" : "cancelled"
        if check.status === "blocked-local" && optLength(check.waiting).truthy { check.cancelledWaiting = check.waiting; check.removeKey("waiting") }
        check.cancelledAt = Value(isoNow())
    }
    return .undefined
}
func milliseconds(_ value: Value = .undefined) throws -> Value {
    let raw = value.isNumber ? toNumber(value) : dateParse((value ?? "").description)
    return Value(raw.isFinite ? (raw < 1e12 ? raw * 1000 : raw) : -1)
}
func typed(_ e: Value = .undefined) throws -> Value {
    if !e.truthy { return e }
    return Value(e.typeOf == "object" && TYPES.contains(e.type.asString ?? "\u{0}") && e.uuid.isString && !e.isSidechain.truthy)
}
func message(_ e: Value = .undefined) throws -> Value {
    and(try typed(e), Value(e.type !== "progress"))
}

// MARK: - Processes

public func parseProcesses(_ processes: Value = .undefined, _ commands: Value = .undefined, _ app: Value = .undefined, _ registrations: Value = .undefined) throws -> Value {
    let app = (app.isUndefined ? "/Applications/Claude.app" : app).description
    let registrations = registrations.isUndefined ? [] : registrations
    let pattern = re(#"^\s*(\d+)\s+(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+\d+:\d+:\d+\s+\d{4})\s+(.+)$"#)
    var identities: [String: [Value]] = [:]
    for line in commands.description.components(separatedBy: "\n") where !line.trimmingWhitespace.isEmpty {
        guard let match = pattern.match(line) else { throw EngineError("cannot parse worker command identity") }
        identities["\(match[1]!)/\(match[3]!)"] = UUIDS.matches(match[4]!).map { .string($0.lowercased()) }
    }
    var rows: [Value] = []
    for line in processes.description.components(separatedBy: "\n") where !line.trimmingWhitespace.isEmpty {
        guard let match = pattern.match(line) else { throw EngineError("cannot parse worker process identity") }
        let executable = match[4]!.trimmingWhitespace
        let worker = path.basename(executable).lowercased() == "claude" || executable.hasSuffix("/Claude.app/Contents/Helpers/disclaimer") ||
            executable == path.join(app, "Contents/Helpers/disclaimer")
        rows.append(["pid": Value(toNumber(.string(match[1]!))), "ppid": Value(toNumber(.string(match[2]!))), "started": Value(match[3]!),
                     "executable": Value(executable), "worker": Value(worker), "ids": (identities["\(match[1]!)/\(match[3]!)"] ?? []).value])
    }
    for row in rows where !registrations.elements.isEmpty {
        let started = dateParse(row.started.description)
        let registered = registrations.elements.first { item in
            item.pid === row.pid && item.pidDomain === "darwin" && started.isFinite &&
                parseUTC("\(item.procStart) UTC") == started && UUID.test((item.sessionId ?? "").description)
        }
        if let registered, row.worker.truthy {
            row.ids = unique(row.ids.elements + [.string(registered.sessionId.description.lowercased())]).value
            row.cwd = registered.cwd.isString ? registered.cwd : .null
            row.sessionName = registered.name.isString ? registered.name : .null
        }
    }
    let byPid = ValueMap(rows.map { ($0.pid, $0) })
    for row in rows {
        let visited = ValueSet()
        var parent = row
        row.desktopPid = .null
        while parent.truthy && !visited.has(parent.pid) {
            visited.add(parent.pid)
            if desktopExecutable(parent.executable).truthy || parent.executable === Value(path.join(app, "Contents/MacOS/Claude")) { row.desktopPid = parent.pid; break }
            parent = byPid.get(parent.ppid)
        }
    }
    return rows.value
}

public func processTable(_ app: Value = .undefined) throws -> Value {
    var env = process.env()
    env["LC_ALL"] = "C"
    let options = SpawnOptions(timeout: 2000, env: env, maxBuffer: 16 * 1024 * 1024)
    let processes = childProcess.spawnSync("/bin/ps", ["-axo", "pid=,ppid=,lstart=,comm="], options)
    let commands = childProcess.spawnSync("/bin/ps", ["-axo", "pid=,ppid=,lstart=,command="], options)
    if [processes, commands].contains(where: { $0.error != nil || $0.status != 0 }) { throw EngineError("cannot inspect running workers") }
    let directory = path.join(process.homedir(), ".claude/sessions")
    var registrations: [Value] = []
    do {
        registrations = try fs.names(directory).filter { re(#"^\d+\.json$"#).test($0) }.flatMap { name -> [Value] in
            do {
                let row = try JSON.parse(fs.readText(path.join(directory, name)))
                return row.pid === Value(toNumber(.string(sliceString(name, 0, -5)))) ? [row] : []
            } catch { return [] }
        }
    } catch {}
    return try parseProcesses(Value(processes.stdout), Value(commands.stdout), app, registrations.value)
}
func workers(_ rows: Value = .undefined) throws -> Value {
    let rows = rows.isUndefined ? try processTable() : rows
    let set = Value.newSet(rows.elements.filter { $0.worker.truthy && $0.pid !== $0.desktopPid }.flatMap { $0.ids.elements })
    set["rows"] = rows
    return set
}
func ownsWorker(_ live: Value = .undefined, _ id: Value = .undefined, _ recordId: Value = .undefined) throws -> Value {
    let record: Value = recordId.nullish ? .undefined : .string(re("^local_").replace(recordId.description, "").lowercased())
    return Value(live.has(lowerOpt(id)) || live.has(record))
}
func processIdentity(_ row: Value = .undefined) throws -> Value { Value("\(row.pid)/\(row.started)") }
func restartFingerprint(_ desktop: Value = .undefined, _ rows: Value = .undefined) throws -> Value {
    let workers: [Value] = rows.elements.filter { $0.worker.truthy && $0.desktopPid === desktop.pid && $0.pid !== desktop.pid }
        .map { ["pid": $0.pid, "started": $0.started, "ids": $0.ids] }
    let sorted = stableSorted(workers) { a, b in toNumber(a.pid) - toNumber(b.pid) }
    return Value(sha(stable(["desktop": ["pid": desktop.pid, "started": desktop.started], "workers": sorted.value])))
}
func processOwns(_ worker: Value = .undefined, _ row: Value = .undefined) throws -> Value {
    let record = try desktopRecordOf(row)
    return try ownsWorker(Value.newSet(worker.ids.elements), row.id, record.sessionId)
}

func workerGroups(_ table: Value = .undefined) throws -> Value {
    let byPid = ValueMap(table.elements.map { ($0.pid, $0) }), groups = ValueMap()
    for worker in table.elements.filter({ $0.worker.truthy && $0.desktopPid.truthy && $0.pid !== $0.desktopPid }) {
        var root = worker, parent = byPid.get(worker.ppid)
        let seen = ValueSet([worker.pid])
        while parent.truthy && parent.pid !== worker.desktopPid && !seen.has(parent.pid) {
            seen.add(parent.pid)
            if parent.worker.truthy { root = parent }
            parent = byPid.get(parent.ppid)
        }
        let key = try processIdentity(root)
        let group = groups.get(key) ?? Value.spread(root, ["ids": [], "workers": []])
        group.ids = unique(group.ids.elements + worker.ids.elements).value
        group.workers.push(worker)
        groups.set(key, group)
    }
    return groups.values.value
}

func canRestartWaiting(_ receipt: Value = .undefined, _ table: Value = .undefined) throws -> Value {
    Value(try waitingSessions(receipt).elements.contains { row in
        let owns = { (worker: Value) throws -> Bool in try ownsWorker(Value.newSet(worker.ids.elements), row.localId, row.recordId).truthy }
        return try workerGroups(table).elements.contains(where: owns) && !table.elements.contains { worker in try worker.worker.truthy && !worker.desktopPid.truthy && owns(worker) }
    })
}

public func restartPlan(_ inv: Value = .undefined, _ paths: Value = .undefined, _ table: Value = .undefined) throws -> Value {
    let table = table.isUndefined ? try processTable(paths.claudeApp) : table
    let apps = table.elements.filter { row in desktopExecutable(row.executable).truthy || row.executable === Value(path.join(paths.claudeApp.description, "Contents/MacOS/Claude")) }
    if apps.count != 1 { return .null }
    let desktop = apps[0]
    let all = try accounts(paths)
    let owned = try workerGroups(table).elements.filter { $0.desktopPid === desktop.pid }
    func matching(_ row: Value) throws -> [Value] {
        try table.elements.filter { worker in
            try worker.worker.truthy && worker.pid !== desktop.pid && (row.members ?? [row]).elements.contains { member in try processOwns(worker, member).truthy }
        }
    }
    func stoppable(_ rows: [Value]) -> Bool { rows.count > 0 && rows.allSatisfy { $0.desktopPid === desktop.pid } }
    func release(_ row: Value) throws -> Value {
        let worker: Value = try stoppable(matching(row)) ? false : row.worker
        var extra: [(String, Value)] = [("schedulerBusy", false), ("worker", worker)]
        if row.members.truthy {
            let members: [Value] = try row.members.elements.map { member in
                let memberWorker: Value = try stoppable(matching(member)) ? false : member.worker
                return Value.spread(member, ["worker": memberWorker])
            }
            extra.append(("members", members.value))
        }
        return Value.spread(row, Value(extra))
    }
    let target: Value = inv.truthy ? (try all.elements.first { account in try sameAccount(account, inv.toAccount).truthy } ?? .undefined) : inv
    let released: [Value] = target.truthy ? try localPlan(try (inv.move.elements + inv.blocked.elements).map(release).value, target).move.elements : []
    var candidates: [(row: Value, source: Value)] = []
    if inv.truthy {
        candidates += released.filter { row in inv.blocked.elements.contains { source in source.file === row.file } }.map { (row: $0, source: $0) }
        for source in inv.there.elements {
            let target = inv.targets.elements.first { row in row.id === source.cloudTargetId }
            if let target, !(try retirementOwnership(inv, release(source), ["history": target]).truthy) {
                for row in (source.members ?? [source]).elements + [target] where try row.worker.truthy && !rehomeOwnership(release(row)).truthy {
                    candidates.append((row: row, source: source))
                }
            }
        }
        for source in inv.move.elements {
            for row in inv.targets.elements where try row.worker.truthy && included(row, source).truthy && !ownership(release(row)).truthy {
                candidates.append((row: row, source: source))
            }
        }
    }
    let held: Value = []
    func add(_ row: Value, _ source: Value, _ matches: [Value]) throws -> Bool {
        let record = try desktopRecordOf(row), file = try desktopFileOf(row)
        if held.elements.contains(where: { item in item.record === file && item.sources.elements.contains { member in member.file === source.file } }) { return false }
        let release: Value = or(or(or(source.taskFamily, source.taskOwned), record.scheduledTaskId), record.notifySessionId).truthy ? "scheduler" : matches.count > 0 ? "worker" : "unknown"
        let sources: [Value] = (source.members ?? [source]).elements.map { item in ["id": item.id, "file": item.file, "account": item.account.account, "org": item.account.org] }
        let workerRows: [Value] = matches.map { ["pid": $0.pid, "started": $0.started, "desktopPid": $0.desktopPid] }
        held.push(["id": row.id, "record": file, "recordId": record.sessionId, "title": or(or(record.title, row.title), "Untitled"),
                   "account": row.account.account, "org": row.account.org, "cwd": record.cwd,
                   "release": release, "sources": sources.value, "workers": workerRows.value])
        return true
    }
    for (row, source) in candidates {
        let matches = try matching(row)
        if stoppable(matches) || inv.blocked.elements.contains(where: { item in item.file === source.file && item.schedulerBusy.truthy }) && !matches.contains(where: { $0.desktopPid !== desktop.pid }) {
            _ = try add(row, source, matches)
        }
    }
    var added = true
    while added && inv.truthy {
        added = false
        for source in released + inv.there.elements {
            let related = try held.elements.first { item in
                try item.sources.elements.contains { member in
                    let current = inv.sources.elements.first { row in row.file === member.file } ?? .undefined
                    return try current.truthy && (source.members ?? [source]).elements.contains { row in
                        try sameAccount(row.account, current.account).truthy &&
                            (row.taskFamily.truthy && row.taskFamily === current.taskFamily || row.record.forkedFromSessionId === current.record.sessionId ||
                                current.record.forkedFromSessionId === row.record.sessionId)
                    }
                }
            }
            if let related { added = try add(source, source, related.workers.elements) || added }
        }
    }
    if inv.truthy && held.length == 0 { return .null }
    let known: [Value] = all.elements.flatMap { account in account.sessions.elements.map { session in Value.spread(session, ["account": account]) } }
    let current = try signedIn(paths, table)
    let affected: [Value] = try owned.map { worker in
        var matches = try known.filter { row in try processOwns(worker, row).truthy }
        let direct = matches.filter { row in
            worker.ids.includes(row.record.sessionId.nullish ? .undefined : .string(re("^local_").replace(row.record.sessionId.description, "")))
        }
        if !direct.isEmpty { matches = direct }
        let scoped = try matches.filter { row in try sameAccount(row.account, current).truthy }
        if !scoped.isEmpty { matches = scoped }
        let match: Value = matches.count == 1 || ValueSet(matches.map { $0.title }).size == 1 ? matches[0] : .null
        let named = worker.workers.elements.first { $0.sessionName.truthy } ?? .undefined
        let withCwd = worker.workers.elements.first { $0.cwd.truthy } ?? .undefined
        let fields: [(String, Value)] = [
            ("pid", worker.pid), ("started", worker.started), ("desktopPid", desktop.pid),
            ("id", match.id ?? .null), ("recordId", match.record.sessionId ?? .null),
            ("title", or(or(match.title, named.sessionName), "Another open Claude session")),
            ("cwd", match.cwd ?? withCwd.cwd ?? .null),
            ("pids", worker.workers.elements.map { $0.pid }.value),
        ]
        return Value(fields)
    }
    let selected = ValueSet(try held.elements.flatMap { row in try row.workers.elements.map(processIdentity) })
    let members: [Value] = table.elements.filter { $0.desktopPid === desktop.pid }.map { ["pid": $0.pid, "started": $0.started] }
    let interrupts = try affected.enumerated().filter { index, _ in
        !(try owned[index].workers.elements.contains { worker in selected.has(try processIdentity(worker)) })
    }.map { $0.element }
    let result: [(String, Value)] = [
        ("app", Value(path.resolve(desktop.executable.description, "../../.."))),
        ("desktop", ["pid": desktop.pid, "started": desktop.started]),
        ("members", members.value), ("held", held), ("affected", affected.value),
        ("interrupts", interrupts.value), ("fingerprint", try restartFingerprint(desktop, table)),
    ]
    return Value(result)
}

func waitFor(_ predicate: Value = .undefined, _ deadline: Value = .undefined, _ now: Value = .undefined, _ wait: Value = .undefined) throws -> Value {
    let now = now.isUndefined ? Value { _ in Value(process.monotonic()) } : now
    let wait = wait.isUndefined ? Value { args in process.sleep(toNumber(arg(args, 0))); return .undefined } : wait
    let deadline = toNumber(deadline)
    repeat {
        if try predicate.call().truthy { return true }
        if toNumber(try now.call()) >= deadline { return false }
        try wait.call(Value(nanMin(250, deadline - toNumber(try now.call()))))
    } while true
}
func appProcess(_ paths: Value = .undefined, _ table: Value = .undefined) throws -> Value {
    let table = table.isUndefined ? try processTable(paths.claudeApp) : table
    let executable = Value(path.join(paths.claudeApp.description, "Contents/MacOS/Claude"))
    return table.elements.first { $0.executable === executable } ?? .undefined
}
func command(_ file: Value = .undefined, _ args: Value = .undefined, _ timeout: Value = .undefined) throws -> Value {
    let result = childProcess.command(file.description, args.elements.map { $0.description }, toNumber(timeout))
    return ["status": result.status.map { Value(Int($0)) } ?? .null, "timedOut": Value(result.timedOut)]
}

func restartReceiptId(_ paths: Value = .undefined, _ file: Value = .undefined) throws -> Value {
    guard let file = file.asString else { return .null }
    return path.dirname(file) == paths.state.asString && RECEIPT_FILE.test(path.basename(file)) ? Value(path.basename(file)) : .null
}

func appendRestartEvent(_ paths: Value = .undefined, _ event: Value = .undefined) throws -> Value {
    do {
        let file = path.join(paths.state.description, "restart-events.jsonl")
        var detail: Value = .null
        do { detail = try fs.lstat(file) } catch {
            let error = errorObject(error)
            if error.code !== "ENOENT" { throw EngineError(error) }
        }
        if try detail.truthy && !detail["isFile"].call().truthy { return .undefined }
        let text = jsonText(event, 0)
        let length = Double(text.utf8.count)
        if length > 4096 { return .undefined }
        if detail.truthy && toNumber(detail["size"]) + length > RESTART_LOG_BYTES {
            try fs.rm("\(file).1", force: true)
            try fs.rename(file, "\(file).1")
        }
        let handle = try fs.open(file, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        defer { try? handle.close() }
        try handle.chmod(0o600)
        try handle.writeFile(text)
        try handle.close()
    } catch {}
    return .undefined
}

func foldRestartHistory(_ paths: Value = .undefined, _ file: Value = .undefined, _ receipt: Value = .undefined) throws -> Value {
    if try needsRecovery(receipt).truthy || !receipt.restartHistory.isUndefined &&
        (!receipt.restartHistory.isArray || receipt.restartHistory.elements.contains { row in !row.truthy || row.typeOf != "object" }) { return .undefined }
    let receiptId = try restartReceiptId(paths, file)
    if !receiptId.truthy { return .undefined }
    let outcomes = ValueMap((receipt.restartHistory ?? []).elements.map { ($0.attemptId, $0) })
    for name in ["restart-events.jsonl.1", "restart-events.jsonl"] {
        var handle: FileHandle?
        defer { try? handle?.close() }
        do {
            handle = try fs.open(path.join(paths.state.description, name), O_RDONLY | O_NOFOLLOW, 0o666)
            let detail = try handle!.stat()
            if !(try detail["isFile"].call().truthy) || toNumber(detail["size"]) > RESTART_LOG_BYTES { continue }
            let text = String(decoding: try handle!.readFile(), as: UTF8.self)
            for line in text.components(separatedBy: "\n").dropLast() {
                guard let row = try? JSON.parse(line) else { continue }
                if row.event === "outcome" && row.receiptId === receiptId && UUID.test((row.attemptId ?? "").description) && !outcomes.has(row.attemptId) {
                    outcomes.set(row.attemptId, row)
                }
            }
        } catch {}
    }
    if outcomes.size > 0 { receipt.restartHistory = outcomes.values.value }
    return .undefined
}

func updateRestartReceipt(_ paths: Value = .undefined, _ file: Value = .undefined, _ update: Value = .undefined) throws -> Value {
    if !(try restartReceiptId(paths, file)).truthy { return .null }
    func snapshot() throws -> Value {
        try [file.description, "\(file).journal"].map { name -> Value in
            var detail: Value = .null
            do { detail = try fs.lstat(name, bigint: true) } catch {
                let error = errorObject(error)
                if error.code !== "ENOENT" { throw EngineError(error) }
            }
            if try detail.truthy && !detail["isFile"].call().truthy { throw EngineError("Restart receipt is not a regular file") }
            return detail.truthy ? try statIdentity(detail) : .null
        }.value
    }
    var before: Value = .undefined, receipt: Value = .undefined
    do {
        before = try snapshot()
        if !before[0].truthy { return .null }
        receipt = try readReceipt(file)
        if try needsRecovery(receipt).truthy { return .null }
    } catch { return .null }
    try update.call(receipt)
    let beforeText = stable(before)
    _ = try saveText(file, Value(jsonText(receipt)), Value { _ in
        if stable(try snapshot()) != beforeText { throw EngineError("Restart receipt changed before saving") }
        return .undefined
    })
    return receipt
}

public func withDesktopRestart(_ plan: Value = .undefined, _ paths: Value = .undefined, _ work: Value = .undefined, _ report: Value = .undefined, _ io: Value = .undefined) throws -> Value {
    let report = fnOr(report)
    let paths = Value.spread(paths, ["claudeApp": plan.app ?? paths.claudeApp])
    let nowValue: Value = io.now ?? Value { _ in Value(process.monotonic()) }
    let now = { () throws -> Double in toNumber(try nowValue.call()) }
    let wait: Value = io.wait ?? Value { args in process.sleep(toNumber(arg(args, 0))); return .undefined }
    let inspect = { () throws -> Value in io.inspect.isUndefined ? try processTable(paths.claudeApp) : try io.inspect.call() }
    let safeInspect = { () -> Value in (try? inspect()) ?? .null }
    let run: Value = io.command ?? Value { args in try command(arg(args, 0), arg(args, 1), arg(args, 2)) }
    let reserve = toNumber(io.reserve ?? Value(REOPEN_RESERVE))
    let started = try now()
    var lastProgress = try now()
    let activity: Value = ["progress": Value { _ in lastProgress = try now(); return .undefined }]
    let shutdownWait = toNumber(io.shutdownWait ?? Value(SHUTDOWN_WAIT))
    let file = path.join(paths.state.description, "restart.json")
    let state: Value = ["at": Value(stamp()), "attemptId": Value(randomUUID()), "requestedAt": Value(isoNow()), "app": paths.claudeApp,
                        "desktop": plan.desktop, "held": plan.held, "outcome": "closing"]
    let origin: Value = plan.receiptFile ?? (plan.selection.truthy ? Value(path.join(paths.state.description, "\(state.at).json")) : .null)
    let kind: Value = plan.kind === "undo" ? "undo" : plan.resume.truthy || plan.kind === "finish" || plan.kind === "recover" ? "finish" : plan.kind === "move" ? "move" : "restart"
    func diagnostic(_ event: String, _ extra: Value = Value.newObject()) throws {
        let base: [(String, Value)] = [
            ("event", Value(event)), ("kind", kind), ("attemptId", state.attemptId), ("at", Value(isoNow())),
            ("receiptId", try restartReceiptId(paths, origin)),
            ("planNonce", UUID.test((plan.nonce ?? "").description) ? plan.nonce : .null),
            ("selectionId", plan.selection.truthy ? Value(sha(stable(plan.selection))) : .null),
            ("elapsedMs", Value(nanMax(0, roundHalfUp(try now() - started)))),
            ("held", plan.held["length"]), ("affected", optLength(plan.affected) ?? 0),
        ]
        _ = try appendRestartEvent(paths, Value.spread(Value(base), extra))
    }
    func save() throws { _ = try saveJson(Value(file), state) }
    var nextInspection = -Double.infinity
    func check(_ force: Bool) throws {
        let stallWait = toNumber(io.stallWait ?? Value(STALL_WAIT))
        if try now() - lastProgress >= stallWait { throw makeError("The move stopped making progress", code: "MOVE_STALLED") }
        if try !force && now() < nextInspection { return }
        let possible = io.inspect.truthy || childProcess.spawnSync("/usr/bin/pgrep", ["-x", "Claude"], SpawnOptions()).status != 1
        if try possible && appProcess(paths, inspect()).truthy {
            throw makeError("Claude Desktop reopened before the held move finished. Retry the move.", code: "RESTART_REOPENED")
        }
        nextInspection = try now() + 100
        if try now() - lastProgress >= stallWait { throw makeError("The move stopped making progress", code: "MOVE_STALLED") }
    }
    let checkValue = Value { args in try check(arg(args, 0).truthy); return .undefined }
    try fs.mkdir(paths.state.description, true, 0o700)
    try save()
    try diagnostic("start")
    var result: Value = .undefined, failure: Value = .undefined, stopCode: Value = .undefined
    do {
        let live = try inspect()
        let desktop = try appProcess(paths, live)
        if try !desktop.truthy || restartFingerprint(desktop, live) !== plan.fingerprint {
            throw makeError("Open Claude sessions changed. Review the restart plan again.", code: "RESTART_PLAN_CHANGED")
        }
        if try plan.held.elements.contains(where: { held in
            try live.elements.contains { row in
                try row.worker.truthy && row.desktopPid !== desktop.pid && ownsWorker(Value.newSet(row.ids.elements), held.id, held.recordId).truthy
            }
        }) { throw makeError("An external worker now owns a held session. No restart was started.", code: "RESTART_EXTERNAL_WORKER") }
        try report.call("desktop", "Closing Claude Desktop", ["live": true])
        let shutdownDeadline = try now() + shutdownWait
        let quit = try run.call("/usr/bin/osascript", ["-e", Value("tell application \(JSON.text(paths.claudeApp)) to quit")], Value(nanMax(0, shutdownDeadline - now())))
        let gone = try quit.status === 0 && waitFor(Value { _ in
            Value(!(try inspect().elements.contains { row in
                try plan.members.elements.contains { prior in try processIdentity(prior) === processIdentity(row) }
            }))
        }, Value(shutdownDeadline), nowValue, wait).truthy
        if !gone || quit.status !== 0 {
            state.outcome = quit.timedOut.truthy ? "quit-timeout" : "quit-not-confirmed"
            state.error = "Claude Desktop did not confirm shutdown. Answer any native quit dialog yourself. Held records were not moved."
        } else {
            try activity.progress.call()
            state.exitedAt = Value(isoNow())
            state.outcome = "moving"
            try save()
            try diagnostic("exited")
            try check(true)
            result = try localActivity.run(activity) {
                try work.call(["at": state.at, "restart": state, "check": checkValue, "progress": activity.progress])
            }
        }
    } catch {
        failure = errorObject(error)
        state.error = failure.message
        state.outcome = state.outcome === "closing" ? "quit-failed" : "move-failed"
    }
    // finally
    let remainingRows = safeInspect()
    if try !remainingRows.truthy || !appProcess(paths, remainingRows).truthy {
        state.outcomeBeforeReopen = state.outcome
        state.outcome = "reopening"
        let reopenDeadline = try now() + reserve
        let remaining = try reopenDeadline - now()
        // `open` returns before Desktop is up, so the reopen is reported after it returns.
        let opened: Value = (try? run.call("/usr/bin/open", ["-g", "-a", paths.claudeApp], Value(nanMax(1, remaining)))) ?? ["status": .null]
        _ = try? report.call("reopen", "Opening Claude Desktop", ["live": true])
        let present = try waitFor(Value { _ in
            let rows = safeInspect()
            return try and(rows, Value(appProcess(paths, rows).truthy))
        }, Value(reopenDeadline), nowValue, wait)
        state.outcome = opened.status === 0 && present.truthy ? "reopened" : "reopen-failed"
        if state.outcome === "reopened" { state.reopenedAt = Value(isoNow()) } else { state.error = "Could not confirm Claude Desktop reopened. Reopen it manually." }
    }
    do {
        try save()
        if !failure.truthy && result.file.truthy && result.receipt.truthy {
            let receipt = try updateRestartReceipt(paths, result.file, Value { args in arg(args, 0).restart = Value.spread(state); return .undefined })
            if receipt.truthy { Value.assign(result.receipt, receipt) }
        }
    } catch {
        let error = errorObject(error)
        state.error = Value("Restart journal could not be saved: \(error.message)")
        if failure.nullish { failure = error }
    }
    let codes: Set<String> = ["MOVE_STALLED", "RESTART_REOPENED", "RESTART_PLAN_CHANGED", "RESTART_EXTERNAL_WORKER"]
    if failure.truthy {
        stopCode = failure.code.asString.map { codes.contains($0) } == true ? failure.code : "WORK_FAILED"
    } else if state.outcome === "reopen-failed" {
        stopCode = "REOPEN_FAILED"
    } else if (state.outcomeBeforeReopen ?? state.outcome).description.hasPrefix("quit-") {
        stopCode = "QUIT_UNCONFIRMED"
    } else {
        stopCode = state.error.truthy ? "WORK_FAILED" : result.ok === false ? "WORK_REFUSED" : result.truthy ? "COMPLETE" : "NO_WORK"
    }
    let receiptCounts: Value = result.receipt.truthy
        ? ["sessions": optLength(result.receipt.sessions) ?? .null, "failed": optLength(result.receipt.failed) ?? .null, "remote": optLength(result.receipt.remote) ?? .null]
        : .null
    try diagnostic("outcome", ["receiptId": try restartReceiptId(paths, origin ?? result.file), "outcome": state.outcome, "stopCode": stopCode, "receiptCounts": receiptCounts])
    if !failure.truthy {
        do {
            let receiptFile = result.truthy && result.hasOwn("file") ? result.file : origin
            let receipt = try updateRestartReceipt(paths, receiptFile, Value { args in try foldRestartHistory(paths, receiptFile, arg(args, 0)) })
            if receipt.truthy && result.receipt.truthy { Value.assign(result.receipt, receipt) }
        } catch {}
    }
    return ["result": result, "restart": state, "code": stopCode, "error": failure.message ?? state.error,
            "ok": Value(state.outcome === "reopened" && !state.error.truthy && result.ok !== false)]
}

public func layout(_ home: Value = .undefined) throws -> Value {
    let home = home.isUndefined ? process.homedir() : home.description
    let support = path.join(home, "Library/Application Support")
    let entries: [(String, Value)] = [
        ("home", Value(home)),
        ("records", Value(path.join(support, "Claude/claude-code-sessions"))),
        ("agentSessions", Value(path.join(support, "Claude/local-agent-mode-sessions"))),
        ("desktop", Value(path.join(support, "Claude/config.json"))),
        ("logs", Value(path.join(home, "Library/Logs/Claude"))),
        ("cookies", Value(path.join(support, "Claude/Cookies"))),
        ("claudeApp", "/Applications/Claude.app"),
        ("pool", Value(path.join(home, ".claude/projects"))),
        ("login", Value(path.join(home, ".claude.json"))),
        ("backups", Value(path.join(home, ".claude/backups"))),
        ("switchAccounts", Value(path.join(home, ".claude-switch/accounts"))),
        ("webCache", Value(path.join(support, "Claude/IndexedDB/https_claude.ai_0.indexeddb.blob"))),
        ("labels", Value(path.join(support, "claude-handoff/labels.json"))),
        ("state", Value(path.join(support, "claude-handoff"))),
    ]
    return Value(entries)
}
