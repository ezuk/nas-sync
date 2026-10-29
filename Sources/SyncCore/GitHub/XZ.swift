import Compression
import CryptoKit
import Foundation

/// `.xz` compression using the system Compression framework (LZMA2 in an xz container, level 6).
public enum XZ {
    static let chunkSize = 1 << 20

    public static func compress(_ input: URL, to output: URL, isCancelled: () -> Bool = { false }) throws {
        try transform(input, to: output, operation: .compress, isCancelled: isCancelled)
    }

    public static func decompress(_ input: URL, to output: URL, isCancelled: () -> Bool = { false }) throws {
        try transform(input, to: output, operation: .decompress, isCancelled: isCancelled)
    }

    private static func transform(_ input: URL, to output: URL, operation: FilterOperation, isCancelled: () -> Bool) throws {
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        FileManager.default.createFile(atPath: output.path(percentEncoded: false), contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }

        var writeError: Error?
        let filter = try OutputFilter(operation, using: .lzma) { data in
            guard let data, writeError == nil else { return }
            do { try writer.write(contentsOf: data) } catch { writeError = error }
        }
        while true {
            if isCancelled() { throw CancellationError() }
            let chunk = try reader.read(upToCount: chunkSize) ?? Data()
            try filter.write(chunk)
            if let writeError { throw writeError }
            if chunk.isEmpty { break }
        }
        try filter.finalize()
        if let writeError { throw writeError }
    }

    /// SHA-256 of a file, read in chunks.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
