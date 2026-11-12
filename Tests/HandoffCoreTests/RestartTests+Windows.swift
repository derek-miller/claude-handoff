import Foundation
import Testing
@testable import HandoffCore

extension Engine.Restarts {
    @Test("task moves, Undo and recovery use the approved restart and preserve final scheduler state")
    func approvedRestartPreservesSchedulerState() throws {
        for operation in ["move", "undo", "recovery"] {
            let h = try taskFamilyFixture(), (from, to) = try h.selection()
            if operation == "undo" { _ = try executeMove([from], to, h.paths, ["processes": []]) }
            if operation == "recovery" { try interruptTaskFamily(h, "move", "target") }
            let mock = taskHarness()
            if operation == "move" {
                mock.beforeQuit = {
                    h.sourceRegistry["scheduledTasks"][0]["lastScheduledFor"] = "2026-09-03T00:00:00Z"
                    h.sourceRegistry["scheduledTasks"][0]["enabled"] = true
                    try writeJSON(h.sourceFile, h.sourceRegistry)
                }
            }
            let run = { (options: Value) throws -> Value in
                operation == "move" ? try executeMove([from], to, h.paths, options) : operation == "undo" ? try undo(h.paths, options) : try finishWorkflow(h.paths, options)
            }
            let plan = try run(["io": mock.io])
            ok(plan["plan"], operation)
            #expect(mock.calls == [])
            let result = try run(["io": mock.io, "approve": plan["plan"]["token"]])
            eq(result["restarted"], true, JSON.text(["operation": Value(operation), "reason": result["reason"], "outcome": result["restartOutcome"]["outcome"]]))
            #expect(mock.calls == ["/usr/bin/osascript", "/usr/bin/open"], "\(operation)")
            ok(mock.time < 30000, operation)
            if operation == "move" {
                eq(result["ok"], true)
                deq(try readJSON(h.targetFile)["scheduledTasks"].slice(1), h.sourceRegistry["scheduledTasks"])
            } else {
                ok(operation == "undo" ? result["dest"] : result["recoveryRequired"], operation)
                deq(try readJSON(h.sourceFile), h.sourceRegistry, operation)
            }
        }
    }

    @Test("task workers and changed restart inventories never authorize an external stop")
    func taskWorkersNeverAuthorizeExternalStop() throws {
        let h = try taskFamilyFixture(), (from, to) = try h.selection()
        let table = desktopFixture().concat([["pid": 600, "worker": true, "ids": [Value(h.run)], "desktopPid": nil]])
        let result = try executeMove([from], to, h.paths, ["processes": table])
        eq(result["plan"], .undefined)
        deq(result["receipt"]["sessions"].map { $0["id"] }, [Value(h.cold)])
        deq(try readJSON(h.sourceFile), h.sourceRegistry)
        var calls: [String] = []
        let io: Value = ["inspect": fn { _ in [desktopFixture()[0]] }, "command": fn { args in calls.append(args[0].str); return ["status": 0] }]
        eq(try finishWorkflow(h.paths, ["io": io])["plan"], .undefined)
        #expect(calls == [])
    }

    @Test("productive preparation and cold moving do not spend shutdown or moving time")
    func productivePreparation() throws {
        for phase in ["scan", "move", "verify", "retire"] {
            let h = try taskFamilyFixture(), (from, to) = try h.selection(), mock = taskHarness()
            let planned = try executeMove([from], to, h.paths, ["io": mock.io])
            var delayed = false
            let result = try executeMove([from], to, h.paths, ["io": mock.io, "approve": planned["plan"]["token"], "report": fn { args in
                if args[0].str == phase && Self.arg(args, 2)["preparatory"].truthy && !delayed { delayed = true; mock.time += 180_000 }
                return .undefined
            }])
            #expect(delayed, "\(phase)")
            eq(result["ok"], true, result["reason"].description)
            eq(result["receipt"]["sessions"].length, 4)
            #expect(mock.calls == ["/usr/bin/osascript", "/usr/bin/open"])
            eq(result["restartOutcome"]["deadline"], .undefined)
            deq(try readJSON(h.targetFile), h.targetAfter)
        }
    }

    // History reads advance the clock when a transcript is opened for reading: FileHandle.read bypasses the fs table.
    @Test("productive reads and awaited mutations can exceed both old restart windows")
    func productiveReadsAndMutations() throws {
        for phase in ["history", "publication", "retirement", "durability"] {
            let h = try taskFamilyFixture(), (from, to) = try h.selection(), mock = taskHarness()
            if phase == "durability" {
                try appendText(h.transcript(SOURCE), JSON.text(["type": "bridge-session", "sessionId": Value(SOURCE), "bridgeSessionId": "session_fixture", "ownerAccountUuid": Value(h.acct.P), "ownerOrganizationUuid": Value(h.org.P)]) + "\n")
            }
            let planned = try executeMove([from], to, h.paths, ["io": mock.io])
            let native = (readFile: fs.readFile, link: fs.link, rename: fs.rename, open: fs.open, sync: fs.handleSync)
            var timings: [Value] = [], writing = false, delayed = 0
            let run = mock.io["command"]
            mock.io["command"] = fn { args in eq(writing, false); timings.append(Self.arg(args, 2)); return try run.callArgs(args) }
            fs.readFile = { p in
                let result = try native.readFile(p)
                if phase == "history" && mock.rows.length == 0 && p.hasSuffix(".jsonl") { mock.time += 90_000; delayed += 1 }
                return result
            }
            fs.open = { p, flags, mode in
                let handle = try native.open(p, flags, mode)
                if phase == "history" && p.hasSuffix(".jsonl") && !Self.mutatingOpen(flags) && mock.rows.length == 0 { mock.time += 90_000; delayed += 1 }
                return handle
            }
            fs.handleSync = { handle in
                if phase == "durability" && handle.path.hasSuffix(".journal") {
                    writing = true; mock.time += 90_000; delayed += 1
                    try native.sync(handle)
                    writing = false
                    return
                }
                try native.sync(handle)
            }
            fs.link = { a, b in
                let selected = mock.rows.length == 0 && phase == "publication" && path.dirname(b) == h.dir("T")
                if selected { writing = true; mock.time += 90_000; delayed += 1 }
                defer { writing = false }
                try native.link(a, b)
            }
            fs.rename = { a, b in
                let selected = mock.rows.length == 0 && phase == "retirement" && path.dirname(a) == h.dir("P")
                if selected { writing = true; mock.time += 90_000; delayed += 1 }
                defer { writing = false }
                try native.rename(a, b)
            }
            let result = try executeMove([from], to, h.paths, ["io": mock.io, "approve": planned["plan"]["token"]])
            (fs.readFile, fs.link, fs.rename, fs.open, fs.handleSync) = native
            ok(delayed > 0, phase)
            eq(result["ok"], true, result["reason"].description)
            eq(result["receipt"]["sessions"].length, 4)
            deq(Value(timings), [30_000, 8_000], phase)
            eq(result["restartOutcome"]["deadline"], .undefined)
            ok(try undo(h.paths, ["processes": []])["dest"])
        }
    }
}
