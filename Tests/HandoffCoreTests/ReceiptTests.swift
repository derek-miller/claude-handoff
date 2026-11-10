import Foundation
import Testing
@testable import HandoffCore

extension Engine {
    @Suite("receipts and recovery")
    struct Receipts {
        @Test("bridge Undo preserves later messages, newer bridges and replaced transcripts", arguments: ["later messages", "newer bridge", "rewritten prefix", "replacement"])
        func bridgeUndoPreserves(mode: String) throws {
            let h = try bridgeFixture(), transcript = h.transcriptPath
            eq(try move(try inventory([h.from], h.to, h.paths, NOOP, ["processes": []]), h.to, h.paths).ok, true)
            try appendText(transcript, "\(JSON.text(entry("user", 3, 2, SOURCE)))\n")
            if mode == "newer bridge" { try appendText(transcript, "\(JSON.text(.spread(h.bridge, ["bridgeSessionId": "cse_newer", "ownerAccountUuid": h.to.account, "ownerOrganizationUuid": h.to.org])))\n") }
            if mode == "rewritten prefix" { try writeText(transcript, try readText(transcript).replacingOccurrences(of: "message 1", with: "changed history")) }
            if mode == "replacement" { try rename(transcript, "\(transcript).old"); try writeData(transcript, try readData("\(transcript).old")) }
            let before = try readData(transcript), undone = try undo(h.paths, ["processes": []]), after = try readData(transcript)
            ok(undone.dest)
            if mode != "later messages" {
                #expect(after == before)
                deq(.strings(try readdir(h.dir("Z"))), [])
                ok(exists(h.recordFile("P", SOURCE)))
                return
            }
            #expect(after.prefix(before.count) == before)
            let rows = lines(String(decoding: after, as: UTF8.self))
            deq(rows.at(-1), h.bridge)
            eq(rows.filter { MESSAGES.contains($0.type.str) }.length, 3)
            deq(try readJSON(h.recordFile("P", SOURCE)).bridgeSessionIds, ["session_prior"])
            deq(.strings(try readdir(h.dir("Z"))), [])
        }

        @Test("deleted task history recovers interrupted retirement with one record per run and moves again cold")
        func deletedTaskHistoryRecovers() throws {
            let h = try taskHistoryFixture(), before = try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str])
            try interruptTaskFamily(h, "move", "retiring")
            ok(try finishWorkflow(h.paths, ["processes": []]).reconciled)
            deq(try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str]), before)
            let settled = try finishWorkflow(h.paths, ["processes": []])
            eq(settled.ok, true, JSON.text(settled.reason))
            eq(settled.summary.notMoved.length, 2)
            let (from, to) = try h.selection(), moved = try executeMove([from], to, h.paths, ["processes": []])
            eq(moved.ok, true)
            eq(moved.receipt.sessions.length, 2)
            ok(try undo(h.paths, ["processes": []]).dest)
            deq(try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str]), before)
        }

        @Test("task checkpoint integrity keeps interrupted Undo scoped to the whole receipt")
        func checkpointUndoScope() throws {
            let h = try taskCheckpointFixture(), all = try accounts(h.paths, [])
            let moved = try executeMove([all.find { $0.account.str == h.acct.P }], all.find { $0.account.str == h.acct.T }, h.paths, ["processes": []])
            eq(moved.ok, true)
            eq(moved.receipt.taskTransfers.length, 2)
            try interruptTaskFamily(h, "undo", "target")
            let receipt = try readJSON(moved.file.str)
            ok(receipt.undoing)
            receipt.appendCheckpoint = ["sessions": 1, "superseded": 1, "taskTransfers": 1, "held": []]
            try writeJSON(moved.file.str, receipt)
            ok(try finishWorkflow(h.paths, ["processes": []]).dest)
            deq(try readJSON(h.sourceFile), h.sourceRegistry)
            #expect(try h.sessions.map { try readData(h.recordFile("P", $0)) } == h.originalRecords)
            ok(!exists(h.targetFile))
            deq(.strings(try readdir(h.dir("T"))), [])
        }
    }
}
