import Foundation

/// Wire format of `GET https://api.anthropic.com/api/oauth/usage` (undocumented; see docs/ENDPOINTS.md).
/// Every field is optional so schema drift degrades gracefully instead of failing the whole reading.
public struct ClaudeUsageResponse: Decodable, Equatable {
    public struct Window: Decodable, Equatable {
        public var utilization: Double?
        public var resets_at: String?
    }
    public struct LimitEntry: Decodable, Equatable {
        public struct Scope: Decodable, Equatable {
            public struct Model: Decodable, Equatable {
                public var id: String?
                public var display_name: String?
            }
            public var model: Model?
            public var surface: String?
        }
        public var kind: String?
        public var group: String?
        public var percent: Double?
        public var severity: String?
        public var resets_at: String?
        public var is_active: Bool?
        public var scope: Scope?
    }
    public struct Extra: Decodable, Equatable {
        public var limit_type: String?
        public var is_enabled: Bool?
        public var monthly_limit: Double?
        public var monthly_credit_limit: Double?
        public var currency: String?
        public var used_credits: Double?
        public var out_of_credits: Bool?
        public var spend_limit_amount_cents: Double?
        public var balance_cents: Double?
    }

    public var five_hour: Window?
    public var seven_day: Window?
    public var seven_day_oauth_apps: Window?
    public var seven_day_opus: Window?
    public var seven_day_sonnet: Window?
    public var limits: [LimitEntry]?
    public var extra_usage: Extra?
}

public enum ClaudeUsageDecoder {
    /// Trims fractional seconds to three digits (ISO8601DateFormatter is strict about the fraction length).
    static func normalizeFraction(_ s: String) -> String {
        guard let dot = s.firstIndex(of: "."), let tzStart = s[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else { return s }
        let fraction = s[s.index(after: dot)..<tzStart]
        guard fraction.allSatisfy(\.isNumber) else { return s }
        let trimmed = String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        return String(s[..<dot]) + "." + trimmed + String(s[tzStart...])
    }

    public static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let s = normalizeFraction(raw)
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded()) }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }
        if let epoch = Double(s) { return Date(timeIntervalSince1970: epoch > 1e12 ? epoch / 1000 : epoch) }
        return nil
    }

    public static func decode(_ data: Data) throws -> ClaudeUsageResponse {
        try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
    }

    /// `nil` when the account has no usage dashboard at all (free tier / API-only).
    public static func snapshot(from r: ClaudeUsageResponse, accountId: String, now: Date, source: String = "oauth-usage") -> UsageSnapshot? {
        var fiveHour: UsageWindow?
        if let w = r.five_hour, let u = w.utilization {
            fiveHour = UsageWindow(kind: .fiveHour, label: "5-hour", usedPercent: u, resetsAt: parseDate(w.resets_at), windowSeconds: UsageWindow.fiveHourSeconds)
        }
        var weekly: UsageWindow?
        if let w = r.seven_day, let u = w.utilization {
            weekly = UsageWindow(kind: .weekly, label: "Weekly", usedPercent: u, resetsAt: parseDate(w.resets_at), windowSeconds: UsageWindow.weekSeconds)
        }
        var models: [UsageWindow] = []
        if let w = r.seven_day_opus, let u = w.utilization, !(u == 0 && w.resets_at == nil) {
            models.append(UsageWindow(kind: .modelWeekly, label: "Opus weekly", usedPercent: u, resetsAt: parseDate(w.resets_at), windowSeconds: UsageWindow.weekSeconds))
        }
        if let w = r.seven_day_sonnet, let u = w.utilization, !(u == 0 && w.resets_at == nil) {
            models.append(UsageWindow(kind: .modelWeekly, label: "Sonnet weekly", usedPercent: u, resetsAt: parseDate(w.resets_at), windowSeconds: UsageWindow.weekSeconds))
        }
        for entry in r.limits ?? [] {
            guard let percent = entry.percent else { continue }
            switch entry.kind {
            case "weekly_scoped":
                guard let name = entry.scope?.model?.display_name ?? entry.group else { continue }
                let label = "\(name) weekly"
                if !models.contains(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) {
                    models.append(UsageWindow(kind: .modelWeekly, label: label, usedPercent: percent, resetsAt: parseDate(entry.resets_at), windowSeconds: UsageWindow.weekSeconds))
                }
            case "session" where fiveHour == nil:
                fiveHour = UsageWindow(kind: .fiveHour, label: "5-hour", usedPercent: percent, resetsAt: parseDate(entry.resets_at), windowSeconds: UsageWindow.fiveHourSeconds)
            case "weekly_all" where weekly == nil:
                weekly = UsageWindow(kind: .weekly, label: "Weekly", usedPercent: percent, resetsAt: parseDate(entry.resets_at), windowSeconds: UsageWindow.weekSeconds)
            default:
                continue
            }
        }
        var extra: ExtraUsage?
        if let e = r.extra_usage {
            let limit = e.monthly_limit ?? e.monthly_credit_limit ?? e.spend_limit_amount_cents.map { $0 / 100 }
            let used = e.used_credits ?? e.balance_cents.map { $0 / 100 }
            extra = ExtraUsage(enabled: e.is_enabled ?? false, monthlyLimit: limit, usedCredits: used, currency: e.currency, outOfCredits: e.out_of_credits ?? false)
        }
        guard fiveHour != nil || weekly != nil || !models.isEmpty else { return nil }
        return UsageSnapshot(provider: .claude, accountId: accountId, fetchedAt: now, fiveHour: fiveHour, weekly: weekly,
                             modelWindows: models, extraUsage: extra, credits: nil, plan: nil, source: source)
    }

    /// Status-line beacon JSON (documented `rate_limits` keys; epoch seconds).
    public static func snapshot(fromStatusLineJSON data: Data, accountId: String, observedAt: Date) -> UsageSnapshot? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let limits = obj["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String, kind: UsageWindowKind, label: String, seconds: TimeInterval) -> UsageWindow? {
            guard let w = limits[key] as? [String: Any], let used = w["used_percentage"] as? Double else { return nil }
            var resets: Date?
            if let r = w["resets_at"] as? Double { resets = Date(timeIntervalSince1970: r) }
            return UsageWindow(kind: kind, label: label, usedPercent: used, resetsAt: resets, windowSeconds: seconds)
        }
        let five = window("five_hour", kind: .fiveHour, label: "5-hour", seconds: UsageWindow.fiveHourSeconds)
        let week = window("seven_day", kind: .weekly, label: "Weekly", seconds: UsageWindow.weekSeconds)
        guard five != nil || week != nil else { return nil }
        return UsageSnapshot(provider: .claude, accountId: accountId, fetchedAt: observedAt, fiveHour: five, weekly: week, source: "statusline-beacon")
    }
}
