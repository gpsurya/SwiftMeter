import Foundation
import SwiftUI
import ServiceManagement
import os.log

// User preferences. Backed by `@AppStorage` so the values survive restarts
// and any view can observe them via `@ObservedObject AppSettings.shared`.
//
// v1.2 surface: auto-launch (via SMAppService), history retention, soft
// monthly data-cap. More settings get added as later releases need them.

final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    private let log = Logger(subsystem: "com.swiftmeter.app", category: "settings")

    // MARK: - Stored prefs

    @AppStorage("settings.autoLaunch")           var autoLaunch: Bool          = true
    @AppStorage("settings.historyRetentionDays") var historyRetentionDays: Int = 90
    /// Soft monthly data cap in GB. 0 = no cap.
    @AppStorage("settings.dataCapGB")            var dataCapGB: Double         = 0

    private init() {
        migrateLegacyLaunchAgentIfNeeded()
        applyAutoLaunch()
    }

    // MARK: - Auto-launch via SMAppService

    /// Mirror the `autoLaunch` toggle into the system. SMAppService.mainApp
    /// is the modern Sonoma path; it requires the app to be in /Applications
    /// or a similar trusted location. If registration fails (e.g. running a
    /// dev build from /tmp) we just log — the user keeps using the toggle
    /// once they install properly.
    func applyAutoLaunch() {
        let service = SMAppService.mainApp
        do {
            if autoLaunch {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            log.error("SMAppService toggle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Up through v1.1 the launch agent was hand-installed by `build.sh`
    /// at `~/Library/LaunchAgents/com.swiftmeter.app.plist`. v1.2 owns
    /// auto-launch via SMAppService instead. On first launch we delete the
    /// old plist so the app doesn't get launched twice.
    private func migrateLegacyLaunchAgentIfNeeded() {
        let path = NSString(string: "~/Library/LaunchAgents/com.swiftmeter.app.plist")
            .expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        // Best-effort unload; ignore errors (it may already be unloaded).
        let unload = Process()
        unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        unload.arguments     = ["unload", path]
        try? unload.run()
        unload.waitUntilExit()
        try? FileManager.default.removeItem(atPath: path)
        log.info("Removed legacy LaunchAgent plist; SMAppService now manages auto-launch.")
    }
}
