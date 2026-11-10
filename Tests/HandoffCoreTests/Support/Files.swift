import Darwin
import Foundation
import Testing
@testable import HandoffCore

// Direct filesystem access for test setup and assertions. These bypass the engine's `fs` table, so a test
// that patches `fs` still sees the real files.

func readData(_ file: String) throws -> Data { try NodeFS.nativeReadFile(file) }
func readText(_ file: String) throws -> String { String(decoding: try readData(file), as: UTF8.self) }
func readJSON(_ file: String) throws -> Value { try JSON.parse(try readText(file)) }
// readFile(...).catch(() => null)
func readOrNil(_ file: String) -> Value { guard let text = try? readText(file) else { return .null }; return Value(text) }
func readDataOrNil(_ file: String) -> Data? { try? readData(file) }

func writeData(_ file: String, _ data: Data) throws { try NodeFS.nativeWriteFile(file, data, "w", 0o666) }
func writeText(_ file: String, _ text: String) throws { try writeData(file, Data(text.utf8)) }
func writeText(_ file: Value, _ text: String) throws { try writeText(file.str, text) }
// writeFile(file, JSON.stringify(value)) — compact, no trailing newline.
func writeJSON(_ file: String, _ value: Value, space: Int = 0) throws { try writeText(file, JSON.text(value, space: space)) }
func appendText(_ file: String, _ text: String) throws { try NodeFS.nativeWriteFile(file, Data(text.utf8), "a", 0o666) }

func mkdirp(_ dir: String) throws { try NodeFS.nativeMkdir(dir, true, 0o777) }
func mkdirp(_ dir: Value) throws { try mkdirp(dir.str) }
func rename(_ from: String, _ to: String) throws { if Darwin.rename(from, to) != 0 { throw fsError(errno, "rename", from, to) } }
func unlink(_ file: String) throws { if Darwin.unlink(file) != 0 { throw fsError(errno, "unlink", file) } }
func rmrf(_ file: String) throws { try NodeFS.nativeRm(file, true, true) }
func symlink(_ target: String, _ file: String) throws { if Darwin.symlink(target, file) != 0 { throw fsError(errno, "symlink", target, file) } }
func exists(_ file: String) -> Bool { var s = Darwin.stat(); return Darwin.lstat(file, &s) == 0 }
// readdir in directory order, like Node.
func readdir(_ dir: String) throws -> [String] { try NodeFS.nativeReaddir(dir).map(\.name) }
func readdirOrEmpty(_ dir: String) -> [String] { (try? readdir(dir)) ?? [] }
func stat(_ file: String) throws -> Value { try NodeFS.nativeStat(file, false, follow: true) }
func lstat(_ file: String) throws -> Value { try NodeFS.nativeStat(file, false, follow: false) }

// Receipts in the state directory, oldest first.
func receiptFiles(_ h: Home) -> [String] {
    readdirOrEmpty(h.paths.state.str).filter { JSRegExp.cached(#"^\d.*\.json$"#).test($0) }.sorted().map { path.join(h.paths.state.str, $0) }
}

// MARK: - CLI

struct CLIResult {
    let stdout: String
    let stderr: String
    let code: Int32
}

// Runs the claude-handoff CLI in process with HOME at `home`. `setup` replaces tables (child processes, fs)
// for this run only.
func cli(_ home: String, _ args: [String], setup: () -> Void = {}) -> CLIResult {
    let saved = (fs, process, childProcess, cloudFetch)
    defer { (fs, process, childProcess, cloudFetch) = saved }
    process = Host()
    process.homedir = { home }
    process.stdinIsTTY = { false }
    childProcess = Sandbox.fixtureChildProcess()
    var out = "", err = ""
    process.stdout = { out += $0 }
    process.stderr = { err += $0 }
    setup()
    let code = runCLI(args)
    return CLIResult(stdout: out, stderr: err, code: code)
}

// A fixed /bin/ps table: `list` answers pid,ppid,lstart,comm and `commands` answers the command= form.
func processSetup(list: String, commands: String) {
    let run = childProcess.spawnSync
    childProcess.spawnSync = { file, args, options in
        if file == "/bin/ps" { return SpawnResult(status: 0, stdout: args.count > 1 && args[1].hasSuffix("command=") ? commands : list) }
        return run(file, args, options)
    }
}

// MARK: - fetch

// A fetch mock: `handle(url, request)` returns a body value (encoded as JSON), or a full response from response().
func mockFetch(_ handle: @escaping (URL, Value) throws -> Value) {
    cloudFetch = { request in
        let url = URL(string: request.url.str)!
        let answer = try handle(url, request)
        if answer.isPlainObject, answer.hasOwn("$response") { return answer["$response"] }
        return response(answer)
    }
}

func response(_ body: Value, status: Int = 200, headers: Value = [:]) -> Value {
    let data: Data = body.asData ?? (body.isString ? Data(body.str.utf8) : Data(JSON.text(body).utf8))
    let lowered = Value.newObject()
    for (k, v) in headers.ownEntries { lowered[k.lowercased()] = v }
    return ["$response": ["status": Value(status), "ok": Value((200...299).contains(status)), "headers": lowered, "body": Value(data)]]
}
