import Foundation
import Testing
@testable import SyncCore

let hasRsync = Rsync.find() != nil

/// A temporary source folder and a local folder standing in for the NAS.
final class TempPair {
    let root: URL
    let source: URL
    let nasRoot: URL
    /// The job's folder on the NAS.
    let dest: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "nassync-test-\(UUID().uuidString)")
        source = root.appending(path: "src")
        nasRoot = root.appending(path: "nas")
        dest = nasRoot.appending(path: "x")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var nas: NAS { NAS(config: NASConfig(ssh: nil, path: nasRoot.path(percentEncoded: false))) }

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
        FolderSync(job: job ?? self.job(), nas: nas)
    }
}

@Suite struct RsyncOutputTests {
    @Test func parsesItemizedLines() {
        #expect(FolderSync.parse(">f+++++++++ 12 a b.txt") == .init(kind: .new, size: 12, path: "a b.txt"))
        #expect(FolderSync.parse("<f.st...... 5 sub/c.txt") == .init(kind: .changed, size: 5, path: "sub/c.txt"))
        #expect(FolderSync.parse("*deleting   0 old.txt") == .init(kind: .deleted, size: 0, path: "old.txt"))
        #expect(FolderSync.parse("*deleting   0 olddir/")?.kind == .other)
        #expect(FolderSync.parse("cd+++++++++ 0 sub/")?.kind == .other)
        #expect(FolderSync.parse(".d..t...... 0 ./")?.kind == .other)
        #expect(FolderSync.parse("skipping non-regular file \"link\"") == nil)
    }

    @Test func readsTheSourceCountFromStats() {
        #expect(FolderSync.statsCount("Number of files: 1,234 (reg: 1,000, dir: 234)") == 1000)
        #expect(FolderSync.statsCount("Number of created files: 3 (reg: 3)") == nil)
    }

    @Test func explainsFailures() {
        #expect(FolderSync.explain(.init(status: 11, stdout: "", stderr: "write failed: No space left on device")) == "The NAS is full.")
        #expect(FolderSync.explain(.init(status: 255, stdout: "", stderr: "")) == "Lost the connection to the NAS.")
    }

    @Test func archiveFolderHasDayAndTime() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 15, minute: 30, second: 12))!
        #expect(FolderSync.archivePath(date) == "_archive/2026-10-29/153012")
    }
}

@Suite(.enabled(if: hasRsync)) struct FolderSyncTests {
    let now = Date()
    var day: String { FolderSync.dayFormatter.string(from: now) }
    var archive: String { FolderSync.archivePath(now) }

    @Test func copiesNewFilesAndFolders() throws {
        let t = try TempPair()
        try t.write("a.txt", "A")
        try t.write("sub/b.txt", "B")
        try t.write("sub/deeper/c.txt", "C")
        let sync = t.sync()
        let plan = try sync.plan()
        #expect(plan.copyCount == 3)
        #expect(plan.copyBytes == 3)
        let out = sync.execute(plan)
        #expect(out.fatalError == nil)
        #expect(out.counts.new == 3)
        #expect(t.read("sub/deeper/c.txt") == "C")

        let again = try sync.plan()
        #expect(again.isEmpty)
        #expect(again.sourceFileCount == 3)
    }

    @Test func reportsComparingThenCopying() throws {
        let t = try TempPair()
        try t.write("a.txt", "A")
        let sync = t.sync()
        let phases = LockedBox<[FolderSync.Progress.Phase]>([])
        let plan = try sync.plan(progress: { p in phases.update { $0.append(p.phase) } })
        _ = sync.execute(plan, progress: { p in phases.update { $0.append(p.phase) } })
        #expect(phases.get().first == .comparing)
        #expect(phases.get().last == .copying)
    }

    @Test func preservesModificationTime() throws {
        let t = try TempPair()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try t.write("a.txt", "A", modified: date)
        let sync = t.sync()
        _ = sync.execute(try sync.plan())
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
        _ = sync.execute(try sync.plan())

        try t.write("change.txt", "new version", modified: Date().addingTimeInterval(60))
        try t.delete("gone.txt")
        try t.delete("folder")
        let plan = try sync.plan()
        #expect(plan.changedFiles == 1)
        #expect(plan.deletedFiles == 2)
        let out = sync.execute(plan, now: now)
        #expect(out.fatalError == nil)
        #expect(out.counts.changed == 1)
        #expect(out.counts.archived == 3)
        #expect(t.read("change.txt") == "new version")
        #expect(!t.exists("gone.txt"))
        #expect(!t.exists("folder"))
        #expect(t.read("\(archive)/change.txt") == "old")
        #expect(t.read("\(archive)/gone.txt") == "bye")
        #expect(t.read("\(archive)/folder/inner.txt") == "in")

        // A later replacement on the same day gets its own time folder.
        let later = now.addingTimeInterval(1)
        try t.write("change.txt", "newest", modified: Date().addingTimeInterval(120))
        _ = sync.execute(try sync.plan(), now: later)
        #expect(t.read("\(FolderSync.archivePath(later))/change.txt") == "new version")
        #expect(t.read("\(archive)/change.txt") == "old")
    }

    @Test func respectsExcludesOnBothSides() throws {
        let t = try TempPair()
        try t.write("a.txt", "A")
        try t.write(".DS_Store", "x")
        try t.write("node_modules/lib.js", "x")
        try t.write(".DS_Store", "nas", in: t.dest)
        let sync = t.sync(t.job(exclude: [".DS_Store", "node_modules/"]))
        let out = sync.execute(try sync.plan())
        #expect(out.counts.new == 1)
        #expect(t.read(".DS_Store") == "nas")
        #expect(!t.exists("node_modules"))
    }

    @Test func guardsMissingAndEmptySource() throws {
        let t = try TempPair()
        try t.write("a.txt", "A")
        let sync = t.sync()
        _ = sync.execute(try sync.plan())

        try t.delete("a.txt")
        #expect(throws: FolderSync.GuardError.sourceEmpty(t.source.path(percentEncoded: false))) {
            try sync.plan()
        }
        try FileManager.default.removeItem(at: t.source)
        #expect(throws: FolderSync.GuardError.sourceMissing(t.source.path(percentEncoded: false))) {
            try sync.plan()
        }
        #expect(t.exists("a.txt"))
    }

    @Test func guardsMassDelete() throws {
        let t = try TempPair()
        for i in 0..<40 { try t.write("f\(i).txt", "\(i)") }
        let sync = t.sync(t.job(maxDeletePercent: 20))
        _ = sync.execute(try sync.plan())
        for i in 0..<20 { try t.delete("f\(i).txt") }
        let plan = try sync.plan()
        #expect(throws: FolderSync.GuardError.massDelete(files: 20, percent: 50)) {
            try sync.checkMassDelete(plan)
        }
        // A small number of deletions is fine.
        let t2 = try TempPair()
        for i in 0..<40 { try t2.write("f\(i).txt", "\(i)") }
        let sync2 = t2.sync()
        _ = sync2.execute(try sync2.plan())
        try t2.delete("f1.txt")
        try sync2.checkMassDelete(try sync2.plan())
    }

    @Test func folderReplacedByFile() throws {
        let t = try TempPair()
        try t.write("thing/inner.txt", "i")
        let sync = t.sync()
        _ = sync.execute(try sync.plan())
        try t.delete("thing")
        try t.write("thing", "now a file")
        let out = sync.execute(try sync.plan(), now: now)
        #expect(out.fatalError == nil)
        #expect(t.read("thing") == "now a file")
        #expect(t.read("\(archive)/thing/inner.txt") == "i")
    }

    @Test func fileReplacedByFolder() throws {
        let t = try TempPair()
        try t.write("thing", "a file")
        let sync = t.sync()
        _ = sync.execute(try sync.plan())
        try t.delete("thing")
        try t.write("thing/inner.txt", "i")
        let out = sync.execute(try sync.plan(), now: now)
        #expect(out.fatalError == nil)
        #expect(t.read("thing/inner.txt") == "i")
        #expect(t.read("\(archive)/thing") == "a file")
    }

    @Test func handlesManyFiles() throws {
        let t = try TempPair()
        for i in 0..<300 { try t.write("d\(i % 7)/sub\(i % 3)/f\(i).txt", "v1-\(i)", modified: Date(timeIntervalSince1970: 1_700_000_000)) }
        let sync = t.sync(t.job(maxDeletePercent: 100, maxDeleteFiles: 10_000))
        let first = sync.execute(try sync.plan())
        #expect(first.fatalError == nil)
        #expect(first.counts.new == 300)

        for i in 0..<100 { try t.delete("d\(i % 7)/sub\(i % 3)/f\(i).txt") }
        for i in 100..<200 { try t.write("d\(i % 7)/sub\(i % 3)/f\(i).txt", "v2-\(i)") }
        let second = sync.execute(try sync.plan(), now: now)
        #expect(second.fatalError == nil)
        #expect(second.counts.changed == 100)
        #expect(second.counts.archived == 200)
        #expect(t.read("d0/sub0/f0.txt") == nil)
        #expect(t.read("\(archive)/d0/sub0/f0.txt") == "v1-0")
        #expect(t.read("d2/sub2/f107.txt") == "v2-107")
        #expect(t.read("\(archive)/d2/sub2/f107.txt") == "v1-107")
        #expect(try sync.plan().isEmpty)
    }

    @Test func skipsSymlinks() throws {
        let t = try TempPair()
        try t.write("real.txt", "r")
        try FileManager.default.createSymbolicLink(atPath: t.source.appending(path: "link").path(percentEncoded: false), withDestinationPath: "real.txt")
        let sync = t.sync()
        let plan = try sync.plan()
        #expect(plan.newFiles == 1)
        #expect(plan.notes.contains { $0.contains("link") })
        let out = sync.execute(plan)
        #expect(out.fatalError == nil)
        #expect(out.counts.new == 1)
        #expect(!t.exists("link"))
    }

    @Test func prunesOldArchiveDays() throws {
        let t = try TempPair()
        try t.write("_archive/2000-01-01/000000/old.txt", "x", in: t.dest)
        try t.write("_archive/\(day)/000000/new.txt", "x", in: t.dest)
        let removed = t.sync().pruneArchive(now: now)
        #expect(removed.count == 1)
        #expect(!t.exists("_archive/2000-01-01"))
        #expect(t.exists("_archive/\(day)/000000/new.txt"))
    }

    @Test func archiveIsNeverCompared() throws {
        let t = try TempPair()
        try t.write("_archive/2020-01-01/000000/x.txt", "x", in: t.dest)
        try t.write("a.txt", "a")
        let plan = try t.sync().plan()
        #expect(plan.deletedFiles == 0)
    }
}

@Suite(.serialized, .enabled(if: hasRsync)) struct FolderWatcherTests {
    @Test func reportsChangedFoldersAfterQuietPeriod() async throws {
        let t = try TempPair()
        try t.write("keep.txt", "K")
        try t.write("sub/old.txt", "O")
        let sync = t.sync()
        _ = sync.execute(try sync.plan())

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

        let plan = try sync.plan()
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

@Suite(.enabled(if: hasRsync)) struct FolderRunnerTests {
    @Test func writesIntoTheJobFolderOnTheNAS() throws {
        let t = try TempPair()
        try t.write("a.txt", "A")
        let store = try Store(directory: t.root.appending(path: "state"))
        try t.write("unrelated/keep.txt", "K", in: t.nasRoot)
        var job = t.job()
        job.dest = "Backups/Docs"

        let r = FolderRunner.run(job: job, nas: t.nas, store: store, options: .init(trigger: "test", scope: .full))
        #expect(r.outcome == .success)
        #expect(t.read("Backups/Docs/a.txt", in: t.nasRoot) == "A")
        #expect(t.read("unrelated/keep.txt", in: t.nasRoot) == "K")
        #expect(!t.exists("Backups/Docs/_archive", in: t.nasRoot))
    }

    @Test func refusesTheNASFolderItself() throws {
        let t = try TempPair()
        try t.write("a.txt", "A")
        var job = t.job()
        job.dest = "."
        let sync = FolderSync(job: job, nas: t.nas)
        #expect(throws: FolderSync.GuardError.self) { try sync.plan() }
    }
}
