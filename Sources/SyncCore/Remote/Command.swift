import Foundation

public struct CommandError: Error, CustomStringConvertible {
    public var tool: String
    public var status: Int32
    public var output: String

    public var description: String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "\(tool) failed (exit \(status))" : text
    }
}

/// Runs a command-line tool with a timeout, cancellation and optional line-by-line output.
public enum Command {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    /// Runs `executable`. When `onLine` is given, stdout is delivered line by line as it arrives
    /// (on a background thread) and isn't kept in the result.
    public static func run(
        _ executable: URL, _ args: [String], input: URL? = nil, timeout: TimeInterval = 3600,
        isCancelled: @Sendable () -> Bool = { false }, onLine: (@Sendable (String) -> Void)? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        process.environment = env
        process.qualityOfService = .utility

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = try input.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice

        let outData = LockedData(), errData = LockedData()
        let lines = onLine.map { LineSplitter(onLine: $0) }
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if let lines { lines.feed(d) } else { outData.append(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in errData.append(h.availableData) }

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        var failure: Error?
        while process.isRunning {
            if isCancelled() { failure = CancellationError(); break }
            if Date() > deadline {
                failure = CommandError(tool: executable.lastPathComponent, status: -1, output: "\(executable.lastPathComponent) timed out")
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if failure != nil, process.isRunning { process.terminate() }
        process.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        let rest = outPipe.fileHandleForReading.readDataToEndOfFile()
        if let lines { lines.feed(rest); lines.finish() } else { outData.append(rest) }
        errData.append(errPipe.fileHandleForReading.readDataToEndOfFile())
        if let failure { throw failure }
        return Result(status: process.terminationStatus, stdout: outData.string, stderr: errData.string)
    }
}

/// Splits a byte stream into lines.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    func finish() {
        lock.lock()
        let last = buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        lock.unlock()
        if let last { onLine(last) }
    }
}
