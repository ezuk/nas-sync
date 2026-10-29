import Foundation

public struct AppConfig: Sendable, Equatable {
    public var home: HomeConfig
    public var nas: NASConfig
    public var battery: BatteryConfig
    public var folders: [FolderJobConfig]
    public var folderDefaults: FolderDefaults
    public var github: GitHubConfig?
}

public struct HomeConfig: Sendable, Equatable {
    public var wifi: String
}

public struct NASConfig: Sendable, Equatable {
    /// Full share URL, for example `smb://nas.local/home`.
    public var url: URL
    public var unmountWhenAway: Bool

    public var host: String { url.host() ?? "" }
    /// The share name, the first path component of the URL.
    public var share: String { url.pathComponents.dropFirst().first ?? "" }
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
}

public struct FolderJobConfig: Sendable, Equatable, Identifiable {
    public var name: String
    public var source: URL
    /// Path inside the NAS share.
    public var dest: String
    public var exclude: [String]
    public var archiveDays: Int
    public var staleAfter: Interval
    public var quietPeriod: Interval
    public var maxDeletePercent: Int
    public var maxDeleteFiles: Int
    public var line: Int
    /// Change-driven syncs start at most this often. Zero means no limit.
    public var atMostEvery = Interval(seconds: 0)

    public var id: String { name }
    public var excludeSet: GlobSet { GlobSet(exclude) }
}

public struct RetentionPolicy: Sendable, Equatable {
    public var daily: Int
    public var weekly: Int
    public var monthly: Int
    public var quarterly: Int
    public var max: Int

    public static let standard = RetentionPolicy(daily: 3, weekly: 1, monthly: 1, quarterly: 1, max: 6)
}

public struct GitHubConfig: Sendable, Equatable {
    public enum NewRepos: String, Sendable { case include, ignore }

    public var every: Interval
    public var around: TimeOfDay?
    public var staleAfter: Interval
    /// Path inside the NAS share.
    public var dest: String
    public var scan: [URL]
    public var newRepos: NewRepos
    public var exclude: [String]
    public var remoteOnly: [String]
    /// Owner (lowercased) to folder name. `*` is the fallback.
    public var groups: [String: String]
    public var keep: RetentionPolicy
    public var gc: Bool
    public var line: Int
    /// Line of each `exclude` entry and `remote_only` entry, for linking from the UI.
    public var excludeLine: Int?
    public var remoteOnlyLine: Int?

    public var excludeSet: GlobSet { GlobSet(exclude) }

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
        let urlText = nasSection.string("url", required: true, in: &issues) ?? ""
        let unmount = nasSection.bool("unmount_when_away", default: false, in: &issues)
        var nasURL = URL(string: "smb://invalid/share")!
        if !urlText.isEmpty {
            if let u = URL(string: urlText), u.scheme?.lowercased() == "smb", u.host() != nil,
               u.pathComponents.count >= 2 {
                nasURL = u
            } else {
                issue(nasSection.line("url"), "nas.url must look like smb://host/share.")
            }
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
            atMostEvery: fd.interval("at_most_every", default: Interval(seconds: 0), in: &issues),
            nightlyCheck: fd.timeOfDay("nightly_check", default: TimeOfDay(hour: 3, minute: 0), in: &issues),
            maxDeletePercent: fd.int("max_delete_percent", default: 20, range: 1...100, in: &issues),
            maxDeleteFiles: fd.int("max_delete_files", default: 1000, range: 1...Int.max, in: &issues),
            exclude: fd.stringList("exclude", default: [".DS_Store", "._*", ".Trash", ".Trashes", "Icon\r", "*.tmp", "~$*", ".TemporaryItems", ".smbdelete*"], in: &issues)
        )
        finish(fd)

        var folders: [FolderJobConfig] = []
        for (index, var item) in r.tableList("folder", in: &issues).enumerated() {
            let name = item.string("name", required: true, in: &issues) ?? "folder \(index + 1)"
            let sourceText = item.string("source", required: true, in: &issues) ?? ""
            let dest = item.string("dest", required: true, in: &issues) ?? ""
            let extra = item.stringList("exclude", default: [], in: &issues)
            let job = FolderJobConfig(
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
                atMostEvery: item.interval("at_most_every", default: defaults.atMostEvery, in: &issues)
            )
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

        var github: GitHubConfig?
        var gh = section(&r, "github", required: false)
        if gh.present, gh.bool("enabled", default: true, in: &issues) {
            var keepSection = gh.subsection("keep")
            let keep = RetentionPolicy(
                daily: keepSection.int("daily", default: 3, range: 0...1000, in: &issues),
                weekly: keepSection.int("weekly", default: 1, range: 0...1000, in: &issues),
                monthly: keepSection.int("monthly", default: 1, range: 0...1000, in: &issues),
                quarterly: keepSection.int("quarterly", default: 1, range: 0...1000, in: &issues),
                max: keepSection.int("max", default: 6, range: 1...1000, in: &issues)
            )
            finish(keepSection)

            var groups: [String: String] = [:]
            if let node = gh.raw("groups") {
                if case .table(let t) = node.value {
                    for (k, v) in t.entries {
                        if case .string(let s) = v.value, !s.isEmpty {
                            groups[k.lowercased()] = s
                        } else {
                            issue(v.line, "github.groups.\(k) must be a folder name in quotes.")
                        }
                    }
                } else {
                    issue(node.line, "github.groups must be a table like { \"owner\" = \"folder\", \"*\" = \"other\" }.")
                }
            }

            let newReposText = gh.string("new_repos", required: false, in: &issues) ?? "include"
            let newRepos = GitHubConfig.NewRepos(rawValue: newReposText)
            if newRepos == nil {
                issue(gh.line("new_repos"), "github.new_repos must be \"include\" or \"ignore\".")
            }
            let dest = gh.string("dest", required: false, in: &issues) ?? "github-backups"
            checkDest(dest, label: "github", line: gh.line("dest"))
            let remoteOnly = gh.stringList("remote_only", default: [], in: &issues)
            for repo in remoteOnly where repo.split(separator: "/").count != 2 {
                issue(gh.line("remote_only"), "github.remote_only: '\(repo)' should look like owner/repo.")
            }
            github = GitHubConfig(
                every: gh.interval("every", default: .hours(24), in: &issues),
                around: gh.optionalTimeOfDay("around", in: &issues),
                staleAfter: gh.interval("stale_after", default: .hours(48), in: &issues),
                dest: normalizeDest(dest),
                scan: gh.stringList("scan", default: [], in: &issues).map(expand),
                newRepos: newRepos ?? .include,
                exclude: gh.stringList("exclude", default: [], in: &issues),
                remoteOnly: remoteOnly,
                groups: groups,
                keep: keep,
                gc: gh.bool("gc", default: false, in: &issues),
                line: gh.table.line,
                excludeLine: gh.line("exclude"),
                remoteOnlyLine: gh.line("remote_only")
            )
        }
        finish(gh)
        finish(r)

        checkOverlaps(folders: folders, github: github)

        if folders.isEmpty && github == nil {
            issues.append(ConfigIssue(severity: .warning, line: nil, message: "Nothing to back up yet. Add a [[folder]] or a [github] section."))
        }

        return AppConfig(
            home: HomeConfig(wifi: wifi),
            nas: NASConfig(url: nasURL, unmountWhenAway: unmount),
            battery: BatteryConfig(holdBelowPercent: holdBelow, butNotLongerThan: maxDelay),
            folders: folders,
            folderDefaults: defaults,
            github: github
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

    mutating func interval(_ key: String, default value: Interval, in issues: inout [ConfigIssue]) -> Interval {
        guard let node = raw(key) else { return value }
        guard case .string(let s) = node.value, let v = Interval(parsing: s) else {
            issues.append(ConfigIssue(severity: .error, line: node.line, message: "'\(path(key))' should be a duration in quotes, like \"30s\", \"12h\" or \"2d\"."))
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
