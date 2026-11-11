import Foundation

// Retirement into quarantine, Remote Control archival, cloud attempt bookkeeping and Undo of remote archives.

// Groups items by key, in first-seen key order.
fileprivate func groupBy(_ items: [Value], _ key: (Value) throws -> Value) rethrows -> [[Value]] {
    let index = ValueMap()
    var groups: [[Value]] = []
    for item in items {
        let k = try key(item)
        if let i = index.get(k).asInt { groups[i].append(item) } else {
            index.set(k, .number(Double(groups.count)))
            groups.append([item])
        }
    }
    return groups
}

// The work's result, or null if it throws.
fileprivate func orNull(_ work: () throws -> Value) -> Value {
    do { return try work() } catch { return .null }
}

// The elements of an iterable value; a non-iterable throws.
fileprivate func spreadable(_ v: Value) throws -> [Value] {
    switch v {
    case .array, .set, .map: return v.elements
    case .string(let s): return s.utf16.map { .string(String(utf16CodeUnits: [$0], count: 1)) }
    default: throw EngineError.type("\(v.description) is not iterable")
    }
}

fileprivate func isStopCode(_ error: Value) -> Bool {
    let code = error["code"]
    return code === "MOVE_STALLED" || code === "RESTART_REOPENED"
}

func retire(_ inv: Value = .undefined, _ to: Value = .undefined, _ receipt: Value = .undefined, _ paths: Value = .undefined, _ at: Value = .undefined, _ problems: Value = .undefined, _ save: Value = .undefined, _ report: Value = .undefined, _ check: Value = .undefined, _ snapshots: Value = .undefined) throws -> Value {
    let report = fnOr(report)
    let check = fnOr(check)
    let snapshots: Value = snapshots.isUndefined ? .null : snapshots
    try check.call(true)
    try report.call("retire", "checking", ["live": true])
    let retained = Value.newSet()
    let bad = Value.newSet(problems.elements.map { $0["id"] })
    let dest = path.join(paths["state"].description, "quarantine", at.description)
    var plan: [Value] = []
    var landed: [Value] = []
    for row in receipt["sessions"].elements {
        let history: Value = bad.has(row["targetId"]) ? .null : (inv["move"].elements.first { $0["id"] === row["id"] } ?? .undefined)
        if history.truthy { landed.append(["by": row["targetId"], "history": history]) }
    }
    var parentIds: [Value] = []
    for row in try spreadable(to["sessions"]) + spreadable(inv["move"]) {
        let parent = try desktopRecordOf(row)["forkedFromSessionId"]
        if parent.truthy { parentIds.append(parent) }
    }
    let requiredParents = Value.newSet(parentIds)
    let gone = Value.newSet()
    let blocked = Value.newSet()
    let sourceRows = Value.newMap()
    let targetRows = Value.newMap()
    var liveWorkers = try workers()
    let settled = Value.newMap()
    let targetStable = { (target: Value) throws -> Value in
        if !settled.has(target) { settled.put(target, try untouched(target, liveWorkers)) }
        return settled.get(target)
    }
    for entry in landed {
        let by = entry["by"], history = entry["history"]
        for t in inv["targets"].elements {
            if try gone.has(t) || requiredParents.has(t["record"]) || !t["transcript"].truthy || !included(t, history).truthy { continue }
            let claim = try ownership(t, liveWorkers)
            if claim.truthy {
                if !blocked.has(t["session"]["file"]) { receipt["failed"].push(["id": t["id"], "title": t["session"]["title"], "error": .string("\(claim) kept in destination")]) }
                blocked.add(t["session"]["file"])
                continue
            }
            if !(try targetStable(t)).truthy { continue }
            gone.add(t)
            let items: [Value] = [t["session"]["file"]]
            let item: Value = [
                "id": t["id"],
                "title": t["session"]["title"],
                "by": by,
                "required": Value(items),
                "hashes": [[t["session"]["file"], .null]],
                "trees": [],
                "moved": Value(items.map { p in [p, .string(path.join(dest, "superseded", path.basename(p.description)))] as Value })
            ]
            plan.append(item)
            targetRows.put(t["session"]["file"], t)
        }
    }
    var stableTargets: [Value] = []
    for target in inv["targets"].elements {
        if gone.has(target) || !target["transcript"].truthy { continue }
        var anySource = false
        for source in inv["sources"].elements where try included(source, target).truthy { anySource = true; break }
        if anySource, try targetStable(target).truthy { stableTargets.append(target) }
    }
    let carried = Value(landed + stableTargets.map { history in ["by": history["id"], "history": history] as Value })
    let ready = Value.newMap(try owners(inv["sources"], carried).elements.map { ($0["s"], $0["owner"]) })
    let expected = Value.newSet(try owners(inv["sources"], carrying(inv, Value(landed), gone)).elements.map { $0["s"] })
    var checkedSources = 0
    try progress(report, "retire", Value(checkedSources), Value(inv["sources"].length))
    for s in inv["sources"].elements {
        var bodyError: Error? = nil
        do {
            func body() throws {
                if receipt["held"].elements.contains(where: { held in held["sources"].elements.contains { $0["file"] === s["file"] } }) { return }
                let owner = ready.get(s)
                if !owner.truthy {
                    if expected.has(s) { receipt["failed"].push(Value.spread(["id": s["id"], "title": s["title"], "error": "destination changed since inventory, source kept"], try failureIdentity(s))) }
                    return
                }
                let claim = try retirementOwnership(inv, s, owner, liveWorkers)
                if claim.truthy {
                    receipt["failed"].push(Value.spread(["id": s["id"], "title": s["title"], "error": .string("\(claim) kept in source")], try failureIdentity(s)))
                    return
                }
                let moved: Value = [[s["file"], .string(path.join(dest, "sources", path.relative(paths["records"].description, s["file"].description)))]]
                plan.append(["id": s["id"], "title": s["title"], "by": owner["by"], "source": true, "required": [s["file"]], "hashes": [[s["file"], .null]], "moved": moved])
                sourceRows.put(s["file"], s)
            }
            try body()
        } catch { bodyError = error }
        checkedSources += 1
        try progress(report, "retire", Value(checkedSources), Value(inv["sources"].length))
        if let bodyError { throw bodyError }
    }
    try report.call("finalize", "preparing", ["live": true])
    let carriers = Value.newMap(receipt["sessions"].elements.map { ($0["targetId"], $0) })
    for target in stableTargets where !carriers.has(target["id"]) { carriers.put(target["id"], target) }
    liveWorkers = try workers()
    settled.asMap!.clearAll()
    let invalid = Value.newSet()
    let carrierChecks = Value.newMap()
    for item in plan {
        if invalid.has(item["by"]) { continue }
        let carrier = carriers.get(item["by"])
        if !carrierChecks.has(item["by"]) {
            let valid: Value
            if carrier["targetId"].truthy {
                valid = Value(try targetChanges(carrier, liveWorkers, Value(carrier["strategy"] !== "rehome")).length == 0)
            } else if carrier.truthy {
                valid = try targetStable(carrier)
            } else { valid = false }
            carrierChecks.put(item["by"], valid)
        }
        let valid = carrierChecks.get(item["by"])
        if !valid.truthy { invalid.add(item["by"]) }
    }
    if invalid.length > 0 {
        for id in invalid.elements {
            let members = Value(plan.filter { $0["by"] === id && $0["source"].truthy }.map { sourceRows.get($0["moved"][0][0]) })
            receipt["failed"].push(Value.spread(["id": id, "title": "destination", "error": "destination changed before retirement, source kept"], try failureIdentity(["members": members])))
        }
        plan = plan.filter { !invalid.has($0["by"]) }
    }
    var readyPlan: [Value] = []
    for item in plan {
        let row = (item["source"].truthy ? sourceRows : targetRows).get(item["moved"][0][0])
        let unchanged: Value = row.truthy ? try untouched(row, liveWorkers, Value(row["strategy"] !== "rehome")) : row
        if !row.truthy || !unchanged.truthy {
            let identity: Value = item["source"].truthy && row.truthy ? try failureIdentity(row) : [:]
            receipt["failed"].push(Value.spread(["id": item["id"], "title": item["title"], "error": .string("\(item["source"].truthy ? "source" : "destination") changed before retirement, kept")], identity))
        } else { readyPlan.append(try snapshotPlan(item)) }
    }
    plan = readyPlan
    if plan.isEmpty { return retained }
    let root = path.dirname(dest)
    let retiringRows = { (items: [Value]) -> Value in Value(items.flatMap { item in item["source"].truthy ? [sourceRows.get(item["moved"][0][0])] : [] }) }
    let restoreItems = { (items: [Value]) throws in
        let blockedItems = try restoreProblems(Value(items), .string(root), true)
        if blockedItems.length > 0 { throw EngineError("retirement rollback blocked: \(blockedItems.join(", "))") }
        try restore(Value(items), .string(root))
    }
    do {
        let directories = Value.newSet(plan.map { .string(path.dirname($0["moved"][0][0].description)) })
        let parents = try parentReferences(directories, snapshots, check)
        let retiring = Value.newSet(plan.map { $0["moved"][0][0] })
        var kept = (parents.asMap?.keys ?? []).filter { !retiring.has($0) }
        var k = 0
        while k < kept.count {
            let parent = parents.get(kept[k])
            if retiring.delete(parent) { kept.append(parent) }
            k += 1
        }
        for item in plan where item["source"].truthy && !retiring.has(item["moved"][0][0]) { retained.add(item["moved"][0][0]) }
        plan = plan.filter { retiring.has($0["moved"][0][0]) }
        if plan.isEmpty { return retained }
        let checkParents = { (parked: Bool) throws in
            for pair in try parentReferences(directories, snapshots, check).elements {
                let file = pair[0], parent = pair[1]
                if retiring.has(parent) && (parked || !retiring.has(file)) { throw EngineError("parent reference changed during retirement: \(file)") }
            }
        }
        let carrierSafe = { (id: Value, live: Value) throws -> Bool in
            let carrier = carriers.get(id)
            if carrier["targetId"].truthy { return try targetChanges(carrier, live, Value(carrier["strategy"] !== "rehome")).length == 0 }
            return carrier.truthy ? try untouched(carrier, live, Value(carrier["strategy"] !== "rehome")).truthy : false
        }
        let groups = { (items: [Value], work: ([Value]) throws -> Void) throws -> [Value] in
            var done: [Value] = []
            for group in groupBy(items, { $0["by"] }) {
                do { try work(group); done.append(contentsOf: group) }
                catch {
                    let error = errorObject(error)
                    if isStopCode(error) { throw EngineError(error) }
                    try restoreItems(group)
                    receipt["failed"].push(Value.spread(["id": group[0]["id"], "title": group[0]["title"], "error": error["message"]], try failureIdentity(["members": retiringRows(group)])))
                }
            }
            return done
        }
        receipt["retiring"] = Value(plan)
        try save.call()
        try check.call(true)
        try checkParents(false)
        let parkWorkers = try workers()
        let parked = try groups(plan) { group in
            try park(Value(group), Value { args in
                let item = args.first ?? .undefined
                try check.call()
                if !(try carrierSafe(item["by"], parkWorkers)) { throw EngineError("destination changed during retirement: \(item["by"])") }
                let carrier = carriers.get(item["by"]), carrierId = carrier["targetId"] ?? carrier["id"]
                if carrierId.truthy {
                    guard let text = carrierId.asString else { throw EngineError.type("carrierId.toLowerCase is not a function") }
                    if parkWorkers.has(Value(text.lowercased())) { throw EngineError("running worker changed during retirement: \(item["id"])") }
                }
                let row = (item["source"].truthy ? sourceRows : targetRows).get(item["moved"][0][0])
                if try !row.truthy || !untouched(row, parkWorkers, Value(row["strategy"] !== "rehome")).truthy {
                    throw EngineError("\(item["source"].truthy ? "source" : "destination") changed during retirement: \(item["id"])")
                }
                return .undefined
            })
        }
        try check.call(true)
        let postWorkers = try workers()
        plan = try groups(parked) { group in
            if !(try carrierSafe(group[0]["by"], postWorkers)) { throw EngineError("destination changed after retirement: \(group[0]["by"])") }
            for item in group.filter({ $0["source"].truthy }) {
                let row = sourceRows.get(item["moved"][0][0])
                if try !row.truthy || !witnessed(row, postWorkers, Value(row["strategy"] !== "rehome")).truthy { throw EngineError("source changed after retirement: \(item["id"])") }
            }
        }
        try checkParents(true)
    } catch {
        let error = errorObject(error)
        if isStopCode(error) { throw EngineError(error) }
        try restoreItems(plan)
        receipt["retiring"] = .null
        receipt["failed"].push(Value.spread(["id": .null, "title": "retirement", "error": error["message"]], try failureIdentity(["members": retiringRows(plan)])))
        try save.call()
        return retained
    }
    receipt["superseded"] = Value(try spreadable(receipt["superseded"]) + plan)
    receipt["retiring"] = .null
    try save.call()
    return retained
}

fileprivate extension ValueMap {
    func clearAll() { for k in keys { delete(k) } }
}

let REMOTE_OPEN: Set<String> = ["active", "paused"]
let REMOTE_IDLE: Set<String> = [
    "WORKER_STATUS_UNSPECIFIED", "WORKER_STATUS_IDLE", "WORKER_STATUS_DISCONNECTED",
    "idle", "disconnected", "stopped",
]
fileprivate func setHas(_ set: Set<String>, _ v: Value) -> Bool { v.asString.map { set.contains($0) } ?? false }

func remoteOpen(_ session: Value = .undefined) throws -> Value {
    Value(session["connection_status"] === "connected" || session["client_presence"].isArray && session["client_presence"].length > 0)
}
func remoteBusy(_ session: Value = .undefined) throws -> Value {
    Value(session["connection_status"] !== "disconnected" ||
        !session["client_presence"].isArray || session["client_presence"].length > 0 ||
        !setHas(REMOTE_IDLE, session["worker_status"]))
}
func remoteStateSha(_ rows: Value = .undefined) throws -> Value {
    var text = "["
    var separator = ""
    for row in rows.elements {
        let type = row["event_type"]
        let wanted: Bool
        if type === "user" || type === "assistant" { wanted = true } else {
            guard let s = type.asString else { throw EngineError.type("Cannot read properties of \(type.description) (reading 'startsWith')") }
            wanted = s.hasPrefix("control_")
        }
        if wanted {
            text += separator + stable(row)
            separator = ","
        }
    }
    text += "]"
    return .string(sha(text))
}

func remoteActionsPending(_ session: Value = .undefined) throws -> Value {
    let metadata = session["external_metadata"]
    if !metadata.nullish && (!metadata.isObjectLike || metadata.isArray) { return true }
    for candidate in [session["requires_action_details_list"], metadata["pending_action"], metadata["pending_actions"]] {
        var value = candidate
        if let s = value.asString {
            do { value = try JSON.parse(s) } catch { return true }
        }
        if !value.nullish && !(value.isArray && value.length == 0) { return true }
    }
    return false
}

func assertRemoteIdle(_ session: Value = .undefined) throws -> Value {
    if !setHas(REMOTE_OPEN, session["status"]) { throw EngineError("Remote Control status changed to \(session["status"] ?? "unknown")") }
    if try remoteBusy(session).truthy {
        throw makeError("Remote Control session is not proven disconnected and idle", code: try remoteOpen(session).truthy ? "REMOTE_OPEN" : "REMOTE_STATE_UNKNOWN")
    }
    if try remoteActionsPending(session).truthy { throw EngineError("Remote Control has pending actions or unreadable action state") }
    let type = session["last_event_at"].typeOf
    if type != "string" && type != "number" { throw EngineError("Remote Control event marker is missing") }
    return session["last_event_at"]
}

func stableRemoteRows(_ cloud: Value = .undefined, _ id: Value = .undefined) throws -> Value {
    let before = try cloud["session"].call(id)
    let marker = try assertRemoteIdle(before)
    let rows = try cloud["eventRows"].call(id)
    let after = try cloud["session"].call(id)
    _ = try assertRemoteIdle(after)
    if after["last_event_at"] !== marker { throw EngineError("Remote Control history changed while reading") }
    return ["rows": rows, "marker": marker, "stateSha": try remoteStateSha(rows), "session": after]
}

func waitRemote(_ cloud: Value = .undefined, _ id: Value = .undefined, _ statuses: Value = .undefined) throws -> Value {
    var current: Value = .null
    for _ in 0..<12 {
        current = try cloud["session"].call(id)
        if statuses.includes(current["status"]) { return current }
        process.sleep(250)
    }
    return current
}

func remoteReceipt(_ match: Value = .undefined) throws -> Value {
    let base: Value = [
        "id": match["session"]["id"],
        "title": match["session"]["title"],
        "account": match["account"]["account"],
        "accountLabel": match["account"]["label"],
        "org": match["account"]["org"],
        "status": match["session"]["status"],
        "conversationSha": match["conversationSha"],
        "targetId": match["target"]["id"],
        "targetKind": match["target"]["kind"],
        "matchMode": match["target"]["matchMode"],
    ]
    return Value.spread(base, match["target"]["artifactCounts"].truthy ? ["artifactCounts": match["target"]["artifactCounts"]] : [:])
}

func targetActivation(_ row: Value = .undefined, _ keepArchived: Value = .undefined) throws -> Value {
    let keepArchived: Value = keepArchived.isUndefined ? false : keepArchived
    let candidate = row["record"] ?? ""
    guard let candidatePath = candidate.asString else { throw EngineError.type("The \"path\" argument must be of type string. Received \(candidate.typeOf)") }
    let record = path.isAbsolute(candidatePath) ? row["record"] : row["session"]["file"]
    let raw: Value = record.truthy ? orNull { try readFile(record, "utf8") } : .null
    if !raw.truthy { throw EngineError("local target record is missing") }
    let current = try JSON.parse(raw.description)
    if try recordSemantic(current) !== row["recordSemantic"] { throw EngineError("local target record changed before Remote Control archival") }
    if keepArchived.truthy || current["isArchived"] !== true { return .null }
    let after = Value.spread(current, ["isArchived": false])
    let afterText = jsonText(after)
    return [
        "record": record, "beforeSha": .string(sha(raw.description)), "beforeSemantic": try recordSemantic(current),
        "afterSha": .string(sha(afterText)), "afterSemantic": try recordSemantic(after), "after": after,
    ]
}

func applyActivation(_ activation: Value = .undefined, _ row: Value = .undefined) throws -> Value {
    if !activation.truthy { return .undefined }
    if Value(sha(try readFile(activation["record"]))) !== activation["beforeSha"] { throw EngineError("local target record changed before activation") }
    try saveText(activation["record"], .string(jsonText(activation["after"])))
    if Value(sha(try readFile(activation["record"]))) !== activation["afterSha"] { throw EngineError("local target activation verification failed") }
    row["recordSha"] = activation["afterSha"]
    row["recordSnapshot"] = recordSnapshot(activation["after"])
    row["recordSemantic"] = activation["afterSemantic"]
    row["archived"] = false
    if row["session"].truthy {
        row["session"]["record"] = activation["after"]
        row["session"]["archived"] = false
    }
    activation.removeKey("after")
    return .undefined
}

func activationProblems(_ receipt: Value = .undefined) throws -> Value {
    let problems = Value.newArray()
    for row in (try spreadable(receipt["remote"] ?? []) + [receipt["remotePending"]]).filter({ $0.truthy }) {
        let activation = row["activation"]
        if !activation.truthy { continue }
        let raw = orNull { try readFile(activation["record"]) }
        var unchanged = raw.truthy
        do {
            if raw.truthy, let data = raw.asData {
                let semantic = try recordSemantic(try JSON.parse(data))
                unchanged = semantic === activation["beforeSemantic"] || semantic === activation["afterSemantic"]
            }
        } catch { unchanged = false }
        if !unchanged { problems.push(.string("\(row["title"]) | activated target record changed")) }
    }
    return problems
}

func restoreActivations(_ receipt: Value = .undefined) throws -> Value {
    for row in try spreadable(receipt["remote"] ?? []).reversed() {
        let activation = row["activation"]
        if !activation.truthy || !exists(activation["record"]) { continue }
        let current = try readJson(activation["record"])
        let semantic = try recordSemantic(current)
        if semantic === activation["beforeSemantic"] { continue }
        if semantic !== activation["afterSemantic"] { throw EngineError("activated target record changed during Undo") }
        try saveJson(activation["record"], Value.spread(current, ["isArchived": true]))
    }
    return .undefined
}

func rollbackActivation(_ activation: Value = .undefined, _ row: Value = .undefined) throws -> Value {
    let row: Value = row.isUndefined ? .null : row
    if !activation.truthy { return .undefined }
    let raw = orNull { try readFile(activation["record"]) }
    var current: Value = .null
    do { if raw.truthy, let data = raw.asData { current = try JSON.parse(data) } } catch {}
    let semantic: Value = current.truthy ? try recordSemantic(current) : .null
    if !(semantic === activation["beforeSemantic"] || semantic === activation["afterSemantic"]) { throw EngineError("activated target record changed during recovery") }
    let restored = semantic === activation["afterSemantic"] ? Value.spread(current, ["isArchived": true]) : current
    let text: Value = semantic === activation["afterSemantic"] ? .string(jsonText(restored)) : raw
    if semantic === activation["afterSemantic"] { try saveText(activation["record"], text) }
    if row.truthy {
        row["recordSha"] = .string(sha(text))
        row["recordSnapshot"] = recordSnapshot(restored)
        row["recordSemantic"] = try recordSemantic(restored)
        row["archived"] = true
        if row["session"].truthy {
            row["session"]["record"] = restored
            row["session"]["archived"] = true
        }
    }
    return .undefined
}

func receiptCloudCheck(_ receipt: Value = .undefined, _ cloud: Value = .undefined) throws -> Value {
    for check in (receipt["cloudChecks"] ?? []).elements where try sameAccount(check, cloud).truthy { return check }
    return .null
}

func clearCloudAttempt(_ receipt: Value = .undefined, _ cloud: Value = .undefined, _ retain: Value = .undefined) throws -> Value {
    let retain = retain.isUndefined ? Value { _ in false } : retain
    receipt["failed"] = Value(try (receipt["failed"] ?? []).elements.filter { failure in
        try !cloudTagged(failure, cloud).truthy || failure["blockedByLocal"]["length"].truthy || retain.call(failure).truthy
    })
    receipt["cloudError"] = .null
    if receipt["verification"].truthy {
        let retried = try (receipt["verification"]["problems"] ?? []).elements.contains { try cloudTagged($0, cloud).truthy }
        receipt["verification"]["problems"] = Value(try (receipt["verification"]["problems"] ?? []).elements.filter { try !cloudTagged($0, cloud).truthy })
        receipt["verification"]["ok"] = Value(receipt["verification"]["problems"].length == 0 && (receipt["verification"]["ok"] !== false || retried))
    }
    let check = try receiptCloudCheck(receipt, cloud)
    if check.truthy {
        check["status"] = "pending"
        check.removeKey("failures")
        check.removeKey("waiting")
        check.removeKey("later")
        check.removeKey("checkedAt")
    }
    return check
}

func addCloudFailure(_ receipt: Value = .undefined, _ cloud: Value = .undefined, _ failure: Value = .undefined) throws -> Value {
    let check = try receiptCloudCheck(receipt, cloud)
    if failure["code"] === "REMOTE_OPEN" && check.truthy {
        check["waiting"] = Value(try spreadable(check["waiting"] ?? []) + [["id": failure["id"], "title": failure["title"], "localId": failure["localId"] ?? .null]])
    } else { receipt["failed"].push(try taggedCloudFailure(cloud, failure)) }
    return .undefined
}

func finishCloudAttempt(_ receipt: Value = .undefined, _ cloud: Value = .undefined, _ later: Value = .undefined, _ waiting: Value = .undefined, _ options: Value = .undefined) throws -> Value {
    let later: Value = later.isUndefined ? [] : later
    let waiting: Value = waiting.isUndefined ? [] : waiting
    let options: Value = options.isUndefined ? [:] : options
    let check = try receiptCloudCheck(receipt, cloud)
    if !check.truthy { return .null }
    let failures = try receipt["failed"].elements.filter { try cloudTagged($0, cloud).truthy }
    let budget = try memorySignature(try options["memory"] ?? cloud["memory"] ?? operationMemory())
    let isolatedId = options.hasOwn("isolatedId") ? options["isolatedId"] : cloud["isolatedId"]
    let limitCodes: [Value] = ["CLOUD_MEMORY_BUDGET", "CLOUD_HISTORY_LIMIT", "CLOUD_BUDGET_LIMIT", "CLOUD_PARSER_LIMIT"]
    for failure in failures {
        if try failure["code"] === "CLOUD_MEMORY_BUDGET" && !isolatedId.isUndefined && remoteId(failure["id"]) === isolatedId { failure["code"] = "CLOUD_BUDGET_LIMIT" }
        if limitCodes.contains(failure["code"]) {
            if failure["limitEngine"].nullish { failure["limitEngine"] = try artifactEngine() }
            if failure["code"] !== "CLOUD_HISTORY_LIMIT" && failure["limitBudget"].nullish { failure["limitBudget"] = budget }
        }
    }
    let kept = try keptCopy(receipt)
    let open = try failures.filter { try !kept.call($0).truthy }
    check["attemptEngine"] = try artifactEngine()
    check["attemptBudget"] = budget
    if !open.isEmpty && open.allSatisfy({ $0["code"] === "CLOUD_AUTH_PENDING" }) { check["authRetries"] = Value(toNumber(check["authRetries"] ?? 0) + 1) }
    else { check.removeKey("authRetries") }
    let byId = ValueMap()
    for row in try spreadable(check["waiting"] ?? []) + spreadable(waiting) { byId.set(row["id"], row) }
    check["waiting"] = Value(byId.values)
    if !open.isEmpty {
        check["status"] = open.allSatisfy({ $0["blockedByLocal"]["length"].truthy }) && check["waiting"].length == 0 ? "blocked-local" : "failed"
    } else {
        check["status"] = check["waiting"].length > 0 ? "waiting" : "complete"
    }
    check["checkedAt"] = .string(isoNow())
    if !open.isEmpty {
        check["failures"] = Value(open.map { row -> Value in
            let base: Value = ["id": row["id"], "title": row["title"], "error": row["error"]]
            return Value.spread(base,
                row["code"].truthy ? ["code": row["code"]] : [:],
                row["limitEngine"].truthy ? ["limitEngine": row["limitEngine"]] : [:],
                row["limitBudget"].truthy ? ["limitBudget": row["limitBudget"]] : [:])
        })
    } else { check.removeKey("failures") }
    if later.length > 0 { check["later"] = later } else { check.removeKey("later") }
    return check
}

func cloudProgress(_ receipt: Value = .undefined, _ cloud: Value = .undefined) throws -> Value {
    Value.spread(["moved": Value(receipt["sessions"].length)], try sourceProgress(cloud["source"]))
}

func archiveCloud(_ inv: Value = .undefined, _ receipt: Value = .undefined, _ save: Value = .undefined, _ report: Value = .undefined) throws -> Value {
    let report = fnOr(report)
    let matches = (inv["cloud"]["matches"] ?? []).elements.filter { !$0["target"]["failed"].truthy }
    if matches.isEmpty {
        if !inv["deferredCloudSources"]["length"].truthy && (!inv["cloudRequested"].truthy || inv["cloud"]["checked"].truthy) { try progress(report, "cloud", 0, 0) }
        return .undefined
    }
    let cloud = inv["cloud"]["client"]
    let failedVerification = Value.newSet(receipt["verification"]["problems"].elements.map { $0["id"] })
    var archived = 0
    let total = Value(matches.count)
    try progress(report, "cloud", Value(archived), total, try cloudProgress(receipt, inv["cloud"]))
    for (index, match) in matches.enumerated() {
        let row: Value = match["target"]["kind"] === "existing"
            ? match["target"]["row"]
            : (receipt["sessions"].elements.first { $0["targetId"] === match["target"]["id"] } ?? .undefined)
        if failedVerification.has(row["targetId"] ?? match["target"]["id"]) {
            try addCloudFailure(receipt, inv["cloud"], ["id": match["session"]["id"], "title": match["session"]["title"], "error": "local target failed verification, Remote Control source kept"])
            archived += 1
            try progress(report, "cloud", Value(archived), total, try cloudProgress(receipt, inv["cloud"]))
            continue
        }
        let liveWorkers = try workers()
        let retained = match["target"]["retained"]
        let retainedUnchanged = { () throws -> Bool in
            if !retained.truthy { return true }
            return orNull({ try mappedPath(retained["transcript"]) }) === retained["canonicalTranscript"] &&
                orNull({ try artifactStat(retained["canonicalTranscript"])["signature"] }) === retained["fingerprint"] &&
                orNull({ Value(sha(try readRegular(retained["canonicalTranscript"], retained["fingerprint"]))) }) === retained["contentSha"] &&
                orNull({ try mappedPath(retained["transcript"]) }) === retained["canonicalTranscript"]
        }
        let targetOkay: Bool = row["targetId"].truthy
            ? try targetChanges(row, liveWorkers, true).length == 0
            : row.truthy ? try untouched(row, liveWorkers).truthy : false
        if try !targetOkay || !retainedUnchanged() {
            try addCloudFailure(receipt, inv["cloud"], ["id": match["session"]["id"], "title": match["session"]["title"], "error": "local target changed before Remote Control archival"])
            archived += 1
            try progress(report, "cloud", Value(archived), total, try cloudProgress(receipt, inv["cloud"]))
            continue
        }
        var lastEventAt: Value = .null, stateSha: Value = .null
        do {
            let current = try stableRemoteRows(cloud, match["session"]["id"])
            lastEventAt = current["marker"]
            stateSha = current["stateSha"]
            let currentConversation = try conversationFromRows(current["rows"])
            if Value(sha(stable(currentConversation))) !== match["conversationSha"] { throw EngineError("Remote Control history changed since inventory") }
        } catch {
            let error = errorObject(error)
            try addCloudFailure(receipt, inv["cloud"], ["id": match["session"]["id"], "title": match["session"]["title"], "error": error["message"], "code": try memoryErrorCode(error), "localId": match["target"]["id"]])
            archived += 1
            try progress(report, "cloud", Value(archived), total, try cloudProgress(receipt, inv["cloud"]))
            continue
        }
        var activation: Value = .undefined
        do {
            let keep = match["target"]["kind"] === "existing" && receipt["sessions"].elements.contains { $0["record"] === row["session"]["file"] && !$0["archived"].truthy }
            activation = try targetActivation(row, Value(keep))
        } catch {
            let error = errorObject(error)
            try addCloudFailure(receipt, inv["cloud"], ["id": match["session"]["id"], "title": match["session"]["title"], "error": error["message"], "code": try memoryErrorCode(error), "localId": match["target"]["id"]])
            archived += 1
            try progress(report, "cloud", Value(archived), total, try cloudProgress(receipt, inv["cloud"]))
            continue
        }
        let pending = Value.spread(try remoteReceipt(match), ["lastEventAt": lastEventAt, "stateSha": stateSha, "activation": activation])
        receipt["remotePending"] = pending
        try save.call()
        var attempted = false
        do {
            try applyActivation(pending["activation"], row)
            try save.call()
            let current = try stableRemoteRows(cloud, pending["id"])
            if current["marker"] !== pending["lastEventAt"] { throw EngineError("Remote Control history changed before archival") }
            if current["stateSha"] !== pending["stateSha"] { throw EngineError("Remote Control history or input changed before archival") }
            if retained.truthy {
                var changed = !(try retainedUnchanged())
                if !changed {
                    changed = row["targetId"].truthy
                        ? try targetChanges(row, try workers(), true).length > 0
                        : !(try untouched(row, try workers())).truthy
                }
                if changed { throw EngineError("Retained local history changed before Remote Control archival") }
            }
            if match["target"]["matchMode"] === "artifacts" {
                let events = try remoteEvents(current["rows"])
                if Value(sha(stable(events))) !== match["target"]["artifactSignature"] { throw EngineError(try artifactError("remote event identities changed before archival")) }
                let intact: Bool = row["targetId"].truthy ? try targetChanges(row, try workers(), true).length == 0 : try untouched(row, try workers()).truthy
                if !intact { throw EngineError(try artifactError("local target changed before archival")) }
                let proof = try supplementalCoverage(events, match["target"]["row"], inv["cloud"]["artifacts"])
                if !proof.truthy || stable(proof["artifactCounts"]) != stable(match["target"]["artifactCounts"]) { throw EngineError(try artifactError("the selected local artifacts no longer cover the remote history")) }
            }
            attempted = true
            try cloud["archive"].call(pending["id"])
            let after = try waitRemote(cloud, pending["id"], ["archived"])
            if after["status"] !== "archived" { throw EngineError("Remote Control archive verification returned \(after["status"] ?? "unknown")") }
            if receipt["remote"].nullish { receipt["remote"] = [] }
            receipt["remote"].push(pending)
            receipt.removeKey("remotePending")
            try save.call()
        } catch {
            let error = errorObject(error)
            var rolledBack = false
            if !attempted {
                do {
                    try rollbackActivation(pending["activation"], row)
                    receipt.removeKey("remotePending")
                    rolledBack = true
                } catch {}
            }
            try addCloudFailure(receipt, inv["cloud"], ["id": pending["id"], "title": pending["title"], "error": error["message"], "code": try memoryErrorCode(error), "localId": match["target"]["id"]])
            if !rolledBack {
                for skipped in matches.dropFirst(index + 1) {
                    try addCloudFailure(receipt, inv["cloud"], ["id": skipped["session"]["id"], "title": skipped["session"]["title"], "error": "not attempted while Remote Control recovery is pending"])
                }
            }
            try save.call()
            if !rolledBack { break }
        }
        archived += 1
        try progress(report, "cloud", Value(archived), total, try cloudProgress(receipt, inv["cloud"]))
    }
    if receipt["remote"]["length"].truthy { try report.call("cloud", .string("\(count(receipt["remote"].length)) source mirrors archived")) }
    return .undefined
}

func cloudIdentity(_ paths: Value = .undefined, _ options: Value = .undefined) throws -> Value {
    let active = try options["active"] ?? signedIn(paths, options["processes"])
    return !options["active"].truthy && active["state"] === "unknown" && options["cloud"].truthy && !options["cloud"].isFunction ? options["cloud"] : active
}
func cloudScope(_ supplied: Value = .undefined, _ source: Value = .undefined) throws -> Value {
    if !supplied.truthy || supplied.isFunction { return true }
    return try sameAccount(supplied, source)
}
func cloudAttemptAt(_ receipt: Value = .undefined, _ source: Value = .undefined) throws -> Value {
    let key = "\(source["account"])/\(source["org"])", at = receipt["cloudAttempts"][key] ?? 0
    return isFiniteNumber(at) && toNumber(at) >= 0 ? at : 0
}
func unchangedLimit(_ source: Value = .undefined, _ row: Value = .undefined, _ memory: Value = .undefined) throws -> Value {
    guard try source["attemptEngine"] === artifactEngine(), try (row["limitEngine"] ?? source["attemptEngine"]) === artifactEngine() else { return false }
    if row["code"] === "CLOUD_HISTORY_LIMIT" { return true }
    return Value(try source["attemptBudget"] === memorySignature(memory) && (row["limitBudget"] ?? source["attemptBudget"]) === memorySignature(memory))
}
func limitedFailure(_ source: Value = .undefined, _ row: Value = .undefined, _ memory: Value = .undefined) throws -> Value {
    let codes: [Value] = ["CLOUD_HISTORY_LIMIT", "CLOUD_BUDGET_LIMIT", "CLOUD_PARSER_LIMIT"]
    return Value(try codes.contains(row["code"]) && unchangedLimit(source, row, memory).truthy)
}
func budgetRetryRows(_ source: Value = .undefined, _ memory: Value = .undefined) throws -> Value {
    let deferred = (source["waiting"] ?? []).elements.filter { $0["code"] === "CLOUD_MEMORY_DEFERRED" }
    let budget = try (source["failures"] ?? []).elements.filter { try $0["code"] === "CLOUD_MEMORY_BUDGET" && unchangedLimit(source, $0, memory).truthy }
    return Value(deferred + budget)
}
func historyLimited(_ source: Value = .undefined, _ memory: Value = .undefined) throws -> Value {
    let memory = memory.isUndefined ? try operationMemory() : memory
    let first = Value(!source["waiting"]["length"].truthy)
    if !first.truthy { return first }
    let failuresLength = source["failures"]["length"]
    if !failuresLength.truthy { return failuresLength }
    return Value(try source["failures"].elements.allSatisfy { try limitedFailure(source, $0, memory).truthy })
}
func cloudRetryAt(_ receipt: Value = .undefined, _ source: Value = .undefined, _ active: Value = .undefined, _ now: Value = .undefined, _ memory: Value = .undefined) throws -> Value {
    let now: Value = now.isUndefined ? Value(dateNow()) : now
    let memory = memory.isUndefined ? try operationMemory() : memory
    if try historyLimited(source, memory).truthy { return .null }
    let last = try cloudAttemptAt(receipt, source)
    let auth = and(source["failures"]["length"], Value(source["failures"].elements.allSatisfy { $0["code"] === "CLOUD_AUTH_PENDING" }))
    if !last.truthy || toNumber(last) > toNumber(now) { return now }
    if auth.truthy, try sameLogin(source, active).truthy, active["at"].truthy, source["loginAt"] !== active["at"] { return now }
    let shortWait = auth.truthy && toNumber(source["authRetries"] ?? 0) <= 2
    return Value(toNumber(last) + (shortWait ? 15_000 : 60_000))
}

func sourceCloud(_ paths: Value = .undefined, _ source: Value = .undefined, _ supplied: Value = .undefined) throws -> Value {
    let cloud = supplied.isFunction
        ? try supplied.call(Value.spread(try accountRef(source), ["label": try accountLabel(source)]))
        : try supplied ?? cloudClient(paths, source)
    if !(try sameAccount(cloud, source)).truthy { throw EngineError("Cloud client does not match the recorded source \(try accountLabel(source))") }
    return cloud
}

func receiptCloud(_ receipt: Value = .undefined, _ paths: Value = .undefined, _ supplied: Value = .undefined) throws -> Value {
    let row = receipt["remotePending"] ?? receipt["remote"][0]
    if !row.truthy { return .null }
    return try sourceCloud(paths, row, supplied)
}

func restoreRemote(_ receipt: Value = .undefined, _ file: Value = .undefined, _ paths: Value = .undefined, _ options: Value = .undefined) throws -> Value {
    let options: Value = options.isUndefined ? [:] : options
    if !receipt["remoteUndoing"]["length"].truthy { return ["problems": [], "pending": []] }
    var restored = 0
    var errorMessage: Value = .undefined
    let problems = Value.newArray()
    let active = try cloudIdentity(paths, options)
    let bySource = ValueMap()
    for row in receipt["remoteUndoing"].elements where try sameLogin(row, active).truthy && cloudScope(options["cloud"], row).truthy {
        bySource.set(.string("\(row["account"])/\(row["org"])"), row)
    }
    for source in bySource.values {
        let cloud: Value
        do { cloud = try sourceCloud(paths, source, options["cloud"]) }
        catch { errorMessage = errorObject(error)["message"]; continue }
        for row in try receipt["remoteUndoing"].elements.filter({ try sameAccount($0, source).truthy }) {
            do {
                let current = try cloud["session"].call(row["id"])
                if current["status"] === "archived" { try cloud["unarchive"].call(row["id"]) }
                let after = try waitRemote(cloud, row["id"], ["active", "paused"])
                if !setHas(REMOTE_OPEN, after["status"]) { throw EngineError("Remote Control unarchive verification returned \(after["status"] ?? "unknown")") }
                receipt["remoteUndoing"] = Value(receipt["remoteUndoing"].elements.filter { $0 !== row })
                restored += 1
                try saveJson(file, receipt)
            } catch {
                let caught = errorObject(error)
                problems.push(.string("\(row["title"]) | \(caught["message"])"))
            }
        }
    }
    if receipt["remoteUndoing"].length == 0 { receipt.removeKey("remoteUndoing") }
    try saveJson(file, receipt)
    var pending: [Value] = []
    for row in (receipt["remoteUndoing"] ?? []).elements { pending.append(try loginLabel(row)) }
    let result: Value = [
        "problems": problems,
        "pending": Value(unique(pending)),
        "restored": Value(restored),
    ]
    return Value.spread(result, errorMessage.truthy ? ["error": errorMessage] : [:])
}

func unitsOf(_ rows: Value = .undefined) throws -> Value {
    let keys = ValueMap()
    for row in rows.elements {
        for member in (row["members"] ?? Value([row])).elements {
            keys.set(.string("\(member["account"]["account"])/\(member["account"]["org"])/\(member["record"]["sessionId"])"), row)
        }
    }
    let root = ValueMap(rows.elements.map { ($0, $0) })
    func findRoot(_ row: Value) -> Value { root.get(row) === row ? row : findRoot(root.get(row)) }
    for row in rows.elements {
        for member in (row["members"] ?? Value([row])).elements {
            let parent = keys.get(.string("\(member["account"]["account"])/\(member["account"]["org"])/\(member["record"]["forkedFromSessionId"])"))
            if parent.truthy { root.set(findRoot(row), findRoot(parent)) }
        }
    }
    return Value(groupBy(rows.elements, findRoot).map { Value($0) })
}
