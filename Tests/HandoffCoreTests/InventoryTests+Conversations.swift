import Foundation
import Testing
@testable import HandoffCore

extension Engine.Inventory {
    @Test("canonical user messages keep their exact hash and order beside richer previews and consumed copies")
    func canonicalUserMessages() throws {
        let text = "Synthetic text"
        let blocks: Value = [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "YWJj"]], ["type": "text", "text": Value(text)]]
        let user: Value = ["type": "user", "uuid": Value(id(8000)), "sessionId": Value(SOURCE), "message": ["role": "user", "content": Value(text)]]
        let attachment: Value = ["type": "attachment", "sessionId": Value(SOURCE), "attachment": ["type": "queued_command", "source_uuid": user.uuid, "delivery_id": "delivery", "prompt": blocks]]
        let removed: Value = ["type": "queue-operation", "sessionId": Value(SOURCE), "operation": "remove", "reason": "absorbed_mid_turn", "commandUuid": user.uuid, "deliveryId": "delivery"]
        let session = Value(SOURCE)
        for rows in [[user, attachment, removed], [removed, attachment, user], [attachment, removed, user], [user, attachment, removed, user, removed]] as [Value] {
            let before = JSON.text(rows)
            deq(try conversation(rows, session), try conversation([user]))
            eq(JSON.text(rows), before)
        }
        let preceding = entry("assistant", 8010, nil, SOURCE), following = entry("assistant", 8011, nil, SOURCE)
        for reverse in [false, true] {
            let canonical = Value.spread(user, ["message": ["role": "user", "content": reverse ? blocks : Value(text)]])
            let consumed = Value.spread(removed, ["content": reverse ? Value(text) : blocks])
            let expected = try conversation([canonical])
            for rows in [[canonical, attachment, consumed], [consumed, attachment, canonical], [attachment, consumed, canonical, consumed]] as [Value] {
                deq(try conversation(rows, session), expected)
            }
            deq(try conversation([attachment, consumed, preceding, canonical, following], session), try conversation([preceding, canonical, following]))
            deq(try conversation([preceding, canonical, following, attachment, consumed], session), try conversation([preceding, canonical, following]))
            let conflictingUser = Value.spread(canonical, ["message": ["role": "user", "content": reverse ? Value(text) : blocks]])
            deq(try conversation([canonical, attachment, consumed, conflictingUser], session), [])
            deq(try conversation([conflictingUser, attachment, consumed, canonical], session), [])
            deq(try conversation([canonical, attachment, consumed, .spread(consumed, ["content": canonical.message.content])], session), [])
            deq(try conversation([canonical, attachment, .spread(consumed, ["deliveryId": "different"])], session), [])
            let changedPrompt = Value.spread(attachment, ["attachment": .spread(attachment.attachment, ["prompt": queuedImagePrompt(text + " changed")])])
            deq(try conversation([canonical, changedPrompt, consumed], session), [])
        }
        let differentImage: Value = [.spread(blocks[0], ["source": .spread(blocks[0].source, ["data": "ZGlmZmVyZW50"])]), blocks[1]]
        let differentAttachment = Value.spread(attachment, ["attachment": .spread(attachment.attachment, ["prompt": differentImage])])
        deq(try conversation([user, attachment, removed, differentAttachment], session), [])
        let second = Value.spread(user, ["uuid": Value(id(8001))])
        deq(try conversation([user, attachment, removed, second, user], session), try conversation([user, second]))
    }

    @Test("queued text and image copies use the exact consumed payload without losing command multiplicity")
    func queuedTextAndImageCopies() throws {
        let text = "  Synthetic image question\nwith exact spacing  ", blocks = queuedImagePrompt(text), session = Value(SOURCE)
        for reverse in [false, true] {
            let payload = reverse ? blocks : Value(text)
            let consumed: Value = ["type": "queue-operation", "operation": "remove", "reason": "absorbed_mid_turn", "sessionId": session, "commandUuid": Value(id(8000)), "deliveryId": "delivery-1", "content": payload]
            let attachment: Value = ["type": "attachment", "uuid": Value(id(8100)), "sessionId": session,
                                     "attachment": ["type": "queued_command", "source_uuid": consumed.commandUuid, "delivery_id": consumed.deliveryId, "prompt": reverse ? Value(text) : blocks]]
            let user = entry("user", 8000, nil, SOURCE, ["message": ["role": "user", "content": payload]])
            let expected = try conversation([user])
            for copies in [[attachment, consumed], [consumed, attachment], [attachment, attachment, consumed, consumed], [user, attachment, consumed], [attachment, user, consumed]] as [Value] {
                let before = JSON.text(copies)
                deq(try conversation(copies, session), expected)
                eq(JSON.text(copies), before)
            }
            let second = Value.spread(consumed, ["commandUuid": Value(id(8001)), "deliveryId": "delivery-2"])
            let secondAttachment = Value.spread(attachment, ["uuid": Value(id(8101)), "attachment": .spread(attachment.attachment, ["source_uuid": second.commandUuid, "delivery_id": second.deliveryId])])
            deq(try conversation([attachment, consumed, secondAttachment, second, consumed, secondAttachment], session), expected.concat(expected))
            deq(try conversation([attachment, consumed, .spread(consumed, ["content": reverse ? Value(text) : blocks])], session), [])
            deq(try conversation([attachment, consumed, .spread(consumed, ["deliveryId": "conflicting-delivery"])], session), [])
            let different = reverse ? Value(text + " changed") : queuedImagePrompt(text + " changed")
            deq(try conversation([.spread(attachment, ["attachment": .spread(attachment.attachment, ["prompt": different])]), consumed], session), [])
            let elsewhere = try conversation([attachment, .spread(consumed, ["sessionId": Value(id(2))])], session)
            deq(elsewhere, reverse ? try conversation([.spread(user, ["message": ["role": "user", "content": Value(text)]])]) : [])
        }
        let consumed: Value = ["type": "queue-operation", "operation": "remove", "reason": "absorbed_mid_turn", "sessionId": session, "commandUuid": Value(id(8000)), "deliveryId": "delivery-1", "content": Value(text)]
        let attachment: Value = ["type": "attachment", "uuid": Value(id(8100)), "sessionId": session, "attachment": ["type": "queued_command", "source_uuid": Value(id(8000)), "delivery_id": "delivery-1", "prompt": blocks]]
        let differentImage: Value = [.spread(blocks[0], ["source": .spread(blocks[0].source, ["data": "ZGlmZmVyZW50"])]), blocks[1]]
        deq(try conversation([attachment, consumed, .spread(attachment, ["uuid": Value(id(8101)), "attachment": .spread(attachment.attachment, ["prompt": differentImage])])], session), [])
        let incompatibles: [Value] = [
            blocks.concat([["type": "text", "text": ""]]),
            [["type": "document", "source": blocks[0].source], blocks[1]],
            [blocks[0], .spread(blocks[1], ["otherFilledValue": "different representation"])],
        ]
        for incompatible in incompatibles {
            deq(try conversation([consumed, .spread(attachment, ["attachment": .spread(attachment.attachment, ["prompt": incompatible])])], session), [])
        }
        deq(try conversation([attachment, .spread(attachment, ["uuid": Value(id(8101)), "attachment": .spread(attachment.attachment, ["prompt": Value(text)])])], session), [])
    }

    // The reference LCS the Node suite compares the bounded matcher against.
    static func referenceMatch(_ source: [Int], _ target: [Int]) -> Value {
        if source.isEmpty { return .null }
        var counts: [Int: Int] = [:]
        for value in target { counts[value, default: 0] += 1 }
        for value in source {
            guard let n = counts[value], n > 0 else { return .null }
            counts[value] = n - 1
        }
        var previous = Array(repeating: 0, count: target.count + 1)
        for value in source {
            var next = [0]
            for at in stride(from: 1, through: target.count, by: 1) {
                next.append(value == target[at - 1] ? previous[at - 1] + 1 : max(previous[at], next[at - 1]))
            }
            previous = next
        }
        let missing = source.count - previous[target.count]
        return missing == 0 ? "ordered" : missing <= min(8, source.count / 100) ? "equivalent" : .null
    }

    static func ints(_ xs: [Int]) -> Value { Value(xs.map { Value($0) }) }

    @Test("bounded near-order matching agrees with reference LCS and exact multiplicities")
    func boundedNearOrderMatching() throws {
        for length in [0, 1, 99, 100, 199, 200, 799, 800, 1000] {
            let source = Array(0..<length)
            var swaps = 0
            while swaps <= 9 && swaps * 2 <= length {
                var target = source
                for i in stride(from: 0, to: swaps * 2, by: 2) { target.swapAt(i, i + 1) }
                eq(try conversationMatch(Self.ints(source), Self.ints(target)), Self.referenceMatch(source, target), "\(length)/\(swaps)")
                swaps += 1
            }
        }
        var seed: UInt32 = 123456
        func random(_ limit: Int) -> Int { seed = seed &* 1664525 &+ 1013904223; return Int(seed % UInt32(limit)) }
        for trial in 0..<350 {
            let source = (0..<(random(230) + 1)).map { _ in random(7) }
            var target = source
            var swaps = random(10)
            while swaps > 0 {
                let a = random(target.count), b = random(target.count)
                target.swapAt(a, b)
                swaps -= 1
            }
            if trial % 3 == 0 { target.remove(at: random(target.count)) }
            if trial % 5 == 0 { target.insert(random(7), at: random(target.count)) }
            eq(try conversationMatch(Self.ints(source), Self.ints(target)), Self.referenceMatch(source, target), "random case \(trial)")
        }
        let same = Value(Array(repeating: Value("same"), count: 100))
        eq(try conversationMatch(same, Value(Array(repeating: Value("same"), count: 99) + ["other"])), nil)
    }

    // Node ran this in a child process with a 15 s timeout and logged the duration; here it runs in process
    // against the same 15 s budget.
    @Test("bounded near-order matching handles large histories without quadratic work or counter overflow")
    func boundedNearOrderMatchingLarge() throws {
        let started = Date()
        let source = Array(0..<100_000)
        var target = source
        for i in stride(from: 0, to: 16, by: 2) { target.swapAt(i, i + 1) }
        eq(try conversationMatch(Self.ints(source), Self.ints(target)), "equivalent")
        target.swapAt(16, 17)
        eq(try conversationMatch(Self.ints(source), Self.ints(target)), nil)
        eq(try conversationMatch(Self.ints(source), Self.ints(Array(source[1...]) + [source[0]])), "equivalent")
        eq(try conversationMatch(Self.ints(source + [source[0]]), Self.ints(target)), nil)
        let elapsed = Date().timeIntervalSince(started)
        ok(elapsed < 15, "four 100k-message comparisons took \(elapsed) s")
    }

    @Test("sidecar link changes invalidate plans and link targets cannot masquerade as regular sidecars")
    func sidecarLinkChanges() throws {
        for scenario in ["changed link", "link replaced by file", "relative roots", "link vs file"] {
            let h = try home(), other = id(8301), entries = branchEntries(4, SOURCE, 1)
            try h.write(SOURCE, entries)
            try h.record("P", SOURCE, rehomeRecord())
            let dir = path.join(h.project, SOURCE), file = path.join(dir, "snapshot")
            try mkdirp(dir)
            try symlink("relative-destination", file)
            if ["relative roots", "link vs file"].contains(scenario) {
                try h.write(other, fork(entries, SOURCE, other, "Synthetic other"))
                try h.record("Z", other, rehomeRecord())
                let second = path.join(h.project, other)
                try mkdirp(second)
                if scenario == "relative roots" { try symlink("relative-destination", path.join(second, "snapshot")) }
                else { try writeText(path.join(second, "snapshot"), "relative-destination") }
            }
            let all = try accounts(h.paths, []), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.Z }
            let inv = try inventory([from], to, h.paths, NOOP, ["processes": [], "writeCache": true])
            eq(inv.move.length, 1, scenario)
            eq(inv.there.length, 0, scenario)
            if scenario.hasPrefix("changed") || scenario == "link replaced by file" {
                try unlink(file)
                if scenario == "changed link" { try symlink("different", file) } else { try writeText(file, "relative-destination") }
                var reports: [Value] = []
                let moved = try move(inv, to, h.paths, fn { args in reports.append(Self.arg(args, 0)); return .undefined })
                ok(reports.contains("recovery"), scenario)
                eq(moved.ok, true, scenario)
            }
        }
    }

    @Test("sidecar link replacements are refused during regular reads and warm cache verification")
    func sidecarLinkReplacements() throws {
        for warm in [false, true] {
            let h = try home(), dir = path.join(h.project, SOURCE), file = path.join(dir, "snapshot"), external = path.join(h.root, "synthetic-target")
            try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
            try h.record("P", SOURCE, rehomeRecord())
            try mkdirp(dir)
            try writeText(file, "original")
            try writeText(external, "never read this synthetic target")
            let all = try accounts(h.paths, []), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.Z }
            if warm { _ = try inventory([from], to, h.paths, NOOP, ["processes": [], "writeCache": true]) }
            let physicalFile = try NodeFS.nativeRealpath(file), physicalExternal = try NodeFS.nativeRealpath(external)
            let originalOpen = fs.open, originalLstat = fs.lstat
            var replaced = false
            let replace = { replaced = true; try unlink(file); try symlink(external, file) }
            fs.open = { name, flags, mode in
                ne(Value(name), Value(physicalExternal))
                if name == physicalFile && !warm && !replaced {
                    ok(flags & O_NOFOLLOW != 0)
                    try replace()
                }
                return try originalOpen(name, flags, mode)
            }
            fs.lstat = { name, big in
                let detail = try originalLstat(name, big)
                if name == physicalFile && warm && !replaced { try replace() }
                return detail
            }
            let inv: Value
            do {
                defer { fs.open = originalOpen; fs.lstat = originalLstat }
                inv = try inventory([from], to, h.paths, NOOP, ["processes": [], "writeCache": true])
            }
            #expect(replaced)
            eq(inv.move.length, 0)
            eq(inv.rejected.length, 1)
        }
    }

    @Test("sidecar root links refuse inventory without traversing targets or changing accounts")
    func sidecarRootLinks() throws {
        for scenario in ["dangling root", "live root"] {
            let h = try home(), dir = path.join(h.project, SOURCE), external = path.join(h.root, "unrelated"), other = id(8302)
            try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
            try h.record("P", SOURCE, rehomeRecord())
            try h.write(other, [entry("user", 2, nil, other)])
            try h.record("Z", other, rehomeRecord())
            if scenario == "live root" {
                try mkdirp(external)
                try writeText(path.join(external, "unrelated.txt"), "Synthetic target that the walker must not read")
            }
            try symlink(external, dir)
            let link = dir, inode = try lstat(link).ino
            let physicalDir = path.join(try NodeFS.nativeRealpath(h.project), SOURCE), physicalExternal = path.join(try NodeFS.nativeRealpath(h.root), "unrelated")
            let before = try fixtureSnapshot(h, [h.dir("P"), h.dir("Z")])
            let all = try accounts(h.paths, []), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.Z }
            let check = { (name: String, key: String) in
                ok(name != dir && !name.hasPrefix(dir + "/"), "sidecar root target \(key)")
                ok(name != external && !name.hasPrefix(external + "/"), "external target \(key)")
                ok(name != physicalDir && !name.hasPrefix(physicalDir + "/"), "physical sidecar target \(key)")
                ok(name != physicalExternal && !name.hasPrefix(physicalExternal + "/"), "physical external target \(key)")
            }
            let readdirOriginal = fs.readdir, readFileOriginal = fs.readFile, openOriginal = fs.open
            fs.readdir = { name in check(name, "readdir"); return try readdirOriginal(name) }
            fs.readFile = { name in check(name, "readFile"); return try readFileOriginal(name) }
            fs.open = { name, flags, mode in check(name, "open"); return try openOriginal(name, flags, mode) }
            let inv: Value
            do {
                defer { fs.readdir = readdirOriginal; fs.readFile = readFileOriginal; fs.open = openOriginal }
                inv = try inventory([from], to, h.paths, NOOP, ["processes": []])
            }
            eq(inv.move.length, 0, scenario)
            eq(inv.there.length, 0, scenario)
            eq(inv.rejected.length, 1, scenario)
            eq(inv.rejected[0].error, Value("unsupported entry \(dir)"), scenario)
            deq(try fixtureSnapshot(h, [h.dir("P"), h.dir("Z")]), before, scenario)
            eq(String(decoding: try NodeFS.nativeReadlink(link), as: UTF8.self), external)
            eq(try lstat(link).ino, inode)
            ok(!exists(h.paths.state.str))
        }
    }
}
