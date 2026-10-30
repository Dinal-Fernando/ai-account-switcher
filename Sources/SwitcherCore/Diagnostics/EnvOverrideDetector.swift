import Foundation

public struct EnvOverrideFinding: Equatable, Sendable, Identifiable {
    public var provider: Provider
    public var variable: String
    /// "login shell", "settings: <path>", "managed settings: <path>"
    public var source: String
    public var id: String { "\(provider.rawValue):\(variable):\(source)" }

    public var message: String {
        "\(variable) is set in \(source); it takes precedence over the selected \(provider.shortName) login."
    }
}

/// Finds credentials that silently override the selected profile: shell environment variables and the
/// `env` / `apiKeyHelper` keys of Claude Code settings files.
public enum EnvOverrideDetector {
    public static func findings(provider: Provider, environment: [String: String], source: String = "the login shell") -> [EnvOverrideFinding] {
        provider.credentialOverrideEnvVars.compactMap { v in
            guard let value = environment[v], !value.isEmpty else { return nil }
            return EnvOverrideFinding(provider: provider, variable: v, source: source)
        }
    }

    public static let claudeManagedSettingsPaths = [
        "/Library/Application Support/ClaudeCode/managed-settings.json",
    ]

    /// Inspects `<configDir>/settings.json` and managed settings for `env` overrides and `apiKeyHelper`.
    public static func claudeSettingsFindings(configDir: URL) -> [EnvOverrideFinding] {
        var out: [EnvOverrideFinding] = []
        var files = [(configDir.appendingPathComponent("settings.json").path, "settings: ")]
        files += claudeManagedSettingsPaths.map { ($0, "managed settings: ") }
        for (path, prefix) in files {
            guard let data = FileManager.default.contents(atPath: path),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let env = obj["env"] as? [String: Any] {
                for v in Provider.claude.credentialOverrideEnvVars {
                    if let value = env[v] as? String, !value.isEmpty {
                        out.append(EnvOverrideFinding(provider: .claude, variable: v, source: prefix + path))
                    }
                }
                if let dir = env[Provider.claude.configDirEnvVar] as? String, !dir.isEmpty {
                    out.append(EnvOverrideFinding(provider: .claude, variable: Provider.claude.configDirEnvVar, source: prefix + path))
                }
            }
            if let helper = obj["apiKeyHelper"] as? String, !helper.isEmpty {
                out.append(EnvOverrideFinding(provider: .claude, variable: "apiKeyHelper", source: prefix + path))
            }
            if let forced = obj["forceLoginMethod"] as? String, forced == "console" {
                out.append(EnvOverrideFinding(provider: .claude, variable: "forceLoginMethod=console", source: prefix + path))
            }
        }
        return out
    }
}
