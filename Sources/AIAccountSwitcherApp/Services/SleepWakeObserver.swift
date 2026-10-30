import AppKit

/// Calls back after the Mac wakes from sleep so cached readings get refreshed promptly.
final class SleepWakeObserver {
    private var token: NSObjectProtocol?

    init(onWake: @escaping () -> Void) {
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            onWake()
        }
    }

    deinit {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
}
