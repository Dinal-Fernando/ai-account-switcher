import Foundation

/// Every path the app, the CLI and the shell wrapper agree on. Root is `$AISWITCH_HOME` or `~/.aiswitch`.
public struct SwitcherPaths: Sendable, Equatable {
    public let root: URL
    public let home: URL

    public init(root: URL? = nil, home: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let homeURL: URL
        if let home {
            homeURL = home
        } else if let h = environment["HOME"], !h.isEmpty {
            homeURL = URL(fileURLWithPath: h, isDirectory: true)
        } else {
            homeURL = FileManager.default.homeDirectoryForCurrentUser
        }
        self.home = homeURL
        if let root {
            self.root = root
        } else if let custom = environment["AISWITCH_HOME"], !custom.isEmpty {
            self.root = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            self.root = homeURL.appendingPathComponent(".aiswitch", isDirectory: true)
        }
    }

    public var isDefaultRoot: Bool { root.standardizedFileURL.path == home.appendingPathComponent(".aiswitch").standardizedFileURL.path }

    public var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
    public var config: URL { root.appendingPathComponent("config", isDirectory: true) }
    public var state: URL { root.appendingPathComponent("state", isDirectory: true) }
    public var profilesRoot: URL { root.appendingPathComponent("profiles", isDirectory: true) }
    public var backups: URL { root.appendingPathComponent("backups", isDirectory: true) }
    public var usage: URL { root.appendingPathComponent("usage", isDirectory: true) }
    public var history: URL { root.appendingPathComponent("history", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var tmp: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    public var accountsFile: URL { root.appendingPathComponent("accounts.json") }
    public var logFile: URL { logs.appendingPathComponent("aiswitch.log") }

    public func profiles(_ provider: Provider) -> URL { profilesRoot.appendingPathComponent(provider.rawValue, isDirectory: true) }
    public func profileDir(_ provider: Provider, _ id: String) -> URL { profiles(provider).appendingPathComponent(id, isDirectory: true) }
    public func activeStateFile(_ provider: Provider) -> URL { state.appendingPathComponent("active-\(provider.rawValue)") }
    public func realExecutableFile(_ provider: Provider) -> URL { config.appendingPathComponent("\(provider.rawValue).real") }
    public func wrapper(_ provider: Provider) -> URL { bin.appendingPathComponent(provider.executableName) }
    public var statusLineBeacon: URL { bin.appendingPathComponent("aiswitch-statusline") }
    public func statusLineChainFile(profileId: String) -> URL { config.appendingPathComponent("statusline-chain-\(profileId)") }
    public func rcBackupPointer(rcName: String) -> URL { config.appendingPathComponent("rc-backup-\(rcName)") }
    public func usageCacheFile(_ key: AccountKey) -> URL { usage.appendingPathComponent("\(key.provider.rawValue)-\(key.id).json") }
    public func statusLineBeaconFile(profileId: String) -> URL { usage.appendingPathComponent("claude-\(profileId).statusline.json") }
    public func historyFile(_ key: AccountKey) -> URL { history.appendingPathComponent("\(key.provider.rawValue)-\(key.id).jsonl") }

    public var allDirectories: [URL] {
        [root, bin, config, state, profilesRoot, profiles(.claude), profiles(.codex), backups, usage, history, logs, tmp]
    }

    /// Creates the layout with restrictive permissions (0700; `bin` is 0755 so shells can exec the wrappers).
    public func ensureLayout() throws {
        let fm = FileManager.default
        for dir in allDirectories {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
    }

    /// Shell-friendly spelling of the bin dir for rc files (`$HOME/.aiswitch/bin` when default).
    public var binPathExpression: String {
        isDefaultRoot ? "$HOME/.aiswitch/bin" : bin.path
    }
}
