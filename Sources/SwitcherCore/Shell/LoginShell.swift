import Foundation

/// Helpers for asking the user's *login, interactive* shell questions (the only place the PATH block lives).
public struct LoginShell: Sendable {
    public let shellPath: String
    private let runner: ProcessRunning

    public init(shellPath: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment, runner: ProcessRunning = ProcessRunner()) {
        let candidate = shellPath ?? environment["SHELL"] ?? "/bin/zsh"
        self.shellPath = FileManager.default.isExecutableFile(atPath: candidate) ? candidate : "/bin/sh"
        self.runner = runner
    }

    public var isInteractiveCapable: Bool {
        let name = (shellPath as NSString).lastPathComponent
        return ["zsh", "bash", "sh", "fish"].contains(name)
    }

    /// Runs `command -v <name>` in a login+interactive shell and returns the last non-empty line.
    public func resolve(_ command: String, timeout: TimeInterval = 15) -> String? {
        let result = try? runner.run(shellPath, arguments: ["-lic", "command -v \(command)"], environment: nil,
                                     currentDirectory: nil, input: nil, timeout: timeout)
        guard let result, result.exitCode == 0 else { return nil }
        return result.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }

    /// Environment of a login+interactive shell (what Terminal windows see). Parsed from `env` output.
    public func environment(timeout: TimeInterval = 15) -> [String: String] {
        guard let result = try? runner.run(shellPath, arguments: ["-lic", "env"], environment: nil,
                                           currentDirectory: nil, input: nil, timeout: timeout), result.exitCode == 0 else {
            return [:]
        }
        return Self.parseEnv(result.stdout)
    }

    public static func parseEnv(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        var currentKey: String?
        for line in text.components(separatedBy: "\n") {
            if let eq = line.firstIndex(of: "=") {
                // Not an identifier (e.g. an exported bash function `BASH_FUNC_x%%=…`): ignore it and stop
                // treating following lines as a continuation of the previous variable.
                guard Self.isIdentifier(line[..<eq]) else { currentKey = nil; continue }
                currentKey = String(line[..<eq])
                env[currentKey!] = String(line[line.index(after: eq)...])
            } else if let key = currentKey, !line.isEmpty {
                env[key, default: ""] += "\n" + line
            }
        }
        return env
    }

    private static func isIdentifier(_ s: Substring) -> Bool {
        guard let first = s.first, first == "_" || first.isLetter else { return false }
        return s.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}
