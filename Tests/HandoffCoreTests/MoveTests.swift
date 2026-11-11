import Darwin
import Foundation
import Testing
@testable import HandoffCore

extension Engine {
    @Suite("moves and verification")
    struct Moves {
        static func arg(_ args: [Value], _ i: Int) -> Value { i < args.count ? args[i] : .undefined }

        static func mutatingOpen(_ flags: Int32) -> Bool { flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC | O_APPEND) != 0 }

        // The last row per account wins.
        static func byAccount(_ all: Value) -> [String: Value] {
            var out: [String: Value] = [:]
            for row in all.elements { out[row.account.str] = row }
            return out
        }

        static func names(_ dir: String) throws -> Value { .strings(try readdir(dir)) }

        // An external process holding the state lock, through lockf(1) or a perl flock.
        final class Holder {
            let process: Foundation.Process
            let input: Pipe
            init(process: Foundation.Process, input: Pipe) { self.process = process; self.input = input }
            func release() {
                try? input.fileHandleForWriting.close()
                process.waitUntilExit()
            }
        }

        static func hold(_ file: String, native: Bool = false) throws -> Holder {
            let command = native
                ? ["/usr/bin/lockf", "-k", "-t", "0", file, "/bin/sh", "-c", "printf ready; cat >/dev/null"]
                : ["/usr/bin/perl", "-MFcntl=:flock", "-e", "open(my $lock, \">>\", $ARGV[0]) or die $!; flock($lock, LOCK_EX) or die $!; $| = 1; print \"ready\"; 1 while <STDIN>;", file]
            let child = Foundation.Process(), input = Pipe(), output = Pipe()
            child.executableURL = URL(fileURLWithPath: command[0])
            child.arguments = Array(command.dropFirst())
            child.standardInput = input
            child.standardOutput = output
            child.standardError = FileHandle.nullDevice
            try child.run()
            _ = output.fileHandleForReading.availableData
            return Holder(process: child, input: input)
        }

        @Test("placed verification ignores activity and bridge registration but records title drift without repairing it")
        func placedVerification() throws {
            let h = try home()
            try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
            try h.record("P", SOURCE)
            let from = try h.account("P"), to = try h.account("T")
            let result = try move(try inventory([from], to, h.paths), to, h.paths)
            let file = result.receipt.sessions[0].record.str
            let record = try readJSON(file)
            record.lastFocusedAt = Value(dateNow())
            record.completedTurns = 100
            record.bridgeSessionIds = ["session_new"]
            record.writtenBranches = ["main", "feature/anything"]
            record.prs = [["prNumber": 1, "url": "https://github.com/example/repo/pull/1"]]
            record.branch = "feature/anything"
            record.prState = "merged"
            record.model = "claude-opus-5"
            record.contextExceededCount = 3
            record.alwaysAllowedReasons = ["Bash"]
            record.someFutureDesktopField = ["anything": true]
            try writeJSON(file, record)
            deq(try verifyPlaced(h.paths).changed, [])
            record.title = "Different title after placement"
            record.isArchived = true
            try writeJSON(file, record)
            let changed = try verifyPlaced(h.paths)
            eq(changed.changed.length, 1)
            deq(changed.changed[0].fields.sorted(), ["isArchived", "title"])
            ok(exists(changed.changed[0].placed.str))
            ok(exists(changed.changed[0].found.str))
            eq(try readJSON(file).title, record.title)
            record.lastFocusedAt = Value(record.lastFocusedAt.asNumber! + 1)
            try writeJSON(file, record)
            eq(try verifyPlaced(h.paths).changed[0].found, changed.changed[0].found)
        }

        @Test("native and fallback helpers share the kernel lock and release it after a move")
        func kernelLock() throws {
            let nativeAvailable = exists("/usr/bin/lockf")
            for native in nativeAvailable ? [false, true] : [false] {
                let h = try home()
                try h.write(id(999), [entry("user", 999, nil, id(999))])
                try h.record("P", id(999))
                try mkdirp(h.paths.state)
                let file = path.join(h.paths.state.str, "lock")
                let guardian = try Moves.hold(file, native: native), inode = try stat(file).ino
                let args = ["--from", "p@example.com", "--to", "z@example.com", "--json"]
                let result = cli(h.root, args)
                guardian.release()
                eq(result.code, 1)
                eq(lines(result.stdout).at(-1).code, "LOCK_BUSY")
                eq(try readdir(h.dir("Z")).count, 0)
                let moved = cli(h.root, args)
                eq(moved.code, 0, moved.stderr)
                eq(try readdir(h.dir("Z")).count, 1)
                eq(try stat(file).ino, inode)
                let undone = cli(h.root, ["undo", "--json"])
                eq(undone.code, 0, undone.stderr)
                eq(try readdir(h.dir("P")).count, 1)
            }
        }

        @Test("a contained destination supersedes only its Desktop record")
        func containedDestination() throws {
            let h = try home()
            let q1: Value = [entry("user", 940, nil, id(940)), entry("assistant", 941, 940, id(940))]
            try h.write(id(940), q1.concat([entry("user", 942, 941, id(940))]))
            try h.record("P", id(940))
            try h.write(id(945), fork(q1, id(940), id(945), "Q"))
            let olderTranscript = h.transcript(id(945))
            try h.record("Z", id(945))
            let by = Moves.byAccount(try accounts(h.paths))
            let inv = try inventory([by[h.acct.P]!], by[h.acct.Z]!, h.paths)
            deq(inv.move.map { $0.id }, [Value(id(940))])
            let result = try move(inv, by[h.acct.Z]!, h.paths)
            eq(result.ok, true)
            deq(result.receipt.superseded.filter { !$0.source.truthy }.map { $0.id }, [Value(id(945))])
            ok(exists(olderTranscript))
            deq(.strings(try readdir(h.dir("Z")).map { String($0.dropFirst(6).dropLast(5)) }), [result.receipt.sessions[0].targetId])
            deq(try Moves.names(h.dir("P")), [])
            ok(try undo(h.paths).dest)
            ok(exists(olderTranscript))
            deq(.strings(try readdir(h.dir("Z")).map { String($0.dropFirst(6).dropLast(5)) }), [Value(id(945))])
            eq(try readdir(h.dir("P")).count, 1)
        }

        @Test("a target without a Desktop record id never covers and retires a valid source")
        func targetWithoutRecordId() throws {
            let h = try home()
            try h.write(SOURCE, [entry("user", 1, nil, SOURCE)])
            try h.record("P", SOURCE, rehomeRecord(["title": "Valid source"]))
            try h.record("Z", SOURCE, rehomeRecord(["sessionId": nil, "title": "Invalid target identity"]))
            let from = try h.account("P"), to = try h.account("Z")
            let inv = try inventory([from], to, h.paths)
            eq(inv.there.length, 0)
            eq(inv.move.length, 0)
            match(inv.blocked[0].error, "target session id collision")
            let result = try move(inv, to, h.paths)
            eq(result.ok, false)
            ok(exists(h.recordFile("P", SOURCE)))
        }

        @Test("stale source entries retire when the destination already holds them")
        func staleSourceEntriesRetire() throws {
            let h = try home()
            try h.write(id(960), [entry("user", 960, nil, id(960)), entry("assistant", 961, 960, id(960))])
            try h.record("P", id(960))
            func pick() throws -> (from: Value, to: Value) { let by = Moves.byAccount(try accounts(h.paths)); return ([by[h.acct.P]!], by[h.acct.Z]!) }
            var p = try pick()
            let first = try move(try inventory(p.from, p.to, h.paths), p.to, h.paths)
            eq(first.receipt.sessions.length, 1)
            try h.record("P", id(960))
            p = try pick()
            let inv = try inventory(p.from, p.to, h.paths)
            eq(inv.move.length, 0)
            eq(inv.there.length, 1)
            var stages: [String] = []
            let second = try move(inv, p.to, h.paths, fn { args in
                if !Moves.arg(args, 2)["live"].truthy { stages.append("\(Moves.arg(args, 0)) \(Moves.arg(args, 1))") }
                return .undefined
            })
            #expect(stages == ["retired 1 source records → quarantine | chat messages unchanged"])
            eq(second.receipt.sessions.length, 0)
            deq(try Moves.names(h.dir("P")), [])
            ok(exists(h.transcript(id(960))))
            eq(try readdir(h.dir("Z")).count, 1)
            ok(try undo(h.paths).dest)
            eq(try readdir(h.dir("P")).count, 1)
            eq(try readdir(h.dir("Z")).count, 1)
        }

        // A transcript may be streamed through fs.open, so read-only opens count as reads.
        @Test("retirement rereads only potential destination carriers and preserves sources when carriers change")
        func retirementRereadsCarriers() throws {
            for changed in [false, true] {
                let h = try home(), carrier = id(2), unrelated = [id(3), id(4)]
                let source: Value = [entry("user", 1, nil, SOURCE)]
                try h.write(SOURCE, source)
                try h.record("P", SOURCE)
                try h.write(carrier, fork(source, SOURCE, carrier, "Carrier"))
                try h.record("Z", carrier)
                for (i, sid) in unrelated.enumerated() {
                    try h.write(sid, [entry("user", 10 + i, nil, sid)])
                    try h.record("Z", sid)
                }
                let from = try h.account("P"), to = try h.account("Z")
                let inv = try inventory([from], to, h.paths)
                eq(inv.move.length, 0)
                eq(inv.there.length, 1)
                if changed { try h.write(carrier, [entry("user", 20, nil, carrier)]) }
                var reads: [String: Int] = [:]
                let read = fs.readFile, open = fs.open
                fs.readFile = { file in
                    if file.hasSuffix(".jsonl") { reads[file, default: 0] += 1 }
                    return try read(file)
                }
                fs.open = { file, flags, mode in
                    if file.hasSuffix(".jsonl") && !Moves.mutatingOpen(flags) { reads[file, default: 0] += 1 }
                    return try open(file, flags, mode)
                }
                let result: Value
                do {
                    defer { fs.readFile = read; fs.open = open }
                    result = try move(inv, to, h.paths)
                }
                ok((reads[h.transcript(carrier)] ?? 0) > 0)
                for sid in unrelated { eq(reads[h.transcript(sid)] ?? 0, 0, sid) }
                eq(result.ok, Value(!changed))
                deq(result.receipt.superseded.filter { $0.source.truthy }.map { $0.id }, changed ? [] : [Value(SOURCE)])
                eq(exists(h.recordFile("P", SOURCE)), changed)
                if changed { match(result.receipt.failed[0].error, "destination changed since inventory") }
            }
        }

        @Test("a vanished existing destination keeps the source entry")
        func vanishedDestination() throws {
            let h = try home()
            try h.write(id(920), [entry("user", 920, nil, id(920))])
            try h.record("P", id(920))
            func pick() throws -> (from: Value, to: Value) { let by = Moves.byAccount(try accounts(h.paths)); return ([by[h.acct.P]!], by[h.acct.Z]!) }
            var p = try pick()
            let first = try move(try inventory(p.from, p.to, h.paths), p.to, h.paths)
            try h.record("P", id(920))
            p = try pick()
            let inv = try inventory(p.from, p.to, h.paths)
            eq(inv.there.length, 1)
            try unlink(first.receipt.sessions[0].targetTranscript.str)
            let second = try move(inv, p.to, h.paths)
            eq(second.ok, false)
            match(second.receipt.failed[0].error, "destination changed since inventory")
            eq(try readdir(h.dir("P")).count, 1)
        }

        @Test("retirement records the exact bytes after harmless source focus drift")
        func retirementExactBytes() throws {
            let h = try home()
            try h.write(id(928), [entry("user", 928, nil, id(928))])
            try h.record("P", id(928))
            let sourceRecord = h.recordFile("P", id(928))
            let by = Moves.byAccount(try accounts(h.paths))
            let result = try move(try inventory([by[h.acct.P]!], by[h.acct.Z]!, h.paths), by[h.acct.Z]!, h.paths, fn { args in
                if Moves.arg(args, 0) != "verify" || !(Moves.arg(args, 2)["completed"] == 0) { return .undefined }
                let focused = try readJSON(sourceRecord)
                try writeJSON(sourceRecord, .spread(focused, ["lastFocusedAt": Value(focused.lastFocusedAt.asNumber! + 1)]))
                return .undefined
            })
            eq(result.ok, true)
            ok(try undo(h.paths).dest)
            eq(try readJSON(sourceRecord).lastFocusedAt, 3)
        }

        @Test("pending cleanup refuses wrong scoped clients and defers cross-login sources without calls")
        func pendingCleanupRefusesWrongClients() throws {
            let f = try pendingOrganizations(), before = try readData(f.moved.file.str)
            let actives: [Value] = [["account": Value(f.h.acct.T), "state": "known"], ["account": nil, "state": "unknown"],
                                    ["account": Value(f.h.acct.P), "state": "unknown"], ["account": Value(f.h.acct.P), "state": "logged-out"]]
            for active in actives {
                let deferred = try sweep(f.h.paths, .spread(f.options, ["active": .spread(active, ["org": Value(f.h.org.T)])]))
                eq(deferred.pending, true)
                eq(f.calls.value.count, 0)
                #expect(try readData(f.moved.file.str) == before)
            }
            let stale = try finishPending(f.h.paths, ["processes": f.identity.processes, "cloud": cloudFixture(f.h, ["account": Value(f.h.acct.T), "list": fn { _ in
                Issue.record("stale client must not run")
                throw JSError("stale client must not run")
            }])])
            eq(stale.pending, true)
            #expect(try readData(f.moved.file.str) == before)
            for patch: Value in [["account": Value(f.h.acct.T)], ["org": Value(f.h.org.Q)]] {
                let result = try finishPending(f.h.paths, .spread(f.options, ["cloud": fn { args in .spread(try f.client.call(Moves.arg(args, 0)), patch) }]))
                eq(result.ok, false)
                eq(result.complete, false)
                match(result.failed.map { $0.error }.join(" "), "does not match the recorded source")
                #expect(f.rows.allSatisfy { $0.status == "active" })
                eq(f.requested.value.count, 0)
            }
        }

        @Test("same-account organization moves rehome one record without copying history")
        func sameAccountOrganizationMoves() throws {
            let h = try home()
            let teamDir = path.join(h.paths.records.str, h.acct.P, h.org.T)
            try mkdirp(teamDir)
            let transcript = h.transcript(SOURCE)
            let entries: Value = [
                entry("user", 1, nil, SOURCE),
                entry("assistant", 2, 1, SOURCE),
                ["type": "bridge-session", "sessionId": Value(SOURCE), "bridgeSessionId": "session_fixture", "ownerAccountUuid": Value(h.acct.P), "ownerOrganizationUuid": Value(h.org.P)],
            ]
            try h.write(SOURCE, entries)
            try mkdirp(path.join(h.project, SOURCE, "subagents"))
            try writeText(path.join(h.project, SOURCE, "subagents", "agent.jsonl"), "{\"fixture\":true}\n")
            let recordId = "local_\(id(777))", recordName = "\(recordId).json"
            try h.record("P", SOURCE, rehomeRecord(["sessionId": Value(recordId), "bridgeSessionIds": ["session_fixture"]]))
            try rename(h.recordFile("P", SOURCE), path.join(h.dir("P"), recordName))
            let cleared: Value = ["type": "bridge-session", "sessionId": Value(SOURCE), "bridgeSessionId": "", "lastSequenceNum": 0]
            let before = try readData(transcript) + Data("\(JSON.text(cleared))\n".utf8)

            func select(_ fromOrg: String, _ toOrg: String) throws -> (from: Value, to: Value) {
                let all = try accounts(h.paths)
                return (all.find { $0.account.str == h.acct.P && $0.org.str == fromOrg }, all.find { $0.account.str == h.acct.P && $0.org.str == toOrg })
            }

            var picked = try select(h.org.P, h.org.T)
            var inv = try inventory([picked.from], picked.to, h.paths)
            eq(inv.move.length, 1)
            eq(inv.move[0].strategy, "rehome")
            let first = try move(inv, picked.to, h.paths)
            eq(first.ok, true)
            eq(first.receipt.sessions[0].strategy, "rehome")
            eq(first.receipt.sessions[0].targetId, Value(SOURCE))
            #expect(try readData(transcript) == before)
            let clearedStat = try stat(transcript)
            #expect(try readdir(h.project).sorted() == [SOURCE, "\(SOURCE).jsonl"].sorted())
            deq(try Moves.names(h.dir("P")), [])
            deq(try Moves.names(teamDir), [Value(recordName)])

            picked = try select(h.org.T, h.org.P)
            inv = try inventory([picked.from], picked.to, h.paths)
            eq(inv.move[0].strategy, "rehome")
            let second = try move(inv, picked.to, h.paths)
            eq(second.ok, true)
            #expect(try readData(transcript) == before)
            deq(try Moves.names(h.dir("P")), [Value(recordName)])
            deq(try Moves.names(teamDir), [])

            for _ in 1..<10 {
                picked = try select(h.org.P, h.org.T)
                inv = try inventory([picked.from], picked.to, h.paths)
                eq(inv.move[0].strategy, "rehome")
                eq(try move(inv, picked.to, h.paths).ok, true)
                picked = try select(h.org.T, h.org.P)
                inv = try inventory([picked.from], picked.to, h.paths)
                eq(inv.move[0].strategy, "rehome")
                eq(try move(inv, picked.to, h.paths).ok, true)
                #expect(try readData(transcript) == before)
                eq(try stat(transcript).mtimeMs, clearedStat.mtimeMs)
                #expect(try readdir(h.project).sorted() == [SOURCE, "\(SOURCE).jsonl"].sorted())
            }

            func bytes(_ root: String) throws -> Double {
                var total = 0.0
                for name in try readdir(root) {
                    let file = path.join(root, name), info = try lstat(file)
                    total += try info.isDirectory.call().truthy ? bytes(file) : info.size.asNumber!
                }
                return total
            }
            ok(try bytes(h.paths.state.str) < 1_000_000)

            let undone = try undo(h.paths)
            ok(undone.dest)
            deq(try Moves.names(h.dir("P")), [])
            deq(try Moves.names(teamDir), [Value(recordName)])
            #expect(try readData(transcript) == before)
        }

        @Test("cross-login moves rehome across same and different organizations")
        func crossLoginRehome() throws {
            for targetOrg in ["P", "Z"] {
                let h = try home()
                try h.write(SOURCE, [entry("user", 1, nil, SOURCE), entry("assistant", 2, 1, SOURCE)])
                try h.record("P", SOURCE, rehomeRecord())
                let targetDir = path.join(h.paths.records.str, h.acct.Z, h.org[targetOrg])
                try mkdirp(targetDir)
                let before = try readData(h.transcript(SOURCE))
                let all = try accounts(h.paths)
                let from = all.find { $0.account.str == h.acct.P && $0.org.str == h.org.P }
                let to = all.find { $0.account.str == h.acct.Z && $0.org.str == h.org[targetOrg] }
                let inv = try inventory([from], to, h.paths)
                eq(inv.move[0].strategy, "rehome")
                let result = try move(inv, to, h.paths)
                eq(result.ok, true)
                eq(result.receipt.sessions[0].strategy, "rehome")
                eq(result.receipt.sessions[0].targetId, Value(SOURCE))
                #expect(try readData(h.transcript(SOURCE)) == before)
                deq(try Moves.names(h.dir("P")), [])
                deq(try Moves.names(targetDir), [Value("local_\(SOURCE).json")])
            }
        }
    }
}
