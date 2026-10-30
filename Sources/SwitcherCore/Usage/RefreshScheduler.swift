import Foundation

public enum RefreshMode: String, Codable, CaseIterable, Sendable {
    case smart
    case fixed
    case manual

    public var displayName: String {
        switch self {
        case .smart: return "Smart (adaptive)"
        case .fixed: return "Fixed interval"
        case .manual: return "Manual only"
        }
    }
}

public struct RefreshSettings: Codable, Equatable, Sendable {
    public var mode: RefreshMode = .smart
    public var fixedInterval: TimeInterval = 180
    /// Hard floor between automatic fetches of the same account (the Anthropic endpoint rate-limits aggressively).
    public var minimumInterval: TimeInterval = 60
    public var manualDebounce: TimeInterval = 10

    public init() {}
    public static let fixedChoices: [TimeInterval] = [60, 180, 300, 600, 1800]
}

/// Adaptive cadence: 60 s while numbers move, stepping down to 10 min when nothing changes.
public struct SmartRefreshPolicy: Sendable, Equatable {
    public static let levels: [TimeInterval] = [60, 180, 300, 600]
    public static let demoteAfterRounds = [3, 6, 12]
    public static let changeEpsilon = 0.01

    public struct State: Equatable, Sendable {
        public var level = 0
        public var unchangedRounds = 0
        public var lastValues: [AccountKey: Double] = [:]
        public init() {}
        public var interval: TimeInterval { SmartRefreshPolicy.levels[min(level, SmartRefreshPolicy.levels.count - 1)] }
    }

    public init() {}

    /// Feed the latest headline percentages; returns the interval until the next automatic refresh.
    public func next(state: inout State, observed: [AccountKey: Double]) -> TimeInterval {
        var changed = false
        for (key, value) in observed {
            if let last = state.lastValues[key] {
                if abs(last - value) > Self.changeEpsilon { changed = true }
            } else {
                changed = true
            }
        }
        state.lastValues = observed
        if changed {
            state.level = 0
            state.unchangedRounds = 0
        } else {
            state.unchangedRounds += 1
            if state.level < Self.demoteAfterRounds.count, state.unchangedRounds >= Self.demoteAfterRounds[state.level] {
                state.level += 1
            }
        }
        return state.interval
    }

    /// Popover opened / manual refresh: go back to the fastest cadence.
    public func activate(state: inout State) {
        state.level = 0
        state.unchangedRounds = 0
    }
}

/// Decides *when* the next automatic refresh happens and whether a manual one is allowed. Timer-free so it
/// can be unit tested; the app drives it with a Task/Timer.
public final class RefreshScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private let time: TimeSource
    public private(set) var settings: RefreshSettings
    private let smart = SmartRefreshPolicy()
    private var smartState = SmartRefreshPolicy.State()
    private var lastStarted: Date?
    private var lastManual: Date?

    public init(settings: RefreshSettings = RefreshSettings(), time: TimeSource = SystemTimeSource()) {
        self.settings = settings
        self.time = time
    }

    public func update(settings: RefreshSettings) {
        lock.lock(); defer { lock.unlock() }
        self.settings = settings
    }

    public func noteRefreshStarted() {
        lock.lock(); defer { lock.unlock() }
        lastStarted = time.now
    }

    /// Interval to wait after a completed round, given the observed headline numbers. `nil` = no automatic refresh.
    public func intervalAfterRound(observed: [AccountKey: Double]) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        switch settings.mode {
        case .manual: return nil
        case .fixed: return max(settings.minimumInterval, settings.fixedInterval)
        case .smart: return max(settings.minimumInterval, smart.next(state: &smartState, observed: observed))
        }
    }

    /// Manual refresh / popover open. Returns false when debounced.
    public func requestManualRefresh() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = time.now
        if let last = lastManual, now.timeIntervalSince(last) < settings.manualDebounce { return false }
        lastManual = now
        smart.activate(state: &smartState)
        return true
    }

    public func activate() {
        lock.lock(); defer { lock.unlock() }
        smart.activate(state: &smartState)
    }

    public var currentSmartInterval: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return smartState.interval
    }
}
