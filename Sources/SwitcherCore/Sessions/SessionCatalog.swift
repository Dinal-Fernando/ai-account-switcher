import Foundation

/// A conversation stored on disk by a vendor CLI. The transcript is a plain local file, so it is readable
/// (and copyable into another profile) regardless of the account's quota state.
public struct CLISession: Identifiable, Equatable, Sendable {
    /// The vendor's session id (`claude --resume <id>` / `codex resume <id>`).
    public var id: String
    public var provider: Provider
    public var accountId: String
    /// Working directory the conversation ran in (resume must happen there for Claude Code to find it).
    public var cwd: String
    /// Path inside the config directory, e.g. `projects/-Users-jane-proj/<id>.jsonl`.
    public var relativePath: String
    public var fileURL: URL
    public var title: String
    public var modifiedAt: Date
    public var sizeBytes: Int
    public var messageCount: Int

    public init(id: String, provider: Provider, accountId: String, cwd: String, relativePath: String, fileURL: URL,
                title: String, modifiedAt: Date, sizeBytes: Int, messageCount: Int) {
        self.id = id
        self.provider = provider
        self.accountId = accountId
        self.cwd = cwd
        self.relativePath = relativePath
        self.fileURL = fileURL
        self.title = title
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
        self.messageCount = messageCount
    }

    public var key: AccountKey { AccountKey(provider, accountId) }
    public var folderName: String { (cwd as NSString).lastPathComponent }

    /// Arguments that resume this conversation with the vendor CLI (run inside `cwd`).
    public var resumeArguments: [String] {
        switch provider {
        case .claude: return ["--resume", id]
        case .codex: return ["resume", id]
        }
    }
}

public enum SessionError: Error, LocalizedError, Equatable {
    case alreadyExists(String)
    case notFound(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let p): return "A transcript with this session id already exists in the target profile (\(p)). Use overwrite to replace it."
        case .notFound(let id): return "Session \(id) was not found"
        case .unreadable(let p): return "Could not read \(p)"
        }
    }
}

/// Lists conversations per profile. Read-only; parses only the head of each transcript.
public enum SessionCatalog {
    static let uuidRegex = try! NSRegularExpression(pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
    static let headLineLimit = 80
    static let titleLimit = 120

    public static func isUUID(_ s: String) -> Bool {
        uuidRegex.firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)) != nil
    }

    static func cleanTitle(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.hasPrefix("<") else { return nil }   // skips <command-name>, <environment_context>, …
        let oneLine = t.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > titleLimit ? String(oneLine.prefix(titleLimit)) + "…" : oneLine
    }

    /// Reads up to `limit` lines of a JSONL file without loading large transcripts entirely.
    static func headLines(_ url: URL, limit: Int) -> [String] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: 256 * 1024)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).prefix(limit)).map(String.init)
    }

    static func countLines(_ url: URL, matching predicate: (String) -> Bool) -> Int {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return 0 }
        var n = 0
        text.enumerateLines { line, _ in if predicate(line) { n += 1 } }
        return n
    }

    static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Text of a Claude user message: plain string or `[{"type":"text","text":…}]` (tool results yield nil).
    static func claudeUserText(_ message: [String: Any]) -> String? {
        if let s = message["content"] as? String { return s }
        if let blocks = message["content"] as? [[String: Any]] {
            for b in blocks where b["type"] as? String == "text" {
                if let t = b["text"] as? String { return t }
            }
        }
        return nil
    }

    // MARK: Claude Code

    /// `<configDir>/projects/<encoded cwd>/<uuid>.jsonl`, newest first.
    public static func listClaudeSessions(configDir: URL, accountId: String, limit: Int = 100) -> [CLISession] {
        let fm = FileManager.default
        let projects = configDir.appendingPathComponent("projects", isDirectory: true)
        guard let folders = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [CLISession] = []
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let id = file.deletingPathExtension().lastPathComponent
                guard isUUID(id) else { continue }
                if let s = claudeSession(file: file, id: id, folder: folder, accountId: accountId) { out.append(s) }
            }
        }
        out.sort { $0.modifiedAt > $1.modifiedAt }
        return Array(out.prefix(limit))
    }

    static func claudeSession(file: URL, id: String, folder: URL, accountId: String) -> CLISession? {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        var cwd = ""
        var title: String?
        var sessionId = id
        for line in headLines(file, limit: headLineLimit) {
            guard let obj = json(line) else { continue }
            if cwd.isEmpty, let c = obj["cwd"] as? String { cwd = c }
            if let sid = obj["sessionId"] as? String, isUUID(sid) { sessionId = sid }
            if title == nil, obj["type"] as? String == "user", let message = obj["message"] as? [String: Any],
               let text = claudeUserText(message), let clean = cleanTitle(text) {
                title = clean
            }
            if title != nil, !cwd.isEmpty { break }
        }
        if cwd.isEmpty { cwd = folder.lastPathComponent.replacingOccurrences(of: "-", with: "/") }
        let count = countLines(file) { $0.contains("\"type\":\"user\"") || $0.contains("\"type\":\"assistant\"") }
        return CLISession(id: sessionId, provider: .claude, accountId: accountId, cwd: cwd,
                          relativePath: "projects/\(folder.lastPathComponent)/\(file.lastPathComponent)", fileURL: file,
                          title: title ?? "(no prompt recorded)", modifiedAt: values?.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                          sizeBytes: values?.fileSize ?? 0, messageCount: count)
    }

    // MARK: Codex

    /// `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`, newest first.
    public static func listCodexSessions(codexHome: URL, accountId: String, limit: Int = 100) -> [CLISession] {
        let fm = FileManager.default
        let root = codexHome.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]) else { return [] }
        var out: [CLISession] = []
        for case let file as URL in enumerator where file.pathExtension == "jsonl" && file.lastPathComponent.hasPrefix("rollout-") {
            if let s = codexSession(file: file, root: codexHome, accountId: accountId) { out.append(s) }
        }
        out.sort { $0.modifiedAt > $1.modifiedAt }
        return Array(out.prefix(limit))
    }

    static func codexSession(file: URL, root: URL, accountId: String) -> CLISession? {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        var id: String?
        var cwd = ""
        var title: String?
        var started: Date?
        for line in headLines(file, limit: headLineLimit) {
            guard let obj = json(line) else { continue }
            let type = obj["type"] as? String
            let payload = obj["payload"] as? [String: Any]
            if type == "session_meta", let p = payload {
                id = p["id"] as? String
                cwd = p["cwd"] as? String ?? cwd
                started = ClaudeUsageDecoder.parseDate(p["timestamp"] as? String)
            } else if title == nil, type == "event_msg", let p = payload, p["type"] as? String == "user_message",
                      let m = p["message"] as? String, let clean = cleanTitle(m) {
                title = clean
            } else if title == nil, type == "response_item", let p = payload, p["type"] as? String == "message",
                      p["role"] as? String == "user", let content = p["content"] as? [[String: Any]] {
                for block in content {
                    if let t = block["text"] as? String, let clean = cleanTitle(t) { title = clean; break }
                }
            }
        }
        // Fall back to the uuid at the end of the file name.
        if id == nil {
            let base = file.deletingPathExtension().lastPathComponent
            if base.count > 36 { let tail = String(base.suffix(36)); if isUUID(tail) { id = tail } }
        }
        guard let id else { return nil }
        let relative = file.path.hasPrefix(root.path + "/") ? String(file.path.dropFirst(root.path.count + 1)) : "sessions/\(file.lastPathComponent)"
        let count = countLines(file) { $0.contains("\"type\":\"user_message\"") || $0.contains("\"type\":\"agent_message\"") }
        return CLISession(id: id, provider: .codex, accountId: accountId, cwd: cwd, relativePath: relative, fileURL: file,
                          title: title ?? "(no prompt recorded)", modifiedAt: values?.contentModificationDate ?? started ?? Date(timeIntervalSince1970: 0),
                          sizeBytes: values?.fileSize ?? 0, messageCount: count)
    }

    // MARK: generic

    public static func list(provider: Provider, configDir: URL, accountId: String, limit: Int = 100) -> [CLISession] {
        switch provider {
        case .claude: return listClaudeSessions(configDir: configDir, accountId: accountId, limit: limit)
        case .codex: return listCodexSessions(codexHome: configDir, accountId: accountId, limit: limit)
        }
    }

    /// Finds a session id across several profiles (`[accountId: configDir]`).
    public static func find(id: String, provider: Provider, in directories: [(String, URL)]) -> CLISession? {
        let needle = id.lowercased()
        for (accountId, dir) in directories {
            if let hit = list(provider: provider, configDir: dir, accountId: accountId, limit: 10_000).first(where: { $0.id.lowercased() == needle }) {
                return hit
            }
        }
        return nil
    }
}

/// Copies one transcript into another profile. Nothing is shared or linked; the copy is an independent file.
public enum SessionCopier {
    @discardableResult
    public static func duplicate(_ session: CLISession, into targetConfigDir: URL, targetAccountId: String, overwrite: Bool = false) throws -> CLISession {
        let fm = FileManager.default
        let target = targetConfigDir.appendingPathComponent(session.relativePath)
        if fm.fileExists(atPath: target.path) && !overwrite { throw SessionError.alreadyExists(target.path) }
        guard let data = try? Data(contentsOf: session.fileURL) else { throw SessionError.unreadable(session.fileURL.path) }
        let dir = target.deletingLastPathComponent()
        // Create intermediate directories with private permissions.
        var current = targetConfigDir
        for component in dir.path.dropFirst(targetConfigDir.path.count).split(separator: "/") {
            current = current.appendingPathComponent(String(component), isDirectory: true)
            if !fm.fileExists(atPath: current.path) {
                try fm.createDirectory(at: current, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
        }
        try AtomicFile.write(data, to: target, permissions: 0o600)
        // Claude Code keeps per-session side files (e.g. sub-agent transcripts) in a folder named after the id.
        let sideDir = session.fileURL.deletingPathExtension()
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: sideDir.path, isDirectory: &isDir), isDir.boolValue {
            let targetSide = target.deletingPathExtension()
            if overwrite { try? fm.removeItem(at: targetSide) }
            if !fm.fileExists(atPath: targetSide.path) { try? fm.copyItem(at: sideDir, to: targetSide) }
        }
        SwitcherLog.shared.log("duplicated \(session.provider.rawValue) session \(session.id) from \(session.accountId) to \(targetAccountId)", category: "sessions")
        var copy = session
        copy.accountId = targetAccountId
        copy.fileURL = target
        return copy
    }
}
