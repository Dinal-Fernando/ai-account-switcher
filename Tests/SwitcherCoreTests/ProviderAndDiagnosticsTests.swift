import XCTest
@testable import SwitcherCore

final class ProviderAndDiagnosticsTests: XCTestCase {
    func testCLIEnvironmentStripsOverridesAndSetsProfileDir() {
        let env = TempEnvironment()
        let ctx = ProviderContext(paths: env.paths, runner: FakeProcessRunner(), http: FakeHTTPClient(),
                                  baseEnvironment: ["HOME": "/wrong", "PATH": "/usr/bin", "ANTHROPIC_API_KEY": "sk-x", "CLAUDE_CONFIG_DIR": "/elsewhere", "OPENAI_API_KEY": "k"])
        let work = Account(id: "work-1", provider: .claude, name: "Work", kind: .managed)
        let e = ctx.cliEnvironment(for: work)
        XCTAssertNil(e["ANTHROPIC_API_KEY"])
        XCTAssertEqual(e["CLAUDE_CONFIG_DIR"], env.paths.profileDir(.claude, "work-1").path)
        XCTAssertEqual(e["HOME"], env.home.path)
        XCTAssertEqual(e["DISABLE_AUTOUPDATER"], "1")
        XCTAssertEqual(e["OPENAI_API_KEY"], "k", "other provider's variables are untouched")
        let def = ctx.cliEnvironment(for: Account.makeDefault(provider: .codex))
        XCTAssertNil(def["CODEX_HOME"])
        XCTAssertNil(def["OPENAI_API_KEY"])
    }

    func testClaudeCheckAuthUsesVendorCLIAndIdentityFiles() async throws {
        let env = TempEnvironment()
        let runner = FakeProcessRunner()
        let claudeExe = env.makeFakeExecutable("claude")
        try AtomicFile.write(claudeExe + "\n", to: env.paths.realExecutableFile(.claude))
        runner.script("claude auth", ProcessResult(exitCode: 0, stdout: "{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"email\":\"w@x.y\",\"subscriptionType\":\"max\",\"configDirectory\":\"\(env.paths.profileDir(.claude, "work-1").path)\"}", stderr: ""))
        let ctx = ProviderContext(paths: env.paths, runner: runner, http: FakeHTTPClient(), baseEnvironment: ["HOME": env.home.path, "PATH": "/usr/bin"])
        let provider = ClaudeProvider(context: ctx)
        let profiles = CLIProfileManager(paths: env.paths)
        let dir = try profiles.createProfileDirectory(provider: .claude, id: "work-1", options: ProfileSeedOptions(copyClaudeUserSettings: false, copyCodexConfig: false))
        try "{\"oauthAccount\":{\"emailAddress\":\"w@x.y\",\"organizationName\":\"Org\"}}".write(to: dir.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let account = Account(id: "work-1", provider: .claude, name: "Work", kind: .managed)
        let status = await provider.checkAuth(account: account)
        XCTAssertTrue(status.isAuthenticated, status.message ?? "")
        XCTAssertTrue(status.warnings.isEmpty)
        XCTAssertEqual(provider.identity(account: account)?.organizationName, "Org")
        let call = runner.calls.first { $0.arguments == ["auth", "status"] }!
        XCTAssertEqual(call.environment?["CLAUDE_CONFIG_DIR"], dir.path, "the vendor CLI must be asked inside the profile")
        let script = provider.loginScript(account: account, deviceAuth: false)!
        XCTAssertTrue(script.contains("export CLAUDE_CONFIG_DIR='\(dir.path)'"))
        XCTAssertTrue(script.contains("auth login"))
        XCTAssertTrue(script.contains("unset ANTHROPIC_API_KEY"))
    }

    func testClaudeUsageFetchFromCredentialsFileAndHTTP() async throws {
        let env = TempEnvironment()
        let runner = FakeProcessRunner()
        let http = FakeHTTPClient()
        let ctx = ProviderContext(paths: env.paths, runner: runner, http: http, baseEnvironment: ["HOME": env.home.path, "PATH": "/usr/bin", "USER": "jane"])
        let provider = ClaudeProvider(context: ctx)
        let profiles = CLIProfileManager(paths: env.paths)
        let dir = try profiles.createProfileDirectory(provider: .claude, id: "work-1", options: ProfileSeedOptions(copyClaudeUserSettings: false, copyCodexConfig: false))
        let far = Int(Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1000)
        try "{\"claudeAiOauth\":{\"accessToken\":\"sk-ant-oat01-token\",\"expiresAt\":\(far),\"subscriptionType\":\"max\"}}".write(to: dir.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
        http.script(ClaudeProvider.usageURL.absoluteString, HTTPResponse(status: 200, body: Data("{\"five_hour\":{\"utilization\":12,\"resets_at\":\"2025-10-10T12:00:00Z\"},\"seven_day\":{\"utilization\":3}}".utf8)))
        let account = Account(id: "work-1", provider: .claude, name: "Work", kind: .managed)
        let snap = try await provider.fetchUsage(account: account)
        XCTAssertEqual(snap.fiveHour?.usedPercent, 12)
        XCTAssertEqual(snap.plan, "max")
        let (url, headers) = http.requests[0]
        XCTAssertEqual(url, ClaudeProvider.usageURL)
        XCTAssertEqual(headers["Authorization"], "Bearer sk-ant-oat01-token")
        XCTAssertEqual(headers["anthropic-beta"], ClaudeProvider.betaHeader)
        // 429 → rateLimited with Retry-After
        http.script(ClaudeProvider.usageURL.absoluteString, HTTPResponse(status: 429, headers: ["retry-after": "300"]))
        do { _ = try await provider.fetchUsage(account: account); XCTFail() } catch let e as UsageFetchError {
            XCTAssertEqual(e, .rateLimited(retryAfter: 300))
        }
        // 401 → unauthorized
        http.script(ClaudeProvider.usageURL.absoluteString, HTTPResponse(status: 401))
        do { _ = try await provider.fetchUsage(account: account); XCTFail() } catch let e as UsageFetchError {
            if case .unauthorized = e {} else { XCTFail("\(e)") }
        }
        // disabled source
        var off = account; off.usageSource = .disabled
        do { _ = try await provider.fetchUsage(account: off); XCTFail() } catch let e as UsageFetchError { XCTAssertEqual(e, .disabled) }
        // missing credential
        let none = Account(id: "none-1", provider: .claude, name: "None", kind: .managed)
        _ = try profiles.createProfileDirectory(provider: .claude, id: "none-1", options: ProfileSeedOptions(copyClaudeUserSettings: false, copyCodexConfig: false))
        do { _ = try await provider.fetchUsage(account: none); XCTFail() } catch let e as UsageFetchError { if case .noCredential = e {} else { XCTFail("\(e)") } }
    }

    func testCodexUsageFetchReadsAuthJSONAndSendsAccountHeader() async throws {
        let env = TempEnvironment()
        let http = FakeHTTPClient()
        let ctx = ProviderContext(paths: env.paths, runner: FakeProcessRunner(), http: http, baseEnvironment: ["HOME": env.home.path, "PATH": "/usr/bin"])
        let provider = CodexProvider(context: ctx)
        let dir = try CLIProfileManager(paths: env.paths).createProfileDirectory(provider: .codex, id: "work-1")
        let access = makeJWT(payload: ["exp": Date().timeIntervalSince1970 + 86_400])
        let json: [String: Any] = ["tokens": ["id_token": makeJWT(payload: ["email": "d@e.f", "https://api.openai.com/auth": ["chatgpt_plan_type": "pro", "chatgpt_account_id": "acct-9"]]), "access_token": access, "refresh_token": "r", "account_id": "acct-9"]]
        try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("auth.json"))
        http.script(CodexProvider.usageURL.absoluteString, HTTPResponse(status: 200, body: Data("{\"plan_type\":\"pro\",\"rate_limit\":{\"primary_window\":{\"used_percent\":40,\"limit_window_seconds\":18000,\"reset_after_seconds\":100}}}".utf8)))
        let account = Account(id: "work-1", provider: .codex, name: "Work", kind: .managed)
        let snap = try await provider.fetchUsage(account: account)
        XCTAssertEqual(snap.fiveHour?.usedPercent, 40)
        XCTAssertEqual(http.requests[0].1["chatgpt-account-id"], "acct-9")
        XCTAssertEqual(http.requests[0].1["Authorization"], "Bearer \(access)")
        XCTAssertEqual(provider.identity(account: account)?.email, "d@e.f")
        // expired token
        let expired = makeJWT(payload: ["exp": Date().timeIntervalSince1970 - 10])
        try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": expired, "account_id": "acct-9"]]).write(to: dir.appendingPathComponent("auth.json"))
        do { _ = try await provider.fetchUsage(account: account); XCTFail() } catch let e as UsageFetchError { if case .credentialExpired = e {} else { XCTFail("\(e)") } }
        // keyring mode is unsupported for monitoring
        try "cli_auth_credentials_store = \"keyring\"\n".write(to: dir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        do { _ = try await provider.fetchUsage(account: account); XCTFail() } catch let e as UsageFetchError { if case .unsupported = e {} else { XCTFail("\(e)") } }
        XCTAssertEqual(provider.compatibilityIssues(version: nil, account: account).first?.id, "codex-version-unknown")
    }

    func testEnvOverrideDetector() throws {
        let env = TempEnvironment()
        let f = EnvOverrideDetector.findings(provider: .claude, environment: ["ANTHROPIC_API_KEY": "x", "CLAUDE_CODE_USE_BEDROCK": "1", "OPENAI_API_KEY": "y", "ANTHROPIC_AUTH_TOKEN": ""])
        XCTAssertEqual(f.map(\.variable), ["ANTHROPIC_API_KEY", "CLAUDE_CODE_USE_BEDROCK"])
        let dir = env.paths.profileDir(.claude, "p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{\"env\":{\"ANTHROPIC_API_KEY\":\"sk\"},\"apiKeyHelper\":\"/bin/key\"}".write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let s = EnvOverrideDetector.claudeSettingsFindings(configDir: dir)
        XCTAssertEqual(s.map(\.variable).sorted(), ["ANTHROPIC_API_KEY", "apiKeyHelper"])
    }

    func testDoctorProducesActionableItemsWithoutProbing() async throws {
        let env = TempEnvironment()
        let runner = FakeProcessRunner()
        let ctx = ProviderContext(paths: env.paths, runner: runner, http: FakeHTTPClient(), baseEnvironment: ["HOME": env.home.path, "PATH": "/usr/bin"])
        let accounts = AccountManager(paths: env.paths)
        try accounts.load()
        let doctor = Doctor(context: ctx, accounts: accounts, adapters: [.claude: ClaudeProvider(context: ctx), .codex: CodexProvider(context: ctx)], probeShell: false, probeAuth: false)
        let report = await doctor.run()
        XCTAssertTrue(report.hasFailures, "wrappers are not installed yet")
        XCTAssertTrue(report.items.contains { $0.id == "claude-wrapper" && $0.level == .failure })
        XCTAssertTrue(report.items.contains { $0.id == "claude-keychain" })
        XCTAssertTrue(report.text.contains("[FAIL]"))
        // install wrappers with fake binaries → wrapper items become ok and a dry-run appears
        let claude = env.makeFakeExecutable("claude"); _ = env.makeFakeExecutable("codex")
        let fakebin = (claude as NSString).deletingLastPathComponent
        let realRunner = ProcessRunner()
        let ctx2 = ProviderContext(paths: env.paths, runner: realRunner, http: FakeHTTPClient(), baseEnvironment: ["HOME": env.home.path, "PATH": fakebin + ":/usr/bin:/bin"])
        _ = try ctx2.shell.install(ShellIntegrationOptions(rcFiles: [], addPathBlock: false))
        let report2 = await Doctor(context: ctx2, accounts: accounts, adapters: [:], probeShell: false, probeAuth: false).run()
        XCTAssertTrue(report2.items.contains { $0.id == "claude-wrapper" && $0.level == .ok })
        XCTAssertTrue(report2.items.contains { $0.id == "claude-dryrun" && $0.title.contains("profile=default") })
    }

    func testProcessRunnerTimeoutAndOutput() throws {
        let r = try ProcessRunner().run("/bin/sh", arguments: ["-c", "echo out; echo err 1>&2; exit 3"], environment: nil, currentDirectory: nil, input: nil, timeout: 5)
        XCTAssertEqual(r.exitCode, 3)
        XCTAssertEqual(r.stdout, "out\n")
        XCTAssertEqual(r.stderr, "err\n")
        let t = try ProcessRunner().run("/bin/sh", arguments: ["-c", "sleep 5"], environment: nil, currentDirectory: nil, input: nil, timeout: 0.5)
        XCTAssertTrue(t.timedOut)
        XCTAssertThrowsError(try ProcessRunner().run("/nonexistent/binary", arguments: [], environment: nil, currentDirectory: nil, input: nil, timeout: 1))
        let piped = try ProcessRunner().run("/bin/cat", arguments: [], environment: nil, currentDirectory: nil, input: Data("hi".utf8), timeout: 5)
        XCTAssertEqual(piped.stdout, "hi")
    }
}
