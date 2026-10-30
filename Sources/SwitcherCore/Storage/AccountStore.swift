import Foundation

struct AccountsDocument: Codable {
    var version: Int
    var accounts: [Account]
}

/// Persists account metadata as JSON (`accounts.json`, mode 0600). No secrets are ever stored here.
public final class AccountStore: @unchecked Sendable {
    public static let currentVersion = 1
    private let paths: SwitcherPaths
    private let lock = NSLock()

    public init(paths: SwitcherPaths) { self.paths = paths }

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func load() throws -> [Account] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: paths.accountsFile.path) else { return [] }
        let data = try Data(contentsOf: paths.accountsFile)
        let doc = try Self.makeDecoder().decode(AccountsDocument.self, from: data)
        return doc.accounts
    }

    public func save(_ accounts: [Account]) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try Self.makeEncoder().encode(AccountsDocument(version: Self.currentVersion, accounts: accounts))
        try AtomicFile.write(data, to: paths.accountsFile, permissions: 0o600)
    }
}
