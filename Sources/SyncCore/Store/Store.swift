import Foundation

public enum RepoSource: String, Sendable, Codable {
    case localClone
    case remoteOnly
}

public enum RepoStatus: String, Sendable, Codable {
    case ok
    case failed
    /// The local clone disappeared, or the repo is no longer in the config.
    case missingLocally
    /// GitHub says the repository doesn't exist (any more).
    case goneFromGitHub
    case excluded
}

/// What the app remembers about one repo between runs.
///
/// Stored as JSON. Records written by older versions (which kept dated archives) still decode: their archive
/// fields are ignored and the mirror fields start empty.
public struct RepoRecord: Sendable, Codable, Equatable, Identifiable {
    /// `owner/repo`, or the folder name for a clone with no GitHub remote.
    public var fullName: String
    public var source: RepoSource
    public var localPath: String?
    /// Ref name to commit, as of the mirror last copied to the NAS.
    public var refs: [String: String]
    public var fingerprint: String?
    public var lastChangeSeen: Date?
    /// When the mirror on the NAS was last updated.
    public var mirrorUpdated: Date?
    /// Where the mirror is, relative to `<dest>/mirrors` on the NAS, like `acme/app.git`.
    public var mirrorPath: String?
    /// Size of the mirror on the NAS.
    public var sizeOnNAS: Int64?
    /// Refs kept in the mirror after they were deleted or force-pushed at the source, like
    /// `refs/deleted/2026-11-01/heads/fix/x`.
    public var deletedRefsKept: [String]
    /// False for a clone with no GitHub remote: the NAS has the only other copy.
    public var hasGitHubRemote: Bool
    public var status: RepoStatus
    public var message: String?
    public var firstSeen: Date
    public var unpushedCommits: Int?
    public var usesLFS: Bool
    /// True once the NAS helper has handled this repo. Its mirror is then in `mirrors-v2`, and `refs` and
    /// `fingerprint` still describe the app's old mirror.
    public var usesHelper: Bool
    /// The refs this Mac last sent to the helper's mirror.
    public var macFingerprint: String?
    /// Why this Mac couldn't send its work to the helper's mirror.
    public var pushError: String?
    /// What went wrong in the helper's latest run.
    public var helperProblem: String?
    /// GitHub told the helper this repo doesn't exist.
    public var helperGone: Bool

    public var id: String { fullName }

    /// `https://github.com/owner/repo`, when the repo is on GitHub.
    public var githubURL: URL? { hasGitHubRemote ? URL(string: "https://github.com/\(fullName)") : nil }

    public init(fullName: String, source: RepoSource, localPath: String?, firstSeen: Date, hasGitHubRemote: Bool = true) {
        self.fullName = fullName
        self.source = source
        self.localPath = localPath
        refs = [:]
        deletedRefsKept = []
        self.hasGitHubRemote = hasGitHubRemote
        status = .ok
        self.firstSeen = firstSeen
        usesLFS = false
        usesHelper = false
        helperGone = false
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fullName = try c.decode(String.self, forKey: .fullName)
        source = try c.decodeIfPresent(RepoSource.self, forKey: .source) ?? .localClone
        localPath = try c.decodeIfPresent(String.self, forKey: .localPath)
        refs = try c.decodeIfPresent([String: String].self, forKey: .refs) ?? [:]
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint)
        lastChangeSeen = try c.decodeIfPresent(Date.self, forKey: .lastChangeSeen)
        mirrorUpdated = try c.decodeIfPresent(Date.self, forKey: .mirrorUpdated)
        mirrorPath = try c.decodeIfPresent(String.self, forKey: .mirrorPath)
        sizeOnNAS = try c.decodeIfPresent(Int64.self, forKey: .sizeOnNAS)
        deletedRefsKept = try c.decodeIfPresent([String].self, forKey: .deletedRefsKept) ?? []
        hasGitHubRemote = try c.decodeIfPresent(Bool.self, forKey: .hasGitHubRemote) ?? fullName.contains("/")
        status = (try? c.decodeIfPresent(RepoStatus.self, forKey: .status)) ?? .ok
        message = try c.decodeIfPresent(String.self, forKey: .message)
        firstSeen = try c.decodeIfPresent(Date.self, forKey: .firstSeen) ?? Date()
        unpushedCommits = try c.decodeIfPresent(Int.self, forKey: .unpushedCommits)
        usesLFS = try c.decodeIfPresent(Bool.self, forKey: .usesLFS) ?? false
        usesHelper = try c.decodeIfPresent(Bool.self, forKey: .usesHelper) ?? false
        macFingerprint = try c.decodeIfPresent(String.self, forKey: .macFingerprint)
        pushError = try c.decodeIfPresent(String.self, forKey: .pushError)
        helperProblem = try c.decodeIfPresent(String.self, forKey: .helperProblem)
        helperGone = try c.decodeIfPresent(Bool.self, forKey: .helperGone) ?? false
    }

    /// Sets `status` and `message` from what the helper and this Mac last reported.
    mutating func refreshHelperStatus() {
        if helperGone {
            status = .goneFromGitHub
            message = helperProblem ?? "GitHub says this repo doesn't exist any more. The mirror on the NAS is kept."
        } else if let problem = pushError ?? helperProblem {
            status = .failed
            message = problem
        } else {
            status = .ok
            message = nil
        }
    }
}

/// App state and history, kept in SQLite.
public final class Store: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let lock = NSLock()
    public static let maxItemsPerRun = 5000

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "NAS Sync")
    }

    public let directory: URL

    public init(directory: URL = Store.defaultDirectory()) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try SQLiteDatabase(path: directory.appending(path: "state.sqlite").path(percentEncoded: false))
        try migrate()
    }

    private func migrate() throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            job TEXT NOT NULL,
            trigger TEXT NOT NULL,
            started REAL NOT NULL,
            finished REAL,
            outcome TEXT NOT NULL,
            summary TEXT NOT NULL,
            message TEXT,
            counts BLOB NOT NULL,
            items BLOB NOT NULL,
            timings BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS runs_started ON runs(started);
        CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS repos (full_name TEXT PRIMARY KEY, data BLOB NOT NULL);
        """)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    // MARK: Runs

    @discardableResult
    public func saveRun(_ run: RunRecord) throws -> Int64 {
        let items = Array(run.items.prefix(Self.maxItemsPerRun))
        let params: [SQLiteDatabase.Value?] = [
            .text(run.kind.rawValue), .text(run.job), .text(run.trigger),
            .double(run.started.timeIntervalSince1970), run.finished.map { .double($0.timeIntervalSince1970) },
            .text(run.outcome.rawValue), .text(run.summary), run.message.map { .text($0) },
            .blob(try Self.encoder.encode(run.counts)), .blob(try Self.encoder.encode(items)),
            .blob(try Self.encoder.encode(run.stepTimings)),
        ]
        return try locked {
            if let id = run.id {
                try db.run("""
                UPDATE runs SET kind=?, job=?, trigger=?, started=?, finished=?, outcome=?, summary=?, message=?,
                counts=?, items=?, timings=? WHERE id=?
                """, params + [.int(id)])
                return id
            }
            return try db.run("""
            INSERT INTO runs (kind, job, trigger, started, finished, outcome, summary, message, counts, items, timings)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, params)
        }
    }

    /// Recent runs, newest first. Items are only loaded when `withItems` is true.
    /// Saves a helper install or update, unless another check just reported the same one.
    func saveHelperChange(_ run: RunRecord) {
        let recent = (try? recentRuns(limit: 5, kinds: [.helper])) ?? []
        if recent.contains(where: { $0.summary == run.summary && abs($0.started.timeIntervalSince(run.started)) < 300 }) { return }
        _ = try? saveRun(run)
    }

    public func recentRuns(limit: Int = 300, kinds: Set<RunKind>? = nil, withItems: Bool = false) throws -> [RunRecord] {
        let rows = try locked {
            try db.query("SELECT * FROM runs ORDER BY started DESC, id DESC LIMIT ?", [.int(Int64(limit * (kinds == nil ? 1 : 4)))])
        }
        var runs = rows.compactMap { row(toRun: $0, withItems: withItems) }
        if let kinds { runs = runs.filter { kinds.contains($0.kind) } }
        return Array(runs.prefix(limit))
    }

    public func run(id: Int64) throws -> RunRecord? {
        try locked { try db.query("SELECT * FROM runs WHERE id = ?", [.int(id)]) }.first.flatMap { row(toRun: $0, withItems: true) }
    }

    private func row(toRun r: SQLiteDatabase.Row, withItems: Bool) -> RunRecord? {
        guard let kind = r.text("kind").flatMap(RunKind.init), let started = r.double("started"),
              let outcome = r.text("outcome").flatMap(RunOutcome.init) else { return nil }
        return RunRecord(
            id: r.int("id"), kind: kind, job: r.text("job") ?? "", trigger: r.text("trigger") ?? "",
            started: Date(timeIntervalSince1970: started),
            finished: r.double("finished").map(Date.init(timeIntervalSince1970:)),
            outcome: outcome,
            counts: r.blob("counts").flatMap { try? Self.decoder.decode(RunCounts.self, from: $0) } ?? RunCounts(),
            summary: r.text("summary") ?? "",
            message: r.text("message"),
            items: withItems ? (r.blob("items").flatMap { try? Self.decoder.decode([RunItem].self, from: $0) } ?? []) : [],
            stepTimings: r.blob("timings").flatMap { try? Self.decoder.decode([String: Double].self, from: $0) } ?? [:]
        )
    }

    /// Deletes history older than `days`.
    public func pruneHistory(olderThan days: Int, now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        try locked { _ = try db.run("DELETE FROM runs WHERE started < ?", [.double(cutoff)]) }
    }

    // MARK: Key-value

    public func value(_ key: String) -> String? {
        try? locked { try db.query("SELECT value FROM kv WHERE key = ?", [.text(key)]) }.first?.text("value")
    }

    public func setValue(_ value: String?, for key: String) {
        _ = try? locked {
            if let value {
                try db.run("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [.text(key), .text(value)])
            } else {
                try db.run("DELETE FROM kv WHERE key = ?", [.text(key)])
            }
        }
    }

    public func date(_ key: String) -> Date? {
        value(key).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    public func setDate(_ date: Date?, for key: String) {
        setValue(date.map { String($0.timeIntervalSince1970) }, for: key)
    }

    public func int(_ key: String) -> Int? {
        value(key).flatMap(Int.init)
    }

    public func setInt(_ value: Int?, for key: String) {
        setValue(value.map(String.init), for: key)
    }

    // MARK: Repos

    public func repos() -> [RepoRecord] {
        let rows = (try? locked { try db.query("SELECT data FROM repos") }) ?? []
        return rows.compactMap { $0.blob("data").flatMap { try? Self.decoder.decode(RepoRecord.self, from: $0) } }
            .sorted { $0.fullName.lowercased() < $1.fullName.lowercased() }
    }

    public func repo(_ fullName: String) -> RepoRecord? {
        (try? locked { try db.query("SELECT data FROM repos WHERE full_name = ?", [.text(fullName)]) })?
            .first?.blob("data").flatMap { try? Self.decoder.decode(RepoRecord.self, from: $0) }
    }

    public func saveRepo(_ repo: RepoRecord) throws {
        let data = try Self.encoder.encode(repo)
        try locked {
            _ = try db.run("INSERT INTO repos (full_name, data) VALUES (?, ?) ON CONFLICT(full_name) DO UPDATE SET data = excluded.data",
                           [.text(repo.fullName), .blob(data)])
        }
    }

    public func deleteRepo(_ fullName: String) throws {
        try locked { _ = try db.run("DELETE FROM repos WHERE full_name = ?", [.text(fullName)]) }
    }
}

/// Keys used in the key-value table.
public enum StoreKey {
    static let helperRunSeen = "helperRunSeen"
    static let helperRunFailed = "helperRunFailed"
    public static func lastSuccess(_ job: String) -> String { "lastSuccess.\(job)" }
    public static func lastAttempt(_ job: String) -> String { "lastAttempt.\(job)" }
    public static func eventCursor(_ job: String) -> String { "eventCursor.\(job)" }
    public static func eventSource(_ job: String) -> String { "eventSource.\(job)" }
    public static func sourceFileCount(_ job: String) -> String { "sourceFileCount.\(job)" }
    public static func destFileCount(_ job: String) -> String { "destFileCount.\(job)" }
    public static func lastFullCheck(_ job: String) -> String { "lastFullCheck.\(job)" }
    public static func fullCheckAttempt(_ job: String) -> String { "fullCheckAttempt.\(job)" }
    public static func lastResult(_ job: String) -> String { "lastResult.\(job)" }
    public static let githubJob = "GitHub repos"
    /// Newly found repos, one per line: waiting for a decision with `new_repos = "prompt"`, otherwise just reported.
    public static let newRepos = "newRepos"
}
