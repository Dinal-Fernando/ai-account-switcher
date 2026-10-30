import Foundation
import SwitcherCore

enum GraphStyle: String, Codable, CaseIterable {
    case rings
    case pace
    var displayName: String { self == .rings ? "Rings" : "Pace graph" }
}

/// User preferences, persisted as one JSON blob in UserDefaults (no secrets).
struct AppSettings: Codable, Equatable {
    var refresh = RefreshSettings()
    var thresholds = NotificationThresholds()
    var notificationsEnabled = true
    /// Opt-in per provider: automatically switch to the account with the most capacity when the active one is exhausted.
    var autoSwitch: [String: Bool] = [:]
    var autoSwitchThreshold: Double = 95
    var terminalApp = "Terminal"
    var showDockIcon = true
    var graphStyle: GraphStyle = .rings
    var showRemaining = false
    var onboardingCompleted = false
    var firedNotifications: [String: Double] = [:]
    var menuBarShowsPercent = true

    static let defaultsKey = "dev.aiswitch.settings.v1"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case refresh, thresholds, notificationsEnabled, autoSwitch, autoSwitchThreshold, terminalApp, showDockIcon,
             graphStyle, showRemaining, onboardingCompleted, firedNotifications, menuBarShowsPercent
    }

    /// Every key is optional so adding fields later never resets existing preferences.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refresh = try c.decodeIfPresent(RefreshSettings.self, forKey: .refresh) ?? RefreshSettings()
        thresholds = try c.decodeIfPresent(NotificationThresholds.self, forKey: .thresholds) ?? NotificationThresholds()
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        autoSwitch = try c.decodeIfPresent([String: Bool].self, forKey: .autoSwitch) ?? [:]
        autoSwitchThreshold = try c.decodeIfPresent(Double.self, forKey: .autoSwitchThreshold) ?? 95
        terminalApp = try c.decodeIfPresent(String.self, forKey: .terminalApp) ?? "Terminal"
        showDockIcon = try c.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? true
        graphStyle = try c.decodeIfPresent(GraphStyle.self, forKey: .graphStyle) ?? .rings
        showRemaining = try c.decodeIfPresent(Bool.self, forKey: .showRemaining) ?? false
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        firedNotifications = try c.decodeIfPresent([String: Double].self, forKey: .firedNotifications) ?? [:]
        menuBarShowsPercent = try c.decodeIfPresent(Bool.self, forKey: .menuBarShowsPercent) ?? true
    }

    static func load(defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    func autoSwitchEnabled(_ provider: Provider) -> Bool { autoSwitch[provider.rawValue] ?? false }
}
