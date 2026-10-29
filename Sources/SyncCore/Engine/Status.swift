import Foundation

/// The app's overall state, shown by the menu bar icon and the popover headline.
public enum OverallState: String, Sendable, Codable {
    case starting, upToDate, syncing, away, holdingOff, paused, stale, error
}

public struct JobProgress: Sendable, Codable, Equatable {
    public var done: Int
    public var total: Int
    public var bytesDone: Int64
    public var bytesTotal: Int64
    /// File being copied, or repo being backed up.
    public var current: String
    /// GitHub: the pipeline step of the current repo. Folders: comparing or copying.
    public var step: String?
    /// GitHub only: repos that needed a new archive so far.
    public var changedSoFar: Int?
    public var started: Date

    public init(done: Int, total: Int, bytesDone: Int64, bytesTotal: Int64, current: String, step: String?, changedSoFar: Int?, started: Date) {
        self.done = done
        self.total = total
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.current = current
        self.step = step
        self.changedSoFar = changedSoFar
        self.started = started
    }

    public var fraction: Double {
        if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
        if total > 0 { return min(1, Double(done) / Double(total)) }
        return 0
    }

    /// False while there's nothing to measure yet, such as while comparing with the NAS.
    public var hasFraction: Bool {
        total > 0 || bytesTotal > 0
    }
}

public struct JobStatus: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable { case folder, github }
    public enum State: String, Sendable, Codable {
        case idle, queued, running, away, holdingOff, paused, stale, error
    }

    public var name: String
    public var kind: Kind
    public var state: State
    public var lastSuccess: Date?
    public var lastSummary: String?
    public var lastOutcome: RunOutcome?
    /// Problem shown on the job row, in plain language.
    public var message: String?
    /// Folder: change events not yet synced.
    public var waitingChanges: Int
    /// Folder: files in the source at the last full check.
    public var fileCount: Int?
    public var progress: JobProgress?
    public var nextRun: Date?
    public var holdUntil: Date?
    /// The mass-delete guard stopped the last run; the user can allow it once.
    public var needsDeleteConfirmation: Bool
    public var staleAfter: TimeInterval

    public init(name: String, kind: Kind, state: State, lastSuccess: Date?, lastSummary: String?, lastOutcome: RunOutcome?, message: String?, waitingChanges: Int, fileCount: Int?, progress: JobProgress?, nextRun: Date?, holdUntil: Date?, needsDeleteConfirmation: Bool, staleAfter: TimeInterval) {
        self.name = name
        self.kind = kind
        self.state = state
        self.lastSuccess = lastSuccess
        self.lastSummary = lastSummary
        self.lastOutcome = lastOutcome
        self.message = message
        self.waitingChanges = waitingChanges
        self.fileCount = fileCount
        self.progress = progress
        self.nextRun = nextRun
        self.holdUntil = holdUntil
        self.needsDeleteConfirmation = needsDeleteConfirmation
        self.staleAfter = staleAfter
    }

    public var id: String { name }
}

public struct GitHubSummary: Sendable, Codable, Equatable {
    public var repoCount: Int
    public var localClones: Int
    public var remoteOnly: Int
    public var problems: Int
    public var excluded: Int
    public var every: TimeInterval
    /// Repos found since the last time the user dismissed the note.
    public var newRepos: [String]

    public init(repoCount: Int, localClones: Int, remoteOnly: Int, problems: Int, excluded: Int, every: TimeInterval, newRepos: [String]) {
        self.repoCount = repoCount
        self.localClones = localClones
        self.remoteOnly = remoteOnly
        self.problems = problems
        self.excluded = excluded
        self.every = every
        self.newRepos = newRepos
    }
}

public struct StatusSnapshot: Sendable, Codable, Equatable {
    public var state: OverallState
    public var wifiName: String?
    public var homeWiFi: String?
    public var isHome: Bool
    public var locationAllowed: Bool
    public var nasConnected: Bool
    /// `user@host:/path`, or a local path.
    public var nasLocation: String?
    public var connectSteps: [NASCheck.Step]
    public var connectError: String?
    public var lastConnectCheck: Date?
    public var onBattery: Bool
    public var batteryPercent: Int?
    public var holdBelowPercent: Int
    public var pausedUntil: Date?
    public var configPath: String
    public var configValid: Bool
    public var configIssues: [String]
    /// True when the file has errors but an earlier valid version is still running.
    public var usingLastGoodConfig: Bool
    public var jobs: [JobStatus]
    public var github: GitHubSummary?
    public var notificationsAllowed: Bool
    public var updated: Date

    public static func initial(configPath: String) -> StatusSnapshot {
        StatusSnapshot(state: .starting, wifiName: nil, homeWiFi: nil, isHome: false, locationAllowed: false, nasConnected: false,
                       nasLocation: nil, connectSteps: [], connectError: nil, lastConnectCheck: nil, onBattery: false, batteryPercent: nil,
                       holdBelowPercent: 30, pausedUntil: nil, configPath: configPath, configValid: false, configIssues: [],
                       usingLastGoodConfig: false, jobs: [], github: nil, notificationsAllowed: true, updated: Date())
    }

    public var folderJobs: [JobStatus] { jobs.filter { $0.kind == .folder } }
    public var githubJob: JobStatus? { jobs.first { $0.kind == .github } }
    public var waitingChanges: Int { folderJobs.reduce(0) { $0 + $1.waitingChanges } }
    public var runningJob: JobStatus? { jobs.first { $0.state == .running } }

    public static func fileURL() -> URL { Store.defaultDirectory().appending(path: "status.json") }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public func jsonData() -> Data { (try? Self.encoder.encode(self)) ?? Data() }

    public static func read(from url: URL = fileURL()) -> StatusSnapshot? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? d.decode(StatusSnapshot.self, from: $0) }
    }
}

/// Plain-language headline and details, computed fresh so relative times stay current.
public enum StatusText {
    public struct Headline: Sendable, Equatable {
        public var title: String
        public var detail: String
    }

    public static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let s = now.timeIntervalSince(date)
        if s < 60 { return "just now" }
        if s < 3600 { return Format.count(Int(s / 60), "minute") + " ago" }
        if s < 86400 * 0.75 { return Format.count(Int((s / 3600).rounded()), "hour") + " ago" }
        return inSentence(date, now: now)
    }

    /// Short form for the right column of job rows, like "4 min ago" or "Yesterday 18:02".
    public static func short(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Never" }
        let s = now.timeIntervalSince(date)
        if s < 60 { return "Just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 6 * 3600 { return "\(Int(s / 3600)) hr ago" }
        return dayAndTime(date, now: now)
    }

    /// "24h", "6h", "2d", "30m".
    public static func every(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s % 3600 == 0, s <= 72 * 3600 { return "\(s / 3600)h" }
        if s % 86400 == 0 { return "\(s / 86400)d" }
        return Interval(seconds: seconds).description
    }

    /// dayAndTime for use inside a sentence ("since yesterday 18:02").
    public static func inSentence(_ date: Date, now: Date = Date()) -> String {
        let text = dayAndTime(date, now: now)
        return text.hasPrefix("Yesterday") ? "y" + text.dropFirst() : text
    }

    public static func dayAndTime(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDate(date, inSameDayAs: now) { return time }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "Yesterday \(time)" }
        if now.timeIntervalSince(date) < 6 * 86400 { return date.formatted(.dateTime.weekday(.wide)) + " " + time }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func timeOnly(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? date.formatted(date: .omitted, time: .shortened) : dayAndTime(date, now: now)
    }

    public static func headline(_ s: StatusSnapshot, now: Date = Date()) -> Headline {
        let folders = s.folderJobs
        let gh = s.githubJob
        switch s.state {
        case .starting:
            return Headline(title: "Starting…", detail: "Checking Wi-Fi and the NAS.")
        case .paused:
            let until = s.pausedUntil.map { timeOnly($0, now: now) } ?? "you resume"
            return Headline(title: "Paused until \(until)", detail: "Nothing is copied while paused. Changes are still counted.")
        case .away:
            if !s.locationAllowed {
                return Headline(title: "Location permission needed",
                                detail: "macOS only shares the Wi-Fi name with apps allowed to use Location. Without it, NAS Sync can't tell when you're home.")
            }
            let on = s.wifiName.map { "You're on “\($0)”." } ?? "You're not on Wi-Fi."
            let home = s.homeWiFi.map { " Syncing resumes automatically when you join “\($0)”." } ?? ""
            return Headline(title: "Away from home, not syncing", detail: on + home)
        case .holdingOff:
            let pct = s.batteryPercent.map { "\($0)%" } ?? "low"
            let until = s.jobs.compactMap(\.holdUntil).min()
            let last = s.jobs.compactMap(\.lastSuccess).max()
            var detail = "Last backup \(relative(last, now: now)). Resumes when you plug in, charge reaches \(s.holdBelowPercent)%"
            if let until { detail += ", or at \(timeOnly(until, now: now))" }
            detail += ", whichever comes first."
            return Headline(title: "Holding off: battery at \(pct)", detail: detail)
        case .syncing:
            guard let job = s.runningJob else { return Headline(title: "Syncing", detail: "") }
            let p = job.progress
            if job.kind == .github {
                let detail = p.map { "Checked \($0.done) of \($0.total) · \($0.changedSoFar ?? 0) changed so far" } ?? "Starting"
                return Headline(title: "Backing up GitHub repos", detail: detail)
            }
            guard let p, p.total > 0 else {
                return Headline(title: "Checking \(job.name)", detail: p.flatMap(scanText) ?? "Comparing the folder with the NAS.")
            }
            return Headline(title: "Copying \(job.name) to the NAS",
                            detail: "\(p.done.formatted()) of \(Format.count(p.total, "changed file")) · \(Format.bytes(p.bytesDone)) of \(Format.bytes(p.bytesTotal))")
        case .error:
            if !s.nasConnected, s.connectError != nil {
                let last = s.jobs.compactMap(\.lastSuccess).max()
                return Headline(title: "Can't reach the NAS",
                                detail: "You're home, but the NAS didn't answer. Nothing has been backed up since \(last.map { inSentence($0, now: now) } ?? "the app started").")
            }
            if !s.configValid, !s.usingLastGoodConfig {
                return Headline(title: "The config file has problems", detail: s.configIssues.first ?? "Open Settings to see what's wrong.")
            }
            let bad = s.jobs.filter { $0.state == .error }
            if let first = bad.first {
                let title = bad.count == 1 ? "\(first.name) needs attention" : "\(bad.count) backups need attention"
                return Headline(title: title, detail: first.message ?? first.lastSummary ?? "")
            }
            return Headline(title: "Something needs attention", detail: s.configIssues.first ?? "")
        case .stale:
            let stale = s.jobs.filter { $0.state == .stale }
            let oldest = stale.compactMap(\.lastSuccess).min()
            let hours = oldest.map { Int(now.timeIntervalSince($0) / 3600) }
            let title = hours.map { "No backup in \(Format.count($0, "hour"))" } ?? "No backup yet"
            let names = stale.map(\.name).joined(separator: ", ")
            return Headline(title: title, detail: "You're home, but \(names) hasn't completed a backup. Open Activity for details.")
        case .upToDate:
            let lastFolder = folders.compactMap(\.lastSuccess).max()
            if let gh, !folders.isEmpty {
                let ghText = gh.lastSuccess.map { "GitHub repos \(relativeDay($0, now: now))" } ?? "GitHub repos not backed up yet"
                return Headline(title: "Everything is backed up", detail: "Folders \(relative(lastFolder, now: now)). \(ghText).")
            }
            if let gh {
                return Headline(title: "Repos are backed up", detail: "Last run \(relative(gh.lastSuccess, now: now)).")
            }
            let title = lastFolder.map { "Backed up \(relative($0, now: now))" } ?? "Watching for changes"
            let detail = folders.count == 1 ? "\(folders[0].name) is on the NAS." : "All \(folders.count) folders are on the NAS."
            return Headline(title: title, detail: detail)
        }
    }

    /// "this morning at 03:12", "yesterday at 03:12".
    static func relativeDay(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDate(date, inSameDayAs: now) {
            let h = cal.component(.hour, from: date)
            return (h < 12 ? "this morning" : h < 18 ? "this afternoon" : "this evening") + " at \(time)"
        }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "yesterday at \(time)" }
        return dayAndTime(date, now: now)
    }

    /// "Comparing with the NAS", or nil once copying.
    public static func scanText(_ p: JobProgress) -> String? {
        p.step == "comparing" ? "Comparing with the NAS" : nil
    }

    /// Second line of a job row.
    public static func jobLine(_ j: JobStatus, now: Date = Date(), showElapsed: Bool = true) -> String {
        switch j.state {
        case .running:
            if j.kind == .github, let p = j.progress {
                return "\(p.current) · \(p.step ?? "checking")"
            }
            let started = j.progress.map { Format.duration(now.timeIntervalSince($0.started)) } ?? ""
            if let p = j.progress, let scan = scanText(p) { return showElapsed ? "\(scan) · started \(started) ago" : scan }
            if let p = j.progress, p.total > 0 {
                return "Copying \(p.done.formatted()) of \(Format.count(p.total, "file")) · \(Format.bytes(p.bytesDone)) of \(Format.bytes(p.bytesTotal))"
            }
            return showElapsed ? "Starting… \(started) ago" : "Starting"
        case .queued:
            let next = j.nextRun.map { " · next sync at \(timeOnly($0, now: now))" } ?? ""
            return (j.waitingChanges > 0 ? "Queued, \(Format.count(j.waitingChanges, "change")) seen" : "Queued") + next
        case .away, .paused:
            if j.kind == .github { return j.nextRun.map { $0 <= now ? "Due now" : "Next at \(timeOnly($0, now: now))" } ?? "Waiting" }
            return j.waitingChanges > 0 ? "\(Format.count(j.waitingChanges, "change")) waiting" : "Nothing waiting"
        case .holdingOff:
            return j.kind == .github ? "Due now, waiting for power" : "\(Format.count(j.waitingChanges, "change")) waiting"
        case .error, .stale:
            return j.message ?? j.lastSummary ?? "Needs attention"
        case .idle:
            var line = j.lastSummary ?? "Waiting for the first run"
            if j.kind == .github, let next = j.nextRun { line += " · next at \(timeOnly(next, now: now))" }
            if j.kind == .folder, let n = j.fileCount { line += " · \(Format.count(n, "file"))" }
            return line
        }
    }
}
