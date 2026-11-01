import Foundation

public struct GitError: Error, CustomStringConvertible {
    public var command: String
    public var status: Int32
    public var output: String

    public var description: String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "git \(command) failed (exit \(status))" : text
    }
}

/// Runs the system git.
public struct Git: Sendable {
    public var executable: URL
    public var timeout: TimeInterval

    public init(executable: URL = URL(filePath: "/usr/bin/git"), timeout: TimeInterval = 1800) {
        self.executable = executable
        self.timeout = timeout
    }

    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    /// Runs git and returns stdout, throwing on a non-zero exit. `input` is a file fed to git's standard input.
    @discardableResult
    public func run(_ args: [String], in directory: URL? = nil, timeout: TimeInterval? = nil, input: URL? = nil,
                    isCancelled: @Sendable () -> Bool = { false }) throws -> String {
        let r = try runRaw(args, in: directory, timeout: timeout, input: input, isCancelled: isCancelled)
        guard r.status == 0 else {
            throw GitError(command: args.first ?? "", status: r.status, output: r.stderr.isEmpty ? r.stdout : r.stderr)
        }
        return r.stdout
    }

    public func runRaw(_ args: [String], in directory: URL? = nil, timeout: TimeInterval? = nil, input: URL? = nil,
                       isCancelled: @Sendable () -> Bool = { false }) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = (directory.map { ["-C", $0.path(percentEncoded: false)] } ?? []) + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=20"
        env["LC_ALL"] = "C"
        process.environment = env
        process.qualityOfService = .utility

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = try input.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice

        let outData = LockedData(), errData = LockedData()
        outPipe.fileHandleForReading.readabilityHandler = { h in outData.append(h.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { h in errData.append(h.availableData) }

        try process.run()
        let deadline = Date().addingTimeInterval(timeout ?? self.timeout)
        while process.isRunning {
            if isCancelled() {
                process.terminate()
                process.waitUntilExit()
                throw CancellationError()
            }
            if Date() > deadline {
                process.terminate()
                process.waitUntilExit()
                throw GitError(command: args.first ?? "", status: -1, output: "git \(args.first ?? "") timed out")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        outData.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        errData.append(errPipe.fileHandleForReading.readDataToEndOfFile())
        return Result(status: process.terminationStatus, stdout: outData.string, stderr: errData.string)
    }
}

final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ d: Data) {
        lock.lock()
        data.append(d)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
