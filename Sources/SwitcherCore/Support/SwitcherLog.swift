import Foundation

/// Small append-only log with secret redaction. Tokens, cookies and bearer headers never reach disk.
public final class SwitcherLog: @unchecked Sendable {
    public static let shared = SwitcherLog()

    private let lock = NSLock()
    private var fileURL: URL?
    private let maxBytes = 512 * 1024
    public var alsoPrintToStderr = false

    public init(fileURL: URL? = nil) { self.fileURL = fileURL }

    public func configure(fileURL: URL) {
        lock.lock(); defer { lock.unlock() }
        self.fileURL = fileURL
    }

    public func log(_ message: String, category: String = "app") {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(category)] \(Self.redact(message))\n"
        lock.lock(); defer { lock.unlock() }
        if alsoPrintToStderr { FileHandle.standardError.write(Data(line.utf8)) }
        guard let fileURL else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let attrs = try? fm.attributesOfItem(atPath: fileURL.path), let size = attrs[.size] as? Int, size > maxBytes {
                let rotated = fileURL.deletingPathExtension().appendingPathExtension("1.log")
                try? fm.removeItem(at: rotated)
                try? fm.moveItem(at: fileURL, to: rotated)
            }
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let fh = try FileHandle(forWritingTo: fileURL)
            try fh.seekToEnd()
            try fh.write(contentsOf: Data(line.utf8))
            try fh.close()
        } catch {
            // Logging must never break the app.
        }
    }

    private static let patterns: [NSRegularExpression] = {
        let raw = [
            #"sk-ant-[A-Za-z0-9_\-]{8,}"#,                         // Anthropic keys / tokens
            #"sk-[A-Za-z0-9_\-]{16,}"#,                            // OpenAI keys
            #"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#, // JWTs
            #"(?i)(bearer\s+)[A-Za-z0-9_\-\.=]{8,}"#,
            #"(?i)(sessionkey=)[A-Za-z0-9_\-\.%]{8,}"#,
            #"(?i)("(?:access|refresh|id)_?token"\s*:\s*")[^"]{8,}(")"#,
            #"(?i)("accessToken"\s*:\s*")[^"]{8,}(")"#,
            #"(?i)("refreshToken"\s*:\s*")[^"]{8,}(")"#,
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Replaces anything that looks like a credential with `[redacted]`.
    public static func redact(_ text: String) -> String {
        var out = text
        for re in patterns {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            let hasGroups = re.numberOfCaptureGroups > 0
            let template = hasGroups ? (re.numberOfCaptureGroups >= 2 ? "$1[redacted]$2" : "$1[redacted]") : "[redacted]"
            out = re.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: template)
        }
        return out
    }
}
