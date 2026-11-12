import Darwin
import Foundation
import Testing
@testable import HandoffCore

extension Engine.Receipts {
    @Test("recovery blockers preserve unfinished journals and never repeat automatic recovery on refresh")
    func recoveryBlockers() throws {
        for scenario in ["changed target", "ordinary rollback", "task rollback", "ordinary rollback after retry", "task rollback after retry"] {
            let ordinary = scenario.hasPrefix("ordinary")
            let tf: TaskFamily? = ordinary ? nil : try taskFamilyFixture()
            let h: Home = try tf ?? home()
            let cold = tf?.cold ?? id(703), healthy = id(710)
            if ordinary {
                for (index, sid) in [SOURCE, cold, healthy].enumerated() {
                    try h.write(sid, [entry("user", 800 + index, nil, sid)])
                    try h.record("P", sid, rehomeRecord())
                }
            }
            let all = try accounts(h.paths, []), from = all.find { $0["account"].str == h.acct.P }, to = all.find { $0["account"].str == h.acct.T }
            let mock = taskHarness(ordinary ? desktopFixture() : [desktopFixture()[0]])
            if ordinary { mock.rows[1]["ids"] = [Value(SOURCE), Value(healthy)] }
            let planned = try executeMove([from], to, h.paths, ["io": mock.io])
            var published: [String] = [], attempts = 0, rollbacks = 0, publications = 0
            let link = fs.link, rename = fs.rename, target = h.recordFile("T", SOURCE)
            fs.link = { a, b in
                try link(a, b)
                if path.dirname(b) == h.dir("T") { published.append(path.basename(b)) }
                if b == target {
                    publications += 1
                    if scenario == "changed target" { try writeJSON(b, .spread(try readJSON(b), ["title": "Changed by another owner"])) }
                    throw EngineError("Synthetic interrupted publication")
                }
            }
            fs.rename = { a, b in
                if scenario.contains("rollback") && a == target {
                    rollbacks += 1
                    if !scenario.hasSuffix("after retry") || publications == 2 { throw EngineError("Synthetic rollback failure") }
                }
                try rename(a, b)
            }
            let result = try executeMove([from], to, h.paths, ["io": mock.io, "approve": planned["plan"]["token"], "report": fn { args in
                if Engine.Receipts.arg(args, 0) == "recovery" { attempts += 1 }
                return .undefined
            }])
            fs = FileSystem()
            let retried = scenario.hasSuffix("after retry")
            eq(attempts, retried ? 1 : 0, scenario)
            eq(publications, retried ? 2 : 1, scenario)
            eq(rollbacks, retried ? 3 : scenario.contains("rollback") ? 2 : 0, scenario)
            eq(result["recoveryRequired"], true, scenario)
            eq(result["summary"]["moved"], Value(ordinary && retried ? 2 : 1), scenario)
            eq(result["summary"]["notMoved"].length, ordinary ? retried ? 1 : 2 : 3, scenario)
            match(result["reason"], scenario.contains("rollback") ? "Synthetic rollback failure" : "changed.*pending")
            let receipt = try readReceipt(result["file"])
            eq(receipt["finalizing"], true, scenario)
            ok(receipt["pending"], scenario)
            ok(exists("\(result["file"].str).journal"), scenario)
            eq(published.contains("local_\(healthy).json"), ordinary && retried, scenario)
            let before = try fixtureSnapshot(h)
            for _ in 0..<2 {
                let refreshed = try sweep(h.paths, ["processes": []])
                eq(refreshed["ok"], false, scenario)
                eq(refreshed["recovered"]["error"], result["reason"], scenario)
                deq(try fixtureSnapshot(h), before, scenario)
            }
            eq(try keepLocal(h.paths)["recoveryRequired"], true, scenario)
            eq(receipt["sessions"].find { $0["id"].str == cold }["id"], Value(cold), scenario)
            #expect(mock.calls == ["/usr/bin/osascript", "/usr/bin/open"], "\(scenario)")
        }
    }

    @Test("registry changes during a task move remain recoverable without lost edits")
    func registryChangesDuringMove() throws {
        let h = try taskFamilyFixture(), (from, to) = try h.selection()
        var edited = false
        let result = try executeMove([from], to, h.paths, ["processes": [], "report": fn { args in
            if Engine.Receipts.arg(args, 0) != "move" || Engine.Receipts.arg(args, 2)["completed"] != 1 || edited { return .undefined }
            let source = try readJSON(h.sourceFile)
            if source["scheduledTasks"].length > 0 { return .undefined }
            edited = true
            source["scheduledTasks"] = [.spread(h.tasks[0], ["enabled": true])]
            source["unrelatedEdit"] = 9
            try writeJSON(h.sourceFile, source)
            return .undefined
        }])
        #expect(edited)
        eq(result["recoveryRequired"], true)
        let changed = try readJSON(h.sourceFile)
        eq(changed["scheduledTasks"][0]["enabled"], true)
        eq(changed["unrelatedEdit"], 9)
        changed["scheduledTasks"] = []
        try writeJSON(h.sourceFile, changed)
        _ = try finishWorkflow(h.paths, ["processes": []])
        deq(try readJSON(h.sourceFile), .spread(h.sourceRegistry, ["unrelatedEdit": 9]))
        ok(exists(h.recordFile("T", h.cold)))
    }

    @Test("task Undo preserves absent directories and registries and only tolerates ENOENT on removal")
    func absentDirectoriesAndRegistries() throws {
        for scenario in ["directory", "registry", "fields", "ENOENT", "EACCES"] {
            let h = try taskFamilyFixture(), registry: Value = scenario == "fields" ? ["future": ["intact": true]] : .null
            if !registry.isNull { try writeJSON(h.targetFile, registry) }
            else if scenario == "directory" { try rmrf(h.dir("T")) }
            else { try unlink(h.targetFile) }
            let (from, to) = try h.selection()
            deq(to["sessions"], [], scenario)
            let moved = try executeMove([from], to, h.paths, ["processes": []])
            eq(moved["ok"], true, scenario)
            eq(moved["receipt"]["sessions"].length, 4, scenario)
            let target = try readData(h.targetFile)
            deq(try JSON.parse(target), .spread(registry, [
                "scheduledTasks": h.tasks,
                "recordedSkips": ["task_0": h.sourceRegistry["recordedSkips"]["task_0"], "task_1": h.sourceRegistry["recordedSkips"]["task_1"]],
                "runRetries": ["task_0": h.sourceRegistry["runRetries"]["task_0"]],
            ]), scenario)
            deq(try readJSON(h.sourceFile), h.sourceAfter, scenario)
            var removals = 0
            var undone: Value = .undefined
            let original = fs.unlink
            fs.unlink = { file in
                if file != h.targetFile || !scenario.hasPrefix("E") { return try original(file) }
                removals += 1
                if scenario == "ENOENT" { try original(file) }
                throw makeError("fixture registry removal failure", code: scenario)
            }
            if scenario == "EACCES" {
                throwsError(where: ["code": Value(scenario), "message": "fixture registry removal failure"]) { try undo(h.paths, ["processes": []]) }
            } else {
                undone = try undo(h.paths, ["processes": []])
            }
            fs = FileSystem()
            if scenario.hasPrefix("E") { eq(removals, 1, scenario) }
            if scenario == "EACCES" {
                eq(try readData(h.targetFile), target)
                undone = try finishWorkflow(h.paths, ["processes": []])
            }
            ok(undone["dest"], scenario)
            deq(.strings(try readdir(h.dir("T"))), registry.isNull ? [] : ["scheduled-tasks.json"], scenario)
            deq(exists(h.targetFile) ? try readJSON(h.targetFile) : .null, registry, scenario)
            deq(try readJSON(h.sourceFile), h.sourceRegistry, scenario)
            for sid in [SOURCE, h.run, h.second, h.cold] { ok(exists(h.recordFile("P", sid)), scenario) }
        }
    }

    @Test("task notification identities may differ from CLI ids and remain protected during recovery")
    func notificationIdentities() throws {
        let h = try taskFamilyFixture()
        let notification = id(714)
        h.notificationId = notification
        try h.record("P", SOURCE, rehomeRecord(["sessionId": Value("local_\(notification)")]))
        try rename(h.recordFile("P", SOURCE), h.recordFile("P", notification))
        for task in h.tasks.elements { task["notifySessionId"] = Value("local_\(notification)") }
        for (index, sid) in [h.run, h.second].enumerated() {
            try h.record("P", sid, rehomeRecord(["scheduledTaskId": h.tasks[index]["id"], "notifySessionId": Value("local_\(notification)")]))
        }
        try writeJSON(h.sourceFile, h.sourceRegistry)
        try interruptTaskFamily(h, "move", "record")
        let file = h.recordFile("T", notification), before = try readData(file)
        try writeJSON(file, .spread(try JSON.parse(before), ["title": "Changed after interruption"]))
        let refused = try finishWorkflow(h.paths, ["processes": []])
        eq(refused["recoveryRequired"], true)
        match(refused["reconciled"]["error"], "task.*record changed")
        try writeData(file, before)
        _ = try finishWorkflow(h.paths, ["processes": []])
        let finished = try finishHeld(h.paths, ["processes": []])
        eq(finished["ok"], true)
        eq(try readJSON(file)["sessionId"], Value("local_\(notification)"))
        ok(try undo(h.paths, ["processes": []])["dest"])
        deq(try readJSON(h.sourceFile), h.sourceRegistry)
    }

    @Test("task registry edits during publication and Undo retain their values and recovery")
    func registryEditsDuringPublication() throws {
        for phase in ["publication", "undo"] {
            let h = try taskFamilyFixture(), (from, to) = try h.selection()
            if phase == "undo" { _ = try executeMove([from], to, h.paths, ["processes": []]) }
            var injected = false
            let inject = {
                injected = true
                let registry = try readJSON(h.targetFile)
                registry["duringWrite"] = ["preserved": true]
                if phase == "undo" { registry["scheduledTasks"].push(.spread(h.tasks[0], ["enabled": true])) }
                try writeJSON(h.targetFile, registry)
            }
            if phase == "publication" {
                let write = fs.writeFile
                fs.writeFile = { file, data, flag, mode in
                    try write(file, data, flag, mode)
                    if file.hasPrefix(h.targetFile + ".") && !injected { try inject() }
                }
            } else {
                let rename = fs.rename, record = h.recordFile("T", SOURCE)
                fs.rename = { a, b in
                    try rename(a, b)
                    if a == record && !injected { try inject() }
                }
            }
            let result = phase == "publication" ? try executeMove([from], to, h.paths, ["processes": []]) : try undo(h.paths, ["processes": []])
            fs = FileSystem()
            #expect(injected, "\(phase)")
            deq(try readJSON(h.targetFile)["duringWrite"], ["preserved": true], phase)
            if phase == "publication" {
                eq(result["ok"], true)
                eq(result["receipt"]["sessions"].length, 4)
                ok(try undo(h.paths, ["processes": []])["dest"])
            } else {
                match(Value(result["restoreProblems"].join(" ")), "scheduled task")
                let registry = try readJSON(h.targetFile)
                eq(registry["scheduledTasks"].find { $0["id"] == h.tasks[0]["id"] }["enabled"], true)
                registry["scheduledTasks"] = registry["scheduledTasks"].filter { task in !h.tasks.some { $0["id"] == task["id"] } }
                try writeJSON(h.targetFile, registry)
                ok(try finishWorkflow(h.paths, ["processes": []])["dest"])
            }
            deq(try readJSON(h.sourceFile), h.sourceRegistry, phase)
            deq(try readJSON(h.targetFile), .spread(h.targetRegistry, ["duringWrite": ["preserved": true]]), phase)
        }
    }

    @Test("compatible Desktop parent and archived fork move separately and undo without changing history")
    func parentAndArchivedFork() throws {
        for richer in ["parent", "fork"] {
            let h = try home(), child = id(777)
            let targetDir = path.join(h.paths["records"].str, h.acct.P, h.org.T)
            try mkdirp(targetDir)
            let base: Value = [entry("user", 1, nil, SOURCE), entry("assistant", 2, 1, SOURCE)]
            let branch = fork(base, SOURCE, child, "Archived fork")
            try h.write(SOURCE, richer == "parent" ? base.concat([entry("user", 3, 2, SOURCE)]) : base)
            try h.write(child, richer == "fork" ? branch.concat([entry("user", 4, nil, child)]) : branch)
            try h.record("P", SOURCE, rehomeRecord(["title": "Parent", "isArchived": false, "isStarred": true]))
            try h.record("P", child, rehomeRecord(["title": "Archived fork", "isArchived": true, "forkedFromSessionId": Value("local_\(SOURCE)")]))
            var files: [(file: String, bytes: Data, inode: Value)] = []
            for sid in [SOURCE, child] {
                try mkdirp(path.join(h.project, sid))
                let sidecar = path.join(h.project, sid, "\(sid).txt")
                try writeText(sidecar, "supporting data for \(sid)")
                for file in [h.transcript(sid), sidecar] {
                    let bytes = try readData(file), inode = try stat(file)["ino"]
                    files.append((file: file, bytes: bytes, inode: inode))
                }
            }
            let originalRecords = try [SOURCE, child].map { try readData(h.recordFile("P", $0)) }
            let all = try accounts(h.paths), from = all.find { $0["account"].str == h.acct.P && $0["org"].str == h.org.P }, to = all.find { $0["account"].str == h.acct.P && $0["org"].str == h.org.T }
            let inv = try inventory([from], to, h.paths)
            deq(inv["blocked"].map { $0["error"] }, [], richer)
            deq(inv["move"].map { $0["id"] }, [Value(SOURCE), Value(child)], richer)
            let moved = try move(inv, to, h.paths)
            eq(moved["ok"], true)
            eq(moved["receipt"]["sessions"].length, 2)
            eq(moved["receipt"]["sessions"].every { $0["strategy"] == "rehome" }, true)
            deq(.strings(try readdir(h.dir("P"))), [])
            let parent = try readJSON(path.join(targetDir, "local_\(SOURCE).json"))
            let archived = try readJSON(path.join(targetDir, "local_\(child).json"))
            eq(parent["title"], "Parent")
            eq(parent["isStarred"], true)
            eq(parent["isArchived"], false)
            eq(archived["title"], "Archived fork")
            eq(archived["isArchived"], true)
            eq(archived["forkedFromSessionId"], parent["sessionId"])
            for file in files {
                eq(try readData(file.file), file.bytes)
                eq(try stat(file.file)["ino"], file.inode)
            }
            let restored = try undo(h.paths)
            ok(restored["dest"])
            deq(.strings(try readdir(targetDir)), [])
            for (index, sid) in [SOURCE, child].enumerated() { eq(try readData(h.recordFile("P", sid)), originalRecords[index]) }
        }
    }

    @Test("unreadable Desktop metadata stops retirement and preserves recoverable source and destination records")
    func unreadableMetadataStopsRetirement() throws {
        let h = try home(), child = id(777), corrupt = id(778), base = branchEntries(2, SOURCE, 1)
        try h.write(SOURCE, base)
        try h.record("P", SOURCE, rehomeRecord())
        try h.write(child, fork(base, SOURCE, child, "Fork"))
        try h.record("P", child, rehomeRecord(["forkedFromSessionId": Value("local_\(SOURCE)")]))
        let from = try h.account("P"), to = try h.account("T")
        let originals = try from["sessions"].elements.map { ($0["file"].str, try readData($0["file"].str)) }
        let inv = try inventory([from], to, h.paths)
        let corruptFile = h.recordFile("P", corrupt)
        try writeText(corruptFile, "{broken")
        let moved = try move(inv, to, h.paths)
        eq(moved["ok"], false)
        match(moved["receipt"]["failed"].at(-1)["error"], "unreadable Desktop record:")
        deq(moved["receipt"]["superseded"], [])
        eq(moved["receipt"]["retiring"], nil)
        eq(moved["receipt"]["sessions"].length, 0)
        for (file, bytes) in originals {
            eq(try readData(file), bytes)
            ok(!exists(path.join(h.dir("T"), path.basename(file))))
        }
        let swept = try sweep(h.paths, ["processes": []])
        match(swept["verification"]["notMoved"].at(-1)["error"], "unreadable Desktop record")
        try unlink(corruptFile)
        ok(try undo(h.paths)["dest"])
        for (file, bytes) in originals { eq(try readData(file), bytes) }
        deq(.strings(try readdir(h.dir("T"))), [])
    }

    @Test("Undo restores destination parents when forks arrive during local mutations and remains recoverable")
    func forksArriveDuringUndo() throws {
        for stage in ["restore source", "park destination"] {
            for unreadable in [false, true] {
                let label = "\(stage)/\(unreadable)"
                let h = try home(), child = id(777), later = id(778), base = branchEntries(2, SOURCE, 1)
                try h.write(SOURCE, base)
                try h.record("P", SOURCE, rehomeRecord())
                try h.write(child, fork(base, SOURCE, child, "Moved fork"))
                try h.record("P", child, rehomeRecord(["forkedFromSessionId": Value("local_\(SOURCE)")]))
                let from = try h.account("P"), to = try h.account("T")
                let originals = try from["sessions"].elements.map { ($0["file"].str, try readData($0["file"].str)) }
                let moved = try move(try inventory([from], to, h.paths), to, h.paths)
                eq(moved["ok"], true, label)
                let destination = try moved["receipt"]["sessions"].elements.map { ($0["record"].str, try readData($0["record"].str)) }
                let sourceParent = h.recordFile("P", SOURCE), targetParent = h.recordFile("T", SOURCE)
                var injected = false
                let rename = fs.rename
                fs.rename = { a, b in
                    try rename(a, b)
                    if injected || !(stage == "restore source" ? b == sourceParent : a == targetParent) { return }
                    injected = true
                    if unreadable { try writeText(h.recordFile("T", later), "{broken") }
                    else { try h.record("T", later, rehomeRecord(["isArchived": true, "forkedFromSessionId": Value("local_\(SOURCE)")])) }
                }
                let refused = try undo(h.paths)
                fs = FileSystem()
                #expect(injected, "\(label)")
                eq(refused["dest"], .undefined, label)
                match(refused["restoreProblems"][0], unreadable ? "unreadable Desktop record:" : "parent Desktop record would be removed by Undo")
                for (file, bytes) in destination { eq(try readData(file), bytes, "\(label)") }
                if !unreadable { eq(try readJSON(h.recordFile("T", later))["forkedFromSessionId"], Value("local_\(SOURCE)"), label) }
                for (file, bytes) in originals { eq(try readData(file), bytes, "\(label)") }
                let receipt = try readJSON(moved["file"].str)
                eq(receipt["undoing"].length, 2, label)
                deq(receipt["superseded"], moved["receipt"]["superseded"], label)
                for row in receipt["superseded"].elements { for pair in row["moved"].elements { eq(readOrNil(pair[1].str), nil, label) } }
                let retried = try finishPending(h.paths)
                eq(retried["ok"], false, label)
                match(retried["reconciled"]["problems"][0], unreadable ? "unreadable Desktop record:" : "parent Desktop record would be removed by Undo")
                for (file, bytes) in destination { eq(try readData(file), bytes, "\(label)") }
                try unlink(h.recordFile("T", later))
                let undone = try finishWorkflow(h.paths)
                ok(undone["dest"], label)
                eq(undone["complete"], true, label)
                eq(try readJSON(path.join(undone["dest"].str, "receipt.json"))["at"], moved["receipt"]["at"], label)
                for (file, bytes) in originals { eq(try readData(file), bytes, "\(label)") }
                deq(.strings(try readdir(h.dir("T"))), [], label)
            }
        }
    }

    @Test("Undo rollback preserves foreign records and source forks while restoring every safe destination record")
    func undoRollbackPreservesForeign() throws {
        for change in ["source record", "destination parent", "destination sibling", "source fork"] {
            let h = try home(), child = id(777), later = id(778), sourceFork = id(779), base = branchEntries(2, SOURCE, 1)
            try h.write(SOURCE, base)
            try h.record("P", SOURCE, rehomeRecord())
            try h.write(child, fork(base, SOURCE, child, "Moved fork"))
            try h.record("P", child, rehomeRecord(["forkedFromSessionId": Value("local_\(SOURCE)")]))
            let from = try h.account("P"), to = try h.account("T")
            var originals: [String: Data] = [:]
            for row in from["sessions"].elements { originals[row["file"].str] = try readData(row["file"].str) }
            let moved = try move(try inventory([from], to, h.paths), to, h.paths)
            eq(moved["ok"], true, change)
            var destination: [String: Data] = [:]
            for row in moved["receipt"]["sessions"].elements { destination[row["record"].str] = try readData(row["record"].str) }
            let sourceParent = h.recordFile("P", SOURCE), targetParent = h.recordFile("T", SOURCE)
            let targetChild = h.recordFile("T", child), parkedParent = path.join(h.paths["state"].str, "quarantine", moved["receipt"]["at"].str, path.basename(targetParent))
            let foreignFile = change == "source record" ? sourceParent : change == "destination parent" ? targetParent : change == "destination sibling" ? targetChild : h.recordFile("P", sourceFork)
            var injected = false, foreignBytes = Data()
            let rename = fs.rename
            fs.rename = { a, b in
                try rename(a, b)
                if injected || a != targetParent || b != parkedParent { return }
                injected = true
                try h.record("T", later, rehomeRecord(["forkedFromSessionId": Value("local_\(SOURCE)")]))
                if change == "source fork" { try h.record("P", sourceFork, rehomeRecord(["forkedFromSessionId": Value("local_\(SOURCE)")])) }
                else {
                    let extra: Value = change == "destination sibling" ? ["title": "Independent change", "forkedFromSessionId": Value("local_\(SOURCE)")] : ["title": "Independent change"]
                    try h.record(change == "source record" ? "P" : "T", change == "destination sibling" ? child : SOURCE, rehomeRecord(extra))
                }
                foreignBytes = try readData(foreignFile)
            }
            let refused = try undo(h.paths)
            fs = FileSystem()
            #expect(injected, "\(change)")
            eq(refused["dest"], .undefined, change)
            match(refused["restoreProblems"][0], "parent Desktop record would be removed by Undo")
            if change != "source fork" { ok(refused["restoreProblems"].some { TextPattern.cached("restore path occupied|recovery artifact changed").test($0.str) }, change) }
            eq(try readData(foreignFile), foreignBytes, "\(change)")
            for (file, bytes) in originals { eq(try readData(file), (file == foreignFile ? foreignBytes : bytes), "\(change) \(file)") }
            for (file, bytes) in destination { eq(try readData(file), (file == foreignFile ? foreignBytes : bytes), "\(change) \(file)") }
            if change == "destination parent" { eq(try readData(parkedParent), destination[targetParent]) }
            let receipt = try readJSON(moved["file"].str)
            eq(receipt["undoing"].length, 2, change)
            deq(receipt["superseded"], moved["receipt"]["superseded"], change)
            if change != "source fork" {
                try rename(foreignFile, "\(foreignFile).foreign")
                if change == "source record" { try writeData(foreignFile, originals[foreignFile]!) }
                if change == "destination sibling" { try writeData(foreignFile, destination[foreignFile]!) }
            }
            try unlink(h.recordFile("T", later))
            let undone = try finishWorkflow(h.paths)
            ok(undone["dest"], change)
            eq(undone["complete"], true, change)
            for (file, bytes) in originals { eq(try readData(file), bytes, "\(change) \(file)") }
            for file in destination.keys { eq(readOrNil(file), nil, change) }
            eq(try readData(change == "source fork" ? foreignFile : "\(foreignFile).foreign"), foreignBytes, "\(change)")
        }
    }

    @Test("new or changed parent references during retirement roll back the journal")
    func parentReferencesDuringRetirement() throws {
        for change in ["new", "changed"] {
            for location in ["P", "T"] {
                let label = "\(change)/\(location)"
                let h = try home(), richer = id(776), child = id(777), base = branchEntries(2, SOURCE, 1)
                try h.write(SOURCE, base)
                try h.record(location, SOURCE, rehomeRecord())
                try h.write(richer, fork(base, SOURCE, richer, "Richer").concat([entry("user", 3, nil, richer)]))
                try h.record(location == "P" ? "T" : "P", richer, rehomeRecord())
                if change == "changed" { try h.record(location, child, rehomeRecord(["isArchived": true])) }
                let from = try h.account("P"), to = try h.account("T")
                let inv = try inventory([from], to, h.paths)
                var coordinate: Box<Bool>?
                let result = try move(inv, to, h.paths, fn { args in
                    if Engine.Receipts.arg(args, 0) != "finalize" || Engine.Receipts.arg(args, 1) != "preparing" { return .undefined }
                    let taskFile = from["taskFile"].str
                    try writeJSON(taskFile, ["scheduledTasks": []])
                    coordinate = Engine.Receipts.duringSecondRead(taskFile) {
                        try h.record(location, child, rehomeRecord(["isArchived": true, "forkedFromSessionId": Value("local_\(SOURCE)")]))
                    }
                    return .undefined
                })
                ok(coordinate?.value ?? false, "\(label): the task registry was never read during finalization")
                eq(result["ok"], Value(location == "T"), label)
                if location == "P" { match(result["receipt"]["failed"].at(-1)["error"], "parent reference changed during retirement") }
                eq(result["receipt"]["retiring"], nil, label)
                deq(result["receipt"]["superseded"].map { $0["id"] }, location == "T" ? [Value(richer)] : [], label)
                ok(exists(h.recordFile(location, SOURCE)), label)
                let kept = try readJSON(h.recordFile(location, child))
                eq(kept["forkedFromSessionId"], Value("local_\(SOURCE)"), label)
                eq(kept["isArchived"], true, label)
                if location == "T" { ok(try undo(h.paths)["dest"], label) }
                fs = FileSystem()
            }
        }
    }

    @Test("dry-run and real move agree that bridges rehome across logins")
    func dryRunAgreesOnBridges() throws {
        let h = try home()
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE), ["type": "bridge-session", "sessionId": Value(SOURCE), "bridgeSessionId": "session_fixture"]])
        try h.record("P", SOURCE, rehomeRecord(["bridgeSessionIds": ["session_fixture"]]))
        let sourceRecord = try readJSON(h.recordFile("P", SOURCE))
        let dry = cli(h.root, ["--from", "\(h.acct.P) \(h.org.P)", "--to", "\(h.acct.Z) \(h.org.Z)", "--dry-run", "--json"])
        eq(dry.code, 0, dry.stderr.isEmpty ? dry.stdout : dry.stderr)
        let planned = lines(dry.stdout).at(-1)
        eq(planned["planned"], 1)
        eq(planned["retiring"], 1)
        let all = try accounts(h.paths)
        let from = all.find { $0["account"].str == h.acct.P && $0["org"].str == h.org.P }
        let to = all.find { $0["account"].str == h.acct.Z && $0["org"].str == h.org.Z }
        let result = try move(try inventory([from], to, h.paths), to, h.paths)
        eq(result["ok"], true)
        eq(result["receipt"]["sessions"][0]["strategy"], "rehome")
        let placed = try readJSON(h.recordFile("Z", SOURCE))
        deq(placed["bridgeSessionIds"], [])
        eq(placed["cliSessionId"], Value(SOURCE))
        deq(.spread(placed, ["bridgeSessionIds": ["session_fixture"]]), sourceRecord)
        ok(try undo(h.paths)["dest"])
        deq(try readJSON(h.recordFile("P", SOURCE))["bridgeSessionIds"], ["session_fixture"])
    }

    @Test("an interrupted rehome removes only its unchanged target record")
    func interruptedRehomeRemovesTarget() throws {
        let h = try home()
        let teamDir = path.join(h.paths["records"].str, h.acct.P, h.org.T)
        try mkdirp(teamDir)
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE, rehomeRecord())
        let sourceRecord = h.recordFile("P", SOURCE)
        let targetRecord = path.join(teamDir, "local_\(SOURCE).json")
        let record = try readData(sourceRecord)
        try writeData(targetRecord, record)
        let at = "2099-01-02T00-00-00-000"
        let receipt: Value = [
            "at": Value(at), "from": ["source"], "to": "target", "sessions": [], "failed": [], "superseded": [],
            "cloudChecks": [["account": Value(h.acct.P), "org": Value(h.org.P), "label": "source", "status": "pending"]],
            "finalizing": true,
            "pending": ["strategy": "rehome", "id": Value(SOURCE), "targetId": Value(SOURCE), "title": "Session 001", "made": [Value(targetRecord)], "recordSha": Value(sha(record))],
        ]
        try mkdirp(h.paths["state"])
        try writeJSON(path.join(h.paths["state"].str, "\(at).json"), receipt)
        let all = try accounts(h.paths)
        let to = all.find { $0["account"].str == h.acct.P && $0["org"].str == h.org.T }
        let result = try move(["move": []], to, h.paths)
        eq(result["recoveryRequired"], true)
        ok(exists(sourceRecord))
        ok(exists(h.transcript(SOURCE)))
        eq(readOrNil(targetRecord), nil)
        deq(.strings(try readdir(path.join(h.paths["state"].str, "quarantine", at, "failed"))), [Value("local_\(SOURCE).json")])
        eq(try readJSON(path.join(h.paths["state"].str, "\(at).json"))["cloudChecks"][0]["status"], "cancelled")
    }

    @Test("interrupted placement leaves a foreign byte-identical target untouched")
    func foreignByteIdenticalTarget() throws {
        for replaced in [false, true] {
            let h = try home()
            try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
            try h.record("P", SOURCE)
            let target = h.recordFile("T", SOURCE)
            let text = JSON.text(try readJSON(h.recordFile("P", SOURCE)), space: 2) + "\n"
            try writeText(target, text)
            let identity = try stat(target)
            if replaced {
                try rename(target, target + ".original")
                try writeText(target, text)
            }
            let at = "2099-01-02T00-00-00-000"
            let pending: Value = ["strategy": "rehome", "id": Value(SOURCE), "title": "Interrupted", "targetId": Value(SOURCE), "made": [Value(target)],
                                  "recordSha": Value(sha(text)), "creationRequired": true]
            if replaced { pending["created"] = ["dev": identity["dev"], "ino": identity["ino"]] }
            let receipt: Value = ["at": Value(at), "sessions": [], "superseded": [], "failed": [], "finalizing": true, "pending": pending]
            try mkdirp(h.paths["state"])
            let file = path.join(h.paths["state"].str, at + ".json")
            try writeJSON(file, receipt)
            ok(try undo(h.paths)["reconciled"], "\(replaced)")
            eq(readOrNil(target), Value(text))
            eq(try readJSON(file)["retained"], .undefined)
        }
    }

    @Test("interrupted rehome rollback keeps shared transcript and sidecar changes")
    func rehomeRollbackKeepsShared() throws {
        let h = try home()
        let teamDir = path.join(h.paths["records"].str, h.acct.P, h.org.T)
        try mkdirp(teamDir)
        let transcript = h.transcript(SOURCE)
        let sidecar = path.join(h.project, SOURCE, "subagents", "agent.jsonl")
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try mkdirp(path.dirname(sidecar))
        try writeText(sidecar, "{\"before\":true}\n")
        try h.record("P", SOURCE, rehomeRecord())
        let all = try accounts(h.paths)
        let from = all.find { $0["account"].str == h.acct.P && $0["org"].str == h.org.P }
        let to = all.find { $0["account"].str == h.acct.P && $0["org"].str == h.org.T }
        let moved = try move(try inventory([from], to, h.paths), to, h.paths)
        let receipt = try readJSON(moved["file"].str)
        receipt["finalizing"] = true
        try writeJSON(moved["file"].str, receipt)
        try appendText(transcript, "\(JSON.text(entry("assistant", 2, 1, SOURCE)))\n")
        try appendText(sidecar, "{\"after\":true}\n")
        let recovered = try undo(h.paths)
        match(recovered["reconciled"]["error"], "finalization rolled back")
        ok(try readText(transcript).contains("message 2"))
        ok(try readText(sidecar).contains("after"))
        ok(exists(h.recordFile("P", SOURCE)))
        eq(readOrNil(path.join(teamDir, "local_\(SOURCE).json")), nil)
    }

    @Test("rehome undo keeps shared transcript and sidecar changes")
    func rehomeUndoKeepsShared() throws {
        let h = try home()
        let teamDir = path.join(h.paths["records"].str, h.acct.P, h.org.T)
        try mkdirp(teamDir)
        let transcript = h.transcript(SOURCE)
        let sidecar = path.join(h.project, SOURCE, "subagents", "agent.jsonl")
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try mkdirp(path.dirname(sidecar))
        try writeText(sidecar, "{\"before\":true}\n")
        try h.record("P", SOURCE, rehomeRecord())
        let all = try accounts(h.paths)
        let from = all.find { $0["account"].str == h.acct.P && $0["org"].str == h.org.P }
        let to = all.find { $0["account"].str == h.acct.P && $0["org"].str == h.org.T }
        eq(try move(try inventory([from], to, h.paths), to, h.paths)["ok"], true)
        try appendText(transcript, "\(JSON.text(entry("assistant", 2, 1, SOURCE)))\n")
        try appendText(sidecar, "{\"after\":true}\n")
        let undone = try undo(h.paths)
        ok(undone["dest"])
        ok(try readText(transcript).contains("message 2"))
        ok(try readText(sidecar).contains("after"))
        ok(exists(h.recordFile("P", SOURCE)))
        eq(readOrNil(path.join(teamDir, "local_\(SOURCE).json")), nil)
    }

    @Test("a parent moves and keeps its source for an archived fork without history, and Undo restores both")
    func parentKeepsSourceForArchivedFork() throws {
        let h = try home(), fork = id(730)
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE), entry("assistant", 2, 1, SOURCE)])
        try h.record("P", SOURCE, rehomeRecord())
        try h.record("P", fork, rehomeRecord(["forkedFromSessionId": Value("local_\(SOURCE)"), "isArchived": true]))
        let before = try fixtureSnapshot(h, [h.paths["records"].str])
        let all = try accounts(h.paths, []), from = all.find { $0["account"].str == h.acct.P }, to = all.find { $0["account"].str == h.acct.T }
        let result = try executeMove([from], to, h.paths, ["processes": []])
        eq(result["ok"], true, JSON.text(result["receipt"]["failed"]))
        eq(result["complete"], true)
        deq(result["receipt"]["failed"], [])
        deq(result["receipt"]["sessions"].map { $0["id"] }, [Value(SOURCE)])
        eq(result["receipt"]["superseded"].length, 0)
        ok(exists(h.recordFile("T", SOURCE)))
        ok(exists(h.recordFile("P", SOURCE)))
        ok(try undo(h.paths, ["processes": []])["dest"])
        deq(try fixtureSnapshot(h, [h.paths["records"].str]), before)
    }

    @Test("interrupted placement replays complete journal entries and ignores only a torn final append")
    func tornFinalAppend() throws {
        for keep in [3, 4] {
            let h = try home()
            try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
            try h.record("P", SOURCE, rehomeRecord())
            let original = try readData(h.recordFile("P", SOURCE))
            let from = try h.account("P"), to = try h.account("T")
            var reported: [Value] = []
            let inv = try inventory([from], to, h.paths)
            throwsError("fixture interrupted publication") {
                try move(inv, to, h.paths, fn { args in
                    reported.append(["stage": Engine.Receipts.arg(args, 0), "text": Engine.Receipts.arg(args, 1), "progress": Engine.Receipts.arg(args, 2)])
                    if Engine.Receipts.arg(args, 0) == "move" && Engine.Receipts.arg(args, 2)["completed"] == 1 { throw EngineError("fixture interrupted publication") }
                    return .undefined
                })
            }
            let log = try readdir(h.paths["state"].str).first { $0.hasSuffix(".journal") }!
            let file = path.join(h.paths["state"].str, log)
            let patches = try readText(file).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression).components(separatedBy: "\n")
            eq(patches.count, 4, "\(keep)")
            ok(try JSON.parse(patches[2])["pending"]["created"])
            try writeText(file, patches.prefix(keep).joined(separator: "\n") + "\n{\"sequence\":")
            eq(reported.contains { $0["stage"] == "move" && $0["text"].str.contains("✓") }, false)
            eq(try readJSON(String(file.dropLast(8)))["sessions"].length, 0)
            let recovered = try sweep(h.paths)
            ok(recovered["recovered"])
            eq(try readdir(h.dir("T")).count, 0)
            eq(try readData(h.recordFile("P", SOURCE)), original)
            eq(try readdir(h.paths["state"].str).contains { $0.hasSuffix(".journal") }, false)
            eq(try sweep(h.paths)["recovered"], .undefined)
        }
    }

    @Test("receipt snapshots omit tool metadata while Desktop records, drift and Undo retain their safeguards")
    func receiptSnapshotsOmitToolMetadata() throws {
        let h = try home()
        let metadata: Value = ["servers": [["name": "synthetic-mcp", "tools": [["name": "synthetic-tool", "schema": Value(String(repeating: "x", count: 1_000_000))]]]]]
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE, rehomeRecord(["toolSurfaceSnapshot": metadata, "mcpServers": metadata, "isStarred": true]))
        let all = try accounts(h.paths, []), from = all.find { $0["account"].str == h.acct.P }, to = all.find { $0["account"].str == h.acct.Z }
        let moved = try move(try inventory([from], to, h.paths, NOOP, ["processes": []]), to, h.paths)
        eq(moved["ok"], true)
        let row = moved["receipt"]["sessions"][0], record = try readJSON(row["record"].str)
        deq(record["toolSurfaceSnapshot"], metadata)
        deq(record["mcpServers"], metadata)
        deq(.strings(row["recordSnapshot"].ownKeys.sorted(by: utf16Less)), .strings(["sessionId", "cliSessionId", "cwd", "originCwd", "title", "isArchived", "isStarred"].sorted(by: utf16Less)))
        ok(JSON.text(row["recordSnapshot"]).utf16.count < 600)
        eq(row["recordSha"], Value(sha(try readData(row["record"].str))))
        let changed = Value.spread(record, ["title": "Changed title", "isStarred": false])
        try writeJSON(row["record"].str, changed)
        deq(try verifyPlaced(h.paths)["changed"][0]["fields"], ["title", "isStarred"])
        match(try undo(h.paths)["changed"][0], "desktop record")
        try writeJSON(row["record"].str, record)
        ok(try undo(h.paths)["dest"])
        deq(try readJSON(h.recordFile("P", SOURCE))["mcpServers"], metadata)
    }

    @Test("incremental receipt journals preserve UTF-8, sequence and corruption rules")
    func incrementalJournals() throws {
        let root = temporaryDirectory("ct-journal-"), file = path.join(root, "receipt.json")
        let snapshot: Value = ["sessionId": Value("local_\(SOURCE)"), "cliSessionId": Value(SOURCE), "cwd": "/tmp/fixture", "originCwd": "/tmp/fixture",
                               "title": "Synthetic \u{96ea}\u{1F30B}", "isArchived": false, "isStarred": true, "mcp": Value(String(repeating: "x", count: 200_000))]
        let row: Value = ["recordSnapshot": snapshot, "recordSha": "hash", "recordSemantic": "semantic", "rollback": ["bytes": "keep"], "task": ["prompt": "keep task"]]
        let base: Value = ["journalSequence": 1, "sessions": [row], "failed": [], "retained": [], "pending": .spread(row), "futureField": ["value": "keep unknown"]]
        let patch: Value = ["sequence": 2, "sessions": [row], "failed": [], "retained": [.spread(row)], "pending": row]
        try writeJSON(file, base)
        let skipped = JSON.text(["sequence": 1, "sessions": "already applied"]) + "\n"
        let room = 65535 - skipped.utf8.count
        let padding = String(repeating: " ", count: room - 65536 * Int((Double(room) / 65536).rounded(.down)))
        try writeText("\(file).journal", skipped + padding + JSON.text(patch) + "\n" + JSON.text(["sequence": 3]) + "\u{96ea}")
        let receipt = try readReceipt(Value(file))
        eq(receipt["journalSequence"], 2)
        eq(receipt["sessions"].length, 2)
        deq(receipt["futureField"], base["futureField"])
        for saved in receipt["sessions"].elements + receipt["retained"].elements + [receipt["pending"]] {
            eq(saved["recordSnapshot"]["title"], snapshot["title"])
            eq(saved["recordSha"], "hash")
            deq(saved["task"], row["task"])
            deq(saved["rollback"], row["rollback"])
        }
        eq(try readJSON(file)["sessions"][0]["recordSnapshot"]["mcp"].length, 200_000)
        let encoded = Data((JSON.text(patch) + "\n").utf8)
        let unicodeAt = encoded.range(of: Data("\u{96ea}".utf8))!.lowerBound - encoded.startIndex
        for split in [1, 2, 3] {
            try writeData("\(file).journal", Data(String(repeating: " ", count: 65536 - unicodeAt - split).utf8) + encoded)
            eq(try readReceipt(Value(file))["sessions"][1]["recordSnapshot"]["title"], snapshot["title"], "split \(split)")
        }
        let cases: [(String, String)] = [
            ("{broken}\n", "JSON|property|Expected"), ("\n", "JSON"), (JSON.text(.spread(patch, ["sequence": 3])) + "\n", "Incomplete move journal"),
            (JSON.text(.spread(patch, ["sequence": 0])) + "\n", "Invalid move journal sequence"), (JSON.text(.spread(patch, ["sessions": Value.newObject()])) + "\n", "Invalid move journal entries"),
        ]
        for (text, error) in cases {
            try writeText("\(file).journal", text)
            throwsError(error) { try readReceipt(Value(file)) }
        }
    }

    // Replay must stream the journal: it is never read whole, and the process footprint stays well below its size.
    @Test("incremental receipt journal replay stays within a small heap for a large synthetic journal")
    func journalReplayHeap() throws {
        let root = temporaryDirectory("ct-journal-heap-"), file = path.join(root, "receipt.json")
        try writeJSON(file, ["sessions": [], "failed": [], "retained": []])
        let padding = String(repeating: "x", count: 512 * 1024)
        try writeText("\(file).journal", "")
        let journal = Foundation.FileHandle(forWritingAtPath: "\(file).journal")!
        for sequence in 1...256 {
            let line: Value = ["sequence": Value(sequence), "pending": ["strategy": "rehome", "padding": Value(padding)], "failed": [], "retained": [],
                               "sessions": [["recordSha": Value("sha-\(sequence)"), "recordSnapshot": ["sessionId": Value("local_\(SOURCE)"), "cliSessionId": Value(SOURCE), "title": Value("Synthetic \(sequence)")]]]]
            journal.write(Data((JSON.text(line) + "\n").utf8))
        }
        try journal.close()
        let bytes = try stat("\(file).journal")["size"].asNumber!
        let readFile = fs.readFile
        fs.readFile = { p in
            ok(!p.hasSuffix(".journal"), "the journal was read whole")
            return try readFile(p)
        }
        let start = footprint()
        let receipt = try readReceipt(Value(file))
        let grown = footprint() - start
        eq(receipt["sessions"].length, 256)
        eq(receipt["journalSequence"], 256)
        eq(receipt["pending"]["padding"].length, 512 * 1024)
        ok(bytes > 128 * 1024 * 1024)
        ok(grown < 96 * 1024 * 1024, "replaying \(Int(bytes)) journal bytes grew the footprint by \(grown) bytes")
    }

    static func physicalFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    func footprint() -> Int { Engine.Receipts.physicalFootprint() }

    @Test("sidecar link leaves survive parent and child moves and Undo without reading their targets")
    func sidecarLinkLeaves() throws {
        let h = try home(), child = id(8300), external = path.join(h.root, "external")
        try mkdirp(external)
        try writeText(path.join(external, "secret"), "synthetic unread target")
        var links: [(file: String, destination: String, inode: Value)] = []
        for sid in [SOURCE, child] {
            try h.write(sid, [entry("user", sid == SOURCE ? 1 : 2, nil, sid)])
            try h.record("P", sid, rehomeRecord(sid == child ? ["forkedFromSessionId": Value("local_\(SOURCE)")] : [:]))
            let dir = path.join(h.project, sid, "workflow")
            try mkdirp(dir)
            for (name, destination) in [("dangling", "../missing"), ("external", external), ("cycle", "cycle"), ("regular-target", path.join(external, "secret"))] {
                let file = path.join(dir, name)
                try symlink(destination, file)
                let inode = try lstat(file)["ino"]
                links.append((file: file, destination: destination, inode: inode))
            }
        }
        let physicalExternal = try FileSystem.nativeRealpath(external)
        let physicalLinks = try links.map { path.join(try FileSystem.nativeRealpath(path.dirname($0.file)), path.basename($0.file)) }
        let check = { (file: String, key: String) in
            ok(!file.hasPrefix(external), "external target \(key)")
            ok(!links.contains { $0.file == file } && !physicalLinks.contains(file), "link target \(key)")
            ok(!file.hasPrefix(physicalExternal), "physical external target \(key)")
        }
        let readFile = fs.readFile, open = fs.open, readdir = fs.readdir
        fs.readFile = { p in check(p, "readFile"); return try readFile(p) }
        fs.open = { p, flags, mode in check(p, "open"); return try open(p, flags, mode) }
        fs.readdir = { p in check(p, "readdir"); return try readdir(p) }
        let all = try accounts(h.paths, []), from = all.find { $0["account"].str == h.acct.P }, to = all.find { $0["account"].str == h.acct.Z }
        let moved = try move(try inventory([from], to, h.paths, NOOP, ["processes": [], "writeCache": true]), to, h.paths)
        eq(moved["ok"], true, JSON.text(moved["receipt"]["failed"]))
        deq(moved["receipt"]["sessions"].map { $0["id"] }, [Value(SOURCE), Value(child)])
        ok(try undo(h.paths)["dest"])
        fs = FileSystem()
        for link in links {
            eq(String(decoding: try FileSystem.nativeReadlink(link.file), as: UTF8.self), link.destination)
            eq(try lstat(link.file)["ino"], link.inode)
        }
    }

    @Test("regular sidecar hashes and fingerprints retain the existing receipt format")
    func sidecarHashFormat() throws {
        let h = try home(), data = Data("unchanged synthetic sidecar\n".utf8), dir = path.join(h.project, SOURCE), file = path.join(dir, "snapshot")
        try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
        try h.record("P", SOURCE, rehomeRecord())
        try mkdirp(dir)
        try writeData(file, data)
        let detail = try FileSystem.nativeStat(file, true, follow: true).value
        let signature = [detail["dev"], detail["ino"], detail["size"], detail["mtimeNs"], detail["ctimeNs"]].map { $0.description }.joined(separator: ":")
        let all = try accounts(h.paths, []), from = all.find { $0["account"].str == h.acct.P }, to = all.find { $0["account"].str == h.acct.Z }
        let inv = try inventory([from], to, h.paths, NOOP, ["processes": []])
        eq(inv["move"][0]["sidecar"]["sha"], Value(sha(JSON.text([["bytes": Value(data.count), "rel": "snapshot", "sha": Value(sha(data))]]))))
        eq(inv["move"][0]["sidecar"]["fingerprint"], Value(sha(JSON.text([["fingerprint": Value(signature), "rel": "snapshot"]]))))
    }

    @Test("trusted project aliases preserve logical move and Undo paths including legacy receipts")
    func trustedProjectAliases() throws {
        for legacy in [false, true] {
            let h = try home(), physical = path.join(h.root, "physical-project"), data = Data("Synthetic ordinary sidecar".utf8)
            try h.write(SOURCE, branchEntries(4, SOURCE, 1))
            try h.record("P", SOURCE, rehomeRecord())
            try mkdirp(path.join(h.project, SOURCE))
            try writeData(path.join(h.project, SOURCE, "ordinary"), data)
            try symlink("absent", path.join(h.project, SOURCE, "dangling"))
            try rename(h.project, physical)
            try symlink(physical, h.project)
            let transcript = h.transcript(SOURCE), before = try readData(transcript)
            let all = try accounts(h.paths, []), from = all.find { $0["account"].str == h.acct.P }, to = all.find { $0["account"].str == h.acct.Z }
            let moved = try move(try inventory([from], to, h.paths, NOOP, ["processes": []]), to, h.paths)
            eq(moved["ok"], true, JSON.text(moved["receipt"]["failed"]))
            eq(moved["receipt"]["sessions"][0]["targetTranscript"], Value(transcript))
            eq(moved["receipt"]["sessions"][0]["record"], Value(h.recordFile("Z", SOURCE)))
            eq(moved["receipt"]["sessions"][0]["sidecars"]["canonicalRoot"], Value(path.join(try FileSystem.nativeRealpath(physical), SOURCE)))
            if legacy {
                moved["receipt"]["sessions"][0]["sidecars"].removeKey("canonicalRoot")
                try writeJSON(moved["file"].str, moved["receipt"])
            }
            ok(try undo(h.paths, ["processes": []])["dest"], "\(legacy)")
            eq(try readData(transcript), before)
            eq(try readData(path.join(h.project, SOURCE, "ordinary")), data)
            eq(String(decoding: try FileSystem.nativeReadlink(path.join(h.project, SOURCE, "dangling")), as: UTF8.self), "absent")
        }
    }
}
