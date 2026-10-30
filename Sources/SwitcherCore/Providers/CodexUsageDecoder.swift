import Foundation

/// Wire format of `GET https://chatgpt.com/backend-api/wham/usage` (undocumented; see docs/ENDPOINTS.md).
public struct CodexUsageResponse: Decodable, Equatable {
    public struct Window: Decodable, Equatable {
        public var used_percent: Double?
        public var limit_window_seconds: Int?
        public var reset_after_seconds: Int?
        public var reset_at: Double?
        public var resets_at: Double?
    }
    public struct RateLimit: Decodable, Equatable {
        public var allowed: Bool?
        public var limit_reached: Bool?
        public var primary_window: Window?
        public var secondary_window: Window?
    }
    public struct Credits: Decodable, Equatable {
        public var has_credits: Bool?
        public var unlimited: Bool?
        public var overage_limit_reached: Bool?
        public var balance: Double?

        enum CodingKeys: String, CodingKey { case has_credits, unlimited, overage_limit_reached, balance }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            has_credits = try c.decodeIfPresent(Bool.self, forKey: .has_credits)
            unlimited = try c.decodeIfPresent(Bool.self, forKey: .unlimited)
            overage_limit_reached = try c.decodeIfPresent(Bool.self, forKey: .overage_limit_reached)
            if let d = try? c.decodeIfPresent(Double.self, forKey: .balance) { balance = d }
            else if let s = try? c.decodeIfPresent(String.self, forKey: .balance) { balance = Double(s) }
            else if let i = try? c.decodeIfPresent(Int.self, forKey: .balance) { balance = Double(i) }
        }
    }

    public var account_id: String?
    public var email: String?
    public var plan_type: String?
    public var rate_limit: RateLimit?
    public var credits: Credits?
}

public enum CodexUsageDecoder {
    public static func decode(_ data: Data) throws -> CodexUsageResponse {
        try JSONDecoder().decode(CodexUsageResponse.self, from: data)
    }

    /// Classifies a window by its duration (closest to 5 h vs 7 d), not by its JSON slot: Codex has moved
    /// windows between `primary_window` and `secondary_window` before.
    static func classify(_ w: CodexUsageResponse.Window) -> UsageWindowKind {
        guard let secs = w.limit_window_seconds else { return .weekly }
        let d5 = abs(Double(secs) - UsageWindow.fiveHourSeconds)
        let d7 = abs(Double(secs) - UsageWindow.weekSeconds)
        return d5 <= d7 ? .fiveHour : .weekly
    }

    static func window(_ w: CodexUsageResponse.Window, now: Date) -> UsageWindow? {
        guard let used = w.used_percent else { return nil }
        let kind = classify(w)
        var resets: Date?
        if let epoch = w.reset_at ?? w.resets_at { resets = Date(timeIntervalSince1970: epoch > 1e12 ? epoch / 1000 : epoch) }
        else if let after = w.reset_after_seconds { resets = now.addingTimeInterval(TimeInterval(after)) }
        let seconds = w.limit_window_seconds.map(TimeInterval.init) ?? (kind == .fiveHour ? UsageWindow.fiveHourSeconds : UsageWindow.weekSeconds)
        return UsageWindow(kind: kind, label: kind == .fiveHour ? "5-hour" : "Weekly", usedPercent: used, resetsAt: resets, windowSeconds: seconds)
    }

    public static func snapshot(from r: CodexUsageResponse, accountId: String, now: Date, source: String = "wham-usage") -> UsageSnapshot? {
        var five: UsageWindow?
        var week: UsageWindow?
        for raw in [r.rate_limit?.primary_window, r.rate_limit?.secondary_window].compactMap({ $0 }) {
            guard let w = window(raw, now: now) else { continue }
            if w.kind == .fiveHour { if five == nil { five = w } else if week == nil { week = w } }
            else { if week == nil { week = w } else if five == nil { five = w } }
        }
        var credits: CreditsInfo?
        if let c = r.credits {
            credits = CreditsInfo(hasCredits: c.has_credits ?? false, unlimited: c.unlimited ?? false, balance: c.balance, overageLimitReached: c.overage_limit_reached ?? false)
        }
        guard five != nil || week != nil || credits != nil else { return nil }
        return UsageSnapshot(provider: .codex, accountId: accountId, fetchedAt: now, fiveHour: five, weekly: week,
                             modelWindows: [], extraUsage: nil, credits: credits, plan: r.plan_type, source: source)
    }
}
