import Foundation
@testable import HandoffCore

// handoff-parity serve: runs one engine export for Tests/Parity/shim.mjs.
// Protocol (JSON lines): stdin gets {name, args}; stdout answers with {result}|{error}|{unsupported}.
// While running, callbacks, spawnSync, command and fetch are sent to Node as
// {callback,args} / {spawnSync} / {command} / {fetch}, which answers {value} or {thrown}.

final class LineReader {
    private var buffer = Data()
    func next() -> String? {
        while true {
            if let i = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<i]
                buffer.removeSubrange(buffer.startIndex...i)
                return String(decoding: line, as: UTF8.self)
            }
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty { return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self) }
            buffer.append(chunk)
        }
    }
}

let reader = LineReader()
let realStdout = FileHandle.standardOutput
func send(_ v: Value) { realStdout.write(Data((JSON.text(v) + "\n").utf8)) }

var codec = Codec(callFunction: { _, _ in .undefined })
func ask(_ message: Value) throws -> Value {
    send(message)
    guard let line = reader.next() else { throw JSError("parity peer closed") }
    let reply = try JSON.parse(line)
    if reply.hasOwn("thrown") { throw JSError(codec.decode(reply["thrown"])) }
    return codec.decode(reply["value"])
}
codec = Codec(callFunction: { index, args in
    try ask(["callback": Value(index), "args": try codec.encode(Value(args))])
})

// Engine output must not interleave with the protocol: route stdout/stderr writes to stderr.
process.stdout = { FileHandle.standardError.write(Data($0.utf8)) }
childProcess.spawnSync = { file, args, options in
    var opts: Value = .newObject()
    if let t = options.timeout { opts["timeout"] = Value(t) }
    if let m = options.maxBuffer { opts["maxBuffer"] = Value(m) }
    if let env = options.env { opts["env"] = .object(JSObject(env.sorted { $0.key < $1.key }.map { ($0.key, Value($0.value)) })) }
    if let input = options.input { opts["input"] = Value(String(decoding: input, as: UTF8.self)) }
    do {
        let r = try ask(["spawnSync": [Value(file), .strings(args), opts]])
        var out = SpawnResult(status: r.status.asNumber.map { Int32($0) }, stdout: r.stdout.asString ?? "", stderr: r.stderr.asString ?? "")
        if !r.error.nullish { out.error = JSError(r.error.message.description, code: r.error.code) }
        return out
    } catch {
        return SpawnResult(status: nil, error: JSError(jsErrorValue(error)))
    }
}
childProcess.command = { file, args, timeout in
    do {
        let r = try ask(["command": [Value(file), .strings(args), Value(timeout)]])
        var out = SpawnResult(status: r.status.asNumber.map { Int32($0) })
        out.timedOut = r.timedOut.truthy
        return out
    } catch {
        // Node's command() rejects when spawn throws; surface the same failure.
        var out = SpawnResult(status: nil, error: JSError(jsErrorValue(error)))
        out.timedOut = false
        return out
    }
}
cloudFetch = { request in
    let r = try ask(["fetch": request])
    let hex = Array(r.body.description.utf8)
    var data = Data(capacity: hex.count / 2)
    var i = 0
    while i + 1 < hex.count { data.append(UInt8(String(decoding: hex[i...i + 1], as: UTF8.self), radix: 16)!); i += 2 }
    r.body = .bytes(JSBytes(data))
    return r
}

func a(_ xs: [Value], _ i: Int) -> Value { i < xs.count ? xs[i] : .undefined }
let dispatch: [String: ([Value]) throws -> Value] = [
    "accounts": { try accounts(a($0, 0), a($0, 1)) },
    "cloudClient": { try cloudClient(a($0, 0), a($0, 1), a($0, 2)) },
    "conversation": { try conversation(a($0, 0), a($0, 1)) },
    "conversationMatch": { try conversationMatch(a($0, 0), a($0, 1)) },
    "executeMove": { try executeMove(a($0, 0), a($0, 1), a($0, 2), a($0, 3)) },
    "finishHeld": { try finishHeld(a($0, 0), a($0, 1)) },
    "finishPending": { try finishPending(a($0, 0), a($0, 1)) },
    "finishWorkflow": { try finishWorkflow(a($0, 0), a($0, 1)) },
    "idleTimeouts": { try idleTimeouts(a($0, 0), a($0, 1)) },
    "inventory": { try inventory(a($0, 0), a($0, 1), a($0, 2), a($0, 3), a($0, 4)) },
    "leftovers": { try leftovers(a($0, 0), a($0, 1)) },
    "tidy": { try tidy(a($0, 0), a($0, 1).isUndefined ? .null : a($0, 1)) },
    "keepLocal": { try keepLocal(a($0, 0), a($0, 1)) },
    "layout": { try layout(a($0, 0)) },
    "move": { try move(a($0, 0), a($0, 1), a($0, 2), a($0, 3)) },
    "normalize": { try normalize(a($0, 0), a($0, 1)) },
    "parseProcesses": { try parseProcesses(a($0, 0), a($0, 1), a($0, 2), a($0, 3)) },
    "pendingPresentation": { try pendingPresentation(a($0, 0), a($0, 1), a($0, 2), a($0, 3), a($0, 4), a($0, 5), a($0, 6), a($0, 7)) },
    "readReceipt": { try readReceipt(a($0, 0)) },
    "receiptSummary": { try receiptSummary(a($0, 0)) },
    "restartPlan": { try restartPlan(a($0, 0), a($0, 1), a($0, 2)) },
    "semantic": { try semantic(a($0, 0), a($0, 1), a($0, 2)) },
    "signedIn": { try signedIn(a($0, 0), a($0, 1)) },
    "step": { try step(a($0, 0), a($0, 1)) },
    "sweep": { try sweep(a($0, 0), a($0, 1)) },
    "undo": { try undo(a($0, 0), a($0, 1)) },
    "verifyPlaced": { try verifyPlaced(a($0, 0)) },
    "withDesktopRestart": { try withDesktopRestart(a($0, 0), a($0, 1), a($0, 2), a($0, 3), a($0, 4)) },
    "writeNew": { try writeNew(a($0, 0), a($0, 1), a($0, 2)) },
]

guard CommandLine.arguments.dropFirst().first == "serve", let line = reader.next() else {
    FileHandle.standardError.write(Data("usage: handoff-parity serve\n".utf8))
    exit(64)
}
// A test can run one call in Swift and the next in Node, so both engines share Node's cache generation here.
CACHE_VERSION = 13
if let hash = ProcessInfo.processInfo.environment["PARITY_ENGINE_HASH"] { artifactEngineHash = .string(hash) }
if let runtime = ProcessInfo.processInfo.environment["PARITY_NODE_RUNTIME"], let heap = ProcessInfo.processInfo.environment["PARITY_NODE_HEAP"].flatMap(Double.init) {
    budgetRuntime = runtime
    nativeHeapLimit = Value(heap)
}
var args: [Value] = []
do {
    let request = try JSON.parse(line)
    let name = request.name.description
    guard let fn = dispatch[name] else { send(["unsupported": Value("no dispatch for \(name)")]); exit(0) }
    args = codec.decode(request.args).elements
    let result = try fn(args)
    // Arguments go back too, so in-place changes reach the caller's objects as they would in-process.
    do { send(["result": try codec.encode(result), "args": try codec.encode(Value(args))]) } catch {
        send(["unsupported": Value(jsErrorValue(error).message.description)])
    }
} catch {
    let e = jsErrorValue(error)
    var reply: Value = ["error": (try? codec.encode(e)) ?? ["$e": ["message": e.message, "name": "Error", "props": Value.newObject()]]]
    if let encoded = try? codec.encode(Value(args)) { reply["args"] = encoded }
    send(reply)
}
exit(0)
