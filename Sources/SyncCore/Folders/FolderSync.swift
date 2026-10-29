import Darwin
import Foundation

/// One-way mirror of a local folder into a NAS folder, with a dated archive of
/// deleted and replaced files.
public struct FolderSync: Sendable {
    public static let archiveFolder = "_archive"
    public static let tempPrefix = ".nassync-tmp-"
    /// Modification times closer than this count as equal (some NAS file systems round them).
    public static let timeTolerance: TimeInterval = 2

    public var job: FolderJobConfig
    public var source: URL
    public var destination: URL

    /// Syncs into `shareRoot/<job.dest>`.
    public init(job: FolderJobConfig, shareRoot: URL) {
        self.init(job: job, destination: shareRoot.appending(path: job.dest, directoryHint: .isDirectory))
        self.shareRoot = shareRoot
    }

    /// Syncs into exactly `destination`.
    public init(job: FolderJobConfig, destination: URL) {
        self.job = job
        source = job.source
        self.destination = destination
    }

    /// When set, the destination must be strictly inside it.
    public var shareRoot: URL?

    var sourceLister: FileLister { FileLister(root: source, exclude: job.excludeSet, reservedRootNames: [Self.archiveFolder]) }
    var destLister: FileLister { FileLister(root: destination, exclude: job.excludeSet, reservedRootNames: [Self.archiveFolder]) }
    public var archiveRoot: URL { destination.appending(path: Self.archiveFolder) }

    // MARK: Planning

    /// What part of the tree to compare.
    public enum Scope: Sendable, Equatable {
        case full
        /// Relative folder paths; `true` means compare everything below it too.
        case directories([String: Bool])
    }

    public enum Action: Sendable, Equatable {
        case makeDirectory(String)
        case copy(FileEntry, replacing: FileEntry?)
        /// Moves a file or a whole folder from the NAS into the archive. Counts describe what's inside.
        case archive(FileEntry, files: Int, bytes: Int64)
    }

    public struct Plan: Sendable, Equatable {
        public var actions: [Action] = []
        /// Source items that were intentionally not copied (symbolic links and the like).
        public var ignored: [RunItem] = []
        public var sourceFileCount = 0
        public var destFileCount = 0
        public var isFull = false

        public var copyCount: Int { actions.reduce(0) { if case .copy = $1 { $0 + 1 } else { $0 } } }
        public var copyBytes: Int64 { actions.reduce(0) { if case .copy(let e, _) = $1 { $0 + e.size } else { $0 } } }
        /// Files that would be archived because they were deleted from the source (not replacements).
        public var deletedFileCount: Int { actions.reduce(0) { if case .archive(_, let n, _) = $1 { $0 + n } else { $0 } } }
        public var isEmpty: Bool { actions.isEmpty }
    }

    public enum GuardError: Error, Equatable, CustomStringConvertible {
        case sourceMissing(String)
        case sourceEmpty(String)
        case destinationMissing(String)
        case destinationIsShareRoot(String)
        case massDelete(files: Int, percent: Int)

        public var description: String {
            switch self {
            case .sourceMissing(let p): "The source folder \(p) doesn't exist. Nothing was changed on the NAS."
            case .sourceEmpty(let p): "The source folder \(p) is empty, but the NAS copy has files. Nothing was changed, in case the source is temporarily unavailable."
            case .destinationMissing(let p): "The NAS folder \(p) isn't there."
            case .destinationIsShareRoot(let p): "The destination \(p) is the whole NAS share. Set dest to a folder inside the share."
            case .massDelete(let files, let percent): "This run would archive \(files.formatted()) deleted files (\(percent)% of the backup). Stopped to be safe; confirm to continue."
            }
        }
    }

    /// Lists the NAS side in parallel before a full comparison.
    public var prefetchDestination = true

    public func plan(scope: Scope, isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> Plan {
        var plan = Plan()
        plan.isFull = scope == .full

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false), isDirectory: &isDir), isDir.boolValue else {
            throw GuardError.sourceMissing(source.path(percentEncoded: false))
        }
        if let shareRoot {
            let root = shareRoot.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
            let dest = destination.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
            guard dest.hasPrefix(root + "/"), dest.count > root.count + 1 else { throw GuardError.destinationIsShareRoot(dest) }
        }
        let src = sourceLister
        var dst = destLister

        switch scope {
        case .full:
            if prefetchDestination { dst.cache = try dst.prefetch(isCancelled: isCancelled) }
            try compare("", recursive: true, src: src, dst: dst, plan: &plan, isCancelled: isCancelled)
        case .directories(let dirs):
            // Skip folders already covered by a recursive parent in the set.
            let recursiveRoots = dirs.filter(\.value).map(\.key)
            for (dir, recursive) in dirs.sorted(by: { $0.key < $1.key }) {
                let coveredByParent = recursiveRoots.contains { root in
                    root != dir && (root.isEmpty || dir.hasPrefix(root + "/"))
                }
                if coveredByParent { continue }
                if src.exclude.matches(dir, isDirectory: true) { continue }
                try compare(dir, recursive: recursive, src: src, dst: dst, plan: &plan, isCancelled: isCancelled)
            }
        }

        if plan.isFull, plan.sourceFileCount == 0, plan.destFileCount > 0 {
            throw GuardError.sourceEmpty(source.path(percentEncoded: false))
        }
        return plan
    }

    private func compare(
        _ dir: String, recursive: Bool, src: FileLister, dst: FileLister, plan: inout Plan, isCancelled: () -> Bool
    ) throws {
        if isCancelled() { throw CancellationError() }
        let srcEntries = try src.list(dir)
        let dstEntries = try dst.list(dir)

        guard let srcEntries else {
            // Folder gone from the source: archive the NAS copy as a whole.
            if !dir.isEmpty, dstEntries != nil {
                let entry = FileEntry(relativePath: dir, kind: .directory, size: 0, modified: 0)
                let (files, bytes) = try count(dir, in: dst, isCancelled: isCancelled)
                plan.actions.append(.archive(entry, files: files, bytes: bytes))
                plan.destFileCount += files
            }
            return
        }
        guard let dstEntries else {
            if !dir.isEmpty { plan.actions.append(.makeDirectory(dir)) }
            try copyTree(srcEntries, src: src, plan: &plan, isCancelled: isCancelled)
            return
        }

        var dstByName: [String: FileEntry] = [:]
        for e in dstEntries { dstByName[e.name] = e }
        var seen: Set<String> = []

        for s in srcEntries.sorted(by: { $0.relativePath < $1.relativePath }) {
            seen.insert(s.name)
            let d = dstByName[s.name]
            switch s.kind {
            case .file:
                plan.sourceFileCount += 1
                if let d {
                    if d.kind == .file {
                        plan.destFileCount += 1
                        if !Self.same(s, d) { plan.actions.append(.copy(s, replacing: d)) }
                    } else if d.kind == .directory {
                        let (files, bytes) = try count(d.relativePath, in: dst, isCancelled: isCancelled)
                        plan.destFileCount += files
                        plan.actions.append(.archive(d, files: files, bytes: bytes))
                        plan.actions.append(.copy(s, replacing: nil))
                    } else {
                        plan.ignored.append(RunItem(action: .skipped, path: s.relativePath, detail: "Something that isn't a file is in the way on the NAS"))
                    }
                } else {
                    plan.actions.append(.copy(s, replacing: nil))
                }
            case .directory:
                if let d, d.kind == .directory {
                    if recursive {
                        try compare(s.relativePath, recursive: true, src: src, dst: dst, plan: &plan, isCancelled: isCancelled)
                    }
                } else {
                    if let d {
                        plan.actions.append(.archive(d, files: 1, bytes: d.size))
                        plan.destFileCount += 1
                    }
                    plan.actions.append(.makeDirectory(s.relativePath))
                    let children = try src.list(s.relativePath) ?? []
                    try copyTree(children, src: src, plan: &plan, isCancelled: isCancelled)
                }
            case .symlink:
                plan.ignored.append(RunItem(action: .ignored, path: s.relativePath, detail: "Symbolic link, not copied"))
            case .other:
                plan.ignored.append(RunItem(action: .ignored, path: s.relativePath, detail: "Not a regular file, not copied"))
            }
        }

        for d in dstEntries.sorted(by: { $0.relativePath < $1.relativePath }) where !seen.contains(d.name) {
            switch d.kind {
            case .file:
                plan.destFileCount += 1
                plan.actions.append(.archive(d, files: 1, bytes: d.size))
            case .directory:
                let (files, bytes) = try count(d.relativePath, in: dst, isCancelled: isCancelled)
                plan.destFileCount += files
                plan.actions.append(.archive(d, files: files, bytes: bytes))
            case .symlink, .other:
                break
            }
        }
    }

    private func copyTree(_ entries: [FileEntry], src: FileLister, plan: inout Plan, isCancelled: () -> Bool) throws {
        for e in entries.sorted(by: { $0.relativePath < $1.relativePath }) {
            if isCancelled() { throw CancellationError() }
            switch e.kind {
            case .file:
                plan.sourceFileCount += 1
                plan.actions.append(.copy(e, replacing: nil))
            case .directory:
                plan.actions.append(.makeDirectory(e.relativePath))
                try copyTree(try src.list(e.relativePath) ?? [], src: src, plan: &plan, isCancelled: isCancelled)
            case .symlink:
                plan.ignored.append(RunItem(action: .ignored, path: e.relativePath, detail: "Symbolic link, not copied"))
            case .other:
                plan.ignored.append(RunItem(action: .ignored, path: e.relativePath, detail: "Not a regular file, not copied"))
            }
        }
    }

    private func count(_ dir: String, in lister: FileLister, isCancelled: () -> Bool) throws -> (Int, Int64) {
        var files = 0
        var bytes: Int64 = 0
        for e in try lister.listRecursive(dir, isCancelled: isCancelled) where e.kind == .file {
            files += 1
            bytes += e.size
        }
        return (files, bytes)
    }

    static func same(_ a: FileEntry, _ b: FileEntry) -> Bool {
        a.size == b.size && abs(a.modified - b.modified) <= timeTolerance
    }

    /// Checks the mass-delete guard. `knownDestFileCount` is used for partial scans.
    public func checkMassDelete(_ plan: Plan, knownDestFileCount: Int?) throws {
        let deleted = plan.deletedFileCount
        guard deleted > 0 else { return }
        let base = max(plan.isFull ? plan.destFileCount : (knownDestFileCount ?? plan.destFileCount), 1)
        let percent = Int((Double(deleted) / Double(base) * 100).rounded(.up))
        if deleted > job.maxDeleteFiles || (percent > job.maxDeletePercent && deleted > 10) {
            throw GuardError.massDelete(files: deleted, percent: min(percent, 100))
        }
    }

    // MARK: Executing

    public struct Progress: Sendable {
        public var done: Int
        public var total: Int
        public var bytesDone: Int64
        public var bytesTotal: Int64
        public var current: String
    }

    public struct Outcome: Sendable {
        public var counts = RunCounts()
        public var items: [RunItem] = []
        /// Set when the run had to stop, for example because the NAS went away or is full.
        public var fatalError: String?
    }

    public func execute(
        _ plan: Plan, now: Date = Date(),
        isCancelled: @Sendable () -> Bool = { false },
        progress: (Progress) -> Void = { _ in }
    ) -> Outcome {
        var out = Outcome()
        out.counts.total = plan.sourceFileCount
        out.items.append(contentsOf: plan.ignored)
        out.counts.skipped += plan.ignored.filter { $0.action == .skipped }.count

        let totalCopies = plan.copyCount
        let totalBytes = plan.copyBytes
        var done = 0
        var bytesDone: Int64 = 0
        let archiveDay = Self.dayFormatter.string(from: now)

        for action in plan.actions {
            if isCancelled() {
                out.fatalError = "Stopped."
                break
            }
            do {
                switch action {
                case .makeDirectory(let rel):
                    try FileManager.default.createDirectory(at: destination.appending(path: rel), withIntermediateDirectories: true)
                case .archive(let entry, let files, let bytes):
                    let target = try moveToArchive(entry.relativePath, day: archiveDay)
                    out.counts.archived += files
                    out.items.append(RunItem(
                        action: .archived, path: entry.relativePath, size: bytes,
                        detail: "Deleted from the source, moved to \(Self.archiveFolder)/\(archiveDay)/\(target)"
                            + (entry.kind == .directory ? " (\(Format.count(files, "file")))" : "")
                    ))
                case .copy(let entry, let replacing):
                    progress(Progress(done: done, total: totalCopies, bytesDone: bytesDone, bytesTotal: totalBytes, current: entry.relativePath))
                    if replacing != nil {
                        _ = try moveToArchive(entry.relativePath, day: archiveDay)
                        out.counts.archived += 1
                    }
                    try copyFile(entry)
                    done += 1
                    bytesDone += entry.size
                    out.counts.bytes += entry.size
                    if replacing == nil {
                        out.counts.new += 1
                        out.items.append(RunItem(action: .new, path: entry.relativePath, size: entry.size))
                    } else {
                        out.counts.changed += 1
                        out.items.append(RunItem(action: .changed, path: entry.relativePath, size: entry.size, detail: "Previous version archived"))
                    }
                }
            } catch let error as CopyError {
                switch error {
                case .changedWhileCopying:
                    out.counts.skipped += 1
                    out.items.append(RunItem(action: .skipped, path: action.path, detail: "Changed while copying; will retry"))
                case .unreadable(let reason):
                    out.counts.skipped += 1
                    out.items.append(RunItem(action: .skipped, path: action.path, detail: reason))
                case .fatal(let reason):
                    out.counts.failed += 1
                    out.items.append(RunItem(action: .failed, path: action.path, detail: reason))
                    out.fatalError = reason
                }
                if out.fatalError != nil { break }
            } catch {
                let reason = Self.describe(error)
                if Self.isFatal(error) {
                    out.fatalError = reason
                    out.counts.failed += 1
                    out.items.append(RunItem(action: .failed, path: action.path, detail: reason))
                    break
                }
                out.counts.failed += 1
                out.items.append(RunItem(action: .failed, path: action.path, detail: reason))
            }
        }
        out.counts.unchanged = max(0, plan.sourceFileCount - out.counts.new - out.counts.changed - out.counts.skipped - out.counts.failed)
        progress(Progress(done: done, total: totalCopies, bytesDone: bytesDone, bytesTotal: totalBytes, current: ""))
        return out
    }

    enum CopyError: Error {
        case changedWhileCopying
        case unreadable(String)
        case fatal(String)
    }

    private func copyFile(_ entry: FileEntry) throws {
        let src = source.appending(path: entry.relativePath)
        let dst = destination.appending(path: entry.relativePath)
        let dir = dst.deletingLastPathComponent()
        let tmp = dir.appending(path: Self.tempPrefix + UUID().uuidString.prefix(8) + "-" + dst.lastPathComponent)
        let srcPath = src.path(percentEncoded: false)
        let tmpPath = tmp.path(percentEncoded: false)

        guard access(srcPath, R_OK) == 0 else {
            throw CopyError.unreadable("Can't read this file (permission denied or in use)")
        }
        if !FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if copyfile(srcPath, tmpPath, nil, copyfile_flags_t(COPYFILE_DATA)) != 0 {
            let code = errno
            unlink(tmpPath)
            if code == ENOSPC { throw CopyError.fatal("The NAS is full.") }
            if code == ENOENT {
                throw CopyError.changedWhileCopying
            }
            if code == EACCES || code == EPERM || code == EDEADLK || code == EBUSY {
                throw CopyError.unreadable("Can't read this file (\(String(cString: strerror(code))))")
            }
            throw CopyError.fatal(Self.errnoMessage(code))
        }
        // The source may have changed during the copy.
        let after = try? src.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if Int64(after?.fileSize ?? -1) != entry.size
            || abs((after?.contentModificationDate?.timeIntervalSince1970 ?? 0) - entry.modified) > 0.001 {
            unlink(tmpPath)
            throw CopyError.changedWhileCopying
        }
        var times = [
            timespec(tv_sec: Int(entry.modified), tv_nsec: Int((entry.modified - floor(entry.modified)) * 1e9)),
            timespec(tv_sec: Int(entry.modified), tv_nsec: Int((entry.modified - floor(entry.modified)) * 1e9)),
        ]
        _ = utimensat(AT_FDCWD, tmpPath, &times, 0)
        if rename(tmpPath, dst.path(percentEncoded: false)) != 0 {
            let code = errno
            unlink(tmpPath)
            throw CopyError.fatal(Self.errnoMessage(code))
        }
    }

    /// Moves a NAS item into `_archive/<day>/`, keeping its relative path. Returns the path used inside the day folder.
    private func moveToArchive(_ relativePath: String, day: String) throws -> String {
        let from = destination.appending(path: relativePath)
        let dayRoot = archiveRoot.appending(path: day)
        var rel = relativePath
        var to = dayRoot.appending(path: rel)
        var n = 2
        while FileManager.default.fileExists(atPath: to.path(percentEncoded: false)) {
            let ext = (relativePath as NSString).pathExtension
            let base = (relativePath as NSString).deletingPathExtension
            rel = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            to = dayRoot.appending(path: rel)
            n += 1
        }
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        if rename(from.path(percentEncoded: false), to.path(percentEncoded: false)) != 0 {
            throw CopyError.fatal("Couldn't move \(relativePath) into the archive: " + Self.errnoMessage(errno))
        }
        return rel
    }

    // MARK: Archive pruning

    /// Deletes dated archive folders older than the job's `archiveDays`.
    public func pruneArchive(now: Date = Date()) -> [RunItem] {
        guard let days = try? FileManager.default.contentsOfDirectory(atPath: archiveRoot.path(percentEncoded: false)) else { return [] }
        let cutoff = now.addingTimeInterval(-Double(job.archiveDays) * 86400)
        var removed: [RunItem] = []
        for day in days.sorted() {
            guard let date = Self.dayFormatter.date(from: day), date < cutoff else { continue }
            let url = archiveRoot.appending(path: day)
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed.append(RunItem(action: .pruned, path: "\(Self.archiveFolder)/\(day)", detail: "Older than \(job.archiveDays) days"))
            }
        }
        return removed
    }

    // MARK: Helpers

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func errnoMessage(_ code: Int32) -> String {
        switch code {
        case ENOSPC: "The NAS is full."
        case ENOENT: "The NAS folder disappeared (was the share unmounted?)."
        case EIO, ENOTCONN, ETIMEDOUT, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH: "Lost the connection to the NAS."
        case EROFS: "The NAS share is read-only."
        case EACCES, EPERM: "Permission denied on the NAS."
        default: String(cString: strerror(code))
        }
    }

    static func isFatal(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            return [ENOSPC, EIO, ENOTCONN, ETIMEDOUT, ENETDOWN, EROFS].contains(Int32(ns.code))
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isFatal(underlying) }
        return ns.domain == NSCocoaErrorDomain && [NSFileWriteOutOfSpaceError, NSFileWriteVolumeReadOnlyError].contains(ns.code)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? CopyError {
            switch e {
            case .changedWhileCopying: return "Changed while copying"
            case .unreadable(let s), .fatal(let s): return s
            }
        }
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return errnoMessage(Int32(underlying.code))
        }
        return ns.localizedDescription
    }
}

extension FolderSync.Action {
    var path: String {
        switch self {
        case .makeDirectory(let p): p
        case .copy(let e, _): e.relativePath
        case .archive(let e, _, _): e.relativePath
        }
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var s = self
        while s.hasSuffix(suffix), s.count > suffix.count { s.removeLast(suffix.count) }
        return s
    }
}
