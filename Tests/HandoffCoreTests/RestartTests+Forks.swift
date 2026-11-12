import Foundation
import Testing
@testable import HandoffCore

extension Engine.Restarts {
    static func recordNames(_ sids: [String]) -> [String] { sids.map { "local_\($0).json" }.sorted() }

    @Test("source parents stay with forks omitted, held, unreadable, empty, or failed")
    func sourceParentsStay() throws {
        for reason in ["omitted", "worker", "task", "missing", "empty", "unreadable"] {
            let h = try home(), richer = id(776), child = id(777), base = branchEntries(2, SOURCE, 1)
            try h.write(SOURCE, base)
            try h.record("P", SOURCE, rehomeRecord())
            try h.write(richer, fork(base, SOURCE, richer, "Richer").concat([entry("user", 3, nil, richer)]))
            try h.record("T", richer, rehomeRecord())
            if reason != "missing" { try h.write(child, reason == "empty" ? [] : fork(base, SOURCE, child, "Fork")) }
            if reason == "unreadable" { try appendText(h.transcript(child), "{broken\n") }
            let childRecord = rehomeRecord(.spread(["isArchived": true, "forkedFromSessionId": Value("local_\(SOURCE)")], reason == "task" ? ["scheduledTaskId": "fixture"] : [:]))
            try h.record("P", child, childRecord)
            let (from, to) = try Self.pair(h)
            let source = reason == "omitted" ? .spread(from, ["sessions": from["sessions"].filter { $0["id"].str == SOURCE }]) : from
            let inv = try inventory([source], to, h.paths, NOOP, ["processes": reason == "worker" ? desktopFixture(child) : []])
            let originals = try from["sessions"].elements.map { ($0["file"].str, try readData($0["file"].str)) }
            let moved = try move(inv, to, h.paths)
            if ["omitted", "missing", "empty"].contains(reason) { eq(moved, nil, reason) }
            else { eq(moved["receipt"]["superseded"].some { $0["source"].truthy }, false, reason) }
            #expect(try readdir(h.dir("P")).sorted() == Self.recordNames([SOURCE, child]), "\(reason)")
            for (file, bytes) in originals { #expect(try readData(file) == bytes, "\(reason) \(file)") }
        }
    }

    @Test("held forks move and retire their parents through Finish, sweep, and Undo")
    func heldForksRetireParents() throws {
        let continuations: [(String, (Value, Value) throws -> Value)] = [("finishHeld", { try finishHeld($0, $1) }), ("finishWorkflow", { try finishWorkflow($0, $1) }), ("sweep", { try sweep($0, $1) })]
        for present in [false, true] {
            for (name, continuation) in continuations {
                let label = "\(present) \(name)"
                let h = try home(), child = id(777), cold = id(778), later = id(779), base = branchEntries(2, SOURCE, 1)
                try h.write(SOURCE, base)
                try h.record("P", SOURCE, rehomeRecord())
                try h.write(child, fork(base, SOURCE, child, "Fork"))
                try h.record("P", child, rehomeRecord(["forkedFromSessionId": Value("local_\(SOURCE)")]))
                try h.write(cold, branchEntries(2, cold, 300))
                try h.record("P", cold, rehomeRecord())
                if present { try h.record("T", SOURCE, rehomeRecord()) }
                let originalParent = present ? try readData(h.recordFile("T", SOURCE)) : nil
                let (from, to) = try Self.pair(h)
                let originals = try from["sessions"].elements.map { ($0["file"].str, try readData($0["file"].str)) }
                let moved = try executeMove([from], to, h.paths, ["processes": desktopFixture(child), "moveOnly": true])
                eq(moved["ok"], true, label)
                eq(moved["complete"], false, label)
                deq(moved["receipt"]["held"].map { $0["id"] }, [Value(child), Value(SOURCE)], label)
                deq(moved["receipt"]["sessions"].map { $0["id"] }, [Value(cold)], label)
                deq(moved["receipt"]["failed"], [], label)
                #expect(try readdir(h.dir("P")).sorted() == Self.recordNames([SOURCE, child]))
                #expect(try readdir(h.dir("T")).sorted() == Self.recordNames([cold] + (present ? [SOURCE] : [])))
                try h.write(later, branchEntries(2, later, 400))
                try h.record("P", later, rehomeRecord())
                let result = try continuation(h.paths, ["processes": []]), finished = result["result"].nullish ? result : result["result"]
                eq(finished["file"], moved["file"], label)
                eq(finished["receipt"]["at"], moved["receipt"]["at"], label)
                eq(finished["ok"], true, label)
                eq(finished["complete"], true, label)
                deq(finished["receipt"]["held"], [], label)
                deq(finished["receipt"]["failed"], [], label)
                #expect(try readdir(h.dir("P")) == ["local_\(later).json"], "\(label)")
                #expect(try readdir(h.dir("T")).sorted() == Self.recordNames([SOURCE, child, cold]), "\(label)")
                eq(try sweep(h.paths, ["processes": []])["complete"], true, label)
                let undone = try undo(h.paths)
                ok(undone["dest"], label)
                eq(try readJSON(path.join(undone["dest"].str, "receipt.json"))["at"], moved["receipt"]["at"], label)
                #expect(try readdir(h.dir("T")) == (present ? ["local_\(SOURCE).json"] : []), "\(label)")
                if present { #expect(try readData(h.recordFile("T", SOURCE)) == originalParent) }
                for (file, bytes) in originals { #expect(try readData(file) == bytes, "\(label) \(file)") }
                ok(exists(h.recordFile("P", later)), label)
            }
        }
    }

    @Test("held fork families include ancestors and siblings only in the same source account and org")
    func heldForkFamilies() throws {
        for sameLogin in [false, true] {
            let h = try home(), parent = id(776), child = id(777), sibling = id(778), other = id(779), base = branchEntries(2, SOURCE, 1)
            if sameLogin { h.acct.Q = h.acct.P; try mkdirp(h.dir("Q")) }
            let parentEntries = fork(base, SOURCE, parent, "Parent")
            let family: [(String, Value, Value)] = [
                (SOURCE, base, nil),
                (parent, parentEntries, Value("local_\(SOURCE)")),
                (child, fork(parentEntries, parent, child, "Child"), Value("local_\(parent)")),
                (sibling, fork(parentEntries, parent, sibling, "Sibling"), Value("local_\(parent)")),
            ]
            for (sid, entries, forkedFrom) in family {
                try h.write(sid, entries)
                try h.record("P", sid, rehomeRecord(["forkedFromSessionId": forkedFrom]))
            }
            try h.record("T", SOURCE, rehomeRecord())
            try h.write(other, fork(base, SOURCE, other, "Other source fork"))
            try h.record("Q", other, rehomeRecord(["forkedFromSessionId": Value("local_\(SOURCE)")]))
            let all = try accounts(h.paths), from = all.filter { [h.org.P, h.org.Q].contains($0["org"].str) }, to = all.find { $0["account"].str == h.acct.T }
            let originals = try from.flatMap { $0["sessions"] }.elements.map { ($0["file"].str, try readData($0["file"].str)) }
            let table = desktopFixture(child).concat([.spread(desktopFixture(id(888))[1], ["pid": 502, "started": "collateral"])])
            let plan = try restartPlan(try inventory(from, to, h.paths, NOOP, ["processes": table]), h.paths, table)
            #expect(Set(plan["held"].elements.map { $0["id"].str }) == [SOURCE, parent, child, sibling])
            deq(plan["interrupts"].map { $0["pid"] }, [502])
            ok(plan["held"].every { $0["workers"].length == 1 && $0["workers"][0]["pid"] == 501 && $0["sources"].every { $0["account"].str == h.acct.P && $0["org"].str == h.org.P } })
            let moved = try executeMove(from, to, h.paths, ["processes": table, "moveOnly": true])
            eq(moved["ok"], true)
            deq(moved["receipt"]["sessions"].map { $0["id"] }, [Value(other)])
            #expect(try readdir(h.dir("Q")) == [])
            let finished = try finishHeld(h.paths, ["processes": []])
            eq(finished["ok"], true)
            eq(finished["complete"], true)
            #expect(try readdir(h.dir("P")) == [])
            ok(try undo(h.paths)["dest"])
            for (file, bytes) in originals { #expect(try readData(file) == bytes, "\(file)") }
            #expect(try readdir(h.dir("T")) == ["local_\(SOURCE).json"])
        }
    }
}
