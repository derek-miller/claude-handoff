import Darwin
import Foundation

// Filesystem errors carry the errno name as `code` and a message of the form `ENOENT: no such file or directory, open '<path>'`.
public func fsError(_ err: Int32, _ syscall: String, _ path: String? = nil, _ dest: String? = nil) -> EngineError {
    let (code, text) = errnoName(err)
    var message = "\(code): \(text), \(syscall)"
    if let path { message += " '\(path)'" }
    if let dest { message += " -> '\(dest)'" }
    var extra: [(String, Value)] = [("errno", Value(-Int(err))), ("syscall", Value(syscall))]
    if let path { extra.append(("path", Value(path))) }
    if let dest { extra.append(("dest", Value(dest))) }
    return EngineError(message, code: Value(code), extra: extra)
}

func errnoName(_ err: Int32) -> (String, String) {
    switch err {
    case ENOENT: return ("ENOENT", "no such file or directory")
    case EEXIST: return ("EEXIST", "file already exists")
    case ENOTDIR: return ("ENOTDIR", "not a directory")
    case EISDIR: return ("EISDIR", "illegal operation on a directory")
    case EACCES: return ("EACCES", "permission denied")
    case EPERM: return ("EPERM", "operation not permitted")
    case ENOTEMPTY: return ("ENOTEMPTY", "directory not empty")
    case ELOOP: return ("ELOOP", "too many symbolic links encountered")
    case EXDEV: return ("EXDEV", "cross-device link not permitted")
    case EBADF: return ("EBADF", "bad file descriptor")
    case EINVAL: return ("EINVAL", "invalid argument")
    case EMLINK: return ("EMLINK", "too many links")
    case EBUSY: return ("EBUSY", "resource busy or locked")
    case EAGAIN: return ("EAGAIN", "resource temporarily unavailable")
    case ENOSPC: return ("ENOSPC", "no space left on device")
    case EROFS: return ("EROFS", "read-only file system")
    case ENAMETOOLONG: return ("ENAMETOOLONG", "name too long")
    case EIO: return ("EIO", "i/o error")
    case EMFILE: return ("EMFILE", "too many open files")
    default: return ("E\(err)", String(cString: strerror(err)))
    }
}

// A stat result. `bigint` records whether it was read with BigInt fields: only those carry nanosecond times, so
// it changes `value` and `identity`, both of which are stored on disk.
public struct FileStat {
    public let dev, mode, nlink, uid, gid, rdev, blksize, ino, size, blocks: Int64
    public let atime, mtime, ctime, birthtime: timespec
    public let bigint: Bool

    public init(_ s: Darwin.stat, bigint: Bool) {
        dev = Int64(s.st_dev); mode = Int64(s.st_mode); nlink = Int64(s.st_nlink); uid = Int64(s.st_uid); gid = Int64(s.st_gid)
        rdev = Int64(s.st_rdev); blksize = Int64(s.st_blksize); ino = Int64(bitPattern: UInt64(s.st_ino)); size = Int64(s.st_size)
        blocks = Int64(s.st_blocks); atime = s.st_atimespec; mtime = s.st_mtimespec; ctime = s.st_ctimespec
        birthtime = s.st_birthtimespec; self.bigint = bigint
    }

    private var kind: mode_t { mode_t(truncatingIfNeeded: mode) & S_IFMT }
    public var isFile: Bool { kind == S_IFREG }
    public var isDirectory: Bool { kind == S_IFDIR }
    public var isSymbolicLink: Bool { kind == S_IFLNK }
    public var isFIFO: Bool { kind == S_IFIFO }
    public var isSocket: Bool { kind == S_IFSOCK }

    private static func ns(_ t: timespec) -> Int64 { Int64(t.tv_sec) * 1_000_000_000 + Int64(t.tv_nsec) }
    private func number(_ x: Int64) -> Value { bigint ? .bigint(x) : .number(Double(x)) }
    private func ms(_ t: timespec) -> Value {
        bigint ? .bigint(FileStat.ns(t) / 1_000_000) : .number(Double(t.tv_sec) * 1000 + Double(t.tv_nsec) / 1_000_000)
    }
    public var sizeValue: Value { number(size) }
    public var inoValue: Value { number(ino) }
    public var devValue: Value { number(dev) }
    public var mtimeMs: Value { ms(mtime) }

    // dev:ino:size:mtimeNs:ctimeNs. Without BigInt fields the two times are empty.
    public var identity: String {
        let times = bigint ? "\(FileStat.ns(mtime)):\(FileStat.ns(ctime))" : ":"
        return "\(devValue.description):\(inoValue.description):\(sizeValue.description):\(times)"
    }

    // The stat as an object, for results that carry it: the numeric fields plus isFile/isDirectory/isSymbolicLink/
    // isFIFO/isSocket as hidden methods.
    public var value: Value {
        let o = ValueObject()
        o["dev"] = number(dev); o["mode"] = number(mode); o["nlink"] = number(nlink); o["uid"] = number(uid); o["gid"] = number(gid)
        o["rdev"] = number(rdev); o["blksize"] = number(blksize); o["ino"] = number(ino); o["size"] = number(size); o["blocks"] = number(blocks)
        o["atimeMs"] = ms(atime); o["mtimeMs"] = ms(mtime); o["ctimeMs"] = ms(ctime); o["birthtimeMs"] = ms(birthtime)
        if bigint {
            o["atimeNs"] = .bigint(FileStat.ns(atime)); o["mtimeNs"] = .bigint(FileStat.ns(mtime))
            o["ctimeNs"] = .bigint(FileStat.ns(ctime)); o["birthtimeNs"] = .bigint(FileStat.ns(birthtime))
        }
        let (file, directory, link, fifo, socket) = (isFile, isDirectory, isSymbolicLink, isFIFO, isSocket)
        o["isFile"] = Value { _ in .bool(file) }
        o["isDirectory"] = Value { _ in .bool(directory) }
        o["isSymbolicLink"] = Value { _ in .bool(link) }
        o["isFIFO"] = Value { _ in .bool(fifo) }
        o["isSocket"] = Value { _ in .bool(socket) }
        o.hidden = ["isFile", "isDirectory", "isSymbolicLink", "isFIFO", "isSocket"]
        return .object(o)
    }
}

public struct Dirent {
    public let name: String
    public let type: UInt8
    public var isDirectory: Bool { type == DT_DIR }
    public var isFile: Bool { type == DT_REG }
    public var isSymbolicLink: Bool { type == DT_LNK }
}

// An open file descriptor.
public final class FileHandle {
    public let fd: Int32
    public let path: String
    private var closed = false
    init(fd: Int32, path: String) { self.fd = fd; self.path = path }
    deinit { if !closed { Darwin.close(fd) } }

    public func stat(bigint: Bool = false) throws -> FileStat {
        try fs.handleStat(self, bigint)
    }
    public func readFile() throws -> Data { try fs.handleReadFile(self) }
    // handle.read(buffer, 0, length, position) → bytes actually read.
    public func read(length: Int, position: Int64?) throws -> Data {
        var n = 0, failure: Int32 = 0
        let buf = [UInt8](unsafeUninitializedCapacity: length) { raw, count in
            n = position.map { pread(fd, raw.baseAddress, length, off_t($0)) } ?? Darwin.read(fd, raw.baseAddress, length)
            failure = errno
            count = max(n, 0)
        }
        if n < 0 { throw fsError(failure, "read") }
        return Data(buf)
    }
    public func writeFile(_ data: Data) throws { try fs.handleWrite(self, data) }
    public func writeFile(_ text: String) throws { try writeFile(Data(text.utf8)) }
    public func sync() throws { try fs.handleSync(self) }
    public func chmod(_ mode: Int) throws { if fchmod(fd, mode_t(mode)) != 0 { throw fsError(errno, "fchmod") } }
    public func truncate(_ length: Int64 = 0) throws { if ftruncate(fd, off_t(length)) != 0 { throw fsError(errno, "ftruncate") } }
    public func close() throws {
        if closed { return }
        closed = true
        if Darwin.close(fd) != 0 { throw fsError(errno, "close") }
    }
    // Sequential chunks from the current position, like handle.createReadStream({ autoClose: false }).
    public func chunks(size: Int = 64 * 1024, _ body: (Data) throws -> Void) throws {
        while true {
            let d = try read(length: size, position: nil)
            if d.isEmpty { return }
            try body(d)
        }
    }
}

// Every filesystem call goes through this table so tests can interpose.
public final class FileSystem {
    public var readFile: (String) throws -> Data = FileSystem.nativeReadFile
    public var writeFile: (String, Data, String, Int) throws -> Void = FileSystem.nativeWriteFile
    public var stat: (String, Bool) throws -> FileStat = { p, big in try FileSystem.nativeStat(p, big, follow: true) }
    public var lstat: (String, Bool) throws -> FileStat = { p, big in try FileSystem.nativeStat(p, big, follow: false) }
    public var readdir: (String) throws -> [Dirent] = FileSystem.nativeReaddir
    public var mkdir: (String, Bool, Int) throws -> Void = FileSystem.nativeMkdir
    public var rename: (String, String) throws -> Void = { a, b in if Darwin.rename(a, b) != 0 { throw fsError(errno, "rename", a, b) } }
    public var link: (String, String) throws -> Void = { a, b in if Darwin.link(a, b) != 0 { throw fsError(errno, "link", a, b) } }
    public var symlink: (String, String) throws -> Void = { a, b in if Darwin.symlink(a, b) != 0 { throw fsError(errno, "symlink", a, b) } }
    public var unlink: (String) throws -> Void = { a in if Darwin.unlink(a) != 0 { throw fsError(errno, "unlink", a) } }
    public var rmdir: (String) throws -> Void = { a in if Darwin.rmdir(a) != 0 { throw fsError(errno, "rmdir", a) } }
    public var rm: (String, Bool, Bool) throws -> Void = FileSystem.nativeRm
    public var realpath: (String) throws -> String = FileSystem.nativeRealpath
    public var readlink: (String) throws -> Data = FileSystem.nativeReadlink
    public var copyFile: (String, String) throws -> Void = { a, b in if copyfile(a, b, nil, copyfile_flags_t(COPYFILE_ALL)) != 0 { throw fsError(errno, "copyfile", a, b) } }
    public var open: (String, Int32, Int) throws -> FileHandle = FileSystem.nativeOpen
    public var handleStat: (FileHandle, Bool) throws -> FileStat = { h, big in
        var s = Darwin.stat()
        if fstat(h.fd, &s) != 0 { throw fsError(errno, "fstat") }
        return FileStat(s, bigint: big)
    }
    public var handleReadFile: (FileHandle) throws -> Data = { h in
        var out = Data()
        try h.chunks { out.append($0) }
        return out
    }
    public var handleWrite: (FileHandle, Data) throws -> Void = { h, data in
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(h.fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 { if errno == EINTR { continue }; throw fsError(errno, "write") }
                off += n
            }
        }
    }
    public var handleSync: (FileHandle) throws -> Void = { h in if fsync(h.fd) != 0 { throw fsError(errno, "fsync") } }

    public init() {}

    public static func nativeReadFile(_ p: String) throws -> Data {
        let h = try nativeOpen(p, O_RDONLY, 0)
        defer { try? h.close() }
        var s = Darwin.stat()
        if fstat(h.fd, &s) != 0 { throw fsError(errno, "fstat") }
        if s.st_mode & S_IFMT == S_IFDIR { throw fsError(EISDIR, "read") }
        var out = Data(capacity: Int(s.st_size))
        try h.chunks(size: 1 << 20) { out.append($0) }
        return out
    }

    // flag is "w", "wx", "a" or "ax": write or append, with x failing if the file exists.
    public static func nativeWriteFile(_ p: String, _ data: Data, _ flag: String, _ mode: Int) throws {
        var flags: Int32 = O_WRONLY | O_CREAT
        if flag.hasPrefix("a") { flags |= O_APPEND } else { flags |= O_TRUNC }
        if flag.contains("x") { flags |= O_EXCL }
        let h = try nativeOpen(p, flags, mode)
        defer { try? h.close() }
        try h.writeFile(data)
    }

    public static func nativeStat(_ p: String, _ bigint: Bool, follow: Bool) throws -> FileStat {
        var s = Darwin.stat()
        let r: Int32 = follow ? statPath(p, &s) : Darwin.lstat(p, &s)
        if r != 0 { throw fsError(errno, follow ? "stat" : "lstat", p) }
        return FileStat(s, bigint: bigint)
    }

    public static func nativeReaddir(_ p: String) throws -> [Dirent] {
        guard let d = opendir(p) else { throw fsError(errno, "scandir", p) }
        defer { closedir(d) }
        var out: [Dirent] = []
        while let e = Darwin.readdir(d) {
            let name = withUnsafePointer(to: e.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(e.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var type = e.pointee.d_type
            if type == DT_UNKNOWN {
                var s = Darwin.stat()
                if Darwin.lstat((p as NSString).appendingPathComponent(name), &s) == 0 {
                    switch s.st_mode & S_IFMT {
                    case S_IFDIR: type = UInt8(DT_DIR)
                    case S_IFREG: type = UInt8(DT_REG)
                    case S_IFLNK: type = UInt8(DT_LNK)
                    default: break
                    }
                }
            }
            out.append(Dirent(name: name, type: type))
        }
        return out
    }

    public static func nativeMkdir(_ p: String, _ recursive: Bool, _ mode: Int) throws {
        if !recursive {
            if Darwin.mkdir(p, mode_t(mode)) != 0 { throw fsError(errno, "mkdir", p) }
            return
        }
        var s = Darwin.stat()
        if statPath(p, &s) == 0 {
            if s.st_mode & S_IFMT == S_IFDIR { return }
            throw fsError(EEXIST, "mkdir", p)
        }
        let parent = (p as NSString).deletingLastPathComponent
        if !parent.isEmpty && parent != p { try nativeMkdir(parent, true, mode) }
        if Darwin.mkdir(p, mode_t(mode)) != 0 && errno != EEXIST { throw fsError(errno, "mkdir", p) }
    }

    public static func nativeRm(_ p: String, _ recursive: Bool, _ force: Bool) throws {
        var s = Darwin.stat()
        if Darwin.lstat(p, &s) != 0 {
            if force && errno == ENOENT { return }
            throw fsError(errno, "lstat", p)
        }
        if s.st_mode & S_IFMT == S_IFDIR {
            guard recursive else { throw EngineError("Path is a directory: rm returned EISDIR (is a directory) \(p)", code: "ERR_FS_EISDIR") }
            for e in try nativeReaddir(p) { try nativeRm((p as NSString).appendingPathComponent(e.name), true, force) }
            if Darwin.rmdir(p) != 0 { throw fsError(errno, "rmdir", p) }
        } else if Darwin.unlink(p) != 0 {
            if force && errno == ENOENT { return }
            throw fsError(errno, "unlink", p)
        }
    }

    public static func nativeRealpath(_ p: String) throws -> String {
        guard let r = Darwin.realpath(p, nil) else { throw fsError(errno, "realpath", p) }
        defer { free(r) }
        return String(cString: r)
    }

    public static func nativeReadlink(_ p: String) throws -> Data {
        var buf = [Int8](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = Darwin.readlink(p, &buf, buf.count - 1)
        if n < 0 { throw fsError(errno, "readlink", p) }
        return Data(buf[0..<n].map { UInt8(bitPattern: $0) })
    }

    public static func nativeOpen(_ p: String, _ flags: Int32, _ mode: Int) throws -> FileHandle {
        let fd = Darwin.open(p, flags | O_CLOEXEC, mode_t(mode))
        if fd < 0 { throw fsError(errno, "open", p) }
        return FileHandle(fd: fd, path: p)
    }
}

// The process-wide filesystem table.
public var fs = FileSystem()

// Convenience wrappers with the common default arguments.
extension FileSystem {
    public func readText(_ p: String) throws -> String { String(decoding: try readFile(p), as: UTF8.self) }
    public func readJSON(_ p: String) throws -> Value { try JSON.parse(try readFile(p)) }
    public func write(_ p: String, _ text: String, flag: String = "w", mode: Int = 0o666) throws { try writeFile(p, Data(text.utf8), flag, mode) }
    public func stat(_ p: String, bigint: Bool = false) throws -> FileStat { try stat(p, bigint) }
    public func lstat(_ p: String, bigint: Bool = false) throws -> FileStat { try lstat(p, bigint) }
    public func names(_ p: String) throws -> [String] { try readdir(p).map(\.name) }
    public func mkdirp(_ p: String, mode: Int = 0o777) throws { try mkdir(p, true, mode) }
    public func rm(_ p: String, recursive: Bool = false, force: Bool = false) throws { try rm(p, recursive, force) }
    // String flags for open(): r, r+, w, wx, a, ax.
    public func open(_ p: String, _ flag: String, mode: Int = 0o666) throws -> FileHandle {
        let flags: Int32
        switch flag {
        case "r": flags = O_RDONLY
        case "r+": flags = O_RDWR
        case "w": flags = O_WRONLY | O_CREAT | O_TRUNC
        case "wx": flags = O_WRONLY | O_CREAT | O_TRUNC | O_EXCL
        case "a": flags = O_WRONLY | O_CREAT | O_APPEND
        case "ax": flags = O_WRONLY | O_CREAT | O_APPEND | O_EXCL
        default: flags = O_RDONLY
        }
        return try open(p, flags, mode)
    }
    public func exists(_ p: String) -> Bool { (try? stat(p, false)) != nil }
    public func mkdtemp(_ prefix: String) throws -> String {
        var template = Array((prefix + "XXXXXX").utf8CString)
        guard Darwin.mkdtemp(&template) != nil else { throw fsError(errno, "mkdtemp", prefix + "XXXXXX") }
        return String(cString: template)
    }
}

func statPath(_ p: String, _ s: inout Darwin.stat) -> Int32 { fstatat(AT_FDCWD, p, &s, 0) }
