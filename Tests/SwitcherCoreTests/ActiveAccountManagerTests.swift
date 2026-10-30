import XCTest
@testable import SwitcherCore

final class ActiveAccountManagerTests: XCTestCase {
    func testDefaultWhenNothingSelected() {
        let env = TempEnvironment()
        let m = ActiveAccountManager(paths: env.paths)
        XCTAssertEqual(m.activeProfileId(for: .claude), "default")
        XCTAssertFalse(m.hasExplicitSelection(for: .claude))
    }

    func testSetActiveWritesAtomicFileThatTheWrapperReads() throws {
        let env = TempEnvironment()
        let m = ActiveAccountManager(paths: env.paths)
        try FileManager.default.createDirectory(at: env.paths.profileDir(.claude, "work-1"), withIntermediateDirectories: true)
        try m.setActive(provider: .claude, profileId: "work-1")
        XCTAssertEqual(try String(contentsOf: env.paths.activeStateFile(.claude), encoding: .utf8), "work-1\n")
        XCTAssertEqual(posixMode(env.paths.activeStateFile(.claude).path), 0o600)
        XCTAssertEqual(m.activeProfileId(for: .claude), "work-1")
        XCTAssertEqual(m.activeProfileId(for: .codex), "default", "providers are independent")
        // persists across instances (new process / reboot)
        XCTAssertEqual(ActiveAccountManager(paths: env.paths).activeProfileId(for: .claude), "work-1")
        // and no temp files are left behind
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: env.paths.state.path).filter { $0.contains(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testSwitchBackAndForth() throws {
        let env = TempEnvironment()
        let m = ActiveAccountManager(paths: env.paths)
        for id in ["work-1", "personal-2"] { try FileManager.default.createDirectory(at: env.paths.profileDir(.claude, id), withIntermediateDirectories: true) }
        try m.setActive(provider: .claude, profileId: "work-1")
        try m.setActive(provider: .claude, profileId: "personal-2")
        XCTAssertEqual(m.activeProfileId(for: .claude), "personal-2")
        try m.setActive(provider: .claude, profileId: "work-1")
        XCTAssertEqual(m.activeProfileId(for: .claude), "work-1")
        try m.resetToDefault(provider: .claude)
        XCTAssertEqual(m.activeProfileId(for: .claude), "default")
    }

    func testRejectsInvalidIdsAndMissingDirectories() {
        let env = TempEnvironment()
        let m = ActiveAccountManager(paths: env.paths)
        XCTAssertThrowsError(try m.setActive(provider: .claude, profileId: "../evil"))
        XCTAssertThrowsError(try m.setActive(provider: .claude, profileId: "has space"))
        XCTAssertThrowsError(try m.setActive(provider: .claude, profileId: ""))
        XCTAssertThrowsError(try m.setActive(provider: .claude, profileId: "ghost-9"))
        XCTAssertTrue(ActiveAccountManager.isValidProfileId("work-1.a_b"))
        XCTAssertFalse(ActiveAccountManager.isValidProfileId(".hidden"))
        XCTAssertFalse(ActiveAccountManager.isValidProfileId("a/b"))
    }

    func testFallsBackToDefaultWhenSelectedDirectoryVanishes() throws {
        let env = TempEnvironment()
        let m = ActiveAccountManager(paths: env.paths)
        let dir = env.paths.profileDir(.codex, "work-1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try m.setActive(provider: .codex, profileId: "work-1")
        try FileManager.default.removeItem(at: dir)
        XCTAssertEqual(m.activeProfileId(for: .codex), "default")
        XCTAssertEqual(m.rawSelection(for: .codex), "work-1")
    }

    func testConcurrentWritesNeverProduceTornReads() throws {
        let env = TempEnvironment()
        let m = ActiveAccountManager(paths: env.paths)
        for id in ["work-1", "personal-2"] { try FileManager.default.createDirectory(at: env.paths.profileDir(.claude, id), withIntermediateDirectories: true) }
        let group = DispatchGroup()
        final class TornCounter: @unchecked Sendable { var value = 0 }
        let bad = NSLock(); let torn = TornCounter()
        for i in 0..<200 {
            group.enter()
            DispatchQueue.global().async {
                try? m.setActive(provider: .claude, profileId: i % 2 == 0 ? "work-1" : "personal-2")
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                let v = AtomicFile.readLine(env.paths.activeStateFile(.claude)) ?? "default"
                if !["work-1", "personal-2", "default"].contains(v) { bad.lock(); torn.value += 1; bad.unlock() }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(torn.value, 0)
    }
}
