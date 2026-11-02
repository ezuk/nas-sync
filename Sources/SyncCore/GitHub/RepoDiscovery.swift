import Foundation

/// A git repository to back up: a clone on this Mac (with or without a GitHub remote) or a GitHub repo
/// listed in `remote_only`.
public struct RepoTarget: Sendable, Equatable {
    /// GitHub owner. Empty for a clone with no GitHub remote.
    public var owner: String
    /// GitHub repo name, or the folder name for a clone with no GitHub remote.
    public var name: String
    public var source: RepoSource
    /// Working folder of a local clone.
    public var localPath: URL?
    /// The GitHub remote URL. Empty for a clone with no GitHub remote.
    public var remoteURL: String
    /// True for clones listed in `github.repos`, which are always backed up, even with `new_repos = "prompt"`.
    public var isListed: Bool

    /// `owner/repo`, or just the folder name for a clone with no GitHub remote.
    public var fullName: String { owner.isEmpty ? name : "\(owner)/\(name)" }
    public var hasGitHubRemote: Bool { !owner.isEmpty }
    /// `https://github.com/owner/repo`, when the repo is on GitHub.
    public var githubURL: URL? { hasGitHubRemote ? URL(string: "https://github.com/\(fullName)") : nil }

    public init(owner: String, name: String, source: RepoSource, localPath: URL?, remoteURL: String, isListed: Bool = false) {
        self.owner = owner
        self.name = name
        self.source = source
        self.localPath = localPath
        self.remoteURL = remoteURL
        self.isListed = isListed
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
        guard let gitDir = gitDirectory(of: repo),
              let text = try? String(contentsOf: gitDir.appending(path: "config"), encoding: .utf8) else { return nil }
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

    /// The folder holding a working folder's repository config: `.git`, or for a worktree or submodule (where
    /// `.git` is a file), the folder it points to, or that folder's common folder.
    static func gitDirectory(of repo: URL) -> URL? {
        let fm = FileManager.default
        let dotGit = repo.appending(path: ".git")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dotGit.path(percentEncoded: false), isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return dotGit }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        var dir = path.hasPrefix("/") ? URL(filePath: path, directoryHint: .isDirectory) : repo.appending(path: path, directoryHint: .isDirectory)
        if let common = try? String(contentsOf: dir.appending(path: "commondir"), encoding: .utf8) {
            let c = common.trimmingCharacters(in: .whitespacesAndNewlines)
            dir = c.hasPrefix("/") ? URL(filePath: c, directoryHint: .isDirectory) : dir.appending(path: c, directoryHint: .isDirectory)
        }
        return dir.standardizedFileURL
    }

    /// True when `dir` is a git working folder (it has a `.git` folder or file).
    public static func isWorkingFolder(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appending(path: ".git").path(percentEncoded: false))
    }

    /// Everything the config backs up, minus excluded repos, without changing anything: clones with a GitHub remote
    /// under the scan folders, then the clones listed in `repos` (a GitHub remote is optional there), then
    /// `remote_only`. The first one found wins for duplicates. Clones in `repos` that don't exist are left out.
    public static func targets(config: GitHubConfig) -> (targets: [RepoTarget], excluded: [RepoTarget]) {
        var byName: [String: RepoTarget] = [:]
        var order: [String] = []
        func add(_ t: RepoTarget) {
            let key = t.fullName.lowercased()
            if byName[key] == nil {
                byName[key] = t
                order.append(key)
            }
        }
        for dir in findRepos(in: config.scan) {
            guard let r = githubRemote(of: dir) else { continue }
            add(RepoTarget(owner: r.owner, name: r.repo, source: .localClone, localPath: dir, remoteURL: r.url))
        }
        var listed: Set<String> = []
        for dir in config.repos where isWorkingFolder(dir) {
            listed.insert(dir.standardizedFileURL.path(percentEncoded: false))
            if let r = githubRemote(of: dir) {
                add(RepoTarget(owner: r.owner, name: r.repo, source: .localClone, localPath: dir, remoteURL: r.url, isListed: true))
            } else {
                add(RepoTarget(owner: "", name: dir.standardizedFileURL.lastPathComponent, source: .localClone, localPath: dir, remoteURL: "", isListed: true))
            }
        }
        for full in config.remoteOnly {
            let parts = full.split(separator: "/").map(String.init)
            guard parts.count == 2 else { continue }
            // A clone also named here counts as listed: it was asked for by name.
            byName[full.lowercased()]?.isListed = true
            add(RepoTarget(owner: parts[0], name: parts[1], source: .remoteOnly, localPath: nil, remoteURL: GitHubRemote.sshURL(full)))
        }
        let globs = config.excludeSet
        var targets: [RepoTarget] = [], excluded: [RepoTarget] = []
        for key in order {
            var t = byName[key]!
            // A clone found in a scan folder that is also listed in `repos` counts as listed.
            if let path = t.localPath?.standardizedFileURL.path(percentEncoded: false), listed.contains(path) { t.isListed = true }
            if globs.matches(t.fullName) || globs.matches(t.fullName.lowercased()) { excluded.append(t) } else { targets.append(t) }
        }
        return (targets, excluded)
    }
}
