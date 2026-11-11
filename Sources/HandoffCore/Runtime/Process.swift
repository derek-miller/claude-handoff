import Darwin
import Foundation

// spawnSync result: { status, stdout, stderr, error }.
public struct SpawnResult {
    public var status: Int32?
    public var stdout: String
    public var stderr: String
    public var error: JSError?
    public var timedOut = false
    public init(status: Int32?, stdout: String = "", stderr: String = "", error: JSError? = nil) {
        self.status = status; self.stdout = stdout; self.stderr = stderr; self.error = error
    }
    public var value: Value {
        ["status": status.map { Value(Int($0)) } ?? .null, "stdout": Value(stdout), "stderr": Value(stderr), "error": error?.value ?? .undefined]
    }
}

public struct SpawnOptions {
    public var timeout: Double? = nil  // milliseconds
    public var env: [String: String]? = nil
    public var input: Data? = nil
    public var cwd: String? = nil
    // Node's maxBuffer in bytes per stream; nil = no limit. Exceeding it fails with ENOBUFS.
    public var maxBuffer: Double? = nil
    public init(timeout: Double? = nil, env: [String: String]? = nil, input: Data? = nil, cwd: String? = nil, maxBuffer: Double? = nil) {
        self.timeout = timeout; self.env = env; self.input = input; self.cwd = cwd; self.maxBuffer = maxBuffer
    }
}

// External commands go through this table so tests can replace them, like the JS tests patch child_process.
public final class ChildProcess {
    public var spawnSync: (String, [String], SpawnOptions) -> SpawnResult = ChildProcess.nativeSpawnSync
    // Fire-and-wait with a timeout and ignored stdio: { status, timedOut }.
    public var command: (String, [String], Double) -> SpawnResult = { file, args, timeout in
        if timeout <= 0 { var r = SpawnResult(status: nil); r.timedOut = true; return r }
        var r = ChildProcess.nativeSpawnSync(file, args, SpawnOptions(timeout: timeout))
        r.stdout = ""; r.stderr = ""
        return r
    }
    public init() {}

    public static func nativeSpawnSync(_ file: String, _ args: [String], _ options: SpawnOptions) -> SpawnResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: file.hasPrefix("/") ? file : "/usr/bin/env")
        p.arguments = file.hasPrefix("/") ? args : [file] + args
        if let env = options.env { p.environment = env }
        if let cwd = options.cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = options.input == nil ? FileHandleNull.devNull : inp
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch {
            let code = (error as NSError).code == 4 ? ENOENT : EACCES
            return SpawnResult(status: nil, error: fsError(Int32(code), "spawnSync \(file)", file))
        }
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if let input = options.input {
            inp.fileHandleForWriting.write(input)
            try? inp.fileHandleForWriting.close()
        }
        var timedOut = false
        if let timeout = options.timeout, timeout > 0 {
            if exited.wait(timeout: .now() + timeout / 1000) == .timedOut, p.isRunning { timedOut = true; p.terminate() }
        }
        p.waitUntilExit()
        group.wait()
        var r = SpawnResult(status: timedOut || p.terminationReason == .uncaughtSignal ? nil : p.terminationStatus,
                            stdout: String(decoding: outData, as: UTF8.self), stderr: String(decoding: errData, as: UTF8.self))
        if timedOut { r.timedOut = true; r.error = JSError("spawnSync \(file) ETIMEDOUT", code: "ETIMEDOUT") }
        else if let limit = options.maxBuffer, Double(outData.count) > limit || Double(errData.count) > limit {
            r.error = JSError("spawnSync \(file) ENOBUFS", code: "ENOBUFS")
        }
        return r
    }
}

enum FileHandleNull {
    static let devNull = Foundation.FileHandle(forReadingAtPath: "/dev/null")!
}

public var childProcess = ChildProcess()

// Process-level facts the engine reads (pid, environment, home).
public final class Host {
    public var pid: Int32 = getpid()
    public var homedir: () -> String = { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }
    public var tmpdir: () -> String = { (ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp").replacingOccurrences(of: "/+$", with: "", options: .regularExpression) }
    public var env: () -> [String: String] = { ProcessInfo.processInfo.environment }
    public var totalmem: () -> Double = { Double(ProcessInfo.processInfo.physicalMemory) }
    public var now: () -> Double = { (Date().timeIntervalSince1970 * 1000).rounded(.down) }
    // performance.now() in milliseconds.
    public var monotonic: () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
    public var sleep: (Double) -> Void = { ms in if ms > 0 { usleep(useconds_t(min(ms, 4_000_000) * 1000)) } }
    public var exitCode: Int32 = 0
    public var stdinIsTTY: () -> Bool = { isatty(0) != 0 }
    public var stdout: (String) -> Void = { s in Foundation.FileHandle.standardOutput.write(Data(s.utf8)) }
    public var stderr: (String) -> Void = { s in Foundation.FileHandle.standardError.write(Data(s.utf8)) }
    public init() {}
}

public var process = Host()
