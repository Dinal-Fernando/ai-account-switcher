import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService (macOS 13+). Only meaningful when running from an app bundle.
public enum LaunchAtLogin {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    public static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
}
