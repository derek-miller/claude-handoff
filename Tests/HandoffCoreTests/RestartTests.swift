import Foundation
import Testing
@testable import HandoffCore

extension Engine {
    @Suite("restarts and workflows")
    struct Restarts {
        // A Desktop process table after reopening, as the restart fixtures return it.
        static func reopened(_ started: String = "new") -> Value {
            [.spread(desktopFixture()[0], ["pid": 700, "desktopPid": 700, "started": Value(started)])]
        }

        @Test("process identity separates Desktop descendants, external workers, and reused pids")
        func processIdentity() throws {
            let at = "Fri Sep  4 18:00:00 2026", later = "Fri Sep  4 18:01:00 2026"
            let table = [
                "10 1 \(at) /Applications/Claude.app/Contents/MacOS/Claude",
                "11 10 \(at) /Applications/Claude.app/Contents/Helpers/disclaimer",
                "12 11 \(at) /Library/Application Support/Claude/claude",
                "13 1 \(at) /tmp/claude",
                "14 1 \(at) /tmp/claude",
                "15 16 \(at) /tmp/claude",
                "16 15 \(at) /bin/sh",
            ].joined(separator: "\n")
            let commands = [
                "10 1 \(at) Claude", "11 10 \(at) disclaimer local_\(SOURCE)",
                "12 11 \(at) claude --resume \(id(2))", "13 1 \(at) claude --resume \(id(2))",
                "14 1 \(later) claude --resume \(SOURCE)", "15 16 \(at) claude", "16 15 \(at) sh",
            ].joined(separator: "\n")
            let rows = try parseProcesses(Value(table), Value(commands))
            eq(rows.find { $0["pid"] == 12 }["desktopPid"], 10)
            eq(rows.find { $0["pid"] == 13 }["desktopPid"], nil)
            deq(rows.find { $0["pid"] == 14 }["ids"], [])
            deq(rows.find { $0["pid"] == 11 }["ids"], [Value(SOURCE)])
            eq(rows.find { $0["pid"] == 15 }["desktopPid"], nil)
            throwsError("process identity") { try parseProcesses("unparseable", "") }
            let alternate = try parseProcesses(Value(table.replacingOccurrences(of: "/Applications/Claude.app", with: "/Users/fixture/Applications/Claude.app")), Value(commands))
            eq(alternate.find { $0["pid"] == 11 }["worker"], true)
            eq(alternate.find { $0["pid"] == 12 }["desktopPid"], 10)
        }

        @Test("process inventory handles more than one megabyte of unrelated argv")
        func megabyteArgv() throws {
            let h = try home()
            var ready: [Pipe] = []
            let children = try (0..<9).map { _ -> Foundation.Process in
                let child = Foundation.Process(), pipe = Pipe()
                child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                child.arguments = ["-c", "import sys, time; sys.stdout.write('r'); sys.stdout.flush(); time.sleep(30)", String(repeating: "x", count: 120 * 1024)]
                child.standardInput = FileHandle.nullDevice
                child.standardOutput = pipe
                child.standardError = FileHandle.nullDevice
                try child.run()
                ready.append(pipe)
                return child
            }
            defer {
                for child in children where child.isRunning { child.terminate() }
                for child in children { child.waitUntilExit() }
            }
            // Each child writes one byte once Python is running.
            for pipe in ready { _ = pipe.fileHandleForReading.readData(ofLength: 1) }
            // Under load ps can print a running process without its argv, so read until the children's argv shows.
            let ps = { ChildProcess.nativeSpawnSync("/bin/ps", ["-axo", "pid=,ppid=,lstart=,command="], SpawnOptions(timeout: 2000, maxBuffer: 16 * 1024 * 1024)) }
            var listing = ps()
            let deadline = Date().addingTimeInterval(5)
            while listing.status == 0 && listing.stdout.utf8.count <= 1024 * 1024 && Date() < deadline { usleep(200_000); listing = ps() }
            eq(listing.status.map { Value(Int($0)) } ?? nil, 0)
            ok(listing.stdout.utf8.count > 1024 * 1024, "ps listed \(listing.stdout.utf8.count) bytes")
            let to = try h.account("T")
            eq(try inventory([], to, h.paths)["move"].length, 0)
        }

        @Test("publication exposes complete bytes only after creation evidence is saved")
        func publication() throws {
            let root = temporaryDirectory("ct-publish-"), file = path.join(root, "record.json"), payload = "{\"title\":\"complete\"}\n"
            _ = try writeNew(Value(file), Value(payload), fn { args in
                eq(args[0]["size"], Value(payload.utf8.count))
                eq(readOrNil(file), nil)
                return .undefined
            })
            eq(Value(try readText(file)), Value(payload))
            deq(.strings(try readdir(root)), ["record.json"])
        }

        @Test("inventory recognizes a live Desktop record id before its CLI uuid enters argv")
        func liveDesktopRecordId() throws {
            let h = try home()
            try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
            let desktopId = id(800)
            try h.record("P", SOURCE, ["sessionId": Value("local_\(desktopId)")])
            try rename(h.recordFile("P", SOURCE), h.recordFile("P", desktopId))
            let from = try h.account("P"), to = try h.account("T")
            let inv = try inventory([from], to, h.paths, NOOP, ["processes": [["pid": 100, "worker": true, "ids": [Value(desktopId)], "desktopPid": 50]]])
            eq(inv["move"].length, 0)
            eq(inv["blocked"][0]["id"], Value(SOURCE))
            match(inv["blocked"][0]["error"], "running worker")
        }

        @Test("restart plans include collateral and refuse to claim external worker ownership")
        func collateral() throws {
            let h = try home()
            try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
            try h.record("P", SOURCE)
            let from = try h.account("P"), to = try h.account("T")
            let table = desktopFixture().concat([["pid": 502, "ppid": 500, "started": "other", "executable": "/tmp/claude", "ids": [Value(id(400))], "worker": true, "desktopPid": 500]])
            let inv = try inventory([from], to, h.paths, NOOP, ["processes": table])
            let plan = try restartPlan(inv, h.paths, table)
            eq(plan["held"].length, 1)
            eq(plan["held"][0]["id"], Value(SOURCE))
            deq(plan["interrupts"].map { $0["pid"] }, [502])
            let external = table.concat([["pid": 600, "ppid": 1, "started": "external", "executable": "/tmp/claude", "ids": [Value(SOURCE)], "worker": true, "desktopPid": nil]])
            eq(try restartPlan(inv, h.paths, external), nil)
        }

        @Test("a worker on a non-representative Desktop alias holds the whole compatible group")
        func aliasHoldsGroup() throws {
            let h = try home(), alias = id(810)
            try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
            try h.record("P", SOURCE, ["lastFocusedAt": 1000])
            try h.record("T", SOURCE, ["sessionId": Value("local_\(alias)")])
            try rename(h.recordFile("T", SOURCE), h.recordFile("T", alias))
            let all = try accounts(h.paths)
            let from = all.filter { [h.acct.P, h.acct.T].contains($0["account"].str) }, to = all.find { $0["account"].str == h.acct.Z }
            let rows = desktopFixture(alias)
            let inv = try inventory(from, to, h.paths, NOOP, ["processes": rows])
            eq(inv["move"].length, 0)
            eq(inv["blocked"][0]["worker"], false)
            eq(Value(inv["blocked"][0]["members"].some { $0["worker"].truthy }), true)
            let plan = try restartPlan(inv, h.paths, rows)
            eq(plan["held"][0]["sources"].length, 2)
        }

        @Test("a worker plus a permanent filename collision never offers a restart")
        func collisionNeverRestarts() throws {
            let h = try home(), other = id(400)
            try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
            try h.record("P", SOURCE)
            try h.write(other, [entry("user", 400, nil, other)])
            try h.record("T", other, ["sessionId": Value("local_\(SOURCE)")])
            try rename(h.recordFile("T", other), h.recordFile("T", SOURCE))
            let from = try h.account("P"), to = try h.account("T")
            let inv = try inventory([from], to, h.paths, NOOP, ["processes": desktopFixture()])
            match(inv["blocked"][0]["error"], "filename collision")
            eq(try restartPlan(inv, h.paths, desktopFixture()), nil)
        }

        @Test("restart waits for children, moves only after exit, and reopens on move failure")
        func waitsForChildren() throws {
            let h = try home()
            var rows = desktopFixture(), time = 0.0
            let plan = try restartPlan(nil, h.paths, rows)
            var calls: [String] = []
            let result = try withDesktopRestart(plan, h.paths, fn { _ in
                eq(rows.length, 0)
                calls.append("move")
                throw EngineError("fixture move failed")
            }, NOOP, [
                "now": fn { _ in Value(time) }, "shutdownWait": 400, "reserve": 200, "inspect": fn { _ in rows },
                "wait": fn { args in time += args[0].asNumber!; rows = []; return .undefined },
                "command": fn { args in
                    if args[0].str.hasSuffix("osascript") { calls.append("quit"); rows = rows.slice(1); return ["status": 0] }
                    calls.append("open"); rows = Restarts.reopened(); return ["status": 0]
                },
            ])
            #expect(calls == ["quit", "move", "open"])
            eq(result["restart"]["outcome"], "reopened")
            eq(result["ok"], false)
            match(result["error"], "fixture move failed")
            ok(time <= 1000)
        }

        @Test("a native quit veto leaves held work untouched and does not reopen the running app")
        func quitVeto() throws {
            let h = try home()
            let rows = desktopFixture()
            let plan = try restartPlan(nil, h.paths, rows)
            var time = 0.0, moved = false, opened = false
            let result = try withDesktopRestart(plan, h.paths, fn { () in moved = true }, NOOP, [
                "now": fn { _ in Value(time) }, "shutdownWait": 400, "reserve": 200, "inspect": fn { _ in rows },
                "wait": fn { args in time += args[0].asNumber!; return .undefined },
                "command": fn { args in if args[0].str.hasSuffix("/open") { opened = true }; return ["status": 1] },
            ])
            #expect(moved == false)
            #expect(opened == false)
            eq(result["restart"]["outcome"], "quit-not-confirmed")
            #expect(time == 0)
        }

        @Test("long closed work gets a fresh bounded reopen wait")
        func freshReopenWait() throws {
            let h = try home()
            var rows = desktopFixture(), time = 0.0
            let plan = try restartPlan(nil, h.paths, rows)
            var calls: [(file: String, timeout: Double)] = []
            let result = try withDesktopRestart(plan, h.paths, fn { args in
                for _ in 0..<10 { time += 30_000; try args[0]["progress"].call(); try args[0]["check"].call() }
                return .undefined
            }, NOOP, [
                "inspect": fn { _ in rows }, "now": fn { _ in Value(time) }, "shutdownWait": 400, "reserve": 200,
                "command": fn { args in
                    calls.append((args[0].str, args[2].asNumber ?? .nan))
                    rows = args[0].str.hasSuffix("osascript") ? [] : Restarts.reopened()
                    return ["status": 0]
                },
            ])
            #expect(calls.last?.file == "/usr/bin/open")
            #expect((calls.last?.timeout ?? 0) > 0)
            eq(result["ok"], true)
            eq(result["error"], .undefined)
            #expect(calls.last?.timeout == 200)
            eq(lines(try readText(path.join(h.paths["state"].str, "restart-events.jsonl"))).at(-1)["stopCode"], "NO_WORK")
        }

        @Test("a journal failure after quit cannot prevent the reopen request")
        func journalFailure() throws {
            let h = try home()
            var rows = desktopFixture()
            let plan = try restartPlan(nil, h.paths, rows)
            var calls: [String] = []
            let state = h.paths["state"].str
            let result = try withDesktopRestart(plan, h.paths, fn { () in
                try rename(state, state + ".saved")
                try writeText(state, "state path is unavailable")
            }, NOOP, ["inspect": fn { _ in rows }, "command": fn { args in
                calls.append(args[0].str)
                rows = args[0].str.hasSuffix("osascript") ? [] : Restarts.reopened()
                return ["status": 0]
            }])
            #expect(calls == ["/usr/bin/osascript", "/usr/bin/open"])
            eq(result["restart"]["outcome"], "reopened")
            eq(result["ok"], false)
            match(result["restart"]["error"], "journal could not be saved")
        }

        @Test("a failed progress callback cannot prevent the mandatory reopen")
        func failedProgressCallback() throws {
            let h = try home()
            var rows = desktopFixture(), reportedAfterOpen = false
            let plan = try restartPlan(nil, h.paths, rows)
            var calls: [String] = []
            let result = try withDesktopRestart(plan, h.paths, fn { _ in ["ok": true] }, fn { args in
                if args[0] == "reopen" {
                    reportedAfterOpen = calls.contains("/usr/bin/open")
                    throw EngineError("progress output unavailable")
                }
                return .undefined
            }, ["inspect": fn { _ in rows }, "command": fn { args in
                calls.append(args[0].str)
                rows = args[0].str.hasSuffix("osascript") ? [] : Restarts.reopened()
                return ["status": 0]
            }])
            #expect(calls == ["/usr/bin/osascript", "/usr/bin/open"])
            #expect(reportedAfterOpen)
            eq(result["restart"]["outcome"], "reopened")
            eq(result["ok"], true)
        }

        @Test("new workers invalidate the reviewed restart scope before any quit")
        func newWorkersInvalidate() throws {
            let h = try home()
            let rows = desktopFixture()
            let plan = try restartPlan(nil, h.paths, rows)
            let changed = rows.concat([.spread(rows[1], ["pid": 502, "ids": [Value(id(300))]])])
            var called = false
            let result = try withDesktopRestart(plan, h.paths, fn { () in called = true }, NOOP, [
                "inspect": fn { _ in changed }, "command": fn { _ in called = true; return ["status": 0] },
            ])
            #expect(called == false)
            match(result["error"], "sessions changed")
        }

        @Test("a slow shutdown uses only its shutdown budget and leaves held files untouched")
        func slowShutdown() throws {
            let h = try home()
            let rows = desktopFixture()
            let plan = try restartPlan(nil, h.paths, rows)
            var time = 0.0, moved = false
            let result = try withDesktopRestart(plan, h.paths, fn { () in moved = true }, NOOP, [
                "now": fn { _ in Value(time) }, "shutdownWait": 400, "reserve": 200, "inspect": fn { _ in rows },
                "wait": fn { args in time += args[0].asNumber!; return .undefined }, "command": fn { _ in ["status": 0] },
            ])
            #expect(moved == false)
            #expect(time == 400)
            eq(result["restart"]["outcome"], "quit-not-confirmed")
        }

        @Test("a twenty-second shutdown leaves moving and reopening their own phases")
        func twentySecondShutdown() throws {
            let h = try home()
            var rows = desktopFixture(), time = 0.0
            let plan = try restartPlan(nil, h.paths, rows)
            var calls: [(file: String, timeout: Double)] = []
            let result = try withDesktopRestart(plan, h.paths, fn { args in
                time += 21_999
                try args[0]["check"].call(true)
                return ["ok": true]
            }, NOOP, [
                "now": fn { _ in Value(time) }, "inspect": fn { _ in rows },
                "command": fn { args in
                    calls.append((args[0].str, args[2].asNumber ?? .nan))
                    time += args[0].str.hasSuffix("osascript") ? 20_000 : 7_999
                    rows = args[0].str.hasSuffix("osascript") ? [] : Restarts.reopened()
                    return ["status": 0]
                },
            ])
            eq(result["ok"], true, result["error"].description)
            #expect(time == 49_998)
            #expect(calls.count == 2)
            #expect(calls.first?.timeout == 30_000)
            #expect(calls.last?.timeout == 8_000)
        }

        @Test("recovery reopens an interrupted approved restart without requesting another shutdown")
        func recoveryReopens() throws {
            let h = try home()
            try mkdirp(h.paths["state"])
            try writeJSON(path.join(h.paths["state"].str, "restart.json"), ["outcome": "moving", "desktop": ["pid": 500, "started": "first"]])
            var rows: Value = [], calls: [String] = []
            let result = try sweep(h.paths, ["io": [
                "inspect": fn { _ in rows }, "command": fn { args in calls.append(args[0].str); rows = desktopFixture(); return ["status": 0] },
            ]])
            #expect(calls == ["/usr/bin/open"])
            eq(result["recovered"]["title"], "Interrupted restart")
            eq(try readJSON(path.join(h.paths["state"].str, "restart.json"))["outcome"], "interrupted-reopened")
        }
    }
}
