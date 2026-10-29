import Darwin

/// A gitignore-style pattern.
///
/// - A pattern without `/` matches a file or folder name at any depth.
/// - A pattern with `/` is matched against the whole relative path.
/// - `**` matches any number of folders, `*` and `?` match within one name.
/// - A trailing `/` matches folders only.
public struct Glob: Sendable, Hashable {
    public let pattern: String
    private let segments: [String]
    private let anchored: Bool
    private let directoryOnly: Bool

    public init(_ pattern: String) {
        self.pattern = pattern
        var p = pattern
        directoryOnly = p.hasSuffix("/")
        if directoryOnly { p.removeLast() }
        if p.hasPrefix("/") { p.removeFirst() }
        anchored = p.contains("/")
        segments = p.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Matches a path relative to the root, using `/` separators.
    public func matches(_ relativePath: String, isDirectory: Bool = false) -> Bool {
        if directoryOnly && !isDirectory { return false }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return false }
        if anchored {
            return Self.match(segments[...], parts[...])
        }
        guard let name = parts.last, segments.count == 1 else { return false }
        return Self.fn(segments[0], name)
    }

    private static func match(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
        guard let head = pattern.first else { return path.isEmpty }
        if head == "**" {
            let rest = pattern.dropFirst()
            if rest.isEmpty { return true }
            var p = path
            while true {
                if match(rest, p) { return true }
                guard !p.isEmpty else { return false }
                p = p.dropFirst()
            }
        }
        guard let first = path.first, fn(head, first) else { return false }
        return match(pattern.dropFirst(), path.dropFirst())
    }

    private static func fn(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }
}

/// A set of globs where any match counts.
public struct GlobSet: Sendable, Hashable {
    public let globs: [Glob]

    public init(_ patterns: [String]) {
        globs = patterns.map(Glob.init)
    }

    public func matches(_ relativePath: String, isDirectory: Bool = false) -> Bool {
        globs.contains { $0.matches(relativePath, isDirectory: isDirectory) }
    }
}
