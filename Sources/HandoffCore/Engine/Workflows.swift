import Darwin
import Foundation

// The move, finish, sweep and Undo workflows, account selection, the interactive picker and the progress reporter.

fileprivate func optCall(_ f: Value, _ args: Value...) throws -> Value {
    f.isFunction ? try f.callArgs(args) : .undefined
}

fileprivate func orNull(_ body: () throws -> Value) -> Value {
    do { return try body() } catch { return .null }
}

fileprivate func isInteger(_ v: Value) -> Bool {
    guard case .number(let d) = v else { return false }
    return d.isFinite && d == d.rounded(.towardZero)
}

// The Host table has no stdout TTY probe, so this asks the terminal directly.
fileprivate func stdoutIsTTY() -> Bool { isatty(1) != 0 }

// The files of a row's members, or the row's own file when it has none.
fileprivate func memberFiles(_ row: Value) -> [Value] {
    let members = row["members"]
    return (members.nullish ? [row] : members.elements).map { $0["file"] }
}

@discardableResult
public func executeMove(_ from: Value = .undefined, _ to: Value = .undefined, _ paths: Value = .undefined, _ options: Value = .undefined) throws -> Value { try executeMove(from, to, DataLayout(paths), options) }
@discardableResult
func executeMove(_ from: Value = .undefined, _ to: Value = .undefined, _ paths: DataLayout, _ options: Value = .undefined) throws -> Value {
    let options: Value = Value.spread(options, ["cloudRequested": Value(options["cloudRequested"] === true || options["cloud"].truthy)])
    let report: Value = options["report"] ?? Value { _ in .undefined }
    let approving = !options["approve"].nullish
    return try locked(paths, Value { _ in
        let inspect: Value = Value { _ in
            try optCall(options["io"]["inspect"]) ?? options["processes"] ?? (try processTable(Value(paths.claudeApp)))
        }
        let kind: Value = options["recover"].truthy ? "recover" : options["undo"].truthy ? "undo" : from.truthy ? "move" : options["finish"].truthy ? "finish" : "refresh"
        let receiptFile: Value = (options["resume"].truthy ? options["resumeFile"] : options["receiptFile"]) ?? .null
        let planFile = path.join(paths.state, "restart-plan.json")
        let saved: Value = approving ? orNull { try readJson(Value(planFile)) } : .null
        if approving {
            var bad = !saved.truthy || saved["token"] !== options["approve"]
            if !bad { bad = Value(sha(stable(try without(saved, .strings(["token"]))))) !== saved["token"] }
            if !bad { bad = saved["kind"] !== kind }
            if bad {
                return ["ok": false, "code": "RESTART_APPROVAL_CHANGED", "reason": "Restart approval is missing or does not match the saved plan"]
            }
        }
        if saved.truthy && (saved["receiptFile"] ?? .null) !== receiptFile { return ["ok": false, "reason": "The approved pending receipt changed"] }
        if options["undo"].truthy || options["recover"].truthy || saved["receiptFile"].truthy {
            if try latestReceipt(paths)["file"] !== receiptFile { return ["ok": false, "reason": "The operation receipt changed"] }
        }
        var selection: Value = .null
        if from.truthy {
            var fromRows: [Value] = []
            for account in from.elements {
                let files: [Value] = try (account["sessions"].elements + account["unreadable"].elements).map { try desktopFileOf($0) }
                fromRows.append(Value.spread(try accountRef(account), ["files": Value(files)]))
            }
            selection = ["from": Value(fromRows), "to": try accountRef(to)]
        }
        if saved.truthy {
            var changed = saved["selection"].truthy != selection.truthy
            if !changed && selection.truthy {
                changed = try !sameAccount(saved["selection"]["to"], selection["to"]).truthy
                if !changed { changed = saved["selection"]["from"]["length"] !== selection["from"]["length"] }
                if !changed {
                    var every = true
                    for source in saved["selection"]["from"].elements {
                        var some = false
                        for row in selection["from"].elements where try sameAccount(row, source).truthy { some = true; break }
                        if !some { every = false; break }
                    }
                    changed = !every
                }
            }
            if changed { return ["ok": false, "code": "RESTART_APPROVAL_CHANGED", "reason": "The selected accounts changed after the restart plan"] }
        }
        let recovery: Value = options["recover"].truthy ? try recoveryPending(paths) : .null
        let taskTransfers: Value = recovery["receipt"].truthy ? try recoveryFamilies(Receipt(recovery["receipt"])) : []
        if options["recover"].truthy && (taskTransfers.length == 0 || recovery["file"] !== options["receiptFile"] || recovery["receipt"]["remotePending"].truthy || recovery["receipt"]["remoteUndoing"]["length"].truthy) {
            return ["ok": false, "reason": "Task recovery changed or still needs cloud restoration"]
        }
        if recovery.truthy {
            let problems = try taskTransferProblems(taskTransfers, paths, inspect, true).elements.filter { $0 !== Value(SCHEDULER_OWNS) }
            if !problems.isEmpty { return ["ok": false, "reason": Value(Value(problems).join(", "))] }
        }
        let reconciled: Value = options["recover"].truthy ? .null : try reconcile(paths, options)
        if reconciled.truthy { return ["reconciled": reconciled, "recoveryRequired": true, "ok": false] }
        let deferred = try deferredWorkflow(paths)
        if options["resume"].truthy && (deferred["mode"] !== "local" || deferred["file"] !== options["resumeFile"]) {
            return ["ok": false, "reason": "The pending move changed. No stale continuation was run."]
        }
        var existing: Value = options["resume"].truthy ? deferred : .null
        if from.truthy && deferred.truthy && !existing.truthy {
            return ["deferred": deferred, "ok": false, "complete": false, "pendingCloud": deferred["mode"] === "cloud" ? Value(deferred["sources"].length) : 0]
        }
        let drift = try inspectPlaced(paths)
        if drift["changed"].length > 0 {
            _ = try report.call("changed", Value("\(quantity(drift["changed"].length, "moved session")) now has different metadata. Evidence saved with the receipt."))
        }
        if options["finish"].truthy && deferred["file"] !== options["receiptFile"] { return ["ok": false, "reason": "The pending move changed before its restart"] }
        var chosen: Value = saved["selection"] ?? selection
        let sessionFiles: Value = .newSet(try receiptSummary(existing["receipt"] ?? .newObject())["notMoved"].elements.map { $0["file"] }.filter { $0.truthy })
        let sessionProgress: Value = Value { args in
            let receipt = Receipt(args.first ?? .undefined)
            let retired = try retiredFiles(Receipt(receipt.raw ?? .newObject()))
            let remaining = sessionFiles.elements.filter { !retired.has($0) }.count
            _ = try report.call("sessions", "Remaining sessions", ["live": true, "sessionTotal": Value(sessionFiles.length), "remainingCount": Value(remaining)])
            return .undefined
        }
        let requestedAt: Value = saved["requestedAt"] ?? existing["receipt"]["startedAt"] ?? options["requestedAt"] ?? Value(isoNow())
        let prepareReport: Value = Value { args in
            let stage = args.count > 0 ? args[0] : .undefined
            let text = args.count > 1 ? args[1] : .undefined
            let extra: Value = args.count > 2 && !args[2].isUndefined ? args[2] : .newObject()
            return try report.call(stage, text, extra["live"].truthy ? Value.spread(extra, ["preparatory": true]) : extra)
        }
        let replan = { (cloudArg: Value, checkArg: Value, preparatoryArg: Value) throws -> Value in
            let cloud: Value = cloudArg.isUndefined ? .null : cloudArg
            let check: Value = fnOr(checkArg)
            let preparatory: Value = preparatoryArg.isUndefined ? false : preparatoryArg
            _ = try check.call()
            let latest = try accounts(paths)
            var sources: [Value] = []
            for selected in chosen["from"].elements {
                var current: Value = .undefined
                for account in latest.elements where try sameAccount(account, selected).truthy { current = account; break }
                if !current.truthy { throw EngineError("\(selected["label"]) is no longer available") }
                let known: Value = .newSet(try (current["sessions"].elements + current["unreadable"].elements).map { try desktopFileOf($0) })
                let files = selected["files"]
                let sessions = current["sessions"].elements.filter { files.includes($0["file"]) }
                var unreadable: [Value] = []
                for row in current["unreadable"].elements where files.includes(try desktopFileOf(row)) { unreadable.append(row) }
                unreadable += files.elements.filter { !known.has($0) }
                sources.append(Value.spread(current, ["sessions": Value(sessions), "unreadable": Value(unreadable)]))
            }
            var target: Value = .undefined
            for account in latest.elements where try sameAccount(account, chosen["to"]).truthy { target = account; break }
            if !target.truthy { throw EngineError("Destination account is no longer available") }
            let inventoryOptions: Value = [
                "cloud": cloud, "cloudRequested": options["cloudRequested"], "cloudError": options["cloudError"], "requestedAt": requestedAt,
                "writeCache": true, "processes": try inspect.call(), "inspect": inspect, "check": check,
            ]
            let inv = try inventory(Value(sources), target, paths, preparatory.truthy ? prepareReport : report, inventoryOptions)
            let failedFiles = try receiptSummary(["failed": try inventoryFailures(inv)])["notMoved"].elements.map { $0["file"] }
            for file in inv.sources.elements.map({ $0["file"] }) + failedFiles { sessionFiles.add(file) }
            _ = try sessionProgress.call(existing["receipt"])
            return ["inv": inv, "target": target]
        }
        let initialCloud: Value = saved.truthy || existing.truthy ? .null : options["cloud"]
        let initial: Value = chosen.truthy ? try replan(initialCloud, .undefined, Value(approving)) : .null
        if options["finish"].truthy {
            let finishAccount = saved["finishAccount"] ?? options["finishAccount"]
            var checks: [Value] = []
            for check in deferred["receipt"]["cloudChecks"].elements where try sameAccount(check, finishAccount).truthy { checks.append(check) }
            if try !canRestartWaiting(Receipt(["cloudChecks": Value(checks)]), try inspect.call()).truthy { return ["nothing": true, "ok": true] }
        }
        let plan: Value = try saved ?? (try restartPlan(MovePlan(initial["inv"] ?? .null), paths, try inspect.call()))
        if plan.truthy && options["background"].truthy { return ["pendingLocal": true, "ok": true] }
        if plan.truthy && !options["moveOnly"].truthy {
            if !saved.truthy || saved["fingerprint"] !== plan["fingerprint"] {
                let active: Value = try options["cloud"] ?? (try signedIn(paths))
                var deferredCloudSources: Value = []
                if options["cloudRequested"].truthy {
                    if chosen.nullish {
                        deferredCloudSources = []
                    } else {
                        let picked = chosen["from"].elements.filter { source in
                            (!active["account"].truthy || source["account"] === active["account"]) && (!active["org"].truthy || source["org"] === active["org"])
                        }
                        deferredCloudSources = Value(try picked.map { try accountRef($0) })
                    }
                }
                let proposal: Value = Value.spread(["version": 1], plan, [
                    "kind": kind, "resume": Value(existing.truthy), "receiptFile": receiptFile, "finishAccount": options["finishAccount"] ?? .null,
                    "selection": chosen, "remainingCount": chosen.truthy ? Value(sessionFiles.length) : .null, "requestedAt": requestedAt,
                    "createdAt": Value(isoNow()), "nonce": Value(randomUUID()), "deferredCloudSources": deferredCloudSources,
                ])
                proposal["token"] = Value(sha(stable(proposal)))
                _ = try saveJson(Value(planFile), proposal)
                return ["plan": proposal, "ok": true]
            }
            var prepared: Value = .null
            var pendingPlan: Value = plan
            if initial.truthy {
                let live = try inspect.call()
                let desktop = try appProcess(paths, live)
                if try !desktop.truthy || restartFingerprint(desktop, live) !== plan["fingerprint"] {
                    return ["ok": false, "code": "RESTART_PLAN_CHANGED", "reason": "Open Claude sessions changed. Review the restart plan again."]
                }
                let current = try restartPlan(MovePlan(initial["inv"]), paths, live)
                var held: [Value] = (current["held"] ?? []).elements
                let ready: Value = .newSet((initial["inv"]["move"].elements + initial["inv"]["there"].elements).flatMap(memberFiles))
                for row in plan["held"].elements {
                    if row["sources"].elements.contains(where: { !ready.has($0["file"]) }) && !held.contains(where: { $0["record"] === row["record"] }) { held.append(row) }
                }
                pendingPlan = Value.spread(plan, ["held": Value(held)])
                let heldFiles: Value = .newSet(held.flatMap { $0["sources"].elements.map { $0["file"] } })
                let regular: Value = Value.spread(initial["inv"], [
                    "held": Value(held),
                    "cloud": ["checked": false, "matches": [], "blocked": [], "waiting": [], "later": []],
                    "move": Value(initial["inv"]["move"].elements.filter { !memberFiles($0).contains(where: { heldFiles.has($0) }) }),
                ])
                if regular["move"].length > 0 || regular["there"].length > 0 {
                    let at: Value = existing["receipt"]["at"] ?? Value(stamp())
                    _ = existing["file"] ?? Value(path.join(paths.state, "\(at).json"))
                    prepared = try transfer(MovePlan(regular), initial["target"], paths, prepareReport, ["existing": existing, "at": at, "sessionProgress": sessionProgress])
                    if prepared["recoveryRequired"].truthy || prepared["deferred"].truthy { return prepared }
                    if prepared["receipt"].truthy, try needsRecovery(prepared["receipt"]).truthy { return prepared }
                    if prepared["file"].truthy {
                        existing = ["file": prepared["file"], "receipt": prepared["receipt"]]
                        let retired = try retiredFiles(Receipt(prepared["receipt"]))
                        let fromRows: [Value] = chosen["from"].elements.map { source in
                            Value.spread(source, ["files": Value(source["files"].elements.filter { !retired.has($0) })])
                        }
                        chosen = Value.spread(chosen, ["from": Value(fromRows)])
                    }
                }
            }
            let work: Value = Value { args in
                let context = args.first ?? .undefined
                try fs.unlink(planFile)
                if options["recover"].truthy {
                    let reconciled = try reconcileFiles(paths, Value.spread(options, ["inspect": inspect, "check": context["check"]]))
                    return reconciled["undo"].truthy
                        ? Value.spread(reconciled["undo"], ["ok": true, "complete": true])
                        : ["reconciled": reconciled, "recoveryRequired": true, "ok": false]
                }
                if options["undo"].truthy {
                    let result = try undoFiles(paths, Value.spread(options, ["inspect": inspect, "check": context["check"]]))
                    return Value.spread(result, ["ok": Value(result["dest"].truthy), "complete": Value(result["dest"].truthy)])
                }
                if !chosen.truthy { return .null }
                let planned = try replan(.null, context["check"], .undefined)
                let inv = MovePlan(planned["inv"]), target = planned["target"]
                _ = try context["check"].call()
                let ready: Value = .newSet((inv.move.elements + inv.there.elements).flatMap(memberFiles))
                inv.held = Value(pendingPlan["held"].elements.filter { $0["sources"].elements.contains(where: { !ready.has($0["file"]) }) })
                inv.deferredCloudSources = saved["deferredCloudSources"]
                _ = try optCall(options["summary"], inv.raw)
                let result = try transfer(inv, target, paths, report, Value.spread(context, [
                    "existing": existing, "sessionProgress": sessionProgress,
                    "refreshCloudChecks": and(prepared, Value(!options["resume"].truthy)),
                ]))
                if prepared.truthy && result.truthy {
                    return Value.spread(result, [
                        "added": Value(toNumber(prepared["added"] ?? 0) + toNumber(result["added"] ?? 0)),
                        "targetChanged": or(prepared["targetChanged"], result["targetChanged"]),
                    ])
                }
                return result
            }
            let restarted = try withDesktopRestart(Value.spread(pendingPlan, ["receiptFile": existing["file"] ?? plan["receiptFile"]]), paths, work, report, options["io"])
            let code: Value = restarted["code"] === "WORK_REFUSED" ? restarted["result"]["code"] ?? restarted["code"] : restarted["code"]
            return Value.spread(restarted["result"] ?? prepared ?? .newObject(), [
                "ok": and(restarted["ok"], Value(restarted["result"]["ok"] !== false)),
                "restartOutcome": restarted["restart"], "restarted": Value(restarted["restart"]["outcome"] === "reopened"),
                "code": code, "reason": restarted["error"] ?? restarted["result"]["reason"],
            ])
        }
        if !chosen.truthy && options["recover"].truthy {
            return ["reconciled": try reconcileFiles(paths, Value.spread(options, ["inspect": inspect])), "recoveryRequired": true, "ok": false]
        }
        if !chosen.truthy && options["undo"].truthy { return try undoFiles(paths, Value.spread(options, ["inspect": inspect])) }
        if !chosen.truthy {
            return try processRows(inspect.call()).filter(\.isDesktop).count > 1
                ? ["ok": false, "reason": "More than one Claude Desktop instance is running. Close the extra instance before restarting."]
                : ["nothing": true, "ok": true]
        }
        let inv = MovePlan(initial["inv"]), target = initial["target"]
        inv.held = plan["held"] ?? []
        let heldFiles: Value = .newSet(inv.held.elements.flatMap { $0["sources"].elements.map { $0["file"] } })
        inv.move = Value(inv.move.elements.filter { !memberFiles($0).contains(where: { heldFiles.has($0) }) })
        _ = try optCall(options["summary"], inv.raw)
        let result = try transfer(inv, target, paths, report, ["existing": existing, "sessionProgress": sessionProgress])
        return result ?? ["nothing": true, "ok": true]
    })
}

@discardableResult
public func finishHeld(_ paths: Value = .undefined, _ options: Value = .undefined) throws -> Value { try finishHeld(DataLayout(paths), options) }
@discardableResult
func finishHeld(_ paths: DataLayout, _ options: Value = .undefined) throws -> Value {
    let options: Value = options.isUndefined ? .newObject() : options
    let latest = try latestReceipt(paths)
    if !latest.truthy || latest["corrupt"].truthy || !latest["receipt"]["held"]["length"].truthy { return ["nothing": true, "ok": true] }
    if options["background"].truthy {
        let rows: Value = try optCall(options["io"]["inspect"]) ?? options["processes"] ?? (try processTable(Value(paths.claudeApp)))
        for held in latest["receipt"]["held"].elements {
            for row in rows.elements where row["worker"].truthy {
                if try ownsWorker(.newSet(row["ids"].elements), held["id"], held["recordId"]).truthy { return ["pendingLocal": true, "ok": true] }
            }
        }
    }
    let all = try accounts(paths)
    let files: Value = .newSet(latest["receipt"]["held"].elements.flatMap { $0["sources"].elements.map { $0["file"] } })
    var from: [Value] = []
    for ref in latest["receipt"]["fromAccounts"].elements {
        var account: Value = .undefined
        for row in all.elements where try sameAccount(row, ref).truthy { account = row; break }
        if !account.truthy { throw EngineError("\(ref["label"]) is no longer available") }
        var unreadable: [Value] = []
        for row in account["unreadable"].elements where files.has(try desktopFileOf(row)) { unreadable.append(row) }
        from.append(Value.spread(account, ["sessions": Value(account["sessions"].elements.filter { files.has($0["file"]) }), "unreadable": Value(unreadable)]))
    }
    var to: Value = .undefined
    for row in all.elements where try sameAccount(row, latest["receipt"]["toAccount"]).truthy { to = row; break }
    if !to.truthy { throw EngineError("Destination account is no longer available") }
    let found: Value = .newSet(try from.flatMap { account in try (account["sessions"].elements + account["unreadable"].elements).map { try desktopFileOf($0) } })
    if files.elements.contains(where: { !found.has($0) }) { return ["ok": false, "reason": "A held source record disappeared. Its move was not marked complete."] }
    var prior: [Value] = latest["receipt"]["failed"].elements
    let retryIds: Value = .newSet(latest["receipt"]["held"].elements.flatMap { $0["sources"].elements.map { $0["id"] } })
    let result = try executeMove(Value(from), to, paths, Value.spread(options, [
        "resume": true, "resumeFile": latest["file"], "cloudRequested": Value(latest["receipt"]["cloudChecks"].length > 0),
    ]))
    if !result["receipt"].truthy || result["plan"].truthy || result["recoveryRequired"].truthy || result["reason"].truthy { return result }
    var failed: [Value] = []
    for row in result["receipt"]["failed"].elements {
        let at = prior.firstIndex(where: { stable($0) == stable(row) }) ?? -1
        if at >= 0 { prior.remove(at: at) }
        let keep = row["cloudAccount"].truthy ? try actionableCloudFailure(Receipt(result["receipt"]), row).truthy : retryIds.has(row["id"]) || at < 0
        if keep { failed.append(row) }
    }
    return Value.spread(result, [
        "ok": and(try finishOkay(result["receipt"]), Value(failed.isEmpty)), "failed": Value(failed),
        "notMoved": Value(result["receipt"]["failed"].elements.filter { row in !failed.contains(where: { $0 === row }) }),
    ])
}

@discardableResult
public func completeActiveCloud(_ result: Value = .undefined, _ paths: Value = .undefined, _ options: Value = .undefined) throws -> Value { try completeActiveCloud(result, DataLayout(paths), options) }
@discardableResult
func completeActiveCloud(_ result: Value = .undefined, _ paths: DataLayout, _ options: Value = .undefined) throws -> Value {
    let options: Value = options.isUndefined ? .newObject() : options
    if result["plan"].truthy || !result["file"].truthy || !result["receipt"].truthy || result["cloudChecked"].truthy || result["receipt"]["held"]["length"].truthy { return result }
    if try openCloudChecks(Receipt(result["receipt"])).length == 0 || result["recoveryRequired"].truthy || result["restartOutcome"].truthy && !result["ok"].truthy { return result }
    do {
        let active = try cloudIdentity(paths, options)
        var matched = false
        for check in try openCloudChecks(Receipt(result["receipt"])).elements {
            if try sameLogin(check, active).truthy && cloudScope(options["cloud"], check).truthy { matched = true; break }
        }
        if !matched { return result }
        let finished = try finishPending(paths, Value.spread(options, ["active": active, "receiptFile": result["file"]]))
        return Value.spread(result, finished, [
            "restarted": result["restarted"], "restartOutcome": result["restartOutcome"],
            "added": result["added"] ?? 0, "targetChanged": or(result["targetChanged"], finished["restart"]), "reason": finished["reason"],
        ])
    } catch {
        let error = errorObject(error)
        return Value.spread(result, ["ok": false, "complete": false, "code": error["code"], "reason": error["message"]])
    }
}

@discardableResult
public func finishWorkflow(_ paths: Value = .undefined, _ options: Value = .undefined) throws -> Value { try finishWorkflow(DataLayout(paths), options) }
@discardableResult
func finishWorkflow(_ paths: DataLayout, _ options: Value = .undefined) throws -> Value {
    let options: Value = options.isUndefined ? .newObject() : options
    let approving = !options["approve"].nullish
    if approving && (!options["approve"].isString || !re("^[a-f0-9]{64}$").test(options["approve"].asString!)) {
        return ["ok": false, "code": "RESTART_APPROVAL_CHANGED", "reason": "Restart approval is missing or does not match the saved plan"]
    }
    let recovery = try recoveryPending(paths)
    if recovery.truthy {
        if options["background"].truthy && recovery["receipt"]["localRecovery"]["blocked"].truthy {
            return Value.spread(recovery, [
                "summary": try receiptSummary(recovery["receipt"]), "code": "LOCAL_RECOVERY_BLOCKED", "recoveryRequired": true, "ok": false,
                "reconciled": ["title": "Move recovery blocked", "error": recovery["receipt"]["localRecovery"]["blocked"]],
            ])
        }
        let taskTransfers: Value = recovery["receipt"].truthy ? try recoveryFamilies(Receipt(recovery["receipt"])) : []
        if !options["background"].truthy && taskTransfers.length > 0 && !recovery["receipt"]["remotePending"].truthy && !recovery["receipt"]["remoteUndoing"]["length"].truthy {
            var go = approving
            if !go {
                let namespaces = Value(taskTransfers.elements.flatMap { [$0["from"], $0["to"]] })
                go = try schedulerBusy(paths, namespaces, try optCall(options["io"]["inspect"]) ?? options["processes"]).truthy
            }
            if go { return try executeMove(.null, .null, paths, Value.spread(options, ["recover": true, "receiptFile": recovery["file"]])) }
        }
        return try finishPending(paths, options)
    }
    if !(try latestReceipt(paths)).truthy { return ["nothing": true, "ok": true] }
    let deferred = try deferredWorkflow(paths)
    if deferred["mode"] === "local" { return try completeActiveCloud(try finishHeld(paths, options), paths, options) }
    if deferred["mode"] === "undo" { return try finishPending(paths, options) }
    if deferred["mode"] === "partial" { return Value.spread(deferred, ["summary": try receiptSummary(deferred["receipt"]), "ok": false, "complete": false]) }
    if approving {
        if !deferred.truthy || deferred["mode"] !== "cloud" { return ["ok": false, "reason": "The pending move changed before its restart"] }
        let restarted = try executeMove(.null, .null, paths, Value.spread(options, ["finish": true, "receiptFile": deferred["file"]]))
        if !restarted["ok"].truthy || restarted["plan"].truthy { return restarted }
        return try completeActiveCloud(Value.spread(restarted, ["file": deferred["file"], "receipt": deferred["receipt"]]), paths, options)
    }
    let report: Value = Value { args in
        let stage = args.count > 0 ? args[0] : .undefined
        let text = args.count > 1 ? args[1] : .undefined
        let extra: Value = args.count > 2 && !args[2].isUndefined ? args[2] : .newObject()
        return try optCall(options["report"], stage, text, extra["live"].truthy ? Value.spread(extra, ["preparatory": true]) : extra)
    }
    let result = try finishPending(paths, Value.spread(options, ["report": report]))
    let table: Value = try optCall(options["io"]["inspect"]) ?? options["processes"] ?? (try processTable(Value(paths.claudeApp)))
    var checked: Value = .undefined
    if result["receipt"].truthy {
        for check in result["receipt"]["cloudChecks"].elements where try sameAccount(check, result["checkedAccount"]).truthy { checked = check; break }
    }
    if !options["background"].truthy && checked["waiting"]["length"].truthy, try canRestartWaiting(Receipt(["cloudChecks": [checked]]), table).truthy {
        let plan = try executeMove(.null, .null, paths, Value.spread(options, ["finish": true, "finishAccount": result["checkedAccount"], "receiptFile": result["file"]]))
        if plan["plan"].truthy || !plan["ok"].truthy { return plan }
    }
    return result
}

func observedRecord(_ record: Value = .undefined) throws -> Value {
    .fromEntries(DURABLE_RECORD_KEYS.map { ($0, record[$0]) })
}

func inspectPlaced(_ paths: DataLayout) throws -> Value {
    let latest = try latestReceipt(paths)
    if !latest.truthy { return ["changed": []] }
    if latest["corrupt"].truthy { return ["changed": [], "error": "Latest move receipt is unreadable"] }
    let receipt = Receipt(latest["receipt"]), file = latest["file"]
    if receipt.finalizing.truthy || receipt.undoing.truthy || receipt.retiring.truthy || receipt.pending.truthy { return ["changed": [], "recoveryRequired": true] }
    var changed: [Value] = []
    let destination: Value = receipt.toAccount.truthy
        ? Value(path.join(paths.records, receipt.toAccount["account"].description, receipt.toAccount["org"].description))
        : receipt.toAccount
    for row in (receipt.sessions ?? []).elements {
        if !row["recordSnapshot"].truthy || !destination.truthy || Value(path.dirname(row["record"].description)) !== destination || !UUID.test(row["targetId"].description) { continue }
        let raw: Value = orNull { try readFile(row["record"]) }
        if raw.truthy && Value(sha(raw)) === row["recordSha"] { continue }
        var record: Value = .undefined
        if raw.truthy, let data = raw.asData { record = (try? JSON.parse(data)) ?? .undefined }
        let before = try observedRecord(row["recordSnapshot"])
        let after: Value = record.truthy ? try observedRecord(record) : .null
        if after.truthy && stable(before) == stable(after) { continue }
        let fields: Value = after.truthy
            ? .strings(unique(before.ownKeys + after.ownKeys).filter { stable(before[$0]) != stable(after[$0]) })
            : .strings(["record unavailable"])
        let found: String = after.truthy ? sha(stable(after)) : raw.truthy ? sha(raw) : "missing"
        let directory = path.join(paths.state, "drift", path.basename(file.description, ".json"))
        try fs.mkdirp(directory, mode: 0o700)
        let placedFile = path.join(directory, "\(row["targetId"]).placed.json")
        let foundFile = path.join(directory, "\(row["targetId"]).\(found).found.json")
        if !exists(Value(placedFile)) { _ = try writeNew(Value(placedFile), Value(jsonText(row["recordSnapshot"]))) }
        if raw.truthy && !exists(Value(foundFile)) { _ = try writeNew(Value(foundFile), raw) }
        changed.append(["id": row["targetId"], "title": record["title"] ?? row["title"], "fields": fields, "placed": Value(placedFile), "found": raw.truthy ? Value(foundFile) : .null])
    }
    let changedValue = Value(changed)
    if latest["projected"].truthy || stable(receipt.metadataDrift ?? []) != stable(changedValue) {
        receipt.metadataDrift = changedValue
        _ = try projectLocalFailures(receipt, paths, false)
        _ = try saveJson(file, receipt.raw)
    }
    var failed: [Value] = []
    for row in (receipt.failed ?? []).elements where try actionableCloudFailure(receipt, row).truthy { failed.append(row) }
    return [
        "changed": changedValue, "receipt": file, "summary": try receiptSummary(receipt), "ok": try finishOkay(receipt), "failed": Value(failed),
        "notMoved": Value((receipt.failed ?? []).elements.filter { !$0["cloudAccount"].truthy }), "problems": receipt.verification["problems"] ?? [],
    ]
}

@discardableResult
public func verifyPlaced(_ paths: Value = .undefined) throws -> Value { try verifyPlaced(DataLayout(paths)) }
@discardableResult
func verifyPlaced(_ paths: DataLayout) throws -> Value {
    try locked(paths, Value { _ in try inspectPlaced(paths) })
}

@discardableResult
public func sweep(_ paths: Value = .undefined, _ options: Value = .undefined) throws -> Value { try sweep(DataLayout(paths), options) }
@discardableResult
func sweep(_ paths: DataLayout, _ options: Value = .undefined) throws -> Value {
    let options: Value = options.isUndefined ? .newObject() : options
    let recovered = try locked(paths, Value { _ in try reconcile(paths, Value.spread(options, ["background": true])) })
    if recovered["pendingUndo"].truthy { return ["pending": true, "pendingUndo": recovered["pendingUndo"], "ok": true, "complete": false] }
    if recovered.truthy { return ["recovered": recovered, "error": Value("\(recovered["title"]): \(recovered["error"])"), "ok": false] }
    let verification = try verifyPlaced(paths)
    let deferred = try deferredWorkflow(paths)
    if deferred["mode"] === "local" {
        let result = try finishHeld(paths, Value.spread(options, ["background": true]))
        let problems: Value = result["problems"].nullish ? .undefined : Value(result["problems"].elements.map { row in Value("\(row["title"]): \(row["check"])") }.map { $0.description }.joined(separator: ", "))
        let failedText: Value = result["receipt"].nullish ? .undefined : Value(result["receipt"]["failed"].elements.map { row in "\(row["title"]): \(row["error"])" }.joined(separator: ", "))
        let error: Value = result["reason"] ?? problems ?? failedText
        var refreshRequired: Value = Value(!result["receipt"]["held"]["length"].truthy)
        if refreshRequired.truthy { refreshRequired = Value(toNumber(result["added"]) > 0) }
        if refreshRequired.truthy { refreshRequired = try sameAccount(try signedIn(paths), result["receipt"]["toAccount"]) }
        return [
            "verification": verification, "result": result,
            "error": result["ok"] === false ? or(error, "Pending local work needs attention") : .null,
            "refreshRequired": refreshRequired, "ok": Value(result["ok"] !== false),
        ]
    }
    if !deferred.truthy || deferred["mode"] !== "cloud" {
        return ["verification": verification, "ok": Value(!verification["error"].truthy && verification["ok"] !== false), "complete": Value(!deferred.truthy && verification["ok"] === true)]
    }
    let active: Value = try options["active"] ?? (try signedIn(paths, options["processes"]))
    do {
        let result = try finishPending(paths, Value.spread(options, ["active": active, "receiptFile": deferred["file"], "automatic": true]))
        var refresh = result["restart"].truthy
        if refresh { refresh = try sameAccount(active, result["receipt"]["toAccount"]).truthy }
        let failedText: Value = result["failed"].nullish ? .undefined : Value(result["failed"].elements.map { row in "\(row["title"]): \(row["error"])" }.joined(separator: ", "))
        return [
            "verification": verification, "result": result, "pending": result["pending"], "refreshRequired": Value(refresh),
            "error": result["ok"] === false ? or(failedText, "Pending cloud work needs attention") : .null, "ok": Value(result["ok"] !== false),
        ]
    } catch {
        let error = errorObject(error)
        return ["verification": verification, "pending": true, "ok": false, "code": error["code"], "error": error["message"]]
    }
}

@discardableResult
public func undo(_ paths: Value = .undefined, _ options: Value = .undefined) throws -> Value { try undo(DataLayout(paths), options) }
@discardableResult
func undo(_ paths: DataLayout, _ options: Value = .undefined) throws -> Value {
    let options: Value = options.isUndefined ? .newObject() : options
    if !options["approve"].nullish {
        let recovery = try recoveryPending(paths)
        let recover = recovery["receipt"]["taskTransfers"]["length"].truthy
        let latest: Value = try recovery ?? (try latestReceipt(paths))
        return try executeMove(.null, .null, paths, Value.spread(options, ["undo": Value(!recover), "recover": Value(recover), "receiptFile": latest["file"]]))
    }
    let result = try locked(paths, Value { _ in try undoFiles(paths, options) })
    if !result["restartNeeded"].truthy { return result }
    return try executeMove(.null, .null, paths, Value.spread(options, [
        "undo": Value(!result["receipt"]["undoing"].truthy), "recover": Value(result["receipt"]["undoing"].truthy), "receiptFile": result["file"],
    ]))
}

func undoFiles(_ paths: DataLayout, _ options: Value = .undefined) throws -> Value {
    let options: Value = options.isUndefined ? .newObject() : options
    if options["receiptFile"].truthy, try latestReceipt(paths)["file"] !== options["receiptFile"] { return ["ok": false, "reason": "The operation receipt changed"] }
    let reconciled: Value = options["check"].truthy ? .null : try reconcile(paths, options)
    if reconciled["undo"].truthy { return reconciled["undo"] }
    if reconciled["pendingUndo"].truthy {
        return ["receipt": reconciled["receipt"], "pendingUndo": reconciled["pendingUndo"], "remoteRestored": reconciled["remoteRestored"] ?? 0]
    }
    if reconciled.truthy { return ["reconciled": reconciled] }
    let latest = try latestReceipt(paths)
    if options["receiptFile"].truthy && latest["file"] !== options["receiptFile"] { return ["ok": false, "reason": "The operation receipt changed"] }
    if !latest.truthy { return ["nothing": true] }
    let file = latest["file"], receipt = Receipt(latest["receipt"])
    if receipt.retained["length"].truthy { return ["receipt": receipt.raw, "retained": receipt.retained] }
    var kept: [Value] = []
    let inspect = try inspector(paths, options)
    let liveWorkers = try workers(try inspect.call())
    for r in receipt.sessions.elements {
        let changes = try targetChanges(r, liveWorkers, Value(r["strategy"] !== "rehome"))
        if changes.length > 0 { kept.append(Value("\(r["title"]) | \(short(r["targetId"])) | \(changes.join(", ")) changed")) }
    }
    if !kept.isEmpty { return ["receipt": receipt.raw, "changed": Value(kept)] }
    let root = path.join(paths.state, "quarantine")
    let blocked: [Value] = try restoreProblems(receipt.superseded ?? [], Value(root)).elements
        + (try bridgeProblems(receipt.sessions, true)).elements
        + (try taskTransferProblems(receipt.taskTransfers, paths, inspect)).elements
    let schedulerHeld = !blocked.isEmpty && blocked.allSatisfy { $0 === Value(SCHEDULER_OWNS) } && !options["check"].truthy
    if schedulerHeld && !receipt.remote["length"].truthy { return ["restartNeeded": true, "file": file, "receipt": receipt.raw] }
    if !blocked.isEmpty && !schedulerHeld { return ["receipt": receipt.raw, "restoreProblems": Value(blocked)] }
    let plan = try prepareUndo(receipt, paths)
    var changedAfterSnapshot: [Value] = []
    let finalWorkers = try workers(try inspect.call())
    for r in receipt.sessions.elements {
        let changes = try targetChanges(r, finalWorkers, Value(r["strategy"] !== "rehome"))
        if changes.length > 0 { changedAfterSnapshot.append(Value("\(r["title"]) | \(short(r["targetId"])) | \(changes.join(", ")) changed")) }
    }
    if !changedAfterSnapshot.isEmpty { return ["receipt": receipt.raw, "changed": Value(changedAfterSnapshot)] }
    let activationBlocked = try activationProblems(receipt)
    let parentProblems = try undoParentProblems(receipt).elements
    let familyProblems = try taskTransferProblems(receipt.taskTransfers, paths, inspect).elements.filter { !schedulerHeld || $0 !== Value(SCHEDULER_OWNS) }
    activationBlocked.asArray?.items.append(contentsOf: parentProblems + familyProblems)
    if activationBlocked.length > 0 { return ["receipt": receipt.raw, "restoreProblems": activationBlocked] }
    receipt.undoing = plan
    if receipt.remote["length"].truthy { receipt.remoteUndoing = receipt.remote.deepClone() }
    _ = try cancelCloudChecks(receipt)
    _ = try saveJson(file, receipt.raw)
    let remote = try restoreRemote(receipt, file, paths, options)
    if remote["problems"].length > 0 { return ["receipt": receipt.raw, "restoreProblems": remote["problems"]] }
    if remote["pending"].length > 0 { return ["receipt": receipt.raw, "pendingUndo": remote["pending"], "remoteRestored": remote["restored"]] }
    if schedulerHeld { return ["restartNeeded": true, "file": file, "receipt": receipt.raw] }
    return try finishUndo(receipt, file, paths, Value.spread(options, ["inspect": inspect]))
}

public func describe(_ list: Value = .undefined) throws -> Value {
    let emails: Value = .newSet(list.elements.map { $0["email"] ?? Value(short($0["account"])) })
    if emails.length == 1 {
        return Value("\(emails.elements[0]) · \(list.elements.map { ($0["orgName"] ?? Value(short($0["org"]))).description }.joined(separator: " + "))")
    }
    return Value(list.elements.map { $0["label"].description }.joined(separator: ", "))
}

public func find(_ all: Value = .undefined, _ sel: Value = .undefined) throws -> Value {
    func hay(_ a: Value) -> String { "\(a["email"] ?? "") \(a["account"]) \(a["orgName"] ?? "") \(a["org"])".lowercased() }
    let terms = re(#"\s+"#).split(sel.description.lowercased())
    let hits = all.elements.filter { a in
        let text = hay(a)
        return terms.allSatisfy { $0.isEmpty || text.contains($0) }
    }
    if hits.count == 1 { return hits[0] }
    throw EngineError(!hits.isEmpty ? "\"\(sel)\" matches \(hits.map { $0["label"].description }.joined(separator: ", "))" : "\"\(sel)\" matches no account")
}

public func step(_ state: Value = .undefined, _ key: Value = .undefined) throws -> Value {
    let cursor = state["cursor"], chosen = state["chosen"], size = state["size"], multi = state["multi"]
    if key === "up" { return Value.spread(state, ["cursor": Value((toNumber(cursor) + toNumber(size) - 1).truncatingRemainder(dividingBy: toNumber(size)))]) }
    if key === "down" { return Value.spread(state, ["cursor": Value((toNumber(cursor) + 1).truncatingRemainder(dividingBy: toNumber(size)))]) }
    if key === "space" && multi.truthy {
        let next = ValueSet(chosen.elements)
        if next.has(cursor) { next.delete(cursor) } else { next.add(cursor) }
        return Value.spread(state, ["chosen": .set(next)])
    }
    if key === "return" {
        return multi.truthy
            ? (chosen["size"].truthy ? Value.spread(state, ["done": true]) : state)
            : Value.spread(state, ["chosen": .newSet([cursor]), "done": true])
    }
    return state
}

// Decodes terminal input bytes into the key names the picker reacts to.
fileprivate struct PickKey { var name: String?; var ctrl = false }

fileprivate func decodeKeys(_ bytes: [UInt8]) -> [PickKey] {
    var keys: [PickKey] = []
    var i = 0
    func single(_ b: UInt8) -> PickKey {
        switch b {
        case 0x0D: return PickKey(name: "return")
        case 0x0A: return PickKey(name: "enter")
        case 0x09: return PickKey(name: "tab")
        case 0x08, 0x7F: return PickKey(name: "backspace")
        case 0x20: return PickKey(name: "space")
        case 0x1B: return PickKey(name: "escape")
        case 0x01...0x1A: return PickKey(name: String(UnicodeScalar(b + 0x60)), ctrl: true)
        case 0x30...0x39, 0x61...0x7A: return PickKey(name: String(UnicodeScalar(b)))
        case 0x41...0x5A: return PickKey(name: String(UnicodeScalar(b + 0x20)))
        default: return PickKey(name: nil)
        }
    }
    while i < bytes.count {
        let b = bytes[i]
        if b == 0x1B && i + 1 < bytes.count {
            let next = bytes[i + 1]
            if next == 0x5B || next == 0x4F {
                var j = i + 2
                while j < bytes.count && !(0x40...0x7E).contains(bytes[j]) { j += 1 }
                let final: UInt8? = j < bytes.count ? bytes[j] : nil
                switch final {
                case 0x41: keys.append(PickKey(name: "up"))
                case 0x42: keys.append(PickKey(name: "down"))
                case 0x43: keys.append(PickKey(name: "right"))
                case 0x44: keys.append(PickKey(name: "left"))
                default: keys.append(PickKey(name: nil))
                }
                i = min(j + 1, bytes.count)
                continue
            }
            // Escape followed by a key reports that key.
            keys.append(next == 0x1B ? PickKey(name: "escape") : single(next))
            i += 2
            continue
        }
        if b >= 0x80 {
            // A UTF-8 character: no key name.
            var j = i + 1
            while j < bytes.count && bytes[j] & 0xC0 == 0x80 { j += 1 }
            keys.append(PickKey(name: nil))
            i = j
            continue
        }
        keys.append(single(b))
        i += 1
    }
    return keys
}

public func pick(_ title: Value = .undefined, _ rows: Value = .undefined, _ multi: Value = .undefined) throws -> Value {
    let rowList = rows.elements
    if rowList.isEmpty { throw EngineError("no accounts to choose from") }
    let hint = multi.truthy ? "↑↓ move · space select · enter next" : "↑↓ move · enter confirm"
    let width = rowList.map { $0["label"].length }.max() ?? 0
    var state: Value = ["cursor": 0, "chosen": .newSet(), "size": Value(rowList.count), "multi": multi]
    func lines() -> [String] {
        ["\(title)  \(hint)"] + rowList.enumerated().map { (i, r) in
            let cursor = Value(i) === state["cursor"] ? "❯" : " "
            let choice = multi.truthy ? (state["chosen"].has(Value(i)) ? "◉" : "○") : Value(i) === state["cursor"] ? "●" : "○"
            return "  \(cursor) \(choice) \(padEnd(r["label"].description, width))  \(r["stats"])"
        }
    }
    let erase = "\u{1b}[\(rowList.count + 1)A\u{1b}[J"
    // input.setRawMode(true): libuv's raw mode keeps output post-processing so "\n" still returns the carriage.
    var saved = termios()
    let haveTermios = tcgetattr(0, &saved) == 0
    if haveTermios {
        var raw = saved
        raw.c_iflag &= ~tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
        raw.c_oflag |= tcflag_t(ONLCR)
        raw.c_cflag |= tcflag_t(CS8)
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | IEXTEN | ISIG)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        _ = tcsetattr(0, TCSADRAIN, &raw)
    }
    process.stdout("\u{1b}[?25l\(lines().joined(separator: "\n"))\n")
    defer {
        if haveTermios { _ = tcsetattr(0, TCSADRAIN, &saved) }
        process.stdout("\(erase)\u{1b}[?25h")
    }
    var buffer = [UInt8](repeating: 0, count: 64)
    reading: while true {
        let n = Darwin.read(0, &buffer, buffer.count)
        if n < 0 && errno == EINTR { continue }
        // Input closed: treat it as an abort rather than waiting forever.
        if n <= 0 { throw EngineError("aborted", code: 130) }
        for key in decodeKeys(Array(buffer[0..<n])) {
            if (key.ctrl && key.name == "c") || key.name == "escape" || key.name == "q" {
                throw EngineError("aborted", code: 130)
            }
            state = try step(state, key.name.map { Value($0) } ?? .undefined)
            if state["done"].truthy { break reading }
            process.stdout("\(erase)\(lines().joined(separator: "\n"))\n")
        }
    }
    let indices = state["chosen"].elements.map { toNumber($0) }.sorted()
    return Value(indices.map { rowList[Int($0)] })
}

public func reporter(_ json: Value = .undefined) throws -> Value {
    var lastLive = 0.0
    return Value { args in
        let stage = args.count > 0 ? args[0] : .undefined
        let text = args.count > 1 ? args[1] : .undefined
        let extra: Value = args.count > 2 && !args[2].isUndefined ? args[2] : .newObject()
        let now = dateNow()
        let edge = stage === "sessions" || extra["completed"] === 0 || extra["completed"] === extra["total"]
        if extra["live"].truthy && !edge && now - lastLive < 100 { return .undefined }
        if extra["live"].truthy { lastLive = now }
        let fields = ValueObject()
        fields["stage"] = stage
        fields["text"] = text
        if extra["live"].truthy { fields["live"] = true }
        if extra["preparatory"].truthy { fields["preparatory"] = true }
        if extra["activity"].isString { fields["activity"] = extra["activity"] }
        if extra["sourceId"].isString { fields["sourceId"] = extra["sourceId"] }
        if extra["sourceLabel"].isString { fields["sourceLabel"] = extra["sourceLabel"] }
        let total = extra["sessionTotal"], remaining = extra["remainingCount"]
        if isSafeInteger(total) && toNumber(total) >= 0 && isSafeInteger(remaining) && toNumber(remaining) >= 0 && toNumber(remaining) <= toNumber(total) {
            fields["sessionTotal"] = total
            fields["remainingCount"] = remaining
        }
        if isInteger(extra["moved"]) { fields["moved"] = extra["moved"] }
        if isInteger(extra["completed"]) { fields["completed"] = extra["completed"] }
        if isInteger(extra["total"]) { fields["total"] = extra["total"] }
        if json.truthy {
            process.stdout("\(JSON.text(.object(fields)))\n")
            return true
        }
        let tty = stdoutIsTTY()
        if extra["live"].truthy && !tty { return .undefined }
        process.stdout("\(tty ? "\r\u{1b}[K" : "")  \(padEnd(stage.description, 11)) \(text)\(extra["live"].truthy ? "" : "\n")")
        return true
    }
}

// The menu bar app ships as Claude Handoff.app, so `menubar` only refuses.
public func menubar(_ paths: Value = .undefined, _ remove: Value = .undefined, _ snapshot: Value = .undefined) throws -> Value { try menubar(DataLayout(paths), remove, snapshot) }
func menubar(_ paths: DataLayout, _ remove: Value = .undefined, _ snapshot: Value = .undefined) throws -> Value {
    throw EngineError("the menubar app ships as Claude Handoff.app; install it from the release DMG")
}
