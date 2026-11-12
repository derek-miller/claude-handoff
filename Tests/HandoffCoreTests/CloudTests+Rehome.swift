import Foundation
import Testing
@testable import HandoffCore

extension Engine.Cloud {
    // SOURCE with one sidecar, rehomed from P's own organization to its team organization T.
    static func rehomeToTeam(_ h: Home) throws -> (teamDir: String, transcript: String, sidecarDir: String, from: Value, to: Value) {
        let teamDir = path.join(h.paths["records"].str, h.acct.P, h.org.T)
        try mkdirp(teamDir)
        let transcript = h.transcript(SOURCE), sidecarDir = path.join(h.project, SOURCE)
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try mkdirp(sidecarDir)
        try writeText(path.join(sidecarDir, "agent.jsonl"), "{\"before\":true}\n")
        try h.record("P", SOURCE, rehomeRecord())
        let all = try accounts(h.paths)
        let from = all.find { $0["account"].str == h.acct.P && $0["org"].str == h.org.P }
        let to = all.find { $0["account"].str == h.acct.P && $0["org"].str == h.org.T }
        return (teamDir, transcript, sidecarDir, from, to)
    }

    @Test("interrupted rehome recovery identifies vanished shared artifacts")
    func interruptedRehomeVanished() throws {
        let h = try home(), r = try Engine.Cloud.rehomeToTeam(h)
        let moved = try move(try inventory([r.from], r.to, h.paths), r.to, h.paths)
        let receipt = try readJSON(moved["file"].str)
        receipt["finalizing"] = true
        try writeJSON(moved["file"].str, receipt)
        try rename(r.transcript, "\(r.transcript).missing")
        try rename(r.sidecarDir, "\(r.sidecarDir).missing")
        let recovered = try undo(h.paths)
        match(recovered["reconciled"]["error"], "changed copies left in place")
        let tracked = try readJSON(moved["file"].str)
        match(tracked["failed"].at(-1)["error"], "\(SOURCE)\\.jsonl is missing, \(SOURCE) is missing")
        ok(exists(h.recordFile("P", SOURCE)))
        ok(exists(path.join(r.teamDir, "local_\(SOURCE).json")))
    }

    @Test("rehome undo refuses when shared artifacts vanished")
    func rehomeUndoVanished() throws {
        let h = try home(), r = try Engine.Cloud.rehomeToTeam(h)
        eq(try move(try inventory([r.from], r.to, h.paths), r.to, h.paths)["ok"], true)
        try rename(r.transcript, "\(r.transcript).missing")
        try rename(r.sidecarDir, "\(r.sidecarDir).missing")
        let refused = try undo(h.paths)
        match(refused["changed"][0], "transcript missing, sidecars missing changed")
        ok(!exists(h.recordFile("P", SOURCE)))
        ok(exists(path.join(r.teamDir, "local_\(SOURCE).json")))
    }

    @Test("restart reuses preparation across cloud and local phases and reparses only changed history")
    func restartReusesPreparation() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE)
        for offset in 0..<180 {
            let session = id(2000 + offset)
            try h.write(session, [entry("user", 10000 + offset, nil, session)])
            try h.record("T", session)
        }
        let all = try accounts(h.paths), from = all.find { $0["account"].str == h.acct.P }, to = all.find { $0["account"].str == h.acct.T }
        var rows = desktopFixture(), scanned: Value = .undefined
        let cloud = cloudFixture(h)
        let io: Value = ["inspect": fn { _ in rows }, "command": fn { args in
            if args[0].str.hasSuffix("osascript") {
                try appendText(h.transcript(SOURCE), JSON.text(entry("assistant", 2, 1, SOURCE)) + "\n")
                rows = []
            } else {
                rows = [.spread(desktopFixture()[0], ["pid": 700, "desktopPid": 700, "started": "new"])]
            }
            return ["status": 0]
        }]
        let planned = try executeMove([from], to, h.paths, ["cloud": cloud, "io": io])
        ok(planned["plan"])
        let result = try executeMove([from], to, h.paths, ["cloudRequested": true, "io": io, "approve": planned["plan"]["token"],
                                                         "summary": fn { args in scanned = args[0]["cacheStats"]; return .undefined }])
        eq(result["ok"], true)
        eq(result["receipt"]["sessions"].length, 1)
        eq(scanned["historyHits"], 180)
        eq(scanned["historyMisses"], 1)
        eq(result["receipt"]["sessions"][0]["events"], 2)
    }
}
