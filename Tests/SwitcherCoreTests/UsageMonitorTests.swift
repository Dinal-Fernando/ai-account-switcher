import XCTest
@testable import SwitcherCore

final class UsageMonitorTests: XCTestCase {
    private func makeContext(_ env: TempEnvironment) -> ProviderContext {
        ProviderContext(paths: env.paths, runner: FakeProcessRunner(), http: FakeHTTPClient(), baseEnvironment: ["HOME": env.home.path, "PATH": "/usr/bin:/bin"])
    }

    func testOneFailingAccountDoesNotBlockOthers() async {
        let env = TempEnvironment()
        let ctx = makeContext(env)
        let clock = FixedTimeSource()
        let claude = StubAdapter(provider: .claude, context: ctx) { account in
            if account.id == "bad" { throw UsageFetchError.serverError(500) }
            return sampleSnapshot(id: account.id, five: 33, weekly: 44, at: clock.now)
        }
        let codex = StubAdapter(provider: .codex, context: ctx) { account in
            throw UsageFetchError.rateLimited(retryAfter: 120)
        }
        let monitor = UsageMonitor(adapters: [.claude: claude, .codex: codex], cache: UsageCache(paths: env.paths), time: clock)
        let good = Account(id: "good", provider: .claude, name: "Good", kind: .managed)
        let bad = Account(id: "bad", provider: .claude, name: "Bad", kind: .managed)
        let cx = Account(id: "cx", provider: .codex, name: "Codex", kind: .managed)
        let states = await monitor.refreshAll([good, bad, cx], force: true)
        XCTAssertEqual(states[good.key]?.snapshot?.fiveHour?.usedPercent, 33)
        if case .fresh = states[good.key]!.status {} else { XCTFail("good should be fresh") }
        if case .error = states[bad.key]!.status {} else { XCTFail("bad should be error, got \(states[bad.key]!.status)") }
        if case .rateLimited(let until) = states[cx.key]!.status {
            XCTAssertGreaterThanOrEqual(until.timeIntervalSince(clock.now), 120)
        } else { XCTFail("codex should be rate limited") }
        XCTAssertEqual(states[bad.key]?.backoff.consecutiveFailures, 1)
        // cached on disk for next launch
        XCTAssertNotNil(UsageCache(paths: env.paths).loadSnapshot(good.key))
    }

    func testBackoffAndMinimumIntervalAreRespectedUnlessForced() async {
        let env = TempEnvironment()
        let ctx = makeContext(env)
        let clock = FixedTimeSource()
        let counter = Counter()
        let claude = StubAdapter(provider: .claude, context: ctx) { account in
            await counter.increment()
            throw UsageFetchError.serverError(503)
        }
        let monitor = UsageMonitor(adapters: [.claude: claude], cache: UsageCache(paths: env.paths), time: clock, minimumInterval: 60)
        let a = Account(id: "a", provider: .claude, name: "A", kind: .managed)
        _ = await monitor.refresh(a, force: true)
        _ = await monitor.refresh(a, force: false)
        var calls = await counter.value
        XCTAssertEqual(calls, 1, "blocked by backoff")
        _ = await monitor.refresh(a, force: true)
        calls = await counter.value
        XCTAssertEqual(calls, 2, "force bypasses backoff")
        clock.advance(10_000)
        _ = await monitor.refresh(a, force: false)
        calls = await counter.value
        XCTAssertEqual(calls, 3)
    }

    func testCachedReadingIsStaleAfterRestartAndOfflineKeepsIt() async {
        let env = TempEnvironment()
        let ctx = makeContext(env)
        let cache = UsageCache(paths: env.paths)
        let a = Account(id: "a", provider: .claude, name: "A", kind: .managed)
        // Whole seconds: the on-disk cache uses ISO-8601 without fractional seconds, and the test compares dates exactly.
        let old = sampleSnapshot(id: "a", five: 70, weekly: 10, at: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded(.down)))
        cache.saveSnapshot(old)
        let claude = StubAdapter(provider: .claude, context: ctx) { _ in throw UsageFetchError.network("down") }
        let monitor = UsageMonitor(adapters: [.claude: claude], cache: cache)
        await monitor.load(accounts: [a])
        let seeded = await monitor.state(for: a.key)
        XCTAssertEqual(seeded.snapshot?.fiveHour?.usedPercent, 70)
        if case .stale = seeded.status {} else { XCTFail("seeded reading must be stale") }
        await monitor.setOffline(true)
        let off = await monitor.refresh(a, force: true)
        if case .offline(let last) = off.status { XCTAssertEqual(last, old.fetchedAt) } else { XCTFail("offline") }
        XCTAssertEqual(off.snapshot?.fiveHour?.usedPercent, 70, "cached value kept")
        await monitor.setOffline(false)
        let failed = await monitor.refresh(a, force: true)
        if case .stale(_, let reason) = failed.status { XCTAssertTrue(reason.contains("Network")) } else { XCTFail("network failure with cache → stale") }
    }

    func testSessionExpiredAndDisabled() async {
        let env = TempEnvironment()
        let ctx = makeContext(env)
        let claude = StubAdapter(provider: .claude, context: ctx) { _ in throw UsageFetchError.unauthorized("401") }
        let monitor = UsageMonitor(adapters: [.claude: claude], cache: UsageCache(paths: env.paths))
        let a = Account(id: "a", provider: .claude, name: "A", kind: .managed)
        let s = await monitor.refresh(a, force: true)
        if case .sessionExpired = s.status {} else { XCTFail("expected sessionExpired") }
        var d = a; d.usageSource = .disabled
        let s2 = await monitor.refresh(d, force: true)
        XCTAssertEqual(s2.status, .disabled)
        let headlines = await monitor.observedHeadlines()
        XCTAssertTrue(headlines.isEmpty)
    }

    func testLapsedTokenPausesButKeepsTheLastReading() async {
        let env = TempEnvironment()
        let ctx = makeContext(env)
        let cache = UsageCache(paths: env.paths)
        let a = Account(id: "a", provider: .claude, name: "A", kind: .managed)
        let old = sampleSnapshot(id: "a", five: 40, weekly: 10, at: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 7200).rounded(.down)))
        cache.saveSnapshot(old)
        let clock = FixedTimeSource()
        let claude = StubAdapter(provider: .claude, context: ctx) { _ in throw UsageFetchError.credentialExpired("lapsed") }
        let monitor = UsageMonitor(adapters: [.claude: claude], cache: cache, time: clock)
        await monitor.load(accounts: [a])
        let s = await monitor.refresh(a, force: true)
        if case .paused(let at, let reason) = s.status {
            XCTAssertEqual(at, old.fetchedAt)
            XCTAssertEqual(reason, "lapsed")
        } else { XCTFail("expected paused, got \(s.status)") }
        XCTAssertEqual(s.snapshot?.fiveHour?.usedPercent, 40, "last reading is kept")
        XCTAssertEqual(s.status.shortLabel, "Usage paused")
        XCTAssertTrue(s.status.isProblem)
        let wait = s.backoff.notBefore!.timeIntervalSince(clock.now)
        XCTAssertGreaterThanOrEqual(wait, 300)
        XCTAssertLessThanOrEqual(wait, 360, "short, fixed re-check interval for lapsed tokens")
    }

    func testReloadBeaconsPicksUpStatusLineReadingWithoutNetwork() async throws {
        let env = TempEnvironment()
        let ctx = makeContext(env)
        let monitor = UsageMonitor(adapters: [.claude: ClaudeProvider(context: ctx)], cache: UsageCache(paths: env.paths))
        let a = Account(id: "a", provider: .claude, name: "A", kind: .managed)
        await monitor.load(accounts: [a])
        let before = await monitor.state(for: a.key)
        XCTAssertNil(before.effectiveSnapshot)
        let json = "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":77,\"resets_at\":1900000000},\"seven_day\":{\"used_percentage\":12}}}"
        try AtomicFile.write(json, to: env.paths.statusLineBeaconFile(profileId: "a"))
        await monitor.reloadBeacons([a])
        let after = await monitor.state(for: a.key)
        XCTAssertEqual(after.effectiveSnapshot?.fiveHour?.usedPercent, 77)
        XCTAssertEqual(after.effectiveSnapshot?.weekly?.usedPercent, 12)
        XCTAssertEqual(after.effectiveSnapshot?.source, "statusline-beacon")
        XCTAssertEqual(after.effectiveSnapshot?.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_900_000_000))
    }

    func testHistoryAppendsWithSpacing() {
        let env = TempEnvironment()
        let cache = UsageCache(paths: env.paths)
        cache.historyMinSpacing = 60
        let key = AccountKey(.claude, "h")
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        cache.saveSnapshot(sampleSnapshot(id: "h", five: 1, weekly: 2, at: t0))
        cache.saveSnapshot(sampleSnapshot(id: "h", five: 2, weekly: 2, at: t0.addingTimeInterval(10)))
        cache.saveSnapshot(sampleSnapshot(id: "h", five: 3, weekly: 2, at: t0.addingTimeInterval(120)))
        let points = cache.history(key)
        XCTAssertEqual(points.map { $0.fiveHour ?? -1 }, [1, 3])
        XCTAssertEqual(posixMode(env.paths.historyFile(key).path), 0o600)
        cache.removeSnapshot(key)
        XCTAssertTrue(cache.history(key).isEmpty)
    }
}

actor Counter {
    var value = 0
    func increment() { value += 1 }
}
