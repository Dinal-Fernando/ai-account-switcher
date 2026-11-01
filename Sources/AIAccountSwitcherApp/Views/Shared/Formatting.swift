import SwiftUI
import SwitcherCore

enum UsageFormat {
    static func color(for percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return .green
    }

    /// "1h 23m left", rounded up like the reference app.
    static func countdown(_ window: UsageWindow?, now: Date) -> String {
        guard let window, let resetsAt = window.resetsAt else { return "Reset time appears after first use" }
        let secs = resetsAt.timeIntervalSince(now)
        if secs <= 0 { return "Resetting soon" }
        let mins = Int(ceil(secs / 60))
        if mins < 60 { return "\(mins)m left" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h \(mins % 60)m left" }
        return "\(hours / 24)d \(hours % 24)h left"
    }

    static func resetTime(_ window: UsageWindow?) -> String? {
        guard let date = window?.resetsAt else { return nil }
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func age(_ date: Date, now: Date) -> String {
        let secs = max(0, now.timeIntervalSince(date))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(Int(secs / 60)) min ago" }
        if secs < 86_400 { return "\(Int(secs / 3600)) h ago" }
        return "\(Int(secs / 86_400)) d ago"
    }

    static func money(_ value: Double?, currency: String?) -> String {
        guard let value else { return "—" }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency ?? "USD"
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}

struct StatusDot: View {
    let status: SyncStatus
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
    private var color: Color {
        switch status {
        case .fresh: return .green
        case .refreshing: return .blue
        case .stale, .rateLimited, .offline, .paused: return .orange
        case .error, .sessionExpired: return .red
        case .never, .disabled: return .gray
        }
    }
}
