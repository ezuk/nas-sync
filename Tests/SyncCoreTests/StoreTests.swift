import Foundation
import Testing
@testable import SyncCore

@Suite struct StoreTests {
    func makeStore() throws -> (Store, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "nassync-store-\(UUID().uuidString)")
        return (try Store(directory: dir), dir)
    }

    @Test func savesAndLoadsRuns() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var counts = RunCounts()
        counts.new = 2
        counts.bytes = 100
        var run = RunRecord(kind: .folder, job: "Docs", trigger: "changes", started: Date(timeIntervalSince1970: 1000),
                            counts: counts, summary: "2 copied", items: [RunItem(action: .new, path: "a.txt", size: 50)])
        let id = try store.saveRun(run)
        run.id = id
        run.finished = Date(timeIntervalSince1970: 1010)
        run.outcome = .warning
        try store.saveRun(run)

        let loaded = try #require(try store.run(id: id))
        #expect(loaded == run)
        let list = try store.recentRuns()
        #expect(list.count == 1)
        #expect(list[0].items.isEmpty)
        #expect(list[0].counts.new == 2)
        #expect(try store.recentRuns(kinds: [.github]).isEmpty)
    }

    @Test func prunesHistory() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.saveRun(RunRecord(kind: .folder, job: "A", trigger: "x", started: Date(timeIntervalSince1970: 0)))
        try store.saveRun(RunRecord(kind: .folder, job: "B", trigger: "x", started: Date()))
        try store.pruneHistory(olderThan: 90)
        #expect(try store.recentRuns().map(\.job) == ["B"])
    }

    @Test func keyValuesAndRepos() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(timeIntervalSince1970: 1234)
        store.setDate(now, for: StoreKey.lastSuccess("A"))
        #expect(store.date(StoreKey.lastSuccess("A")) == now)
        store.setInt(5, for: "n")
        #expect(store.int("n") == 5)
        store.setValue(nil, for: "n")
        #expect(store.int("n") == nil)

        var repo = RepoRecord(fullName: "o/r", source: .localClone, localPath: "/x", firstSeen: now)
        repo.refs = ["refs/heads/main": "abc"]
        try store.saveRepo(repo)
        repo.sizeOnNAS = 2048
        repo.mirrorPath = "o/r.git"
        repo.deletedRefsKept = ["refs/deleted/2026-11-01/heads/x"]
        try store.saveRepo(repo)
        #expect(store.repos() == [repo])
        try store.deleteRepo("o/r")
        #expect(store.repos().isEmpty)
    }

    @Test func decodesRecordsFromArchiveVersion() throws {
        // A record saved by the version that kept dated .bundle.xz archives.
        let old = """
        {"fullName":"o/r","source":"localClone","localPath":"/x","refs":{"refs/heads/main":"abc"},"fingerprint":"f",
         "lastChangeSeen":1000,"newestArchive":900,"newestArchiveName":"260101-o-r.bundle.xz","newestArchiveSize":12,
         "archiveCount":3,"archiveDates":[900,800],"status":"ok","firstSeen":500,"usesLFS":false}
        """
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        let r = try d.decode(RepoRecord.self, from: Data(old.utf8))
        #expect(r.fullName == "o/r")
        #expect(r.refs == ["refs/heads/main": "abc"])
        #expect(r.fingerprint == "f")
        #expect(r.hasGitHubRemote)
        #expect(r.mirrorPath == nil && r.sizeOnNAS == nil && r.mirrorUpdated == nil)
        #expect(r.deletedRefsKept.isEmpty)

        let counts = try JSONDecoder().decode(RunCounts.self, from: Data(#"{"new":1,"changed":2,"archived":0,"skipped":0,"failed":0,"unchanged":3,"pruned":4,"bytes":5,"total":6}"#.utf8))
        #expect(counts.pruned == 4 && counts.keptRefs == 0 && counts.total == 6)
    }
}
