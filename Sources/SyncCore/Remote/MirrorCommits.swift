import Foundation

/// A commit as it is in a mirror on the NAS.
public struct MirrorCommit: Sendable, Equatable, Identifiable {
    public var sha: String
    public var shortSHA: String
    public var subject: String
    public var author: String
    public var date: Date
    /// Branches and tags that point at this commit.
    public var refs: [String]

    public var id: String { sha }

    static let separator = "\u{1F}"
    static let terminator = "\u{1E}"
    static let format = ["%H", "%h", "%ct", "%an", "%D", "%s"].joined(separator: "%x1f") + "%x1e"

    /// Reads `git log` output written with `format`.
    static func parse(_ output: String) -> [MirrorCommit] {
        output.components(separatedBy: terminator).compactMap { record in
            let fields = record.trimmingCharacters(in: .newlines).components(separatedBy: separator)
            guard fields.count == 6, let seconds = TimeInterval(fields[2]) else { return nil }
            let refs = fields[4].components(separatedBy: ", ").compactMap { ref -> String? in
                let name = ref.replacingOccurrences(of: "HEAD -> ", with: "").replacingOccurrences(of: "tag: ", with: "")
                return name.isEmpty || name == "HEAD" ? nil : name
            }
            return MirrorCommit(sha: fields[0], shortSHA: fields[1], subject: fields[5], author: fields[3],
                                date: Date(timeIntervalSince1970: seconds), refs: refs)
        }
    }
}

/// Why a mirror couldn't be read.
public enum MirrorReadError: LocalizedError, Equatable {
    case noMirror
    case notReachable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noMirror: "There's no mirror of this repo on the NAS yet."
        case .notReachable: "Couldn't reach the NAS to read this mirror."
        case .failed(let detail): "Couldn't read this mirror: \(detail)"
        }
    }
}

extension NAS {
    /// The newest commits in a mirror, across its branches, tags and what this Mac has sent. Stashes aren't included.
    public func recentCommits(inMirror rel: String, count: Int = 5) throws -> [MirrorCommit] {
        let script = """
        export \(Self.gitPathOnNAS); git --git-dir=\(Self.quote(absolute(rel))) log -\(count) --date-order --format=\(Self.quote(MirrorCommit.format)) \
        --decorate-refs=refs/heads --decorate-refs=refs/tags --branches --tags --exclude=refs/mac/stash --glob='refs/mac/*'
        """
        let result: Command.Result
        do {
            result = try shellRaw(script, timeout: 30)
        } catch {
            throw MirrorReadError.notReachable
        }
        guard result.status == 0 else {
            if isRemote, result.status == 255 { throw MirrorReadError.notReachable }
            if result.stderr.contains("not a git repository") { throw MirrorReadError.noMirror }
            throw MirrorReadError.failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return MirrorCommit.parse(result.stdout)
    }
}
