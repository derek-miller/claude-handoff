import Foundation
import Testing
@testable import HandoffCore

extension Engine.Cloud {
    @Test("native prior bindings stay scoped to the source login when several accounts move together")
    func nativePriorScopedToLogin() throws {
        let f = try nativePriorFixture(), h = f.h
        let secondRecord = h.recordFile("T", SOURCE)
        try rename(h.recordFile("P", SOURCE), secondRecord)
        let rows = lines(try readText(f.priorFile))
        rows.find { $0.type == "bridge-session" }.ownerAccountUuid = Value(h.acct.T)
        rows.find { $0.type == "bridge-session" }.ownerOrganizationUuid = Value(h.org.T)
        try h.write(f.prior, rows)
        let all = try accounts(h.paths, []), other = all.find { $0.account.str == h.acct.T }
        let inv = try inventory([all.find { $0.account.str == h.acct.P }, other], f.to, h.paths, NOOP, ["cloud": f.cloud, "processes": []])
        ok(inv.move[0].retainedHistories.length > 0)
        ok(inv.cloud.matches.every { !$0.target.retained.truthy })
        eq(f.archives, 0)
    }

    @Test("retained image attachments and consumed text match existing targets immediately and after deferred cleanup")
    func retainedImagesMatch() throws {
        for deferred in [false, true] {
            for reverse in [false, true] {
                let label = "deferred \(deferred) reverse \(reverse)"
                let f = try nativePriorFixture(), h = f.h
                let rows = lines(try readText(f.priorFile))
                let enriched = Value(rows.elements.enumerated().flatMap { index, row -> [Value] in
                    if row.type != "queue-operation" { return [row] }
                    let text = row.content, blocks = queuedImagePrompt(text.str), consumed = Value.spread(row, ["content": reverse ? blocks : text])
                    f.remote.find { $0.uuid === row.commandUuid }.message.content = consumed.content
                    let attachment: Value = ["type": "attachment", "uuid": Value(id(90000 + index)), "sessionId": Value(f.prior),
                                             "attachment": ["type": "queued_command", "source_uuid": row.commandUuid, "delivery_id": row.deliveryId, "prompt": reverse ? text : blocks]]
                    return [attachment, consumed, .spread(attachment, ["uuid": Value(id(91000 + index))]), .spread(consumed)]
                })
                try h.write(f.prior, enriched)
                let files = [f.priorFile, h.transcript(SOURCE)], before = try files.map { try readData($0) }
                let expectedHash = sha(JSON.text(try conversation(f.remote)))
                if !deferred { try rename(h.recordFile("P", SOURCE), h.recordFile("Z", SOURCE)) }
                let all = try accounts(h.paths, []), from = all.find { $0.account.str == h.acct.P }, to = all.find { $0.account.str == h.acct.Z }
                let inv = try inventory([from], to, h.paths, NOOP, ["cloudRequested": true, "cloud": deferred ? .null : f.cloud, "processes": [], "writeCache": true])
                let prior = (deferred ? inv.move[0] : inv.targets[0]).retainedHistories[0]
                eq(prior.conversation.length, f.remote.length, label)
                if !deferred {
                    eq(inv.cloud.matches.length, 1)
                    eq(inv.cloud.matches[0].target.kind, "existing")
                    eq(inv.cloud.matches[0].target.matchMode, "equivalent")
                    eq(inv.cloud.matches[0].conversationSha, Value(expectedHash))
                }
                let moved = try move(inv, to, h.paths)
                eq(moved.ok, true, JSON.text(moved.receipt.failed))
                let result = deferred ? try finishPending(h.paths, ["cloud": f.cloud, "processes": []]) : moved
                eq(result.ok, true, JSON.text(result.failed))
                eq(result.complete, true, label)
                eq(result.receipt.remote.length, 1, label)
                eq(result.receipt.remote[0].targetKind, "existing")
                eq(result.receipt.remote[0].matchMode, "equivalent")
                eq(result.receipt.remote[0].conversationSha, Value(expectedHash))
                eq(result.receipt.sessions.some { $0.strategy == "remote" }, false)
                eq(f.archives, 1, label)
                #expect(try files.map { try readData($0) } == before, "\(label)")
            }
        }
    }

    @Test("retained image attachments with different text do not prove cloud containment")
    func retainedImagesDifferentText() throws {
        let f = try nativePriorFixture(), h = f.h
        let rows = Value(lines(try readText(f.priorFile)).elements.enumerated().flatMap { index, row -> [Value] in
            if row.type != "queue-operation" { return [row] }
            return [["type": "attachment", "uuid": Value(id(90000 + index)), "sessionId": Value(f.prior),
                     "attachment": ["type": "queued_command", "source_uuid": row.commandUuid, "delivery_id": row.deliveryId, "prompt": queuedImagePrompt(row.content.str + " different text")]], row]
        })
        try h.write(f.prior, rows)
        let before = try readData(f.priorFile)
        let inv = try inventory([f.from], f.to, h.paths, NOOP, ["cloud": f.cloud, "processes": []])
        deq(inv.cloud.matches, [])
        eq(f.archives, 0)
        #expect(try readData(f.priorFile) == before)
    }

    @Test("supplemental queued text and image coverage keeps the consumed representation and rejects conflicting copies")
    func supplementalQueuedCoverage() throws {
        for scenario in ["consumed string", "consumed array", "conflicting consumed", "conflicting image", "different text"] {
            let f = try artifactFixture(), text = "Synthetic supplemental image question", blocks = queuedImagePrompt(text)
            let reverse = scenario == "consumed array"
            f.queued.attachment.prompt = reverse ? Value(text) : blocks
            f.removal.content = reverse ? blocks : Value(text)
            f.remote.at(-1).message.content = f.removal.content
            if scenario == "conflicting consumed" { f.extra.push(.spread(f.removal, ["content": blocks])) }
            if scenario == "conflicting image" {
                f.extra.push(.spread(f.removal, ["operation": "enqueue", "content": [.spread(blocks[0], ["source": .spread(blocks[0].source, ["data": "ZGlmZmVyZW50"])]), blocks[1]]]))
            }
            if scenario == "different text" { f.queued.attachment.prompt = queuedImagePrompt(text + " different") }
            try f.write()
            let inv = try f.inventory()
            if scenario.hasPrefix("consumed") {
                eq(inv.cloud.matches[0].target.matchMode, "artifacts", scenario)
                deq(inv.cloud.matches[0].target.artifactCounts, ["main": 365, "subagent": 104, "queued": 1], scenario)
            } else {
                deq(inv.cloud.matches, [], scenario)
                eq(inv.cloud.blocked[0].code, "CLOUD_ARTIFACT_UNCERTAIN", scenario)
            }
        }
    }

    @Test("retained bridge bindings deduplicate exact repeats and keep a conflicting owner untrusted")
    func retainedBindingsDeduplicate() throws {
        for conflict in [false, true] {
            let f = try nativePriorFixture(), h = f.h, rows = lines(try readText(f.priorFile))
            let bridge = rows.find { $0.type == "bridge-session" }
            var repeated: [Value] = (0..<1104).map { _ in .spread(bridge) }
            if conflict { repeated.insert(.spread(bridge, ["ownerAccountUuid": Value(h.acct.T)]), at: 552) }
            try h.write(f.prior, rows.filter { $0.type != "bridge-session" }.concat(Value(repeated)))
            let before = try readData(f.priorFile)
            let inspect = { (inv: Value) in
                if conflict {
                    eq(inv.move[0].retainedHistories, .undefined)
                    ok(inv.cloud.matches.every { !$0.target.retained.truthy })
                } else {
                    eq(inv.move[0].retainedHistories.length, 1)
                    eq(inv.move[0].retainedHistories[0].bindings.length, 1)
                    eq(inv.cloud.matches[0].target.matchMode, "equivalent")
                }
            }
            inspect(try inventory([f.from], f.to, h.paths, NOOP, ["cloud": f.cloud, "processes": [], "writeCache": true]))
            let file = path.join(h.paths.state.str, "cache.json"), cache = try readJSON(file)
            let stored = cache.histories.valuesArray.find { item in item.value.dependencies.some { $0[0].str == f.priorFile } }.value.result
            eq(stored.bridgeOwners.length, conflict ? 2 : 1)
            let first = stored.bridgeOwners[0], other = stored.bridgeOwners[1]
            var owners: [Value] = (0..<1104).map { _ in first }
            if !other.isUndefined { owners.insert(other, at: 552) }
            stored.bridgeOwners = Value(owners)
            try writeJSON(file, cache)
            let warm = try inventory([f.from], f.to, h.paths, NOOP, ["cloud": f.cloud, "processes": []])
            eq(warm.cacheStats.historyMisses, 0)
            inspect(warm)
            #expect(try readData(f.priorFile) == before)
        }
    }

    @Test("retained native proof pins a trusted project alias before archival")
    func retainedProofPinsAlias() throws {
        for deferred in [false, true] {
            let f = try nativePriorFixture(), h = f.h, change = try mappedProjectFixture(h)
            let inv = try inventory([f.from], f.to, h.paths, NOOP, ["cloudRequested": true, "cloud": deferred ? .null : f.cloud, "processes": []])
            if !deferred { try change() }
            let moved = try move(inv, f.to, h.paths)
            if deferred {
                f.cloud.eventRows = fn { _ in
                    f.reads += 1
                    if f.reads == 3 { try change() }
                    return remoteRows(f.remote)
                }
                let finished = try finishPending(h.paths, ["cloud": f.cloud, "processes": []])
                eq(finished.ok, false)
            } else {
                eq(moved.ok, false)
            }
            eq(f.archives, 0, "deferred \(deferred)")
        }
    }
}
