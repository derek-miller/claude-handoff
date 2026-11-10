import Darwin
import Foundation
import Testing
@testable import HandoffCore

extension Engine {
    @Suite("accounts and tidy")
    struct Accounts {
        static func arg(_ args: [Value], _ i: Int) -> Value { i < args.count ? args[i] : .undefined }

        static func login(_ file: String, _ account: String, _ org: String, _ email: String, _ name: String, _ type: String? = nil) throws {
            let oauth: Value = ["accountUuid": Value(account), "organizationUuid": Value(org), "emailAddress": Value(email), "organizationName": Value(name)]
            if let type { oauth.organizationType = Value(type) }
            try writeJSON(file, ["oauthAccount": oauth])
        }

        @Test("signed-in identity survives inactivity and ignores usage, focus, and allowlist refreshes")
        func identitySurvivesInactivity() throws {
            let h = try home(), f = try identityFixture(h)
            let team = path.join(h.paths.records.str, h.acct.P, h.org.T)
            try mkdirp(team)
            try writeJSON(path.join(team, "local_\(id(999)).json"), ["sessionId": Value("local_\(id(999))"), "cliSessionId": Value(id(999)), "cwd": "/tmp/fixture", "lastFocusedAt": Value(dateNow())])
            let claude = path.dirname(h.paths.desktop.str)
            try writeJSON(path.join(claude, "plan-usage-history.json"), ["samples": [["org": Value(h.org.T), "t": Value(dateNow())]]])
            let scope = path.join(claude, "sentry/scope_v3.json")
            try mkdirp(path.dirname(scope))
            try writeJSON(scope, ["scope": ["breadcrumbs": [["timestamp": Value(dateNow()), "data": ["url": Value("https://claude.ai/api/organizations/\(h.org.T)/usage")]]]]])
            let desktop = Value.newObject()
            desktop["lastKnownAccountUuid"] = Value(h.acct.P)
            desktop["dxt:allowlistLastUpdated:\(h.org.T)"] = Value(isoNow())
            try writeJSON(h.paths.desktop.str, desktop)
            let result = try signedIn(h.paths, f.processes)
            deq(result, ["account": Value(h.acct.P), "org": Value(h.org.P), "state": "known", "source": "log", "at": Value(isoString(f.started))])
            let list = try accounts(h.paths, f.processes)
            deq(list.filter { $0.active.truthy }.map { $0.org }, [Value(h.org.P)])
            #expect(list.filter { $0.account.str == h.acct.P }.every { $0.signedIn.truthy })
            #expect(!list.filter { $0.account.str != h.acct.P }.some { $0.signedIn.truthy })
        }

        @Test("signed-in identity invalidates incomplete transitions, logout, and initialization failures")
        func identityInvalidates() throws {
            let h = try home(), f = try identityFixture(h)
            let cases: [(String, String)] = [
                ("[LocalSessionManager] Org changed from \(h.org.P) to \(h.org.T), reinitializing sessions", "unknown"),
                ("[LocalSessionManager] Org changed from null to \(h.org.T), reinitializing sessions", "unknown"),
                ("[account] Login-state transition (loggedOut: false \u{2192} true, uuid: \(h.acct.P) \u{2192} <none>), clearing oauth cache", "logged-out"),
                ("[account] Login-state transition (loggedOut: false \u{2192} false, uuid: \(h.acct.P) \u{2192} \(h.acct.T)), clearing oauth cache", "unknown"),
                ("[LocalSessionManager] Account logged out, marking for re-init on next login", "logged-out"),
                ("[LocalSessionManager] Cannot initialize sessions: accountId=null, orgId=null. Keeping existing sessions.", "unknown"),
                ("[LocalSessionManager] loadSessions failed during account transition", "unknown"),
                ("[LocalSessionManager] Initialization succeeded, accountId=invalid, orgId=invalid", "unknown"),
            ]
            for (event, state) in cases {
                try f.write(f.`init`() + f.event(1, event))
                let result = try signedIn(h.paths, f.processes)
                eq(result.state, Value(state), event)
                eq(result.account, nil)
                eq(result.org, nil)
                try f.write(f.`init`() + f.event(1, event) + f.`init`(2, h.acct.P, h.org.T))
                eq(try signedIn(h.paths, f.processes).org, Value(h.org.T))
            }
        }

        @Test("signed-in identity reads rotations, accepts the launch second, and rejects a previous launch")
        func identityRotations() throws {
            let h = try home(), f = try identityFixture(h)
            try f.write(f.event(10, "[display] unrelated display event"))
            try f.write(f.`init`(), "main1.log")
            try f.write(f.`init`(-30, h.acct.T, h.org.T), "main2.log")
            eq(try signedIn(h.paths, f.processes).org, Value(h.org.P))
            let restarted: Value = [.spread(f.processes[0], ["started": Value(dateString(f.started + 1000))])]
            eq(try signedIn(h.paths, restarted).state, "unknown")
            try f.write(f.event(15, "[LocalSessionManager] Initialization wording changed"))
            eq(try signedIn(h.paths, restarted).state, "unknown")
            eq(try signedIn(h.paths, []).state, "unknown")
            eq(try signedIn(h.paths, f.processes.concat([.spread(f.processes[0], ["pid": 501])])).state, "unknown")
        }

        @Test("signed-in identity rejects account conflicts and recovers only from a paired entry")
        func identityConflicts() throws {
            let h = try home(), f = try identityFixture(h)
            try writeJSON(h.paths.desktop.str, ["lastKnownAccountUuid": Value(h.acct.T)])
            eq(try signedIn(h.paths, f.processes).state, "unknown")
            try f.write(f.`init`() + f.event(1, "[LocalSessionManager] Org changed from \(h.org.P) to \(h.org.T), reinitializing sessions"))
            eq(try signedIn(h.paths, f.processes).state, "unknown")
            try f.write(f.`init`() + f.`init`(2, h.acct.T, h.org.T))
            eq(try signedIn(h.paths, f.processes).account, Value(h.acct.T))
            try writeText(h.paths.desktop.str, "{}")
            eq(try signedIn(h.paths, f.processes).account, Value(h.acct.T))
        }

        @Test("signed-in identity handles missing, future, and partially written log evidence")
        func identityLogEvidence() throws {
            let h = try home(), f = try identityFixture(h)
            let partial = f.`init`(2, h.acct.P, h.org.T).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            try f.write(f.`init`() + partial)
            eq(try signedIn(h.paths, f.processes).state, "unknown")
            try f.write(f.`init`(48 * 60 * 60))
            eq(try signedIn(h.paths, f.processes).state, "unknown")
            try unlink(path.join(h.paths.logs.str, "main.log"))
            eq(try signedIn(h.paths, f.processes).state, "unknown")
        }

        @Test("signed-in identity follows an offline switch without using network-dependent markers")
        func identityOffline() throws {
            let h = try home(), f = try identityFixture(h)
            var calls = 0
            cloudFetch = { _ in calls += 1; throw JSError("offline") }
            let desktop = Value.newObject()
            desktop["lastKnownAccountUuid"] = Value(h.acct.P)
            desktop["dxt:allowlistLastUpdated:\(h.org.P)"] = Value(isoNow())
            try writeJSON(h.paths.desktop.str, desktop)
            try f.write(f.`init`() + f.event(1, "[LocalSessionManager] Org changed from \(h.org.P) to \(h.org.T), reinitializing sessions") + f.`init`(2, h.acct.P, h.org.T) + f.event(3, "Failed to check allowlist status: offline"))
            eq(try signedIn(h.paths, f.processes).org, Value(h.org.T))
            eq(calls, 0)
        }

        @Test("accounts includes a known login organization with no Desktop directory")
        func knownLoginWithoutDirectory() throws {
            let h = try home()
            let account = id(920), org = id(921), profile = path.join(h.root, ".claude-known")
            try mkdirp(profile)
            try Accounts.login(path.join(profile, ".claude.json"), account, org, "known@example.com", "Known Team", "team")
            let row = try accounts(h.paths).find { $0.account.str == account && $0.org.str == org }
            eq(row.label, "known@example.com · Known Team")
            eq(row.sessions.length, 0)
            #expect(!exists(row.dir.str))
        }

        @Test("accounts keeps a learned name after its login file goes away")
        func learnedNameSurvives() throws {
            let h = try home()
            let account = id(924), org = id(925), profile = path.join(h.root, ".claude-gone")
            try mkdirp(profile)
            try mkdirp(path.join(h.paths.records.str, account, org))
            try mkdirp(h.paths.state)
            try Accounts.login(path.join(profile, ".claude.json"), account, org, "gone@example.com", "Gone Team", "team")
            _ = try accounts(h.paths)
            try rmrf(profile)
            let row = try accounts(h.paths).find { $0.account.str == account && $0.org.str == org }
            eq(row.label, "gone@example.com · Gone Team")
            let saved = try readJSON(h.paths.labels.str)
            eq(saved.emails[account], "gone@example.com")
            eq(saved.orgs[org], "Gone Team")
        }

        @Test("accounts follows a login file that changes its email or organization name")
        func loginRename() throws {
            let h = try home()
            let account = id(926), org = id(927), profile = path.join(h.root, ".claude-rename")
            try mkdirp(profile)
            try mkdirp(h.paths.state)
            try Accounts.login(path.join(profile, ".claude.json"), account, org, "old@example.com", "Old Team", "team")
            _ = try accounts(h.paths)
            try Accounts.login(path.join(profile, ".claude.json"), account, org, "new@example.com", "New Team", "team")
            let row = try accounts(h.paths).find { $0.account.str == account && $0.org.str == org }
            eq(row.label, "new@example.com · New Team")
            let saved = try readJSON(h.paths.labels.str)
            eq(saved.emails[account], "new@example.com")
            eq(saved.orgs[org], "New Team")
        }

        @Test("accounts tells apart organizations that share a name with their uuid prefix")
        func sharedOrganizationNames() throws {
            let h = try home()
            let account = id(924), orgs = [id(925), id(926)]
            for (index, org) in orgs.enumerated() {
                let profile = path.join(h.root, ".claude-personal-\(index)")
                try mkdirp(profile)
                try Accounts.login(path.join(profile, ".claude.json"), account, org, "same@example.com", "Personal", "personal")
            }
            let rows = try accounts(h.paths).filter { $0.account.str == account }
            deq(rows.map { $0.label }.sorted(), Value.strings(orgs.map { "same@example.com · Personal · \(short($0))" }).sorted())
        }

        @Test("tidy sets aside only empty folders Desktop left for another login personal organization")
        func tidyLeftovers() throws {
            let h = try home()
            let (owner, guest, solo, other) = (id(930), id(931), id(932), id(933))
            let (ownerOrg, guestOrg, team, soloOrg, otherOrg, shared) = (id(940), id(941), id(942), id(943), id(944), id(945))
            func login(_ name: String, _ account: String, _ org: String, _ organizationName: String) throws {
                try mkdirp(path.join(h.root, name))
                try Accounts.login(path.join(h.root, name, ".claude.json"), account, org, "\(name.dropFirst(8))@example.com", organizationName)
            }
            try login(".claude-owner", owner, ownerOrg, "Personal")
            try login(".claude-guest", guest, guestOrg, "Personal")
            try login(".claude-team", owner, team, "Shared Team")
            try login(".claude-solo", solo, soloOrg, "Personal")
            try login(".claude-other", other, otherOrg, "Personal")
            try login(".claude-shared", solo, shared, "Personal")
            func folder(_ root: String, _ account: String, _ org: String, _ tasks: Value = []) throws {
                try mkdirp(path.join(root, account, org))
                try writeJSON(path.join(root, account, org, "scheduled-tasks.json"), ["scheduledTasks": tasks])
            }
            try mkdirp(path.join(h.paths.records.str, owner, ownerOrg))
            try writeJSON(path.join(h.paths.records.str, owner, ownerOrg, "local_\(id(950)).json"), ["sessionId": Value("local_\(id(950))"), "cliSessionId": Value(id(950)), "cwd": "/tmp", "title": "Kept", "lastActivityAt": 2])
            let kept = [(guest, guestOrg), (guest, team), (owner, team), (other, ownerOrg), (other, otherOrg), (solo, soloOrg), (solo, shared), (other, shared)]
            for root in [h.paths.records.str, h.paths.agentSessions.str] {
                try folder(root, guest, ownerOrg)
                for (account, org) in kept { try folder(root, account, org, account == other && org == ownerOrg ? [["id": "daily"]] : []) }
            }

            let found = try leftovers(h.paths, try accounts(h.paths))
            deq(found.map { Value("\($0.account)/\($0.org)") }, [Value("\(guest)/\(ownerOrg)")])
            let result = try tidy(h.paths)
            deq(result.moved.map { Value($0.account.str + $0.org.str) }, [Value(guest + ownerOrg)])
            for (tree, root) in [("claude-code-sessions", h.paths.records.str), ("local-agent-mode-sessions", h.paths.agentSessions.str)] {
                #expect(!exists(path.join(root, guest, ownerOrg)))
                #expect(exists(path.join(result.dest.str, tree, guest, ownerOrg, "scheduled-tasks.json")))
                for (account, org) in kept { #expect(exists(path.join(root, account, org))) }
            }
            deq(try tidy(h.paths).moved, [])
            throwsError(where: ["code": "ACCOUNT_NOT_EMPTY"]) { try tidy(h.paths, ["account": Value(owner), "org": Value(ownerOrg)]) }
            throwsError(where: ["code": "ACCOUNT_NOT_EMPTY"]) { try tidy(h.paths, ["account": Value(other), "org": Value(ownerOrg)]) }
            throwsError(where: ["code": "NO_ACCOUNT"]) { try tidy(h.paths, ["account": Value(other), "org": Value(team)]) }
            let single = try tidy(h.paths, ["account": Value(guest), "org": Value(guestOrg)])
            deq(single.moved.map { Value($0.account.str + $0.org.str) }, [Value(guest + guestOrg)])
            for root in [h.paths.records.str, h.paths.agentSessions.str] { #expect(!exists(path.join(root, guest, guestOrg))) }
            #expect(exists(path.join(h.paths.records.str, guest, team)))
        }

        @Test("tidy clears an emptied account from every Desktop folder but a scratch folder a session still uses")
        func tidyClearsEveryFolder() throws {
            let h = try home()
            let claude = path.dirname(h.paths.records.str)
            let (owner, gone, moved) = (id(960), id(961), id(962))
            let (ownerOrg, goneOrg, movedOrg) = (id(970), id(971), id(972))
            func folders(_ account: String, _ org: String) -> [String] {
                [path.join(h.paths.records.str, account, org), path.join(h.paths.agentSessions.str, account, org), path.join(claude, "plugin-list", account, org),
                 path.join(h.paths.agentSessions.str, "skills-plugin", org, account), path.join(claude, "scratch-workspaces", account, org, "scratch-1")]
            }
            for (account, org) in [(gone, goneOrg), (moved, movedOrg)] {
                for dir in folders(account, org) { try mkdirp(dir) }
                try writeText(path.join(claude, "plugin-list", account, org, "plugins.json"), "[]")
            }
            let used = path.join(claude, "scratch-workspaces", moved, movedOrg, "scratch-1")
            try mkdirp(path.join(h.paths.records.str, owner, ownerOrg))
            try writeJSON(path.join(h.paths.records.str, owner, ownerOrg, "local_\(id(980)).json"), ["sessionId": Value("local_\(id(980))"), "cliSessionId": Value(id(980)), "cwd": Value(used), "title": "Moved", "lastActivityAt": 2])

            let first = try tidy(h.paths, ["account": Value(gone), "org": Value(goneOrg)])
            eq(first.moved[0].scratchKept, .undefined)
            for dir in folders(gone, goneOrg) { #expect(!exists(dir), "\(dir)") }
            #expect(exists(path.join(first.dest.str, "plugin-list", gone, goneOrg, "plugins.json")))
            #expect(exists(path.join(first.dest.str, "skills-plugin", goneOrg, gone)))
            #expect(exists(path.join(first.dest.str, "scratch-workspaces", gone, goneOrg, "scratch-1")))

            let second = try tidy(h.paths, ["account": Value(moved), "org": Value(movedOrg)])
            eq(second.moved[0].scratchKept, Value(path.join(claude, "scratch-workspaces", moved, movedOrg)))
            #expect(exists(used))
            for dir in folders(moved, movedOrg).prefix(4) { #expect(!exists(dir), "\(dir)") }
        }

        @Test("accounts labels a login held in a claude-acc account directory")
        func switchAccountsLabel() throws {
            let h = try home()
            let account = id(922), org = id(923), profile = path.join(h.paths.switchAccounts.str, "work")
            try mkdirp(profile)
            try Accounts.login(path.join(profile, ".claude.json"), account, org, "switched@example.com", "Switched Team", "team")
            let row = try accounts(h.paths).find { $0.account.str == account && $0.org.str == org }
            eq(row.label, "switched@example.com \u{00b7} Switched Team")
        }

        // The Node test checked the suite's own mutatingOpen spy over Node's string and numeric flags. The Swift fs
        // table only ever sees numeric open(2) flags, so the spy and this check cover those.
        @Test("mutation spies distinguish read-only and mutating open flags")
        func mutationSpies() {
            for flags in [O_RDONLY, O_RDONLY | O_NOFOLLOW, O_RDONLY | O_CLOEXEC] { #expect(!Moves.mutatingOpen(flags), "\(flags)") }
            for flags in [O_WRONLY, O_RDWR, O_CREAT, O_TRUNC, O_APPEND, O_RDWR | O_NOFOLLOW, O_CREAT | O_EXCL, O_WRONLY | O_CREAT | O_TRUNC, O_WRONLY | O_CREAT | O_APPEND] {
                #expect(Moves.mutatingOpen(flags), "\(flags)")
            }
        }

        @Test("process registry identifies a new worker without argv ids and rejects stale pid reuse")
        func processRegistry() throws {
            let started = "Fri Sep  4 18:00:00 2026"
            var components = DateComponents()
            (components.year, components.month, components.day, components.hour) = (2026, 9, 4, 18)
            let date = Calendar(identifier: .gregorian).date(from: components)!
            let utc = DateFormatter()
            utc.locale = Locale(identifier: "en_US_POSIX")
            utc.timeZone = TimeZone(identifier: "UTC")
            utc.dateFormat = "EEE MMM dd HH:mm:ss yyyy"
            let processes = "500 1 \(started) /Applications/Claude.app/Contents/MacOS/Claude\n501 500 \(started) /Applications/Claude.app/Contents/Helpers/disclaimer\n502 501 \(started) /tmp/claude"
            let commands = "500 1 \(started) Claude\n501 500 \(started) disclaimer\n502 501 \(started) claude --input-format stream-json"
            let registration: Value = ["pid": 502, "sessionId": Value(SOURCE), "cwd": "/tmp/fixture", "name": "A new session", "procStart": Value(utc.string(from: date)), "pidDomain": "darwin"]
            let rows = try parseProcesses(Value(processes), Value(commands), "/Applications/Claude.app", [registration])
            deq(rows.find { $0.pid == 502 }.ids, [Value(SOURCE)])
            eq(rows.find { $0.pid == 502 }.desktopPid, 500)
            let stale = try parseProcesses(Value(processes), Value(commands), "/Applications/Claude.app", [.spread(registration, ["procStart": "Thu Sep 3 00:00:00 2026"])])
            deq(stale.find { $0.pid == 502 }.ids, [])
            let foreign = try parseProcesses(Value(processes), Value(commands), "/Applications/Claude.app", [.spread(registration, ["pidDomain": "linux"])])
            deq(foreign.find { $0.pid == 502 }.ids, [])
        }
    }
}
