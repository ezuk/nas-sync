import Foundation
import Testing
@testable import SyncCore

@Suite struct DiagnosisTests {
    private func repo(_ status: RepoStatus, _ message: String?, source: RepoSource = .localClone) -> RepoProblem {
        RepoProblem(fullName: "acme/app", source: source, localPath: "/code/app/", status: status, message: message, hasGitHubRemote: true)
    }

    @Test func explainsRunningOutOfFiles() {
        let d = Diagnosis.explain("The operation couldn’t be completed. Bad file descriptor")
        #expect(d.title == "NAS Sync ran out of open files")
        #expect(d.fixes == [.backUpAgain])
        #expect(d.technical.contains("Bad file descriptor"))
        #expect(Diagnosis.explain("Couldn't start git fetch: Too many open files").title == "NAS Sync ran out of open files")
    }

    @Test func signInIsNotMistakenForAFilePermissionProblem() {
        #expect(Diagnosis.explain("git@github.com: Permission denied (publickey).").title == "GitHub refused the SSH sign-in")
        #expect(Diagnosis.explain("open \"/x\": Permission denied (13)").title == "macOS or the NAS blocked access")
    }

    @Test func recognizesCommonErrors() {
        #expect(Diagnosis.explain("ssh: Could not resolve host: github.com").title == "Couldn't reach GitHub")
        #expect(Diagnosis.explain("write failed: No space left on device (28)").title == "The NAS is full")
        #expect(Diagnosis.explain("git fetch timed out").title == "The connection dropped")
        #expect(Diagnosis.explain("fatal: not a git repository (or any of the parent directories): .git").title == "This folder isn't a working git repo")
        #expect(Diagnosis.explain("The mirror didn't pass git's check, so the NAS copy wasn't changed (x).").title == "The mirror failed git's integrity check")
    }

    @Test func unknownErrorsKeepTheOriginalText() {
        let d = Diagnosis.explain("frobnicator overheated")
        #expect(d.isUnrecognized)
        #expect(d.technical == "frobnicator overheated")
    }

    @Test func dubiousOwnershipOffersTheCommand() {
        let d = Diagnosis.explain("fatal: detected dubious ownership in repository at '/code/it's'", localPath: "/code/it's")
        #expect(d.fixes.contains(.copyCommand("git config --global --add safe.directory '/code/it'\\''s'")))
    }

    @Test func fileNameConversionNamesTheFile() {
        let d = Diagnosis.explain("[sender] cannot convert filename: docs/📊 tracker.json (Illegal byte sequence)")
        #expect(d.fixes == [.revealFile("docs/📊 tracker.json")])
    }

    @Test func repoStatesOfferTheRightFixes() {
        #expect(Diagnosis.forRepo(repo(.missingLocally, "gone")).fixes.contains(.forgetRepo))
        #expect(Diagnosis.forRepo(repo(.goneFromGitHub, "gone", source: .remoteOnly)).fixes.contains(.stopBackingUp))
        #expect(!Diagnosis.forRepo(repo(.goneFromGitHub, "gone")).fixes.contains(.stopBackingUp))
        #expect(Diagnosis.forRepo(repo(.ok, nil)).title == "Not on the NAS yet")
        #expect(Diagnosis.forRepo(repo(.failed, "frobnicator overheated")).fixes.contains(.revealClone))
    }

    @Test func runWithFailedReposExplainsEachOne() {
        var c = RunCounts()
        c.failed = 2
        let run = RunRecord(kind: .github, job: "GitHub repos", trigger: "t", started: Date(), outcome: .warning, counts: c,
                            items: [RunItem(action: .failed, path: "a/x", detail: "Bad file descriptor"),
                                    RunItem(action: .changed, path: "a/y"),
                                    RunItem(action: .failed, path: "a/z", detail: "git fetch timed out")])
        let problems = Diagnosis.forRun(run)
        #expect(problems.map(\.subject) == ["a/x", "a/z"])
        #expect(problems[1].diagnosis.title == "The connection dropped")
    }

    @Test func folderRunCountsFilesAndPrefersLastingProblems() throws {
        var c = RunCounts()
        c.failed = 4
        let message = "Changed while copying, will retry: a\n[sender] cannot convert filename: b (Illegal byte sequence)\n[sender] cannot convert filename: c (Illegal byte sequence)"
        let run = RunRecord(kind: .folder, job: "Tresorit", trigger: "t", started: Date(), outcome: .warning, counts: c, message: message)
        let d = try #require(Diagnosis.forFolderRun(run))
        #expect(d.title == "4 files can't be backed up because of their names")
        #expect(!d.isTransient)
        #expect(d.fixes == [.revealFile("b")])
        #expect(d.technical.contains("and 1 more"))
        #expect(d.advice.hasPrefix("Rename them"))
    }

    @Test func folderRunWithOnlyChangedFilesIsTransient() throws {
        var c = RunCounts()
        c.failed = 1
        let run = RunRecord(kind: .folder, job: "Tresorit", trigger: "t", started: Date(), outcome: .warning, counts: c, message: "Changed while copying, will retry: a")
        #expect(try #require(Diagnosis.forFolderRun(run)).isTransient)
    }

    @Test func olderFolderRunsWithoutFileNamesOfferASync() throws {
        var c = RunCounts()
        c.failed = 1
        let run = RunRecord(kind: .folder, job: "Tresorit", trigger: "t", started: Date(), outcome: .warning, counts: c, message: "rsync couldn't copy some files (exit 23).")
        let d = try #require(Diagnosis.forFolderRun(run))
        #expect(d.title == "Some files couldn't be copied")
        #expect(d.fixes == [.syncAgain])
    }

    @Test func successfulRunsHaveNoProblems() {
        #expect(Diagnosis.forRun(RunRecord(kind: .github, job: "x", trigger: "t", started: Date())).isEmpty)
    }

    @Test func repoRecordProblems() {
        var r = RepoRecord(fullName: "a/b", source: .localClone, localPath: nil, firstSeen: Date())
        #expect(r.problem == nil)
        r.refs = ["refs/heads/main": "abc"]
        #expect(r.isWaitingForMirror)
        #expect(r.problem != nil)
        r.mirrorUpdated = Date()
        #expect(r.problem == nil)
        r.status = .failed
        #expect(r.problem?.status == .failed)
        #expect(!r.isWaitingForMirror)
    }
}
