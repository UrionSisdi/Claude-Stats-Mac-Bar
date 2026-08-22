import Foundation
import ServiceManagement

enum LaunchAtLogin {
    private static let desiredKey = "launchAtLoginDesired"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: desiredKey)
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("ClaudeStats: launch-at-login change failed: \(error.localizedDescription)")
        }
    }

    /// Enabled by default. Re-registered on every launch because a rebuild changes
    /// the signature and invalidates the previous login item.
    static func syncOnLaunch() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: desiredKey) == nil { defaults.set(true, forKey: desiredKey) }
        guard defaults.bool(forKey: desiredKey) else { return }
        if SMAppService.mainApp.status != .enabled { set(true) }
    }
}
