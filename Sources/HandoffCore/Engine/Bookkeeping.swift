import Foundation

// Desktop keeps a session's queued input, archive flag and filed suggestions beside its record.

fileprivate let WAITING = "waiting-input", ARCHIVE_INDEX = "archived-sessions.idx", BACKLOG = "backlog/tasks.json"

fileprivate func present(_ p: String) -> Bool { (try? fs.lstat(p)) != nil }

fileprivate func readList(_ file: String, _ key: String) -> (Value, [Value])? {
    guard present(file), let data = try? readJson(Value(file)), data.isPlainObject, data[key].isArray else { return nil }
    return (data, data[key].elements)
}

fileprivate func writeCompact(_ file: String, _ value: Value) throws {
    try fs.mkdirp(path.dirname(file), mode: 0o700)
    try saveText(Value(file), Value(JSON.text(value)))
}

fileprivate func copyTree(_ from: String, _ to: String) throws {
    let info = try fs.lstat(from)
    if info.isDirectory {
        try fs.mkdirp(to, mode: 0o700)
        for name in try fs.names(from) { try copyTree(path.join(from, name), path.join(to, name)) }
    } else if info.isFile {
        try fs.copyFile(from, to)
    }
}

// What a move would add at `destDir` for the session whose Desktop record id is `recordId`.
func bookkeepingPlan(_ recordId: String, _ sourceDir: String, _ destDir: String) -> Value {
    let files = [recordId + ".json", recordId].filter { name in
        present(path.join(sourceDir, WAITING, name)) && !present(path.join(destDir, WAITING, name))
    }
    let destArchived = readList(path.join(destDir, ARCHIVE_INDEX), "archived")
    let archived = readList(path.join(sourceDir, ARCHIVE_INDEX), "archived")?.1.contains(Value(recordId)) == true
        && !(destArchived?.1.contains(Value(recordId)) ?? false)
        && (destArchived != nil || !present(path.join(destDir, ARCHIVE_INDEX)))
    let destItems = readList(path.join(destDir, BACKLOG), "items")
    let taken = Set((destItems?.1 ?? []).map { $0["id"].description })
    let backlog = (destItems != nil || !present(path.join(destDir, BACKLOG)))
        ? (readList(path.join(sourceDir, BACKLOG), "items")?.1 ?? []).filter { item in
            item["originSessionId"] === Value(recordId) && item["id"].isString && !taken.contains(item["id"].description)
        }.map { $0["id"] }
        : []
    if files.isEmpty && !archived && backlog.isEmpty { return .null }
    return [
        "source": Value(sourceDir), "dir": Value(destDir),
        "files": .strings(files.map { path.join(WAITING, $0) }),
        "archived": Value(archived), "createdIndex": Value(archived && destArchived == nil),
        "backlog": Value(backlog), "createdBacklog": Value(!backlog.isEmpty && destItems == nil),
    ]
}

func carryBookkeeping(_ plan: Value, _ recordId: String) throws {
    let source = plan["source"].description, dir = plan["dir"].description
    for name in plan["files"].elements.map(\.description) {
        let from = path.join(source, name), to = path.join(dir, name)
        if present(to) || !present(from) { continue }
        try fs.mkdirp(path.dirname(to), mode: 0o700)
        try copyTree(from, to)
    }
    if plan["archived"].truthy {
        let file = path.join(dir, ARCHIVE_INDEX)
        let (data, ids) = readList(file, "archived") ?? (["v": 1, "archived": []], [])
        if !ids.contains(Value(recordId)) { try writeCompact(file, Value.spread(data, ["archived": Value(ids + [Value(recordId)])] as Value)) }
    }
    let wanted = Set(plan["backlog"].elements.map(\.description))
    if !wanted.isEmpty {
        let file = path.join(dir, BACKLOG)
        let (data, items) = readList(file, "items") ?? (["version": 1, "items": []], [])
        let have = Set(items.map { $0["id"].description })
        let added = (readList(path.join(source, BACKLOG), "items")?.1 ?? []).filter { item in
            wanted.contains(item["id"].description) && !have.contains(item["id"].description)
        }
        if !added.isEmpty { try writeCompact(file, Value.spread(data, ["items": Value(items + added)] as Value)) }
    }
}

// Takes back what carryBookkeeping added; queued input is parked under `parkRoot`, never deleted.
func uncarryBookkeeping(_ plan: Value, _ recordId: String, _ parkRoot: String) throws {
    guard plan.truthy else { return }
    let dir = plan["dir"].description
    for name in plan["files"].elements.map(\.description) {
        let file = path.join(dir, name), parked = path.join(parkRoot, name)
        if !present(file) || present(parked) { continue }
        try fs.mkdirp(path.dirname(parked), mode: 0o700)
        try fs.rename(file, parked)
    }
    if plan["archived"].truthy {
        let file = path.join(dir, ARCHIVE_INDEX)
        if let (data, ids) = readList(file, "archived"), ids.contains(Value(recordId)) {
            let rest = ids.filter { $0 !== Value(recordId) }
            if rest.isEmpty && plan["createdIndex"].truthy { try fs.unlink(file) }
            else { try writeCompact(file, Value.spread(data, ["archived": Value(rest)] as Value)) }
        }
    }
    let added = Set(plan["backlog"].elements.map(\.description))
    if !added.isEmpty {
        let file = path.join(dir, BACKLOG)
        if let (data, items) = readList(file, "items") {
            let rest = items.filter { item in !(added.contains(item["id"].description) && item["originSessionId"] === Value(recordId)) }
            if rest.count != items.count {
                if rest.isEmpty && plan["createdBacklog"].truthy {
                    try fs.unlink(file)
                    try? fs.rmdir(path.dirname(file))
                } else { try writeCompact(file, Value.spread(data, ["items": Value(rest)] as Value)) }
            }
        }
    }
}
