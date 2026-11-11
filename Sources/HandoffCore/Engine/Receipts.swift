import Darwin
import Foundation

// Receipts, journals, atomic writes, Undo, recovery and reconciliation.

// MARK: - Local helpers

fileprivate func arg(_ a: [Value], _ i: Int) -> Value { i < a.count ? a[i] : .undefined }

@discardableResult
fileprivate func optCall(_ f: Value, _ args: Value...) throws -> Value {
    if f.nullish { return .undefined }
    return try f.callArgs(args)
}

fileprivate func catchNull(_ f: () throws -> Value) -> Value {
    do { return try f() } catch { return .null }
}

// Array results are flattened one level; other results are kept as they are.
fileprivate func flatMapValues(_ xs: [Value], _ f: (Value) throws -> Value) rethrows -> [Value] {
    var out: [Value] = []
    for x in xs {
        let r = try f(x)
        if case .array(let a) = r { out.append(contentsOf: a.items) } else { out.append(r) }
    }
    return out
}

// A slice or splice index: undefined and NaN are 0, fractions truncate, and huge values clamp.
fileprivate func toInteger(_ v: Value) -> Int {
    let d = v.isUndefined ? 0 : toNumber(v)
    if d.isNaN { return 0 }
    if d >= 9.0e18 { return Int.max / 2 }
    if d <= -9.0e18 { return Int.min / 2 }
    return Int(d.rounded(.towardZero))
}

// A splice start: negative counts from the end, clamped to the array.
fileprivate func spliceStart(_ d: Double, _ length: Int) -> Int {
    if d.isNaN { return 0 }
    let n = d.isInfinite ? (d < 0 ? Int.min / 2 : Int.max / 2) : Int(d.rounded(.towardZero))
    return n < 0 ? max(0, length + n) : min(n, length)
}

fileprivate func indexOf(_ xs: Value, _ v: Value) -> Int { xs.elements.firstIndex { $0 === v } ?? -1 }

// `set.values().next().value`
fileprivate func firstValue(_ s: Value) -> Value { s.elements.first ?? .undefined }

fileprivate func errorMessage(_ error: Error) -> Value { errorObject(error)["message"] }

// MARK: - Receipts

func receipts(_ paths: Value = .undefined) throws -> Value {
    let names: [String]
    do { names = try fs.names(paths.state.description) } catch { names = [] }
    return .strings(defaultSorted(names.filter { RECEIPT_FILE.test($0) }))
}

public func latestReceipt(_ paths: Value = .undefined) throws -> Value {
    let name = try receipts(paths).elements.last ?? .undefined
    if !name.truthy { return .null }
    let file = Value(path.join(paths.state.description, name.description))
    let receipt = catchNull { try readReceipt(file) }
    if !receipt.truthy { return ["name": name, "file": file, "corrupt": true] }
    if !receipt.writer.truthy && (receipt.finalizing.truthy && receipt.appendCheckpoint.truthy && receipt.appendCheckpoint.taskTransfers.isUndefined
        || receipt.pending.truthy && !(["rehome", "remote"] as Value).includes(receipt.pending.strategy)) {
        throw makeError(OLDER_MOVE, code: "OLDER_MOVE", [("file", file)])
    }
    let before = stable(receipt)
    if try !needsRecovery(receipt).truthy { _ = try projectLocalFailures(receipt, paths) }
    return ["name": name, "file": file, "receipt": receipt, "projected": Value(stable(receipt) != before)]
}

public func deferredWorkflow(_ paths: Value = .undefined, _ latest: Value = .undefined) throws -> Value {
    var latest = latest
    if latest.isUndefined { latest = try latestReceipt(paths) }
    if !latest.truthy || latest.corrupt.truthy { return .null }
    let receipt = latest.receipt
    if receipt.remoteUndoing["length"].truthy {
        let m = ValueMap()
        for row in receipt.remoteUndoing.elements {
            m.set(Value("\(row.account)/\(row.org)"), ["account": row.account, "org": row.org, "label": try accountLabel(row)])
        }
        return .spread(latest, ["mode": "undo", "sources": Value(m.values)])
    }
    if (receipt.pending.truthy || receipt.retiring.truthy || receipt.finalizing.truthy || receipt.undoing.truthy) && receipt.taskTransfers["length"].truthy {
        let transfers = try recoveryFamilies(receipt)
        let m = ValueMap()
        for row in transfers.elements { m.set(Value("\(row.from.account)/\(row.from.org)"), row.from) }
        let sources = m.values
        if !sources.isEmpty {
            return .spread(latest, ["mode": receipt.undoing.truthy ? "undo" : "recovery", "recovery": true, "sources": Value(sources)])
        }
    }
    if receipt.undoing.truthy { return .spread(latest, ["mode": "undo", "sources": receipt.fromAccounts ?? Value.newArray()]) }
    if receipt.held["length"].truthy {
        let m = ValueMap()
        for row in flatMapValues(receipt.held.elements, { $0.sources }) {
            m.set(Value("\(row.account)/\(row.org)"), ["account": row.account, "org": row.org, "label": try accountLabel(row)])
        }
        return .spread(latest, ["mode": "local", "sources": Value(m.values)])
    }
    let sources = try openCloudChecks(receipt)
    if sources.length == 0 && receipt.localStopped.truthy && !receipt.localCancelledAt.truthy {
        let partial = try receipt.fromAccounts.elements.filter { source in
            try receiptSummary(receipt).notMoved.elements.contains { row in try sameAccount(row, source).truthy }
        }
        return .spread(latest, ["mode": "partial", "sources": Value(partial)])
    }
    return sources.length != 0 ? .spread(latest, ["mode": "cloud", "sources": sources]) : .null
}

@discardableResult
func syncPath(_ file: Value = .undefined) throws -> Value {
    let handle = try fs.open(file.description, O_RDONLY | O_NOFOLLOW, 0o666)
    do { try handle.sync() } catch {
        try handle.close()
        throw error
    }
    try handle.close()
    return .undefined
}

@discardableResult
func saveText(_ file: Value = .undefined, _ text: Value = .undefined, _ before: Value = .undefined, _ durable: Value = .undefined) throws -> Value {
    let before = fnOr(before)
    let durable = durable.isUndefined ? Value(false) : durable
    let temp = "\(file).\(process.pid).\(randomUUID()).tmp"
    defer { try? fs.unlink(temp) }
    let data: Data = text.asData ?? Data(text.description.utf8)
    try fs.writeFile(temp, data, "wx", 0o600)
    if durable.truthy { try syncPath(Value(temp)) }
    try before.call()
    try fs.rename(temp, file.description)
    if durable.truthy { try syncPath(Value(path.dirname(file.description))) }
    productive()
    return text
}

@discardableResult
func saveJson(_ file: Value = .undefined, _ value: Value = .undefined, _ spacing: Value = .undefined, _ durable: Value = .undefined) throws -> Value {
    let spacing = spacing.isUndefined ? 2 : toInteger(spacing)
    return try saveText(file, Value(jsonText(value, spacing)), .undefined, durable)
}

public func readReceipt(_ file: Value = .undefined) throws -> Value {
    let receipt = try readJson(file)
    let handle: FileHandle
    do { handle = try fs.open("\(file).journal", "r") } catch {
        if errorObject(error).code === "ENOENT" { return receipt }
        throw error
    }
    func apply(_ line: String) throws {
        let patch = try JSON.parse(line)
        if !isSafeInteger(patch.sequence) || toNumber(patch.sequence) < 1 { throw EngineError("Invalid move journal sequence") }
        let sequence = toNumber(patch.sequence)
        if sequence <= toNumber(receipt.journalSequence ?? 0) { return }
        if sequence != toNumber(receipt.journalSequence ?? 0) + 1 { throw EngineError("Incomplete move journal") }
        for key in ["sessions", "failed", "retained"] {
            if !patch[key].isArray { throw EngineError("Invalid move journal entries") }
            for row in patch[key].elements {
                if receipt[key].nullish { receipt[key] = Value.newArray() }
                receipt[key].push(row)
            }
        }
        receipt.pending = patch.pending
        receipt.journalSequence = patch.sequence
    }
    do {
        var parts: [UInt8] = []
        try handle.chunks { chunk in
            productive()
            let bytes = [UInt8](chunk)
            var start = 0
            while let end = bytes[start...].firstIndex(of: 10) {
                let part = bytes[start..<end]
                try apply(String(decoding: parts.isEmpty ? Array(part) : parts + part, as: UTF8.self))
                parts = []
                start = end + 1
            }
            if start < bytes.count { parts.append(contentsOf: bytes[start...]) }
        }
    } catch {
        try handle.close()
        throw error
    }
    try handle.close()
    return receipt
}

func placementJournal(_ file: Value = .undefined, _ receipt: Value = .undefined, _ check: Value = .undefined) throws -> Value {
    let check = fnOr(check)
    try check.call()
    try saveJson(file, receipt)
    let name = "\(file).journal"
    try check.call()
    try fs.rm(name, recursive: false, force: true)
    try check.call()
    let handle = try fs.open(name, "ax", mode: 0o600)
    let keys = ["sessions", "failed", "retained"]
    var sizes: [String: Int] = [:]
    for key in keys { sizes[key] = receipt[key].nullish ? 0 : receipt[key].length }
    let save = Value { args in
        let durable = arg(args, 0).isUndefined ? Value(false) : arg(args, 0)
        try check.call()
        let patch: Value = ["sequence": Value(toNumber(receipt.journalSequence ?? 0) + 1), "pending": receipt.pending ?? .null]
        for key in keys { patch[key] = Value(sliceArray((receipt[key] ?? Value.newArray()).elements, sizes[key]!)) }
        do {
            try handle.writeFile(jsonText(patch, 0))
            if durable.truthy {
                try handle.sync()
                try syncPath(file)
                try syncPath(Value(path.dirname(file.description)))
            }
            productive()
        } catch {
            let e = errorObject(error)
            e["code"] = "JOURNAL_WRITE"
            throw EngineError(e)
        }
        receipt.journalSequence = patch.sequence
        for key in keys { sizes[key] = receipt[key].nullish ? 0 : receipt[key].length }
        try check.call()
        return .undefined
    }
    let close = Value { _ in try handle.close(); return .undefined }
    let compact = Value { _ in
        try check.call()
        try saveJson(file, receipt)
        try check.call()
        try fs.rm(name, recursive: false, force: true)
        return .undefined
    }
    return ["save": save, "close": close, "compact": compact]
}

public func recoveryPending(_ paths: Value = .undefined) throws -> Value {
    let latest = try latestReceipt(paths)
    if !latest.truthy || latest.corrupt.truthy { return latest }
    return try needsRecovery(latest.receipt).truthy ? ["name": latest.name, "file": latest.file, "receipt": latest.receipt] : .null
}

func parkingOrder(_ item: Value = .undefined) throws -> Value {
    func tmp(_ v: Value) -> Double { (v[0].asString?.hasSuffix(".json.tmp") ?? false) ? 1 : 0 }
    return Value(stableSorted(item.moved.elements) { a, b in tmp(b) - tmp(a) })
}

@discardableResult
func park(_ plan: Value = .undefined, _ before: Value = .undefined) throws -> Value {
    let before = fnOr(before)
    for item in plan.elements {
        try before.call(item)
        let hashes = ValueMap((item.hashes ?? Value.newArray()).elements.map { ($0[0], $0[1]) })
        let trees = ValueMap((item.trees ?? Value.newArray()).elements.map { ($0[0], $0[1]) })
        let semantics = ValueMap((item.semantics ?? Value.newArray()).elements.map { ($0[0], $0[1]) })
        for pair in try parkingOrder(item).elements {
            let original = pair[0], parked = pair[1]
            let hasOriginal = exists(original), hasParked = exists(parked)
            if hasOriginal && hasParked { throw EngineError("retirement path occupied: \(path.basename(parked.description))") }
            if hasParked { continue }
            if !hasOriginal { throw EngineError("retirement artifact missing: \(path.basename(original.description))") }
            if hashes.has(original), Value(sha(try readFile(original))) !== hashes.get(original) {
                throw EngineError("retirement artifact changed: \(path.basename(original.description))")
            }
            if trees.has(original), try manifest(original).sha !== trees.get(original) {
                throw EngineError("retirement artifact changed: \(path.basename(original.description))")
            }
            if semantics.has(original), try recordSemantic(try readJson(original)) !== semantics.get(original) {
                throw EngineError("retirement artifact changed: \(path.basename(original.description))")
            }
            if LOCAL_RECORD.test(path.basename(original.description, ".json")) && exists(Value("\(original).tmp")) {
                throw EngineError("Desktop record has a new pending update: \(path.basename(original.description))")
            }
            try fs.mkdirp(path.dirname(parked.description))
            try fs.rename(original.description, parked.description)
            productive()
        }
    }
    return .undefined
}

@discardableResult
func restore(_ plan: Value = .undefined, _ root: Value = .undefined, _ before: Value = .undefined) throws -> Value {
    let before = fnOr(before)
    for p in plan.elements.reversed() {
        for pair in try parkingOrder(p).elements.reversed() {
            let original = pair[0], parked = pair[1]
            try before.call()
            if exists(parked) && !exists(original) { try fs.rename(parked.description, original.description) }
        }
    }
    let rootPath = root.description
    for p in plan.elements {
        for pair in p.moved.elements {
            var dir = path.dirname(pair[1].description)
            while dir != rootPath && !path.relative(rootPath, dir).hasPrefix("..") && ((try? fs.rmdir(dir)) != nil) { dir = path.dirname(dir) }
        }
    }
    return .undefined
}

func prepareUndo(_ receipt: Value = .undefined, _ paths: Value = .undefined) throws -> Value {
    let dest = path.join(paths.state.description, "quarantine", receipt.at.description)
    var plan: [Value] = []
    for row in receipt.sessions.elements {
        let files: [Value] = row.strategy === "rehome" ? [] : [row.targetTranscript].filter { $0.truthy }
        let trees: [Value] = row.strategy === "rehome" ? [] : [row.targetDir].filter { $0.truthy }
        let items = try artifacts(row)
        let item: Value = [
            "id": row.targetId,
            "title": row.title,
            "required": items,
            "hashes": Value(files.map { [$0, .null] as Value }),
            "trees": Value(trees.map { [$0, .null] as Value }),
            "semantics": [[row.record, .null]],
            "moved": Value(items.elements.map { [$0, Value(path.join(dest, path.basename($0.description)))] as Value }),
        ]
        plan.append(try snapshotPlan(item))
    }
    return Value(plan)
}

func taskTransferProblems(_ transfers: Value = .undefined, _ paths: Value = .undefined, _ inspect: Value = .undefined, _ partial: Value = .undefined, _ check: Value = .undefined, _ snapshots: Value = .undefined) throws -> Value {
    let partial = partial.isUndefined ? Value(false) : partial
    let check = fnOr(check)
    let snapshots = snapshots.isUndefined ? Value.null : snapshots
    var problems: [Value] = []
    for family in transfers.elements {
        try check.call()
        do {
            let ids = Value.newSet(family.ids.elements), recordIds = Value.newSet(family.recordIds.elements)
            let links = Value.newMap(family.links.elements.map { ($0[0], Value(stable($0))) })
            let cliIds = Value.newSet(family.links.elements.map { $0[1] })
            let inspected = try optCall(inspect)
            let table = try inspected.nullish ? processTable(paths.claudeApp) : inspected
            let liveWorkers = Value.newSet(flatMapValues(table.elements.filter { $0.worker.truthy }) { $0.ids })
            if try schedulerBusy(paths, [family.from, family.to], table).truthy { problems.append(Value(SCHEDULER_OWNS)) }
            if try sameAccount(family.from, family.to).truthy { throw EngineError("scheduled task namespaces must differ") }
            var selected: [Bool] = []
            for (file, namespace) in [(family.sourceFile, family.from), (family.targetFile, family.to)] {
                if !UUID.test(namespace.account.description) || !UUID.test(namespace.org.description)
                    || file !== Value(path.join(paths.records.description, namespace.account.description, namespace.org.description, "scheduled-tasks.json")) {
                    throw EngineError("scheduled task namespace mismatch")
                }
                let registry = try taskSessions(file).registry
                let tasks = registry.scheduledTasks ?? Value.newArray()
                let target = file === family.targetFile
                let kind = try taskRegistrationKind(family, registry, Value(target), selected.isEmpty ? .undefined : Value(selected[0]))
                if tasks.elements.contains(where: { !ids.has($0.id) && recordIds.has($0.notifySessionId) }) { throw EngineError("new scheduled task dependency") }
                if family.state.truthy {
                    let expected = try kind === "published" ? family.state : target ? family.targetState : taskState(.null, Value.newArray())
                    if try stable(taskState(registry, family.ids)) != stable(expected) { throw EngineError("scheduled task state changed") }
                }
                selected.append(kind === "published")
                let dir = Value(path.dirname(file.description))
                let rows: Value
                do { rows = try folderRecords(dir, snapshots, check) } catch {
                    let e = errorObject(error)
                    if file === family.targetFile && e.code === "ENOENT" && e.path === dir { rows = Value.newArray() } else { throw error }
                }
                var records: [Value] = []
                for row in rows.elements {
                    let recordFile = row.file, record = row.record
                    try check.call()
                    records.append(record)
                    let member = recordIds.has(record.sessionId)
                    if !member && file === family.targetFile && cliIds.has(record.cliSessionId) { throw EngineError("target scheduled task session id collision") }
                    if !member && (ids.has(record.scheduledTaskId) || recordIds.has(record.notifySessionId) || recordIds.has(record.forkedFromSessionId)) {
                        throw EngineError("new scheduled task family dependency")
                    }
                    if try member && (!validDesktopRecord(["file": recordFile, "record": record]).truthy || links.get(record.sessionId) !== Value(stable(taskLinks(record)))) {
                        throw EngineError("scheduled task family identity or route changed")
                    }
                    if try member && ownsWorker(liveWorkers, record.cliSessionId, record.sessionId).truthy { throw EngineError("running worker owns scheduled task family") }
                }
                if kind === "twin" {
                    for replaced in family.replaced.elements {
                        let task = replaced.task
                        let first = selected[0]
                        let problem = try staleTaskProblem(
                            family.tasks.elements.first { $0.id === task.id } ?? .undefined, task,
                            ["source": family.state, "target": registry],
                            Value(records.filter { first || !recordIds.has($0.sessionId) }), false)
                        if problem.truthy { throw EngineError(problem.description) }
                    }
                }
            }
            if family.tasks.length != 0 && (selected.allSatisfy { $0 } || !partial.truthy && (selected[0] || !selected[1])) {
                throw EngineError("scheduled task ownership changed")
            }
        } catch {
            let e = errorObject(error)
            if e.code === "MOVE_STALLED" || e.code === "RESTART_REOPENED" { throw error }
            problems.append(e["message"])
        }
    }
    return Value(unique(problems))
}

@discardableResult
func writeTaskRegistrations(_ transfers: Value = .undefined, _ side: Value = .undefined, _ present: Value = .undefined, _ paths: Value = .undefined, _ inspect: Value = .undefined, _ check: Value = .undefined, _ snapshots: Value = .undefined) throws -> Value {
    let check = fnOr(check)
    let snapshots = snapshots.isUndefined ? Value.null : snapshots
    let families = side === "target" && !present.truthy ? Array(transfers.elements.reversed()) : transfers.elements
    for family in families {
        try check.call(true)
        let problems = try taskTransferProblems([family], paths, inspect, true, check, snapshots)
        if problems.length != 0 { throw EngineError(problems.join(", ")) }
        let file = side === "source" ? family.sourceFile : family.targetFile
        let registry = try taskSessions(file).registry
        let tasks = registry.scheduledTasks ?? Value.newArray()
        let source = try taskSessions(family.sourceFile).registry
        let kind = try taskRegistrationKind(family, registry, Value(side === "target"),
                                            Value((source.scheduledTasks ?? Value.newArray()).elements.contains { family.ids.includes($0.id) }))
        if Value(kind === "published") === present || family.tasks.length == 0 { continue }
        var next = tasks.elements.filter { !family.ids.includes($0.id) }
        if present.truthy {
            for task in family.tasks.elements {
                let order = family.sourceOrder
                let following = side === "source" ? (next.firstIndex { indexOf(order, $0.id) > indexOf(order, task.id) } ?? -1) : -1
                next.insert(task, at: following < 0 ? next.count : following)
            }
        } else if side === "target" {
            for replaced in (family.replaced ?? Value.newArray()).elements {
                next.insert(replaced.task, at: spliceStart(min(toNumber(replaced.index), Double(next.count)), next.count))
            }
        }
        if try stable(taskSessions(file).registry) != stable(registry) { throw EngineError("scheduled task registry changed before write") }
        try check.call(true)
        if try schedulerBusy(paths, [family.from, family.to], optCall(inspect)).truthy { throw EngineError(SCHEDULER_OWNS) }
        let after = Value.spread(registry, ["scheduledTasks": Value(next)])
        if family.state.truthy {
            for key in TASK_STATE_KEYS {
                let chosen: Value = present.truthy ? family.state[key] : side === "target" ? family.targetState[key] : Value.newObject()
                let kept = Value.fromEntries((registry[key] ?? Value.newObject()).ownEntries.filter { !family.ids.includes(Value($0.0)) })
                let entries = Value.spread(kept, chosen)
                if (registry ?? Value.newObject()).hasOwn(key) || !entries.ownKeys.isEmpty { after[key] = entries }
                if !present.truthy && side === "target" && !family.targetStateFields.includes(Value(key)) && entries.ownKeys.isEmpty { after.removeKey(key) }
            }
        }
        if !present.truthy && side === "target" && !family.targetHadTasks.truthy && next.isEmpty { after.removeKey("scheduledTasks") }
        let remove = !present.truthy && side === "target" && !family.targetExisted.truthy && after.ownKeys.isEmpty
        if remove {
            do { try fs.unlink(file.description) } catch { if errorObject(error).code !== "ENOENT" { throw error } }
        } else {
            try saveText(file, Value(jsonText(after)), Value { _ in
                let problems = try taskTransferProblems([family], paths, inspect, true, check, snapshots)
                if problems.length != 0 { throw EngineError(problems.join(", ")) }
                try check.call(true)
                if try stable(taskSessions(file).registry) != stable(registry) { throw EngineError("scheduled task registry changed before publication") }
                if try schedulerBusy(paths, [family.from, family.to], optCall(inspect)).truthy { throw EngineError(SCHEDULER_OWNS) }
                return .undefined
            })
        }
        if try stable(taskSessions(file).registry) != stable(remove ? .null : after) { throw EngineError("scheduled task registry changed during write") }
    }
    return .undefined
}

func finishUndo(_ receipt: Value = .undefined, _ file: Value = .undefined, _ paths: Value = .undefined, _ options: Value = .undefined) throws -> Value {
    let options = options.isUndefined ? Value.newObject() : options
    let root = Value(path.join(paths.state.description, "quarantine"))
    let dest = Value(path.join(root.description, receipt.at.description))
    let superseded = receipt.superseded ?? Value.newArray(), undoing = receipt.undoing ?? Value.newArray()
    var problems: [Value] = []
    problems += try restoreProblems(superseded, root).elements
    problems += try restoreProblems(undoing, root).elements
    problems += try bridgeProblems(receipt.sessions, true).elements
    problems += try activationProblems(receipt).elements
    problems += try taskTransferProblems(receipt.taskTransfers, paths, inspector(paths, options), true, options.check).elements
    if exists(Value(path.join(dest.description, "receipt.json"))) { problems.append("undo receipt path occupied") }
    let liveWorkers = try workers(inspector(paths, options).call())
    for row in receipt.sessions.elements {
        if try ownsWorker(liveWorkers, row.targetId, row.targetRecordId).truthy { problems.append(Value("\(row.title) | running worker kept in destination")) }
        if try !row.taskFamily.truthy && row.taskFile.truthy
            && Value(taskSessions(row.taskFile).has(row.targetRecordId ?? Value("local_\(row.targetId)"))) !== row.taskOwned {
            problems.append(Value("\(row.title) | scheduled tasks changed"))
        }
    }
    problems += try undoParentProblems(receipt).elements
    if !problems.isEmpty { return ["receipt": receipt, "restoreProblems": Value(problems)] }
    var failure: Error? = nil
    let inspect = try inspector(paths, options)
    do {
        try writeTaskRegistrations(receipt.taskTransfers, "target", false, paths, inspect, options.check)
        try restore(superseded, root, options.check)
        try park(undoing, Value { _ in try optCall(options.check) })
        _ = try restoreActivations(receipt)
        for row in receipt.sessions.elements {
            _ = try restoreBridge(row, Value { _ in try saveJson(file, receipt, 2, true) }, inspect, true)
        }
        try writeTaskRegistrations(receipt.taskTransfers, "source", true, paths, inspect, options.check)
        try fs.mkdirp(dest.description)
    } catch { failure = error }
    problems += try undoParentProblems(receipt).elements
    problems += try taskTransferProblems(receipt.taskTransfers, paths, inspect, true, options.check).elements
    if problems.isEmpty, let failure { throw failure }
    if !problems.isEmpty {
        if let failure { problems.append(errorMessage(failure)) }
        var blocked: [Value] = []
        for item in undoing.elements {
            let unsafe = try restoreProblems([item], root).elements
            blocked += unsafe
            if unsafe.isEmpty {
                do { try restore([item], root) } catch { blocked.append(Value("Undo rollback blocked: \(errorMessage(error))")) }
            }
        }
        blocked += try restoreProblems(undoing, root).elements
        blocked += try restoreProblems(superseded, root).elements
        return ["receipt": receipt, "restoreProblems": Value(unique(problems + blocked))]
    }
    try fs.rename(file.description, path.join(dest.description, "receipt.json"))
    return ["receipt": receipt, "dest": dest]
}

func rollbackTarget(_ row: Value = .undefined, _ dest: Value = .undefined, _ liveWorkers: Value = .undefined, _ before: Value = .undefined) throws -> Value {
    let liveWorkers = liveWorkers.isUndefined ? try workers() : liveWorkers
    let before = fnOr(before)
    func locateArtifact(_ original: Value) -> Value {
        let parked = Value(path.join(dest.description, path.basename(original.description)))
        let hasOriginal = exists(original), hasParked = exists(parked)
        if hasOriginal == hasParked {
            return ["error": Value("\(path.basename(original.description)) \(hasOriginal ? "exists in both locations" : "is missing")")]
        }
        return ["original": original, "parked": parked, "file": hasOriginal ? original : parked, "move": Value(hasOriginal)]
    }
    func sameRecordAs(_ file: Value) -> Bool {
        let raw = catchNull { try readFile(file) }
        var sameRecord = raw.truthy
        do {
            if raw.truthy { sameRecord = try row.recordSemantic.truthy && recordSemantic(JSON.parse(raw.asData ?? Data())) === row.recordSemantic }
        } catch { sameRecord = false }
        return sameRecord
    }
    let transcript = locateArtifact(row.targetTranscript)
    let record = locateArtifact(row.record)
    let sidecarArtifact: Value = row.targetDir.truthy ? locateArtifact(row.targetDir) : .null
    if row.strategy === "rehome" {
        let candidates: [Value] = [
            transcript.error,
            !transcript.error.truthy && !transcript.move.truthy ? "transcript missing" : .null,
            sidecarArtifact.error,
            sidecarArtifact.truthy && !sidecarArtifact.error.truthy && !sidecarArtifact.move.truthy ? "sidecars missing" : .null,
            record.error,
        ]
        var changes = candidates.filter { $0.truthy }
        if !record.error.truthy {
            if !sameRecordAs(record.file) { changes.append("desktop record changed") }
        }
        if try row.taskFile.truthy && Value(taskSessions(row.taskFile).has(row.targetRecordId ?? Value("local_\(row.targetId)"))) !== row.taskOwned {
            changes.append("scheduled tasks changed")
        }
        if try ownsWorker(liveWorkers, row.targetId, row.targetRecordId).truthy { changes.append("running worker") }
        if changes.isEmpty {
            try before.call()
            if record.move.truthy {
                try fs.mkdirp(dest.description)
                try fs.rename(record.original.description, record.parked.description)
            }
        }
        return Value(changes)
    }
    var changes = [transcript.error, record.error, sidecarArtifact.error].filter { $0.truthy }
    if !sidecarArtifact.error.truthy {
        let root = sidecarArtifact.file ?? Value(path.join(path.dirname(row.targetTranscript.description), row.targetId.description))
        if try manifest(root).sha !== row.sidecars.sha { changes.append("sidecars changed") }
    }
    if !record.error.truthy {
        if !sameRecordAs(record.file) { changes.append("desktop record changed") }
    }
    if try row.taskFile.truthy && Value(taskSessions(row.taskFile).has(row.targetRecordId ?? Value("local_\(row.targetId)"))) !== row.taskOwned {
        changes.append("scheduled tasks changed")
    }
    if try ownsWorker(liveWorkers, row.targetId, row.targetRecordId).truthy { changes.append("running worker") }
    if try !transcript.error.truthy && changed(transcript.file, row.targetId, knownOf(row)).truthy { changes.append("transcript changed") }
    let present = [transcript, sidecarArtifact, record].filter { $0.truthy }
    if !changes.isEmpty {
        for artifact in present {
            if artifact.error.truthy || artifact.move.truthy || exists(artifact.original) || !exists(artifact.parked) { continue }
            try fs.mkdirp(path.dirname(artifact.original.description))
            try fs.rename(artifact.parked.description, artifact.original.description)
        }
        return Value(changes)
    }
    for artifact in present {
        if !artifact.move.truthy { continue }
        try fs.mkdirp(dest.description)
        try fs.rename(artifact.original.description, artifact.parked.description)
    }
    return Value.newArray()
}

public func reconcile(_ paths: Value = .undefined, _ options: Value = .undefined) throws -> Value {
    var paths = paths
    let options = options.isUndefined ? Value.newObject() : options
    let file = Value(path.join(paths.state.description, "restart.json"))
    let restart = catchNull { try readJson(file) }
    let interrupted = restart.truthy && (["closing", "moving", "reopening"] as Value).includes(restart.outcome)
    var result: Value = .undefined
    var thrown: Error? = nil
    do {
        if options.background.truthy || options.automatic.truthy {
            let pending = try recoveryPending(paths)
            if (!options.receiptFile.truthy || pending.file === options.receiptFile) && (pending.receipt.undoing.truthy || pending.receipt.remoteUndoing["length"].truthy) {
                let labels = try (pending.receipt.remoteUndoing ?? Value.newArray()).elements.map { try loginLabel($0) }
                result = ["title": "Undo pending", "error": "Finish undo to continue", "pendingUndo": Value(unique(labels))]
            }
        }
        let pending = try recoveryPending(paths)
        if result.nullish {
            result = try (options.background.truthy || options.automatic.truthy) && pending.receipt.localRecovery.blocked.truthy
                ? ["title": "Move recovery blocked", "error": pending.receipt.localRecovery.blocked]
                : reconcileFiles(paths, options)
        }
    } catch { thrown = error }
    if interrupted {
        paths = .spread(paths, ["claudeApp": restart.app ?? paths.claudeApp])
        let current = paths
        let io = options.io ?? Value.newObject()
        let now = io.now ?? Value { _ in Value(process.monotonic()) }
        let inspect = io.inspect ?? Value { _ in try processTable(current.claudeApp) }
        let running = Value { _ in
            do { return Value(try appProcess(current, try inspect.call()).truthy) } catch { return false }
        }
        if try !running.call().truthy {
            let deadline = toNumber(try now.call()) + REOPEN_RESERVE
            let run = io.command ?? Value { a in try command(arg(a, 0), arg(a, 1), arg(a, 2)) }
            let opened = try run.call("/usr/bin/open", ["-g", "-a", paths.claudeApp], Value(REOPEN_RESERVE))
            restart.outcome = try opened.status === 0 && waitFor(running, Value(deadline), now, io.wait).truthy ? "interrupted-reopened" : "reopen-failed"
        } else { restart.outcome = "interrupted-app-running" }
        restart.recoveredAt = Value(isoNow())
        try saveJson(file, restart)
    }
    if let thrown { throw thrown }
    if interrupted && restart.outcome === "reopen-failed" {
        let message = [result.error, "Reopen Claude Desktop manually, then retry"].filter { $0.truthy }.map { $0.description }.joined(separator: ". ")
        throw makeError(message, code: "REOPEN_FAILED")
    }
    return result ?? (interrupted ? ["title": "Interrupted restart", "error": "Desktop is running. Retry the requested operation."] : .null)
}

func reconcileFiles(_ paths: Value = .undefined, _ options: Value = .undefined) throws -> Value {
    let options = options.isUndefined ? Value.newObject() : options
    let p = try recoveryPending(paths)
    if !p.truthy { return .null }
    if options.receiptFile.truthy && p.file !== options.receiptFile { return ["title": "recovery blocked", "error": "The operation receipt changed"] }
    if p.corrupt.truthy {
        try fs.rename(p.file.description, "\(p.file).corrupt")
        return ["title": p.name, "error": "corrupt receipt set aside"]
    }
    let receipt = p.receipt
    let rollback = receipt.localRecovery.rollback ?? ""
    let failedDirectory = Value(path.join(paths.state.description, "quarantine", receipt.at.description, "failed",
                                          UUID.test(rollback.description) ? receipt.localRecovery.rollback.description : ""))
    let bridgeRows: Value
    if receipt.undoing.truthy { bridgeRows = receipt.sessions ?? Value.newArray() }
    else if receipt.remotePending.truthy { bridgeRows = Value.newArray() }
    else {
        var rows: [Value] = []
        if receipt.pending.truthy { rows.append(receipt.pending) }
        if receipt.finalizing.truthy { rows += sliceArray((receipt.sessions ?? Value.newArray()).elements, toInteger(receipt.appendCheckpoint.sessions ?? 0)) }
        bridgeRows = Value(rows)
    }
    let bridgeIssues = try bridgeProblems(bridgeRows, Value(receipt.undoing.truthy))
    if bridgeIssues.length != 0 { return ["title": "bridge recovery blocked", "error": Value(bridgeIssues.join(", ")), "problems": bridgeIssues] }
    let inspect = try inspector(paths, options)
    let taskTransfers = try recoveryFamilies(receipt)
    let taskProblems = try taskTransferProblems(taskTransfers, paths, inspect, true, options.check)
    if taskProblems.length != 0 && !(receipt.undoing.truthy && receipt.remoteUndoing["length"].truthy
        && taskProblems.elements.allSatisfy { $0 === Value(SCHEDULER_OWNS) } && !options.check.truthy) {
        return ["title": "scheduled task recovery blocked", "error": Value(taskProblems.join(", ")), "problems": taskProblems]
    }
    if receipt.failed.nullish { receipt.failed = Value.newArray() }
    if receipt.superseded.nullish { receipt.superseded = Value.newArray() }
    if receipt.undoing.truthy {
        let blocked = try undoParentProblems(receipt)
        if blocked.length != 0 { return ["title": "undo recovery blocked", "error": Value(blocked.join(", ")), "problems": blocked] }
        let remote = try restoreRemote(receipt, p.file, paths, options)
        if remote.problems.length != 0 { return ["title": "Remote Control undo recovery blocked", "error": Value(remote.problems.join(", ")), "problems": remote.problems] }
        if remote.pending.length != 0 {
            return ["title": "Undo pending", "error": Value("sign Claude Desktop into \(remote.pending.join(" or "))"), "pendingUndo": remote.pending, "remoteRestored": remote.restored, "receipt": receipt]
        }
        let result = try finishUndo(receipt, p.file, paths, options)
        if result.restoreProblems.truthy { return ["title": "undo recovery blocked", "error": Value(result.restoreProblems.join(", ")), "problems": result.restoreProblems] }
        return ["title": Value("\(receipt.sessions["length"]) sessions"), "error": "interrupted undo completed", "undo": result]
    }
    if receipt.remotePending.truthy {
        let row = receipt.remotePending
        do {
            let cloud = try receiptCloud(receipt, paths, options.cloud)
            let current = try cloud["session"].call(row.id)
            if current.status === "archived" {
                if receipt.remote.nullish { receipt.remote = Value.newArray() }
                if !receipt.remote.elements.contains(where: { $0.id === row.id }) { receipt.remote.push(row) }
                receipt.failed = Value(receipt.failed.elements.filter { $0.id !== row.id })
                receipt.removeKey("remotePending")
                try saveJson(p.file, receipt)
                return ["title": row.title, "error": "interrupted Remote Control archive completed"]
            }
            if current.status === "active" || current.status === "paused" {
                let target = receipt.sessions.elements.first { $0.record === row.activation.record } ?? .undefined
                _ = try rollbackActivation(row.activation, target)
                _ = try addCloudFailure(receipt, row, ["id": row.id, "title": row.title, "error": "interrupted Remote Control archive not applied"])
                receipt.removeKey("remotePending")
                try saveJson(p.file, receipt)
                return ["title": row.title, "error": "interrupted Remote Control archive not applied"]
            }
            return ["title": row.title, "error": Value("Remote Control recovery blocked at \(current.status ?? "unknown")")]
        } catch {
            return ["title": row.title, "error": Value("Remote Control recovery blocked: \(errorMessage(error))")]
        }
    }
    var recovered: [Value] = []
    if receipt.retiring.truthy {
        let plan = receipt.retiring
        let root = Value(path.join(paths.state.description, "quarantine"))
        let blocked = try restoreProblems(plan, root, true)
        if blocked.length != 0 { return ["title": "retirement recovery blocked", "error": Value(blocked.join(", ")), "problems": blocked] }
        try restore(plan, root, options.check)
        receipt.retiring = .null
        recovered.append(["title": Value("\(plan["length"]) retirement entries"), "error": "interrupted retirement rolled back"])
    }
    if receipt.pending.truthy {
        let pendingRow = receipt.pending
        let id = pendingRow.id, title = pendingRow.title, targetId = pendingRow.targetId, made = pendingRow.made
        let strategy = pendingRow.strategy, creationRequired = pendingRow.creationRequired, created = pendingRow.created
        let found: Value = creationRequired.truthy ? catchNull { try fs.stat(made[0].description, bigint: false) } : .null
        let foreign = and(and(creationRequired, found), Value(!created.truthy || found.dev !== created.dev || found.ino !== created.ino))
        do { _ = try restoreBridge(receipt.pending, Value { _ in try saveJson(p.file, receipt, 2, true) }, inspect) }
        catch { return ["title": "bridge recovery blocked", "error": errorMessage(error)] }
        let used: Value
        if strategy === "rehome" {
            let raw: Value? = try? readFile(made[0])
            if let raw { used = Value(receipt.pending.recordSha.truthy && Value(sha(raw)) !== receipt.pending.recordSha) } else { used = false }
        } else {
            used = try changed(made[0], targetId, knownOf(receipt.pending))
        }
        if (used.truthy || foreign.truthy) && taskTransfers.elements.contains(where: { $0.recordIds.includes(Value(path.basename(made[0].description, ".json"))) }) {
            return ["title": "scheduled task recovery blocked", "error": "scheduled task target record changed, recovery remains pending"]
        }
        if !used.truthy && !foreign.truthy {
            _ = try quarantine(made, failedDirectory, Value { _ in
                try optCall(options.check, true)
                if try ownsWorker(workers(inspect.call()), targetId, Value(path.basename(made[0].description, ".json"))).truthy {
                    throw EngineError("A running worker owns the unfinished record. Recovery remains pending.")
                }
                return .undefined
            })
        }
        let error: Value = foreign.truthy ? "interrupted, independently created target left in place" : used.truthy ? "interrupted, target record changed since, left in place" : "interrupted"
        receipt.failed.push(["id": id, "title": title, "targetId": targetId, "artifacts": made, "retained": and(used, Value(!foreign.truthy)), "error": error])
        if used.truthy && !foreign.truthy {
            receipt.retained = Value((receipt.retained ?? Value.newArray()).elements + [["id": id, "title": title, "targetId": targetId, "artifacts": made] as Value])
        }
        receipt.pending = .null
        recovered.append(["title": title, "error": error])
    }
    if receipt.finalizing.truthy {
        let checkpoint = receipt.appendCheckpoint
        let root = Value(path.join(paths.state.description, "quarantine"))
        let superseded = Value(sliceArray(receipt.superseded.elements, toInteger(checkpoint.superseded ?? 0)))
        let rollingBack = Value(sliceArray((receipt.sessions ?? Value.newArray()).elements, toInteger(checkpoint.sessions ?? 0)))
        let blocked = try restoreProblems(superseded, root).elements + bridgeProblems(rollingBack).elements
        if !blocked.isEmpty { return ["title": "recovery blocked", "error": Value(Value(blocked).join(", ")), "problems": Value(blocked)] }
        try writeTaskRegistrations(taskTransfers, "target", false, paths, inspect, options.check)
        try restore(superseded, root, options.check)
        var kept: [Value] = []
        var rolledBack = 0
        let dest = failedDirectory
        let liveWorkers = try workers(inspect.call())
        for row in rollingBack.elements {
            try optCall(options.check)
            let changes: Value
            do {
                changes = try rollbackTarget(row.taskFamily.truthy ? .spread(row, ["taskOwned": false]) : row, dest, liveWorkers,
                                             Value { _ in try restoreBridge(row, Value { _ in try saveJson(p.file, receipt, 2, true) }, inspect) })
            } catch { return ["title": "bridge recovery blocked", "error": errorMessage(error)] }
            if changes.length != 0 {
                kept.append(row)
                receipt.failed.push(["id": row.id, "title": row.title, "error": Value("interrupted finalization, \(changes.join(", ")) changed since, left in place")])
            } else {
                receipt.failed.push(["id": row.id, "title": row.title, "error": "interrupted finalization"])
                rolledBack += 1
            }
        }
        if kept.contains(where: { $0.taskFamily.truthy }) {
            return ["title": "scheduled task recovery blocked", "error": "scheduled task family records changed, recovery remains pending"]
        }
        try writeTaskRegistrations(taskTransfers, "source", true, paths, inspect, options.check)
        receipt.taskTransfers = Value(sliceArray((receipt.taskTransfers ?? Value.newArray()).elements, 0, toInteger(checkpoint.taskTransfers ?? 0)))
        receipt.sessions = Value(sliceArray((receipt.sessions ?? Value.newArray()).elements, 0, toInteger(checkpoint.sessions ?? 0)) + kept)
        receipt.superseded = Value(sliceArray(receipt.superseded.elements, 0, toInteger(checkpoint.superseded ?? 0)))
        receipt.finalizing = false
        receipt.verification = checkpoint.verification ?? [
            "ok": Value(kept.isEmpty),
            "problems": Value(kept.map { ["id": $0.targetId, "title": $0.title, "check": "interrupted finalization"] as Value }),
        ]
        if checkpoint.truthy { receipt.held = checkpoint.held } else { _ = try cancelCloudChecks(receipt) }
        receipt.removeKey("appendCheckpoint")
        recovered.append([
            "title": Value("\(rolledBack) unfinished copies"),
            "error": kept.isEmpty ? "interrupted finalization rolled back" : Value("\(kept.count) changed copies left in place"),
        ])
    }
    if receipt.localRecovery.truthy { receipt.localRecovery.removeKey("blocked") }
    _ = try foldRestartHistory(paths, p.file, receipt)
    try saveJson(p.file, receipt)
    try fs.rm("\(p.file).journal", recursive: false, force: true)
    if recovered.count == 1 { return recovered[0] }
    return [
        "title": Value(recovered.map { $0.title.description }.joined(separator: " + ")),
        "error": Value(recovered.map { $0.error.description }.joined(separator: ", ")),
    ]
}

func witnessed(_ row: Value = .undefined, _ liveWorkers: Value = .undefined, _ checkShared: Value = .undefined) throws -> Value {
    let checkShared = checkShared.isUndefined ? Value(true) : checkShared
    let expectedSidecars = row.sidecar ?? row.sidecars
    if row.strategy === "rehome" && row.transcriptFingerprint.truthy && expectedSidecars.fingerprint.truthy {
        let sidecarRoot = Value(path.join(path.dirname(row.transcript.description), row.id.description))
        let currentTranscript = catchNull { try fingerprint(row.transcript) }
        let currentSidecars = catchNull { try treeFingerprint(sidecarRoot) }
        let sameTask = try !row.account.taskFile.truthy
            || Value(taskSessions(row.account.taskFile).has(desktopRecordOf(row).sessionId)) === row.taskOwned
        let shared = try and(and(and(Value(currentTranscript.truthy),
                                     Value(!expectedSidecars.count.truthy || exists(sidecarRoot))),
                                 Value(!expectedSidecars.canonicalRoot.truthy || currentSidecars.canonicalRoot === expectedSidecars.canonicalRoot)),
                             !checkShared.truthy ? Value(true) : and(Value(currentTranscript === row.transcriptFingerprint), try sameTree(expectedSidecars, currentSidecars)))
        return try and(and(and(shared, Value(sameTask)), Value(!ownsWorker(liveWorkers, row.id, desktopRecordOf(row).sessionId).truthy)), try bridgeIntact(row))
    }
    let now = catchNull { try sidecars(row.transcript, row.id) }
    let sameTask = try !row.account.taskFile.truthy
        || Value(taskSessions(row.account.taskFile).has(desktopRecordOf(row).sessionId)) === row.taskOwned
    if try !now.truthy || now.sha !== row.sidecar.sha || row.sidecar.canonicalRoot.truthy && now.canonicalRoot !== row.sidecar.canonicalRoot
        || !sameTask || ownsWorker(liveWorkers, row.id, desktopRecordOf(row).sessionId).truthy {
        return false
    }
    return try Value(exists(row.transcript) && !changed(row.transcript, row.id, ["semantic": row.snapshot, "semanticVersion": Value(SEMANTIC_VERSION), "bridge": row.bridge]).truthy)
}

func untouched(_ row: Value = .undefined, _ liveWorkers: Value = .undefined, _ checkShared: Value = .undefined) throws -> Value {
    let record = row.session.file ?? row.file
    let raw: Value = record.truthy ? catchNull { try readFile(record) } : .null
    var sameRecord = raw.truthy
    if raw.truthy {
        do { sameRecord = try row.recordSemantic.truthy && recordSemantic(JSON.parse(raw.asData ?? Data())) === row.recordSemantic } catch { sameRecord = false }
    }
    return try and(Value(sameRecord), try witnessed(row, liveWorkers, checkShared))
}

public func carrying(_ inv: Value = .undefined, _ landed: Value = .undefined, _ gone: Value = .undefined) throws -> Value {
    let gone = gone.isUndefined ? Value.newSet() : gone
    let carried = inv.targets.elements.filter { $0.transcript.truthy && !gone.has($0) }.map { ["by": $0.id, "history": $0] as Value }
    return Value(landed.elements + carried)
}

public func owners(_ sources: Value = .undefined, _ carried: Value = .undefined) throws -> Value {
    let candidates = ValueMap(sources.elements.filter { $0.roots["size"].truthy }.map { (firstValue($0.roots), Value.newArray()) })
    for carrier in carried.elements { for root in carrier.history.roots.elements { candidates.get(root).push(carrier) } }
    var out: [Value] = []
    for s in sources.elements {
        let owner: Value
        if s.sole.truthy {
            owner = carried.elements.first { $0.history.members.includes(s) } ?? .undefined
        } else {
            owner = try candidates.get(firstValue(s.roots)).elements.first { try included(s, $0.history).truthy } ?? .undefined
        }
        let row: Value = ["s": s, "owner": owner]
        if row.owner.truthy { out.append(row) }
    }
    return Value(out)
}

func parentReferences(_ directories: Value = .undefined, _ snapshots: Value = .undefined, _ check: Value = .undefined) throws -> Value {
    let snapshots = snapshots.isUndefined ? Value.null : snapshots
    let check = fnOr(check)
    let parents = ValueMap()
    for dir in directories.elements {
        for row in try folderRecords(dir, snapshots, check).elements {
            let parent = row.record.forkedFromSessionId
            parents.set(row.file, LOCAL_RECORD.test((parent ?? "").description) ? Value(path.join(dir.description, "\(parent).json")) : .null)
        }
    }
    return .map(parents)
}

func undoParentProblems(_ receipt: Value = .undefined) throws -> Value {
    let removing = Value.newSet(receipt.sessions.elements.map { $0.record })
    do {
        let parents = try parentReferences(Value.newSet(removing.elements.map { Value(path.dirname($0.description)) }))
        return Value(parents.asMap!.entries.filter { file, parent in !removing.has(file) && removing.has(parent) }
            .map { file, _ in Value("\(path.basename(file.description)) | parent Desktop record would be removed by Undo") })
    } catch { return [errorMessage(error)] }
}
