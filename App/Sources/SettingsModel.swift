import AppKit
import Observation
import SwiftUI
import SyncCore

/// A page in the Settings window.
enum SettingsPane: Hashable {
    case nas, when, allFolders, folder(Int), git, gitConfig, gitRepos, gitNAS, general, permissions, file
}

/// One setting in the form, as it's named in the file.
struct FieldKey: Hashable {
    var table: ConfigDocument.Table
    var key: String

    static func named(_ table: String, _ key: String) -> FieldKey { FieldKey(table: .named(table), key: key) }
    static func folder(_ index: Int, _ key: String) -> FieldKey { FieldKey(table: .folder(index), key: key) }

    /// `nas.path`, `folder.dest`, ...
    var fileName: String { "\(table.keyPrefix).\(key)" }

    var pane: SettingsPane {
        switch table {
        case .folder(let i): return .folder(i)
        case .named(let t):
            switch t {
            case "home", "battery": return .when
            case "nas": return .nas
            case "folders": return .allFolders
            case "github":
                switch key {
                case "every", "around", "stale_after", "enabled": return .git
                case "remote_only", "repos": return .gitRepos
                case "dest", "groups", "on_remote_delete", "helper_repos": return .gitNAS
                default: return .gitConfig
                }
            default: return .file
            }
        }
    }
}

/// The form's view of the config file.
///
/// The file is the source of truth. Each change in the form edits only the lines of that setting, is
/// checked by the same checker the app uses at startup, and is written straight away when it passes.
/// A change that doesn't pass is never written: the field keeps what you typed and says why.
/// When the file changes on disk the form reads it again.
@MainActor @Observable
final class SettingsModel {
    var pane: SettingsPane = .nas

    private(set) var doc = ConfigDocument(text: "")
    /// The checker's result for `doc`.
    private(set) var result = ConfigLoader.parse("")
    /// The last config that passed, which the form shows while the file is broken.
    private(set) var shown: AppConfig = SettingsModel.placeholder
    private(set) var fileExists = false
    /// Rejected changes, by field.
    private(set) var fieldErrors: [FieldKey: String] = [:]
    /// The file's lines when the window opened, so the Config File page can mark what changed.
    private(set) var baselineLines: Set<String> = []
    /// The config when the window opened, for warnings about renaming and moving folders.
    private(set) var opened: AppConfig?
    private(set) var savedOnce = false
    var removingFolder: Int?

    @ObservationIgnored private var engine: Engine?
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var lastReadText: String?

    /// No config file yet: the form fills in a new one and saves it once it's valid.
    var isSetup: Bool { !fileExists }
    /// The file on disk has a mistake. The form can't safely edit it, so it's read-only until it's fixed.
    var isLocked: Bool { fileExists && !result.errors.isEmpty }
    var firstError: ConfigIssue? { result.errors.first }

    var config: AppConfig { shown }
    var github: GitHubConfig { shown.githubSettings ?? SettingsModel.defaultGitHub }
    var githubOn: Bool { shown.githubSettings?.enabled ?? false }

    // MARK: Loading

    func attach(_ engine: Engine) {
        let changedFile = url != engine.configURL
        self.engine = engine
        url = engine.configURL
        if changedFile { lastReadText = nil; baselineLines = []; opened = nil }
        reload()
    }

    /// Reads the file again if it changed on disk.
    func reload() {
        guard let url else { return }
        let path = url.path(percentEncoded: false)
        let exists = FileManager.default.fileExists(atPath: path)
        if !exists {
            fileExists = false
            if lastReadText != nil || doc.text.isEmpty {
                lastReadText = nil
                doc = ConfigDocument(text: StarterConfig.setupText(wifi: WiFi.currentName() ?? ""))
                result = doc.check()
                shown = result.config ?? SettingsModel.decodeLoosely(doc) ?? SettingsModel.placeholder
                fieldErrors = [:]
                if pane != .general, pane != .permissions { pane = .nas }
            }
            return
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        fileExists = true
        guard text != lastReadText else { return }
        lastReadText = text
        doc = ConfigDocument(text: text)
        result = doc.check()
        if let c = result.config, result.errors.isEmpty {
            shown = c
            if opened == nil { opened = c }
        } else if opened == nil, let c = engine?.config {
            // Opened on a broken file: show what's still running, read-only.
            shown = c
        }
        if baselineLines.isEmpty { baselineLines = Set(ConfigDocument.lines(text)) }
        // A hand edit may have fixed or replaced what was rejected.
        fieldErrors = [:]
        if case .folder(let i) = pane, i >= shown.allFolders.count { pane = .allFolders }
    }

    // MARK: Editing

    /// Changes one setting. Returns false when the change was rejected.
    @discardableResult
    func set(_ field: FieldKey, _ value: ConfigDocument.Value?) -> Bool {
        guard !isLocked else { return false }
        var candidate = doc
        do {
            try candidate.set(field.key, in: field.table, to: value)
        } catch {
            fieldErrors[field] = error.localizedDescription
            return false
        }
        return apply(candidate, field: field)
    }

    /// Changes several settings that only make sense together.
    @discardableResult
    func set(_ changes: [(FieldKey, ConfigDocument.Value?)], reportOn field: FieldKey) -> Bool {
        guard !isLocked else { return false }
        var candidate = doc
        do {
            for (f, v) in changes { try candidate.set(f.key, in: f.table, to: v) }
        } catch {
            fieldErrors[field] = error.localizedDescription
            return false
        }
        return apply(candidate, field: field)
    }

    func error(_ field: FieldKey) -> String? { fieldErrors[field] }

    func clearError(_ field: FieldKey) { fieldErrors[field] = nil }

    func paneHasError(_ pane: SettingsPane) -> Bool {
        fieldErrors.keys.contains { $0.pane == pane }
    }

    func addFolder(source: URL) {
        let name = uniqueFolderName(source.lastPathComponent)
        var dest = "Mac/\(name)"
        var n = 2
        let taken = Set(shown.allFolders.map(\.dest)) .union(shown.githubSettings.map { [$0.dest] } ?? [])
        while taken.contains(where: { $0 == dest || $0.hasPrefix(dest + "/") || dest.hasPrefix($0 + "/") }) {
            dest = "Mac/\(name) \(n)"
            n += 1
        }
        var candidate = doc
        let index = candidate.addFolder(name: name, source: Self.abbreviate(source), dest: dest)
        if apply(candidate, field: .folder(index, "source")) || isSetup {
            pane = .folder(index)
        }
    }

    func removeFolder(_ index: Int) {
        var candidate = doc
        guard (try? candidate.removeFolder(index)) != nil else { return }
        let errors = fieldErrors.keys.filter { if case .folder = $0.table { true } else { false } }
        for k in errors { fieldErrors[k] = nil }
        if apply(candidate, field: .named("folders", "exclude")) { pane = .allFolders }
    }

    private func uniqueFolderName(_ base: String) -> String {
        let names = Set(shown.allFolders.map(\.name))
        var name = base.isEmpty ? "Folder" : base
        var n = 2
        while names.contains(name) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    private func apply(_ candidate: ConfigDocument, field: FieldKey) -> Bool {
        let check = candidate.check()
        let errors = check.errors
        if isSetup {
            // Nothing is on disk yet: keep filling in, and save the moment it's valid.
            doc = candidate
            result = check
            shown = check.config ?? Self.decodeLoosely(candidate) ?? shown
            fieldErrors = [:]
            for e in errors {
                if let f = fieldFor(e, in: candidate, preferring: field) { fieldErrors[f] = Self.plain(e.message) }
            }
            if errors.isEmpty { save(candidate) }
            return errors.isEmpty
        }
        guard errors.isEmpty else {
            let issue = errors.first { fieldFor($0, in: candidate, preferring: field) == field } ?? errors[0]
            fieldErrors[field] = Self.plain(issue.message)
            return false
        }
        fieldErrors[field] = nil
        doc = candidate
        result = check
        if let c = check.config { shown = c }
        save(candidate)
        return true
    }

    private func save(_ candidate: ConfigDocument) {
        guard let url else { return }
        do {
            try candidate.write(to: url)
            lastReadText = candidate.text
            if !fileExists {
                fileExists = true
                baselineLines = Set(ConfigDocument.lines(candidate.text))
                opened = shown
            }
            savedOnce = true
            engine?.reloadConfig()
        } catch {
            NSLog("Couldn't save the config: \(error.localizedDescription)")
        }
    }

    /// Which field a checker message is about: the one on its line, or the one it names.
    private func fieldFor(_ issue: ConfigIssue, in candidate: ConfigDocument, preferring field: FieldKey) -> FieldKey? {
        if let line = issue.line {
            if candidate.line(of: field.key, in: field.table) == line || candidate.line(of: field.table) == line { return field }
            for table in Self.tables(candidate) {
                for key in Self.knownKeys(table) where candidate.line(of: key, in: table) == line {
                    return FieldKey(table: table, key: key)
                }
            }
        }
        for table in Self.tables(candidate) {
            for key in Self.knownKeys(table) where issue.message.contains("'\(table.keyPrefix).\(key)'") {
                return FieldKey(table: table, key: key)
            }
        }
        return issue.line == nil ? nil : field
    }

    private static func tables(_ doc: ConfigDocument) -> [ConfigDocument.Table] {
        ["home", "nas", "battery", "folders", "github"].map { .named($0) } + (0..<doc.folderCount).map { .folder($0) }
    }

    private static func knownKeys(_ table: ConfigDocument.Table) -> [String] {
        switch table {
        case .folder: ["name", "source", "dest", "exclude", "enabled"] + FolderJobConfig.overridableKeys
        case .named("home"): ["wifi"]
        case .named("nas"): ["ssh", "port", "path", "rsync", "remote_rsync"]
        case .named("battery"): ["hold_below_percent", "but_not_longer_than"]
        case .named("folders"): ["quiet_period", "at_most_every", "nightly_check", "archive_days", "max_delete_percent", "max_delete_files", "stale_after", "exclude"]
        case .named("github"): ["enabled", "every", "around", "stale_after", "dest", "scan", "repos", "new_repos", "exclude", "remote_only", "groups", "on_remote_delete", "helper_repos"]
        default: []
        }
    }

    /// Checker messages name settings the way the file does, which is fine under a field, except for
    /// "Missing 'nas.path'." while you're still filling in a new setup.
    static func plain(_ message: String) -> String {
        if message.hasPrefix("Missing '") { return "Fill this in." }
        return message
    }

    // MARK: Values

    static func abbreviate(_ url: URL) -> String { abbreviate(url.path(percentEncoded: false)) }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        var p = path
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        if p == h { return "~" }
        return p.hasPrefix(h + "/") ? "~/" + p.dropFirst(h.count + 1) : p
    }

    /// The config a half-filled first-run file would have: lines with mistakes are left out and missing
    /// required settings are filled in, so the form can show everything else.
    private static func decodeLoosely(_ doc: ConfigDocument) -> AppConfig? {
        var d = doc
        var filled: Set<String> = []
        for _ in 0..<20 {
            let r = d.check()
            if var c = r.config {
                if filled.contains("nas.path") { c.nas.path = "" }
                if filled.contains("home.wifi") { c.home.wifi = "" }
                return c
            }
            guard let e = r.errors.first else { return nil }
            if e.message.hasPrefix("Missing '") {
                let name = e.message.split(separator: "'").dropFirst().first.map(String.init) ?? ""
                let parts = name.split(separator: ".").map(String.init)
                guard parts.count == 2, parts[0] != "folder", !filled.contains(name),
                      (try? d.set(parts[1], in: .named(parts[0]), to: .string(parts[1] == "path" ? "/" : "x"))) != nil else { return nil }
                filled.insert(name)
            } else if let line = e.line {
                var lines = ConfigDocument.lines(d.text)
                guard line >= 1, line <= lines.count, !lines[line - 1].trimmingCharacters(in: .whitespaces).hasPrefix("[") else { return nil }
                lines[line - 1] = ""
                d = ConfigDocument(text: lines.joined(separator: "\n"))
            } else {
                return nil
            }
        }
        return nil
    }

    static let defaultGitHub: GitHubConfig = {
        let r = ConfigLoader.parse("[home]\nwifi = \"x\"\n[nas]\npath = \"/x\"\n[github]\nenabled = false\n")
        return r.config!.githubSettings!
    }()

    static let placeholder: AppConfig = {
        var c = ConfigLoader.parse("[home]\nwifi = \"x\"\n[nas]\npath = \"/x\"\n").config!
        c.home.wifi = ""
        c.nas.path = ""
        return c
    }()
}
