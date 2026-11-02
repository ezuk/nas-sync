import Foundation

/// What kind of activity a history row describes.
public enum RunKind: String, Sendable, Codable, CaseIterable {
    case folder
    case github
    case check
    case mount
    case away
    case hold
    case helper
}

public enum RunOutcome: String, Sendable, Codable {
    case success
    /// Finished, but some items were skipped or need attention.
    case warning
    case failed
    case cancelled
    /// Stopped by a safety guard before changing anything.
    case blocked
}

public enum ItemAction: String, Sendable, Codable {
    case new
    case changed
    case archived
    case skipped
    /// Intentionally not copied, such as symbolic links. Not a problem.
    case ignored
    case failed
    case unchanged
    case pruned
}

/// One file or repo touched by a run.
public struct RunItem: Sendable, Codable, Equatable {
    public var action: ItemAction
    public var path: String
    public var size: Int64?
    public var detail: String?

    public init(action: ItemAction, path: String, size: Int64? = nil, detail: String? = nil) {
        self.action = action
        self.path = path
        self.size = size
        self.detail = detail
    }
}

public struct RunCounts: Sendable, Codable, Equatable {
    public var new = 0
    public var changed = 0
    public var archived = 0
    public var skipped = 0
    public var failed = 0
    public var unchanged = 0
    /// Folders: old archive folders removed. GitHub: refs deleted from mirrors with `on_remote_delete = "prune"`.
    public var pruned = 0
    /// GitHub: refs deleted or force-pushed at the source and kept under `refs/deleted/` in the mirror.
    public var keptRefs = 0
    public var bytes: Int64 = 0
    /// Total files (folders) or repos (GitHub) considered.
    public var total = 0

    public init() {}

    /// Missing counts (from runs saved by older versions) read as zero.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        new = try c.decodeIfPresent(Int.self, forKey: .new) ?? 0
        changed = try c.decodeIfPresent(Int.self, forKey: .changed) ?? 0
        archived = try c.decodeIfPresent(Int.self, forKey: .archived) ?? 0
        skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        unchanged = try c.decodeIfPresent(Int.self, forKey: .unchanged) ?? 0
        pruned = try c.decodeIfPresent(Int.self, forKey: .pruned) ?? 0
        keptRefs = try c.decodeIfPresent(Int.self, forKey: .keptRefs) ?? 0
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
    }

    public var copied: Int { new + changed }
}

/// One row of history.
public struct RunRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: Int64?
    public var kind: RunKind
    /// Folder name, "GitHub repos", or empty for mount/away rows.
    public var job: String
    /// Why it ran: "changes", "scheduled", "manual", "nightly check", "startup".
    public var trigger: String
    public var started: Date
    public var finished: Date?
    public var outcome: RunOutcome
    public var counts: RunCounts
    /// Short plain-language result, like "12 copied, 2 archived".
    public var summary: String
    /// Longer explanation for problems.
    public var message: String?
    public var items: [RunItem]
    /// Seconds per step, for GitHub runs.
    public var stepTimings: [String: Double]

    public init(
        id: Int64? = nil, kind: RunKind, job: String, trigger: String, started: Date, finished: Date? = nil,
        outcome: RunOutcome = .success, counts: RunCounts = RunCounts(), summary: String = "",
        message: String? = nil, items: [RunItem] = [], stepTimings: [String: Double] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.job = job
        self.trigger = trigger
        self.started = started
        self.finished = finished
        self.outcome = outcome
        self.counts = counts
        self.summary = summary
        self.message = message
        self.items = items
        self.stepTimings = stepTimings
    }

    public var duration: TimeInterval? { finished.map { $0.timeIntervalSince(started) } }
}

public enum Format {
    public static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    public static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}
