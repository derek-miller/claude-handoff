import AppKit
import Foundation
import Sparkle

// In-app updates through Sparkle, using the appcast published with each GitHub release.
@MainActor
final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()
    private var controller: SPUStandardUpdaterController?
    private var busy: () -> Bool = { false }

    // Sparkle only works from a signed bundle that carries the release public key.
    var available: Bool { controller != nil }

    func start(busy: @escaping () -> Bool) {
        self.busy = busy
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard Bundle.main.bundleURL.pathExtension == "app", !key.isEmpty, !key.hasPrefix("__") else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    func check() { controller?.checkForUpdates(nil) }

    // A move, finish or sweep must not be interrupted by the relaunch an update needs.
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let blocked = MainActor.assumeIsolated { busy() }
        if blocked {
            throw NSError(domain: "ClaudeHandoff", code: 1, userInfo: [NSLocalizedDescriptionKey: "Finish the current move before updating."])
        }
    }
}
