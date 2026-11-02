import Foundation

public struct AppConfig: Sendable, Equatable {
    public var home: HomeConfig
    public var nas: NASConfig
    public var battery: BatteryConfig
    /// Folders that are switched on. These are the ones that sync.
    public var folders: [FolderJobConfig]
    public var folderDefaults: FolderDefaults
    /// GitHub backups, only when switched on.
    public var github: GitHubConfig?
    /// Every `[[folder]]` in file order, including ones with `enabled = false`.
    public var allFolders: [FolderJobConfig]
    /// The `[github]` settings even when `enabled = false`, so the form can show them.
    public var githubSettings: GitHubConfig?

    public init(home: HomeConfig, nas: NASConfig, battery: BatteryConfig, folders: [FolderJobConfig], folderDefaults: FolderDefaults,
                github: GitHubConfig?, allFolders: [FolderJobConfig]? = nil, githubSettings: GitHubConfig? = nil) {
        self.home = home
        self.nas = nas
        self.battery = battery
        self.folders = folders
        self.folderDefaults = folderDefaults
        self.github = github
        self.allFolders = allFolders ?? folders
        self.githubSettings = githubSettings ?? github
    }
}

public struct HomeConfig: Sendable, Equatable {
    public var wifi: String
}

public struct NASConfig: Sendable, Equatable {
    /// SSH login such as `me@nas.local`. Without it, `path` is a folder on this Mac.
    public var ssh: String?
    public var port: Int
    /// Base folder on the NAS; every `dest` is inside it.
    public var path: String
    /// rsync on this Mac, when not in a standard place.
    public var rsync: String?
    /// rsync on the NAS. Synology only accepts the full path.
    public var remoteRsync: String

    public init(ssh: String?, port: Int = 22, path: String, rsync: String? = nil, remoteRsync: String = "/usr/bin/rsync") {
        self.ssh = ssh
        self.port = port
        self.path = path
        self.rsync = rsync
        self.remoteRsync = remoteRsync
    }

    /// The host name, without the user.
    public var host: String { ssh.map { String($0.split(separator: "@").last ?? Substring($0)) } ?? "this Mac" }
}

public struct BatteryConfig: Sendable, Equatable {
    public var holdBelowPercent: Int
    public var butNotLongerThan: Interval
}

public struct FolderDefaults: Sendable, Equatable {
    public var archiveDays: Int
    public var staleAfter: Interval
    public var quietPeriod: Interval
    /// Change-driven syncs start at most this often. Zero means no limit.
    public var atMostEvery = Interval(seconds: 0)
    public var nightlyCheck: TimeOfDay
    public var maxDeletePercent: Int
    public var maxDeleteFiles: Int
    public var exclude: [String]

    /// Skipped in every folder when `[folders]` doesn't set `exclude`.
    public static let builtinExclude = [".DS_Store", "._*", ".Trash", ".Trashes", "Icon\r", "*.tmp", "~$*", ".TemporaryItems", ".smbdelete*", "@eaDir", "#recycle"]
}

public struct FolderJobConfig: Sendable, Equatable, Identifiable {
    public var name: String
    public var source: URL
    /// Path inside the NAS share.
    public var dest: String
    /// The shared `[folders]` patterns followed by this folder's own.
    public var exclude: [String]
    /// Only this folder's own `exclude` patterns.
    public var ownExclude: [String] = []
    /// False when the folder is paused with `enabled = false`.
    public var enabled = true
    /// Settings this folder sets itself instead of following `[folders]`, by key (`quiet_period`, `archive_days`, ...).
    public var overrides: Set<String> = []
    /// Line of each key in this folder's section.
    public var keyLines: [String: Int] = [:]
    public var archiveDays: Int
    public var staleAfter: Interval
    public var quietPeriod: Interval
    public var maxDeletePercent: Int
    public var maxDeleteFiles: Int
    public var line: Int
    /// Change-driven syncs start at most this often. Zero means no limit.
    public var atMostEvery = Interval(seconds: 0)

    public init(name: String, source: URL, dest: String, exclude: [String], archiveDays: Int, staleAfter: Interval, quietPeriod: Interval,
                maxDeletePercent: Int, maxDeleteFiles: Int, line: Int, atMostEvery: Interval = Interval(seconds: 0)) {
        self.name = name
        self.source = source
        self.dest = dest
        self.exclude = exclude
        self.archiveDays = archiveDays
        self.staleAfter = staleAfter
        self.quietPeriod = quietPeriod
        self.maxDeletePercent = maxDeletePercent
        self.maxDeleteFiles = maxDeleteFiles
        self.line = line
        self.atMostEvery = atMostEvery
    }

    public var id: String { name }
    public var excludeSet: GlobSet { GlobSet(exclude) }

    /// Keys a folder may set to override `[folders]`.
    public static let overridableKeys = ["quiet_period", "at_most_every", "archive_days", "max_delete_percent", "max_delete_files", "stale_after"]
}

public struct GitHubConfig: Sendable, Equatable {
    /// What happens to a newly found local clone. `prompt` holds it until you decide in the menu.
    public enum NewRepos: String, Sendable, CaseIterable { case include, ignore, prompt }
    /// What happens on the NAS to a branch or tag that was deleted at the source.
    public enum OnRemoteDelete: String, Sendable, CaseIterable { case keep, prune }

    public var enabled = true

    public var every: Interval
    public var around: TimeOfDay?
    public var staleAfter: Interval
    /// Path inside the NAS share.
    public var dest: String
    public var scan: [URL]
    /// Clones anywhere on this Mac, outside the scan folders. A GitHub remote is optional.
    public var repos: [URL] = []
    public var newRepos: NewRepos
    public var exclude: [String]
    public var remoteOnly: [String]
    /// Owner (lowercased) to folder name. `*` is the fallback.
    public var groups: [String: String]
    /// Owner to folder name in file order, with the owner's original case.
    public var groupList: [(owner: String, folder: String)] = []
    public var onRemoteDelete: OnRemoteDelete = .keep
    /// Repos the NAS helper backs up from GitHub, as patterns like `acme/*` or `*/*`.
    public var helperRepos: [String] = []
    public var line: Int
    /// Line of each `exclude` entry and `remote_only` entry, for linking from the UI.
    public var excludeLine: Int?
    public var remoteOnlyLine: Int?

    /// NAS folder, inside `dest`, for repos that have no GitHub remote.
    public static let localGroup = "local"

    public static func == (a: GitHubConfig, b: GitHubConfig) -> Bool {
        a.enabled == b.enabled && a.every == b.every && a.around == b.around && a.staleAfter == b.staleAfter && a.dest == b.dest
            && a.scan == b.scan && a.repos == b.repos && a.newRepos == b.newRepos && a.exclude == b.exclude && a.remoteOnly == b.remoteOnly
            && a.groups == b.groups && a.groupList.map { "\($0.owner)=\($0.folder)" } == b.groupList.map { "\($0.owner)=\($0.folder)" }
            && a.onRemoteDelete == b.onRemoteDelete && a.helperRepos == b.helperRepos && a.line == b.line && a.excludeLine == b.excludeLine
            && a.remoteOnlyLine == b.remoteOnlyLine
    }

    public var excludeSet: GlobSet { GlobSet(exclude) }

    /// True when the NAS helper backs up this GitHub repo, instead of this Mac.
    public func usesHelper(_ fullName: String) -> Bool {
        guard fullName.contains("/") else { return false }
        let globs = GlobSet(helperRepos)
        return globs.matches(fullName) || globs.matches(fullName.lowercased())
    }

    public func group(forOwner owner: String) -> String {
        groups[owner.lowercased()] ?? groups["*"] ?? "other"
    }
}

public struct ConfigIssue: Sendable, Equatable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }

    public var severity: Severity
    public var line: Int?
    public var message: String

    public var description: String {
        if let line { return "line \(line): \(message)" }
        return message
    }
}

public struct ConfigLoadResult: Sendable {
    public var config: AppConfig?
    public var issues: [ConfigIssue]

    public var errors: [ConfigIssue] { issues.filter { $0.severity == .error } }
    public var isValid: Bool { config != nil && errors.isEmpty }
}

public enum ConfigLoader {
    /// `~/.config/nas-sync/config.toml`
    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: ".config/nas-sync/config.toml")
    }

    public static func load(from url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ConfigLoadResult {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ConfigLoadResult(config: nil, issues: [
                ConfigIssue(severity: .error, line: nil, message: "Can't read the config file at \(url.path(percentEncoded: false)).")
            ])
        }
        return parse(text, home: home)
    }

    public static func parse(_ text: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ConfigLoadResult {
        let root: TOMLTable
        do {
            root = try TOMLParser.parse(text)
        } catch {
            return ConfigLoadResult(config: nil, issues: [ConfigIssue(severity: .error, line: error.line, message: error.message)])
        }
        var decoder = ConfigDecoder(home: home)
        let config = decoder.decode(root)
        let hasErrors = decoder.issues.contains { $0.severity == .error }
        return ConfigLoadResult(config: hasErrors ? nil : config, issues: decoder.issues)
    }
}

// MARK: - Decoding

struct ConfigDecoder {
    let home: URL
    var issues: [ConfigIssue] = []

    init(home: URL) {
        self.home = home
    }

    mutating func decode(_ root: TOMLTable) -> AppConfig {
        var r = Section(table: root, name: nil)

        var homeSection = section(&r, "home", required: true)
        let wifi = homeSection.string("wifi", required: true, in: &issues) ?? ""
        if homeSection.present, wifi.trimmingCharacters(in: .whitespaces).isEmpty {
            issue(homeSection.line("wifi"), "home.wifi can't be empty.")
        }
        finish(homeSection)

        var nasSection = section(&r, "nas", required: true)
        if nasSection.raw("url") != nil {
            issue(nasSection.line("url"), "nas.url (SMB) is no longer used. Set nas.ssh and nas.path instead, for example ssh = \"me@nas.local\" and path = \"/volume1/homes/me\".")
            _ = nasSection.string("url", required: false, in: &issues)
        }
        let ssh = nasSection.string("ssh", required: false, in: &issues)
        let port = nasSection.int("port", default: 22, range: 1...65535, in: &issues)
        let nasPath = nasSection.string("path", required: true, in: &issues) ?? ""
        let rsyncPath = nasSection.string("rsync", required: false, in: &issues)
        let remoteRsync = nasSection.string("remote_rsync", required: false, in: &issues) ?? "/usr/bin/rsync"
        if let ssh, ssh.isEmpty || ssh.contains(" ") || ssh.hasPrefix("-") {
            issue(nasSection.line("ssh"), "nas.ssh must be a login like me@nas.local.")
        }
        if !nasPath.isEmpty, !nasPath.hasPrefix("/") {
            issue(nasSection.line("path"), "nas.path must be a full path on the NAS, like /volume1/homes/me.")
        }
        finish(nasSection)

        var batterySection = section(&r, "battery", required: false)
        let holdBelow = batterySection.int("hold_below_percent", default: 30, range: 0...100, in: &issues)
        let maxDelay = batterySection.interval("but_not_longer_than", default: .hours(12), in: &issues)
        finish(batterySection)

        var fd = section(&r, "folders", required: false)
        let defaults = FolderDefaults(
            archiveDays: fd.int("archive_days", default: 90, range: 1...36500, in: &issues),
            staleAfter: fd.interval("stale_after", default: .hours(24), in: &issues),
            quietPeriod: fd.interval("quiet_period", default: Interval(seconds: 30), in: &issues),
            atMostEvery: fd.interval("at_most_every", default: Interval(seconds: 0), allowOff: true, in: &issues),
            nightlyCheck: fd.timeOfDay("nightly_check", default: TimeOfDay(hour: 3, minute: 0), in: &issues),
            maxDeletePercent: fd.int("max_delete_percent", default: 20, range: 1...100, in: &issues),
            maxDeleteFiles: fd.int("max_delete_files", default: 1000, range: 1...Int.max, in: &issues),
            exclude: fd.stringList("exclude", default: FolderDefaults.builtinExclude, in: &issues)
        )
        finish(fd)

        var folders: [FolderJobConfig] = []
        for (index, var item) in r.tableList("folder", in: &issues).enumerated() {
            let name = item.string("name", required: true, in: &issues) ?? "folder \(index + 1)"
            let sourceText = item.string("source", required: true, in: &issues) ?? ""
            let dest = item.string("dest", required: true, in: &issues) ?? ""
            let extra = item.stringList("exclude", default: [], in: &issues)
            let enabled = item.bool("enabled", default: true, in: &issues)
            var job = FolderJobConfig(
                name: name,
                source: expand(sourceText),
                dest: normalizeDest(dest),
                exclude: defaults.exclude + extra,
                archiveDays: item.int("archive_days", default: defaults.archiveDays, range: 1...36500, in: &issues),
                staleAfter: item.interval("stale_after", default: defaults.staleAfter, in: &issues),
                quietPeriod: item.interval("quiet_period", default: defaults.quietPeriod, in: &issues),
                maxDeletePercent: item.int("max_delete_percent", default: defaults.maxDeletePercent, range: 1...100, in: &issues),
                maxDeleteFiles: item.int("max_delete_files", default: defaults.maxDeleteFiles, range: 1...Int.max, in: &issues),
                line: item.table.line,
                atMostEvery: item.interval("at_most_every", default: defaults.atMostEvery, allowOff: true, in: &issues)
            )
            job.ownExclude = extra
            job.enabled = enabled
            job.overrides = Set(FolderJobConfig.overridableKeys.filter { item.table[$0] != nil })
            job.keyLines = Dictionary(uniqueKeysWithValues: item.table.entries.map { ($0.key, $0.node.line) })
            if !sourceText.isEmpty, !sourceText.hasPrefix("/"), !sourceText.hasPrefix("~") {
                issue(item.line("source"), "folder '\(name)': source must be a full path or start with ~.")
            }
            checkDest(dest, label: "folder '\(name)'", line: item.line("dest"))
            if folders.contains(where: { $0.name == name }) {
                issue(item.table.line, "Two folders are named '\(name)'. Names must be unique.")
            }
            finish(item)
            folders.append(job)
        }

        var githubSettings: GitHubConfig?
        var github: GitHubConfig?
        var gh = section(&r, "github", required: false)
        if gh.present {
            let enabled = gh.bool("enabled", default: true, in: &issues)
            if let keep = gh.raw("keep") {
                issues.append(ConfigIssue(severity: .warning, line: keep.line,
                                          message: "[github.keep] is no longer used. Each repo is now one git mirror on the NAS, so there are no older copies to keep. Delete the section, and use on_remote_delete to choose what happens to deleted branches."))
            }

            var groups: [String: String] = [:]
            var groupList: [(owner: String, folder: String)] = []
            if let node = gh.raw("groups") {
                if case .table(let t) = node.value {
                    for (k, v) in t.entries {
                        if case .string(let s) = v.value, !s.isEmpty {
                            groups[k.lowercased()] = s
                            groupList.append((k, s))
                        } else {
                            issue(v.line, "github.groups.\(k) must be a folder name in quotes.")
                        }
                    }
                } else {
                    issue(node.line, "github.groups must be a table like { \"owner\" = \"folder\", \"*\" = \"other\" }.")
                }
            }
            for (owner, folder) in groupList where folder.lowercased() == GitHubConfig.localGroup && owner != "*" {
                issue(gh.line("groups"), "github.groups: '\(folder)' is kept for repos with no GitHub remote. Use another folder name for \(owner).")
            }

            let newReposText = gh.string("new_repos", required: false, in: &issues) ?? GitHubConfig.NewRepos.prompt.rawValue
            let newRepos = GitHubConfig.NewRepos(rawValue: newReposText)
            if newRepos == nil {
                issue(gh.line("new_repos"), "github.new_repos must be \"prompt\", \"include\" or \"ignore\".")
            }
            let onDeleteText = gh.string("on_remote_delete", required: false, in: &issues) ?? GitHubConfig.OnRemoteDelete.keep.rawValue
            let onDelete = GitHubConfig.OnRemoteDelete(rawValue: onDeleteText)
            if onDelete == nil {
                issue(gh.line("on_remote_delete"), "github.on_remote_delete must be \"keep\" or \"prune\".")
            }
            let dest = gh.string("dest", required: false, in: &issues) ?? "github-backups"
            checkDest(dest, label: "github", line: gh.line("dest"))
            let remoteOnly = gh.stringList("remote_only", default: [], in: &issues)
            for repo in remoteOnly where repo.split(separator: "/").count != 2 {
                issue(gh.line("remote_only"), "github.remote_only: '\(repo)' should look like owner/repo.")
            }
            let repoPaths = gh.stringList("repos", default: [], in: &issues)
            for p in repoPaths where !p.hasPrefix("/") && !p.hasPrefix("~") {
                issue(gh.line("repos"), "github.repos: '\(p)' must be a full path or start with ~.")
            }
            var settings = GitHubConfig(
                every: gh.interval("every", default: .hours(24), in: &issues),
                around: gh.optionalTimeOfDay("around", in: &issues),
                staleAfter: gh.interval("stale_after", default: .hours(48), in: &issues),
                dest: normalizeDest(dest),
                scan: gh.stringList("scan", default: [], in: &issues).map(expand),
                newRepos: newRepos ?? .prompt,
                exclude: gh.stringList("exclude", default: [], in: &issues),
                remoteOnly: remoteOnly,
                groups: groups,
                line: gh.table.line,
                excludeLine: gh.line("exclude"),
                remoteOnlyLine: gh.line("remote_only")
            )
            settings.enabled = enabled
            settings.repos = repoPaths.map(expand)
            settings.groupList = groupList
            settings.onRemoteDelete = onDelete ?? .keep
            settings.helperRepos = gh.stringList("helper_repos", default: [], in: &issues)
            // No longer used. Configs written by older versions may still set it.
            _ = gh.bool("gc", default: false, in: &issues)
            githubSettings = settings
            if enabled { github = settings }
        }
        finish(gh)
        finish(r)

        // Paused folders and switched-off GitHub backups still own their NAS folder.
        checkOverlaps(folders: folders, github: githubSettings)

        if !folders.contains(where: \.enabled) && github == nil {
            issues.append(ConfigIssue(severity: .warning, line: nil, message: "Nothing to back up yet. Add a [[folder]] or a [github] section."))
        }

        return AppConfig(
            home: HomeConfig(wifi: wifi),
            nas: NASConfig(ssh: ssh, port: port, path: nasPath, rsync: rsyncPath, remoteRsync: remoteRsync),
            battery: BatteryConfig(holdBelowPercent: holdBelow, butNotLongerThan: maxDelay),
            folders: folders.filter(\.enabled),
            folderDefaults: defaults,
            github: github,
            allFolders: folders,
            githubSettings: githubSettings
        )
    }

    // MARK: Helpers

    private mutating func section(_ parent: inout Section, _ key: String, required: Bool) -> Section {
        guard let node = parent.raw(key) else {
            if required {
                issues.append(ConfigIssue(severity: .error, line: nil, message: "Missing the [\(key)] section."))
            }
            return Section(table: TOMLTable(line: 0), name: key, present: false)
        }
        guard case .table(let t) = node.value else {
            issue(node.line, "'\(key)' should be a section like [\(key)].")
            return Section(table: TOMLTable(line: node.line), name: key, present: false)
        }
        return Section(table: t, name: key)
    }

    private mutating func finish(_ section: Section) {
        for (key, node) in section.table.entries where !section.used.contains(key) {
            let full = section.name.map { "\($0).\(key)" } ?? key
            issue(node.line, "Unknown setting '\(full)'.")
        }
    }

    private mutating func issue(_ line: Int?, _ message: String) {
        issues.append(ConfigIssue(severity: .error, line: line, message: message))
    }

    func expand(_ path: String) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appending(path: String(path.dropFirst(2))) }
        return URL(filePath: path)
    }

    private func normalizeDest(_ dest: String) -> String {
        dest.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    private mutating func checkDest(_ dest: String, label: String, line: Int?) {
        let parts = dest.split(separator: "/")
        if dest.isEmpty || parts.isEmpty {
            issue(line, "\(label): dest can't be empty.")
        } else if dest.hasPrefix("/") || parts.contains("..") || parts.contains(".") {
            issue(line, "\(label): dest must be a folder path inside the NAS share, like \"Backups/Documents\".")
        }
    }

    private mutating func checkOverlaps(folders: [FolderJobConfig], github: GitHubConfig?) {
        var dests: [(label: String, path: String, line: Int)] = folders.map { ("folder '\($0.name)'", $0.dest, $0.line) }
        if let github { dests.append(("github", github.dest, github.line)) }
        for i in dests.indices {
            for j in dests.indices where j > i {
                let a = dests[i].path + "/", b = dests[j].path + "/"
                if a.hasPrefix(b) || b.hasPrefix(a) {
                    issue(dests[j].line, "\(dests[j].label) and \(dests[i].label) write into the same NAS folder (\(dests[j].path) / \(dests[i].path)).")
                }
            }
        }
    }
}

/// A table being read, which remembers which keys were used.
struct Section {
    var table: TOMLTable
    var name: String?
    var present = true
    var used: Set<String> = []

    func line(_ key: String) -> Int? { table[key]?.line }

    mutating func raw(_ key: String) -> TOMLNode? {
        used.insert(key)
        return table[key]
    }

    private func path(_ key: String) -> String { name.map { "\($0).\(key)" } ?? key }

    mutating func subsection(_ key: String) -> Section {
        guard let node = raw(key), case .table(let t) = node.value else {
            return Section(table: TOMLTable(line: 0), name: path(key), present: false)
        }
        return Section(table: t, name: path(key))
    }

    mutating func tableList(_ key: String, in issues: inout [ConfigIssue]) -> [Section] {
        guard let node = raw(key) else { return [] }
        guard case .array(let items) = node.value else {
            issues.append(ConfigIssue(severity: .error, line: node.line, message: "'\(key)' should be written as [[\(key)]] sections."))
            return []
        }
        return items.compactMap { item in
            guard case .table(let t) = item.value else {
                issues.append(ConfigIssue(severity: .error, line: item.line, message: "Each [[\(key)]] must be a section."))
                return nil
            }
            return Section(table: t, name: key)
        }
    }

    mutating func string(_ key: String, required: Bool, in issues: inout [ConfigIssue]) -> String? {
        guard let node = raw(key) else {
            if required, present {
                issues.append(ConfigIssue(severity: .error, line: table.line > 0 ? table.line : nil, message: "Missing '\(path(key))'."))
            }
            return nil
        }
        guard case .string(let s) = node.value else {
            issues.append(ConfigIssue(severity: .error, line: node.line, message: "'\(path(key))' should be text in quotes, not a \(node.typeName)."))
            return nil
        }
        return s
    }

    mutating func stringList(_ key: String, default value: [String], in issues: inout [ConfigIssue]) -> [String] {
        guard let node = raw(key) else { return value }
        guard case .array(let items) = node.value else {
            issues.append(ConfigIssue(severity: .error, line: node.line, message: "'\(path(key))' should be a list like [\"a\", \"b\"]."))
            return value
        }
        var result: [String] = []
        for item in items {
            if case .string(let s) = item.value {
                result.append(s)
            } else {
                issues.append(ConfigIssue(severity: .error, line: item.line, message: "'\(path(key))' should only contain text in quotes."))
            }
        }
        return result
    }

    mutating func int(_ key: String, default value: Int, range: ClosedRange<Int>, in issues: inout [ConfigIssue]) -> Int {
        guard let node = raw(key) else { return value }
        guard case .integer(let v) = node.value else {
            issues.append(ConfigIssue(severity: .error, line: node.line, message: "'\(path(key))' should be a whole number."))
            return value
        }
        guard range.contains(v) else {
            let expected = range.upperBound == Int.max
                ? "at least \(range.lowerBound)"
                : "between \(range.lowerBound) and \(range.upperBound)"
            issues.append(ConfigIssue(severity: .error, line: node.line, message: "'\(path(key))' should be \(expected)."))
            return value
        }
        return v
    }

    mutating func bool(_ key: String, default value: Bool, in issues: inout [ConfigIssue]) -> Bool {
        guard let node = raw(key) else { return value }
        guard case .boolean(let v) = node.value else {
            issues.append(ConfigIssue(severity: .error, line: node.line, message: "'\(path(key))' should be true or false."))
            return value
        }
        return v
    }

    /// With `allowOff`, `"off"` is accepted and read as zero, meaning no limit.
    mutating func interval(_ key: String, default value: Interval, allowOff: Bool = false, in issues: inout [ConfigIssue]) -> Interval {
        guard let node = raw(key) else { return value }
        if allowOff, case .string(let s) = node.value, s.trimmingCharacters(in: .whitespaces).lowercased() == "off" {
            return Interval(seconds: 0)
        }
        guard case .string(let s) = node.value, let v = Interval(parsing: s) else {
            let example = allowOff ? "\"30s\", \"12h\", \"2d\" or \"off\"" : "\"30s\", \"12h\" or \"2d\""
            issues.append(ConfigIssue(severity: .error, line: node.line, message: "'\(path(key))' should be a duration in quotes, like \(example)."))
            return value
        }
        return v
    }

    mutating func timeOfDay(_ key: String, default value: TimeOfDay, in issues: inout [ConfigIssue]) -> TimeOfDay {
        optionalTimeOfDay(key, in: &issues) ?? value
    }

    mutating func optionalTimeOfDay(_ key: String, in issues: inout [ConfigIssue]) -> TimeOfDay? {
        guard let node = raw(key) else { return nil }
        guard case .string(let s) = node.value, let v = TimeOfDay(parsing: s) else {
            issues.append(ConfigIssue(severity: .error, line: node.line, message: "'\(path(key))' should be a time in quotes, like \"03:00\"."))
            return nil
        }
        return v
    }
}
