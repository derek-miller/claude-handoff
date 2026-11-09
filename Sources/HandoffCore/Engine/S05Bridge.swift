import CryptoKit
import Darwin
import Foundation

// engine.js lines 2347-2900: bridge metadata appends and recovery, rehoming, failure projection, verification.

// MARK: - Section-local helpers

// Opaque Swift objects (file handles, running hashes) carried through Values. The box is a function that, when called,
// deposits its object in a slot; JSON.stringify drops functions, so these never leak into written JSON.
fileprivate var unboxSlot: AnyObject?
fileprivate func boxed(_ object: AnyObject) -> Value { Value { _ in unboxSlot = object; return .undefined } }
fileprivate func unboxed<T: AnyObject>(_ v: Value, _ type: T.Type) throws -> T {
    unboxSlot = nil
    defer { unboxSlot = nil }
    if v.isFunction { _ = try v.call() }
    guard let object = unboxSlot as? T else { throw JSError.type("\(v.typeOf) is not a \(T.self)") }
    return object
}

// createHash('sha256') with .copy(); CryptoKit's SHA256 is a value type, so copying the struct copies the state.
fileprivate final class RunningHash {
    var hasher = SHA256()
    init() {}
    init(_ hasher: SHA256) { self.hasher = hasher }
    func copy() -> RunningHash { RunningHash(hasher) }
    @discardableResult func update(_ data: Data) -> RunningHash { hasher.update(data: data); return self }
    @discardableResult func update(_ text: String) -> RunningHash { update(Data(text.utf8)) }
    func digest() -> String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
}

fileprivate func handleOf(_ v: Value) throws -> FileHandle { try unboxed(v, FileHandle.self) }
fileprivate func hashOf(_ v: Value) throws -> RunningHash { try unboxed(v, RunningHash.self) }

fileprivate func str(_ v: Value) -> String { v.description }
fileprivate func isFileStat(_ st: Value) throws -> Bool { try st["isFile"].call().truthy }
// Buffer.byteLength(string)
fileprivate func byteLength(_ v: Value) -> Double { Double(v.description.utf8.count) }
// Math.max / Math.min with NaN propagation.
fileprivate func jsMax(_ a: Double, _ b: Double) -> Double { a.isNaN || b.isNaN ? .nan : Swift.max(a, b) }
fileprivate func jsMin(_ a: Double, _ b: Double) -> Double { a.isNaN || b.isNaN ? .nan : Swift.min(a, b) }
// Buffer#subarray(start, end) index semantics.
fileprivate func subarray(_ data: Data, _ start: Double, _ end: Double? = nil) -> Data {
    let n = data.count
    func rel(_ x: Double) -> Int {
        if x.isNaN { return 0 }
        if x < 0 { return x == -.infinity ? 0 : Swift.max(n + Int(x.rounded(.towardZero)), 0) }
        return x == .infinity ? n : Swift.min(Int(x.rounded(.towardZero)), n)
    }
    let s = rel(start), e = end.map(rel) ?? n
    if e <= s { return Data() }
    let base = data.startIndex
    return Data(data[(base + s)..<(base + e)])
}
// JS regexps here use `$` without the m flag (end of input only), so ICU patterns use \z.
fileprivate let DIGITS = re(#"^[0-9]+\z"#)
fileprivate let SIGNED = re(#"^-?[0-9]+\z"#)
fileprivate let HEX64 = re(#"^[a-f0-9]{64}\z"#)
// node:path throws TypeError for non-string arguments.
fileprivate func strictJoin(_ parts: [Value]) throws -> String {
    for part in parts where !part.isString {
        throw JSError.type("The \"path\" argument must be of type string. Received \(part.typeOf == "object" && part.isNull ? "null" : part.typeOf)")
    }
    return path.join(parts.map { $0.description })
}
// Map.groupBy(items, key) → JSMap of arrays.
fileprivate func groupBy(_ items: [Value], _ key: (Value) throws -> Value) rethrows -> JSMap {
    let groups = JSMap()
    for item in items {
        let k = try key(item)
        let existing = groups.get(k)
        if case .array(let a) = existing { a.items.append(item) } else { groups.set(k, Value([item])) }
    }
    return groups
}
// try { body() } finally { cleanup() } — a cleanup error replaces the body's outcome, as in JS.
fileprivate func withFinally(_ body: () throws -> Value, _ cleanup: () throws -> Void) throws -> Value {
    let result: Result<Value, Error>
    do { result = .success(try body()) } catch { result = .failure(error) }
    try cleanup()
    return try result.get()
}

// MARK: - Bridge metadata

// L2347
func bridgeClear(_ sessionId: Value = .undefined) throws -> Value {
    ["type": "bridge-session", "sessionId": sessionId, "bridgeSessionId": "", "lastSequenceNum": 0]
}
// L2348
func bridgeError(_ text: Value = .undefined) throws -> Value {
    jsThrow("Local bridge metadata: \(text)", code: "BRIDGE_RECOVERY").value
}
fileprivate func bridgeFailure(_ text: String) throws -> JSError { JSError(try bridgeError(Value(text))) }
// L2349
func bridgeEntry(_ entry: Value = .undefined, _ sessionId: Value = .undefined) throws -> Value {
    Value(entry.truthy && entry.typeOf == "object" && !entry.isArray &&
        entry["type"] === "bridge-session" && entry.sessionId === sessionId && (entry.bridgeSessionId ?? entry.bridge_session_id).isString)
}

// L2352
func bridgePlans(_ row: Value = .undefined, _ aliases: Value = .undefined) throws -> Value {
    let aliases = aliases.isUndefined ? Value.newArray() : aliases
    if row.bridgeAppend.nullish && row.bridgeUndo.nullish { return .newArray() }
    let id = row.targetId ?? row.id
    let plans = Value([row.bridgeAppend] + (row.bridgeUndo.nullish ? [] : [row.bridgeUndo]))
    for (index, plan) in plans.elements.enumerated() {
        let invalid = { () throws -> Never in throw try bridgeFailure("invalid bridge recovery receipt") }
        if try !UUID.test((id ?? "").description) || !plan.truthy || plan.typeOf != "object" || plan.isArray || plan.sessionId !== id ||
            !(try bridgeEntry(plan.original, id)).truthy || !(plan.original.bridgeSessionId ?? plan.original.bridge_session_id).truthy { try invalid() }
        let made0 = row.made[0]
        let recordId = row.targetRecordId ?? row.recordSnapshot.sessionId ?? row.recordId ??
            (made0.truthy ? Value(path.basename(made0.description, ".json")) : .null)
        let recordIds = plan.recordIds
        if !recordIds.isArray || recordIds.length == 0 || recordIds.elements.contains(where: { !$0.isString || !LOCAL_RECORD.test($0.description) }) ||
            JSSet(recordIds.elements).size != recordIds.length || ([recordId] + aliases.elements).contains(where: { $0.truthy && !recordIds.includes($0) }) { try invalid() }
        if ["transcript", "canonical"].contains(where: { key in !plan[key].isString || !path.isAbsolute(plan[key].description) || path.basename(plan[key].description) != "\(id).jsonl" }) ||
            ["dev", "ino"].contains(where: { key in !plan[key].isString || !DIGITS.test(plan[key].description) }) ||
            !isSafeInteger(plan["length"]) || jsNumber(plan["length"]) < 0 ||
            ["sha", "afterSha"].contains(where: { key in !plan[key].isString || !HEX64.test(plan[key].description) }) { try invalid() }
        let signature: [String] = plan.fingerprint.isString ? plan.fingerprint.description.jsSplit(":") : []
        if signature.count != 5 || signature[0..<3].joined(separator: ":") != "\(plan.dev):\(plan.ino):\(plan["length"])" ||
            signature[3...].contains(where: { !SIGNED.test($0) }) { try invalid() }
        let bytes = jsonText(index != 0 ? plans[0].original : try bridgeClear(id), 0)
        if plan["bytes"] !== Value(bytes) && plan["bytes"] !== Value("\n\(bytes)") || !isSafeInteger(Value(jsNumber(plan["length"]) + byteLength(plan["bytes"]))) { try invalid() }
        if (row.targetTranscript ?? row.transcript ?? plan.transcript) !== plan.transcript || index != 0 &&
            (["transcript", "canonical", "dev", "ino"].contains(where: { plan[$0] !== plans[0][$0] }) || stable(plan.recordIds) != stable(plans[0].recordIds) ||
             stable(plan.original) != stable(plans[0].original) || jsNumber(plan["length"]) < jsNumber(plans[0]["length"]) + byteLength(plans[0]["bytes"])) { try invalid() }
        if !plan.continuation.nullish {
            let continuation = plan.continuation, offset = jsNumber(continuation["length"]) - jsNumber(plan["length"])
            if !isSafeInteger(Value(offset)) || offset < 0 || offset >= byteLength(plan["bytes"]) ||
                !continuation.sha.isString || !HEX64.test(continuation.sha.description) ||
                continuation["bytes"] !== Value(subarray(Data(plan["bytes"].description.utf8), offset).base64EncodedString()) ||
                !continuation.fingerprint.isString ||
                !re("^\(plan.dev):\(plan.ino):\(continuation["length"]):-?[0-9]+:-?[0-9]+\\z").test(continuation.fingerprint.description) { try invalid() }
        }
    }
    return plans
}

// L2384
func bridgeFile(_ plan: Value = .undefined, _ writable: Value = .undefined, _ work: Value = .undefined) throws -> Value {
    if try mappedPath(plan.transcript) !== plan.canonical || Value(try fs.realpath(str(plan.canonical))) !== plan.canonical { throw try bridgeFailure("transcript path changed") }
    let before = try fs.lstat(str(plan.canonical), bigint: true)
    if !(try isFileStat(before)) || plan.dev !== Value(before.dev.description) || plan.ino !== Value(before.ino.description) { throw try bridgeFailure("transcript identity changed") }
    let flags: Int32 = (writable.truthy ? O_RDWR | O_APPEND : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK
    let handle = try fs.open(str(plan.canonical), flags, 0o666)
    let boxedHandle = boxed(handle)
    return try withFinally({
        _ = try bridgeStable(plan, boxedHandle, try statIdentity(before))
        return try work.call(boxedHandle)
    }, { try handle.close() })
}

// L2395
func bridgeStable(_ plan: Value = .undefined, _ handle: Value = .undefined, _ signature: Value = .undefined, _ inspect: Value = .undefined) throws -> Value {
    if inspect.truthy {
        let live = try workers(try inspect.call())
        for recordId in (plan.recordIds ?? [.null]).elements where try ownsWorker(live, plan.sessionId, recordId).truthy { throw try bridgeFailure("running worker") }
    }
    let current = try handleOf(handle).stat(bigint: true)
    let named = try fs.lstat(str(plan.canonical), bigint: true)
    if try !isFileStat(current) || !isFileStat(named) || statIdentity(current) !== signature || statIdentity(named) !== signature ||
        Value(current.dev.description) !== plan.dev || Value(current.ino.description) !== plan.ino ||
        mappedPath(plan.transcript) !== plan.canonical || Value(fs.realpath(str(plan.canonical))) !== plan.canonical { throw try bridgeFailure("transcript changed") }
    return .undefined
}

// L2407
func bridgeRead(_ plan: Value = .undefined, _ handle: Value = .undefined, _ parse: Value = .undefined) throws -> Value {
    let parse = parse.isUndefined ? Value(true) : parse
    let file = try handleOf(handle)
    let detail = try file.stat(bigint: true), size = jsNumber(detail["size"]), signature = try statIdentity(detail)
    if !isSafeInteger(Value(size)) { throw try bridgeFailure("transcript size is unsupported") }
    let memory = try operationMemory()
    let hash = RunningHash(), prefix = RunningHash()
    var tail = Data()
    let bufferLength = 64.0 * 1024, limit = byteLength(plan["bytes"] ?? "")
    let planLength = jsNumber(plan["length"])
    var parts: [Data] = [], length = 0, last: Value = .null, prefixLast: Value = .null, invalid = false, newline = false
    func consume(_ end: Double) throws {
        _ = try memory.check.call(Value(Double(length * 4)))
        var joined = Data(capacity: length)
        for part in parts { joined.append(part) }
        let text = String(decoding: joined, as: UTF8.self).jsTrim
        parts = []; length = 0
        if text.isEmpty { return }
        do {
            let entry = try JSON.parse(text)
            if entry["type"] === "bridge-session" && entry.sessionId === plan.sessionId {
                last = entry
                if end <= planLength { prefixLast = entry }
            }
        } catch { invalid = true }
    }
    var at = 0.0
    while at < size {
        let chunk = try file.read(length: Int(jsMin(bufferLength, size - at)), position: Int64(at))
        let bytesRead = chunk.count
        if bytesRead == 0 { throw try bridgeFailure("transcript changed while reading") }
        productive()
        _ = try memory.check.call(Value(Double(bytesRead)))
        hash.update(chunk)
        if at < planLength { prefix.update(subarray(chunk, 0, jsMin(Double(bytesRead), planLength - at))) }
        let startTail = jsMax(0, planLength - at), endTail = jsMin(Double(bytesRead), planLength + limit - at)
        if endTail > startTail { tail.append(subarray(chunk, startTail, endTail)) }
        if parse.truthy {
            var start = 0
            let base = chunk.startIndex
            var end = chunk.firstIndex(of: 10).map { $0 - base } ?? -1
            while end >= 0 {
                parts.append(Data(chunk[(base + start)..<(base + end)])); length += end - start
                try consume(at + Double(end))
                start = end + 1
                end = chunk[(base + start)...].firstIndex(of: 10).map { $0 - base } ?? -1
            }
            if start < bytesRead { parts.append(Data(chunk[(base + start)...])); length += bytesRead - start }
        }
        newline = chunk.last == 10
        at += Double(bytesRead)
    }
    if length != 0 { try consume(size) }
    _ = try bridgeStable(plan, handle, signature)
    let o = JSObject()
    o["length"] = Value(size)
    o["fingerprint"] = signature
    o["sha"] = Value(hash.copy().digest())
    o["hash"] = boxed(hash)
    o["prefixHash"] = boxed(prefix.copy())
    o["intendedSha"] = Value(prefix.copy().update((plan["bytes"] ?? "").description).digest())
    o["prefixSha"] = Value(prefix.digest())
    o["prefixLast"] = prefixLast
    o["tail"] = Value(tail)
    o["last"] = last
    o["invalid"] = Value(invalid)
    o["newline"] = Value(newline)
    return .object(o)
}

// L2455
func bridgePlan(_ base: Value = .undefined, _ state: Value = .undefined, _ entry: Value = .undefined) throws -> Value {
    if !(try bridgeEntry(entry, base.sessionId)).truthy { throw try bridgeFailure("invalid bridge metadata entry") }
    let bytes = "\(state["length"].truthy && !state.newline.truthy ? "\n" : "")\(JSON.text(entry))\n"
    return Value.spread(try without(base, .strings(["continuation"])), [
        "length": state["length"], "sha": state.sha, "fingerprint": state.fingerprint, "bytes": Value(bytes),
        "afterSha": Value(try hashOf(state["hash"]).copy().update(bytes).digest())
    ])
}

// L2462
func bridgeSource(_ s: Value = .undefined, _ to: Value = .undefined, _ `guard`: Value = .undefined) throws -> Value {
    let canonical = try mappedPath(s.transcript), detail = try fs.lstat(str(canonical), bigint: true)
    let records = try ([s] + `guard`.sources.elements + `guard`.targets.elements).filter { $0.id === s.id }.map { try desktopRecordOf($0) }
    let recordIds = Value(defaultSorted(unique(records.map { $0.sessionId })))
    let base: Value = ["transcript": s.transcript, "canonical": canonical, "sessionId": s.id, "recordIds": recordIds,
                       "dev": Value(detail.dev.description), "ino": Value(detail.ino.description)]
    return try bridgeFile(base, false, Value { args in
        let handle = args.first ?? .undefined
        let state = try bridgeRead(base, handle, Value(s.bridge !== false && s.contentSha !== s.bridgeAppend.afterSha))
        if state.fingerprint !== s.transcriptFingerprint || s.contentSha.truthy && state.sha !== s.contentSha { throw JSError("source changed since inventory") }
        let last = state["last"]
        let pointer = last.bridgeSessionId ?? last.bridge_session_id
        let destinationOwned = last.ownerAccountUuid === to.account && last.ownerOrganizationUuid === to.org
        let mirror = records.contains(where: { record in record.sshConfig.truthy || record.sshRemoteTranscriptPath.isString && record.sshRemoteTranscriptPath !== "" }) ||
            [s.transcript, canonical].contains(where: { file in path.basename(path.dirname(file.description)) == "ssh-\(s.id)" })
        let append: Value = pointer.isString && pointer.truthy && !state.invalid.truthy && !destinationOwned && !mirror
            ? Value.spread(try bridgePlan(base, state, try bridgeClear(s.id)), ["original": last]) : .null
        if append.truthy { _ = try bridgePlans(["id": s.id, "recordId": s.record.sessionId, "transcript": s.transcript, "bridgeAppend": append]) }
        return ["fingerprint": state.fingerprint, "append": append]
    })
}

// L2481
func appendBridge(_ plan: Value = .undefined, _ inspect: Value = .undefined, _ recovering: Value = .undefined, _ save: Value = .undefined) throws -> Value {
    let recovering = recovering.isUndefined ? Value(false) : recovering
    let save = save.isUndefined ? Value.null : save
    var attempted = false
    do {
        return try bridgeFile(plan, true, Value { args in
            let handle = args.first ?? .undefined
            let state = try bridgeRead(plan, handle, false), bytes = Data(plan["bytes"].description.utf8)
            let extra = jsNumber(state["length"]) - jsNumber(plan["length"])
            if recovering.truthy {
                if !(try bridgeWitness(plan, state)).truthy { throw try bridgeFailure("append recovery witness changed") }
                if extra >= Double(bytes.count) { return state }
                plan.continuation = ["length": state["length"], "sha": state.sha, "fingerprint": state.fingerprint,
                                     "bytes": Value(subarray(bytes, extra).base64EncodedString())]
                _ = try save.call()
            }
            if !recovering.truthy && (state["length"] !== plan["length"] || state.sha !== plan.sha || state.fingerprint !== plan.fingerprint) { throw try bridgeFailure("source changed before append") }
            _ = try bridgeStable(plan, handle, state.fingerprint, inspect)
            attempted = true
            let file = try handleOf(handle)
            try file.writeFile(recovering.truthy ? subarray(bytes, extra) : bytes)
            try file.sync()
            let after = try bridgeRead(plan, handle, false)
            if after["length"] !== Value(jsNumber(plan["length"]) + byteLength(plan["bytes"])) || after.sha !== plan.afterSha ||
                after.prefixSha !== plan.sha || after.tail.asData != Data(plan["bytes"].description.utf8) { throw try bridgeFailure("unexpected content after append") }
            _ = try bridgeStable(plan, handle, after.fingerprint, inspect)
            return after
        })
    } catch {
        let value = jsErrorValue(error)
        value.bridgeUntouched = Value(!attempted)
        throw JSError(value)
    }
}

// L2505
func bridgeWitness(_ plan: Value = .undefined, _ state: Value = .undefined) throws -> Value {
    let bytes = Data(plan["bytes"].description.utf8), extra = jsNumber(state["length"]) - jsNumber(plan["length"])
    if state.prefixSha === plan.sha {
        var broken = state.intendedSha !== plan.afterSha
        if !broken && plan.continuation.truthy {
            let witness = try hashOf(state.prefixHash).copy()
                .update(subarray(bytes, 0, jsNumber(plan.continuation["length"]) - jsNumber(plan["length"]))).digest()
            broken = Value(witness) !== plan.continuation.sha
        }
        if broken { throw try bridgeFailure("invalid bridge recovery receipt witness") }
    }
    return Value(extra >= 0 && state.prefixSha === plan.sha && state.tail.asData == subarray(bytes, 0, extra))
}

// L2512
func bridgeRecovery(_ row: Value = .undefined, _ optional: Value = .undefined, _ aliases: Value = .undefined) throws -> Value {
    let optional = optional.isUndefined ? Value(false) : optional
    let aliases = aliases.isUndefined ? Value.newArray() : aliases
    let plans = try bridgePlans(row, aliases), plan = plans[0]
    if !plan.truthy { return .null }
    let state: Value
    do { state = try bridgeFile(plan, false, Value { args in try bridgeRead(plan, args.first ?? .undefined) }) }
    catch { if optional.truthy && !row.bridgeUndo.truthy { return .null }; throw error }
    if state.prefixSha === plan.sha && stable(state.prefixLast) != stable(plan.original) { throw try bridgeFailure("invalid original bridge witness") }
    let witnessed = try bridgeWitness(plan, state), extra = jsNumber(state["length"]) - jsNumber(plan["length"])
    if !witnessed.truthy {
        if optional.truthy && !row.bridgeUndo.truthy { return .null }
        throw try bridgeFailure("transcript restoration witness changed")
    }
    if row.bridgeUndo.truthy {
        if extra < byteLength(plan["bytes"]) { throw try bridgeFailure("transcript restoration witness changed") }
        let undo = row.bridgeUndo
        let restored = try bridgeFile(undo, false, Value { args in try bridgeRead(undo, args.first ?? .undefined, false) })
        if !(try bridgeWitness(row.bridgeUndo, restored)).truthy { throw try bridgeFailure("transcript restoration witness changed") }
        return ["plan": plan, "state": state, "restoring": true]
    }
    if extra == 0 { return .null }
    if try extra >= byteLength(plan["bytes"]) && (state.invalid.truthy || stable(state["last"]) != stable(try bridgeClear(plan.sessionId))) {
        if optional.truthy { return .null }
        throw try bridgeFailure("transcript restoration witness changed")
    }
    return ["plan": plan, "state": state, "partial": Value(extra < byteLength(plan["bytes"]))]
}

// L2538
func restoreBridge(_ row: Value = .undefined, _ save: Value = .undefined, _ inspect: Value = .undefined, _ optional: Value = .undefined, _ allowLater: Value = .undefined) throws -> Value {
    let optional = optional.isUndefined ? Value(false) : optional
    let allowLater = allowLater.isUndefined ? Value(true) : allowLater
    let recovery = try bridgeRecovery(row, optional)
    if !recovery.truthy { return .undefined }
    let plan = recovery.plan, partial = recovery.partial, restoring = recovery.restoring
    if restoring.truthy { return try appendBridge(row.bridgeUndo, inspect, true, save) }
    if !allowLater.truthy && jsNumber(recovery.state["length"]) > jsNumber(plan["length"]) + byteLength(plan["bytes"]) { throw try bridgeFailure("newer transcript content prevents bridge restoration") }
    if partial.truthy { _ = try appendBridge(plan, inspect, true, save) }
    let ready = try bridgeRecovery(row, optional)
    if !ready.truthy { return .undefined }
    row.bridgeUndo = try bridgePlan(plan, ready.state, plan.original)
    _ = try save.call()
    _ = try appendBridge(row.bridgeUndo, inspect)
    return .undefined
}

// L2552
func bridgeProblems(_ rows: Value = .undefined, _ optional: Value = .undefined) throws -> Value {
    let optional = optional.isUndefined ? Value(false) : optional
    let problems = Value.newArray()
    let related = groupBy(rows.elements) { $0.targetId ?? $0.id }
    for row in rows.elements {
        do {
            let aliases = related.get(row.targetId ?? row.id).elements.map { $0.targetRecordId ?? $0.recordSnapshot.sessionId }
            _ = try bridgeRecovery(row, optional, Value(aliases))
        } catch { problems.push(Value("\(row.title) | \(jsErrorValue(error)["message"])")) }
    }
    return problems
}

// L2563
func bridgeIntact(_ row: Value = .undefined) throws -> Value {
    if !row.bridgeAppend.truthy { return true }
    let plan = row.bridgeAppend
    do {
        return try bridgeFile(plan, false, Value { args in
            let state = try bridgeRead(plan, args.first ?? .undefined, false)
            return Value(state.prefixSha === plan.sha && state.tail.asData == Data(plan["bytes"].description.utf8))
        })
    } catch { return false }
}

// MARK: - Rehome

// L2572
func rehomeOne(_ s: Value = .undefined, _ to: Value = .undefined, _ journal: Value = .undefined, _ `guard`: Value = .undefined) throws -> Value {
    let source = try bridgeSource(s, to, `guard`)
    let transcriptFingerprint = source.fingerprint, append = source.append
    let sidecarRoot = path.join(path.dirname(str(s.transcript)), str(s.id))
    let sidecarTree = try treeFingerprint(Value(sidecarRoot))
    if try !s.sidecar.fingerprint.truthy || !(try sameTree(s.sidecar, sidecarTree)).truthy { throw JSError("source sidecars changed since inventory") }
    let sourceSidecars = Value.spread(s.sidecar, ["fingerprint": sidecarTree.fingerprint, "canonicalRoot": sidecarTree.canonicalRoot])
    let sourceRecord = try readFile(s.file, "utf8")
    let current = try JSON.parse(sourceRecord.description)
    if try current.cliSessionId !== s.id || !(try validDesktopRecord(["file": s.file, "record": current])).truthy { throw JSError("source Desktop record changed identity") }
    if try recordSemantic(current) !== s.recordSemantic { throw JSError("source Desktop record changed since inventory") }
    if current.forkedFromSessionId !== s.record.forkedFromSessionId { throw JSError("source Desktop lineage changed since inventory") }
    let taskSessionsMap = `guard`.taskSessions
    if !s.taskFamily.truthy {
        var owned = current.notifySessionId.truthy
        if !owned && current.scheduledTaskId.truthy {
            if !s.coldRun.truthy { owned = true } else {
                let owners = Value([s.account.taskFile, to.taskFile].map { file -> Value in ["taskSessions": taskSessionsMap.get(file)] })
                owned = try coldBlocked(current, owners).truthy
            }
        }
        if owned { throw JSError("source Desktop ownership changed since inventory") }
    }
    let sourceTasks = taskSessionsMap.get(s.account.taskFile)
    if sourceTasks.nullish { throw JSError.type("Cannot read properties of \(sourceTasks) (reading 'has')") }
    if sourceTasks.has(current.sessionId) { throw JSError("source scheduled task ownership changed since inventory") }
    let targetTasks = taskSessionsMap.get(to.taskFile).registry.scheduledTasks ?? .newArray()
    if targetTasks.elements.contains(where: { task in
        task.notifySessionId === current.sessionId &&
            !s.taskFamily.replaced.elements.contains(where: { row in stable(row.task) == stable(task) })
    }) { throw JSError("target scheduled task collision") }
    if try ownsWorker(`guard`.workers, s.id, current.sessionId).truthy { throw JSError("running worker") }
    let title = or(or(Value((current.title ?? "").description.jsTrim), s.title), "Untitled")
    let record = path.join(str(to.dir), path.basename(str(s.file)))
    let sourceRecordSha = sha(sourceRecord)
    let placed = Value.spread(try without(current, .strings(ACCOUNT_ERROR_KEYS)), ["bridgeSessionIds": .newArray()])
    let recordText = jsonText(placed)
    let recordSha = sha(recordText)
    _ = try journal.call(["strategy": "rehome", "recordSha": Value(recordSha)])
    if `guard`.check.isFunction { _ = try `guard`.check.call() }
    _ = try writeNew(Value(record), Value(recordText), Value { args in
        let made = args.first ?? .undefined
        let dev = made.dev, ino = made.ino
        `guard`.created.put(Value(record), ["dev": dev, "ino": ino])
        _ = try journal.call(["created": ["dev": dev, "ino": ino]])
        return .undefined
    })
    let afterTranscriptFingerprint = try fingerprint(s.transcript)
    let afterRecord = try readFile(s.file, "utf8")
    let afterSidecars = try treeFingerprint(Value(sidecarRoot))
    if afterTranscriptFingerprint !== transcriptFingerprint { throw JSError("source changed during move") }
    if sha(afterRecord) != sourceRecordSha { throw JSError("source Desktop record changed during move") }
    if !(try sameTree(sourceSidecars, afterSidecars)).truthy { throw JSError("source sidecars changed during move") }
    if `guard`.check.isFunction { _ = try `guard`.check.call() }
    var placedFingerprint = transcriptFingerprint
    if append.truthy {
        _ = try journal.call(["bridgeAppend": append], true)
        let after: Value
        do { after = try appendBridge(append, `guard`.inspect) }
        catch {
            if jsErrorValue(error).bridgeUntouched.truthy { _ = try journal.call(["bridgeAppend": .null], true) }
            throw error
        }
        placedFingerprint = after.fingerprint
        append.applied = true
        _ = try journal.call(["bridgeAppend": append], true)
        let sourceSha = s.contentSha
        for member in `guard`.sources.elements where member.transcript === s.transcript && member.contentSha === sourceSha && member.transcriptFingerprint === transcriptFingerprint {
            member.contentSha = after.sha
            member.transcriptFingerprint = placedFingerprint
            member.bridgeAppend = append
        }
    }
    for member in (s.members ?? [s]).elements {
        member.strategy = "rehome"
        member.transcriptFingerprint = placedFingerprint
        member.sidecar = Value.spread(member.sidecar, ["fingerprint": sourceSidecars.fingerprint])
    }
    let o = JSObject()
    o["strategy"] = "rehome"
    o["id"] = s.id
    o["targetId"] = s.id
    o["title"] = title
    o["archived"] = Value(current.isArchived === true)
    o["transcript"] = s.transcript
    o["targetTranscript"] = s.transcript
    o["targetDir"] = sourceSidecars["count"].truthy ? Value(path.join(path.dirname(str(s.transcript)), str(s.id))) : .null
    o["record"] = Value(record)
    o["recordSha"] = Value(recordSha)
    o["recordSnapshot"] = recordSnapshot(placed)
    o["recordSemantic"] = try recordSemantic(placed)
    o["targetRecordId"] = current.sessionId
    o["taskFile"] = to.taskFile
    o["taskOwned"] = false
    if s.taskFamily.truthy { o["taskFamily"] = s.taskFamily.key }
    o["transcriptFingerprint"] = placedFingerprint
    if append.truthy { o["bridgeAppend"] = append }
    o["sidecars"] = ["count": sourceSidecars["count"], "bytes": sourceSidecars["bytes"], "fingerprint": sourceSidecars.fingerprint, "canonicalRoot": sourceSidecars.canonicalRoot]
    o["events"] = s.roots["size"]
    return .object(o)
}

// MARK: - Ownership and failures

// L2657
func knownOf(_ row: Value = .undefined) throws -> Value {
    ["semantic": row.targetSemantic, "semanticVersion": row.targetSemanticVersion]
}
// L2661
func artifacts(_ row: Value = .undefined) throws -> Value {
    row.strategy === "rehome" ? [row.record] : [row.targetTranscript, row.targetDir, row.record].filter { $0.truthy }.value
}
// L2662
public func retiredCount(_ receipt: Value = .undefined) throws -> Value {
    Value((receipt.superseded ?? .newArray()).elements.filter { $0.source.truthy }.count)
}
// L2663
func retiredFiles(_ receipt: Value = .undefined) throws -> Value {
    .newSet((receipt.superseded ?? .newArray()).elements.filter { $0.source.truthy }.flatMap { row in row.moved.elements.map { $0[0] } })
}
// L2664
func ownership(_ row: Value = .undefined, _ liveWorkers: Value = .undefined, _ bridges: Value = .undefined) throws -> Value {
    let bridges = bridges.isUndefined ? Value(true) : bridges
    let record = try desktopRecordOf(row)
    let worker = try row.worker.truthy || ownsWorker(liveWorkers, row.id, record.sessionId).truthy
    let parts: [String?] = [
        bridges.truthy && record.bridgeSessionIds["length"].truthy ? "Remote Control bridge" : nil,
        bridges.truthy && row.bridge.truthy ? "transcript bridge" : nil,
        record.scheduledTaskId.truthy && !row.coldRun.truthy ? "scheduled task" : nil,
        record.notifySessionId.truthy ? "notification route" : nil,
        row.taskOwned.truthy ? "scheduled task registry" : nil,
        worker ? "running worker" : nil
    ]
    return Value(parts.compactMap { $0 }.joined(separator: ", "))
}
// L2675
func rehomeOwnership(_ row: Value = .undefined, _ liveWorkers: Value = .undefined) throws -> Value {
    if row.taskFamily.truthy && !row.taskFamily.error.truthy {
        return try row.worker.truthy || ownsWorker(liveWorkers, row.id, try desktopRecordOf(row).sessionId).truthy ? "running worker" : ""
    }
    return try ownership(row, liveWorkers, false)
}
// L2677
public func retirementOwnership(_ inv: Value = .undefined, _ row: Value = .undefined, _ owner: Value = .undefined, _ liveWorkers: Value = .undefined) throws -> Value {
    owner.history.strategy === "rehome" || inv.cloudRequested.truthy ? try rehomeOwnership(row, liveWorkers) : try ownership(row, liveWorkers)
}
// L2678
func sourceIdentity(_ row: Value = .undefined) throws -> Value {
    let rest: Value = ["label": try accountLabel(row.account), "id": row.id, "sessionId": row.record.sessionId, "file": row.file,
                       "title": row.title, "remoteIds": try remoteIdsOf(row)]
    return Value.spread(try accountRef(row.account), rest, row.recordSha.truthy ? ["recordSha": row.recordSha] : [:])
}
// L2680
func failureIdentity(_ item: Value = .undefined) throws -> Value {
    let rows = try (item.members ?? [item]).elements.filter { try $0.account.truthy && validDesktopRecord($0).truthy }
    return ["sources": Value(try rows.map { try sourceIdentity($0) })]
}
// L2681
func inventoryFailure(_ item: Value = .undefined) throws -> Value {
    let title: String
    if jsNumber(item.members["length"]) > 1 {
        title = item.members.elements.map { member in "\(member.account.label) | \(or(member.title, Value(path.basename(str(member.file)))))" }.joined(separator: " + ")
    } else {
        title = "\(item.account.label) | \(or(item.title, Value(path.basename(str(item.file)))))"
    }
    let head: Value = ["id": item.id ?? .null, "title": Value(title), "error": item.error ?? "unreadable Desktop record"]
    return Value.spread(head, item.code.truthy ? ["code": item.code] : [:], try failureIdentity(item))
}
// L2690
func taggedCloudFailure(_ cloud: Value = .undefined, _ failure: Value = .undefined) throws -> Value {
    Value.spread(failure, ["cloudAccount": cloud.account, "cloudOrg": cloud.org])
}
// L2691
func cloudTagged(_ row: Value = .undefined, _ cloud: Value = .undefined) throws -> Value {
    Value(row.cloudAccount === cloud.account && row.cloudOrg === cloud.org)
}
// L2692
public func inventoryFailures(_ inv: Value = .undefined) throws -> Value {
    let local = try (inv.unreadable.elements + inv.rejected.elements + (inv.blocked ?? .newArray()).elements).map { try inventoryFailure($0) }
    let cloud = try (inv.cloud.blocked ?? .newArray()).elements.map { try taggedCloudFailure(inv.cloud, try inventoryFailure($0)) }
    return Value(local + cloud)
}
// L2696
func localFailureKey(_ row: Value = .undefined) throws -> Value {
    Value("\(row.account)/\(row.org)/\(row.sessionId)")
}
// L2697
func failureCause(_ error: Value = .undefined) throws -> Value {
    let text = error.description
    if text.hasPrefix(TASK_FAMILY_BLOCKED) { return "waiting on task family" }
    if re("conflicting duplicate uuids|unparseable lines|history cannot be compared safely").test(text) { return "history check" }
    if error === Value(PARENT_MISSING) { return "waiting on parent" }
    if re("task.*(?:collision|differs|enabled|dependency|unreadable|record exists)").test(text) { return "task collision" }
    return "other"
}
// L2699
public func receiptSummary(_ receipt: Value = .undefined) throws -> Value {
    let failed = (receipt.failed ?? .newArray()).elements
    let local = failed.filter { !$0.cloudAccount.truthy }
    let byKey = JSMap()
    for row in local {
        for source in (row.sources ?? .newArray()).elements {
            let entry = Value.spread(source, ["error": row.error, "cause": try failureCause(row.error)])
            byKey.set(try localFailureKey(entry), entry)
        }
    }
    let notMoved = byKey.values
    let moved = receipt.finalizing.truthy ? receipt.appendCheckpoint.sessions ?? 0 : receipt.sessions["length"] ?? 0
    let groups = groupBy(notMoved) { $0.cause }.entries.map { pair -> Value in ["cause": pair.0, "records": pair.1] }
    let attention = try failed.filter { row in
        row.cloudAccount.truthy ? try actionableCloudFailure(receipt, row).truthy : !row.sources["length"].truthy
    }
    let keep = try keptCopy(receipt), failedArray = Value(failed)
    let kept = try failed.enumerated().filter { try keep.call($0.element, Value($0.offset), failedArray).truthy }.map { $0.element }
    let o = JSObject()
    o["moved"] = moved
    o["notMoved"] = Value(notMoved)
    o["groups"] = Value(groups)
    o["attention"] = Value(attention)
    o["kept"] = Value(kept)
    return .object(o)
}

// L2708
func projectLocalFailures(_ receipt: Value = .undefined, _ paths: Value = .undefined, _ project: Value = .undefined) throws -> Value {
    let project = project.isUndefined ? Value(true) : project
    let local = (receipt.failed ?? .newArray()).elements.filter { !$0.cloudAccount.truthy }
    if local.isEmpty && !(receipt.failed ?? .newArray()).elements.contains(where: { $0.blockedByLocal["length"].truthy }) { return .undefined }
    var candidates: [Value]? = nil
    var pool: Value = .undefined
    let verified = JSMap()
    for failure in local {
        if project.truthy && !failure.sources["length"].truthy && failure.id.truthy && receipt.fromAccounts["length"].truthy {
            if candidates == nil {
                var collected: [Value] = []
                for account in receipt.fromAccounts.elements {
                    do {
                        if !UUID.test(account.account.description) || !UUID.test(account.org.description) { collected.append(.null); continue }
                        let files: Value
                        do { files = try recordFiles(Value(try strictJoin([paths.records, account.account, account.org]))) }
                        catch { if jsErrorValue(error).code === "ENOENT" { files = .newArray() } else { throw error } }
                        var rows: [Value] = []
                        for file in files.elements {
                            let raw = try readFile(file), record = try JSON.parse(raw.asData ?? Data())
                            rows.append(Value.spread(try desktopSession(file, record), ["account": account, "observedRecordSha": Value(sha(raw))]))
                        }
                        collected.append(Value(rows))
                    } catch { collected.append(.null) }
                }
                candidates = collected
            }
            let all = candidates ?? []
            let matches = try all.flatMap { ($0 ?? .newArray()).elements }.filter { row in
                try validDesktopRecord(row).truthy && [row.id, row.record.sessionId].contains(where: { $0 === failure.id })
            }
            if all.allSatisfy({ $0.truthy }) && matches.count == 1 {
                let row = matches[0]
                let current = (try? readFile(row.file)) ?? ""
                if Value(sha(current)) === row.observedRecordSha {
                    failure.sources = [Value.spread(try sourceIdentity(row), ["observedRecordSha": row.observedRecordSha])]
                }
            }
        }
        for source in (failure.sources ?? .newArray()).elements {
            do {
                if try !(try receipt.fromAccounts.elements.contains(where: { try sameAccount($0, source).truthy })) || !LOCAL_RECORD.test((source.sessionId ?? "").description) ||
                    source.file !== Value(try strictJoin([paths.records, source.account, source.org, Value("\(source.sessionId).json")])) { continue }
                let raw = try readFile(source.file), record = try JSON.parse(raw.asData ?? Data())
                if record.sessionId !== source.sessionId || record.cliSessionId !== source.id ||
                    Value(sha(raw)) !== (source.recordSha ?? source.observedRecordSha) { continue }
                let relevant = try (receipt.failed ?? .newArray()).elements.filter { try cloudTagged($0, source).truthy && remoteId($0.id).truthy }
                if relevant.isEmpty { continue }
                if pool.nullish { pool = try index(paths.pool) }
                let transcript = try locate(pool, source.id, record.cwd)
                if !transcript.truthy { continue }
                let before = try fingerprint(transcript), data = try load(transcript)
                let bridges = data.entries.elements.filter { $0["type"] === "bridge-session" }
                let recordIds = try (record.bridgeSessionIds ?? .newArray()).elements.map { try remoteId($0) }.filter { $0.truthy }
                let ownedBridges = try bridges.filter { entry in !data.invalid.truthy && entry.ownerAccountUuid === source.account && entry.ownerOrganizationUuid === source.org }
                    .map { try remoteId($0.bridgeSessionId ?? $0.bridge_session_id) }.filter { $0.truthy }
                let owned = try unique(recordIds + ownedBridges).filter { id in
                    try bridges.filter { try remoteId($0.bridgeSessionId ?? $0.bridge_session_id) === id }.allSatisfy { entry in
                        (!entry.ownerAccountUuid.truthy || entry.ownerAccountUuid === source.account) &&
                            (!entry.ownerOrganizationUuid.truthy || entry.ownerOrganizationUuid === source.org)
                    }
                }
                let ownedValue = Value(owned)
                if try before !== fingerprint(transcript) || sha(try readFile(source.file)) != sha(raw) { continue }
                if source.observedRecordSha.truthy && !source.recordSha.truthy { source.remoteIds = ownedValue }
                let kept = (source.remoteIds ?? .newArray()).elements.filter { ownedValue.includes($0) }
                verified.set(try localFailureKey(source), Value.spread(source, ["remoteIds": Value(kept)]))
            } catch {}
        }
    }
    for failure in (receipt.failed ?? .newArray()).elements where failure.cloudAccount.truthy {
        let links = try verified.entries.filter { pair in
            try cloudTagged(failure, pair.1).truthy && pair.1.remoteIds.includes(try remoteId(failure.id))
        }.map { $0.0 }
        if !links.isEmpty { failure.blockedByLocal = Value(links) }
        else { failure.removeKey("blockedByLocal") }
    }
    let kept = try keptCopy(receipt)
    for check in (receipt.cloudChecks ?? .newArray()).elements {
        if check.status === "complete" || check.status === "cancelled" { continue }
        let failures = try (receipt.failed ?? .newArray()).elements.filter { try cloudTagged($0, check).truthy && !(try kept.call($0)).truthy }
        let blocked = !failures.isEmpty && failures.allSatisfy { $0.blockedByLocal["length"].truthy } && !check.waiting["length"].truthy &&
            check.checkedAt.truthy && !receipt.cloudError.truthy
        if blocked { check.status = "blocked-local" }
        else if check.status === "blocked-local" { check.status = "failed" }
    }
    return .undefined
}

// MARK: - Target checks

// L2771
func changed(_ file: Value = .undefined, _ sessionId: Value = .undefined, _ known: Value = .undefined) throws -> Value {
    if !exists(file) { return false }
    if !known.semantic.truthy || known.semanticVersion !== Value(SEMANTIC_VERSION) { return true }
    let data = try load(file)
    if try semantic(data.entries, sessionId, data.invalid) !== known.semantic { return true }
    return Value(!known.bridge.isUndefined && Value(data.entries.elements.contains { $0["type"] === "bridge-session" }) !== known.bridge)
}

// L2778
func targetChanges(_ row: Value = .undefined, _ liveWorkers: Value = .undefined, _ checkShared: Value = .undefined, _ allowRecordDrift: Value = .undefined) throws -> Value {
    let checkShared = checkShared.isUndefined ? Value(true) : checkShared
    let allowRecordDrift = allowRecordDrift.isUndefined ? Value(false) : allowRecordDrift
    let changes = Value.newArray()
    if row.strategy === "rehome" {
        let currentFingerprint = (try? fingerprint(row.targetTranscript)) ?? .null
        if !currentFingerprint.truthy { changes.push("transcript missing") }
        else if checkShared.truthy && row.transcriptFingerprint.truthy && currentFingerprint !== row.transcriptFingerprint { changes.push("transcript") }
        else if try checkShared.truthy && !(try bridgeIntact(row)).truthy { changes.push("transcript") }
        let targetDir = row.targetDir ?? Value(path.join(path.dirname(str(row.targetTranscript)), str(row.targetId)))
        let sidecarsExist = !row.sidecars["count"].truthy || exists(targetDir)
        if !sidecarsExist { changes.push("sidecars missing") }
        else if try row.sidecars.canonicalRoot.truthy && ((try? mappedPath(targetDir)) ?? .null) !== row.sidecars.canonicalRoot ||
            checkShared.truthy && row.sidecars.fingerprint.truthy && !(try sameTree(row.sidecars, (try? treeFingerprint(targetDir)) ?? .null)).truthy {
            changes.push("sidecars")
        }
    } else {
        if try !exists(row.targetTranscript) || (try changed(row.targetTranscript, row.targetId, try knownOf(row))).truthy { changes.push("transcript") }
        let targetDir = row.targetDir ?? Value(path.join(path.dirname(str(row.targetTranscript)), str(row.targetId)))
        let currentSidecars = (try? manifest(targetDir)) ?? .null
        if !currentSidecars.truthy || currentSidecars.sha !== row.sidecars.sha { changes.push("sidecars") }
    }
    let currentRecord = (try? readFile(row.record)) ?? .null
    var recordChanged = !currentRecord.truthy
    if currentRecord.truthy {
        do {
            let record = try JSON.parse(currentRecord.asData ?? Data())
            if allowRecordDrift.truthy && row.recordSnapshot.truthy {
                var rewound = row.strategy === "rehome" && record.cliSessionId !== row.targetId && UUID.test((record.cliSessionId ?? "").description)
                if rewound { rewound = try priorSessions(record).includes(row.targetId) }
                if rewound {
                    let detail = (try? fs.stat(path.join(path.dirname(str(row.targetTranscript)), "\(record.cliSessionId).jsonl"))) ?? .null
                    rewound = detail.nullish ? false : try isFileStat(detail)
                }
                recordChanged = try !validDesktopRecord(["file": row.record, "record": record]).truthy ||
                    ["sessionId", "cwd", "originCwd"].contains(where: { record[$0] !== row.recordSnapshot[$0] }) ||
                    row.recordSnapshot.cliSessionId !== row.targetId || (!rewound && record.cliSessionId !== row.targetId) || record.sessionId !== row.targetRecordId
            } else {
                recordChanged = try !row.recordSemantic.truthy || recordSemantic(record) !== row.recordSemantic
            }
        } catch { recordChanged = true }
    }
    if recordChanged { changes.push("desktop record") }
    if try !allowRecordDrift.truthy && !row.taskFamily.truthy && row.taskFile.truthy &&
        Value(try taskSessions(row.taskFile).has(row.targetRecordId ?? Value("local_\(row.targetId)"))) !== row.taskOwned { changes.push("scheduled tasks") }
    if try !allowRecordDrift.truthy && ownsWorker(liveWorkers, row.targetId, row.targetRecordId).truthy { changes.push("running worker") }
    return changes
}

// L2818
func restoreProblems(_ plan: Value = .undefined, _ root: Value = .undefined, _ parkedOnly: Value = .undefined) throws -> Value {
    let parkedOnly = parkedOnly.isUndefined ? Value(false) : parkedOnly
    let problems = Value.newArray()
    func pairs(_ v: Value) -> JSMap { JSMap((v ?? .newArray()).elements.map { ($0[0], $0[1]) }) }
    for item in plan.elements {
        let hashes = pairs(item.hashes), trees = pairs(item.trees), semantics = pairs(item.semantics)
        let name = or(item.title, item.id)
        for pair in item.moved.elements {
            let original = pair[0], parked = pair[1]
            let relative = path.relative(str(root), str(parked))
            if relative.hasPrefix("..") || path.isAbsolute(relative) {
                problems.push(Value("\(name) | recovery path outside quarantine | \(path.basename(str(parked)))"))
                continue
            }
            let hasOriginal = exists(original), hasParked = exists(parked)
            if parkedOnly.truthy && !hasParked {
                if !hasOriginal { problems.push(Value("\(name) | recovery artifact missing | \(path.basename(str(parked)))")) }
                continue
            }
            if hasOriginal && hasParked { problems.push(Value("\(name) | restore path occupied | \(path.basename(str(original)))")) }
            else if !hasOriginal && !hasParked { problems.push(Value("\(name) | recovery artifact missing | \(path.basename(str(parked)))")) }
            else {
                let available = hasOriginal ? original : parked
                let expectedHash = hashes.get(original)
                let expectedTree = trees.get(original)
                let expectedSemantic = semantics.get(original)
                let changedText = Value("\(name) | recovery artifact changed | \(path.basename(str(available)))")
                if expectedHash.truthy && Value(sha((try? readFile(available)) ?? Value(Data()))) !== expectedHash { problems.push(changedText) }
                else if expectedTree.truthy && ((try? manifest(available)) ?? .null).sha !== expectedTree { problems.push(changedText) }
                else if try expectedSemantic.truthy && recordSemantic((try? readJson(available)) ?? .newObject()) !== expectedSemantic { problems.push(changedText) }
            }
        }
    }
    return problems
}

// L2851
func snapshotPlan(_ item: Value = .undefined) throws -> Value {
    let hashes = try (item.hashes ?? .newArray()).elements.map { pair -> Value in [pair[0], Value(sha(try readFile(pair[0])))] }
    let trees = try (item.trees ?? .newArray()).elements.map { pair -> Value in [pair[0], try manifest(pair[0]).sha] }
    let semantics = try (item.semantics ?? .newArray()).elements.map { pair -> Value in [pair[0], try recordSemantic(try readJson(pair[0]))] }
    let plan = Value.spread(item, ["hashes": Value(hashes), "trees": Value(trees), "semantics": Value(semantics)])
    for pair in item.moved.elements {
        let file = pair[0], parked = pair[1]
        if !LOCAL_RECORD.test(path.basename(str(file), ".json")) { continue }
        let temp = "\(file).tmp"
        let detail: Value
        do { detail = try fs.lstat(temp) }
        catch { if jsErrorValue(error).code === "ENOENT" { continue }; throw error }
        if !(try isFileStat(detail)) { throw JSError("Desktop record temp is not a regular file: \(path.basename(temp))") }
        let raw = try readFile(Value(temp))
        if stable(try JSON.parse(raw.asData ?? Data())) != stable(try readJson(file)) { throw JSError("Desktop record has a different pending update: \(path.basename(str(file)))") }
        plan.hashes.push([Value(temp), Value(sha(raw))])
        plan.required = Value((plan.required ?? .newArray()).elements + [Value(temp)])
        plan.moved = Value(plan.moved.elements + [[Value(temp), Value("\(parked).tmp")]])
    }
    return plan
}

// L2873
func verify(_ rows: Value = .undefined, _ report: Value = .undefined, _ check: Value = .undefined) throws -> Value {
    let report = fnOr(report), check = fnOr(check)
    var bad: [String: Int] = ["transcript": 0, "sidecars": 0, "desktop": 0]
    let problems = Value.newArray()
    func flag(_ key: String, _ r: Value) { bad[key, default: 0] += 1; problems.push(["id": r.targetId, "title": r.title, "check": Value(key)]) }
    let total = Value(rows.length)
    _ = try progress(report, "verify", 0, total)
    for (i, r) in rows.elements.enumerated() {
        _ = try check.call()
        _ = try withFinally({
            let targetDir = r.targetDir ?? Value(path.join(path.dirname(str(r.targetTranscript)), str(r.targetId)))
            let currentFingerprint = (try? fingerprint(r.targetTranscript)) ?? .null
            if !currentFingerprint.truthy || currentFingerprint !== r.transcriptFingerprint { flag("transcript", r) }
            if !(try sameTree(r.sidecars, (try? treeFingerprint(targetDir)) ?? .null)).truthy { flag("sidecars", r) }
            let raw = (try? readFile(r.record, "utf8")) ?? .null
            if !raw.truthy || Value(sha(raw)) !== r.recordSha { flag("desktop", r) }
            _ = try check.call()
            return .undefined
        }, { _ = try progress(report, "verify", Value(i + 1), total) })
    }
    func mark(_ v: Int) -> String { v != 0 ? "✗ \(v)" : "✓" }
    let lines: Value = .strings([
        "chat messages unchanged \(mark(bad["transcript"]!))",
        "sidecars unchanged \(mark(bad["sidecars"]!))",
        "desktop \(mark(bad["desktop"]!))"
    ])
    return ["ok": Value(problems.length == 0), "problems": problems, "lines": lines]
}
