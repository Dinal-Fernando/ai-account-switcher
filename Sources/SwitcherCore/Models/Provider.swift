import Foundation

/// The two CLIs this app can route between.
public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    public var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// Name of the executable the user types in Terminal (and of the wrapper).
    public var executableName: String { rawValue }

    /// The single environment variable the wrapper exports to select a managed profile.
    public var configDirEnvVar: String {
        switch self {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex: return "CODEX_HOME"
        }
    }

    /// Per-terminal override honoured by the wrapper (used by "Open Terminal with this account").
    public var profileOverrideEnvVar: String {
        switch self {
        case .claude: return "AISWITCH_CLAUDE_PROFILE"
        case .codex: return "AISWITCH_CODEX_PROFILE"
        }
    }

    /// Directory the CLI uses when no profile is applied.
    public var defaultConfigDirName: String {
        switch self {
        case .claude: return ".claude"
        case .codex: return ".codex"
        }
    }

    public func defaultConfigDir(home: URL) -> URL {
        home.appendingPathComponent(defaultConfigDirName, isDirectory: true)
    }

    /// Environment variables that take precedence over the CLI's stored login (documented by each vendor).
    /// If any of these is set, the selected profile's subscription is silently bypassed.
    public var credentialOverrideEnvVars: [String] {
        switch self {
        case .claude:
            return ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
                    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"]
        case .codex:
            return ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"]
        }
    }

    /// Human-readable login command shown in the UI / docs.
    public var loginCommandDescription: String {
        switch self {
        case .claude: return "claude auth login"
        case .codex: return "codex login"
        }
    }
}
