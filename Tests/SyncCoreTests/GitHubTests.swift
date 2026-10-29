import Foundation
import Testing
@testable import SyncCore

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    ArchiveNaming.calendar.date(from: DateComponents(year: y, month: m, day: d))!
}

private func archives(_ dates: [Date]) -> [ArchiveFile] {
    dates.map { ArchiveFile(name: ArchiveNaming.name(owner: "org", repo: "repo", date: $0), date: $0) }
}

@Suite struct RetentionTests {
    @Test func naming() {
        #expect(ArchiveNaming.name(owner: "MyOrg", repo: "My-Repo", date: day(2026, 4, 3)) == "260403-MyOrg-My-Repo.bundle.xz")
        #expect(ArchiveNaming.date(fromName: "260403-org-repo.bundle.xz") == day(2026, 4, 3))
        #expect(ArchiveNaming.date(fromName: "invalid.bundle.xz") == nil)
        #expect(ArchiveNaming.date(fromName: "261340-org-repo.bundle.xz") == nil)
        #expect(ArchiveNaming.date(fromName: "260231-org-repo.bundle.xz") == nil)
    }

    @Test func recentArchivesAreKept() {
        let r = Retention.apply(archives([day(2026, 4, 3), day(2026, 4, 2)]), policy: .standard, now: day(2026, 4, 3))
        #expect(r.keep.count == 2)
        #expect(r.delete.isEmpty)
    }

    @Test func dailyKeepsNewest() {
        let dates = (1...5).reversed().map { day(2026, 4, $0) }
        let policy = RetentionPolicy(daily: 2, weekly: 0, monthly: 0, quarterly: 0, max: 10)
        let r = Retention.apply(archives(dates), policy: policy, now: day(2026, 4, 5))
        #expect(r.keep.map(\.name) == ["260405-org-repo.bundle.xz", "260404-org-repo.bundle.xz"])
    }

    @Test func weeklyBucket() {
        let dates = [day(2026, 4, 20), day(2026, 4, 19), day(2026, 4, 18), day(2026, 4, 10), day(2026, 4, 3)]
        let policy = RetentionPolicy(daily: 3, weekly: 2, monthly: 0, quarterly: 0, max: 10)
        let r = Retention.apply(archives(dates), policy: policy, now: day(2026, 4, 20))
        #expect(r.keep.count == 5)
    }

    @Test func neverDeletesEverything() {
        let policy = RetentionPolicy(daily: 3, weekly: 1, monthly: 1, quarterly: 0, max: 6)
        let r = Retention.apply(archives([day(2025, 1, 1)]), policy: policy, now: day(2026, 4, 3))
        #expect(r.keep.count == 1)
        #expect(r.delete.isEmpty)
    }

    @Test func maxCap() {
        let dates = (0..<10).map { day(2026, 4, 30 - $0) }
        let policy = RetentionPolicy(daily: 10, weekly: 5, monthly: 5, quarterly: 5, max: 4)
        let r = Retention.apply(archives(dates), policy: policy, now: day(2026, 4, 30))
        #expect(r.keep.count == 4)
        #expect(r.keep.first?.date == day(2026, 4, 30))
    }

    @Test func fullScenario() {
        let dates = [day(2026, 4, 3), day(2026, 4, 2), day(2026, 4, 1), day(2026, 3, 25), day(2026, 3, 18),
                     day(2026, 2, 15), day(2026, 1, 20), day(2025, 12, 1), day(2025, 6, 1)]
        let r = Retention.apply(archives(dates), policy: .standard, now: day(2026, 4, 3))
        #expect(r.keep.count <= 6)
        #expect(r.keep.count + r.delete.count == dates.count)
        #expect(r.delete.contains { $0.date == day(2025, 6, 1) })
        #expect(r.keep.contains { $0.date == day(2026, 3, 25) })
    }

    @Test func pythonWeekNumbers() {
        // 2026-01-01 is a Thursday: week 0 until the first Monday (Jan 5).
        #expect(Retention.weekKey(day(2026, 1, 1)) == "2026-0")
        #expect(Retention.weekKey(day(2026, 1, 5)) == "2026-1")
        #expect(Retention.weekKey(day(2026, 4, 3)) == "2026-13")
    }
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
    var nas: URL { root.appending(path: "nas/github-backups") }
    var work: URL { root.appending(path: "work") }

    @discardableResult
    func makeRepo(_ path: String, remote: String?, commits: Int = 1) throws -> URL {
        let dir = scan.appending(path: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try git.run(["init", "--quiet", "-b", "main"], in: dir)
        try git.run(["config", "user.email", "test@example.com"], in: dir)
        try git.run(["config", "user.name", "Test"], in: dir)
        try git.run(["config", "commit.gpgsign", "false"], in: dir)
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

    func config(remoteOnly: [String] = [], exclude: [String] = [], newRepos: GitHubConfig.NewRepos = .include) -> GitHubConfig {
        GitHubConfig(every: Interval(seconds: 86400), around: nil, staleAfter: Interval(seconds: 172800), dest: "github-backups",
                     scan: [scan], newRepos: newRepos, exclude: exclude, remoteOnly: remoteOnly,
                     groups: ["acme": "acme", "*": "other"], keep: .standard, gc: false, line: 1)
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

        let found = RepoDiscovery.findRepos(in: [s.scan])
        #expect(found.count == 4)
        #expect(!found.contains { $0.path().contains("vendor") })
        #expect(RepoDiscovery.githubRemote(of: outer)?.owner == "acme")

        let (targets, excluded) = RepoDiscovery.targets(config: s.config(remoteOnly: ["acme/archive"], exclude: ["someone/*"]))
        #expect(targets.map(\.fullName) == ["acme/app", "acme/archive"])
        #expect(targets[1].source == .remoteOnly)
        #expect(excluded.map(\.fullName) == ["someone/tool"])
    }

    @Test func backsUpThenSkipsUnchangedThenDetectsChanges() throws {
        let s = try GitSandbox()
        let repo = try s.makeRepo("acme/app", remote: "git@github.com:acme/app.git", commits: 2)
        let store = try Store(directory: s.root.appending(path: "state"))
        let day1 = day(2026, 4, 1)

        let first = s.backup(s.config(), store: store).run(trigger: "manual", now: day1)
        #expect(first.record.outcome == .success)
        #expect(first.repos.first?.action == .backedUp)
        #expect(first.repos.first?.reason.hasPrefix("new repo") == true)
        // Not pushed anywhere, so all commits count as unpushed.
        #expect(first.repos.first?.reason.contains("2 commits not pushed") == true)

        let archive = s.nas.appending(path: "bundles/acme/app/260401-acme-app.bundle.xz")
        #expect(FileManager.default.fileExists(atPath: archive.path(percentEncoded: false)))
        let reports = try FileManager.default.contentsOfDirectory(atPath: s.nas.appending(path: "reports").path(percentEncoded: false))
        #expect(reports.count == 1)

        // The archive restores to a repo with the same history.
        let restored = s.root.appending(path: "restored.bundle")
        try XZ.decompress(archive, to: restored)
        let clone = s.root.appending(path: "clone")
        try s.git.run(["clone", "--quiet", restored.path(percentEncoded: false), clone.path(percentEncoded: false)])
        #expect(try s.git.run(["rev-parse", "HEAD"], in: clone) == s.git.run(["rev-parse", "HEAD"], in: repo))

        let second = s.backup(s.config(), store: store).run(trigger: "scheduled", now: day(2026, 4, 2))
        #expect(second.repos.first?.action == .unchanged)

        try s.commit(repo, count: 3)
        try s.git.run(["branch", "feature/x"], in: repo)
        let third = s.backup(s.config(), store: store).run(trigger: "scheduled", now: day(2026, 4, 3))
        let reason = try #require(third.repos.first?.reason)
        #expect(reason.contains("3 new commits on main"))
        #expect(reason.contains("new branch feature/x"))

        let record = try #require(store.repo("acme/app"))
        #expect(record.archiveCount == 2)
        #expect(record.newestArchiveName == "260403-acme-app.bundle.xz")
        #expect(record.status == .ok)
    }

    @Test func dryRunWritesNothing() throws {
        let s = try GitSandbox()
        try s.makeRepo("acme/app", remote: "git@github.com:acme/app.git")
        let store = try Store(directory: s.root.appending(path: "state"))
        let result = s.backup(s.config(), store: store).run(trigger: "manual", dryRun: true)
        #expect(result.repos.first?.action == .wouldBackUp)
        #expect(result.record.summary == "1 would be backed up")
        #expect(!FileManager.default.fileExists(atPath: s.nas.appending(path: "bundles").path(percentEncoded: false)))
        #expect(store.repos().isEmpty)
    }

    @Test func prunesOldArchivesAndFlagsMissingRepos() throws {
        let s = try GitSandbox()
        let repo = try s.makeRepo("acme/app", remote: "git@github.com:acme/app.git")
        let store = try Store(directory: s.root.appending(path: "state"))
        let folder = s.nas.appending(path: "bundles/acme/app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for d in [day(2026, 3, 30), day(2026, 3, 31), day(2026, 4, 1), day(2025, 1, 1)] {
            try Data("x".utf8).write(to: folder.appending(path: ArchiveNaming.name(owner: "acme", repo: "app", date: d)))
        }
        let result = s.backup(s.config(), store: store).run(trigger: "manual", now: day(2026, 4, 2))
        #expect(result.repos.first?.pruned == ["250101-acme-app.bundle.xz"])
        #expect(store.repo("acme/app")?.archiveCount == 4)

        try FileManager.default.removeItem(at: repo)
        _ = s.backup(s.config(), store: store).run(trigger: "manual", now: day(2026, 4, 3))
        #expect(store.repo("acme/app")?.status == .missingLocally)
        #expect(store.repo("acme/app")?.archiveCount == 4)
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

    @Test func mirrorsRemoteOnlyRepos() throws {
        let s = try GitSandbox()
        let upstream = try s.makeRepo("upstream", remote: nil, commits: 2)
        try s.git.run(["tag", "v1"], in: upstream)
        let store = try Store(directory: s.root.appending(path: "state"))
        let b = s.backup(s.config(), store: store)
        let url = upstream.path(percentEncoded: false)
        let remote = try b.remoteRefs(url, isCancelled: { false })
        #expect(Set(remote.keys) == ["refs/heads/main", "refs/tags/v1"])

        let mirror = s.work.appending(path: "mirrors/x/upstream.git")
        try b.updateMirror(mirror, url: url, isCancelled: { false })
        #expect(try b.localRefs(mirror) == remote)
        #expect(GitHubBackup.fingerprint(try b.localRefs(mirror)) == GitHubBackup.fingerprint(remote))
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
