import Foundation
import Testing
@testable import SyncCore

/// A temporary source and destination pair.
final class TempPair {
    let root: URL
    let source: URL
    let dest: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "nassync-test-\(UUID().uuidString)")
        source = root.appending(path: "src")
        dest = root.appending(path: "dst")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ rel: String, _ text: String, in base: URL? = nil, modified: Date? = nil) throws {
        let url = (base ?? source).appending(path: rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path(percentEncoded: false))
        }
    }

    func read(_ rel: String, in base: URL? = nil) -> String? {
        (try? Data(contentsOf: (base ?? dest).appending(path: rel))).map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ rel: String, in base: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (base ?? dest).appending(path: rel).path(percentEncoded: false))
    }

    func delete(_ rel: String) throws {
        try FileManager.default.removeItem(at: source.appending(path: rel))
    }

    func job(exclude: [String] = [".DS_Store"], maxDeletePercent: Int = 20, maxDeleteFiles: Int = 1000) -> FolderJobConfig {
        FolderJobConfig(
            name: "Test", source: source, dest: "x", exclude: exclude, archiveDays: 30,
            staleAfter: .hours(24), quietPeriod: Interval(seconds: 1),
            maxDeletePercent: maxDeletePercent, maxDeleteFiles: maxDeleteFiles, line: 1
        )
    }

    func sync(_ job: FolderJobConfig? = nil) -> FolderSync {
        FolderSync(job: job ?? self.job(), destinationRoot: dest)
    }
}

@Suite struct FolderSyncTests {
    let day = FolderSync.dayFormatter.string(from: Date())

    @Test func copiesNewFilesAndFolders() throws {
        let t = try TempPair()
        try t.write("a.txt", "A")
        try t.write("sub/b.txt", "B")
        try t.write("sub/deeper/c.txt", "C")
        let sync = t.sync()
        let plan = try sync.plan(scope: .full)
        #expect(plan.copyCount == 3)
        let out = sync.execute(plan)
        #expect(out.fatalError == nil)
        #expect(out.counts.new == 3)
        #expect(t.read("sub/deeper/c.txt") == "C")

        let again = try sync.plan(scope: .full)
        #expect(again.isEmpty)
        #expect(again.sourceFileCount == 3)
    }

    @Test func preservesModificationTime() throws {
        let t = try TempPair()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try t.write("a.txt", "A", modified: date)
        let sync = t.sync()
        _ = sync.execute(try sync.plan(scope: .full))
        let attrs = try FileManager.default.attributesOfItem(atPath: t.dest.appending(path: "a.txt").path(percentEncoded: false))
        #expect((attrs[.modificationDate] as? Date) == date)
    }

    @Test func archivesReplacedAndDeletedFiles() throws {
        let t = try TempPair()
        try t.write("keep.txt", "1")
        try t.write("change.txt", "old")
        try t.write("gone.txt", "bye")
        try t.write("folder/inner.txt", "in")
        let sync = t.sync()
        _ = sync.execute(try sync.plan(scope: .full))

        try t.write("change.txt", "new version", modified: Date().addingTimeInterval(60))
        try t.delete("gone.txt")
        try t.delete("folder")
        let plan = try sync.plan(scope: .full)
        let out = sync.execute(plan)
        #expect(out.counts.changed == 1)
        #expect(out.counts.archived == 3)
        #expect(t.read("change.txt") == "new version")
        #expect(!t.exists("gone.txt"))
        #expect(!t.exists("folder"))
        #expect(t.read("_archive/\(day)/change.txt") == "old")
        #expect(t.read("_archive/\(day)/gone.txt") == "bye")
        #expect(t.read("_archive/\(day)/folder/inner.txt") == "in")

        // A second replacement on the same day gets a numbered name.
        try t.write("change.txt", "newest", modified: Date().addingTimeInterval(120))
        _ = sync.execute(try sync.plan(scope: .full))
        #expect(t.read("_archive/\(day)/change (2).txt") == "new version")
    }

    @Test func respectsExcludesOnBothSides() throws {
        let t = try TempPair()
        try t.write("a.txt", "A")
        try t.write(".DS_Store", "x")
        try t.write("node_modules/lib.js", "x")
        try t.write("only-on-nas.DS_Store", "x", in: t.dest)
        try t.write(".DS_Store", "nas", in: t.dest)
        let sync = t.sync(t.job(exclude: [".DS_Store", "node_modules/"]))
        let plan = try sync.plan(scope: .full)
        let out = sync.execute(plan)
        #expect(out.counts.new == 1)
        #expect(t.read(".DS_Store") == "nas")
        #expect(!t.exists("node_modules"))
    }

    @Test func guardsMissingAndEmptySource() throws {
        let t = try TempPair()
        try t.write("a.txt", "A")
        let sync = t.sync()
        _ = sync.execute(try sync.plan(scope: .full))

        try t.delete("a.txt")
        #expect(throws: FolderSync.GuardError.sourceEmpty(t.source.path(percentEncoded: false))) {
            try sync.plan(scope: .full)
        }
        try FileManager.default.removeItem(at: t.source)
        #expect(throws: FolderSync.GuardError.sourceMissing(t.source.path(percentEncoded: false))) {
            try sync.plan(scope: .full)
        }
        #expect(t.exists("a.txt"))
    }

    @Test func guardsMassDelete() throws {
        let t = try TempPair()
        for i in 0..<40 { try t.write("f\(i).txt", "\(i)") }
        let sync = t.sync(t.job(maxDeletePercent: 20))
        _ = sync.execute(try sync.plan(scope: .full))
        for i in 0..<20 { try t.delete("f\(i).txt") }
        let plan = try sync.plan(scope: .full)
        #expect(throws: FolderSync.GuardError.massDelete(files: 20, percent: 50)) {
            try sync.checkMassDelete(plan, knownDestFileCount: nil)
        }
        // A small number of deletions is fine.
        let t2 = try TempPair()
        for i in 0..<40 { try t2.write("f\(i).txt", "\(i)") }
        let sync2 = t2.sync()
        _ = sync2.execute(try sync2.plan(scope: .full))
        try t2.delete("f1.txt")
        try sync2.checkMassDelete(try sync2.plan(scope: .full), knownDestFileCount: nil)
    }

    @Test func scopedPlanOnlyLooksAtGivenFolders() throws {
        let t = try TempPair()
        try t.write("a/1.txt", "1")
        try t.write("b/2.txt", "2")
        let sync = t.sync()
        _ = sync.execute(try sync.plan(scope: .full))

        try t.write("a/new.txt", "n")
        try t.write("b/new.txt", "n")
        let plan = try sync.plan(scope: .directories(["a": false]))
        #expect(plan.copyCount == 1)
        _ = sync.execute(plan)
        #expect(t.exists("a/new.txt"))
        #expect(!t.exists("b/new.txt"))

        // A new folder found in a non-recursive scan is copied in full.
        try t.write("a/x/y/z.txt", "z")
        let plan2 = try sync.plan(scope: .directories(["a": false]))
        #expect(plan2.copyCount == 1)
    }

    @Test func folderReplacedByFile() throws {
        let t = try TempPair()
        try t.write("thing/inner.txt", "i")
        let sync = t.sync()
        _ = sync.execute(try sync.plan(scope: .full))
        try t.delete("thing")
        try t.write("thing", "now a file")
        let out = sync.execute(try sync.plan(scope: .full))
        #expect(out.fatalError == nil)
        #expect(t.read("thing") == "now a file")
        #expect(t.read("_archive/\(day)/thing/inner.txt") == "i")
    }

    @Test func ignoresSymlinks() throws {
        let t = try TempPair()
        try t.write("real.txt", "r")
        try FileManager.default.createSymbolicLink(atPath: t.source.appending(path: "link").path(percentEncoded: false), withDestinationPath: "real.txt")
        let sync = t.sync()
        let out = sync.execute(try sync.plan(scope: .full))
        #expect(out.counts.new == 1)
        #expect(out.counts.skipped == 0)
        #expect(out.items.contains { $0.action == .ignored && $0.path == "link" })
    }

    @Test func prunesOldArchiveDays() throws {
        let t = try TempPair()
        try t.write("_archive/2000-01-01/old.txt", "x", in: t.dest)
        try t.write("_archive/\(day)/new.txt", "x", in: t.dest)
        let removed = t.sync().pruneArchive()
        #expect(removed.count == 1)
        #expect(!t.exists("_archive/2000-01-01"))
        #expect(t.exists("_archive/\(day)/new.txt"))
    }

    @Test func archiveIsNeverCompared() throws {
        let t = try TempPair()
        try t.write("_archive/2020-01-01/x.txt", "x", in: t.dest)
        try t.write("a.txt", "a")
        let plan = try t.sync().plan(scope: .full)
        #expect(plan.deletedFileCount == 0)
    }
}

@Suite(.serialized) struct FolderWatcherTests {
    @Test func reportsChangedFoldersAfterQuietPeriod() async throws {
        let t = try TempPair()
        try t.write("keep.txt", "K")
        try t.write("sub/old.txt", "O")
        let sync = t.sync()
        _ = sync.execute(try sync.plan(scope: .full))

        let received = LockedBox<[FolderWatcher.Changes]>([])
        let watcher = FolderWatcher(source: t.source, quietPeriod: 0.5) { c in received.set(received.get() + [c]) }
        watcher.start(since: nil)
        try await Task.sleep(for: .milliseconds(300))
        try t.write("sub/new.txt", "N")
        try FileManager.default.removeItem(at: t.source.appending(path: "sub/old.txt"))
        try t.write("top.txt", "T")

        for _ in 0..<50 where received.get().isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        watcher.stop()
        let changes = try #require(received.get().first)
        guard case .directories(let dirs) = changes.scope else { Issue.record("expected folders, got \(changes.scope)"); return }
        #expect(dirs.keys.contains("sub"))
        #expect(dirs.keys.contains(""))
        #expect(changes.eventID > 0)

        let plan = try sync.plan(scope: changes.scope)
        let out = sync.execute(plan)
        #expect(out.counts.new == 2)
        #expect(out.counts.archived == 1)
        #expect(t.read("sub/new.txt") == "N")
        #expect(!t.exists("sub/old.txt"))
    }

    @Test func relativePaths() {
        #expect(FolderWatcher.relative("/a/b/c", root: "/a/") == "b/c")
        #expect(FolderWatcher.relative("/a", root: "/a/") == "")
        #expect(FolderWatcher.relative("/ab/c", root: "/a/") == nil)
    }
}
