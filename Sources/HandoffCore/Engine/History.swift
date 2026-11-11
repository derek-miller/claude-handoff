import Darwin
import Foundation

// Transcript indexing, semantic shapes, lineage, conversation matching, supplemental cloud coverage
// and history inclusion.

// MARK: - Local helpers

// Unicode whitespace and line terminators.
fileprivate func isTextWhitespace(_ u: Unicode.Scalar) -> Bool {
    switch u.value {
    case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
    default: return false
    }
}
fileprivate func trimmed(_ s: Substring) -> String {
    // Fast path: ASCII on both ends, so only ASCII whitespace can be trimmed.
    let u = s.utf8
    var start = u.startIndex, end = u.endIndex
    while start < end, [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20].contains(u[start]) { start = u.index(after: start) }
    while start < end, [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20].contains(u[u.index(before: end)]) { end = u.index(before: end) }
    if start == end { return "" }
    if u[start] < 0x80 && u[u.index(before: end)] < 0x80 { return String(Substring(u[start..<end])) }
    return trimmedScalars(s)
}
fileprivate func trimmedScalars<S: StringProtocol>(_ s: S) -> String {
    let scalars = s.unicodeScalars
    guard let first = scalars.firstIndex(where: { !isTextWhitespace($0) }) else { return "" }
    let last = scalars.lastIndex(where: { !isTextWhitespace($0) })!
    return String(String.UnicodeScalarView(scalars[first...last]))
}

// raw.split('\n'): only LF separates lines; CR stays part of the line (and is removed by trim()).
fileprivate func lines(_ raw: String) -> [Substring] {
    raw.utf8.split(separator: 10, omittingEmptySubsequences: false).map { Substring($0) }
}

fileprivate func groupBy(_ xs: [Value], _ key: (Value) throws -> Value) rethrows -> ValueMap {
    let map = ValueMap()
    for x in xs {
        let k = try key(x)
        if let group = map.get(k).asArray { group.items.append(x) } else { map.set(k, Value([x])) }
    }
    return map
}

fileprivate func withoutList(_ entry: Value, _ keys: [String]) -> Value {
    let copy = entry.deepClone()
    for key in keys { copy.removeKey(key) }
    return copy
}

fileprivate func artifactFail(_ text: String, _ code: String = "CLOUD_ARTIFACT_UNCERTAIN") -> EngineError {
    makeError("Supplemental cloud coverage is uncertain: \(text)", code: code)
}

// lstat with BigInt fields, or null when the file does not exist.
fileprivate func lstatOrNull(_ file: String) throws -> FileStat? {
    do { return try fs.lstat(file, bigint: true) } catch {
        let e = errorObject(error)
        if e["code"] === "ENOENT" { return nil }
        throw EngineError(e)
    }
}

// Runs body, then closes handle; a close failure replaces the body's outcome.
fileprivate func closing<T>(_ handle: FileHandle, _ body: () throws -> T) throws -> T {
    let result = Result(catching: body)
    try handle.close()
    return try result.get()
}

fileprivate func flatArray(_ v: Value) -> [Value] { v.isArray ? v.elements : [v] }

// MARK: - Index and transcripts

func index(_ pool: Value = .undefined) throws -> Value {
    let map = ValueMap()
    let pool = pool.description
    for dir in (try? fs.names(pool)) ?? [] {
        let full = path.join(pool, dir)
        for name in (try? fs.names(full)) ?? [] {
            let id = sliceString(name, 0, -6)
            if name.hasSuffix(".jsonl") && UUID.test(id) {
                map.set(.string(id), Value(map.get(.string(id)).elements + [.string(path.join(full, name))]))
            }
        }
    }
    return .map(map)
}

func locate(_ index: Value = .undefined, _ id: Value = .undefined, _ cwd: Value = .undefined) throws -> Value {
    let cwd = cwd.isUndefined ? Value("") : cwd
    let paths = index.get(id) ?? Value.newArray()
    if paths.length == 1 { return paths[0] }
    // cwd.replace(/[^A-Za-z0-9]/g, '-') per UTF-16 code unit
    let units: [UInt16] = cwd.description.utf16.map { u in
        (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122) ? u : 45
    }
    let slug = String(decoding: units, as: UTF16.self)
    return paths.elements.first { path.basename(path.dirname($0.description)) == slug } ?? .null
}

public func scan(_ file: Value = .undefined) throws -> Value {
    let raw = try readFile(file, "utf8").description
    var ids: [Value] = []
    let forked = ValueMap()
    var invalid = 0
    for line in lines(raw) {
        productive()
        let text = trimmed(line)
        if text.isEmpty { continue }
        let e: Value
        do { e = try JSON.parse(text) } catch { invalid += 1; continue }
        if !(try message(e)).truthy { continue }
        ids.append(e["uuid"])
        if e["forkedFrom"]["messageUuid"].isString { forked.set(e["uuid"], e["forkedFrom"]) }
    }
    return ["file": file, "sha": Value(sha(raw)), "ids": ids.value, "forked": .map(forked), "invalid": Value(invalid)]
}

func load(_ file: Value = .undefined) throws -> Value {
    let raw = try readFile(file, "utf8").description
    var entries: [Value] = []
    var invalid = 0
    for line in lines(raw) {
        productive()
        let text = trimmed(line)
        if text.isEmpty { continue }
        do {
            let e = try JSON.parse(text)
            if e.isPlainObject { entries.append(e) }
        } catch { invalid += 1 }
    }
    return ["sha": Value(sha(raw)), "entries": entries.value, "invalid": Value(invalid)]
}

func without(_ entry: Value = .undefined, _ keys: Value = .undefined) throws -> Value {
    withoutList(entry, keys.elements.map { $0.description })
}

func recordSemantic(_ record: Value = .undefined) throws -> Value {
    Value(sha(stable(withoutList(record, RECORD_RUNTIME_KEYS))))
}

func semanticShape(_ entry: Value = .undefined) throws -> Value {
    Value(stable(withoutList(entry, RUNTIME_KEYS)))
}

let OUTPUT_KEYS = ["stdout", "stderr", "fileContent", "fileBase64"]
func toolOutput(_ entry: Value = .undefined) throws -> Value {
    let result = entry["toolUseResult"]
    return ["stdout": result["stdout"], "stderr": result["stderr"], "fileContent": result["file"]["content"], "fileBase64": result["file"]["base64"]]
}

func stripToolOutput(_ entry: Value = .undefined) throws -> Value {
    let result = entry["toolUseResult"]
    if result.isPlainObject {
        result.removeKey("stdout")
        result.removeKey("stderr")
        if result["file"]["content"].isString { result["file"].removeKey("content") }
        if result["file"]["base64"].isString { result["file"].removeKey("base64") }
    }
    return entry
}

func replayShape(_ entry: Value = .undefined) throws -> Value {
    let copy = try stripToolOutput(withoutList(entry, RUNTIME_KEYS))
    if copy["type"] === "attachment" && copy["attachment"]["type"] === "edited_text_file" { copy["attachment"].removeKey("displayPath") }
    return Value(stable(copy))
}
func richness(_ entry: Value = .undefined) throws -> Value {
    Value(try toolOutput(entry).ownEntries.reduce(0) { n, pair in n + (pair.1.asString.map { $0.utf8.count } ?? 0) })
}

func survivor(_ rows: Value = .undefined, _ ids: Value = .undefined) throws -> Value {
    if Set(try rows.elements.map { try replayShape($0["entry"]).description }).count != 1 { return .null }
    if rows.elements.contains(where: { $0["entry"]["parentUuid"].truthy && !ids.has($0["entry"]["parentUuid"]) }) { return .null }
    let keep = ValueObject()
    for k in OUTPUT_KEYS {
        let values = ValueSet(try rows.elements.map { try toolOutput($0["entry"])[k] }.filter { ($0.asString?.utf16.count ?? 0) > 0 })
        if values.size > 1 { return .null }
        keep[k] = values.values.first ?? ""
    }
    let ranked = try stableSorted(rows.elements) { a, b in
        let d = toNumber(try richness(b["entry"])) - toNumber(try richness(a["entry"]))
        return d != 0 && !d.isNaN ? d : toNumber(a["line"]) - toNumber(b["line"])
    }
    for r in ranked {
        let output = try toolOutput(r["entry"])
        if OUTPUT_KEYS.allSatisfy({ !keep[$0].truthy || output[$0] === keep[$0] }) { return r["line"] ?? .null }
    }
    return .null
}

func toolDetails(_ value: Value = .undefined, _ segments: Value = .undefined, _ detail: Value = .undefined) throws -> Value {
    let segments = segments.isUndefined ? Value.newArray() : segments
    let detail = detail.isUndefined ? Value.newObject() : detail
    if value.nullish || value === "" || (value.typeOf == "object" && value.ownKeys.isEmpty) { return detail }
    if value.typeOf == "object" && !value.isArray {
        for (key, child) in value.ownEntries { _ = try toolDetails(child, Value(segments.elements + [.string(key)]), detail) }
    } else {
        detail[JSON.text(segments)] = Value(sha(stable(["type": Value(value.isArray ? "array" : value.typeOf), "value": value])))
    }
    return detail
}
func detailIncluded(_ a: Value = .undefined, _ b: Value = .undefined) throws -> Value {
    Value(a.ownEntries.allSatisfy { b[$0.0] === $0.1 })
}
func replayDetails(_ entry: Value = .undefined) throws -> Value {
    try toolDetails(["toolUseResult": entry["toolUseResult"], "origin": ["producer": entry["origin"]["producer"]]])
}
func stripReplayMetadata(_ copy: Value = .undefined) throws -> Value {
    if copy["message"].isPlainObject { copy["message"].removeKey("usage") }
    if copy["origin"].isPlainObject {
        copy["origin"].removeKey("producer")
        if copy["origin"].ownKeys.isEmpty { copy.removeKey("origin") }
    }
    return copy
}
func omissionShape(_ entry: Value = .undefined, _ metadata: Value = .undefined) throws -> Value {
    let metadata = metadata.isUndefined ? Value(false) : metadata
    let copy = withoutList(entry, RUNTIME_KEYS + ["toolUseResult"])
    if metadata.truthy { _ = try stripReplayMetadata(copy) }
    if copy["type"] === "attachment" && copy["attachment"]["type"] === "edited_text_file" { copy["attachment"].removeKey("displayPath") }
    return Value(stable(copy))
}
func omissionSurvivor(_ rows: Value = .undefined, _ ids: Value = .undefined, _ metadata: Value = .undefined) throws -> Value {
    let metadata = metadata.isUndefined ? Value(false) : metadata
    if rows.elements.contains(where: { $0["entry"]["parentUuid"].truthy && !ids.has($0["entry"]["parentUuid"]) }) { return .null }
    if Set(try rows.elements.map { try omissionShape($0["entry"], metadata).description }).count != 1 { return .null }
    let candidates: [Value] = try rows.elements.map { row in
        Value.spread(row, ["detail": metadata.truthy ? try replayDetails(row["entry"]) : try toolDetails(row["entry"]["toolUseResult"]),
                           "size": Value(JSON.text(row["entry"]).utf8.count)])
    }
    let sorted = stableSorted(candidates) { a, b in
        let d = toNumber(b["size"]) - toNumber(a["size"])
        return d != 0 ? d : toNumber(a["line"]) - toNumber(b["line"])
    }
    for row in sorted {
        if try candidates.allSatisfy({ try detailIncluded($0["detail"], row["detail"]).truthy }) { return row["line"] ?? .null }
    }
    return .null
}

public func normalize(_ entries: Value = .undefined, _ omissions: Value = .undefined) throws -> Value {
    let omissions = omissions.isUndefined ? Value(true) : omissions
    let rows: [Value] = try entries.elements.enumerated().map { (line, entry) -> Value in ["entry": entry, "line": Value(line)] }
        .filter { try typed($0["entry"]).truthy }
    let groups = groupBy(rows) { $0["entry"]["uuid"] }
    let ids = Value.set(ValueSet(groups.keys))
    var drop = Set<Int>()
    var replays = 0
    var conflicts = 0
    for group in groups.values {
        if group.length < 2 { continue }
        var line = try survivor(group, ids)
        if line.nullish {
            if omissions.truthy {
                line = try omissionSurvivor(group, ids)
                if line.nullish { line = try omissionSurvivor(group, ids, true) }
            } else { line = .null }
        }
        if line.isNull { conflicts += 1; continue }
        replays += 1
        for r in group.elements where r["line"] !== line { drop.insert(r["line"].asInt!) }
    }
    let kept = entries.elements.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    return ["entries": kept.value, "replays": Value(replays), "conflicts": Value(conflicts)]
}

func sessionState(_ entries: Value = .undefined, _ sessionId: Value = .undefined, _ origin: Value = .undefined) throws -> Value {
    let origin = origin.isUndefined ? Value.newMap() : origin
    var replacements: [Value] = []
    var relocated = Value.null
    for e in entries.elements {
        if e["type"] === "content-replacement" && e["sessionId"] === sessionId && e["replacements"].isArray {
            for replacement in e["replacements"].elements {
                let copy = replacement.deepClone()
                if copy["uuid"].isString { copy["uuid"] = origin.get(copy["uuid"]) ?? copy["uuid"] }
                replacements.append(copy)
            }
        } else if e["type"] === "relocated" && e["sessionId"] === sessionId && e["relocatedCwd"].isString && e["relocatedCwd"].truthy {
            relocated = e["relocatedCwd"]
        }
    }
    return ["replacements": replacements.value, "suppressed": Value(entries.elements.contains { $0["type"] === "history-suppression" }), "relocated": relocated]
}

public func semantic(_ entries: Value = .undefined, _ sessionId: Value = .undefined, _ invalid: Value = .undefined) throws -> Value {
    let invalid = invalid.isUndefined ? Value(0) : invalid
    let normalized = try normalize(entries, false)
    let rows: [Value] = try normalized["entries"].elements.filter { try message($0).truthy }.map { Value(sha(try semanticShape($0).description)) }
    return Value(sha(stable(["rows": rows.value, "state": try sessionState(entries, sessionId), "invalid": invalid, "conflicts": normalized["conflicts"]])))
}

func scanLineage(_ ctx: Value = .undefined, _ transcript: Value = .undefined) throws -> Value {
    let forked = ctx["scans"].get(transcript)["forked"] ?? Value.newMap()
    let lineage = unique(forked.asMap?.values.map { $0["sessionId"] } ?? [])
    return ["forks": Value(forked.length), "lineage": lineage.value]
}

func scanned(_ id: Value = .undefined, _ ctx: Value = .undefined, _ cwd: Value = .undefined, _ dependencies: Value = .undefined) throws -> Value {
    let cwd = cwd.isUndefined ? Value("") : cwd
    let file = try locate(ctx["index"], id, cwd)
    if !file.truthy { return .null }
    dependencies.add(file)
    if !ctx["scans"].has(file) { ctx["scans"].put(file, try scan(file)) }
    return ctx["scans"].get(file)
}

func sidecars(_ transcript: Value = .undefined, _ id: Value = .undefined, _ cache: Value = .undefined) throws -> Value {
    let cache = cache.isUndefined ? Value.null : cache
    let root = path.join(path.dirname(transcript.description), id.description)
    return try manifest(Value(root), cache)
}

func sidecarsAgree(_ a: Value = .undefined, _ b: Value = .undefined) throws -> Value {
    let files = ValueMap(try a["rows"].elements.map { ($0["rel"], try sidecarIdentity($0)) })
    return Value(try b["rows"].elements.allSatisfy { row in try !files.has(row["rel"]) || files.get(row["rel"]) === (try sidecarIdentity(row)) })
}

func origins(_ id: Value = .undefined, _ ctx: Value = .undefined, _ cwd: Value = .undefined) throws -> Value {
    let cwd = cwd.isUndefined ? Value("") : cwd
    let out = ValueMap()
    let dependencies = Value.newSet()
    let own = try scanned(id, ctx, cwd, dependencies)
    for uuid in ValueSet((own["ids"] ?? Value.newArray()).elements).values {
        var cursor = uuid
        var session = own
        let seen = ValueSet()
        while session.truthy && !seen.has(cursor) {
            seen.add(cursor)
            let from = session["forked"].get(cursor)
            if !from.truthy { break }
            cursor = from["messageUuid"]
            session = try scanned(from["sessionId"], ctx, "", dependencies)
        }
        out.set(uuid, cursor)
    }
    return ["origin": .map(out), "dependencies": dependencies]
}

func lineageEvent(_ entry: Value = .undefined) throws -> Value {
    let c = try stripReplayMetadata(withoutList(entry, RUNTIME_KEYS))
    let detail = try replayDetails(entry)
    let ignored = [
        "uuid", "logicalParentUuid", "sessionId", "timestamp",
        "forkedFrom", "teamName", "agentName", "sessionKind", "sourceToolAssistantUUID", "neutralizedByFork",
    ]
    for k in ignored { c.removeKey(k) }
    c.removeKey("toolUseResult")
    return ["base": Value(sha(stable(c))), "detail": detail]
}

func eventIncluded(_ a: Value = .undefined, _ b: Value = .undefined) throws -> Value {
    Value(try b.truthy && a["base"] === b["base"] && (try detailIncluded(a["detail"], b["detail"])).truthy)
}

func messageHash(_ type: Value = .undefined, _ value: Value = .undefined) throws -> Value {
    Value(sha(stable(["type": type, "message": withoutList(value, MESSAGE_RUNTIME_KEYS)])))
}
func queuedContent(_ content: Value = .undefined, _ hash: Value = .undefined) throws -> Value {
    let hash = hash.isUndefined ? try messageHash("user", ["role": "user", "content": content]) : hash
    if content.isString { return ["hash": hash, "textHash": hash] }
    if content.isArray && content.length > 1 && content.elements.allSatisfy({ block in
        (block["type"] === "image" && block["source"].truthy && block["source"].isObjectLike && !block["source"].isArray) ||
            (block["type"] === "text" && block["text"].isString && block.ownKeys.allSatisfy { ["type", "text"].contains($0) })
    }) {
        let text = content.elements.filter { $0["type"] === "text" }
        if text.count == 1 { return ["hash": hash, "textHash": try messageHash("user", ["role": "user", "content": text[0]["text"]]), "richHash": hash] }
    }
    return ["hash": hash]
}
func queuedContentAgrees(_ a: Value = .undefined, _ b: Value = .undefined) throws -> Value {
    // (!a.hash || !b.hash || a.hash === b.hash || a.textHash && a.textHash === b.textHash) && (!a.richHash || !b.richHash || a.richHash === b.richHash)
    let first: Value = !a["hash"].truthy || !b["hash"].truthy || a["hash"] === b["hash"] ? .bool(true)
        : and(a["textHash"], Value(a["textHash"] === b["textHash"]))
    return and(first, Value(!a["richHash"].truthy || !b["richHash"].truthy || a["richHash"] === b["richHash"]))
}
func uniqueBridgeOwners(_ owners: Value = .undefined) throws -> Value {
    ValueMap(owners.elements.map { (Value(stable($0)), $0) }).values.value
}

public func conversation(_ entries: Value = .undefined, _ sessionId: Value = .undefined) throws -> Value {
    let sessionId = sessionId.isUndefined ? Value.null : sessionId
    let aliases = ValueMap()
    var output: [Value] = []
    var unidentified = Set<Int>()
    let consumedHashes = ValueSet()
    func identity(_ value: Value) -> Value { (value.asString?.isEmpty == false) ? value : .null }
    func root(_ start: Value) -> Value {
        var found = start
        while found["parent"].truthy { found = found["parent"] }
        var node = start
        while node["parent"].truthy { let next = node["parent"]; node["parent"] = found; node = next }
        return found
    }
    func merge(_ a: Value, _ b: Value) throws -> Value {
        if a === b { return a }
        b["parent"] = a
        if !a["bad"].truthy {
            a["bad"] = Value(try b["bad"].truthy || !(try queuedContentAgrees(a, b)).truthy
                || (a["userHash"].truthy && b["userHash"].truthy && a["userHash"] !== b["userHash"])
                || (a["consumedHash"].truthy && b["consumedHash"].truthy && a["consumedHash"] !== b["consumedHash"])
                || (a["command"].truthy && b["command"].truthy && a["command"] !== b["command"])
                || (a["delivery"].truthy && b["delivery"].truthy && a["delivery"] !== b["delivery"]))
        }
        if !a["mixed"].truthy { a["mixed"] = Value(b["mixed"].truthy || (a["hash"].truthy && b["hash"].truthy && a["hash"] !== b["hash"])) }
        if a["textHash"].nullish { a["textHash"] = b["textHash"] }
        if a["richHash"].nullish { a["richHash"] = b["richHash"] }
        if a["userHash"].nullish { a["userHash"] = b["userHash"] }
        a["userFirst"] = Value(min(toNumber(a["userFirst"]), toNumber(b["userFirst"])))
        if a["consumedHash"].nullish { a["consumedHash"] = b["consumedHash"] }
        if a["hash"].nullish { a["hash"] = b["hash"] }
        if a["command"].nullish { a["command"] = b["command"] }
        if a["delivery"].nullish { a["delivery"] = b["delivery"] }
        a["first"] = Value(min(toNumber(a["first"]), toNumber(b["first"])))
        return a
    }
    for entry in entries.elements {
        var hash = Value.null, command = Value.null, delivery = Value.null
        var eligible = false, bad = false, consumed = false
        var shape: Value = Value.newObject()
        let type = entry["type"]
        if entry.truthy && (type === "user" || type === "assistant") && entry["message"].truthy {
            hash = try messageHash(type, entry["message"])
            eligible = true
            if type === "user" {
                command = identity(entry["commandUuid"]) ?? identity(entry["uuid"])
                delivery = identity(entry["deliveryId"])
                if entry["message"]["role"] === "user" && entry["message"].ownKeys.allSatisfy({ (["role", "content"] + MESSAGE_RUNTIME_KEYS).contains($0) }) {
                    shape = try queuedContent(entry["message"]["content"], hash)
                }
            }
        } else if type === "attachment" && (entry["attachment"]["prompt"].isString || (sessionId.truthy && entry["attachment"]["type"] === "queued_command")) {
            let prompt = entry["attachment"]["prompt"]
            if prompt.isString || prompt.isArray { shape = try queuedContent(prompt); hash = shape["hash"] }
            command = identity(entry["attachment"]["commandUuid"]) ?? identity(entry["attachment"]["source_uuid"])
            delivery = identity(entry["attachment"]["delivery_id"])
            eligible = prompt.isString
            bad = !hash.truthy
        } else if sessionId.truthy && type === "queue-operation" && entry["sessionId"] === sessionId {
            command = identity(entry["commandUuid"])
            delivery = identity(entry["deliveryId"])
            let operation = entry["operation"]
            consumed = operation === "remove" && entry["reason"] === "absorbed_mid_turn"
            if entry["content"].isString || entry["content"].isArray { shape = try queuedContent(entry["content"]); hash = shape["hash"] }
            eligible = consumed && hash.truthy && (command.truthy || delivery.truthy)
            if eligible { consumedHashes.add(hash) }
            bad = (consumed && entry.hasOwn("content") && !hash.truthy) || (operation === "remove" && !consumed) || operation === "cancel" || operation === "dequeue"
        } else { continue }
        let own = entry["sessionId"] ?? sessionId
        if !sessionId.truthy || (!command.truthy && !delivery.truthy) {
            if eligible {
                if sessionId.truthy && own === sessionId && type !== "assistant" { unidentified.insert(output.count) }
                output.append(hash)
            }
            continue
        }
        var keys: [Value] = []
        if command.truthy { keys.append(Value(stable([own, "command", command]))) }
        if delivery.truthy { keys.append(Value(stable([own, "delivery", delivery]))) }
        var node = Value.spread(shape, [
            "hash": hash, "command": command, "delivery": delivery, "bad": Value(bad),
            "userHash": type === "user" ? hash : .null, "userFirst": Value(type === "user" ? Double(output.count) : .infinity),
            "consumedHash": consumed && eligible ? hash : .null, "first": Value(eligible ? Double(output.count) : .infinity),
        ])
        for key in keys where aliases.has(key) { node = try merge(root(aliases.get(key)), node) }
        for key in keys { aliases.set(key, node) }
        output.append(node)
    }
    var result: [Value] = []
    for (at, item) in output.enumerated() {
        if item.isString {
            if !(unidentified.contains(at) && consumedHashes.has(item)) { result.append(item) }
            continue
        }
        let group = root(item)
        let position = group["userHash"].truthy ? group["userFirst"] : group["first"]
        if !group["bad"].truthy && (!group["mixed"].truthy || group["userHash"].truthy || group["consumedHash"].truthy) && position === Value(Double(at)) {
            result.append(group["userHash"] ?? group["consumedHash"] ?? group["hash"])
        }
    }
    return result.value
}

func conversationFromRows(_ rows: Value = .undefined) throws -> Value {
    let messages = rows.elements.filter { $0["event_type"] === "user" || $0["event_type"] === "assistant" }
    if messages.contains(where: { row in
        let payload = row["payload"]
        return payload["type"] !== row["event_type"] || !payload["message"].truthy || payload["message"].typeOf != "object" || payload["message"].isArray
    }) { throw makeError("Remote Control message payload is unreadable", code: "CLOUD_HISTORY_UNREADABLE") }
    return try conversation(messages.map { $0["payload"] }.value)
}

func orderedConversation(_ source: Value = .undefined, _ target: Value = .undefined) throws -> Value {
    if !source.isArray || !target.isArray || source.length == 0 { return false }
    let items = source.elements
    var at = 0
    for event in target.elements where at < items.count && items[at] === event { at += 1 }
    return Value(at == items.count)
}

func multisetConversation(_ source: Value = .undefined, _ target: Value = .undefined) throws -> Value {
    let available = ValueMap()
    for event in target.elements { available.set(event, Value(toNumber(available.get(event) ?? 0) + 1)) }
    for event in source.elements {
        let countValue = toNumber(available.get(event) ?? 0)
        if countValue == 0 || countValue.isNaN { return false }
        available.set(event, Value(countValue - 1))
    }
    return true
}

func nearOrderedConversation(_ source: Value = .undefined, _ target: Value = .undefined, _ tolerance: Value = .undefined) throws -> Value {
    let positions = ValueMap()
    let targetItems = target.elements
    var lists: [[Int]] = []
    for (at, event) in targetItems.enumerated() {
        if !positions.has(event) { positions.set(event, Value(lists.count)); lists.append([]) }
        lists[positions.get(event).asInt!].append(at)
    }
    let tolerance = tolerance.asInt ?? 0
    var frontier = [Double](repeating: .infinity, count: tolerance + 1)
    frontier[0] = 0
    for event in source.elements {
        let matches = positions.get(event).asInt.map { lists[$0] } ?? []
        for skipped in stride(from: tolerance, through: 0, by: -1) {
            let start = frontier[skipped]
            var low = 0, high = matches.count
            while low < high {
                let mid = (low + high) / 2
                if Double(matches[mid]) < start { low = mid + 1 } else { high = mid }
            }
            frontier[skipped] = min(low < matches.count ? Double(matches[low] + 1) : .infinity, skipped > 0 ? frontier[skipped - 1] : .infinity)
        }
        if frontier.allSatisfy({ $0 == .infinity }) { return false }
    }
    return Value(frontier.contains { $0 != .infinity })
}

func conversationAnchored(_ source: Value = .undefined, _ target: Value = .undefined, _ needed: Value = .undefined) throws -> Value {
    let needed = toNumber(needed)
    if Double(source.length) < needed || Double(target.length) < needed { return false }
    let s = source.elements, t = target.elements
    let first = s.first ?? .undefined
    let n = Int(needed.isFinite ? needed : 0)
    var start = t.firstIndex(of: first) ?? -1
    outer: while start >= 0 {
        if n > 1 {
            for at in 1..<n where (at < s.count ? s[at] : .undefined) !== (start + at < t.count ? t[start + at] : .undefined) {
                start = t[(start + 1)...].firstIndex(of: first) ?? -1
                continue outer
            }
        }
        return true
    }
    return false
}

public func conversationMatch(_ source: Value = .undefined, _ target: Value = .undefined) throws -> Value {
    if !source.isArray || !target.isArray || source.length == 0 { return .null }
    if try orderedConversation(source, target).truthy { return "ordered" }
    let tolerance = min(8, source.length / 100)
    if try tolerance == 0 || !(try multisetConversation(source, target)).truthy { return .null }
    return try nearOrderedConversation(source, target, Value(tolerance)).truthy ? "equivalent" : .null
}

// MARK: - Supplemental cloud coverage

func artifactError(_ text: Value = .undefined, _ code: Value = .undefined) throws -> Value {
    artifactFail(text.description, code.isUndefined ? "CLOUD_ARTIFACT_UNCERTAIN" : code.description).value
}
func artifactBudget(_ limit: Value = .undefined) throws -> Value {
    let value = isSafeInteger(limit) && limit.asNumber! >= 0 ? min(ARTIFACT_BYTES, limit.asNumber!) : ARTIFACT_BYTES
    return ["limit": Value(value), "used": 0, "indexes": Value.newMap()]
}
func eventDescriptor(_ entry: Value = .undefined) throws -> Value {
    let out: Value = ["uuid": entry["uuid"], "type": entry["type"], "role": entry["message"]["role"],
                      "hash": try messageHash(entry["type"], entry["message"]), "timestamp": entry["timestamp"]]
    if !entry["agentId"].isUndefined { out["agentId"] = entry["agentId"] }
    if !entry["isSidechain"].isUndefined { out["isSidechain"] = entry["isSidechain"] }
    return out
}
func remoteEvents(_ rows: Value = .undefined) throws -> Value {
    try rows.elements.filter { $0["event_type"] === "user" || $0["event_type"] === "assistant" }.map { row -> Value in
        let event = try eventDescriptor(Value.spread(row["payload"], ["timestamp": row["payload"]["timestamp"] ?? row["created_at"]]))
        for key in ["agentId", "isSidechain"] where !row[key].isUndefined {
            event[key] = !event[key].isUndefined && event[key] !== row[key] ? .null : row[key]
        }
        return event
    }.value
}
func eventAgrees(_ a: Value = .undefined, _ b: Value = .undefined) throws -> Value {
    Value(a["uuid"] === b["uuid"] && a["type"] === b["type"] && a["role"] === b["role"] && a["hash"] === b["hash"])
}
func agentName(_ value: Value = .undefined) throws -> Value {
    Value(value.asString.map { re(#"^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}\z"#).test($0) } ?? false)
}
func statIdentity(_ detail: FileStat) -> Value { Value(detail.identity) }

func readRegular(_ file: Value = .undefined, _ signature: Value = .undefined) throws -> Value {
    let signature = signature.isUndefined ? Value.null : signature
    let name = file.description
    let before = try fs.lstat(name, bigint: true)
    if !before.isFile || (signature.truthy && statIdentity(before) !== signature) { throw EngineError("regular file changed before reading: \(name)") }
    let handle = try fs.open(name, O_RDONLY | O_NOFOLLOW, 0o666)
    return try closing(handle) {
        let identity = statIdentity(before)
        if try statIdentity(handle.stat(bigint: true)) !== identity { throw EngineError("regular file changed before reading: \(name)") }
        let data = try handle.readFile()
        if try statIdentity(handle.stat(bigint: true)) !== identity || (try statIdentity(fs.lstat(name, bigint: true))) !== identity {
            throw EngineError("regular file changed while reading: \(name)")
        }
        return .bytes(ValueBytes(data))
    }
}

struct ArtifactStat {
    let detail: FileStat
    let signature: Value
}

func artifactStat(_ file: Value = .undefined) throws -> ArtifactStat {
    let detail = try fs.lstat(file.description, bigint: true)
    if try !detail.isFile || (try fs.realpath(file.description)) != file.description {
        throw artifactFail("artifact is not a regular file within its session root")
    }
    return ArtifactStat(detail: detail, signature: statIdentity(detail))
}

func artifactInputs(_ row: Value = .undefined) throws -> Value {
    if try !UUID.test(row["id"].description) || path.basename(row["transcript"].description) != "\(row["id"]).jsonl" || (try desktopRecordOf(row))["cliSessionId"] !== row["id"] {
        throw artifactFail("the linked parent identity is not established")
    }
    let project = try fs.realpath(path.dirname(row["transcript"].description)), transcript = path.join(project, "\(row["id"]).jsonl")
    if row["sidecar"]["canonicalRoot"].truthy && Value(path.join(project, row["id"].description)) !== row["sidecar"]["canonicalRoot"] {
        throw artifactFail("session root mapping changed")
    }
    let signature = try artifactStat(Value(transcript)).signature, root = path.join(project, row["id"].description), directory = path.join(root, "subagents")
    var fingerprints: [Value] = [[Value(transcript), signature]]
    var files: [Value] = []
    for dir in [root, directory] {
        let detail = try lstatOrNull(dir)
        fingerprints.append([Value(dir), detail.map { statIdentity($0) } ?? .null])
        guard let detail else { break }
        if try !detail.isDirectory || (try fs.realpath(dir)) != dir { throw artifactFail("subagent root is not a real session directory") }
        if dir == directory {
            let entries = try fs.readdir(dir).enumerated().sorted { a, b in
                let c = localeCompare(a.element.name, b.element.name)
                return c < 0 || (c == 0 && a.offset < b.offset)
            }.map(\.element)
            for entry in entries {
                if !re(#"^agent-.+\.jsonl\z"#).test(entry.name) { continue }
                let agent = sliceString(entry.name, 6, -6), name = path.join(dir, entry.name)
                if try !entry.isFile || !(try agentName(Value(agent))).truthy { throw artifactFail("subagent entry is not a regular owned file") }
                let current = try artifactStat(Value(name))
                fingerprints.append([Value(name), current.signature])
                files.append(["file": Value(name), "agent": Value(agent), "modified": Value(Double(current.detail.mtimeNs / 1_000_000))])
            }
        }
    }
    return ["transcript": Value(transcript), "fingerprints": fingerprints.value, "files": files.value]
}

func artifactIndex(_ file: Value = .undefined, _ kind: Value = .undefined, _ budget: Value = .undefined) throws -> Value {
    let stat = try artifactStat(file)
    let signature = stat.signature
    let key = Value("\(file)/\(signature)/\(kind)")
    if budget["indexes"].has(key) { return budget["indexes"].get(key) }
    // Only a finished index is cached; a failure leaves no entry, so the next call retries.
    let name = file.description
    let size = Int(stat.detail.size)
    let handle = try fs.open(name, O_RDONLY | O_NOFOLLOW, 0o666)
    let result: Value = try closing(handle) {
        if try statIdentity(handle.stat(bigint: true)) !== signature { throw artifactFail("artifact changed before reading") }
        func read(_ length: Int, _ position: Int) throws -> Data {
            if toNumber(budget["used"]) + Double(length) > toNumber(budget["limit"]) {
                throw artifactFail("the shared read budget was exhausted", "CLOUD_ARTIFACT_BUDGET")
            }
            budget["used"] = Value(toNumber(budget["used"]) + Double(length))
            let data = try handle.read(length: length, position: Int64(position))
            if data.count != length { throw artifactFail("artifact changed while reading") }
            return data
        }
        var main: [Value] = [], events: [Value] = [], queued: [Value] = [], operations: [Value] = []
        var timestamp: Value? = nil
        if kind === "header" {
            let data = try read(min(size, 4096), 0)
            let newline = data.firstIndex(of: 10)
            let first = String(decoding: newline.map { data[data.startIndex..<$0] } ?? data[...], as: UTF8.self)
            let match = re(#""timestamp"\s*:\s*"([^"]{1,64})""#).match(first)
            timestamp = try milliseconds(match?[1].map { Value($0) } ?? .undefined)
        } else {
            var parts = Data(), length = 0, skip = false, classified = false
            let relevant: [String] = kind === "agent" ? ["user", "assistant"] : ["user", "assistant", "attachment", "queue-operation"]
            func consume() throws {
                if skip || length == 0 { return }
                let text = trimmed(Substring(String(decoding: parts, as: UTF8.self)))
                if text.isEmpty { return }
                let row: Value
                do { row = try JSON.parse(text) } catch { throw artifactFail("artifact contains an unreadable relevant line") }
                let type = row["type"]
                if !row.truthy || !(type.asString.map { relevant.contains($0) } ?? false) { return }
                let isMessage = type === "user" || type === "assistant"
                if isMessage && row["message"].isPlainObject {
                    let event = Value.spread(try eventDescriptor(row), ["sessionId": row["sessionId"]])
                    if kind === "agent" { events.append(event) } else if !row["isSidechain"].truthy { main.append(event) }
                } else if type === "attachment" && row["attachment"]["type"] === "queued_command" {
                    let item = row["attachment"], prompt = item["prompt"]
                    queued.append(Value.spread(["uuid": item["source_uuid"], "delivery": item["delivery_id"], "type": "user", "role": "user",
                                                "sessionId": row["sessionId"], "isSidechain": row["isSidechain"]],
                                               prompt.isString || prompt.isArray ? try queuedContent(prompt) : ["hash": .null]))
                } else if type === "queue-operation" {
                    let operation = row["operation"]
                    let consumed = operation === "remove" && row["reason"] === "absorbed_mid_turn"
                    let cancelled = (operation === "remove" && !consumed) || operation === "cancel" || operation === "dequeue"
                    operations.append(Value.spread(["uuid": row["commandUuid"], "delivery": row["deliveryId"], "sessionId": row["sessionId"], "consumed": Value(consumed),
                                                    "cancelled": Value(cancelled), "hasContent": Value(row.hasOwn("content"))],
                                                   row["content"].isString || row["content"].isArray ? try queuedContent(row["content"]) : ["hash": .null]))
                } else if isMessage { throw artifactFail("artifact message is unreadable") }
            }
            var position = 0
            while position < size {
                let chunk = try read(min(64 * 1024, size - position), position)
                position += chunk.count
                let bytes = [UInt8](chunk)
                var start = 0
                while start < bytes.count {
                    let newline = bytes[start...].firstIndex(of: 10)
                    let end = newline ?? bytes.count
                    if !skip {
                        parts.append(contentsOf: bytes[start..<end])
                        length += end - start
                        var type: String? = nil
                        if !classified {
                            let prefix = String(decoding: parts.prefix(4096), as: UTF8.self)
                            type = re(#"^\s*\{\s*"type"\s*:\s*"([^"]+)""#).match(prefix)?[1] ?? nil
                        }
                        classified = classified || type != nil || length >= 4096
                        if let type, !relevant.contains(type) { skip = true; parts = Data() }
                        else if Double(length) > ARTIFACT_LINE_BYTES { throw artifactFail("a relevant line exceeds 16 MiB", "CLOUD_ARTIFACT_LINE_LIMIT") }
                    }
                    if newline != nil { try consume(); parts = Data(); length = 0; skip = false; classified = false }
                    start = newline.map { $0 + 1 } ?? bytes.count
                }
            }
            try consume()
        }
        if try artifactStat(file).signature !== signature { throw artifactFail("artifact changed while reading") }
        let out: Value = ["main": main.value, "events": events.value, "queued": queued.value, "operations": operations.value]
        if let timestamp { out["timestamp"] = timestamp }
        return out
    }
    budget["indexes"].put(key, result)
    return result
}

func supplementalCoverage(_ events: Value = .undefined, _ row: Value = .undefined, _ budget: Value = .undefined, _ inputs: Value = .undefined) throws -> Value {
    if events.length == 0 { return .null }
    if try events.elements.contains(where: { event in
        try !UUID.test((event["uuid"] ?? "").description) || event["role"] !== event["type"] ||
            (!event["agentId"].isUndefined && !(try agentName(event["agentId"])).truthy) ||
            (!event["isSidechain"].isUndefined && event["isSidechain"].typeOf != "boolean")
    }) { throw artifactFail("remote event identity is incomplete") }
    let inputs = inputs.nullish ? try artifactInputs(row) : inputs
    let local = try artifactIndex(inputs["transcript"], "main", budget)
    let main = groupBy(local["main"].elements) { $0["uuid"] }
    let commands = groupBy(local["operations"].elements) { $0["uuid"] }, deliveries = groupBy(local["operations"].elements) { $0["delivery"] }
    let queues = ValueMap()
    for item in local["queued"].elements {
        let prior = queues.get(item["uuid"])
        if try !UUID.test((item["uuid"] ?? "").description) || !item["delivery"].isString || !item["delivery"].truthy || !item["hash"].truthy || item["sessionId"] !== row["id"] || item["isSidechain"].truthy ||
            (prior.truthy && (!(try eventAgrees(prior, item)).truthy || prior["delivery"] !== item["delivery"])) {
            throw artifactFail("queued prompt identity or replay copies disagree")
        }
        queues.set(item["uuid"], item)
    }
    var remainder: [Value] = [], pending: [Value] = [], queuedIds: [Value] = []
    var countMain = 0, countSubagent = 0, countQueued = 0
    let consumed = ValueSet()
    for event in events.elements {
        if main.has(event["uuid"]) {
            let copies = main.get(event["uuid"]).elements
            if try event["isSidechain"] === true || !event["agentId"].isUndefined || (try copies.contains { !(try eventAgrees($0, event)).truthy }) || consumed.has(event["uuid"]) {
                throw artifactFail("main event identity or multiplicity disagrees")
            }
            consumed.add(event["uuid"])
            remainder.append(event["hash"])
            countMain += 1
        } else if queues.has(event["uuid"]) {
            let item = queues.get(event["uuid"])
            let copies = ValueSet(commands.get(item["uuid"]).elements + deliveries.get(item["delivery"]).elements).values
            let delivered = copies.filter { $0["consumed"].truthy && $0["hasContent"].truthy }
            let disagree = try copies.contains { copy in
                if copy["cancelled"].truthy || copy["sessionId"] !== row["id"] { return true }
                if !copy["uuid"].isUndefined && copy["uuid"] !== item["uuid"] { return true }
                if !copy["delivery"].isUndefined && copy["delivery"] !== item["delivery"] { return true }
                return try copy["hasContent"].truthy && (!copy["hash"].truthy || !(try queuedContentAgrees(copy, item)).truthy)
            }
            if disagree || ValueSet(delivered.map { $0["hash"] }).size > 1 || ValueSet(([item] + copies).map { $0["richHash"] }.filter { $0.truthy }).size > 1 {
                throw artifactFail("queued prompt operation copies disagree")
            }
            let witness = Value.spread(item, ["hash": (delivered.first ?? .undefined)["hash"] ?? item["hash"]])
            if !(try eventAgrees(witness, event)).truthy || event["isSidechain"] === true || !event["agentId"].isUndefined || consumed.has(event["uuid"]) ||
                !copies.contains(where: { $0["consumed"].truthy && $0["uuid"] === item["uuid"] && $0["delivery"] === item["delivery"] && $0["sessionId"] === row["id"] }) {
                throw artifactFail("queued prompt delivery is not proven")
            }
            consumed.add(event["uuid"])
            queuedIds.append(event["uuid"])
            countQueued += 1
        } else { pending.append(event) }
    }
    if try !queuedIds.isEmpty && !(try orderedConversation(queuedIds.value, queues.keys.value)).truthy { throw artifactFail("queued prompt order disagrees") }
    if try !remainder.isEmpty && !(try conversationMatch(remainder.value, row["conversation"])).truthy { throw artifactFail("remaining main history does not match") }
    var files = inputs["files"].elements
    if !pending.isEmpty {
        let hinted = ValueSet(pending.flatMap { $0["agentId"].isUndefined ? [] : [$0["agentId"]] })
        if pending.allSatisfy({ !$0["agentId"].isUndefined }) { files = files.filter { hinted.has($0["agent"]) } }
        let times = try pending.map { toNumber(try milliseconds($0["timestamp"])) }.filter { $0 >= 0 }
        let earliest = times.reduce(Double.infinity) { Swift.min($0, $1) }, latest = times.reduce(-Double.infinity) { Swift.max($0, $1) }
        for file in files {
            let timestamp = toNumber(try artifactIndex(file["file"], "header", budget)["timestamp"])
            let modified = toNumber(file["modified"])
            file["priority"] = hinted.has(file["agent"]) ? 0 : times.isEmpty || timestamp < 0 || modified < timestamp ? 1 : timestamp <= latest && modified >= earliest ? 0 : 2
        }
        let found = ValueMap(), owners = ValueMap()
        let ordered = stableSorted(files) { a, b in
            let d = toNumber(a["priority"]) - toNumber(b["priority"])
            return d != 0 ? d : Double(localeCompare(a["file"].description, b["file"].description))
        }
        for file in ordered {
            let localEvents = try artifactIndex(file["file"], "agent", budget)["events"].elements
            let needed = pending.filter { $0["agentId"].isUndefined || $0["agentId"] === file["agent"] }
            let ids = ValueSet(needed.map { $0["uuid"] })
            let selected = localEvents.filter { ids.has($0["uuid"]) }
            let byId = groupBy(selected) { $0["uuid"] }
            for event in selected {
                if event["sessionId"] !== row["id"] || event["agentId"] !== file["agent"] || event["isSidechain"] !== true || main.has(event["uuid"]) || queues.has(event["uuid"]) ||
                    (owners.has(event["uuid"]) && owners.get(event["uuid"]) !== file["agent"]) {
                    throw artifactFail("subagent ownership or stream assignment disagrees")
                }
                owners.set(event["uuid"], file["agent"])
            }
            for copies in byId.values {
                if try copies.elements.contains(where: { !(try eventAgrees(copies[0], $0)).truthy }) { throw artifactFail("subagent payload, order or multiplicity disagrees") }
            }
            let stream = needed.filter { byId.has($0["uuid"]) }
            var at = 0
            for event in stream {
                if event["isSidechain"] === false { throw artifactFail("remote sidechain identity disagrees") }
                while at < selected.count, !(try eventAgrees(selected[at], event)).truthy { at += 1 }
                if at == selected.count { throw artifactFail("subagent payload, order or multiplicity disagrees") }
                at += 1
            }
            for event in stream { found.set(event, file["agent"]) }
            if found.size == pending.count { countSubagent = pending.count; break }
        }
    }
    for pair in inputs["fingerprints"].elements {
        let file = pair[0].description, signature = pair[1]
        let current = try lstatOrNull(file)
        if try (current.map { statIdentity($0) } ?? .null) !== signature || (current != nil && (try fs.realpath(file)) != file) {
            throw artifactFail("session artifacts changed during coverage analysis")
        }
    }
    if try mappedPath(row["transcript"]) !== inputs["transcript"] { throw artifactFail("session root mapping changed during coverage analysis") }
    if countSubagent != pending.count { return .null }
    let counts: Value = ["main": Value(countMain), "subagent": Value(countSubagent), "queued": Value(countQueued)]
    return ["matchMode": "artifacts", "artifactCounts": counts, "artifactSignature": Value(sha(stable(events)))]
}

// MARK: - History

func priorHistory(_ cache: Value = .undefined, _ key: Value = .undefined) throws -> Value {
    cache["used"]["histories"].add(key)
    let item = cache["data"]["histories"][key]
    let dependencies = item["value"]["dependencies"]
    let encoded = item["value"]["result"]
    if dependencies.isArray && encoded.truthy && encoded["events"].isArray && encoded["bridgeOwners"].isArray && encoded["contentSha"].isString {
        do {
            var current: [Value] = []
            for dependency in dependencies.elements {
                let file = dependency[0]
                current.append([file, try fingerprint(file, cache)])
            }
            if Value(sha(stable(current.value))) === item["signature"] {
                cache["stats"]["historyHits"] = Value(toNumber(cache["stats"]["historyHits"]) + 1)
                let events = Value.newMap(encoded["events"].elements.map { ($0[0], $0[1]) })
                return Value.spread(encoded, ["bridgeOwners": try uniqueBridgeOwners(encoded["bridgeOwners"]), "events": events,
                                              "roots": .set(ValueSet(events.asMap!.keys))])
            }
        } catch {}
    }
    cache["stats"]["historyMisses"] = Value(toNumber(cache["stats"]["historyMisses"]) + 1)
    return .null
}

func history(_ id: Value = .undefined, _ transcript: Value = .undefined, _ ctx: Value = .undefined, _ cwd: Value = .undefined) throws -> Value {
    let cwd = cwd.isUndefined ? Value("") : cwd
    let cacheKey: Value = ctx["cache"].truthy
        ? Value(sha(stable(["version": Value(CACHE_VERSION), "semanticVersion": Value(SEMANTIC_VERSION), "id": id, "transcript": transcript, "cwd": cwd])))
        : .null
    if ctx["cache"].truthy {
        let prior = try priorHistory(ctx["cache"], cacheKey)
        if prior.truthy { return prior }
    }
    let lineage = try origins(id, ctx, cwd)
    var dependencyRows: [Value] = []
    if ctx["cache"].truthy {
        for file in defaultSorted(lineage["dependencies"].elements) { dependencyRows.append([file, try fingerprint(file, ctx["cache"])]) }
    }
    let data = try load(transcript)
    let normalized = try normalize(data["entries"])
    let origin = lineage["origin"]
    let events = ValueMap(), seen = ValueSet()
    var conflicts = toNumber(normalized["conflicts"])
    for e in try normalized["entries"].elements.filter({ try message($0).truthy }) {
        let root = origin.get(e["uuid"]) ?? e["uuid"]
        let shape = try lineageEvent(e)
        let prior = events.get(root)
        if try !prior.truthy || (try eventIncluded(prior, shape)).truthy { events.set(root, shape) }
        else if !(try eventIncluded(shape, prior)).truthy && !seen.has(e["uuid"]) { conflicts += 1 }
        seen.add(e["uuid"])
    }
    let roots = ValueSet(events.keys)
    let state = Value(sha(stable(try sessionState(data["entries"], id, origin))))
    let comparable = data["invalid"] === 0 && conflicts == 0 && roots.size > 0
    let bridges = data["entries"].elements.filter { $0["type"] === "bridge-session" }
    let bridgeIds = unique(bridges.map { $0["bridgeSessionId"] ?? $0["bridge_session_id"] }.filter { $0.isString })
    let bridgeOwners = try uniqueBridgeOwners(try bridges.map { entry -> Value in
        ["id": try remoteId(entry["bridgeSessionId"] ?? entry["bridge_session_id"]), "sessionId": entry["sessionId"] ?? .null,
         "account": entry["ownerAccountUuid"] ?? .null, "org": entry["ownerOrganizationUuid"] ?? .null]
    }.value)
    let head: Value = ["roots": .set(roots), "events": .map(events), "conversation": try conversation(normalized["entries"], id)]
    let tail: Value = ["state": state, "bridge": Value(!bridges.isEmpty), "bridgeIds": bridgeIds.value, "bridgeOwners": bridgeOwners,
                       "invalid": data["invalid"], "conflicts": Value(conflicts), "comparable": Value(comparable),
                       "snapshot": try semantic(data["entries"], id, data["invalid"]), "contentSha": data["sha"]]
    let result = Value.spread(head, try scanLineage(ctx, transcript), tail)
    if ctx["cache"].truthy {
        let encoded = Value.spread(result, ["roots": .undefined, "events": events.entries.map { Value([$0.0, $0.1]) }.value])
        _ = try cacheStore(ctx["cache"], "histories", cacheKey, Value(sha(stable(dependencyRows.value))), ["dependencies": dependencyRows.value, "result": encoded])
    }
    return result
}

func sameEvents(_ a: Value = .undefined, _ b: Value = .undefined) throws -> Value {
    for (id, event) in a["events"].asMap?.entries ?? [] where !(try eventIncluded(event, b["events"].get(id))).truthy { return false }
    return true
}
func historyIncluded(_ a: Value = .undefined, _ b: Value = .undefined) throws -> Value {
    if a["sole"].truthy || b["sole"].truthy || !a["comparable"].truthy || !b["comparable"].truthy { return false }
    guard let x = a["roots"].asSet, let y = b["roots"].asSet else { throw EngineError.type("a.roots.isSubsetOf is not a function") }
    return Value(try x.isSubset(of: y) && a["state"] === b["state"] && (try sameEvents(a, b)).truthy)
}
func carries(_ a: Value = .undefined, _ b: Value = .undefined) throws -> Value {
    if !(a["sidecar"].truthy && b["sidecar"].truthy) { return false }
    guard let x = a["sidecar"]["set"].asSet, let y = b["sidecar"]["set"].asSet else { throw EngineError.type("a.sidecar.set.isSubsetOf is not a function") }
    return Value(x.isSubset(of: y))
}
func desktopRecordOf(_ row: Value = .undefined) throws -> Value { MoveSource(row).desktopRecord.raw }
func canShareRecord(_ a: Value = .undefined, _ b: Value = .undefined, _ requiredParents: Value = .undefined) throws -> Value {
    let first = try desktopRecordOf(a), second = try desktopRecordOf(b)
    if a["taskFamily"].truthy || b["taskFamily"].truthy {
        if !(a["taskFamily"] === b["taskFamily"] && first["sessionId"] === second["sessionId"]) { return false }
        return try sameAccount(a["account"], b["account"])
    }
    if first["sessionId"] !== second["sessionId"] && (requiredParents.has(first["sessionId"]) || requiredParents.has(second["sessionId"])) { return false }
    return Value(a["transcript"] === b["transcript"] || !(first["forkedFromSessionId"].truthy || second["forkedFromSessionId"].truthy))
}
func included(_ a: Value = .undefined, _ b: Value = .undefined) throws -> Value {
    let shared = try canShareRecord(a, b)
    if !shared.truthy { return shared }
    let history = try historyIncluded(a, b)
    if !history.truthy { return history }
    return try carries(a, b)
}
func progress(_ report: Value = .undefined, _ stage: Value = .undefined, _ completed: Value = .undefined, _ total: Value = .undefined, _ extra: Value = .undefined) throws -> Value {
    let extra = extra.isUndefined ? Value.newObject() : extra
    return try report.call(stage, Value("\(completed)/\(total)"), Value.spread(["live": true, "completed": completed, "total": total], extra))
}
func desktopFileOf(_ row: Value = .undefined) throws -> Value { row.isString ? row : MoveSource(row).desktopFile }
func taskLinks(_ record: Value = .undefined) throws -> Value {
    [record["sessionId"], record["cliSessionId"], record["scheduledTaskId"] ?? .null, record["notifySessionId"] ?? .null,
     record["forkedFromSessionId"] ?? .null, record["cwd"] ?? .null, record["originCwd"] ?? .null]
}
func bridgeIdsOf(_ row: Value = .undefined) throws -> Value {
    try ([row] + (row["members"] ?? Value.newArray()).elements).flatMap { member -> [Value] in
        let record = try desktopRecordOf(member)
        return (member["bridgeIds"] ?? Value.newArray()).elements + (record["bridgeSessionIds"] ?? Value.newArray()).elements
    }.value
}
func remoteIdsOf(_ row: Value = .undefined) throws -> Value {
    unique(try bridgeIdsOf(row).elements.map { try remoteId($0) }.filter { $0.truthy }).value
}
func sourceCloudLinks(_ sources: Value = .undefined) throws -> Value {
    try sources.elements.flatMap { source -> [Value] in
        try (source["members"] ?? Value([source])).elements.flatMap { member -> [Value] in
            let bridgeIds = try remoteIdsOf(member).elements.filter { id in
                try (member["bridgeOwners"] ?? Value.newArray()).elements.allSatisfy { owner in
                    try owner["id"] !== id ||
                        (try sameAccount(["account": owner["account"] ?? member["account"]["account"], "org": owner["org"] ?? member["account"]["org"]], member["account"])).truthy
                }
            }
            return bridgeIds.isEmpty ? [] : [Value.spread(try accountRef(member["account"]), ["targetId": source["cloudTargetId"] ?? source["id"], "bridgeIds": bridgeIds.value])]
        }
    }.value
}
func linkedCloudIds(_ links: Value = .undefined, _ account: Value = .undefined) throws -> Value {
    let rows = try links.elements.filter { try sameAccount($0, account).truthy }
    return unique(try rows.flatMap { flatArray($0["bridgeIds"]) }.map { try remoteId($0) }.filter { $0.truthy }).value
}
func retainedCloudChecks(_ receipt: Receipt, _ inv: MovePlan, _ current: Value = .undefined) throws -> Value {
    return try receipt.cloudChecks.elements.flatMap { check -> [Value] in
        if try (inv.cloud["checked"].truthy && (try sameAccount(check, inv.cloud)).truthy) ||
            (try inv.deferredCloudSources.elements.contains { try sameAccount(check, $0).truthy }) ||
            (try localCloudPending(try current.elements.first { try sameAccount($0, check).truthy } ?? .undefined)).truthy {
            return [check]
        }
        let sessionIds = try linkedCloudIds(receipt.cloudLinks, check)
        return sessionIds.length > 0 ? [Value.spread(check, ["sessionIds": sessionIds])] : []
    }.value
}
func validDesktopRecord(_ row: Value = .undefined) throws -> Value {
    let record = try desktopRecordOf(row)
    let file = try desktopFileOf(row)
    return Value(LOCAL_RECORD.test((record["sessionId"] ?? "").description) && file.isString && path.basename(file.description) == "\(record["sessionId"]).json")
}
