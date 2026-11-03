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
        try w.git.run(["checkout", "--quiet", "-b", "idea"], in: w.copy("app"))
        try w.commit("app", "not on GitHub")
        let tip = try w.sha("HEAD", in: w.copy("app"))
        try w.git.run(["push", "--quiet", mirror.path(percentEncoded: false), "idea:refs/heads/from-mac/idea", "idea:refs/tags/from-mac/v9"], in: w.copy("app"))
        try w.git.run(["checkout", "--quiet", "main"], in: w.copy("app"))

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
        var config = GitHubConfig(every: Interval(seconds: 86400), around: nil, staleAfter: Interval(seconds: 172800), dest: "gh",
                                  scan: [], newRepos: .prompt, exclude: ["acme/skip"], remoteOnly: ["acme/old", "acme/app", "acme/skip"],
                                  groups: ["*": "other", "acme": "acme"], line: 0)
        #expect(HelperManifest.build(config: config, nas: w.nas, store: store).repos.isEmpty, "no repo uses the helper until helper_repos says so")
        config.helperRepos = ["acme/old"]
        #expect(HelperManifest.build(config: config, nas: w.nas, store: store).repos.map(\.name) == ["acme/old"])
        config.helperRepos = ["*/*"]

        let all = HelperManifest.build(config: config, nas: w.nas, store: store)
        #expect(all.mirrors == w.nas.absolute("gh/mirrors-v2"))
        #expect(all.onRemoteDelete == "keep")
        #expect(all.repos.map(\.name) == ["acme/old", "acme/app"])
        #expect(all.repos[0].path == "acme/renamed.git")
        #expect(all.repos[1].url == "https://github.com/acme/app.git")
        #expect(all.repos[1].path == "acme/app.git")
        #expect(all.repos[1].source == "remote")
        #expect(all.repos[1].legacy == w.nas.absolute("gh/mirrors/acme/app.git"))

        let one = HelperManifest.build(config: config, nas: w.nas, store: store, only: ["ACME/app"])
        #expect(one.repos.map(\.name) == ["acme/app"])
    }

    // MARK: Old mirrors and work from a Mac

    /// A copy of the repo's GitHub state with extra local work, standing in for the app's old mirror.
    private func makeLegacy(_ w: HelperWorld, _ name: String) throws -> URL {
        let legacy = w.root.appending(path: "nas/old/\(name).git")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try w.git.run(["init", "--bare", "--quiet", "-b", "main"], in: legacy)
        try w.git.run(["push", "--quiet", legacy.path(percentEncoded: false), "main"], in: w.copy(name))
        return legacy
    }

    private func manifest(_ w: HelperWorld, _ name: String, legacy: URL?, source: String) throws {
        let repo = HelperManifest.Repo(name: "owner/\(name)", url: w.github.appending(path: "\(name).git").path(percentEncoded: false), path: "\(name).git",
                                       legacy: legacy?.path(percentEncoded: false), source: source)
        try w.helper.save(HelperManifest(mirrors: w.mirrors.path(percentEncoded: false), onRemoteDelete: "keep", repos: [repo]))
    }

    /// Pushes a branch from the working copy into `refs/mac/` the way the app does.
    private func macPush(_ w: HelperWorld, _ name: String) throws {
        try w.git.run(["push", "--quiet", "--prune", w.mirror(name).path(percentEncoded: false),
                       "+refs/heads/*:refs/mac/heads/*", "+refs/tags/*:refs/mac/tags/*"], in: w.copy(name))
    }

    @Test func adoptsTheOldMirrorOfAClone() throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        let legacy = try makeLegacy(w, "app")
        try w.git.run(["checkout", "--quiet", "-b", "local-only"], in: w.copy("app"))
        try w.commit("app", "only on the Mac")
        let local = try w.sha("HEAD", in: w.copy("app"))
        try w.git.run(["push", "--quiet", legacy.path(percentEncoded: false), "local-only", "HEAD:refs/deleted/2020-01-01/heads/old"], in: w.copy("app"))
        try manifest(w, "app", legacy: legacy, source: "clone")

        let repo = try w.result("app", w.run())
        #expect(repo.fromMac == 1)
        let mirror = w.mirror("app")
        #expect(try w.refs("refs/heads", in: mirror) == ["refs/heads/from-mac/local-only", "refs/heads/main"], "main is on GitHub, so only the local branch is listed separately")
        #expect(try w.sha("refs/heads/from-mac/local-only", in: mirror) == local)
        #expect(try w.refs("refs/deleted", in: mirror) == ["refs/deleted/2020-01-01/heads/old"])
        #expect(try w.refs("refs/legacy", in: mirror).isEmpty)
    }

    @Test func oldMirrorBranchesOfARemoteRepoCountAsDeletedAtTheSource() throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        let legacy = try makeLegacy(w, "app")
        try w.git.run(["checkout", "--quiet", "-b", "gone"], in: w.copy("app"))
        try w.commit("app", "deleted on GitHub since")
        try w.git.run(["push", "--quiet", legacy.path(percentEncoded: false), "gone"], in: w.copy("app"))
        try manifest(w, "app", legacy: legacy, source: "remote")

        _ = try w.run()
        let mirror = w.mirror("app")
        #expect(try w.refs("refs/heads", in: mirror) == ["refs/heads/main"])
        #expect(try w.refs("refs/deleted", in: mirror).count == 1)
    }

    @Test func oldMirrorStaysVisibleWhenGitHubCantBeRead() throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        let legacy = try makeLegacy(w, "app")
        try FileManager.default.removeItem(at: w.github.appending(path: "app.git"))
        try manifest(w, "app", legacy: legacy, source: "remote")

        let repo = try w.result("app", w.run())
        #expect(repo.action == "failed")
        #expect(try w.refs("refs/heads", in: w.mirror("app")) == ["refs/heads/from-mac/main"])
    }

    @Test func sortsWhatAMacSends() throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        try manifest(w, "app", legacy: nil, source: "clone")
        _ = try w.run()
        let mirror = w.mirror("app")

        // A branch GitHub lacks shows up, and main, which GitHub has, doesn't.
        try w.git.run(["checkout", "--quiet", "-b", "wip"], in: w.copy("app"))
        try w.commit("app", "one")
        try macPush(w, "app")
        #expect(try w.result("app", w.run()).fromMac == 1)
        #expect(try w.refs("refs/heads", in: mirror) == ["refs/heads/from-mac/wip", "refs/heads/main"])
        let first = try w.sha("HEAD", in: w.copy("app"))
        #expect(try w.sha("refs/heads/from-mac/wip", in: mirror) == first)

        // A rewrite moves the branch and keeps the old commit.
        try w.git.run(["-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "--quiet", "--amend", "--allow-empty", "-m", "two"], in: w.copy("app"))
        try macPush(w, "app")
        _ = try w.run()
        #expect(try w.sha("refs/heads/from-mac/wip", in: mirror) == w.sha("HEAD", in: w.copy("app")))
        let kept = try w.refs("refs/deleted", in: mirror)
        #expect(kept.count == 1)
        #expect(try w.sha(kept[0], in: mirror) == first)

        // Once GitHub has it, the separate copy goes, with nothing more kept.
        try w.git.run(["push", "--quiet", "origin", "wip"], in: w.copy("app"))
        _ = try w.run()
        #expect(try w.refs("refs/heads", in: mirror) == ["refs/heads/main", "refs/heads/wip"])
        #expect(try w.refs("refs/deleted", in: mirror).count == 1)
    }

    @Test func aBranchDeletedOnTheMacIsKept() throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        try manifest(w, "app", legacy: nil, source: "clone")
        _ = try w.run()
        try w.git.run(["checkout", "--quiet", "-b", "wip"], in: w.copy("app"))
        try w.commit("app", "one")
        let tip = try w.sha("HEAD", in: w.copy("app"))
        try macPush(w, "app")
        _ = try w.run()

        try w.git.run(["checkout", "--quiet", "main"], in: w.copy("app"))
        try w.git.run(["branch", "--quiet", "-D", "wip"], in: w.copy("app"))
        try macPush(w, "app")
        let repo = try w.result("app", w.run())
        let mirror = w.mirror("app")
        #expect(repo.fromMac == 0)
        #expect(try w.refs("refs/heads", in: mirror) == ["refs/heads/main"])
        let kept = try w.refs("refs/deleted", in: mirror)
        #expect(kept.count == 1)
        #expect(try w.sha(kept[0], in: mirror) == tip)
    }

    @Test func aQuietRunDoesNoSorting() throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        try manifest(w, "app", legacy: nil, source: "clone")
        _ = try w.run()
        try w.git.run(["checkout", "--quiet", "-b", "wip"], in: w.copy("app"))
        try w.commit("app", "one")
        try macPush(w, "app")
        #expect(try w.result("app", w.run()).action == "changed")
        let repo = try w.result("app", w.run())
        #expect(repo.action == "unchanged")
        #expect(repo.fromMac == 1)
    }

    @Test func lfsOnlyLooksAtGitHubRefs() throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        try manifest(w, "app", legacy: nil, source: "clone")
        _ = try w.run()
        try w.git.run(["checkout", "--quiet", "-b", "wip"], in: w.copy("app"))
        try w.commit("app", "never pushed to GitHub")
        try macPush(w, "app")
        try w.git.run(["checkout", "--quiet", "main"], in: w.copy("app"))
        try w.commit("app", "on GitHub")
        try w.git.run(["push", "--quiet", "origin", "main"], in: w.copy("app"))
        _ = try w.run()
        let log = try String(contentsOf: w.lfsLog, encoding: .utf8)
        #expect(log.contains("refs/heads/main"))
        #expect(!log.contains("wip"))
    }

    // MARK: The whole path

    /// Runs the Mac's backup, then the helper with GitHub replaced by the local bare repos.
    private func macThenHelper(_ w: HelperWorld, _ backup: GitHubBackup) throws -> GitHubBackup.Result {
        let result = backup.run(trigger: "test")
        let manifestFile = w.nas.absolute("\(NASHelper.stateFolder)/manifest.json")
        var manifest = try JSONDecoder().decode(HelperManifest.self, from: Data(contentsOf: URL(filePath: manifestFile)))
        manifest.repos = manifest.repos.map {
            var repo = $0
            repo.url = w.github.appending(path: "\($0.name.split(separator: "/")[1]).git").path(percentEncoded: false)
            return repo
        }
        try w.helper.save(manifest)
        _ = try w.run()
        return result
    }

    @Test func aCloneSendsItsWorkWithoutBeingChanged() throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        let clone = w.copy("app")
        try w.git.run(["remote", "set-url", "--push", "origin", "https://github.com/owner/app.git"], in: clone)
        try w.git.run(["config", "remote.origin.url", "https://github.com/owner/app.git"], in: clone)
        try w.git.run(["checkout", "--quiet", "-b", "wip"], in: clone)
        try w.commit("app", "not pushed")
        let tip = try w.sha("HEAD", in: clone)
        let hook = clone.appending(path: ".git/hooks/pre-push")
        try Data("#!/bin/sh\ntouch '\(w.root.path(percentEncoded: false))/hook-ran'\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path(percentEncoded: false))

        let store = try Store(directory: w.root.appending(path: "state"))
        var config = GitHubConfig(every: Interval(seconds: 86400), around: nil, staleAfter: Interval(seconds: 172800), dest: "gh",
                                  scan: [w.work], newRepos: .include, exclude: [], remoteOnly: [],
                                  groups: ["*": "other"], line: 0)
        config.helperRepos = ["owner/*"]
        let backup = GitHubBackup(config: config, nas: w.nas, store: store, workDirectory: w.root.appending(path: "cache"))
        backup.checksGitHub = false
        backup.startsHelperRuns = false
        let before = try w.git.run(["for-each-ref"], in: clone) + String(contentsOf: clone.appending(path: ".git/config"), encoding: .utf8)
        let mirror = w.root.appending(path: "nas/gh/mirrors-v2/other/app.git")

        // First run: nothing is sent until the helper has made the mirror.
        let first = try macThenHelper(w, backup)
        #expect(first.repos.map(\.action) == [.onNAS])
        #expect(first.record.summary == "1 handled by the NAS helper")
        #expect(first.record.counts.unchanged == 1)
        #expect(FileManager.default.fileExists(atPath: mirror.appending(path: "HEAD").path(percentEncoded: false)))
        #expect(try w.refs("refs/mac", in: mirror).isEmpty)
        GitHubBackup.applyHelperRun(try #require(try w.helper.lastRun()), config: config, store: store)
        var record = try #require(store.repos().first)
        #expect(record.usesHelper)
        #expect(record.mirrorUpdated != nil)
        #expect(record.macFingerprint == nil)
        #expect(GitHubBackup.nasMirrorPath(dest: "gh", record: record) == "gh/mirrors-v2/other/app.git")

        // Second run: the clone's work goes across and shows up as a branch.
        let second = try macThenHelper(w, backup)
        #expect(second.repos.map(\.action) == [.backedUp])
        #expect(try w.sha("refs/heads/from-mac/wip", in: mirror) == tip)
        #expect(try w.refs("refs/heads", in: mirror).contains("refs/heads/main"))

        // Nothing new: nothing is sent.
        #expect(backup.run(trigger: "test").repos.map(\.action) == [.onNAS])

        // The clone is exactly as it was, and its hooks didn't run.
        #expect(try w.git.run(["for-each-ref"], in: clone) + String(contentsOf: clone.appending(path: ".git/config"), encoding: .utf8) == before)
        #expect(!FileManager.default.fileExists(atPath: w.root.appending(path: "hook-ran").path(percentEncoded: false)))

        // Removing the setting goes back to the old mirror, which the helper's mirror doesn't affect.
        config.helperRepos = []
        let old = GitHubBackup(config: config, nas: w.nas, store: store, workDirectory: w.root.appending(path: "cache"))
        old.checksGitHub = false
        #expect(old.run(trigger: "test").repos.map(\.action) == [.backedUp])
        record = try #require(store.repos().first)
        #expect(!record.usesHelper)
        #expect(GitHubBackup.nasMirrorPath(dest: "gh", record: record) == "gh/mirrors/other/app.git")
        #expect(try w.sha("refs/heads/wip", in: w.root.appending(path: "nas/gh/mirrors/other/app.git")) == tip)
        #expect(try w.sha("refs/heads/from-mac/wip", in: mirror) == tip)
    }

    @Test func aHelperFailureShowsOnTheRepo() throws {
        let w = try HelperWorld()
        let store = try Store(directory: w.root.appending(path: "state"))
        var record = RepoRecord(fullName: "owner/app", source: .remoteOnly, localPath: nil, firstSeen: Date())
        record.mirrorPath = "other/app.git"
        try store.saveRepo(record)
        var config = GitHubConfig(every: Interval(seconds: 86400), around: nil, staleAfter: Interval(seconds: 172800), dest: "gh",
                                  scan: [], newRepos: .include, exclude: [], remoteOnly: ["owner/app"], groups: ["*": "other"], line: 0)
        func report(action: String, detail: String? = nil, gone: Bool? = nil) -> HelperRunReport {
            let repo = HelperRunReport.Repo(name: "owner/app", action: action, detail: detail, bytes: 2048, gone: gone)
            return HelperRunReport(status: "finished", finished: Date(), repos: [repo])
        }

        GitHubBackup.applyHelperRun(report(action: "failed", detail: "nope"), config: config, store: store)
        #expect(try #require(store.repos().first).usesHelper == false, "a repo not in helper_repos is left alone")

        config.helperRepos = ["*/*"]
        GitHubBackup.applyHelperRun(report(action: "failed", detail: "nope"), config: config, store: store)
        var r = try #require(store.repos().first)
        #expect(r.status == .failed)
        #expect(r.message == "nope")
        #expect(r.sizeOnNAS == 2048)

        GitHubBackup.applyHelperRun(report(action: "failed", detail: "repository not found", gone: true), config: config, store: store)
        r = try #require(store.repos().first)
        #expect(r.status == .goneFromGitHub)

        GitHubBackup.applyHelperRun(report(action: "unchanged"), config: config, store: store)
        r = try #require(store.repos().first)
        #expect(r.status == .ok)
        #expect(r.message == nil)
    }

    @Test func helperReposSettingIsReadAndOldGCSettingIsIgnored() throws {
        let text = """
        [nas]
        path = "/tmp/nas"

        [home]
        wifi = "Home"

        [github]
        helper_repos = ["acme/*", "other/one"]
        gc = true
        """
        let parsed = ConfigLoader.parse(text)
        #expect(parsed.errors.isEmpty, "\(parsed.errors)")
        let github = try #require(parsed.config?.github)
        #expect(github.helperRepos == ["acme/*", "other/one"])
        #expect(github.usesHelper("acme/app"))
        #expect(github.usesHelper("Other/One"))
        #expect(!github.usesHelper("other/two"))
        #expect(!github.usesHelper("no-remote"))
        var all = github
        all.helperRepos = ["*/*"]
        #expect(all.usesHelper("anyone/anything"))
        #expect(!all.usesHelper("no-remote"))
    }

    @Test func aCloneNamedInRemoteOnlyCountsAsListed() throws {
        let w = try HelperWorld()
        try w.makeRepo("app")
        try w.git.run(["config", "remote.origin.url", "https://github.com/owner/app.git"], in: w.copy("app"))
        let config = GitHubConfig(every: Interval(seconds: 86400), around: nil, staleAfter: Interval(seconds: 172800), dest: "gh",
                                  scan: [w.work], newRepos: .prompt, exclude: [], remoteOnly: ["Owner/App"], groups: ["*": "other"], line: 0)
        let targets = RepoDiscovery.targets(config: config).targets
        #expect(targets.count == 1)
        #expect(targets[0].source == .localClone)
        #expect(targets[0].isListed)
    }

    @Test func aRunSummaryForActivity() {
        let repos = [HelperRunReport.Repo(name: "a/b", action: "changed"), HelperRunReport.Repo(name: "a/c", action: "unchanged"),
                     HelperRunReport.Repo(name: "a/d", action: "failed", detail: "no token")]
        let run = HelperRunReport(status: "finished", started: Date(), finished: Date(), total: 3, repos: repos).runRecord()
        #expect(run.kind == .helper)
        #expect(run.summary == "1 updated, 1 unchanged, 1 failed")
        #expect(run.outcome == .warning)
        #expect(run.message == "a/d: no token")
    }

    @Test func reportsWhenScheduledRunsStop() {
        let now = Date()
        func finished(_ age: TimeInterval) -> HelperRunReport {
            HelperRunReport(status: "finished", started: now.addingTimeInterval(-age), finished: now.addingTimeInterval(-age), repos: [])
        }
        #expect(Diagnosis.forHelperRun(nil, now: now) == nil)
        #expect(Diagnosis.forHelperRun(finished(3600), now: now) == nil)
        #expect(Diagnosis.forHelperRun(finished(4 * 3600), now: now)?.title == "The NAS helper hasn't run lately")
        let running = { (age: TimeInterval) in HelperRunReport(status: "running", started: now.addingTimeInterval(-age), repos: []) }
        #expect(Diagnosis.forHelperRun(running(4 * 3600), now: now) == nil, "a first backup can take many hours")
        #expect(Diagnosis.forHelperRun(running(25 * 3600), now: now)?.title == "The NAS helper's run looks stuck")
    }
}
