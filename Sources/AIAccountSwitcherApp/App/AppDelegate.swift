import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var sharedModel: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppDelegate.sharedModel?.start()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.identifier?.rawValue.contains("dashboard") == true || window.title == "AI Account Switcher" {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // keep living in the menu bar
    }
}
