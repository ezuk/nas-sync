import Foundation
import Network
import Observation

/// A one-shot cancel switch shared with background work.
public final class CancelFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// Prevents the app and the command-line tool from running the same job at once.
public final class JobLock: @unchecked Sendable {
    private let fd: Int32

    public init?(job: String) {
        let dir = Store.defaultDirectory().appending(path: "locks")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = job.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let path = dir.appending(path: String(safe) + ".lock").path(percentEncoded: false)
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        self.fd = fd
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// Something worth a notification.
public struct Notice: Sendable, Equatable {
    public var id: String
    public var title: String
    public var body: String

    public init(id: String, title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }
}

/// Decides when to sync and runs the jobs. Lives on the main actor; heavy work runs in the background.
@MainActor @Observable
public final class Engine {
    public private(set) var status: StatusSnapshot
    public private(set) var config: AppConfig?
    public private(set) var configIssues: [ConfigIssue] = []
    /// Bumped whenever a run is saved, so history views can refresh.
    public private(set) var historyVersion = 0

    @ObservationIgnored public var onNotice: ((Notice) -> Void)?
    /// Set by the app from CoreLocation.
    public var locationAllowed = false { didSet { if oldValue != locationAllowed { evaluate() } } }
    public var notificationsAllowed = true { didSet { status.notificationsAllowed = notificationsAllowed } }

    public let configURL: URL
    public let store: Store
    @ObservationIgnored private let statusURL: URL
    @ObservationIgnored private var watchers: [String: FolderWatcher] = [:]
    @ObservationIgnored private var pending: [String: (scope: FolderSync.Scope, eventID: UInt64, count: Int)] = [:]
    @ObservationIgnored private var running: [String: CancelFlag] = [:]
    @ObservationIgnored private var progress: [String: JobProgress] = [:]
    @ObservationIgnored private var lastRuns: [String: RunRecord] = [:]
    @ObservationIgnored private var runAnywayOnce: Set<String> = []
    @ObservationIgnored private var allowDeleteOnce: Set<String> = []
    @ObservationIgnored private var mountedByApp = false
    @ObservationIgnored private var mounting = false
    @ObservationIgnored private var mountFailures = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var configSource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var configReload: DispatchWorkItem?
    @ObservationIgnored private var health: [String: JobStatus.State] = [:]
    @ObservationIgnored private var mountHealthy = true
    @ObservationIgnored private var awaySince: Date?
    @ObservationIgnored private var lastStatusData = Data()
    @ObservationIgnored private let started = Date()
    @ObservationIgnored private var evaluateScheduled = false

    public static let githubJob = StoreKey.githubJob

    public var lastGitHubRun: RunRecord? { lastRuns[Self.githubJob] }
    static let mountRetry: TimeInterval = 300

    public init(configURL: URL = ConfigLoader.defaultURL(), store: Store) {
        self.configURL = configURL
        self.store = store
        statusURL = SnapshotPaths.statusURL(store: store)
        status = .initial(configPath: configURL.path(percentEncoded: false))
        if let until = store.date("pausedUntil"), until > Date() { status.pausedUntil = until }
        status.github = nil
        for run in (try? store.recentRuns(limit: 200)) ?? [] where lastRuns[run.job] == nil && run.kind != .away && run.kind != .mount {
            lastRuns[run.job] = run
        }
        if let since = store.date("awaySince") { awaySince = since }
    }

    // MARK: Lifecycle

    public func start() {
        reloadConfig()
        watchConfigFile()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.scheduleEvaluate(after: 2) }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        evaluate()
    }

    public func stop() {
        timer?.invalidate()
        pathMonitor?.cancel()
        configSource?.cancel()
        for w in watchers.values { w.stop() }
        for flag in running.values { flag.cancel() }
    }

    /// Call after the Mac wakes from sleep.
    public func systemDidWake() { scheduleEvaluate(after: 5) }

    private func scheduleEvaluate(after delay: TimeInterval) {
        guard !evaluateScheduled else { return }
        evaluateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                self?.evaluateScheduled = false
                self?.evaluate()
            }
        }
    }

    // MARK: Config

    public func reloadConfig() {
        let result = ConfigLoader.load(from: configURL)
        configIssues = result.issues
        status.configIssues = result.issues.map(\.description)
        if result.isValid, let new = result.config {
            apply(new)
            status.configValid = true
            status.usingLastGoodConfig = false
        } else {
            status.configValid = false
            status.usingLastGoodConfig = config != nil
        }
        evaluate()
    }

    private func apply(_ new: AppConfig) {
        let old = config
        config = new
        status.homeWiFi = new.home.wifi
        status.holdBelowPercent = new.battery.holdBelowPercent
        let names = Set(new.folders.map(\.name))
        for (name, w) in watchers where !names.contains(name) || old?.folders.first(where: { $0.name == name }) != new.folders.first(where: { $0.name == name }) {
            w.stop()
            watchers[name] = nil
        }
        for job in new.folders where watchers[job.name] == nil {
            startWatcher(job)
        }
    }

    private func startWatcher(_ job: FolderJobConfig) {
        let name = job.name
        let watcher = FolderWatcher(source: job.source, quietPeriod: job.quietPeriod.seconds) { [weak self] changes in
            Task { @MainActor in self?.received(changes, for: name) }
        }
        watchers[name] = watcher
        let source = FolderWatcher.eventSourceID(for: job.source)
        let savedSource = store.value(StoreKey.eventSource(name))
        let cursor = store.value(StoreKey.eventCursor(name)).flatMap(UInt64.init)
        if let cursor, source != nil, source == savedSource {
            watcher.start(since: cursor)
        } else {
            watcher.start(since: nil)
            queue(name, scope: .full, eventID: FolderWatcher.currentEventID)
        }
    }

    private func watchConfigFile() {
        let dir = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path(percentEncoded: false), O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.configReload?.cancel()
                let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reloadConfig() } }
                self.configReload = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configSource = source
    }

    // MARK: Changes

    private func received(_ changes: FolderWatcher.Changes, for job: String) {
        queue(job, scope: changes.scope, eventID: changes.eventID, count: 1)
        evaluate()
    }

    private func queue(_ job: String, scope: FolderSync.Scope, eventID: UInt64, count: Int = 0) {
        var entry = pending[job] ?? (scope: .directories([:]), eventID: 0, count: 0)
        entry.scope = Self.merge(entry.scope, scope)
        entry.eventID = max(entry.eventID, eventID)
        entry.count += count
        pending[job] = entry
    }

    static func merge(_ a: FolderSync.Scope, _ b: FolderSync.Scope) -> FolderSync.Scope {
        switch (a, b) {
        case (.full, _), (_, .full): return .full
        case (.directories(let x), .directories(let y)): return .directories(x.merging(y) { $0 || $1 })
        }
    }

    // MARK: User actions

    public func syncFoldersNow() {
        guard let config else { return }
        for job in config.folders { queue(job.name, scope: .full, eventID: FolderWatcher.currentEventID) }
        runAnywayOnce.formUnion(config.folders.map(\.name))
        evaluate()
    }

    public func backUpReposNow() {
        store.setValue("1", for: "githubRequested")
        runAnywayOnce.insert(Self.githubJob)
        evaluate()
    }

    public func runAnyway() {
        runAnywayOnce.formUnion(status.jobs.filter { $0.state == .holdingOff }.map(\.name))
        evaluate()
    }

    public func allowMassDelete(job: String) {
        allowDeleteOnce.insert(job)
        queue(job, scope: .full, eventID: FolderWatcher.currentEventID)
        evaluate()
    }

    public func stop(job: String? = nil) {
        for (name, flag) in running where job == nil || job == name { flag.cancel() }
    }

    public func pause(for interval: TimeInterval?) {
        let until = interval.map { Date().addingTimeInterval($0) } ?? Date.distantFuture
        status.pausedUntil = until
        store.setDate(until, for: "pausedUntil")
        stop()
        evaluate()
    }

    public func resume() {
        status.pausedUntil = nil
        store.setDate(nil, for: "pausedUntil")
        evaluate()
    }

    public func retryMount() {
        mountFailures = 0
        status.lastMountAttempt = nil
        evaluate()
    }

    public func dismissNewRepos() {
        store.setValue(nil, for: "newRepos")
        status.github?.newRepos = []
    }

    // MARK: Evaluation

    /// Looks at the world and starts whatever is due. Cheap; called often.
    public func evaluate() {
        let now = Date()
        if let until = status.pausedUntil, until <= now { resume(); return }
        let power = PowerState.current()
        status.onBattery = power.onBattery
        status.batteryPercent = power.percent
        status.locationAllowed = locationAllowed
        status.wifiName = WiFi.currentName()
        let isHome = config.map { status.wifiName == $0.home.wifi } ?? false
        trackAway(isHome: isHome, now: now)
        status.isHome = isHome

        if let config, let mounted = NASMount.find(config.nas) {
            if !status.nasMounted { mountRecovered(now: now) }
            status.nasMounted = true
            status.mountPoint = mounted.mountPoint.path(percentEncoded: false)
        } else {
            status.nasMounted = false
            status.mountPoint = nil
            if let config, isHome, status.pausedUntil == nil { mountIfNeeded(config, now: now) }
        }
        if !isHome, mountedByApp, config?.nas.unmountWhenAway == true, let config, let m = NASMount.find(config.nas) {
            if NASMount.unmount(m) { mountedByApp = false }
        }
        if !isHome { status.mountError = nil; status.mountSteps = [] }

        if let config, isHome, status.nasMounted, status.pausedUntil == nil, let mountPoint = status.mountPoint {
            startDueJobs(config, mountPoint: URL(filePath: mountPoint, directoryHint: .isDirectory), power: power, now: now)
        }
        refreshJobs(now: now, power: power)
        publish()
    }

    private func trackAway(isHome: Bool, now: Date) {
        guard config != nil, locationAllowed else { return }
        if !isHome, awaySince == nil {
            awaySince = now
            store.setDate(now, for: "awaySince")
        } else if isHome, let since = awaySince {
            awaySince = nil
            store.setDate(nil, for: "awaySince")
            if now.timeIntervalSince(since) > 600 {
                let run = RunRecord(kind: .away, job: "", trigger: "wifi", started: since, finished: now, outcome: .success,
                                    summary: "Not on home Wi-Fi, nothing attempted")
                _ = try? store.saveRun(run)
                historyVersion += 1
            }
        }
    }

    private func mountIfNeeded(_ config: AppConfig, now: Date) {
        guard !mounting else { return }
        if let last = status.lastMountAttempt, status.mountError != nil, now.timeIntervalSince(last) < Self.mountRetry { return }
        mounting = true
        status.lastMountAttempt = now
        let nas = config.nas, wifi = status.wifiName, home = config.home.wifi
        Task.detached(priority: .utility) { [weak self] in
            let result = NASMount.mount(nas)
            let steps: [NASMount.Step]
            if case .failure = result { steps = NASMount.diagnose(nas, wifiName: wifi, homeWiFi: home) } else { steps = [] }
            await MainActor.run { self?.mountFinished(result, steps: steps) }
        }
    }

    private func mountFinished(_ result: Result<NASMount.Mounted, NASMount.Failure>, steps: [NASMount.Step]) {
        mounting = false
        switch result {
        case .success:
            mountedByApp = true
            mountRecovered(now: Date())
        case .failure(let f):
            mountFailures += 1
            // The checklist's own mount attempt may have succeeded.
            if steps.last?.state == .ok {
                mountedByApp = true
                mountRecovered(now: Date())
                break
            }
            status.mountError = f.description
            status.mountSteps = steps + [NASMount.Step(title: "Sync skipped", state: .skipped, detail: nil)]
            if mountHealthy {
                mountHealthy = false
                let run = RunRecord(kind: .mount, job: "", trigger: "mount", started: Date(), finished: Date(), outcome: .failed,
                                    summary: "Couldn't mount the NAS", message: f.description)
                _ = try? store.saveRun(run)
                historyVersion += 1
                let last = status.jobs.compactMap(\.lastSuccess).max()
                notify("mount", "Can't reach the NAS", "\(f.description) Nothing backed up since \(last.map { StatusText.dayAndTime($0) } ?? "the app started").")
            }
        }
        evaluate()
    }

    private func mountRecovered(now: Date) {
        status.mountError = nil
        status.mountSteps = []
        mountFailures = 0
        if !mountHealthy {
            mountHealthy = true
            let waiting = pending.values.reduce(0) { $0 + $1.count }
            notify("mount", "Backups are running again", waiting > 0 ? "Catching up \(Format.count(waiting, "change"))." : "The NAS is reachable again.")
            _ = try? store.saveRun(RunRecord(kind: .mount, job: "", trigger: "mount", started: now, finished: now, outcome: .success, summary: "NAS mounted again"))
            historyVersion += 1
        }
    }

    private func startDueJobs(_ config: AppConfig, mountPoint: URL, power: PowerState, now: Date) {
        // The destination must really be on the share, not a stale folder under /Volumes.
        guard NASMount.isOnShare(mountPoint, config: config.nas) else {
            status.mountError = "The NAS folder isn't on the expected network share."
            return
        }
        for job in config.folders where running[job.name] == nil {
            let nightly = config.folderDefaults.nightlyCheck.lastOccurrence(atOrBefore: now)
            if (store.date(StoreKey.lastFullCheck(job.name)) ?? .distantPast) < nightly, now.timeIntervalSince(started) > 60 || pending[job.name] == nil {
                queue(job.name, scope: .full, eventID: FolderWatcher.currentEventID)
            }
            guard let entry = pending[job.name] else { continue }
            if case .directories(let d) = entry.scope, d.isEmpty { pending[job.name] = nil; continue }
            guard batteryAllows(job.name, power: power, now: now) else { continue }
            pending[job.name] = nil
            runFolder(job, mountPoint: mountPoint, scope: entry.scope, eventID: entry.eventID,
                      trigger: entry.scope == .full ? (runAnywayOnce.contains(job.name) ? "manual" : "full check") : "changes")
        }
        if let gh = config.github, running[Self.githubJob] == nil {
            let requested = store.value("githubRequested") != nil
            let last = store.date(StoreKey.lastSuccess(Self.githubJob))
            let lastAttempt = store.date(StoreKey.lastAttempt(Self.githubJob))
            let failedRecently = lastAttempt.map { now.timeIntervalSince($0) < 3600 && (last ?? .distantPast) < $0 } ?? false
            let due = Schedule.isDue(lastSuccess: last, every: gh.every, around: gh.around, now: now) && !failedRecently
            if requested || due, batteryAllows(Self.githubJob, power: power, now: now) {
                store.setValue(nil, for: "githubRequested")
                runGitHub(gh, mountPoint: mountPoint, trigger: requested ? "manual" : "scheduled (every \(gh.every))")
            }
        }
    }

    private func batteryAllows(_ job: String, power: PowerState, now: Date) -> Bool {
        if runAnywayOnce.contains(job) { return true }
        guard let config else { return true }
        let decision = BatteryRule.decide(power: power, lastSuccess: store.date(StoreKey.lastSuccess(job)), config: config.battery, now: now)
        return decision == .run
    }

    // MARK: Running

    private func runFolder(_ job: FolderJobConfig, mountPoint: URL, scope: FolderSync.Scope, eventID: UInt64, trigger: String) {
        let flag = CancelFlag()
        running[job.name] = flag
        runAnywayOnce.remove(job.name)
        let allowDelete = allowDeleteOnce.remove(job.name) != nil
        let store = self.store
        let name = job.name
        progress[name] = JobProgress(done: 0, total: 0, bytesDone: 0, bytesTotal: 0, current: "", step: nil, changedSoFar: nil, started: Date())
        let options = FolderRunner.Options(trigger: trigger, scope: scope, allowMassDelete: allowDelete,
                                           eventID: eventID, eventSource: FolderWatcher.eventSourceID(for: job.source))
        let startedAt = Date()
        evaluateSoon()
        Task.detached(priority: .utility) { [weak self] in
            guard let lock = JobLock(job: name) else {
                await MainActor.run { self?.finished(name, record: nil, requeue: scope) }
                return
            }
            let record = FolderRunner.run(job: job, nasRoot: mountPoint, store: store, options: options, isCancelled: { flag.isCancelled }) { p in
                let jp = JobProgress(done: p.done, total: p.total, bytesDone: p.bytesDone, bytesTotal: p.bytesTotal, current: p.current,
                                     step: nil, changedSoFar: nil, started: startedAt)
                Task { @MainActor in self?.progress[name] = jp; self?.publishThrottled() }
            }
            _ = lock
            let ok = record.outcome == .success || record.outcome == .warning
            await MainActor.run { self?.finished(name, record: record, requeue: ok ? nil : scope) }
        }
    }

    private func runGitHub(_ gh: GitHubConfig, mountPoint: URL, trigger: String) {
        let flag = CancelFlag()
        let name = Self.githubJob
        running[name] = flag
        runAnywayOnce.remove(name)
        let store = self.store
        let destination = mountPoint.appending(path: gh.dest)
        let startedAt = Date()
        store.setDate(startedAt, for: StoreKey.lastAttempt(name))
        progress[name] = JobProgress(done: 0, total: 0, bytesDone: 0, bytesTotal: 0, current: "Finding repos", step: "check", changedSoFar: 0, started: startedAt)
        evaluateSoon()
        Task.detached(priority: .utility) { [weak self] in
            guard let lock = JobLock(job: name) else {
                await MainActor.run { self?.finished(name, record: nil, requeue: nil) }
                return
            }
            let changed = LockedBox(0)
            let backup = GitHubBackup(config: gh, destination: destination, store: store)
            let result = backup.run(trigger: trigger, isCancelled: { flag.isCancelled }) { p in
                let jp = JobProgress(done: p.index, total: p.total, bytesDone: 0, bytesTotal: 0, current: p.repo,
                                     step: p.step.rawValue, changedSoFar: changed.get(), started: startedAt)
                Task { @MainActor in self?.progress[name] = jp; self?.publishThrottled() }
            } repoFinished: { r in
                if r.action == .backedUp { changed.set(changed.get() + 1) }
            }
            _ = lock
            var record = result.record
            if let id = try? store.saveRun(record) { record.id = id }
            if record.outcome == .success || record.outcome == .warning { store.setDate(record.started, for: StoreKey.lastSuccess(name)) }
            store.setValue(record.outcome.rawValue, for: StoreKey.lastResult(name))
            if !result.newRepos.isEmpty {
                let existing = store.value("newRepos")?.split(separator: "\n").map(String.init) ?? []
                store.setValue((existing + result.newRepos).joined(separator: "\n"), for: "newRepos")
            }
            await MainActor.run { self?.finished(name, record: record, requeue: nil) }
        }
    }

    private func finished(_ job: String, record: RunRecord?, requeue: FolderSync.Scope?) {
        running[job] = nil
        progress[job] = nil
        if let record {
            lastRuns[job] = record
            historyVersion += 1
            if record.kind == .github, record.counts.failed > 0 {
                notify("github-run-\(record.started.timeIntervalSince1970)", "\(Format.count(record.counts.failed, "repo")) failed to back up",
                       record.message ?? "Open Activity for details.")
            }
        }
        if let requeue, record?.outcome != .blocked, record?.outcome != .cancelled {
            queue(job, scope: requeue, eventID: 0)
        }
        evaluate()
    }

    private func evaluateSoon() {
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.refreshJobs(now: Date(), power: nil); self?.publish() } }
    }

    @ObservationIgnored private var lastThrottledPublish = Date.distantPast

    private func publishThrottled() {
        guard Date().timeIntervalSince(lastThrottledPublish) > 0.25 else { return }
        lastThrottledPublish = Date()
        refreshJobs(now: Date(), power: nil)
        publish()
    }

    // MARK: Status

    private func refreshJobs(now: Date, power: PowerState?) {
        guard let config else {
            status.jobs = []
            status.state = status.configIssues.isEmpty ? .starting : .error
            return
        }
        let power = power ?? PowerState(onBattery: status.onBattery, percent: status.batteryPercent)
        var jobs: [JobStatus] = []
        for job in config.folders {
            jobs.append(jobStatus(name: job.name, kind: .folder, staleAfter: job.staleAfter.seconds, power: power, now: now))
        }
        if let gh = config.github {
            var j = jobStatus(name: Self.githubJob, kind: .github, staleAfter: gh.staleAfter.seconds, power: power, now: now)
            j.nextRun = Schedule.nextDue(lastSuccess: j.lastSuccess, every: gh.every, around: gh.around, now: now)
            jobs.append(j)
            let repos = store.repos()
            let newRepos = store.value("newRepos")?.split(separator: "\n").map(String.init) ?? []
            status.github = GitHubSummary(
                repoCount: repos.filter { $0.status != .excluded }.count,
                localClones: repos.filter { $0.source == .localClone && $0.status != .excluded }.count,
                remoteOnly: repos.filter { $0.source == .remoteOnly && $0.status != .excluded }.count,
                problems: repos.filter { [.failed, .missingLocally, .goneFromGitHub].contains($0.status) }.count,
                excluded: repos.filter { $0.status == .excluded }.count,
                every: gh.every.seconds, newRepos: newRepos)
        } else {
            status.github = nil
        }
        status.jobs = jobs
        for j in jobs { noteHealth(j) }
        status.state = overall(now: now)
    }

    private func jobStatus(name: String, kind: JobStatus.Kind, staleAfter: TimeInterval, power: PowerState, now: Date) -> JobStatus {
        let last = lastRuns[name]
        let lastSuccess = store.date(StoreKey.lastSuccess(name))
        let entry = pending[name]
        var j = JobStatus(name: name, kind: kind, state: .idle, lastSuccess: lastSuccess, lastSummary: last?.summary, lastOutcome: last?.outcome,
                          message: nil, waitingChanges: entry?.count ?? 0, fileCount: store.int(StoreKey.sourceFileCount(name)),
                          progress: progress[name], nextRun: nil, holdUntil: nil, needsDeleteConfirmation: false, staleAfter: staleAfter)
        if let config, case .holdOff(_, let until) = BatteryRule.decide(power: power, lastSuccess: lastSuccess, config: config.battery, now: now),
           !runAnywayOnce.contains(name) {
            j.holdUntil = until
        }
        let githubDue = kind == .github && config?.github.map {
            Schedule.isDue(lastSuccess: lastSuccess, every: $0.every, around: $0.around, now: now)
        } == true
        let hasWork = kind == .folder ? entry != nil : githubDue

        if running[name] != nil {
            j.state = .running
        } else if status.pausedUntil != nil {
            j.state = .paused
        } else if !status.isHome {
            j.state = .away
        } else if let last, last.outcome == .failed || last.outcome == .blocked {
            j.state = .error
            j.message = last.message ?? last.summary
            if case .blocked = last.outcome, last.summary.hasPrefix("Stopped:") { j.needsDeleteConfirmation = true }
        } else if hasWork, j.holdUntil != nil {
            j.state = .holdingOff
        } else if let ls = lastSuccess, now.timeIntervalSince(ls) > staleAfter {
            j.state = .stale
            j.message = "No successful backup in \(Format.count(Int(now.timeIntervalSince(ls) / 3600), "hour"))"
        } else if lastSuccess == nil, now.timeIntervalSince(started) > staleAfter {
            j.state = .stale
        } else if hasWork {
            j.state = .queued
        } else if kind == .github, let last, last.outcome == .warning {
            j.state = .error
            j.message = last.summary
        }
        if status.nasMounted == false, status.isHome, status.mountError != nil, j.state != .running { j.state = .error; j.message = status.mountError }
        return j
    }

    private func overall(now: Date) -> OverallState {
        if !status.configValid, !status.usingLastGoodConfig { return .error }
        if status.pausedUntil != nil { return .paused }
        if !status.isHome { return .away }
        let states = status.jobs.map(\.state)
        if status.mountError != nil || states.contains(.error) { return .error }
        if states.contains(.stale) { return .stale }
        if states.contains(.running) { return .syncing }
        if states.contains(.holdingOff) { return .holdingOff }
        return .upToDate
    }

    private func noteHealth(_ j: JobStatus) {
        let old = health[j.name]
        let new: JobStatus.State = j.state == .error || j.state == .stale ? j.state : .idle
        health[j.name] = new
        guard let old, old != new, status.mountError == nil else { return }
        switch new {
        case .error:
            notify("job-\(j.name)", "\(j.name) needs attention", j.message ?? "Open NAS Sync for details.")
        case .stale:
            notify("job-\(j.name)", "No backup in \(Format.count(Int(Date().timeIntervalSince(j.lastSuccess ?? started) / 3600), "hour"))",
                   "You've been home on “\(status.homeWiFi ?? "")”, but \(j.name) hasn't completed a backup. Open for details.")
        default:
            if old == .error { notify("job-\(j.name)", "\(j.name) is backing up again", j.lastSummary ?? "Back to normal.") }
        }
    }

    private func notify(_ id: String, _ title: String, _ body: String) {
        onNotice?(Notice(id: id, title: title, body: body))
    }

    private func publish() {
        status.updated = Date()
        var copy = status
        copy.updated = Date(timeIntervalSince1970: 0)
        let data = copy.jsonData()
        guard data != lastStatusData else { return }
        lastStatusData = data
        let out = status.jsonData()
        let url = statusURL
        DispatchQueue.global(qos: .utility).async { try? out.write(to: url, options: .atomic) }
    }
}

enum SnapshotPaths {
    static func statusURL(store: Store) -> URL { store.directory.appending(path: "status.json") }
}
