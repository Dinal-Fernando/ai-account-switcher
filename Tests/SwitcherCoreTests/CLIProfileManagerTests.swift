import XCTest
@testable import SwitcherCore

final class CLIProfileManagerTests: XCTestCase {
    func testSlugAndIdGeneration() {
        XCTAssertEqual(CLIProfileManager.slug("Claude Work"), "claude-work")
        XCTAssertEqual(CLIProfileManager.slug("  Émilie's  Codex!! "), "milie-s-codex")
        XCTAssertEqual(CLIProfileManager.slug("###"), "account")
        let env = TempEnvironment()
        let m = CLIProfileManager(paths: env.paths)
        let id = m.makeProfileId(from: "Claude Work", existing: [])
        XCTAssertTrue(id.hasPrefix("claude-work-"))
        XCTAssertTrue(ActiveAccountManager.isValidProfileId(id))
        XCTAssertEqual(id.count, "claude-work-".count + 4)
    }

    func testCreateProfileDirectoriesAreIsolatedAndPrivate() throws {
        let env = TempEnvironment()
        let m = CLIProfileManager(paths: env.paths)
        let claudeDir = try m.createProfileDirectory(provider: .claude, id: "work-1", options: ProfileSeedOptions(copyClaudeUserSettings: false, copyCodexConfig: false))
        XCTAssertEqual(posixMode(claudeDir.path), 0o700)
        let codexDir = try m.createProfileDirectory(provider: .codex, id: "work-1")
        XCTAssertEqual(posixMode(codexDir.path), 0o700)
        let toml = try String(contentsOf: codexDir.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(toml.contains("cli_auth_credentials_store = \"file\""))
        XCTAssertEqual(posixMode(codexDir.appendingPathComponent("config.toml").path), 0o600)
        XCTAssertThrowsError(try m.createProfileDirectory(provider: .codex, id: "work-1"), "duplicate")
        XCTAssertThrowsError(try m.createProfileDirectory(provider: .codex, id: "default"))
        XCTAssertThrowsError(try m.createProfileDirectory(provider: .codex, id: "../x"))
        let account = Account(id: "work-1", provider: .claude, name: "Work", kind: .managed)
        XCTAssertEqual(m.configDirectory(for: account), claudeDir)
        XCTAssertEqual(m.environmentOverrides(for: account), ["CLAUDE_CONFIG_DIR": claudeDir.path])
        XCTAssertEqual(m.environmentOverrides(for: Account.makeDefault(provider: .claude)), [:])
        XCTAssertEqual(m.configDirectory(for: Account.makeDefault(provider: .codex)), env.home.appendingPathComponent(".codex", isDirectory: true))
    }

    func testClaudeSeedCopiesSettingsButNeverAccountFile() throws {
        let env = TempEnvironment()
        let claudeHome = env.home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        try "{\"theme\":\"dark\"}".write(to: claudeHome.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        try "{\"oauthAccount\":{\"emailAddress\":\"x@y\"}}".write(to: claudeHome.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try "{\"claudeAiOauth\":{}}".write(to: claudeHome.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
        let m = CLIProfileManager(paths: env.paths)
        let dir = try m.createProfileDirectory(provider: .claude, id: "work-1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".claude.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".credentials.json").path))
    }

    func testCodexConfigMergingKeepsTopLevelKeysAboveTables() {
        let user = """
        model = "gpt-5"
        cli_auth_credentials_store = "keyring"

        [sandbox]
        mode = "workspace-write"
        """
        let out = CLIProfileManager.codexConfigContent(profileId: "p", seedFrom: user, credentialStore: "file")
        let lines = out.components(separatedBy: "\n")
        let storeLine = lines.firstIndex { $0.hasPrefix("cli_auth_credentials_store") }!
        let tableLine = lines.firstIndex { $0.hasPrefix("[sandbox]") }!
        XCTAssertLessThan(storeLine, tableLine)
        XCTAssertEqual(lines.filter { $0.hasPrefix("cli_auth_credentials_store") }.count, 1)
        XCTAssertTrue(out.contains("model = \"gpt-5\""))
        XCTAssertTrue(out.contains("mode = \"workspace-write\""))
        XCTAssertEqual(CLIProfileManager.codexCredentialStoreSetting(in: out), "file")
        XCTAssertNil(CLIProfileManager.codexCredentialStoreSetting(in: "[x]\ncli_auth_credentials_store = \"keyring\""), "only top-level counts")
        XCTAssertEqual(CLIProfileManager.codexCredentialStoreSetting(in: "cli_auth_credentials_store = 'auto' # c"), "auto")
        let untouched = CLIProfileManager.codexConfigContent(profileId: "p", seedFrom: "a = 1\n", credentialStore: nil)
        XCTAssertFalse(untouched.contains("cli_auth_credentials_store"))
    }

    func testRemoveProfileDirectory() throws {
        let env = TempEnvironment()
        let m = CLIProfileManager(paths: env.paths)
        let dir = try m.createProfileDirectory(provider: .codex, id: "tmp-1")
        try m.removeProfileDirectory(provider: .codex, id: "tmp-1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertThrowsError(try m.removeProfileDirectory(provider: .codex, id: "default"))
    }
}
