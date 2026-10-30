import Foundation

public struct SwitchRecommendation: Equatable, Sendable {
    public var provider: Provider
    public var from: AccountKey
    public var to: AccountKey
    public var toName: String
    public var fromRemaining: Double
    public var toRemaining: Double
    public var reason: String
}

/// Suggests another signed-in account of the same provider with materially more capacity left.
public enum RecommendationEngine {
    public static func bestAlternative(provider: Provider, active: Account, accounts: [Account], usage: [AccountKey: UsageSnapshot],
                                       minimumAdvantage: Double = 15) -> SwitchRecommendation? {
        guard let activeSnapshot = usage[active.key] else { return nil }
        let activeRemaining = activeSnapshot.remainingCapacity
        var best: (Account, UsageSnapshot)?
        for candidate in accounts where candidate.provider == provider && candidate.key != active.key {
            guard let snap = usage[candidate.key] else { continue }
            if let auth = candidate.lastAuth, !auth.isAuthenticated { continue }
            if let current = best, current.1.remainingCapacity >= snap.remainingCapacity { continue }
            best = (candidate, snap)
        }
        guard let (account, snap) = best, snap.remainingCapacity - activeRemaining >= minimumAdvantage else { return nil }
        let reason = "\(account.name) has \(Int(snap.remainingCapacity.rounded()))% of its quota left (\(active.name): \(Int(activeRemaining.rounded()))%)."
        return SwitchRecommendation(provider: provider, from: active.key, to: account.key, toName: account.name,
                                    fromRemaining: activeRemaining, toRemaining: snap.remainingCapacity, reason: reason)
    }

    /// Opt-in automatic switching: only when the active account is at/over `threshold` and a clearly better one exists.
    public static func automaticSwitch(provider: Provider, active: Account, accounts: [Account], usage: [AccountKey: UsageSnapshot],
                                       threshold: Double = 95) -> SwitchRecommendation? {
        guard let snap = usage[active.key], snap.worstPercent >= threshold else { return nil }
        return bestAlternative(provider: provider, active: active, accounts: accounts, usage: usage, minimumAdvantage: 25)
    }
}
