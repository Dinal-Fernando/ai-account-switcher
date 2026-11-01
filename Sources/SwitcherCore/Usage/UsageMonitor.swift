import Foundation

public struct AccountUsageState: Equatable, Sendable {
    public var snapshot: UsageSnapshot?
    /// Latest values Claude Code itself observed (status-line beacon), independent of the API.
    public var beacon: UsageSnapshot?
    public var status: SyncStatus = .never
    public var backoff = BackoffState()
    public var lastAttempt: Date?

    public init() {}

    /// Whichever reading is newest.
    public var effectiveSnapshot: UsageSnapshot? {
        switch (snapshot, beacon) {
        case (let a?, let b?): return a.fetchedAt >= b.fetchedAt ? a : b
        case (let a?, nil): return a
        case (nil, let b?): return b
        default: return nil
        }
    }
}

/// Fetches usage for every account independently. A failing account never blocks the others; failures
/// feed per-account backoff; cached readings survive restarts and are shown as stale.
public actor UsageMonitor {
    private var states: [AccountKey: AccountUsageState] = [:]
    private let adapters: [Provider: ProviderAdapter]
    private let cache: UsageCache
    private let time: TimeSource
    private let policy: BackoffPolicy
    private let minimumInterval: TimeInterval
    private var offline = false
    private var inFlight: Set<AccountKey> = []

    public init(adapters: [Provider: ProviderAdapter], cache: UsageCache, time: TimeSource = SystemTimeSource(),
                policy: BackoffPolicy = BackoffPolicy(), minimumInterval: TimeInterval = 60) {
        self.adapters = adapters
        self.cache = cache
        self.time = time
        self.policy = policy
        self.minimumInterval = minimumInterval
    }

    public func state(for key: AccountKey) -> AccountUsageState { states[key] ?? AccountUsageState() }
    public func allStates() -> [AccountKey: AccountUsageState] { states }

    /// Seeds from the on-disk cache so the UI has numbers immediately (marked stale).
    public func load(accounts: [Account]) {
        for account in accounts {
            var s = states[account.key] ?? AccountUsageState()
            if s.snapshot == nil, let cached = cache.loadSnapshot(account.key) {
                s.snapshot = cached
                s.status = .stale(at: cached.fetchedAt, reason: "Cached reading from a previous run")
            }
            if account.usageSource == .disabled { s.status = .disabled }
            refreshBeacon(account, into: &s)
            states[account.key] = s
        }
    }

    /// Re-reads the status-line beacon files only (no network). The app calls this from a file watcher so a
    /// card updates within a second of Claude Code reporting new numbers.
    public func reloadBeacons(_ accounts: [Account]) {
        for account in accounts where account.provider == .claude {
            var s = states[account.key] ?? AccountUsageState()
            refreshBeacon(account, into: &s)
            states[account.key] = s
        }
    }

    public func remove(_ key: AccountKey) {
        states.removeValue(forKey: key)
        cache.removeSnapshot(key)
    }

    public func setOffline(_ value: Bool) {
        offline = value
        if value {
            for (k, var s) in states where s.status != .disabled {
                s.status = .offline(lastSuccess: s.snapshot?.fetchedAt)
                states[k] = s
            }
        }
    }

    private func refreshBeacon(_ account: Account, into s: inout AccountUsageState) {
        guard account.provider == .claude, let claude = adapters[.claude] as? ClaudeProvider else { return }
        if let beacon = claude.beaconSnapshot(account: account) { s.beacon = beacon }
    }

    @discardableResult
    public func refresh(_ account: Account, force: Bool = false) async -> AccountUsageState {
        let key = account.key
        var s = states[key] ?? AccountUsageState()
        refreshBeacon(account, into: &s)
        let now = time.now
        guard let adapter = adapters[account.provider] else { return s }
        if account.usageSource == .disabled {
            s.status = .disabled
            states[key] = s
            return s
        }
        if offline {
            s.status = .offline(lastSuccess: s.snapshot?.fetchedAt)
            states[key] = s
            return s
        }
        if inFlight.contains(key) { return s }
        if !force {
            if s.backoff.isBlocked(now: now) { states[key] = s; return s }
            if let last = s.lastAttempt, now.timeIntervalSince(last) < minimumInterval { states[key] = s; return s }
        }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        s.status = .refreshing
        s.lastAttempt = now
        states[key] = s
        do {
            let snapshot = try await adapter.fetchUsage(account: account)
            s.snapshot = snapshot
            s.status = .fresh(at: snapshot.fetchedAt)
            s.backoff.reset()
            cache.saveSnapshot(snapshot)
        } catch let error as UsageFetchError {
            apply(error: error, to: &s, now: time.now)
        } catch {
            s.status = s.snapshot.map { .stale(at: $0.fetchedAt, reason: error.localizedDescription) } ?? .error(error.localizedDescription)
            s.backoff.recordFailure(.server, policy: policy, now: time.now)
        }
        states[key] = s
        return s
    }

    private func apply(error: UsageFetchError, to s: inout AccountUsageState, now: Date) {
        let cachedAt = s.snapshot?.fetchedAt
        let staleOrError: (String) -> SyncStatus = { reason in
            cachedAt.map { .stale(at: $0, reason: reason) } ?? .error(reason)
        }
        switch error {
        case .disabled:
            s.status = .disabled
        case .rateLimited(let retryAfter):
            s.backoff.recordFailure(.rateLimited(retryAfter: retryAfter), policy: policy, now: now)
            s.status = .rateLimited(until: s.backoff.notBefore ?? now.addingTimeInterval(60))
        case .credentialExpired(let m):
            s.backoff.recordFailure(.paused, policy: policy, now: now)
            s.status = .paused(at: cachedAt, reason: m)
        case .unauthorized(let m), .noCredential(let m):
            s.backoff.recordFailure(.auth, policy: policy, now: now)
            s.status = .sessionExpired(m)
        case .network(let m):
            s.backoff.recordFailure(.network, policy: policy, now: now)
            s.status = staleOrError("Network error: \(m)")
        case .serverError, .blocked, .decoding:
            s.backoff.recordFailure(.server, policy: policy, now: now)
            s.status = staleOrError(error.localizedDescription)
        case .unsupported(let m):
            s.backoff.recordFailure(.auth, policy: policy, now: now)
            s.status = .error(m)
        }
        SwitcherLog.shared.log("usage fetch failed: \(error.localizedDescription)", category: "usage")
    }

    /// Refreshes all accounts concurrently; each account's failure is isolated.
    @discardableResult
    public func refreshAll(_ accounts: [Account], force: Bool = false) async -> [AccountKey: AccountUsageState] {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { [self] in _ = await self.refresh(account, force: force) }
            }
            await group.waitForAll()
        }
        return states
    }

    /// Headline numbers for the adaptive scheduler.
    public func observedHeadlines() -> [AccountKey: Double] {
        var out: [AccountKey: Double] = [:]
        for (k, s) in states { if let p = s.effectiveSnapshot?.primaryPercent { out[k] = p } }
        return out
    }
}
