import Foundation

// engine.js lines 1926-2346: cloudInventory, rehomeReason, localPlan, retainedHistories, inventory.

// `REMOTE_OPEN` (engine.js L3827, S07's range): `new Set(['active', 'paused'])`. Kept private here under
// a distinct name so it cannot collide with S07's global.
fileprivate let S04_REMOTE_OPEN: Set<String> = ["active", "paused"]
fileprivate func remoteOpenStatus(_ status: Value) -> Bool { status.asString.map { S04_REMOTE_OPEN.contains($0) } ?? false }

// `a - b || c - d || …` used as a sort comparator: NaN and 0 fall through; a final NaN sorts as equal.
fileprivate func comparatorChain(_ ds: [Double]) -> Double {
    for d in ds.dropLast() where d != 0 && !d.isNaN { return d }
    let last = ds.last ?? 0
    return last.isNaN ? 0 : last
}

// Array.prototype.flatMap callback result: arrays are flattened one level, anything else is kept.
fileprivate func flatPart(_ v: Value) -> [Value] { v.isArray ? v.elements : [v] }

// L1926
func cloudInventory(_ cloud: Value = .undefined, _ from: Value = .undefined, _ targets: Value = .undefined, _ move: Value = .undefined, _ cache: Value = .undefined, _ report: Value = .undefined, _ cutoff: Value = .undefined, _ liveSources: Value = .undefined, _ sessionIds: Value = .undefined, _ excludedIds: Value = .undefined, _ options: Value = .undefined) throws -> Value {
    let cutoff: Value = cutoff.isUndefined ? .null : cutoff
    let liveSources: Value = liveSources.isUndefined ? .newArray() : liveSources
    let sessionIds: Value = sessionIds.isUndefined ? .null : sessionIds
    let excludedIds: Value = excludedIds.isUndefined ? .newSet() : excludedIds
    let options: Value = options.isUndefined ? .newObject() : options
    if !cloud.truthy {
        let empty: Value = ["checked": false, "matches": [], "blocked": [], "waiting": [], "later": [], "client": .null]
        return empty
    }
    var account: Value = .undefined
    for candidate in from.elements where try sameAccount(candidate, cloud).truthy { account = candidate; break }
    if !account.truthy {
        let empty: Value = ["checked": false, "matches": [], "blocked": [], "waiting": [], "later": [], "client": cloud]
        return empty
    }
    let candidate = { (kind: String, row: Value, title: Value) throws -> Value in
        let remoteIds = Value.newSet(try remoteIdsOf(row).elements)
        let out: Value = ["kind": .string(kind), "id": row["id"], "title": title, "conversation": row["conversation"], "remoteIds": remoteIds, "row": row]
        return out
    }
    var candidates: [Value] = []
    for target in targets.elements { candidates.append(try candidate("existing", target, target["session"]["title"])) }
    for source in move.elements { candidates.append(try candidate("move", source, source["title"])) }
    var waitingCandidates = candidates
    for row in liveSources.elements { waitingCandidates.append(try candidate("source", row, row["title"])) }
    let listed: Value
    do {
        listed = try cloud["list"].call()
    } catch {
        let error = jsErrorValue(error)
        let blockedRow: Value = ["id": .null, "title": "Remote Control", "account": account, "error": .string("cloud check failed: \(error["message"])"), "code": try memoryErrorCode(error)]
        let out: Value = [
            "checked": true,
            "matches": [],
            "blocked": [blockedRow],
            "later": [],
            "client": cloud,
            "account": cloud["account"],
            "org": cloud["org"],
            "source": account,
            "serial": Value(options["serial"].truthy),
            "isolatedId": options["budgetRetry"].truthy ? .null : .undefined,
        ]
        out["memory"] = try selectedMemory(Value.spread(options, ["cloud": cloud]))
        return out
    }
    let blocked = Value.newArray()
    let waiting = Value.newArray()
    let later = Value.newArray()
    let cutoffTime: Double? = cutoff.truthy ? jsNumber(try milliseconds(cutoff)) : nil
    if cutoff.truthy, let t = cutoffTime, t < 0 { throw JSError("pending move creation time is invalid") }
    let deferredOrder = { (id: Value) -> Double in
        let value = cache["data"]["remote"][id]["value"]["artifactDeferred"]
        return isSafeInteger(value) && jsNumber(value) > 0 ? jsNumber(value) : .infinity
    }
    let priority = Value.newMap((options["budgetRetry"] ?? []).elements.enumerated().map { ($0.element, Value($0.offset)) })
    let retryOrder = { (id: Value) throws -> Double in
        let found = priority.get(try remoteId(id))
        return found.isUndefined ? .infinity : jsNumber(found)
    }
    var firstPass: [Value] = []
    for session in listed.elements {
        if excludedIds.has(try remoteId(session["id"])) { continue }
        if try sessionIds.truthy && !sessionIds.has(remoteId(session["id"])) { continue }
        if !(session["environment_kind"] === "bridge") { continue }
        if !(session["tags"].isArray && session["tags"].elements.contains { $0.asString.map { REMOTE_TAGS.contains($0) } ?? false }) { continue }
        if !remoteOpenStatus(session["status"]) { continue }
        firstPass.append(session)
    }
    var filtered: [Value] = []
    for session in firstPass {
        guard let cutoffTime else { filtered.append(session); continue }
        let createdAt = jsNumber(try milliseconds(session["created_at"]))
        if createdAt > cutoffTime {
            later.push(["id": session["id"] ?? .null, "title": session["title"] ?? "Remote Control", "createdAt": session["created_at"]])
            continue
        }
        if createdAt >= 0 { filtered.append(session); continue }
        blocked.push(["id": session["id"] ?? .null, "title": session["title"] ?? "Remote Control", "account": account, "error": "Remote Control creation time is missing, check refused to widen the original move"])
    }
    let eligibleSessions = try jsSorted(filtered) { a, b in
        comparatorChain([try retryOrder(a["id"]) - retryOrder(b["id"]), deferredOrder(a["id"]) - deferredOrder(b["id"])])
    }
    let sessions: [Value] = options["budgetRetry"].truthy ? jsArraySlice(eligibleSessions, 0, 1) : eligibleSessions
    if options["budgetRetry"].truthy {
        for session in jsArraySlice(eligibleSessions, 1) {
            waiting.push(["id": session["id"], "title": or(session["title"], "Untitled session"), "localId": .null, "code": "CLOUD_MEMORY_DEFERRED"])
        }
    }
    let matches = Value.newArray()
    let artifacts = try artifactBudget(options["artifactLimit"])
    var completed = 0
    var deferralSequence = sessions.reduce(0.0) { maximum, session in
        Swift.max(maximum, deferredOrder(session["id"]).isFinite ? deferredOrder(session["id"]) : 0)
    }
    // artifactTurn: the JS chains artifact checks so they run one at a time; this port analyzes sessions sequentially,
    // so each `await preceding` has already resolved.
    if !sessions.isEmpty { try progress(report, "cloud scan", Value(completed), Value(sessions.count)) }
    let analyze = { (session: Value) throws -> Value in
        let result: Value
        do {
            result = try {
                let sessionId = try wireRemoteId(session["id"])
                let named = candidates.filter { $0["title"] === session["title"] }
                let linked = candidates.filter { $0["remoteIds"].has(sessionId) }
                let detail = try cloud["session"].call(session["id"])
                if remoteOpenStatus(detail["status"]), try remoteOpen(detail).truthy {
                    let local = waitingCandidates.filter { $0["remoteIds"].has(sessionId) }
                    let same: Value = JSSet(local.map { $0["id"] }).size == 1 ? local[0] : .null
                    let recordId: Value = same.truthy ? try desktopRecordOf(same["row"])["sessionId"] : .null
                    let row: Value = ["id": session["id"], "title": or(session["title"], "Untitled session"), "localId": same["id"] ?? .null, "recordId": recordId]
                    return ["waiting": row]
                }
                if linked.count > 1 { return ["blocked": ["id": session["id"], "title": session["title"], "account": account, "error": "multiple local targets carry the Remote Control id"]] }
                try assertRemoteIdle(detail)
                let signature = Value(sha(stable(["id": session["id"], "updatedAt": session["updated_at"], "lastEventAt": detail["last_event_at"], "status": detail["status"]])))
                var remote = try cacheLookup(cache, "remote", session["id"], signature)
                var remoteConversation = remote["conversation"]
                let refresh = { () throws in
                    let rows = try stableRemoteRows(cloud, session["id"])["rows"]
                    let current = try conversationFromRows(rows)
                    if remoteConversation.truthy && sha(stable(current)) != sha(stable(remoteConversation)) { throw JSError("Remote Control history changed since cached analysis") }
                    remoteConversation = current
                    remote = ["conversation": current, "events": try remoteEvents(rows)]
                    try cacheStore(cache, "remote", session["id"], signature, remote)
                }
                if !remoteConversation.truthy { try refresh() }
                let findCovered = { (items: [Value]) throws -> [Value] in
                    var out: [Value] = []
                    for candidate in items {
                        let matchMode = try conversationMatch(remoteConversation, candidate["conversation"])
                        if matchMode.truthy { out.append(Value.spread(candidate, ["matchMode": matchMode])); continue }
                        var retained: Value = .undefined
                        for h in candidate["row"]["retainedHistories"].elements {
                            var bound = false
                            for owner in h["bindings"].elements where owner["id"] === sessionId {
                                if try sameAccount(owner, account).truthy { bound = true; break }
                            }
                            if bound, try conversationMatch(remoteConversation, h["conversation"]).truthy { retained = h; break }
                        }
                        if retained.truthy {
                            out.append(Value.spread(candidate, ["matchMode": try conversationMatch(remoteConversation, retained["conversation"]), "retained": retained]))
                        }
                    }
                    return out
                }
                let eligible = remoteConversation.length >= 4 ? candidates : unique(named + linked)
                let covered = try findCovered(eligible)
                let linkedCovered = covered.filter { $0["remoteIds"].has(sessionId) }
                let verified = linkedCovered.count == 1 ? linkedCovered : covered
                if verified.count > 1 { return ["blocked": ["id": session["id"], "title": session["title"], "account": account, "error": "multiple verified local target histories"]] }
                if verified.count == 1 { return ["match": ["session": session, "target": verified[0], "conversationSha": Value(sha(stable(remoteConversation))), "account": account]] }
                let anchors = !linked.isEmpty ? linked : named
                let base: Value = anchors.count == 1 ? anchors[0] : .null
                let record: Value = base.truthy ? try desktopRecordOf(base["row"]) : base
                let anchored: Bool = try base.truthy && (!linked.isEmpty || conversationAnchored(remoteConversation, base["conversation"], 8).truthy)
                var artifactLinked = false
                if base.truthy && !linked.isEmpty {
                    let ids = try base["row"]["artifactBridgeIds"] ?? remoteIdsOf(Value.spread(base["row"], ["members": []]))
                    artifactLinked = ids.includes(sessionId)
                }
                if artifactLinked || anchored && (base["row"]["taskOwned"].truthy || record["scheduledTaskId"].truthy || record["notifySessionId"].truthy) {
                    let selected = base
                    var retrySignature: Value = .undefined, fullBudget = false, checked = false
                    var deferredAt: Double? = nil
                    var settled: Value? = nil
                    do {
                        if !linked.isEmpty && !artifactLinked { throw JSError(try artifactError("the retained parent history cannot be verified")) }
                        if !remote["events"].isArray { try refresh() }
                        fullBudget = artifacts["used"] === 0
                        deferredAt = deferredOrder(session["id"])
                        let inputs = try artifactInputs(selected["row"])
                        retrySignature = Value(sha(stable(["engine": try artifactEngine(), "limit": artifacts["limit"], "remote": signature, "id": selected["id"], "record": selected["row"]["recordSemantic"], "files": inputs["fingerprints"]])))
                        let previous = remote["artifactFailure"]
                        if options["automatic"].truthy && previous["signature"] === retrySignature { throw JSError(try artifactError("unchanged inputs still exceed the supplemental read limits", previous["code"])) }
                        remote.removeKey("artifactFailure")
                        remote.removeKey("artifactDeferred")
                        checked = true
                        let proof = try supplementalCoverage(remote["events"], selected["row"], artifacts, inputs)
                        if proof.truthy { settled = ["match": ["session": session, "target": Value.spread(selected, proof), "conversationSha": Value(sha(stable(remoteConversation))), "account": account]] }
                    } catch {
                        let error = jsErrorValue(error)
                        if checked && retrySignature.truthy {
                            if error["code"] === "CLOUD_ARTIFACT_LINE_LIMIT" || error["code"] === "CLOUD_ARTIFACT_BUDGET" && fullBudget {
                                remote["artifactFailure"] = ["signature": retrySignature, "code": error["code"]]
                            } else if error["code"] === "CLOUD_ARTIFACT_BUDGET" {
                                if let d = deferredAt, d.isFinite { remote["artifactDeferred"] = Value(d) } else { deferralSequence += 1; remote["artifactDeferred"] = Value(deferralSequence) }
                            }
                        }
                        let typed = error["code"].asString?.hasPrefix("CLOUD_ARTIFACT_") ?? false
                        settled = ["blocked": ["id": session["id"], "title": session["title"], "account": account, "code": typed ? error["code"] : "CLOUD_ARTIFACT_UNCERTAIN",
                                               "error": typed ? error["message"] : "Supplemental cloud coverage is uncertain: local artifacts could not be verified"]]
                    }
                    // finally
                    if checked { try cacheStore(cache, "remote", session["id"], signature, remote) }
                    if let settled { return settled }
                }
                return ["blocked": ["id": session["id"], "title": session["title"], "account": account, "code": "CLOUD_UNPROVEN", "error": .string("not proven to be on this Mac, kept in \(account["label"])")]]
            }()
        } catch {
            let error = jsErrorValue(error)
            do {
                result = ["blocked": ["id": session["id"], "title": session["title"], "account": account, "code": try memoryErrorCode(error), "error": .string("Remote Control history unreadable: \(error["message"])")]]
            } catch {
                completed += 1
                try progress(report, "cloud scan", Value(completed), Value(sessions.count))
                throw error
            }
        }
        // finally
        completed += 1
        try progress(report, "cloud scan", Value(completed), Value(sessions.count))
        return result
    }
    var at = 0
    while at < sessions.count {
        let size = options["serial"].truthy ? 1 : (try selectedMemory(Value.spread(options, ["cloud": cloud]))["parallel"].call()).asInt ?? 0
        var batch: [Value] = []
        for session in jsArraySlice(sessions, at, at + size) { batch.append(try analyze(session)) }
        at += batch.count
        for result in batch {
            if result["match"].truthy { matches.push(result["match"]) }
            else if result["waiting"].truthy { waiting.push(result["waiting"]) }
            else { blocked.push(result["blocked"]) }
        }
    }
    let out: Value = [
        "checked": true, "matches": matches, "blocked": blocked, "waiting": waiting, "later": later, "client": cloud,
        "account": cloud["account"], "org": cloud["org"], "source": account, "artifacts": artifacts, "serial": Value(options["serial"].truthy),
    ]
    out["isolatedId"] = options["budgetRetry"].truthy ? try remoteId(sessions.first?["id"] ?? .undefined) : .undefined
    out["memory"] = try selectedMemory(Value.spread(options, ["cloud": cloud]))
    return out
}

// L2087
func rehomeReason(_ source: Value = .undefined, _ to: Value = .undefined, _ targetIds: Value = .undefined, _ targetNames: Value = .undefined) throws -> Value {
    if source["taskFamily"]["error"].truthy || source["account"]["taskError"].truthy || to["taskError"].truthy {
        return source["taskFamily"]["error"] ?? source["account"]["taskError"] ?? to["taskError"]
    }
    if JSSet(source["members"].elements.map { $0["transcript"] }).size > 1 { return "multiple compatible source versions require merging" }
    if try sameAccount(source["account"], to).truthy { return "source and destination are the same" }
    if !source["sole"].truthy && source["invalid"].truthy { return .string("\(source["invalid"]) unparseable lines") }
    if !source["sole"].truthy && source["conflicts"].truthy { return .string("\(source["conflicts"]) conflicting duplicate uuids") }
    if !source["sole"].truthy && !source["comparable"].truthy { return "history cannot be compared safely" }
    if !source["taskFamily"].truthy && !source["coldRun"].truthy && source["record"]["scheduledTaskId"].truthy { return "scheduled task owns the Desktop record" }
    if !source["taskFamily"].truthy && source["record"]["notifySessionId"].truthy { return "notification route owns the Desktop record" }
    if !source["taskFamily"].truthy && source["taskOwned"].truthy { return "scheduled task registry owns the Desktop record" }
    if targetIds.has(source["id"]) { return "target session id collision" }
    if targetNames.has(.string(path.basename(source["file"].description))) { return "target Desktop filename collision" }
    if (source["members"] ?? [source]).elements.contains(where: { $0["worker"].truthy }) { return .string(WORKER_OWNS) }
    if source["schedulerBusy"].truthy { return .string(SCHEDULER_OWNS) }
    return .null
}

// L2104
func localPlan(_ pending: Value = .undefined, _ to: Value = .undefined) throws -> Value {
    let pendingRows = pending.elements
    let targetIds = JSSet(to["sessions"].elements.map { $0["id"] }.filter { $0.truthy })
    let targetNames = JSSet(to["sessions"].elements.map { Value(path.basename($0["file"].description)) } + to["unreadable"].elements.map { Value(path.basename($0.description)) })
    let reasons = JSMap()
    for source in pendingRows { reasons.set(source, try rehomeReason(source, to, .set(targetIds), .set(targetNames))) }
    for family in JSSet(pendingRows.map { $0["taskFamily"] }.filter { $0.truthy }).values {
        let members = pendingRows.filter { $0["taskFamily"] === family }
        let hardReason = { (row: Value) -> Bool in
            let reason = reasons.get(row)
            return reason.truthy && !(reason === .string(WORKER_OWNS) || reason === .string(SCHEDULER_OWNS))
        }
        let blocker = members.first(where: hardReason) ?? members.first(where: { reasons.get($0).truthy })
        if let blocker {
            for row in members where !hardReason(row) {
                let reason = reasons.get(blocker)
                reasons.set(row, hardReason(blocker) ? .string("\(TASK_FAMILY_BLOCKED) \(or(blocker["title"], blocker["record"]["sessionId"])): \(reason)") : reason)
            }
        }
    }
    let availableParents = JSSet(to["sessions"].elements.map { $0["record"]["sessionId"] }.filter { $0.truthy })
    var added = true
    while added {
        added = false
        for source in pendingRows {
            if reasons.get(source).truthy || availableParents.has(source["record"]["sessionId"]) { continue }
            if !source["record"]["forkedFromSessionId"].truthy || availableParents.has(source["record"]["forkedFromSessionId"]) {
                availableParents.add(source["record"]["sessionId"])
                added = true
            }
        }
    }
    for source in pendingRows where source["taskFamily"].truthy && !availableParents.has(source["record"]["sessionId"]) {
        for row in pendingRows.filter({ $0["taskFamily"] === source["taskFamily"] }) where !reasons.get(row).truthy { reasons.set(row, .string(PARENT_MISSING)) }
    }
    let blocked = Value.newArray()
    var move: [Value] = []
    for source in pendingRows {
        let reason = or(reasons.get(source), !availableParents.has(source["record"]["sessionId"]) ? .string(PARENT_MISSING) : .null)
        if reason.truthy { blocked.push(Value.spread(source, ["error": reason])) }
        else {
            source["strategy"] = "rehome"
            move.append(source)
        }
    }
    var ordered: [Value] = []
    var pendingMove = move
    let landedRecords = JSSet(to["sessions"].elements.map { $0["record"]["sessionId"] }.filter { $0.truthy })
    while !pendingMove.isEmpty {
        guard let at = pendingMove.firstIndex(where: { !$0["record"]["forkedFromSessionId"].truthy || landedRecords.has($0["record"]["forkedFromSessionId"]) }) else {
            throw JSError("parent ordering invariant failed")
        }
        let next = pendingMove.remove(at: at)
        ordered.append(next)
        landedRecords.add(next["record"]["sessionId"])
    }
    move = ordered
    return ["move": move.value, "blocked": blocked]
}

// L2156
func retainedHistories(_ target: Value = .undefined, _ ctx: Value = .undefined, _ options: Value = .undefined, _ owners: Value = .undefined, _ enabled: Value = .undefined) throws -> Value {
    let cloudBridgeIds = options["cloudBridgeIds"]
    target["artifactBridgeIds"] = unique(try remoteIdsOf(target).elements + (cloudBridgeIds.get(target["id"]) ?? []).elements.map(remoteId).filter { $0.truthy }).value
    if !enabled.truthy { return .undefined }
    let priorIds = unique(try priorSessions(desktopRecordOf(target)).elements.filter { id in
        guard let s = id.asString else { return false }
        return UUID.test(s) && id !== target["id"]
    })
    let remembered = ([target["id"]] + priorIds).flatMap { id in flatPart(cloudBridgeIds.get(id) ?? []) }
    if !remembered.isEmpty {
        target["bridgeIds"] = unique((target["bridgeIds"] ?? []).elements + (try remembered.map(remoteId)).filter { $0.truthy }).value
    }
    for id in priorIds {
        let transcript = path.join(path.dirname(target["transcript"].description), "\(id).jsonl")
        if !ctx["index"].get(id).includes(.string(transcript)) { continue }
        do {
            let canonicalTranscript = try mappedPath(.string(transcript))
            let before = try artifactStat(canonicalTranscript)
            let detail = try history(id, .string(transcript), ctx, desktopRecordOf(target)["cwd"])
            if !detail["comparable"].truthy { continue }
            if try artifactStat(canonicalTranscript)["signature"] !== before["signature"] { continue }
            if Value(sha(try readRegular(canonicalTranscript, before["signature"]))) !== detail["contentSha"] { continue }
            if try mappedPath(.string(transcript)) !== canonicalTranscript { continue }
            // Map.groupBy(detail.bridgeOwners, owner => owner.id)
            let groups = JSMap()
            for owner in detail["bridgeOwners"].elements {
                let key = owner["id"]
                if groups.has(key) { groups.get(key).push(owner) } else { groups.set(key, [owner]) }
            }
            var native: [Value] = []
            for copies in groups.values {
                let owner = copies[0]
                if copies.length == 1 && owner["id"].truthy && owner["sessionId"] === id {
                    var owned = false
                    for source in owners.elements where try sameAccount(owner, source).truthy { owned = true; break }
                    if owned { native.append(owner) }
                }
            }
            let cloud = options["cloud"]
            let bindings = native + (try (cloudBridgeIds.get(id) ?? []).elements.map(remoteId)).filter { $0.truthy }.map { bridgeId -> Value in
                ["id": bridgeId, "account": cloud["account"], "org": cloud["org"]]
            }
            let bridgeIds = unique(bindings.map { $0["id"] })
            if bridgeIds.isEmpty { continue }
            target["bridgeIds"] = unique((target["bridgeIds"] ?? []).elements + bridgeIds).value
            if target["retainedHistories"].nullish { target["retainedHistories"] = [] }
            target["retainedHistories"].push([
                "transcript": .string(transcript), "canonicalTranscript": canonicalTranscript, "fingerprint": before["signature"],
                "contentSha": detail["contentSha"], "conversation": detail["conversation"], "bindings": bindings.value,
            ])
        } catch {}
    }
    return .undefined
}

// L2183
public func inventory(_ from: Value = .undefined, _ to: Value = .undefined, _ paths: Value = .undefined, _ report: Value = .undefined, _ options: Value = .undefined) throws -> Value {
    let report = fnOr(report)
    let options: Value = options.isUndefined ? .newObject() : options
    let check = { () throws in
        if !options["check"].nullish { try options["check"].call() }
        try selectedMemory(options)["check"].call()
    }
    try check()
    let requestedAt = options["requestedAt"] ?? .string(isoNow())
    let cloudRequested = options["cloudRequested"] === true || options["cloud"].truthy
    let workTotal = from.elements.reduce(0) { $0 + $1["sessions"].length } + to["sessions"].length
    var completed = 0
    try progress(report, "scan", Value(completed), Value(workTotal))
    let cache = try openAnalysisCache(paths, Value(options["writeCache"] === true))
    let ctxIndex = try index(paths["pool"])
    let ctx: Value = ["index": ctxIndex, "scans": .newMap(), "workers": try workers(options["processes"]), "cache": cache]
    try check()
    let soleRecord = { (s: Value) throws -> Bool in
        guard s["shared"] === false && !s["record"]["forkedFromSessionId"].truthy else { return false }
        for id in try priorSessions(s["record"]).elements where id !== s["id"] && ctx["index"].has(id) { return false }
        return true
    }
    let analyzed = JSMap()
    let missing = Value.newArray()
    let unreadable = Value.newArray()
    let rejected = Value.newArray()
    let found = Value.newArray()
    var total = 0
    for account in from.elements {
        total += account["unreadable"].nullish ? 0 : account["unreadable"].length
        for file in account["unreadable"].elements { unreadable.push(["file": file, "account": account]) }
        for s in account["sessions"].elements {
            try check()
            total += 1
            let scan = { () throws in
                if !s["id"].truthy { missing.push(s); return }
                let transcript = try locate(ctx["index"], s["id"], s["cwd"])
                if !transcript.truthy { missing.push(s); return }
                do {
                    var detail = analyzed.get(transcript)
                    if !detail.truthy {
                        var historyDetail: Value
                        do { historyDetail = try history(s["id"], transcript, ctx, s["cwd"]) } catch {
                            if !(try soleRecord(s)) { throw error }
                            historyDetail = .undefined
                        }
                        let base: Value = try historyDetail ?? Value.spread(["roots": .newSet(), "events": .newMap(), "conversation": []], scanLineage(ctx, transcript))
                        let transcriptFingerprint = try fingerprint(transcript, cache)
                        let sidecar = try sidecars(transcript, s["id"], cache)
                        detail = Value.spread(base, ["transcriptFingerprint": transcriptFingerprint, "sidecar": sidecar])
                        analyzed.set(transcript, detail)
                    }
                    if detail["contentSha"].truthy && !detail["roots"]["size"].truthy && !detail["invalid"].truthy { missing.push(s); return }
                    let taskOwned = Value(account["taskSessions"].has(s["record"]["sessionId"]))
                    let worker = try ownsWorker(ctx["workers"], s["id"], s["record"]["sessionId"])
                    let recordSha = Value(sha(try readFile(s["file"])))
                    let semantic = try recordSemantic(s["record"])
                    let source = Value.spread(s, ["account": account, "transcript": transcript], detail,
                                              ["taskOwned": taskOwned, "worker": worker, "recordSha": recordSha, "recordSemantic": semantic])
                    if try validDesktopRecord(source).truthy {
                        _ = try retainedHistories(source, ctx, options, [account], Value(cloudRequested))
                        found.push(source)
                    } else { rejected.push(Value.spread(s, ["account": account, "error": "Desktop record identity is invalid"])) }
                } catch {
                    rejected.push(Value.spread(s, ["account": account, "error": jsErrorValue(error)["message"]]))
                }
            }
            do { try scan() } catch {
                completed += 1
                try progress(report, "scan", Value(completed), Value(workTotal))
                try check()
                throw error
            }
            completed += 1
            try progress(report, "scan", Value(completed), Value(workTotal))
            try check()
        }
    }
    for file in to["unreadable"].elements { unreadable.push(["file": file, "account": to, "target": true]) }
    let families = try taskFamilies(from, to, found)
    for family in families.elements {
        let busy = try schedulerBusy(paths, [family["from"], family["to"]], ctx["workers"]["rows"])
        for row in found.elements where row["taskFamily"] === family { row["schedulerBusy"] = busy }
    }
    let targets = Value.newArray()
    for s in to["sessions"].elements {
        try check()
        let scan = { () throws in
            if !s["id"].truthy { return }
            let transcript = try locate(ctx["index"], s["id"], s["cwd"])
            do {
                let detail: Value = transcript.truthy ? try history(s["id"], transcript, ctx, s["cwd"]) : .null
                if detail["roots"]["size"].truthy {
                    let head: Value = ["record": s["record"]["sessionId"], "id": s["id"]]
                    let taskOwned = Value(to["taskSessions"].has(s["record"]["sessionId"]))
                    let worker = try ownsWorker(ctx["workers"], s["id"], s["record"]["sessionId"])
                    let transcriptFingerprint = try fingerprint(transcript, cache)
                    let sidecar = try sidecars(transcript, s["id"], cache)
                    let recordSha = Value(sha(try readFile(s["file"])))
                    let semantic = try recordSemantic(s["record"])
                    let target = Value.spread(head, detail, [
                        "session": s, "account": to, "taskOwned": taskOwned, "worker": worker, "transcript": transcript,
                        "transcriptFingerprint": transcriptFingerprint, "sidecar": sidecar, "recordSha": recordSha, "recordSemantic": semantic,
                    ])
                    if try validDesktopRecord(target).truthy {
                        _ = try retainedHistories(target, ctx, options, options["cloud"].truthy ? [options["cloud"]] : from, Value(cloudRequested))
                        targets.push(target)
                    } else { rejected.push(["id": s["id"], "title": s["title"], "account": to, "target": true, "error": "Desktop record identity is invalid"]) }
                }
            } catch {
                rejected.push(["id": s["id"], "title": s["title"], "account": to, "target": true, "error": jsErrorValue(error)["message"]])
            }
        }
        do { try scan() } catch {
            completed += 1
            try progress(report, "scan", Value(completed), Value(workTotal))
            try check()
            throw error
        }
        completed += 1
        try progress(report, "scan", Value(completed), Value(workTotal))
        try check()
    }
    let forked = JSSet((found.elements + targets.elements).flatMap { flatPart($0["lineage"] ?? []) })
    for source in found.elements {
        source["sole"] = Value(try soleRecord(source) && !source["lineage"]["length"].truthy && !forked.has(source["id"]))
    }
    let requiredParents = Value.newSet(found.elements.map { $0["record"]["forkedFromSessionId"] }.filter { $0.truthy })
    let ranked = jsSorted(found.elements) { a, b in
        comparatorChain([
            jsNumber(b["roots"]["size"]) - jsNumber(a["roots"]["size"]),
            jsNumber(b["activeAt"]) - jsNumber(a["activeAt"]),
            jsNumber(a["forks"]) - jsNumber(b["forks"]),
            jsNumber(a["createdAt"]) - jsNumber(b["createdAt"]),
        ])
    }
    var reps: [Value] = []
    for source in ranked {
        var at = -1
        search: for (i, candidate) in reps.enumerated() {
            if try !historyIncluded(source, candidate).truthy && !historyIncluded(candidate, source).truthy { continue }
            for member in candidate["members"].elements {
                if try !canShareRecord(member, source, requiredParents).truthy || !sidecarsAgree(member["sidecar"], source["sidecar"]).truthy { continue search }
            }
            at = i
            break
        }
        if at >= 0 {
            let prior = reps[at]
            let members = Value(prior["members"].elements + [source])
            let fullest = try historyIncluded(prior, source).truthy && !(try historyIncluded(source, prior)).truthy ? source : prior
            reps[at] = Value.spread(fullest, ["members": members])
        } else {
            reps.append(Value.spread(source, ["members": [source]]))
        }
    }
    let covering = { (s: Value) throws -> Value in
        for target in targets.elements where target["record"].truthy {
            var all = true
            for member in s["members"].elements {
                let ok = try included(member, target).truthy && (!requiredParents.has(member["record"]["sessionId"]) || target["record"] === member["record"]["sessionId"])
                if !ok { all = false; break }
            }
            if all { return target }
        }
        return .null
    }
    let there = Value.newArray()
    let pending = Value.newArray()
    for s in reps {
        let covered = try covering(s)
        if covered.truthy && !s["invalid"].truthy {
            s["cloudTargetId"] = covered["id"]
            there.push(s)
        } else { pending.push(s) }
    }
    let plan = try localPlan(pending, to)
    let move = plan["move"], blocked = plan["blocked"]
    let rootOwner = JSMap(), divergent = JSSet()
    for row in reps {
        for root in row["roots"].elements {
            let prior = rootOwner.get(root)
            if prior.truthy { divergent.add(prior); divergent.add(row) }
            else { rootOwner.set(root, row) }
        }
    }
    let apart = divergent.size
    let cloudCutoff = options["cloudCutoff"] ?? (cloudRequested ? requestedAt : .null)
    let brokenTasks = (from.elements + [to]).first { $0["taskError"].truthy }
    if options["cloud"].truthy, let brokenTasks { throw JSError(brokenTasks["taskError"].description) }
    let cloudPlan = try cloudInventory(options["cloud"], from, targets, options["cloudTargetOnly"].truthy ? [] : move, cache, report, cloudCutoff, found, options["cloudSessionIds"], options["cloudExcludedIds"], options)
    let retiring = Value.newSet((move.elements + there.elements).flatMap { row in (row["members"] ?? [row]).elements.map { $0["file"] } })
    let links = try sourceCloudLinks(Value(move.elements + there.elements))
    var cloudCheckAccounts: [Value] = []
    for account in from.elements {
        if try (cloudPlan["checked"].truthy && sameAccount(account, cloudPlan).truthy) || localCloudPending(account, retiring).truthy {
            cloudCheckAccounts.append(try accountRef(account))
            continue
        }
        let sessionIds = try linkedCloudIds(links, account)
        if sessionIds.length > 0 { cloudCheckAccounts.append(Value.spread(try accountRef(account), ["sessionIds": sessionIds])) }
    }
    do {
        try check()
        _ = try saveAnalysisCache(cache)
        try check()
    } catch {
        let errorValue = jsErrorValue(error)
        let isolatedId = cloudPlan["isolatedId"]
        if errorValue["code"] === "CLOUD_MEMORY_BUDGET" && isolatedId.truthy {
            var hit = false
            for match in cloudPlan["matches"].elements where try remoteId(match["session"]["id"]) === isolatedId { hit = true; break }
            if !hit {
                for row in cloudPlan["blocked"].elements where row["code"] === "CLOUD_MEMORY_BUDGET" {
                    if try remoteId(row["id"]) === isolatedId { hit = true; break }
                }
            }
            if hit { errorValue["budgetWork"] = ["id": isolatedId, "waiting": cloudPlan["waiting"]] }
        }
        throw error
    }
    let out: Value = [
        "total": Value(total),
        "missing": missing,
        "unreadable": unreadable,
        "rejected": rejected,
        "blocked": blocked,
        "twice": Value(found.length - reps.count),
        "apart": Value(apart),
        "there": there,
        "move": move,
        "targets": targets,
        "sources": found,
        "from": Value(from.elements.map { $0["label"] }),
    ]
    out["fromAccounts"] = Value(try from.elements.map { try accountRef($0) })
    out["cloudCheckAccounts"] = cloudCheckAccounts.value
    let cloudSettled = cloudPlan["checked"].truthy && !(cloudPlan["blocked"].length > 0) && !cloudPlan["waiting"]["length"].truthy
    out["pendingCloud"] = cloudRequested ? Value(cloudCheckAccounts.count - (cloudSettled ? 1 : 0)) : 0
    out["toAccount"] = try accountRef(to)
    out["requestedAt"] = requestedAt
    out["cloudRequested"] = Value(cloudRequested)
    out["cloudError"] = options["cloudError"] ?? .null
    out["cacheStats"] = cache["stats"]
    out["cloud"] = cloudPlan
    if options["inspect"].nullish {
        let inspect = Value { _ in try options["processes"] ?? processTable(paths["claudeApp"]) }
        // Lets the parity harness rebuild this closure on the Node side; invisible to JSON and the engine.
        inspect["$recipe"] = ["inspect", options["processes"], paths["claudeApp"]]
        out["inspect"] = inspect
    } else {
        out["inspect"] = options["inspect"]
    }
    return out
}
