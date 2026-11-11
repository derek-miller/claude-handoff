import AppKit

// Stand-ins the spliced App.swift calls instead of Sparkle, UserDefaults, the engine process and timers.
@MainActor final class Updates {
    static let shared = Updates()
    var available = false
    var checks = 0
    func check() { checks += 1 }
}
// Demo models are snapshots, which never offer updates; the update checks lift that for themselves.
@MainActor var updatesInSnapshots = false
@MainActor final class FixtureDefaults {
    var values: [String: Any] = [:]
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
@MainActor let fixtureDefaults = FixtureDefaults()
@MainActor var requests: [([String], (String) -> Void, (Int32, String) -> Void)] = []
@MainActor var automaticRefreshFixture = false
@MainActor var badgeResets: [() -> Void] = []
@MainActor func scheduleBadgeReset(_ action: @escaping () -> Void) { badgeResets.append(action) }
@MainActor var restartDialogs: [RestartPrompt] = []
@MainActor var restartDialogResponse: (NSApplication.ModalResponse, Bool) = (.alertThirdButtonReturn, false)
@MainActor var notices: [String] = []
@MainActor var launches: [(Process, (Int32, String) -> Void)] = []
extension Model {
    func checkSweep() { sweep() }
    func checkFinish(_ status: Int32) { finish(status, "fixture failure") }
    func checkOperation(_ args: [String]) { operationArgs = args }
    func checkCancel(_ plan: Event) { cancelRestart(plan) }
}
