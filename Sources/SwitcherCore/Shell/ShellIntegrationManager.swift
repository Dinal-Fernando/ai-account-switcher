import Foundation

public struct ShellIntegrationStatus: Equatable, Sendable {
    public var wrapperInstalled: [Provider: Bool] = [:]
    public var wrapperVersion: [Provider: Int] = [:]
    public var realExecutable: [Provider: String] = [:]
    public var statusLineBeaconInstalled = false
    public var rcFilesWithBlock: [String] = []
    /// Filled by `verify(...)`: what a fresh login shell resolves `claude` / `codex` to.
    public var loginShellResolution: [Provider: String] = [:]
    /// Filled by `verify(...)`: the login shell's PATH entries, in order.
    public var loginShellPATH: [String] = []
    public var loginShellName: String?
    public var loginShellProbed = false

    public init() {}

    public func wrapperPath(_ provider: Provider, paths: SwitcherPaths) -> String { paths.wrapper(provider).path }

    static func canonical(_ path: String, home: URL) -> String {
        var p = path
        if p == "~" || p.hasPrefix("~/") { p = home.path + p.dropFirst() }
        return URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Index of our bin dir in the login-shell PATH, and of the directory holding the real executable.
    func pathOrder(_ provider: Provider, paths: SwitcherPaths) -> (bin: Int?, real: Int?) {
        let entries = loginShellPATH.map { Self.canonical($0, home: paths.home) }
        let bin = entries.firstIndex(of: Self.canonical(paths.bin.path, home: paths.home))
        var real: Int?
        if let exe = realExecutable[provider] {
            real = entries.firstIndex(of: Self.canonical((exe as NSString).deletingLastPathComponent, home: paths.home))
        }
        return (bin, real)
    }

    /// True when the wrapper exists *and* a login shell actually picks it up: either the shell resolves the
    /// command to the wrapper, or our bin dir precedes the real executable's directory in the shell's PATH.
    public func isActive(_ provider: Provider, paths: SwitcherPaths) -> Bool {
        guard wrapperInstalled[provider] == true, loginShellProbed else { return false }
        let wrapper = Self.canonical(paths.wrapper(provider).path, home: paths.home)
        if let r = loginShellResolution[provider], Self.canonical(r, home: paths.home) == wrapper { return true }
        let order = pathOrder(provider, paths: paths)
        if let bin = order.bin {
            if let real = order.real { return bin < real }
            return true
        }
        return false
    }

    /// One sentence explaining the probe result, for banners and diagnostics.
    public func detail(_ provider: Provider, paths: SwitcherPaths) -> String {
        guard loginShellProbed else { return "Login shell not checked yet." }
        let shell = loginShellName ?? "shell"
        let resolved = loginShellResolution[provider] ?? "nothing"
        if isActive(provider, paths: paths) {
            return "Your login \(shell) runs \(provider.executableName) from \(resolved); switching is in effect for new terminals."
        }
        var s = "Your login \(shell) runs \(provider.executableName) from \(resolved), not from \(paths.wrapper(provider).path)."
        let order = pathOrder(provider, paths: paths)
        if loginShellPATH.isEmpty {
            s += " The shell's PATH could not be read (slow or interactive rc file?)."
        } else if order.bin == nil {
            s += " \(paths.bin.path) is not on that PATH: the block in your rc file is missing or is overwritten by a later PATH assignment."
        } else if let real = order.real, let bin = order.bin, real < bin {
            s += " \(paths.bin.path) is on the PATH but after the real executable's directory; move the aiswitch block to the end of your rc file."
        }
        return s
    }
}

public struct ShellIntegrationOptions: Equatable, Sendable {
    public var rcFiles: [URL]
    public var addPathBlock: Bool
    /// Explicit executables (otherwise detected from the login-shell PATH).
    public var executables: [Provider: String]

    public init(rcFiles: [URL], addPathBlock: Bool = true, executables: [Provider: String] = [:]) {
        self.rcFiles = rcFiles
        self.addPathBlock = addPathBlock
        self.executables = executables
    }
}

public enum ShellIntegrationError: Error, LocalizedError, Equatable {
    case executableIsWrapper(String)
    case executableMissing(Provider)

    public var errorDescription: String? {
        switch self {
        case .executableIsWrapper(let p): return "\(p) is an aiswitch wrapper, not the real CLI"
        case .executableMissing(let p): return "No \(p.executableName) executable found. Install \(p.displayName) first."
        }
    }
}

/// Native counterpart of Scripts/install-shell-integration.sh. Installs wrappers, records real executables,
/// edits rc files (with backups) and verifies the result in a real login shell.
public final class ShellIntegrationManager: @unchecked Sendable {
    public let paths: SwitcherPaths
    private let runner: ProcessRunning
    private let environment: [String: String]
    private let fm = FileManager.default

    public init(paths: SwitcherPaths, runner: ProcessRunning = ProcessRunner(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.runner = runner
        self.environment = environment
    }

    public static let commonExecutableDirs = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.claude/local", "~/.npm-global/bin", "~/.volta/bin", "~/.bun/bin"]

    public func defaultRCFiles() -> [URL] {
        var files = [paths.home.appendingPathComponent(".zshrc")]
        let shell = (environment["SHELL"] ?? "").split(separator: "/").last.map(String.init) ?? "zsh"
        if shell == "bash" { files.append(paths.home.appendingPathComponent(".bashrc")) }
        return files
    }

    public func isWrapper(_ path: String) -> Bool {
        guard let data = fm.contents(atPath: path), data.count < 64 * 1024 else { return false }
        return String(decoding: data, as: UTF8.self).contains("AISWITCH_WRAPPER_VERSION")
    }

    public func wrapperVersion(at path: String) -> Int? {
        guard let data = fm.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("AISWITCH_WRAPPER_VERSION=") {
            return Int(line.dropFirst("AISWITCH_WRAPPER_VERSION=".count))
        }
        return nil
    }

    private func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Finds the real CLI on a PATH string (defaults to this process' PATH), skipping our bin dir and any wrapper.
    public func detectExecutable(_ provider: Provider, searchPath: String? = nil) -> String? {
        let binResolved = resolved(paths.bin.path)
        let path = searchPath ?? environment["PATH"] ?? ""
        for dir in path.split(separator: ":").map(String.init) {
            let d = dir.isEmpty ? "." : dir
            let candidate = (d as NSString).appendingPathComponent(provider.executableName)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue, fm.isExecutableFile(atPath: candidate) else { continue }
            if resolved(d) == binResolved || isWrapper(candidate) { continue }
            return candidate
        }
        for dir in Self.commonExecutableDirs {
            let expanded = dir.hasPrefix("~") ? paths.home.path + dir.dropFirst() : dir
            let candidate = (expanded as NSString).appendingPathComponent(provider.executableName)
            if fm.isExecutableFile(atPath: candidate), !isWrapper(candidate) { return candidate }
        }
        return nil
    }

    public func recordedExecutable(_ provider: Provider) -> String? {
        guard let p = AtomicFile.readLine(paths.realExecutableFile(provider)) else { return nil }
        return p
    }

    /// Recorded path if still valid, otherwise a fresh detection.
    public func effectiveExecutable(_ provider: Provider, searchPath: String? = nil) -> String? {
        if let p = recordedExecutable(provider), fm.isExecutableFile(atPath: p), !isWrapper(p) { return p }
        return detectExecutable(provider, searchPath: searchPath)
    }

    public func recordExecutable(_ provider: Provider, path: String) throws {
        guard !isWrapper(path) else { throw ShellIntegrationError.executableIsWrapper(path) }
        try AtomicFile.write(path + "\n", to: paths.realExecutableFile(provider), permissions: 0o600)
    }

    // MARK: install / uninstall

    @discardableResult
    public func install(_ options: ShellIntegrationOptions, searchPath: String? = nil) throws -> ShellIntegrationStatus {
        try paths.ensureLayout()
        for provider in Provider.allCases {
            if let explicit = options.executables[provider] {
                try recordExecutable(provider, path: explicit)
            } else if let found = effectiveExecutable(provider, searchPath: searchPath) {
                try recordExecutable(provider, path: found)
            }
        }
        for provider in Provider.allCases {
            try AtomicFile.write(EmbeddedScripts.wrapper + "\n", to: paths.wrapper(provider), permissions: 0o755)
        }
        try AtomicFile.write(EmbeddedScripts.statusLine + "\n", to: paths.statusLineBeacon, permissions: 0o755)
        if options.addPathBlock {
            let stamp = Self.timestamp()
            for rc in options.rcFiles {
                try addBlock(to: rc, backupStamp: stamp)
            }
        }
        SwitcherLog.shared.log("shell integration installed (rc: \(options.rcFiles.map(\.path)))", category: "shell")
        return status()
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    private func addBlock(to rc: URL, backupStamp: String) throws {
        let backupDir = paths.backups.appendingPathComponent(backupStamp, isDirectory: true)
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let pointer = paths.rcBackupPointer(rcName: rc.lastPathComponent)
        var existing = ""
        if fm.fileExists(atPath: rc.path) {
            existing = (try? String(contentsOf: rc, encoding: .utf8)) ?? ""
            let backup = backupDir.appendingPathComponent(rc.lastPathComponent)
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: rc, to: backup)
            try AtomicFile.write(backup.path + "\n", to: pointer, permissions: 0o600)
        } else {
            try AtomicFile.write("(none: \(rc.path) did not exist before install)\n", to: pointer, permissions: 0o600)
        }
        let updated = RCFileEditor.addingBlock(existing, pathExpr: paths.binPathExpression)
        let perms = (try? fm.attributesOfItem(atPath: rc.path)[.posixPermissions] as? Int) ?? 0o644
        try AtomicFile.write(updated, to: rc, permissions: perms)
    }

    public func uninstall(rcFiles: [URL], restoreBackups: Bool = false, purgeEverything: Bool = false) throws {
        for rc in rcFiles {
            guard fm.fileExists(atPath: rc.path) else { continue }
            if restoreBackups, let pointer = AtomicFile.readLine(paths.rcBackupPointer(rcName: rc.lastPathComponent)) {
                if pointer.hasPrefix("(none") {
                    try fm.removeItem(at: rc)
                    continue
                } else if fm.fileExists(atPath: pointer) {
                    let data = try Data(contentsOf: URL(fileURLWithPath: pointer))
                    let perms = (try? fm.attributesOfItem(atPath: rc.path)[.posixPermissions] as? Int) ?? 0o644
                    try AtomicFile.write(data, to: rc, permissions: perms)
                    continue
                }
            }
            let content = (try? String(contentsOf: rc, encoding: .utf8)) ?? ""
            if RCFileEditor.containsBlock(content) {
                let perms = (try? fm.attributesOfItem(atPath: rc.path)[.posixPermissions] as? Int) ?? 0o644
                try AtomicFile.write(RCFileEditor.removingBlock(content), to: rc, permissions: perms)
            }
        }
        for provider in Provider.allCases {
            let w = paths.wrapper(provider)
            if fm.fileExists(atPath: w.path), isWrapper(w.path) { try fm.removeItem(at: w) }
        }
        if fm.fileExists(atPath: paths.statusLineBeacon.path) { try? fm.removeItem(at: paths.statusLineBeacon) }
        if purgeEverything, paths.root.path.count > 5, fm.fileExists(atPath: paths.root.path) {
            try fm.removeItem(at: paths.root)
        }
        SwitcherLog.shared.log("shell integration uninstalled (restore=\(restoreBackups), purge=\(purgeEverything))", category: "shell")
    }

    // MARK: status

    public func status() -> ShellIntegrationStatus {
        var s = ShellIntegrationStatus()
        for provider in Provider.allCases {
            let w = paths.wrapper(provider).path
            let installed = fm.isExecutableFile(atPath: w) && isWrapper(w)
            s.wrapperInstalled[provider] = installed
            if installed, let v = wrapperVersion(at: w) { s.wrapperVersion[provider] = v }
            if let real = recordedExecutable(provider) { s.realExecutable[provider] = real }
        }
        s.statusLineBeaconInstalled = fm.isExecutableFile(atPath: paths.statusLineBeacon.path)
        for rc in defaultRCFiles() {
            if let content = try? String(contentsOf: rc, encoding: .utf8), RCFileEditor.containsBlock(content) {
                s.rcFilesWithBlock.append(rc.path)
            }
        }
        return s
    }

    /// Probes a real login shell. Slow (hundreds of ms); call off the main thread.
    public func verify(_ base: ShellIntegrationStatus? = nil, shell: LoginShell? = nil) -> ShellIntegrationStatus {
        var s = base ?? status()
        let login = shell ?? LoginShell(environment: environment, runner: runner)
        for provider in Provider.allCases {
            if let r = login.resolve(provider.executableName) { s.loginShellResolution[provider] = r }
        }
        s.loginShellPATH = login.pathEntries()
        s.loginShellName = login.shellName
        s.loginShellProbed = true
        return s
    }

    /// Dry-runs the installed wrapper and returns its resolution (what a new `claude` would do right now).
    public func wrapperResolution(_ provider: Provider, extraEnvironment: [String: String] = [:]) -> [String: String]? {
        let w = paths.wrapper(provider).path
        guard fm.isExecutableFile(atPath: w) else { return nil }
        var env = environment
        env["AISWITCH_PRINT_RESOLUTION"] = "1"
        env["AISWITCH_HOME"] = paths.root.path
        env["HOME"] = paths.home.path
        for (k, v) in extraEnvironment { env[k] = v }
        guard let r = try? runner.run("/bin/sh", arguments: [w], environment: env, currentDirectory: nil, input: nil, timeout: 10), r.exitCode == 0 else { return nil }
        var out: [String: String] = [:]
        for line in r.stdout.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return out
    }
}
