import XCTest
@testable import SwitcherCore

final class SHA256AndKeyDerivationTests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(SHA256.hexDigest(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hexDigest("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hexDigest("The quick brown fox jumps over the lazy dog"), "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
        XCTAssertEqual(SHA256.hexDigest(String(repeating: "a", count: 1000)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testClaudeKeychainServiceNameMatchesVendorScheme() {
        // Claude Code 2.1.x: no suffix for the default directory, "-<sha256(CLAUDE_CONFIG_DIR)[0..<8]>" otherwise.
        XCTAssertEqual(CLIProfileManager.claudeKeychainService(configDirEnvValue: nil), "Claude Code-credentials")
        XCTAssertEqual(CLIProfileManager.claudeKeychainService(configDirEnvValue: ""), "Claude Code-credentials")
        XCTAssertEqual(CLIProfileManager.claudeKeychainService(configDirEnvValue: "/Users/jane/.aiswitch/profiles/claude/work-1a2b"),
                       "Claude Code-credentials-542f0a82")
    }

    func testClaudeKeychainAccountFallsBackForOddUserNames() {
        XCTAssertEqual(CLIProfileManager.claudeKeychainAccount(environment: ["USER": "jane.doe-1"]), "jane.doe-1")
        XCTAssertEqual(CLIProfileManager.claudeKeychainAccount(environment: ["USER": "jane doe"]), "claude-code-user")
        XCTAssertEqual(CLIProfileManager.claudeKeychainAccount(environment: ["USER": "jäne"]), "claude-code-user")
    }

    func testCodexKeyringAccountUsesCanonicalPathHash() {
        let env = TempEnvironment()
        let dir = env.paths.profileDir(.codex, "work-1")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let canonical = dir.resolvingSymlinksInPath().standardizedFileURL.path
        let expected = "cli|" + String(SHA256.hexDigest(canonical).prefix(16))
        XCTAssertEqual(CLIProfileManager.codexKeyringAccount(codexHome: dir), expected)
        XCTAssertEqual(CLIProfileManager.codexKeyringService, "Codex Auth")
    }
}
