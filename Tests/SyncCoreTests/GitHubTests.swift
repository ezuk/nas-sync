import Foundation
import Testing
@testable import SyncCore

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .current
    return c.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
}

@Suite struct RemoteParsingTests {
    @Test func parsesGitHubURLs() {
        #expect(GitHubRemote.parse("git@github.com:Owner/repo.git")! == ("Owner", "repo"))
        #expect(GitHubRemote.parse("https://github.com/owner/repo")! == ("owner", "repo"))
        #expect(GitHubRemote.parse("https://github.com/owner/repo.git/")! == ("owner", "repo"))
        #expect(GitHubRemote.parse("ssh://git@github.com/owner/repo.git")! == ("owner", "repo"))
        #expect(GitHubRemote.parse("https://token@github.com/owner/repo.git")! == ("owner", "repo"))
        #expect(GitHubRemote.parse("git@gitlab.com:owner/repo.git") == nil)
        #expect(GitHubRemote.parse("https://github.com/owner") == nil)
    }
}

@Suite struct MirrorNamingTests {
    @Test func deletedRefNamesNeverClash() {
        var existing: Set<String> = ["refs/heads/fix", "refs/deleted/2026-11-01/heads/old"]
        #expect(GitHubBackup.deletedName(for: "refs/heads/fix", day: "2026-11-01", existing: &existing) == "refs/deleted/2026-11-01/heads/fix")
        // Same branch deleted twice on one day.
        #expect(GitHubBackup.deletedName(for: "refs/heads/fix", day: "2026-11-01", existing: &existing) == "refs/deleted/2026-11-01-2/heads/fix")
        // Would be a folder and a ref at once.
        #expect(GitHubBackup.deletedName(for: "refs/heads/old/x", day: "2026-11-01", existing: &existing) == "refs/deleted/2026-11-01-2/heads/old/x")
        #expect(GitHubBackup.deletedName(for: "refs/tags/v1", day: "2026-11-02", existing: &existing) == "refs/deleted/2026-11-02/tags/v1")
    }

    @Test func rsyncStats() {
        #expect(NAS.transferredBytes("Number of files: 3\nTotal transferred file size: 1,234 bytes\n") == 1234)
        #expect(NAS.transferredBytes("nothing") == 0)
    }

    @Test func newRepoListMerging() {
        #expect(Engine.mergeNewRepos(existing: ["a/x"], found: ["a/y", "A/X"], replace: false) == ["a/x", "a/y"])
        #expect(Engine.mergeNewRepos(existing: ["a/x"], found: ["a/y"], replace: true) == ["a/y"])
    }
}

/// Throwaway repos plus a fake NAS folder.
private final class GitSandbox {
    let root: URL
    let git = Git()

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "nassync-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: nas, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scan, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var scan: URL { root.appending(path: "code") }
    /// Clones outside the scan folder, for `repos`.
    var elsewhere: URL { root.appending(path: "elsewhere") }
    var nas: URL { root.appending(path: "nas/github-backups") }
    var work: URL { root.appending(path: "work") }

    func mirror(_ path: String) -> URL { nas.appending(path: "mirrors/\(path)") }

    @discardableResult
    func makeRepo(_ path: String, remote: String?, commits: Int = 1, in base: URL? = nil) throws -> URL {
        let dir = (base ?? scan).appending(path: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try git.run(["init", "--quiet", "-b", "main"], in: dir)
        try git.run(["config", "user.email", "test@example.com"], in: dir)
        try git.run(["config", "user.name", "Test"], in: dir)
        try git.run(["config", "commit.gpgsign", "false"], in: dir)
        try git.run(["config", "tag.gpgsign", "false"], in: dir)
        if let remote { try git.run(["remote", "add", "origin", remote], in: dir) }
        try commit(dir, count: commits)
        return dir
    }

    func commit(_ dir: URL, count: Int = 1) throws {
        for _ in 0..<count {
            try UUID().uuidString.write(to: dir.appending(path: "file.txt"), atomically: true, encoding: .utf8)
            try git.run(["add", "."], in: dir)
            try git.run(["commit", "--quiet", "-m", "change"], in: dir)
        }
    }

    func sha(_ ref: String, in dir: URL) throws -> String {
        try git.run(["rev-parse", ref], in: dir).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func refs(_ prefix: String, in dir: URL) throws -> [String] {
        try git.run(["for-each-ref", "--format=%(refname)", prefix], in: dir).split(separator: "\n").map(String.init)
    }

    func config(remoteOnly: [String] = [], exclude: [String] = [], newRepos: GitHubConfig.NewRepos = .include,
                repos: [URL] = [], onRemoteDelete: GitHubConfig.OnRemoteDelete = .keep) -> GitHubConfig {
        var c = GitHubConfig(every: Interval(seconds: 86400), around: nil, staleAfter: Interval(seconds: 172800), dest: "github-backups",
                             scan: [scan], newRepos: newRepos, exclude: exclude, remoteOnly: remoteOnly,
                             groups: ["acme": "acme", "*": "other"], line: 1)
        c.repos = repos
        c.onRemoteDelete = onRemoteDelete
        return c
    }

    func backup(_ config: GitHubConfig, store: Store) -> GitHubBackup {
        let remote = NAS(config: NASConfig(ssh: nil, path: root.appending(path: "nas").path(percentEncoded: false)))
        let b = GitHubBackup(config: config, nas: remote, store: store, workDirectory: work)
        b.checksGitHub = false
        return b
    }
}

@Suite(.serialized) struct GitHubBackupTests {
    @Test func discoversReposAndSkipsNested() throws {
        let s = try GitSandbox()
        let outer = try s.makeRepo("acme/app", remote: "git@github.com:acme/app.git")
        try s.makeRepo("acme/app/vendor/lib", remote: "git@github.com:other/lib.git")
        try s.makeRepo("misc/notgithub", remote: "git@gitlab.com:x/y.git")
        try s.makeRepo("misc/noremote", remote: nil)
        try s.makeRepo("misc/tool", remote: "https://github.com/someone/tool.git")
        let thesis = try s.makeRepo("thesis", remote: nil, in: s.elsewhere)
        let listed = try s.makeRepo("site", remote: "git@github.com:me/site.git", in: s.elsewhere)

        let found = RepoDiscovery.findRepos(in: [s.scan])
        #expect(found.count == 4)
        #expect(!found.contains { $0.path().contains("vendor") })
        #expect(RepoDiscovery.githubRemote(of: outer)?.owner == "acme")

        let config = s.config(remoteOnly: ["acme/archive"], exclude: ["someone/*"],
                              repos: [thesis, listed, outer, s.elsewhere.appending(path: "missing")])
        let (targets, excluded) = RepoDiscovery.targets(config: config)
        #expect(targets.map(\.fullName) == ["acme/app", "thesis", "me/site", "acme/archive"])
        #expect(targets[0].isListed)
        #expect(!targets[1].hasGitHubRemote && targets[1].isListed && targets[1].remoteURL.isEmpty)
        #expect(targets[2].hasGitHubRemote && targets[2].isListed)
        #expect(targets[3].source == .remoteOnly && !targets[3].isListed)
        #expect(excluded.map(\.fullName) == ["someone/tool"])
    }

    @Test func backsUpThenSkipsUnchangedThenDetectsChanges() throws {
        let s = try GitSandbox()
        let repo = try s.makeRepo("acme/app", remote: "git@github.com:acme/app.git", commits: 2)
        let store = try Store(directory: s.root.appending(path: "state"))

        let first = s.backup(s.config(), store: store).run(trigger: "manual", now: day(2026, 4, 1))
        #expect(first.record.outcome == .success)
        #expect(first.repos.first?.action == .backedUp)
        #expect(first.repos.first?.reason.hasPrefix("new repo") == true)
        // Not pushed anywhere, so all commits count as unpushed.
        #expect(first.repos.first?.reason.contains("2 commits not pushed") == true)

        let mirror = s.mirror("acme/app.git")
        #expect(FileManager.default.fileExists(atPath: mirror.appending(path: "HEAD").path(percentEncoded: false)))
        let reports = try FileManager.default.contentsOfDirectory(atPath: s.nas.appending(path: "reports").path(percentEncoded: false))
        #expect(reports.count == 1)

        // The mirror on the NAS clones to a repo with the same history.
        let clone = s.root.appending(path: "clone")
        try s.git.run(["clone", "--quiet", mirror.path(percentEncoded: false), clone.path(percentEncoded: false)])
        #expect(try s.sha("HEAD", in: clone) == s.sha("HEAD", in: repo))

        let record1 = try #require(store.repo("acme/app"))
        #expect(record1.mirrorPath == "acme/app.git")
        #expect((record1.sizeOnNAS ?? 0) > 0)
        #expect(record1.mirrorUpdated != nil)
        #expect(record1.hasGitHubRemote)

        let second = s.backup(s.config(), store: store).run(trigger: "scheduled", now: day(2026, 4, 2))
        #expect(second.repos.first?.action == .unchanged)

        try s.commit(repo, count: 3)
        try s.git.run(["branch", "feature/x"], in: repo)
        let third = s.backup(s.config(), store: store).run(trigger: "scheduled", now: day(2026, 4, 3))
        let reason = try #require(third.repos.first?.reason)
        #expect(reason.contains("3 new commits on main"))
        #expect(reason.contains("new branch feature/x"))
        #expect(try s.sha("refs/heads/feature/x", in: mirror) == s.sha("HEAD", in: repo))
        #expect(store.repo("acme/app")?.status == .ok)
    }

    @Test func dryRunWritesNothing() throws {
        let s = try GitSandbox()
        try s.makeRepo("acme/app", remote: "git@github.com:acme/app.git")
        let store = try Store(directory: s.root.appending(path: "state"))
        let result = s.backup(s.config(), store: store).run(trigger: "manual", dryRun: true)
        #expect(result.repos.first?.action == .wouldBackUp)
        #expect(result.record.summary == "1 would be backed up")
        #expect(!FileManager.default.fileExists(atPath: s.nas.appending(path: "mirrors").path(percentEncoded: false)))
        #expect(store.repos().isEmpty)
    }

    @Test func keepsDeletedBranchesAndForcePushedCommits() throws {
        let s = try GitSandbox()
        let repo = try s.makeRepo("acme/app", remote: "git@github.com:acme/app.git", commits: 2)
        try s.git.run(["checkout", "--quiet", "-b", "feature"], in: repo)
        try s.commit(repo)
        try s.git.run(["checkout", "--quiet", "main"], in: repo)
        try s.git.run(["tag", "v1"], in: repo)
        let feature = try s.sha("refs/heads/feature", in: repo)
        let oldMain = try s.sha("refs/heads/main", in: repo)
        let store = try Store(directory: s.root.appending(path: "state"))
        _ = s.backup(s.config(), store: store).run(trigger: "manual", now: day(2026, 4, 1))

        // Delete the branch and the tag, and rewrite main.
        try s.git.run(["branch", "-D", "feature"], in: repo)
        try s.git.run(["tag", "-d", "v1"], in: repo)
        try s.git.run(["reset", "--quiet", "--hard", "HEAD~1"], in: repo)
        try s.commit(repo)
        let result = s.backup(s.config(), store: store).run(trigger: "manual", now: day(2026, 4, 2))
        let r = try #require(result.repos.first)
        #expect(r.action == .backedUp)
        #expect(Set(r.keptRefs) == ["refs/deleted/2026-04-02/heads/feature", "refs/deleted/2026-04-02/tags/v1",
                                    "refs/deleted/2026-04-02/heads/main"])
        #expect(result.record.counts.keptRefs == 3)
        #expect(result.record.summary.contains("3 deleted refs kept"))

        let mirror = s.mirror("acme/app.git")
        #expect(try s.refs("refs/heads", in: mirror) == ["refs/heads/main"])
        #expect(try s.refs("refs/tags", in: mirror).isEmpty)
        #expect(try s.sha("refs/deleted/2026-04-02/heads/feature", in: mirror) == feature)
        #expect(try s.sha("refs/deleted/2026-04-02/heads/main", in: mirror) == oldMain)
        #expect(try s.sha("refs/heads/main", in: mirror) == s.sha("HEAD", in: repo))
        #expect(store.repo("acme/app")?.deletedRefsKept.count == 3)

        // A lost cache on this Mac is filled from the NAS first, so the kept refs survive.
        try FileManager.default.removeItem(at: s.work)
        try s.commit(repo)
        _ = s.backup(s.config(), store: store).run(trigger: "manual", now: day(2026, 4, 3))
        #expect(try s.sha("refs/deleted/2026-04-02/heads/feature", in: mirror) == feature)
        #expect(try s.sha("refs/heads/main", in: mirror) == s.sha("HEAD", in: repo))
    }

    @Test func pruneRemovesDeletedBranches() throws {
        let s = try GitSandbox()
        let repo = try s.makeRepo("acme/app", remote: "git@github.com:acme/app.git")
        try s.git.run(["branch", "feature"], in: repo)
        let store = try Store(directory: s.root.appending(path: "state"))
        let config = s.config(onRemoteDelete: .prune)
        _ = s.backup(config, store: store).run(trigger: "manual", now: day(2026, 4, 1))
        let mirror = s.mirror("acme/app.git")
        #expect(try s.refs("refs/heads", in: mirror) == ["refs/heads/feature", "refs/heads/main"])

        try s.git.run(["branch", "-D", "feature"], in: repo)
        let result = s.backup(config, store: store).run(trigger: "manual", now: day(2026, 4, 2))
        #expect(result.repos.first?.prunedRefs == ["refs/heads/feature"])
        #expect(result.record.counts.pruned == 1)
        #expect(try s.refs("refs/heads", in: mirror) == ["refs/heads/main"])
        #expect(try s.refs("refs/deleted", in: mirror).isEmpty)
    }

    @Test func reposWithoutGitHubRemoteGoToLocalGroup() throws {
        let s = try GitSandbox()
        try s.makeRepo("acme/app", remote: "git@github.com:acme/app.git")
        let store = try Store(directory: s.root.appending(path: "state"))
        _ = s.backup(s.config(), store: store).run(trigger: "manual", now: day(2026, 4, 1))

        // Listed in repos after the first run: counts as decided even with prompt.
        let thesis = try s.makeRepo("thesis", remote: nil, commits: 2, in: s.elsewhere)
        let result = s.backup(s.config(newRepos: .prompt, repos: [thesis]), store: store).run(trigger: "manual", now: day(2026, 4, 2))
        #expect(result.repos.first { $0.fullName == "thesis" }?.action == .backedUp)
        #expect(result.newRepos.isEmpty)
        let mirror = s.mirror("local/thesis.git")
        #expect(try s.sha("refs/heads/main", in: mirror) == s.sha("HEAD", in: thesis))
        let record = try #require(store.repo("thesis"))
        #expect(!record.hasGitHubRemote)
        #expect(record.unpushedCommits == nil)
        #expect(record.mirrorPath == "local/thesis.git")
    }

    @Test func promptHoldsNewReposUntilIncluded() throws {
        let s = try GitSandbox()
        try s.makeRepo("acme/app", remote: "git@github.com:acme/app.git")
        let store = try Store(directory: s.root.appending(path: "state"))
        let first = s.backup(s.config(newRepos: .prompt), store: store).run(trigger: "manual", now: day(2026, 4, 1))
        #expect(first.newRepos.isEmpty)
        #expect(first.repos.first?.action == .backedUp)

        try s.makeRepo("acme/new", remote: "git@github.com:acme/new.git")
        let held = s.backup(s.config(newRepos: .prompt), store: store).run(trigger: "manual", now: day(2026, 4, 2))
        #expect(held.newRepos == ["acme/new"])
        let r = try #require(held.repos.first { $0.fullName == "acme/new" })
        #expect(r.action == .skipped)
        #expect(r.reason.contains("waiting for you to decide"))
        #expect(store.repo("acme/new") == nil)
        #expect(!FileManager.default.fileExists(atPath: s.mirror("acme/new.git").path(percentEncoded: false)))

        // What Engine.includeNewRepos saves.
        try store.saveRepo(RepoRecord(fullName: "acme/new", source: .localClone, localPath: nil, firstSeen: day(2026, 4, 2)))
        let included = s.backup(s.config(newRepos: .prompt), store: store).run(trigger: "manual", now: day(2026, 4, 3))
        #expect(included.newRepos.isEmpty)
        #expect(included.repos.first { $0.fullName == "acme/new" }?.action == .backedUp)
        #expect(FileManager.default.fileExists(atPath: s.mirror("acme/new.git/HEAD").path(percentEncoded: false)))
    }

    @Test func newReposAreReportedAfterFirstRun() throws {
        let s = try GitSandbox()
        try s.makeRepo("acme/app", remote: "git@github.com:acme/app.git")
        let store = try Store(directory: s.root.appending(path: "state"))
        let first = s.backup(s.config(), store: store).run(trigger: "manual", now: day(2026, 4, 1))
        #expect(first.newRepos.isEmpty)

        try s.makeRepo("acme/new", remote: "git@github.com:acme/new.git")
        let ignored = s.backup(s.config(newRepos: .ignore), store: store).run(trigger: "manual", now: day(2026, 4, 2))
        #expect(ignored.newRepos == ["acme/new"])
        #expect(ignored.repos.first { $0.fullName == "acme/new" }?.action == .skipped)
    }

    @Test func flagsMissingReposAndKeepsTheirMirror() throws {
        let s = try GitSandbox()
        let repo = try s.makeRepo("acme/app", remote: "git@github.com:acme/app.git")
        let store = try Store(directory: s.root.appending(path: "state"))
        _ = s.backup(s.config(), store: store).run(trigger: "manual", now: day(2026, 4, 1))
        try FileManager.default.removeItem(at: repo)
        _ = s.backup(s.config(), store: store).run(trigger: "manual", now: day(2026, 4, 2))
        #expect(store.repo("acme/app")?.status == .missingLocally)
        #expect(FileManager.default.fileExists(atPath: s.mirror("acme/app.git/HEAD").path(percentEncoded: false)))
    }

    @Test func sameNameInOneGroupGetsItsOwnMirror() throws {
        let s = try GitSandbox()
        try s.makeRepo("x/app", remote: "git@github.com:someone/app.git")
        try s.makeRepo("y/app", remote: "git@github.com:other/app.git")
        let store = try Store(directory: s.root.appending(path: "state"))
        _ = s.backup(s.config(), store: store).run(trigger: "manual", now: day(2026, 4, 1))
        #expect(store.repo("someone/app")?.mirrorPath == "other/app.git")
        #expect(store.repo("other/app")?.mirrorPath == "other/other-app.git")
    }

    @Test func mirrorsFromAnyGitURL() throws {
        let s = try GitSandbox()
        let upstream = try s.makeRepo("upstream", remote: nil, commits: 2)
        try s.git.run(["tag", "v1"], in: upstream)
        let store = try Store(directory: s.root.appending(path: "state"))
        let b = s.backup(s.config(), store: store)
        let url = upstream.path(percentEncoded: false)
        let remote = try b.remoteRefs(url, isCancelled: { false })
        #expect(Set(remote.keys) == ["refs/heads/main", "refs/tags/v1"])

        let mirror = s.work.appending(path: "nas-mirrors/x/upstream.git")
        try b.prepareMirror(mirror, nasPath: "github-backups/mirrors/x/upstream.git", onNAS: false, previous: nil, isCancelled: { false })
        let update = try b.updateMirror(mirror, from: url, sourceRefs: remote, now: day(2026, 4, 1), isCancelled: { false })
        #expect(update == GitHubBackup.MirrorUpdate())
        #expect(try b.localRefs(mirror) == remote)
        #expect(GitHubBackup.fingerprint(try b.localRefs(mirror)) == GitHubBackup.fingerprint(remote))
        try b.verifyMirror(mirror, isCancelled: { false })
    }

    @Test func xzRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "nassync-xz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "in"), packed = dir.appending(path: "in.xz"), output = dir.appending(path: "out")
        let data = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try data.write(to: input)
        try XZ.compress(input, to: packed)
        let header = try Data(contentsOf: packed).prefix(6)
        #expect(header == Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]))
        try XZ.decompress(packed, to: output)
        #expect(try Data(contentsOf: output) == data)
    }
}


@Suite(.serialized) struct OpenFileTests {
    private func openFiles() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }

    @Test func gitDoesNotKeepFilesOpen() throws {
        let git = Git()
        let before = openFiles()
        for _ in 0..<100 { try git.run(["--version"]) }
        #expect(openFiles() - before < 50)
    }

    @Test func gitWithInputDoesNotKeepFilesOpen() throws {
        let git = Git()
        let input = FileManager.default.temporaryDirectory.appending(path: "nassync-input-\(UUID().uuidString)")
        try Data("x\n".utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let before = openFiles()
        for _ in 0..<100 { try git.run(["hash-object", "--stdin"], input: input) }
        #expect(openFiles() - before < 50)
    }

    @Test func commandDoesNotKeepFilesOpen() throws {
        let before = openFiles()
        for _ in 0..<100 { _ = try Command.run(URL(filePath: "/bin/echo"), ["hi"]) }
        #expect(openFiles() - before < 50)
    }
}

@Suite(.serialized) struct LostRefsTests {
    @Test func repoThatHadRefsIsNotSkippedAsEmpty() throws {
        let s = try GitSandbox()
        let repo = try s.makeRepo("acme/app", remote: "git@github.com:acme/app.git")
        let store = try Store(directory: s.root.appending(path: "store"))
        let config = s.config()
        #expect(s.backup(config, store: store).run(trigger: "test").repos.first?.action == .backedUp)

        try s.git.run(["update-ref", "-d", "refs/heads/main"], in: repo)
        let result = s.backup(config, store: store).run(trigger: "test")
        let r = try #require(result.repos.first)
        #expect(r.action == .failed)
        #expect(r.reason.hasPrefix("While checking for changes: "))
        #expect(r.reason.contains("reported no branches"))
        #expect(store.repo("acme/app")?.status == .failed)
    }

    @Test func emptyRepoIsStillSkipped() throws {
        let s = try GitSandbox()
        let dir = s.scan.appending(path: "acme/fresh")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try s.git.run(["init", "--quiet", "-b", "main"], in: dir)
        try s.git.run(["remote", "add", "origin", "git@github.com:acme/fresh.git"], in: dir)
        let store = try Store(directory: s.root.appending(path: "store"))
        let result = s.backup(s.config(), store: store).run(trigger: "test")
        #expect(result.repos.first?.action == .skipped)
        #expect(result.record.summary == "1 skipped")
        #expect(result.record.outcome == .success)
    }
}
