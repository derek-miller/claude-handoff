import Foundation
import Testing
@testable import HandoffCore

extension Engine.Restarts {
    @Test("restart snapshots notice in-place external dependencies before registry publication")
    func snapshotsNoticeExternalDependencies() throws {
        let h = try taskCheckpointFixture(), foreign = id(799)
        try h.record("T", foreign, rehomeRecord())
        let (from, to) = try Self.pair(h, "P", "T", []), mock = taskHarness()
        let plan = try executeMove([from], to, h.paths, ["io": mock.io])
        let write = fs.writeFile
        var edited = false
        fs.writeFile = { p, d, flag, m in
            try write(p, d, flag, m)
            if !edited && p.hasPrefix(h.targetFile + ".") {
                edited = true
                let file = h.recordFile("T", foreign), record = try readJSON(file)
                record["forkedFromSessionId"] = Value("local_\(h.sessions[0])")
                try writeJSON(file, record)
            }
        }
        let result = try executeMove([from], to, h.paths, ["io": mock.io, "approve": plan["plan"]["token"]])
        fs.writeFile = write
        #expect(edited)
        eq(result["ok"], false)
        eq(result["recoveryRequired"], true)
        ok(!exists(h.targetFile))
        eq(try readJSON(h.recordFile("T", foreign))["forkedFromSessionId"], Value("local_\(h.sessions[0])"))
        try h.record("T", foreign, rehomeRecord())
        mock.rows = []
        _ = try finishWorkflow(h.paths, ["io": mock.io, "processes": []])
        deq(try readJSON(h.sourceFile), h.sourceRegistry)
    }

    @Test("polling without productive work stalls without racing unfinished mutations")
    func pollingWithoutProductiveWork() throws {
        let h = try home(), mock = taskHarness(desktopFixture())
        let plan = try restartPlan(nil, h.paths, mock.rows)
        var settled = false
        let command = mock.io["command"]
        mock.io["command"] = fn { args in
            if args[0].str.hasSuffix("/open") { #expect(settled) }
            return try command.callArgs(args)
        }
        let result = try withDesktopRestart(plan, h.paths, fn { args in
            mock.time += 61_000
            settled = true
            try args[0]["check"].call()
            return .undefined
        }, NOOP, mock.io)
        eq(result["ok"], false)
        eq(result["code"], "MOVE_STALLED")
        eq(result["restart"]["outcome"], "reopened")
        #expect(mock.calls == ["/usr/bin/osascript", "/usr/bin/open"])
    }

    @Test("a forced boundary detects reopening before retirement even inside the polling interval")
    func forcedBoundaryDetectsReopening() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE, rehomeRecord())
        let (from, to) = try Self.pair(h)
        var rows = desktopFixture(), opens = 0
        let io: Value = ["now": fn { _ in 0 }, "inspect": fn { _ in rows }, "command": fn { args in
            if !args[0].str.hasSuffix("osascript") { opens += 1 }
            rows = []
            return ["status": 0]
        }]
        let planned = try executeMove([from], to, h.paths, ["io": io])
        let result = try executeMove([from], to, h.paths, ["io": io, "approve": planned["plan"]["token"], "report": fn { args in
            if args[0] == "verify" && Self.arg(args, 2)["completed"] == 1 { rows = Self.reopened() }
            return .undefined
        }])
        eq(result["ok"], false)
        match(result["reason"], "reopened before")
        eq(opens, 0)
        ok(exists(h.recordFile("P", SOURCE)))
    }

    @Test("restart warnings group a helper and its child as one session and resolve copied records")
    func restartWarningsGroupHelpers() throws {
        let h = try home(), other = id(400)
        try h.record("P", SOURCE, ["title": "First session"])
        try h.record("T", other, ["title": "Second session"])
        try h.record("Z", other, ["title": "Second session"])
        let rows: Value = [
            desktopFixture()[0],
            ["pid": 501, "ppid": 500, "started": "helper one", "executable": "/Applications/Claude.app/Contents/Helpers/disclaimer", "worker": true, "desktopPid": 500, "ids": []],
            ["pid": 502, "ppid": 501, "started": "child one", "executable": "/tmp/claude", "worker": true, "desktopPid": 500, "ids": [Value(SOURCE)]],
            ["pid": 503, "ppid": 500, "started": "helper two", "executable": "/Applications/Claude.app/Contents/Helpers/disclaimer", "worker": true, "desktopPid": 500, "ids": []],
            ["pid": 504, "ppid": 503, "started": "child two", "executable": "/tmp/claude", "worker": true, "desktopPid": 500, "ids": [Value(other)]],
        ]
        let plan = try restartPlan(nil, h.paths, rows)
        eq(plan["affected"].length, 2)
        deq(plan["affected"].map { $0["title"] }, ["First session", "Second session"])
        deq(plan["affected"].map { $0["pids"] }, [[501, 502], [503, 504]])
        eq(plan["members"].length, 5)
        let unknown = try restartPlan(nil, h.paths, rows.map { .spread($0, ["ids": []]) })
        eq(unknown["affected"].length, 2)
    }
}
