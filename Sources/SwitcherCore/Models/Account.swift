import Foundation

/// How a profile maps onto the CLI's configuration directory.
public enum ProfileKind: String, Codable, Sendable {
    /// The CLI's own `~/.claude` / `~/.codex`. The wrapper exports nothing for it.
    case `default`
    /// A directory under `$AISWITCH_HOME/profiles/<provider>/<id>` exported as CLAUDE_CONFIG_DIR / CODEX_HOME.
    case managed
}

/// Where usage figures for an account come from.
public enum UsageSource: String, Codable, Sendable, CaseIterable {
    /// Read-only reuse of the profile's own CLI login (access token only; never written back).
    case cliLogin
    /// Do not fetch usage for this account.
    case disabled

    public var displayName: String {
        switch self {
        case .cliLogin: return "Profile's CLI login (read-only)"
        case .disabled: return "Disabled"
        }
    }
}

/// Identity information read from the provider's own files or `auth status` output.
public struct AccountIdentity: Codable, Equatable, Sendable {
    public var email: String?
    public var displayName: String?
    public var organizationName: String?
    public var organizationId: String?
    public var plan: String?
    public var accountId: String?
    public var method: String?
    public var verifiedAt: Date?

    public init(email: String? = nil, displayName: String? = nil, organizationName: String? = nil,
                organizationId: String? = nil, plan: String? = nil, accountId: String? = nil,
                method: String? = nil, verifiedAt: Date? = nil) {
        self.email = email
        self.displayName = displayName
        self.organizationName = organizationName
        self.organizationId = organizationId
        self.plan = plan
        self.accountId = accountId
        self.method = method
        self.verifiedAt = verifiedAt
    }

    /// One-line summary for cards and menus, e.g. "jane@example.com · Max".
    public var summary: String {
        var parts: [String] = []
        if let email, !email.isEmpty { parts.append(email) }
        else if let displayName, !displayName.isEmpty { parts.append(displayName) }
        if let organizationName, !organizationName.isEmpty, organizationName != email { parts.append(organizationName) }
        if let plan, !plan.isEmpty { parts.append(plan.capitalized) }
        return parts.joined(separator: " · ")
    }

    public var isEmpty: Bool { email == nil && displayName == nil && organizationName == nil && plan == nil && accountId == nil }
}

/// Stable key for an account across the app: provider + profile id.
public struct AccountKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public var provider: Provider
    public var id: String

    public init(_ provider: Provider, _ id: String) {
        self.provider = provider
        self.id = id
    }

    public var description: String { "\(provider.rawValue):\(id)" }

    public init?(string: String) {
        let parts = string.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let provider = Provider(rawValue: parts[0]), !parts[1].isEmpty else { return nil }
        self.init(provider, parts[1])
    }
}

/// An authenticated (or to-be-authenticated) CLI profile with a friendly name.
public struct Account: Codable, Identifiable, Equatable, Sendable {
    public static let defaultProfileId = "default"

    /// Profile id; `"default"` for the CLI's own directory, otherwise a slug like `work-3f9a`.
    public var id: String
    public var provider: Provider
    public var name: String
    public var kind: ProfileKind
    public var createdAt: Date
    public var identity: AccountIdentity?
    public var lastAuth: AuthStatus?
    public var usageSource: UsageSource
    /// Claude only: the profile's settings.json points its statusLine at the aiswitch beacon.
    public var statusLineBeacon: Bool
    public var notes: String?

    public init(id: String, provider: Provider, name: String, kind: ProfileKind, createdAt: Date = Date(),
                identity: AccountIdentity? = nil, lastAuth: AuthStatus? = nil, usageSource: UsageSource = .cliLogin,
                statusLineBeacon: Bool = false, notes: String? = nil) {
        self.id = id
        self.provider = provider
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.identity = identity
        self.lastAuth = lastAuth
        self.usageSource = usageSource
        self.statusLineBeacon = statusLineBeacon
        self.notes = notes
    }

    public var key: AccountKey { AccountKey(provider, id) }
    public var isDefault: Bool { kind == .default }

    public static func makeDefault(provider: Provider) -> Account {
        Account(id: defaultProfileId, provider: provider,
                name: "\(provider.shortName) (default ~/\(provider.defaultConfigDirName))",
                kind: .default, createdAt: Date(timeIntervalSince1970: 0))
    }

    // Tolerate older documents missing newer keys.
    private enum CodingKeys: String, CodingKey {
        case id, provider, name, kind, createdAt, identity, lastAuth, usageSource, statusLineBeacon, notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decode(Provider.self, forKey: .provider)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(ProfileKind.self, forKey: .kind) ?? (id == Account.defaultProfileId ? .default : .managed)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        identity = try c.decodeIfPresent(AccountIdentity.self, forKey: .identity)
        lastAuth = try c.decodeIfPresent(AuthStatus.self, forKey: .lastAuth)
        usageSource = try c.decodeIfPresent(UsageSource.self, forKey: .usageSource) ?? .cliLogin
        statusLineBeacon = try c.decodeIfPresent(Bool.self, forKey: .statusLineBeacon) ?? false
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
}
