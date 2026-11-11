import CryptoKit
import Darwin
import Foundation

// Bridge metadata appends and recovery, rehoming, failure projection and verification.

// MARK: - Local helpers

// Opaque Swift objects (file handles, running hashes) carried through Values. The box is a function that, when called,
// deposits its object in a slot; JSON.stringify drops functions, so these never leak into written JSON.
fileprivate var unboxSlot: AnyObject?
fileprivate func boxed(_ object: AnyObject) -> Value { Value { _ in unboxSlot = object; return .undefined } }
fileprivate func unboxed<T: AnyObject>(_ v: Value, _ type: T.Type) throws -> T {
    unboxSlot = nil
    defer { unboxSlot = nil }
    if v.isFunction { _ = try v.call() }
    guard let object = unboxSlot as? T else { throw EngineError.type("\(v.typeOf) is not a \(T.self)") }
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
fileprivate func byteLength(_ v: Value) -> Double { Double(v.description.utf8.count) }
fileprivate func nanMax(_ a: Double, _ b: Double) -> Double { a.isNaN || b.isNaN ? .nan : Swift.max(a, b) }
fileprivate func nanMin(_ a: Double, _ b: Double) -> Double { a.isNaN || b.isNaN ? .nan : Swift.min(a, b) }
// A byte range: negative indices count from the end, and both ends are clamped.
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
fileprivate let DIGITS = re(#"^[0-9]+\z"#)
fileprivate let SIGNED = re(#"^-?[0-9]+\z"#)
fileprivate let HEX64 = re(#"^[a-f0-9]{64}\z"#)
// Path helpers throw a TypeError for non-string arguments.
fileprivate func strictJoin(_ parts: [Value]) throws -> String {
    for part in parts where !part.isString {
        throw EngineError.type("The \"path\" argument must be of type string. Received \(part.typeOf == "object" && part.isNull ? "null" : part.typeOf)")
    }
    return path.join(parts.map { $0.description })
}
fileprivate func groupBy(_ items: [Value], _ key: (Value) throws -> Value) rethrows -> ValueMap {
    let groups = ValueMap()
    for item in items {
        let k = try key(item)
        let existing = groups.get(k)
        if case .array(let a) = existing { a.items.append(item) } else { groups.set(k, Value([item])) }
    }
    return groups
}
// try { body() } finally { cleanup() } — a cleanup error replaces the body's outcome.
fileprivate func withFinally(_ body: () throws -> Value, _ cleanup: () throws -> Void) throws -> Value {
    let result: Result<Value, Error>
    do { result = .success(try body()) } catch { result = .failure(error) }
    try cleanup()
    return try result.get()
}

// MARK: - Bridge metadata

func bridgeClear(_ sessionId: Value = .undefined) throws -> Value {
    ["type": "bridge-session", "sessionId": sessionId, "bridgeSessionId": "", "lastSequenceNum": 0]
}
func bridgeError(_ text: Value = .undefined) throws -> Value {
    makeError("Local bridge metadata: \(text)", code: "BRIDGE_RECOVERY").value
}
fileprivate func bridgeFailure(_ text: String) throws -> EngineError { EngineError(try bridgeError(Value(text))) }
func bridgeEntry(_ entry: Value = .undefined, _ sessionId: Value = .undefined) throws -> Value {
    let line = BridgeEntry(entry)
    return Value(entry.truthy && entry.typeOf == "object" && !entry.isArray &&
        line.type === "bridge-session" && line.sessionId === sessionId && line.bridgeSessionId.isString)
}

func bridgePlans(_ row: Value = .undefined, _ aliases: Value = .undefined) throws -> Value {
    let aliases = aliases.isUndefined ? Value.newArray() : aliases
    let session = PlacedSession(row)
    if session.bridgeAppend.nullish && session.bridgeUndo.nullish { return .newArray() }
    let id = session.targetId ?? session.id
    let plans = Value([session.bridgeAppend] + (session.bridgeUndo.nullish ? [] : [session.bridgeUndo]))
    for (index, value) in plans.elements.enumerated() {
        let plan = BridgePlan(value), first = BridgePlan(plans[0])
        let invalid = { () throws -> Never in throw try bridgeFailure("invalid bridge recovery receipt") }
        if try !UUID.test((id ?? "").description) || !value.truthy || value.typeOf != "object" || value.isArray || plan.sessionId !== id ||
            !(try bridgeEntry(plan.original, id)).truthy || !BridgeEntry(plan.original).bridgeSessionId.truthy { try invalid() }
        let made0 = session.made[0]
        let recordId = session.targetRecordId ?? DesktopRecord(session.recordSnapshot).sessionId ?? session.recordId ??
            (made0.truthy ? Value(path.basename(made0.description, ".json")) : .null)
        let recordIds = plan.recordIds
        if !recordIds.isArray || recordIds.length == 0 || recordIds.elements.contains(where: { !$0.isString || !LOCAL_RECORD.test($0.description) }) ||
            ValueSet(recordIds.elements).size != recordIds.length || ([recordId] + aliases.elements).contains(where: { $0.truthy && !recordIds.includes($0) }) { try invalid() }
        if [plan.transcript, plan.canonical].contains(where: { !$0.isString || !path.isAbsolute($0.description) || path.basename($0.description) != "\(id).jsonl" }) ||
            [plan.dev, plan.ino].contains(where: { !$0.isString || !DIGITS.test($0.description) }) ||
            !isSafeInteger(plan.length) || toNumber(plan.length) < 0 ||
            [plan.sha, plan.afterSha].contains(where: { !$0.isString || !HEX64.test($0.description) }) { try invalid() }
        let signature: [String] = plan.fingerprint.isString ? plan.fingerprint.description.splitting(":") : []
        if signature.count != 5 || signature[0..<3].joined(separator: ":") != "\(plan.dev):\(plan.ino):\(plan.length)" ||
            signature[3...].contains(where: { !SIGNED.test($0) }) { try invalid() }
        let bytes = jsonText(index != 0 ? first.original : try bridgeClear(id), 0)
        if plan.bytes !== Value(bytes) && plan.bytes !== Value("\n\(bytes)") || !isSafeInteger(Value(toNumber(plan.length) + byteLength(plan.bytes))) { try invalid() }
        if (session.targetTranscript ?? session.transcript ?? plan.transcript) !== plan.transcript || index != 0 &&
            (plan.transcript !== first.transcript || plan.canonical !== first.canonical || plan.dev !== first.dev || plan.ino !== first.ino ||
             stable(plan.recordIds) != stable(first.recordIds) ||
             stable(plan.original) != stable(first.original) || toNumber(plan.length) < toNumber(first.length) + byteLength(first.bytes)) { try invalid() }
        if !plan.continuation.nullish {
            let continuation = BridgeContinuation(plan.continuation), offset = toNumber(continuation.length) - toNumber(plan.length)
            if !isSafeInteger(Value(offset)) || offset < 0 || offset >= byteLength(plan.bytes) ||
                !continuation.sha.isString || !HEX64.test(continuation.sha.description) ||
                continuation.bytes !== Value(subarray(Data(plan.bytes.description.utf8), offset).base64EncodedString()) ||
                !continuation.fingerprint.isString ||
                !re("^\(plan.dev):\(plan.ino):\(continuation.length):-?[0-9]+:-?[0-9]+\\z").test(continuation.fingerprint.description) { try invalid() }
        }
    }
    return plans
}

func bridgeFile(_ planValue: Value = .undefined, _ writable: Value = .undefined, _ work: Value = .undefined) throws -> Value {
    let plan = BridgePlan(planValue)
    if try mappedPath(plan.transcript) !== plan.canonical || Value(try fs.realpath(str(plan.canonical))) !== plan.canonical { throw try bridgeFailure("transcript path changed") }
    let before = try fs.lstat(str(plan.canonical), bigint: true)
    if !before.isFile || plan.dev !== Value(before.dev.description) || plan.ino !== Value(before.ino.description) { throw try bridgeFailure("transcript identity changed") }
    let flags: Int32 = (writable.truthy ? O_RDWR | O_APPEND : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK
    let handle = try fs.open(str(plan.canonical), flags, 0o666)
    let boxedHandle = boxed(handle)
    return try withFinally({
        _ = try bridgeStable(planValue, boxedHandle, statIdentity(before))
        return try work.call(boxedHandle)
    }, { try handle.close() })
}

func bridgeStable(_ planValue: Value = .undefined, _ handle: Value = .undefined, _ signature: Value = .undefined, _ inspect: Value = .undefined) throws -> Value {
    let plan = BridgePlan(planValue)
    if inspect.truthy {
        let live = try workers(try inspect.call())
        for recordId in (plan.recordIds ?? [.null]).elements where try ownsWorker(live, plan.sessionId, recordId).truthy { throw try bridgeFailure("running worker") }
    }
    let current = try handleOf(handle).stat(bigint: true)
    let named = try fs.lstat(str(plan.canonical), bigint: true)
    if try !current.isFile || !named.isFile || statIdentity(current) !== signature || statIdentity(named) !== signature ||
        Value(current.dev.description) !== plan.dev || Value(current.ino.description) !== plan.ino ||
        mappedPath(plan.transcript) !== plan.canonical || Value(fs.realpath(str(plan.canonical))) !== plan.canonical { throw try bridgeFailure("transcript changed") }
    return .undefined
}

func bridgeRead(_ planValue: Value = .undefined, _ handle: Value = .undefined, _ parse: Value = .undefined) throws -> Value {
    let plan = BridgePlan(planValue)
    let parse = parse.isUndefined ? Value(true) : parse
    let file = try handleOf(handle)
    let detail = try file.stat(bigint: true), size = Double(detail.size), signature = statIdentity(detail)
    if !isSafeInteger(Value(size)) { throw try bridgeFailure("transcript size is unsupported") }
    let memory = try operationMemory()
    let hash = RunningHash(), prefix = RunningHash()
    var tail = Data()
    let bufferLength = 64.0 * 1024, limit = byteLength(plan.bytes ?? "")
    let planLength = toNumber(plan.length)
    var parts: [Data] = [], length = 0, last: Value = .null, prefixLast: Value = .null, invalid = false, newline = false
    func consume(_ end: Double) throws {
        _ = try memory["check"].call(Value(Double(length * 4)))
        var joined = Data(capacity: length)
        for part in parts { joined.append(part) }
        let text = String(decoding: joined, as: UTF8.self).trimmingWhitespace
        parts = []; length = 0
        if text.isEmpty { return }
        do {
            let entry = try JSON.parse(text), line = BridgeEntry(entry)
            if line.type === "bridge-session" && line.sessionId === plan.sessionId {
                last = entry
                if end <= planLength { prefixLast = entry }
            }
        } catch { invalid = true }
    }
    var at = 0.0
    while at < size {
        let chunk = try file.read(length: Int(nanMin(bufferLength, size - at)), position: Int64(at))
        let bytesRead = chunk.count
        if bytesRead == 0 { throw try bridgeFailure("transcript changed while reading") }
        productive()
        _ = try memory["check"].call(Value(Double(bytesRead)))
        hash.update(chunk)
        if at < planLength { prefix.update(subarray(chunk, 0, nanMin(Double(bytesRead), planLength - at))) }
        let startTail = nanMax(0, planLength - at), endTail = nanMin(Double(bytesRead), planLength + limit - at)
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
    _ = try bridgeStable(planValue, handle, signature)
    let o = ValueObject()
    o["length"] = Value(size)
    o["fingerprint"] = signature
    o["sha"] = Value(hash.copy().digest())
    o["hash"] = boxed(hash)
    o["prefixHash"] = boxed(prefix.copy())
    o["intendedSha"] = Value(prefix.copy().update((plan.bytes ?? "").description).digest())
    o["prefixSha"] = Value(prefix.digest())
    o["prefixLast"] = prefixLast
    o["tail"] = Value(tail)
    o["last"] = last
    o["invalid"] = Value(invalid)
    o["newline"] = Value(newline)
    return .object(o)
}

func bridgePlan(_ base: Value = .undefined, _ stateValue: Value = .undefined, _ entry: Value = .undefined) throws -> Value {
    let state = BridgeState(stateValue)
    if !(try bridgeEntry(entry, BridgePlan(base).sessionId)).truthy { throw try bridgeFailure("invalid bridge metadata entry") }
    let bytes = "\(state.length.truthy && !state.newline.truthy ? "\n" : "")\(JSON.text(entry))\n"
    return Value.spread(try without(base, .strings(["continuation"])), [
        "length": state.length, "sha": state.sha, "fingerprint": state.fingerprint, "bytes": Value(bytes),
        "afterSha": Value(try hashOf(state.hash).copy().update(bytes).digest())
    ])
}

func bridgeSource(_ source: Value = .undefined, _ to: Value = .undefined, _ guardValue: Value = .undefined) throws -> Value {
    let s = MoveSource(source), destination = Account(to), check = RehomeGuard(guardValue)
    let canonical = try mappedPath(s.transcript), detail = try fs.lstat(str(canonical), bigint: true)
    let records = ([source] + check.sources.elements + check.targets.elements).filter { $0["id"] === s.id }.map { MoveSource($0).desktopRecord }
    let recordIds = Value(defaultSorted(unique(records.map(\.sessionId))))
    let base: Value = ["transcript": s.transcript, "canonical": canonical, "sessionId": s.id, "recordIds": recordIds,
                       "dev": Value(detail.dev.description), "ino": Value(detail.ino.description)]
    return try bridgeFile(base, false, Value { args in
        let handle = args.first ?? .undefined
        let stateValue = try bridgeRead(base, handle, Value(s.bridge !== false && s.contentSha !== BridgePlan(s.bridgeAppend).afterSha))
        let state = BridgeState(stateValue)
        if state.fingerprint !== s.transcriptFingerprint || s.contentSha.truthy && state.sha !== s.contentSha { throw EngineError("source changed since inventory") }
        let last = BridgeEntry(state.last)
        let pointer = last.bridgeSessionId
        let destinationOwned = last.ownerAccountUuid === destination.accountId && last.ownerOrganizationUuid === destination.orgId
        let mirror = records.contains(where: { record in record.sshConfig.truthy || record.sshRemoteTranscriptPath.isString && record.sshRemoteTranscriptPath !== "" }) ||
            [s.transcript, canonical].contains(where: { file in path.basename(path.dirname(file.description)) == "ssh-\(s.id)" })
        let append: Value = pointer.isString && pointer.truthy && !state.invalid.truthy && !destinationOwned && !mirror
            ? Value.spread(try bridgePlan(base, stateValue, try bridgeClear(s.id)), ["original": last.raw]) : .null
        if append.truthy { _ = try bridgePlans(["id": s.id, "recordId": DesktopRecord(s.record).sessionId, "transcript": s.transcript, "bridgeAppend": append]) }
        return ["fingerprint": state.fingerprint, "append": append]
    })
}

func appendBridge(_ planValue: Value = .undefined, _ inspect: Value = .undefined, _ recovering: Value = .undefined, _ save: Value = .undefined) throws -> Value {
    let plan = BridgePlan(planValue)
    let recovering = recovering.isUndefined ? Value(false) : recovering
    let save = save.isUndefined ? Value.null : save
    var attempted = false
    do {
        return try bridgeFile(planValue, true, Value { args in
            let handle = args.first ?? .undefined
            let stateValue = try bridgeRead(planValue, handle, false), state = BridgeState(stateValue), bytes = Data(plan.bytes.description.utf8)
            let extra = toNumber(state.length) - toNumber(plan.length)
            if recovering.truthy {
                if !(try bridgeWitness(planValue, stateValue)).truthy { throw try bridgeFailure("append recovery witness changed") }
                if extra >= Double(bytes.count) { return stateValue }
                plan.continuation = ["length": state.length, "sha": state.sha, "fingerprint": state.fingerprint,
                                     "bytes": Value(subarray(bytes, extra).base64EncodedString())]
                _ = try save.call()
            }
            if !recovering.truthy && (state.length !== plan.length || state.sha !== plan.sha || state.fingerprint !== plan.fingerprint) { throw try bridgeFailure("source changed before append") }
            _ = try bridgeStable(planValue, handle, state.fingerprint, inspect)
            attempted = true
            let file = try handleOf(handle)
            try file.writeFile(recovering.truthy ? subarray(bytes, extra) : bytes)
            try file.sync()
            let afterValue = try bridgeRead(planValue, handle, false), after = BridgeState(afterValue)
            if after.length !== Value(toNumber(plan.length) + byteLength(plan.bytes)) || after.sha !== plan.afterSha ||
                after.prefixSha !== plan.sha || after.tail.asData != Data(plan.bytes.description.utf8) { throw try bridgeFailure("unexpected content after append") }
            _ = try bridgeStable(planValue, handle, after.fingerprint, inspect)
            return afterValue
        })
    } catch {
        let value = errorObject(error)
        value["bridgeUntouched"] = Value(!attempted)
        throw EngineError(value)
    }
}

func bridgeWitness(_ planValue: Value = .undefined, _ stateValue: Value = .undefined) throws -> Value {
    let plan = BridgePlan(planValue), state = BridgeState(stateValue)
    let bytes = Data(plan.bytes.description.utf8), extra = toNumber(state.length) - toNumber(plan.length)
    if state.prefixSha === plan.sha {
        var broken = state.intendedSha !== plan.afterSha
        if !broken && plan.continuation.truthy {
            let continuation = BridgeContinuation(plan.continuation)
            let witness = try hashOf(state.prefixHash).copy()
                .update(subarray(bytes, 0, toNumber(continuation.length) - toNumber(plan.length))).digest()
            broken = Value(witness) !== continuation.sha
        }
        if broken { throw try bridgeFailure("invalid bridge recovery receipt witness") }
    }
    return Value(extra >= 0 && state.prefixSha === plan.sha && state.tail.asData == subarray(bytes, 0, extra))
}

func bridgeRecovery(_ row: Value = .undefined, _ optional: Value = .undefined, _ aliases: Value = .undefined) throws -> Value {
    let optional = optional.isUndefined ? Value(false) : optional
    let aliases = aliases.isUndefined ? Value.newArray() : aliases
    let session = PlacedSession(row)
    let plans = try bridgePlans(row, aliases), planValue = plans[0], plan = BridgePlan(planValue)
    if !planValue.truthy { return .null }
    let stateValue: Value
    do { stateValue = try bridgeFile(planValue, false, Value { args in try bridgeRead(planValue, args.first ?? .undefined) }) }
    catch { if optional.truthy && !session.bridgeUndo.truthy { return .null }; throw error }
    let state = BridgeState(stateValue)
    if state.prefixSha === plan.sha && stable(state.prefixLast) != stable(plan.original) { throw try bridgeFailure("invalid original bridge witness") }
    let witnessed = try bridgeWitness(planValue, stateValue), extra = toNumber(state.length) - toNumber(plan.length)
    if !witnessed.truthy {
        if optional.truthy && !session.bridgeUndo.truthy { return .null }
        throw try bridgeFailure("transcript restoration witness changed")
    }
    if session.bridgeUndo.truthy {
        if extra < byteLength(plan.bytes) { throw try bridgeFailure("transcript restoration witness changed") }
        let undo = session.bridgeUndo
        let restored = try bridgeFile(undo, false, Value { args in try bridgeRead(undo, args.first ?? .undefined, false) })
        if !(try bridgeWitness(session.bridgeUndo, restored)).truthy { throw try bridgeFailure("transcript restoration witness changed") }
        return ["plan": planValue, "state": stateValue, "restoring": true]
    }
    if extra == 0 { return .null }
    if try extra >= byteLength(plan.bytes) && (state.invalid.truthy || stable(state.last) != stable(try bridgeClear(plan.sessionId))) {
        if optional.truthy { return .null }
        throw try bridgeFailure("transcript restoration witness changed")
    }
    return ["plan": planValue, "state": stateValue, "partial": Value(extra < byteLength(plan.bytes))]
}

func restoreBridge(_ row: Value = .undefined, _ save: Value = .undefined, _ inspect: Value = .undefined, _ optional: Value = .undefined, _ allowLater: Value = .undefined) throws -> Value {
    let optional = optional.isUndefined ? Value(false) : optional
    let allowLater = allowLater.isUndefined ? Value(true) : allowLater
    let session = PlacedSession(row)
    let recovery = BridgeRecovery(try bridgeRecovery(row, optional))
    if !recovery.isPresent { return .undefined }
    let plan = BridgePlan(recovery.plan)
    if recovery.restoring.truthy { return try appendBridge(session.bridgeUndo, inspect, true, save) }
    if !allowLater.truthy && toNumber(BridgeState(recovery.state).length) > toNumber(plan.length) + byteLength(plan.bytes) { throw try bridgeFailure("newer transcript content prevents bridge restoration") }
    if recovery.partial.truthy { _ = try appendBridge(plan.raw, inspect, true, save) }
    let ready = BridgeRecovery(try bridgeRecovery(row, optional))
    if !ready.isPresent { return .undefined }
    session.bridgeUndo = try bridgePlan(plan.raw, ready.state, plan.original)
    _ = try save.call()
    _ = try appendBridge(session.bridgeUndo, inspect)
    return .undefined
}

func bridgeProblems(_ rows: Value = .undefined, _ optional: Value = .undefined) throws -> Value {
    let optional = optional.isUndefined ? Value(false) : optional
    let problems = Value.newArray()
    func key(_ row: PlacedSession) -> Value { row.targetId ?? row.id }
    let related = groupBy(rows.elements) { key(PlacedSession($0)) }
    for row in rows.elements.map(PlacedSession.init) {
        do {
            let aliases = related.get(key(row)).elements.map(PlacedSession.init).map { $0.targetRecordId ?? DesktopRecord($0.recordSnapshot).sessionId }
            _ = try bridgeRecovery(row.raw, optional, Value(aliases))
        } catch { problems.push(Value("\(row.title) | \(errorObject(error)["message"])")) }
    }
    return problems
}

func bridgeIntact(_ row: Value = .undefined) throws -> Value {
    let planValue = PlacedSession(row).bridgeAppend
    if !planValue.truthy { return true }
    let plan = BridgePlan(planValue)
    do {
        return try bridgeFile(planValue, false, Value { args in
            let state = BridgeState(try bridgeRead(planValue, args.first ?? .undefined, false))
            return Value(state.prefixSha === plan.sha && state.tail.asData == Data(plan.bytes.description.utf8))
        })
    } catch { return false }
}

// MARK: - Rehome

func rehomeOne(_ sourceValue: Value = .undefined, _ to: Value = .undefined, _ journal: Value = .undefined, _ guardValue: Value = .undefined) throws -> Value {
    let s = MoveSource(sourceValue), destination = Account(to), check = RehomeGuard(guardValue)
    let source = try bridgeSource(sourceValue, to, guardValue)
    let transcriptFingerprint = source["fingerprint"], append = BridgePlan(source["append"])
    let sidecarRoot = path.join(path.dirname(str(s.transcript)), str(s.id))
    let sidecarTree = try treeFingerprint(Value(sidecarRoot)), tree = SidecarTree(sidecarTree)
    if try !SidecarTree(s.sidecar).fingerprint.truthy || !(try sameTree(s.sidecar, sidecarTree)).truthy { throw EngineError("source sidecars changed since inventory") }
    let sourceSidecars = SidecarTree(Value.spread(s.sidecar, ["fingerprint": tree.fingerprint, "canonicalRoot": tree.canonicalRoot]))
    let sourceRecord = try readFile(s.file, "utf8")
    let currentValue = try JSON.parse(sourceRecord.description), current = DesktopRecord(currentValue)
    if try current.cliSessionId !== s.id || !(try validDesktopRecord(["file": s.file, "record": currentValue])).truthy { throw EngineError("source Desktop record changed identity") }
    if try recordSemantic(currentValue) !== s.recordSemantic { throw EngineError("source Desktop record changed since inventory") }
    if current.forkedFromSessionId !== DesktopRecord(s.record).forkedFromSessionId { throw EngineError("source Desktop lineage changed since inventory") }
    let taskSessionsMap = check.taskSessions
    if !s.taskFamily.truthy {
        var owned = current.notifySessionId.truthy
        if !owned && current.scheduledTaskId.truthy {
            if !s.coldRun.truthy { owned = true } else {
                let owners = Value([s.account.taskFile, destination.taskFile].map { file -> Value in ["taskSessions": taskSessionsMap.get(file)] })
                owned = try coldBlocked(currentValue, owners).truthy
            }
        }
        if owned { throw EngineError("source Desktop ownership changed since inventory") }
    }
    let sourceTasks = taskSessionsMap.get(s.account.taskFile)
    if sourceTasks.nullish { throw EngineError.type("Cannot read properties of \(sourceTasks) (reading 'has')") }
    if TaskRegistry(sourceTasks).notifies(current.sessionId) { throw EngineError("source scheduled task ownership changed since inventory") }
    let targetTasks = TaskRegistry(taskSessionsMap.get(destination.taskFile)).tasks
    if targetTasks.elements.contains(where: { task in
        task["notifySessionId"] === current.sessionId &&
            !s.taskFamily["replaced"].elements.contains(where: { row in stable(row["task"]) == stable(task) })
    }) { throw EngineError("target scheduled task collision") }
    if try ownsWorker(check.workers, s.id, current.sessionId).truthy { throw EngineError("running worker") }
    let title = or(or(Value((current.title ?? "").description.trimmingWhitespace), s.title), "Untitled")
    let record = path.join(destination.dir, path.basename(str(s.file)))
    let sourceRecordSha = sha(sourceRecord)
    let placed = Value.spread(try without(currentValue, .strings(ACCOUNT_ERROR_KEYS)), ["bridgeSessionIds": .newArray()])
    let recordText = jsonText(placed)
    let recordSha = sha(recordText)
    _ = try journal.call(["strategy": "rehome", "recordSha": Value(recordSha)])
    if check.check.isFunction { _ = try check.check.call() }
    _ = try writeNew(Value(record), Value(recordText), Value { args in
        let made = args.first ?? .undefined
        let dev = made["dev"], ino = made["ino"]
        check.created.put(Value(record), ["dev": dev, "ino": ino])
        _ = try journal.call(["created": ["dev": dev, "ino": ino]])
        return .undefined
    })
    let afterTranscriptFingerprint = try fingerprint(s.transcript)
    let afterRecord = try readFile(s.file, "utf8")
    let afterSidecars = try treeFingerprint(Value(sidecarRoot))
    if afterTranscriptFingerprint !== transcriptFingerprint { throw EngineError("source changed during move") }
    if sha(afterRecord) != sourceRecordSha { throw EngineError("source Desktop record changed during move") }
    if !(try sameTree(sourceSidecars.raw, afterSidecars)).truthy { throw EngineError("source sidecars changed during move") }
    if check.check.isFunction { _ = try check.check.call() }
    var placedFingerprint = transcriptFingerprint
    if append.isPresent {
        _ = try journal.call(["bridgeAppend": append.raw], true)
        let after: BridgeState
        do { after = BridgeState(try appendBridge(append.raw, check.inspect)) }
        catch {
            if errorObject(error)["bridgeUntouched"].truthy { _ = try journal.call(["bridgeAppend": .null], true) }
            throw error
        }
        placedFingerprint = after.fingerprint
        append.applied = true
        _ = try journal.call(["bridgeAppend": append.raw], true)
        let sourceSha = s.contentSha
        for member in check.sources.elements.map(MoveSource.init) where member.transcript === s.transcript && member.contentSha === sourceSha && member.transcriptFingerprint === transcriptFingerprint {
            member.contentSha = after.sha
            member.transcriptFingerprint = placedFingerprint
            member.bridgeAppend = append.raw
        }
    }
    for member in s.members {
        member.strategy = "rehome"
        member.transcriptFingerprint = placedFingerprint
        member.sidecar = Value.spread(member.sidecar, ["fingerprint": sourceSidecars.fingerprint])
    }
    let o = ValueObject()
    o["strategy"] = "rehome"
    o["id"] = s.id
    o["targetId"] = s.id
    o["title"] = title
    o["archived"] = Value(current.isArchived)
    o["transcript"] = s.transcript
    o["targetTranscript"] = s.transcript
    o["targetDir"] = sourceSidecars.count.truthy ? Value(path.join(path.dirname(str(s.transcript)), str(s.id))) : .null
    o["record"] = Value(record)
    o["recordSha"] = Value(recordSha)
    o["recordSnapshot"] = recordSnapshot(placed)
    o["recordSemantic"] = try recordSemantic(placed)
    o["targetRecordId"] = current.sessionId
    o["taskFile"] = destination.taskFile
    o["taskOwned"] = false
    if s.taskFamily.truthy { o["taskFamily"] = s.taskFamily["key"] }
    o["transcriptFingerprint"] = placedFingerprint
    if append.isPresent { o["bridgeAppend"] = append.raw }
    o["sidecars"] = ["count": sourceSidecars.count, "bytes": sourceSidecars.bytes, "fingerprint": sourceSidecars.fingerprint, "canonicalRoot": sourceSidecars.canonicalRoot]
    o["events"] = s.roots["size"]
    return .object(o)
}

// MARK: - Ownership and failures

func knownOf(_ row: Value = .undefined) throws -> Value {
    let session = PlacedSession(row)
    return ["semantic": session.targetSemantic, "semanticVersion": session.targetSemanticVersion]
}
func artifacts(_ row: Value = .undefined) throws -> Value {
    let session = PlacedSession(row)
    return session.strategy === "rehome" ? [session.record] : [session.targetTranscript, session.targetDir, session.record].filter { $0.truthy }.value
}
public func retiredCount(_ receipt: Value = .undefined) throws -> Value { try retiredCount(Receipt(receipt)) }
func retiredCount(_ receipt: Receipt) throws -> Value {
    Value((receipt.superseded ?? .newArray()).elements.filter { $0["source"].truthy }.count)
}
func retiredFiles(_ receipt: Receipt) throws -> Value {
    .newSet((receipt.superseded ?? .newArray()).elements.filter { $0["source"].truthy }.flatMap { row in RetirementItem(row).moved.elements.map { $0[0] } })
}
func ownership(_ row: Value = .undefined, _ liveWorkers: Value = .undefined, _ bridges: Value = .undefined) throws -> Value {
    let bridges = bridges.isUndefined ? Value(true) : bridges
    let source = MoveSource(row), record = source.desktopRecord
    let worker = try source.hasWorker || ownsWorker(liveWorkers, source.id, record.sessionId).truthy
    let parts: [String?] = [
        bridges.truthy && record.bridgeSessionIds["length"].truthy ? "Remote Control bridge" : nil,
        bridges.truthy && source.bridge.truthy ? "transcript bridge" : nil,
        record.scheduledTaskId.truthy && !source.coldRun.truthy ? "scheduled task" : nil,
        record.notifySessionId.truthy ? "notification route" : nil,
        source.taskOwned ? "scheduled task registry" : nil,
        worker ? "running worker" : nil
    ]
    return Value(parts.compactMap { $0 }.joined(separator: ", "))
}
func rehomeOwnership(_ row: Value = .undefined, _ liveWorkers: Value = .undefined) throws -> Value {
    let source = MoveSource(row)
    if source.taskFamily.truthy && !source.taskFamily["error"].truthy {
        return try source.hasWorker || ownsWorker(liveWorkers, source.id, source.desktopRecord.sessionId).truthy ? "running worker" : ""
    }
    return try ownership(row, liveWorkers, false)
}
public func retirementOwnership(_ inv: Value = .undefined, _ row: Value = .undefined, _ owner: Value = .undefined, _ liveWorkers: Value = .undefined) throws -> Value { try retirementOwnership(MovePlan(inv), row, owner, liveWorkers) }
func retirementOwnership(_ inv: MovePlan, _ row: Value = .undefined, _ owner: Value = .undefined, _ liveWorkers: Value = .undefined) throws -> Value {
    PlacedSession(owner["history"]).strategy === "rehome" || inv.cloudRequested.truthy ? try rehomeOwnership(row, liveWorkers) : try ownership(row, liveWorkers)
}
func sourceIdentity(_ row: Value = .undefined) throws -> Value {
    let source = MoveSource(row)
    let rest: Value = ["label": try accountLabel(source.account.raw), "id": source.id, "sessionId": DesktopRecord(source.record).sessionId, "file": source.file,
                       "title": source.title, "remoteIds": try remoteIdsOf(row)]
    return Value.spread(try accountRef(source.account.raw), rest, source.recordSha.truthy ? ["recordSha": source.recordSha] : [:])
}
func failureIdentity(_ item: Value = .undefined) throws -> Value {
    let rows = try MoveSource(item).members.filter { try $0.account.raw.truthy && validDesktopRecord($0.raw).truthy }
    return ["sources": Value(try rows.map { try sourceIdentity($0.raw) })]
}
func inventoryFailure(_ item: Value = .undefined) throws -> Value {
    let source = MoveSource(item)
    func name(_ row: MoveSource) -> String { "\(row.account.label) | \(or(row.title, Value(path.basename(str(row.file)))))" }
    let title: String
    if toNumber(item["members"]["length"]) > 1 {
        title = item["members"].elements.map { name(MoveSource($0)) }.joined(separator: " + ")
    } else {
        title = name(source)
    }
    let head: Value = ["id": source.id ?? .null, "title": Value(title), "error": source.error ?? "unreadable Desktop record"]
    return Value.spread(head, source.code.truthy ? ["code": source.code] : [:], try failureIdentity(item))
}
func taggedCloudFailure(_ cloud: Value = .undefined, _ failure: Value = .undefined) throws -> Value {
    Value.spread(failure, ["cloudAccount": AccountPair(cloud).accountId, "cloudOrg": AccountPair(cloud).orgId])
}
func cloudTagged(_ row: Value = .undefined, _ cloud: Value = .undefined) throws -> Value {
    let failure = FailedSession(row), pair = AccountPair(cloud)
    return Value(failure.cloudAccount === pair.accountId && failure.cloudOrg === pair.orgId)
}
public func inventoryFailures(_ inv: Value = .undefined) throws -> Value { try inventoryFailures(MovePlan(inv)) }
func inventoryFailures(_ inv: MovePlan) throws -> Value {
    let local = try (inv.unreadable.elements + inv.rejected.elements + (inv.blocked ?? .newArray()).elements).map { try inventoryFailure($0) }
    let cloud = try (inv.cloud["blocked"] ?? .newArray()).elements.map { try taggedCloudFailure(inv.cloud, try inventoryFailure($0)) }
    return Value(local + cloud)
}
func localFailureKey(_ row: Value = .undefined) throws -> Value {
    let source = FailureSource(row)
    return Value("\(source.account)/\(source.org)/\(source.sessionId)")
}
func failureCause(_ error: Value = .undefined) throws -> Value {
    let text = error.description
    if text.hasPrefix(TASK_FAMILY_BLOCKED) { return "waiting on task family" }
    if re("conflicting duplicate uuids|unparseable lines|history cannot be compared safely").test(text) { return "history check" }
    if error === Value(PARENT_MISSING) { return "waiting on parent" }
    if re("task.*(?:collision|differs|enabled|dependency|unreadable|record exists)").test(text) { return "task collision" }
    return "other"
}
public func receiptSummary(_ receipt: Value = .undefined) throws -> Value { try receiptSummary(Receipt(receipt)) }
func receiptSummary(_ receipt: Receipt) throws -> Value {
    let failed = (receipt.failed ?? .newArray()).elements
    let local = failed.map(FailedSession.init).filter { !$0.cloudAccount.truthy }
    let byKey = ValueMap()
    for row in local {
        for source in (row.sources ?? .newArray()).elements {
            let entry = Value.spread(source, ["error": row.error, "cause": try failureCause(row.error)])
            byKey.set(try localFailureKey(entry), entry)
        }
    }
    let notMoved = byKey.values
    let moved = receipt.finalizing.truthy ? receipt.appendCheckpoint["sessions"] ?? 0 : receipt.sessions["length"] ?? 0
    let groups = groupBy(notMoved) { FailureSource($0).cause }.entries.map { pair -> Value in ["cause": pair.0, "records": pair.1] }
    let attention = try failed.filter { row in
        FailedSession(row).cloudAccount.truthy ? try actionableCloudFailure(receipt, row).truthy : !FailedSession(row).sources["length"].truthy
    }
    let keep = try keptCopy(receipt), failedArray = Value(failed)
    let kept = try failed.enumerated().filter { try keep.call($0.element, Value($0.offset), failedArray).truthy }.map { $0.element }
    let o = ValueObject()
    o["moved"] = moved
    o["notMoved"] = Value(notMoved)
    o["groups"] = Value(groups)
    o["attention"] = Value(attention)
    o["kept"] = Value(kept)
    return .object(o)
}

func projectLocalFailures(_ receipt: Receipt, _ paths: DataLayout, _ project: Value = .undefined) throws -> Value {
    let project = project.isUndefined ? Value(true) : project
    let local = (receipt.failed ?? .newArray()).elements.map(FailedSession.init).filter { !$0.cloudAccount.truthy }
    if local.isEmpty && !(receipt.failed ?? .newArray()).elements.contains(where: { FailedSession($0).blockedByLocal["length"].truthy }) { return .undefined }
    var candidates: [Value]? = nil
    var pool: Value = .undefined
    let verified = ValueMap()
    for failure in local {
        if project.truthy && !failure.sources["length"].truthy && failure.id.truthy && receipt.fromAccounts["length"].truthy {
            if candidates == nil {
                var collected: [Value] = []
                for accountValue in receipt.fromAccounts.elements {
                    let account = AccountPair(accountValue)
                    do {
                        if !UUID.test(account.accountId.description) || !UUID.test(account.orgId.description) { collected.append(.null); continue }
                        let files: Value
                        do { files = try recordFiles(Value(try strictJoin([Value(paths.records), account.accountId, account.orgId]))) }
                        catch { if errorObject(error)["code"] === "ENOENT" { files = .newArray() } else { throw error } }
                        var rows: [Value] = []
                        for file in files.elements {
                            let raw = try readFile(file), record = try JSON.parse(raw.asData ?? Data())
                            rows.append(Value.spread(try desktopSession(file, record), ["account": accountValue, "observedRecordSha": Value(sha(raw))]))
                        }
                        collected.append(Value(rows))
                    } catch { collected.append(.null) }
                }
                candidates = collected
            }
            let all = candidates ?? []
            let matches = try all.flatMap { ($0 ?? .newArray()).elements }.filter { row in
                try validDesktopRecord(row).truthy && [row["id"], DesktopRecord(row["record"]).sessionId].contains(where: { $0 === failure.id })
            }
            if all.allSatisfy({ $0.truthy }) && matches.count == 1 {
                let row = matches[0], observed = row["observedRecordSha"]
                let current = (try? readFile(row["file"])) ?? ""
                if Value(sha(current)) === observed {
                    failure.sources = [Value.spread(try sourceIdentity(row), ["observedRecordSha": observed])]
                }
            }
        }
        for source in (failure.sources ?? .newArray()).elements.map(FailureSource.init) {
            do {
                if try !(try receipt.fromAccounts.elements.contains(where: { try sameAccount($0, source.raw).truthy })) || !LOCAL_RECORD.test((source.sessionId ?? "").description) ||
                    source.file !== Value(try strictJoin([Value(paths.records), source.account, source.org, Value("\(source.sessionId).json")])) { continue }
                let raw = try readFile(source.file), recordValue = try JSON.parse(raw.asData ?? Data()), record = DesktopRecord(recordValue)
                if record.sessionId !== source.sessionId || record.cliSessionId !== source.id ||
                    Value(sha(raw)) !== (source.recordSha ?? source.observedRecordSha) { continue }
                let relevant = try (receipt.failed ?? .newArray()).elements.filter { try cloudTagged($0, source.raw).truthy && remoteId(FailedSession($0).id).truthy }
                if relevant.isEmpty { continue }
                if pool.nullish { pool = try index(Value(paths.pool)) }
                let transcript = try locate(pool, source.id, record.cwd)
                if !transcript.truthy { continue }
                let before = try fingerprint(transcript), data = TranscriptLoad(try load(transcript))
                let bridges = data.entries.elements.map(BridgeEntry.init).filter { $0.type === "bridge-session" }
                let recordIds = try (record.bridgeSessionIds ?? .newArray()).elements.map { try remoteId($0) }.filter { $0.truthy }
                let ownedBridges = try bridges.filter { entry in !data.invalid.truthy && entry.ownerAccountUuid === source.account && entry.ownerOrganizationUuid === source.org }
                    .map { try remoteId($0.bridgeSessionId) }.filter { $0.truthy }
                let owned = try unique(recordIds + ownedBridges).filter { id in
                    try bridges.filter { try remoteId($0.bridgeSessionId) === id }.allSatisfy { entry in
                        (!entry.ownerAccountUuid.truthy || entry.ownerAccountUuid === source.account) &&
                            (!entry.ownerOrganizationUuid.truthy || entry.ownerOrganizationUuid === source.org)
                    }
                }
                let ownedValue = Value(owned)
                if try before !== fingerprint(transcript) || sha(try readFile(source.file)) != sha(raw) { continue }
                if source.observedRecordSha.truthy && !source.recordSha.truthy { source.remoteIds = ownedValue }
                let kept = (source.remoteIds ?? .newArray()).elements.filter { ownedValue.includes($0) }
                verified.set(try localFailureKey(source.raw), Value.spread(source.raw, ["remoteIds": Value(kept)]))
            } catch {}
        }
    }
    for failure in (receipt.failed ?? .newArray()).elements.map(FailedSession.init) where failure.cloudAccount.truthy {
        let links = try verified.entries.filter { pair in
            try cloudTagged(failure.raw, pair.1).truthy && FailureSource(pair.1).remoteIds.includes(try remoteId(failure.id))
        }.map { $0.0 }
        if !links.isEmpty { failure.blockedByLocal = Value(links) }
        else { failure.raw.removeKey("blockedByLocal") }
    }
    let kept = try keptCopy(receipt)
    for check in (receipt.cloudChecks ?? .newArray()).elements.map(CloudCheck.init) {
        if check.status === "complete" || check.status === "cancelled" { continue }
        let failures = try (receipt.failed ?? .newArray()).elements.filter { try cloudTagged($0, check.raw).truthy && !(try kept.call($0)).truthy }
        let blocked = !failures.isEmpty && failures.allSatisfy { FailedSession($0).blockedByLocal["length"].truthy } && !check.waiting["length"].truthy &&
            check.checkedAt.truthy && !receipt.cloudError.truthy
        if blocked { check.status = "blocked-local" }
        else if check.status === "blocked-local" { check.status = "failed" }
    }
    return .undefined
}

// MARK: - Target checks

func changed(_ file: Value = .undefined, _ sessionId: Value = .undefined, _ knownValue: Value = .undefined) throws -> Value {
    let known = KnownTarget(knownValue)
    if !exists(file) { return false }
    if !known.semantic.truthy || known.semanticVersion !== Value(SEMANTIC_VERSION) { return true }
    let data = TranscriptLoad(try load(file))
    if try semantic(data.entries, sessionId, data.invalid) !== known.semantic { return true }
    return Value(!known.bridge.isUndefined && Value(data.entries.elements.contains { $0["type"] === "bridge-session" }) !== known.bridge)
}

func targetChanges(_ row: Value = .undefined, _ liveWorkers: Value = .undefined, _ checkShared: Value = .undefined, _ allowRecordDrift: Value = .undefined) throws -> Value {
    let checkShared = checkShared.isUndefined ? Value(true) : checkShared
    let allowRecordDrift = allowRecordDrift.isUndefined ? Value(false) : allowRecordDrift
    let session = PlacedSession(row)
    let changes = Value.newArray()
    if session.strategy === "rehome" {
        let currentFingerprint = (try? fingerprint(session.targetTranscript)) ?? .null
        if !currentFingerprint.truthy { changes.push("transcript missing") }
        else if checkShared.truthy && session.transcriptFingerprint.truthy && currentFingerprint !== session.transcriptFingerprint { changes.push("transcript") }
        else if try checkShared.truthy && !(try bridgeIntact(row)).truthy { changes.push("transcript") }
        let targetDir = session.targetDir ?? Value(path.join(path.dirname(str(session.targetTranscript)), str(session.targetId)))
        let sidecarsExist = !SidecarTree(session.sidecars).count.truthy || exists(targetDir)
        if !sidecarsExist { changes.push("sidecars missing") }
        else if try SidecarTree(session.sidecars).canonicalRoot.truthy && ((try? mappedPath(targetDir)) ?? .null) !== SidecarTree(session.sidecars).canonicalRoot ||
            checkShared.truthy && SidecarTree(session.sidecars).fingerprint.truthy && !(try sameTree(session.sidecars, (try? treeFingerprint(targetDir)) ?? .null)).truthy {
            changes.push("sidecars")
        }
    } else {
        if try !exists(session.targetTranscript) || (try changed(session.targetTranscript, session.targetId, try knownOf(row))).truthy { changes.push("transcript") }
        let targetDir = session.targetDir ?? Value(path.join(path.dirname(str(session.targetTranscript)), str(session.targetId)))
        let currentSidecars = (try? manifest(targetDir)) ?? .null
        if !currentSidecars.truthy || SidecarTree(currentSidecars).sha !== SidecarTree(session.sidecars).sha { changes.push("sidecars") }
    }
    let currentRecord = (try? readFile(session.record)) ?? .null
    var recordChanged = !currentRecord.truthy
    if currentRecord.truthy {
        do {
            let recordValue = try JSON.parse(currentRecord.asData ?? Data()), record = DesktopRecord(recordValue)
            if allowRecordDrift.truthy && session.recordSnapshot.truthy {
                var rewound = session.strategy === "rehome" && record.cliSessionId !== session.targetId && UUID.test((record.cliSessionId ?? "").description)
                if rewound { rewound = try priorSessions(recordValue).includes(session.targetId) }
                if rewound {
                    let detail = try? fs.stat(path.join(path.dirname(str(session.targetTranscript)), "\(record.cliSessionId).jsonl"))
                    rewound = detail?.isFile ?? false
                }
                recordChanged = try !validDesktopRecord(["file": session.record, "record": recordValue]).truthy ||
                    ["sessionId", "cwd", "originCwd"].contains(where: { recordValue[$0] !== session.recordSnapshot[$0] }) ||
                    DesktopRecord(session.recordSnapshot).cliSessionId !== session.targetId || (!rewound && record.cliSessionId !== session.targetId) || record.sessionId !== session.targetRecordId
            } else {
                recordChanged = try !session.recordSemantic.truthy || recordSemantic(recordValue) !== session.recordSemantic
            }
        } catch { recordChanged = true }
    }
    if recordChanged { changes.push("desktop record") }
    if try !allowRecordDrift.truthy && !session.taskFamily.truthy && session.taskFile.truthy &&
        Value(try taskRegistry(session.taskFile).notifies(session.targetRecordId ?? Value("local_\(session.targetId)"))) !== session.taskOwned { changes.push("scheduled tasks") }
    if try !allowRecordDrift.truthy && ownsWorker(liveWorkers, session.targetId, session.targetRecordId).truthy { changes.push("running worker") }
    return changes
}

func restoreProblems(_ plan: Value = .undefined, _ root: Value = .undefined, _ parkedOnly: Value = .undefined) throws -> Value {
    let parkedOnly = parkedOnly.isUndefined ? Value(false) : parkedOnly
    let problems = Value.newArray()
    func pairs(_ v: Value) -> ValueMap { ValueMap((v ?? .newArray()).elements.map { ($0[0], $0[1]) }) }
    for item in plan.elements.map(RetirementItem.init) {
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
                else if expectedTree.truthy && SidecarTree((try? manifest(available)) ?? .null).sha !== expectedTree { problems.push(changedText) }
                else if try expectedSemantic.truthy && recordSemantic((try? readJson(available)) ?? .newObject()) !== expectedSemantic { problems.push(changedText) }
            }
        }
    }
    return problems
}

func snapshotPlan(_ itemValue: Value = .undefined) throws -> Value {
    let item = RetirementItem(itemValue)
    let hashes = try (item.hashes ?? .newArray()).elements.map { pair -> Value in [pair[0], Value(sha(try readFile(pair[0])))] }
    let trees = try (item.trees ?? .newArray()).elements.map { pair -> Value in [pair[0], SidecarTree(try manifest(pair[0])).sha] }
    let semantics = try (item.semantics ?? .newArray()).elements.map { pair -> Value in [pair[0], try recordSemantic(try readJson(pair[0]))] }
    let plan = RetirementItem(Value.spread(itemValue, ["hashes": Value(hashes), "trees": Value(trees), "semantics": Value(semantics)]))
    for pair in item.moved.elements {
        let file = pair[0], parked = pair[1]
        if !LOCAL_RECORD.test(path.basename(str(file), ".json")) { continue }
        let temp = "\(file).tmp"
        let detail: FileStat
        do { detail = try fs.lstat(temp) }
        catch { if errorObject(error)["code"] === "ENOENT" { continue }; throw error }
        if !detail.isFile { throw EngineError("Desktop record temp is not a regular file: \(path.basename(temp))") }
        let raw = try readFile(Value(temp))
        if stable(try JSON.parse(raw.asData ?? Data())) != stable(try readJson(file)) { throw EngineError("Desktop record has a different pending update: \(path.basename(str(file)))") }
        plan.hashes.push([Value(temp), Value(sha(raw))])
        plan.required = Value((plan.required ?? .newArray()).elements + [Value(temp)])
        plan.moved = Value(plan.moved.elements + [[Value(temp), Value("\(parked).tmp")]])
    }
    return plan.raw
}

func verify(_ rows: Value = .undefined, _ report: Value = .undefined, _ check: Value = .undefined) throws -> Value {
    let report = fnOr(report), check = fnOr(check)
    var bad: [String: Int] = ["transcript": 0, "sidecars": 0, "desktop": 0]
    let problems = Value.newArray()
    func flag(_ key: String, _ r: PlacedSession) { bad[key, default: 0] += 1; problems.push(["id": r.targetId, "title": r.title, "check": Value(key)]) }
    let total = Value(rows.length)
    _ = try progress(report, "verify", 0, total)
    for (i, r) in rows.elements.map(PlacedSession.init).enumerated() {
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
