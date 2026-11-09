import CommonCrypto
import CryptoKit
import Foundation

// MARK: - Hashing and canonical JSON

public func sha(_ text: String) -> String { sha(Data(text.utf8)) }
private let hexDigits = Array("0123456789abcdef".utf8)
public func sha(_ data: Data) -> String {
    var out = [UInt8]()
    out.reserveCapacity(64)
    for b in SHA256.hash(data: data) { out.append(hexDigits[Int(b >> 4)]); out.append(hexDigits[Int(b & 15)]) }
    return String(decoding: out, as: UTF8.self)
}
public func sha(_ v: Value) -> String {
    if case .bytes(let b) = v { return sha(b.data) }
    return sha(v.description)
}

// JS default sort order: UTF-16 code units.
public func utf16Less(_ a: String, _ b: String) -> Bool {
    var ia = a.utf16.makeIterator(), ib = b.utf16.makeIterator()
    while true {
        switch (ia.next(), ib.next()) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (x?, y?): if x != y { return x < y }
        }
    }
}

// `a.localeCompare(b)` for the identifiers and titles the engine sorts: ICU root collation.
public func localeCompare(_ a: String, _ b: String) -> Int {
    switch a.compare(b, options: [], range: nil, locale: Locale(identifier: "en-US")) {
    case .orderedAscending: return -1
    case .orderedDescending: return 1
    case .orderedSame: return 0
    }
}

public func sortKeys(_ v: Value) -> Value {
    switch v {
    case .array(let a): return .array(JSArray(a.items.map(sortKeys)))
    case .object, .set, .map, .bytes:
        let keys = v.ownKeys.sorted(by: utf16Less)
        return .object(JSObject(keys.map { ($0, sortKeys(v[$0])) }))
    default: return v
    }
}

public func stable(_ v: Value) -> String { (try? JSON.stringify(v, sorted: true)) ?? "undefined" }
public func jsonText(_ v: Value, _ spacing: Int = 2) -> String { JSON.text(v, space: spacing) + "\n" }
public func short(_ id: String) -> String { jsSlice(id, 0, 8) }
public func short(_ id: Value) -> String { short(id.description) }

// Number.prototype.toLocaleString('en-US')
public func count(_ v: Double) -> String {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "en_US")
    f.numberStyle = .decimal
    f.maximumFractionDigits = 3
    f.roundingMode = .halfEven
    return f.string(from: NSNumber(value: v)) ?? jsNumberString(v)
}
public func count(_ v: Int) -> String { count(Double(v)) }
public func count(_ v: Value) -> String { count(v.asNumber ?? .nan) }
public func quantity(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
    "\(count(value)) \(value == 1 ? singular : plural ?? singular + "s")"
}
public func quantity(_ value: Value, _ singular: String, _ plural: String? = nil) -> String {
    "\(count(value)) \(value.asNumber == 1 ? singular : plural ?? singular + "s")"
}

// MARK: - Strings with JS (UTF-16) indexing

public func jsSlice(_ s: String, _ start: Int, _ end: Int? = nil) -> String {
    let u = Array(s.utf16)
    func clamp(_ i: Int) -> Int { i < 0 ? max(0, u.count + i) : min(i, u.count) }
    let a = clamp(start), b = clamp(end ?? u.count)
    return a < b ? String(decoding: u[a..<b], as: UTF16.self) : ""
}

public func jsArraySlice(_ xs: [Value], _ start: Int, _ end: Int? = nil) -> [Value] {
    func clamp(_ i: Int) -> Int { i < 0 ? max(0, xs.count + i) : min(i, xs.count) }
    let a = clamp(start), b = clamp(end ?? xs.count)
    return a < b ? Array(xs[a..<b]) : []
}

public func padStart(_ s: String, _ n: Int, _ fill: String = " ") -> String {
    let len = s.utf16.count
    return len >= n ? s : String(repeating: fill, count: n - len) + s
}
public func padEnd(_ s: String, _ n: Int, _ fill: String = " ") -> String {
    let len = s.utf16.count
    return len >= n ? s : s + String(repeating: fill, count: n - len)
}

extension String {
    // JS String.prototype.trim whitespace set.
    public var jsTrim: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    public func jsSplit(_ sep: String) -> [String] {
        if sep.isEmpty { return utf16.map { String(utf16CodeUnits: [$0], count: 1) } }
        return components(separatedBy: sep)
    }
}

// MARK: - Regular expressions (JS syntax through ICU)

public final class JSRegExp {
    public let source: String
    public let flags: String
    let re: NSRegularExpression
    private static var cache: [String: JSRegExp] = [:]
    private static let lock = NSLock()

    public init(_ source: String, _ flags: String = "") {
        self.source = source
        self.flags = flags
        var opts: NSRegularExpression.Options = []
        if flags.contains("i") { opts.insert(.caseInsensitive) }
        if flags.contains("m") { opts.insert(.anchorsMatchLines) }
        if flags.contains("s") { opts.insert(.dotMatchesLineSeparators) }
        re = try! NSRegularExpression(pattern: flags.contains("m") ? source : JSRegExp.strictEnd(source), options: opts)
    }

    // ICU's `$` also matches before a final newline; JS's only matches at the very end.
    static func strictEnd(_ source: String) -> String {
        var out = "", escaped = false, inClass = false
        for ch in source {
            if escaped { out.append(ch); escaped = false; continue }
            switch ch {
            case "\\": escaped = true; out.append(ch)
            case "[": inClass = true; out.append(ch)
            case "]": inClass = false; out.append(ch)
            case "$" where !inClass: out += "\\z"
            default: out.append(ch)
            }
        }
        return out
    }

    public static func cached(_ source: String, _ flags: String = "") -> JSRegExp {
        lock.lock(); defer { lock.unlock() }
        let key = flags + "/" + source
        if let r = cache[key] { return r }
        let r = JSRegExp(source, flags)
        cache[key] = r
        return r
    }

    public func test(_ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    // s.match(re) without g: [full, group1, ...] with nil for unmatched groups.
    public func match(_ s: String) -> [String?]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return groups(m, in: s)
    }
    public func matchAll(_ s: String) -> [[String?]] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { groups($0, in: s) }
    }
    // s.match(/…/g): all full matches.
    public func matches(_ s: String) -> [String] { matchAll(s).compactMap { $0[0] } }
    func groups(_ m: NSTextCheckingResult, in s: String) -> [String?] {
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : Range(r, in: s).map { String(s[$0]) }
        }
    }
    // s.replace(re, replacement) honoring the g flag; replacement uses JS `$1` syntax.
    public func replace(_ s: String, _ template: String) -> String {
        let t = template.replacingOccurrences(of: "$&", with: "$0")
        let range = NSRange(s.startIndex..., in: s)
        if flags.contains("g") { return re.stringByReplacingMatches(in: s, range: range, withTemplate: t) }
        guard let m = re.firstMatch(in: s, range: range) else { return s }
        let ns = s as NSString
        return ns.replacingCharacters(in: m.range, with: re.replacementString(for: m, in: s, offset: 0, template: t))
    }
    public func replace(_ s: String, _ fn: ([String?]) -> String) -> String {
        let ns = s as NSString
        let all = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        let ms = flags.contains("g") ? all : Array(all.prefix(1))
        var out = "", last = 0
        for m in ms {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += fn(groups(m, in: s))
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
    public func split(_ s: String) -> [String] {
        let ns = s as NSString
        var out: [String] = [], last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.length == 0 && m.range.location == last && last != 0 { continue }
            out.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        out.append(ns.substring(from: last))
        return out
    }
}

public func re(_ source: String, _ flags: String = "") -> JSRegExp { JSRegExp.cached(source, flags) }

// MARK: - Dates

public func dateNow() -> Double { process.now() }

// new Date(ms).toISOString()
public func isoString(_ ms: Double) -> String {
    let secs = (ms / 1000).rounded(.down)
    let millis = Int(ms - secs * 1000)
    var t = time_t(secs)
    var tm = tm()
    gmtime_r(&t, &tm)
    let year = Int(tm.tm_year) + 1900
    let y = year >= 0 && year <= 9999 ? String(format: "%04d", year) : (year < 0 ? "-" : "+") + String(format: "%06d", abs(year))
    return "\(y)-\(String(format: "%02d-%02dT%02d:%02d:%02d.%03dZ", tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec, millis))"
}
public func isoNow() -> String { isoString(dateNow()) }

// Date.parse for ISO-8601 strings (the forms the engine and Claude write) and `ps` lstart strings; NaN otherwise.
public func dateParse(_ s: String) -> Double {
    if let m = re(#"^([+-]\d{6}|\d{4})(?:-(\d{2})(?:-(\d{2}))?)?(?:T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?(Z|[+-]\d{2}:\d{2})?)?$"#).match(s) {
        let year = Int(m[1]!)!, month = Int(m[2] ?? "1")!, day = Int(m[3] ?? "1")!
        let hour = Int(m[4] ?? "0")!, minute = Int(m[5] ?? "0")!, second = Int(m[6] ?? "0")!
        let frac = m[7].map { Double("0." + $0)! } ?? 0
        guard (1...12).contains(month), (1...31).contains(day), hour <= 24, minute < 60, second < 60 else { return .nan }
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day; comps.hour = hour; comps.minute = minute; comps.second = second
        var cal = Calendar(identifier: .gregorian)
        let dateOnly = m[4] == nil
        var offset = 0
        if let z = m[8], z != "Z" {
            let sign = z.hasPrefix("-") ? -1 : 1
            let parts = z.dropFirst().split(separator: ":")
            offset = sign * (Int(parts[0])! * 3600 + Int(parts[1])! * 60)
        }
        cal.timeZone = (dateOnly || m[8] != nil) ? TimeZone(secondsFromGMT: offset)! : TimeZone.current
        guard let d = cal.date(from: comps) else { return .nan }
        return (d.timeIntervalSince1970 * 1000).rounded() + (frac * 1000).rounded(.down)
    }
    // "Fri Sep  4 18:00:00 2026" (ps lstart, local time)
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    for format in ["EEE MMM d HH:mm:ss yyyy", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE MMM dd yyyy HH:mm:ss 'GMT'Z"] {
        f.dateFormat = format
        // Date#toString appends " (Pacific Standard Time)", which Date.parse ignores.
        let text = re(#"\s*\([^()]*\)$"#).replace(s.replacingOccurrences(of: "  ", with: " ")) { _ in "" }
        if let d = f.date(from: text) { return (d.timeIntervalSince1970 * 1000).rounded() }
    }
    return .nan
}

// stamp(): receipt file names.
public func stamp() -> String { jsSlice(isoNow(), 0, 23).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-") }

// MARK: - Crypto

public func randomUUID() -> String { Foundation.UUID().uuidString.lowercased() }

public func pbkdf2(_ password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
    var out = [UInt8](repeating: 0, count: keyLength)
    password.withUnsafeBytes { pw in
        salt.withUnsafeBytes { s in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                     s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                     UInt32(iterations), &out, keyLength)
        }
    }
    return Data(out)
}

// AES-128-CBC with PKCS#7 padding, like createDecipheriv('aes-128-cbc').
public func aes128cbcDecrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
    var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
    var moved = 0
    let status = data.withUnsafeBytes { d in key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                k.baseAddress, key.count, v.baseAddress, d.baseAddress, data.count, &out, out.count, &moved)
    } } }
    if status != kCCSuccess { throw JSError("bad decrypt", code: "ERR_OSSL_BAD_DECRYPT") }
    return Data(out[0..<moved])
}

// MARK: - Numbers

// Number(v)
public func jsNumber(_ v: Value) -> Double {
    switch v {
    case .undefined: return .nan
    case .null: return 0
    case .bool(let b): return b ? 1 : 0
    case .number(let d): return d
    case .bigint(let i): return Double(i)
    case .string(let s):
        let t = s.jsTrim
        if t.isEmpty { return 0 }
        if t.hasPrefix("0x") || t.hasPrefix("0X") { return UInt64(t.dropFirst(2), radix: 16).map(Double.init) ?? .nan }
        if t == "Infinity" || t == "+Infinity" { return .infinity }
        if t == "-Infinity" { return -.infinity }
        guard t.allSatisfy({ "0123456789+-.eE".contains($0) }) else { return .nan }
        return Double(t) ?? .nan
    case .array(let a): return a.items.isEmpty ? 0 : a.items.count == 1 ? jsNumber(.string(a.items[0].description)) : .nan
    default: return .nan
    }
}

public func isSafeInteger(_ v: Value) -> Bool {
    guard case .number(let d) = v, d.isFinite, d == d.rounded(.towardZero) else { return false }
    return abs(d) <= 9_007_199_254_740_991
}
public func isFiniteNumber(_ v: Value) -> Bool { if case .number(let d) = v { return d.isFinite }; return false }

// MARK: - Arrays

extension Array where Element == Value {
    public var value: Value { .array(JSArray(self)) }
}

extension Array where Element == String {
    public var value: Value { .strings(self) }
}

// [...new Set(xs)]
public func unique(_ xs: [Value]) -> [Value] { JSSet(xs).values }
public func unique(_ xs: [String]) -> [String] {
    var seen = Set<String>()
    return xs.filter { seen.insert($0).inserted }
}

// Array.prototype.sort() with no comparator: by ToString, UTF-16 order, undefined last.
public func defaultSorted(_ xs: [Value]) -> [Value] {
    let defined = xs.filter { !$0.isUndefined }, undef = xs.filter { $0.isUndefined }
    return defined.enumerated().sorted { a, b in
        let x = a.element.description, y = b.element.description
        return x == y ? a.offset < b.offset : utf16Less(x, y)
    }.map(\.element) + undef
}
public func defaultSorted(_ xs: [String]) -> [String] { xs.sorted(by: utf16Less) }

// Stable sort with a JS comparator returning a number.
public func jsSorted(_ xs: [Value], _ compare: (Value, Value) throws -> Double) rethrows -> [Value] {
    try xs.enumerated().sorted { a, b in
        let c = try compare(a.element, b.element)
        return c < 0 || (c == 0 && a.offset < b.offset)
    }.map(\.element)
}
