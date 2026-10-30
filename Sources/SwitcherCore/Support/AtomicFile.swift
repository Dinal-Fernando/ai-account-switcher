import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum AtomicFileError: Error, LocalizedError {
    case createFailed(String)
    case renameFailed(String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .createFailed(let p): return "Could not create temporary file for \(p)"
        case .renameFailed(let p, let code): return "Could not atomically replace \(p) (errno \(code))"
        }
    }
}

/// Crash-safe file replacement: write to a temp file in the same directory, fsync, then rename(2).
/// Readers (including the shell wrapper) always see either the old or the complete new content.
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: permissions]) else {
            throw AtomicFileError.createFailed(url.path)
        }
        if let fh = try? FileHandle(forUpdating: tmp) {
            try? fh.synchronize()
            try? fh.close()
        }
        if rename(tmp.path, url.path) != 0 {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw AtomicFileError.renameFailed(url.path, errno: code)
        }
    }

    public static func write(_ string: String, to url: URL, permissions: Int = 0o600) throws {
        try write(Data(string.utf8), to: url, permissions: permissions)
    }

    /// Reads a single trimmed line (used for `state/active-*` and `config/*.real`).
    public static func readLine(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        guard let first = text.split(separator: "\n", omittingEmptySubsequences: false).first else { return nil }
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
