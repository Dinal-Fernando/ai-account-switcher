import Foundation

/// Exponential backoff with jitter for the undocumented usage endpoints, which are known to answer bursts
/// with 429 (and `Retry-After: 0`). Mirrors the behaviour that stabilised Usage4Claude.
public struct BackoffPolicy: Sendable, Equatable {
    public var baseDelay: TimeInterval = 60
    public var maxDelay: TimeInterval = 30 * 60
    public var maxNetworkDelay: TimeInterval = 5 * 60
    public var maxRetryAfter: TimeInterval = 60 * 60
    public var jitterFraction: Double = 0.2

    public enum FailureKind: Equatable, Sendable {
        case rateLimited(retryAfter: TimeInterval?)
        case server
        case network
        case auth
    }

    public init() {}

    public func delay(afterConsecutiveFailures n: Int, kind: FailureKind, random: Double = Double.random(in: 0...1)) -> TimeInterval {
        let exponent = max(0, n - 1)
        let cap = kind == .network ? maxNetworkDelay : maxDelay
        var delay = min(baseDelay * pow(2, Double(min(exponent, 20))), cap)
        if case .rateLimited(let retryAfter) = kind, let retryAfter, retryAfter > 0 {
            delay = max(delay, min(retryAfter, maxRetryAfter))
        }
        if kind == .auth { delay = max(delay, 10 * 60) }   // nothing to gain from retrying an expired login quickly
        return delay * (1 + jitterFraction * min(1, max(0, random)))
    }
}

public struct BackoffState: Equatable, Sendable, Codable {
    public var consecutiveFailures = 0
    public var notBefore: Date?

    public init() {}

    public mutating func recordFailure(_ kind: BackoffPolicy.FailureKind, policy: BackoffPolicy, now: Date) {
        consecutiveFailures += 1
        notBefore = now.addingTimeInterval(policy.delay(afterConsecutiveFailures: consecutiveFailures, kind: kind))
    }

    public mutating func reset() {
        consecutiveFailures = 0
        notBefore = nil
    }

    public func isBlocked(now: Date) -> Bool {
        guard let notBefore else { return false }
        return now < notBefore
    }
}
