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

    public var shellName: String { (shellPath as NSString).lastPathComponent }

    /// Runs a snippet in a login + interactive shell (the configuration Terminal windows get).
    func run(_ snippet: String, timeout: TimeInterval) -> ProcessResult? {
        try? runner.run(shellPath, arguments: ["-l", "-i", "-c", snippet], environment: nil, currentDirectory: nil, input: nil, timeout: timeout)
    }

    /// The executable the login shell would run for `command`, ignoring aliases and functions
    /// (`whence -p` in zsh, `type -P` in bash); the last absolute path printed wins, so rc-file chatter is ignored.
    public func resolve(_ command: String, timeout: TimeInterval = 15) -> String? {
        let snippet: String
        switch shellName {
        case "zsh": snippet = "whence -p \(command) 2>/dev/null || command -v \(command)"
        case "bash": snippet = "type -P \(command) 2>/dev/null || command -v \(command)"
        case "fish": snippet = "command -s \(command)"
        default: snippet = "command -v \(command)"
        }
        guard let result = run(snippet, timeout: timeout), result.exitCode == 0 else { return nil }
        return Self.lastAbsolutePath(in: result.stdout)
    }

    static func lastAbsolutePath(in text: String) -> String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { $0.hasPrefix("/") }
    }

    /// PATH entries of the login shell, in order.
    public func pathEntries(timeout: TimeInterval = 15) -> [String] {
        guard let result = run("printf '%s\\n' \"$PATH\"", timeout: timeout), result.exitCode == 0 else { return [] }
        guard let line = result.stdout.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { $0.contains("/") }) else { return [] }
        return line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    }

    /// Environment of a login+interactive shell (what Terminal windows see). Parsed from `env` output.
    public func environment(timeout: TimeInterval = 15) -> [String: String] {
        guard let result = run("env", timeout: timeout), result.exitCode == 0 else { return [:] }
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
