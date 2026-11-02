import CryptoKit
import Foundation

/// Backs up git repos to the NAS, one bare git mirror per repo.
///
/// Each repo has a bare mirror in the cache folder on this Mac, at the same path as on the NAS. A run fetches
/// every branch and tag from the source (the local clone, or GitHub for remote-only repos) into it without
/// pruning, deals with refs that disappeared at the source, checks the mirror, then copies it to
/// `<dest>/mirrors/<group>/<name>.git` on the NAS with rsync. Nothing is deleted on the NAS by default: with
/// `on_remote_delete = "keep"`, branches and tags deleted at the source, and the old tips of force-pushed
/// branches and moved tags, are kept under `refs/deleted/<day>/` in the mirror.
public final class GitHubBackup: @unchecked Sendable {
    public enum Step: String, Sendable, Codable, CaseIterable {
        case checking, fetching, verifying, copying
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
            /// The NAS helper handles this repo, and this Mac had nothing to send.
            case onNAS
        }

        public var fullName: String
        public var action: Action
        public var reason: String
        /// Size of the mirror on the NAS.
        public var size: Int64?
        /// Bytes copied to the NAS this run.
        public var sent: Int64?
        public var seconds: Double
        /// Refs saved under `refs/deleted/` this run.
        public var keptRefs: [String]
        /// Refs removed from the mirror this run because they were deleted at the source (`on_remote_delete = "prune"`).
        public var prunedRefs: [String]

        public init(fullName: String, action: Action, reason: String, size: Int64? = nil, sent: Int64? = nil, seconds: Double = 0,
                    keptRefs: [String] = [], prunedRefs: [String] = []) {
            self.fullName = fullName
            self.action = action
            self.reason = reason
            self.size = size
            self.sent = sent
            self.seconds = seconds
            self.keptRefs = keptRefs
            self.prunedRefs = prunedRefs
        }
    }

    public struct Result: Sendable {
        public var record: RunRecord
        public var repos: [RepoResult]
        /// Local clones seen for the first time, not counting the very first run or clones listed in `repos`.
        /// With `new_repos = "prompt"` or `"ignore"` these were not backed up.
        public var newRepos: [String]
    }

    public let config: GitHubConfig
    public let nas: NAS
    /// Folder for GitHub backups, relative to the NAS base folder.
    public let dest: String
    public let store: Store
    public let workDirectory: URL
    public let git: Git
    /// Asks GitHub whether each repo still exists. Off in tests.
    public var checksGitHub = true
    /// Starts the NAS helper at the end of a run. Off in tests.
    public var startsHelperRuns = true

    /// Folder inside `dest` that holds the mirrors.
    public static let mirrorsFolder = "mirrors"
    /// Where refs deleted or rewritten at the source are kept in a mirror.
    public static let deletedRefsPrefix = "refs/deleted/"

    public static func defaultWorkDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "NAS Sync")
    }

    public init(config: GitHubConfig, nas: NAS, store: Store, workDirectory: URL = GitHubBackup.defaultWorkDirectory(), git: Git = Git()) {
        self.config = config
        self.nas = nas
        dest = config.dest
        self.store = store
        self.workDirectory = workDirectory
        self.git = git
    }

    var tempDirectory: URL { workDirectory.appending(path: "work") }
    /// Local mirrors, at the same paths as inside `<dest>/mirrors` on the NAS.
    var cacheDirectory: URL { workDirectory.appending(path: "nas-mirrors") }
    /// Hidden copies of remote-only repos made by earlier versions, which pruned. No longer used.
    var legacyMirrorDirectory: URL { workDirectory.appending(path: "mirrors") }
    var mirrorsDirectory: String { "\(dest)/\(Self.mirrorsFolder)" }
    var reportsDirectory: String { "\(dest)/reports" }

    /// The mirror of a repo on the NAS, relative to the NAS base folder, like `github-backups/mirrors/acme/app.git`.
    /// `mirrorPath` is `RepoRecord.mirrorPath`.
    public static func nasMirrorPath(dest: String, mirrorPath: String) -> String {
        "\(dest)/\(mirrorsFolder)/\(mirrorPath)"
    }

    /// Where a repo's mirror is on the NAS, relative to the NAS base folder. Nil before it has one.
    public static func nasMirrorPath(dest: String, record: RepoRecord) -> String? {
        guard let path = record.mirrorPath else { return nil }
        return record.usesHelper ? "\(dest)/\(HelperManifest.mirrorsFolder)/\(path)" : nasMirrorPath(dest: dest, mirrorPath: path)
    }

    /// The folder inside `mirrors` for a repo: its owner's group, or `local` without a GitHub remote.
    func group(for t: RepoTarget) -> String {
        t.hasGitHubRemote ? config.group(forOwner: t.owner) : GitHubConfig.localGroup
    }

    /// Mirrors on the NAS (`group/name.git`), read once per run.
    private let nasMirrors = LockedBox<Set<String>>([])

    // MARK: Run

    public func run(
        trigger: String, dryRun: Bool = false, now: Date = Date(),
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: @escaping @Sendable (Progress) -> Void = { _ in },
        repoFinished: @escaping @Sendable (RepoResult) -> Void = { _ in }
    ) -> Result {
        var record = RunRecord(kind: .github, job: StoreKey.githubJob, trigger: dryRun ? "\(trigger), dry run" : trigger, started: now)
        let fm = FileManager.default

        do {
            try loadNASMirrors()
        } catch {
            record.outcome = .blocked
            record.finished = Date()
            record.summary = "NAS not available"
            record.message = "Couldn't read the GitHub backups folder on the NAS (\(error)). Nothing was changed."
            return Result(record: record, repos: [], newRepos: [])
        }
        try? fm.removeItem(at: tempDirectory)
        try? fm.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        if !dryRun { try? fm.removeItem(at: legacyMirrorDirectory) }

        let helper = NASHelper(nas: nas)
        let helperProblem = dryRun || config.helperRepos.isEmpty ? nil : prepareHelper(helper)

        let (targets, excluded) = RepoDiscovery.targets(config: config)
        let known = Dictionary(store.repos().map { ($0.fullName.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let isFirstRun = known.isEmpty
        var claimed = Self.claimedMirrorPaths(known.values)
        var newRepos: [String] = []
        var results: [RepoResult] = []
        var timings: [String: Double] = [:]

        if !dryRun {
            markMissing(known: known, targets: targets, excluded: excluded, now: now)
            for t in excluded {
                var r = known[t.fullName.lowercased()] ?? newRecord(t, now: now)
                r.status = .excluded
                r.message = "Excluded in the config."
                try? store.saveRepo(r)
            }
        }

        for (i, t) in targets.enumerated() {
            if isCancelled() { record.outcome = .cancelled; break }
            let existing = known[t.fullName.lowercased()]
            if existing == nil, t.source == .localClone, !t.isListed, !isFirstRun {
                newRepos.append(t.fullName)
                switch config.newRepos {
                case .include:
                    break
                case .ignore:
                    results.append(RepoResult(fullName: t.fullName, action: .skipped, reason: "new repo, not included (new_repos = \"ignore\")"))
                    continue
                case .prompt:
                    results.append(RepoResult(fullName: t.fullName, action: .skipped, reason: "new repo, waiting for you to decide"))
                    continue
                }
            }
            let mirrorPath = assignMirrorPath(t, existing: existing, claimed: &claimed)
            let lastStep = LockedBox(Step.checking)
            let report: @Sendable (Step) -> Void = { step in
                lastStep.set(step)
                progress(Progress(index: i, total: targets.count, repo: t.fullName, step: step))
            }
            let started = Date()
            do {
                var result: RepoResult
                if config.usesHelper(t.fullName), t.hasGitHubRemote {
                    if let helperProblem {
                        result = RepoResult(fullName: t.fullName, action: .failed, reason: helperProblem)
                    } else {
                        result = try sendToHelper(t, existing: existing, mirrorPath: mirrorPath, dryRun: dryRun, isCancelled: isCancelled, report: report)
                    }
                } else {
                    result = try backUp(t, existing: existing, mirrorPath: mirrorPath, dryRun: dryRun, now: now,
                                        isCancelled: isCancelled, report: report, timings: &timings)
                }
                result.seconds = Date().timeIntervalSince(started)
                results.append(result)
                repoFinished(result)
            } catch is CancellationError {
                record.outcome = .cancelled
                break
            } catch {
                let message = "\(Self.stepPhrase(lastStep.get())): \(Self.plain(error))"
                results.append(RepoResult(fullName: t.fullName, action: .failed, reason: message, seconds: Date().timeIntervalSince(started)))
                if !dryRun {
                    var r = existing ?? newRecord(t, now: now)
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
        if !dryRun, record.outcome != .cancelled, helperProblem == nil, !config.helperRepos.isEmpty || known.values.contains(where: \.usesHelper) {
            do {
                try handOffToHelper(helper)
            } catch {
                if record.outcome == .success { record.outcome = .warning }
                let text = "Couldn't start the NAS helper: \(Self.plain(error))"
                record.message = record.message.map { "\($0)\n\(text)" } ?? text
            }
        }
        if !dryRun, record.outcome != .cancelled || !results.isEmpty {
            writeReport(record: record, results: results, now: now)
        }
        return Result(record: record, repos: results, newRepos: newRepos)
    }

    func newRecord(_ t: RepoTarget, now: Date) -> RepoRecord {
        RepoRecord(fullName: t.fullName, source: t.source, localPath: t.localPath?.path(percentEncoded: false), firstSeen: now,
                   hasGitHubRemote: t.hasGitHubRemote)
    }

    private func markMissing(known: [String: RepoRecord], targets: [RepoTarget], excluded: [RepoTarget], now: Date) {
        let present = Set((targets + excluded).map { $0.fullName.lowercased() })
        for (key, var r) in known where !present.contains(key) && r.status != .missingLocally {
            r.status = .missingLocally
            r.message = r.source == .localClone
                ? "The local clone is gone, or no longer in the scan folders or repos. The mirror on the NAS is kept."
                : "No longer listed in remote_only. The mirror on the NAS is kept."
            try? store.saveRepo(r)
        }
    }

    // MARK: Mirror paths

    /// Mirror paths already used by known repos, lowercased, to the repo's lowercased name.
    static func claimedMirrorPaths<S: Sequence>(_ records: S) -> [String: String] where S.Element == RepoRecord {
        var claimed: [String: String] = [:]
        for r in records {
            if let p = r.mirrorPath { claimed[p.lowercased()] = r.fullName.lowercased() }
        }
        return claimed
    }

    /// `group/name.git`. A repo keeps its path while its group stays the same. Two repos with the same name in one
    /// group (say `acme/app` and `other/app` both in `other`) don't share a mirror: the later one gets `owner-name.git`.
    func assignMirrorPath(_ t: RepoTarget, existing: RepoRecord?, claimed: inout [String: String]) -> String {
        let key = t.fullName.lowercased()
        let folder = self.group(for: t)
        if let p = existing?.mirrorPath, p.hasPrefix(folder + "/") {
            claimed[p.lowercased()] = key
            return p
        }
        let owner = t.owner.isEmpty ? GitHubConfig.localGroup : t.owner
        var path = "\(folder)/\(t.name).git"
        var n = 1
        while let holder = claimed[path.lowercased()], holder != key {
            path = n == 1 ? "\(folder)/\(owner)-\(t.name).git" : "\(folder)/\(owner)-\(t.name)-\(n).git"
            n += 1
        }
        claimed[path.lowercased()] = key
        return path
    }

    // MARK: One repo

    private func backUp(
        _ t: RepoTarget, existing: RepoRecord?, mirrorPath: String, dryRun: Bool, now: Date,
        isCancelled: @escaping @Sendable () -> Bool, report: (Step) -> Void, timings: inout [String: Double]
    ) throws -> RepoResult {
        report(.checking)
        var record = existing ?? newRecord(t, now: now)
        record.source = t.source
        record.localPath = t.localPath?.path(percentEncoded: false)
        record.hasGitHubRemote = t.hasGitHubRemote
        record.usesHelper = false
        record.pushError = nil
        record.helperProblem = nil
        record.helperGone = false

        let gone = isGoneFromGitHub(t)
        let refs: [String: String]
        let fetchFrom: String
        var sourceHead: String?
        switch t.source {
        case .localClone:
            let dir = t.localPath!
            refs = try localRefs(dir)
            if t.hasGitHubRemote {
                record.unpushedCommits = Int((try? git.run(["rev-list", "--count", "--branches", "--not", "--remotes"], in: dir, timeout: 60))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            } else {
                record.unpushedCommits = nil
            }
            record.usesLFS = usesLFS(dir)
            fetchFrom = dir.path(percentEncoded: false)
            sourceHead = (try? git.run(["symbolic-ref", "-q", "HEAD"], in: dir, timeout: 30))?.trimmingCharacters(in: .whitespacesAndNewlines)
        case .remoteOnly:
            if gone {
                record.status = .goneFromGitHub
                record.message = BackupError.goneFromGitHub.description
                if !dryRun { try? store.saveRepo(record) }
                return RepoResult(fullName: t.fullName, action: .skipped,
                                  reason: "GitHub says this repo doesn't exist any more; the mirror on the NAS is kept", size: record.sizeOnNAS)
            }
            refs = try remoteRefs(t.remoteURL, isCancelled: isCancelled)
            fetchFrom = t.remoteURL
        }
        record.status = gone ? .goneFromGitHub : .ok
        record.message = gone ? "GitHub says this repo doesn't exist any more. It's still backed up from this Mac, and the mirror on the NAS is kept." : nil

        guard !refs.isEmpty else {
            if !record.refs.isEmpty { throw BackupError.noBranchesReported(had: record.refs.count) }
            if !dryRun { try? store.saveRepo(record) }
            return RepoResult(fullName: t.fullName, action: .skipped, reason: "empty repository, nothing to back up")
        }
        let onNAS = nasMirrors.get().contains(mirrorPath)
        if Self.fingerprint(refs) == record.fingerprint, onNAS, record.mirrorPath == mirrorPath {
            if !dryRun { try? store.saveRepo(record) }
            let since = record.lastChangeSeen ?? record.mirrorUpdated
            let reason = since.map { "unchanged since \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "unchanged"
            return RepoResult(fullName: t.fullName, action: .unchanged, reason: reason, size: record.sizeOnNAS)
        }

        var reason: String
        if record.fingerprint == nil {
            reason = "new repo, first backup"
        } else if !onNAS {
            reason = "no mirror on the NAS yet, copying the whole repo"
        } else {
            reason = describeChanges(old: record.refs, new: refs, in: t.source == .localClone ? t.localPath : nil)
        }
        if let n = record.unpushedCommits, n > 0 {
            reason += ", " + Format.count(n, "commit") + " not pushed to GitHub yet"
        }
        if dryRun {
            return RepoResult(fullName: t.fullName, action: .wouldBackUp, reason: reason)
        }

        func timed<T>(_ step: Step, _ body: () throws -> T) rethrows -> T {
            report(step)
            let start = Date()
            defer { timings[step.rawValue, default: 0] += Date().timeIntervalSince(start) }
            return try body()
        }

        let local = cacheDirectory.appending(path: mirrorPath, directoryHint: .isDirectory)
        let nasPath = Self.nasMirrorPath(dest: dest, mirrorPath: mirrorPath)
        var previous: URL?
        if let old = existing?.mirrorPath, old != mirrorPath {
            previous = cacheDirectory.appending(path: old, directoryHint: .isDirectory)
        }
        let update: MirrorUpdate = try timed(.fetching) {
            try prepareMirror(local, nasPath: nasPath, onNAS: onNAS, previous: previous, isCancelled: isCancelled)
            return try updateMirror(local, from: fetchFrom, sourceRefs: refs, sourceHead: sourceHead, now: now, isCancelled: isCancelled)
        }
        try timed(.verifying) {
            do {
                try tidyMirror(local, isCancelled: isCancelled)
                try verifyMirror(local, isCancelled: isCancelled)
            } catch let error as GitError {
                // Start again from the NAS copy next time. The NAS wasn't changed.
                try? FileManager.default.removeItem(at: local)
                let detail = error.description.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                throw BackupError.checkFailed("The mirror didn't pass git's check, so the NAS copy wasn't changed (\(detail)).")
            }
        }
        let sent: Int64 = try timed(.copying) { try nas.uploadFolder(local, to: nasPath, isCancelled: isCancelled) }
        nasMirrors.update { _ = $0.insert(mirrorPath) }
        let size = Self.folderSize(local)

        record.refs = try localRefs(local)
        record.fingerprint = Self.fingerprint(record.refs)
        record.lastChangeSeen = now
        record.mirrorUpdated = Date()
        record.mirrorPath = mirrorPath
        record.sizeOnNAS = size
        record.deletedRefsKept = (try? deletedRefs(local)) ?? record.deletedRefsKept
        try store.saveRepo(record)

        if update.kept.count == 1 {
            reason += ", kept the old \(Self.shortName(update.original[0])) as \(update.kept[0])"
        } else if update.kept.count > 1 {
            reason += ", kept \(Format.count(update.kept.count, "deleted or rewritten ref")) under \(Self.deletedRefsPrefix)"
        }
        if !update.pruned.isEmpty {
            reason += ", removed \(Format.count(update.pruned.count, "ref")) deleted at the source"
        }
        return RepoResult(fullName: t.fullName, action: .backedUp, reason: reason, size: size, sent: sent,
                          keptRefs: update.kept, prunedRefs: update.pruned)
    }

    enum BackupError: Error, CustomStringConvertible {
        case goneFromGitHub
        case checkFailed(String)
        case noBranchesReported(had: Int)

        var description: String {
            switch self {
            case .goneFromGitHub: "GitHub says this repo doesn't exist any more. The mirror on the NAS is kept."
            case .checkFailed(let s): s
            case .noBranchesReported(let had):
                "git reported no branches, but this repo had \(Format.count(had, "ref")) at the last backup. The mirror on the NAS wasn't changed."
            }
        }
    }

    static func plain(_ error: Error) -> String {
        let text = (error as? GitError)?.description ?? (error as? BackupError)?.description ?? (error as? CommandError)?.description
            ?? error.localizedDescription
        if text.contains("Permission denied (publickey)") || text.contains("Host key verification failed") {
            return "git couldn't sign in to GitHub over SSH. Check that your SSH key is loaded in the SSH agent."
        }
        if text.contains("Could not resolve host") {
            return "Couldn't reach GitHub. Check the internet connection."
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        return lines.first { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") } ?? lines.first ?? text
    }

    /// Where in a repo's backup an error happened.
    static func stepPhrase(_ step: Step) -> String {
        switch step {
        case .checking: "While checking for changes"
        case .fetching: "While updating the mirror"
        case .verifying: "While verifying the mirror"
        case .copying: "While copying to the NAS"
        }
    }

    // MARK: Refs

    /// Branches, tags and the stash.
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

    /// Every ref name in a repo.
    func allRefs(_ repo: URL) throws -> [String] {
        try git.run(["for-each-ref", "--format=%(refname)"], in: repo, timeout: 120).split(whereSeparator: \.isNewline).map(String.init)
    }

    /// Refs kept under `refs/deleted/`, sorted.
    func deletedRefs(_ repo: URL) throws -> [String] {
        try git.run(["for-each-ref", "--format=%(refname)", "refs/deleted"], in: repo, timeout: 120)
            .split(whereSeparator: \.isNewline).map(String.init).sorted()
    }

    static func fingerprint(_ refs: [String: String]) -> String {
        let text = refs.keys.sorted().map { "\(refs[$0]!) \($0)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `branch main`, `tag v1`.
    static func shortName(_ ref: String) -> String {
        if ref.hasPrefix("refs/heads/") { return "branch \(ref.dropFirst("refs/heads/".count))" }
        if ref.hasPrefix("refs/tags/") { return "tag \(ref.dropFirst("refs/tags/".count))" }
        return ref
    }

    /// True only when GitHub clearly says the repo doesn't exist. Network or sign-in problems return false.
    func isGoneFromGitHub(_ t: RepoTarget) -> Bool {
        guard checksGitHub, t.hasGitHubRemote,
              let r = try? git.runRaw(["ls-remote", t.remoteURL, "HEAD"], timeout: 60), r.status != 0 else { return false }
        let text = r.stderr.lowercased()
        return text.contains("repository not found") || text.contains("does not exist")
    }

    func usesLFS(_ repo: URL) -> Bool {
        if let gitDir = RepoDiscovery.gitDirectory(of: repo),
           FileManager.default.fileExists(atPath: gitDir.appending(path: "lfs").path(percentEncoded: false)) { return true }
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
        let removedTags = old.keys.filter { $0.hasPrefix("refs/tags/") && new[$0] == nil }
        if !removedTags.isEmpty { parts.append(Format.count(removedTags.count, "tag") + " deleted") }
        if new["refs/stash"] != old["refs/stash"] { parts.append("stash changed") }
        return parts.isEmpty ? "refs changed" : parts.joined(separator: ", ")
    }

    // MARK: Mirror

    struct MirrorUpdate: Equatable {
        /// New refs under `refs/deleted/`.
        var kept: [String] = []
        /// The ref each kept one was, in the same order.
        var original: [String] = []
        /// Refs removed because they were deleted at the source (prune mode).
        var pruned: [String] = []
    }

    static func isMirror(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appending(path: "HEAD").path(percentEncoded: false))
            && fm.fileExists(atPath: dir.appending(path: "objects").path(percentEncoded: false))
    }

    /// Makes sure the local mirror exists. A missing one is copied from the NAS first when the NAS has it,
    /// so a lost cache never makes the NAS copy smaller.
    func prepareMirror(_ local: URL, nasPath: String, onNAS: Bool, previous: URL?, isCancelled: @escaping @Sendable () -> Bool) throws {
        let fm = FileManager.default
        if !Self.isMirror(local) {
            try? fm.removeItem(at: local)
            try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            if onNAS {
                try nas.downloadFolder(nasPath, to: local, isCancelled: isCancelled)
                guard Self.isMirror(local) else {
                    try? fm.removeItem(at: local)
                    throw BackupError.checkFailed("\(nasPath) on the NAS isn't a git repository. Nothing was changed there.")
                }
            } else if let previous, Self.isMirror(previous) {
                // The repo moved to another group folder; start from its old mirror.
                try fm.moveItem(at: previous, to: local)
            } else {
                try fm.createDirectory(at: local, withIntermediateDirectories: true)
                try git.run(["init", "--bare", "--quiet"], in: local)
            }
        }
        // Never let git clean up on its own: objects only reachable from kept refs must stay.
        try git.run(["config", "gc.auto", "0"], in: local)
        try git.run(["config", "core.logAllRefUpdates", "false"], in: local)
    }

    /// Brings the mirror up to date with the source without losing anything.
    ///
    /// 1. Refs gone at the source are moved under `refs/deleted/<day>/` (keep) or removed (prune). This happens
    ///    before fetching, so a new branch `fix/x` can replace a deleted branch `fix`. The stash is just removed.
    /// 2. Branches and tags (and the stash of a local clone) are fetched with explicit refspecs, never pruning.
    /// 3. With keep, the old tip of a branch that was force-pushed, or of a tag that moved, is kept too.
    func updateMirror(_ dir: URL, from source: String, sourceRefs: [String: String], sourceHead: String? = nil, now: Date,
                      isCancelled: @escaping @Sendable () -> Bool) throws -> MirrorUpdate {
        var result = MirrorUpdate()
        let keep = config.onRemoteDelete == .keep
        let before = try localRefs(dir)
        let day = FolderSync.dayFormatter.string(from: now)
        var existing = Set(try allRefs(dir))

        var commands: [String] = []
        func keepCopy(of ref: String, at sha: String) {
            let name = Self.deletedName(for: ref, day: day, existing: &existing)
            commands.append("create \(name) \(sha)")
            result.kept.append(name)
            result.original.append(ref)
        }

        for (ref, sha) in before.sorted(by: { $0.key < $1.key }) where sourceRefs[ref] == nil {
            if ref != "refs/stash" {
                if keep { keepCopy(of: ref, at: sha) } else { result.pruned.append(ref) }
            }
            commands.append("delete \(ref) \(sha)")
        }
        try updateRefs(dir, commands)

        var specs = ["+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"]
        if sourceRefs["refs/stash"] != nil { specs.append("+refs/stash:refs/stash") }
        try git.run(["-c", "gc.auto=0", "fetch", "--quiet", "--force", source] + specs, in: dir, isCancelled: isCancelled)

        let after = try localRefs(dir)
        if keep {
            commands = []
            for (ref, old) in before.sorted(by: { $0.key < $1.key }) where ref != "refs/stash" && sourceRefs[ref] != nil {
                guard let new = after[ref], new != old else { continue }
                if ref.hasPrefix("refs/heads/"), isAncestor(old, of: new, in: dir) { continue }
                keepCopy(of: ref, at: old)
            }
            try updateRefs(dir, commands)
        }
        setHead(dir, preferred: sourceHead, refs: after)
        return result
    }

    /// `refs/deleted/<day>/heads/<branch>`. When that name is taken, or would clash with another ref as a folder,
    /// the day folder gets `-2`, `-3`…: `refs/deleted/<day>-2/heads/<branch>`.
    static func deletedName(for ref: String, day: String, existing: inout Set<String>) -> String {
        let rest = ref.hasPrefix("refs/") ? String(ref.dropFirst("refs/".count)) : ref
        var name = "\(deletedRefsPrefix)\(day)/\(rest)"
        var n = 2
        while existing.contains(name) || existing.contains(where: { $0.hasPrefix(name + "/") || name.hasPrefix($0 + "/") }) {
            name = "\(deletedRefsPrefix)\(day)-\(n)/\(rest)"
            n += 1
        }
        existing.insert(name)
        return name
    }

    /// Applies `create`/`delete` lines with `git update-ref --stdin`, all or nothing.
    func updateRefs(_ dir: URL, _ commands: [String]) throws {
        guard !commands.isEmpty else { return }
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let file = tempDirectory.appending(path: "update-refs-\(UUID().uuidString)")
        try Data((commands.joined(separator: "\n") + "\n").utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try git.run(["update-ref", "--stdin"], in: dir, timeout: 120, input: file)
    }

    func isAncestor(_ old: String, of new: String, in dir: URL) -> Bool {
        (try? git.runRaw(["merge-base", "--is-ancestor", old, new], in: dir, timeout: 300))?.status == 0
    }

    /// Points the mirror's HEAD at the source's current branch, or main, master or the first branch, so a clone
    /// from the NAS checks something out.
    func setHead(_ dir: URL, preferred: String?, refs: [String: String]) {
        let current = (try? git.run(["symbolic-ref", "-q", "HEAD"], in: dir, timeout: 30))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let choice: String?
        if let preferred, refs[preferred] != nil {
            choice = preferred
        } else if let current, refs[current] != nil {
            choice = current
        } else {
            choice = ["refs/heads/main", "refs/heads/master"].first { refs[$0] != nil }
                ?? refs.keys.filter { $0.hasPrefix("refs/heads/") }.sorted().first
        }
        if let choice, choice != current { _ = try? git.run(["symbolic-ref", "HEAD", choice], in: dir, timeout: 30) }
    }

    /// Repacks a mirror that has collected many small packs from fetches. Never drops objects.
    func tidyMirror(_ dir: URL, isCancelled: @escaping @Sendable () -> Bool) throws {
        let out = try git.run(["count-objects", "-v"], in: dir, timeout: 120)
        var values: [String: Int] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = Int(parts[1].trimmingCharacters(in: .whitespaces)) }
        }
        if (values["packs"] ?? 0) > 30 || (values["count"] ?? 0) > 5000 {
            try git.run(["-c", "gc.auto=0", "gc", "--quiet", "--prune=never"], in: dir, isCancelled: isCancelled)
        }
    }

    /// Checks that every ref's history is complete.
    func verifyMirror(_ dir: URL, isCancelled: @escaping @Sendable () -> Bool) throws {
        try git.run(["fsck", "--connectivity-only", "--no-dangling", "--no-progress"], in: dir, isCancelled: isCancelled)
    }

    static func folderSize(_ dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    // MARK: NAS

    /// Lists the mirrors on the NAS in one go.
    func loadNASMirrors() throws {
        var found: Set<String> = []
        for e in try nas.listTree(mirrorsDirectory, maxDepth: 2) ?? [] where e.isDirectory && e.path.hasSuffix(".git") {
            if e.path.split(separator: "/").count == 2 { found.insert(e.path) }
        }
        nasMirrors.set(found)
    }

    // MARK: Report

    private func fill(_ record: inout RunRecord, results: [RepoResult], total: Int, dryRun: Bool) {
        var c = RunCounts()
        c.total = total
        var items: [RunItem] = []
        var onNAS = 0
        for r in results {
            switch r.action {
            case .backedUp, .wouldBackUp:
                if r.reason.hasPrefix("new repo") { c.new += 1 } else { c.changed += 1 }
                c.bytes += r.sent ?? 0
                c.keptRefs += r.keptRefs.count
                c.pruned += r.prunedRefs.count
                items.append(RunItem(action: r.reason.hasPrefix("new repo") ? .new : .changed, path: r.fullName, size: r.size, detail: r.reason))
            case .unchanged:
                c.unchanged += 1
                items.append(RunItem(action: .unchanged, path: r.fullName, size: r.size, detail: r.reason))
            case .failed:
                c.failed += 1
                items.append(RunItem(action: .failed, path: r.fullName, detail: r.reason))
            case .skipped:
                c.skipped += 1
                items.append(RunItem(action: .skipped, path: r.fullName, size: r.size, detail: r.reason))
            case .onNAS:
                onNAS += 1
                items.append(RunItem(action: .unchanged, path: r.fullName, size: r.size, detail: r.reason))
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
        if onNAS > 0 { summary.append("\(onNAS) handled by the NAS helper") }
        if c.skipped > 0 { summary.append("\(c.skipped) skipped") }
        if c.failed > 0 { summary.append("\(c.failed) failed") }
        if c.keptRefs > 0 { summary.append(Format.count(c.keptRefs, "deleted ref") + " kept") }
        if c.pruned > 0 { summary.append(Format.count(c.pruned, "deleted ref") + " pruned") }
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let report = Report(started: record.started, finished: record.finished, trigger: record.trigger,
                            outcome: record.outcome.rawValue, summary: record.summary, repos: results)
        if let data = try? encoder.encode(report) {
            try? nas.write(data, to: "\(reportsDirectory)/\(Self.reportPrefix)\(Self.reportStamp.string(from: record.started)).json")
        }
        let cutoff = now.addingTimeInterval(-90 * 86400)
        let old = ((try? nas.listTree(reportsDirectory, maxDepth: 1)) ?? nil ?? []).map(\.path).filter { name in
            guard name.hasPrefix(Self.reportPrefix) else { return false }
            let stamp = String(name.dropFirst(Self.reportPrefix.count).prefix(15))
            return Self.reportStamp.date(from: stamp).map { $0 < cutoff } ?? false
        }
        try? nas.remove(old.map { "\(reportsDirectory)/\($0)" })
    }
}
