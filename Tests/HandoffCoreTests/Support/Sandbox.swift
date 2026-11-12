import Foundation
import Testing
@testable import HandoffCore

// Every engine test runs inside this trait. The engine reaches the filesystem, clock, child processes,
// stdout and the network through replaceable tables; each test starts from native tables with HOME in a
// fresh temporary directory, so no test can touch the real Claude data, and mocks never leak between tests.
struct Sandboxed: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }
        Sandbox.begin()
        defer { Sandbox.end() }
        try await function()
    }
}

// The binaries that would act on the real Desktop or keychain; a test must mock them explicitly.
let NATIVE_COMMANDS: Set<String> = ["/usr/bin/osascript", "/usr/bin/open", "/bin/launchctl", "launchctl", "pkill"]

enum Sandbox {
    nonisolated(unsafe) static var roots: [String] = []

    static func begin() {
        fs = FileSystem()
        process = Host()
        let home = temporaryDirectory("ct-sandbox-")
        process.homedir = { home }
        childProcess = fixtureChildProcess()
        cloudFetch = { request in throw EngineError("fixture fetch requires a mock: \(request["url"])") }
    }

    static func end() {
        fs = FileSystem()
        process = Host()
        childProcess = ChildProcess()
        cloudFetch = { request in throw EngineError("fixture fetch requires a mock: \(request["url"])") }
        for root in roots { try? FileManager.default.removeItem(atPath: root) }
        roots = []
    }

    // The login keychain is unavailable and native Desktop commands fail unless the test supplies its own.
    static func fixtureChildProcess() -> ChildProcess {
        let table = ChildProcess()
        table.spawnSync = { file, args, options in
            if file == "/usr/bin/security" { return SpawnResult(status: 1, stderr: "fixture login unavailable") }
            if NATIVE_COMMANDS.contains(file) { return SpawnResult(status: nil, error: EngineError("fixture native command requires a mock")) }
            return ChildProcess.nativeSpawnSync(file, args, options)
        }
        let command = table.command
        table.command = { file, args, timeout in
            if NATIVE_COMMANDS.contains(file) { return SpawnResult(status: nil, error: EngineError("fixture native command requires a mock")) }
            return command(file, args, timeout)
        }
        return table
    }
}

func temporaryDirectory(_ prefix: String) -> String {
    // os.tmpdir(): $TMPDIR without its trailing slash and without resolving /var to /private/var.
    let base = NSTemporaryDirectory().replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    var template = Array(path.join(base, prefix + "XXXXXX").utf8CString)
    guard mkdtemp(&template) != nil else { fatalError("mkdtemp failed") }
    let root = String(cString: template)
    Sandbox.roots.append(root)
    return root
}
