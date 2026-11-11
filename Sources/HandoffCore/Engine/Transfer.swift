import Foundation

// Transfers, record transfers, finishing pending work, Keep local and the move itself.

@discardableResult
fileprivate func optCall(_ f: Value, _ args: Value...) throws -> Value {
    if f.nullish { return .undefined }
    return try f.callArgs(args)
}

fileprivate func roundHalfUp(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

func transfer(_ inv: Value = .undefined, _ to: Value = .undefined, _ paths: DataLayout, _ report: Value = .undefined, _ context: Value = .undefined) throws -> Value {
    var context = context.isUndefined ? Value.newObject() : context
    context = Value.spread(context, [
        "at": context.existing["receipt"]["at"] ?? context.at ?? .string(stamp()),
        "snapshots": Value.newMap(),
        "sources": inv.sources,
    ] as Value)
    let file: Value = context.existing["file"] ?? .string(path.join(paths.state, "\(context.at).json"))
    if context.restart.truthy {
        let batches = ValueMap(), grouped = ValueMap()
        for family in ValueSet(inv.move.elements.map { $0.taskFamily }.filter { $0.truthy }).values {
            let pair: Value = .string("\(family.sourceFile)\n\(family.targetFile)")
            var batch = batches.get(pair)
            if !batch.truthy {
                batch = Value.spread(family, ["ids": [], "recordIds": [], "files": [], "links": [], "routes": []] as Value)
                batches.set(pair, batch)
            }
            for key in ["ids", "recordIds", "files", "links", "routes"] { batch[key].asArray?.items.append(contentsOf: family[key].elements) }
            grouped.set(family, batch)
        }
        for row in ValueSet(inv.move.elements + inv.sources.elements).values where grouped.has(row.taskFamily) { row.taskFamily = grouped.get(row.taskFamily) }
    }
    let families: [Value] = ValueSet(inv.move.elements.map { $0.taskFamily }.filter { $0.truthy }).values
    let firstCount: Value = context.existing["receipt"]["sessions"]["length"] ?? 0
    let firstSuperseded: Value = context.existing["receipt"]["superseded"]["length"] ?? 0
    let emptyCloud: Value = ["checked": false, "matches": [], "blocked": [], "waiting": [], "later": []]
    var heldItems: [Value] = (inv.held ?? []).elements
    for family in families {
        let members = inv.sources.elements.filter { $0.taskFamily === family }, row = members.first ?? .undefined
        let base: Value = ["id": row.id, "record": row.file, "recordId": row.record.sessionId, "title": row.title]
        let tail: Value = ["release": "scheduler", "workers": [],
                           "sources": Value(members.map { member in Value.spread(["id": member.id, "file": member.file] as Value, family.from) })]
        heldItems.append(Value.spread(base, family.from, tail))
    }
    let held = Value(heldItems)
    let totals: Value = ["move": Value(inv.move.length), "verify": Value(inv.move.length), "retire": Value(inv.sources.length)]
    let completed: Value = ["move": 0, "verify": 0, "retire": 0]
    let details = ValueMap()
    let unitReport: (Bool) -> Value = { final in
        let before = Value.spread(completed)
        return Value { args in
            let stage = args.count > 0 ? args[0] : .undefined, text = args.count > 1 ? args[1] : .undefined, extra = args.count > 2 ? args[2] : .undefined
            if !extra["live"].truthy { details.set(stage, text); return .undefined }
            if totals.hasOwn(stage.description) {
                if toNumber(extra.total) > 0 { completed[stage] = Value(toNumber(before[stage]) + toNumber(extra.completed)) }
                if !extra.completed.isUndefined && (stage === "move" ? toNumber(extra.total) > 0 : final) {
                    _ = try progress(report, stage, completed[stage], totals[stage], ["activity": stage, "sourceId": extra.sourceId, "sourceLabel": extra.sourceLabel, "moved": extra.moved])
                }
            } else if final { try report.call(stage, text, extra) }
            return .undefined
        }
    }
    let blocked: (Value) throws -> Value = { reason in
        let receipt = Receipt(try readReceipt(file))
        receipt.localRecovery = Value.spread(receipt.localRecovery, ["blocked": reason] as Value)
        let retired = try retiredFiles(receipt)
        receipt.failed.push(Value.spread(["id": .null, "title": "Unfinished move", "error": reason] as Value,
                                         try failureIdentity(["members": Value(inv.sources.elements.filter { !retired.has($0.file) })])))
        _ = try saveJson(file, receipt.raw)
        return ["file": file, "receipt": receipt.raw, "summary": try receiptSummary(receipt), "code": "LOCAL_RECOVERY_BLOCKED", "recoveryRequired": true, "ok": false, "complete": false,
                "reconciled": ["title": "Move recovery blocked", "error": reason], "reason": reason]
    }
    var result: Value = context.existing
    var failed: [Value] = [], orphans: [Value] = []
    let attempt: (Value, Value, Bool, Value, Value) throws -> Value = { unit, family, last, unitHeld, unitReporterArg in
        let unitReporter = unitReporterArg.isUndefined ? unitReport(false) : unitReporterArg
        let existing: Value = result["file"].truthy ? ["file": result.file, "receipt": result.receipt] : context.existing
        let files: [Value] = unit.sources.elements.map { $0.file }
        unit.held = unitHeld ?? Value(existing.receipt.held.elements.filter { row in !row.sources.elements.contains { source in files.contains(source.file) } })
        do {
            try optCall(context.check, true)
            let next = try transferRecords(unit, to, paths, unitReporter, Value.spread(context, ["existing": existing, "taskFamily": family] as Value))
            if !last { failed.append(contentsOf: (next["unwound"] ?? []).elements) }
            return next["deferred"].truthy || next["file"].truthy || !result["file"].truthy ? next : result
        } catch {
            let error = errorObject(error)
            if error.code === "RESTART_REOPENED" || !context.restart.truthy && !family.truthy { throw EngineError(error) }
            try optCall(context.progress)
            var receipt: Receipt
            do { receipt = Receipt(try readReceipt(file)) } catch {
                let e = errorObject(error)
                if e.code !== "ENOENT" { throw EngineError(e) }
                receipt = Receipt(.null)
            }
            if !last { failed.append(contentsOf: files) }
            let failure = Value.spread(["id": .null, "title": family.truthy ? "Scheduled task family" : "Unfinished move", "error": error["message"]] as Value,
                                       try failureIdentity(["members": unit.sources]))
            if !receipt.isPresent {
                orphans.append(contentsOf: try inventoryFailures(unit).elements)
                orphans.append(failure)
                return result
            }
            let failures = Value(receipt.failed.elements), cloudChecks = receipt.cloudChecks.deepClone()
            let checkpoint: Value = receipt.appendCheckpoint ?? ["sessions": 0, "superseded": 0]
            var after = receipt
            if try needsRecovery(receipt).truthy {
                try report.call("rollback", "Restoring unfinished work before continuing", ["live": true])
                receipt.localRecovery = ["rollback": receipt.localRecovery["rollback"] ?? .string(randomUUID())]
                _ = try saveJson(file, receipt.raw)
                var recovered: Value = .undefined
                do { recovered = try reconcileFiles(paths, ["receiptFile": file, "inspect": inv.inspect, "check": context.check]) }
                catch { return try blocked(errorObject(error)["message"]) }
                after = Receipt(try readReceipt(file))
                if try needsRecovery(after).truthy || toNumber(after.retained["length"] ?? 0) > toNumber(receipt.retained["length"] ?? 0) {
                    return try blocked(or(and(try needsRecovery(after), recovered["error"]), "Unfinished work could not be restored consistently"))
                }
                if Value(after.sessions.length) !== checkpoint.sessions || Value(after.superseded.length) !== checkpoint.superseded { return try blocked("Unfinished placement was not fully restored") }
                let heldRows: [Value] = (after.held ?? []).elements.flatMap { row -> [Value] in
                    let sources = row.sources.elements.filter { source in !files.contains(source.file) }
                    return sources.isEmpty ? [] : [Value.spread(row, ["sources": Value(sources)] as Value)]
                }
                Value.assign(after.raw, ["failed": failures, "cloudChecks": cloudChecks, "held": Value(heldRows)] as Value)
                after.clear(.localRecovery)
            }
            after.failed.push(failure)
            _ = try saveJson(file, after.raw)
            return ["file": file, "receipt": after.raw, "ok": false]
        }
    }
    let regular = Value.spread(inv, ["cloud": families.isEmpty ? inv.cloud : emptyCloud,
                                     "move": Value(inv.move.elements.filter { !$0.taskFamily.truthy }),
                                     "sources": Value(inv.sources.elements.filter { !$0.taskFamily.truthy })] as Value)
    if families.isEmpty || !context.existing.truthy || regular.move.length > 0 || regular.sources.length > 0 || regular.blocked.length > 0 || regular.unreadable.length > 0 || regular.rejected.length > 0 {
        result = try attempt(regular, .null, false, held, families.isEmpty ? report : unitReport(false))
    }
    if result["deferred"].truthy || result["recoveryRequired"].truthy { return result }
    for family in families {
        let unit = Value.spread(inv, ["move": Value(inv.move.elements.filter { $0.taskFamily === family }), "sources": Value(inv.sources.elements.filter { $0.taskFamily === family }),
                                      "there": [], "blocked": [], "unreadable": [], "rejected": [], "cloud": emptyCloud, "cloudRequested": false] as Value)
        if !result["file"].truthy && !context.existing.truthy { Value.assign(unit, ["blocked": inv.blocked, "unreadable": inv.unreadable, "rejected": inv.rejected] as Value) }
        result = try attempt(unit, family, false,
                             result["file"].truthy || context.existing.truthy ? .null : Value(held.elements.filter { row in !row.sources.elements.contains { source in family.files.includes(source.file) } }),
                             .undefined)
        if result["deferred"].truthy || result["recoveryRequired"].truthy { return result }
    }
    if !failed.isEmpty && result["file"].truthy {
        try report.call("recovery", "Retrying unfinished sessions once", ["live": true])
        let all = try accounts(paths)
        var target: Value = .undefined
        for row in all.elements where try sameAccount(row, to).truthy { target = row; break }
        if !target.truthy { return try blocked("The destination account disappeared during recovery") }
        let retrying = ValueSet(failed)
        var sourcesList: [Value] = []
        for row in all.elements {
            var matched = false
            for source in inv.fromAccounts.elements where try sameAccount(row, source).truthy { matched = true; break }
            if !matched { continue }
            sourcesList.append(Value.spread(row, ["sessions": Value(row.sessions.elements.filter { retrying.has($0.file) }),
                                                  "unreadable": Value(row.unreadable.elements.filter { retrying.has($0) })] as Value))
        }
        let next = try inventory(Value(sourcesList), target, paths, report, ["inspect": inv.inspect, "processes": try inv.inspect.call(), "check": context.check])
        context = Value.spread(context, ["sources": next.sources] as Value)
        let coveredFiles = try (next.sources.elements + next.rejected.elements + next.unreadable.elements).map { try desktopFileOf($0) }.filter { retrying.has($0) }
        let covered = ValueSet(coveredFiles)
        let keptFailed = result.receipt.failed.elements.filter { row in
            row.cloudAccount.truthy || row.sources.length == 0 || row.sources.elements.contains { source in !covered.has(source.file) }
        }
        result.receipt.failed = Value(keptFailed + (try inventoryFailures(next)).elements)
        var units: [(Value, Value)] = try unitsOf(Value((next.move.elements + next.there.elements).filter { !$0.taskFamily.truthy })).elements.map { ($0, Value.null) }
        for family in ValueSet(next.move.elements.map { $0.taskFamily }.filter { $0.truthy }).values {
            units.append((Value(next.move.elements.filter { $0.taskFamily === family }), family))
        }
        for (rows, family) in units {
            let members = rows.elements.flatMap { row in (row.members ?? [row]).elements }
            let unit = Value.spread(next, ["move": Value(rows.elements.filter { next.move.includes($0) }), "there": Value(rows.elements.filter { next.there.includes($0) }),
                                           "sources": Value(next.sources.elements.filter { row in family.truthy ? row.taskFamily === family : members.contains(row) }),
                                           "blocked": [], "unreadable": [], "rejected": [], "cloud": emptyCloud, "cloudRequested": false] as Value)
            result = try attempt(unit, family, true, .undefined, .undefined)
            if result["deferred"].truthy || result["recoveryRequired"].truthy { return result }
        }
        if try receiptSummary(result.receipt).notMoved.elements.contains(where: { retrying.has($0.file) }) { result.receipt.localStopped = true }
        _ = try saveJson(result.file, result.receipt)
    }
    let receipt = Receipt(result["receipt"])
    if receipt.isPresent && !context.existing.truthy && receipt.sessions.length == 0 && receipt.superseded.length == 0 && receipt.remote.length == 0 && !receipt.held["length"].truthy,
       try openCloudChecks(receipt).length == 0,
       !exists(.string(path.join(paths.state, "quarantine", context.at.description, "failed"))) {
        if result.file.truthy { try fs.rm(result.file.description, recursive: false, force: true) }
        return ["file": .null, "receipt": receipt.raw, "summary": try receiptSummary(receipt), "ok": try receiptOkay(receipt), "validationOnly": true]
    }
    if !result["file"].truthy {
        let refused: Value = ["failed": Value(orphans), "sessions": [], "superseded": [], "verification": ["ok": true, "problems": []]]
        return !orphans.isEmpty ? ["receipt": refused, "summary": try receiptSummary(refused), "file": .null, "ok": false, "validationOnly": true] : result
    }
    if families.isEmpty && failed.isEmpty { return result }
    if inv.cloud["checked"].truthy && !families.isEmpty {
        result = try transferRecords(Value.spread(inv, ["move": [], "sources": [], "targets": [], "there": [], "blocked": [], "unreadable": [], "rejected": [], "held": result.receipt.held] as Value),
                                     to, paths, unitReport(true), Value.spread(context, ["existing": ["file": file, "receipt": receipt.raw], "wholeOperation": true] as Value))
    } else if !families.isEmpty {
        for phase in ["verify", "retire"] { _ = try progress(report, .string(phase), completed[phase], totals[phase]) }
    }
    for (stage, text) in details.entries { try report.call(stage, text) }
    if inv.cloudRequested.truthy && (!context.existing.truthy || context.refreshCloudChecks.truthy) {
        let current = try accounts(paths)
        receipt.cloudChecks = try retainedCloudChecks(receipt, inv, current)
        _ = try saveJson(result.file, receipt.raw)
    }
    let pendingCloud = try openCloudChecks(receipt).length
    let tail: Value = [
        "summary": try receiptSummary(receipt), "ok": try receiptOkay(receipt),
        "complete": Value(pendingCloud == 0 && !receipt.held["length"].truthy && !receipt.localStopped.truthy), "pendingCloud": Value(pendingCloud),
        "pendingLabels": try cloudCheckLabels(receipt), "held": receipt.held, "added": Value(Double(receipt.sessions.length) - toNumber(firstCount)),
        "targetChanged": Value(Double(receipt.sessions.length) > toNumber(firstCount) ||
            sliceArray(receipt.superseded.elements, Int(toNumber(firstSuperseded))).contains { !$0.source.truthy }),
        "problems": receipt.verification["problems"] ?? [],
    ]
    return Value.spread(result, tail)
}

func transferRecords(_ inv: Value = .undefined, _ to: Value = .undefined, _ paths: DataLayout, _ report: Value = .undefined, _ context: Value = .undefined) throws -> Value {
    let context = context.isUndefined ? Value.newObject() : context
    try optCall(context.check, true)
    if context.restart.truthy && inv.cloud["checked"].truthy { throw EngineError("Cloud work cannot run inside the restart window") }
    let deferred = try deferredWorkflow(paths)
    if deferred.truthy && context.existing["file"] !== deferred.file {
        return ["deferred": deferred, "ok": false, "complete": false, "pendingCloud": deferred.mode === "cloud" ? Value(deferred.sources.length) : 0]
    }
    let started = dateNow()
    let startedAt: Value = inv.requestedAt ?? .string(isoString(started))
    let at: Value = context.existing["receipt"]["at"] ?? context.at ?? .string(stamp())
    let held: Value = inv.held ?? []
    let heldFiles = ValueSet(held.elements.flatMap { row in row.sources.elements.map { $0.file } })
    let unheldFailures: (Value) -> [Value] = { row in
        if row.cloudAccount.truthy || row.sources.length == 0 || ![WORKER_OWNS, PARENT_MISSING, SCHEDULER_OWNS].contains(where: { row.error === .string($0) }) { return [row] }
        let sources = row.sources.elements.filter { !heldFiles.has($0.file) }
        return sources.isEmpty ? [] : [Value.spread(row, ["sources": Value(sources)] as Value)]
    }
    let initialFailures: [Value] = try inventoryFailures(inv).elements.flatMap(unheldFailures)
    let receipt: Receipt
    if !context.existing["receipt"].nullish {
        receipt = Receipt(context.existing.receipt)
    } else {
        var cloudChecks: Value = []
        if inv.cloudRequested.truthy {
            let accountsList = (inv.cloudCheckAccounts ?? inv.fromAccounts ?? []).elements + (inv.deferredCloudSources ?? []).elements
            let map = ValueMap(accountsList.map { account in (Value.string("\(account.account)/\(account.org)"), Value.spread(account, ["status": "pending"] as Value)) })
            cloudChecks = Value(map.values)
        }
        let r: Value = [
            "at": at,
            "writer": .string(VERSION),
            "startedAt": startedAt,
            "from": inv.from,
            "to": to.label,
            "fromAccounts": inv.fromAccounts ?? [],
            "toAccount": try inv.toAccount ?? accountRef(to),
            "cloudChecks": cloudChecks,
            "cloudError": or(inv.cloudError, .null),
            "cloudLinks": try sourceCloudLinks(Value(inv.move.elements + inv.there.elements)),
            "sessions": [],
            "remote": [],
            "failed": Value(initialFailures),
            "superseded": [],
            "finalizing": true,
        ]
        if context.restart.truthy { r.restart = context.restart }
        receipt = Receipt(r)
    }
    let file: Value = .string(path.join(paths.state, "\(at).json"))
    if context.existing.truthy {
        receipt.appendCheckpoint = ["sessions": Value(receipt.sessions.length), "superseded": Value(receipt.superseded.length),
                                    "taskTransfers": receipt.taskTransfers["length"] ?? 0, "verification": receipt.verification, "held": receipt.held]
        let retryKeys = ValueSet(try (inv.move.elements + inv.there.elements).flatMap { row in try failureIdentity(row).sources.elements.map { try localFailureKey($0) } })
        receipt.failed = Value(try receipt.failed.elements.flatMap { row -> [Value] in
            if row.retained.truthy || row.cloudAccount.truthy || row.sources.length == 0 { return [row] }
            let sources = try row.sources.elements.filter { source in !retryKeys.has(try localFailureKey(source)) }
            return sources.isEmpty ? [] : [Value.spread(row, ["sources": Value(sources)] as Value)]
        })
        receipt.failed.asArray?.items.append(contentsOf: initialFailures)
        receipt.finalizing = true
        let links = try sourceCloudLinks(Value(inv.move.elements + inv.there.elements))
        for source in (inv.cloudCheckAccounts ?? []).elements {
            let check = try receiptCloudCheck(receipt, source)
            if !check.truthy {
                if inv.cloudRequested.truthy { receipt.cloudChecks.push(Value.spread(source, ["status": "pending"] as Value)) }
            } else if check.status !== "cancelled" {
                let ids = try source.sessionIds ?? linkedCloudIds(links, source)
                let prior = try check.sessionIds ?? linkedCloudIds(receipt.cloudLinks, source)
                if check.status === "complete" && ids.elements.contains(where: { !prior.includes($0) }) { _ = try clearCloudAttempt(receipt, source) }
                if check.sessionIds.truthy { check.sessionIds = Value(ValueSet(check.sessionIds.elements + ids.elements).values) }
            }
        }
        receipt.cloudLinks.asArray?.items.append(contentsOf: links.elements)
    }
    receipt.held = held
    let previousCount = receipt.sessions.length
    let previousSuperseded = receipt.superseded.length
    let save = Value { _ in
        if !context.restart.truthy { try optCall(context.check) }
        return try saveJson(file, receipt.raw)
    }
    let family = context.taskFamily
    if family.truthy {
        let source = try taskRegistry(family.sourceFile).data
        let target = try taskRegistry(family.targetFile).data
        let tasks = Value((source["scheduledTasks"] ?? []).elements.filter { task in family.ids.includes(task.id) })
        let routes = defaultSorted(tasks.elements.map { task in Value([task.id, task.notifySessionId ?? .null]) })
        if stable(Value(routes)) != stable(Value(defaultSorted(family.routes.elements))) { throw EngineError("scheduled task family changed since inventory") }
        let state = try taskState(source, family.ids), targetState = try taskState(target, family.ids)
        if try taskStateConflict(state, targetState).truthy { throw EngineError("target scheduled task state collision") }
        let targetOr: Value = target ?? [:]
        var replaced: [Value] = []
        for (index, task) in (target["scheduledTasks"] ?? []).elements.enumerated() where family.ids.includes(task.id) {
            replaced.append(["task": task, "index": Value(index), "state": try taskState(target, [task.id]), "stateFields": .strings(TASK_STATE_KEYS.filter { target.hasOwn($0) })])
        }
        let extra: Value = [
            "tasks": tasks, "state": state, "targetState": targetState, "targetStateFields": .strings(TASK_STATE_KEYS.filter { targetOr.hasOwn($0) }),
            "replaced": Value(replaced),
            "sourceOrder": Value((source["scheduledTasks"] ?? []).elements.map { $0.id }), "targetExisted": Value(target !== .null), "targetHadTasks": Value(targetOr.hasOwn("scheduledTasks")),
        ]
        let transferRow = Value.spread(family, extra)
        let problems = try taskTransferProblems([transferRow], paths, inv.inspect, true, context.check, context.snapshots)
        if problems.length > 0 { throw EngineError(problems.join(", ")) }
        family.replaced = transferRow.replaced
        receipt.taskTransfers = Value((receipt.taskTransfers ?? []).elements + [transferRow])
        try save.call()
        _ = try writeTaskRegistrations([transferRow], "source", false, paths, inv.inspect, context.check, context.snapshots)
        for row in inv.sources.elements { row.taskOwned = false }
    }
    let guardSources = ValueSet((context.sources ?? inv.sources).elements + inv.move.elements + inv.move.elements.flatMap { s in (s.members ?? []).elements }).values
    let rehomeGuard: Value = ["workers": try workers(try inv.inspect.call()), "inspect": inv.inspect, "sources": Value(guardSources), "targets": inv.targets,
                              "taskSessions": Value.newMap(), "created": Value.newMap(), "check": context.check]
    for taskFile in ValueSet(inv.move.elements.map { $0.account.taskFile } + [to.taskFile]).values {
        rehomeGuard.taskSessions.put(taskFile, try taskSessions(taskFile))
    }
    let landedRecordIds = ValueSet(to.sessions.elements.map { $0.record.sessionId }.filter { $0.truthy })
    _ = try progress(report, "move", 0, Value(inv.move.length))
    let journal: Value = inv.move.length > 0 ? try placementJournal(file, receipt, context.restart.truthy ? .undefined : context.check) : .null
    do {
        for (i, s) in inv.move.elements.enumerated() {
            try optCall(context.check)
            let targetId = s.id
            let made: [String] = [path.join(to.dir.description, path.basename(s.file.description))]
            receipt.pending = ["strategy": "rehome", "id": s.id, "title": s.title, "targetId": targetId, "made": .strings(made), "recordSha": .null, "creationRequired": true]
            try journal["save"].call()
            do {
                if s.record.forkedFromSessionId.truthy && !landedRecordIds.has(s.record.forkedFromSessionId) { throw EngineError("parent Desktop record did not move") }
                let row = try rehomeOne(s, to, Value { args in
                    let patch = args.count > 0 ? args[0] : .undefined, durable = args.count > 1 ? args[1] : .undefined
                    Value.assign(receipt.pending, patch)
                    return try journal["save"].call(durable)
                }, rehomeGuard)
                receipt.sessions.push(row)
                if row.targetRecordId.truthy { landedRecordIds.add(row.targetRecordId) }
            } catch {
                let error = errorObject(error)
                if error.code === "JOURNAL_WRITE" || error.code === "MOVE_STALLED" || error.code === "RESTART_REOPENED" { throw EngineError(error) }
                if receipt.pending.bridgeAppend.truthy {
                    do { _ = try restoreBridge(receipt.pending, Value { _ in try journal["save"].call(true) }, inv.inspect, false, false) }
                    catch let recovery { throw EngineError(try bridgeError(.string("\(error["message"]). \(errorObject(recovery)["message"])"))) }
                }
                let raw: Value = (try? readFile(.string(made[0]))) ?? .null
                let created = rehomeGuard.created.get(.string(made[0]))
                let found = try? fs.stat(made[0])
                if raw.truthy && created.truthy, let found, found.devValue === created.dev && found.inoValue === created.ino {
                    if Value.string(sha(raw)) !== receipt.pending.recordSha { throw EngineError(error) }
                    _ = try quarantine(.strings(made), .string(path.join(paths.state, "quarantine", at.description, "failed")))
                }
                receipt.failed.push(Value.spread(["id": s.id, "title": s.title, "error": error["message"]] as Value, try failureIdentity(s)))
            }
            receipt.pending = .null
            try journal["save"].call()
            _ = try progress(report, "move", Value(i + 1), Value(inv.move.length))
        }
    } catch {
        if !journal.nullish { try journal["close"].call() }
        throw error
    }
    if !journal.nullish { try journal["close"].call() }
    if !journal.nullish { try journal["compact"].call() }
    try optCall(context.check, true)
    let verified = try verify(Value(sliceArray(receipt.sessions.elements, previousCount)), report, context.check)
    let ok = verified.ok, lines = verified.lines, problems = verified.problems
    let priorProblems: Value = context.existing.truthy ? receipt.appendCheckpoint.verification["problems"] ?? [] : []
    receipt.verification = [
        "ok": and(and(ok, Value(receipt.appendCheckpoint["verification"]["ok"] !== false)), Value(priorProblems.length == 0)),
        "problems": Value(priorProblems.elements + problems.elements),
    ]
    try save.call()
    if family.truthy {
        let problems = try taskTransferProblems(try recoveryFamilies(receipt), paths, inv.inspect, true, context.check, context.snapshots)
        if problems.length > 0 { throw EngineError(problems.join(", ")) }
    }
    let retained = try retire(inv, to, receipt, paths, at, problems, save, report, context.check, context.snapshots)
    var unwound: [Value] = []
    if family.truthy {
        let retired = try retiredFiles(receipt)
        if !ok.truthy || inv.sources.elements.contains(where: { !retired.has($0.file) }) { throw EngineError("scheduled task family did not move completely") }
        let transfers = Value(receipt.taskTransfers.elements.filter { $0.key === family.key })
        _ = try writeTaskRegistrations(transfers, "target", true, paths, inv.inspect, context.check, context.snapshots)
        let tasks = transfers[0].tasks
        let liveWorkers = try workers(try inv.inspect.call())
        for row in receipt.sessions.elements.filter({ $0.taskFamily === family.key }) {
            row.taskOwned = Value(tasks.elements.contains { $0.notifySessionId === row.targetRecordId })
            try optCall(context.check)
            if try targetChanges(row, liveWorkers, false).length > 0 { throw EngineError("scheduled task family target changed during publication") }
        }
        let taskProblems = try taskTransferProblems(transfers, paths, inv.inspect, false, context.check, context.snapshots)
        if taskProblems.length > 0 { throw EngineError(taskProblems.join(", ")) }
    } else {
        let retired = try retiredFiles(receipt), liveWorkers = try workers(try inv.inspect.call())
        let units = try unitsOf(Value(inv.move.elements + inv.there.elements)).elements.filter { rows in
            rows.elements.contains { inv.move.includes($0) } &&
                !rows.elements.flatMap { row in (row.members ?? [row]).elements }.allSatisfy { member in
                    retired.has(member.file) || heldFiles.has(member.file) || retained.has(member.file)
                }
        }
        if !units.isEmpty {
            receipt.localRecovery = ["rollback": .string(randomUUID())]
            try save.call()
        }
        let failedDirectory = path.join(paths.state, "quarantine", at.description, "failed", (receipt.localRecovery["rollback"] ?? "").description)
        for rows in units {
            let ids = ValueSet(rows.elements.map { $0.id }), unitFiles = ValueSet(rows.elements.flatMap { row in (row.members ?? [row]).elements }.map { $0.file })
            let items = sliceArray(receipt.superseded.elements, previousSuperseded).filter { item in
                item.source.truthy ? unitFiles.has(item.moved[0][0]) : ids.has(item.by)
            }
            _ = try restore(Value(items), .string(path.join(paths.state, "quarantine")))
            receipt.superseded = Value(receipt.superseded.elements.filter { !items.contains($0) })
            let kept = ValueSet()
            for row in sliceArray(receipt.sessions.elements, previousCount).filter({ ids.has($0.id) }) {
                let changes = try rollbackTarget(row, .string(failedDirectory), liveWorkers, Value { _ in try restoreBridge(row, save, inv.inspect) })
                if changes.length > 0 {
                    kept.add(row.id)
                    receipt.failed.push(["id": row.id, "title": row.title, "error": .string("changed after placement, left in place: \(changes.join(", "))")])
                } else { receipt.sessions = Value(receipt.sessions.elements.filter { $0 !== row }) }
                try save.call()
            }
            let members = rows.elements.filter { !kept.has($0.id) }.flatMap { row in (row.members ?? [row]).elements }
            let files = ValueSet(members.map { $0.file })
            let checks = receipt.verification.problems.elements.filter { ids.has($0.id) }.map { $0.check }
            receipt.verification.problems = Value(receipt.verification.problems.elements.filter { !ids.has($0.id) })
            let lastFailure = receipt.failed.elements.last { row in row.sources.elements.contains { files.has($0.file) } } ?? .undefined
            let error = lastFailure["error"] ?? .string(!checks.isEmpty ? "\(Value(checks).join(", ")) changed during the move" : "the move did not complete")
            let covered = ValueSet(receipt.failed.elements.flatMap { row in (row.sources ?? []).elements }.map { $0.file })
            let rest = members.filter { !covered.has($0.file) }
            if !rest.isEmpty {
                receipt.failed.push(Value.spread(["id": rest[0].id, "title": rest[0].title, "error": error] as Value, try failureIdentity(["members": Value(rest)])))
            }
            unwound.append(contentsOf: files.values)
            try save.call()
        }
        if !units.isEmpty { receipt.clear(.localRecovery) }
        if !unwound.isEmpty { receipt.verification.ok = Value(receipt.verification.problems.length == 0 && receipt.appendCheckpoint["verification"]["ok"] !== false) }
    }
    let done = receipt.sessions.length
    if inv.cloudRequested.truthy {
        let current = try accounts(paths)
        var actual: [Value] = []
        for source in receipt.fromAccounts.elements {
            var match: Value = .undefined
            for account in current.elements where try sameAccount(account, source).truthy { match = account; break }
            if try localCloudPending(match).truthy { actual.append(source) }
        }
        if !context.existing.truthy || context.refreshCloudChecks.truthy { receipt.cloudChecks = try retainedCloudChecks(receipt, inv, current) }
        for source in actual {
            var present = false
            for check in receipt.cloudChecks.elements where try sameAccount(check, source).truthy { present = true; break }
            if !present { receipt.cloudChecks.push(Value.spread(source, ["status": "pending"] as Value)) }
        }
    }
    try optCall(context.check, true)
    receipt.finalizing = false
    receipt.clear(.appendCheckpoint)
    receipt.clear(.cloudAttempts)
    receipt.failed = Value(receipt.failed.elements.flatMap(unheldFailures))
    try save.call()
    try optCall(context.sessionProgress, receipt.raw)
    if inv.move.length > 0 || context.wholeOperation.truthy {
        let rehomed = receipt.sessions.elements.filter { $0.strategy === "rehome" }.count
        let events = receipt.sessions.elements.reduce(0.0) { n, row in n + toNumber(row.events) }
        let parts: [String?] = [
            "\(count(done)) \(receipt.verification.ok.truthy ? "✓" : "need verification")",
            "\(count(events)) events",
            rehomed > 0 ? "\(count(rehomed)) zero-copy" : nil,
            receipt.failed.length > 0 ? "\(receipt.failed.length) failed" : nil,
        ]
        try report.call("move", .string(parts.compactMap { $0 }.joined(separator: " | ")))
        if receipt.verification.ok.truthy {
            let sidecars = receipt.sessions.elements.reduce(0.0) { n, r in n + toNumber(r["sidecars"]["count"]) }
            try report.call("sidecars", .string("\(count(sidecars)) files | unchanged ✓"))
        }
    }
    _ = try archiveCloud(inv, receipt, save, report)
    if inv.cloud["checked"].truthy { _ = try finishCloudAttempt(receipt, inv.cloud, inv.cloud.later, inv.cloud.waiting) }
    _ = try projectLocalFailures(receipt, paths)
    if inv.cloud["later"].length > 0 { try report.call("later", .string(inv.cloud.later.elements.map { $0.title.description }.joined(separator: "\n"))) }
    let retired = try retiredCount(receipt)
    let superseded = Double(receipt.superseded.length) - toNumber(retired)
    let pendingCloud = try openCloudChecks(receipt).length
    if pendingCloud > 0 { try report.call("pending", .string(quantity(pendingCloud, "source cloud check"))) }
    if done == 0 && unwound.isEmpty && receipt.superseded.length == 0 && receipt.remote.length == 0 && !receipt.remotePending.truthy && pendingCloud == 0 && !receipt.held["length"].truthy &&
        !receipt.failed.elements.contains(where: { $0.blockedByLocal["length"].truthy }) {
        try fs.rm(file.description, recursive: false, force: true)
        return receipt.failed.length > 0
            ? ["file": .null, "receipt": receipt.raw, "summary": try receiptSummary(receipt), "checks": [], "problems": problems, "ok": try receiptOkay(receipt), "validationOnly": true]
            : .null
    }
    try save.call()
    if receipt.sessions.length > 0 {
        let archived = receipt.sessions.elements.filter { $0.archived.truthy }.count
        let parts: [String?] = [
            "\(count(done)) records",
            "\(count(archived)) archived",
            "\(count(done - archived)) active",
            superseded != 0 && !superseded.isNaN ? "\(count(superseded)) superseded" : nil,
        ]
        try report.call("desktop", .string(parts.compactMap { $0 }.joined(separator: " | ")))
        let seconds = roundHalfUp((dateNow() - started) / 1000)
        try report.call("verify", .string((lines.elements.map { $0.description } + ["\(numberString(seconds))s"]).joined(separator: " | ")))
    }
    if retired.truthy { try report.call("retired", .string("\(count(retired)) source records → quarantine | chat messages unchanged")) }
    let resultOkay = try receiptOkay(receipt)
    let newerCloud = receipt.cloudChecks.elements.reduce(0.0) { total, check in total + toNumber(check.later["length"] ?? 0) }
    let out: Value = [
        "file": file, "receipt": receipt.raw, "unwound": Value(unwound), "summary": try receiptSummary(receipt), "checks": lines, "problems": receipt.verification.problems,
        "ok": resultOkay, "complete": Value(pendingCloud == 0 && receipt.held.length == 0 && !receipt.localStopped.truthy),
        "added": Value(receipt.sessions.length - previousCount),
        "targetChanged": Value(receipt.sessions.length > previousCount || sliceArray(receipt.superseded.elements, previousSuperseded).contains { !$0.source.truthy }),
        "held": receipt.held, "pendingCloud": Value(pendingCloud), "pendingLabels": try cloudCheckLabels(receipt), "newerCloud": Value(newerCloud),
        "cloudChecked": inv.cloud["checked"].truthy ? 1 : 0,
    ]
    return out
}

public func finishPending(_ paths: Value = .undefined, _ options: Value = .undefined) throws -> Value { try finishPending(DataLayout(paths), options) }
func finishPending(_ paths: DataLayout, _ options: Value = .undefined) throws -> Value {
    let options = options.isUndefined ? Value.newObject() : options
    return try locked(paths, Value { _ in
        let latest = try latestReceipt(paths)
        if !latest.truthy { return ["nothing": true, "ok": true, "complete": true, "pendingCloud": 0] }
        if options.receiptFile.truthy && latest.file !== options.receiptFile { return ["nothing": true, "ok": true] }
        if try latest.corrupt.truthy || needsRecovery(latest.receipt).truthy {
            if (options.automatic.truthy || options.background.truthy) && (latest.receipt.undoing.truthy || latest.receipt.remoteUndoing["length"].truthy) {
                _ = try reconcile(paths, options)
                return ["pending": true, "ok": true, "complete": false]
            }
            let reconciled = try reconcile(paths, options)
            if reconciled["undo"].truthy { return Value.spread(reconciled.undo, ["ok": true, "complete": true, "pendingCloud": 0, "pendingUndo": []] as Value) }
            if reconciled["pendingUndo"].truthy {
                return ["receipt": reconciled.receipt, "ok": true, "complete": false, "pendingCloud": 0, "pendingUndo": reconciled.pendingUndo, "remoteRestored": reconciled.remoteRestored ?? 0]
            }
            return ["reconciled": reconciled, "recoveryRequired": true, "ok": false, "complete": false]
        }
        let file = latest.file, receipt = Receipt(latest.receipt)
        let outstanding = try openCloudChecks(receipt)
        if outstanding.length == 0 {
            if latest.projected.truthy { _ = try saveJson(file, receipt.raw) }
            let ok = try finishOkay(receipt)
            let complete = !receipt.held["length"].truthy && (!receipt.localStopped.truthy || receipt.localCancelledAt.truthy)
            let nothing = and(ok, Value(complete))
            let failed = try (receipt.failed ?? []).elements.filter { row in try (row.cloudAccount.truthy ? actionableCloudFailure(receipt, row) : nothing).truthy }
            let notMoved: Value = nothing.truthy ? [] : Value((receipt.failed ?? []).elements.filter { !$0.cloudAccount.truthy })
            let reason: Value = receipt.verification["ok"] === false && !receipt.verification.problems["length"].truthy ? "The previous move failed verification" : .undefined
            return ["nothing": nothing, "receipt": receipt.raw, "file": file, "summary": try receiptSummary(receipt), "ok": ok, "complete": Value(complete), "pendingCloud": 0, "failed": Value(failed),
                    "notMoved": notMoved, "problems": receipt.verification["problems"] ?? [], "reason": reason]
        }
        let active = try cloudIdentity(paths, options), now = dateNow(), memory = try selectedMemory(options)
        let table: Value = options.automatic.truthy ? try options.processes ?? processTable(Value(paths.claudeApp)) : []
        let eligible = try outstanding.elements.filter { source in try sameLogin(source, active).truthy && cloudScope(options.cloud, source).truthy }
        let candidates = try eligible.filter { source in
            if !options.automatic.truthy { return true }
            guard try options.automatic.typeOf != "object" || sameAccount(source, options.automatic).truthy else { return false }
            guard try cloudRetryAt(receipt, source, active, Value(now), memory) !== .null else { return false }
            guard now >= toNumber(try cloudRetryAt(receipt, source, active, Value(now), memory)) else { return false }
            return try !canRestartWaiting(Receipt(["cloudChecks": [source]]), table).truthy || budgetRetryRows(source, memory).length > 0
        }
        let check = try stableSorted(candidates) { a, b in toNumber(try cloudAttemptAt(receipt, a)) - toNumber(try cloudAttemptAt(receipt, b)) }.first ?? .undefined
        if !check.truthy {
            if try options.automatic.truthy || !eligible.isEmpty || outstanding.elements.contains(where: { try sameLogin($0, active).truthy }) { return ["pending": true, "ok": true, "complete": false] }
            throw EngineError("sign Claude Desktop into \(Value(ValueSet(try outstanding.elements.map { try loginLabel($0) }).values).join(" or "))")
        }
        let report = Value { args in
            let stage = args.count > 0 ? args[0] : .undefined, text = args.count > 1 ? args[1] : .undefined
            let extra = args.count > 2 && !args[2].isUndefined ? args[2] : Value.newObject()
            if options.report.nullish { return .undefined }
            return try options.report.call(stage, text, Value.spread(try sourceProgress(check), extra))
        }
        let retryRows: Value = options.automatic.truthy ? try budgetRetryRows(check, memory) : []
        let budgetRetry: Value = retryRows.length > 0 ? Value(ValueSet(try retryRows.elements.map { try remoteId($0.id) }.filter { $0.truthy }).values) : .null
        let serial = Value(budgetRetry.truthy)
        let kept = try keptCopy(receipt)
        let preserved = ValueSet(try receipt.failed.elements.filter { row in
            try cloudTagged(row, check).truthy && (try kept.call(row).truthy || options.automatic.truthy && (try limitedFailure(check, row, memory)).truthy)
        })
        if active.at.truthy && check.loginAt !== active.at { check.authRetries = 0 }
        check.loginAt = active.at ?? .null
        let attempts = Value.spread(receipt.cloudAttempts)
        attempts["\(check.account)/\(check.org)"] = Value(now)
        receipt.cloudAttempts = attempts
        _ = try clearCloudAttempt(receipt, check, Value { args in Value(preserved.has(args.first ?? .undefined)) })
        _ = try saveJson(file, receipt.raw)
        var cloud: Value = .undefined, to: Value = .undefined, inv: Value = .undefined
        do {
            cloud = try sourceCloud(paths, check, options.cloud)
            let all = try accounts(paths, options.processes)
            var source: Value = .undefined
            for account in all.elements where try sameAccount(account, check).truthy { source = account; break }
            for account in all.elements where try sameAccount(account, receipt.toAccount).truthy { to = account; break }
            if !source.truthy { throw EngineError("\(check.label) is no longer available") }
            if !to.truthy { throw EngineError("\(receipt.to) is no longer available") }
            let cloudSource = Value.spread(source, ["sessions": [], "unreadable": []] as Value)
            let cloudBridgeIds = ValueMap()
            let links = try (receipt.cloudLinks ?? []).elements.filter { row in try sameAccount(row, cloud).truthy }
            for row in links {
                cloudBridgeIds.set(row.targetId, Value(ValueSet((cloudBridgeIds.get(row.targetId) ?? []).elements + row.bridgeIds.elements).values))
            }
            let cloudExcludedIds = ValueSet(try receipt.failed.elements.filter { row in
                try cloudTagged(row, cloud).truthy && (row.blockedByLocal["length"].truthy || preserved.has(row))
            }.map { try remoteId($0.id) }.filter { $0.truthy })
            let invOptions: Value = [
                "cloud": cloud, "memory": memory, "serial": serial, "budgetRetry": budgetRetry, "cloudRequested": true, "cloudTargetOnly": true, "cloudCutoff": receipt.startedAt,
                "cloudBridgeIds": .map(cloudBridgeIds), "cloudSessionIds": check.sessionIds.truthy ? Value.newSet(check.sessionIds.elements) : .null,
                "cloudExcludedIds": .set(cloudExcludedIds), "writeCache": true, "automatic": Value(options.automatic.truthy), "artifactLimit": options.artifactLimit,
                "processes": options.processes,
            ]
            inv = try inventory([cloudSource], to, paths, report, invOptions)
        } catch {
            let error = errorObject(error)
            _ = try addCloudFailure(receipt, check, ["id": error.budgetWork["id"] ?? .null, "title": check.label, "error": error["message"], "code": try memoryErrorCode(error)])
            _ = try finishCloudAttempt(receipt, check, [], error.budgetWork["waiting"] ?? [],
                                       ["memory": memory, "isolatedId": error.budgetWork["id"] ?? (budgetRetry.truthy ? .null : .undefined)])
            _ = try saveJson(file, receipt.raw)
            let failed = try receipt.failed.elements.filter { try actionableCloudFailure(receipt, $0).truthy }
            return ["file": file, "receipt": receipt.raw, "summary": try receiptSummary(receipt), "ok": false, "complete": false, "pendingCloud": Value(try openCloudChecks(receipt).length),
                    "pendingLabels": try cloudCheckLabels(receipt), "failed": Value(failed)]
        }
        for blocked in (inv.cloud["blocked"] ?? []).elements { _ = try addCloudFailure(receipt, cloud, try inventoryFailure(blocked)) }
        if inv.cloud["later"].length > 0 { try report.call("later", .string(inv.cloud.later.elements.map { $0.title.description }.joined(separator: "\n"))) }
        let save = Value { _ in try saveJson(file, receipt.raw) }
        let beforeRemote = receipt.remote.length
        _ = try archiveCloud(inv, receipt, save, report)
        _ = try finishCloudAttempt(receipt, cloud, inv.cloud.later, inv.cloud.waiting, ["memory": memory, "isolatedId": inv.cloud.isolatedId])
        _ = try projectLocalFailures(receipt, paths)
        try save.call()
        let completedRemote = sliceArray(receipt.remote.elements, beforeRemote)
        let pendingCloud = try openCloudChecks(receipt).length
        let failed = try receipt.failed.elements.filter { try actionableCloudFailure(receipt, $0).truthy }
        let ok = try finishOkay(receipt)
        let reason: Value = receipt.verification["ok"] === false && !receipt.verification.problems["length"].truthy ? "The previous move failed verification" : .undefined
        let out: Value = [
            "file": file,
            "receipt": receipt.raw,
            "summary": try receiptSummary(receipt),
            "ok": ok,
            "complete": Value(pendingCloud == 0 && !receipt.held["length"].truthy && (!receipt.localStopped.truthy || receipt.localCancelledAt.truthy)),
            "pendingCloud": Value(pendingCloud),
            "pendingLabels": try cloudCheckLabels(receipt),
            "cloudArchived": Value(completedRemote.count),
            "cloudChecked": 1,
            "checkedAccount": try accountRef(check),
            "newerCloud": Value(inv.cloud.later.length),
            "failed": Value(failed),
            "notMoved": Value(receipt.failed.elements.filter { !$0.cloudAccount.truthy }),
            "problems": receipt.verification["problems"] ?? [],
            "reason": reason,
            "restart": Value(!completedRemote.isEmpty),
        ]
        return out
    })
}

public func keepLocal(_ paths: Value = .undefined, _ options: Value = .undefined) throws -> Value { try keepLocal(DataLayout(paths), options) }
func keepLocal(_ paths: DataLayout, _ options: Value = .undefined) throws -> Value {
    let options = options.isUndefined ? Value.newObject() : options
    return try locked(paths, Value { _ in
        let recovery = try recoveryPending(paths)
        if recovery.truthy { return ["recoveryRequired": true, "recovery": recovery] }
        let latest = try latestReceipt(paths)
        if !latest.truthy { return ["nothing": true] }
        let file = latest.file, receipt = Receipt(latest.receipt)
        let available = try openCloudChecks(receipt)
        let optionChecks = options["checks"]
        let checks: [Value] = optionChecks["length"].truthy
            ? try available.elements.filter { check in optionChecks.includes(try cloudCancelToken(file, check)) }
            : available.elements
        if optionChecks["length"].truthy && checks.count != ValueSet(optionChecks.elements).size {
            return ["refused": [], "code": "PENDING_CHANGED", "reason": "The pending source checks changed. Review them again."]
        }
        let heldCancelled: Value = optionChecks["length"].truthy ? 0 : try heldCount(receipt.held)
        if checks.isEmpty && !heldCancelled.truthy && !receipt.localStopped.truthy { return ["nothing": true, "file": file, "receipt": receipt.raw] }
        let unsafe = try (receipt.verification["problems"] ?? []).elements.filter { problem in try checks.contains { check in try cloudTagged(problem, check).truthy } }
        var refused: [Value] = try unsafe.map { try problemText($0) }
        let liveWorkers = try workers()
        for row in receipt.sessions.elements {
            let changes = try targetChanges(row, liveWorkers, Value(row.strategy !== "rehome"), true)
            if changes.length > 0 { refused.append(.string("\(row.title) | \(changes.join(", ")) changed")) }
        }
        var to: Value = .undefined
        for account in try accounts(paths).elements where try sameAccount(account, receipt.toAccount).truthy { to = account; break }
        let existing = (receipt.superseded ?? []).elements.filter { row in row.source.truthy && !receipt.sessions.elements.contains { $0.targetId === row.by } }
        refused.append(contentsOf: try restoreProblems(receipt.superseded ?? [], .string(path.join(paths.state, "quarantine"))).elements)
        var sourceSessions: [Value] = []
        for source in existing {
            let sourceFile = source.moved[0][1]
            let record: Value = sourceFile.truthy ? ((try? readJson(sourceFile)) ?? .null) : .null
            if record.truthy { sourceSessions.append(try desktopSession(sourceFile, record)) }
            else { refused.append(.string("\(source.title) | source recovery record missing")) }
        }
        if !sourceSessions.isEmpty && to.truthy {
            let auditSource: Value = ["account": "retired", "org": "retired", "label": "retired sources", "sessions": Value(sourceSessions), "unreadable": [],
                                      "taskFile": .string(path.join(paths.state, "keep-local-audit-tasks.json")), "taskSessions": Value.newSet(), "taskError": .null]
            do {
                let audit = try inventory([auditSource], to, paths)
                let covered = ValueSet(audit.there.elements.flatMap { source in (source.members ?? [source]).elements.map { $0.file } })
                for source in sourceSessions where !covered.has(source.file) { refused.append(.string("\(source.title) | destination no longer contains source history")) }
            } catch {
                refused.append(.string("destination verification failed | \(errorObject(error)["message"])"))
            }
        }
        if !sourceSessions.isEmpty && !to.truthy { refused.append(.string("\(receipt.to) | destination account missing")) }
        if !refused.isEmpty { return ["file": file, "receipt": receipt.raw, "refused": Value(refused)] }
        _ = try cancelCloudChecks(receipt, Value(checks))
        if !optionChecks["length"].truthy {
            receipt.held = []
            receipt.localCancelledAt = .string(isoNow())
        }
        receipt.failed = Value(try (receipt.failed ?? []).elements.filter { failure in
            try failure.blockedByLocal["length"].truthy || !checks.contains { check in try cloudTagged(failure, check).truthy }
        })
        if try openCloudChecks(receipt).length == 0 { receipt.cloudError = .null }
        _ = try saveJson(file, receipt.raw)
        let out: Value = [
            "file": file, "receipt": receipt.raw, "summary": try receiptSummary(receipt), "cancelled": Value(checks.count), "heldCancelled": heldCancelled,
            "labels": Value(checks.map { $0.label }), "ok": try finishOkay(receipt),
            "complete": Value(try openCloudChecks(receipt).length == 0 && !receipt.held["length"].truthy),
            "failed": Value(try receipt.failed.elements.filter { try actionableCloudFailure(receipt, $0).truthy }),
            "notMoved": Value(receipt.failed.elements.filter { !$0.cloudAccount.truthy }),
        ]
        return out
    })
}

public func move(_ inv: Value = .undefined, _ to: Value = .undefined, _ paths: Value = .undefined, _ report: Value = .undefined) throws -> Value { try move(inv, to, DataLayout(paths), report) }
func move(_ inv: Value = .undefined, _ to: Value = .undefined, _ paths: DataLayout, _ report: Value = .undefined) throws -> Value {
    let report = fnOr(report)
    return try locked(paths, Value { _ in
        let reconciled = try reconcile(paths, ["cloud": inv.cloud["client"]])
        return reconciled.truthy ? ["reconciled": reconciled, "recoveryRequired": true, "ok": false] : try transfer(inv, to, paths, report)
    })
}
