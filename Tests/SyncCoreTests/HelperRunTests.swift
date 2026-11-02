import Foundation
import Testing
@testable import SyncCore

/// A pretend GitHub (bare repos in a folder), a fake NAS folder and the real helper script.
private final class HelperWorld {
    let root: URL
    let nas: NAS
    let helper: NASHelper
    let git = Git()

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "nassync-run-\(UUID().uuidString)")
        nas = NAS(config: NASConfig(ssh: nil, path: root.appending(path: "nas").path(percentEncoded: false)))
        helper = NASHelper(nas: nas, source: BundledHelper.source, online: false)!
        for dir in [github, work, bin] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(atPath: nas.config.path, withIntermediateDirectories: true)
        _ = try helper.ensure()
        try setFakeLFS(failing: false)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var github: URL { root.appending(path: "github") }
    var work: URL { root.appending(path: "work") }
    var bin: URL { root.appending(path: "bin") }
    var mirrors: URL { root.appending(path: "nas/mirrors-v2") }
    var lfsLog: URL { root.appending(path: "lfs.log") }

    func mirror(_ name: String) -> URL { mirrors.appending(path: "\(name).git") }

    /// A bare "GitHub" repo with one commit on main, and a working copy to change it from.
    func makeRepo(_ name: String) throws {
        let bare = github.appending(path: "\(name).git")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try git.run(["init", "--bare", "--quiet", "-b", "main"], in: bare)
        let copy = work.appending(path: name)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try git.run(["init", "--quiet", "-b", "main"], in: copy)
        try git.run(["remote", "add", "origin", bare.path(percentEncoded: false)], in: copy)
        try commit(name, "first")
        try git.run(["push", "--quiet", "origin", "main"], in: copy)
    }

    func copy(_ name: String) -> URL { work.appending(path: name) }

    func commit(_ name: String, _ message: String) throws {
        try git.run(["-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "--quiet", "--allow-empty", "-m", message], in: copy(name))
    }

    func sha(_ ref: String, in repo: URL) throws -> String {
        try git.run(["rev-parse", ref], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func refs(_ prefix: String, in repo: URL) throws -> [String] {
        try git.run(["for-each-ref", "--format=%(refname)", prefix], in: repo).split(whereSeparator: \.isNewline).map(String.init).sorted()
    }

    func manifest(_ names: [String], onRemoteDelete: String = "keep") throws {
        let repos = names.map {
            HelperManifest.Repo(name: "owner/\($0)", url: github.appending(path: "\($0).git").path(percentEncoded: false), path: "\($0).git")
        }
        try helper.save(HelperManifest(mirrors: mirrors.path(percentEncoded: false), onRemoteDelete: onRemoteDelete, repos: repos))
    }

    func setFakeLFS(failing: Bool) throws {
        let script = bin.appending(path: "git-lfs")
        try Data("#!/bin/sh\necho \"$@\" >> '\(lfsLog.path(percentEncoded: false))'\n\(failing ? "echo 'quota exceeded' >&2; exit 2\n" : "exit 0\n")".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
    }

    var lfsCalls: Int {
        ((try? String(contentsOf: lfsLog, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).count
    }

    /// Runs the helper to completion and returns its report.
    func run() throws -> HelperRunReport {
        let path = "\(bin.path(percentEncoded: false)):\(ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")"
        let r = try Command.run(URL(filePath: "/usr/bin/env"), ["PATH=\(path)", "/usr/bin/python3", helper.currentScript, "run"], timeout: 120)
        #expect(r.status == 0, "\(r.stderr)")
        return try #require(try helper.lastRun())
    }

    func result(_ name: String, _ report: HelperRunReport) throws -> HelperRunReport.Repo {
        try #require(report.repos.first { $0.name == "owner/\(name)" })
    }
}

@Suite(.serialized) struct HelperRunTests {
    @Test func backsUpEveryGitHubBranchAndTag() throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        try w.git.run(["checkout", "--quiet", "-b", "not-on-any-mac"], in: w.copy("app"))
        try w.commit("app", "work")
        try w.git.run(["tag", "v1"], in: w.copy("app"))
        try w.git.run(["push", "--quiet", "origin", "not-on-any-mac", "v1"], in: w.copy("app"))
        try w.manifest(["app"])

        let report = try w.run()
        #expect(report.isFinished)
        #expect(report.helperVersion == BundledHelper.identity.version)
        let repo = try w.result("app", report)
        #expect(repo.action == "new")
        #expect(repo.branches == 2)
        #expect(repo.tags == 1)
        let mirror = w.mirror("app")
        #expect(try w.refs("refs/heads", in: mirror) == ["refs/heads/main", "refs/heads/not-on-any-mac"])
        #expect(try w.sha("refs/heads/not-on-any-mac", in: mirror) == w.sha("HEAD", in: w.copy("app")))
        #expect(try w.git.run(["symbolic-ref", "HEAD"], in: mirror).trimmingCharacters(in: .whitespacesAndNewlines) == "refs/heads/main")
        #expect(w.lfsCalls == 1)
    }

    @Test func aSecondRunWithNoChangesDoesNothing() throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        try w.manifest(["app"])
        _ = try w.run()
        let repo = try w.result("app", try w.run())
        #expect(repo.action == "unchanged")
        #expect(w.lfsCalls == 1, "LFS isn't checked again when nothing moved")
    }

    @Test func picksUpNewCommits() throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        try w.manifest(["app"])
        _ = try w.run()
        try w.commit("app", "second")
        try w.git.run(["push", "--quiet", "origin", "main"], in: w.copy("app"))

        #expect(try w.result("app", try w.run()).action == "changed")
        #expect(try w.sha("refs/heads/main", in: w.mirror("app")) == w.sha("HEAD", in: w.copy("app")))
        #expect(try w.refs("refs/deleted", in: w.mirror("app")).isEmpty, "a normal push keeps nothing extra")
    }

    @Test func keepsForcePushedAndDeletedBranches() throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        let copy = w.copy("app")
        try w.git.run(["checkout", "--quiet", "-b", "gone"], in: copy)
        try w.git.run(["push", "--quiet", "origin", "gone"], in: copy)
        try w.git.run(["checkout", "--quiet", "main"], in: copy)
        try w.commit("app", "to be rewritten")
        try w.git.run(["push", "--quiet", "origin", "main"], in: copy)
        let oldMain = try w.sha("HEAD", in: copy)
        let goneTip = try w.sha("refs/heads/gone", in: copy)
        try w.manifest(["app"])
        _ = try w.run()

        try w.git.run(["reset", "--quiet", "--hard", "HEAD~1"], in: copy)
        try w.commit("app", "rewritten")
        try w.git.run(["push", "--quiet", "--force", "origin", "main", ":gone"], in: copy)

        let repo = try w.result("app", try w.run())
        #expect(repo.action == "changed")
        #expect(repo.keptRefs?.count == 2)
        let mirror = w.mirror("app")
        let kept = try w.refs("refs/deleted", in: mirror)
        let keptMain = try #require(kept.first { $0.hasSuffix("/heads/main") })
        let keptGone = try #require(kept.first { $0.hasSuffix("/heads/gone") })
        #expect(try w.sha(keptMain, in: mirror) == oldMain)
        #expect(try w.sha(keptGone, in: mirror) == goneTip)
        #expect(try w.refs("refs/heads", in: mirror) == ["refs/heads/main"])
        #expect(try w.sha("refs/heads/main", in: mirror) == w.sha("HEAD", in: copy))
    }

    @Test func aMovedTagKeepsItsOldTarget() throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        let copy = w.copy("app")
        try w.git.run(["tag", "v1"], in: copy)
        let oldTag = try w.sha("refs/tags/v1", in: copy)
        try w.git.run(["push", "--quiet", "origin", "v1"], in: copy)
        try w.manifest(["app"])
        _ = try w.run()

        try w.commit("app", "next")
        try w.git.run(["tag", "-f", "v1"], in: copy)
        try w.git.run(["push", "--quiet", "--force", "origin", "main", "v1"], in: copy)
        _ = try w.run()

        let kept = try w.refs("refs/deleted", in: w.mirror("app"))
        #expect(kept.count == 1)
        #expect(kept.first?.hasSuffix("/tags/v1") == true)
        #expect(try w.sha(kept[0], in: w.mirror("app")) == oldTag)
    }

    @Test func pruneModeRemovesDeletedBranches() throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        let copy = w.copy("app")
        try w.git.run(["push", "--quiet", "origin", "main:gone"], in: copy)
        try w.manifest(["app"], onRemoteDelete: "prune")
        _ = try w.run()
        try w.git.run(["push", "--quiet", "origin", ":gone"], in: copy)
        _ = try w.run()
        #expect(try w.refs("refs/heads", in: w.mirror("app")) == ["refs/heads/main"])
        #expect(try w.refs("refs/deleted", in: w.mirror("app")).isEmpty)
    }

    @Test func brokenSourceChangesNothingAndOtherReposCarryOn() throws {
        let w = try HelperWorld()
        try w.makeRepo("broken")
        try w.makeRepo("fine")
        try w.manifest(["broken", "fine"])
        _ = try w.run()
        let before = try w.sha("refs/heads/main", in: w.mirror("broken"))
        try FileManager.default.removeItem(at: w.github.appending(path: "broken.git"))

        let report = try w.run()
        let broken = try w.result("broken", report)
        #expect(broken.action == "failed")
        #expect(broken.detail?.isEmpty == false)
        #expect(try w.result("fine", report).action == "unchanged")
        #expect(try w.sha("refs/heads/main", in: w.mirror("broken")) == before)
        #expect(try w.refs("refs/deleted", in: w.mirror("broken")).isEmpty, "a failure must never look like deleted branches")
    }

    @Test func noBranchesReportedDoesntEmptyTheMirror() throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        try w.manifest(["app"])
        _ = try w.run()
        let bare = w.github.appending(path: "app.git")
        try FileManager.default.removeItem(at: bare)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try w.git.run(["init", "--bare", "--quiet"], in: bare)

        let repo = try w.result("app", try w.run())
        #expect(repo.action == "failed")
        #expect(repo.detail?.contains("no branches") == true)
        #expect(try w.refs("refs/heads", in: w.mirror("app")) == ["refs/heads/main"])
    }

    @Test func skipsAnEmptyRepo() throws {
        let w = try HelperWorld()
        let bare = w.github.appending(path: "empty.git")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try w.git.run(["init", "--bare", "--quiet"], in: bare)
        try w.manifest(["empty"])
        #expect(try w.result("empty", try w.run()).action == "skipped")
    }

    @Test func leavesWorkFromTheMacAlone() throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        try w.manifest(["app"])
        _ = try w.run()
        let mirror = w.mirror("app")
        let tip = try w.sha("refs/heads/main", in: mirror)
        try w.git.run(["update-ref", "refs/heads/from-mac/idea", tip], in: mirror)
        try w.git.run(["update-ref", "refs/tags/from-mac/v9", tip], in: mirror)

        #expect(try w.result("app", try w.run()).action == "unchanged")
        try w.commit("app", "more")
        try w.git.run(["push", "--quiet", "origin", "main"], in: w.copy("app"))
        #expect(try w.result("app", try w.run()).action == "changed")

        #expect(try w.sha("refs/heads/from-mac/idea", in: mirror) == tip)
        #expect(try w.sha("refs/tags/from-mac/v9", in: mirror) == tip)
        #expect(try w.refs("refs/deleted", in: mirror).isEmpty)
    }

    @Test func retriesLFSUntilItWorks() throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        try w.setFakeLFS(failing: true)
        try w.manifest(["app"])

        let first = try w.result("app", try w.run())
        #expect(first.action == "warning")
        #expect(first.detail?.contains("quota exceeded") == true)
        #expect(try w.refs("refs/heads", in: w.mirror("app")) == ["refs/heads/main"], "the branches are still backed up")

        #expect(try w.result("app", try w.run()).action == "warning")
        #expect(w.lfsCalls == 2)

        try w.setFakeLFS(failing: false)
        #expect(try w.result("app", try w.run()).action == "unchanged")
        #expect(w.lfsCalls == 3)
        _ = try w.run()
        #expect(w.lfsCalls == 3, "no more retries once it has worked")
    }

    @Test func startRunCarriesOnInTheBackground() async throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        try w.manifest(["app"])
        try w.helper.startRun()
        let deadline = Date().addingTimeInterval(20)
        var report: HelperRunReport?
        while report?.isFinished != true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
            report = try w.helper.lastRun()
        }
        #expect(report?.isFinished == true)
        #expect(report?.repos.first?.branches == 1)
    }

    @Test func twoRunsDontOverlap() throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        try w.manifest(["app"])
        let lock = w.nas.absolute(".nas-sync/run.lock")
        let fd = open(lock, O_CREAT | O_RDWR, 0o644)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let r = try Command.run(URL(filePath: "/usr/bin/python3"), [w.helper.currentScript, "run"], timeout: 60)
        #expect(r.status == 0)
        #expect(r.stdout.contains("already running"))
        #expect(try w.helper.lastRun() == nil, "the blocked run writes no report")
    }

    @Test func manifestListsGitHubReposAndKeepsKnownPaths() throws {
        let w = try HelperWorld()
        let store = try Store(directory: w.root.appending(path: "state"))
        var known = RepoRecord(fullName: "acme/old", source: .remoteOnly, localPath: nil, firstSeen: Date(), hasGitHubRemote: true)
        known.mirrorPath = "acme/renamed.git"
        try store.saveRepo(known)
        let config = GitHubConfig(every: Interval(seconds: 86400), around: nil, staleAfter: Interval(seconds: 172800), dest: "gh",
                                  scan: [], newRepos: .prompt, exclude: ["acme/skip"], remoteOnly: ["acme/old", "acme/app", "acme/skip"],
                                  groups: ["*": "other", "acme": "acme"], gc: false, line: 0)

        let all = HelperManifest.build(config: config, nas: w.nas, store: store)
        #expect(all.mirrors == w.nas.absolute("gh/mirrors-v2"))
        #expect(all.onRemoteDelete == "keep")
        #expect(all.repos.map(\.name) == ["acme/old", "acme/app"])
        #expect(all.repos[0].path == "acme/renamed.git")
        #expect(all.repos[1].url == "https://github.com/acme/app.git")
        #expect(all.repos[1].path == "acme/app.git")

        let one = HelperManifest.build(config: config, nas: w.nas, store: store, only: ["ACME/app"])
        #expect(one.repos.map(\.name) == ["acme/app"])
    }
}
