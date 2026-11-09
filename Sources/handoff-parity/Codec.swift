import Foundation
@testable import HandoffCore

// Wire format shared with Tests/Parity/serialize.mjs.
struct Codec {
    var callFunction: (Int, [Value]) throws -> Value

    func encode(_ root: Value) throws -> Value {
        var counts: [ObjectIdentifier: Int] = [:]
        func ref(_ v: Value) -> ObjectIdentifier? {
            switch v {
            case .array(let a): return ObjectIdentifier(a)
            case .object(let o): return ObjectIdentifier(o)
            case .set(let s): return ObjectIdentifier(s)
            case .map(let m): return ObjectIdentifier(m)
            case .bytes(let b): return ObjectIdentifier(b)
            default: return nil
            }
        }
        func walk(_ v: Value) {
            if case .function(let f) = v, let recipe = f.props?["$recipe"] { walk(recipe) }
            if case .object(let o) = v, o.has("$recipe") { walk(o["$recipe"]); return }
            guard let id = ref(v) else { return }
            counts[id, default: 0] += 1
            if counts[id]! > 1 { return }
            switch v {
            case .array(let a): a.items.forEach(walk); a.props.map { o in o.keys.forEach { walk(o[$0]) } }
            case .object(let o): o.keys.forEach { walk(o[$0]) }
            case .set(let s): s.values.forEach(walk); s.props.map { o in o.keys.forEach { walk(o[$0]) } }
            case .map(let m): m.entries.forEach { walk($0.0); walk($0.1) }; m.props.map { o in o.keys.forEach { walk(o[$0]) } }
            default: break
            }
        }
        walk(root)
        var seen: [ObjectIdentifier: Int] = [:]
        var next = 0
        func props(_ p: JSObject?) throws -> [(String, Value)] {
            guard let p, !p.keys.isEmpty else { return [] }
            return [("$p", .object(JSObject(try p.keys.map { ($0, try enc(p[$0])) })))]
        }
        func enc(_ v: Value) throws -> Value {
            switch v {
            case .undefined: return ["$u": 1]
            case .number(let d): return d.isFinite ? v : ["$n": Value(jsNumberString(d))]
            case .bigint(let i): return ["$b": Value(String(i))]
            case .function(let f):
                if let index = f.props?["$index"].asInt { return ["$f": Value(index)] }
                if let recipe = f.props?["$recipe"], !recipe.isUndefined { return ["$recipe": try enc(recipe)] }
                // A Swift closure has no Node counterpart; Node gets a function that fails loudly if it is called.
                return ["$sfn": 1]
            case .null, .bool, .string: return v
            case .object(let o) where o.has("$recipe"): return ["$recipe": try enc(o["$recipe"])]
            default: break
            }
            let id = ref(v)!
            if let r = seen[id] { return ["$r": Value(r)] }
            let shared = (counts[id] ?? 0) > 1
            var head: [(String, Value)] = []
            if shared { seen[id] = next; head = [("$id", Value(next))]; next += 1 }
            func tag(_ body: [(String, Value)]) -> Value { .object(JSObject(head + body)) }
            switch v {
            case .bytes(let b): return tag([("$x", Value(b.data.map { String(format: "%02x", $0) }.joined()))])
            case .set(let s): return tag([("$s", Value(try s.values.map(enc)))] + (try props(s.props)))
            case .map(let m): return tag([("$m", Value(try m.entries.map { Value([try enc($0.0), try enc($0.1)]) }))] + (try props(m.props)))
            case .array(let a):
                let items = Value(try a.items.map(enc))
                let extra = try props(a.props)
                if let origin = a.props?["$in"], !origin.isUndefined { return tag([("$a", items)] + extra + [("$in", origin)]) }
                return shared || !extra.isEmpty ? tag([("$a", items)] + extra) : items
            case .object(let o):
                if o.has("__error") {
                    let p = JSObject(try o.keys.map { ($0, try enc(o[$0])) })
                    return tag([("$e", ["message": o["message"], "name": o["name"].nullish ? "Error" : o["name"], "props": .object(p)])])
                }
                let body = JSObject(try o.keys.map { ($0, try enc(o[$0])) })
                if o.has("$in") { return tag([("$o", .object(body)), ("$in", o["$in"])]) }
                return shared || o.keys.contains(where: { $0.hasPrefix("$") }) ? tag([("$o", .object(body))]) : .object(body)
            default: return v
            }
        }
        return try enc(root)
    }

    // Engine values that crossed to Node as recipes become real engine values again.
    func rebuild(_ recipe: Value) -> Value {
        switch recipe[0].description {
        case "memory": return (try? operationMemory()) ?? .undefined
        case "inspect":
            let processes = recipe[1], app = recipe[2]
            let fn = Value { _ in try processes ?? processTable(app) }
            fn["$recipe"] = recipe
            return fn
        default: return .undefined
        }
    }

    func decode(_ root: Value) -> Value {
        var refs: [Int: Value] = [:]
        func dec(_ v: Value) -> Value {
            if case .array(let a) = v { return Value(a.items.map(dec)) }
            guard case .object(let o) = v else { return v }
            if o.has("$u") { return .undefined }
            if o.has("$n") { return .number(jsNumber(o["$n"])) }
            if o.has("$b") { return .bigint(Int64(o["$b"].description) ?? 0) }
            if o.has("$f") {
                let index = o["$f"].asInt ?? -1
                let fn = Value { args in try callFunction(index, args) }
                fn["$index"] = Value(index)
                return fn
            }
            if o.has("$r") { return refs[o["$r"].asInt!] ?? .undefined }
            if o.has("$recipe") { return rebuild(dec(o["$recipe"])) }
            let id = o["$id"].asInt
            func keep(_ x: Value) -> Value { if let id { refs[id] = x }; return x }
            func withProps(_ x: Value) -> Value {
                if case .object(let p) = o["$p"] { for k in p.keys { x[k] = dec(p[k]) } }
                return x
            }
            if o.has("$x") {
                let hex = Array(o["$x"].description.utf8)
                var data = Data(capacity: hex.count / 2)
                var i = 0
                while i + 1 < hex.count { data.append(UInt8(String(decoding: hex[i...i + 1], as: UTF8.self), radix: 16)!); i += 2 }
                return keep(.bytes(JSBytes(data)))
            }
            if o.has("$s") { let s = JSSet(); let r = keep(.set(s)); for x in o["$s"].elements { s.add(dec(x)) }; return withProps(r) }
            if o.has("$m") { let m = JSMap(); let r = keep(.map(m)); for p in o["$m"].elements { m.set(dec(p[0]), dec(p[1])) }; return withProps(r) }
            if o.has("$e") {
                let e = o["$e"]
                let err = JSError(e["message"].description, name: e["name"].asString ?? "Error").value
                for (k, p) in e["props"].ownEntries { err[k] = dec(p) }
                return keep(err)
            }
            if o.has("$a") {
                let a = JSArray(); let r = keep(.array(a)); a.items = o["$a"].elements.map(dec)
                if o.has("$in") { let p = a.props ?? JSObject(); p["$in"] = o["$in"]; p.hidden.insert("$in"); a.props = p }
                return withProps(r)
            }
            let body = o.has("$o") ? o["$o"] : v
            let out = JSObject()
            let r = keep(.object(out))
            for (k, x) in body.ownEntries where !(k == "$id" && !o.has("$o")) { out[k] = dec(x) }
            if o.has("$in") { out["$in"] = o["$in"]; out.hidden.insert("$in") }
            return r
        }
        return dec(root)
    }
}
