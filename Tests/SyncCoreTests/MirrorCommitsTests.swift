import Foundation
import Testing
@testable import SyncCore

@Suite struct MirrorCommitsTests {
    private func sh(_ script: String, in dir: URL) throws {
        let r = try Command.run(URL(filePath: "/bin/sh"), ["-c", "cd \(NAS.quote(dir.path(percentEncoded: false))) && \(script)"], timeout: 30)
        #expect(r.status == 0, "\(r.stderr)")
    }

    /// A bare mirror at `mirrors/a.git`, with commits one day apart.
    private func makeMirror(commits: Int) throws -> (nas: NAS, root: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "mirror-\(UUID().uuidString)")
        let work = root.appending(path: "work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try sh("git init -q -b main && git config user.name 'Ada L' && git config user.email a@example.com", in: work)
        for i in 1...commits {
            try sh("GIT_AUTHOR_DATE='2026-01-\(10 + i)T12:00:00Z' GIT_COMMITTER_DATE='2026-01-\(10 + i)T12:00:00Z' git commit -q --allow-empty -m 'change \(i)'", in: work)
        }
        try FileManager.default.createDirectory(at: root.appending(path: "nas/mirrors"), withIntermediateDirectories: true)
        try sh("git clone -q --mirror work nas/mirrors/a.git", in: root)
        return (NAS(config: NASConfig(ssh: nil, path: root.appending(path: "nas").path(percentEncoded: false))), root)
    }

    @Test func listsTheNewestCommitsWithTheirDetails() throws {
        let (nas, root) = try makeMirror(commits: 7)
        defer { try? FileManager.default.removeItem(at: root) }
        try sh("git tag v1 HEAD~1", in: root.appending(path: "nas/mirrors/a.git"))

        let commits = try nas.recentCommits(inMirror: "mirrors/a.git")
        #expect(commits.map(\.subject) == ["change 7", "change 6", "change 5", "change 4", "change 3"])
        #expect(commits[0].author == "Ada L")
        #expect(commits[0].sha.count == 40)
        #expect(commits[0].sha.hasPrefix(commits[0].shortSHA))
        #expect(commits[0].date == ISO8601DateFormatter().date(from: "2026-01-17T12:00:00Z"))
        #expect(commits[0].refs == ["main"])
        #expect(commits[1].refs == ["v1"])
        #expect(commits[2].refs.isEmpty)
    }

    @Test func coversOtherBranchesAndWhatTheMacSentButNotStashes() throws {
        let (nas, root) = try makeMirror(commits: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appending(path: "work")
        try sh("git checkout -q -b idea && GIT_COMMITTER_DATE='2026-02-01T12:00:00Z' git commit -q --allow-empty -m 'idea' && git push -q ../nas/mirrors/a.git idea", in: work)
        try sh("git checkout -q main && GIT_COMMITTER_DATE='2026-02-02T12:00:00Z' git commit -q --allow-empty -m 'only on the Mac' && git push -q ../nas/mirrors/a.git main:refs/mac/heads/main", in: work)
        try sh("GIT_COMMITTER_DATE='2026-02-03T12:00:00Z' git commit -q --allow-empty -m 'stashed' && git push -q ../nas/mirrors/a.git HEAD:refs/mac/stash", in: work)
        try sh("git update-ref refs/deleted/old refs/mac/stash", in: root.appending(path: "nas/mirrors/a.git"))

        let subjects = try nas.recentCommits(inMirror: "mirrors/a.git").map(\.subject)
        #expect(subjects == ["only on the Mac", "idea", "change 2", "change 1"])
    }

    @Test func aMissingMirrorIsNotTheSameAsAnEmptyOne() throws {
        let (nas, root) = try makeMirror(commits: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: MirrorReadError.noMirror) { try nas.recentCommits(inMirror: "mirrors/nope.git") }
        try sh("git init -q --bare nas/mirrors/empty.git", in: root)
        #expect(try nas.recentCommits(inMirror: "mirrors/empty.git").isEmpty)
    }

    @Test func subjectsKeepTheirPunctuation() {
        let line = ["abc123", "abc", "1700000000", "Ada, L", "HEAD -> main, tag: v1, idea", "fix: a, b | c"].joined(separator: MirrorCommit.separator) + MirrorCommit.terminator + "\n"
        let commits = MirrorCommit.parse(line)
        #expect(commits.count == 1)
        #expect(commits[0].subject == "fix: a, b | c")
        #expect(commits[0].author == "Ada, L")
        #expect(commits[0].refs == ["main", "v1", "idea"])
    }
}
