import Foundation

/// Result of asking the provider CLI whether a profile is signed in.
public struct AuthStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case authenticated
        case notAuthenticated
        case expired
        case unknown
        case error
    }

    public var state: State
    /// Provider-specific method string (`claude.ai`, `oauth_token`, `api_key`, `chatgpt`, ...).
    public var method: String?
    public var message: String?
    public var checkedAt: Date
    /// Compatibility / isolation warnings, e.g. "Console keyless sign-ins are not isolated per profile".
    public var warnings: [String]

    public init(state: State, method: String? = nil, message: String? = nil, checkedAt: Date = Date(), warnings: [String] = []) {
        self.state = state
        self.method = method
        self.message = message
        self.checkedAt = checkedAt
        self.warnings = warnings
    }

    public var isAuthenticated: Bool { state == .authenticated }

    public var displayLabel: String {
        switch state {
        case .authenticated: return "Signed in"
        case .notAuthenticated: return "Not signed in"
        case .expired: return "Login expired"
        case .unknown: return "Unknown"
        case .error: return "Check failed"
        }
    }
}

/// A compatibility issue found while inspecting the installed CLI.
public struct CompatibilityIssue: Equatable, Sendable, Identifiable {
    public enum Severity: String, Sendable { case info, warning, blocking }
    public var id: String
    public var severity: Severity
    public var title: String
    public var detail: String
    public init(id: String, severity: Severity, title: String, detail: String) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}
