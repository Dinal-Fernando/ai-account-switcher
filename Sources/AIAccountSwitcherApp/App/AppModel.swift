import AppKit
import Foundation
import Observation
import SwitcherCore
import SwitcherMac

enum ActiveState: Equatable {
    case notActive
    /// Selected in the state file, auth check pending.
    case selectedUnverified
    /// Selected and the vendor CLI confirmed a valid login: this is what `claude`/`codex` will use.
    case active
    /// Selected, but the profile is not signed in (CLI launches will prompt for login).
    case selectedNeedsLogin
    /// Selected, but the shell wrapper is not in effect, so Terminal ignores the selection.
    case selectedWrapperInactive
}

/// Main-actor view model. Every mutation of CLI state goes through `SwitcherRuntime`.
@MainActor
@Observable
final class AppModel {
    let runtime: SwitcherRuntime
    private(set) var accounts: [Account] = []
    private(set) var usage: [AccountKey: AccountUsageState] = [:]
    private(set) var activeIds: [Provider: String] = [:]
    private(set) var shellStatus = ShellIntegrationStatus()
    var settings: AppSettings {
        didSet {
            settings.save()
            scheduler.update(settings: settings.refresh)
            notificationEngine.thresholds = settings.thresholds
            if oldValue.refresh != settings.refresh { restartRefreshLoop() }
            if oldValue.showDockIcon != settings.showDockIcon { applyActivationPolicy() }
            if oldValue.terminalApp != settings.terminalApp { terminal.terminalApp = settings.terminalApp }
        }
    }
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var isOffline = false
    private(set) var busyKeys: Set<AccountKey> = []
    var errorMessage: String?
    var infoMessage: String?
    var showOnboarding = false
    private(set) var doctorReport: DoctorReport?
    private(set) var isRunningDoctor = false
    private(set) var recommendations: [Provider: SwitchRecommendation] = [:]
    /// Ticks every second for countdowns.
    private(set) var now = Date()
    private(set) var versions: [Provider: String] = [:]
    private(set) var loginWaiting: Set<AccountKey> = []

    private let scheduler: RefreshScheduler
    private let notificationEngine: NotificationDecisionEngine
    private var terminal: TerminalLauncher
    let notifications = NotificationManager()
    private var sleepObserver: SleepWakeObserver?
    private var networkMonitor: NetworkMonitor?
    private var refreshTask: Task<Void, Never>?
    private var ticker: Timer?
    private var started = false

    init(runtime: SwitcherRuntime) {
        self.runtime = runtime
        let settings = AppSettings.load()
        self.settings = settings
        self.scheduler = RefreshScheduler(settings: settings.refresh)
        self.notificationEngine = NotificationDecisionEngine(thresholds: settings.thresholds, fired: settings.firedNotifications)
        self.terminal = TerminalLauncher(paths: runtime.paths, profiles: runtime.profiles, terminalApp: settings.terminalApp)
    }

    // MARK: lifecycle

    func start() {
        guard !started else { return }
        started = true
        applyActivationPolicy()
        reloadAccounts()
        terminal.cleanup()
        notifications.onSwitchAction = { [weak self] key in
            Task { @MainActor in await self?.setActive(key: key) }
        }
        notifications.registerCategories()
        if settings.notificationsEnabled { notifications.requestAuthorization() }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        sleepObserver = SleepWakeObserver { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.refreshAll(force: false)
            }
        }
        networkMonitor = NetworkMonitor { [weak self] online in
            Task { @MainActor in await self?.setOnline(online) }
        }
        showOnboarding = !settings.onboardingCompleted
        Task { await self.bootstrap() }
    }

    private func bootstrap() async {
        await runtime.monitor.load(accounts: accounts)
        usage = await runtime.monitor.allStates()
        await probeShell()
        await verifyActiveAccounts()
        for p in Provider.allCases { versions[p] = await runtime.adapter(p).version() }
        restartRefreshLoop(immediately: true)
    }

    private func setOnline(_ online: Bool) async {
        let wasOffline = isOffline
        isOffline = !online
        await runtime.monitor.setOffline(!online)
        usage = await runtime.monitor.allStates()
        if wasOffline && online { await refreshAll(force: true) }
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
    }

    // MARK: accounts

    func reloadAccounts() {
        do {
            accounts = try runtime.accounts.load()
        } catch {
            errorMessage = "Could not read accounts.json: \(error.localizedDescription)"
        }
        for p in Provider.allCases { activeIds[p] = runtime.active.activeProfileId(for: p) }
    }

    func accounts(for provider: Provider) -> [Account] { runtime.accounts.accounts(for: provider) }

    func activeAccount(for provider: Provider) -> Account? { runtime.accounts.activeAccount(for: provider) }

    func usageState(_ account: Account) -> AccountUsageState { usage[account.key] ?? AccountUsageState() }

    var shellIntegrationActive: Bool { Provider.allCases.allSatisfy { shellStatus.isActive($0, paths: runtime.paths) } }

    func shellIntegrationActive(_ provider: Provider) -> Bool { shellStatus.isActive(provider, paths: runtime.paths) }

    func activeState(_ account: Account) -> ActiveState {
        guard activeIds[account.provider] == account.id else { return .notActive }
        if !shellIntegrationActive(account.provider) && shellStatus.loginShellProbed { return .selectedWrapperInactive }
        guard let auth = account.lastAuth else { return .selectedUnverified }
        switch auth.state {
        case .authenticated: return .active
        case .notAuthenticated, .expired: return .selectedNeedsLogin
        case .unknown, .error: return .selectedUnverified
        }
    }

    func isBusy(_ account: Account) -> Bool { busyKeys.contains(account.key) }

    func profilePath(_ account: Account) -> String { runtime.profiles.configDirectory(for: account).path }

    // MARK: switching (the whole point)

    func setActive(_ account: Account) async {
        busyKeys.insert(account.key)
        defer { busyKeys.remove(account.key) }
        do {
            let auth = try await runtime.setActive(account, verify: true)
            reloadAccounts()
            recommendations[account.provider] = nil
            if let auth, !auth.isAuthenticated {
                infoMessage = "'\(account.name)' is now selected for \(account.provider.displayName), but it is not signed in yet. Use Sign in on its card."
            } else {
                infoMessage = "\(account.provider.displayName) now uses '\(account.name)' for new terminal launches. Already-running sessions keep their account."
            }
            if !shellIntegrationActive(account.provider) && shellStatus.loginShellProbed {
                infoMessage = "'\(account.name)' is selected, but the shell wrapper is not active in your login shell, so Terminal still uses the default login. Install shell integration in Settings."
            }
        } catch {
            errorMessage = "Could not switch: \(error.localizedDescription)"
        }
    }

    func setActive(key: AccountKey) async {
        guard let account = runtime.accounts.account(key) else { return }
        await setActive(account)
    }

    func verify(_ account: Account) async {
        busyKeys.insert(account.key)
        defer { busyKeys.remove(account.key) }
        _ = await runtime.verify(account)
        reloadAccounts()
    }

    private func verifyActiveAccounts() async {
        for p in Provider.allCases {
            if let a = activeAccount(for: p) { await verify(a) }
        }
    }

    func addAccount(provider: Provider, name: String, copySettings: Bool, usageEnabled: Bool) throws -> Account {
        let seed = ProfileSeedOptions(copyClaudeUserSettings: copySettings, copyCodexConfig: copySettings)
        var account = try runtime.accounts.addManagedAccount(provider: provider, name: name, seed: seed)
        if !usageEnabled {
            account.usageSource = .disabled
            try runtime.accounts.update(account)
        }
        reloadAccounts()
        return account
    }

    /// Launches the vendor's browser login in Terminal and polls the profile until it is signed in.
    func startLogin(_ account: Account, deviceAuth: Bool = false) {
        guard let script = runtime.adapter(account.provider).loginScript(account: account, deviceAuth: deviceAuth) else {
            errorMessage = "\(account.provider.executableName) executable not found. Install \(account.provider.displayName) first."
            return
        }
        do {
            try terminal.runLogin(script: script, account: account)
        } catch {
            errorMessage = "Could not open Terminal: \(error.localizedDescription)"
            return
        }
        loginWaiting.insert(account.key)
        Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(10 * 60)
            while Date() < deadline, loginWaiting.contains(account.key) {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let auth = await runtime.verify(account)
                reloadAccounts()
                if auth.isAuthenticated {
                    loginWaiting.remove(account.key)
                    infoMessage = "'\(account.name)' is signed in\(runtime.accounts.account(account.key)?.identity?.email.map { " as \($0)" } ?? "")."
                    await refreshAll(force: true)
                    return
                }
            }
            loginWaiting.remove(account.key)
        }
    }

    func cancelLoginWait(_ account: Account) { loginWaiting.remove(account.key) }

    func rename(_ account: Account, to name: String) {
        do { try runtime.accounts.rename(account.key, to: name); reloadAccounts() } catch { errorMessage = error.localizedDescription }
    }

    /// Rename sheet: name plus the menu bar short label (empty = use initials).
    func update(_ account: Account, name: String, shortLabel: String?) {
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty, trimmedName != account.name { try runtime.accounts.rename(account.key, to: trimmedName) }
            if var current = runtime.accounts.account(account.key) {
                let label = (shortLabel ?? "").trimmingCharacters(in: .whitespaces)
                current.shortLabel = label.isEmpty ? nil : String(label.prefix(4))
                try runtime.accounts.update(current)
            }
            reloadAccounts()
        } catch { errorMessage = error.localizedDescription }
    }

    func remove(_ account: Account, deleteDirectory: Bool) async {
        do {
            try runtime.accounts.remove(account.key, deleteProfileDirectory: deleteDirectory)
            await runtime.monitor.remove(account.key)
            notificationEngine.forget(account.key)
            reloadAccounts()
            usage = await runtime.monitor.allStates()
        } catch { errorMessage = error.localizedDescription }
    }

    func setUsageSource(_ account: Account, _ source: UsageSource) async {
        var a = account
        a.usageSource = source
        do { try runtime.accounts.update(a); reloadAccounts(); await refreshAll(force: true) } catch { errorMessage = error.localizedDescription }
    }

    func openTerminal(_ account: Account) {
        do { try terminal.openShell(for: account, shellPath: runtime.loginEnvironment["SHELL"]) } catch { errorMessage = error.localizedDescription }
    }

    func revealProfile(_ account: Account) {
        NSWorkspace.shared.activateFileViewerSelecting([runtime.profiles.configDirectory(for: account)])
    }

    // MARK: shell integration

    func probeShell() async {
        let shell = runtime.shell
        let status = await Task.detached { shell.verify() }.value
        shellStatus = status
    }

    func installShellIntegration(addPathBlock: Bool) async {
        do {
            let options = ShellIntegrationOptions(rcFiles: runtime.shell.defaultRCFiles(), addPathBlock: addPathBlock)
            _ = try runtime.shell.install(options, searchPath: runtime.loginEnvironment["PATH"])
            await probeShell()
            infoMessage = "Shell integration installed. Open a new terminal window for it to take effect."
        } catch {
            errorMessage = "Shell integration failed: \(error.localizedDescription)"
        }
    }

    func uninstallShellIntegration(restoreBackups: Bool) async {
        do {
            try runtime.shell.uninstall(rcFiles: runtime.shell.defaultRCFiles(), restoreBackups: restoreBackups, purgeEverything: false)
            await probeShell()
            infoMessage = "Shell integration removed. New terminals use the plain claude / codex again."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func runDoctor() async {
        isRunningDoctor = true
        defer { isRunningDoctor = false }
        let doctor = runtime.doctor(probeShell: true, probeAuth: true)
        doctorReport = await doctor.run()
    }

    // MARK: usage refresh

    func restartRefreshLoop(immediately: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            if !immediately {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            while !Task.isCancelled {
                await self.refreshAll(force: false)
                let observed = await self.runtime.monitor.observedHeadlines()
                guard let interval = self.scheduler.intervalAfterRound(observed: observed) else { return }
                try? await Task.sleep(nanoseconds: UInt64(max(10, interval)) * 1_000_000_000)
            }
        }
    }

    /// Popover opened: return to the fastest smart cadence and refresh (debounce-free, backoff still applies).
    func menuBarOpened() async {
        scheduler.activate()
        await refreshAll(force: false)
    }

    func manualRefresh() async {
        guard scheduler.requestManualRefresh() else { return }
        await refreshAll(force: true)
        restartRefreshLoop()
    }

    func refreshAll(force: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        scheduler.noteRefreshStarted()
        let list = accounts
        let states = await runtime.monitor.refreshAll(list, force: force)
        usage = states
        lastRefresh = Date()
        evaluateNotifications(states)
        await evaluateAutomaticSwitching(states)
    }

    private func evaluateNotifications(_ states: [AccountKey: AccountUsageState]) {
        let snapshots = states.compactMapValues { $0.effectiveSnapshot }
        for account in accounts {
            guard let snap = snapshots[account.key] else { continue }
            let alerts = notificationEngine.evaluate(snapshot: snap, accountName: account.name)
            guard !alerts.isEmpty else { continue }
            var recommendation: SwitchRecommendation?
            if activeIds[account.provider] == account.id {
                recommendation = RecommendationEngine.bestAlternative(provider: account.provider, active: account, accounts: accounts, usage: snapshots)
                recommendations[account.provider] = recommendation
            }
            if settings.notificationsEnabled {
                for alert in alerts { notifications.post(alert: alert, recommendation: recommendation) }
            }
        }
        if settings.firedNotifications != notificationEngine.fired { settings.firedNotifications = notificationEngine.fired }
    }

    private func evaluateAutomaticSwitching(_ states: [AccountKey: AccountUsageState]) async {
        let snapshots = states.compactMapValues { $0.effectiveSnapshot }
        for p in Provider.allCases where settings.autoSwitchEnabled(p) {
            guard let active = activeAccount(for: p),
                  let rec = RecommendationEngine.automaticSwitch(provider: p, active: active, accounts: accounts, usage: snapshots, threshold: settings.autoSwitchThreshold),
                  let target = runtime.accounts.account(rec.to) else { continue }
            await setActive(target)
            notifications.postInfo(title: "\(p.displayName): switched to \(target.name)", body: "\(rec.reason) New terminal launches use \(target.name); running sessions are untouched.")
        }
    }

    func applyRecommendation(_ rec: SwitchRecommendation) async {
        await setActive(key: rec.to)
    }

    func history(_ account: Account) -> [UsageCache.HistoryPoint] { runtime.cache.history(account.key) }

    /// "Refresh now" on a paused card: ask the vendor CLI to renew the token, then fetch usage again.
    func refreshCredential(_ account: Account) async {
        busyKeys.insert(account.key)
        defer { busyKeys.remove(account.key) }
        var renewed = true
        if account.provider == .claude, let claude = runtime.adapters[.claude] as? ClaudeProvider {
            renewed = await claude.refreshCredential(account: account)
        }
        if renewed {
            _ = await runtime.monitor.refresh(account, force: true)
            usage = await runtime.monitor.allStates()
            if case .paused = usageState(account).status { renewed = false }
        }
        if !renewed {
            infoMessage = "'\(account.name)' still has a lapsed token. Use the account once (Open Terminal, run \(account.provider.executableName), then quit) and the reading resumes by itself."
        }
    }

    // MARK: sessions

    func sessions(_ account: Account) async -> [CLISession] {
        let runtime = runtime
        return await Task.detached { runtime.sessions(for: account) }.value
    }

    func findSession(id: String, provider: Provider) async -> CLISession? {
        let runtime = runtime
        return await Task.detached { runtime.findSession(id: id, provider: provider) }.value
    }

    /// Copies one transcript into `target`'s profile (overwrites an identical id there). Returns the copy.
    func duplicateSession(_ session: CLISession, to target: Account) async -> CLISession? {
        do {
            let copy = try runtime.duplicate(session, to: target, overwrite: true)
            infoMessage = "Copied session \(session.id.prefix(8))… into '\(target.name)'. Resume it from that account's Sessions list or the prompt that just appeared."
            return copy
        } catch {
            errorMessage = "Could not copy the session: \(error.localizedDescription)"
            return nil
        }
    }

    func resumeSession(_ session: CLISession, in account: Account) {
        do { try runtime.resume(session, in: account) } catch { errorMessage = "Could not open Terminal: \(error.localizedDescription)" }
    }

    func completeOnboarding() {
        settings.onboardingCompleted = true
        showOnboarding = false
    }

    // MARK: menu bar

    /// The percentage the menu bar shows for a reading: weekly by default, 5-hour on request, with fallback.
    func menuBarPercent(_ snapshot: UsageSnapshot?) -> Double? {
        guard let snapshot else { return nil }
        switch settings.menuBarWindow {
        case .weekly: return snapshot.weekly?.usedPercent ?? snapshot.fiveHour?.usedPercent
        case .fiveHour: return snapshot.fiveHour?.usedPercent ?? snapshot.weekly?.usedPercent
        }
    }

    /// One segment per account that has a reading or is active, Claude first then Codex.
    var menuBarSegments: [MenuBarSegment] {
        var out: [MenuBarSegment] = []
        for provider in Provider.allCases {
            for account in accounts(for: provider) {
                let isActive = activeIds[provider] == account.id
                let percent = menuBarPercent(usageState(account).effectiveSnapshot)
                if percent == nil && !isActive { continue }
                out.append(MenuBarSegment(label: account.displayShortLabel, percent: percent, isActive: isActive, provider: provider))
            }
        }
        return out
    }

    var menuBarIcon: NSImage {
        switch settings.menuBarMode {
        case .allAccounts:
            return MenuBarIconRenderer.image(segments: menuBarSegments, compact: settings.menuBarCompact, showRings: settings.menuBarShowRings)
        case .activeOnly:
            let claude = activeAccount(for: .claude).flatMap { menuBarPercent(usageState($0).effectiveSnapshot) }
            let codex = activeAccount(for: .codex).flatMap { menuBarPercent(usageState($0).effectiveSnapshot) }
            return MenuBarIconRenderer.image(claudePercent: claude, codexPercent: codex)
        }
    }

    var menuBarText: String? {
        guard settings.menuBarMode == .activeOnly, settings.menuBarShowsPercent,
              let a = activeAccount(for: .claude), let p = menuBarPercent(usageState(a).effectiveSnapshot) else { return nil }
        return "\(Int(p.rounded()))%"
    }
}
