import CryptoKit
import Foundation

/// Backs up GitHub repos to the NAS as compressed git bundles.
public final class GitHubBackup: @unchecked Sendable {
    public enum Step: String, Sendable, Codable {
        case checking, fetching, bundling, verifying, compressing, copying, pruning
    }

    public struct Progress: Sendable {
        public var index: Int
        public var total: Int
        public var repo: String
        public var step: Step
    }

    public struct RepoResult: Sendable, Codable, Equatable {
        public enum Action: String, Sendable, Codable {
            case backedUp, wouldBackUp, unchanged, failed, skipped
        }

        public var fullName: String
        public var action: Action
        public var reason: String
        public var archiveName: String?
        public var size: Int64?
        public var seconds: Double
        public var pruned: [String]
    }

    public struct Result: Sendable {
        public var record: RunRecord
        public var repos: [RepoResult]
        /// Local clones seen for the first time, not counting the very first run.
        public var newRepos: [String]
    }

    public let config: GitHubConfig
    /// `<NAS mount>/<github.dest>`
    public let destination: URL
    public let store: Store
    public let workDirectory: URL
    public let git: Git
    /// Asks GitHub whether each repo still exists. Off in tests.
    public var checksGitHub = true

    public static func defaultWorkDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "NAS Sync")
    }

    public init(config: GitHubConfig, destination: URL, store: Store, workDirectory: URL = GitHubBackup.defaultWorkDirectory(), git: Git = Git()) {
        self.config = config
        self.destination = destination
        self.store = store
        self.workDirectory = workDirectory
        self.git = git
    }

    var tempDirectory: URL { workDirectory.appending(path: "work") }
    var mirrorDirectory: URL { workDirectory.appending(path: "mirrors") }
    var bundlesDirectory: URL { destination.appending(path: "bundles") }
    var reportsDirectory: URL { destination.appending(path: "reports") }

    func repoFolder(_ t: RepoTarget) -> URL {
        bundlesDirectory.appending(path: config.group(forOwner: t.owner)).appending(path: t.name)
    }

    // MARK: Run

    public func run(
        trigger: String, dryRun: Bool = false, now: Date = Date(),
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) -> Result {
        var record = RunRecord(kind: .github, job: StoreKey.githubJob, trigger: dryRun ? "\(trigger), dry run" : trigger, started: now)
        let fm = FileManager.default

        guard fm.fileExists(atPath: destination.deletingLastPathComponent().path(percentEncoded: false)) else {
            record.outcome = .blocked
            record.finished = Date()
            record.summary = "NAS folder not found"
            record.message = "The NAS folder for GitHub backups isn't available. Nothing was changed."
            return Result(record: record, repos: [], newRepos: [])
        }
        try? fm.removeItem(at: tempDirectory)
        try? fm.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let (targets, excluded) = RepoDiscovery.targets(config: config)
        let known = Dictionary(store.repos().map { ($0.fullName.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let isFirstRun = known.isEmpty
        var newRepos: [String] = []
        var results: [RepoResult] = []
        var timings: [String: Double] = [:]

        if !dryRun {
            markMissing(known: known, targets: targets, excluded: excluded, now: now)
            for t in excluded {
                var r = known[t.fullName.lowercased()] ?? RepoRecord(fullName: t.fullName, source: t.source, localPath: t.localPath?.path(percentEncoded: false), firstSeen: now)
                r.status = .excluded
                r.message = "Excluded in the config."
                try? store.saveRepo(r)
            }
        }

        for (i, t) in targets.enumerated() {
            if isCancelled() { record.outcome = .cancelled; break }
            let existing = known[t.fullName.lowercased()]
            if existing == nil, t.source == .localClone, !isFirstRun { newRepos.append(t.fullName) }
            if existing == nil, t.source == .localClone, config.newRepos == .ignore, !isFirstRun {
                results.append(RepoResult(fullName: t.fullName, action: .skipped, reason: "new repo, not included (new_repos = \"ignore\")", seconds: 0, pruned: []))
                continue
            }
            let report: @Sendable (Step) -> Void = { step in progress(Progress(index: i, total: targets.count, repo: t.fullName, step: step)) }
            let started = Date()
            do {
                var result = try backUp(t, existing: existing, dryRun: dryRun, now: now, isCancelled: isCancelled, report: report, timings: &timings)
                result.seconds = Date().timeIntervalSince(started)
                results.append(result)
            } catch is CancellationError {
                record.outcome = .cancelled
                break
            } catch {
                let message = Self.plain(error)
                results.append(RepoResult(fullName: t.fullName, action: .failed, reason: message, seconds: Date().timeIntervalSince(started), pruned: []))
                if !dryRun {
                    var r = existing ?? RepoRecord(fullName: t.fullName, source: t.source, localPath: t.localPath?.path(percentEncoded: false), firstSeen: now)
                    if r.status != .goneFromGitHub { r.status = .failed }
                    r.message = message
                    try? store.saveRepo(r)
                }
            }
        }
        try? fm.removeItem(at: tempDirectory)

        record.finished = Date()
        record.stepTimings = timings
        fill(&record, results: results, total: targets.count, dryRun: dryRun)
        if !dryRun, record.outcome != .cancelled || !results.isEmpty {
            writeReport(record: record, results: results, now: now)
        }
        return Result(record: record, repos: results, newRepos: newRepos)
    }

    private func markMissing(known: [String: RepoRecord], targets: [RepoTarget], excluded: [RepoTarget], now: Date) {
        let present = Set((targets + excluded).map { $0.fullName.lowercased() })
        for (key, var r) in known where !present.contains(key) && r.status != .missingLocally {
            r.status = .missingLocally
            r.message = r.source == .localClone
                ? "The local clone is gone from the scan folders. Archives on the NAS are kept."
                : "No longer listed in remote_only. Archives on the NAS are kept."
            try? store.saveRepo(r)
        }
    }

    // MARK: One repo

    private func backUp(
        _ t: RepoTarget, existing: RepoRecord?, dryRun: Bool, now: Date,
        isCancelled: @escaping @Sendable () -> Bool, report: (Step) -> Void, timings: inout [String: Double]
    ) throws -> RepoResult {
        report(.checking)
        var record = existing ?? RepoRecord(fullName: t.fullName, source: t.source, localPath: t.localPath?.path(percentEncoded: false), firstSeen: now)
        record.source = t.source
        record.localPath = t.localPath?.path(percentEncoded: false)

        let gone = isGoneFromGitHub(t)
        var refs: [String: String]
        var repoDir: URL
        switch t.source {
        case .localClone:
            repoDir = t.localPath!
            refs = try localRefs(repoDir)
            record.unpushedCommits = Int((try? git.run(["rev-list", "--count", "--branches", "--not", "--remotes"], in: repoDir, timeout: 60))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            record.usesLFS = usesLFS(repoDir)
        case .remoteOnly:
            if gone { throw BackupError.goneFromGitHub }
            refs = try remoteRefs(t.remoteURL, isCancelled: isCancelled)
            repoDir = mirrorDirectory.appending(path: t.owner).appending(path: "\(t.name).git")
        }
        let folder = repoFolder(t)
        let archives = listArchives(folder)
        refreshArchives(&record, archives)
        record.status = gone ? .goneFromGitHub : .ok
        record.message = gone ? "GitHub says this repo doesn't exist any more. Archives on the NAS are kept." : nil

        guard !refs.isEmpty else {
            if !dryRun { try? store.saveRepo(record) }
            return RepoResult(fullName: t.fullName, action: .skipped, reason: "empty repository, nothing to back up", seconds: 0, pruned: [])
        }
        let fingerprint = Self.fingerprint(refs)
        let newestExists = record.newestArchiveName.map { archives.map(\.name).contains($0) } ?? false
        if fingerprint == record.fingerprint, newestExists {
            if !dryRun { try? store.saveRepo(record) }
            let since = record.lastChangeSeen ?? record.newestArchive
            let reason = since.map { "unchanged since \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "unchanged"
            return RepoResult(fullName: t.fullName, action: .unchanged, reason: reason, seconds: 0, pruned: [])
        }

        let isFirst = record.fingerprint == nil || archives.isEmpty
        var reason = isFirst ? "new repo, first backup" : describeChanges(old: record.refs, new: refs, in: t.source == .localClone ? repoDir : nil)
        if let n = record.unpushedCommits, n > 0 {
            reason += ", " + Format.count(n, "commit") + " not pushed to GitHub yet"
        }
        if dryRun {
            return RepoResult(fullName: t.fullName, action: .wouldBackUp, reason: reason, seconds: 0, pruned: [])
        }

        func timed<T>(_ step: Step, _ body: () throws -> T) rethrows -> T {
            report(step)
            let start = Date()
            defer { timings[step.rawValue, default: 0] += Date().timeIntervalSince(start) }
            return try body()
        }

        if t.source == .remoteOnly {
            try timed(.fetching) { try updateMirror(repoDir, url: t.remoteURL, isCancelled: isCancelled) }
            refs = try localRefs(repoDir)
        } else if config.gc {
            try timed(.bundling) { _ = try git.run(["gc", "--quiet"], in: repoDir, isCancelled: isCancelled) }
        }

        let name = ArchiveNaming.name(owner: t.owner, repo: t.name, date: now)
        let bundle = tempDirectory.appending(path: "\(t.owner)-\(t.name).bundle")
        let compressed = tempDirectory.appending(path: name)
        defer {
            try? FileManager.default.removeItem(at: bundle)
            try? FileManager.default.removeItem(at: compressed)
        }
        try timed(.bundling) {
            _ = try git.run(["bundle", "create", bundle.path(percentEncoded: false), "--all"], in: repoDir, isCancelled: isCancelled)
        }
        try timed(.verifying) {
            _ = try git.run(["bundle", "verify", "--quiet", bundle.path(percentEncoded: false)], in: repoDir, isCancelled: isCancelled)
        }
        try timed(.compressing) { try XZ.compress(bundle, to: compressed, isCancelled: isCancelled) }
        let size = try timed(.copying) { try copyToNAS(compressed, folder: folder, name: name) }

        var pruned: [String] = []
        try timed(.pruning) {
            let all = listArchives(folder)
            if record.status == .ok {
                let (_, delete) = Retention.apply(all, policy: config.keep, now: now)
                for a in delete {
                    try FileManager.default.removeItem(at: folder.appending(path: a.name))
                    pruned.append(a.name)
                }
            }
        }

        record.refs = refs
        record.fingerprint = Self.fingerprint(refs)
        record.lastChangeSeen = now
        refreshArchives(&record, listArchives(folder))
        record.newestArchiveName = name
        record.newestArchiveSize = size
        try store.saveRepo(record)
        return RepoResult(fullName: t.fullName, action: .backedUp, reason: reason, archiveName: name, size: size, seconds: 0, pruned: pruned)
    }

    enum BackupError: Error, CustomStringConvertible {
        case goneFromGitHub
        case checkFailed(String)

        var description: String {
            switch self {
            case .goneFromGitHub: "GitHub says this repo doesn't exist any more. Archives on the NAS are kept."
            case .checkFailed(let s): s
            }
        }
    }

    static func plain(_ error: Error) -> String {
        let text = (error as? GitError)?.description ?? (error as? BackupError)?.description ?? error.localizedDescription
        if text.contains("Permission denied (publickey)") || text.contains("Host key verification failed") {
            return "git couldn't sign in to GitHub over SSH. Check that your SSH key is loaded in the SSH agent."
        }
        if text.contains("Could not resolve host") {
            return "Couldn't reach GitHub. Check the internet connection."
        }
        return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    // MARK: Refs

    func localRefs(_ repo: URL) throws -> [String: String] {
        let out = try git.run(["for-each-ref", "--format=%(objectname) %(refname)", "refs/heads", "refs/tags", "refs/stash"], in: repo, timeout: 120)
        var refs: [String: String] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { refs[String(parts[1])] = String(parts[0]) }
        }
        return refs
    }

    func remoteRefs(_ url: String, isCancelled: @escaping @Sendable () -> Bool) throws -> [String: String] {
        let out = try git.run(["ls-remote", "--heads", "--tags", url], timeout: 120, isCancelled: isCancelled)
        var refs: [String: String] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, !parts[1].hasSuffix("^{}") else { continue }
            refs[String(parts[1])] = String(parts[0])
        }
        return refs
    }

    static func fingerprint(_ refs: [String: String]) -> String {
        let text = refs.keys.sorted().map { "\(refs[$0]!) \($0)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// True only when GitHub clearly says the repo doesn't exist. Network or sign-in problems return false.
    func isGoneFromGitHub(_ t: RepoTarget) -> Bool {
        guard checksGitHub, let r = try? git.runRaw(["ls-remote", t.remoteURL, "HEAD"], timeout: 60), r.status != 0 else { return false }
        let text = r.stderr.lowercased()
        return text.contains("repository not found") || text.contains("does not exist")
    }

    func usesLFS(_ repo: URL) -> Bool {
        if FileManager.default.fileExists(atPath: repo.appending(path: ".git/lfs").path(percentEncoded: false)) { return true }
        let attrs = (try? String(contentsOf: repo.appending(path: ".gitattributes"), encoding: .utf8)) ?? ""
        return attrs.contains("filter=lfs")
    }

    /// Plain-language summary like "14 new commits on main, new branch fix/x".
    func describeChanges(old: [String: String], new: [String: String], in repo: URL?) -> String {
        var parts: [String] = []
        let branches = new.keys.filter { $0.hasPrefix("refs/heads/") }.sorted()
        for ref in branches {
            let short = String(ref.dropFirst("refs/heads/".count))
            guard let before = old[ref] else { parts.append("new branch \(short)"); continue }
            guard before != new[ref] else { continue }
            if let repo, let n = (try? git.run(["rev-list", "--count", "\(before)..\(new[ref]!)"], in: repo, timeout: 60))
                .flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), n > 0 {
                parts.append("\(Format.count(n, "new commit")) on \(short)")
            } else {
                parts.append("\(short) updated")
            }
        }
        let removed = old.keys.filter { $0.hasPrefix("refs/heads/") && new[$0] == nil }
        if !removed.isEmpty { parts.append(Format.count(removed.count, "branch", "branches") + " deleted") }
        let newTags = new.keys.filter { $0.hasPrefix("refs/tags/") && old[$0] != new[$0] }.sorted()
        if newTags.count == 1 { parts.append("new tag \(newTags[0].dropFirst("refs/tags/".count))") }
        else if newTags.count > 1 { parts.append(Format.count(newTags.count, "new tag")) }
        if new["refs/stash"] != old["refs/stash"] { parts.append("stash changed") }
        return parts.isEmpty ? "refs changed" : parts.joined(separator: ", ")
    }

    // MARK: Mirror

    func updateMirror(_ dir: URL, url: String, isCancelled: @escaping @Sendable () -> Bool) throws {
        if !FileManager.default.fileExists(atPath: dir.appending(path: "HEAD").path(percentEncoded: false)) {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try git.run(["init", "--bare", "--quiet"], in: dir)
            try git.run(["remote", "add", "origin", url], in: dir)
            try git.run(["config", "remote.origin.fetch", "+refs/heads/*:refs/heads/*"], in: dir)
            try git.run(["config", "--add", "remote.origin.fetch", "+refs/tags/*:refs/tags/*"], in: dir)
        } else {
            try git.run(["remote", "set-url", "origin", url], in: dir)
        }
        try git.run(["fetch", "--prune", "--force", "--quiet", "origin"], in: dir, isCancelled: isCancelled)
    }

    // MARK: NAS

    func listArchives(_ folder: URL) -> [ArchiveFile] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return items.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasSuffix(ArchiveNaming.suffix), let date = ArchiveNaming.date(fromName: name) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return ArchiveFile(name: name, date: date, size: size)
        }.sorted { $0.date > $1.date }
    }

    func refreshArchives(_ record: inout RepoRecord, _ archives: [ArchiveFile]) {
        record.archiveCount = archives.count
        record.archiveDates = archives.map(\.date)
        if let newest = archives.first {
            record.newestArchive = newest.date
            if record.newestArchiveName == nil || !archives.contains(where: { $0.name == record.newestArchiveName }) {
                record.newestArchiveName = newest.name
                record.newestArchiveSize = newest.size
            }
        } else {
            record.newestArchive = nil
            record.newestArchiveName = nil
            record.newestArchiveSize = nil
        }
    }

    /// Copies under a temp name, renames into place, then checks size and checksum.
    func copyToNAS(_ file: URL, folder: URL, name: String) throws -> Int64 {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for leftover in (try? fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [] where leftover.hasPrefix(FolderSync.tempPrefix) {
            try? fm.removeItem(at: folder.appending(path: leftover))
        }
        let temp = folder.appending(path: FolderSync.tempPrefix + name)
        let final = folder.appending(path: name)
        try fm.copyItem(at: file, to: temp)
        guard rename(temp.path(percentEncoded: false), final.path(percentEncoded: false)) == 0 else {
            let message = String(cString: strerror(errno))
            try? fm.removeItem(at: temp)
            throw BackupError.checkFailed("Couldn't move the archive into place on the NAS: \(message)")
        }
        let localSize = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        let remoteSize = try final.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -2
        guard localSize == remoteSize, try XZ.sha256(of: file) == XZ.sha256(of: final) else {
            try? fm.removeItem(at: final)
            throw BackupError.checkFailed("The archive on the NAS didn't match the local copy, so it was removed. It will be retried next run.")
        }
        return Int64(remoteSize)
    }

    // MARK: Report

    private func fill(_ record: inout RunRecord, results: [RepoResult], total: Int, dryRun: Bool) {
        var c = RunCounts()
        c.total = total
        var items: [RunItem] = []
        for r in results {
            switch r.action {
            case .backedUp, .wouldBackUp:
                if r.reason.hasPrefix("new repo") { c.new += 1 } else { c.changed += 1 }
                c.bytes += r.size ?? 0
                items.append(RunItem(action: r.reason.hasPrefix("new repo") ? .new : .changed, path: r.fullName, size: r.size, detail: r.reason))
                for p in r.pruned {
                    c.pruned += 1
                    items.append(RunItem(action: .pruned, path: "\(r.fullName)/\(p)"))
                }
            case .unchanged:
                c.unchanged += 1
                items.append(RunItem(action: .unchanged, path: r.fullName, detail: r.reason))
            case .failed:
                c.failed += 1
                items.append(RunItem(action: .failed, path: r.fullName, detail: r.reason))
            case .skipped:
                c.skipped += 1
                items.append(RunItem(action: .skipped, path: r.fullName, detail: r.reason))
            }
        }
        record.counts = c
        record.items = items
        if record.outcome != .cancelled {
            record.outcome = c.failed > 0 ? (c.failed == results.count && !results.isEmpty ? .failed : .warning) : .success
        }
        var summary: [String] = []
        if c.copied > 0 { summary.append("\(c.copied) \(dryRun ? "would be backed up" : "backed up")") }
        if c.unchanged > 0 { summary.append("\(c.unchanged) unchanged") }
        if c.failed > 0 { summary.append("\(c.failed) failed") }
        if c.pruned > 0 { summary.append(Format.count(c.pruned, "old archive") + " pruned") }
        record.summary = summary.isEmpty ? "No repos found" : summary.joined(separator: ", ")
        if c.failed > 0 {
            record.message = results.filter { $0.action == .failed }.prefix(3).map { "\($0.fullName): \($0.reason)" }.joined(separator: "\n")
        }
    }

    struct Report: Codable {
        var started: Date
        var finished: Date?
        var trigger: String
        var outcome: String
        var summary: String
        var repos: [RepoResult]
    }

    static let reportPrefix = "backup-report-"
    static let reportStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private func writeReport(record: RunRecord, results: [RepoResult], now: Date) {
        let fm = FileManager.default
        try? fm.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let report = Report(started: record.started, finished: record.finished, trigger: record.trigger,
                            outcome: record.outcome.rawValue, summary: record.summary, repos: results)
        if let data = try? encoder.encode(report) {
            let url = reportsDirectory.appending(path: "\(Self.reportPrefix)\(Self.reportStamp.string(from: record.started)).json")
            try? data.write(to: url, options: .atomic)
        }
        let cutoff = now.addingTimeInterval(-90 * 86400)
        for name in (try? fm.contentsOfDirectory(atPath: reportsDirectory.path(percentEncoded: false))) ?? [] where name.hasPrefix(Self.reportPrefix) {
            let stamp = String(name.dropFirst(Self.reportPrefix.count).prefix(15))
            if let date = Self.reportStamp.date(from: stamp), date < cutoff {
                try? fm.removeItem(at: reportsDirectory.appending(path: name))
            }
        }
    }
}
