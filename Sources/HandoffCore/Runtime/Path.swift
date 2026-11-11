import Foundation

// POSIX path joining, normalization and splitting.
public enum path {
    public static let sep = "/"

    public static func normalize(_ p: String) -> String {
        if p.isEmpty { return "." }
        let absolute = p.hasPrefix("/")
        let trailing = p.hasSuffix("/")
        var out: [Substring] = []
        for part in p.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if let last = out.last, last != ".." { out.removeLast() } else if !absolute { out.append("..") }
                continue
            }
            out.append(part)
        }
        var s = out.joined(separator: "/")
        if s.isEmpty && !absolute { s = "." }
        if !s.isEmpty && trailing && s != "." || (s == "." && trailing && false) { s += "/" }
        return absolute ? "/" + s : s
    }

    public static func join(_ parts: String...) -> String { join(parts) }
    public static func join(_ parts: [String]) -> String {
        let joined = parts.filter { !$0.isEmpty }.joined(separator: "/")
        return joined.isEmpty ? "." : normalize(joined)
    }

    public static func resolve(_ parts: String...) -> String { resolve(parts) }
    public static func resolve(_ parts: [String]) -> String {
        var resolved = ""
        for part in parts.reversed() where !part.isEmpty {
            resolved = resolved.isEmpty ? part : part + "/" + resolved
            if part.hasPrefix("/") { break }
        }
        if !resolved.hasPrefix("/") { resolved = FileManager.default.currentDirectoryPath + (resolved.isEmpty ? "" : "/" + resolved) }
        var n = normalize(resolved)
        while n.count > 1 && n.hasSuffix("/") { n.removeLast() }
        return n
    }

    public static func isAbsolute(_ p: String) -> Bool { p.hasPrefix("/") }

    public static func dirname(_ p: String) -> String {
        if p.isEmpty { return "." }
        var s = Substring(p)
        while s.count > 1 && s.hasSuffix("/") { s = s.dropLast() }
        guard let i = s.lastIndex(of: "/") else { return "." }
        if i == s.startIndex { return "/" }
        var d = s[..<i]
        while d.count > 1 && d.hasSuffix("/") { d = d.dropLast() }
        return String(d)
    }

    public static func basename(_ p: String, _ ext: String? = nil) -> String {
        var s = Substring(p)
        while s.count > 1 && s.hasSuffix("/") { s = s.dropLast() }
        if s == "/" { return "" }
        var b = String(s[(s.lastIndex(of: "/").map { s.index(after: $0) } ?? s.startIndex)...])
        if let ext, !ext.isEmpty, b.hasSuffix(ext), b != ext { b.removeLast(ext.count) }
        return b
    }

    public static func extname(_ p: String) -> String {
        let b = basename(p)
        guard let i = b.lastIndex(of: "."), i != b.startIndex else { return "" }
        return String(b[i...])
    }

    public static func relative(_ from: String, _ to: String) -> String {
        let a = resolve(from), b = resolve(to)
        if a == b { return "" }
        let fa = a.split(separator: "/"), fb = b.split(separator: "/")
        var i = 0
        while i < fa.count && i < fb.count && fa[i] == fb[i] { i += 1 }
        let up = Array(repeating: "..", count: fa.count - i)
        return (up + fb[i...].map(String.init)).joined(separator: "/")
    }
}
