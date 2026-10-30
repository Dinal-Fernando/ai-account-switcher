import Foundation
import SwitcherCore
import UserNotifications

/// UNUserNotificationCenter wrapper. The "Switch to …" action performs a real account switch for future
/// CLI launches (via AppModel), never a cosmetic selection.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let categoryId = "dev.aiswitch.usage"
    static let switchActionId = "dev.aiswitch.switch"

    var onSwitchAction: ((AccountKey) -> Void)?
    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }
    private var authorized = false

    func registerCategories() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let switchAction = UNNotificationAction(identifier: Self.switchActionId, title: "Switch account", options: [])
        let category = UNNotificationCategory(identifier: Self.categoryId, actions: [switchAction], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    func post(alert: UsageAlert, recommendation: SwitchRecommendation?) {
        guard available else { SwitcherLog.shared.log("notification (no bundle): \(alert.title) — \(alert.body)", category: "notify"); return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        var body = alert.body
        if let rec = recommendation {
            body += " \(rec.toName) has \(Int(rec.toRemaining.rounded()))% left."
            content.categoryIdentifier = Self.categoryId
            content.userInfo = ["target": rec.to.description]
        }
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "usage-\(alert.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func postInfo(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "info-\(UUID().uuidString)", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let target = userInfo["target"] as? String
        Task { @MainActor in
            if action == Self.switchActionId, let target, let key = AccountKey(string: target) {
                self.onSwitchAction?(key)
            }
            completionHandler()
        }
    }
}
