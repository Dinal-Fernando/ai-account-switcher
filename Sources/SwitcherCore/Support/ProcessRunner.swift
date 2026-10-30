import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct ProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }
    public var combinedOutput: String { stdout + (stderr.isEmpty ? "" : "\n" + stderr) }
}

public enum ProcessRunnerError: Error, LocalizedError {
    case executableNotFound(String)
    case launchFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let p): return "Executable not found: \(p)"
        case .launchFailed(let p, let why): return "Could not launch \(p): \(why)"
        }
    }
}

/// Abstraction over launching subprocesses so managers can be unit-tested with a fake.
public protocol ProcessRunning: Sendable {
    func run(_ executable: String, arguments: [String], environment: [String: String]?,
             currentDirectory: URL?, input: Data?, timeout: TimeInterval) throws -> ProcessResult
}

public extension ProcessRunning {
    func run(_ executable: String, _ arguments: [String] = [], environment: [String: String]? = nil,
             timeout: TimeInterval = 30) throws -> ProcessResult {
        try run(executable, arguments: arguments, environment: environment, currentDirectory: nil, input: nil, timeout: timeout)
    }

    func runAsync(_ executable: String, arguments: [String] = [], environment: [String: String]? = nil,
                  currentDirectory: URL? = nil, input: Data? = nil, timeout: TimeInterval = 30) async throws -> ProcessResult {
        let runner = self
        return try await Task.detached(priority: .userInitiated) {
            try runner.run(executable, arguments: arguments, environment: environment,
                           currentDirectory: currentDirectory, input: input, timeout: timeout)
        }.value
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
    var flag = false
}

/// Foundation.Process based runner with a hard timeout (SIGTERM, then SIGKILL after 2 s).
public struct ProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ executable: String, arguments: [String], environment: [String: String]?,
                    currentDirectory: URL?, input: Data?, timeout: TimeInterval) throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessRunnerError.executableNotFound(executable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = input == nil ? nil : Pipe()
        if let inPipe { process.standardInput = inPipe } else { process.standardInput = FileHandle.nullDevice }

        do { try process.run() } catch {
            throw ProcessRunnerError.launchFailed(executable, error.localizedDescription)
        }
        if let inPipe, let input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }

        let out = DataBox(), err = DataBox(), timedOut = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            out.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            err.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let pid = process.processIdentifier
        let killer = DispatchWorkItem {
            if process.isRunning {
                timedOut.flag = true
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()
        // Pipes normally hit EOF the moment the child exits. A grandchild that inherited them (a login shell
        // spawning background jobs, a CLI forking a daemon) could keep them open; cap the wait so a status
        // check can never hang the caller. Any output still arriving after the cap is dropped.
        if group.wait(timeout: .now() + 5) == .timedOut {
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
        }
        return ProcessResult(exitCode: process.terminationStatus,
                             stdout: String(decoding: out.data, as: UTF8.self),
                             stderr: String(decoding: err.data, as: UTF8.self),
                             timedOut: timedOut.flag)
    }
}

/// Test double: scripted results keyed by executable basename + first argument.
public final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    public struct Call: Equatable, Sendable {
        public var executable: String
        public var arguments: [String]
        public var environment: [String: String]?
    }
    private let lock = NSLock()
    private var scripted: [String: ProcessResult] = [:]
    public private(set) var calls: [Call] = []
    public var defaultResult = ProcessResult(exitCode: 127, stdout: "", stderr: "not scripted")

    public init() {}

    /// Key format: "<basename> <first arg>" or just "<basename>".
    public func script(_ key: String, _ result: ProcessResult) {
        lock.lock(); defer { lock.unlock() }
        scripted[key] = result
    }

    public func run(_ executable: String, arguments: [String], environment: [String: String]?,
                    currentDirectory: URL?, input: Data?, timeout: TimeInterval) throws -> ProcessResult {
        lock.lock(); defer { lock.unlock() }
        calls.append(Call(executable: executable, arguments: arguments, environment: environment))
        let base = (executable as NSString).lastPathComponent
        let keys = [base + " " + arguments.prefix(2).joined(separator: " "),
                    base + " " + (arguments.first ?? ""), base]
        for k in keys { if let r = scripted[k] { return r } }
        return defaultResult
    }
}
