import Foundation

public enum UsageFetchError: Error, LocalizedError, Equatable {
    case disabled
    case noCredential(String)
    case credentialExpired(String)
    case unauthorized(String)
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(Int)
    case blocked(String)
    case network(String)
    case decoding(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .disabled: return "Usage monitoring is disabled for this account"
        case .noCredential(let m): return m
        case .credentialExpired(let m): return m
        case .unauthorized(let m): return m
        case .rateLimited(let r): return r.map { "Rate limited by the provider (retry after \(Int($0)) s)" } ?? "Rate limited by the provider"
        case .serverError(let s): return "Provider returned HTTP \(s)"
        case .blocked(let m): return m
        case .network(let m): return m
        case .decoding(let m): return m
        case .unsupported(let m): return m
        }
    }
}

/// Everything an adapter needs; built once by the app / CLI.
public struct ProviderContext: Sendable {
    public var paths: SwitcherPaths
    public var profiles: CLIProfileManager
    public var shell: ShellIntegrationManager
    public var runner: ProcessRunning
    public var http: HTTPClient
    public var time: TimeSource
    /// Environment used to launch the CLIs (typically the login-shell environment captured at startup).
    public var baseEnvironment: [String: String]
    public var userAgent: String

    public init(paths: SwitcherPaths, profiles: CLIProfileManager? = nil, shell: ShellIntegrationManager? = nil,
                runner: ProcessRunning = ProcessRunner(), http: HTTPClient = URLSessionHTTPClient(), time: TimeSource = SystemTimeSource(),
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment, userAgent: String = "AIAccountSwitcher/1.0") {
        self.paths = paths
        self.profiles = profiles ?? CLIProfileManager(paths: paths)
        self.shell = shell ?? ShellIntegrationManager(paths: paths, runner: runner, environment: baseEnvironment)
        self.runner = runner
        self.http = http
        self.time = time
        self.baseEnvironment = baseEnvironment
        self.userAgent = userAgent
    }

    /// Environment for running the provider CLI *as a given account*: the base environment with credential
    /// override variables removed, the profile's config-dir variable set, and auto-update noise disabled.
    public func cliEnvironment(for account: Account) -> [String: String] {
        var env = baseEnvironment
        for v in account.provider.credentialOverrideEnvVars { env.removeValue(forKey: v) }
        env.removeValue(forKey: Provider.claude.configDirEnvVar)
        env.removeValue(forKey: Provider.codex.configDirEnvVar)
        env.removeValue(forKey: "CLAUDE_SECURESTORAGE_CONFIG_DIR")
        for (k, v) in profiles.environmentOverrides(for: account) { env[k] = v }
        env["HOME"] = paths.home.path
        if env["PATH"] == nil { env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin" }
        if account.provider == .claude { env["DISABLE_AUTOUPDATER"] = "1" }
        if env["TERM"] == nil { env["TERM"] = "dumb" }
        return env
    }
}

/// One implementation per CLI. All methods are read-only with respect to vendor credentials.
public protocol ProviderAdapter: Sendable {
    var provider: Provider { get }
    var context: ProviderContext { get }

    /// Real executable (recorded by the installer, or detected).
    func executablePath() -> String?
    func version() async -> String?
    /// Runs the vendor's own status command inside the profile. May refresh tokens as a side effect of the vendor CLI.
    func checkAuth(account: Account) async -> AuthStatus
    /// Identity from files the vendor already wrote (no network).
    func identity(account: Account) -> AccountIdentity?
    /// A shell script the app runs in Terminal to sign this profile in.
    func loginScript(account: Account, deviceAuth: Bool) -> String?
    func fetchUsage(account: Account) async throws -> UsageSnapshot
    func compatibilityIssues(version: String?, account: Account?) -> [CompatibilityIssue]
}

public extension ProviderAdapter {
    func executablePath() -> String? { context.shell.effectiveExecutable(provider) }

    func version() async -> String? {
        guard let exe = executablePath() else { return nil }
        let r = try? await context.runner.runAsync(exe, arguments: ["--version"], environment: context.cliEnvironment(for: Account.makeDefault(provider: provider)), timeout: 20)
        guard let r, r.exitCode == 0 else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init)
    }

    /// Shared HTTP status handling for the two usage endpoints.
    func classify(_ response: HTTPResponse) -> UsageFetchError? {
        switch response.status {
        case 200...299: return response.looksLikeHTML ? .blocked("The provider answered with an HTML page instead of JSON (bot check or outage).") : nil
        case 401: return .unauthorized("The provider rejected this account's stored login (HTTP 401). Sign in again from this card.")
        case 403: return response.looksLikeHTML ? .blocked("Blocked by the provider's bot protection (HTTP 403).") : .unauthorized("Access denied (HTTP 403).")
        case 429: return .rateLimited(retryAfter: response.retryAfter)
        case 500...599: return .serverError(response.status)
        case 0: return .network("No HTTP response")
        default: return .serverError(response.status)
        }
    }
}

/// Shell-quoting for generated login scripts.
public enum ShellQuote {
    public static func single(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
