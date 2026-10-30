import Foundation

public enum AccountManagerError: Error, LocalizedError, Equatable {
    case notFound(String)
    case duplicateName(String)
    case cannotRemoveDefault

    public var errorDescription: String? {
        switch self {
        case .notFound(let k): return "Account \(k) not found"
        case .duplicateName(let n): return "An account named '\(n)' already exists for this provider"
        case .cannotRemoveDefault: return "The default account cannot be removed (it is the CLI's own ~/.claude or ~/.codex). Rename or hide it instead."
        }
    }
}

/// CRUD for accounts. Every provider always has a "default" account representing the CLI's own directory,
/// so an existing login keeps working without re-authentication.
public final class AccountManager: @unchecked Sendable {
    public let paths: SwitcherPaths
    public let store: AccountStore
    public let profiles: CLIProfileManager
    public let active: ActiveAccountManager
    private let lock = NSLock()
    private var cached: [Account] = []

    public init(paths: SwitcherPaths, store: AccountStore? = nil, profiles: CLIProfileManager? = nil, active: ActiveAccountManager? = nil) {
        self.paths = paths
        self.store = store ?? AccountStore(paths: paths)
        self.profiles = profiles ?? CLIProfileManager(paths: paths)
        self.active = active ?? ActiveAccountManager(paths: paths)
    }

    public var accounts: [Account] {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    public func accounts(for provider: Provider) -> [Account] {
        accounts.filter { $0.provider == provider }.sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            return a.createdAt < b.createdAt
        }
    }

    public func account(_ key: AccountKey) -> Account? {
        accounts.first { $0.key == key }
    }

    /// Looks up by id first, then by case-insensitive name.
    public func find(provider: Provider, nameOrId: String) -> Account? {
        let list = accounts(for: provider)
        if let byId = list.first(where: { $0.id == nameOrId }) { return byId }
        return list.first { $0.name.caseInsensitiveCompare(nameOrId) == .orderedSame }
    }

    public func activeAccount(for provider: Provider) -> Account? {
        let id = active.activeProfileId(for: provider)
        return account(AccountKey(provider, id)) ?? accounts(for: provider).first { $0.isDefault }
    }

    /// Loads accounts.json, adding missing default accounts and dropping managed accounts whose directory vanished.
    @discardableResult
    public func load() throws -> [Account] {
        try paths.ensureLayout()
        var list = try store.load()
        var changed = false
        for provider in Provider.allCases where !list.contains(where: { $0.provider == provider && $0.isDefault }) {
            list.append(Account.makeDefault(provider: provider))
            changed = true
        }
        lock.lock(); cached = list; lock.unlock()
        if changed { try store.save(list) }
        return list
    }

    private func mutate(_ body: (inout [Account]) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var list = cached
        try body(&list)
        try store.save(list)
        cached = list
    }

    public func addManagedAccount(provider: Provider, name: String, seed: ProfileSeedOptions = ProfileSeedOptions()) throws -> Account {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "\(provider.shortName) account" : trimmed
        if accounts(for: provider).contains(where: { $0.name.caseInsensitiveCompare(finalName) == .orderedSame }) {
            throw AccountManagerError.duplicateName(finalName)
        }
        let id = profiles.makeProfileId(from: finalName, existing: Set(accounts.map(\.id)))
        try profiles.createProfileDirectory(provider: provider, id: id, options: seed)
        let account = Account(id: id, provider: provider, name: finalName, kind: .managed)
        try mutate { $0.append(account) }
        return account
    }

    public func update(_ account: Account) throws {
        try mutate { list in
            guard let idx = list.firstIndex(where: { $0.key == account.key }) else { throw AccountManagerError.notFound(account.key.description) }
            list[idx] = account
        }
    }

    public func rename(_ key: AccountKey, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try mutate { list in
            guard let idx = list.firstIndex(where: { $0.key == key }) else { throw AccountManagerError.notFound(key.description) }
            if list.contains(where: { $0.provider == key.provider && $0.key != key && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                throw AccountManagerError.duplicateName(trimmed)
            }
            list[idx].name = trimmed
        }
    }

    /// Removes a managed account. If it was active, the provider falls back to its default profile first.
    public func remove(_ key: AccountKey, deleteProfileDirectory: Bool) throws {
        guard let acct = account(key) else { throw AccountManagerError.notFound(key.description) }
        guard !acct.isDefault else { throw AccountManagerError.cannotRemoveDefault }
        if active.activeProfileId(for: key.provider) == key.id {
            try active.resetToDefault(provider: key.provider)
        }
        try mutate { list in list.removeAll { $0.key == key } }
        if deleteProfileDirectory {
            try profiles.removeProfileDirectory(provider: key.provider, id: key.id)
        }
        SwitcherLog.shared.log("removed account \(key)", category: "account")
    }

    public func setIdentity(_ identity: AccountIdentity?, auth: AuthStatus?, for key: AccountKey) throws {
        try mutate { list in
            guard let idx = list.firstIndex(where: { $0.key == key }) else { return }
            if let identity { list[idx].identity = identity }
            if let auth { list[idx].lastAuth = auth }
        }
    }
}
