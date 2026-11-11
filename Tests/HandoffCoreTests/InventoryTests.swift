import Foundation
import Testing
@testable import HandoffCore

extension Engine {
    @Suite("inventory and planning")
    struct Inventory {
        // A callback argument the engine may not pass.
        static func arg(_ args: [Value], _ i: Int) -> Value { i < args.count ? args[i] : .undefined }

        static let imageBytes = Data(repeating: 0xab, count: 96 * 1024)

        // The text and image file-read payloads the replay tests share, keyed by the field a replay blanks.
        static func fileReads() -> [(type: String, key: String, file: Value)] {
            let text: Value = ["filePath": "/tmp/fixture.txt", "content": "full file body", "numLines": 1]
            let image: Value = ["base64": Value(imageBytes.base64EncodedString()), "dimensions": ["width": 256, "height": 128], "originalSize": Value(96 * 1024), "type": "image/png"]
            return [("text", "content", text), ("image", "base64", image)]
        }

        static func names(_ dir: String) throws -> Value { .strings(try readdir(dir)) }

        // The last row per account wins.
        static func byAccount(_ h: Home, _ processes: Value = .undefined) throws -> [String: Value] {
            var out: [String: Value] = [:]
            for row in try accounts(h.paths, processes).elements { out[row.account.str] = row }
            return out
        }

        @Test("a destination arriving after planning is never quarantined by a failed placement")
        func destinationArrivingAfterPlanning() throws {
            let h = try home()
            try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
            try h.record("P", SOURCE)
            let from = try h.account("P"), to = try h.account("T")
            let target = h.recordFile("T", SOURCE), foreign = "{\"title\":\"independent arrival\"}\n"
            let result = try executeMove([from], to, h.paths, ["processes": [], "summary": fn { () in try writeText(target, foreign) }])
            eq(result.ok, false)
            eq(try readText(target), foreign)
            ok(exists(h.recordFile("P", SOURCE)))
        }

        @Test("normalize collapses replays and reports conflicts")
        func normalizeCollapsesReplays() throws {
            let a = entry("user", 1, nil, id(0))
            let b = entry("user", 2, 1, id(0), ["toolUseResult": ["stdout": "", "stderr": ""]])
            let rich = Value.spread(b, ["toolUseResult": ["stdout": "rich", "stderr": ""]])
            let replay = try normalize([a, b, rich])
            eq(replay.replays, 1)
            deq(replay.entries, [a, rich])
            let c = entry("assistant", 3, 2, id(0))
            let moved = Value.spread(c, ["parentUuid": Value(id(1)), "cwd": "/elsewhere", "gitBranch": "other", "slug": "x", "promptId": "p"])
            eq(try normalize([a, b, c, moved]).replays, 1)
            eq(try normalize([a, b, .spread(b, ["parentUuid": Value(id(9))])]).conflicts, 1)
            let conflict = try normalize([a, b, .spread(b, ["message": ["role": "user", "content": "other"]])])
            eq(conflict.conflicts, 1)
            eq(conflict.entries.length, 3)
        }

        @Test("file-read replays keep the full payload and refuse incompatible copies")
        func fileReadReplays() throws {
            let parent = entry("assistant", 1, nil, SOURCE)
            let snapshots = ["1eb370dc75ffeb3c25ea8cbd9b5cf2c10916baa3441492ac4749a156a23d8c91", "ce9edbd7fdd2d1531c89919b8cd343335e3f784f633e92f07f386cf86c8b5e8a"]
            for ((type, key, file), snapshot) in zip(Inventory.fileReads(), snapshots) {
                let full = entry("user", 2, 1, SOURCE, ["toolUseResult": ["type": Value(type), "file": file]])
                eq(try semantic([parent, full], Value(SOURCE)), Value(snapshot))
                for omitted in [false, true] {
                    let replay = Value.spread(full, ["toolUseResult": .spread(full.toolUseResult, ["file": .spread(file, [key: ""])])])
                    if omitted { replay.toolUseResult.file.removeKey(key) }
                    for rows in [[parent, full, replay], [parent, replay, full]] as [Value] {
                        let before = rows.deepClone(), result = try normalize(rows)
                        eq(result.conflicts, 0)
                        eq(result.replays, 1)
                        deq(result.entries, [parent, full])
                        eq(result.entries[1], full)
                        eq(try semantic(rows, Value(SOURCE)), Value(snapshot))
                        deq(rows, before)
                        if key == "base64" { #expect(Data(base64Encoded: result.entries[1].toolUseResult.file.base64.str) == Inventory.imageBytes) }
                    }
                }
                var incompatible: [Value] = ([Value(Data("different payload".utf8).base64EncodedString()), 42, ["text": "unexpected shape"]] as [Value]).map { .spread(file, [key: $0]) }
                let changes: [Value] = type == "text"
                    ? [["filePath": "/tmp/other.txt"], ["numLines": 2]]
                    : [["dimensions": ["width": 512, "height": 128]], ["originalSize": 1], ["type": "image/jpeg"]]
                incompatible += changes.map { .spread(file, [key: ""], $0) }
                incompatible.append(.spread(file, [key: "", "extra": true]))
                for changedFile in incompatible {
                    let changed = Value.spread(full, ["toolUseResult": .spread(full.toolUseResult, ["file": changedFile])])
                    for rows in [[parent, full, changed], [parent, changed, full]] as [Value] {
                        let result = try normalize(rows)
                        eq(result.conflicts, 1)
                        eq(result.replays, 0)
                        deq(result.entries, rows)
                    }
                }
                let fileOnly = Value.spread(full, ["toolUseResult": .spread(full.toolUseResult, ["stdout": "", "stderr": ""])])
                let outputOnly = Value.spread(full, ["toolUseResult": .spread(full.toolUseResult, ["stdout": "command output", "stderr": "command error", "file": .spread(file, [key: ""])])])
                let complete = Value.spread(full, ["toolUseResult": .spread(outputOnly.toolUseResult, ["file": file])])
                for copies in [[fileOnly, outputOnly], [outputOnly, fileOnly]] {
                    eq(try normalize(Value([parent] + copies)).conflicts, 1)
                    for rows in [Value([parent] + copies + [complete]), Value([parent, complete] + copies)] {
                        let result = try normalize(rows)
                        eq(result.conflicts, 0)
                        deq(result.entries, [parent, complete])
                        eq(result.entries[1], complete)
                    }
                }
            }
        }

        @Test("edited-text attachment replays ignore only their display path")
        func editedTextAttachmentReplays() throws {
            let parent = entry("assistant", 1, nil, SOURCE)
            let original = entry("attachment", 2, 1, SOURCE, ["attachment": ["type": "edited_text_file", "filename": "/tmp/fixture.txt", "snippet": "synthetic file edit"]])
            let replay = Value.spread(original, ["attachment": .spread(original.attachment, ["displayPath": "fixture.txt"])])
            eq(try semantic([parent, original], Value(SOURCE)), "3a7e37a2ae90a9f7fbf77ef203cf3ec5ba6427da4fe10508d8774052f1cba8fa")
            eq(try semantic([parent, replay], Value(SOURCE)), "c53ead433799ea63ec5dfda594a9bb3f6ce9fb74699f9913238f080ab637236c")
            for rows in [[parent, original, replay], [parent, replay, original]] as [Value] {
                let before = rows.deepClone(), result = try normalize(rows)
                eq(result.conflicts, 0)
                eq(result.replays, 1)
                deq(result.entries, [parent, rows[1]])
                eq(result.entries[1], rows[1])
                deq(rows, before)
            }
            let attachments: [Value] = [
                .spread(replay.attachment, ["filename": "/tmp/other.txt"]),
                .spread(replay.attachment, ["snippet": "different edit"]),
                .spread(replay.attachment, ["type": "other"]),
                .spread(replay.attachment, ["extra": true]),
            ]
            for attachment in attachments {
                let changed = Value.spread(replay, ["attachment": attachment])
                for rows in [[parent, original, changed], [parent, changed, original]] as [Value] { eq(try normalize(rows).conflicts, 1) }
            }
            eq(try normalize([parent, original, .spread(replay, ["displayPath": "top-level.txt"])]).conflicts, 1)
            for (type, kind) in [("attachment", "other"), ("user", "edited_text_file"), ("system", "edited_text_file"), ("progress", "edited_text_file")] {
                let other = Value.spread(original, ["type": Value(type), "attachment": .spread(original.attachment, ["type": Value(kind)])])
                let otherReplay = Value.spread(other, ["attachment": .spread(other.attachment, ["displayPath": "fixture.txt"])])
                for rows in [[parent, other, otherReplay], [parent, otherReplay, other]] as [Value] { eq(try normalize(rows).conflicts, 1) }
            }
        }

        @Test("a transcript with a compact file-read replay rehomes intact and is not retired into a poorer fork")
        func compactFileReadReplayRehomes() throws {
            for (_, key, file) in Inventory.fileReads() {
                let h = try home()
                let type = key == "content" ? "text" : "image"
                let parent = entry("assistant", 1, nil, SOURCE)
                let full = entry("user", 2, 1, SOURCE, ["toolUseResult": ["type": Value(type), "file": file]])
                let replay = Value.spread(full, ["toolUseResult": .spread(full.toolUseResult, ["file": .spread(file, [key: ""])])])
                try h.write(SOURCE, [parent, full, replay])
                try h.record("P", SOURCE, rehomeRecord(["title": "Replayed file read"]))
                try h.write(id(991), fork([parent, replay], SOURCE, id(991), "Poorer fork"))
                try h.record("T", id(991), rehomeRecord(["title": "Poorer fork"]))
                let from = try h.account("P"), to = try h.account("T")
                let transcript = h.transcript(SOURCE)
                let before = try readData(transcript), beforeStat = try stat(transcript)
                let inv = try inventory([from], to, h.paths)
                eq(inv.blocked.length, 0)
                eq(inv.there.length, 0)
                eq(inv.move.length, 1)
                let moved = try move(inv, to, h.paths)
                eq(moved.ok, true)
                eq(moved.receipt.sessions[0].strategy, "rehome")
                #expect(try readData(transcript) == before)
                eq(try stat(transcript).ino, beforeStat.ino)
                eq(try accounts(h.paths).find { $0.account.str == h.acct.P }.sessions.length, 0)
            }
        }

        @Test("semantic change detection keeps richer output and parse state")
        func semanticChangeDetection() throws {
            let a = entry("user", 1, nil, id(0))
            let plain = entry("user", 2, 1, id(0), ["toolUseResult": ["stdout": "", "stderr": ""]])
            let rich = Value.spread(plain, ["toolUseResult": ["stdout": "finished", "stderr": ""]])
            let session = Value(id(0))
            eq(try semantic([a, plain, rich], session), "79163d4f82bf5ea15a60aa7fd8993e49fb2788ca942eca14951f5796bc5a113c")
            ne(try semantic([a, plain], session), try semantic([a, rich], session))
            ne(try semantic([a, rich], session), try semantic([a, rich], session, 1))
            let before: Value = [a, rich, ["type": "relocated", "sessionId": session, "relocatedCwd": "/before"]]
            let after: Value = [a, rich, ["type": "relocated", "sessionId": session, "relocatedCwd": "/after"]]
            ne(try semantic(before, session), try semantic(after, session))
        }

        @Test("generic replay omissions keep an existing complete row and protect filled values and structure")
        func genericReplayOmissions() throws {
            let parent = entry("assistant", 1, nil, SOURCE)
            let row = { (toolUseResult: Value) in entry("user", 2, 1, SOURCE, ["toolUseResult": toolUseResult]) }
            for value in ["full file", 0, false, [1, ["nested": "value"]]] as [Value] {
                let rich = row(["invented": ["nested": value]])
                for blank in [.undefined, .null, "", [], [:]] as [Value] {
                    let poor = row(["invented": ["nested": blank]])
                    for copies in [[rich, poor], [poor, rich]] {
                        let result = try normalize(Value([parent] + copies))
                        eq(result.conflicts, 0)
                        eq(result.entries[1], rich)
                    }
                }
            }
            let pairs: [(Value, Value)] = [
                (["originalFile": "first"], ["originalFile": "second"]),
                (["a": "filled", "b": ""], ["a": "", "b": "filled"]),
                (["a.b": "filled"], ["a": ["b": "filled"]]),
                (["a": [1, 2]], ["a": [2, 1]]),
                (["a": [1]], ["a": [1, 2]]),
                (["a": 0], ["a": false]),
            ]
            for (a, b) in pairs { eq(try normalize([parent, row(a), row(b)]).conflicts, 1) }
            let rich = row(["originalFile": "full"]), poor = row(["originalFile": ""])
            eq(try semantic([parent, rich, poor], Value(SOURCE)), "abe8cf96e0c1c0d00bf5fb8c58791cc5f08890e923c97e34967d98713fcf9ae9")
            eq(try semantic([parent, poor, rich], Value(SOURCE)), "a751c53b3a13d465d865ee4a3383320e2620f48090c4aaa2eacfbe18c0472d67")
            for changed in [.spread(poor, ["message": ["role": "user", "content": "different"]]), .spread(poor, ["parentUuid": Value(id(999))])] as [Value] {
                eq(try normalize([parent, rich, changed]).conflicts, 1)
            }
            let first = row(["stdout": "full"]), later = Value.spread(first, ["cwd": "/a/much/longer/runtime/path"])
            eq(try normalize([parent, first, later]).entries[1], first)
            for stdout in ["", "stdout"] {
                for stderr in ["", "stderr"] {
                    for content in ["", "file"] {
                        let complete = row(["stdout": Value(stdout), "stderr": Value(stderr), "file": ["content": Value(content)]])
                        let copies: [Value] = [complete, .spread(complete, ["cwd": "/long/runtime/value"]), row(["stdout": "", "stderr": "", "file": ["content": ""]])]
                        for rows in [Value([parent] + copies), Value([parent] + copies.reversed())] {
                            let legacy = try normalize(rows, false)
                            eq(legacy.conflicts, 0)
                            eq(try normalize(rows).entries[1], legacy.entries[1])
                        }
                    }
                }
            }
        }

        @Test("originalFile replays rehome and retire intact while lineage covers only poorer histories")
        func originalFileReplaysRehome() throws {
            for metadata in [false, true] {
                for order in [false, true] {
                    for richerTarget in [false, true] {
                        let h = try home(), parent = entry("assistant", 1, nil, SOURCE)
                        let rich = entry("user", 2, 1, SOURCE, ["toolUseResult": ["originalFile": "synthetic complete file", "invented": ["nested": false]]])
                        let poor = Value.spread(rich, ["toolUseResult": ["originalFile": "", "invented": [:]]])
                        if metadata {
                            rich.origin = ["producer": "desktop"]
                            rich.message = .spread(rich.message, ["usage": ["output_tokens": 42]])
                            poor.message = .spread(poor.message, ["usage": ["output_tokens": 0]])
                        }
                        let entries = Value([parent] + (order ? [poor, rich] : [rich, poor]))
                        try h.write(SOURCE, richerTarget ? [parent, poor] : entries)
                        try h.record("P", SOURCE, rehomeRecord())
                        try h.write(id(991), fork([parent, richerTarget ? rich : poor], SOURCE, id(991), "Fork"))
                        try h.record("T", id(991), rehomeRecord())
                        let from = try h.account("P"), to = try h.account("T")
                        let before = try readData(h.transcript(SOURCE))
                        let inv = try inventory([from], to, h.paths, NOOP, ["processes": []])
                        eq(inv.blocked.length, 0)
                        eq(inv.there.length, richerTarget ? 1 : 0)
                        let result = try move(inv, to, h.paths)
                        eq(result.ok, true)
                        eq(result.receipt.superseded.filter { $0.source.truthy }.length, 1)
                        #expect(try readData(h.transcript(SOURCE)) == before)
                        ok(try undo(h.paths, ["processes": []]).dest)
                    }
                }
            }
        }

        @Test("a sole Desktop owner moves by identity when its replay history cannot be parsed")
        func soleOwnerMovesByIdentity() throws {
            let parent = entry("user", 1, nil, SOURCE)
            let read = entry("user", 2, 1, SOURCE, ["toolUseResult": ["originalFile": "synthetic complete file"]])
            let reply = entry("assistant", 2, 1, SOURCE, ["message": ["role": "assistant", "content": "same response", "usage": ["output_tokens": 42]], "origin": ["kind": "local", "producer": "desktop"]])
            let shapes: [(String, [Value])] = [
                ("Oct 3", [read, .spread(read, ["toolUseResult": ["originalFile": ""]]), ["origin": ["producer": "desktop"]]]),
                ("Oct 7", [reply, .spread(reply, ["message": .spread(reply.message, ["usage": ["output_tokens": 0]]), "origin": ["kind": "local"]]), ["toolUseResult": ["originalFile": "replay only"]]]),
            ]
            let errors = ["conflict": "conflicting duplicate uuids", "unparseable": "unparseable lines", "unreadable": "forced parse failure"]
            for (name, shape) in shapes {
                let (full, replay, complement) = (shape[0], shape[1], shape[2])
                for mode in ["conflict", "unparseable", "unreadable"] {
                    for shared in [false, true] {
                        let h = try home(), label = "\(name) \(mode) \(shared ? "shared" : "sole")", transcript = h.transcript(SOURCE)
                        let entries: Value = [parent, full, mode == "conflict" ? .spread(replay, complement) : replay]
                        eq(try normalize(entries).conflicts, Value(mode == "conflict" ? 1 : 0), label)
                        try h.write(SOURCE, entries)
                        if mode == "unparseable" { try appendText(transcript, "{\"type\":\"user\",\"uuid\":\"broken\n") }
                        try h.record("P", SOURCE, rehomeRecord())
                        if shared { try h.record("Q", SOURCE, rehomeRecord()) }
                        let before = try readData(transcript), native = fs.readFile
                        if mode == "unreadable" {
                            fs.readFile = { file in if file == transcript { throw EngineError("forced parse failure") }; return try native(file) }
                        }
                        defer { fs.readFile = native }
                        let from = try h.account("P"), to = try h.account("T")
                        let result = try move(try inventory([from], to, h.paths, NOOP, ["processes": []]), to, h.paths)
                        if shared {
                            eq(result.receipt.sessions.length, 0, label)
                            match(result.receipt.failed[0].error, errors[mode]!)
                            deq(try Inventory.names(h.dir("T")), [], label)
                            deq(try Inventory.names(h.dir("P")), [Value("local_\(SOURCE).json")], label)
                        } else {
                            eq(result.ok, true, label)
                            eq(result.receipt.sessions.length, 1, label)
                            eq(result.receipt.superseded.filter { $0.source.truthy }.length, 1, label)
                            deq(try Inventory.names(h.dir("P")), [], label)
                            deq(try Inventory.names(h.dir("T")), [Value("local_\(SOURCE).json")], label)
                            ok(try undo(h.paths, ["processes": []]).dest, label)
                            deq(try Inventory.names(h.dir("T")), [], label)
                        }
                        fs.readFile = native
                        #expect(try readData(transcript) == before, Comment(rawValue: label))
                    }
                }
            }
        }

        @Test("a transcript with fork lineage stays non-sole when its ancestor read fails")
        func forkLineageAncestorReadFails() throws {
            let h = try home(), ancestor = id(740), base = branchEntries(2, ancestor, 740)
            try h.write(ancestor, base)
            try h.write(SOURCE, fork(base, ancestor, SOURCE, "Fork"))
            try h.record("P", SOURCE, rehomeRecord())
            let all = try accounts(h.paths, []), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.T }
            let native = fs.readFile, blocked = h.transcript(ancestor)
            var failed = false
            fs.readFile = { file in
                if file == blocked { failed = true; throw EngineError("forced ancestor read failure") }
                return try native(file)
            }
            let inv: Value
            do { defer { fs.readFile = native }; inv = try inventory([from], to, h.paths, NOOP, ["processes": []]) }
            #expect(failed)
            let source = inv.sources.find { $0.id.str == SOURCE }
            deq(source.lineage, [Value(ancestor)])
            eq(source.sole, false)
            ok(!inv.move.some { $0.id.str == SOURCE })
        }
    }
}
