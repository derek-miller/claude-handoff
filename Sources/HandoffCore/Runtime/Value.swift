import Foundation

// A dynamic value. The engine works on untyped JSON that it mutates in place and writes back byte for byte,
// so objects and arrays are shared references, keys keep insertion order, and undefined is distinct from null.
@dynamicMemberLookup
public enum Value {
    case undefined
    case null
    case bool(Bool)
    case number(Double)
    case bigint(Int64)
    case string(String)
    case array(ValueArray)
    case object(ValueObject)
    case set(ValueSet)
    case map(ValueMap)
    case function(ValueFunction)
    case bytes(ValueBytes)
}

public final class ValueArray {
    public var items: [Value]
    public var props: ValueObject?
    public init(_ items: [Value] = []) { self.items = items }
}

public final class ValueBytes {
    public var data: Data
    public init(_ data: Data) { self.data = data }
}

public final class ValueFunction {
    public let body: ([Value]) throws -> Value
    public var props: ValueObject?
    public init(_ body: @escaping ([Value]) throws -> Value) { self.body = body }
}

// Property order: integer-like keys ascending, then the other keys in insertion order.
public final class ValueObject {
    public private(set) var indexKeys: [String] = []
    public private(set) var stringKeys: [String] = []
    public private(set) var storage: [String: Value] = [:]

    public init() {}
    public init(_ pairs: [(String, Value)]) { for (k, v) in pairs { self[k] = v } }

    // Error objects keep `message` and `name` non-enumerable, so they stay out of JSON and key lists.
    public var hidden: Set<String> = []
    public var keys: [String] {
        let all = indexKeys.isEmpty ? stringKeys : indexKeys + stringKeys
        return hidden.isEmpty ? all : all.filter { !hidden.contains($0) }
    }
    public var count: Int { storage.count }

    static func arrayIndex(_ key: String) -> UInt32? {
        guard let first = key.utf8.first, first >= 48, first <= 57 else { return nil }
        if key.utf8.count > 1 && first == 48 { return nil }
        guard key.utf8.count <= 10, let n = UInt64(key), n < 4_294_967_295 else { return nil }
        return UInt32(n)
    }

    public func has(_ key: String) -> Bool { storage[key] != nil }

    public subscript(key: String) -> Value {
        get { storage[key] ?? .undefined }
        set {
            if storage.updateValue(newValue, forKey: key) == nil {
                if let n = ValueObject.arrayIndex(key) {
                    let pos = indexKeys.firstIndex { ValueObject.arrayIndex($0)! > n } ?? indexKeys.count
                    indexKeys.insert(key, at: pos)
                } else {
                    stringKeys.append(key)
                }
            }
        }
    }

    @discardableResult
    public func remove(_ key: String) -> Value? {
        guard let old = storage.removeValue(forKey: key) else { return nil }
        if let i = stringKeys.firstIndex(of: key) { stringKeys.remove(at: i) } else if let i = indexKeys.firstIndex(of: key) { indexKeys.remove(at: i) }
        return old
    }

    public var entries: [(String, Value)] { keys.map { ($0, storage[$0]!) } }
}

// Set and map key identity: strings and numbers by value (NaN equals NaN, 0 equals -0), objects by reference.
public enum HashKey: Hashable {
    case undefined, null, bool(Bool), number(Double), nan, bigint(Int64), string(String), ref(ObjectIdentifier)
    init(_ v: Value) {
        switch v {
        case .undefined: self = .undefined
        case .null: self = .null
        case .bool(let b): self = .bool(b)
        case .number(let d): self = d.isNaN ? .nan : .number(d == 0 ? 0 : d)
        case .bigint(let i): self = .bigint(i)
        case .string(let s): self = .string(s)
        case .array(let a): self = .ref(ObjectIdentifier(a))
        case .object(let o): self = .ref(ObjectIdentifier(o))
        case .set(let s): self = .ref(ObjectIdentifier(s))
        case .map(let m): self = .ref(ObjectIdentifier(m))
        case .function(let f): self = .ref(ObjectIdentifier(f))
        case .bytes(let b): self = .ref(ObjectIdentifier(b))
        }
    }
}

public final class ValueSet {
    public private(set) var values: [Value] = []
    private var index: [HashKey: Int] = [:]
    public var props: ValueObject?
    public init(_ values: [Value] = []) { for v in values { add(v) } }
    public var size: Int { index.count }
    public func has(_ v: Value) -> Bool { index[HashKey(v)] != nil }
    @discardableResult public func add(_ v: Value) -> ValueSet {
        let k = HashKey(v)
        if index[k] == nil { index[k] = values.count; values.append(v) }
        return self
    }
    @discardableResult public func delete(_ v: Value) -> Bool {
        guard let i = index.removeValue(forKey: HashKey(v)) else { return false }
        values.remove(at: i)
        for (k, j) in index where j > i { index[k] = j - 1 }
        return true
    }
    public func clear() { values = []; index = [:] }
    public func isSubset(of other: ValueSet) -> Bool { size <= other.size && values.allSatisfy { other.has($0) } }
}

public final class ValueMap {
    public private(set) var keys: [Value] = []
    private var storage: [HashKey: Value] = [:]
    public var props: ValueObject?
    public init(_ pairs: [(Value, Value)] = []) { for (k, v) in pairs { set(k, v) } }
    public var size: Int { storage.count }
    public func has(_ k: Value) -> Bool { storage[HashKey(k)] != nil }
    public func get(_ k: Value) -> Value { storage[HashKey(k)] ?? .undefined }
    @discardableResult public func set(_ k: Value, _ v: Value) -> ValueMap {
        let h = HashKey(k)
        if storage.updateValue(v, forKey: h) == nil { keys.append(k) }
        return self
    }
    @discardableResult public func delete(_ k: Value) -> Bool {
        let h = HashKey(k)
        guard storage.removeValue(forKey: h) != nil else { return false }
        keys.removeAll { HashKey($0) == h }
        return true
    }
    public var entries: [(Value, Value)] { keys.map { ($0, storage[HashKey($0)]!) } }
    public var values: [Value] { keys.map { storage[HashKey($0)]! } }
}

// MARK: - Construction

extension Value: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral,
    ExpressibleByStringInterpolation
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: Value...) { self = .array(ValueArray(elements)) }
    public init(dictionaryLiteral elements: (String, Value)...) { self = .object(ValueObject(elements)) }
    public init(nilLiteral: ()) { self = .null }

    public init(_ s: String) { self = .string(s) }
    public init(_ s: String?) { self = s.map { .string($0) } ?? .null }
    public init(_ n: Int) { self = .number(Double(n)) }
    public init(_ n: Double) { self = .number(n) }
    public init(_ b: Bool) { self = .bool(b) }
    public init(_ items: [Value]) { self = .array(ValueArray(items)) }
    public init(_ pairs: [(String, Value)]) { self = .object(ValueObject(pairs)) }
    public init(_ fn: @escaping ([Value]) throws -> Value) { self = .function(ValueFunction(fn)) }
    public init(_ data: Data) { self = .bytes(ValueBytes(data)) }
    public static func strings(_ xs: [String]) -> Value { .array(ValueArray(xs.map { .string($0) })) }
    public static func newSet(_ xs: [Value] = []) -> Value { .set(ValueSet(xs)) }
    public static func newMap(_ xs: [(Value, Value)] = []) -> Value { .map(ValueMap(xs)) }
    public static func newObject() -> Value { .object(ValueObject()) }
    public static func newArray() -> Value { .array(ValueArray()) }
}

// MARK: - Inspection

extension Value {
    public var truthy: Bool {
        switch self {
        case .undefined, .null: return false
        case .bool(let b): return b
        case .number(let d): return !(d == 0 || d.isNaN)
        case .bigint(let i): return i != 0
        case .string(let s): return !s.isEmpty
        default: return true
        }
    }
    public var nullish: Bool { if case .undefined = self { return true }; if case .null = self { return true }; return false }
    public var isUndefined: Bool { if case .undefined = self { return true }; return false }
    public var isNull: Bool { if case .null = self { return true }; return false }
    public var isArray: Bool { if case .array = self { return true }; return false }
    public var isString: Bool { if case .string = self { return true }; return false }
    public var isNumber: Bool { if case .number = self { return true }; return false }
    public var isFunction: Bool { if case .function = self { return true }; return false }
    // An object, array, set, map or byte buffer.
    public var isObjectLike: Bool {
        switch self {
        case .array, .object, .set, .map, .bytes: return true
        default: return false
        }
    }
    // A plain, non-array object.
    public var isPlainObject: Bool { if case .object = self { return true }; return false }

    public var typeOf: String {
        switch self {
        case .undefined: return "undefined"
        case .null: return "object"
        case .bool: return "boolean"
        case .number: return "number"
        case .bigint: return "bigint"
        case .string: return "string"
        case .function: return "function"
        default: return "object"
        }
    }

    public var asString: String? { if case .string(let s) = self { return s }; return nil }
    public var asNumber: Double? { if case .number(let d) = self { return d }; return nil }
    public var asInt: Int? { if case .number(let d) = self, d.isFinite, d == d.rounded(), abs(d) < 9.3e18 { return Int(d) }; return nil }
    public var asBool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var asArray: ValueArray? { if case .array(let a) = self { return a }; return nil }
    public var asObject: ValueObject? { if case .object(let o) = self { return o }; return nil }
    public var asSet: ValueSet? { if case .set(let s) = self { return s }; return nil }
    public var asMap: ValueMap? { if case .map(let m) = self { return m }; return nil }
    public var asFunction: ValueFunction? { if case .function(let f) = self { return f }; return nil }
    public var asData: Data? { if case .bytes(let b) = self { return b.data }; return nil }

    // Elements of an array, the values of a Set, or [] for anything else. Use for `for … of` and array transforms.
    public var elements: [Value] {
        switch self {
        case .array(let a): return a.items
        case .set(let s): return s.values
        case .map(let m): return m.entries.map { .array(ValueArray([$0.0, $0.1])) }
        default: return []
        }
    }
    // Enumerable string keys, in order.
    public var ownKeys: [String] {
        switch self {
        case .object(let o): return o.keys
        case .array(let a): return a.items.indices.map(String.init) + (a.props?.keys ?? [])
        case .string(let s): return Array(s.utf16).indices.map(String.init)
        default: return props?.keys ?? []
        }
    }
    public var ownEntries: [(String, Value)] { ownKeys.map { ($0, self[$0]) } }
    public func hasOwn(_ key: String) -> Bool {
        switch self {
        case .object(let o): return o.has(key)
        case .array(let a): if let i = Int(key), i >= 0, i < a.items.count { return true }; return a.props?.has(key) ?? false
        default: return props?.has(key) ?? false
        }
    }

    var props: ValueObject? {
        switch self {
        case .array(let a): return a.props
        case .set(let s): return s.props
        case .map(let m): return m.props
        case .function(let f): return f.props
        default: return nil
        }
    }

    private func ensureProps() -> ValueObject? {
        switch self {
        case .array(let a): if a.props == nil { a.props = ValueObject() }; return a.props
        case .set(let s): if s.props == nil { s.props = ValueObject() }; return s.props
        case .map(let m): if m.props == nil { m.props = ValueObject() }; return m.props
        case .function(let f): if f.props == nil { f.props = ValueObject() }; return f.props
        default: return nil
        }
    }

    // MARK: Property access (missing keys and non-objects yield undefined).

    public subscript(key: String) -> Value {
        get {
            switch self {
            case .object(let o): return o[key]
            case .array(let a):
                if key == "length" { return .number(Double(a.items.count)) }
                if let i = Int(key), i >= 0, String(i) == key { return i < a.items.count ? a.items[i] : .undefined }
                return a.props?[key] ?? .undefined
            case .string(let s):
                if key == "length" { return .number(Double(s.utf16.count)) }
                return .undefined
            case .set(let s): return key == "size" ? .number(Double(s.size)) : s.props?[key] ?? .undefined
            case .map(let m): return key == "size" ? .number(Double(m.size)) : m.props?[key] ?? .undefined
            case .bytes(let b): return key == "length" || key == "byteLength" ? .number(Double(b.data.count)) : .undefined
            case .function(let f): return f.props?[key] ?? .undefined
            default: return .undefined
            }
        }
        nonmutating set {
            switch self {
            case .object(let o): o[key] = newValue
            case .array(let a):
                if let i = Int(key), i >= 0, String(i) == key {
                    while a.items.count <= i { a.items.append(.undefined) }
                    a.items[i] = newValue
                } else if key == "length", let n = newValue.asInt {
                    if n < a.items.count { a.items.removeLast(a.items.count - n) } else { while a.items.count < n { a.items.append(.undefined) } }
                } else { ensureProps()?[key] = newValue }
            default: ensureProps()?[key] = newValue
            }
        }
    }

    public subscript(index: Int) -> Value {
        get {
            switch self {
            case .array(let a): return index >= 0 && index < a.items.count ? a.items[index] : .undefined
            case .string(let s):
                let u = Array(s.utf16)
                return index >= 0 && index < u.count ? .string(String(utf16CodeUnits: [u[index]], count: 1)) : .undefined
            case .bytes(let b): return index >= 0 && index < b.data.count ? .number(Double(b.data[b.data.startIndex + index])) : .undefined
            default: return self[String(index)]
            }
        }
        nonmutating set { self[String(index)] = newValue }
    }

    public subscript(key: Value) -> Value {
        get { if case .number(let d) = key, let i = Int(exactly: d) { return self[i] }; return self[key.description] }
        nonmutating set { self[key.description] = newValue }
    }

    public subscript(dynamicMember key: String) -> Value {
        get { self[key] }
        nonmutating set { self[key] = newValue }
    }

    // delete obj[key]
    public func removeKey(_ key: String) {
        switch self {
        case .object(let o): o.remove(key)
        default: props?.remove(key)
        }
    }

    public var length: Int {
        switch self {
        case .array(let a): return a.items.count
        case .string(let s): return s.utf16.count
        case .bytes(let b): return b.data.count
        case .set(let s): return s.size
        case .map(let m): return m.size
        default: return self["length"].asInt ?? 0
        }
    }

    @discardableResult
    public func call(_ args: Value...) throws -> Value { try callArgs(args) }
    @discardableResult
    public func callArgs(_ args: [Value]) throws -> Value {
        guard case .function(let f) = self else { throw EngineError.type("\(self.typeOf) is not a function") }
        return try f.body(args)
    }
}

// MARK: - Equality and operators

extension Value {
    public static func === (a: Value, b: Value) -> Bool {
        switch (a, b) {
        case (.undefined, .undefined), (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.bigint(let x), .bigint(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)): return x === y
        case (.object(let x), .object(let y)): return x === y
        case (.set(let x), .set(let y)): return x === y
        case (.map(let x), .map(let y)): return x === y
        case (.function(let x), .function(let y)): return x === y
        case (.bytes(let x), .bytes(let y)): return x === y
        default: return false
        }
    }
    public static func !== (a: Value, b: Value) -> Bool { !(a === b) }
    // Loose `==` against null/undefined only.
    public var looseNull: Bool { nullish }
}

extension Value: Equatable {
    // `==` is strict equality (no type coercion; objects compare by identity), so `Value` works with contains/firstIndex.
    public static func == (a: Value, b: Value) -> Bool { a === b }
}

infix operator ??= : AssignmentPrecedence

// `??` falls back only for null and undefined.
public func ?? (lhs: Value, rhs: @autoclosure () throws -> Value) rethrows -> Value {
    lhs.nullish ? try rhs() : lhs
}
// `obj.key ??= b` assigns only when the property is null or undefined.
public func ??= (lhs: inout Value, rhs: @autoclosure () throws -> Value) rethrows {
    if lhs.nullish { lhs = try rhs() }
}
// `||` and `&&` on truthiness, returning an operand rather than a Bool.
public func or(_ a: Value, _ b: @autoclosure () throws -> Value) rethrows -> Value { a.truthy ? a : try b() }
public func and(_ a: Value, _ b: @autoclosure () throws -> Value) rethrows -> Value { a.truthy ? try b() : a }

// MARK: - Object helpers

extension Value {
    // Merges objects: later sources override earlier ones, and each key keeps its first position.
    public static func spread(_ sources: Value...) -> Value { spread(sources) }
    public static func spread(_ sources: [Value]) -> Value {
        let o = ValueObject()
        for s in sources {
            switch s {
            case .object(let src): for k in src.keys { o[k] = src[k] }
            case .array(let a): for (i, v) in a.items.enumerated() { o[String(i)] = v }; if let p = a.props { for k in p.keys { o[k] = p[k] } }
            case .string(let str): for (i, u) in str.utf16.enumerated() { o[String(i)] = .string(String(utf16CodeUnits: [u], count: 1)) }
            default: if let p = s.props { for k in p.keys { o[k] = p[k] } }
            }
        }
        return .object(o)
    }
    // Copies every source's keys onto target and returns target.
    @discardableResult
    public static func assign(_ target: Value, _ sources: Value...) -> Value {
        for s in sources { for (k, v) in s.ownEntries { target[k] = v } }
        return target
    }
    // An object built from [key, value] pairs.
    public static func fromEntries(_ pairs: [(String, Value)]) -> Value { .object(ValueObject(pairs)) }
    public static func fromEntries(_ pairs: Value) -> Value {
        .object(ValueObject(pairs.elements.map { ($0[0].description, $0[1]) }))
    }
    // The [key, value] pairs, in order.
    public var entriesArray: Value { Value(ownEntries.map { Value([.string($0.0), $0.1]) }) }
    public var keysArray: Value { .strings(ownKeys) }
    public var valuesArray: Value { Value(ownEntries.map { $0.1 }) }

    // A deep copy that keeps shared references shared and cycles intact, and copies sets, maps and byte buffers.
    public func deepClone() -> Value {
        if !hasSharedReferences() { return treeClone() }
        var seen: [ObjectIdentifier: Value] = [:]
        func clone(_ v: Value) -> Value {
            switch v {
            case .array(let a):
                if let c = seen[ObjectIdentifier(a)] { return c }
                let n = ValueArray(); let r = Value.array(n); seen[ObjectIdentifier(a)] = r
                n.items = a.items.map(clone); return r
            case .object(let o):
                if let c = seen[ObjectIdentifier(o)] { return c }
                let n = ValueObject(); let r = Value.object(n); seen[ObjectIdentifier(o)] = r
                for k in o.keys { n[k] = clone(o[k]) }; return r
            case .set(let s):
                if let c = seen[ObjectIdentifier(s)] { return c }
                let n = ValueSet(); let r = Value.set(n); seen[ObjectIdentifier(s)] = r
                for x in s.values { n.add(clone(x)) }; return r
            case .map(let m):
                if let c = seen[ObjectIdentifier(m)] { return c }
                let n = ValueMap(); let r = Value.map(n); seen[ObjectIdentifier(m)] = r
                for (k, x) in m.entries { n.set(clone(k), clone(x)) }; return r
            case .bytes(let b): return .bytes(ValueBytes(b.data))
            default: return v
            }
        }
        return clone(self)
    }

    // Plain recursive copy for trees (the common case: values parsed from JSON).
    private func treeClone() -> Value {
        switch self {
        case .array(let a): return .array(ValueArray(a.items.map { $0.treeClone() }))
        case .object(let o):
            let n = ValueObject()
            for k in o.keys { n[k] = o[k].treeClone() }
            return .object(n)
        case .set(let s): return .set(ValueSet(s.values.map { $0.treeClone() }))
        case .map(let m): return .map(ValueMap(m.entries.map { ($0.0.treeClone(), $0.1.treeClone()) }))
        case .bytes(let b): return .bytes(ValueBytes(b.data))
        default: return self
        }
    }

    private func hasSharedReferences() -> Bool {
        var seen = Set<ObjectIdentifier>()
        func walk(_ v: Value) -> Bool {
            let id: ObjectIdentifier
            switch v {
            case .array(let a): id = ObjectIdentifier(a)
            case .object(let o): id = ObjectIdentifier(o)
            case .set(let s): id = ObjectIdentifier(s)
            case .map(let m): id = ObjectIdentifier(m)
            default: return false
            }
            if !seen.insert(id).inserted { return true }
            switch v {
            case .array(let a): return a.items.contains(where: walk)
            case .object(let o): return o.keys.contains { walk(o[$0]) }
            case .set(let s): return s.values.contains(where: walk)
            case .map(let m): return m.entries.contains { walk($0.0) || walk($0.1) }
            default: return false
            }
        }
        return walk(self)
    }
}

// MARK: - String conversion

extension Value: CustomStringConvertible {
    public var description: String {
        switch self {
        case .undefined: return "undefined"
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let d): return numberString(d)
        case .bigint(let i): return String(i)
        case .string(let s): return s
        case .array(let a): return a.items.map { $0.nullish ? "" : $0.description }.joined(separator: ",")
        case .object(let o):
            // Error-shaped objects print like `Error: message`.
            if case .string(let m) = o["message"], o.has("__error") { return "\(o["name"].asString ?? "Error"): \(m)" }
            return "[object Object]"
        case .set: return "[object Set]"
        case .map: return "[object Map]"
        case .function: return "function () { [native code] }"
        case .bytes(let b): return String(decoding: b.data, as: UTF8.self)
        }
    }
}

// The shortest decimal form that round-trips, in exponent notation below 1e-6 and from 1e21 up.
public func numberString(_ d: Double) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
    if d == 0 { return "0" }
    let negative = d < 0
    // Swift's description gives the shortest round-trip digits; this applies the exponent thresholds.
    var s = "\(abs(d))"
    var exponent = 0
    if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        exponent = Int(s[s.index(after: e)...])!
        s = String(s[..<e])
    }
    var digits: String
    var pointPos: Int
    if let dot = s.firstIndex(of: ".") {
        let intPart = String(s[..<dot]), frac = String(s[s.index(after: dot)...])
        digits = intPart + frac
        pointPos = intPart.count
    } else {
        digits = s
        pointPos = s.count
    }
    // strip leading zeros
    while digits.count > 1 && digits.hasPrefix("0") { digits.removeFirst(); pointPos -= 1 }
    while digits.count > 1 && digits.hasSuffix("0") { digits.removeLast() }
    if digits == "0" { return "0" }
    let k = digits.count
    let n = pointPos + exponent  // decimal point position relative to digits
    var out: String
    if k <= n && n <= 21 {
        out = digits + String(repeating: "0", count: n - k)
    } else if 0 < n && n <= 21 {
        let i = digits.index(digits.startIndex, offsetBy: n)
        out = digits[..<i] + "." + digits[i...]
    } else if -6 < n && n <= 0 {
        out = "0." + String(repeating: "0", count: -n) + digits
    } else {
        let e = n - 1
        let sign = e < 0 ? "-" : "+"
        if k == 1 { out = digits + "e" + sign + String(abs(e)) } else {
            let i = digits.index(after: digits.startIndex)
            out = digits[..<i] + "." + digits[i...] + "e" + sign + String(abs(e))
        }
    }
    return negative ? "-" + out : out
}

// MARK: - Errors

// A thrown engine value. Error objects are plain objects carrying `message`, `name`, an optional `code` and a `__error` marker.
public struct EngineError: Error, CustomStringConvertible {
    public let value: Value
    public init(_ value: Value) { self.value = value }
    public init(_ message: String, code: Value = .undefined, name: String = "Error", extra: [(String, Value)] = []) {
        let o = ValueObject()
        o["message"] = .string(message)
        o["name"] = .string(name)
        if !code.isUndefined { o["code"] = code }
        for (k, v) in extra { o[k] = v }
        o["__error"] = .bool(true)
        o.hidden = ["message", "name", "__error", "stack"]
        value = .object(o)
    }
    public static func type(_ message: String) -> EngineError { EngineError(message, name: "TypeError") }
    public static func range(_ message: String) -> EngineError { EngineError(message, name: "RangeError") }

    public var message: String { value["message"].asString ?? value.description }
    public var code: Value { value["code"] }
    public var description: String { value.description }
}

// Normalizes any Swift error into the error object the engine inspects (`error.code`, `error.message`).
public func errorObject(_ error: Error) -> Value {
    if let e = error as? EngineError { return e.value }
    return EngineError("\(error)").value
}

// An error with a message, an optional code and any extra properties.
public func makeError(_ message: String, code: String? = nil, _ extra: [(String, Value)] = []) -> EngineError {
    EngineError(message, code: code.map { .string($0) } ?? .undefined, extra: extra)
}

extension Value {
    // Error objects created by the runtime carry a hidden marker that must not be serialized.
    var isErrorObject: Bool { asObject?.has("__error") ?? false }
}

// MARK: - Collection conveniences (Set, Map, Array)

extension Value {
    public func has(_ v: Value) -> Bool {
        switch self {
        case .set(let s): return s.has(v)
        case .map(let m): return m.has(v)
        default: return false
        }
    }
    public func has(_ s: String) -> Bool { has(.string(s)) }
    @discardableResult public func add(_ v: Value) -> Value { asSet?.add(v); return self }
    public func get(_ k: Value) -> Value { asMap?.get(k) ?? .undefined }
    public func get(_ k: String) -> Value { get(.string(k)) }
    @discardableResult public func put(_ k: Value, _ v: Value) -> Value { asMap?.set(k, v); return self }
    @discardableResult public func delete(_ k: Value) -> Bool {
        switch self {
        case .set(let s): return s.delete(k)
        case .map(let m): return m.delete(k)
        default: return false
        }
    }
    public func push(_ vs: Value...) { asArray?.items.append(contentsOf: vs) }
    // Array membership (NaN matches NaN) or substring test (the empty string is always contained).
    public func includes(_ v: Value) -> Bool {
        switch self {
        case .array(let a): return a.items.contains { $0 === v || ($0.asNumber?.isNaN == true && v.asNumber?.isNaN == true) }
        case .string(let s): return v.asString.map { $0.isEmpty || s.contains($0) } ?? false
        default: return false
        }
    }
    // Joins elements' string forms; null and undefined join as empty strings.
    public func join(_ sep: String = ",") -> String { elements.map { $0.nullish ? "" : $0.description }.joined(separator: sep) }
}
