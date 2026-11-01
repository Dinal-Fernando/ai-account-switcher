import XCTest
@testable import SwitcherCore

final class SchedulingAndNotificationTests: XCTestCase {
    func testBackoffGrowsCapsAndHonoursRetryAfter() {
        let p = BackoffPolicy()
        XCTAssertEqual(p.delay(afterConsecutiveFailures: 1, kind: .server, random: 0), 60)
        XCTAssertEqual(p.delay(afterConsecutiveFailures: 2, kind: .server, random: 0), 120)
        XCTAssertEqual(p.delay(afterConsecutiveFailures: 10, kind: .server, random: 0), 1800, "capped at 30 min")
        XCTAssertEqual(p.delay(afterConsecutiveFailures: 10, kind: .network, random: 0), 300, "network cap 5 min")
        XCTAssertEqual(p.delay(afterConsecutiveFailures: 1, kind: .rateLimited(retryAfter: 900), random: 0), 900)
        XCTAssertEqual(p.delay(afterConsecutiveFailures: 1, kind: .rateLimited(retryAfter: 99_999), random: 0), 3600, "Retry-After capped at 1 h")
        XCTAssertEqual(p.delay(afterConsecutiveFailures: 1, kind: .server, random: 1), 72, "20% jitter max")
        XCTAssertEqual(p.delay(afterConsecutiveFailures: 1, kind: .auth, random: 0), 600)
        XCTAssertEqual(p.delay(afterConsecutiveFailures: 7, kind: .paused, random: 0), 300, "paused never grows")
        var s = BackoffState()
        let now = Date()
        s.recordFailure(.server, policy: p, now: now)
        XCTAssertTrue(s.isBlocked(now: now.addingTimeInterval(30)))
        XCTAssertFalse(s.isBlocked(now: now.addingTimeInterval(80)))
        s.reset()
        XCTAssertFalse(s.isBlocked(now: now))
    }

    func testSmartRefreshDemotesAndReactivates() {
        let policy = SmartRefreshPolicy()
        var state = SmartRefreshPolicy.State()
        let k = AccountKey(.claude, "a")
        XCTAssertEqual(policy.next(state: &state, observed: [k: 10]), 60)
        for _ in 0..<3 { _ = policy.next(state: &state, observed: [k: 10]) }
        XCTAssertEqual(state.interval, 180, "3 unchanged rounds → 180 s")
        for _ in 0..<6 { _ = policy.next(state: &state, observed: [k: 10]) }
        XCTAssertEqual(state.interval, 300)
        for _ in 0..<12 { _ = policy.next(state: &state, observed: [k: 10]) }
        XCTAssertEqual(state.interval, 600)
        XCTAssertEqual(policy.next(state: &state, observed: [k: 11]), 60, "a change resets to the fastest level")
        for _ in 0..<3 { _ = policy.next(state: &state, observed: [k: 11]) }
        policy.activate(state: &state)
        XCTAssertEqual(state.interval, 60)
    }

    func testSchedulerModesAndManualDebounce() {
        let clock = FixedTimeSource()
        var settings = RefreshSettings()
        settings.mode = .fixed
        settings.fixedInterval = 30
        let s = RefreshScheduler(settings: settings, time: clock)
        XCTAssertEqual(s.intervalAfterRound(observed: [:]), 60, "floor of 60 s enforced")
        settings.mode = .manual
        s.update(settings: settings)
        XCTAssertNil(s.intervalAfterRound(observed: [:]))
        XCTAssertTrue(s.requestManualRefresh())
        XCTAssertFalse(s.requestManualRefresh(), "debounced")
        clock.advance(11)
        XCTAssertTrue(s.requestManualRefresh())
    }

    func testNotificationsFireOncePerCycleAndRearmAfterReset() {
        let engine = NotificationDecisionEngine()
        let key = AccountKey(.claude, "a")
        let reset1 = Date(timeIntervalSince1970: 1_000)
        let snap = { (five: Double, reset: Date) in
            UsageSnapshot(provider: .claude, accountId: "a", fetchedAt: Date(),
                          fiveHour: UsageWindow(kind: .fiveHour, label: "5-hour", usedPercent: five, resetsAt: reset, windowSeconds: 18000),
                          weekly: UsageWindow(kind: .weekly, label: "Weekly", usedPercent: 10, resetsAt: reset, windowSeconds: 604800), source: "t")
        }
        XCTAssertTrue(engine.evaluate(snapshot: snap(50, reset1), accountName: "Personal").isEmpty)
        let first = engine.evaluate(snapshot: snap(91, reset1), accountName: "Personal")
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].threshold, 90)
        XCTAssertTrue(first[0].body.contains("Personal has used 91%"))
        XCTAssertTrue(engine.evaluate(snapshot: snap(95, reset1), accountName: "Personal").isEmpty, "no repeat within the cycle")
        let reset2 = Date(timeIntervalSince1970: 20_000)
        XCTAssertTrue(engine.evaluate(snapshot: snap(5, reset2), accountName: "Personal").isEmpty)
        XCTAssertEqual(engine.evaluate(snapshot: snap(92, reset2), accountName: "Personal").count, 1, "re-armed after the window reset")
        XCTAssertEqual(engine.fired.count, 1)
        engine.forget(key)
        XCTAssertTrue(engine.fired.isEmpty)
        // weekly has two thresholds: crossing both at once yields one alert for the highest
        let weeklyHeavy = UsageSnapshot(provider: .claude, accountId: "a", fetchedAt: Date(), fiveHour: nil,
                                        weekly: UsageWindow(kind: .weekly, label: "Weekly", usedPercent: 96, resetsAt: reset1, windowSeconds: 604800), source: "t")
        let alerts = engine.evaluate(snapshot: weeklyHeavy, accountName: "P")
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].threshold, 90)
        XCTAssertEqual(engine.fired.count, 2, "both 75 and 90 recorded")
        engine.thresholds.enabled = false
        XCTAssertTrue(engine.evaluate(snapshot: snap(99, Date(timeIntervalSince1970: 99_999)), accountName: "P").isEmpty)
    }

    func testRecommendationPicksBestSignedInAlternative() {
        let active = Account(id: "personal", provider: .claude, name: "Personal", kind: .managed, lastAuth: AuthStatus(state: .authenticated))
        let work = Account(id: "work", provider: .claude, name: "Work", kind: .managed, lastAuth: AuthStatus(state: .authenticated))
        let dead = Account(id: "dead", provider: .claude, name: "Dead", kind: .managed, lastAuth: AuthStatus(state: .notAuthenticated))
        let codex = Account(id: "cx", provider: .codex, name: "Codex", kind: .managed, lastAuth: AuthStatus(state: .authenticated))
        let usage: [AccountKey: UsageSnapshot] = [
            active.key: sampleSnapshot(id: "personal", five: 92, weekly: 40),
            work.key: sampleSnapshot(id: "work", five: 20, weekly: 30),
            dead.key: sampleSnapshot(id: "dead", five: 0, weekly: 0),
            codex.key: sampleSnapshot(.codex, id: "cx", five: 0, weekly: 0),
        ]
        let rec = RecommendationEngine.bestAlternative(provider: .claude, active: active, accounts: [active, work, dead, codex], usage: usage)!
        XCTAssertEqual(rec.to, work.key, "unauthenticated and other-provider accounts are ignored")
        XCTAssertEqual(rec.toRemaining, 70)
        XCTAssertNil(RecommendationEngine.bestAlternative(provider: .claude, active: active, accounts: [active, work], usage: [active.key: sampleSnapshot(five: 50), work.key: sampleSnapshot(id: "work", five: 45)]), "needs a material advantage")
        XCTAssertNil(RecommendationEngine.automaticSwitch(provider: .claude, active: active, accounts: [active, work], usage: usage, threshold: 95), "92% is below the 95% auto threshold")
        XCTAssertNotNil(RecommendationEngine.automaticSwitch(provider: .claude, active: active, accounts: [active, work], usage: usage, threshold: 90))
    }
}
