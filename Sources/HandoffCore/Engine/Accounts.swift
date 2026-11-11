import CryptoKit
import Darwin
import Foundation

// Account discovery, the analysis cache, tree manifests, locking, the Desktop login and the claude.ai client.

// MARK: - Local helpers

// `v.k`, throwing a TypeError when `v` is null or undefined.
fileprivate func member(_ v: Value, _ k: String) throws -> Value {
    if v.nullish { throw EngineError.type("Cannot read properties of \(v.isNull ? "null" : "undefined") (reading '\(k)')") }
    return v[k]
}


fileprivate func nanMax(_ xs: [Double]) -> Double {
    var out = -Double.infinity
    for x in xs {
        if x.isNaN { return .nan }
        if x > out || (x == 0 && out == 0 && x.sign == .plus) { out = x }
    }
    return out
}

fileprivate func roundHalfUp(_ x: Double) -> Double { x.isFinite ? (x + 0.5).rounded(.down) : x }

// Drops trailing whitespace and newlines, and U+FEFF.
fileprivate func trimEnd(_ s: String) -> String {
    var scalars = Array(s.unicodeScalars)
    while let last = scalars.last, CharacterSet.whitespacesAndNewlines.contains(last) || last == "\u{FEFF}" { scalars.removeLast() }
    var out = ""
    out.unicodeScalars.append(contentsOf: scalars)
    return out
}

// Hex-decodes, stopping at the first invalid pair.
fileprivate func hexData(_ s: String) -> Data {
    var out = Data()
    let u = Array(s.utf8)
    func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }
    var i = 0
    while i + 1 < u.count {
        guard let hi = nibble(u[i]), let lo = nibble(u[i + 1]) else { break }
        out.append(hi << 4 | lo)
        i += 2
    }
    return out
}

// URLSearchParams serialization (application/x-www-form-urlencoded).
fileprivate func formEncode(_ s: String) -> String {
    var out = ""
    for b in s.utf8 {
        switch b {
        case 0x2A, 0x2D, 0x2E, 0x5F, 0x30...0x39, 0x41...0x5A, 0x61...0x7A: out.append(Character(UnicodeScalar(b)))
        case 0x20: out += "+"
        default: out += String(format: "%%%02X", b)
        }
    }
    return out
}
fileprivate func searchParams(_ pairs: [(String, String)]) -> String { pairs.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&") }

// BigInt comparison of non-negative decimal strings.
fileprivate func decimalLessOrEqual(_ a: String, _ b: String) -> Bool {
    func norm(_ s: String) -> String { let t = s.drop { $0 == "0" }; return t.isEmpty ? "0" : String(t) }
    let x = norm(a), y = norm(b)
    if x.count != y.count { return x.count < y.count }
    return x <= y
}

// Insertion-ordered string set.
fileprivate final class OrderedStrings {
    var items: [String] = []
    var seen: Set<String> = []
    init(_ xs: [String] = []) { for x in xs { add(x) } }
    func add(_ x: String) { if seen.insert(x).inserted { items.append(x) } }
    func has(_ x: String) -> Bool { seen.contains(x) }
}

// MARK: - Folders and trees

func dirs(_ root: Value = .undefined) throws -> Value {
    let entries = (try? fs.readdir(root.description)) ?? []
    return defaultSorted(entries.filter { $0.isDirectory && UUID.test($0.name) }.map(\.name)).value
}

func mappedPath(_ file: Value = .undefined) throws -> Value {
    let f = file.description
    return Value(path.join(try fs.realpath(path.dirname(f)), path.basename(f)))
}

func sameTree(_ expected: Value = .undefined, _ current: Value = .undefined) throws -> Value {
    Value(current.truthy && expected["fingerprint"] === current["fingerprint"] && (!expected["canonicalRoot"].truthy || expected["canonicalRoot"] === current["canonicalRoot"]))
}

func tree(_ root: Value = .undefined, _ canonicalRoot: Value = .undefined) throws -> Value {
    var out: [Value] = []
    let rootPath = root.description, canonical = canonicalRoot.description
    func walk(_ dir: String) throws {
        let before = try fs.lstat(dir, bigint: true)
        if try !before.isDirectory || fs.realpath(dir) != path.resolve(dir) {
            throw EngineError("unsupported entry \(path.join(rootPath, path.relative(canonical, dir)))")
        }
        let entries = try fs.readdir(dir).enumerated().sorted { a, b in
            let c = localeCompare(a.element.name, b.element.name)
            return c < 0 || (c == 0 && a.offset < b.offset)
        }.map(\.element)
        for e in entries {
            let p = path.join(dir, e.name)
            if e.isDirectory { try walk(p) } else if e.isFile || e.isSymbolicLink { out.append(Value(p)) } else { throw EngineError("unsupported entry \(p)") }
        }
        if try fs.lstat(dir, bigint: true).identity != before.identity || fs.realpath(dir) != path.resolve(dir) {
            throw EngineError("sidecars changed while reading")
        }
    }
    var present = false
    do { _ = try fs.lstat(canonical, bigint: false); present = true } catch {
        let error = errorObject(error)
        if error["code"] !== "ENOENT" { throw EngineError(error) }
    }
    if present { try walk(canonical) }
    if try mappedPath(root) !== canonicalRoot { throw EngineError("sidecar root mapping changed while reading") }
    return out.value
}

func treeFingerprint(_ root: Value = .undefined) throws -> Value {
    let canonicalRoot = try mappedPath(root)
    let files = try tree(root, canonicalRoot)
    let signatures = Value.newMap()
    var dependencies: [Value] = []
    for file in files.elements {
        let f = file.description
        let detail = try fs.lstat(f, bigint: true)
        if !detail.isFile && !detail.isSymbolicLink { throw EngineError("unsupported entry \(f)") }
        let identity = statIdentity(detail)
        signatures.put(file, identity)
        let print: Value = detail.isSymbolicLink ? Value("link:\(identity):\(sha(try fs.readlink(f)))") : identity
        if try statIdentity(fs.lstat(f, bigint: true)) !== identity { throw EngineError("sidecars changed while reading") }
        dependencies.append(["rel": Value(path.relative(canonicalRoot.description, f)), "fingerprint": print])
    }
    if try mappedPath(root) !== canonicalRoot { throw EngineError("sidecar root mapping changed while reading") }
    return ["files": files, "signatures": signatures, "fingerprint": Value(sha(stable(dependencies.value))), "canonicalRoot": canonicalRoot]
}

func manifest(_ root: Value = .undefined, _ cache: Value = .undefined) throws -> Value {
    let cache = cache.isUndefined ? Value.null : cache
    let before = try treeFingerprint(root)
    let files = before["files"]
    let signature = Value(sha(stable([before["fingerprint"], before["canonicalRoot"]])))
    let prior = cache.truthy ? try cacheLookup(cache, "manifests", root, signature) : Value.null
    let rows = prior["rows"] ?? Value.newArray()
    if !prior.truthy {
        for file in files.elements {
            let f = file.description
            let detail = try fs.lstat(f, bigint: true)
            if statIdentity(detail) !== before["signatures"].get(file) { throw EngineError("sidecars changed while reading") }
            let rel = Value(path.relative(before["canonicalRoot"].description, f))
            if detail.isSymbolicLink {
                let data = try fs.readlink(f)
                rows.push(["rel": rel, "bytes": Value(data.count), "sha": Value(sha(data)), "type": "symlink",
                           "resolved": Value(path.resolve(path.dirname(f), String(decoding: data, as: UTF8.self)))])
            } else {
                let data = try readRegular(file, before["signatures"].get(file))
                rows.push(["rel": rel, "bytes": data["length"], "sha": Value(sha(data))])
            }
        }
    }
    if try !sameTree(before, treeFingerprint(root)).truthy { throw EngineError("sidecars changed while reading") }
    if cache.truthy && !prior.truthy { _ = try cacheStore(cache, "manifests", root, signature, ["rows": rows]) }
    return try manifestOf(rows, before["fingerprint"], before["canonicalRoot"])
}

func sidecarIdentity(_ row: Value = .undefined) throws -> Value {
    row["type"] === "symlink" ? Value("link:\(row["sha"]):\(row["resolved"])") : row["sha"]
}

func manifestOf(_ rows: Value = .undefined, _ fingerprint: Value = .undefined, _ canonicalRoot: Value = .undefined) throws -> Value {
    let fingerprint = fingerprint.isUndefined ? Value.null : fingerprint
    let canonicalRoot = canonicalRoot.isUndefined ? Value.null : canonicalRoot
    let set = Value.newSet(try rows.elements.map { Value("\($0["rel"]):\(try sidecarIdentity($0))") })
    let bytes = rows.elements.reduce(0.0) { $0 + ($1["bytes"].asNumber ?? .nan) }
    return ["set": set, "rows": rows, "count": Value(rows.length), "bytes": Value(bytes), "sha": Value(sha(stable(rows))),
            "fingerprint": fingerprint, "canonicalRoot": canonicalRoot]
}

// MARK: - Analysis cache

func emptyCache() throws -> Value {
    ["version": Value(CACHE_VERSION), "semanticVersion": Value(SEMANTIC_VERSION), "histories": .newObject(), "manifests": .newObject(), "remote": .newObject()]
}

func openAnalysisCache(_ paths: DataLayout, _ writable: Value = .undefined) throws -> Value {
    let file = Value(path.join(paths.state, "cache.json"))
    let stored = (try? readJson(file)) ?? .null
    let valid = stored["version"] === Value(CACHE_VERSION) && stored["semanticVersion"] === Value(SEMANTIC_VERSION) &&
        ["histories", "manifests", "remote"].allSatisfy { stored[$0].truthy && stored[$0].isObjectLike && !stored[$0].isArray }
    let used: Value = ["histories": .newSet(), "manifests": .newSet(), "remote": .newSet()]
    let stats: Value = ["historyHits": 0, "historyMisses": 0, "manifestHits": 0, "manifestMisses": 0, "remoteHits": 0, "remoteMisses": 0]
    return ["file": file, "writable": writable, "data": valid ? stored : try emptyCache(), "used": used, "fingerprints": .newMap(), "stats": stats]
}

func fingerprint(_ file: Value = .undefined, _ cache: Value = .undefined) throws -> Value {
    if cache["fingerprints"].has(file) { return cache["fingerprints"].get(file) }
    let detail = try fs.stat(file.description, bigint: true)
    let value = statIdentity(detail)
    cache["fingerprints"].put(file, value)
    return value
}

let cacheNames: Value = [
    "histories": ["historyHits", "historyMisses"],
    "manifests": ["manifestHits", "manifestMisses"],
    "remote": ["remoteHits", "remoteMisses"],
]

func cacheLookup(_ cache: Value = .undefined, _ bucket: Value = .undefined, _ key: Value = .undefined, _ signature: Value = .undefined) throws -> Value {
    cache["used"][bucket].add(key)
    let item = cache["data"][bucket][key]
    if item["signature"] === signature {
        let name = cacheNames[bucket][0]
        cache["stats"][name] = Value(toNumber(cache["stats"][name]) + 1)
        return item["value"]
    }
    let name = cacheNames[bucket][1]
    cache["stats"][name] = Value(toNumber(cache["stats"][name]) + 1)
    return .null
}

func cacheStore(_ cache: Value = .undefined, _ bucket: Value = .undefined, _ key: Value = .undefined, _ signature: Value = .undefined, _ value: Value = .undefined) throws -> Value {
    cache["used"][bucket].add(key)
    cache["data"][bucket][key] = ["signature": signature, "value": value]
    return .undefined
}

func saveAnalysisCache(_ cache: Value = .undefined) throws -> Value {
    if !cache["writable"].truthy { return .undefined }
    func kept(_ bucket: String) -> Value {
        .fromEntries(cache["used"][bucket].elements.compactMap { key in
            let item = cache["data"][bucket][key]
            return item.truthy ? (key.description, item) : nil
        })
    }
    try fs.mkdirp(path.dirname(cache["file"].description))
    let body: Value = ["version": Value(CACHE_VERSION), "semanticVersion": Value(SEMANTIC_VERSION),
                       "histories": kept("histories"), "manifests": kept("manifests"), "remote": kept("remote")]
    _ = try saveJson(cache["file"], body, 0)
    return .undefined
}

// MARK: - Files

public func writeNew(_ file: Value = .undefined, _ text: Value = .undefined, _ created: Value = .undefined) throws -> Value {
    let created = fnOr(created)
    let f = file.description
    try fs.mkdirp(path.dirname(f))
    let temp = path.join(path.dirname(f), ".\(path.basename(f)).\(randomUUID()).tmp")
    let handle = try fs.open(temp, "wx", mode: 0o600)
    var failure: Error?
    do {
        if case .bytes(let b) = text { try handle.writeFile(b.data) } else { try handle.writeFile(text.description) }
        try created.call(try handle.stat().value)
        try fs.link(temp, f)
        productive()
    } catch { failure = error }
    try handle.close()
    try? fs.unlink(temp)
    if let failure { throw failure }
    return .undefined
}

func quarantine(_ items: Value = .undefined, _ dest: Value = .undefined, _ before: Value = .undefined) throws -> Value {
    let before = fnOr(before)
    for p in items.elements {
        if !exists(p) { continue }
        try fs.mkdirp(dest.description)
        try before.call()
        try fs.rename(p.description, path.join(dest.description, path.basename(p.description)))
        productive()
    }
    return .undefined
}

// Holds an exclusive flock(2) on state/lock for the duration of `work`, the same lock `/usr/bin/lockf` takes.
func locked(_ paths: DataLayout, _ work: Value = .undefined) throws -> Value {
    try fs.mkdirp(paths.state)
    let lockFile = path.join(paths.state, "lock")
    let handle: FileHandle
    do { handle = try fs.open(lockFile, O_WRONLY | O_CREAT | O_APPEND, 0o666) } catch {
        throw makeError("lock helper failed, exit 73", code: "LOCK_FAILED")
    }
    if flock(handle.fd, LOCK_EX | LOCK_NB) != 0 {
        let err = errno
        try? handle.close()
        if err == EWOULDBLOCK { throw makeError("another run holds the lock", code: "LOCK_BUSY") }
        throw makeError("lock helper failed, exit 73", code: "LOCK_FAILED")
    }
    defer {
        _ = flock(handle.fd, LOCK_UN)
        try? handle.close()
    }
    return try work.call()
}

// MARK: - Desktop records

func recordFiles(_ dir: Value = .undefined) throws -> Value {
    let d = dir.description
    return defaultSorted(try fs.names(d).filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") }).map { path.join(d, $0) }.value
}

func folderRecords(_ dir: Value = .undefined, _ snapshots: Value = .undefined, _ check: Value = .undefined) throws -> Value {
    let snapshots = snapshots.isUndefined ? Value.null : snapshots
    let check = fnOr(check)
    let before = snapshots.truthy ? try fingerprint(dir) : Value.null
    let previous = snapshots.get(dir)
    let files = previous["signature"] === before ? previous["records"].asMap!.keys : try recordFiles(dir).elements
    let recordsMap = Value.newMap()
    for file in files {
        try check.call()
        let signature = snapshots.truthy ? try fingerprint(file) : Value.null
        let cached = previous["records"].get(file)
        let record = cached["signature"] === signature ? cached["record"] : ((try? readJson(file)) ?? .null)
        if !record.truthy || !record.isObjectLike || record.isArray { throw EngineError("unreadable Desktop record: \(file)") }
        if try snapshots.truthy && fingerprint(file) !== signature { throw EngineError("Desktop record changed while reading: \(file)") }
        recordsMap.put(file, ["signature": signature, "record": record])
        productive()
    }
    if try snapshots.truthy && fingerprint(dir) !== before { throw EngineError("Desktop folder changed while reading: \(dir)") }
    snapshots.put(dir, ["signature": before, "records": recordsMap])
    return recordsMap.asMap!.entries.map { file, entry -> Value in ["file": file, "record": entry["record"]] }.value
}

func records(_ root: Value = .undefined) throws -> Value {
    var out: [Value] = []
    for account in try dirs(root).elements {
        for org in try dirs(Value(path.join(root.description, account.description))).elements {
            let dir = Value(path.join(root.description, account.description, org.description))
            out.append(["account": account, "org": org, "dir": dir, "files": (try? recordFiles(dir)) ?? .newArray()])
        }
    }
    return out.value
}

// MARK: - Scheduled tasks

func taskSessions(_ file: Value = .undefined) throws -> Value {
    let data: Value
    do { data = try readJson(file) } catch {
        if errorObject(error)["code"] === "ENOENT" { let s = Value.newSet(); s["registry"] = .null; return s }
        throw EngineError("unreadable scheduled task registry \(file)")
    }
    if !data.truthy || !data.isObjectLike || data.isArray { throw EngineError("invalid scheduled task registry \(file)") }
    if !data["scheduledTasks"].isUndefined && !data["scheduledTasks"].isArray { throw EngineError("invalid scheduled task registry \(file)") }
    if TASK_STATE_KEYS.contains(where: { key in !data[key].isUndefined && (!data[key].truthy || !data[key].isObjectLike || data[key].isArray) }) {
        throw EngineError("invalid scheduled task state \(file)")
    }
    let tasks = data["scheduledTasks"] ?? Value.newArray()
    if tasks.elements.contains(where: { task in
        !task.truthy || !task.isObjectLike || task.isArray || !task["id"].isString || !task["id"].truthy ||
            (!task["notifySessionId"].isUndefined && !task["notifySessionId"].isNull && !LOCAL_RECORD.test(task["notifySessionId"].description))
    }) { throw EngineError("invalid scheduled task registry \(file)") }
    if Set(tasks.elements.map { $0["id"].description }).count != tasks.length { throw EngineError("scheduled task id collision in \(file)") }
    let s = Value.newSet(tasks.elements.map { $0["notifySessionId"] }.filter(\.truthy))
    s["registry"] = data
    return s
}

func taskState(_ registry: Value = .undefined, _ ids: Value = .undefined) throws -> Value {
    .fromEntries(TASK_STATE_KEYS.map { key in
        (key, Value.fromEntries((registry[key] ?? Value.newObject()).ownEntries.filter { ids.includes(Value($0.0)) }))
    })
}

func taskStateConflict(_ source: Value = .undefined, _ target: Value = .undefined) throws -> Value {
    Value(TASK_STATE_KEYS.contains { key in
        target[key].ownEntries.contains { id, value in !source[key].hasOwn(id) || stable(source[key][id]) != stable(value) }
    })
}

func sortedTasks(_ tasks: Value = .undefined) throws -> Value {
    guard tasks.isArray else { throw EngineError.type("Cannot read properties of \(tasks.nullish ? tasks.description : "object") (reading 'toSorted')") }
    return Value(stable(stableSorted(tasks.elements) { a, b in Double(localeCompare(a["id"].description, b["id"].description)) }.value))
}

func staleTaskProblem(_ source: Value = .undefined, _ twin: Value = .undefined, _ registry: Value = .undefined, _ records: Value = .undefined, _ unreadable: Value = .undefined) throws -> Value {
    let ignored = ["enabled", "lastRunAt", "lastScheduledFor", "notifySessionId"]
    let keys = defaultSorted(unique(source.ownKeys + twin.ownKeys))
    if let different = keys.first(where: { !ignored.contains($0) && stable(source[$0]) != stable(twin[$0]) }) { return Value("destination task differs: \(different)") }
    if twin["enabled"] !== false { return "destination task enabled" }
    if unreadable.truthy { return "destination task records unreadable" }
    if twin["notifySessionId"].truthy && records.elements.contains(where: { $0["sessionId"] === twin["notifySessionId"] }) { return "destination task notification record exists" }
    if records.elements.contains(where: { record in
        record["scheduledTaskId"] === twin["id"] ||
            (record["notifySessionId"].truthy && Value([source["notifySessionId"], twin["notifySessionId"]]).includes(record["notifySessionId"]))
    }) { return "destination task record dependency" }
    for key in TASK_STATE_KEYS {
        let id = twin["id"].description
        if (registry["target"][key] ?? Value.newObject()).hasOwn(id) &&
            (!(registry["source"][key] ?? Value.newObject()).hasOwn(id) || stable(registry["target"][key][id]) != stable(registry["source"][key][id])) {
            return Value("destination task state differs: \(key)")
        }
    }
    return .null
}

func taskRegistrationKind(_ family: Value = .undefined, _ registry: Value = .undefined, _ target: Value = .undefined, _ sourcePresent: Value = .undefined) throws -> Value {
    let sourcePresent = sourcePresent.isUndefined ? Value(false) : sourcePresent
    let tasks = registry["scheduledTasks"] ?? Value.newArray()
    let owned = tasks.elements.filter { family["ids"].includes($0["id"]) }.value
    let twin = try target.truthy && family["replaced"]["length"].truthy &&
        sortedTasks(owned) === sortedTasks(family["replaced"].elements.map { $0["task"] }.value)
    if try twin && (sourcePresent.truthy || stable(taskState(registry, family["ids"])) != stable(family["state"])) { return "twin" }
    if try owned.length > 0 && sortedTasks(owned) === sortedTasks(family["tasks"]) { return "published" }
    if twin { return "twin" }
    if owned.length == 0 && !(target.truthy && family["replaced"]["length"].truthy) { return "absent" }
    throw EngineError("scheduled task registrations changed")
}

func schedulerBusy(_ paths: DataLayout, _ namespaces: Value = .undefined, _ table: Value = .undefined) throws -> Value {
    let table = table.isUndefined ? try processTable(Value(paths.claudeApp)) : table
    if !processRows(table).contains(where: \.isDesktop) { return false }
    let current = try signedIn(paths, table)
    if current["state"] !== "known" { return true }
    return Value(try namespaces.elements.contains { try sameAccount($0, current).truthy })
}

func coldBlocked(_ record: Value = .undefined, _ owners: Value = .undefined) throws -> Value {
    Value(owners.elements.contains { owner in
        let ts = owner["taskSessions"]
        return ts.has(record["sessionId"]) || ts["registry"]["scheduledTasks"].elements.contains { $0["id"] === record["scheduledTaskId"] } ||
            TASK_STATE_KEYS.contains { (ts["registry"][$0] ?? Value.newObject()).hasOwn(record["scheduledTaskId"].description) }
    })
}

func taskFamilies(_ from: Value = .undefined, _ to: Value = .undefined, _ found: Value = .undefined) throws -> Value {
    var families: [Value] = []
    for account in from.elements {
        let tasks = account["taskSessions"]["registry"]["scheduledTasks"] ?? Value.newArray()
        let recordRows = account["allSessions"] ?? account["sessions"]
        var graph: [String: OrderedStrings] = [:]
        let seeds = OrderedStrings()
        func connect(_ a: String, _ b: String) {
            if graph[a] == nil { graph[a] = OrderedStrings() }
            if graph[b] == nil { graph[b] = OrderedStrings() }
            graph[a]!.add(b)
            graph[b]!.add(a)
        }
        for task in tasks.elements {
            seeds.add("task:\(task["id"])")
            connect("task:\(task["id"])", task["notifySessionId"].truthy ? "record:\(task["notifySessionId"])" : "task:\(task["id"])")
        }
        // Returns the `&&` chain's value, which is stored on `row.coldRun`.
        func coldRun(_ row: Value) throws -> Value {
            let deleted = row["deletedTask"]
            if !deleted.truthy { return deleted }
            let record = row["record"]
            return Value(try record["isArchived"] === true && !record["notifySessionId"].truthy && !record["forkedFromSessionId"].truthy &&
                !recordRows.elements.contains { other in Value([other["record"]["forkedFromSessionId"], other["record"]["notifySessionId"]]).includes(record["sessionId"]) } &&
                !coldBlocked(record, [account, to]).truthy)
        }
        for row in found.elements where try sameAccount(row["account"], account).truthy { row["coldRun"] = try coldRun(row) }
        for row in recordRows.elements {
            let record = row["record"], key = "record:\(record["sessionId"])"
            if try record["scheduledTaskId"].truthy && !coldRun(row).truthy { seeds.add(key); connect(key, "task:\(record["scheduledTaskId"])") }
            if record["notifySessionId"].truthy { seeds.add(key); connect(key, "record:\(record["notifySessionId"])") }
            if record["forkedFromSessionId"].truthy { connect(key, "record:\(record["forkedFromSessionId"])") }
        }
        var visited = Set<String>()
        for seed in seeds.items {
            if visited.contains(seed) { continue }
            let keys = OrderedStrings([seed])
            var i = 0
            while i < keys.items.count {
                let key = keys.items[i]
                visited.insert(key)
                for next in graph[key]?.items ?? [] { keys.add(next) }
                i += 1
            }
            let ids = keys.items.filter { $0.hasPrefix("task:") }.map { sliceString($0, 5) }
            let recordIds = keys.items.filter { $0.hasPrefix("record:") }.map { sliceString($0, 7) }
            let idsValue = ids.value, recordIdsValue = recordIds.value
            let members = try found.elements.filter { row in try sameAccount(row["account"], account).truthy && recordIdsValue.includes(row["record"]["sessionId"]) }
            if members.isEmpty { continue }
            let routes: [Value] = tasks.elements.filter { idsValue.includes($0["id"]) }.map { [$0["id"], $0["notifySessionId"] ?? .null] }
            let family: Value = [
                "key": Value("\(account["account"])/\(account["org"])/\(seed)"), "from": try accountRef(account), "to": try accountRef(to),
                "sourceFile": account["taskFile"], "targetFile": to["taskFile"], "ids": idsValue, "recordIds": recordIdsValue,
                "files": members.map { $0["file"] }.value, "links": try members.map { try taskLinks($0["record"]) }.value, "routes": routes.value,
            ]
            let historical = routes.isEmpty &&
                members.allSatisfy { $0["record"]["isArchived"] === true && $0["record"]["scheduledTaskId"].truthy && !$0["record"]["notifySessionId"].truthy } &&
                TASK_STATE_KEYS.allSatisfy { key in
                    ids.allSatisfy { id in
                        !(account["taskSessions"]["registry"][key] ?? Value.newObject()).hasOwn(id) && !(to["taskSessions"]["registry"][key] ?? Value.newObject()).hasOwn(id)
                    }
                }
            let targetTasks = to["taskSessions"]["registry"]["scheduledTasks"] ?? Value.newArray()
            let twins = targetTasks.elements.filter { idsValue.includes($0["id"]) }
            let twinProblems: [Value] = try twins.map { twin in
                guard let source = tasks.elements.first(where: { $0["id"] === twin["id"] }) else { return "target scheduled task collision" }
                let registry: Value = ["source": account["taskSessions"]["registry"], "target": to["taskSessions"]["registry"]]
                return try staleTaskProblem(source, twin, registry, (to["allSessions"] ?? to["sessions"]).elements.map { $0["record"] }.value, to["unreadable"]["length"])
            }
            let twinProblem = twinProblems.first(where: \.truthy) ?? .undefined
            family["error"] = try account["taskError"] ?? to["taskError"] ?? (
                account["unreadable"].length > 0 ? "unreadable scheduled task family member" :
                    (!historical && ids.contains { id in !tasks.elements.contains { $0["id"] === Value(id) } }) || recordIds.count != members.count ? "scheduled task family member missing" :
                    twinProblem ?? (
                        targetTasks.elements.contains { !idsValue.includes($0["id"]) && recordIdsValue.includes($0["notifySessionId"]) } ? "target scheduled task collision" :
                            taskStateConflict(taskState(account["taskSessions"]["registry"], idsValue), taskState(to["taskSessions"]["registry"], idsValue)).truthy
                            ? "target scheduled task state collision" : .null))
            for row in members { Value.assign(row, ["taskFamily": family, "coldRun": false]) }
            families.append(family)
        }
    }
    for family in families where families.contains(where: { other in other !== family && other["ids"].elements.contains { family["ids"].includes($0) } }) {
        family["error"] = "source scheduled task id collision"
    }
    return families.value
}

// MARK: - Account labels (patched)

func unsnappy(_ src: Data) throws -> Data {
    let s = [UInt8](src)
    var pos = 0, len = 0, shift = 0
    func next() throws -> Int {
        guard pos < s.count else { throw EngineError("bad snappy block") }
        defer { pos += 1 }
        return Int(s[pos])
    }
    while true {
        let b = try next()
        guard shift < 63 else { throw EngineError("bad snappy block") }
        len += (b & 0x7f) << shift
        if b < 0x80 { break }
        shift += 7
    }
    guard len <= 1 << 30 else { throw EngineError.range("Array buffer allocation failed") }
    var out = [UInt8](repeating: 0, count: len)
    var o = 0
    while pos < s.count {
        let tag = try next(), kind = tag & 3
        if kind == 0 {
            var n = tag >> 2
            if n >= 60 {
                let k = n - 59
                n = 0
                for i in 0..<k { n += try next() << (8 * i) }
            }
            n += 1
            // src.copy clamps to both buffers but the cursors still advance by n.
            let copy = max(0, min(n, s.count - pos, len - o))
            if copy > 0 { out.replaceSubrange(o..<(o + copy), with: s[pos..<(pos + copy)]) }
            pos += n
            o += n
            continue
        }
        var n: Int, off: Int
        if kind == 1 {
            n = ((tag >> 2) & 7) + 4
            off = ((tag >> 5) << 8) | (try next())
        } else if kind == 2 {
            n = (tag >> 2) + 1
            guard pos + 2 <= s.count else { throw EngineError.range("The value of \"offset\" is out of range.") }
            off = Int(s[pos]) | Int(s[pos + 1]) << 8
            pos += 2
        } else {
            n = (tag >> 2) + 1
            guard pos + 4 <= s.count else { throw EngineError.range("The value of \"offset\" is out of range.") }
            off = Int(s[pos]) | Int(s[pos + 1]) << 8 | Int(s[pos + 2]) << 16 | Int(s[pos + 3]) << 24
            pos += 4
        }
        if off == 0 || off > o || o + n > len { throw EngineError("bad snappy block") }
        for _ in 0..<n { out[o] = out[o - off]; o += 1 }
    }
    return Data(out)
}

// Desktop's IndexedDB values use V8's serialization format, at a wire version newer than common decoders accept.
// Dates are kept as their time value (no enumerable keys either way); very sparse array indexes land in properties.
func readV8(_ buf: [UInt8], _ start: Int) throws -> Value {
    var p = start
    var refs: [Value] = []
    func at(_ i: Int) -> Int? { i >= 0 && i < buf.count ? Int(buf[i]) : nil }
    func varint() -> Double {
        var v = 0.0, s = 0.0
        while true {
            let b = at(p) ?? 0
            p += 1
            v += Double(b & 0x7f) * pow(2, s)
            s += 7
            if b & 0x80 == 0 { return v }
        }
    }
    func double() throws -> Double {
        guard p >= 0, p + 8 <= buf.count else { throw EngineError.range("The value of \"offset\" is out of range.") }
        var bits: UInt64 = 0
        for i in 0..<8 { bits |= UInt64(buf[p + i]) << (8 * UInt64(i)) }
        p += 8
        return Double(bitPattern: bits)
    }
    func bytes(_ n: Double) -> ArraySlice<UInt8> {
        let a = min(max(p, 0), buf.count), b = min(max(0, Double(p) + n).clampedInt, buf.count)
        p = (Double(p) + n).clampedInt
        return a < b ? buf[a..<b] : []
    }
    func put(_ target: Value, _ k: Value, _ v: Value) {
        if case .array(let a) = target, case .number(let d) = k, let i = Int(exactly: d), i >= 0, i < a.items.count + (1 << 20) {
            target[i] = v
        } else if case .array = target, case .number(let d) = k, Int(exactly: d) != nil {
            target[k.description] = v
        } else {
            target[k.description] = v
        }
    }
    var depth = 0
    func value() throws -> Value {
        depth += 1
        defer { depth -= 1 }
        if depth > 10_000 { throw EngineError.range("Maximum call stack size exceeded") }
        while true {
            guard let byte = at(p), p < buf.count else { throw EngineError("truncated V8 value") }
            p += 1
            let t = Character(UnicodeScalar(UInt8(byte)))
            switch t {
            case "\0": continue
            case "_", "-": return .undefined
            case "0": return .null
            case "T": return true
            case "F": return false
            case "I":
                let z = varint()
                return Value(z.truncatingRemainder(dividingBy: 2) != 0 ? -(z + 1) / 2 : z / 2)
            case "U": return Value(varint())
            case "N": return Value(try double())
            case "D":
                let d = Value(try double())
                refs.append(d)
                return d
            case "\"":
                let n = varint()
                return Value(String(bytes: bytes(n), encoding: .isoLatin1) ?? "")
            case "S":
                let n = varint()
                return Value(String(decoding: bytes(n), as: UTF8.self))
            case "c":
                let raw = Array(bytes(varint()))
                let units = stride(from: 0, to: raw.count - 1, by: 2).map { UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8 }
                return Value(String(decoding: units, as: UTF16.self))
            case "^":
                let i = varint()
                return i < Double(refs.count) ? refs[Int(i)] : .undefined
            case "o":
                let o = Value.newObject()
                refs.append(o)
                while at(p) != 0x7b { let k = try value(); put(o, k, try value()) }
                p += 1
                _ = varint()
                return o
            case "A":
                let n = varint()
                // Every element consumes at least one byte, so a longer array is truncated (V8's own deserializer throws the same way).
                if n > Double(buf.count - p) { throw EngineError("truncated V8 value") }
                let a = Value(Array(repeating: Value.undefined, count: Int(n)))
                refs.append(a)
                for i in 0..<Int(n) { a[i] = try value() }
                while at(p) != 0x24 { let k = try value(); put(a, k, try value()) }
                p += 1
                _ = varint(); _ = varint()
                return a
            case "a":
                _ = varint()
                let a = Value.newArray()
                refs.append(a)
                while at(p) != 0x40 { let k = try value(); put(a, k, try value()) }
                p += 1
                _ = varint(); _ = varint()
                return a
            default: throw EngineError("unsupported V8 tag \(t)")
            }
        }
    }
    return try value()
}

fileprivate extension Double {
    var clampedInt: Int { self.isNaN ? 0 : self >= Double(Int.max / 2) ? Int.max / 2 : self <= Double(Int.min / 2) ? Int.min / 2 : Int(self) }
}

func idbValue(_ blob: Data) throws -> Value {
    let b = [UInt8](blob)
    func at(_ s: [UInt8], _ i: Int) -> Int? { i < s.count ? Int(s[i]) : nil }
    let raw = at(b, 0) == 0xff && at(b, 1) == 0x11 && at(b, 2) == 0x02 ? [UInt8](try unsnappy(Data(b.dropFirst(3)))) : b
    var p = 0
    if at(raw, 0) == 0xff && at(raw, 2) == 0xfe { p = 15 } else if at(raw, 0) == 0xff && at(raw, 2) == 0xff { p = 2 }
    if at(raw, p) != 0xff { throw EngineError("not a V8 value") }
    p += 1
    while (at(raw, p) ?? 0) & 0x80 != 0 { p += 1 }
    return try readV8(raw, p + 1)
}

func orgLabel(_ o: Value = .undefined) throws -> Value {
    let caps = o["capabilities"] ?? Value.newArray()
    guard caps.isArray || caps.isString else { throw EngineError.type("(o.capabilities ?? []).includes is not a function") }
    return o["raven_type"].truthy || caps.includes("raven") ? Value("\(o["name"]) Team") : caps.includes("chat") ? "Personal" : o["name"]
}

// The signed-in Desktop account's profile lives only in claude.ai's persisted query cache.
func desktopProfiles(_ dir: Value = .undefined) throws -> Value {
    let emails = Value.newMap()
    let orgs = Value.newMap()
    func visit(_ v: Value, _ depth: Int = 0) throws {
        if !v.truthy || !v.isObjectLike || depth > 12 { return }
        if UUID.test((v["uuid"] ?? "").description) && v["email_address"].isString && v["memberships"].isArray {
            emails.put(v["uuid"], v["email_address"])
            for m in v["memberships"].elements where UUID.test((m["organization"]["uuid"] ?? "").description) && m["organization"]["name"].truthy {
                orgs.put(m["organization"]["uuid"], try orgLabel(m["organization"]))
            }
            return
        }
        // Array holes come back from readV8 as undefined, which visit ignores.
        for k in v.ownKeys { try visit(v[k], depth + 1) }
    }
    func files(_ d: String) -> [String] {
        ((try? fs.readdir(d)) ?? []).flatMap { e -> [String] in
            e.isDirectory ? files(path.join(d, e.name)) : e.name == ".DS_Store" ? [] : [path.join(d, e.name)]
        }
    }
    for file in files(dir.description) {
        // Blob files rotate while Desktop runs; a vanished one is skipped.
        guard let blob = try? readFileData(file) else { continue }
        do { try visit(try idbValue(blob)) } catch {}
    }
    return ["emails": emails, "orgs": orgs]
}

func logins(_ paths: DataLayout) throws -> Value {
    let emails = Value.newMap()
    let orgs = Value.newMap()
    let pairs = Value.newMap()
    func take(_ file: String) throws {
        let a = try member((try? readJson(Value(file))) ?? Value.newObject(), "oauthAccount")
        if a["accountUuid"].truthy && a["emailAddress"].truthy { emails.put(a["accountUuid"], a["emailAddress"]) }
        if a["organizationUuid"].truthy && a["organizationName"].truthy {
            let type = a["organizationType"]
            orgs.put(a["organizationUuid"], type.truthy && !re("team|enterprise").test(type.description) ? "Personal" : a["organizationName"])
        }
        if UUID.test((a["accountUuid"] ?? "").description) && UUID.test((a["organizationUuid"] ?? "").description) {
            pairs.put(Value("\(a["accountUuid"])/\(a["organizationUuid"])"), ["account": a["accountUuid"], "org": a["organizationUuid"]])
        }
    }
    let home = paths.home
    for e in (try? fs.readdir(home)) ?? [] where e.name.hasPrefix(".claude") {
        try take(e.isDirectory ? path.join(home, e.name, ".claude.json") : path.join(home, e.name))
    }
    let switchAccounts = paths.switchAccounts
    for e in (try? fs.readdir(switchAccounts)) ?? [] where e.isDirectory { try take(path.join(switchAccounts, e.name, ".claude.json")) }
    for f in (try? fs.names(paths.backups)) ?? [] where f.hasPrefix(".claude.json.backup") { try take(path.join(paths.backups, f)) }
    try take(paths.login)
    // Desktop only caches the signed-in account, so remember every one seen for later runs.
    let remembered = (try? readJson(Value(paths.labels))) ?? Value.newObject()
    let seen = try desktopProfiles(Value(paths.webCache))
    let rememberedEmails = try member(remembered, "emails"), rememberedOrgs = remembered["orgs"]
    // Live login files and Desktop's profile override what earlier runs remembered.
    let entries = { (map: Value) in Value.fromEntries(map.asMap!.entries.map { ($0.0.description, $0.1) }) }
    let saved: Value = [
        "emails": Value.spread(rememberedEmails, entries(emails), entries(seen["emails"])),
        "orgs": Value.spread(rememberedOrgs, entries(orgs), entries(seen["orgs"])),
    ]
    let previous: Value = ["emails": rememberedEmails ?? Value.newObject(), "orgs": rememberedOrgs ?? Value.newObject()]
    for (account, email) in saved["emails"].ownEntries where UUID.test(account) { emails.put(Value(account), email) }
    for (org, name) in saved["orgs"].ownEntries where UUID.test(org) { orgs.put(Value(org), name) }
    for row in try records(Value(paths.agentSessions)).elements {
        let account = row["account"], org = row["org"]
        if UUID.test(account.description) && UUID.test(org.description) { pairs.put(Value("\(account)/\(org)"), ["account": account, "org": org]) }
        for file in row["files"].elements {
            if emails.has(account) { break }
            let r = (try? readJson(file)) ?? Value.newObject()
            if try member(r, "emailAddress").truthy { emails.put(account, r["emailAddress"]) }
        }
    }
    // Accounts emptied by earlier moves leave no other trace, but their receipts still name them.
    let receiptFiles = try receipts(paths)
    guard let receiptList = receiptFiles.asArray else { throw EngineError.type("receipts(...).reverse is not a function") }
    receiptList.items.reverse()
    for file in receiptList.items {
        guard let handle = try? fs.open(path.join(paths.state, file.description), "r") else { continue }
        var head = ""
        do {
            let data = try handle.read(length: 16 * 1024, position: 0)
            head = String(decoding: data, as: UTF8.self)
        } catch {}
        try? handle.close()
        for m in re(#""account": "([0-9a-f-]{36})",\s*"org": "([0-9a-f-]{36})",\s*"label": "((?:[^"\\]|\\.)*)""#, "gi").matchAll(head) {
            let account = m[1] ?? "", org = m[2] ?? "", raw = m[3] ?? ""
            if !UUID.test(account) || !UUID.test(org) { continue }
            let isDir: Bool
            do { isDir = try fs.stat(path.join(paths.records, account, org)).isDirectory } catch { isDir = false }
            if !isDir { continue }
            pairs.put(Value("\(account)/\(org)"), ["account": Value(account), "org": Value(org)])
            let parts = try JSON.parse("\"\(raw)\"").description.components(separatedBy: " · ")
            let who = parts[0], team = parts.count > 1 ? parts[1] : nil
            if who.contains("@") && !emails.has(account) { emails.put(Value(account), Value(who)) }
            if let team, !team.isEmpty, team != short(org), !orgs.has(org) { orgs.put(Value(org), Value(team)) }
        }
    }
    // Login files, agent records and receipts come and go, so keep any name they taught us.
    for (name, learned) in [("emails", emails), ("orgs", orgs)] {
        let kept = saved[name].asObject!
        for (key, label) in learned.asMap!.entries where UUID.test(key.description) && !kept.has(key.description) { kept[key.description] = label }
    }
    if JSON.text(saved) != JSON.text(previous) {
        let labels = paths.labels
        let tmp = "\(labels).\(process.pid).tmp"
        do {
            try fs.write(tmp, JSON.text(saved, space: 2) + "\n")
            try fs.rename(tmp, labels)
        } catch { try? fs.unlink(tmp) }
    }
    return ["emails": emails, "orgs": orgs, "pairs": pairs]
}

// MARK: - Presentation

func ago(_ ms: Value = .undefined) throws -> Value {
    if !ms.truthy { return "-" }
    let s = max(0, dateNow() - toNumber(ms)) / 1000
    let (n, unit): (Double, String) = s < 3600 ? (s / 60, "m") : s < 86400 ? (s / 3600, "h") : s < 86400 * 30 ? (s / 86400, "d") : (s / 86400 / 30, "mo")
    let r = roundHalfUp(n)
    return Value("\(numberString(r.isNaN ? .nan : max(1, r)))\(unit) ago")
}

func mode(_ values: Value = .undefined) throws -> Value {
    let tally = ValueMap()
    for v in values.elements where v.truthy { tally.set(v, Value(toNumber(tally.get(v) ?? 0) + 1)) }
    let sorted = stableSorted(tally.entries.map { Value([$0.0, $0.1]) }) { a, b in toNumber(b[1]) - toNumber(a[1]) }
    return sorted.first?[0] ?? "-"
}

// MARK: - Desktop identity

func desktopLaunch(_ paths: DataLayout, _ table: Value = .undefined) throws -> Value {
    let app = path.join(paths.claudeApp, "Contents/MacOS/Claude")
    let apps = processRows(table).filter { $0.isDesktop || $0.executable == app }.map(\.raw)
    let started = apps.count == 1 ? dateParse(apps[0]["started"].description) : .nan
    return started.isFinite && started <= dateNow() ? ["pid": apps[0]["pid"], "started": Value(started)] : .null
}

public func idleTimeouts(_ paths: Value = .undefined, _ table: Value = .undefined) throws -> Value { try idleTimeouts(DataLayout(paths), table) }
func idleTimeouts(_ paths: DataLayout, _ table: Value = .undefined) throws -> Value {
    let launch = try desktopLaunch(paths, table), result = Value.newMap()
    if !launch.truthy { return result }
    var handle: FileHandle?
    defer { try? handle?.close() }
    do {
        handle = try fs.open(path.join(paths.logs, "main.log"), O_RDONLY | O_NOFOLLOW, 0o666)
        let before = try handle!.stat()
        if !before.isFile { return result }
        let total = Int(before.size)
        let size = min(total, 4 * 1024 * 1024)
        let data = try handle!.read(length: size, position: Int64(total - size))
        if data.count != size { return result }
        var rows = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let recordPattern = re(#"\[WarmLifecycle:session\] Starting idle timeout for (local_"# + UUID_PATTERN + "):", "i")
        if size < total { rows.removeFirst() }
        let entryPattern = re(#"^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,3})?) \[info\] \[WarmLifecycle:session\] Starting idle timeout for local_[0-9a-f-]+: ([1-9][0-9]*)s\z"#, "i")
        for (index, line) in rows.enumerated() {
            guard let record = recordPattern.match(line)?[1]?.lowercased() else { continue }
            let entry = entryPattern.match(line)
            let time = entry != nil ? dateParse(entry![1]!.replacingOccurrences(of: " ", with: "T", options: [], range: entry![1]!.range(of: " "))) : .nan
            if time.isFinite && time < launch["started"].asNumber! { continue }
            let seconds: Value
            if let entry, index < rows.count - 1, time <= dateNow(), isSafeInteger(Value(toNumber(Value(entry[2]!)))) { seconds = Value(toNumber(Value(entry[2]!))) } else { seconds = .null }
            let key = Value(record)
            result.put(key, !result.has(key) || result.get(key) === seconds ? seconds : .null)
        }
        let after = try handle!.stat()
        if after.sizeValue !== before.sizeValue || after.mtimeMs !== before.mtimeMs { return Value.newMap() }
    } catch { return Value.newMap() }
    return result
}

public func signedIn(_ paths: Value = .undefined, _ table: Value = .undefined) throws -> Value { try signedIn(DataLayout(paths), table) }
func signedIn(_ paths: DataLayout, _ table: Value = .undefined) throws -> Value {
    func unknown(_ state: String = "unknown", _ time: Double? = nil) -> Value {
        ["account": .null, "org": .null, "state": Value(state), "source": time == nil ? "unknown" : "log", "at": time.map { Value(isoString($0)) } ?? .null]
    }
    do {
        var table = table
        if table.nullish {
            var env = process.env()
            env["LC_ALL"] = "C"
            let result = childProcess.spawnSync("/bin/ps", ["-axo", "pid=,ppid=,lstart=,comm="], SpawnOptions(timeout: 2000, env: env))
            if result.error != nil || result.status != 0 { return unknown() }
            table = try parseProcesses(Value(result.stdout), "", Value(paths.claudeApp))
        }
        let launch = try desktopLaunch(paths, table)
        if !launch.truthy { return unknown() }
        let started = launch["started"].asNumber!
        let desktop = (try? readJson(Value(paths.desktop))) ?? Value.newObject()
        let logs = paths.logs
        let logNames: [Value] = try fs.names(logs).filter { re(#"^main(?:[1-9][0-9]*)?\.log$"#).test($0) }.map { Value($0) }
        let files = stableSorted(logNames) { a, b in
            toNumber(Value(sliceString(a.description, 4, -4))) - toNumber(Value(sliceString(b.description, 4, -4)))
        }
        let entryPattern = re(#"^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,3})?) \[[A-Za-z0-9_]+\] (.*)$"#)
        for file in files {
            let lines = try readFileText(path.join(logs, file.description)).components(separatedBy: "\n")
            var index = lines.count - 1
            while index >= 0 {
                defer { index -= 1 }
                let line = lines[index]
                let local = line.contains("[LocalSessionManager]")
                let login = line.contains("[account] Login-state transition")
                if !login && !(local && re("Initialization succeeded|Org changed|Account logged out|Cannot initialize sessions|loadSessions failed").test(line)) { continue }
                let entry = entryPattern.match(line)
                let time = entry != nil ? dateParse(entry![1]!.replacingOccurrences(of: " ", with: "T", options: [], range: entry![1]!.range(of: " "))) : .nan
                if index == lines.count - 1 || !time.isFinite || time < started || time > dateNow() { return unknown() }
                let body = entry![2]!
                if login || body.contains("Account logged out") {
                    return unknown(re(#"loggedOut: .*?(?:→|->) true(?:,|\))|Account logged out"#).test(body) ? "logged-out" : "unknown", time)
                }
                let match = re(#"^\[LocalSessionManager\] Initialization succeeded\b.*?accountId=([^,\s]+), orgId=([^,\s]+)"#).match(body)
                guard let match, UUID.test(match[1]!), UUID.test(match[2]!) else { return unknown("unknown", time) }
                let account = match[1]!.lowercased(), org = match[2]!.lowercased()
                let last = try member(desktop, "lastKnownAccountUuid")
                if last.truthy {
                    guard let text = last.asString else { throw EngineError.type("desktop.lastKnownAccountUuid.toLowerCase is not a function") }
                    if text.lowercased() != account { return unknown("unknown", time) }
                }
                return ["account": Value(account), "org": Value(org), "state": "known", "source": "log", "at": Value(isoString(time))]
            }
        }
    } catch {}
    return unknown()
}

// MARK: - Desktop login material

func plistValue(_ file: Value = .undefined, _ key: Value = .undefined) throws -> Value {
    let result = childProcess.spawnSync("/usr/libexec/PlistBuddy", ["-c", "Print :\(key)", file.description], SpawnOptions(timeout: 10_000))
    if result.error != nil || result.status != 0 || result.stdout.trimmingWhitespace.isEmpty { throw EngineError("cannot read \(path.basename(file.description))") }
    return Value(result.stdout.trimmingWhitespace)
}

// `pattern` is the regex source; the first capture group is returned.
func binaryMatch(_ file: Value = .undefined, _ pattern: Value = .undefined) throws -> Value {
    let regex = re(pattern.description)
    let handle = try fs.open(file.description, "r")
    defer { try? handle.close() }
    var carry = ""
    var found: String?
    // createReadStream's default 64 KiB chunks.
    try handle.chunks(size: 64 * 1024) { chunk in
        if found != nil { return }
        productive()
        let text = carry + (String(data: chunk, encoding: .isoLatin1) ?? "")
        if let match = regex.match(text) { found = match[1] ?? "undefined"; return }
        carry = sliceString(text, -128)
    }
    return found.map { Value($0) } ?? .null
}

func desktopUserAgent(_ paths: DataLayout) throws -> Value {
    let app = paths.claudeApp
    let appInfo = path.join(app, "Contents/Info.plist")
    let framework = path.join(app, "Contents/Frameworks/Electron Framework.framework/Versions/A")
    let claude = try plistValue(Value(appInfo), "CFBundleShortVersionString")
    let electron = try plistValue(Value(path.join(framework, "Resources/Info.plist")), "CFBundleVersion")
    let chrome = try binaryMatch(Value(path.join(framework, "Electron Framework")), #"Chrome/([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)"#)
    if !chrome.truthy { throw EngineError("cannot determine Claude Desktop browser version") }
    return Value("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Claude/\(claude) Chrome/\(chrome) Electron/\(electron) Safari/537.36")
}

func decryptCookie(_ host: Value = .undefined, _ encrypted: Value = .undefined, _ key: Value = .undefined, _ version: Value = .undefined) throws -> Value {
    let data = encrypted.asData ?? Data()
    if data.isEmpty || !["v10", "v11"].contains(String(decoding: data.prefix(3), as: UTF8.self)) { throw EngineError("unsupported Claude cookie encryption") }
    let plain = try aes128cbcDecrypt(Data(data.dropFirst(3)), key: key.asData ?? Data(), iv: Data(repeating: 0x20, count: 16))
    if toNumber(version) < 24 { return Value(String(decoding: plain, as: UTF8.self)) }
    let digest = Data(SHA256.hash(data: Data(host.description.utf8)))
    if plain.prefix(digest.count) != digest { throw EngineError("Claude cookie host verification failed") }
    return Value(String(decoding: plain.dropFirst(digest.count), as: UTF8.self))
}

func desktopCookies(_ paths: DataLayout) throws -> Value {
    let options = SpawnOptions(timeout: 10_000)
    let cookies = paths.cookies
    let versionResult = childProcess.spawnSync("/usr/bin/sqlite3", ["-readonly", cookies, "SELECT value FROM meta WHERE key='version';"], options)
    let rowsResult = childProcess.spawnSync("/usr/bin/sqlite3", ["-readonly", "-separator", "\t", cookies,
        "SELECT host_key,name,hex(CAST(value AS BLOB)),hex(encrypted_value) FROM cookies WHERE host_key IN ('.claude.ai','claude.ai') ORDER BY length(path) DESC,creation_utc;"], options)
    let secretResult = childProcess.spawnSync("/usr/bin/security", ["find-generic-password", "-w", "-s", "Claude Safe Storage"], options)
    if [versionResult, rowsResult, secretResult].contains(where: { $0.error != nil || $0.status != 0 }) { throw EngineError("cannot read Claude Desktop login") }
    let version = toNumber(Value(versionResult.stdout.trimmingWhitespace))
    let password = trimEnd(secretResult.stdout)
    let key = pbkdf2(Data(password.utf8), salt: Data("saltysalt".utf8), iterations: 1003, keyLength: 16)
    let values = Value.newMap()
    for line in rowsResult.stdout.components(separatedBy: "\n") where !line.isEmpty {
        let fields = line.components(separatedBy: "\t")
        let host = fields[0], name = fields.count > 1 ? fields[1] : nil, plainHex = fields.count > 2 ? fields[2] : nil, encryptedHex = fields.count > 3 ? fields[3] : nil
        if !re(#"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$"#).test(name ?? "") { continue }
        let value: String
        if let plainHex, !plainHex.isEmpty {
            value = String(decoding: hexData(plainHex), as: UTF8.self)
        } else {
            guard let encryptedHex else { throw EngineError.type("The first argument must be of type string or an instance of Buffer, ArrayBuffer, or Array or an Array-like Object. Received undefined") }
            value = try decryptCookie(Value(host), Value(hexData(encryptedHex)), Value(key), Value(version)).description
        }
        if !value.isEmpty && !re("[;\r\n]").test(value) { values.put(Value(name!), Value(value)) }
    }
    if !values.has("sessionKey") { throw makeError("Claude Desktop login is still updating", code: "CLOUD_AUTH_PENDING") }
    return values
}

func wireRemoteId(_ id: Value = .undefined) throws -> Value {
    let text = (id ?? "").description
    if !re(#"^(?:cse|session)_[A-Za-z0-9_-]+$"#).test(text) { throw EngineError("invalid Remote Control session id") }
    return Value(re("^cse_").replace(id.description, "session_"))
}

func remoteId(_ id: Value = .undefined) throws -> Value {
    (try? wireRemoteId(id)) ?? .null
}

// MARK: - claude.ai client

// The HTTP transport behind cloudClient; tests replace it.
// Request: { url, method, headers, body?, redirect: 'error', timeout? (ms) | signal? }.
// Response: { status, ok, headers: { lowercased-name: value }, body: bytes }.
public var cloudFetch: (Value) throws -> Value = { request in try nativeCloudFetch(request) }

fileprivate final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

fileprivate final class FetchBox { var data: Data?; var response: URLResponse?; var error: Error? }

fileprivate func nativeCloudFetch(_ request: Value) throws -> Value {
    guard let url = URL(string: request["url"].description) else { throw EngineError.type("Failed to parse URL from \(request["url"])") }
    var req = URLRequest(url: url)
    req.httpMethod = request["method"].nullish ? "GET" : request["method"].description
    req.httpShouldHandleCookies = false
    for (k, v) in request["headers"].ownEntries { req.setValue(v.description, forHTTPHeaderField: k) }
    if case .bytes(let b) = request["body"] { req.httpBody = b.data } else if !request["body"].nullish { req.httpBody = Data(request["body"].description.utf8) }
    let timeout = request["timeout"].asNumber
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCache = nil
    if let timeout { config.timeoutIntervalForRequest = timeout / 1000; req.timeoutInterval = timeout / 1000 }
    let session = URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let box = FetchBox(), done = DispatchSemaphore(value: 0)
    let task = session.dataTask(with: req) { data, response, error in box.data = data; box.response = response; box.error = error; done.signal() }
    task.resume()
    if let timeout {
        if done.wait(timeout: .now() + .milliseconds(Int(timeout))) == .timedOut {
            task.cancel()
            done.wait()
            throw EngineError("The operation was aborted due to timeout", code: Value(23), name: "TimeoutError")
        }
    } else { done.wait() }
    if let error = box.error as? URLError, error.code == .timedOut {
        throw EngineError("The operation was aborted due to timeout", code: Value(23), name: "TimeoutError")
    }
    guard box.error == nil, let http = box.response as? HTTPURLResponse else { throw EngineError.type("fetch failed") }
    // redirect: 'error'
    if [301, 302, 303, 307, 308].contains(http.statusCode) { throw EngineError.type("fetch failed") }
    let headers = Value.newObject()
    for (k, v) in http.allHeaderFields { headers[String(describing: k).lowercased()] = Value(String(describing: v)) }
    return ["status": Value(http.statusCode), "ok": Value((200...299).contains(http.statusCode)), "headers": headers, "body": Value(box.data ?? Data())]
}

public func cloudClient(_ paths: Value = .undefined, _ expected: Value = .undefined, _ io: Value = .undefined) throws -> Value { try cloudClient(DataLayout(paths), expected, io) }
func cloudClient(_ paths: DataLayout, _ expected: Value = .undefined, _ io: Value = .undefined) throws -> Value {
    let expected = expected.isUndefined ? Value.null : expected
    let io = io.isUndefined ? Value.newObject() : io
    let memory = try io["memory"] ?? operationMemory()
    let current = try io["active"] ?? signedIn(paths)
    if current["state"] === "logged-out" { throw EngineError("Claude Desktop is signed out") }
    if try expected.truthy && current["state"] === "known" && !sameLogin(expected, current).truthy { throw EngineError("sign Claude Desktop into \(try loginLabel(expected))") }
    let selected = expected.truthy ? expected : (current["state"] === "known" ? current : .null)
    let cookies = try io["cookies"] ?? desktopCookies(paths)
    let cookie = cookies.elements.map { "\($0[0])=\($0[1])" }.joined(separator: "; ")
    let userAgent = try io["userAgent"] ?? desktopUserAgent(paths)
    let baseHeaders: Value = [
        "accept": "application/json",
        "cookie": Value(cookie),
        "origin": "https://claude.ai",
        "referer": "https://claude.ai/",
        "user-agent": userAgent,
        "anthropic-version": "2023-06-01",
        "anthropic-beta": "oauth-2025-04-20",
    ]
    func raw(_ endpoint: String, _ options: Value = .newObject(), _ org: Value = .null) throws -> Value {
        try memory["check"].call()
        let headers = Value.spread(baseHeaders, org.truthy ? ["x-organization-uuid": org] : .newObject(), options["headers"] ?? .newObject())
        let request = Value.spread(options, ["url": Value("https://claude.ai\(endpoint)"), "method": options["method"] ?? "GET", "headers": headers, "redirect": "error"])
        if options["signal"].nullish { request["timeout"] = 15_000 }
        let response = try cloudFetch(request)
        if !response["ok"].truthy {
            throw makeError("Claude \(endpoint.components(separatedBy: "?")[0]) returned \(response["status"])", code: response["status"] === 401 ? "CLOUD_AUTH_PENDING" : "CLOUD_HTTP_ERROR")
        }
        if org.truthy && endpoint.hasPrefix("/v1/code/") {
            let responseOrg = response["headers"]["anthropic-organization-id"] ?? .null
            if responseOrg !== org { throw EngineError("Claude Remote Control organization changed") }
        }
        if response["status"] === 204 { return .null }
        // The memory budget reads a body as a list of chunks; this transport delivers the whole body as one.
        let body = response["body"]
        return try memory["read"].call(Value.spread(response, ["body": body.nullish ? body : [body]]))
    }
    let account = try raw("/api/account")
    if !UUID.test((account["uuid"] ?? "").description) { throw EngineError("Claude Desktop account could not be verified") }
    if selected["account"].truthy && account["uuid"] !== selected["account"] {
        let mismatch = try expected.truthy && !sameLogin(selected, current).truthy
        throw makeError(mismatch ? "sign Claude Desktop into \(try loginLabel(expected))" : "Claude Desktop login is still updating. Try again in a moment.",
                      code: try sameLogin(selected, current).truthy ? "CLOUD_AUTH_PENDING" : "CLOUD_ACCOUNT_MISMATCH")
    }
    let organizations = try raw("/api/organizations")
    let preferredOrg = selected["org"] ?? cookies.get("lastActiveOrg")
    let organization = organizations.isArray ? try organizations.elements.first { try member($0, "uuid") === preferredOrg } ?? .undefined : .null
    if !organization.truthy { throw EngineError("Claude Desktop organization could not be verified") }
    let org = organization["uuid"]
    func request(_ endpoint: String, _ options: Value = .newObject()) throws -> Value { try raw(endpoint, options, org) }
    func session(_ id: Value) throws -> Value {
        let body = try request("/v1/code/sessions/\(try wireRemoteId(id))")
        let value = body["response_shape"] ?? body
        if !value.truthy || !value.isObjectLike || value.isArray { throw EngineError("Remote Control session response changed") }
        return value
    }
    func eventRows(_ id: Value) throws -> Value {
        var out: [Value] = []
        var cursor: Value = .null
        var lastSequence: String?
        let seen = ValueSet()
        for _ in 0...2000 {
            var query: [(String, String)] = [("limit", "500"), ("sort_order", "asc")]
            if cursor.truthy { query.append(("cursor", cursor.description)) }
            let body = try request("/v1/code/sessions/\(try wireRemoteId(id))/events?\(searchParams(query))")
            if !body["data"].isArray || body["data"].length > 500 { throw EngineError("Remote Control history response changed") }
            let data = body["data"].elements
            if out.count + data.count > 1_000_000 { throw makeError("Remote Control history exceeded 1,000,000 events", code: "CLOUD_HISTORY_LIMIT") }
            if data.contains(where: { event in
                !event.truthy || !event.isObjectLike || !event["event_type"].isString || !event["payload"].truthy || !event["payload"].isObjectLike
            }) { throw EngineError("Remote Control event response changed") }
            for event in data {
                let n = event["sequence_num"]
                let sequence: String? = n.isNumber && isSafeInteger(n) && n.asNumber! >= 0 ? String(Int64(n.asNumber!))
                    : n.isString && re(#"^[0-9]+$"#).test(n.asString!) ? n.asString! : nil
                guard let sequence else { throw EngineError("Remote Control event sequence changed") }
                if let lastSequence, decimalLessOrEqual(sequence, lastSequence) { throw EngineError("Remote Control event sequence changed") }
                lastSequence = sequence
            }
            out.append(contentsOf: data)
            if data.count < 500 { return out.value }
            cursor = body["resume_cursor"]
            if !cursor.truthy || seen.has(cursor) { throw EngineError("Remote Control history cursor did not advance") }
            seen.add(cursor)
        }
        throw makeError("Remote Control history exceeded 1,000,000 events", code: "CLOUD_HISTORY_LIMIT")
    }
    let post: Value = ["method": "POST", "headers": ["content-type": "application/json"], "body": "{}"]
    return [
        "memory": memory,
        "account": account["uuid"],
        "org": org,
        "list": Value { _ in
            let query = searchParams([("statuses", "active"), ("limit", "100"), ("statuses", "paused")])
            let body = try request("/v1/code/sessions?\(query)")
            if !body["data"].isArray { throw EngineError("Remote Control session list response changed") }
            if body["data"].length >= 100 { throw EngineError("Remote Control session list reached its safety limit") }
            return body["data"]
        },
        "eventRows": Value { args in try eventRows(args.first ?? .undefined) },
        "session": Value { args in try session(args.first ?? .undefined) },
        "archive": Value { args in try request("/v1/code/sessions/\(try wireRemoteId(args.first ?? .undefined))/archive", post.deepClone()) },
        "unarchive": Value { args in try request("/v1/code/sessions/\(try wireRemoteId(args.first ?? .undefined))/unarchive", post.deepClone()) },
    ]
}

// MARK: - Accounts

func priorSessions(_ record: Value = .undefined) throws -> Value {
    record["priorCliSessionIds"].isArray ? record["priorCliSessionIds"] : .newArray()
}

func desktopSession(_ file: Value = .undefined, _ record: Value = .undefined) throws -> Value {
    [
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

public func accounts(_ paths: Value = .undefined, _ processes: Value = .undefined) throws -> Value { try accounts(DataLayout(paths), processes) }
func accounts(_ paths: DataLayout, _ processes: Value = .undefined) throws -> Value {
    let processes = processes.isUndefined ? Value.null : processes
    let found = try logins(paths)
    let emails = found["emails"], orgs = found["orgs"], pairs = found["pairs"]
    let cur = try signedIn(paths, processes)
    var out: [Value] = []
    let stored = try records(Value(paths.records))
    let known: [Value] = try pairs.asMap!.values.filter { pair in try !stored.elements.contains { try sameAccount($0, pair).truthy } }.map { pair in
        ["account": pair["account"], "org": pair["org"], "dir": Value(path.join(paths.records, pair["account"].description, pair["org"].description)), "files": .newArray()]
    }
    for row in stored.elements + known {
        let account = row["account"], org = row["org"], dir = row["dir"]
        var sessions: [Value] = []
        var unreadable: [Value] = []
        for file in row["files"].elements {
            let r = (try? readJson(file)) ?? .null
            if !r.truthy { unreadable.append(file); continue }
            sessions.append(try desktopSession(file, r))
        }
        let activeAt = nanMax([0] + sessions.map { toNumber($0["activeAt"]) })
        let email = emails.get(account) ?? .null
        let orgName = orgs.get(org) ?? .null
        let taskFile = Value(path.join(dir.description, "scheduled-tasks.json"))
        var scheduled = Value.newSet()
        var taskError: Value = .null
        do { scheduled = try taskSessions(taskFile) } catch { taskError = errorObject(error)["message"] }
        let label = "\(email.nullish ? Value(short(account)) : email) · \(orgName.nullish ? Value(short(org)) : orgName)"
        var base = "0 | -"
        if !sessions.isEmpty {
            let names = try sessions.map { s -> Value in
                guard let cwd = s["cwd"].asString else { throw EngineError.type("The \"path\" argument must be of type string. Received \(s["cwd"].typeOf)") }
                return Value(path.basename(cwd))
            }
            base = "\(sessions.count) | \(try ago(Value(activeAt))) | \(try mode(names.value))"
        }
        let stats = "\(base)\(unreadable.isEmpty ? "" : " | \(unreadable.count) unreadable")\(taskError.truthy ? " | task registry unreadable" : "")"
        let sessionsValue = sessions.value
        out.append([
            "account": account, "org": org, "dir": dir, "email": email, "orgName": orgName, "sessions": sessionsValue, "allSessions": sessionsValue,
            "unreadable": unreadable.value, "taskFile": taskFile, "taskSessions": scheduled, "taskError": taskError, "activeAt": Value(activeAt),
            "focusedAt": Value(nanMax([0] + sessions.map { toNumber($0["focusedAt"]) })), "label": Value(label), "stats": Value(stats), "active": false,
            "signedIn": try sameLogin(["account": account], cur), "identityState": cur["state"],
        ])
    }
    let sessions = out.flatMap { $0["sessions"].elements }
    var claims: [HashKey: Int] = [:]
    for session in sessions { for id in unique([session["id"]] + (try priorSessions(session["record"])).elements) { claims[HashKey(id), default: 0] += 1 } }
    let parents = ValueSet(sessions.map { $0["record"]["forkedFromSessionId"] })
    let tasks: ValueSet? = out.contains { $0["taskError"].truthy } ? nil
        : ValueSet(out.flatMap { ($0["taskSessions"]["registry"]["scheduledTasks"] ?? Value.newArray()).elements.map { $0["id"] } })
    for session in sessions {
        let record = session["record"]
        Value.assign(session, [
            "shared": Value((claims[HashKey(session["id"])] ?? 0) > 1 || parents.has(record["sessionId"])),
            "deletedTask": Value(tasks != nil && record["scheduledTaskId"].isString && !tasks!.has(record["scheduledTaskId"])),
        ])
    }
    // Desktop keeps a folder for every account/org pair it has signed in with, and personal orgs share one name.
    let labels = Dictionary(grouping: out, by: { $0["label"].description })
    for rows in labels.values where rows.count > 1 { for row in rows { Value.assign(row, ["label": Value("\(row["label"]) · \(short(row["org"]))")]) } }
    let mine = out.filter { $0["account"] === cur["account"] }
    if let chosen = mine.first(where: { $0["org"] === cur["org"] }) { Value.assign(chosen, ["active": true, "stats": Value("\(chosen["stats"]) | active")]) }
    return stableSorted(out) { a, b in
        let d = toNumber(b["activeAt"]) - toNumber(a["activeAt"])
        return d.isNaN ? 0 : d
    }.value
}

// While Desktop switches logins it briefly pairs the incoming account with the previous login's org and leaves an
// empty folder for that pair in both session trees. Only folders with no sessions and no scheduled tasks qualify.
func holdsNothing(_ dir: String) -> Bool {
    let names: [String]
    do { names = try fs.names(dir) } catch { return errorObject(error).code === "ENOENT" }
    for name in names {
        guard name == "scheduled-tasks.json", let registry = try? fs.readJSON(path.join(dir, name)),
              case .array(let tasks) = registry["scheduledTasks"], tasks.items.isEmpty else { return false }
    }
    return true
}

public func leftovers(_ paths: Value = .undefined, _ all: Value = .undefined) throws -> Value { try leftovers(DataLayout(paths), all) }
func leftovers(_ paths: DataLayout, _ all: Value = .undefined) throws -> Value {
    let rows = all.elements
    let holders = Dictionary(grouping: rows, by: { $0["org"].description })
    var found: [Value] = []
    for row in rows {
        let account = row["account"].description, org = row["org"].description
        if row["active"].truthy || row["orgName"] !== "Personal" || row["sessions"].length > 0 || row["unreadable"].length > 0 { continue }
        if (holders[org]?.count ?? 0) < 2 || !rows.contains(where: { $0["account"] === row["account"] && $0["org"] !== row["org"] }) { continue }
        if holdsNothing(path.join(paths.records, account, org)) && holdsNothing(path.join(paths.agentSessions, account, org)) { found.append(row) }
    }
    return Value(found.filter { row in holders[row["org"].description]!.contains { other in !found.contains { $0 === other } } })
}

// Without a pair, sets aside the leftovers above; with one, sets aside that account/org if it holds nothing.
public func tidy(_ paths: Value = .undefined, _ pair: Value = .null) throws -> Value { try tidy(DataLayout(paths), pair) }
func tidy(_ paths: DataLayout, _ pair: Value = .null) throws -> Value {
    let latest = try latestReceipt(paths)
    if latest.truthy {
        let unfinished = try latest.corrupt.truthy || needsRecovery(latest.receipt).truthy || deferredWorkflow(paths, latest).truthy
        if unfinished { throw EngineError("Finish or undo the last move before tidying", code: "MOVE_UNFINISHED") }
    }
    let all = try accounts(paths)
    let dest = path.join(paths.state, "leftovers", stamp())
    var rows = try leftovers(paths, all).elements
    if pair.truthy {
        guard let row = all.elements.first(where: { $0["account"] === pair["account"] && $0["org"] === pair["org"] }) else { throw EngineError("No such account", code: "NO_ACCOUNT") }
        if row["active"].truthy { throw EngineError("Claude is signed in to \(row["label"])", code: "ACCOUNT_ACTIVE") }
        if row["sessions"].length > 0 || row["unreadable"].length > 0 { throw EngineError("\(row["label"]) still holds sessions", code: "ACCOUNT_NOT_EMPTY") }
        let dirs = [Value(paths.records), Value(paths.agentSessions)].map { path.join($0.description, row["account"].description, row["org"].description) }
        if !dirs.allSatisfy(holdsNothing) { throw EngineError("\(row["label"]) still holds scheduled tasks or other files", code: "ACCOUNT_NOT_EMPTY") }
        rows = [row]
    }
    let claude = path.dirname(paths.records)
    // A session moved to another account keeps working in the scratch folder it started in.
    let working = all.elements.flatMap { row in row["sessions"].elements.flatMap { [$0["cwd"], $0["record"]["originCwd"]] } }
        .compactMap { $0.asString }.filter { !$0.isEmpty }
    var moved: [Value] = []
    for row in rows {
        let account = row["account"].description, org = row["org"].description
        let dirs = [("claude-code-sessions", Value(paths.records)), ("local-agent-mode-sessions", Value(paths.agentSessions))].map { ($0.0, path.join($0.1.description, account, org)) }
        if !dirs.allSatisfy({ holdsNothing($0.1) }) { continue }
        let scratch = path.join(claude, "scratch-workspaces", account, org)
        let scratchKept = working.contains { $0 == scratch || $0.hasPrefix(scratch + path.sep) } && fs.exists(scratch)
        let caches = [("plugin-list", path.join(claude, "plugin-list", account, org)), ("skills-plugin", path.join(paths.agentSessions, "skills-plugin", org, account))]
        for (tree, dir) in dirs + caches + (scratchKept ? [] : [("scratch-workspaces", scratch)]) where fs.exists(dir) {
            let parent = path.basename(path.dirname(dir))
            try fs.mkdirp(path.join(dest, tree, parent))
            try fs.rename(dir, path.join(dest, tree, parent, path.basename(dir)))
        }
        var entry: Value = ["account": row["account"], "org": row["org"], "label": row["label"]]
        if scratchKept { entry = Value.spread(entry, ["scratchKept": .string(scratch)]) }
        moved.append(entry)
    }
    return ["ok": true, "moved": Value(moved), "dest": moved.isEmpty ? .null : .string(dest)]
}
