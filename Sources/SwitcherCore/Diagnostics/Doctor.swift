import Foundation

public struct DoctorItem: Equatable, Sendable, Identifiable {
    public enum Level: String, Sendable { case ok, info, warning, failure }
    public var id: String
    public var level: Level
    public var title: String
    public var detail: String

    public init(id: String, level: Level, title: String, detail: String = "") {
        self.id = id
        self.level = level
        self.title = title
        self.detail = detail
    }
}

public struct DoctorReport: Equatable, Sendable {
    public var generatedAt: Date
    public var items: [DoctorItem]

    public var hasFailures: Bool { items.contains { $0.level == .failure } }
    public var hasWarnings: Bool { items.contains { $0.level == .warning } }

    public var text: String {
        var lines = ["AI Account Switcher diagnostics (\(ISO8601DateFormatter().string(from: generatedAt)))", ""]
        for item in items {
            let mark: String
            switch item.level {
            case .ok: mark = "[ok]  "
            case .info: mark = "[info]"
            case .warning: mark = "[warn]"
            case .failure: mark = "[FAIL]"
            }
            lines.append("\(mark) \(item.title)")
            if !item.detail.isEmpty { lines.append("       \(item.detail)") }
        }
        return lines.joined(separator: "\n")
    }
}

/// Answers "which executable, which profile, which identity will `claude`/`codex` use right now?".
public struct Doctor: Sendable {
    public var context: ProviderContext
    public var accounts: AccountManager
    public var adapters: [Provider: ProviderAdapter]
    /// Probing the login shell and the vendor CLIs is slow; callers can opt out for a quick snapshot.
    public var probeShell = true
    public var probeAuth = true

    public init(context: ProviderContext, accounts: AccountManager, adapters: [Provider: ProviderAdapter], probeShell: Bool = true, probeAuth: Bool = true) {
        self.context = context
        self.accounts = accounts
        self.adapters = adapters
        self.probeShell = probeShell
        self.probeAuth = probeAuth
    }

    public func run(providers: [Provider] = Provider.allCases) async -> DoctorReport {
        var items: [DoctorItem] = []
        let paths = context.paths
        let fm = FileManager.default

        // Layout
        if fm.fileExists(atPath: paths.root.path) {
            let perms = (try? fm.attributesOfItem(atPath: paths.root.path)[.posixPermissions] as? Int) ?? 0
            items.append(DoctorItem(id: "home", level: perms == 0o700 ? .ok : .warning, title: "State directory \(paths.root.path)",
                                    detail: perms == 0o700 ? "mode 0700" : String(format: "mode %o (expected 0700)", perms)))
        } else {
            items.append(DoctorItem(id: "home", level: .failure, title: "State directory \(paths.root.path) does not exist", detail: "Run the onboarding or Scripts/install-shell-integration.sh."))
        }

        var shellStatus = context.shell.status()
        var loginEnv: [String: String] = [:]
        if probeShell {
            shellStatus = context.shell.verify(shellStatus)
            loginEnv = LoginShell(environment: context.baseEnvironment, runner: context.runner).environment()
        }

        for provider in providers {
            let p = provider.rawValue
            let wrapperPath = paths.wrapper(provider).path
            if shellStatus.wrapperInstalled[provider] == true {
                let v = shellStatus.wrapperVersion[provider] ?? 0
                items.append(DoctorItem(id: "\(p)-wrapper", level: v == EmbeddedScripts.wrapperVersion ? .ok : .warning,
                                        title: "\(provider.executableName) wrapper installed at \(wrapperPath)",
                                        detail: v == EmbeddedScripts.wrapperVersion ? "version \(v)" : "version \(v), app expects \(EmbeddedScripts.wrapperVersion): reinstall shell integration"))
            } else {
                items.append(DoctorItem(id: "\(p)-wrapper", level: .failure, title: "\(provider.executableName) wrapper not installed",
                                        detail: "Terminal commands will use whatever login ~/\(provider.defaultConfigDirName) holds. Install shell integration from Settings."))
            }
            if let real = shellStatus.realExecutable[provider] {
                let ok = fm.isExecutableFile(atPath: real) && !context.shell.isWrapper(real)
                items.append(DoctorItem(id: "\(p)-real", level: ok ? .ok : .failure, title: "Real \(provider.executableName): \(real)",
                                        detail: ok ? "" : "Recorded path is missing or is a wrapper; reinstall shell integration or reinstall \(provider.displayName)."))
            } else if let detected = context.shell.detectExecutable(provider, searchPath: loginEnv["PATH"]) {
                items.append(DoctorItem(id: "\(p)-real", level: .warning, title: "Real \(provider.executableName) not recorded (found \(detected))", detail: "The wrapper will search PATH at run time. Reinstall shell integration to pin it."))
            } else {
                items.append(DoctorItem(id: "\(p)-real", level: .failure, title: "No \(provider.executableName) executable found", detail: "Install \(provider.displayName) first."))
            }
            if probeShell {
                if let resolved = shellStatus.loginShellResolution[provider] {
                    let viaWrapper = resolved == wrapperPath
                    items.append(DoctorItem(id: "\(p)-path", level: viaWrapper ? .ok : (shellStatus.wrapperInstalled[provider] == true ? .failure : .info),
                                            title: "Login shell resolves `\(provider.executableName)` to \(resolved)",
                                            detail: viaWrapper ? "Switching is in effect for new terminals." : "Not the wrapper: check that the aiswitch PATH block in ~/.zshrc comes after anything else that edits PATH, then open a new terminal."))
                } else {
                    items.append(DoctorItem(id: "\(p)-path", level: .warning, title: "Login shell could not resolve `\(provider.executableName)`", detail: "Open a new terminal and run `command -v \(provider.executableName)`."))
                }
                let overrides = EnvOverrideDetector.findings(provider: provider, environment: loginEnv)
                for f in overrides { items.append(DoctorItem(id: f.id, level: .warning, title: f.message, detail: "Unset it (or use AISWITCH_NO_ENV_WARN=1 to silence the wrapper) if you want the selected subscription login.")) }
            }

            // Active profile
            let activeId = accounts.active.activeProfileId(for: provider)
            let raw = accounts.active.rawSelection(for: provider)
            if let raw, raw != activeId {
                items.append(DoctorItem(id: "\(p)-active", level: .warning, title: "Selected \(provider.shortName) profile '\(raw)' is unusable; falling back to default", detail: "Its directory is missing. Select another account."))
            }
            let account = accounts.activeAccount(for: provider)
            let dir = account.map { context.profiles.configDirectory(for: $0).path } ?? "?"
            items.append(DoctorItem(id: "\(p)-selected", level: .info, title: "Active \(provider.shortName) account: \(account?.name ?? activeId) (profile '\(activeId)')",
                                    detail: "\(provider.configDirEnvVar)=\(activeId == Account.defaultProfileId ? "(unset → ~/\(provider.defaultConfigDirName))" : dir)"))
            if let res = context.shell.wrapperResolution(provider) {
                let applied = res["applied"] ?? "?"
                let level: DoctorItem.Level = (applied == "yes" || applied == "default") ? .ok : .warning
                items.append(DoctorItem(id: "\(p)-dryrun", level: level, title: "Wrapper dry-run: profile=\(res["profile"] ?? "?") real=\(res["real"] ?? "?")",
                                        detail: "config_dir=\(res["config_dir"] ?? "") applied=\(applied) overrides=\(res["overrides"] ?? "")"))
            }
            if provider == .claude, let account {
                items.append(DoctorItem(id: "claude-keychain", level: .info, title: "Expected Keychain item for this profile",
                                        detail: "service \"\(context.profiles.claudeKeychainService(for: account))\", account \"\(CLIProfileManager.claudeKeychainAccount(environment: context.baseEnvironment))\" (Keychain Access → login)"))
                for f in EnvOverrideDetector.claudeSettingsFindings(configDir: context.profiles.configDirectory(for: account)) {
                    items.append(DoctorItem(id: f.id, level: .warning, title: f.message))
                }
            }
            if provider == .codex, let account, let toml = try? String(contentsOf: context.profiles.codexConfigFile(for: account), encoding: .utf8) {
                let store = CLIProfileManager.codexCredentialStoreSetting(in: toml) ?? "(vendor default: file)"
                items.append(DoctorItem(id: "codex-store", level: .info, title: "Codex credential store: \(store)",
                                        detail: "keyring key would be \(CLIProfileManager.codexKeyringService) / \(CLIProfileManager.codexKeyringAccount(codexHome: context.profiles.configDirectory(for: account)))"))
            }

            // Version + compatibility + auth
            if let adapter = adapters[provider] {
                let version = probeAuth ? await adapter.version() : nil
                if let version { items.append(DoctorItem(id: "\(p)-version", level: .info, title: "\(provider.displayName) version: \(version)")) }
                for issue in adapter.compatibilityIssues(version: version, account: account) {
                    items.append(DoctorItem(id: issue.id, level: issue.severity == .blocking ? .failure : (issue.severity == .warning ? .warning : .info), title: issue.title, detail: issue.detail))
                }
                if probeAuth, let account {
                    let auth = await adapter.checkAuth(account: account)
                    let identity = adapter.identity(account: account)
                    let who = identity?.summary ?? ""
                    items.append(DoctorItem(id: "\(p)-auth", level: auth.isAuthenticated ? .ok : (auth.state == .error ? .failure : .warning),
                                            title: "\(provider.shortName) auth for '\(account.name)': \(auth.displayLabel)\(who.isEmpty ? "" : " — \(who)")",
                                            detail: ([auth.message ?? ""] + auth.warnings).filter { !$0.isEmpty }.joined(separator: " ")))
                }
            }
        }
        return DoctorReport(generatedAt: context.time.now, items: items)
    }
}
