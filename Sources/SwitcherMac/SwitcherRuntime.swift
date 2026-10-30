import Foundation
import SwitcherCore

/// Composition root shared by the app and the `aiswitch` CLI: builds paths, managers, adapters and the monitor.
public final class SwitcherRuntime: @unchecked Sendable {
    public static let version = "1.0.0"

    public let paths: SwitcherPaths
    public let accounts: AccountManager
    public let profiles: CLIProfileManager
    public let active: ActiveAccountManager
    public let shell: ShellIntegrationManager
    public let context: ProviderContext
    public let adapters: [Provider: ProviderAdapter]
    public let cache: UsageCache
    public let monitor: UsageMonitor
    public let terminal: TerminalLauncher
    public let secureStorage: SecureStorage
    /// Login-shell environment captured at start (GUI apps do not inherit the user's PATH).
    public let loginEnvironment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, captureLoginShell: Bool = true,
                runner: ProcessRunning = ProcessRunner(), http: HTTPClient = URLSessionHTTPClient(), time: TimeSource = SystemTimeSource()) {
        let paths = SwitcherPaths(environment: environment)
        try? paths.ensureLayout()
        SwitcherLog.shared.configure(fileURL: paths.logFile)
        self.paths = paths

        var base = environment
        var loginEnv: [String: String] = [:]
        if captureLoginShell {
            loginEnv = LoginShell(environment: environment, runner: runner).environment(timeout: 6)
            if let path = loginEnv["PATH"], !path.isEmpty {
                let current = environment["PATH"] ?? ""
                base["PATH"] = current.isEmpty ? path : path + ":" + current
            }
        }
        self.loginEnvironment = loginEnv

        let profiles = CLIProfileManager(paths: paths)
        let shell = ShellIntegrationManager(paths: paths, runner: runner, environment: base)
        let context = ProviderContext(paths: paths, profiles: profiles, shell: shell, runner: runner, http: http, time: time,
                                      baseEnvironment: base, userAgent: "AIAccountSwitcher/\(Self.version) (macOS)")
        self.profiles = profiles
        self.shell = shell
        self.context = context
        self.active = ActiveAccountManager(paths: paths)
        self.accounts = AccountManager(paths: paths, profiles: profiles, active: active)
        self.adapters = [.claude: ClaudeProvider(context: context), .codex: CodexProvider(context: context)]
        self.cache = UsageCache(paths: paths)
        self.monitor = UsageMonitor(adapters: adapters, cache: cache, time: time)
        self.terminal = TerminalLauncher(paths: paths, profiles: profiles)
        self.secureStorage = SecureStorage()
        _ = try? accounts.load()
    }

    public func adapter(_ provider: Provider) -> ProviderAdapter { adapters[provider]! }

    public func doctor(probeShell: Bool = true, probeAuth: Bool = true) -> Doctor {
        Doctor(context: context, accounts: accounts, adapters: adapters, probeShell: probeShell, probeAuth: probeAuth)
    }

    /// The one operation that changes what `claude`/`codex` do next: atomic state write, then an auth check.
    @discardableResult
    public func setActive(_ account: Account, verify: Bool = true) async throws -> AuthStatus? {
        try active.setActive(provider: account.provider, profileId: account.id)
        guard verify else { return nil }
        let auth = await adapter(account.provider).checkAuth(account: account)
        let identity = adapter(account.provider).identity(account: account)
        try? accounts.setIdentity(identity, auth: auth, for: account.key)
        return auth
    }

    /// Re-checks a profile with the vendor CLI and stores identity + status.
    @discardableResult
    public func verify(_ account: Account) async -> AuthStatus {
        let adapter = adapter(account.provider)
        let auth = await adapter.checkAuth(account: account)
        var identity = adapter.identity(account: account)
        if identity == nil, account.provider == .claude, auth.isAuthenticated,
           let exe = adapter.executablePath(),
           let r = try? await context.runner.runAsync(exe, arguments: ["auth", "status"], environment: context.cliEnvironment(for: account), timeout: 60),
           let parsed = ClaudeAuthStatusParser.parse(r.stdout) {
            identity = ClaudeAuthStatusParser.identity(from: parsed)
        }
        try? accounts.setIdentity(identity, auth: auth, for: account.key)
        return auth
    }
}
