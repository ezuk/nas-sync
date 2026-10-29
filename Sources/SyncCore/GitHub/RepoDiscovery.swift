import Foundation

/// A GitHub repository to back up.
public struct RepoTarget: Sendable, Equatable {
    public var owner: String
    public var name: String
    public var source: RepoSource
    /// Working folder of a local clone.
    public var localPath: URL?
    public var remoteURL: String

    public var fullName: String { "\(owner)/\(name)" }

    public init(owner: String, name: String, source: RepoSource, localPath: URL?, remoteURL: String) {
        self.owner = owner
        self.name = name
        self.source = source
        self.localPath = localPath
        self.remoteURL = remoteURL
    }
}

public enum GitHubRemote {
    /// Owner and repo from a GitHub remote URL (scp-style ssh, ssh://, https://).
    public static func parse(_ url: String) -> (owner: String, repo: String)? {
        var s = url.trimmingCharacters(in: .whitespaces)
        let prefixes = ["git@github.com:", "ssh://git@github.com/", "ssh://github.com/", "https://github.com/",
                        "http://github.com/", "git://github.com/", "https://www.github.com/"]
        guard let prefix = prefixes.first(where: { s.lowercased().hasPrefix($0) }) else {
            // https://user@github.com/owner/repo
            guard let r = s.range(of: "@github.com/", options: .caseInsensitive), s.lowercased().hasPrefix("https://") else { return nil }
            s = String(s[r.upperBound...])
            return split(s)
        }
        s.removeFirst(prefix.count)
        return split(s)
    }

    private static func split(_ path: String) -> (owner: String, repo: String)? {
        var p = path
        while p.hasSuffix("/") { p.removeLast() }
        if p.hasSuffix(".git") { p.removeLast(4) }
        let parts = p.split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    public static func sshURL(_ fullName: String) -> String { "git@github.com:\(fullName).git" }
}

public enum RepoDiscovery {
    public static let maxDepth = 6
    static let skippedFolders: Set<String> = ["node_modules", "Pods", "DerivedData", ".build"]

    /// Git working folders under `roots`. Doesn't descend into repos, so submodules and nested repos are skipped.
    public static func findRepos(in roots: [URL]) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        var queue: [(URL, Int)] = roots.map { ($0, 0) }
        var seen: Set<String> = []
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            let path = dir.standardizedFileURL.path(percentEncoded: false)
            guard seen.insert(path).inserted else { continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.appending(path: ".git").path(percentEncoded: false), isDirectory: &isDir), isDir.boolValue {
                found.append(dir)
                continue
            }
            guard depth < maxDepth,
                  let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true,
                      !skippedFolders.contains(child.lastPathComponent) else { continue }
                queue.append((child, depth + 1))
            }
        }
        return found
    }

    /// The GitHub remote of a working folder, preferring `origin`.
    public static func githubRemote(of repo: URL) -> (owner: String, repo: String, url: String)? {
        guard let text = try? String(contentsOf: repo.appending(path: ".git/config"), encoding: .utf8) else { return nil }
        var remotes: [(name: String, url: String)] = []
        var current: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = nil
                // [remote "origin"]
                if line.hasPrefix("[remote "), let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close {
                    current = String(line[line.index(after: open)..<close])
                }
            } else if let name = current, let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                if key == "url" {
                    remotes.append((name, line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        let ordered = remotes.filter { $0.name == "origin" } + remotes.filter { $0.name != "origin" }
        for r in ordered {
            if let parsed = GitHubRemote.parse(r.url) { return (parsed.owner, parsed.repo, r.url) }
        }
        return nil
    }

    /// Local clones plus remote-only repos, minus excluded ones. The first clone found wins for duplicates.
    public static func targets(config: GitHubConfig) -> (targets: [RepoTarget], excluded: [RepoTarget]) {
        var byName: [String: RepoTarget] = [:]
        var order: [String] = []
        for dir in findRepos(in: config.scan) {
            guard let r = githubRemote(of: dir) else { continue }
            let t = RepoTarget(owner: r.owner, name: r.repo, source: .localClone, localPath: dir, remoteURL: r.url)
            let key = t.fullName.lowercased()
            if byName[key] == nil {
                byName[key] = t
                order.append(key)
            }
        }
        for full in config.remoteOnly {
            let parts = full.split(separator: "/").map(String.init)
            guard parts.count == 2 else { continue }
            let key = full.lowercased()
            if byName[key] == nil {
                byName[key] = RepoTarget(owner: parts[0], name: parts[1], source: .remoteOnly, localPath: nil, remoteURL: GitHubRemote.sshURL(full))
                order.append(key)
            }
        }
        let globs = config.excludeSet
        var targets: [RepoTarget] = [], excluded: [RepoTarget] = []
        for key in order {
            let t = byName[key]!
            if globs.matches(t.fullName) || globs.matches(t.fullName.lowercased()) { excluded.append(t) } else { targets.append(t) }
        }
        return (targets, excluded)
    }
}
