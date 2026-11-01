import Foundation

public enum UsageWindowKind: String, Codable, Sendable {
    case fiveHour
    case weekly
    case modelWeekly
    case other
}

/// One rolling quota window (5-hour, weekly, per-model weekly, ...).
public struct UsageWindow: Codable, Equatable, Sendable, Identifiable {
    public var kind: UsageWindowKind
    public var label: String
    /// 0...100 (clamped).
    public var usedPercent: Double
    public var resetsAt: Date?
    public var windowSeconds: TimeInterval?

    public init(kind: UsageWindowKind, label: String, usedPercent: Double, resetsAt: Date? = nil, windowSeconds: TimeInterval? = nil) {
        self.kind = kind
        self.label = label
        self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
    }

    public var id: String { "\(kind.rawValue):\(label)" }
    public var remainingPercent: Double { max(0, 100 - usedPercent) }

    /// Share of the window that has elapsed (0...1), for pace graphs. Needs a reset time and window length.
    public func elapsedRatio(now: Date = Date()) -> Double? {
        guard let resetsAt, let windowSeconds, windowSeconds > 0 else { return nil }
        let elapsed = windowSeconds - resetsAt.timeIntervalSince(now)
        return min(1, max(0, elapsed / windowSeconds))
    }

    public func secondsUntilReset(now: Date = Date()) -> TimeInterval? {
        guard let resetsAt else { return nil }
        return max(0, resetsAt.timeIntervalSince(now))
    }

    public static let fiveHourSeconds: TimeInterval = 5 * 3600
    public static let weekSeconds: TimeInterval = 7 * 24 * 3600
}

/// Claude "extra usage" (pay-as-you-go beyond the plan).
public struct ExtraUsage: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var monthlyLimit: Double?
    public var usedCredits: Double?
    public var currency: String?
    public var outOfCredits: Bool

    public init(enabled: Bool, monthlyLimit: Double? = nil, usedCredits: Double? = nil, currency: String? = nil, outOfCredits: Bool = false) {
        self.enabled = enabled
        self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits
        self.currency = currency
        self.outOfCredits = outOfCredits
    }

    public var usedPercent: Double? {
        guard let monthlyLimit, monthlyLimit > 0, let usedCredits else { return nil }
        return min(100, max(0, usedCredits / monthlyLimit * 100))
    }
}

/// Codex credits.
public struct CreditsInfo: Codable, Equatable, Sendable {
    public var hasCredits: Bool
    public var unlimited: Bool
    public var balance: Double?
    public var overageLimitReached: Bool

    public init(hasCredits: Bool, unlimited: Bool = false, balance: Double? = nil, overageLimitReached: Bool = false) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
        self.overageLimitReached = overageLimitReached
    }
}

/// A point-in-time reading of an account's quota.
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var provider: Provider
    public var accountId: String
    public var fetchedAt: Date
    public var fiveHour: UsageWindow?
    public var weekly: UsageWindow?
    public var modelWindows: [UsageWindow]
    public var extraUsage: ExtraUsage?
    public var credits: CreditsInfo?
    public var plan: String?
    /// Which mechanism produced this reading (`oauth-usage`, `wham-usage`, `statusline-beacon`).
    public var source: String

    public init(provider: Provider, accountId: String, fetchedAt: Date, fiveHour: UsageWindow? = nil, weekly: UsageWindow? = nil,
                modelWindows: [UsageWindow] = [], extraUsage: ExtraUsage? = nil, credits: CreditsInfo? = nil,
                plan: String? = nil, source: String) {
        self.provider = provider
        self.accountId = accountId
        self.fetchedAt = fetchedAt
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.modelWindows = modelWindows
        self.extraUsage = extraUsage
        self.credits = credits
        self.plan = plan
        self.source = source
    }

    public var key: AccountKey { AccountKey(provider, accountId) }

    /// The headline number for an account: the 5-hour window when present, otherwise weekly.
    public var primaryPercent: Double? { fiveHour?.usedPercent ?? weekly?.usedPercent }

    /// Highest utilisation across all windows (what "approaching the limit" means).
    public var worstPercent: Double {
        ([fiveHour, weekly].compactMap { $0 } + modelWindows).map(\.usedPercent).max() ?? 0
    }

    public var allWindows: [UsageWindow] { [fiveHour, weekly].compactMap { $0 } + modelWindows }

    public var nextReset: Date? { allWindows.compactMap(\.resetsAt).min() }

    /// Capacity left in the most constraining window (used for recommendations).
    public var remainingCapacity: Double { 100 - worstPercent }

    public func age(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(fetchedAt) }
}

/// Synchronisation state of one account's usage reading.
public enum SyncStatus: Equatable, Sendable, Codable {
    case never
    case refreshing
    case fresh(at: Date)
    case stale(at: Date, reason: String)
    case error(String)
    case sessionExpired(String)
    /// The account is signed in, but the monitor's copy of its access token lapsed (idle account). The vendor
    /// renews it when the account is used; the last reading is kept.
    case paused(at: Date?, reason: String)
    case rateLimited(until: Date)
    case offline(lastSuccess: Date?)
    case disabled

    public var isProblem: Bool {
        switch self {
        case .never, .refreshing, .fresh, .disabled: return false
        default: return true
        }
    }

    public var shortLabel: String {
        switch self {
        case .never: return "Not synced"
        case .refreshing: return "Refreshing…"
        case .fresh: return "Up to date"
        case .stale: return "Stale"
        case .error: return "Error"
        case .sessionExpired: return "Sign-in needed"
        case .paused: return "Usage paused"
        case .rateLimited: return "Rate limited"
        case .offline: return "Offline"
        case .disabled: return "Disabled"
        }
    }

    public var detail: String? {
        switch self {
        case .stale(_, let reason): return reason
        case .error(let message): return message
        case .sessionExpired(let message): return message
        case .paused(_, let reason): return reason
        case .rateLimited(let until): return "The provider asked for a pause until \(until)"
        default: return nil
        }
    }
}
