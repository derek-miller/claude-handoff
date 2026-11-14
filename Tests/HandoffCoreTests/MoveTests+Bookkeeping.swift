import Foundation
import Testing
@testable import HandoffCore

extension Engine.Moves {
    static func moved(_ h: Home) throws -> Value {
        try executeMove([try h.account("P")], try h.account("T"), h.paths, ["processes": []])
    }

    @Test("a move carries queued input, the archive flag and filed suggestions, and Undo takes back only those")
    func carriesBookkeeping() throws {
        let h = try home(), record = "local_\(SOURCE)", other = "local_\(id(901))"
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE)
        let p = h.dir("P"), t = h.dir("T")
        for dir in [path.join(p, "waiting-input", record), path.join(p, "backlog")] { try mkdirp(dir) }
        try writeJSON(path.join(p, "waiting-input", "\(record).json"), ["v": 1, "sessionId": Value(record), "entries": [["uuid": "u1"]]])
        try writeText(path.join(p, "waiting-input", record, "attachment"), "bytes")
        try writeJSON(path.join(p, "waiting-input", "\(other).json"), ["v": 1, "sessionId": Value(other)])
        try writeJSON(path.join(p, "archived-sessions.idx"), ["v": 1, "archived": [Value(other), Value(record)]])
        try writeJSON(path.join(p, "backlog", "tasks.json"), ["version": 1, "items": [
            ["id": "todo_mine", "originSessionId": Value(record), "source": "dismissed"],
            ["id": "todo_other", "originSessionId": Value(other), "source": "evicted"],
        ]])
        try mkdirp(t)
        let destIndex = path.join(t, "archived-sessions.idx")
        try writeJSON(destIndex, ["v": 1, "archived": ["local_kept"]])
        let sourceBefore = try [path.join(p, "archived-sessions.idx"), path.join(p, "backlog", "tasks.json")].map(readText)

        let result = try Self.moved(h)
        ok(result["ok"])
        eq(readOrNil(path.join(t, "waiting-input", "\(record).json")), readOrNil(path.join(p, "waiting-input", "\(record).json")))
        eq(readOrNil(path.join(t, "waiting-input", record, "attachment")), "bytes")
        ok(!exists(path.join(t, "waiting-input", "\(other).json")))
        eq(try readJSON(destIndex)["archived"].elements.map(\.str), ["local_kept", record])
        eq(try readJSON(path.join(t, "backlog", "tasks.json"))["items"].elements.map { $0["id"].str }, ["todo_mine"])
        eq(try [path.join(p, "archived-sessions.idx"), path.join(p, "backlog", "tasks.json")].map(readText), sourceBefore)
        ok(exists(path.join(p, "waiting-input", "\(record).json")))

        ok(try undo(h.paths)["dest"])
        ok(!exists(path.join(t, "waiting-input", "\(record).json")))
        ok(!exists(path.join(t, "waiting-input", record)))
        eq(try readJSON(destIndex)["archived"].elements.map(\.str), ["local_kept"])
        ok(!exists(path.join(t, "backlog")))
        eq(try [path.join(p, "archived-sessions.idx"), path.join(p, "backlog", "tasks.json")].map(readText), sourceBefore)
        ok(exists(path.join(p, "waiting-input", record, "attachment")))
    }

    @Test("a session without Desktop bookkeeping moves and undoes as before")
    func noBookkeeping() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE)
        let result = try Self.moved(h)
        ok(result["ok"])
        eq(result["receipt"]["sessions"][0]["bookkeeping"], .undefined)
        let t = h.dir("T")
        for name in ["waiting-input", "backlog", "archived-sessions.idx"] { ok(!exists(path.join(t, name))) }
        ok(try undo(h.paths)["dest"])
        ok(exists(h.recordFile("P", SOURCE)))
    }

    @Test("a move never overwrites destination bookkeeping and Undo leaves it in place")
    func keepsDestinationBookkeeping() throws {
        let h = try home(), record = "local_\(SOURCE)"
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE)
        let p = h.dir("P"), t = h.dir("T")
        for dir in [p, t].flatMap({ [path.join($0, "waiting-input"), path.join($0, "backlog")] }) { try mkdirp(dir) }
        try writeText(path.join(p, "waiting-input", "\(record).json"), "source")
        try writeJSON(path.join(p, "archived-sessions.idx"), ["v": 1, "archived": [Value(record)]])
        try writeJSON(path.join(p, "backlog", "tasks.json"), ["version": 1, "items": [["id": "todo_same", "originSessionId": Value(record)]]])
        try writeText(path.join(t, "waiting-input", "\(record).json"), "destination")
        try writeJSON(path.join(t, "archived-sessions.idx"), ["v": 1, "archived": [Value(record)]])
        try writeJSON(path.join(t, "backlog", "tasks.json"), ["version": 1, "items": [["id": "todo_same", "originSessionId": "local_elsewhere"]]])
        let destBefore = try ["waiting-input/\(record).json", "archived-sessions.idx", "backlog/tasks.json"].map { try readText(path.join(t, $0)) }

        let result = try Self.moved(h)
        ok(result["ok"])
        eq(result["receipt"]["sessions"][0]["bookkeeping"], .undefined)
        ok(try undo(h.paths)["dest"])
        eq(try ["waiting-input/\(record).json", "archived-sessions.idx", "backlog/tasks.json"].map { try readText(path.join(t, $0)) }, destBefore)
    }
}
