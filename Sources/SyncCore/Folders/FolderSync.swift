import Foundation

/// One-way mirror of a local folder into a NAS folder using rsync, with a dated archive of
/// deleted and replaced files.
public struct FolderSync: Sendable {
    public static let archiveFolder = "_archive"
    /// Modification times closer than this count as equal (some NAS file systems round them).
    public static let timeTolerance = 2

    public var job: FolderJobConfig
    public var nas: NAS

    public init(job: FolderJobConfig, nas: NAS) {
        self.job = job
        self.nas = nas
    }

    public var source: URL { job.source }

    /// What part of the tree changed. rsync always compares the whole tree; this is kept for scheduling.
    public enum Scope: Sendable, Equatable {
        case full
        /// Relative folder paths; `true` means everything below it too.
        case directories([String: Bool])
    }

    public enum GuardError: Error, Equatable, CustomStringConvertible {
        case sourceMissing(String)
        case sourceEmpty(String)
        case destinationIsShareRoot(String)
        case massDelete(files: Int, percent: Int)

        public var description: String {
            switch self {
            case .sourceMissing(let p): "The source folder \(p) doesn't exist. Nothing was changed on the NAS."
            case .sourceEmpty(let p): "The source folder \(p) is empty, but the NAS copy has files. Nothing was changed, in case the source is temporarily unavailable."
            case .destinationIsShareRoot(let p): "The destination \(p) is the whole NAS folder. Set dest to a folder inside it."
            case .massDelete(let files, let percent): "This run would archive \(files.formatted()) deleted files (\(percent)% of the backup). Stopped to be safe; confirm to continue."
            }
        }
    }

    public struct SyncError: Error, CustomStringConvertible {
        public var description: String
    }

    // MARK: Planning

    /// What a run would do, from an rsync dry run.
    public struct Plan: Sendable, Equatable {
        public var items: [RunItem] = []
        public var newFiles = 0
        public var changedFiles = 0
        public var deletedFiles = 0
        public var copyBytes: Int64 = 0
        public var sourceFileCount = 0
        /// Notes from rsync, such as skipped symbolic links.
        public var notes: [String] = []
        public var isFull: Bool { true }

        public var copyCount: Int { newFiles + changedFiles }
        /// Files on the NAS before the run.
        public var destFileCount: Int { max(0, sourceFileCount - newFiles + deletedFiles) }
        public var isEmpty: Bool { copyCount == 0 && deletedFiles == 0 }
    }

    public struct Progress: Sendable {
        public enum Phase: String, Sendable {
            case comparing, copying
        }

        public var phase: Phase = .copying
        public var done = 0
        public var total = 0
        public var bytesDone: Int64 = 0
        public var bytesTotal: Int64 = 0
        public var current = ""
    }

    public struct Outcome: Sendable {
        public var counts = RunCounts()
        public var items: [RunItem] = []
        /// Set when the run had to stop, for example because the NAS went away or is full.
        public var fatalError: String?
        /// Problems with single files (rsync exit 23 or 24).
        public var warnings: [String] = []
    }

    func checkSource() throws {
        var isDir: ObjCBool = false
        let path = source.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw GuardError.sourceMissing(path)
        }
        let dest = job.dest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !dest.isEmpty, dest != "." else { throw GuardError.destinationIsShareRoot(nas.absolute("")) }
    }

    /// Compares the folder with the NAS without changing anything.
    public func plan(isCancelled: @escaping @Sendable () -> Bool = { false }, progress: @escaping @Sendable (Progress) -> Void = { _ in }) throws -> Plan {
        try checkSource()
        progress(Progress(phase: .comparing))
        let lines = LockedBox<[String]>([])
        let r = try rsync(dryRun: true, archiveDay: nil, isCancelled: isCancelled) { line in lines.update { $0.append(line) } }
        if r.status != 0, r.status != 23, r.status != 24 { throw SyncError(description: Self.explain(r)) }
        var plan = Plan()
        for line in lines.get() {
            if let n = Self.statsCount(line) { plan.sourceFileCount = n; continue }
            guard let item = Self.parse(line) else {
                if line.hasPrefix("skipping ") { plan.notes.append(line) }
                continue
            }
            switch item.kind {
            case .new: plan.newFiles += 1; plan.copyBytes += item.size
            case .changed: plan.changedFiles += 1; plan.copyBytes += item.size
            case .deleted: plan.deletedFiles += 1
            case .other: continue
            }
            plan.items.append(item.runItem(dryRun: true))
        }
        if plan.sourceFileCount == 0, plan.deletedFiles > 0 {
            throw GuardError.sourceEmpty(source.path(percentEncoded: false))
        }
        return plan
    }

    /// Stops when a run would archive a large share of the NAS copy.
    public func checkMassDelete(_ plan: Plan) throws {
        let deleted = plan.deletedFiles
        guard deleted > 0 else { return }
        let base = max(plan.destFileCount, 1)
        let percent = Int((Double(deleted) / Double(base) * 100).rounded(.up))
        if deleted > job.maxDeleteFiles || (percent > job.maxDeletePercent && deleted > 10) {
            throw GuardError.massDelete(files: deleted, percent: min(percent, 100))
        }
    }

    // MARK: Running

    /// Copies changes and moves deleted or replaced files to `_archive/<day>/<time>`.
    public func execute(_ plan: Plan, now: Date = Date(), isCancelled: @escaping @Sendable () -> Bool = { false },
                        progress: @escaping @Sendable (Progress) -> Void = { _ in }) -> Outcome {
        let state = LockedBox((out: Outcome(), done: 0, bytes: Int64(0), lastReport: Date.distantPast))
        let total = plan.copyCount, totalBytes = plan.copyBytes
        let archive = Self.archivePath(now)
        var out: Outcome
        do {
            try nas.makeDirectory(job.dest)
            let r = try rsync(dryRun: false, archiveDay: now, isCancelled: isCancelled) { line in
                guard let item = Self.parse(line) else { return }
                let report: Progress? = state.update { s in
                    switch item.kind {
                    case .new: s.out.counts.new += 1
                    case .changed: s.out.counts.changed += 1; s.out.counts.archived += 1
                    case .deleted: s.out.counts.archived += 1
                    case .other: return nil
                    }
                    s.out.items.append(item.runItem(dryRun: false, archive: archive))
                    guard item.kind != .deleted else { return nil }
                    s.done += 1
                    s.bytes += item.size
                    s.out.counts.bytes += item.size
                    let t = Date()
                    guard t.timeIntervalSince(s.lastReport) > 0.2 else { return nil }
                    s.lastReport = t
                    return Progress(done: s.done, total: max(total, s.done), bytesDone: s.bytes, bytesTotal: max(totalBytes, s.bytes), current: item.path)
                }
                if let report { progress(report) }
            }
            out = state.get().out
            switch r.status {
            case 0:
                break
            case 23, 24:
                out.warnings = Self.fileErrors(r.stderr)
                out.counts.failed = max(out.warnings.count, 1)
            default:
                out.fatalError = Self.explain(r)
            }
        } catch is CancellationError {
            out = state.get().out
            out.fatalError = "Stopped."
        } catch {
            out = state.get().out
            out.fatalError = "\(error)"
        }
        out.counts.total = plan.sourceFileCount
        out.counts.unchanged = max(0, plan.sourceFileCount - out.counts.new - out.counts.changed - out.counts.failed)
        let s = state.get()
        progress(Progress(done: s.done, total: max(total, s.done), bytesDone: s.bytes, bytesTotal: max(totalBytes, s.bytes)))
        return out
    }

    func rsync(dryRun: Bool, archiveDay: Date?, isCancelled: @escaping @Sendable () -> Bool, onLine: @escaping @Sendable (String) -> Void) throws -> Command.Result {
        guard let exe = nas.rsync else { throw SyncError(description: Rsync.missingMessage) }
        var args = ["-rt", "--delete", "--modify-window=\(Self.timeTolerance)", "--out-format=%i %l %n",
                    "--exclude=/\(Self.archiveFolder)/"]
        args += job.exclude.map { "--exclude=\($0)" }
        args += nas.rsyncTransportArgs
        if dryRun {
            args += ["--dry-run", "--stats"]
        } else if let archiveDay {
            args += ["--backup", "--backup-dir=\(Self.archivePath(archiveDay))"]
        }
        args += [source.path(percentEncoded: false) + "/", nas.rsyncTarget(job.dest) + "/"]
        return try Command.run(exe, args, timeout: 24 * 3600, isCancelled: isCancelled, onLine: onLine)
    }

    /// `_archive/2026-10-29/153012`, relative to the job folder.
    static func archivePath(_ date: Date) -> String {
        "\(archiveFolder)/\(dayFormatter.string(from: date))/\(timeFormatter.string(from: date))"
    }

    // MARK: Archive pruning

    /// Deletes dated archive folders older than the job's `archiveDays`.
    public func pruneArchive(now: Date = Date()) -> [RunItem] {
        let root = "\(job.dest)/\(Self.archiveFolder)"
        guard let days = try? nas.listTree(root, maxDepth: 1) else { return [] }
        let cutoff = now.addingTimeInterval(-Double(job.archiveDays) * 86400)
        let old = days.filter(\.isDirectory).map(\.path).filter { day in
            Self.dayFormatter.date(from: day).map { $0 < cutoff } ?? false
        }.sorted()
        guard !old.isEmpty, (try? nas.remove(old.map { "\(root)/\($0)" })) != nil else { return [] }
        return old.map { RunItem(action: .pruned, path: "\(Self.archiveFolder)/\($0)", detail: "Older than \(job.archiveDays) days") }
    }

    // MARK: Parsing rsync output

    struct Line: Equatable {
        enum Kind { case new, changed, deleted, other }
        var kind: Kind
        var size: Int64
        var path: String

        func runItem(dryRun: Bool, archive: String = FolderSync.archiveFolder) -> RunItem {
            switch kind {
            case .new: RunItem(action: .new, path: path, size: size)
            case .changed: RunItem(action: .changed, path: path, size: size, detail: dryRun ? nil : "Previous version moved to \(archive)")
            case .deleted: RunItem(action: .archived, path: path, detail: dryRun ? nil : "Deleted from the source, moved to \(archive)")
            case .other: RunItem(action: .unchanged, path: path)
            }
        }
    }

    /// Parses one `%i %l %n` line. Folders and attribute-only updates come back as `.other`.
    static func parse(_ line: String) -> Line? {
        guard line.count > 13 else { return nil }
        let code = Array(line.prefix(11))
        let rest = line.dropFirst(12)
        guard let space = rest.firstIndex(of: " "), let size = Int64(rest[..<space]) else { return nil }
        let path = String(rest[rest.index(after: space)...])
        if String(code).hasPrefix("*deleting") {
            return Line(kind: path.hasSuffix("/") ? .other : .deleted, size: 0, path: path)
        }
        guard code.count == 11, "<>ch.".contains(code[0]) else { return nil }
        guard code[1] == "f", code[0] == "<" || code[0] == ">" else { return Line(kind: .other, size: size, path: path) }
        return Line(kind: code[2] == "+" ? .new : .changed, size: size, path: path)
    }

    /// The source file count from `--stats` ("Number of files: 1,234 (reg: 1,000, dir: 234)").
    static func statsCount(_ line: String) -> Int? {
        guard line.hasPrefix("Number of files:"), let reg = line.range(of: "reg: ") else { return nil }
        return Int(line[reg.upperBound...].prefix { $0.isNumber || $0 == "," }.filter(\.isNumber))
    }

    static func fileErrors(_ stderr: String) -> [String] {
        stderr.split(separator: "\n").map(String.init).filter { $0.hasPrefix("rsync: ") }.prefix(20).map {
            String($0.dropFirst("rsync: ".count))
        }
    }

    /// A plain-language reason for an rsync failure.
    static func explain(_ r: Command.Result) -> String {
        let err = r.stderr.lowercased()
        if err.contains("no space left") { return "The NAS is full." }
        if err.contains("permission denied (publickey") { return "The NAS refused the SSH login." }
        if [12, 30, 35, 255].contains(r.status) || err.contains("connection") { return "Lost the connection to the NAS." }
        return r.stderr.split(separator: "\n").first { !$0.isEmpty }.map(String.init) ?? "rsync stopped (exit \(r.status))."
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HHmmss"
        return f
    }()
}

