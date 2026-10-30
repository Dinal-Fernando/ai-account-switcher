import Foundation
import Security

public enum SecureStorageError: Error, LocalizedError {
    case osStatus(OSStatus)
    case encoding

    public var errorDescription: String? {
        switch self {
        case .osStatus(let s):
            let msg = SecCopyErrorMessageString(s, nil) as String? ?? "OSStatus \(s)"
            return "Keychain error: \(msg)"
        case .encoding: return "Keychain value could not be encoded"
        }
    }
}

/// App-owned secrets (none are required for the default usage source; reserved for optional credentials such
/// as a separate web-session token). Stored as generic passwords, this device only, when unlocked.
/// Vendor credentials (Claude Code / Codex) are never written through this class.
public final class SecureStorage: @unchecked Sendable {
    public let service: String

    public init(service: String = "dev.aiswitch.AIAccountSwitcher") { self.service = service }

    private func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func set(_ data: Data, account: String) throws {
        var query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            for (k, v) in attributes { query[k] = v }
            let add = SecItemAdd(query as CFDictionary, nil)
            guard add == errSecSuccess else { throw SecureStorageError.osStatus(add) }
        } else if status != errSecSuccess {
            throw SecureStorageError.osStatus(status)
        }
    }

    public func get(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecureStorageError.osStatus(status) }
        return result as? Data
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecureStorageError.osStatus(status) }
    }

    public func setString(_ value: String, account: String) throws {
        try set(Data(value.utf8), account: account)
    }

    public func getString(account: String) throws -> String? {
        guard let data = try get(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
