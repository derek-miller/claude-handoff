import Foundation
import Testing
@testable import HandoffCore

extension Engine {
    // Checks of the menu bar app's model and rendering: Sources/ClaudeHandoff/App.swift is spliced so the engine
    // process, Sparkle, UserDefaults and timers are replaced by recorders (Fixtures/MenuBar/Stubs.swift), then
    // compiled with the check programs in Fixtures/MenuBar into one binary per test process.
    @Suite("menu bar")
    struct MenuBar {
        static func arg(_ args: [Value], _ i: Int) -> Value { i < args.count ? args[i] : .undefined }

        static let here = path.dirname(#filePath)
        nonisolated(unsafe) static var built: Result<String, Error>?
        static let lock = NSLock()

        // The checks binary, compiled on first use.
        static func checks() throws -> String {
            lock.lock()
            defer { lock.unlock() }
            if built == nil { built = Result { try compile() } }
            return try built!.get()
        }

        static func replaceOnce(_ source: String, _ anchor: String, _ replacement: String) throws -> String {
            let parts = source.components(separatedBy: anchor)
            guard parts.count == 2 else { throw EngineError("App.swift splice anchor found \(parts.count - 1) times: \(anchor)") }
            return parts.joined(separator: replacement)
        }

        static func replaceSpan(_ source: String, from start: String, to end: String, with replacement: String) throws -> String {
            guard let lower = source.range(of: start), let upper = source.range(of: end, range: lower.upperBound..<source.endIndex) else {
                throw EngineError("App.swift splice span not found: \(start)")
            }
            return source.replacingCharacters(in: lower.lowerBound..<upper.lowerBound, with: replacement)
        }

        static func splicedApp() throws -> String {
            let app = try readText(path.join(here, "../../Sources/ClaudeHandoff/App.swift"))
            guard var source = app.components(separatedBy: "@main\nstruct HandoffApp: App {").first, source.count < app.count else {
                throw EngineError("App.swift has no HandoffApp entry point")
            }
            source = try replaceOnce(source, "import Sparkle\n", "")
            source = try replaceSpan(source, from: "    private func run(_ args: [String]", to: "\n// MenuBarExtra keeps", with: """
                    private func run(_ args: [String], line: @escaping (String) -> Void, done: @escaping (Int32, String) -> Void) {
                        requests.append((args, line, done))
                    }
                    private func launch(_ process: Process, timeout: Bool = false, line: @escaping (String) -> Void = { _ in }, done: @escaping (Int32, String) -> Void) {
                        launches.append((process, done))
                    }
                }

                """)
            source = try replaceSpan(source, from: "    private func restartResponse(_ prompt: RestartPrompt)", to: "    private func cancelRestart", with: """
                    private func restartResponse(_ prompt: RestartPrompt) -> (NSApplication.ModalResponse, Bool) {
                        restartDialogs.append(prompt)
                        return restartDialogResponse
                    }


                """)
            for (anchor, replacement) in [
                ("guard canMutate, !sweeping, !snapshot else { return }", "guard canMutate, !sweeping else { return }"),
                ("if !snapshot && (changed || panelOpen || !pendingAccounts.isEmpty)", "if automaticRefreshFixture && (changed || panelOpen || !pendingAccounts.isEmpty)"),
                ("DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in", "scheduleBadgeReset { [weak self] in"),
                ("if demo || snapshot { return }", "notices.append(title)\n        if demo || snapshot { return }"),
                ("    private let config: Config?", "    var config: Config?"),
                ("private var canUpdate: Bool { !snapshot && ", "private var canUpdate: Bool { (!snapshot || updatesInSnapshots) && "),
                ("static let version = Bundle.main.object(forInfoDictionaryKey: \"CFBundleShortVersionString\") as? String", "static let version: String? = \"4.2.1\""),
            ] {
                source = try replaceOnce(source, anchor, replacement)
            }
            source = source.replacingOccurrences(of: "UserDefaults.standard", with: "fixtureDefaults")
            // Stubs extends Model with wrappers around private members, so it shares the app's file.
            return source + "\n" + (try readText(path.join(here, "Fixtures/MenuBar/Stubs.swift")))
        }

        static func compile() throws -> String {
            let base = NSTemporaryDirectory().replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            let root = try fs.mkdtemp(path.join(base, "ct-menubar-checks-"))
            let app = path.join(root, "App.swift"), binary = path.join(root, "menubar-checks")
            try writeText(app, try splicedApp())
            let sources = ["Main.swift", "WordingChecks.swift", "StateChecks.swift"].map { path.join(here, "Fixtures/MenuBar", $0) }
            let result = ChildProcess.nativeSpawnSync("/usr/bin/nice", ["-n", "15", "/usr/bin/xcrun", "swiftc", "-parse-as-library", "-o", binary, app] + sources,
                                                      SpawnOptions(timeout: 600_000))
            guard result.status == 0 else { throw EngineError("menu bar checks failed to compile: \(result.stderr)\(result.error?.message ?? "")") }
            return binary
        }

        static func run(_ check: String, _ directory: String, timeout: Double = 90_000) throws -> String {
            let result = ChildProcess.nativeSpawnSync(try checks(), [check, directory], SpawnOptions(timeout: timeout))
            guard result.status == 0 else { throw EngineError("menu bar \(check) checks failed (\(result.status.map(String.init) ?? "signal")): \(result.stdout)\(result.stderr)") }
            return result.stdout
        }

        // Account panels for every wording state, with pending state computed by the engine.
        static func wordingFixtures() throws -> Value {
            let base = Value([
                ["account": "work", "org": "company", "email": "work@example.test", "orgName": "Nomad Inc.", "label": "work@example.test · Nomad Inc.", "active": true, "signedIn": true],
                ["account": "work", "org": "personal", "email": "work@example.test", "orgName": "Personal", "label": "work@example.test · Personal", "active": false, "signedIn": true],
                ["account": "home", "org": "personal", "email": "home@example.test", "orgName": "Personal", "label": "home@example.test · Personal", "active": false, "signedIn": false],
            ].enumerated().map { index, row -> Value in .spread(row, ["activeAt": Value(3 - index), "pending": nil, "pendingFailures": [], "identityState": "known"]) })
            func pending(_ index: Int, _ mode: String, _ count: Int, _ code: String? = nil, _ release: String? = nil, _ activeIndex: Int = 0, _ seconds: Value = nil) throws -> Value {
                let rows = Value(base.deepClone().elements.enumerated().map { i, row -> Value in
                    .spread(row, ["active": Value(i == activeIndex), "signedIn": Value(row.account === base[activeIndex].account)])
                })
                let account = rows[index]
                let source: Value = ["account": account.account, "org": account.org, "sessionIds": .strings((0..<count).map { "session_\($0)" })]
                if let code {
                    source.failures = source.sessionIds.map { ["id": $0, "title": "Research conversation", "code": Value(code), "error": Value(code)] }
                }
                if let code, ["CLOUD_HISTORY_LIMIT", "CLOUD_BUDGET_LIMIT", "CLOUD_PARSER_LIMIT"].contains(code) {
                    source.attemptEngine = try artifactEngine()
                    source.attemptBudget = try memoryBudget().signature
                }
                let releaseValue: Value = release.map { Value($0) } ?? .null
                let held: Value = mode == "local" ? Value((0..<count).map { i -> Value in
                    ["id": Value(id(i + 1)), "recordId": Value("local_\(id(i + 1))"), "release": releaseValue, "title": Value("Open chat \(i + 1)"),
                     "sources": [.spread(source, ["file": Value("/synthetic/\(i).json")])]]
                }) : []
                let receipt: Value = ["held": held, "remote": mode == "undo" ? [["id": "cse_0"], ["id": "cse_1"]] : [],
                                      "remoteUndoing": mode == "undo" ? [.spread(source, ["id": "cse_1"])] : []]
                let table: Value = release == "worker"
                    ? Value([desktopFixture()[0]] + held.elements.enumerated().map { i, row in .spread(desktopFixture()[1], ["pid": Value(501 + i), "ids": [row.id]]) })
                    : desktopFixture()
                let presentation = try pendingPresentation(receipt, source, account, Value(mode), table, Value(release == "scheduler"),
                                                           .newMap(held.elements.map { ($0.recordId, seconds) }))
                let fields: Value = ["pending": Value(mode), "pendingFailures": source.failures ?? [], "pendingWaiting": source.waiting ?? [], "receipt": "synthetic-receipt",
                                     "receiptMoved": mode == "local" ? 359 : 361, "receiptDestination": index == 0 ? "work/personal" : "work/company",
                                     "pendingCancel": mode == "cloud" ? Value(String(repeating: String(index + 1), count: 64)) : .null]
                _ = Value.assign(account, fields, presentation, ["pendingRetryAt": nil])
                return rows
            }
            let plan: Value = ["plan": true, "kind": "move", "token": Value(String(repeating: "a", count: 64)), "heldCount": 102, "remainingCount": 102, "moved": 259,
                               "sourceLabels": [base[1].label],
                               "affected": [["pid": 501, "started": "synthetic", "recordId": "local_one", "title": "Research notes"], ["pid": 502, "started": "synthetic", "recordId": "local_two", "title": "Daily brief"]]]
            let capacityPlan = Value.spread(plan, ["ok": false, "code": "RESTART_CAPACITY", "capacity": ["records": 102, "estimatedMs": 26000, "availableMs": 22000, "fits": false]])
            let held = try pending(1, "local", 102, nil, "scheduler")
            held[1].receiptMoved = 259
            let mixed = try pending(2, "cloud", 3)
            mixed[1] = held[1]
            mixed[2].receiptMoved = 259
            let mixedWaiting = try pending(0, "cloud", 2, "CLOUD_HISTORY_UNREADABLE"), mixedAccount = mixedWaiting[0]
            let mixedSource: Value = ["account": mixedAccount.account, "org": mixedAccount.org, "failures": mixedAccount.pendingFailures.slice(0, 1),
                                      "waiting": [["id": "session_1", "title": "Another open conversation", "localId": Value(SOURCE)]]]
            _ = Value.assign(mixedAccount, ["pendingFailures": mixedSource.failures, "pendingWaiting": mixedSource.waiting],
                             try pendingPresentation([:], mixedSource, mixedAccount, "cloud", desktopFixture()))
            let limitAndSignIn = try pending(1, "cloud", 1, "CLOUD_HISTORY_LIMIT")
            limitAndSignIn[2] = try pending(2, "cloud", 3)[2]
            let twoSources = try pending(0, "cloud", 1)
            twoSources[1] = try pending(1, "cloud", 1)[1]
            for row in twoSources.elements where row.pending.truthy { row.receiptDestination = "home/personal" }
            let localUndo = try pending(2, "undo", 1)
            _ = Value.assign(localUndo[2], try pendingPresentation(["undoing": [], "remote": [["id": "cse_one"]]], localUndo[2], localUndo[2], "undo"))
            let partialSummary: Value = ["moved": 272, "notMoved": Value((0..<3).map { i -> Value in
                ["account": "work", "org": "personal", "id": Value(id(i + 1)), "title": Value("Remaining \(i + 1)"), "error": "Synthetic publication failure"]
            }), "groups": [], "attention": []]
            let partial = base.deepClone()
            _ = Value.assign(partial[1], ["pending": "partial", "pendingState": "partial", "pendingAction": "blocked", "pendingCount": 3, "pendingAutomatic": false,
                                          "receipt": "synthetic-receipt", "receiptSummary": partialSummary, "receiptMoved": 272, "receiptDestination": "work/company"])
            let recorded = base.map { .spread($0, ["receipt": "/synthetic/2026-10-30T21-00-00-000.json", "receiptDone": base[1].label,
                                                   "receiptSummary": ["moved": 499, "notMoved": [], "groups": [], "attention": [], "kept": []]]) }
            let starting = try pending(0, "cloud", 1, "CLOUD_AUTH_PENDING", nil, 2).map { .spread($0, ["active": false, "signedIn": false, "identityState": "unknown"]) }
            let unfinished = try pending(2, "cloud", 3).map { $0.pending.truthy ? .spread($0, ["receiptSummary": partialSummary]) : $0 }
            // An hour ahead: compiling the menu bar app before it renders can take most of a minute on CI.
            let retrying = { (rows: Value) in rows.map { $0.pending.truthy ? .spread($0, ["pendingRetryAt": Value(dateNow() + 3_600_000)]) : $0 } }
            let label0 = base[0].label, label1 = base[1].label
            let rows: [Value] = [
                ["name": "01-done", "screen": "moved", "event": ["done": true, "ok": true, "complete": true, "moved": 361, "destinationLabel": label0], "contains": ["Done. 361 sessions are now in", label0], "primary": nil],
                ["name": "02-held", "screen": "needs a restart", "accounts": held, "contains": ["259 sessions moved\n102 more need Claude to restart."], "primary": "Restart Claude and move 102"],
                ["name": "03-restart-dialog", "plan": plan, "dialog": true, "contains": ["Restart Claude to move 102 more sessions?", "These open chats will stop:"], "primary": "Restart and move"],
                ["name": "04-same-login", "screen": "moved", "accounts": try pending(1, "cloud", 1), "contains": ["361 sessions moved\n1 old copy needs checking", "Cleanup will retry automatically."], "primary": nil],
                ["name": "05-other-login", "screen": "needs a sign-in", "accounts": try pending(2, "cloud", 3), "contains": ["361 sessions moved\n3 old copies need checking", "Sign Claude in as home@example.test"], "primary": "Leave old copies and move"],
                ["name": "06-clearing", "screen": "moving", "accounts": try pending(1, "cloud", 1, nil, nil, 1), "operation": ["finish", "--json"],
                 "event": ["stage": "cloud", "live": true, "text": "0/1", "total": 1, "completed": 0, "moved": 361, "sourceId": "work/personal", "sourceLabel": label1], "contains": ["0%"], "primary": nil],
                ["name": "08-unproven", "screen": "moved", "event": ["done": true, "ok": true, "complete": true, "moved": 361, "destinationLabel": label0, "summary": ["moved": 361, "notMoved": [], "groups": [], "attention": [],
                 "kept": [["id": "cse_research", "title": "Research conversation", "error": Value("not proven to be on this Mac, kept in \(label1)")]]]],
                 "contains": ["Done. 361 sessions are now in", Value("Research conversation | cse_rese | not proven to be on this Mac, kept in \(label1)")], "primary": nil, "expanded": true],
                ["name": "09-open-chats", "screen": "needs a restart", "accounts": try pending(1, "local", 2, nil, "worker"), "contains": ["359 sessions moved\n2 open chats move after they go idle"], "primary": "Restart Claude and move 2"],
                ["name": "10-interrupted", "screen": "needs a restart", "accounts": try pending(1, "recovery", 0), "contains": ["361 sessions moved\nThe last move was interrupted."], "primary": "Finish the move"],
                ["name": "11-repair", "screen": "can't move", "accounts": base.map { .spread($0, ["recoveryProblem": ["receipt": "/synthetic/move.json", "error": "An older version started this move and must finish it", "code": "OLDER_MOVE"]]) },
                 "contains": ["The last move is paused.\nAn older version started this move and must finish it."], "primary": nil],
                ["name": "12-undo-pending", "screen": "needs a sign-in", "accounts": try pending(2, "undo", 1), "contains": ["Undo is partly done\nSign Claude in as home@example.test."], "primary": nil],
                ["name": "13-move-stopped", "screen": "needs a restart", "event": ["done": true, "ok": false, "code": "QUIT_UNCONFIRMED", "retryable": true], "contains": ["Move stopped: Claude did not confirm it had closed."], "primary": "Try again"],
                ["name": "14-background-complete", "screen": "moved", "event": ["swept": true, "ok": true, "complete": true, "moved": 12, "restart": true], "contains": ["Moved 12 more sessions. Restart Claude to see them."], "primary": nil],
                ["name": "15-restart-cancelled", "screen": "needs a restart", "accounts": held, "plan": plan, "cancel": true, "contains": ["Restart cancelled.", "102 sessions", label1], "primary": "Restart Claude and move 102"],
                ["name": "16-approval-changed", "screen": "needs a restart", "event": ["done": true, "ok": false, "code": "RESTART_PLAN_CHANGED", "retryable": true], "contains": ["Different chats are open now.", "review again."], "primary": "Restart Claude and move"],
                ["name": "17-uncertain", "screen": "moved", "accounts": try pending(0, "cloud", 1, "CLOUD_ARTIFACT_UNCERTAIN"), "contains": ["361 sessions moved\nWaiting to verify 1 conversation", "The check will retry automatically."], "primary": nil],
                ["name": "19-undo-complete", "screen": "moved", "event": ["undone": "synthetic-receipt", "restored": 3, "sessions": 3, "restart": true], "operation": ["undo", "--json"], "contains": ["Undo complete. 3 source entries restored."], "primary": nil],
                ["name": "20-stopped-here", "screen": "moved", "event": ["done": true, "ok": true, "complete": true, "moved": 259, "keptLocal": 1, "heldCancelled": 102], "operation": ["keep-local", "--json"], "contains": ["259 moved. Stopped here.", "Remaining work cancelled."], "primary": nil],
                ["name": "21-partial", "screen": "can't move", "event": ["done": true, "ok": false, "complete": true, "summary": ["moved": 233, "notMoved": Value((0..<10).map { i -> Value in ["id": Value(id(i)), "error": "MOVE_BLOCKED"] }), "groups": [], "attention": []]],
                 "contains": ["233 moved.", "10 sessions were not moved."], "primary": nil],
                ["name": "25-completion-pending", "screen": "moved", "event": ["done": true, "ok": true, "complete": false, "moved": 12], "contains": ["12 moved. Remaining work is waiting."], "primary": nil],
                ["name": "26-undo-ready", "screen": "needs a sign-in", "accounts": try pending(2, "undo", 1, nil, nil, 2), "contains": ["Undo is partly done\nPress Finish undo."], "primary": "Finish undo"],
                ["name": "27-timed-open-chats", "screen": "needs a restart", "accounts": try pending(1, "local", 2, nil, "worker", 0, 900), "contains": ["after about 15 idle minutes"], "primary": "Restart Claude and move 2"],
                ["name": "28-mixed-held-and-cloud", "screen": "needs a restart", "accounts": mixed, "contains": ["259 sessions moved\n102 more need Claude to restart.", "3 old copies need checking"], "primary": "Restart Claude and move 102"],
                ["name": "29-unreadable", "screen": "moved", "accounts": try pending(0, "cloud", 1, "CLOUD_HISTORY_UNREADABLE"), "contains": ["Waiting to verify 1 conversation", "The check will retry automatically."], "primary": nil],
                ["name": "30-check-dismissed", "screen": "moved", "operation": ["keep-local", "--json", "--leave-check", Value(String(repeating: "a", count: 64))],
                 "event": ["done": true, "ok": true, "complete": true, "moved": 0, "keptLocal": 1, "heldCancelled": 0], "contains": ["Stopped here. Remaining source checks cancelled."], "primary": nil],
                ["name": "31-mixed-unreadable-and-waiting", "screen": "needs a restart", "accounts": mixedWaiting, "contains": ["Waiting to verify 2 conversations"], "primary": "Restart Claude and finish cleanup", "keep": true],
                ["name": "32-one-source-clearing", "screen": "moved", "accounts": twoSources, "background": true,
                 "event": ["stage": "cloud", "live": true, "text": "0/1", "completed": 0, "total": 1, "sourceId": "work/personal", "sourceLabel": label1], "contains": ["Clearing 1 old copy from", label1], "primary": nil],
                ["name": "33-background-verification", "screen": "moved", "accounts": twoSources, "background": true, "event": ["stage": "verify", "live": true, "text": "1/3", "completed": 1, "total": 3], "contains": ["Cleanup will retry automatically."], "primary": nil],
                ["name": "34-same-login-undo", "screen": "needs a sign-in", "accounts": try pending(1, "undo", 1), "contains": ["Press Finish undo."], "primary": "Finish undo"],
                ["name": "35-local-undo-recovery", "screen": "needs a restart", "accounts": localUndo, "contains": ["Press Finish undo."], "primary": "Finish undo"],
                ["name": "37-reopen-failed", "screen": "needs a restart", "accounts": try pending(1, "undo", 1), "event": ["swept": true, "ok": false, "code": "REOPEN_FAILED", "error": "Synthetic reopen failure"],
                 "contains": ["Claude could not be confirmed open.", "Open Claude, then press Try again."], "primary": "Try again"],
                ["name": "38-same-login-uncertain", "screen": "moved", "accounts": try pending(1, "cloud", 1, "CLOUD_ARTIFACT_UNCERTAIN"), "contains": ["The check will retry automatically."], "primary": nil],
                ["name": "39-capacity-dialog", "dialog": true, "plan": capacityPlan, "event": capacityPlan, "contains": ["stay closed while", "These open chats will stop:"], "primary": "Restart and move"],
                ["name": "40-capacity-suppressed-warning", "dialog": true, "suppressed": true, "plan": capacityPlan, "event": capacityPlan, "contains": ["stay closed while", "These open chats will stop:"], "primary": "Restart and move"],
                ["name": "43-partial-quit-veto", "screen": "needs a restart", "accounts": held,
                 "event": ["done": true, "ok": false, "complete": false, "receipt": "synthetic-receipt", "moved": 259, "heldCount": 102, "code": "QUIT_UNCONFIRMED", "retryable": true],
                 "contains": ["259 moved. Move stopped:", "Claude did not confirm it had closed."], "primary": "Try again"],
                ["name": "44-login-retry", "screen": "moved", "accounts": retrying(try pending(0, "cloud", 1, "CLOUD_AUTH_PENDING")), "contains": ["361 sessions moved\nWaiting for Claude to finish signing in.", "Retrying in"], "primary": nil],
                ["name": "45-memory-retry", "screen": "moved", "accounts": retrying(try pending(0, "cloud", 1, "CLOUD_MEMORY_PRESSURE")), "contains": ["361 sessions moved\nWaiting for memory", "Retrying in"], "primary": nil],
                ["name": "46-history-limit", "screen": "can't move", "accounts": try pending(0, "cloud", 1, "CLOUD_HISTORY_LIMIT"), "contains": ["361 sessions moved\n1 conversation exceeds the history limit"], "primary": nil, "keep": true],
                ["name": "47-budget-limit", "screen": "can't move", "accounts": try pending(0, "cloud", 1, "CLOUD_BUDGET_LIMIT"), "contains": ["memory budget", "even one at a time"], "primary": nil, "keep": true],
                ["name": "48-parser-limit", "screen": "can't move", "accounts": try pending(0, "cloud", 1, "CLOUD_PARSER_LIMIT"), "contains": ["history reader's limit"], "primary": nil, "keep": true],
                ["name": "49-local-partial", "screen": "can't move", "accounts": partial, "contains": ["272 sessions moved\n3 sessions remain", "Keep moved sessions or undo this move."], "primary": nil, "keep": true],
                ["name": "50-limit-and-sign-in", "screen": "needs a sign-in", "accounts": limitAndSignIn, "contains": ["361 sessions moved\n3 old copies need checking", "exceeds the history limit"], "primary": nil],
                ["name": "51-recorded-result", "screen": "moved", "accounts": recorded, "contains": [Value("Done. 499 sessions are now in \(label1).\nHistory verified")], "primary": "Move"],
                ["name": "52-waiting-for-claude", "accounts": starting, "contains": ["361 sessions moved\nWaiting for Claude."], "primary": nil],
                ["name": "53-other-login-and-unfinished-local", "screen": "needs a sign-in", "accounts": unfinished, "contains": ["272 sessions moved\n3 old copies need checking"], "primary": nil],
            ]
            return Value(rows.map { row in
                .spread(row, ["accounts": row.accounts ?? base, "operation": row.operation ?? ["--from", "work personal", "--to", "work company", "--cloud", "--json"],
                              "event": row.event.truthy ? Value(JSON.text(row.event)) : .null])
            })
        }

        @Test("Swift section 1 wording states render the production panel and restart prompt")
        func wordingStates() throws {
            let root = temporaryDirectory("ct-section1-panels-")
            let fixtures = try MenuBar.wordingFixtures()
            try writeJSON(path.join(root, "fixtures.json"), fixtures)
            let stdout = try MenuBar.run("wording", root)
            match(stdout, "Rendered \\d+ production wording states")
            let manifest = try readJSON(path.join(root, "manifest.json"))
            eq(manifest.length, fixtures.length)
            for row in manifest.elements {
                #expect(try readData(row.path.str).prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]), "\(row.name)")
            }
        }

        @Test("Swift preserves command, progress, metadata, and completion states")
        func commandProgressMetadataCompletion() throws {
            let root = temporaryDirectory("ct-swift-state-")
            let cliProgress = try CLI.cliProgressFixture()
            let checkpointAccounts = try CLI.checkpointAccountsFixture()
            let h = try taskFamilyFixture(true, 1)
            try interruptTaskFamily(h, "move", "target")
            let recoveryAccounts = cli(h.root, ["accounts", "--json"])
            eq(recoveryAccounts.code, 0)

            let transfer = try taskFamilyFixture(), selected = try transfer.selection(), mock = taskHarness()
            var captured: [Value] = []
            let planned = try executeMove([selected.from], selected.to, transfer.paths, ["io": mock.io])
            var closing = false
            let moved = try executeMove([selected.from], selected.to, transfer.paths, ["io": mock.io, "approve": planned.plan.token, "report": fn { args in
                let stage = MenuBar.arg(args, 0), text = MenuBar.arg(args, 1), extra = MenuBar.arg(args, 2)
                if stage == "desktop" { closing = true }
                let line = Value.spread(["stage": stage, "text": text], extra.isObjectLike ? extra : [:])
                captured.append(["preQuit": Value(!closing), "line": Value(JSON.text(line))])
                return .undefined
            }])
            eq(moved.ok, true, moved.reason.description)
            ok(try captured.contains { row in
                let line = try JSON.parse(row.line.str)
                return row.preQuit.truthy && line.stage == "move" && toNumber(line.completed) > 0
            })

            let retryHome = try taskFamilyFixture(), retrySelection = try retryHome.selection()
            let desktop = "500 1 Tue Sep 1 00:00:00 2026 /Applications/Claude.app/Contents/MacOS/Claude"
            let listing = "\(desktop)\n701 500 Tue Sep 1 00:00:00 2026 /tmp/claude", commands = "\(listing) --resume \(retryHome.run)"
            let retryMock = taskHarness(try parseProcesses(Value(desktop), Value(desktop)))
            let retryPlan = try executeMove([retrySelection.from], retrySelection.to, retryHome.paths, ["io": retryMock.io])
            var changed = false
            let interrupted = try executeMove([retrySelection.from], retrySelection.to, retryHome.paths, ["io": retryMock.io, "approve": retryPlan.plan.token, "report": fn { args in
                if !changed && MenuBar.arg(args, 0) == "move" && MenuBar.arg(args, 2).completed == 1 {
                    changed = true
                    retryMock.rows = try parseProcesses(Value(listing), Value(commands))
                }
                return .undefined
            }])
            #expect(changed)
            eq(interrupted.code, "RESTART_PLAN_CHANGED")
            eq(interrupted.receipt.sessions.length, 1)
            #expect(retryMock.calls == [])
            let retryAccounts = cli(retryHome.root, ["accounts", "--json"]) { processSetup(list: listing, commands: commands) }
            eq(retryAccounts.code, 0, retryAccounts.stderr)
            let event = Value.spread(interrupted, ["done": true, "receipt": interrupted.file, "moved": Value(interrupted.receipt.sessions.length),
                                                   "heldCount": Value(interrupted.receipt.held.length), "held": interrupted.receipt.held])
            let continuation: Value = ["accounts": try JSON.parse(retryAccounts.stdout), "args": ["--from", retrySelection.from.label, "--to", retrySelection.to.label, "--json"],
                                       "event": Value(JSON.text(event))]

            let data: [(String, String)] = [
                ("TASK_RECOVERY_ACCOUNTS", recoveryAccounts.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
                ("CORRUPTED_CHECKPOINT_ACCOUNTS", checkpointAccounts.corrupted),
                ("REPAIRED_CHECKPOINT_ACCOUNTS", checkpointAccounts.repaired),
                ("WORDING_FIXTURES", JSON.text(try MenuBar.wordingFixtures())),
                ("CAPTURED_RESTART_PROGRESS", JSON.text(Value(captured))),
                ("CLI_COUNTER_EVENTS", JSON.text(.strings(cliProgress))),
                ("ACTUAL_CONTINUATION", JSON.text(continuation)),
            ]
            for (name, text) in data { try writeText(path.join(root, name), text) }
            let stdout = try MenuBar.run("state", root, timeout: 60_000)
            match(stdout, "Swift queue and metadata states passed")
            guard let commandLine = stdout.components(separatedBy: "\n").first(where: { $0.hasPrefix("CONTINUATION_COMMAND ") }) else {
                Issue.record("no CONTINUATION_COMMAND in \(stdout)")
                return
            }
            let command = try JSON.parse(String(commandLine.dropFirst("CONTINUATION_COMMAND ".count))).elements.map(\.str)
            let receiptBytes = try readData(interrupted.file.str)
            let next = cli(retryHome.root, command) { processSetup(list: listing, commands: commands) }
            eq(next.code, 0, next.stderr)
            let continuationPlan = lines(next.stdout).find { $0.plan.truthy }
            ok(continuationPlan, next.stdout)
            eq(continuationPlan.receiptFile, interrupted.file)
            eq(continuationPlan.resume, true)
            ne(continuationPlan.token, retryPlan.plan.token)
            #expect(try readData(interrupted.file.str) == receiptBytes)
            let finished = try finishWorkflow(retryHome.paths, ["io": retryMock.io, "approve": continuationPlan.token])
            eq(finished.ok, true, finished.reason.description)
            eq(finished.complete, true)
            eq(finished.file, interrupted.file)
            eq(finished.receipt.sessions.length, 4)
        }
    }
}
