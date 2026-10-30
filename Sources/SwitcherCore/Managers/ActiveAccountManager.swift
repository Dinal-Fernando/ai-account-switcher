import Foundation

public enum ActiveAccountError: Error, LocalizedError, Equatable {
    case invalidProfileId(String)
    case profileDirectoryMissing(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProfileId(let id): return "'\(id)' is not a valid profile id"
        case .profileDirectoryMissing(let path): return "Profile directory does not exist: \(path)"
        }
    }
}

/// Owns the single source of truth the wrapper reads: `$AISWITCH_HOME/state/active-<provider>`.
/// Writes are atomic (temp file + rename), so a `claude` launched mid-switch sees the old or the new
/// selection, never a torn file. Nothing here touches running CLI processes.
public final class ActiveAccountManager: @unchecked Sendable {
    public static let defaultProfileId = Account.defaultProfileId
    private let paths: SwitcherPaths

    public init(paths: SwitcherPaths) { self.paths = paths }

    /// Same rule as the wrapper: `[A-Za-z0-9._-]+`, not starting with a dot (blocks `..`).
    public static func isValidProfileId(_ id: String) -> Bool {
        guard !id.isEmpty, !id.hasPrefix(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return id.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    /// The profile id the wrapper will use for the next launch (`"default"` when nothing is selected).
    public func activeProfileId(for provider: Provider) -> String {
        guard let raw = AtomicFile.readLine(paths.activeStateFile(provider)) else { return Self.defaultProfileId }
        if raw == Self.defaultProfileId { return raw }
        guard Self.isValidProfileId(raw) else { return Self.defaultProfileId }
        guard FileManager.default.fileExists(atPath: paths.profileDir(provider, raw).path) else { return Self.defaultProfileId }
        return raw
    }

    /// Raw content of the state file, for diagnostics (may name a missing profile).
    public func rawSelection(for provider: Provider) -> String? {
        AtomicFile.readLine(paths.activeStateFile(provider))
    }

    public func hasExplicitSelection(for provider: Provider) -> Bool {
        FileManager.default.fileExists(atPath: paths.activeStateFile(provider).path)
    }

    /// Atomically selects `profileId` for future `claude`/`codex` launches.
    public func setActive(provider: Provider, profileId: String) throws {
        if profileId != Self.defaultProfileId {
            guard Self.isValidProfileId(profileId) else { throw ActiveAccountError.invalidProfileId(profileId) }
            let dir = paths.profileDir(provider, profileId)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                throw ActiveAccountError.profileDirectoryMissing(dir.path)
            }
        }
        try AtomicFile.write(profileId + "\n", to: paths.activeStateFile(provider), permissions: 0o600)
        SwitcherLog.shared.log("active \(provider.rawValue) profile set to \(profileId)", category: "switch")
    }

    public func resetToDefault(provider: Provider) throws {
        try setActive(provider: provider, profileId: Self.defaultProfileId)
    }
}
