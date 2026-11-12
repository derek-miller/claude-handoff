import Foundation
import Testing
@testable import HandoffCore

extension Engine.Cloud {
    @Test("consumed queue prompts preserve exact content and command multiplicity")
    func consumedQueuePrompts() throws {
        let content = "  Synthetic queued prompt\nwith exact spacing  "
        let consumed: Value = ["type": "queue-operation", "operation": "remove", "reason": "absorbed_mid_turn", "sessionId": Value(SOURCE),
                               "commandUuid": Value(id(8000)), "deliveryId": "delivery-1", "content": Value(content)]
        let user = entry("user", 8000, nil, SOURCE, ["message": ["role": "user", "content": Value(content)]])
        let attachment: Value = ["type": "attachment", "uuid": Value(id(8100)), "sessionId": Value(SOURCE),
                                 "attachment": ["type": "queued_command", "source_uuid": Value(id(8000)), "delivery_id": "delivery-1", "prompt": Value(content)]]
        let expected = try conversation([user])
        let source = Value(SOURCE)
        let copies: [Value] = [[consumed], [consumed, consumed], [user, consumed], [attachment, consumed], [user, attachment, consumed], [consumed, attachment, user]]
        for list in copies { deq(try conversation(list, source), expected, JSON.text(list.map { $0["type"] })) }
        let unused: [Value] = [
            .spread(consumed, ["operation": "enqueue"]), .spread(consumed, ["reason": "cancelled"]), .spread(consumed, ["operation": "dequeue"]),
            .spread(consumed, ["reason": "unrelated"]), .spread(consumed, ["sessionId": Value(id(2))]), .spread(consumed, ["sessionId": .undefined]),
            .spread(consumed, ["commandUuid": .undefined, "deliveryId": .undefined]),
        ]
        for row in unused { deq(try conversation([row], source), [], JSON.text(row)) }
        let conflicts: [Value] = [
            .spread(consumed, ["content": Value("\(content)!")]), .spread(consumed, ["deliveryId": "different-delivery"]),
            .spread(consumed, ["commandUuid": Value(id(8001))]), .spread(consumed, ["reason": "cancelled"]),
            .spread(attachment, ["attachment": .spread(attachment["attachment"], ["prompt": "different"])]),
            .spread(user, ["message": ["role": "user", "content": Value(content.trimmingCharacters(in: .whitespacesAndNewlines))]]),
        ]
        for conflict in conflicts { deq(try conversation([consumed, conflict], source), [], JSON.text(conflict)) }
        deq(try conversation([consumed, .spread(consumed, ["commandUuid": Value(id(8001)), "deliveryId": "delivery-2"])], source), expected.concat(expected))
        deq(try conversation([consumed, .spread(consumed, ["commandUuid": .undefined])], source), expected)
        deq(try conversation([consumed, .spread(consumed, ["deliveryId": .undefined])], source), expected)
        let unidentified = Value.spread(attachment, ["attachment": ["prompt": Value(content)]])
        deq(try conversation([unidentified, consumed], source), expected)
        deq(try conversation([user, unidentified, consumed], source), expected)
        deq(try conversation([.spread(user, ["uuid": Value(id(8001))]), consumed], source), expected.concat(expected))
        eq(try conversation([.spread(unidentified, ["attachment": ["prompt": Value(content + " different")]]), consumed], source).length, 2)
        let blocks: Value = [["type": "text", "text": Value(content)], ["type": "image", "source": ["type": "base64", "data": "YWJj", "media_type": "image/png"]]]
        deq(try conversation([.spread(consumed, ["content": blocks])], source), try conversation([.spread(user, ["message": ["role": "user", "content": blocks]])]))
        deq(try conversation([consumed, .spread(attachment, ["attachment": .spread(attachment["attachment"], ["prompt": blocks])])], source), expected)
    }

    @Test("consumed queue-only messages prove cloud containment without changing transcript semantics")
    func consumedQueueContainment() throws {
        for operation in ["consumed", "enqueue", "cancelled"] {
            let h = try home(), entries = branchEntries(4, SOURCE, 1), prompt = entry("user", 8000, 4, SOURCE)
            let queue: Value = ["type": "queue-operation", "sessionId": Value(SOURCE), "commandUuid": prompt["uuid"], "deliveryId": "delivery", "content": prompt["message"]["content"],
                                "operation": Value(operation == "enqueue" ? "enqueue" : "remove"), "reason": Value(operation == "cancelled" ? "cancelled" : "absorbed_mid_turn")]
            try h.write(SOURCE, entries.concat([queue, queue]))
            try h.record("Z", SOURCE, rehomeRecord(["title": "Local synthetic title"]))
            let all = try accounts(h.paths, []), from = all.find { $0["account"].str == h.acct.P }, to = all.find { $0["account"].str == h.acct.Z }
            let cloud = cloudFixture(h, [
                "list": fn { _ in [remoteSession(["id": "cse_queue", "title": "Different remote title"])] },
                "eventRows": fn { _ in remoteRows(entries.concat([prompt])) },
            ])
            let inv = try inventory([from], to, h.paths, NOOP, ["cloud": cloud, "processes": []])
            eq(inv["cloud"]["matches"].length, operation == "consumed" ? 1 : 0, operation)
            if operation == "consumed" { eq(inv["cloud"]["matches"][0]["target"]["matchMode"], "ordered") }
            eq(try semantic(entries.concat([queue, queue]), Value(SOURCE)), try semantic(entries, Value(SOURCE)), operation)
        }
    }

    @Test("native bridge retained history covers immediate and deferred moves without a prior receipt target")
    func nativeRetainedCovers() throws {
        for deferred in [false, true] {
            let f = try nativePriorFixture(), h = f.h
            let readBoth = { [try readData(f.priorFile), try readData(h.transcript(SOURCE))] }
            let before = try readBoth()
            let inv = try inventory([f.from], f.to, h.paths, NOOP, ["cloudRequested": true, "cloud": deferred ? .null : f.cloud, "processes": [], "writeCache": true])
            eq(inv["move"][0]["retainedHistories"].length, 1)
            if !deferred { eq(inv["cloud"]["matches"][0]["target"]["matchMode"], "equivalent") }
            let moved = try move(inv, f.to, h.paths)
            eq(moved["ok"], true, JSON.text(moved["receipt"]["failed"]))
            deq(moved["receipt"]["cloudLinks"].map { $0["targetId"] }, [Value(SOURCE)])
            if deferred {
                eq(moved["pendingCloud"], 1)
                let finished = try finishPending(h.paths, ["cloud": f.cloud, "processes": []])
                eq(finished["ok"], true, JSON.text(finished["failed"]))
                eq(finished["complete"], true)
                eq(finished["receipt"]["remote"][0]["matchMode"], "equivalent")
            }
            eq(f.archives, 1, "deferred \(deferred)")
            #expect(try readBoth() == before)
            ok(try undo(h.paths, ["cloud": f.cloud, "processes": []])["dest"])
            eq(f.status, "active")
        }
    }

    @Test("native bridge retained history refuses foreign, ambiguous and incomplete generations")
    func nativeRetainedRefuses() throws {
        for scenario in ["wrong owner", "wrong org", "wrong session", "wrong mirror", "conflicting bridge", "unrecorded", "symlink", "other project", "split priors", "invalid prior", "after cutoff"] {
            let f = try nativePriorFixture(scenario)
            let inv = try inventory([f.from], f.to, f.h.paths, NOOP, ["cloud": f.cloud, "processes": []])
            deq(inv["cloud"]["matches"], [], scenario)
            eq(f.archives, 0, scenario)
        }
    }

    @Test("native bridge retained history rechecks post-plan content and respects cancelled deferred checks")
    func nativeRetainedRechecks() throws {
        for scenario in ["changed", "replaced link", "deferred changed", "cancelled"] {
            let f = try nativePriorFixture(), h = f.h
            let deferred = scenario.hasPrefix("deferred") || scenario == "cancelled"
            let inv = try inventory([f.from], f.to, h.paths, NOOP, ["cloudRequested": true, "cloud": deferred ? .null : f.cloud, "processes": []])
            if scenario == "changed" { try appendText(f.priorFile, "{}\n") }
            if scenario == "replaced link" {
                try rename(f.priorFile, "\(f.priorFile).saved")
                try symlink("\(f.priorFile).saved", f.priorFile)
            }
            let moved = try move(inv, f.to, h.paths)
            if !deferred {
                eq(moved["ok"], false, scenario)
            } else if scenario == "cancelled" {
                _ = try keepLocal(h.paths)
                let finished = try finishPending(h.paths, ["cloud": f.cloud, "processes": []])
                eq(finished["receipt"]["cloudChecks"][0]["status"], "cancelled")
                eq(f.reads, 0)
            } else {
                f.cloud["eventRows"] = fn { _ in
                    f.reads += 1
                    if f.reads == 3 { try appendText(f.priorFile, "{}\n") }
                    return remoteRows(f.remote)
                }
                let finished = try finishPending(h.paths, ["cloud": f.cloud, "processes": []])
                eq(finished["ok"], false, scenario)
            }
            eq(f.archives, 0, scenario)
        }
    }
}
