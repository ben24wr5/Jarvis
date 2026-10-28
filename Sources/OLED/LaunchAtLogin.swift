import Foundation
import ServiceManagement

/// Opens OLED automatically when you log in to the Mac.
enum LaunchAtLogin {
    static let key = "launchAtLogin"

    static var wanted: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key); apply() }
    }

    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// Makes macOS match the setting. Safe to call every launch (also re-registers after an update).
    static func apply() {
        let service = SMAppService.mainApp
        do {
            if wanted {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSLog("OLED: open-at-login change failed: \(error.localizedDescription)")
        }
    }
}
