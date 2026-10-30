import Foundation

/// `$CODEX_HOME/auth.json` (file credential store). Tokens are only held in memory for the usage request.
public struct CodexAuthFile: Sendable {
    public var apiKey: String?
    public var idToken: String?
    public var accessToken: String?
    public var refreshTokenPresent: Bool
    public var accountId: String?
    public var lastRefresh: Date?

    public var hasChatGPTLogin: Bool { accessToken != nil }
}

public enum CodexAuthParser {
    public static func parseAuthFile(_ data: Data) -> CodexAuthFile? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let tokens = obj["tokens"] as? [String: Any]
        var last: Date?
        if let s = obj["last_refresh"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            last = f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        return CodexAuthFile(apiKey: obj["OPENAI_API_KEY"] as? String,
                             idToken: tokens?["id_token"] as? String,
                             accessToken: tokens?["access_token"] as? String,
                             refreshTokenPresent: (tokens?["refresh_token"] as? String).map { !$0.isEmpty } ?? false,
                             accountId: tokens?["account_id"] as? String,
                             lastRefresh: last)
    }

    /// Identity from the id_token claims (`email`, `https://api.openai.com/auth` → plan / account id).
    public static func identity(from auth: CodexAuthFile, now: Date = Date()) -> AccountIdentity? {
        if let id = auth.idToken, let claims = JWT.decodePayload(id) {
            let authClaims = claims["https://api.openai.com/auth"] as? [String: Any]
            let profile = claims["https://api.openai.com/profile"] as? [String: Any]
            let email = (claims["email"] as? String) ?? (profile?["email"] as? String)
            let plan = authClaims?["chatgpt_plan_type"] as? String
            let accountId = (authClaims?["chatgpt_account_id"] as? String) ?? auth.accountId
            let identity = AccountIdentity(email: email, plan: plan, accountId: accountId, method: "chatgpt", verifiedAt: now)
            if !identity.isEmpty { return identity }
        }
        if auth.apiKey != nil { return AccountIdentity(method: "api_key", verifiedAt: now) }
        return nil
    }

    /// `codex login status` prints one line to stderr. Exit code is 0 either way.
    public static func parseLoginStatus(_ result: ProcessResult, now: Date = Date()) -> AuthStatus {
        if result.timedOut { return AuthStatus(state: .error, message: "codex login status timed out", checkedAt: now) }
        let text = result.combinedOutput
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("WARNING:") }
        if let line = lines.first(where: { $0.hasPrefix("Logged in using ChatGPT") }) {
            return AuthStatus(state: .authenticated, method: "chatgpt", message: line, checkedAt: now)
        }
        if let line = lines.first(where: { $0.hasPrefix("API key configured") }) {
            return AuthStatus(state: .authenticated, method: "api_key", message: SwitcherLog.redact(line), checkedAt: now,
                              warnings: ["This profile uses an API key; ChatGPT subscription limits do not apply and the usage dashboard cannot read a quota for it."])
        }
        if let line = lines.first(where: { $0.hasPrefix("Logged in using") }) {
            let method = line.replacingOccurrences(of: "Logged in using ", with: "").lowercased()
            return AuthStatus(state: .authenticated, method: method, message: line, checkedAt: now,
                              warnings: method.contains("access token") || method.contains("bedrock") ? ["Environment-provided credentials are in use; the profile's stored login is bypassed."] : [])
        }
        if lines.contains(where: { $0.hasPrefix("Not logged in") }) {
            return AuthStatus(state: .notAuthenticated, message: "Not signed in", checkedAt: now)
        }
        if result.exitCode != 0 {
            return AuthStatus(state: .error, message: SwitcherLog.redact(lines.joined(separator: " ")), checkedAt: now)
        }
        return AuthStatus(state: .unknown, message: SwitcherLog.redact(lines.joined(separator: " ")), checkedAt: now)
    }
}
