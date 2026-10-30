import Foundation

/// `claude auth status` JSON (default output since 2.1.x). Only the documented keys are relied upon.
public struct ClaudeAuthStatusOutput: Equatable, Sendable {
    public var loggedIn: Bool
    public var authMethod: String?
    public var apiProvider: String?
    public var email: String?
    public var orgName: String?
    public var orgId: String?
    public var subscriptionType: String?
    public var configDirectory: String?
    public var forcedLoginMethod: String?
    public var apiKeySource: String?

    public init(loggedIn: Bool, authMethod: String? = nil, apiProvider: String? = nil, email: String? = nil, orgName: String? = nil,
                orgId: String? = nil, subscriptionType: String? = nil, configDirectory: String? = nil,
                forcedLoginMethod: String? = nil, apiKeySource: String? = nil) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.apiProvider = apiProvider
        self.email = email
        self.orgName = orgName
        self.orgId = orgId
        self.subscriptionType = subscriptionType
        self.configDirectory = configDirectory
        self.forcedLoginMethod = forcedLoginMethod
        self.apiKeySource = apiKeySource
    }
}

public enum ClaudeAuthStatusParser {
    /// Extracts the first JSON object from the CLI output (tolerates banner lines around it).
    public static func parse(_ text: String) -> ClaudeAuthStatusOutput? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") , start < end else { return nil }
        let json = String(text[start...end])
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func str(_ k: String) -> String? { obj[k] as? String }
        return ClaudeAuthStatusOutput(loggedIn: obj["loggedIn"] as? Bool ?? false,
                                      authMethod: str("authMethod"), apiProvider: str("apiProvider"), email: str("email"),
                                      orgName: str("orgName"), orgId: str("orgId"), subscriptionType: str("subscriptionType"),
                                      configDirectory: str("configDirectory"), forcedLoginMethod: str("forcedLoginMethod"),
                                      apiKeySource: str("apiKeySource"))
    }

    /// Turns the parsed output (or its absence) into our AuthStatus, with isolation warnings.
    public static func authStatus(from output: ClaudeAuthStatusOutput?, result: ProcessResult, isManagedProfile: Bool,
                                  expectedConfigDir: String?, now: Date = Date()) -> AuthStatus {
        guard let output else {
            if result.timedOut { return AuthStatus(state: .error, message: "claude auth status timed out", checkedAt: now) }
            let msg = SwitcherLog.redact(result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            return AuthStatus(state: .error, message: msg.isEmpty ? "claude auth status produced no JSON (exit \(result.exitCode))" : msg, checkedAt: now)
        }
        var warnings: [String] = []
        if let dir = output.configDirectory, let expected = expectedConfigDir,
           URL(fileURLWithPath: dir).standardizedFileURL.path != URL(fileURLWithPath: expected).standardizedFileURL.path {
            warnings.append("Claude Code reported config directory \(dir) instead of \(expected); the profile environment was not honoured.")
        }
        guard output.loggedIn else {
            return AuthStatus(state: .notAuthenticated, method: output.authMethod, message: "Not signed in", checkedAt: now, warnings: warnings)
        }
        let method = output.authMethod ?? "unknown"
        switch method {
        case "claude.ai":
            break
        case "oauth_token":
            warnings.append("A CLAUDE_CODE_OAUTH_TOKEN environment variable is in effect; it overrides this profile's stored login.")
        case "api_key", "api_key_helper":
            warnings.append("This profile authenticates with an API key (\(output.apiKeySource ?? method)), not a claude.ai subscription. Usage limits do not apply and Claude Code stores Console keyless sign-ins outside the config directory, so they are not isolated per profile.")
        case "third_party":
            warnings.append("Requests go to a third-party provider (Bedrock/Vertex/Foundry); the claude.ai login is bypassed.")
        case "none":
            return AuthStatus(state: .notAuthenticated, method: method, message: "Not signed in", checkedAt: now, warnings: warnings)
        default:
            break
        }
        var message = "Signed in"
        if let email = output.email { message += " as \(email)" }
        if let plan = output.subscriptionType { message += " (\(plan))" }
        return AuthStatus(state: .authenticated, method: method, message: message, checkedAt: now, warnings: warnings)
    }

    public static func identity(from output: ClaudeAuthStatusOutput, now: Date = Date()) -> AccountIdentity? {
        guard output.loggedIn else { return nil }
        return AccountIdentity(email: output.email, displayName: nil, organizationName: output.orgName, organizationId: output.orgId,
                               plan: output.subscriptionType, accountId: nil, method: output.authMethod, verifiedAt: now)
    }

    /// Identity details from `<configDir>/.claude.json` → `oauthAccount` (written by Claude Code at login).
    public static func identity(fromGlobalConfig data: Data) -> AccountIdentity? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let acct = obj["oauthAccount"] as? [String: Any] else { return nil }
        let identity = AccountIdentity(email: acct["emailAddress"] as? String,
                                       displayName: acct["displayName"] as? String ?? acct["fullName"] as? String,
                                       organizationName: acct["organizationName"] as? String,
                                       organizationId: acct["organizationUuid"] as? String,
                                       plan: acct["planDisplayName"] as? String,
                                       accountId: acct["accountUuid"] as? String,
                                       method: "claude.ai")
        return identity.isEmpty ? nil : identity
    }

    /// Credentials payload (Keychain item or `.credentials.json`): returns the access token and expiry only.
    public struct Credential: Sendable {
        public var accessToken: String
        public var expiresAt: Date?
        public var subscriptionType: String?
        public init(accessToken: String, expiresAt: Date?, subscriptionType: String?) {
            self.accessToken = accessToken
            self.expiresAt = expiresAt
            self.subscriptionType = subscriptionType
        }
        public func isExpired(now: Date = Date(), margin: TimeInterval = 60) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) < margin
        }
    }

    public static func credential(fromCredentialsJSON data: Data) -> Credential? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double { expires = Date(timeIntervalSince1970: ms / 1000) }
        else if let ms = oauth["expiresAt"] as? Int { expires = Date(timeIntervalSince1970: Double(ms) / 1000) }
        return Credential(accessToken: token, expiresAt: expires, subscriptionType: oauth["subscriptionType"] as? String)
    }
}
