import XCTest
@testable import SwitcherCore

final class ShellIntegrationTests: XCTestCase {
    func testEmbeddedScriptsMatchRepositoryFiles() throws {
        let root = TempEnvironment.repoRoot()
        let wrapper = try String(contentsOf: root.appendingPathComponent("Wrapper/aiswitch-wrapper.sh"), encoding: .utf8)
        let statusline = try String(contentsOf: root.appendingPathComponent("Wrapper/aiswitch-statusline.sh"), encoding: .utf8)
        XCTAssertEqual(EmbeddedScripts.wrapper + "\n", wrapper, "run Scripts/sync-embedded-scripts.py")
        XCTAssertEqual(EmbeddedScripts.statusLine + "\n", statusline, "run Scripts/sync-embedded-scripts.py")
        XCTAssertTrue(wrapper.contains("AISWITCH_WRAPPER_VERSION=\(EmbeddedScripts.wrapperVersion)"))
    }

    func testRCFileEditorRoundTrip() {
        let original = "# my zshrc\nexport FOO=bar\n"
        let added = RCFileEditor.addingBlock(original, pathExpr: "$HOME/.aiswitch/bin")
        XCTAssertTrue(RCFileEditor.containsBlock(added))
        XCTAssertTrue(added.hasPrefix(original + "\n# >>> aiswitch >>>\n"))
        XCTAssertTrue(added.contains("export PATH=\"$HOME/.aiswitch/bin:$PATH\""))
        XCTAssertTrue(added.contains("claude() { if [ -x \"$HOME/.aiswitch/bin/claude\" ]; then \"$HOME/.aiswitch/bin/claude\" \"$@\"; else command claude \"$@\"; fi; }"))
        XCTAssertTrue(added.contains("codex() {"))
        XCTAssertEqual(RCFileEditor.addingBlock(added, pathExpr: "$HOME/.aiswitch/bin"), added, "idempotent")
        XCTAssertEqual(RCFileEditor.removingBlock(added), original, "byte-identical after removal")
        XCTAssertEqual(RCFileEditor.removingBlock(""), "")
        XCTAssertEqual(RCFileEditor.removingBlock("x"), "x\n")
        let blockOnly = RCFileEditor.addingBlock("", pathExpr: "/x/bin")
        XCTAssertEqual(RCFileEditor.removingBlock(blockOnly), "")
        // user content after the block survives
        let edited = added + "alias ll='ls -l'\n"
        XCTAssertEqual(RCFileEditor.removingBlock(edited), original + "alias ll='ls -l'\n")
    }

    func testInstallRecordsRealBinariesAndWritesWrappers() throws {
        let env = TempEnvironment()
        let claude = env.makeFakeExecutable("claude")
        let codex = env.makeFakeExecutable("codex")
        let fakebin = (claude as NSString).deletingLastPathComponent
        let rc = env.home.appendingPathComponent(".zshrc")
        try "export FOO=bar\n".write(to: rc, atomically: true, encoding: .utf8)
        let sh = ShellIntegrationManager(paths: env.paths, environment: ["PATH": fakebin + ":/usr/bin:/bin", "HOME": env.home.path, "SHELL": "/bin/zsh"])
        let status = try sh.install(ShellIntegrationOptions(rcFiles: [rc], addPathBlock: true))
        XCTAssertEqual(status.wrapperInstalled[.claude], true)
        XCTAssertEqual(status.wrapperInstalled[.codex], true)
        XCTAssertEqual(status.wrapperVersion[.claude], EmbeddedScripts.wrapperVersion)
        XCTAssertEqual(status.realExecutable[.claude], claude)
        XCTAssertEqual(status.realExecutable[.codex], codex)
        XCTAssertEqual(posixMode(env.paths.wrapper(.claude).path), 0o755)
        XCTAssertEqual(posixMode(env.paths.realExecutableFile(.claude).path), 0o600)
        XCTAssertTrue(status.statusLineBeaconInstalled)
        let rcContent = try String(contentsOf: rc, encoding: .utf8)
        XCTAssertTrue(RCFileEditor.containsBlock(rcContent))
        XCTAssertTrue(rcContent.contains("export FOO=bar"))
        let pointer = AtomicFile.readLine(env.paths.rcBackupPointer(rcName: ".zshrc"))!
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: pointer), encoding: .utf8), "export FOO=bar\n")
        // installing again keeps one block and does not re-point to a wrapper
        _ = try sh.install(ShellIntegrationOptions(rcFiles: [rc], addPathBlock: true))
        XCTAssertEqual(try String(contentsOf: rc, encoding: .utf8).components(separatedBy: RCFileEditor.blockBegin).count - 1, 1)
        XCTAssertEqual(sh.recordedExecutable(.claude), claude)
        // the detector skips wrappers even when they come first in PATH
        let detected = sh.detectExecutable(.claude, searchPath: env.paths.bin.path + ":" + fakebin)
        XCTAssertEqual(detected, claude)
        XCTAssertThrowsError(try sh.recordExecutable(.claude, path: env.paths.wrapper(.claude).path))
    }

    func testInstalledWrapperRoutesToSelectedProfile() throws {
        let env = TempEnvironment()
        let claude = env.makeFakeExecutable("claude")
        _ = env.makeFakeExecutable("codex")
        let fakebin = (claude as NSString).deletingLastPathComponent
        let sh = ShellIntegrationManager(paths: env.paths, environment: ["PATH": fakebin + ":/usr/bin:/bin", "HOME": env.home.path])
        _ = try sh.install(ShellIntegrationOptions(rcFiles: [], addPathBlock: false))
        let profiles = CLIProfileManager(paths: env.paths)
        let dir = try profiles.createProfileDirectory(provider: .claude, id: "work-1", options: ProfileSeedOptions(copyClaudeUserSettings: false, copyCodexConfig: false))
        try ActiveAccountManager(paths: env.paths).setActive(provider: .claude, profileId: "work-1")
        let res = try XCTUnwrap(sh.wrapperResolution(.claude))
        XCTAssertEqual(res["profile"], "work-1")
        XCTAssertEqual(res["config_dir"], dir.path)
        XCTAssertEqual(res["applied"], "yes")
        XCTAssertEqual(res["real"], claude)
        // actually exec through the wrapper and check the real binary saw the env
        let runner = ProcessRunner()
        let out = try runner.run("/bin/sh", arguments: [env.paths.wrapper(.claude).path, "hello"],
                                 environment: ["PATH": env.paths.bin.path + ":" + fakebin + ":/usr/bin:/bin", "HOME": env.home.path, "AISWITCH_HOME": env.paths.root.path],
                                 currentDirectory: nil, input: nil, timeout: 10)
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertTrue(out.stdout.contains("CLAUDE_CONFIG_DIR=\(dir.path)"), out.stdout)
        XCTAssertTrue(out.stdout.contains("ARG=hello"))
        // per-terminal override
        let over = try XCTUnwrap(sh.wrapperResolution(.claude, extraEnvironment: ["AISWITCH_CLAUDE_PROFILE": "default"]))
        XCTAssertEqual(over["profile"], "default")
        XCTAssertEqual(over["profile_source"], "env")
    }

    func testUninstallRemovesBlockAndWrappersButKeepsProfiles() throws {
        let env = TempEnvironment()
        let claude = env.makeFakeExecutable("claude")
        let fakebin = (claude as NSString).deletingLastPathComponent
        let rc = env.home.appendingPathComponent(".zshrc")
        let original = "# mine\n"
        try original.write(to: rc, atomically: true, encoding: .utf8)
        let sh = ShellIntegrationManager(paths: env.paths, environment: ["PATH": fakebin, "HOME": env.home.path])
        _ = try sh.install(ShellIntegrationOptions(rcFiles: [rc], addPathBlock: true))
        try CLIProfileManager(paths: env.paths).createProfileDirectory(provider: .claude, id: "keep-1", options: ProfileSeedOptions(copyClaudeUserSettings: false, copyCodexConfig: false))
        try sh.uninstall(rcFiles: [rc], restoreBackups: false)
        XCTAssertEqual(try String(contentsOf: rc, encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.paths.wrapper(.claude).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.paths.profileDir(.claude, "keep-1").path))
        XCTAssertEqual(sh.status().wrapperInstalled[.claude], false)
        // restore path
        _ = try sh.install(ShellIntegrationOptions(rcFiles: [rc], addPathBlock: true))
        try "alias x=y\n".write(to: rc, atomically: true, encoding: .utf8)
        try sh.uninstall(rcFiles: [rc], restoreBackups: true)
        XCTAssertEqual(try String(contentsOf: rc, encoding: .utf8), original, "restore puts back the install-time backup")
    }

    func testShellInstallerScriptAndSwiftEditorAgree() throws {
        // The bash installer and RCFileEditor must produce identical rc files.
        let env = TempEnvironment()
        let claude = env.makeFakeExecutable("claude")
        let fakebin = (claude as NSString).deletingLastPathComponent
        let rc = env.home.appendingPathComponent(".zshrc")
        let original = "# hi\n\nexport A=1\n"
        try original.write(to: rc, atomically: true, encoding: .utf8)
        let script = TempEnvironment.repoRoot().appendingPathComponent("Scripts/install-shell-integration.sh").path
        let r = try ProcessRunner().run("/bin/bash", arguments: [script, "--home", env.paths.root.path, "--rc", rc.path, "--no-verify", "--quiet"],
                                        environment: ["PATH": fakebin + ":/usr/bin:/bin", "HOME": env.home.path], currentDirectory: nil, input: nil, timeout: 30)
        XCTAssertEqual(r.exitCode, 0, r.combinedOutput)
        let fromScript = try String(contentsOf: rc, encoding: .utf8)
        XCTAssertEqual(fromScript, RCFileEditor.addingBlock(original, pathExpr: env.paths.binPathExpression))
        XCTAssertEqual(try String(contentsOf: env.paths.wrapper(.claude), encoding: .utf8), EmbeddedScripts.wrapper + "\n")
    }

    func testLoginShellResolveIgnoresAliasesAndRcChatter() {
        let runner = FakeProcessRunner()
        runner.script("zsh -l -i -c whence -p claude 2>/dev/null || command -v claude",
                      ProcessResult(exitCode: 0, stdout: "Welcome banner from .zshrc\nclaude: aliased to claude --verbose\n/Users/jane/.aiswitch/bin/claude\n", stderr: ""))
        runner.script("zsh -l -i -c printf '%s\\n' \"$PATH\"", ProcessResult(exitCode: 0, stdout: "banner\n/Users/jane/.aiswitch/bin:/opt/homebrew/bin:/usr/bin\n", stderr: ""))
        XCTAssertEqual(LoginShell.lastAbsolutePath(in: "x\nclaude: aliased to y\n/a/b\n"), "/a/b")
        XCTAssertNil(LoginShell.lastAbsolutePath(in: "nothing here"))
        // A shell whose basename is "zsh" selects the zsh snippet: fake the executable in a temp dir.
        let env = TempEnvironment()
        let fakeZsh = env.makeFakeExecutable("zsh")
        let login = LoginShell(shellPath: fakeZsh, environment: [:], runner: runner)
        XCTAssertEqual(login.shellName, "zsh")
        XCTAssertEqual(login.resolve("claude"), "/Users/jane/.aiswitch/bin/claude")
        XCTAssertEqual(login.pathEntries(), ["/Users/jane/.aiswitch/bin", "/opt/homebrew/bin", "/usr/bin"])
    }

    func testIsActiveUsesResolutionOrPathOrder() {
        let env = TempEnvironment()
        var s = ShellIntegrationStatus()
        s.wrapperInstalled[.claude] = true
        s.realExecutable[.claude] = "/opt/homebrew/bin/claude"
        s.loginShellProbed = true
        // exact resolution to the wrapper
        s.loginShellResolution[.claude] = env.paths.wrapper(.claude).path
        XCTAssertTrue(s.isActive(.claude, paths: env.paths))
        // resolution points elsewhere (alias/function quirk) but PATH order puts our bin first → still active
        s.loginShellResolution[.claude] = "/opt/homebrew/bin/claude"
        s.loginShellPATH = [env.paths.bin.path, "/opt/homebrew/bin", "/usr/bin"]
        XCTAssertTrue(s.isActive(.claude, paths: env.paths))
        XCTAssertTrue(s.detail(.claude, paths: env.paths).contains("switching is in effect"))
        // our bin after the real dir → inactive, with an actionable explanation
        s.loginShellPATH = ["/opt/homebrew/bin", env.paths.bin.path]
        XCTAssertFalse(s.isActive(.claude, paths: env.paths))
        XCTAssertTrue(s.detail(.claude, paths: env.paths).contains("after the real executable"))
        // bin dir missing from PATH
        s.loginShellPATH = ["/opt/homebrew/bin", "/usr/bin"]
        XCTAssertFalse(s.isActive(.claude, paths: env.paths))
        XCTAssertTrue(s.detail(.claude, paths: env.paths).contains("not on that PATH"))
        // tilde entries are expanded
        s.loginShellPATH = ["~/" + env.paths.bin.path.dropFirst(env.home.path.count + 1), "/opt/homebrew/bin"]
        XCTAssertTrue(s.isActive(.claude, paths: env.paths))
        // the functional probe is decisive in both directions
        s.loginShellPATH = ["/opt/homebrew/bin", "/usr/bin"]
        s.loginShellWrapperRan[.claude] = true
        s.loginShellWrapperResolution[.claude] = ["wrapper_version": "1", "profile": "work-1"]
        XCTAssertTrue(s.isActive(.claude, paths: env.paths), "shell functions can make the wrapper win even with a bad PATH order")
        XCTAssertTrue(s.detail(.claude, paths: env.paths).contains("profile work-1"))
        s.loginShellWrapperRan[.claude] = false
        s.loginShellPATH = [env.paths.bin.path, "/opt/homebrew/bin"]
        XCTAssertFalse(s.isActive(.claude, paths: env.paths), "an alias or function running the real binary beats PATH order")
        XCTAssertTrue(s.detail(.claude, paths: env.paths).contains("Repair"))
        s.loginShellWrapperRan = [:]
        // wrapper not installed → never active
        s.wrapperInstalled[.claude] = false
        XCTAssertFalse(s.isActive(.claude, paths: env.paths))
    }

    func testWrapperProbeParsesWrapperOutputAndDetectsRealBinary() {
        let env = TempEnvironment()
        let runner = FakeProcessRunner()
        let zsh = env.makeFakeExecutable("zsh")
        runner.script("zsh -l -i -c AISWITCH_PRINT_RESOLUTION=1 claude --version",
                      ProcessResult(exitCode: 0, stdout: "motd\nwrapper_version=1\ntool=claude\nprofile=work-1\napplied=yes\n", stderr: ""))
        runner.script("zsh -l -i -c AISWITCH_PRINT_RESOLUTION=1 codex --version", ProcessResult(exitCode: 0, stdout: "codex-cli 0.166.0\n", stderr: ""))
        let login = LoginShell(shellPath: zsh, environment: [:], runner: runner)
        let claude = login.wrapperProbe("claude")
        XCTAssertEqual(claude?["profile"], "work-1")
        XCTAssertEqual(claude?["wrapper_version"], "1")
        XCTAssertEqual(login.wrapperProbe("codex"), [:], "real binary answered: wrapper not in effect")
        XCTAssertNil(login.wrapperProbe("nothing"), "scripted default is a failure")
    }

    func testLoginShellEnvParsing() {
        let env = LoginShell.parseEnv("PATH=/a:/b\nFOO=bar=baz\nMULTI=line1\nline2\n_X=1\n9bad=no\n")
        XCTAssertEqual(env["PATH"], "/a:/b")
        XCTAssertEqual(env["FOO"], "bar=baz")
        XCTAssertEqual(env["MULTI"], "line1\nline2")
        XCTAssertEqual(env["_X"], "1")
        XCTAssertNil(env["9bad"])
    }
}
