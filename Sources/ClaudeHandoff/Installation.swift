import AppKit
import Foundation
import ServiceManagement

// First-run housekeeping: live in /Applications and open at login.
enum Installation {
    @MainActor
    static func prepare() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", !bundle.path.contains("/.build/") else { return }
        if offerMoveToApplications(bundle) { return }
        registerLoginItem()
    }

    // Returns true when the app relaunched from its new location.
    @MainActor
    private static func offerMoveToApplications(_ bundle: URL) -> Bool {
        let path = bundle.resolvingSymlinksInPath().path
        let homeApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        if path.hasPrefix("/Applications/") || path.hasPrefix(homeApps + "/") { return false }
        if UserDefaults.standard.bool(forKey: "declinedMoveToApplications") { return false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Claude Handoff to Applications?"
        alert.informativeText = "Claude Handoff updates itself in place, which works best from the Applications folder."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: "declinedMoveToApplications")
            return false
        }
        let writable = FileManager.default.isWritableFile(atPath: "/Applications")
        let folder = writable ? "/Applications" : homeApps
        let target = URL(fileURLWithPath: folder).appendingPathComponent(bundle.lastPathComponent)
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.trashItem(at: target, resultingItemURL: nil) }
            try FileManager.default.copyItem(at: bundle, to: target)
        } catch {
            let failure = NSAlert(error: error)
            failure.runModal()
            return false
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", target.path]
        try? open.run()
        if path.hasPrefix("/Volumes/") {
            // Leave the mounted DMG alone; the user can eject it.
        } else if !path.contains("/AppTranslocation/") {
            try? FileManager.default.trashItem(at: bundle, resultingItemURL: nil)
        }
        NSApp.terminate(nil)
        return true
    }

    private static func registerLoginItem() {
        guard #available(macOS 13.0, *), !UserDefaults.standard.bool(forKey: "registeredLoginItem") else { return }
        if (try? SMAppService.mainApp.register()) != nil { UserDefaults.standard.set(true, forKey: "registeredLoginItem") }
    }
}
