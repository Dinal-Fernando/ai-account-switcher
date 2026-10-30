import XCTest
@testable import SwitcherCore

final class SessionCatalogTests: XCTestCase {
    let sid = "11111111-2222-3333-4444-555555555555"
    let sid2 = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    private func writeClaudeTranscript(_ configDir: URL, folder: String, id: String, lines: [String]) -> URL {
        let dir = configDir.appendingPathComponent("projects/\(folder)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(id).jsonl")
        try! (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testListsClaudeSessionsWithTitleCwdAndCounts() throws {
        let env = TempEnvironment()
        let dir = env.paths.profileDir(.claude, "a")
        let lines = [
            #"{"type":"summary","summary":"Earlier summary","leafUuid":"x"}"#,
            #"{"type":"user","cwd":"/Users/jane/proj","sessionId":"\#(sid)","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","cwd":"/Users/jane/proj","sessionId":"\#(sid)","message":{"role":"user","content":[{"type":"text","text":"Refactor the login flow\nplease"}]}}"#,
            #"{"type":"assistant","sessionId":"\#(sid)","message":{"role":"assistant","content":[{"type":"text","text":"Sure"}]}}"#,
            #"{"type":"user","sessionId":"\#(sid)","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
        ]
        _ = writeClaudeTranscript(dir, folder: "-Users-jane-proj", id: sid, lines: lines)
        _ = writeClaudeTranscript(dir, folder: "-Users-jane-proj", id: "not-a-session", lines: [#"{"type":"user"}"#])
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("projects/-Users-jane-proj/memory"), withIntermediateDirectories: true)
        try "notes".write(to: dir.appendingPathComponent("projects/-Users-jane-proj/memory/MEMORY.md"), atomically: true, encoding: .utf8)
        let list = SessionCatalog.listClaudeSessions(configDir: dir, accountId: "a")
        XCTAssertEqual(list.count, 1)
        let s = list[0]
        XCTAssertEqual(s.id, sid)
        XCTAssertEqual(s.cwd, "/Users/jane/proj")
        XCTAssertEqual(s.title, "Refactor the login flow please", "command and tool-result messages are skipped")
        XCTAssertEqual(s.messageCount, 4)
        XCTAssertEqual(s.relativePath, "projects/-Users-jane-proj/\(sid).jsonl")
        XCTAssertEqual(s.folderName, "proj")
        XCTAssertEqual(s.resumeArguments, ["--resume", sid])
        XCTAssertTrue(s.sizeBytes > 0)
    }

    func testListsCodexRolloutsAndSkipsEnvironmentContext() throws {
        let env = TempEnvironment()
        let home = env.paths.profileDir(.codex, "c")
        let dir = home.appendingPathComponent("sessions/2026/10/30")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-2026-10-30T10-00-00-\(sid2).jsonl")
        let lines = [
            #"{"timestamp":"2026-10-30T10:00:00.123Z","type":"session_meta","payload":{"id":"\#(sid2)","timestamp":"2026-10-30T10:00:00.123Z","cwd":"/Users/jane/api","originator":"codex_cli_rs"}}"#,
            #"{"timestamp":"2026-10-30T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd</environment_context>"}]}}"#,
            #"{"timestamp":"2026-10-30T10:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"Add rate limiting to the API"}}"#,
            #"{"timestamp":"2026-10-30T10:00:03Z","type":"event_msg","payload":{"type":"agent_message","message":"On it"}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let list = SessionCatalog.listCodexSessions(codexHome: home, accountId: "c")
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, sid2)
        XCTAssertEqual(list[0].cwd, "/Users/jane/api")
        XCTAssertEqual(list[0].title, "Add rate limiting to the API")
        XCTAssertEqual(list[0].relativePath, "sessions/2026/10/30/rollout-2026-10-30T10-00-00-\(sid2).jsonl")
        XCTAssertEqual(list[0].messageCount, 2)
        XCTAssertEqual(list[0].resumeArguments, ["resume", sid2])
    }

    func testNewestFirstAndFindAcrossProfiles() throws {
        let env = TempEnvironment()
        let a = env.paths.profileDir(.claude, "a")
        let b = env.paths.profileDir(.claude, "b")
        let old = writeClaudeTranscript(a, folder: "-p", id: sid, lines: [#"{"type":"user","cwd":"/p","message":{"role":"user","content":"old"}}"#])
        let new = writeClaudeTranscript(a, folder: "-p", id: sid2, lines: [#"{"type":"user","cwd":"/p","message":{"role":"user","content":"new"}}"#])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: new.path)
        let list = SessionCatalog.listClaudeSessions(configDir: a, accountId: "a")
        XCTAssertEqual(list.map(\.id), [sid2, sid])
        XCTAssertEqual(SessionCatalog.listClaudeSessions(configDir: a, accountId: "a", limit: 1).count, 1)
        let found = SessionCatalog.find(id: sid.uppercased(), provider: .claude, in: [("b", b), ("a", a)])
        XCTAssertEqual(found?.accountId, "a")
        XCTAssertNil(SessionCatalog.find(id: "99999999-9999-9999-9999-999999999999", provider: .claude, in: [("a", a)]))
        XCTAssertTrue(SessionCatalog.listClaudeSessions(configDir: b, accountId: "b").isEmpty)
    }

    func testDuplicateCopiesTranscriptIntoTargetProfileWithPrivatePermissions() throws {
        let env = TempEnvironment()
        let a = env.paths.profileDir(.claude, "a")
        let b = env.paths.profileDir(.claude, "b")
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let src = writeClaudeTranscript(a, folder: "-Users-jane-proj", id: sid, lines: [#"{"type":"user","cwd":"/Users/jane/proj","sessionId":"\#(sid)","message":{"role":"user","content":"hello"}}"#])
        // side folder with sub-agent transcripts travels with the session
        let side = src.deletingPathExtension()
        try FileManager.default.createDirectory(at: side, withIntermediateDirectories: true)
        try "x".write(to: side.appendingPathComponent("agent-1.jsonl"), atomically: true, encoding: .utf8)
        let session = try XCTUnwrap(SessionCatalog.listClaudeSessions(configDir: a, accountId: "a").first)
        let copy = try SessionCopier.duplicate(session, into: b, targetAccountId: "b")
        XCTAssertEqual(copy.accountId, "b")
        XCTAssertEqual(copy.id, sid, "the session id is preserved so --resume works unchanged")
        XCTAssertEqual(copy.fileURL, b.appendingPathComponent("projects/-Users-jane-proj/\(sid).jsonl"))
        XCTAssertEqual(try String(contentsOf: copy.fileURL, encoding: .utf8), try String(contentsOf: src, encoding: .utf8))
        XCTAssertEqual(posixMode(copy.fileURL.path), 0o600)
        XCTAssertEqual(posixMode(b.appendingPathComponent("projects").path), 0o700)
        XCTAssertEqual(posixMode(b.appendingPathComponent("projects/-Users-jane-proj").path), 0o700)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.appendingPathComponent("projects/-Users-jane-proj/\(sid)/agent-1.jsonl").path))
        XCTAssertThrowsError(try SessionCopier.duplicate(session, into: b, targetAccountId: "b")) { error in
            XCTAssertEqual(error as? SessionError, .alreadyExists(copy.fileURL.path))
        }
        XCTAssertNoThrow(try SessionCopier.duplicate(session, into: b, targetAccountId: "b", overwrite: true))
        XCTAssertEqual(SessionCatalog.listClaudeSessions(configDir: b, accountId: "b").first?.title, "hello")
        // the original is untouched
        XCTAssertEqual(SessionCatalog.listClaudeSessions(configDir: a, accountId: "a").count, 1)
    }

    func testHelpers() {
        XCTAssertTrue(SessionCatalog.isUUID("11111111-2222-3333-4444-555555555555"))
        XCTAssertFalse(SessionCatalog.isUUID("11111111-2222-3333-4444-55555555555"))
        XCTAssertNil(SessionCatalog.cleanTitle("  <local-command-stdout>x</local-command-stdout>"))
        XCTAssertEqual(SessionCatalog.cleanTitle("a\nb"), "a b")
        XCTAssertEqual(SessionCatalog.cleanTitle(String(repeating: "x", count: 200))?.count, 121)
        XCTAssertNil(SessionCatalog.claudeUserText(["content": [["type": "tool_result", "content": "x"]]]))
        XCTAssertEqual(SessionCatalog.claudeUserText(["content": "plain"]), "plain")
    }
}
