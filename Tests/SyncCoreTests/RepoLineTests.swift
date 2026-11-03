import Foundation
import Testing
@testable import SyncCore

@Suite struct RepoLineTests {
    private let macTime = Date(timeIntervalSince1970: 1_000_000)
    private let helperTime = Date(timeIntervalSince1970: 1_050_000)

    private func snapshot(repoCount: Int = 5, waiting: Int = 0, helper: HelperRunReport?) -> StatusSnapshot {
        var s = StatusSnapshot.initial(configPath: "config.toml")
        s.github = GitHubSummary(repoCount: repoCount, localClones: 0, remoteOnly: repoCount, problems: 0, excluded: 0, every: 86400, newRepos: [], waitingForMirror: waiting)
        s.jobs = [JobStatus(name: "GitHub repos", kind: .github, state: .idle, lastSuccess: macTime, lastSummary: nil, lastOutcome: .success, message: nil,
                            waitingChanges: 0, fileCount: nil, progress: nil, nextRun: nil, holdUntil: nil, needsDeleteConfirmation: false, staleAfter: 86400)]
        s.helperRun = helper
        return s
    }

    private func helperRun(_ actions: [String], status: String = "finished") -> HelperRunReport {
        HelperRunReport(status: status, finished: status == "finished" ? helperTime : nil, total: actions.count,
                        repos: actions.enumerated().map { .init(name: "o/r\($0.offset)", action: $0.element) })
    }

    private func macRun(failed: Int = 0, outcome: RunOutcome = .success) -> RunRecord {
        var run = RunRecord(kind: .github, job: "GitHub repos", trigger: "manual", started: macTime, finished: macTime, outcome: outcome, summary: "5 handled by the NAS helper")
        run.counts.failed = failed
        return run
    }

    @Test func helperRunGivesTheStateOfTheRepos() {
        let s = snapshot(helper: helperRun(["changed", "unchanged", "unchanged", "skipped", "failed"]))
        #expect(StatusText.repoLine(s, lastRun: macRun(), nextRun: nil) == "3 up to date · 1 failed · 1 skipped")
    }

    @Test func allGoodRunSaysSo() {
        let s = snapshot(helper: helperRun(["unchanged", "unchanged", "unchanged", "unchanged", "new"]))
        #expect(StatusText.repoLine(s, lastRun: nil, nextRun: nil) == "5 up to date")
    }

    @Test func macFailuresAndWaitingReposAreNotCountedAsUpToDate() {
        let s = snapshot(waiting: 1, helper: helperRun(["unchanged", "unchanged", "unchanged", "unchanged"]))
        #expect(StatusText.repoLine(s, lastRun: macRun(failed: 1), nextRun: nil) == "3 up to date · 1 failed · 1 waiting for a first backup")
    }

    @Test func helperRunInProgressSaysSo() {
        let s = snapshot(helper: helperRun(["unchanged"], status: "running"))
        #expect(StatusText.repoLine(s, lastRun: macRun(), nextRun: nil) == "The NAS is checking GitHub")
    }

    @Test func withoutTheHelperTheLastRunIsCounted() {
        var run = macRun()
        run.counts.changed = 2
        run.counts.unchanged = 3
        #expect(StatusText.repoLine(snapshot(helper: nil), lastRun: run, nextRun: nil) == "2 backed up · 3 unchanged")
        #expect(StatusText.repoLine(snapshot(helper: nil), lastRun: nil, nextRun: nil) == nil)
    }

    @Test func failedRunFallsBackToTheJobLine() {
        let s = snapshot(helper: helperRun(["unchanged"]))
        #expect(StatusText.repoLine(s, lastRun: macRun(outcome: .failed), nextRun: nil) == nil)
    }

    @Test func lastBackupIsTheNewerOfMacAndHelper() {
        #expect(snapshot(helper: helperRun(["unchanged"])).reposLastBackedUp == helperTime)
        #expect(snapshot(helper: nil).reposLastBackedUp == macTime)
        #expect(snapshot(helper: helperRun(["unchanged"], status: "running")).reposLastBackedUp == macTime)
        #expect(snapshot(helper: helperRun(["failed", "failed"])).reposLastBackedUp == macTime)
    }
}
