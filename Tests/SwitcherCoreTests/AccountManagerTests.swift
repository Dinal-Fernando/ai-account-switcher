import XCTest
@testable import SwitcherCore

final class AccountManagerTests: XCTestCase {
    func testLoadCreatesDefaultAccountsAndPersists() throws {
        let env = TempEnvironment()
        let m = AccountManager(paths: env.paths)
        let list = try m.load()
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list.allSatisfy { $0.isDefault })
        XCTAssertEqual(posixMode(env.paths.accountsFile.path), 0o600)
        let again = try AccountManager(paths: env.paths).load()
        XCTAssertEqual(again.map(\.key.description).sorted(), ["claude:default", "codex:default"])
    }

    func testAddRenameRemoveAndActiveFallback() throws {
        let env = TempEnvironment()
        let m = AccountManager(paths: env.paths)
        try m.load()
        let work = try m.addManagedAccount(provider: .claude, name: "Claude Work", seed: ProfileSeedOptions(copyClaudeUserSettings: false, copyCodexConfig: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: m.profiles.configDirectory(for: work).path))
        XCTAssertThrowsError(try m.addManagedAccount(provider: .claude, name: "claude work"), "case-insensitive duplicate")
        XCTAssertEqual(m.find(provider: .claude, nameOrId: "CLAUDE WORK")?.id, work.id)
        XCTAssertEqual(m.find(provider: .claude, nameOrId: work.id)?.id, work.id)
        try m.rename(work.key, to: "Work")
        XCTAssertEqual(m.account(work.key)?.name, "Work")
        try m.active.setActive(provider: .claude, profileId: work.id)
        XCTAssertEqual(m.activeAccount(for: .claude)?.id, work.id)
        try m.remove(work.key, deleteProfileDirectory: true)
        XCTAssertNil(m.account(work.key))
        XCTAssertEqual(m.active.activeProfileId(for: .claude), "default", "removing the active account falls back to default")
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.profiles.configDirectory(for: work).path))
        XCTAssertThrowsError(try m.remove(AccountKey(.claude, "default"), deleteProfileDirectory: false))
    }

    func testOlderDocumentsDecodeWithDefaults() throws {
        let env = TempEnvironment()
        let json = """
        {"version":1,"accounts":[{"id":"work-1","provider":"claude","name":"Work"}]}
        """
        try json.write(to: env.paths.accountsFile, atomically: true, encoding: .utf8)
        let m = AccountManager(paths: env.paths)
        let list = try m.load()
        let work = list.first { $0.id == "work-1" }!
        XCTAssertEqual(work.kind, .managed)
        XCTAssertEqual(work.usageSource, .cliLogin)
        XCTAssertEqual(list.count, 3)
    }

    func testShortLabelsDefaultToInitialsAndRoundTrip() throws {
        XCTAssertEqual(Account(id: "a", provider: .claude, name: "Claude Work", kind: .managed).displayShortLabel, "CW")
        XCTAssertEqual(Account(id: "a", provider: .claude, name: "Personal", kind: .managed).displayShortLabel, "PER")
        XCTAssertEqual(Account(id: "a", provider: .codex, name: "my work account 2", kind: .managed).displayShortLabel, "MWA")
        XCTAssertEqual(Account.makeDefault(provider: .claude).displayShortLabel, "CL")
        XCTAssertEqual(Account.makeDefault(provider: .codex).displayShortLabel, "CX")
        var renamedDefault = Account.makeDefault(provider: .claude)
        renamedDefault.name = "Personal"
        XCTAssertEqual(renamedDefault.displayShortLabel, "PER")
        XCTAssertEqual(Account(id: "a", provider: .claude, name: "X", kind: .managed, shortLabel: " wk ").displayShortLabel, "WK")
        XCTAssertEqual(Account(id: "a", provider: .claude, name: "X", kind: .managed, shortLabel: "toolong").displayShortLabel, "TOOL")
        XCTAssertEqual(Account.initials(of: "", provider: .codex), "CX")
        let env = TempEnvironment()
        let m = AccountManager(paths: env.paths)
        try m.load()
        var a = try m.addManagedAccount(provider: .claude, name: "Work", seed: ProfileSeedOptions(copyClaudeUserSettings: false, copyCodexConfig: false))
        a.shortLabel = "WRK"
        try m.update(a)
        XCTAssertEqual(try AccountManager(paths: env.paths).load().first { $0.key == a.key }?.shortLabel, "WRK")
    }

    func testIdentityAndAuthAreStored() throws {
        let env = TempEnvironment()
        let m = AccountManager(paths: env.paths)
        try m.load()
        let key = AccountKey(.codex, "default")
        try m.setIdentity(AccountIdentity(email: "a@b.c", plan: "plus"), auth: AuthStatus(state: .authenticated, method: "chatgpt"), for: key)
        let reloaded = try AccountManager(paths: env.paths).load().first { $0.key == key }!
        XCTAssertEqual(reloaded.identity?.email, "a@b.c")
        XCTAssertEqual(reloaded.identity?.summary, "a@b.c · Plus")
        XCTAssertTrue(reloaded.lastAuth!.isAuthenticated)
    }
}
