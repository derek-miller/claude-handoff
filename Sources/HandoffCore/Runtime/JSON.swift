import Foundation

// JSON parsing and serialization byte-compatible with the files Claude Desktop and Claude Code read and write:
// insertion key order, shortest round-trip numbers, and undefined and functions omitted.
public enum JSON {
    public static func parse(_ text: String) throws -> Value {
        var text = text
        return try text.withUTF8 { buf in
            var parser = Parser(buf)
            return try parser.document()
        }
    }

    public static func parse(_ data: Data) throws -> Value {
        // Invalid UTF-8 is replaced with U+FFFD before parsing.
        try parse(String(decoding: data, as: UTF8.self))
    }

    // Returns nil for a value with no JSON form (undefined, a function).
    // `sorted` emits JSON.stringify(sortKeys(value)) without building the sorted copy.
    public static func stringify(_ value: Value, space: Int = 0, sorted: Bool = false) throws -> String? {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        let indent = Swift.String(repeating: " ", count: min(10, max(0, space)))
        guard try write(sorted ? sortedView(value) : value, into: &out, indent: Array(indent.utf8), current: [], key: nil, sorted: sorted) else { return nil }
        return Swift.String(decoding: out, as: UTF8.self)
    }

    // JSON.stringify for values known to be serializable.
    public static func text(_ value: Value, space: Int = 0) -> String {
        (try? stringify(value, space: space) ?? "undefined") ?? "undefined"
    }

    private static func serializable(_ v: Value) -> Bool {
        switch v {
        case .undefined, .function: return false
        default: return true
        }
    }

    private static func toJSON(_ v: Value) -> Value {
        if case .bytes(let b) = v { return ["type": "Buffer", "data": Value(b.data.map { Value(Int($0)) })] }
        if case .object(let o) = v, case .function(let f) = o["toJSON"] { return (try? f.body([])) ?? .undefined }
        return v
    }

    @discardableResult
    // Sorting keys turns sets and maps into empty objects and byte buffers into objects keyed by index.
    private static func sortedView(_ v: Value) -> Value {
        switch v {
        case .set, .map: return .object(ValueObject(v.ownKeys.map { ($0, v[$0]) }))
        case .bytes(let b): return .object(ValueObject(b.data.enumerated().map { (Swift.String($0.offset), .number(Double($0.element))) }))
        default: return v
        }
    }

    private static func write(_ raw: Value, into out: inout [UInt8], indent: [UInt8], current: [UInt8], key: String?, sorted: Bool = false) throws -> Bool {
        let v = sorted ? raw : toJSON(raw)
        switch v {
        case .undefined, .function: return false
        case .null: out.append(contentsOf: Array("null".utf8))
        case .bool(let b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .number(let d): out.append(contentsOf: Array((d.isFinite ? numberString(d) : "null").utf8))
        case .bigint: throw EngineError.type("Do not know how to serialize a BigInt")
        case .string(let s): quote(s, into: &out)
        case .set, .map, .bytes: out.append(contentsOf: Array("{}".utf8))
        case .array(let a):
            if a.items.isEmpty { out.append(contentsOf: [0x5B, 0x5D]); return true }
            let inner = current + indent
            out.append(0x5B)
            for (i, item) in a.items.enumerated() {
                if i > 0 { out.append(0x2C) }
                if !indent.isEmpty { out.append(0x0A); out.append(contentsOf: inner) }
                if !(try write(sorted ? sortedView(item) : item, into: &out, indent: indent, current: inner, key: nil, sorted: sorted)) { out.append(contentsOf: Array("null".utf8)) }
            }
            if !indent.isEmpty { out.append(0x0A); out.append(contentsOf: current) }
            out.append(0x5D)
        case .object(let o):
            let inner = current + indent
            out.append(0x7B)
            var first = true
            // Integer-like keys always come first, in numeric order, even when the rest are sorted.
            for k in sorted ? o.keys.filter { ValueObject.arrayIndex($0) != nil } + o.keys.filter { ValueObject.arrayIndex($0) == nil }.sorted(by: utf16Less) : o.keys {
                let item = sorted ? sortedView(o[k]) : toJSON(o[k])
                guard serializable(item) else { continue }
                if !first { out.append(0x2C) }
                first = false
                if !indent.isEmpty { out.append(0x0A); out.append(contentsOf: inner) }
                quote(k, into: &out)
                out.append(0x3A)
                if !indent.isEmpty { out.append(0x20) }
                try write(item, into: &out, indent: indent, current: inner, key: nil, sorted: sorted)
            }
            if !first && !indent.isEmpty { out.append(0x0A); out.append(contentsOf: current) }
            out.append(0x7D)
        }
        return true
    }

    private static let hex: [UInt8] = Array("0123456789abcdef".utf8)

    static func quote(_ s: String, into out: inout [UInt8]) {
        out.append(0x22)
        var s = s
        s.withUTF8 { bytes in
            var start = 0
            for i in 0..<bytes.count {
                let b = bytes[i]
                guard b < 0x20 || b == 0x22 || b == 0x5C else { continue }
                if start < i { out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[start..<i])) }
                start = i + 1
                switch b {
                case 0x22: out.append(contentsOf: [0x5C, 0x22])
                case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
                case 0x08: out.append(contentsOf: [0x5C, 0x62])
                case 0x0C: out.append(contentsOf: [0x5C, 0x66])
                case 0x0A: out.append(contentsOf: [0x5C, 0x6E])
                case 0x0D: out.append(contentsOf: [0x5C, 0x72])
                case 0x09: out.append(contentsOf: [0x5C, 0x74])
                default: out.append(contentsOf: [0x5C, 0x75, 0x30, 0x30, hex[Int(b >> 4)], hex[Int(b & 15)]])
                }
            }
            if start < bytes.count { out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[start..<bytes.count])) }
        }
        out.append(0x22)
    }

    public static func quote(_ s: String) -> String {
        var out: [UInt8] = []
        quote(s, into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    struct Parser {
        let b: UnsafeBufferPointer<UInt8>
        var p = 0
        init(_ b: UnsafeBufferPointer<UInt8>) { self.b = b }

        func fail(_ what: String? = nil) -> EngineError {
            if p >= b.count { return EngineError("Unexpected end of JSON input", name: "SyntaxError") }
            let ch = Swift.String(decoding: [b[p]], as: UTF8.self)
            return EngineError(what ?? "Unexpected token '\(ch)' in JSON at position \(p)", name: "SyntaxError")
        }

        mutating func ws() { while p < b.count, b[p] == 0x20 || b[p] == 0x0A || b[p] == 0x0D || b[p] == 0x09 { p += 1 } }

        mutating func document() throws -> Value {
            // A UTF-8 BOM is not JSON whitespace, so a document starting with one fails to parse.
            ws()
            let v = try value()
            ws()
            if p != b.count { throw fail() }
            return v
        }

        mutating func value() throws -> Value {
            guard p < b.count else { throw fail() }
            switch b[p] {
            case 0x7B: return try object()
            case 0x5B: return try array()
            case 0x22: return .string(try string())
            case 0x74: try literal("true"); return .bool(true)
            case 0x66: try literal("false"); return .bool(false)
            case 0x6E: try literal("null"); return .null
            case 0x2D, 0x30...0x39: return try number()
            default: throw fail()
            }
        }

        mutating func literal(_ word: StaticString) throws {
            let w = UnsafeBufferPointer(start: word.utf8Start, count: word.utf8CodeUnitCount)
            for c in w { guard p < b.count, b[p] == c else { throw fail() }; p += 1 }
        }

        mutating func object() throws -> Value {
            p += 1
            let o = ValueObject()
            ws()
            if p < b.count, b[p] == 0x7D { p += 1; return .object(o) }
            while true {
                ws()
                guard p < b.count, b[p] == 0x22 else { throw fail() }
                let k = try string()
                ws()
                guard p < b.count, b[p] == 0x3A else { throw fail() }
                p += 1
                ws()
                o[k] = try value()
                ws()
                guard p < b.count else { throw fail() }
                if b[p] == 0x2C { p += 1; continue }
                if b[p] == 0x7D { p += 1; return .object(o) }
                throw fail()
            }
        }

        mutating func array() throws -> Value {
            p += 1
            var items: [Value] = []
            ws()
            if p < b.count, b[p] == 0x5D { p += 1; return .array(ValueArray(items)) }
            while true {
                ws()
                items.append(try value())
                ws()
                guard p < b.count else { throw fail() }
                if b[p] == 0x2C { p += 1; continue }
                if b[p] == 0x5D { p += 1; return .array(ValueArray(items)) }
                throw fail()
            }
        }

        mutating func hex4() throws -> UInt16 {
            guard p + 4 <= b.count else { p = b.count; throw fail() }
            var v: UInt16 = 0
            for _ in 0..<4 {
                let c = b[p]
                let d: UInt16
                switch c {
                case 0x30...0x39: d = UInt16(c - 0x30)
                case 0x61...0x66: d = UInt16(c - 0x61 + 10)
                case 0x41...0x46: d = UInt16(c - 0x41 + 10)
                default: throw fail()
                }
                v = v << 4 | d
                p += 1
            }
            return v
        }

        mutating func string() throws -> String {
            p += 1
            let start = p
            // Fast path: no escapes.
            while p < b.count {
                let c = b[p]
                if c == 0x22 {
                    let s = Swift.String(decoding: UnsafeBufferPointer(rebasing: b[start..<p]), as: UTF8.self)
                    p += 1
                    return s
                }
                if c == 0x5C { break }
                if c < 0x20 { throw fail("Bad control character in string literal in JSON at position \(p)") }
                p += 1
            }
            var bytes = Array(b[start..<p])
            var units: [UInt16] = []
            func flushUnits() {
                if units.isEmpty { return }
                bytes.append(contentsOf: Array(Swift.String(decoding: units, as: UTF16.self).utf8))
                units.removeAll()
            }
            while p < b.count {
                let c = b[p]
                if c == 0x22 { flushUnits(); p += 1; return Swift.String(decoding: bytes, as: UTF8.self) }
                if c < 0x20 { throw fail("Bad control character in string literal in JSON at position \(p)") }
                if c != 0x5C { flushUnits(); bytes.append(c); p += 1; continue }
                p += 1
                guard p < b.count else { throw fail() }
                let e = b[p]
                p += 1
                if e == 0x75 { units.append(try hex4()); continue }
                flushUnits()
                switch e {
                case 0x22: bytes.append(0x22)
                case 0x5C: bytes.append(0x5C)
                case 0x2F: bytes.append(0x2F)
                case 0x62: bytes.append(0x08)
                case 0x66: bytes.append(0x0C)
                case 0x6E: bytes.append(0x0A)
                case 0x72: bytes.append(0x0D)
                case 0x74: bytes.append(0x09)
                default: p -= 1; throw fail("Bad escaped character in JSON at position \(p)")
                }
            }
            throw fail()
        }

        mutating func number() throws -> Value {
            let start = p
            if b[p] == 0x2D { p += 1 }
            guard p < b.count, b[p] >= 0x30, b[p] <= 0x39 else { throw fail() }
            if b[p] == 0x30 { p += 1 } else { while p < b.count, b[p] >= 0x30, b[p] <= 0x39 { p += 1 } }
            if p < b.count, b[p] == 0x2E {
                p += 1
                guard p < b.count, b[p] >= 0x30, b[p] <= 0x39 else { throw fail() }
                while p < b.count, b[p] >= 0x30, b[p] <= 0x39 { p += 1 }
            }
            if p < b.count, b[p] == 0x65 || b[p] == 0x45 {
                p += 1
                if p < b.count, b[p] == 0x2B || b[p] == 0x2D { p += 1 }
                guard p < b.count, b[p] >= 0x30, b[p] <= 0x39 else { throw fail() }
                while p < b.count, b[p] >= 0x30, b[p] <= 0x39 { p += 1 }
            }
            let text = Swift.String(decoding: UnsafeBufferPointer(rebasing: b[start..<p]), as: UTF8.self)
            return .number(Double(text) ?? .nan)
        }
    }
}
