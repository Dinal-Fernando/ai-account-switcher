import XCTest
@testable import SwitcherCore

final class AuthParserTests: XCTestCase {
    func testClaudeAuthStatusVariants() {
        let now = Date()
        let r = ProcessResult(exitCode: 0, stdout: "", stderr: "")
        let signedIn = ClaudeAuthStatusParser.parse("""
        {"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "email": "jane@example.com",
         "orgName": "Jane", "subscriptionType": "max", "configDirectory": "/Users/jane/.aiswitch/profiles/claude/work-1"}
        """)!
        let s1 = ClaudeAuthStatusParser.authStatus(from: signedIn, result: r, isManagedProfile: true, expectedConfigDir: "/Users/jane/.aiswitch/profiles/claude/work-1", now: now)
        XCTAssertTrue(s1.isAuthenticated)
        XCTAssertEqual(s1.method, "claude.ai")
        XCTAssertTrue(s1.warnings.isEmpty)
        XCTAssertEqual(ClaudeAuthStatusParser.identity(from: signedIn)?.email, "jane@example.com")
        XCTAssertEqual(ClaudeAuthStatusParser.identity(from: signedIn)?.plan, "max")

        let mismatch = ClaudeAuthStatusParser.authStatus(from: signedIn, result: r, isManagedProfile: true, expectedConfigDir: "/other", now: now)
        XCTAssertEqual(mismatch.warnings.count, 1, "config dir mismatch must be surfaced")

        let out = ClaudeAuthStatusParser.parse("{\"loggedIn\": false, \"authMethod\": \"none\", \"configDirectory\": \"/x\"}")!
        let s2 = ClaudeAuthStatusParser.authStatus(from: out, result: ProcessResult(exitCode: 1, stdout: "", stderr: ""), isManagedProfile: true, expectedConfigDir: "/x", now: now)
        XCTAssertEqual(s2.state, .notAuthenticated)

        let tokenEnv = ClaudeAuthStatusParser.parse("{\"loggedIn\": true, \"authMethod\": \"oauth_token\", \"configDirectory\": \"/x\"}")!
        let s3 = ClaudeAuthStatusParser.authStatus(from: tokenEnv, result: r, isManagedProfile: true, expectedConfigDir: "/x", now: now)
        XCTAssertTrue(s3.isAuthenticated)
        XCTAssertTrue(s3.warnings.first!.contains("CLAUDE_CODE_OAUTH_TOKEN"))

        let apiKey = ClaudeAuthStatusParser.parse("{\"loggedIn\": true, \"authMethod\": \"api_key\", \"apiKeySource\": \"ANTHROPIC_API_KEY\", \"configDirectory\": \"/x\"}")!
        let s4 = ClaudeAuthStatusParser.authStatus(from: apiKey, result: r, isManagedProfile: true, expectedConfigDir: "/x", now: now)
        XCTAssertTrue(s4.warnings.first!.contains("not isolated"))

        let garbage = ClaudeAuthStatusParser.authStatus(from: ClaudeAuthStatusParser.parse("boom"), result: ProcessResult(exitCode: 2, stdout: "boom", stderr: ""), isManagedProfile: false, expectedConfigDir: nil, now: now)
        XCTAssertEqual(garbage.state, .error)
        let timeout = ClaudeAuthStatusParser.authStatus(from: nil, result: ProcessResult(exitCode: 0, stdout: "", stderr: "", timedOut: true), isManagedProfile: false, expectedConfigDir: nil, now: now)
        XCTAssertEqual(timeout.state, .error)
        // banner lines around the JSON are tolerated
        XCTAssertNotNil(ClaudeAuthStatusParser.parse("Checking...\n{\"loggedIn\": true}\nbye"))
    }

    func testClaudeGlobalConfigAndCredentials() {
        let cfg = """
        {"oauthAccount":{"accountUuid":"u-1","emailAddress":"jane@example.com","organizationUuid":"o-1","organizationName":"Jane's Org","displayName":"Jane","planDisplayName":"Max"},"numStartups":3}
        """
        let id = ClaudeAuthStatusParser.identity(fromGlobalConfig: Data(cfg.utf8))!
        XCTAssertEqual(id.email, "jane@example.com")
        XCTAssertEqual(id.organizationName, "Jane's Org")
        XCTAssertEqual(id.accountId, "u-1")
        XCTAssertEqual(id.summary, "jane@example.com · Jane's Org · Max")
        XCTAssertNil(ClaudeAuthStatusParser.identity(fromGlobalConfig: Data("{}".utf8)))

        let creds = """
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"sk-ant-ort01-def","expiresAt":1800000000000,"scopes":["user:inference"],"subscriptionType":"max"}}
        """
        let c = ClaudeAuthStatusParser.credential(fromCredentialsJSON: Data(creds.utf8))!
        XCTAssertEqual(c.accessToken, "sk-ant-oat01-abc")
        XCTAssertEqual(c.subscriptionType, "max")
        XCTAssertEqual(c.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertFalse(c.isExpired(now: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertTrue(c.isExpired(now: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertNil(ClaudeAuthStatusParser.credential(fromCredentialsJSON: Data("{\"claudeAiOauth\":{}}".utf8)))
    }

    func testCodexLoginStatusLines() {
        let now = Date()
        let chat = CodexAuthParser.parseLoginStatus(ProcessResult(exitCode: 0, stdout: "", stderr: "WARNING: proceeding\nLogged in using ChatGPT\n"), now: now)
        XCTAssertTrue(chat.isAuthenticated); XCTAssertEqual(chat.method, "chatgpt")
        let key = CodexAuthParser.parseLoginStatus(ProcessResult(exitCode: 0, stdout: "", stderr: "API key configured - sk-proj-ABCDEFGHIJKLMNOPQRSTUVWXYZ1234\n"), now: now)
        XCTAssertTrue(key.isAuthenticated); XCTAssertEqual(key.method, "api_key")
        XCTAssertFalse(key.message!.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ1234"), "secret must be redacted")
        XCTAssertFalse(key.warnings.isEmpty)
        let none = CodexAuthParser.parseLoginStatus(ProcessResult(exitCode: 0, stdout: "", stderr: "Not logged in\n"), now: now)
        XCTAssertEqual(none.state, .notAuthenticated)
        let token = CodexAuthParser.parseLoginStatus(ProcessResult(exitCode: 0, stdout: "", stderr: "Logged in using access token\n"), now: now)
        XCTAssertTrue(token.isAuthenticated); XCTAssertFalse(token.warnings.isEmpty)
        let err = CodexAuthParser.parseLoginStatus(ProcessResult(exitCode: 1, stdout: "", stderr: "Error checking login status: boom\n"), now: now)
        XCTAssertEqual(err.state, .error)
    }

    func testCodexAuthFileAndJWTIdentity() {
        let id = makeJWT(payload: ["email": "dev@example.com", "exp": 1_900_000_000,
                                   "https://api.openai.com/auth": ["chatgpt_plan_type": "plus", "chatgpt_account_id": "acct-1"]])
        let access = makeJWT(payload: ["exp": 1_900_000_000])
        let json: [String: Any] = ["tokens": ["id_token": id, "access_token": access, "refresh_token": "rt", "account_id": "acct-1"], "last_refresh": "2026-10-01T10:00:00.123Z"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let auth = CodexAuthParser.parseAuthFile(data)!
        XCTAssertEqual(auth.accessToken, access)
        XCTAssertTrue(auth.refreshTokenPresent)
        XCTAssertNotNil(auth.lastRefresh)
        let identity = CodexAuthParser.identity(from: auth)!
        XCTAssertEqual(identity.email, "dev@example.com")
        XCTAssertEqual(identity.plan, "plus")
        XCTAssertEqual(identity.accountId, "acct-1")
        XCTAssertEqual(JWT.expiry(access), Date(timeIntervalSince1970: 1_900_000_000))
        let apiOnly = CodexAuthParser.parseAuthFile(Data("{\"OPENAI_API_KEY\":\"sk-x\"}".utf8))!
        XCTAssertFalse(apiOnly.hasChatGPTLogin)
        XCTAssertEqual(CodexAuthParser.identity(from: apiOnly)?.method, "api_key")
        XCTAssertNil(JWT.decodePayload("not.a.jwt.really"))
    }

    func testRedaction() {
        let text = "Authorization: Bearer sk-ant-oat01-SECRETSECRET and {\"accessToken\":\"abcdefghijkl\"} and eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let out = SwitcherLog.redact(text)
        XCTAssertFalse(out.contains("SECRETSECRET"))
        XCTAssertFalse(out.contains("abcdefghijkl"))
        XCTAssertFalse(out.contains("SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"))
        XCTAssertTrue(out.contains("[redacted]"))
        XCTAssertEqual(SwitcherLog.redact("plain text"), "plain text")
    }

    func testVersionParsing() {
        XCTAssertEqual(VersionNumber(parsing: "2.1.314 (Claude Code)")?.description, "2.1.314")
        XCTAssertEqual(VersionNumber(parsing: "codex-cli 0.166.0")?.description, "0.166.0")
        XCTAssertTrue(VersionNumber(parsing: "2.1.267")! < ClaudeProvider.minimumVerifiedVersion)
        XCTAssertFalse(VersionNumber(parsing: "2.1.268")! < ClaudeProvider.minimumVerifiedVersion)
        XCTAssertTrue(VersionNumber([2, 1]) == VersionNumber([2, 1, 0]))
        XCTAssertNil(VersionNumber(parsing: "no version here"))
    }
}
