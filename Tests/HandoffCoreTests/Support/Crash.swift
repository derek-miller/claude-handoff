import Darwin
import Foundation
@testable import HandoffCore

// A crash at a chosen filesystem mutation. Throwing from the engine would run its rollback, which a killed
// process never does, so the fence lets the chosen mutation finish, then fails every later mutation and throws
// Crash: the disk holds what a process killed at that point would have left behind.
struct Crash: Error, CustomStringConvertible {
    var description: String { "fixture crash" }
}

enum CrashHook { case link, rename, writeFile, unlink, mkdir }

final class CrashFence {
    private(set) var crashed = false
    private let saved: FileSystem

    init(on hook: CrashHook, when trigger: @escaping ([String]) throws -> Bool) {
        saved = fs
        let native = saved, fenced = FileSystem()
        let guardLive = { [unowned self] in if self.crashed { throw Crash() } }
        let fire = { [unowned self] (args: [String]) throws in
            if try trigger(args) { self.crashed = true; throw Crash() }
        }
        fenced.readFile = { try native.readFile($0) }
        fenced.stat = { try native.stat($0, $1) }
        fenced.lstat = { try native.lstat($0, $1) }
        fenced.readdir = { try native.readdir($0) }
        fenced.realpath = { try native.realpath($0) }
        fenced.readlink = { try native.readlink($0) }
        fenced.handleStat = { try native.handleStat($0, $1) }
        fenced.handleReadFile = { try native.handleReadFile($0) }
        fenced.handleSync = { h in try guardLive(); try native.handleSync(h) }
        fenced.handleWrite = { h, d in try guardLive(); try native.handleWrite(h, d) }
        fenced.open = { p, flags, mode in
            if flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC | O_APPEND) != 0 { try guardLive() }
            return try native.open(p, flags, mode)
        }
        fenced.copyFile = { a, b in try guardLive(); try native.copyFile(a, b) }
        fenced.symlink = { a, b in try guardLive(); try native.symlink(a, b) }
        fenced.rmdir = { a in try guardLive(); try native.rmdir(a) }
        fenced.rm = { a, r, f in try guardLive(); try native.rm(a, r, f) }
        fenced.link = { a, b in try guardLive(); try native.link(a, b); if hook == .link { try fire([a, b]) } }
        fenced.rename = { a, b in try guardLive(); try native.rename(a, b); if hook == .rename { try fire([a, b]) } }
        fenced.writeFile = { p, d, flag, mode in try guardLive(); try native.writeFile(p, d, flag, mode); if hook == .writeFile { try fire([p]) } }
        fenced.unlink = { a in try guardLive(); try native.unlink(a); if hook == .unlink { try fire([a]) } }
        fenced.mkdir = { p, r, mode in try guardLive(); try native.mkdir(p, r, mode); if hook == .mkdir { try fire([p]) } }
        fs = fenced
    }

    func restore() { fs = saved }
}

// Runs `body` until the `hook` mutation that satisfies `trigger`, then stops it as a crash would.
// Returns whether the crash point was reached; errors other than the crash propagate.
@discardableResult
func crashing(on hook: CrashHook, when trigger: @escaping ([String]) throws -> Bool, _ body: () throws -> Void) throws -> Bool {
    let fence = CrashFence(on: hook, when: trigger)
    defer { fence.restore() }
    do { try body() } catch {
        if !fence.crashed { throw error }
    }
    return fence.crashed
}
