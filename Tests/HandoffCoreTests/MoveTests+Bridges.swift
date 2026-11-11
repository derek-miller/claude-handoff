import Darwin
import Foundation
import Testing
@testable import HandoffCore

extension Engine.Moves {
    static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test("bridge append rejects the reproduced partial write and concurrent rewrite failures", arguments: ["partial-write", "concurrent-rewrite"])
    func bridgeAppendRejectsPartialWrite(mode: String) throws {
        let h = try bridgeFixture(), transcript = h.transcriptPath
        let inv = try inventory([h.from], h.to, h.paths, NOOP, ["processes": []])
        let realOpen = fs.open, realWrite = fs.handleWrite
        let changedHistory = Data(Self.text(h.before).replacingOccurrences(of: "message 1", with: "concurrently changed history").utf8)
        var injected = false
        var partial: HandoffCore.FileHandle?
        fs.open = { file, flags, mode0 in
            if file != transcript || !Self.mutatingOpen(flags) || injected { return try realOpen(file, flags, mode0) }
            injected = true
            if mode == "concurrent-rewrite" { try writeData(file, changedHistory) }
            let handle = try realOpen(file, flags, mode0)
            if mode == "partial-write" { partial = handle }
            return handle
        }
        fs.handleWrite = { handle, data in
            if let partial, handle === partial {
                try realWrite(handle, data.prefix(25))
                throw makeError("Synthetic partial append", code: "ENOSPC")
            }
            try realWrite(handle, data)
        }
        let result: Value
        do {
            defer { fs.open = realOpen; fs.handleWrite = realWrite }
            result = try move(inv, h.to, h.paths)
        }
        #expect(injected)
        eq(result.ok, true)
        ok(try undo(h.paths, ["processes": []]).dest)
        let after = try readData(transcript)
        assertBridgeRestored(mode == "partial-write" ? h.before : changedHistory, after, h.bridge)
        deq(lines(Self.text(after)).at(-1), h.bridge)
        ok(exists(h.recordFile("P", SOURCE)))
    }

    @Test("bridge append honors native ownership, formatting, aliases and an already cleared pointer",
          arguments: ["foreign", "unknown owner", "destination owner", "other organization", "legacy", "spaced", "no newline", "empty", "foreign session", "parent alias"])
    func bridgeAppendHonorsOwnership(mode: String) throws {
        let h = try bridgeFixture(), bridge = h.bridge
        var transcript = h.transcriptPath
        let entries = lines(Self.text(h.before))
        if mode == "unknown owner" { bridge.removeKey("ownerAccountUuid"); bridge.removeKey("ownerOrganizationUuid") }
        if mode == "destination owner" || mode == "other organization" { bridge.ownerAccountUuid = h.to.account }
        if mode == "destination owner" { bridge.ownerOrganizationUuid = h.to.org }
        if mode == "legacy" { bridge.bridge_session_id = bridge.bridgeSessionId; bridge.removeKey("bridgeSessionId") }
        if mode == "empty" { bridge.bridgeSessionId = "" }
        if mode == "foreign session" { bridge.sessionId = Value(id(799)) }
        entries[entries.length - 1] = bridge
        let text = entries.elements.map { mode == "spaced" ? JSON.text($0, space: 1).replacingOccurrences(of: "\n", with: " ") : JSON.text($0) }.joined(separator: "\n") + (mode == "no newline" ? "" : "\n")
        try writeText(transcript, text)
        if mode == "parent alias" {
            let actual = path.join(h.root, "actual-project")
            try rename(h.project, actual)
            try symlink(actual, h.project)
            transcript = try FileSystem.nativeRealpath(h.transcript(SOURCE))
        }
        let sidecar = path.join(h.project, SOURCE, "agent.jsonl")
        try mkdirp(path.dirname(sidecar))
        try writeText(sidecar, "synthetic sidecar\n")
        let before = try readData(transcript)
        var output: [String] = []
        let result = try move(try inventory([h.from], h.to, h.paths, NOOP, ["processes": []]), h.to, h.paths, fn { args in
            output.append("\(Self.arg(args, 0)) \(Self.arg(args, 1))")
            return .undefined
        })
        eq(result.ok, true)
        eq(result.receipt.failed.length, 0)
        noMatch(output.joined(separator: "\n"), "warning|suppressed|bridge", "i")
        let cleared = !["destination owner", "empty", "foreign session"].contains(mode)
        let after = try readData(transcript), records = lines(Self.text(after))
        #expect(after.prefix(before.count) == before)
        eq(records.length, entries.length + (cleared ? 1 : 0))
        deq(records.filter { MESSAGES.contains($0.type.str) }, entries.filter { MESSAGES.contains($0.type.str) })
        deq(records.filter { $0.type == "history-suppression" }, entries.filter { $0.type == "history-suppression" })
        eq(records.at(-1).bridgeSessionId, cleared ? "" : bridge.bridgeSessionId)
        eq(Value(try readText(sidecar)), "synthetic sidecar\n")
        let all = try accounts(h.paths, []), next = all.find { $0.account.str == h.acct.T }, source = all.find { $0.account.str == h.acct.Z }
        if cleared {
            let again = try move(try inventory([source], next, h.paths, NOOP, ["processes": []]), next, h.paths)
            eq(again.ok, true)
            #expect(try readData(transcript) == after)
        } else {
            ok(try undo(h.paths, ["processes": []]).dest)
            #expect(try readData(transcript) == before)
        }
    }

    @Test("bridge rehome keeps ordinary lines just over 16 MiB movable", arguments: [false, true], [false, true])
    func bridgeRehomeLargeLines(bridge: Bool, tool: Bool) throws {
        let h = try bridgeFixture(), transcript = h.transcriptPath
        let entries = lines(Self.text(h.before)).filter { bridge || $0.type != "bridge-session" }
        let content = Value(String(repeating: "x", count: 16 * 1024 * 1024 + 1))
        entries[0].message.content = tool ? [["type": "tool_result", "tool_use_id": "synthetic", "content": content]] : content
        try h.write(SOURCE, entries)
        let before = try readData(transcript)
        let inv = try inventory([h.from], h.to, h.paths, NOOP, ["processes": []])
        eq(inv.move.length, 1)
        let moved = try move(inv, h.to, h.paths)
        eq(moved.ok, true, moved.receipt.failed.map { $0.error }.join(", "))
        eq(moved.receipt.verification.ok, true)
        let after = try readData(transcript)
        #expect(after.prefix(before.count) == before)
        eq(after.count > before.count, bridge)
        ok(JSON.text(moved.receipt.sessions[0].bridgeAppend ?? .null).utf16.count < 4096)
        deq(try Self.names(h.dir("P")), [])
        ok(try undo(h.paths, ["processes": []]).dest)
        if bridge { assertBridgeRestored(after, try readData(transcript), h.bridge) } else { #expect(try readData(transcript) == before) }
        deq(try Self.names(h.dir("Z")), [])
    }

    @Test("bridge append refuses changed paths and active writers before mutation", arguments: ["missing", "replacement", "symlink", "directory", "parent replacement", "worker"])
    func bridgeAppendRefusesChangedPaths(mode: String) throws {
        let h = try bridgeFixture(), transcript = h.transcriptPath, realOpen = fs.open
        var injected = false, active = false
        let inspect = fn { _ in active ? [["worker": true, "pid": 123, "desktopPid": nil, "ids": [Value(SOURCE)]]] : [] }
        let inv = try inventory([h.from], h.to, h.paths, NOOP, ["inspect": inspect])
        fs.open = { file, flags, mode0 in
            if file == transcript && Self.mutatingOpen(flags) && !injected {
                injected = true
                if mode == "worker" { active = true }
                else if mode == "parent replacement" {
                    try rename(path.dirname(file), "\(path.dirname(file)).old")
                    try mkdirp(path.dirname(file))
                    try writeData(file, h.before)
                } else {
                    try rename(file, "\(file).old")
                    if mode == "replacement" { try writeData(file, h.before) }
                    if mode == "symlink" { try symlink("\(file).old", file) }
                    if mode == "directory" { try mkdirp(file) }
                }
            }
            return try realOpen(file, flags, mode0)
        }
        let result: Value
        do {
            defer { fs.open = realOpen }
            result = try move(inv, h.to, h.paths)
        }
        let healed = ["replacement", "parent replacement"].contains(mode)
        #expect(injected)
        eq(result.ok, Value(healed))
        deq(try Self.names(h.dir("Z")), healed ? [Value("local_\(SOURCE).json")] : [])
        if mode == "missing" { #expect(!exists(transcript)) }
        else if mode == "directory" { eq(try lstat(transcript).isDirectory.call(), true) }
        else if healed { assertBridgeRestored(h.before, try readData(transcript), ["type": "bridge-session", "sessionId": Value(SOURCE), "bridgeSessionId": "", "lastSequenceNum": 0]) }
        else { #expect(try readData(transcript) == h.before) }
        if mode == "symlink" { eq(try lstat(transcript).isSymbolicLink.call(), true) }
        if !healed { ok(exists(h.recordFile("P", SOURCE))) }
    }

    @Test("bridge append keeps unexpected post-write changes pending and untouched", arguments: ["growth", "rewrite", "replacement", "partial growth", "worker"])
    func bridgeAppendKeepsPostWriteChanges(mode: String) throws {
        let h = try bridgeFixture(), transcript = h.transcriptPath, realOpen = fs.open, realWrite = fs.handleWrite
        var injected = false, active = false
        var watched: HandoffCore.FileHandle?
        let inspect = fn { _ in active ? [["worker": true, "pid": 123, "desktopPid": nil, "ids": [Value(SOURCE)]]] : [] }
        let inv = try inventory([h.from], h.to, h.paths, NOOP, ["inspect": inspect])
        fs.open = { file, flags, mode0 in
            let handle = try realOpen(file, flags, mode0)
            if file == transcript && Self.mutatingOpen(flags) && !injected { watched = handle }
            return handle
        }
        fs.handleWrite = { handle, data in
            guard let watched, handle === watched else { return try realWrite(handle, data) }
            try realWrite(handle, mode == "partial growth" ? data.prefix(25) : data)
            injected = true
            if mode == "replacement" { try rename(transcript, "\(transcript).old"); try writeData(transcript, h.before) }
            else if mode == "rewrite" { try writeText(transcript, try readText(transcript).replacingOccurrences(of: "message 1", with: "concurrent history")) }
            else if mode == "worker" { active = true }
            else { try appendText(transcript, "\(JSON.text(entry("user", 3, 2, SOURCE)))\n") }
        }
        do {
            defer { fs.open = realOpen; fs.handleWrite = realWrite }
            throwsError("Local bridge metadata") { try move(inv, h.to, h.paths) }
        }
        #expect(injected)
        let after = try readData(transcript)
        eq(try keepLocal(h.paths).recoveryRequired, true)
        let recovered = try undo(h.paths, ["inspect": inspect])
        let restored = try readData(transcript)
        if mode == "growth" {
            match(recovered.reconciled.error, "interrupted")
            #expect(restored.prefix(after.count) == after)
            deq(lines(Self.text(restored)).at(-1), h.bridge)
            eq(lines(Self.text(restored)).filter { MESSAGES.contains($0.type.str) }.length, 3)
        } else {
            match(recovered.reconciled.error, "bridge|worker")
            #expect(restored == after)
        }
        ok(exists(h.recordFile("P", SOURCE)))
    }

    @Test("bridge restoration follows task-family publication rollback and continuation", arguments: [false, true])
    func bridgeRestorationTaskFamily(later: Bool) throws {
        let h = try taskFamilyFixture(), transcript = h.transcript(SOURCE)
        let bridge: Value = ["type": "bridge-session", "sessionId": Value(SOURCE), "bridgeSessionId": "cse_family", "lastSequenceNum": 9, "ownerAccountUuid": Value(h.acct.P), "ownerOrganizationUuid": Value(h.org.P)]
        try appendText(transcript, "\(JSON.text(bridge))\n")
        let before = try readData(transcript), (from, to) = try h.selection(), realRename = fs.rename
        var injected = false
        fs.rename = { source, target in
            if target == h.targetFile && !injected {
                injected = true
                if later { try appendText(transcript, "\(JSON.text(entry("user", 900, 80, SOURCE)))\n") }
                throw EngineError("Synthetic task publication failure")
            }
            try realRename(source, target)
        }
        let result: Value
        do {
            defer { fs.rename = realRename }
            result = try executeMove([from], to, h.paths, ["processes": []])
        }
        #expect(injected)
        eq(result.ok, true)
        eq(result.receipt.sessions.length, 4)
        deq(try readJSON(h.targetFile), h.targetAfter)
        ok(try undo(h.paths, ["processes": []]).dest)
        let restored = try readData(transcript)
        #expect(restored.prefix(before.count) == before)
        deq(lines(Self.text(restored)).filter { $0.type == "bridge-session" }.at(-1), bridge)
        eq(lines(Self.text(restored)).filter { MESSAGES.contains($0.type.str) }.length, later ? 2 : 1)
        deq(try readJSON(h.sourceFile), h.sourceRegistry)
    }

    @Test("overlapping verified histories refuse absent, ambiguous, or unverified bridge links")
    func overlappingHistoriesRefuseLinks() throws {
        for links in ["none", "multiple", "unverified"] {
            let h = try home(), child = id(777), base = branchEntries(4, SOURCE, 1)
            let bridgeSessionIds: Value = links == "multiple" ? ["session_linked_fork"] : []
            try h.write(SOURCE, base)
            try h.record("T", SOURCE, rehomeRecord(["bridgeSessionIds": bridgeSessionIds]))
            try h.write(child, fork(base, SOURCE, child, "Fork"))
            try h.record("P", child, rehomeRecord(["forkedFromSessionId": Value("local_\(SOURCE)"), "bridgeSessionIds": bridgeSessionIds]))
            if links == "unverified" {
                let shorter = id(778)
                try h.write(shorter, fork(base.slice(0, 3), SOURCE, shorter, "Shorter fork"))
                try h.record("T", shorter, rehomeRecord(["forkedFromSessionId": Value("local_\(SOURCE)"), "bridgeSessionIds": ["session_linked_fork"]]))
            }
            let cloud = cloudFixture(h, [
                "list": fn { _ in [remoteSession(["id": "cse_linked_fork", "title": "Remote fork"])] },
                "eventRows": fn { _ in remoteRows(base) },
            ])
            let all = try accounts(h.paths), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
            let inv = try inventory([from], to, h.paths, NOOP, ["cloud": cloud])
            deq(inv.cloud.matches, [], links)
            eq(inv.cloud.blocked.length, 1, links)
            match(inv.cloud.blocked[0].error, "multiple .*local target")
        }
    }

    @Test("a bridge marker without a recognized id remains conservatively bridged")
    func bridgeMarkerWithoutId() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE), ["type": "bridge-session", "sessionId": Value(SOURCE)]])
        try h.record("P", SOURCE, rehomeRecord())
        let from = try h.account("P"), to = try h.account("Z")
        let inv = try inventory([from], to, h.paths)
        eq(inv.move[0].bridge, true)
        deq(inv.move[0].bridgeIds, [])
    }
}
