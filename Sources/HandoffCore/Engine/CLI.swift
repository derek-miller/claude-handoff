import Foundation

// Argument parsing, the CLI `main` and the top-level error handler.

// Exactly 64 lowercase hex digits; a trailing newline does not match.
fileprivate func hex64(_ v: Value) -> Bool {
    let s = v.description
    return s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
}

// Maps the elements, or undefined when v is null or undefined.
fileprivate func mapOpt(_ v: Value, _ f: (Value) throws -> Value) rethrows -> Value {
    v.nullish ? .undefined : Value(try v.elements.map(f))
}

func parse(_ argv: [String]) throws -> Value {
    let args: Value = ["pair": .null, "from": [], "to": .null, "cmd": .null, "dry": false, "cloud": false, "json": false, "help": false, "version": false, "remove": false, "snapshot": .null, "restartApproved": .null, "moveOnly": false, "leaveChecks": []]
    let value = { (i: Int) throws -> Value in
        if i >= argv.count || argv[i].hasPrefix("-") { throw EngineError("\(argv[i - 1]) needs a value") }
        return .string(argv[i])
    }
    var i = 0
    while i < argv.count {
        let a = argv[i]
        if a == "--from" { i += 1; args["from"].push(try value(i)) }
        else if a == "--to" { i += 1; args.to = try value(i) }
        else if a == "--dry-run" { args.dry = true }
        else if a == "--cloud" { args.cloud = true }
        else if a == "--move-only" { args.moveOnly = true }
        else if a == "--restart-approved" { i += 1; args.restartApproved = try value(i) }
        else if a == "--leave-check" { i += 1; args.leaveChecks.push(try value(i)) }
        else if a == "--json" { args.json = true }
        else if a == "--remove" { args.remove = true }
        else if a == "--snapshot" { i += 1; args.snapshot = try value(i) }
        else if a == "--pair" {
            i += 1
            let parts = try value(i).description.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, try UUID.test(parts[0]), try UUID.test(parts[1]) else { throw EngineError("--pair takes <account uuid>/<org uuid>") }
            args.pair = ["account": .string(parts[0]), "org": .string(parts[1])]
        }
        else if a == "--version" || a == "-v" { args["version"] = true }
        else if a == "--help" || a == "-h" { args.help = true }
        else if !a.hasPrefix("-") && !args.cmd.truthy { args.cmd = .string(a) }
        else { throw EngineError("unknown argument \(a)") }
        i += 1
    }
    let fromCount = args["from"].length
    if (fromCount > 0) != args.to.truthy { throw EngineError("--from and --to go together") }
    if (args.help.truthy || args["version"].truthy) && argv.count > 1 { throw EngineError("\(args.help.truthy ? "--help" : "--version") goes alone") }
    let incompatible = fromCount > 0 || args.to.truthy || args.dry.truthy || args.cloud.truthy || args.remove.truthy || args.snapshot.truthy
    let cmd = args.cmd.asString
    if args.pair.truthy && cmd != "tidy" { throw EngineError("--pair goes with tidy") }
    if ["accounts", "keep-local", "sweep", "tidy"].contains(cmd) && (incompatible || args.restartApproved.truthy || args.moveOnly.truthy) { throw EngineError("\(args.cmd) accepts only --json") }
    if ["finish", "undo"].contains(cmd) && (incompatible || cmd == "undo" && args.moveOnly.truthy) { throw EngineError("\(args.cmd) accepts only --json and --restart-approved") }
    if !args.restartApproved.nullish && !hex64(args.restartApproved) { throw EngineError("restart approval token must be the one displayed by the engine") }
    if args.moveOnly.truthy && (args.restartApproved.truthy || args.dry.truthy || (args.cmd.truthy && cmd != "finish")) { throw EngineError("--move-only applies only to a move or held continuation") }
    if args.restartApproved.truthy && (args.dry.truthy || (args.cmd.truthy && !["restart", "finish", "undo"].contains(cmd))) { throw EngineError("restart approval applies only to a move, finish, undo, or restart") }
    if cmd == "restart" && incompatible { throw EngineError("restart accepts only --json and --restart-approved") }
    if cmd == "menubar" && (fromCount > 0 || args.to.truthy || args.dry.truthy || args.cloud.truthy || args.json.truthy || (args.remove.truthy && args.snapshot.truthy)) { throw EngineError("menubar accepts only --remove or --snapshot <png>") }
    if cmd != "menubar" && (args.remove.truthy || args.snapshot.truthy) { throw EngineError("--remove and --snapshot require menubar") }
    if args.leaveChecks.length > 0 && (cmd != "keep-local" || args.leaveChecks.elements.contains { !hex64($0) }) { throw EngineError("--leave-check requires a current source-check token and keep-local") }
    return args
}

public func main(_ argv: [String]) throws {
    let requestedAt = Value(isoNow())
    let args = try parse(argv)
    if args.help.truthy { return process.stdout(HELP) }
    if args["version"].truthy { return process.stdout("\(VERSION)\n") }
    let paths = DataLayout(home: process.homedir())
    let write = { (s: String) in process.stdout(s) }
    let emit = { (o: Value) in process.stdout(JSON.text(o) + "\n") }

    let showPlan = { (plan: Value) throws -> Void in
        let prior: Value = plan.receiptFile.truthy ? ((try? readReceipt(plan.receiptFile)) ?? .null) : .null
        if args.json.truthy {
            let remaining: Value = plan.remainingCount ?? (plan.selection.nullish ? .undefined : Value(plan.selection["from"].elements.reduce(0.0) { $0 + toNumber($1.files["length"]) })) ?? .null
            let labels: Value = mapOpt(plan.selection["from"]) { $0.label } ?? mapOpt(prior.fromAccounts) { $0.label } ?? []
            let head: Value = ["plan": true]
            let tail: Value = ["heldCount": try heldCount(plan.held), "remainingCount": remaining,
                               "moved": prior.sessions["length"] ?? 0, "undoRecovery": Value(prior.undoing.truthy), "sourceLabels": labels]
            return emit(Value.spread(head, plan, tail))
        }
        let selection: String
        if plan.kind === "undo" { selection = "undo" }
        else if plan.kind === "recover" { selection = "finish" }
        else if plan.resume.truthy { selection = "finish" }
        else if plan.selection.truthy {
            let froms = plan.selection["from"].elements.map { a in "--from \"\(a.account) \(a.org)\"" }.joined(separator: " ")
            selection = "\(froms) --to \"\(plan.selection.to.account) \(plan.selection.to.org)\""
        } else { selection = "restart" }
        let titles = Value(Value.newSet(plan.affected.elements.map { $0.title }).elements).join(", ")
        write("  restart     Claude Desktop must close before this operation\n  affected    \(titles.isEmpty ? "no Code workers" : titles)\n  approve     claude-handoff \(selection) --restart-approved \(plan.token)\(args.cloud.truthy ? " --cloud" : "")\n")
    }

    let showMove = { (result: Value) throws -> Void in
        let report = try reporter(args.json)
        if result.plan.truthy { return try showPlan(result.plan) }
        if result.reason.truthy && !result.receipt.truthy {
            process.exitCode = 1
            if args.json.truthy {
                return emit(["done": true, "ok": false, "code": result.code, "retryable": try retryableCode(result.code), "reason": result.reason, "note": result.reason, "restartOutcome": result.restartOutcome])
            }
            return write("\(result.reason)\n")
        }
        if result.deferred.truthy {
            let labels = Value(result.deferred.sources.elements.map { $0.label })
            process.exitCode = 1
            if args.json.truthy {
                return emit(["done": true, "ok": false, "complete": false, "pendingCloud": result.pendingCloud, "pendingUndo": result.deferred.mode === "undo" ? labels : [], "pendingLabels": labels, "reason": "Finish or undo the pending move before starting another"])
            }
            return write("  pending     finish or undo the pending move before starting another\n")
        }
        if result.recoveryRequired.truthy {
            process.exitCode = 1
            _ = try report.call("reconciled", .string("\(result.reconciled.title) | \(result.reconciled.error)"))
            if args.json.truthy {
                return emit(["done": true, "ok": false, "code": result.code, "recoveryRequired": true, "reconciled": result.reconciled, "reason": result.reason ?? result.reconciled.error, "receipt": result.file, "summary": result.receipt.truthy ? try receiptSummary(result.receipt) : .undefined])
            }
            return write("  move        not run, run it again after reviewing the recovery\n")
        }
        if !result.truthy || result.nothing.truthy || !result.receipt.truthy {
            return args.json.truthy ? emit(["done": true, "ok": result.ok ?? true, "moved": 0, "restarted": result.restarted]) : write("  nothing to move\n")
        }
        let file = result.file, receipt = Receipt(result.receipt), ok = result.ok
        let checks: Value = result.checks.isUndefined ? [] : result.checks
        let problems: Value = result.problems.isUndefined ? [] : result.problems
        if !ok.truthy { process.exitCode = 1 }
        let retired = try retiredCount(receipt)
        let active = try signedIn(paths)
        let refresh = try and(and(Value(!receipt.held["length"].truthy), try sameAccount(active, receipt.toAccount)), Value(result.targetChanged === true))
        let note = result.reason ?? (result.restarted.truthy ? "Claude Desktop reopened after the move" : refresh.truthy ? .string(NOTE) : .null)
        if args.json.truthy {
            let heldAutomatic = receipt.held["length"].truthy && receipt.held.elements.allSatisfy { $0.release === "worker" }
            let code: Value = result.code ?? (!ok.truthy ? (problems.length > 0 ? "LOCAL_VERIFICATION_FAILED" : "MOVE_BLOCKED") : .null)
            let first: Value = ["done": true, "ok": ok, "complete": result.complete, "partial": Value(receipt.localStopped.truthy && !receipt.localCancelledAt.truthy), "receipt": file, "summary": try receiptSummary(receipt), "moved": receipt.sessions["length"],
                                "destinationLabel": receipt.to, "heldCount": try heldCount(receipt.held), "heldAutomatic": Value(heldAutomatic),
                                "sourceLabels": Value(receipt.fromAccounts.elements.map { $0.label }),
                                "code": code,
                                "retryable": try retryableCode(result.code)]
            let second: Value = ["cloudArchived": receipt.remote["length"], "newerCloud": result.newerCloud, "pendingCloud": result.pendingCloud, "pendingLabels": result.pendingLabels, "held": result.held, "waiting": try waitingSessions(receipt), "superseded": Value(toNumber(receipt.superseded["length"]) - toNumber(retired)), "retired": retired, "failed": receipt.failed, "problems": problems, "checks": checks, "note": note, "restart": and(refresh, Value(!result.restarted.truthy)), "restarted": result.restarted, "restartOutcome": result.restartOutcome]
            return emit(Value.spread(first, second))
        }
        let failure = { (f: Value) -> String in "\(or(f.title, f.id)) | \(f.error)" }
        let kept = try keptCopy(receipt)
        var troubles: [String] = []
        for f in receipt.failed.elements where !(try kept.call(f).truthy) { troubles.append(failure(f)) }
        for p in problems.elements { troubles.append("\(p.title.truthy ? "\(p.title) | " : "")\(short(p.id)) | \(p.check) check failed") }
        if !troubles.isEmpty { write("  failed      \(troubles.joined(separator: "\n              "))\n") }
        var copies: [String] = []
        for f in receipt.failed.elements where try kept.call(f).truthy { copies.append(failure(f)) }
        if !copies.isEmpty { write("  kept        \(copies.joined(separator: "\n              "))\n") }
        if !file.truthy { return }
        write("\n  receipt     \(file)\n  undo        claude-handoff undo\n\(note.truthy ? "  then        \(note)\n" : "")")
    }

    if args.cmd === "menubar" {
        let out = try locked(paths, Value { _ in try menubar(paths, args.remove, args.snapshot) })
        return write("\(out)\n")
    }
    if args.cmd === "tidy" {
        let result = try locked(paths, Value { _ in try tidy(paths, args.pair) })
        if args.json.truthy { return emit(result) }
        write(result.moved.length > 0 ? "\(quantity(result.moved.length, "leftover folder", "leftover folders")) set aside | \(result.dest)\n" : "no leftover folders\n")
        for row in result.moved.elements where row["scratchKept"].truthy { write("kept \(row["scratchKept"]) | a session still works there\n") }
        return
    }
    if args.cmd === "sweep" {
        let result = try sweep(paths, ["report": args.json.truthy ? try reporter(true) : .undefined])
        let failed = result.result.failed ?? result.result.receipt.failed ?? result.verification.failed ?? []
        let notMoved = result.result.notMoved ?? result.verification.notMoved ?? []
        let problems = result.result.receipt.verification.problems ?? result.verification.problems ?? []
        var error = result.error ?? result.verification.error
        if error.nullish {
            if problems.length > 0 {
                error = .string(Value(try problems.elements.map { try problemText($0) }).join(", "))
            } else if !result.ok.truthy {
                let text = Value(failed.elements.map { row in Value("\(or(row.title, row.id)) | \(row.error)") }).join(", ")
                error = .string(text.isEmpty ? "The previous move failed verification" : text)
            } else { error = .null }
        }
        if !result.ok.truthy || error.truthy { process.exitCode = 1 }
        if args.json.truthy {
            let code = result.code ?? result.result.code
            let first: Value = ["swept": true, "ok": and(result.ok, Value(!error.truthy)), "error": error, "code": code, "retryable": try retryableCode(code), "changed": result.verification.changed ?? [], "recovered": result.recovered,
                                "receipt": result.result.file ?? result.verification.receipt, "summary": result.result.summary ?? result.verification.summary, "failed": failed, "notMoved": notMoved, "problems": problems]
            let second: Value = ["moved": result.result.added ?? 0, "destinationLabel": result.result.receipt.to,
                                 "pendingLocal": result.result.pendingLocal, "restart": result.refreshRequired, "cloudChecked": result.result.cloudChecked ?? 0, "cloudArchived": result.result.cloudArchived ?? 0, "complete": result.result.complete ?? result.complete]
            return emit(Value.spread(first, second))
        }
        return write(error.truthy ? "\(error)\n" : "\(quantity(result.verification.changed["length"] ?? 0, "metadata change")) detected\n")
    }
    if args.cmd === "restart" {
        let result = try executeMove(.null, .null, paths, ["approve": args.restartApproved, "report": try reporter(args.json)])
        if result.plan.truthy { return try showPlan(result.plan) }
        if !result.ok.truthy { process.exitCode = 1 }
        let note = result.reason ?? (result.restarted.truthy ? "Claude Desktop restarted" : "Claude Desktop is not running")
        return args.json.truthy ? emit(["done": true, "ok": result.ok, "code": result.code, "restarted": result.restarted, "restartOutcome": result.restartOutcome, "note": note]) : write("\(note)\n")
    }
    if args.cmd === "keep-local" {
        let result = try keepLocal(paths, ["checks": args.leaveChecks])
        if result.recoveryRequired.truthy || result.refused.truthy || result.ok === false { process.exitCode = 1 }
        if args.json.truthy {
            if result.nothing.truthy { return emit(["nothing": true]) }
            if result.recoveryRequired.truthy { return emit(["done": true, "ok": false, "recoveryRequired": true, "reason": "Recovery must finish before cloud checks can be cancelled"]) }
            if result.refused.truthy { return emit(["refused": result.refused, "code": result.code ?? "LOCAL_VERIFICATION_FAILED", "reason": result.reason ?? "Moved sessions changed since the move"]) }
            return emit(["done": true, "ok": result.ok, "complete": result.complete, "keptLocal": result.cancelled, "heldCancelled": result.heldCancelled, "labels": result.labels, "sourceLabels": result.labels, "summary": result.summary, "failed": result.failed, "notMoved": result.notMoved, "problems": result.receipt.verification.problems ?? []])
        }
        if result.nothing.truthy { return write("nothing pending\n") }
        if result.recoveryRequired.truthy { return write("  refused     recovery must finish before cloud checks can be cancelled\n") }
        if result.refused.truthy { return write("  refused     \(result.refused.join("\n              "))\n") }
        return write("  kept local  \(quantity(result.cancelled, "cloud check")) cancelled | \(quantity(result.heldCancelled ?? 0, "held session")) left in source\n")
    }
    if args.cmd === "finish" {
        let report = try reporter(args.json)
        _ = try deferredWorkflow(paths)
        let result = try finishWorkflow(paths, ["approve": args.restartApproved, "moveOnly": args.moveOnly, "report": report])
        if result.plan.truthy { return try showPlan(result.plan) }
        if result.ok === false || result.recoveryRequired.truthy || result.restoreProblems["length"].truthy || (!result.nothing.truthy && result.failed["length"].truthy) || result.problems["length"].truthy || result.pendingUndo["length"].truthy { process.exitCode = 1 }
        if args.json.truthy {
            if result.nothing.truthy { return emit(["nothing": true, "summary": result.summary, "failed": result.failed ?? [], "problems": result.problems ?? []]) }
            if result.reconciled.truthy { return emit(["done": true, "ok": false, "code": result.code, "recoveryRequired": true, "reconciled": result.reconciled, "reason": result.reason ?? result.reconciled.error, "receipt": result.file, "summary": result.receipt.truthy ? try receiptSummary(result.receipt) : .undefined]) }
            if result.recoveryRequired.truthy { return emit(["done": true, "ok": false, "recoveryRequired": true, "reason": "Recovery remains pending"]) }
            if result.dest.truthy {
                let r = result.receipt
                return emit(["undone": r.at, "sessions": r.sessions["length"], "restored": try retiredCount(r), "cloudRestored": r.remote["length"] ?? 0, "restart": Value(r.sessions["length"].truthy || r.superseded["length"].truthy || r.remote["length"].truthy)])
            }
            let receipt = Receipt(result.receipt)
            let heldAutomatic = receipt.held["length"].truthy && receipt.held.elements.allSatisfy { $0.release === "worker" }
            let remoteRestored = result.remoteRestored ?? 0
            let first: Value = [
                "done": true,
                "ok": result.ok,
                "complete": result.complete,
                "partial": Value(receipt.localStopped.truthy && !receipt.localCancelledAt.truthy),
                "receipt": result.file,
                "summary": result.summary,
                "moved": receipt.sessions["length"] ?? 0,
                "destinationLabel": receipt.to,
                "heldCount": try heldCount(receipt.held),
                "heldAutomatic": Value(heldAutomatic),
                "code": result.code ?? (result.restoreProblems["length"].truthy ? "UNDO_BLOCKED" : .null),
                "retryable": try retryableCode(result.code),
                "held": receipt.held ?? [],
                "waiting": receipt.truthy ? try waitingSessions(receipt) : [],
                "reason": result.reason,
                "restarted": result.restarted,
            ]
            let second: Value = [
                "cloudArchived": result.cloudArchived ?? 0,
                "cloudRestored": remoteRestored,
                "undoPartial": Value(toNumber(remoteRestored) > 0),
                "cloudChecked": result.cloudChecked ?? 0,
                "newerCloud": result.newerCloud ?? 0,
                "pendingCloud": result.pendingCloud ?? 0,
                "pendingUndo": result.pendingUndo ?? [],
                "pendingLabels": result.pendingLabels ?? result.pendingUndo ?? [],
                "failed": result.failed ?? receipt.failed ?? [],
                "notMoved": result.notMoved ?? [],
                "problems": result.problems ?? [],
                "restart": result.restart ?? false,
            ]
            return emit(Value.spread(first, second))
        }
        if result.nothing.truthy { write("nothing pending\n") }
        if result.reconciled.truthy { return write("recovered   \(result.reconciled.title) | \(result.reconciled.error)\n  finish      not run, review the recovery and try again\n") }
        if result.recoveryRequired.truthy { return write("  pending     recovery remains incomplete\n") }
        if result.dest.truthy { return write("Undo  \(result.receipt.at) completed\n") }
        if result.pendingUndo["length"].truthy { return write("  pending     sign Claude Desktop into \(result.pendingUndo.join(" or ")) and run finish again\n") }
        if result.reason.truthy { write("  failed      \(result.reason)\n") }
        if result.failed["length"].truthy { write("  \(result.nothing.truthy ? "not moved" : "failed   ")   \(result.failed.elements.map { failure in "\(or(failure.title, failure.id)) | \(failure.error)" }.joined(separator: "\n              "))\n") }
        if result.notMoved["length"].truthy { write("  not moved   \(result.notMoved.elements.map { row in "\(or(row.title, row.id)) | \(row.error)" }.joined(separator: "\n              "))\n") }
        if result.problems["length"].truthy { write("  failed      \(Value(try result.problems.elements.map { try problemText($0) }).join("\n              "))\n") }
        if result.nothing.truthy { return }
        let pending = result.pendingLabels["length"].truthy ? " | \(result.pendingLabels.join(", "))" : ""
        return write(result.complete.truthy ? "  cloud       all source checks complete\n" : "  pending     \(result.pendingCloud) cloud checks\(pending)\n")
    }
    if args.cmd === "undo" {
        let result = try undo(paths, ["approve": args.restartApproved, "report": try reporter(args.json)])
        if result.plan.truthy { return try showPlan(result.plan) }
        if result.reason.truthy && !result.receipt.truthy {
            process.exitCode = 1
            return args.json.truthy ? emit(["done": true, "ok": false, "reason": result.reason]) : write("\(result.reason)\n")
        }
        if result.ok === false || result.changed.truthy || result.retained.truthy || result.restoreProblems.truthy || result.reconciled.truthy || result.pendingUndo.truthy { process.exitCode = 1 }
        if args.json.truthy {
            if result.nothing.truthy { return emit(["nothing": true]) }
            if result.reconciled.truthy { return emit(["reconciled": result.reconciled, "retry": true]) }
            if result.pendingUndo.truthy {
                let remoteRestored = result.remoteRestored ?? 0
                return emit(["done": true, "ok": true, "complete": false, "pendingUndo": result.pendingUndo, "pendingLabels": result.pendingUndo, "cloudRestored": remoteRestored, "undoPartial": Value(toNumber(remoteRestored) > 0), "note": .string("sign Claude Desktop into \(result.pendingUndo.join(" or ")) and click Finish undo")])
            }
            if result.retained.truthy { return emit(["refused": Value(result.retained.elements.map { r in Value("\(or(r.title, r.id)) | \(short(r.targetId))") }), "retained": true, "at": result.receipt.at]) }
            if result.changed.truthy { return emit(["refused": result.changed, "at": result.receipt.at]) }
            if result.restoreProblems.truthy { return emit(["refused": result.restoreProblems, "reason": "Undo refused, recovery artifacts are missing or blocked", "at": result.receipt.at]) }
            let r = result.receipt
            return emit([
                "undone": r.at,
                "quarantine": result.dest,
                "sessions": r.sessions["length"],
                "restored": try retiredCount(r),
                "cloudRestored": r.remote["length"] ?? 0,
                "note": .string(NOTE),
                "restart": Value(r.sessions["length"].truthy || r.superseded["length"].truthy || r.remote["length"].truthy),
            ])
        }
        if result.nothing.truthy { return write("nothing to undo\n") }
        if result.reconciled.truthy { return write("reconciled  \(result.reconciled.title) | \(result.reconciled.error)\n  undo        not run, run it again if still wanted\n") }
        let receipt = Receipt(result.receipt)
        write("Undo  \(receipt.at) | \(receipt.from.join(" + ")) → \(receipt.to)\n")
        if result.pendingUndo.truthy { return write("  pending     sign Claude Desktop into \(result.pendingUndo.join(" or ")) and run finish\n") }
        if result.retained.truthy {
            let rows = result.retained.elements.map { r in "    \(or(r.title, r.id)) | \(short(r.targetId))" }.joined(separator: "\n")
            return write("  refused | \(result.retained.length) interrupted copies changed and remain in place\n\(rows)\n")
        }
        if result.changed.truthy {
            return write("  refused | \(result.changed.length) sessions changed since the move | nothing changed\n\(result.changed.elements.map { t in "    \(t)" }.joined(separator: "\n"))\n")
        }
        if result.restoreProblems.truthy {
            return write("  refused | source recovery is incomplete | nothing changed\n\(result.restoreProblems.elements.map { t in "    \(t)" }.joined(separator: "\n"))\n")
        }
        let back = try retiredCount(receipt)
        let cloudBack = receipt.remote["length"] ?? 0
        let lines: [String?] = [
            receipt.sessions["length"].truthy ? "  \(count(receipt.sessions["length"])) desktop records → quarantine" : nil,
            back.truthy ? "  \(count(back)) source records put back" : nil,
            cloudBack.truthy ? "  \(count(cloudBack)) cloud mirrors restored" : nil,
            "  chat messages preserved ✓\(receipt.sessions.elements.contains { $0.bridgeAppend.truthy } ? " | local bridge metadata preserved or restored" : "")",
            "  quarantine  \(result.dest)",
            "  then        \(NOTE)",
            "",
        ]
        return write(lines.compactMap { $0 }.joined(separator: "\n"))
    }
    let all = try accounts(paths)
    if args.cmd === "accounts" {
        let extra = Set(try leftovers(paths, all).elements.map { "\($0.account)/\($0.org)" })
        if args.json.truthy {
            var recoveryProblem: Value = .null
            var latest: Value
            do { latest = try latestReceipt(paths) } catch let thrown {
                let error = errorObject(thrown)
                if error.code !== "OLDER_MOVE" { throw thrown }
                recoveryProblem = ["receipt": error.file, "error": error["message"], "code": error.code]
                latest = .null
            }
            if recoveryProblem.nullish {
                recoveryProblem = latest.corrupt.truthy ? ["receipt": latest.file, "error": "The move record is unreadable"]
                    : latest.receipt.localRecovery.blocked.truthy ? ["receipt": latest.file, "error": latest.receipt.localRecovery.blocked] : .null
            }
            var deferred: Value
            do { deferred = try deferredWorkflow(paths, latest) } catch let thrown {
                let error = errorObject(thrown)
                if latest.nullish { throw EngineError.type("Cannot read properties of \(latest) (reading 'file')") }
                recoveryProblem = ["receipt": latest.file, "error": error["message"]]
                deferred = .null
            }
            let table: Value = deferred.truthy ? try processTable(Value(paths.claudeApp)) : []
            let identity: Value = deferred.truthy ? try signedIn(paths, table) : .null
            let timeouts: Value = deferred.mode === "local" ? try idleTimeouts(paths, table) : Value.newMap()
            let summary: Value = latest.receipt.truthy ? try receiptSummary(latest.receipt) : .null
            var done: Value = .null
            if summary.truthy && !deferred.truthy && !recoveryProblem.truthy {
                if !(try needsRecovery(latest.receipt)).truthy {
                    if (try finishOkay(latest.receipt)).truthy { done = latest.receipt.to }
                }
            }
            var rows: [Value] = []
            for row in all.elements {
                let account = row.account, org = row.org, active = row.active, signedInValue = row.signedIn
                var source: Value = .undefined
                for candidate in deferred.sources.elements where try sameAccount(candidate, ["account": account, "org": org]).truthy { source = candidate; break }
                var waiting: Value = []
                if source.truthy {
                    if deferred.mode === "local" {
                        var held: Value = .undefined
                        if !deferred.receipt.held.nullish {
                            var kept: [Value] = []
                            for h in deferred.receipt.held.elements {
                                var hit = false
                                for member in h.sources.elements where try sameAccount(member, source).truthy { hit = true; break }
                                if hit { kept.append(h) }
                            }
                            held = Value(kept)
                        }
                        var checks: [Value] = []
                        for check in deferred.receipt.cloudChecks.elements where try sameAccount(check, source).truthy { checks.append(check) }
                        waiting = try waitingSessions(["held": held, "cloudChecks": Value(checks)])
                    } else {
                        waiting = source.waiting ?? []
                    }
                }
                let current = all.elements.first { $0.active.truthy } ?? .undefined
                var scheduler = processRows(table).contains(where: \.isDesktop)
                if scheduler {
                    if current.truthy {
                        var hit = false
                        for r in [source, deferred.receipt.toAccount] where try sameAccount(r, current).truthy { hit = true; break }
                        scheduler = hit
                    }
                }
                if scheduler { scheduler = (deferred.receipt.held ?? []).elements.contains { $0.release !== "worker" } }
                let presentation = try pendingPresentation(deferred.receipt ?? Value.newObject(), source, ["active": active, "signedIn": signedInValue], deferred.mode, table, Value(scheduler), timeouts, identity)
                var keptLocal = false
                if !latest.receipt.cloudChecks.nullish {
                    for check in latest.receipt.cloudChecks.elements where try sameAccount(check, ["account": account, "org": org]).truthy && check.status === "cancelled" { keptLocal = true; break }
                }
                let head: Value = [
                    "account": account,
                    "org": org,
                    "email": row.email,
                    "orgName": row.orgName,
                    "label": row.label,
                    "stats": row.stats,
                    "active": active,
                    "signedIn": signedInValue,
                    "identityState": row.identityState,
                    "sessions": row.sessions["length"],
                    "unreadable": row.unreadable["length"],
                    "activeAt": row.activeAt,
                    "pending": source.truthy ? deferred.mode : .null,
                ]
                let tail: Value = [
                    "pendingWaiting": waiting,
                    "pendingCancel": source.truthy && deferred.mode === "cloud" ? try cloudCancelToken(latest.file, source) : .null,
                    "kept": Value(keptLocal),
                    "receiptMoved": summary.moved ?? .null,
                    "receiptSummary": summary,
                    "receiptDone": done,
                    "receiptDestination": source.truthy ? .string("\(deferred.receipt.toAccount.account)/\(deferred.receipt.toAccount.org)") : .null,
                    "pendingFailures": source.failures ?? [],
                    "receipt": latest.file ?? .null,
                    "recoveryProblem": recoveryProblem,
                    "leftover": Value(extra.contains("\(account)/\(org)")),
                ]
                rows.append(Value.spread(head, presentation, tail))
            }
            return emit(Value(rows))
        }
        if all.length == 0 { return write("no accounts found\n") }
        let width = all.elements.map { $0.label.length }.max() ?? 0
        return write("\(all.elements.map { a in "  \(padEnd(a.label.description, width))  \(a.stats)\(extra.contains("\(a.account)/\(a.org)") ? " | leftover" : "")" }.joined(separator: "\n"))\n")
    }
    if args.cmd.truthy { throw EngineError("unknown command \(args.cmd)") }
    var from: Value
    var to: Value
    if args.to.truthy {
        from = Value(try args["from"].elements.map { sel in try find(all, sel) })
        to = try find(all, args.to)
    } else {
        if !process.stdinIsTTY() { throw EngineError("no terminal, pass --from and --to") }
        from = try pick("From", all, true)
        let fromNow = from
        to = try pick("To", Value(all.elements.filter { a in !fromNow.includes(a) }), false)[0]
    }
    if Value.newSet(from.elements.map { account in Value("\(account.account)/\(account.org)") }).length != from.length { throw EngineError("from accounts must be unique") }
    if from.includes(to) { throw EngineError("to must differ from from") }
    let report = try reporter(args.json)
    var cloud: Value = .null
    var cloudError: Value = .null
    if args.cloud.truthy && !args.restartApproved.truthy {
        do { cloud = try cloudClient(paths) } catch { cloudError = errorObject(error)["message"] }
    }
    let deferred = try deferredWorkflow(paths)
    if deferred.truthy {
        let labels = Value(deferred.sources.elements.map { $0.label }).join(", ")
        _ = try report.call("pending", .string("\(deferred.mode === "undo" ? "Undo" : deferred.mode === "local" ? "Held sessions" : "Cloud checks") | \(labels)"))
        process.exitCode = 1
        if args.json.truthy {
            return emit(["done": true, "ok": false, "complete": false, "pendingCloud": deferred.mode === "cloud" ? Value(deferred.sources.length) : 0, "pendingUndo": deferred.mode === "undo" ? Value(deferred.sources.elements.map { $0.label }) : [], "pendingLabels": Value(deferred.sources.elements.map { $0.label }), "reason": "Finish or undo the pending move before starting another"])
        }
        return write("  pending     finish or undo the pending move before starting another\n")
    }
    if !args.json.truthy { write("From  \(try describe(from))\nTo    \(to.label)\n\n") }
    let summaryFn = { (inv: Value) throws -> Void in
        let tally = { (items: Value, target: Bool) -> Int in items.elements.filter { $0.target.truthy == target }.count }
        let sourceUnreadable = tally(inv.unreadable, false)
        let targetUnreadable = tally(inv.unreadable, true)
        let sourceRejected = tally(inv.rejected, false)
        let targetRejected = tally(inv.rejected, true)
        let parts: [String?] = [
            "\(count(inv.total)) records",
            inv.missing["length"].truthy ? "\(count(inv.missing["length"])) without history" : nil,
            sourceUnreadable > 0 ? "\(count(sourceUnreadable)) source unreadable" : nil,
            targetUnreadable > 0 ? "\(count(targetUnreadable)) target unreadable" : nil,
            sourceRejected > 0 ? "\(count(sourceRejected)) source rejected" : nil,
            targetRejected > 0 ? "\(count(targetRejected)) target rejected" : nil,
            inv.twice.truthy ? "\(count(inv.twice)) compatible source versions" : nil,
            inv.apart.truthy ? "\(count(inv.apart)) overlapping versions, kept separate" : nil,
            inv.there["length"].truthy ? "\(count(inv.there["length"])) already there" : nil,
            inv.blocked["length"].truthy ? "\(count(inv.blocked["length"])) blocked" : nil,
            inv.cloud.matches["length"].truthy ? "\(count(inv.cloud.matches["length"])) cloud mirrors" : nil,
            inv.cloud.blocked["length"].truthy ? "\(count(inv.cloud.blocked["length"])) cloud blocked" : nil,
            inv.cloud.waiting["length"].truthy ? "\(count(inv.cloud.waiting["length"])) remote sessions open" : nil,
            inv.cloud.later["length"].truthy ? "\(count(inv.cloud.later["length"])) newer cloud sessions left for next move" : nil,
            inv.pendingCloud.truthy ? "\(quantity(inv.pendingCloud, "cloud check")) pending" : nil,
            "\(count(inv.move["length"])) to move",
        ]
        _ = try report.call("inventory", .string(parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | ")))
        if inv.cloudError.truthy { _ = try report.call("cloud", .string("deferred | \(inv.cloudError)")) }
    }
    let summary = Value { a in try summaryFn(a.first ?? .undefined); return .undefined }
    if args.dry.truthy {
        let p = try recoveryPending(paths)
        if p.truthy {
            var text = "\(p.receipt.sessions["length"] ?? 0) sessions | interrupted finalization, reconciled on the next move"
            if p.corrupt.truthy { text = "\(p.name) | corrupt receipt, set aside on the next move" }
            else if p.receipt.pending.truthy { text = "\(p.receipt.pending.title) | interrupted record placement, reconciled on the next move" }
            else if p.receipt.retiring.truthy { text = "\(p.receipt.retiring["length"]) entries | interrupted retirement, reconciled on the next move" }
            else if p.receipt.undoing.truthy { text = "\(p.receipt.undoing["length"]) sessions | interrupted undo, reconciled on the next move" }
            _ = try report.call("pending", .string(text))
            process.exitCode = 1
            return args.json.truthy ? emit(["done": true, "ok": false, "dry": true, "recoveryRequired": true, "planned": .null]) : write("  dry run     plan unavailable until the next move reconciles this state\n")
        }
        let inv = try inventory(from, to, paths, report, ["cloud": cloud, "cloudRequested": args.cloud, "cloudError": cloudError])
        try summaryFn(inv)
        let landed = Value(inv.move.elements.map { history -> Value in ["history": history] })
        var retiring = 0
        for row in try owners(inv.sources, try carrying(inv, landed)).elements where !(try retirementOwnership(inv, row.s, row.owner)).truthy { retiring += 1 }
        if retiring > 0 { _ = try report.call("retire", .string("\(count(retiring)) source records once the target records verify")) }
        let failures = try inventoryFailures(inv)
        if failures.length > 0 { process.exitCode = 1 }
        if args.json.truthy {
            return emit(["done": true, "ok": Value(failures.length == 0), "dry": true, "moved": 0, "planned": inv.move["length"], "cloudPlanned": inv.cloud.matches["length"], "pendingCloud": inv.pendingCloud, "retiring": Value(retiring), "failed": failures])
        }
        return write(inv.move["length"].truthy || retiring > 0 ? "  dry run     nothing written\n" : failures.length > 0 ? "  dry run     blocked records must be resolved\n" : "  nothing to move\n")
    }
    let result = try executeMove(from, to, paths, ["report": report, "cloud": cloud, "cloudRequested": args.cloud, "cloudError": cloudError, "requestedAt": requestedAt, "approve": args.restartApproved, "moveOnly": args.moveOnly, "summary": summary])
    return try showMove(try completeActiveCloud(result, paths, ["cloud": cloud, "report": report]))
}

// Runs the CLI and maps any uncaught error to its message and exit code.
public func runCLI(_ argv: [String]) -> Int32 {
    do {
        try main(argv)
        return process.exitCode
    } catch {
        let e = errorObject(error)
        let code = e["code"]
        let message = e["message"]
        if argv.contains("--json") {
            let o: Value = ["done": Value(!argv.contains("sweep")), "swept": Value(argv.contains("sweep")), "ok": false, "code": code.isString ? code : "COMMAND_FAILED", "retryable": (try? retryableCode(code)) ?? false, "reason": message, "error": message]
            process.stdout(JSON.text(o) + "\n")
        }
        process.stderr("claude-handoff: \(message)\n")
        process.exitCode = code === 130 ? 130 : 1
        return process.exitCode
    }
}
