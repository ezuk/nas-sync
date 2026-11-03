import CryptoKit
import Foundation

/// Which helper a script is, or claims to be.
public struct HelperIdentity: Sendable, Codable, Equatable {
    public var version: Int
    public var protocolVersion: Int
    public var sha256: String

    enum CodingKeys: String, CodingKey {
        case version = "helper_version"
        case protocolVersion = "protocol"
        case sha256
    }

    public init(version: Int, protocolVersion: Int, sha256: String) {
        self.version = version
        self.protocolVersion = protocolVersion
        self.sha256 = sha256
    }

    /// Reads `HELPER_VERSION` and `PROTOCOL` from a script's source.
    public init?(source: Data) {
        guard let text = String(data: source, encoding: .utf8),
              let version = Self.number("HELPER_VERSION", in: text), let proto = Self.number("PROTOCOL", in: text) else { return nil }
        self.init(version: version, protocolVersion: proto, sha256: SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined())
    }

    private static func number(_ name: String, in text: String) -> Int? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix(name + " = ") {
            return Int(line.dropFirst(name.count + 3))
        }
        return nil
    }
}

/// The helper script built into this app or tool.
public enum BundledHelper {
    public static let source = Data(PackageResources.nas_sync_helper_py)
    public static let identity = HelperIdentity(source: source)!
}

/// What to do about the helper on the NAS.
public enum HelperPlan: Sendable, Equatable {
    public enum Reason: String, Sendable, Codable {
        case missing, damaged, older, different
    }

    case useInstalled
    case install(Reason)
    case appTooOld

    public static func decide(installed: HelperIdentity, bundled: HelperIdentity) -> HelperPlan {
        if installed.version < bundled.version { return .install(.older) }
        if installed.version > bundled.version {
            return installed.protocolVersion == bundled.protocolVersion ? .useInstalled : .appTooOld
        }
        return installed.sha256 == bundled.sha256 ? .useInstalled : .install(.different)
    }
}

/// One health check reported by the helper.
public struct HelperCheck: Sendable, Codable, Equatable, Identifiable {
    public enum Status: String, Sendable, Codable {
        case ok, failed
        /// Couldn't tell, such as when GitHub can't be reached. Not a problem by itself.
        case unknown
    }

    public var id: String
    public var status: Status
    public var detail: String
    public var expires: Date?

    public init(id: String, status: Status, detail: String, expires: Date? = nil) {
        self.id = id
        self.status = status
        self.detail = detail
        self.expires = expires
    }

    /// The owner, for a `token:<owner>` check.
    public var tokenOwner: String? { id.hasPrefix("token:") ? String(id.dropFirst("token:".count)) : nil }
}

/// The helper's state after a check or an install.
public struct HelperReport: Sendable, Codable, Equatable {
    public enum State: String, Sendable, Codable {
        case ready
        /// Found by a read-only check; an install or update would fix it.
        case needsInstall
        case appTooOld
        case failed
    }

    public enum Change: String, Sendable, Codable {
        case installed, updated, repaired
    }

    public var state: State
    public var installedVersion: Int?
    public var bundledVersion: Int
    public var change: Change?
    public var reason: HelperPlan.Reason?
    public var checks: [HelperCheck]
    public var error: String?
    public var checked: Date

    public init(state: State, installedVersion: Int?, bundledVersion: Int, change: Change? = nil, reason: HelperPlan.Reason? = nil,
                checks: [HelperCheck] = [], error: String? = nil, checked: Date = Date()) {
        self.state = state
        self.installedVersion = installedVersion
        self.bundledVersion = bundledVersion
        self.change = change
        self.reason = reason
        self.checks = checks
        self.error = error
        self.checked = checked
    }

    public var failedChecks: [HelperCheck] { checks.filter { $0.status == .failed } }

    /// The Activity entry for this report: an install or update, or a failure.
    public func runRecord(started: Date) -> RunRecord? {
        let summary: String
        let outcome: RunOutcome
        switch (state, change) {
        case (.failed, _):
            summary = "Couldn't update the NAS helper"
            outcome = .failed
        case (.appTooOld, _):
            summary = "The NAS helper is newer than this app"
            outcome = .warning
        case (_, .installed?):
            summary = "Installed NAS helper version \(installedVersion ?? bundledVersion)"
            outcome = .success
        case (_, .updated?):
            summary = "Updated NAS helper to version \(installedVersion ?? bundledVersion)"
            outcome = .success
        case (_, .repaired?):
            summary = "Reinstalled NAS helper version \(installedVersion ?? bundledVersion)"
            outcome = .success
        default:
            return nil
        }
        return RunRecord(kind: .helper, job: "", trigger: "connection", started: started, finished: checked, outcome: outcome,
                         summary: summary, message: error)
    }
}

/// The list of repos the helper backs up, saved on the NAS.
public struct HelperManifest: Sendable, Codable, Equatable {
    public struct Repo: Sendable, Codable, Equatable {
        public var name: String
        public var url: String
        /// Inside the mirrors folder, like `acme/app.git`.
        public var path: String
        /// The app's old mirror of this repo, absolute on the NAS. The helper copies it in once.
        public var legacy: String?
        /// `clone` when a Mac also has the repo, or `remote`.
        public var source: String?
    }

    public static let currentVersion = 1
    /// Where the helper's mirrors go inside the GitHub backup folder. Separate from the app's `mirrors`, which
    /// the app's uploads overwrite.
    public static let mirrorsFolder = "mirrors-v2"

    public var version = HelperManifest.currentVersion
    /// Absolute path on the NAS.
    public var mirrors: String
    public var onRemoteDelete: String
    public var repos: [Repo]

    enum CodingKeys: String, CodingKey {
        case version, mirrors, repos
        case onRemoteDelete = "on_remote_delete"
    }

    var sortedByName: HelperManifest {
        var sorted = self
        sorted.repos.sort { $0.name < $1.name }
        return sorted
    }

    /// The repos the helper should back up: those matching `helper_repos`, leaving out new clones that are still
    /// waiting for approval. With `only`, just the named ones. Names already in `store` keep their paths.
    public static func build(config: GitHubConfig, nas: NAS, store: Store, only: Set<String>? = nil) -> HelperManifest {
        let backup = GitHubBackup(config: config, nas: nas, store: store)
        let known = Dictionary(store.repos().map { ($0.fullName.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var claimed = GitHubBackup.claimedMirrorPaths(known.values)
        let wanted = only.map { Set($0.map { $0.lowercased() }) }
        let repos = RepoDiscovery.targets(config: config).targets.compactMap { t -> Repo? in
            guard t.hasGitHubRemote else { return nil }
            let path = backup.assignMirrorPath(t, existing: known[t.fullName.lowercased()], claimed: &claimed)
            if let wanted {
                if !wanted.contains(t.fullName.lowercased()) { return nil }
            } else {
                let approved = known[t.fullName.lowercased()] != nil || t.isListed || t.source == .remoteOnly
                if !approved || !config.usesHelper(t.fullName) { return nil }
            }
            return Repo(name: t.fullName, url: "https://github.com/\(t.fullName).git", path: path,
                        legacy: nas.absolute(GitHubBackup.nasMirrorPath(dest: config.dest, mirrorPath: path)),
                        source: t.source == .localClone ? "clone" : "remote")
        }
        return HelperManifest(mirrors: nas.absolute("\(config.dest)/\(mirrorsFolder)"), onRemoteDelete: config.onRemoteDelete.rawValue, repos: repos)
    }
}

/// What the helper last did, read from `last-run.json` on the NAS.
public struct HelperRunReport: Sendable, Codable, Equatable {
    public struct Repo: Sendable, Codable, Equatable, Identifiable {
        public var name: String
        /// new, changed, unchanged, skipped, warning or failed
        public var action: String
        public var detail: String?
        public var branches: Int?
        public var tags: Int?
        public var lfsFiles: Int?
        public var lfsBytes: Int64?
        public var bytes: Int64?
        public var seconds: Double?
        public var keptRefs: [String]?
        /// Branches and tags holding work that's only on a Mac.
        public var fromMac: Int?
        public var gone: Bool?

        public var id: String { name }

        init(name: String, action: String, detail: String? = nil, bytes: Int64? = nil, gone: Bool? = nil) {
            self.name = name
            self.action = action
            self.detail = detail
            self.bytes = bytes
            self.gone = gone
        }

        enum CodingKeys: String, CodingKey {
            case name, action, detail, branches, tags, bytes, seconds, gone
            case fromMac = "from_mac"
            case lfsFiles = "lfs_files"
            case lfsBytes = "lfs_bytes"
            case keptRefs = "kept_refs"
        }
    }

    public var status: String
    public var helperVersion: Int?
    public var started: Date?
    public var finished: Date?
    public var total: Int?
    public var current: String?
    public var repos: [Repo]

    public var isFinished: Bool { status == "finished" }

    init(status: String, started: Date? = nil, finished: Date? = nil, total: Int? = nil, repos: [Repo]) {
        self.status = status
        self.started = started
        self.finished = finished
        self.total = total
        self.repos = repos
    }

    public var failedRepos: [Repo] { repos.filter { $0.action == "failed" || $0.action == "warning" } }

    /// The Activity entry for a finished run.
    public func runRecord() -> RunRecord {
        var counts = RunCounts()
        counts.total = total ?? repos.count
        var items: [RunItem] = []
        for repo in repos {
            counts.keptRefs += repo.keptRefs?.count ?? 0
            switch repo.action {
            case "new":
                counts.new += 1
                items.append(RunItem(action: .new, path: repo.name, size: repo.bytes, detail: repo.detail ?? "first backup"))
            case "changed":
                counts.changed += 1
                items.append(RunItem(action: .changed, path: repo.name, size: repo.bytes, detail: repo.detail ?? "updated"))
            case "failed", "warning":
                counts.failed += 1
                items.append(RunItem(action: .failed, path: repo.name, detail: repo.detail ?? "failed"))
            case "skipped":
                counts.skipped += 1
                items.append(RunItem(action: .skipped, path: repo.name, size: repo.bytes, detail: repo.detail ?? "skipped"))
            default:
                counts.unchanged += 1
                items.append(RunItem(action: .unchanged, path: repo.name, size: repo.bytes, detail: repo.detail ?? "unchanged"))
            }
        }
        var parts: [String] = []
        if counts.copied > 0 { parts.append("\(counts.copied) updated") }
        if counts.unchanged > 0 { parts.append("\(counts.unchanged) unchanged") }
        if counts.failed > 0 { parts.append("\(counts.failed) failed") }
        var record = RunRecord(kind: .helper, job: "", trigger: "NAS helper", started: started ?? Date(), finished: finished ?? Date(),
                               outcome: counts.failed > 0 ? .warning : .success,
                               summary: parts.isEmpty ? "No repos to back up" : parts.joined(separator: ", "),
                               message: failedRepos.prefix(3).map { "\($0.name): \($0.detail ?? "failed")" }.joined(separator: "\n").nilIfEmpty)
        record.counts = counts
        record.items = items
        return record
    }

    enum CodingKeys: String, CodingKey {
        case status, started, finished, total, current, repos
        case helperVersion = "helper_version"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public enum HelperError: Error, Sendable, Equatable, CustomStringConvertible {
    /// SSH itself failed, so nothing is known about the helper.
    case unreachable(String)
    case failed(String)

    public var description: String {
        switch self {
        case .unreachable(let s): "Couldn't reach the NAS to check its helper: \(s)"
        case .failed(let s): s
        }
    }
}

/// Finds, checks, installs and updates the helper on the NAS.
public struct NASHelper: Sendable {
    public static let stateFolder = ".nas-sync"
    static let scriptName = "nas-sync-helper.py"
    /// `ssh` exits with this when the connection itself failed.
    private static let sshFailure: Int32 = 255

    public let nas: NAS
    let source: Data
    let bundled: HelperIdentity
    /// Whether health checks ask GitHub about the tokens.
    let online: Bool

    public init(nas: NAS) {
        self.init(nas: nas, source: BundledHelper.source, online: true)!
    }

    init?(nas: NAS, source: Data, online: Bool) {
        guard let bundled = HelperIdentity(source: source) else { return nil }
        self.nas = nas
        self.source = source
        self.bundled = bundled
        self.online = online
    }

    private var helperRoot: String { Self.stateFolder + "/helper" }

    /// Where a scheduled task runs the helper. Stays the same across updates.
    public var currentScript: String { nas.absolute("\(helperRoot)/current/\(Self.scriptName)") }

    // MARK: Running the script

    private struct Output {
        var status: Int32
        var text: String
    }

    private func run(script: String, _ arguments: [String], timeout: TimeInterval = 120) throws -> Output {
        let command = "PATH=/usr/bin:/bin:/usr/local/bin:$PATH; export PATH; exec python3 " + ([script] + arguments).map(NAS.quote).joined(separator: " ")
        let r = try nas.shellRaw(command, timeout: timeout)
        if nas.isRemote, r.status == Self.sshFailure { throw HelperError.unreachable(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return Output(status: r.status, text: r.status == 0 ? r.stdout : (r.stderr.isEmpty ? r.stdout : r.stderr))
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: Data(text.utf8))
    }

    private func identity(of script: String) throws -> HelperIdentity? {
        let out = try run(script: script, ["version"])
        return out.status == 0 ? Self.decode(HelperIdentity.self, out.text) : nil
    }

    private struct CheckOutput: Decodable { var checks: [HelperCheck] }

    private func checks(of script: String, online: Bool) throws -> [HelperCheck]? {
        let out = try run(script: script, ["check"] + (online ? [] : ["--offline"]))
        guard out.status == 0 else { return nil }
        return Self.decode(CheckOutput.self, out.text)?.checks
    }

    // MARK: Status

    private enum Installed {
        case missing
        case damaged
        case found(HelperIdentity)
    }

    private func findInstalled() throws -> Installed {
        let exists = try nas.shellRaw("test -f \(NAS.quote(currentScript))")
        if nas.isRemote, exists.status == Self.sshFailure { throw HelperError.unreachable(exists.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard exists.status == 0 else { return .missing }
        return try identity(of: currentScript).map { .found($0) } ?? .damaged
    }

    /// Reports on the helper without changing anything.
    public func status() throws -> HelperReport {
        switch try findInstalled() {
        case .missing:
            return HelperReport(state: .needsInstall, installedVersion: nil, bundledVersion: bundled.version, reason: .missing)
        case .damaged:
            return HelperReport(state: .needsInstall, installedVersion: nil, bundledVersion: bundled.version, reason: .damaged)
        case .found(let installed):
            let checks = try checks(of: currentScript, online: online) ?? []
            switch HelperPlan.decide(installed: installed, bundled: bundled) {
            case .useInstalled:
                return HelperReport(state: .ready, installedVersion: installed.version, bundledVersion: bundled.version, checks: checks)
            case .install(let reason):
                return HelperReport(state: .needsInstall, installedVersion: installed.version, bundledVersion: bundled.version, reason: reason, checks: checks)
            case .appTooOld:
                return HelperReport(state: .appTooOld, installedVersion: installed.version, bundledVersion: bundled.version, checks: checks)
            }
        }
    }

    // MARK: Backing up

    private var manifestPath: String { "\(Self.stateFolder)/manifest.json" }
    private var lastRunPath: String { "\(Self.stateFolder)/last-run.json" }

    /// Saves the list of repos where scheduled runs will find it.
    public func save(_ manifest: HelperManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try nas.write(try encoder.encode(manifest), to: manifestPath)
    }

    /// Saves the list of repos unless the one on the NAS already matches. Returns whether it saved.
    public func saveIfChanged(_ manifest: HelperManifest) throws -> Bool {
        let path = NAS.quote(nas.absolute(manifestPath))
        let r = try nas.shellRaw("test -f \(path) && cat \(path)")
        if nas.isRemote, r.status == Self.sshFailure { throw HelperError.unreachable(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if r.status == 0, let saved = Self.decode(HelperManifest.self, r.stdout), saved.sortedByName == manifest.sortedByName { return false }
        try save(manifest)
        return true
    }

    /// Starts a run on the NAS and returns right away. It carries on if the connection drops.
    public func startRun() throws {
        let log = NAS.quote(nas.absolute("\(Self.stateFolder)/run.log"))
        let script = NAS.quote(currentScript)
        try nas.shell("PATH=/usr/bin:/bin:/usr/local/bin:$PATH; export PATH; nohup python3 \(script) run > \(log) 2>&1 < /dev/null &")
    }

    /// The latest run's report, or nil before the first one.
    public func lastRun() throws -> HelperRunReport? {
        let path = NAS.quote(nas.absolute(lastRunPath))
        let r = try nas.shellRaw("test -f \(path) && cat \(path)")
        if nas.isRemote, r.status == Self.sshFailure { throw HelperError.unreachable(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return r.status == 0 ? Self.decode(HelperRunReport.self, r.stdout) : nil
    }

    // MARK: Install and update

    /// Installs or updates the helper if needed, then checks its health. If an install fails, the helper already
    /// there stays active. Throws only when the NAS can't be reached.
    public func ensure() throws -> HelperReport {
        let reason: HelperPlan.Reason
        var previous: Int?
        switch try findInstalled() {
        case .missing:
            reason = .missing
        case .damaged:
            reason = .damaged
        case .found(let installed):
            previous = installed.version
            switch HelperPlan.decide(installed: installed, bundled: bundled) {
            case .useInstalled:
                return try reportHealth(installedVersion: installed.version)
            case .appTooOld:
                let checks = try checks(of: currentScript, online: online) ?? []
                return HelperReport(state: .appTooOld, installedVersion: installed.version, bundledVersion: bundled.version, checks: checks)
            case .install(let r):
                reason = r
            }
        }
        do {
            try install()
        } catch let error as HelperError {
            if case .unreachable = error { throw error }
            return HelperReport(state: .failed, installedVersion: previous, bundledVersion: bundled.version, reason: reason, error: error.description)
        } catch {
            return HelperReport(state: .failed, installedVersion: previous, bundledVersion: bundled.version, reason: reason, error: "\(error)")
        }
        var report = try reportHealth(installedVersion: bundled.version)
        report.reason = reason
        switch reason {
        case .missing: report.change = .installed
        case .older: report.change = .updated
        case .damaged, .different: report.change = .repaired
        }
        return report
    }

    private func reportHealth(installedVersion: Int) throws -> HelperReport {
        guard let checks = try checks(of: currentScript, online: online) else {
            return HelperReport(state: .failed, installedVersion: installedVersion, bundledVersion: bundled.version,
                                error: "The helper on the NAS is installed but its health check didn't run.")
        }
        return HelperReport(state: .ready, installedVersion: installedVersion, bundledVersion: bundled.version, checks: checks)
    }

    private struct Activation: Decodable { var previous: String? }

    /// Uploads the script next to the active one, tests it there, and only then makes it active.
    private func install() throws {
        let incoming = "\(helperRoot)/.incoming-\(UUID().uuidString)"
        let rel = "\(incoming)/\(Self.scriptName)"
        let script = nas.absolute(rel)
        var activated = false
        defer { if !activated { try? nas.remove([incoming]) } }

        do {
            try nas.shell("mkdir -p \(NAS.quote(nas.absolute(helperRoot))) && chmod 700 \(NAS.quote(nas.absolute(Self.stateFolder)))")
            try nas.write(source, to: rel)
        } catch let error as HelperError {
            throw error
        } catch {
            throw HelperError.failed("Couldn't copy the helper to the NAS: \(error)")
        }

        guard let tested = try identity(of: script), tested == bundled else {
            throw HelperError.failed("The new helper wouldn't run on the NAS. Check that Python 3 is available there.")
        }
        guard let checks = try checks(of: script, online: false), checks.first(where: { $0.id == "python" })?.status == .ok else {
            throw HelperError.failed("The new helper failed its self-test: it needs Python 3.8 or newer on the NAS.")
        }

        let out = try run(script: script, ["activate"])
        guard out.status == 0, let activation = Self.decode(Activation.self, out.text) else {
            throw HelperError.failed("Couldn't make the new helper active: \(out.text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        activated = true

        if try identity(of: currentScript) != bundled {
            if let previous = activation.previous {
                _ = try run(script: nas.absolute("\(helperRoot)/\(previous)/\(Self.scriptName)"), ["activate"])
            }
            throw HelperError.failed("The new helper didn't start after installing, so the earlier version was put back.")
        }
    }
}
