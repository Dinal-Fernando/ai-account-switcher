import Foundation

public struct NotificationThresholds: Codable, Equatable, Sendable {
    public var enabled = true
    public var fiveHour: [Int] = [90]
    public var weekly: [Int] = [75, 90]
    public var modelWeekly: [Int] = [90]
    public var extraUsage: [Int] = [75, 90]

    public init() {}

    public func thresholds(for kind: UsageWindowKind) -> [Int] {
        switch kind {
        case .fiveHour: return fiveHour
        case .weekly: return weekly
        case .modelWeekly: return modelWeekly
        case .other: return []
        }
    }
}

public struct UsageAlert: Equatable, Identifiable, Sendable {
    public var id: String
    public var key: AccountKey
    public var accountName: String
    public var window: UsageWindow
    public var threshold: Int
    public var title: String
    public var body: String

    public init(id: String, key: AccountKey, accountName: String, window: UsageWindow, threshold: Int, title: String, body: String) {
        self.id = id
        self.key = key
        self.accountName = accountName
        self.window = window
        self.threshold = threshold
        self.title = title
        self.body = body
    }
}

/// Decides which threshold crossings deserve a notification. De-duplicated per
/// `provider:account:window:threshold` and per reset cycle (`resets_at`), so a window that resets re-arms.
public final class NotificationDecisionEngine: @unchecked Sendable {
    private let lock = NSLock()
    public var thresholds: NotificationThresholds
    /// key → resetsAt epoch (0 when unknown) of the cycle in which the threshold fired.
    public private(set) var fired: [String: Double]

    public init(thresholds: NotificationThresholds = NotificationThresholds(), fired: [String: Double] = [:]) {
        self.thresholds = thresholds
        self.fired = fired
    }

    static func recordKey(_ key: AccountKey, windowId: String, threshold: Int) -> String {
        "\(key.description):\(windowId):\(threshold)"
    }

    /// Evaluates one snapshot; returns at most one alert per window (the highest newly crossed threshold).
    public func evaluate(snapshot: UsageSnapshot, accountName: String, now: Date = Date()) -> [UsageAlert] {
        lock.lock(); defer { lock.unlock() }
        guard thresholds.enabled else { return [] }
        var alerts: [UsageAlert] = []
        for window in snapshot.allWindows {
            let cycle = window.resetsAt?.timeIntervalSince1970 ?? 0
            var highestNew: Int?
            for t in thresholds.thresholds(for: window.kind).sorted() {
                let rk = Self.recordKey(snapshot.key, windowId: window.id, threshold: t)
                if window.usedPercent >= Double(t) {
                    if fired[rk] != cycle {
                        fired[rk] = cycle
                        highestNew = t
                    }
                } else if let old = fired[rk], old != cycle || cycle == 0 {
                    fired.removeValue(forKey: rk)   // window reset (or, without reset info, usage dropped): re-arm
                }
            }
            if let t = highestNew {
                let pct = Int(window.usedPercent.rounded())
                var body = "\(accountName) has used \(pct)% of its \(window.label.lowercased()) \(snapshot.provider.shortName) quota."
                if let reset = window.resetsAt {
                    body += " Resets \(Self.relative(reset, now: now))."
                }
                alerts.append(UsageAlert(id: "\(snapshot.key):\(window.id):\(t):\(Int(cycle))", key: snapshot.key, accountName: accountName,
                                         window: window, threshold: t, title: "\(snapshot.provider.shortName): \(accountName) at \(pct)%", body: body))
            }
        }
        return alerts
    }

    /// Marks thresholds already exceeded as fired (used when the user raises/lowers thresholds, so they are not replayed).
    public func silenceReached(snapshot: UsageSnapshot) {
        lock.lock(); defer { lock.unlock() }
        for window in snapshot.allWindows {
            let cycle = window.resetsAt?.timeIntervalSince1970 ?? 0
            for t in thresholds.thresholds(for: window.kind) where window.usedPercent >= Double(t) {
                fired[Self.recordKey(snapshot.key, windowId: window.id, threshold: t)] = cycle
            }
        }
    }

    public func forget(_ key: AccountKey) {
        lock.lock(); defer { lock.unlock() }
        fired = fired.filter { !$0.key.hasPrefix(key.description + ":") }
    }

    static func relative(_ date: Date, now: Date) -> String {
        let secs = max(0, date.timeIntervalSince(now))
        let mins = Int(ceil(secs / 60))
        if mins < 60 { return "in \(mins) min" }
        let hours = mins / 60
        if hours < 48 { return "in \(hours) h \(mins % 60) min" }
        return "in \(hours / 24) d \(hours % 24) h"
    }
}
