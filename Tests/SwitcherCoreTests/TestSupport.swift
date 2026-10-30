import Foundation
import XCTest
@testable import SwitcherCore

/// Isolated `$AISWITCH_HOME` + fake HOME per test.
final class TempEnvironment {
    let root: URL
    let home: URL
    let paths: SwitcherPaths

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("aiswitch-tests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = SwitcherPaths(root: root.appendingPathComponent(".aiswitch", isDirectory: true), home: home)
        try! paths.ensureLayout()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Fake CLI that prints its environment; used to exercise wrappers and the process runner.
    func makeFakeExecutable(_ name: String, body: String? = nil) -> String {
        let dir = root.appendingPathComponent("fakebin", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        let script = body ?? """
        #!/bin/sh
        printf 'REAL=%s\\n' "$0"
        printf 'CLAUDE_CONFIG_DIR=%s\\n' "${CLAUDE_CONFIG_DIR:-}"
        printf 'CODEX_HOME=%s\\n' "${CODEX_HOME:-}"
        for a in "$@"; do printf 'ARG=%s\\n' "$a"; done
        """
        try! AtomicFile.write(script + "\n", to: file, permissions: 0o755)
        return file.path
    }

    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}

func posixMode(_ path: String) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? -1
}

/// Minimal JWT builder (unsigned) for identity-parsing tests.
func makeJWT(payload: [String: Any]) -> String {
    func b64(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    let header = try! JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])
    let body = try! JSONSerialization.data(withJSONObject: payload)
    return b64(header) + "." + b64(body) + ".sig"
}

/// Scriptable provider adapter for monitor/recommendation tests.
struct StubAdapter: ProviderAdapter {
    let provider: Provider
    let context: ProviderContext
    var fetch: @Sendable (Account) async throws -> UsageSnapshot
    var auth: AuthStatus = AuthStatus(state: .authenticated, method: "claude.ai")

    func checkAuth(account: Account) async -> AuthStatus { auth }
    func identity(account: Account) -> AccountIdentity? { nil }
    func loginScript(account: Account, deviceAuth: Bool) -> String? { nil }
    func fetchUsage(account: Account) async throws -> UsageSnapshot { try await fetch(account) }
    func compatibilityIssues(version: String?, account: Account?) -> [CompatibilityIssue] { [] }
}

func sampleSnapshot(_ provider: Provider = .claude, id: String = "a", five: Double = 10, weekly: Double = 20, at: Date = Date(), resets: Date? = Date().addingTimeInterval(3600)) -> UsageSnapshot {
    UsageSnapshot(provider: provider, accountId: id, fetchedAt: at,
                  fiveHour: UsageWindow(kind: .fiveHour, label: "5-hour", usedPercent: five, resetsAt: resets, windowSeconds: UsageWindow.fiveHourSeconds),
                  weekly: UsageWindow(kind: .weekly, label: "Weekly", usedPercent: weekly, resetsAt: resets?.addingTimeInterval(86400), windowSeconds: UsageWindow.weekSeconds),
                  source: "test")
}
