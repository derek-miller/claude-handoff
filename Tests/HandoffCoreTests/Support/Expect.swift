import Foundation
import Testing
@testable import HandoffCore

// Strict assertions on values (no type coercion), recorded as Swift Testing issues at the caller's line.

// assert.equal: Object.is for primitives, identity for objects.
func eq(_ actual: Value, _ expected: Value, _ message: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    if !sameValue(actual, expected) {
        Issue.record("\(message.map { "\($0): " } ?? "")expected \(show(expected)), got \(show(actual))", sourceLocation: sourceLocation)
    }
}

func eq<T: Equatable>(_ actual: T, _ expected: T, _ message: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    if actual != expected {
        Issue.record("\(message.map { "\($0): " } ?? "")expected \(expected), got \(actual)", sourceLocation: sourceLocation)
    }
}

func ne(_ actual: Value, _ unexpected: Value, _ message: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    if sameValue(actual, unexpected) {
        Issue.record("\(message.map { "\($0): " } ?? "")expected anything but \(show(unexpected))", sourceLocation: sourceLocation)
    }
}

// assert.deepEqual (strict).
func deq(_ actual: Value, _ expected: Value, _ message: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    if !deepEqual(actual, expected) {
        Issue.record("\(message.map { "\($0): " } ?? "")expected \(show(expected)), got \(show(actual))", sourceLocation: sourceLocation)
    }
}

func notDeq(_ actual: Value, _ expected: Value, _ message: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    if deepEqual(actual, expected) {
        Issue.record("\(message.map { "\($0): " } ?? "")expected a value other than \(show(expected))", sourceLocation: sourceLocation)
    }
}

// assert.ok
func ok(_ value: Value, _ message: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    if !value.truthy { Issue.record("\(message.map { "\($0): " } ?? "")expected a truthy value, got \(show(value))", sourceLocation: sourceLocation) }
}

func ok(_ value: Bool, _ message: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    if !value { Issue.record(Comment(rawValue: message ?? "expected true"), sourceLocation: sourceLocation) }
}

// Whether a string matches a TextPattern regular expression.
func match(_ value: Value, _ pattern: String, _ flags: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    guard let text = value.asString else { Issue.record("expected a string matching /\(pattern)/, got \(show(value))", sourceLocation: sourceLocation); return }
    if !TextPattern.cached(pattern, flags).test(text) { Issue.record("expected /\(pattern)/\(flags) to match \(show(value))", sourceLocation: sourceLocation) }
}

func noMatch(_ value: Value, _ pattern: String, _ flags: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    guard let text = value.asString else { Issue.record("expected a string, got \(show(value))", sourceLocation: sourceLocation); return }
    if TextPattern.cached(pattern, flags).test(text) { Issue.record("expected /\(pattern)/\(flags) not to match \(show(value))", sourceLocation: sourceLocation) }
}

func match(_ value: String, _ pattern: String, _ flags: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    match(Value(value), pattern, flags, sourceLocation: sourceLocation)
}

func noMatch(_ value: String, _ pattern: String, _ flags: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    noMatch(Value(value), pattern, flags, sourceLocation: sourceLocation)
}

// Expects body to throw, optionally with a message matching pattern; returns the thrown error object.
@discardableResult
func throwsError(_ pattern: String? = nil, _ flags: String = "", sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Any) -> Value {
    do {
        _ = try body()
    } catch {
        let value = errorObject(error)
        if let pattern, !TextPattern.cached(pattern, flags).test(value["message"].description) && !TextPattern.cached(pattern, flags).test(value.description) {
            Issue.record("expected an error matching /\(pattern)/, got \(value["message"])", sourceLocation: sourceLocation)
        }
        return value
    }
    Issue.record("expected an error\(pattern.map { " matching /\($0)/" } ?? "")", sourceLocation: sourceLocation)
    return .undefined
}

// assert.throws(fn, { code, ... }): every listed property must equal the thrown error's.
@discardableResult
func throwsError(where properties: Value, sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Any) -> Value {
    let value = throwsError(nil as String?, sourceLocation: sourceLocation, body)
    if value.isUndefined { return value }
    for (key, expected) in properties.ownEntries {
        let actual = value[key]
        if let pattern = expected.asObject?["$regex"].asString {
            if !TextPattern.cached(pattern).test(actual.description) { Issue.record("error \(key) \(show(actual)) does not match /\(pattern)/", sourceLocation: sourceLocation) }
        } else if !deepEqual(actual, expected) {
            Issue.record("error \(key): expected \(show(expected)), got \(show(actual))", sourceLocation: sourceLocation)
        }
    }
    return value
}

// A regular expression as an expected error property in throwsError(where:).
func regex(_ pattern: String) -> Value { ["$regex": Value(pattern)] }

func show(_ value: Value) -> String {
    switch value {
    case .undefined: return "undefined"
    case .string(let s): return JSON.quote(s)
    case .function: return "[Function]"
    case .set(let s): return "Set(\(JSON.text(Value(s.values))))"
    case .map(let m): return "Map(\(JSON.text(Value(m.entries.map { Value([$0.0, $0.1]) }))))"
    case .bytes(let b): return "<Buffer \(b.data.count) bytes>"
    default: return JSON.text(value)
    }
}

func sameValue(_ a: Value, _ b: Value) -> Bool {
    if case .number(let x) = a, case .number(let y) = b {
        if x.isNaN && y.isNaN { return true }
        return x == y && x.sign == y.sign
    }
    return a === b
}

// assert.deepStrictEqual: own enumerable keys in any order, undefined-valued keys count, Sets and Maps by content.
func deepEqual(_ a: Value, _ b: Value) -> Bool {
    switch (a, b) {
    case (.array(let x), .array(let y)):
        return x.items.count == y.items.count && zip(x.items, y.items).allSatisfy(deepEqual)
    case (.object(let x), .object(let y)):
        return x.count == y.count && x.entries.allSatisfy { key, value in y.has(key) && deepEqual(value, y[key]) }
    case (.set(let x), .set(let y)):
        return x.size == y.size && x.values.allSatisfy { v in y.has(v) || y.values.contains { deepEqual(v, $0) } }
    case (.map(let x), .map(let y)):
        return x.size == y.size && x.entries.allSatisfy { k, v in y.has(k) && deepEqual(v, y.get(k)) }
    case (.bytes(let x), .bytes(let y)):
        return x.data == y.data
    default:
        return sameValue(a, b)
    }
}

// Array.prototype helpers over Value.
extension Value {
    func find(_ predicate: (Value) throws -> Bool) rethrows -> Value { try elements.first(where: predicate) ?? .undefined }
    func findIndex(_ predicate: (Value) throws -> Bool) rethrows -> Int { try elements.firstIndex(where: predicate) ?? -1 }
    func filter(_ predicate: (Value) throws -> Bool) rethrows -> Value { Value(try elements.filter(predicate)) }
    func map(_ transform: (Value) throws -> Value) rethrows -> Value { Value(try elements.map(transform)) }
    func flatMap(_ transform: (Value) throws -> Value) rethrows -> Value { Value(try elements.flatMap { try transform($0).elements }) }
    func some(_ predicate: (Value) throws -> Bool) rethrows -> Bool { try elements.contains(where: predicate) }
    func every(_ predicate: (Value) throws -> Bool) rethrows -> Bool { try elements.allSatisfy(predicate) }
    func at(_ index: Int) -> Value { let xs = elements; let i = index < 0 ? xs.count + index : index; return i >= 0 && i < xs.count ? xs[i] : .undefined }
    func slice(_ start: Int, _ end: Int? = nil) -> Value { Value(sliceArray(elements, start, end)) }
    func sorted() -> Value { Value(defaultSorted(elements)) }
    func concat(_ other: Value) -> Value { Value(elements + other.elements) }
    var str: String { asString ?? description }
}

// A function value from a Swift closure.
func fn(_ body: @escaping ([Value]) throws -> Value) -> Value { Value(body) }
func fn(_ body: @escaping () throws -> Void) -> Value { Value { _ in try body(); return .undefined } }
let NOOP: Value = fn { () in }
