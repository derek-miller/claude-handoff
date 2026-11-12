import Foundation
import Testing
@testable import HandoffCore

// A Z session whose Remote Control mirror can only be proven through its artifacts: 365 main events, three
// subagent streams (104 events) and one queued image prompt consumed mid-turn. The session is also owned by a
// disabled scheduled task. Tests mutate the streams in place, then call write() and inventory().
final class ArtifactFixture {
    let h: Home
    let main: Value
    let agents: Value
    let queued: Value
    let removal: Value
    let directory: String
    let taskFile: String
    var remote: Value
    var extra: Value = []
    var status = "active"
    var updated: Value = .undefined
    var calls = 0
    var reads = 0
    private(set) var cloud: Value = .undefined
    var from: Value = .undefined
    var to: Value = .undefined

    init(large: Bool = false, wrappers: Bool = false) throws {
        h = try home()
        main = branchEntries(365, SOURCE, 1000)
        agents = Value([35, 35, 34].enumerated().map { index, amount in
            branchEntries(amount, SOURCE, 3000 + index * 100).map { .spread($0, ["agentId": Value("a\(index)"), "isSidechain": true]) }
        })
        agents[0][0]["message"] = main[0]["message"].deepClone()
        let prompt: Value = [["type": "text", "text": "Synthetic queued image"],
                             ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": Value(String(repeating: "YWJj", count: large ? 300_000 : 4))]]]
        queued = ["type": "attachment", "uuid": Value(id(8100)), "sessionId": Value(SOURCE),
                  "attachment": ["type": "queued_command", "prompt": prompt, "source_uuid": Value(id(8000)), "delivery_id": "fixture-delivery"]]
        removal = ["type": "queue-operation", "operation": "remove", "reason": "absorbed_mid_turn", "commandUuid": Value(id(8000)), "deliveryId": "fixture-delivery", "sessionId": Value(SOURCE)]
        directory = path.join(h.project, SOURCE, "subagents")
        try mkdirp(directory)
        remote = main.concat(agents.flatMap { $0 }).concat([entry("user", 8000, nil, SOURCE, ["message": ["role": "user", "content": prompt]])])
        taskFile = path.join(h.dir("Z"), "scheduled-tasks.json")
        try write()
        try h.record("Z", SOURCE, rehomeRecord(["bridgeSessionIds": ["session_artifacts"], "scheduledTaskId": "artifact_task"]))
        try writeJSON(taskFile, ["scheduledTasks": [["id": "artifact_task", "notifySessionId": Value("local_\(SOURCE)"), "enabled": false, "prompt": "Synthetic task"]],
                                 "runRetries": ["artifact_task": ["attempts": 2]]])
        cloud = cloudFixture(h, [
            "list": fn { [unowned self] _ in [remoteSession(["id": "cse_artifacts", "title": "Renamed synthetic mirror", "status": Value(self.status), "updated_at": self.updated])] },
            "eventRows": fn { [unowned self] _ in
                self.reads += 1
                return remoteRows(self.remote.map { row in
                    let copy = row.deepClone()
                    if !wrappers { copy.removeKey("agentId"); copy.removeKey("isSidechain") }
                    return copy
                })
            },
            "session": fn { [unowned self] _ in remoteState(self.status) },
            "archive": fn { [unowned self] () in self.calls += 1; self.status = "archived" },
            "unarchive": fn { [unowned self] () in self.status = "active" },
        ])
        let all = try accounts(h.paths, [])
        from = all.find { $0["account"].str == h.acct.P }
        to = all.find { $0["account"].str == h.acct.Z }
    }

    func write() throws {
        try h.write(SOURCE, main.concat(extra).concat([queued, .spread(queued, ["uuid": Value(id(8101))]), removal]))
        for (index, rows) in agents.elements.enumerated() {
            try writeText(path.join(directory, "agent-a\(index).jsonl"), rows.elements.map { JSON.text($0) }.joined(separator: "\n") + "\n")
        }
    }

    func inventory(_ options: Value = [:]) throws -> Value {
        try HandoffCore.inventory([from], to, h.paths, NOOP, .spread(["cloud": cloud, "processes": []], options))
    }

    var transcript: String { h.transcript(SOURCE) }
}

func artifactFixture(large: Bool = false, wrappers: Bool = false) throws -> ArtifactFixture { try ArtifactFixture(large: large, wrappers: wrappers) }
