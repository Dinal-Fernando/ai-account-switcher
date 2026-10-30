import Foundation

/// Injectable clock so schedulers and notification logic are deterministic in tests.
public protocol TimeSource: Sendable {
    var now: Date { get }
}

public struct SystemTimeSource: TimeSource {
    public init() {}
    public var now: Date { Date() }
}

public final class FixedTimeSource: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    public init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = date }
    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    public func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
    public func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        current = date
    }
}
