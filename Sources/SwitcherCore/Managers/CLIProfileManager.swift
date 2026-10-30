import Foundation

public struct ProfileSeedOptions: Equatable, Sendable {
    /// Claude: copy `settings.json`, `CLAUDE.md`, `commands/`, `agents/`, `skills/` from `~/.claude` (never `.claude.json`).
    public var copyClaudeUserSettings: Bool
    /// Codex: copy `~/.codex/config.toml` (auth.json is never copied).
    public var copyCodexConfig: Bool
    /// Codex `cli_auth_credentials_store` written at the top of the profile's config.toml. `file` keeps auth.json
    /// inside the profile so the usage monitor can read it; `nil` leaves the vendor default / user setting.
    public var codexCredentialStore: String?

    public init(copyClaudeUserSettings: Bool = true, copyCodexConfig: Bool = true, codexCredentialStore: String? = "file") {
        self.copyClaudeUserSettings = copyClaudeUserSettings
        self.copyCodexConfig = copyCodexConfig
        self.codexCredentialStore = codexCredentialStore
    }
}

public enum ProfileError: Error, LocalizedError, Equatable {
    case invalidId(String)
    case alreadyExists(String)
    case cannotModifyDefault

    public var errorDescription: String? {
        switch self {
        case .invalidId(let id): return "Invalid profile id '\(id)'"
        case .alreadyExists(let id): return "Profile '\(id)' already exists"
        case .cannotModifyDefault: return "The default profile is the CLI's own directory and cannot be created or deleted here"
        }
    }
}

/// Creates and inspects per-account CLI configuration directories, and reproduces the vendors'
/// credential key derivation for diagnostics.
public final class CLIProfileManager: @unchecked Sendable {
    public let paths: SwitcherPaths
    private let fm = FileManager.default

    public init(paths: SwitcherPaths) { self.paths = paths }

    // MARK: ids

    public static func slug(_ name: String) -> String {
        var out = ""
        var lastDash = true
        for ch in name.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
            if out.count >= 24 { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "account" : out
    }

    public func makeProfileId(from name: String, existing: Set<String>) -> String {
        let base = Self.slug(name)
        for _ in 0..<64 {
            let suffix = String(format: "%04x", Int.random(in: 0...0xffff))
            let candidate = "\(base)-\(suffix)"
            if !existing.contains(candidate), !fm.fileExists(atPath: paths.profileDir(.claude, candidate).path),
               !fm.fileExists(atPath: paths.profileDir(.codex, candidate).path) {
                return candidate
            }
        }
        return "\(base)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    // MARK: directories

    /// The directory the CLI will use for this account (`~/.claude` / `~/.codex` for the default profile).
    public func configDirectory(for account: Account) -> URL {
        switch account.kind {
        case .default: return account.provider.defaultConfigDir(home: paths.home)
        case .managed: return paths.profileDir(account.provider, account.id)
        }
    }

    /// Environment the wrapper (or a login script) must export to select this account. Empty for default.
    public func environmentOverrides(for account: Account) -> [String: String] {
        switch account.kind {
        case .default: return [:]
        case .managed: return [account.provider.configDirEnvVar: paths.profileDir(account.provider, account.id).path]
        }
    }

    public func profileDirectoryExists(_ account: Account) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: configDirectory(for: account).path, isDirectory: &isDir) && isDir.boolValue
    }

    @discardableResult
    public func createProfileDirectory(provider: Provider, id: String, options: ProfileSeedOptions = ProfileSeedOptions()) throws -> URL {
        guard id != Account.defaultProfileId else { throw ProfileError.cannotModifyDefault }
        guard ActiveAccountManager.isValidProfileId(id) else { throw ProfileError.invalidId(id) }
        let dir = paths.profileDir(provider, id)
        guard !fm.fileExists(atPath: dir.path) else { throw ProfileError.alreadyExists(id) }
        try fm.createDirectory(at: paths.profiles(provider), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let defaultDir = provider.defaultConfigDir(home: paths.home)
        switch provider {
        case .claude:
            if options.copyClaudeUserSettings {
                for item in ["settings.json", "CLAUDE.md", "commands", "agents", "skills"] {
                    let src = defaultDir.appendingPathComponent(item)
                    if fm.fileExists(atPath: src.path) {
                        try? fm.copyItem(at: src, to: dir.appendingPathComponent(item))
                    }
                }
            }
        case .codex:
            var userConfig: String?
            if options.copyCodexConfig {
                userConfig = try? String(contentsOf: defaultDir.appendingPathComponent("config.toml"), encoding: .utf8)
            }
            let content = Self.codexConfigContent(profileId: id, seedFrom: userConfig, credentialStore: options.codexCredentialStore)
            try AtomicFile.write(content, to: dir.appendingPathComponent("config.toml"), permissions: 0o600)
        }
        SwitcherLog.shared.log("created \(provider.rawValue) profile \(id)", category: "profile")
        return dir
    }

    public func removeProfileDirectory(provider: Provider, id: String) throws {
        guard id != Account.defaultProfileId else { throw ProfileError.cannotModifyDefault }
        guard ActiveAccountManager.isValidProfileId(id) else { throw ProfileError.invalidId(id) }
        let dir = paths.profileDir(provider, id)
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
    }

    /// Builds a profile `config.toml`: our top-level keys first (so they stay top-level), then the user's
    /// config with any conflicting top-level `cli_auth_credentials_store` line removed.
    public static func codexConfigContent(profileId: String, seedFrom userConfig: String?, credentialStore: String?) -> String {
        var out = "# Generated by AI Account Switcher for Codex profile '\(profileId)'.\n"
        out += "# Edit freely; only the credential-store line below matters to the switcher.\n"
        if let credentialStore {
            out += "cli_auth_credentials_store = \"\(credentialStore)\"\n"
        }
        guard let userConfig, !userConfig.isEmpty else { return out }
        var lines = userConfig.components(separatedBy: "\n")
        if let firstTable = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) {
            let top = lines[..<firstTable].filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("cli_auth_credentials_store") || credentialStore == nil }
            lines = Array(top) + Array(lines[firstTable...])
        } else {
            lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("cli_auth_credentials_store") || credentialStore == nil }
        }
        out += "\n# ---- copied from ~/.codex/config.toml ----\n"
        out += lines.joined(separator: "\n")
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    // MARK: vendor files

    public func claudeCredentialsFile(for account: Account) -> URL { configDirectory(for: account).appendingPathComponent(".credentials.json") }
    public func claudeGlobalConfigFile(for account: Account) -> URL { configDirectory(for: account).appendingPathComponent(".claude.json") }
    public func claudeSettingsFile(for account: Account) -> URL { configDirectory(for: account).appendingPathComponent("settings.json") }
    public func codexAuthFile(for account: Account) -> URL { configDirectory(for: account).appendingPathComponent("auth.json") }
    public func codexConfigFile(for account: Account) -> URL { configDirectory(for: account).appendingPathComponent("config.toml") }

    // MARK: vendor key derivation (diagnostics only; the app never writes these entries)

    /// Claude Code 2.1.x: `Claude Code-credentials` for the default directory; with CLAUDE_CONFIG_DIR set the
    /// service name gains `-<first 8 hex of sha256(CLAUDE_CONFIG_DIR)>`.
    public static func claudeKeychainService(configDirEnvValue: String?) -> String {
        guard let value = configDirEnvValue, !value.isEmpty else { return "Claude Code-credentials" }
        return "Claude Code-credentials-" + String(SHA256.hexDigest(value.precomposedStringWithCanonicalMapping).prefix(8))
    }

    public func claudeKeychainService(for account: Account) -> String {
        Self.claudeKeychainService(configDirEnvValue: environmentOverrides(for: account)[Provider.claude.configDirEnvVar])
    }

    /// Claude Code uses `$USER` (or the OS user name) as the Keychain account, falling back to a fixed name
    /// when the user name contains characters outside `[a-zA-Z0-9._-]`.
    public static func claudeKeychainAccount(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let user = environment["USER"] ?? NSUserName()
        let ok = !user.isEmpty && user.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-") }
        return ok ? user : "claude-code-user"
    }

    /// Codex keyring mode: service `Codex Auth`, account `cli|<first 16 hex of sha256(canonical CODEX_HOME)>`.
    public static let codexKeyringService = "Codex Auth"

    public static func codexKeyringAccount(codexHome: URL) -> String {
        let canonical = codexHome.resolvingSymlinksInPath().standardizedFileURL.path
        return "cli|" + String(SHA256.hexDigest(canonical).prefix(16))
    }

    /// Reads `cli_auth_credentials_store` from a profile's config.toml (top-level only), nil when unset.
    public static func codexCredentialStoreSetting(in toml: String) -> String? {
        for line in toml.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { break }
            if t.hasPrefix("cli_auth_credentials_store") {
                guard let eq = t.firstIndex(of: "=") else { continue }
                var v = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if let hash = v.firstIndex(of: "#") { v = String(v[..<hash]).trimmingCharacters(in: .whitespaces) }
                return v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }
}
