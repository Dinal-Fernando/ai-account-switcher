import Foundation
import SwitcherCore
import SwitcherMac

/// `aiswitch` — command-line companion of AI Account Switcher. Shares all logic with the app.
@main
struct AISwitchCLI {
    static let usage = """
    aiswitch \(SwitcherRuntime.version) — switch the account used by `claude` and `codex`

    USAGE
      aiswitch status                         active accounts, shell integration, cached auth
      aiswitch list [claude|codex]            all accounts
      aiswitch use <claude|codex> <name|id>   make an account active for future CLI launches (atomic)
      aiswitch which <claude|codex>           what the wrapper will run right now (binary, profile, identity)
      aiswitch add <claude|codex> <name> [--no-copy]
                                              create an isolated profile (then run `aiswitch login`)
      aiswitch login <claude|codex> <name|id> [--device]
                                              run the vendor's browser login inside that profile, here in this terminal
      aiswitch auth [claude|codex] [name|id]  re-check sign-in state with the vendor CLI
      aiswitch usage [claude|codex]           fetch quota for all (or one provider's) accounts
      aiswitch sessions <claude|codex> [name|id]   stored conversations (id, age, size, folder, title)
      aiswitch copy-session <claude|codex> <from> <to> <session-id> [--overwrite]
                                              copy one transcript into another account's profile
      aiswitch resume <claude|codex> <name|id> <session-id>
                                              resume a conversation under that account, here in this terminal
      aiswitch beacon claude <name|id> on|off|status
                                              live usage from Claude Code's status line for that account
      aiswitch rename <claude|codex> <name|id> <new name>
      aiswitch remove <claude|codex> <name|id> [--delete-dir]
      aiswitch doctor [--quick]               diagnostics (quick = no shell/auth probing)
      aiswitch install-shell [--no-rc] [--rc FILE]...
      aiswitch uninstall-shell [--restore] [--purge]
      aiswitch version

    ENVIRONMENT
      AISWITCH_HOME   state root (default ~/.aiswitch)
    """

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { print(usage); exit(2) }
        args.removeFirst()
        let flags = Set(args.filter { $0.hasPrefix("--") })
        let positional = args.filter { !$0.hasPrefix("--") }
        let quick = flags.contains("--quick")
        let needsShell = !["version", "list", "use", "which", "add", "rename", "remove", "install-shell", "uninstall-shell", "sessions", "copy-session", "beacon"].contains(command) && !quick
        let runtime = SwitcherRuntime(captureLoginShell: needsShell)
        do {
            switch command {
            case "version", "--version", "-v": print("aiswitch \(SwitcherRuntime.version)")
            case "help", "--help", "-h": print(usage)
            case "status": await status(runtime)
            case "list": list(runtime, provider: positional.first.flatMap(Provider.init(rawValue:)))
            case "use": try await use(runtime, positional)
            case "which": try await which(runtime, positional)
            case "add": try add(runtime, positional, copy: !flags.contains("--no-copy"))
            case "login": try await login(runtime, positional, device: flags.contains("--device"))
            case "auth": try await auth(runtime, positional)
            case "usage": try await usageCommand(runtime, positional)
            case "sessions": try sessionsCommand(runtime, positional)
            case "copy-session": try copySession(runtime, positional, overwrite: flags.contains("--overwrite"))
            case "resume": try resumeCommand(runtime, positional)
            case "beacon": try beaconCommand(runtime, positional)
            case "rename": try rename(runtime, positional)
            case "remove": try remove(runtime, positional, deleteDir: flags.contains("--delete-dir"))
            case "doctor": await doctor(runtime, quick: quick)
            case "install-shell": try installShell(runtime, args)
            case "uninstall-shell": try uninstallShell(runtime, restore: flags.contains("--restore"), purge: flags.contains("--purge"))
            default:
                FileHandle.standardError.write(Data("unknown command: \(command)\n\n\(usage)\n".utf8))
                exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    // MARK: helpers

    static func provider(_ positional: [String], at index: Int = 0) throws -> Provider {
        guard positional.count > index, let p = Provider(rawValue: positional[index].lowercased()) else {
            throw CLIError("expected 'claude' or 'codex'")
        }
        return p
    }

    static func account(_ runtime: SwitcherRuntime, _ positional: [String], providerIndex: Int = 0, nameIndex: Int = 1) throws -> Account {
        let p = try provider(positional, at: providerIndex)
        guard positional.count > nameIndex else { throw CLIError("expected an account name or id") }
        guard let a = runtime.accounts.find(provider: p, nameOrId: positional[nameIndex]) else {
            throw CLIError("no \(p.shortName) account named '\(positional[nameIndex])' (see `aiswitch list`)")
        }
        return a
    }

    static func pct(_ w: UsageWindow?) -> String {
        guard let w else { return "  —  " }
        return String(format: "%3.0f%%", w.usedPercent)
    }

    static func countdown(_ w: UsageWindow?) -> String {
        guard let w, let secs = w.secondsUntilReset() else { return "" }
        let mins = Int(ceil(secs / 60))
        if mins < 60 { return "\(mins)m left" }
        let h = mins / 60
        if h < 48 { return "\(h)h \(mins % 60)m left" }
        return "\(h / 24)d \(h % 24)h left"
    }

    // MARK: commands

    static func status(_ runtime: SwitcherRuntime) async {
        let shellStatus = runtime.shell.verify()
        for p in Provider.allCases {
            let active = runtime.accounts.activeAccount(for: p)
            let name = active?.name ?? "(default)"
            let who = active?.identity?.summary ?? ""
            let auth = active?.lastAuth?.displayLabel ?? "not checked"
            print("\(p.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)) active: \(name)\(who.isEmpty ? "" : " [\(who)]")  auth: \(auth)")
            let wrapper = shellStatus.wrapperInstalled[p] == true
            let resolved = shellStatus.loginShellResolution[p] ?? "(not found)"
            let live = shellStatus.isActive(p, paths: runtime.paths)
            print("             wrapper: \(wrapper ? "installed" : "MISSING")  login shell runs: \(resolved)  → \(live ? "switching active" : "switching NOT in effect")")
        }
    }

    static func list(_ runtime: SwitcherRuntime, provider: Provider?) {
        for p in Provider.allCases where provider == nil || provider == p {
            let activeId = runtime.active.activeProfileId(for: p)
            print("\(p.displayName):")
            for a in runtime.accounts.accounts(for: p) {
                let mark = a.id == activeId ? "*" : " "
                let who = a.identity?.summary ?? ""
                let auth = a.lastAuth?.displayLabel ?? "unchecked"
                print("  \(mark) \(a.name.padding(toLength: 28, withPad: " ", startingAt: 0)) id=\(a.id.padding(toLength: 18, withPad: " ", startingAt: 0)) \(auth)\(who.isEmpty ? "" : "  \(who)")")
            }
        }
    }

    static func use(_ runtime: SwitcherRuntime, _ positional: [String]) async throws {
        let a = try account(runtime, positional)
        try runtime.active.setActive(provider: a.provider, profileId: a.id)
        print("\(a.provider.displayName): '\(a.name)' is now the active account for new `\(a.provider.executableName)` launches.")
        let auth = await runtime.verify(a)
        print("  auth: \(auth.displayLabel)\(auth.message.map { " — \($0)" } ?? "")")
        for w in auth.warnings { print("  warning: \(w)") }
        if !auth.isAuthenticated { print("  run `aiswitch login \(a.provider.rawValue) \(ShellQuote.single(a.name))` to sign in.") }
        let s = runtime.shell.status()
        if s.wrapperInstalled[a.provider] != true { print("  note: the shell wrapper is not installed, so Terminal still uses ~/\(a.provider.defaultConfigDirName). Run `aiswitch install-shell`.") }
    }

    static func which(_ runtime: SwitcherRuntime, _ positional: [String]) async throws {
        let p = try provider(positional)
        guard let res = runtime.shell.wrapperResolution(p) else {
            print("wrapper for \(p.executableName) not installed; `\(p.executableName)` resolves to: \(runtime.shell.effectiveExecutable(p) ?? "(not found)") using ~/\(p.defaultConfigDirName)")
            return
        }
        for key in ["wrapper", "real", "real_resolved", "profile", "profile_source", "config_dir", "applied", "overrides"] {
            print("\(key.padding(toLength: 15, withPad: " ", startingAt: 0)) \(res[key] ?? "")")
        }
        if let acct = runtime.accounts.activeAccount(for: p) {
            print("account         \(acct.name)")
            if let id = runtime.adapter(p).identity(account: acct) { print("identity        \(id.summary)") }
        }
    }

    static func add(_ runtime: SwitcherRuntime, _ positional: [String], copy: Bool) throws {
        let p = try provider(positional)
        guard positional.count > 1 else { throw CLIError("expected a name for the new account") }
        let seed = ProfileSeedOptions(copyClaudeUserSettings: copy, copyCodexConfig: copy)
        let a = try runtime.accounts.addManagedAccount(provider: p, name: positional[1], seed: seed)
        print("created \(p.displayName) account '\(a.name)' (profile \(a.id)) at \(runtime.profiles.configDirectory(for: a).path)")
        print("next: aiswitch login \(p.rawValue) \(ShellQuote.single(a.name))")
    }

    static func login(_ runtime: SwitcherRuntime, _ positional: [String], device: Bool) async throws {
        let a = try account(runtime, positional)
        guard let exe = runtime.adapter(a.provider).executablePath() else { throw CLIError("\(a.provider.executableName) executable not found") }
        var env = runtime.context.cliEnvironment(for: a)
        env["TERM"] = ProcessInfo.processInfo.environment["TERM"] ?? "xterm-256color"
        var arguments: [String]
        switch a.provider {
        case .claude: arguments = ["auth", "login"]
        case .codex: arguments = device ? ["login", "--device-auth"] : ["login"]
        }
        print("Running \(exe) \(arguments.joined(separator: " ")) for '\(a.name)' (\(runtime.profiles.configDirectory(for: a).path))")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = arguments
        process.environment = env
        try process.run()
        process.waitUntilExit()
        print("login exited with status \(process.terminationStatus); verifying…")
        let auth = await runtime.verify(a)
        print("  auth: \(auth.displayLabel)\(auth.message.map { " — \($0)" } ?? "")")
        for w in auth.warnings { print("  warning: \(w)") }
    }

    static func auth(_ runtime: SwitcherRuntime, _ positional: [String]) async throws {
        var targets: [Account]
        if positional.count >= 2 {
            targets = [try account(runtime, positional)]
        } else if let p = positional.first.flatMap({ Provider(rawValue: $0) }) {
            targets = runtime.accounts.accounts(for: p)
        } else {
            targets = runtime.accounts.accounts
        }
        for a in targets {
            let s = await runtime.verify(a)
            let who = runtime.accounts.account(a.key)?.identity?.summary ?? ""
            print("\(a.provider.shortName.padding(toLength: 7, withPad: " ", startingAt: 0)) \(a.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(s.displayLabel)\(who.isEmpty ? "" : "  \(who)")")
            for w in s.warnings { print("        warning: \(w)") }
        }
    }

    static func usageCommand(_ runtime: SwitcherRuntime, _ positional: [String]) async throws {
        let filter = positional.first.flatMap { Provider(rawValue: $0) }
        let targets = runtime.accounts.accounts.filter { filter == nil || $0.provider == filter }
        await runtime.monitor.load(accounts: targets)
        let states = await runtime.monitor.refreshAll(targets, force: true)
        print("provider  account                      5-hour  weekly  status")
        for a in targets {
            let s = states[a.key] ?? AccountUsageState()
            let snap = s.effectiveSnapshot
            var line = "\(a.provider.shortName.padding(toLength: 9, withPad: " ", startingAt: 0)) \(a.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(pct(snap?.fiveHour))   \(pct(snap?.weekly))   \(s.status.shortLabel)"
            if let d = s.status.detail { line += " — \(d)" }
            print(line)
            if let snap {
                for m in snap.modelWindows { print("          \(m.label.padding(toLength: 28, withPad: " ", startingAt: 0)) \(pct(m))   \(countdown(m))") }
                if let f = snap.fiveHour { print("          5-hour resets: \(countdown(f))") }
                if let w = snap.weekly { print("          weekly resets: \(countdown(w))") }
                if let c = snap.credits { print("          credits: \(c.unlimited ? "unlimited" : (c.balance.map { String(format: "%.2f", $0) } ?? (c.hasCredits ? "available" : "none")))") }
                if let e = snap.extraUsage, e.enabled { print("          extra usage: \(e.usedCredits.map { String(format: "%.2f", $0) } ?? "?") / \(e.monthlyLimit.map { String(format: "%.2f", $0) } ?? "?") \(e.currency ?? "")") }
            }
        }
    }

    static func sessionsCommand(_ runtime: SwitcherRuntime, _ positional: [String]) throws {
        let p = try provider(positional)
        let targets = positional.count > 1 ? [try account(runtime, positional)] : runtime.accounts.accounts(for: p)
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        for a in targets {
            let list = runtime.sessions(for: a)
            print("\(a.name) (\(runtime.profiles.configDirectory(for: a).path)): \(list.count) session(s)")
            for s in list {
                let size = ByteCountFormatter.string(fromByteCount: Int64(s.sizeBytes), countStyle: .file)
                print("  \(s.id)  \(f.string(from: s.modifiedAt))  \(String(s.messageCount).padding(toLength: 4, withPad: " ", startingAt: 0)) msgs  \(size.padding(toLength: 8, withPad: " ", startingAt: 0))  \(s.folderName)")
                print("      \(s.title)")
            }
        }
    }

    static func copySession(_ runtime: SwitcherRuntime, _ positional: [String], overwrite: Bool) throws {
        guard positional.count >= 4 else { throw CLIError("usage: aiswitch copy-session <claude|codex> <from> <to> <session-id>") }
        let p = try provider(positional)
        guard let from = runtime.accounts.find(provider: p, nameOrId: positional[1]) else { throw CLIError("no \(p.shortName) account '\(positional[1])'") }
        guard let to = runtime.accounts.find(provider: p, nameOrId: positional[2]) else { throw CLIError("no \(p.shortName) account '\(positional[2])'") }
        let id = positional[3]
        guard let session = runtime.sessions(for: from, limit: 10_000).first(where: { $0.id.lowercased() == id.lowercased() }) else {
            throw CLIError("session \(id) not found in '\(from.name)' (see `aiswitch sessions \(p.rawValue)`)")
        }
        let copy = try runtime.duplicate(session, to: to, overwrite: overwrite)
        print("copied to \(copy.fileURL.path)")
        print("resume with: aiswitch resume \(p.rawValue) \(ShellQuote.single(to.name)) \(session.id)")
    }

    static func resumeCommand(_ runtime: SwitcherRuntime, _ positional: [String]) throws {
        guard positional.count >= 3 else { throw CLIError("usage: aiswitch resume <claude|codex> <account> <session-id>") }
        let a = try account(runtime, positional)
        let id = positional[2]
        guard let session = runtime.sessions(for: a, limit: 10_000).first(where: { $0.id.lowercased() == id.lowercased() }) else {
            if let elsewhere = runtime.findSession(id: id, provider: a.provider) {
                throw CLIError("session \(id) belongs to account '\(elsewhere.accountId)'. Copy it first: aiswitch copy-session \(a.provider.rawValue) \(ShellQuote.single(elsewhere.accountId)) \(ShellQuote.single(a.name)) \(id)")
            }
            throw CLIError("session \(id) not found in any \(a.provider.displayName) profile")
        }
        guard let exe = runtime.adapter(a.provider).executablePath() else { throw CLIError("\(a.provider.executableName) executable not found") }
        var env = runtime.context.cliEnvironment(for: a)
        env["TERM"] = ProcessInfo.processInfo.environment["TERM"] ?? "xterm-256color"
        env[a.provider.profileOverrideEnvVar] = a.id
        let cwd = FileManager.default.fileExists(atPath: session.cwd) ? session.cwd : FileManager.default.homeDirectoryForCurrentUser.path
        print("Resuming \(session.id) under '\(a.name)' in \(cwd)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = session.resumeArguments
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        try process.run()
        process.waitUntilExit()
        exit(process.terminationStatus)
    }

    static func beaconCommand(_ runtime: SwitcherRuntime, _ positional: [String]) throws {
        let a = try account(runtime, positional)
        guard a.provider == .claude else { throw CLIError("the status-line beacon is a Claude Code feature") }
        let action = positional.count > 2 ? positional[2] : "status"
        switch action {
        case "on":
            if !FileManager.default.isExecutableFile(atPath: runtime.paths.statusLineBeacon.path) {
                try AtomicFile.write(EmbeddedScripts.statusLine + "\n", to: runtime.paths.statusLineBeacon, permissions: 0o755)
            }
            try runtime.profiles.installStatusLineBeacon(for: a)
            var updated = a; updated.statusLineBeacon = true; try runtime.accounts.update(updated)
            print("live usage on for '\(a.name)' (\(runtime.profiles.claudeSettingsFile(for: a).path))")
        case "off":
            try runtime.profiles.removeStatusLineBeacon(for: a)
            var updated = a; updated.statusLineBeacon = false; try runtime.accounts.update(updated)
            print("live usage off for '\(a.name)'")
        default:
            let on = runtime.profiles.statusLineBeaconInstalled(for: a)
            print("'\(a.name)': live usage \(on ? "on" : "off")")
            if let chained = AtomicFile.readLine(runtime.paths.statusLineChainFile(profileId: a.id)) { print("chained status line: \(chained)") }
            print("beacon file: \(runtime.paths.statusLineBeaconFile(profileId: a.id).path)")
        }
    }

    static func rename(_ runtime: SwitcherRuntime, _ positional: [String]) throws {
        let a = try account(runtime, positional)
        guard positional.count > 2 else { throw CLIError("expected the new name") }
        try runtime.accounts.rename(a.key, to: positional[2...].joined(separator: " "))
        print("renamed")
    }

    static func remove(_ runtime: SwitcherRuntime, _ positional: [String], deleteDir: Bool) throws {
        let a = try account(runtime, positional)
        try runtime.accounts.remove(a.key, deleteProfileDirectory: deleteDir)
        print("removed '\(a.name)'\(deleteDir ? " and deleted its profile directory" : " (profile directory kept at \(runtime.profiles.configDirectory(for: a).path))")")
    }

    static func doctor(_ runtime: SwitcherRuntime, quick: Bool) async {
        let report = await runtime.doctor(probeShell: !quick, probeAuth: !quick).run()
        print(report.text)
        if report.hasFailures { exit(1) }
    }

    static func installShell(_ runtime: SwitcherRuntime, _ args: [String]) throws {
        var rcFiles: [URL] = []
        var i = 0
        while i < args.count {
            if args[i] == "--rc", i + 1 < args.count { rcFiles.append(URL(fileURLWithPath: args[i + 1])); i += 2 } else { i += 1 }
        }
        if rcFiles.isEmpty { rcFiles = runtime.shell.defaultRCFiles() }
        let options = ShellIntegrationOptions(rcFiles: rcFiles, addPathBlock: !args.contains("--no-rc"))
        let status = try runtime.shell.install(options, searchPath: runtime.loginEnvironment["PATH"])
        for p in Provider.allCases {
            print("\(p.executableName): wrapper \(status.wrapperInstalled[p] == true ? "installed" : "FAILED") at \(runtime.paths.wrapper(p).path); real = \(status.realExecutable[p] ?? "(not found: install \(p.displayName))")")
        }
        print("rc files updated: \(options.addPathBlock ? rcFiles.map(\.path).joined(separator: ", ") : "(skipped)")")
        let verified = runtime.shell.verify(status)
        for p in Provider.allCases {
            print("login shell resolves \(p.executableName) → \(verified.loginShellResolution[p] ?? "(nothing)") \(verified.isActive(p, paths: runtime.paths) ? "✓" : "(open a new terminal, or check PATH order)")")
        }
    }

    static func uninstallShell(_ runtime: SwitcherRuntime, restore: Bool, purge: Bool) throws {
        if purge {
            print("This deletes \(runtime.paths.root.path) including every profile and login created here. Type 'purge' to confirm: ", terminator: "")
            guard readLine() == "purge" else { print("aborted"); return }
        }
        try runtime.shell.uninstall(rcFiles: runtime.shell.defaultRCFiles(), restoreBackups: restore, purgeEverything: purge)
        print("shell integration removed\(restore ? " (rc files restored from install-time backups)" : "")\(purge ? "; all data purged" : "")")
    }
}

struct CLIError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
