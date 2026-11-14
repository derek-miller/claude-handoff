import AppKit

enum StateChecks {
    @MainActor
    static func run() {
        let captured = try! JSONSerialization.jsonObject(with: fixtureData("CAPTURED_RESTART_PROGRESS")) as! [[String: Any]]
        let replay = Model(demo: Demo.accounts)
        replay.begin()
        for row in captured {
            replay.handle(row["line"] as! String)
            if row["preQuit"] as! Bool {
                precondition(replay.moveProgress.percent < 99)
                precondition(!replay.moveProgress.restarting && !replay.moveProgress.skipped.contains("close") && !replay.moveProgress.skipped.contains("reopen"))
            }
        }
        precondition(replay.moveProgress.restarting)
        let menuSize = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)!.size
        var textHeight: Int?
        for badge in ["", "0%", "9%", "10%", "47%", "99%", "100%"] {
            let image = MenuLabel(symbol: "arrow.left.arrow.right", badge: badge).image
            precondition(image.size == menuSize && image.isTemplate && image.tiffRepresentation != nil)
            if !badge.isEmpty {
                let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
                let rows = (0..<bitmap.pixelsHigh).filter { y in (0..<bitmap.pixelsWide).contains { x in bitmap.colorAt(x: x, y: y)!.alphaComponent > 0.4 } }.count
                precondition(textHeight == nil || rows == textHeight)
                textHeight = rows
            }
        }
        for symbol in ["info.circle", "exclamationmark.triangle", "checkmark"] {
            let image = MenuLabel(symbol: symbol, badge: "").image
            precondition(image.size == menuSize && image.isTemplate && image.tiffRepresentation != nil)
        }
        var counts = MoveProgress(now: 0)
        precondition(counts.detail == "0%")
        counts.sessions(total: 498, remaining: 226)
        counts.update("scan", completed: 0, total: 800, now: 0)
        counts.update("scan", completed: 3, total: 800, now: 3)
        precondition(counts.remainingSessions == 226 && counts.detail == "\(counts.percent)% · 226 sessions left")
        counts.sessions(total: 498, remaining: 220)
        counts.update("move", completed: 1, total: 6, now: 4)
        counts.update("move", completed: 1, total: 6, now: 5)
        precondition(counts.remainingSessions == 220)
        counts.sessions(total: 498, remaining: 1)
        precondition(counts.detail == "\(counts.percent)% · 1 session left")
        counts.sessions(total: 498, remaining: 0)
        counts.update("verify", completed: 1, total: 226, now: 6)
        precondition(counts.percent < 100 && counts.detail == "\(counts.percent)%")
        let cliProgress = try! JSONDecoder().decode([String].self, from: fixtureData("CLI_COUNTER_EVENTS"))
        let continued = Model(demo: Demo.accounts)
        continued.begin()
        var countEvents = 0
        for line in cliProgress {
            let event = try! JSONDecoder().decode(Event.self, from: Data(line.utf8))
            continued.handle(line)
            if event.stage == "sessions" { countEvents += 1; precondition(continued.moveProgress.remainingSessions == event.remainingCount) }
        }
        precondition(countEvents == 2 && continued.moveProgress.remainingSessions == 0)
        let sourceProgress = Model(demo: Demo.accounts)
        sourceProgress.begin()
        sourceProgress.handle(#"{"stage":"cloud","text":"0/2","live":true,"completed":0,"total":2,"sourceId":"work/personal","sourceLabel":"Source"}"#)
        let activity = sourceProgress.sourceActivity?.sourceId
        sourceProgress.handle(#"{"stage":"sessions","text":"Remaining sessions","live":true,"sessionTotal":5,"remainingCount":3}"#)
        precondition(sourceProgress.moveProgress.remainingSessions == 3 && sourceProgress.sourceActivity?.sourceId == activity && sourceProgress.displaySummary == sourceProgress.moveProgress.detail)
        for line in [#"{"stage":"sessions","text":"Invalid","live":true,"sessionTotal":2,"remainingCount":3}"#,
                     #"{"stage":"sessions","text":"Invalid","live":true,"sessionTotal":-1,"remainingCount":0}"#] { sourceProgress.handle(line) }
        precondition(sourceProgress.moveProgress.remainingSessions == 3)
        var progress = MoveProgress(now: 0)
        var previous = 0
        for (stage, completed, total, at) in [("scan", 0, 100, 0.0), ("scan", 50, 100, 2.0), ("scan", 100, 100, 4.0), ("cloud scan", 1, 2, 5.0), ("desktop", 0, 1, 6.0), ("scan", 1, 100, 8.0), ("scan", 100, 100, 8.2), ("move", 1, 100, 8.3), ("move", 100, 100, 8.5), ("verify", 100, 100, 8.6), ("retire", 100, 100, 8.7), ("finalize", 0, 1, 8.8), ("reopen", 0, 1, 9.0), ("cloud", 1, 2, 10.0), ("cloud", 2, 2, 11.0)] {
            progress.update(stage, completed: completed, total: total, now: at)
            precondition(progress.percent >= previous && progress.percent <= 99)
            previous = progress.percent
        }
        progress.refresh(10000)
        precondition(progress.percent == 99)
        for stage in ["", "undo", "keep-local", "unknown"] {
            var idle = MoveProgress(now: 0)
            idle.update(stage, completed: nil, total: nil, now: 1)
            precondition(!idle.hasProgress && idle.percent == 0)
        }
        var local = MoveProgress(now: 0)
        local.update("scan", completed: 100, total: 100, now: 1)
        local.update("move", completed: 100, total: 100, now: 2)
        precondition(!local.skipped.contains("move"))
        local.update("finalize", completed: nil, total: nil, now: 3)
        precondition(local.percent >= 85)
        local.update("cloud", completed: 0, total: 0, now: 4)
        precondition(local.skipped.contains("cloud") && local.percent > 90)
        var mixed = MoveProgress(now: 0)
        mixed.update("cloud", completed: 1, total: 1, preparatory: true, now: 2)
        let checked = mixed.percent
        precondition(checked < 99 && mixed.phase == "cloudScan")
        mixed.update("desktop", completed: nil, total: nil, now: 3)
        precondition(mixed.phase == "close" && mixed.percent >= checked)
        mixed.update("reopen", completed: nil, total: nil, now: 4)
        precondition(mixed.phase == "reopen")
        var paused = MoveProgress(now: 0)
        paused.update("scan", completed: 0, total: 1, now: 0)
        paused.paused = 2
        paused.resume(102)
        precondition(paused.started == 100 && paused.paused == nil)
        let progressModel = Model(demo: Demo.accounts)
        progressModel.begin()
        precondition(progressModel.badge == "0%")
        progressModel.handle("{\"stage\":\"cloud\",\"text\":\"1/1\",\"live\":true,\"completed\":1,\"total\":1,\"preparatory\":true}")
        precondition(progressModel.moveProgress.phase == "cloudScan" && progressModel.moveProgress.percent < 99)
        progressModel.begin()
        progressModel.handle("{\"stage\":\"scan\",\"text\":\"50/100\",\"live\":true,\"completed\":50,\"total\":100}")
        progressModel.handle("{\"stage\":\"cloud scan\",\"text\":\"0/1\",\"live\":true,\"completed\":0,\"total\":1}")
        let percentage = progressModel.badge
        precondition(percentage.hasSuffix("%") && !percentage.contains("/"))
        progressModel.handle("{\"stage\":\"sessions\",\"text\":\"Remaining sessions\",\"live\":true,\"sessionTotal\":5,\"remainingCount\":4}")
        precondition(progressModel.displaySummary == percentage + " · 4 sessions left" && progressModel.tooltip == progressModel.displaySummary)
        progressModel.handle("{\"stage\":\"inventory\",\"text\":\"100 sessions\"}")
        precondition(progressModel.badge == percentage)
        progressModel.begin(resetProgress: false)
        progressModel.handle("{\"stage\":\"sessions\",\"text\":\"Remaining sessions\",\"live\":true,\"sessionTotal\":5,\"remainingCount\":3}")
        precondition(progressModel.badge == percentage && progressModel.moveProgress.detail == percentage + " · 3 sessions left" && progressModel.displaySummary == progressModel.moveProgress.detail)
        progressModel.handle("{\"done\":true,\"ok\":false,\"moved\":0,\"reason\":\"fixture rollback\"}")
        progressModel.checkFinish(1)
        precondition(progressModel.badge.isEmpty && !progressModel.running && progressModel.tooltip == "Claude Handoff")
        progressModel.begin()
        progressModel.handle("{\"done\":true,\"ok\":true,\"complete\":true,\"moved\":100}")
        progressModel.checkFinish(0)
        precondition(progressModel.badge == "100%" && !progressModel.running)
        let completed = Model(demo: Demo.accounts)
        completed.selectTarget(Demo.accounts[2].id)
        completed.begin()
        completed.handle("{\"done\":true,\"ok\":true,\"complete\":true,\"moved\":167}")
        precondition(completed.visibleCompletion == nil)
        completed.checkFinish(0)
        precondition(completed.visibleCompletion?.summary == "Done. 167 sessions are now in you@home.com · Personal.")
        precondition(completed.visibleCompletion?.detail == "History verified")
        completed.note = "A moved session has a newer title"
        precondition(completed.visibleCompletion?.summary == "Done. 167 sessions are now in you@home.com · Personal.")
        completed.selectTarget(Demo.accounts[3].id)
        precondition(completed.visibleCompletion != nil && completed.note.isEmpty)
        for event in [
            "{\"done\":true,\"ok\":true,\"complete\":false,\"moved\":167}",
            "{\"done\":true,\"ok\":true,\"complete\":true,\"moved\":167,\"pendingCloud\":1}",
            "{\"done\":true,\"ok\":false,\"complete\":true,\"moved\":167}",
            "{\"done\":true,\"ok\":true,\"complete\":true,\"moved\":0}",
            "{\"done\":true,\"ok\":true,\"complete\":true,\"moved\":167,\"keptLocal\":1}",
            "{\"undone\":true,\"sessions\":167}"
        ] {
            completed.begin()
            completed.handle(event)
            completed.checkFinish(0)
            precondition(completed.visibleCompletion == nil)
        }
        completed.begin()
        completed.handle("{\"done\":true,\"ok\":true,\"complete\":true,\"moved\":167}")
        completed.checkFinish(1)
        precondition(completed.completion == nil)
        requests = []
        let model = Model(demo: Demo.accounts)
        model.selectTarget(Demo.accounts[2].id)
        let selected = model.to
        model.checkSweep()
        precondition(model.ready && !model.running)
        model.move()
        precondition(model.running && !model.ready && model.displaySummary == "0%")
        model.selectTarget(Demo.accounts[3].id)
        precondition(model.to == selected)
        model.to = Demo.accounts[3].id
        model.undo()
        precondition(requests.count == 1)
        requests[0].1("{\"swept\":true,\"ok\":true}")
        requests[0].2(0, "")
        precondition(requests.count == 2)
        let command = requests[1].0
        precondition(command[command.firstIndex(of: "--to")! + 1] == Demo.accounts[2].selector)
        precondition(!command.contains("undo"))
        precondition(!model.sweeping && model.running)
        for field in ["record unavailable", "isStarred", "title", "isArchived"] {
            requests = []
            let item = Model(demo: Demo.accounts)
            item.checkSweep()
            requests[0].1("{\"swept\":true,\"ok\":true,\"changed\":[{\"id\":\"fixture\",\"title\":\"Fixture\",\"fields\":[\"" + field + "\"]}]}")
            requests[0].2(0, "")
            let unavailable = field == "record unavailable"
            precondition(item.symbol == (unavailable ? "exclamationmark.triangle" : "info.circle"))
            precondition(item.note.contains(unavailable ? "cannot be read" : ["isStarred": "starred state", "isArchived": "archive state", "title": "title"][field]!))
            precondition(item.detailLines.contains { $0.1.contains("Fixture") })
        }
        func accountResponse(_ pending: Bool) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: Demo.accounts.enumerated().map { index, account -> [String: Any] in
                var row: [String: Any] = ["account": account.account, "org": account.org, "label": account.label, "active": index == 0]
                if pending && index == 0 { row["pending"] = "cloud"; row["pendingAction"] = "finish"; row["receipt"] = "receipt-one" }
                return row
            }), encoding: .utf8)!
        }
        requests = []
        let picker = Model(demo: Demo.accounts)
        picker.selectTarget(Demo.accounts[2].id)
        picker.toggle(Demo.accounts[0].id)
        for id in Array(picker.from) { picker.toggle(id) }
        precondition(picker.from.isEmpty)
        picker.selectTarget(Demo.accounts[2].id)
        precondition(picker.from == Set(Demo.accounts.map(\.id)).subtracting([Demo.accounts[2].id]))
        picker.toggle(Demo.accounts[0].id)
        picker.selectTarget(Demo.accounts[3].id)
        precondition(!picker.from.contains(Demo.accounts[0].id))
        picker.reset()
        precondition(picker.from.isEmpty && picker.to == nil && !picker.ready && picker.note.isEmpty)
        precondition(requests.count == 1 && requests[0].0 == ["accounts", "--json"])
        requests[0].1(accountResponse(false))
        requests[0].2(0, "")
        precondition(picker.from.isEmpty && picker.to == nil)
        picker.toggle(Demo.accounts[0].id)
        precondition(picker.from == [Demo.accounts[0].id] && picker.to == nil)
        picker.selectTarget(Demo.accounts[2].id)
        precondition(picker.from == [Demo.accounts[0].id] && picker.ready)
        picker.reset()
        picker.selectTarget(Demo.accounts[3].id)
        precondition(picker.from == Set(Demo.accounts.map(\.id)).subtracting([Demo.accounts[3].id]))
        picker.begin()
        picker.reset()
        precondition(picker.running && picker.to == Demo.accounts[3].id)
        let pendingPicker = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(accountResponse(true).utf8)))
        let pendingSelection = pendingPicker.to
        pendingPicker.reset()
        precondition(pendingPicker.to == pendingSelection && !pendingPicker.pendingAccounts.isEmpty)
        let corruptedAccounts = String(data: fixtureData("CORRUPTED_CHECKPOINT_ACCOUNTS"), encoding: .utf8)!
        let repairedAccounts = String(data: fixtureData("REPAIRED_CHECKPOINT_ACCOUNTS"), encoding: .utf8)!
        let discoveredAccounts = try! JSONDecoder().decode([Account].self, from: Data(corruptedAccounts.utf8))
        for populated in [false, true] {
            requests = []
            let inventory = Model(demo: populated ? Demo.accounts : [])
            if populated {
                inventory.note = "An earlier result"
                inventory.lines = [("metadata", "An earlier detail")]
                inventory.completion = ("An earlier result", "History verified")
                inventory.symbol = "info.circle"
                inventory.badge = "100%"
                inventory.restartAvailable = true
            }
            let previousNote = inventory.note, previousLines = inventory.lines
            let previousSymbol = inventory.symbol, previousBadge = inventory.badge
            for _ in 0..<2 {
                let index = requests.count
                inventory.refresh()
                precondition(requests[index].0 == ["accounts", "--json"])
                requests[index].1(corruptedAccounts)
                requests[index].2(0, "")
                precondition(inventory.accounts.map(\.id) == discoveredAccounts.map(\.id))
                precondition(inventory.accounts.map(\.stats) == discoveredAccounts.map(\.stats))
                precondition(inventory.displaySummary == "The last move is paused.")
                precondition(inventory.visibleCompletion == nil)
                precondition(!inventory.canMutate && !inventory.ready && !inventory.pendingReady && !inventory.canKeepLocal)
                precondition(inventory.recoveryProblem?.receipt == discoveredAccounts[0].recoveryProblem?.receipt)
                precondition(inventory.detailLines.contains { $0.0 == "recovery" && $0.1 == "Invalid append checkpoint" })
                precondition(inventory.detailLines.contains { $0.0 == "receipt" && $0.1 == inventory.recoveryProblem?.receipt })
                precondition(inventory.detailLines.count == previousLines.count + 3)
                inventory.move()
                inventory.finishPending()
                inventory.stopHere()
                inventory.undo()
                inventory.restartDesktop()
                inventory.checkSweep()
                precondition(requests.count == index + 1 && !inventory.running && !inventory.sweeping)
            }
            let index = requests.count
            inventory.refresh()
            requests[index].1(repairedAccounts)
            requests[index].2(0, "")
            precondition(inventory.recoveryProblem == nil && inventory.canMutate)
            precondition(inventory.pendingReady && !inventory.ready && !inventory.canKeepLocal)
            precondition(inventory.note.isEmpty && inventory.lines.elementsEqual(previousLines, by: ==))
            precondition(inventory.symbol == "clock.arrow.circlepath" && inventory.badge.isEmpty)
            precondition(inventory.restartAvailable == populated)
            precondition(inventory.detailLines.elementsEqual(previousLines, by: ==))
            precondition(inventory.displaySummary == "The last move was interrupted.")
            inventory.finishPending()
            precondition(requests.last!.0 == ["finish", "--json"] && inventory.running)
        }
        requests = []
        let taskRecovery = Model(demo: try! JSONDecoder().decode([Account].self, from: fixtureData("TASK_RECOVERY_ACCOUNTS")))
        precondition(taskRecovery.pendingReady && !taskRecovery.ready && !taskRecovery.canKeepLocal)
        precondition(taskRecovery.pendingButtonTitle == "Finish the move")
        precondition(taskRecovery.pendingPrompt == "The last move was interrupted.")
        taskRecovery.skipRestartWarning = true
        taskRecovery.finishPending()
        precondition(requests[0].0 == ["finish", "--json"])
        requests[0].1(#"{"plan":true,"kind":"recover","token":"task-recovery-token","affected":[]}"#)
        requests[0].2(0, "")
        precondition(requests[1].0 == ["finish", "--json", "--restart-approved", "task-recovery-token"])
        requests = []
        let recovering = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(accountResponse(true).utf8)))
        recovering.finishPending()
        precondition(requests[0].0 == ["finish", "--json"])
        requests[0].2(1, "Sign Claude Desktop into Personal")
        requests[1].1(accountResponse(true))
        requests[1].2(0, "")
        precondition(recovering.note == "Move stopped: the operation did not complete." && recovering.pendingReady)
        recovering.refresh()
        requests[2].1(accountResponse(false))
        requests[2].2(0, "")
        precondition(recovering.note == "Move stopped: the operation did not complete.")
        func sweepReply(_ model: Model, _ event: String) {
            let index = requests.count
            model.checkSweep()
            requests[index].1(event)
            requests[index].2(0, "")
        }
        let cleanSweep = #"{"swept":true,"ok":true,"complete":true,"receipt":"receipt-one"}"#
        let repeated = Model(demo: Demo.accounts)
        let repeatError = #"{"swept":true,"ok":false,"error":"Repeated error","receipt":"receipt-one"}"#
        sweepReply(repeated, repeatError)
        sweepReply(repeated, repeatError)
        precondition(repeated.note == "The remaining work needs attention")
        precondition(repeated.lines.filter { $0.0 == "background" }.count == 1)
        let retryIndex = requests.count
        repeated.checkSweep()
        requests[retryIndex].1(#"{"stage":"cloud scan","live":true,"completed":0,"total":1,"sourceId":"fixture","sourceLabel":"Fixture"}"#)
        precondition(repeated.lines.filter { $0.0 == "previous check" }.count == 1)
        precondition(repeated.lines.allSatisfy { $0.0 != "background" })
        requests[retryIndex].1(cleanSweep)
        requests[retryIndex].2(0, "")
        precondition(repeated.note.isEmpty)
        precondition(repeated.lines.allSatisfy { !["background", "previous check"].contains($0.0) })
        sweepReply(recovering, #"{"swept":true,"ok":false,"error":"Could not check source","receipt":"receipt-one"}"#)
        precondition(recovering.note == "The remaining work needs attention")
        sweepReply(recovering, cleanSweep)
        precondition(recovering.note == "No remaining work" && !recovering.pendingReady)
        precondition(recovering.lines.isEmpty && recovering.to == nil && recovering.from.isEmpty)
        func failedFinishModel(_ typed: Bool = false) -> Model {
            requests = []
            let model = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(accountResponse(true).utf8)))
            model.finishPending()
            if typed { requests[0].1(#"{"done":true,"ok":false,"code":"COMMAND_FAILED","reason":"Synthetic command failure"}"#) }
            requests[0].2(1, "Sign Claude Desktop into Personal")
            requests[1].1(accountResponse(false))
            requests[1].2(0, "")
            return model
        }
        for typed in [false, true] {
            let completed = failedFinishModel(typed)
            precondition(completed.note == "Move stopped: the operation did not complete.")
            sweepReply(completed, cleanSweep)
            precondition(completed.note == "No remaining work" && completed.lines.isEmpty)
            for event in [
                #"{"swept":true,"ok":false,"receipt":"receipt-one"}"#,
                #"{"swept":true,"ok":true,"complete":false,"receipt":"receipt-one"}"#,
                #"{"swept":true,"ok":true,"complete":true,"receipt":"another-receipt"}"#,
                #"{"swept":true,"ok":true,"complete":true,"receipt":"receipt-one","failed":[{"id":"fixture","error":"Unmoved history"}]}"#,
                #"{"swept":true,"ok":true,"complete":true,"receipt":"receipt-one","problems":[{"id":"fixture","check":"transcript"}]}"#,
                #"{"swept":true,"ok":true,"complete":true,"receipt":"receipt-one","changed":[{"id":"fixture","fields":["record unavailable"]}]}"#
            ] {
                let guarded = failedFinishModel(typed)
                sweepReply(guarded, event)
                precondition(guarded.note != "No remaining work")
                sweepReply(guarded, cleanSweep)
                precondition(guarded.note == "No remaining work")
            }
            let corrupt = failedFinishModel(typed)
            sweepReply(corrupt, #"{"swept":true,"ok":false,"error":"Corrupt receipt set aside"}"#)
            sweepReply(corrupt, #"{"swept":true,"ok":true,"complete":true,"receipt":"older-receipt"}"#)
            precondition(corrupt.note == "The remaining work needs attention")
            let restart = failedFinishModel(typed)
            sweepReply(restart, #"{"swept":true,"ok":true,"complete":true,"receipt":"receipt-one","restart":true}"#)
            let hint = restart.note
            sweepReply(restart, cleanSweep)
            precondition(restart.restartAvailable && restart.note == hint)
        }
        for errors in ["[]", #"[{"id":"fixture","title":"Unmoved session","error":"conflicting history"}]"#] {
            requests = []
            let idle = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(accountResponse(true).utf8)))
            idle.finishPending()
            requests[0].1("{\"nothing\":true,\"failed\":" + errors + "}")
            requests[0].2(0, "")
            requests[1].1(accountResponse(false))
            requests[1].2(0, "")
            precondition(idle.badge.isEmpty && idle.visibleCompletion == nil)
            precondition(idle.note == (errors == "[]" ? "No remaining work" : "1 session was not moved"))
            precondition(idle.symbol == (errors == "[]" ? "arrow.left.arrow.right" : "info.circle"))
            precondition(errors == "[]" || idle.lines.contains { $0.1.contains("conflicting history") })
        }
        requests = []
        let failed = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(accountResponse(true).utf8)))
        failed.finishPending()
        requests[0].1("{\"done\":true,\"ok\":false,\"complete\":true,\"failed\":[{\"id\":\"fixture\",\"title\":\"Unmoved session\",\"error\":\"conflicting history\"}]}")
        requests[0].2(1, "")
        requests[1].1(accountResponse(false))
        requests[1].2(0, "")
        precondition(failed.note == "Move stopped: the operation did not complete.")
        precondition(failed.lines.contains { $0.1.contains("conflicting history") })
        requests = []
        let completedCloud = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(accountResponse(true).utf8)))
        completedCloud.finishPending()
        requests[0].1(#"{"done":true,"ok":true,"complete":true,"moved":1,"failed":[],"notMoved":[{"id":"fixture","title":"Earlier refusal","error":"task family missing"}]}"#)
        requests[0].2(0, "")
        requests[1].1(accountResponse(false))
        requests[1].2(0, "")
        precondition(!completedCloud.note.contains("attention"))
        precondition(completedCloud.lines.contains { $0.0 == "not moved" && $0.1.contains("task family missing") })
        let summary = #"{"moved":233,"notMoved":["# + Array(repeating: #"{"id":"fixture","error":"history refused"}"#, count: 10).joined(separator: ",") + #"],"groups":[{"cause":"history check","records":[{"id":"fixture","error":"history refused"}]},{"cause":"waiting on parent","records":[]},{"cause":"task collision","records":[]}],"attention":[]}"#
        let refusals = Model(demo: Demo.accounts)
        refusals.handle(#"{"done":true,"ok":false,"complete":true,"summary":"# + summary + "}")
        precondition(refusals.note == "233 moved. 10 sessions were not moved.")
        precondition(refusals.lines.map(\.0) == ["history check", "waiting on parent", "task collision"])
        var receiptAccounts = Demo.accounts
        for at in receiptAccounts.indices {
            receiptAccounts[at].receipt = "one-receipt"
            receiptAccounts[at].receiptSummary = try! JSONDecoder().decode(ReceiptSummary.self, from: Data(summary.utf8))
        }
        let refreshedRefusals = Model(demo: receiptAccounts)
        precondition(refreshedRefusals.receiptSummaries.count == 1)
        precondition(refreshedRefusals.pendingPrompt == "233 moved. 10 sessions were not moved.")
        precondition(!refreshedRefusals.pendingReady)
        sweepReply(refreshedRefusals, #"{"swept":true,"ok":true,"complete":true,"summary":"# + summary + "}")
        precondition(refreshedRefusals.note == "233 moved. 10 sessions were not moved.")
        let recoveredCloud = failedFinishModel()
        sweepReply(recoveredCloud, #"{"swept":true,"ok":true,"complete":true,"receipt":"receipt-one","failed":[],"notMoved":[{"id":"fixture","error":"task family missing"}]}"#)
        precondition(recoveredCloud.note == "No remaining work")
        let wording = try! JSONSerialization.jsonObject(with: fixtureData("WORDING_FIXTURES")) as! [[String: Any]]
        func wordingAccounts(_ name: String) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: wording.first { $0["name"] as? String == name }!["accounts"]!), encoding: .utf8)!
        }
        func refreshReply(_ model: Model, _ accounts: String) {
            let index = requests.count
            model.refresh()
            precondition(requests[index].0 == ["accounts", "--json"])
            requests[index].1(accounts)
            requests[index].2(0, "")
        }
        for (name, reason) in [("46-history-limit", "1,000,000 events"), ("47-budget-limit", "memory budget"), ("48-parser-limit", "history reader's limit")] {
            let limited = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts(name).utf8)))
            precondition(limited.displaySummary.contains(reason))
            precondition(!limited.pendingReady && limited.primaryTitle == nil && limited.canKeepLocal && limited.screen == .blocked)
            if name == "48-parser-limit" { precondition(limited.detailLines.contains { $0.1.contains("CLOUD_PARSER_LIMIT") }) }
        }
        for completedReceipt in ["synthetic-receipt", "another-receipt"] {
            requests = []
            let resolved = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts("17-uncertain").utf8)))
            sweepReply(resolved, #"{"swept":true,"ok":true,"complete":false,"issues":0,"restart":true,"moved":2,"receipt":"synthetic-receipt"}"#)
            let notice = resolved.note
            sweepReply(resolved, #"{"swept":true,"ok":false,"complete":false,"issues":1,"error":"Synthetic cloud failure","receipt":"synthetic-receipt"}"#)
            precondition(resolved.restartAvailable && resolved.symbol == "exclamationmark.triangle")
            refreshReply(resolved, wordingAccounts("01-done"))
            precondition(resolved.pendingAccounts.isEmpty)
            sweepReply(resolved, #"{"swept":true,"ok":true,"complete":true,"issues":0,"receipt":""# + completedReceipt + #""}"#)
            if completedReceipt == "another-receipt" {
                precondition(resolved.symbol == "exclamationmark.triangle")
                precondition(resolved.detailLines.contains { $0.1.contains("Synthetic cloud failure") })
                sweepReply(resolved, #"{"swept":true,"ok":true,"complete":true,"issues":0,"receipt":"synthetic-receipt"}"#)
            }
            precondition(resolved.restartAvailable && resolved.symbol == "info.circle" && resolved.note == notice)
            precondition(!resolved.detailLines.contains { $0.1.contains("Synthetic cloud failure") })
        }
        automaticRefreshFixture = true
        for outcome in [
            #"{"swept":true,"ok":true,"complete":false}"#,
            #"{"swept":true,"ok":false,"error":"Incomplete bounded check","failed":[{"code":"CLOUD_ARTIFACT_BUDGET","error":"Incomplete bounded check"}]}"#,
            #"{"swept":true,"ok":true,"complete":true,"moved":12,"restart":true}"#
        ] {
            requests = []
            let item = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts("01-done").utf8)))
            item.begin()
            item.handle(#"{"done":true,"ok":true,"complete":false,"moved":361,"pendingCloud":1}"#)
            item.checkFinish(0)
            precondition(requests[0].0 == ["accounts", "--json"])
            requests[0].1(wordingAccounts("17-uncertain"))
            requests[0].2(0, "")
            precondition(item.displaySummary.contains("will retry automatically") && item.primaryTitle == nil)
            precondition(requests[1].0 == ["sweep", "--json"])
            requests[1].1(outcome)
            requests[1].2(0, "")
            if outcome.contains("\"restart\":true") {
                precondition(item.restartAvailable && item.note == "Moved 12 more sessions. Restart Claude to see them.")
                precondition(item.symbol == "info.circle" && item.badge.isEmpty && !item.running)
                refreshReply(item, wordingAccounts("01-done"))
                precondition(item.restartAvailable && item.note.contains("Moved 12 more sessions"))
                precondition(item.symbol == "info.circle")
                sweepReply(item, #"{"swept":true,"ok":true,"complete":true,"issues":0}"#)
                precondition(item.restartAvailable && item.symbol == "info.circle")
                item.selectTarget("work/personal")
                precondition(item.primaryTitle == "Move")
                precondition(!item.restartAvailable && item.symbol == "arrow.left.arrow.right")
            } else {
                precondition(item.displaySummary.contains("will retry automatically") && item.primaryTitle == nil)
                if outcome.contains("Incomplete bounded check") { precondition(item.detailLines.contains { $0.1.contains("Incomplete bounded check") }) }
            }
        }
        for failed in [false, true] {
            requests = []
            let partial = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts("17-uncertain").utf8)))
            let target = partial.to, sources = partial.from
            if failed { sweepReply(partial, #"{"swept":true,"ok":false,"error":"Synthetic pending failure"}"#) }
            sweepReply(partial, #"{"swept":true,"ok":true,"complete":false,"issues":0,"restart":true,"moved":2}"#)
            let notice = partial.note
            precondition(partial.restartAvailable && notice.contains("Restart Claude"))
            refreshReply(partial, wordingAccounts("17-uncertain"))
            precondition(partial.restartAvailable && partial.note == notice && partial.to == target && partial.from == sources)
            precondition(requests.last!.0 == ["sweep", "--json"])
            requests.last!.1(#"{"swept":true,"ok":true,"complete":false,"issues":0}"#)
            requests.last!.2(0, "")
            precondition(partial.restartAvailable && partial.note == notice && partial.symbol == (failed ? "exclamationmark.triangle" : "info.circle"))
            partial.selectTarget("work/personal")
            precondition(!partial.restartAvailable && partial.note.isEmpty)
            if !failed { precondition(partial.symbol == "arrow.left.arrow.right") }
        }
        for failed in [false, true] {
            requests = []
            let item = Model(demo: Demo.accounts)
            item.selectTarget(Demo.accounts[2].id)
            let selected = item.to, sources = item.from
            item.panelVisibility(false)
            if failed { item.symbol = "exclamationmark.triangle" }
            sweepReply(item, #"{"swept":true,"ok":true,"complete":false,"issues":0,"restart":true,"moved":1}"#)
            precondition(item.restartAvailable && item.symbol == (failed ? "exclamationmark.triangle" : "info.circle"))
            precondition(item.to == selected && item.from == sources && !item.running)
            let count = requests.count
            sweepReply(item, #"{"swept":true,"ok":true,"complete":false,"issues":0,"restart":true}"#)
            precondition(requests.count == count + 1 && requests.last!.0 == ["sweep", "--json"])
            precondition(item.symbol == (failed ? "exclamationmark.triangle" : "info.circle"))
            sweepReply(item, #"{"swept":true,"ok":false,"error":"Synthetic failure"}"#)
            precondition(item.symbol == "exclamationmark.triangle")
        }
        for blocked in [false, true] {
            let model = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts("10-interrupted").utf8)))
            let code = blocked ? "LOCAL_RECOVERY_BLOCKED" : ""
            model.restartAvailable = true
            model.handle(#"{"done":true,"ok":false,"recoveryRequired":true,"code":""# + code + #"","reconciled":{"title":"Unfinished copies","error":"interrupted finalization rolled back"}}"#)
            if blocked {
                precondition(!model.canMutate && !model.canKeepLocal && model.primaryTitle == nil)
            } else {
                precondition(model.detailLines.contains { $0.0 == "recovered" && $0.1.contains("Unfinished copies") })
                precondition(model.note.contains("Press Finish the move to continue.") && !model.restartAvailable)
                precondition(model.primaryTitle == "Finish the move" && model.canMutate)
            }
        }
        let undoActions = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts("26-undo-ready").utf8)))
        precondition(undoActions.primaryTitle == "Finish undo" && undoActions.links.isEmpty)
        let freshActions = Model(demo: Demo.accounts)
        precondition(freshActions.primaryTitle == "Move" && freshActions.links.isEmpty)
        freshActions.skipRestartWarning = true
        precondition(freshActions.links.map(\.title) == ["Show restart warnings"])
        freshActions.links[0].action()
        precondition(!freshActions.skipRestartWarning && freshActions.links.isEmpty)
        requests = []
        let cloudMove = Model(demo: Demo.accounts)
        precondition(!cloudMove.cloudMoves && cloudMove.showsCloudToggle)
        cloudMove.skipRestartWarning = true
        cloudMove.cloudMoves = true
        precondition(fixtureDefaults.bool(forKey: "cloudMoves"))
        cloudMove.primary()
        precondition(requests.count == 1 && requests[0].0.suffix(2) == ["--cloud", "--json"] && cloudMove.running)
        precondition(!cloudMove.moveProgress.skipped.contains("cloud") && !cloudMove.moveProgress.skipped.contains("cloudScan") && !cloudMove.showsCloudToggle)
        cloudMove.cloudMoves = false
        precondition(!fixtureDefaults.bool(forKey: "cloudMoves"))
        requests = []
        let login = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts("12-undo-pending").utf8)))
        precondition(login.undoPending && !login.pendingReady && login.primaryTitle == nil)
        precondition(login.pendingPrompt.contains("Sign Claude in as home@example.test.") && login.screen == .signIn)
        login.finishPending()
        login.undo()
        precondition(requests.isEmpty)
        refreshReply(login, wordingAccounts("26-undo-ready"))
        precondition(login.pendingReady && login.primaryTitle == "Finish undo" && !login.pendingPrompt.contains("Sign Claude"))
        precondition(requests[1].0 == ["sweep", "--json"])
        requests[1].1(#"{"swept":true,"ok":true,"complete":false}"#)
        requests[1].2(0, "")
        precondition(login.primaryTitle == "Finish undo")
        login.primary()
        precondition(requests.last!.0 == ["finish", "--json"])
        requests = []
        let queuedLeave = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts("46-history-limit").utf8)))
        queuedLeave.checkSweep()
        let tokens = queuedLeave.scopedChecks
        precondition(tokens.count == 1 && queuedLeave.canKeepLocal)
        queuedLeave.stopHere()
        precondition(requests.count == 1 && queuedLeave.running)
        requests[0].1(#"{"swept":true,"ok":true,"complete":false}"#)
        requests[0].2(0, "")
        precondition(requests[1].0 == ["keep-local", "--json"] + tokens.flatMap { ["--leave-check", $0] })
        requests[1].1(#"{"done":true,"ok":true,"complete":false,"moved":259,"keptLocal":1,"heldCancelled":0}"#)
        requests[1].2(0, "")
        precondition(queuedLeave.visibleCompletion == nil)
        requests[2].1(wordingAccounts("02-held"))
        requests[2].2(0, "")
        precondition(queuedLeave.primaryTitle == "Restart Claude and move 102")
        precondition(queuedLeave.displaySummary == "259 moved. 102 more need Claude to restart.")
        automaticRefreshFixture = false
        for fits in [false, true, nil] as [Bool?] {
            for response in [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn, .alertThirdButtonReturn] {
                requests = []
                restartDialogs = []
                restartDialogResponse = (response, false)
                let item = Model(demo: Demo.accounts)
                item.skipRestartWarning = true
                item.move()
                let args = requests[0].0
                requests[0].1(#"{"plan":true,"kind":"move","token":"capacity-token","capacity":{"fits":"# + (fits.map { $0 ? "true" : "false" } ?? "null") + #"},"heldCount":3}"#)
                requests[0].2(0, "")
                precondition(restartDialogs.isEmpty)
                precondition(requests.last!.0 == args + ["--restart-approved", "capacity-token"])
            }
        }
        for refresh in [false, true] {
            let accounts = try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts("49-local-partial").utf8))
            let partial = Model(demo: accounts)
            if !refresh {
                partial.handle(#"{"done":true,"ok":false,"complete":false,"partial":true,"summary":{"moved":272,"notMoved":[{"title":"One","error":"failed"},{"title":"Two","error":"failed"},{"title":"Three","error":"failed"}],"groups":[],"attention":[]}}"#)
            }
            precondition(partial.primaryTitle == nil && partial.canKeepLocal && partial.screen == .blocked)
            precondition(partial.sourceTag(partial.pendingAccounts[0]) == "not moved")
            precondition(partial.displaySummary.contains("3 sessions remain"))
            precondition(partial.visibleCompletion == nil)
        }
        for fixture in ["02-held", "31-mixed-unreadable-and-waiting"] {
            let accounts = try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts(fixture).utf8))
            let partial = Model(demo: accounts), primary = partial.primaryTitle
            let event: [String: Any] = ["done": true, "ok": false, "complete": false, "partial": true, "heldCount": fixture == "02-held" ? 102 : 0,
                "pendingCloud": fixture == "02-held" ? 0 : 3, "summary": ["moved": 272, "notMoved": [["title": "One", "error": "failed"]], "groups": [], "attention": []]]
            partial.handle(String(data: try! JSONSerialization.data(withJSONObject: event), encoding: .utf8)!)
            precondition(primary != nil && partial.primaryTitle == primary)
            precondition(!partial.displaySummary.contains("Keep moved sessions or undo this move."))
            refreshReply(partial, wordingAccounts(fixture))
            precondition(partial.primaryTitle == primary)
            let relaunched = Model(demo: accounts)
            precondition(relaunched.primaryTitle == primary)
        }
        restartDialogResponse = (.alertThirdButtonReturn, false)
        let moveArgs = ["--from", "work personal", "--to", "work company", "--json"]
        let emptyAccounts = try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts("01-done").utf8))
        let heldAccounts = try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts("02-held").utf8))
        func completedAccountResponse(_ receipt: String) -> String {
            let rows = try! JSONSerialization.jsonObject(with: Data(wordingAccounts("01-done").utf8)) as! [[String: Any]]
            return String(data: try! JSONSerialization.data(withJSONObject: rows.map { $0.merging(["receipt": receipt]) { _, new in new } }), encoding: .utf8)!
        }
        let completedAccounts = try! JSONDecoder().decode([Account].self, from: Data(completedAccountResponse("synthetic-receipt").utf8))
        var changedAccounts = heldAccounts
        for index in changedAccounts.indices { changedAccounts[index].receipt = "different-receipt" }
        let routes: [(String, [String], [Account], String?, [String]?)] = [
            ("receipt", moveArgs, heldAccounts, "synthetic-receipt", ["finish", "--json"]),
            ("pending", moveArgs, heldAccounts, nil, ["finish", "--json"]),
            ("fresh", moveArgs, emptyAccounts, nil, moveArgs),
            ("completed", moveArgs, completedAccounts, "synthetic-receipt", ["finish", "--json"]),
            ("undo", ["undo", "--json"], emptyAccounts, "synthetic-receipt", ["undo", "--json"]),
            ("restart", ["restart", "--json"], emptyAccounts, "synthetic-receipt", ["restart", "--json"]),
            ("changed receipt", moveArgs, changedAccounts, "synthetic-receipt", nil)
        ]
        for code in ["RESTART_PLAN_CHANGED", "RESTART_APPROVAL_CHANGED", "REOPEN_FAILED", "QUIT_UNCONFIRMED"] {
            for (name, args, accounts, receipt, expected) in routes {
                requests = []
                restartDialogs = []
                let item = Model(demo: accounts)
                item.skipRestartWarning = true
                item.checkOperation(args + ["--restart-approved", "obsolete-token"])
                item.begin()
                var event: [String: Any] = ["done": true, "ok": false, "complete": name == "completed", "code": code, "heldCount": ["fresh", "completed"].contains(name) ? 0 : 3, "retryable": true]
                if let receipt { event["receipt"] = receipt }
                item.handle(String(data: try! JSONSerialization.data(withJSONObject: event), encoding: .utf8)!)
                item.checkFinish(1)
                let count = requests.count
                if expected == nil {
                    precondition(item.primaryTitle == nil, code + name)
                    item.primary()
                    precondition(requests.count == count)
                } else {
                    precondition(item.primaryTitle != nil, code + name)
                    item.primary()
                    precondition(requests.last!.0 == expected!, code + name)
                    precondition(!requests.last!.0.contains("--restart-approved"))
                    if code == "RESTART_PLAN_CHANGED" || code == "RESTART_APPROVAL_CHANGED" {
                        let kind = args.first == "undo" ? "undo" : args.first == "restart" ? "refresh" : "move"
                        requests.last!.1(#"{"plan":true,"kind":"# + "\"" + kind + #"","token":"fresh-token"}"#)
                        requests.last!.2(0, "")
                        precondition(restartDialogs.count == 1, code + name)
                        precondition(!requests.contains { $0.0.contains("--restart-approved") })
                    }
                }
            }
        }
        requests = []
        let staleAccounts = try! JSONDecoder().decode([Account].self, from: Data(completedAccountResponse("old.json").utf8))
        let refreshed = Model(demo: staleAccounts)
        refreshed.checkOperation(moveArgs)
        refreshed.begin()
        refreshed.handle(#"{"done":true,"ok":false,"complete":false,"receipt":"new.json","heldCount":3,"code":"RESTART_PLAN_CHANGED"}"#)
        refreshed.checkFinish(1)
        precondition(refreshed.primaryTitle == nil)
        let count = requests.count
        refreshed.primary()
        precondition(requests.count == count)
        requests[0].1(completedAccountResponse("new.json"))
        requests[0].2(0, "")
        for event in [
            #"{"swept":true,"ok":true,"complete":true,"receipt":"old.json"}"#,
            #"{"swept":true,"ok":true,"complete":false,"receipt":"new.json"}"#,
            #"{"swept":true,"ok":true,"complete":true,"receipt":"new.json","problems":[{"check":"transcript"}]}"#
        ] {
            sweepReply(refreshed, event)
            precondition(refreshed.note.contains("Different chats are open now."))
        }
        sweepReply(refreshed, #"{"swept":true,"ok":true,"complete":true,"receipt":"new.json"}"#)
        precondition(refreshed.note == "No remaining work" && refreshed.primaryTitle == nil)
        requests = []
        let actual = try! JSONSerialization.jsonObject(with: fixtureData("ACTUAL_CONTINUATION")) as! [String: Any]
        let actualAccounts = try! JSONDecoder().decode([Account].self, from: JSONSerialization.data(withJSONObject: actual["accounts"]!))
        let actualModel = Model(demo: actualAccounts)
        actualModel.checkOperation(actual["args"] as! [String])
        actualModel.begin()
        actualModel.handle(actual["event"] as! String)
        actualModel.checkFinish(1)
        precondition(actualModel.primaryTitle == "Restart Claude and move")
        actualModel.primary()
        precondition(requests.last!.0 == ["finish", "--json"])
        print("CONTINUATION_COMMAND " + String(data: try! JSONSerialization.data(withJSONObject: requests.last!.0), encoding: .utf8)!)
        requests = []
        let veto = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts("02-held").utf8)))
        veto.checkOperation(["--from", "work personal", "--to", "work company", "--json"])
        veto.begin()
        veto.handle(#"{"done":true,"ok":false,"complete":false,"receipt":"synthetic-receipt","moved":259,"heldCount":102,"code":"QUIT_UNCONFIRMED","retryable":true}"#)
        veto.checkFinish(1)
        requests[0].1(wordingAccounts("02-held"))
        requests[0].2(0, "")
        precondition(veto.note == "259 moved. Move stopped: Claude did not confirm it had closed.")
        veto.primary()
        precondition(requests.last!.0 == ["finish", "--json"])
        for fixture in ["34-same-login-undo", "35-local-undo-recovery"] {
            requests = []
            let undo = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts(fixture).utf8)))
            precondition(undo.pendingReady && undo.primaryTitle == "Finish undo")
            sweepReply(undo, #"{"swept":true,"ok":true,"complete":false}"#)
            precondition(requests.count == 1 && undo.primaryTitle == "Finish undo")
            undo.primary()
            precondition(requests.last!.0 == ["finish", "--json"])
        }
        for background in [false, true] {
            requests = []
            let failed = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts("34-same-login-undo").utf8)))
            if background {
                failed.checkOperation(["undo", "--json"])
                sweepReply(failed, #"{"swept":true,"ok":false,"code":"REOPEN_FAILED","receipt":"synthetic-receipt","error":"Synthetic reopen failure"}"#)
            } else {
                failed.finishPending()
                requests[0].1(#"{"done":true,"ok":false,"code":"REOPEN_FAILED","error":"Synthetic reopen failure"}"#)
                requests[0].2(1, "")
                requests[1].1(wordingAccounts("01-done"))
                requests[1].2(0, "")
            }
            if background { refreshReply(failed, wordingAccounts("01-done")) }
            for event in [
                #"{"swept":true,"ok":true,"complete":false,"receipt":"synthetic-receipt"}"#,
                #"{"swept":true,"ok":true,"complete":true,"receipt":"another-receipt"}"#,
                #"{"swept":true,"ok":true,"complete":true,"receipt":"synthetic-receipt","problems":[{"check":"transcript"}]}"#
            ] {
                sweepReply(failed, event)
                precondition(failed.note.contains("Open Claude, then press Try again."))
            }
            let count = requests.count
            precondition(failed.note.contains("Open Claude, then press Try again.") && failed.primaryTitle == "Try again")
            precondition(!failed.running && !failed.restartAvailable)
            failed.primary()
            precondition(requests.count == count + 1 && requests.last!.0 == ["finish", "--json"])
        }
        requests = []
        let delayed = Model(demo: Demo.accounts)
        delayed.handle(#"{"done":true,"ok":true,"complete":true,"moved":1}"#)
        delayed.checkFinish(0)
        sweepReply(delayed, #"{"swept":true,"ok":true,"complete":true,"issues":0,"restart":true}"#)
        precondition(delayed.symbol == "info.circle" && delayed.badge.isEmpty)
        let failedWithoutRestart = Model(demo: Demo.accounts)
        failedWithoutRestart.checkFinish(1)
        let failedWithRestart = Model(demo: Demo.accounts)
        failedWithRestart.checkFinish(1)
        sweepReply(failedWithRestart, #"{"swept":true,"ok":true,"complete":true,"issues":0,"restart":true}"#)
        precondition(failedWithoutRestart.symbol == "exclamationmark.triangle" && !failedWithoutRestart.restartAvailable)
        precondition(failedWithRestart.symbol == "exclamationmark.triangle" && failedWithRestart.restartAvailable)
        for action in badgeResets { action() }
        badgeResets = []
        precondition(delayed.restartAvailable && delayed.symbol == "info.circle" && delayed.badge.isEmpty)
        precondition(failedWithoutRestart.symbol == "arrow.left.arrow.right" && failedWithoutRestart.badge.isEmpty)
        precondition(failedWithRestart.symbol == "exclamationmark.triangle" && failedWithRestart.badge.isEmpty)
        fixtureDefaults.values = [:]
        requests = []
        let done = "Done. 499 sessions are now in work@example.test · Personal."
        func recordedAt(_ stamp: String) -> String { wordingAccounts("51-recorded-result").replacingOccurrences(of: "2026-10-30T21-00-00-000", with: stamp) }
        func recordedModel(_ stamp: String) -> Model { Model(demo: try! JSONDecoder().decode([Account].self, from: Data(recordedAt(stamp).utf8))) }
        let background = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts("01-done").utf8)))
        background.selectTarget("work/personal")
        notices = []
        background.begin()
        background.handle(#"{"done":true,"ok":true,"complete":false,"moved":499,"pendingCloud":1}"#)
        background.checkFinish(0)
        requests[0].1(wordingAccounts("17-uncertain"))
        requests[0].2(0, "")
        precondition(background.visibleCompletion == nil && background.primaryTitle == nil && background.symbol == "clock.arrow.circlepath")
        refreshReply(background, recordedAt("2026-10-30T21-00-00-000"))
        precondition(background.visibleCompletion?.summary == done && background.visibleCompletion?.detail == "History verified" && background.screen == .moved)
        precondition(background.from.isEmpty && background.to == nil && background.symbol == "arrow.left.arrow.right")
        background.selectTarget("home/personal")
        precondition(background.primaryTitle == "Move" && background.visibleCompletion?.summary == done)
        background.panelVisibility(false)
        background.panelVisibility(true)
        requests.last!.1(recordedAt("2026-10-30T21-00-00-000"))
        requests.last!.2(0, "")
        precondition(background.visibleCompletion?.summary == done && background.primaryTitle == "Move")
        precondition(notices == ["499 moved. Checking the remaining source conversations.", done])
        let relaunched = recordedModel("2026-10-30T21-00-00-000")
        precondition(relaunched.visibleCompletion?.summary == done && relaunched.links.map(\.title) == ["Undo last move"])
        relaunched.reset()
        requests.last!.1(recordedAt("2026-10-30T21-00-00-000"))
        requests.last!.2(0, "")
        precondition(relaunched.visibleCompletion == nil && recordedModel("2026-10-30T21-00-00-000").visibleCompletion == nil)
        precondition(recordedModel("2026-10-31T09-00-00-000").visibleCompletion?.summary == done)
        let undoing = recordedModel("2026-11-01T09-00-00-000")
        undoing.links[0].action()
        precondition(requests.last!.0 == ["undo", "--json"] && undoing.running)
        requests.last!.1(#"{"undone":"2026-11-01T09-00-00-000","restored":1,"sessions":1}"#)
        requests.last!.2(0, "")
        precondition(undoing.visibleCompletion == nil && undoing.note.hasPrefix("Undo complete.") && recordedModel("2026-10-31T09-00-00-000").visibleCompletion == nil)
        requests.last!.1(recordedAt("2026-10-31T09-00-00-000"))
        requests.last!.2(0, "")
        precondition(undoing.links.isEmpty && recordedModel("2026-10-31T09-00-00-000").links.isEmpty)
        let next = recordedModel("2026-11-02T09-00-00-000")
        precondition(next.visibleCompletion?.summary == done && next.links.map(\.title) == ["Undo last move"])
        next.selectTarget("home/personal")
        next.move()
        precondition(next.visibleCompletion == nil && requests.last!.0.contains("--from"))
        requests.last!.2(1, "Synthetic move failure")
        requests.last!.1(recordedAt("2026-11-02T09-00-00-000"))
        requests.last!.2(0, "")
        precondition(next.visibleCompletion == nil && recordedModel("2026-11-02T09-00-00-000").visibleCompletion == nil)
        let cleared = recordedModel("2026-11-02T09-00-00-000")
        cleared.reset()
        requests.last!.1(recordedAt("2026-11-02T09-00-00-000"))
        requests.last!.2(0, "")
        precondition(cleared.links.map(\.title) == ["Undo last move"])
        requests = []
        notices = []
        let signIn = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts("01-done").utf8)))
        signIn.selectTarget("work/personal")
        signIn.begin()
        signIn.handle(#"{"done":true,"ok":true,"complete":false,"moved":499,"pendingCloud":1}"#)
        signIn.checkFinish(0)
        requests[0].1(wordingAccounts("05-other-login"))
        requests[0].2(0, "")
        precondition(signIn.movable && notices.count == 1)
        refreshReply(signIn, recordedAt("2026-11-03T09-00-00-000"))
        precondition(notices.count == 2 && notices[1] == done)
        let partialLeave = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts("05-other-login").utf8)))
        partialLeave.handle(#"{"done":true,"ok":false,"complete":false,"partial":true,"pendingCloud":1,"summary":{"moved":272,"notMoved":[{"id":"fixture","error":"failed"}],"groups":[],"attention":[]}}"#)
        precondition(!partialLeave.movable && partialLeave.primaryTitle == nil)
        requests = []
        notices = []
        let leaving = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts("05-other-login").utf8)))
        precondition(leaving.primaryTitle == "Leave old copies and move" && leaving.movable)
        leaving.selectTarget("home/personal")
        leaving.skipRestartWarning = true
        leaving.primary()
        precondition(requests.count == 1 && requests[0].0 == ["keep-local", "--json", "--leave-check", String(repeating: "3", count: 64)])
        requests[0].1(#"{"done":true,"ok":true,"complete":true,"keptLocal":1,"heldCancelled":0}"#)
        requests[0].2(0, "")
        let leaveMove = ["--from", "work company", "--from", "work personal", "--to", "home personal", "--json"]
        precondition(requests.count == 2 && requests[1].0 == leaveMove && leaving.running)
        requests[1].1(#"{"plan":true,"kind":"move","token":"leave-token","affected":[]}"#)
        requests[1].2(0, "")
        precondition(requests.count == 3 && requests[2].0 == leaveMove + ["--restart-approved", "leave-token"])
        requests[2].1(#"{"done":true,"ok":true,"complete":true,"moved":4,"destinationLabel":"home@example.test · Personal","summary":{"moved":4,"notMoved":[],"groups":[],"attention":[],"kept":[]}}"#)
        requests[2].2(0, "")
        precondition(leaving.visibleCompletion?.summary == "Done. 4 sessions are now in home@example.test · Personal.")
        precondition(notices == ["Done. 4 sessions are now in home@example.test · Personal."])
        precondition(leaving.detailLines.filter { $0.1.contains("left unarchived") }.map(\.1) == ["3 old copies left unarchived in home@example.test · Personal"])
        requests = []
        let refusedLeave = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts("05-other-login").utf8)))
        refusedLeave.primary()
        requests[0].1(#"{"refused":[],"code":"PENDING_CHANGED","reason":"The pending source checks changed. Review them again."}"#)
        requests[0].2(1, "")
        precondition(requests.count == 2 && requests[1].0 == ["accounts", "--json"] && !refusedLeave.running && refusedLeave.note == "Remaining work could not be cancelled. Check Details.")
        let waiting = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts("52-waiting-for-claude").utf8)))
        precondition(waiting.statusDetail == "Waiting for Claude." && waiting.primaryTitle == nil)
        precondition(Model(demo: try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts("52-waiting-for-claude").replacingOccurrences(of: #""identityState":"unknown""#, with: #""identityState":"logged-out""#).utf8))).identityLabel == "signed out")
        refreshReply(waiting, wordingAccounts("44-login-retry"))
        precondition(waiting.statusDetail?.hasPrefix("Waiting for Claude to finish signing in.") == true)
        refreshReply(waiting, wordingAccounts("05-other-login"))
        precondition(waiting.statusDetail?.contains("Sign Claude in as home@example.test") == true && waiting.primaryTitle == "Leave old copies and move")
        let ghost = Account(account: "ghost", org: "ghost-org", email: nil, orgName: nil, label: "ghost · ghost-or", active: false, signedIn: false, activeAt: nil, pending: nil, pendingFailures: nil, sessions: 0)
        let crowded = Model(demo: Demo.accounts + [ghost])
        precondition(crowded.visibleAccounts.map(\.id) == Demo.accounts.map(\.id))
        crowded.selectTarget(Demo.accounts[2].id)
        precondition(crowded.from == Set(Demo.accounts.map(\.id)).subtracting([Demo.accounts[2].id]))
        crowded.selectTarget(ghost.id)
        precondition(crowded.visibleAccounts.last?.id == ghost.id)
        let activeGhost = Account(account: "ghost", org: "ghost-org", email: nil, orgName: nil, label: "ghost · ghost-or", active: true, signedIn: true, activeAt: nil, pending: nil, pendingFailures: nil, sessions: 0)
        precondition(Model(demo: [activeGhost] + Demo.accounts.dropFirst()).visibleAccounts.contains { $0.id == ghost.id })
        requests = []
        let checkForUpdates = "Check for updates"
        Updates.shared.available = true
        precondition(!Model(demo: Demo.accounts).links.contains { $0.title == checkForUpdates })
        updatesInSnapshots = true
        let checker = Model(demo: Demo.accounts)
        precondition(checker.links.map(\.title).contains(checkForUpdates))
        checker.update()
        precondition(Updates.shared.checks == 1 && requests.isEmpty)
        let busy = Model(demo: Demo.accounts)
        busy.begin()
        precondition(!busy.links.contains { $0.title == checkForUpdates } && busy.updatesBlocked)
        busy.update()
        precondition(Updates.shared.checks == 1)
        for name in ["17-uncertain", "10-interrupted", "11-repair"] {
            let model = Model(demo: try! JSONDecoder().decode([Account].self, from: Data(wordingAccounts(name).utf8)))
            precondition(!model.links.contains { $0.title == checkForUpdates }, name)
        }
        let blocked = Model(demo: Demo.accounts)
        blocked.handle(#"{"done":true,"ok":false,"complete":false,"partial":true,"summary":{"moved":2,"notMoved":[{"id":"fixture","error":"failed"}],"groups":[],"attention":[]}}"#)
        precondition(blocked.directActions && blocked.pendingAccounts.isEmpty && !blocked.links.contains { $0.title == checkForUpdates })
        Updates.shared.available = false
        precondition(!Model(demo: Demo.accounts).links.contains { $0.title == checkForUpdates })
        print("Swift queue and metadata states passed")
    }
}
