import Foundation

/// Last-known usage per account (so the dashboard shows something immediately after launch) plus an
/// append-only history for the sparkline. Both live under `$AISWITCH_HOME` with mode 0600.
public final class UsageCache: @unchecked Sendable {
    private let paths: SwitcherPaths
    private let lock = NSLock()
    /// Minimum spacing between history rows for one account.
    public var historyMinSpacing: TimeInterval = 300
    public var historyMaxRows = 4000

    public init(paths: SwitcherPaths) { self.paths = paths }

    public func loadSnapshot(_ key: AccountKey) -> UsageSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: paths.usageCacheFile(key)) else { return nil }
        return try? AccountStore.makeDecoder().decode(UsageSnapshot.self, from: data)
    }

    public func saveSnapshot(_ snapshot: UsageSnapshot) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? AccountStore.makeEncoder().encode(snapshot) else { return }
        try? AtomicFile.write(data, to: paths.usageCacheFile(snapshot.key), permissions: 0o600)
        appendHistoryLocked(snapshot)
    }

    public func removeSnapshot(_ key: AccountKey) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: paths.usageCacheFile(key))
        try? FileManager.default.removeItem(at: paths.historyFile(key))
    }

    public struct HistoryPoint: Codable, Equatable, Sendable, Identifiable {
        public var at: Date
        public var fiveHour: Double?
        public var weekly: Double?
        public var id: Date { at }
        public init(at: Date, fiveHour: Double?, weekly: Double?) {
            self.at = at
            self.fiveHour = fiveHour
            self.weekly = weekly
        }
    }

    public func history(_ key: AccountKey, limit: Int = 500) -> [HistoryPoint] {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? String(contentsOf: paths.historyFile(key), encoding: .utf8) else { return [] }
        let decoder = AccountStore.makeDecoder()
        let lines = text.split(separator: "\n").suffix(limit)
        return lines.compactMap { line in try? decoder.decode(HistoryPoint.self, from: Data(line.utf8)) }
    }

    private func appendHistoryLocked(_ snapshot: UsageSnapshot) {
        let file = paths.historyFile(snapshot.key)
        let fm = FileManager.default
        var existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let decoder = AccountStore.makeDecoder()
        if let lastLine = existing.split(separator: "\n").last,
           let last = try? decoder.decode(HistoryPoint.self, from: Data(lastLine.utf8)),
           snapshot.fetchedAt.timeIntervalSince(last.at) < historyMinSpacing {
            return
        }
        let point = HistoryPoint(at: snapshot.fetchedAt, fiveHour: snapshot.fiveHour?.usedPercent, weekly: snapshot.weekly?.usedPercent)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(point), let line = String(data: data, encoding: .utf8) else { return }
        var lines = existing.split(separator: "\n").map(String.init)
        lines.append(line)
        if lines.count > historyMaxRows { lines.removeFirst(lines.count - historyMaxRows) }
        existing = lines.joined(separator: "\n") + "\n"
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? AtomicFile.write(existing, to: file, permissions: 0o600)
    }
}
