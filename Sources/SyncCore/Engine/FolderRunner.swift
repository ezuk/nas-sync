import Foundation

/// Runs one folder job end to end and records the result.
public enum FolderRunner {
    public struct Options: Sendable {
        public var trigger: String
        public var scope: FolderSync.Scope
        public var dryRun = false
        /// Skips the mass-delete guard once, after the user confirmed.
        public var allowMassDelete = false
        /// Event ID to save as the watcher cursor when the run succeeds.
        public var eventID: UInt64?
        public var eventSource: String?

        public init(trigger: String, scope: FolderSync.Scope, dryRun: Bool = false, allowMassDelete: Bool = false, eventID: UInt64? = nil, eventSource: String? = nil) {
            self.trigger = trigger
            self.scope = scope
            self.dryRun = dryRun
            self.allowMassDelete = allowMassDelete
            self.eventID = eventID
            self.eventSource = eventSource
        }
    }

    public static func run(
        job: FolderJobConfig, nasRoot: URL, store: Store, options: Options, now: Date = Date(),
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: @escaping @Sendable (FolderSync.Progress) -> Void = { _ in }
    ) -> RunRecord {
        var record = RunRecord(kind: options.scope == .full ? .check : .folder, job: job.name,
                               trigger: options.dryRun ? "\(options.trigger), dry run" : options.trigger, started: now)
        let sync = FolderSync(job: job, shareRoot: nasRoot)
        if !options.dryRun { store.setDate(now, for: StoreKey.lastAttempt(job.name)) }

        let plan: FolderSync.Plan
        do {
            plan = try sync.plan(scope: options.scope, isCancelled: isCancelled)
            if !options.allowMassDelete {
                try sync.checkMassDelete(plan, knownDestFileCount: store.int(StoreKey.destFileCount(job.name)))
            }
        } catch let error as FolderSync.GuardError {
            record.outcome = .blocked
            record.summary = summary(for: error)
            record.message = error.description
            return finish(record, store: store, dryRun: options.dryRun)
        } catch {
            record.outcome = isCancelled() ? .cancelled : .failed
            record.summary = isCancelled() ? "Cancelled" : "Couldn't compare folders"
            record.message = error.localizedDescription
            return finish(record, store: store, dryRun: options.dryRun)
        }

        if options.dryRun {
            record.counts.total = plan.sourceFileCount
            for action in plan.actions {
                switch action {
                case .copy(let e, let replacing):
                    if replacing == nil { record.counts.new += 1 } else { record.counts.changed += 1 }
                    record.counts.bytes += e.size
                    record.items.append(RunItem(action: replacing == nil ? .new : .changed, path: e.relativePath, size: e.size))
                case .archive(let e, let files, let bytes):
                    record.counts.archived += files
                    record.items.append(RunItem(action: .archived, path: e.relativePath, size: bytes))
                case .makeDirectory:
                    break
                }
            }
            record.summary = describe(record.counts, dryRun: true)
            return finish(record, store: store, dryRun: true)
        }

        let out = sync.execute(plan, now: now, isCancelled: isCancelled, progress: progress)
        record.counts = out.counts
        record.items = out.items
        let lastPrune = store.date("lastArchivePrune.\(job.name)") ?? .distantPast
        if now.timeIntervalSince(lastPrune) > 86400 {
            let pruned = sync.pruneArchive(now: now)
            record.items += pruned
            record.counts.pruned += pruned.count
            store.setDate(now, for: "lastArchivePrune.\(job.name)")
        }
        if let fatal = out.fatalError {
            record.outcome = .failed
            record.message = fatal
            record.summary = "Stopped: " + describe(out.counts, dryRun: false)
        } else if isCancelled() {
            record.outcome = .cancelled
            record.summary = "Cancelled after " + describe(out.counts, dryRun: false)
        } else {
            record.outcome = out.counts.failed > 0 || out.counts.skipped > 0 ? .warning : .success
            record.summary = describe(out.counts, dryRun: false)
            if out.counts.failed > 0 {
                record.message = out.items.filter { $0.action == .failed }.prefix(3)
                    .map { "\($0.path): \($0.detail ?? "failed")" }.joined(separator: "\n")
            }
        }
        if record.outcome == .success || record.outcome == .warning {
            store.setDate(now, for: StoreKey.lastSuccess(job.name))
            if plan.isFull {
                store.setInt(plan.sourceFileCount, for: StoreKey.sourceFileCount(job.name))
                store.setInt(plan.sourceFileCount, for: StoreKey.destFileCount(job.name))
                store.setDate(now, for: StoreKey.lastFullCheck(job.name))
            } else if let known = store.int(StoreKey.destFileCount(job.name)) {
                store.setInt(max(0, known + out.counts.new - out.counts.archived), for: StoreKey.destFileCount(job.name))
            }
            if let id = options.eventID { store.setValue(String(id), for: StoreKey.eventCursor(job.name)) }
            if let src = options.eventSource { store.setValue(src, for: StoreKey.eventSource(job.name)) }
        }
        return finish(record, store: store, dryRun: false)
    }

    private static func finish(_ record: RunRecord, store: Store, dryRun: Bool) -> RunRecord {
        var r = record
        r.finished = Date()
        if !dryRun {
            store.setValue(r.outcome.rawValue, for: StoreKey.lastResult(r.job))
            // Quiet change-driven runs with nothing to do don't need a history row.
            let nothing = r.outcome == .success && r.counts.copied == 0 && r.counts.archived == 0 && r.counts.pruned == 0 && r.kind == .folder
            if !nothing, let id = try? store.saveRun(r) { r.id = id }
        }
        return r
    }

    static func summary(for error: FolderSync.GuardError) -> String {
        switch error {
        case .sourceMissing: "Source folder missing"
        case .sourceEmpty: "Source folder is empty"
        case .destinationMissing: "NAS folder missing"
        case .destinationIsShareRoot: "Destination is the whole share"
        case .massDelete(let files, _): "Stopped: \(Format.count(files, "file")) would be archived"
        }
    }

    public static func describe(_ c: RunCounts, dryRun: Bool) -> String {
        var parts: [String] = []
        let verb = dryRun ? "would be " : ""
        if c.copied > 0 { parts.append("\(Format.count(c.copied, "file")) \(verb)copied (\(Format.bytes(c.bytes)))") }
        if c.archived > 0 { parts.append("\(c.archived.formatted()) \(verb)archived") }
        if c.failed > 0 { parts.append("\(c.failed.formatted()) failed") }
        if c.skipped > 0 { parts.append("\(c.skipped.formatted()) skipped") }
        if c.pruned > 0 { parts.append(Format.count(c.pruned, "old archive folder") + " removed") }
        return parts.isEmpty ? "Nothing to copy" : parts.joined(separator: ", ")
    }
}
