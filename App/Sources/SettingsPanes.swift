import AppKit
import SwiftUI
import SyncCore

// MARK: Typed edits

extension SettingsModel {
    func setString(_ f: FieldKey, _ v: String?) { set(f, v.map { .string($0) }) }
    func setInt(_ f: FieldKey, _ v: Int?) { set(f, v.map { .integer($0) }) }
    func setBool(_ f: FieldKey, _ v: Bool?) { set(f, v.map { .boolean($0) }) }
    func setList(_ f: FieldKey, _ v: [String]?) { set(f, v.map { .strings($0) }) }
    func setDuration(_ f: FieldKey, _ v: Interval?) { set(f, v.map { .string(SettingDurationField.toml($0)) }) }
    func setTime(_ f: FieldKey, _ v: TimeOfDay?) { set(f, v.map { .string($0.description) }) }
}

/// A folder picker. Returns the chosen folder.
@MainActor
func chooseDirectory(prompt: String, message: String, startingAt: URL? = nil) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = prompt
    panel.message = message
    panel.directoryURL = startingAt
    return panel.runModal() == .OK ? panel.url : nil
}

// MARK: NAS

struct NASPane: View {
    @Environment(SettingsModel.self) private var s
    /// Chosen in the segmented control but not written yet, because SSH needs a login first.
    @State private var wantsSSH: Bool?
    @State private var steps: [NASCheck.Step]?
    @State private var testing = false

    private let ssh = FieldKey.named("nas", "ssh")
    private let port = FieldKey.named("nas", "port")
    private let path = FieldKey.named("nas", "path")
    private let rsync = FieldKey.named("nas", "rsync")
    private let remote = FieldKey.named("nas", "remote_rsync")

    var body: some View {
        let nas = s.config.nas
        let useSSH = wantsSSH ?? (nas.ssh != nil || (s.isSetup && nas.path.isEmpty))
        SettingsPage(title: "NAS", subtitle: "Where your backups go.") {
            SettingsGroup {
                SettingsRow(label: "Connect with", fileKey: "nas.ssh",
                            help: useSSH ? nil : "For a NAS that is already mounted in Finder, or a disk on this Mac.") {
                    Picker("", selection: Binding(get: { useSSH }, set: { choose(ssh: $0) })) {
                        Text("SSH").tag(true)
                        Text("Folder on this Mac").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if useSSH {
                    SettingsRow(label: "SSH login", fileKey: "nas.ssh", help: "Signs in with your SSH key, never a password. Set it up once with ssh-copy-id.", error: s.error(ssh)) {
                        SettingTextField(value: nas.ssh ?? "", placeholder: "me@nas.local", width: 190, invalid: s.error(ssh) != nil) { v in
                            let t = v.trimmingCharacters(in: .whitespaces)
                            if s.set(ssh, t.isEmpty ? nil : .string(t)) { wantsSSH = nil }
                            steps = nil
                        }
                    }
                    SettingsRow(label: "SSH port", fileKey: "nas.port", error: s.error(port)) {
                        SettingNumberField(value: nas.port, range: 1...65535, invalid: s.error(port) != nil) { s.setInt(port, $0 == 22 ? nil : $0) }
                    }
                }
                SettingsRow(label: "Base folder", fileKey: "nas.path", help: "Every backup goes in a folder inside this one.", error: s.error(path)) {
                    SettingTextField(value: nas.path, placeholder: useSSH ? "/volume1/homes/me" : "/Volumes/Backups", invalid: s.error(path) != nil) { v in
                        s.setString(path, v.trimmingCharacters(in: .whitespaces))
                        steps = nil
                    }
                    if !useSSH {
                        Button("Choose…") {
                            if let url = chooseDirectory(prompt: "Use This Folder", message: "Choose the folder backups go in.", startingAt: URL(filePath: "/Volumes")) {
                                s.setString(path, url.path(percentEncoded: false))
                            }
                        }
                    }
                }
                SettingsRow(label: "Check that this works", help: "Runs the same steps as the checklist in the menu.") {
                    if testing { ProgressView().controlSize(.small) }
                    Button("Test Connection", action: test).disabled(testing || nas.path.isEmpty || s.isSetup)
                }
                if let steps {
                    SettingsWideRow(label: steps.allSatisfy { $0.state == .ok } ? "Everything answered" : "Something didn't answer") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Text(step.state == .ok ? "✓" : step.state == .failed ? "✕" : "–").fontWeight(.bold)
                                        .foregroundStyle(step.state == .ok ? Palette.green : step.state == .failed ? Palette.red : .secondary)
                                    Text(step.title)
                                    if let d = step.detail { Text(d).foregroundStyle(.secondary).lineLimit(2) }
                                }
                            }
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
            SettingsGroup(title: "Advanced") {
                SettingsRow(label: "rsync on this Mac", fileKey: "nas.rsync", help: "Only needed if rsync 3 isn't in /opt/homebrew/bin or /usr/local/bin.", error: s.error(rsync)) {
                    SettingTextField(value: nas.rsync ?? "", placeholder: "Found automatically", width: 190) { v in
                        let t = v.trimmingCharacters(in: .whitespaces)
                        s.setString(rsync, t.isEmpty ? nil : t)
                    }
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.directoryURL = URL(filePath: "/opt/homebrew/bin")
                        if panel.runModal() == .OK, let url = panel.url { s.setString(rsync, url.path(percentEncoded: false)) }
                    }
                }
                if useSSH {
                    SettingsRow(label: "rsync on the NAS", fileKey: "nas.remote_rsync", help: "Synology only accepts the full path.", error: s.error(remote)) {
                        SettingTextField(value: nas.remoteRsync, placeholder: "/usr/bin/rsync", width: 190) { v in
                            let t = v.trimmingCharacters(in: .whitespaces)
                            s.setString(remote, t.isEmpty || t == "/usr/bin/rsync" ? nil : t)
                        }
                    }
                }
            }
        }
    }

    private func choose(ssh useSSH: Bool) {
        steps = nil
        if useSSH {
            wantsSSH = true
        } else {
            wantsSSH = false
            s.set([(ssh, nil), (port, nil), (remote, nil)], reportOn: path)
            s.clearError(ssh)
        }
    }

    private func test() {
        let nasConfig = s.config.nas
        let home = s.config.home.wifi
        testing = true
        steps = nil
        Task {
            let result = await Task.detached {
                NASCheck.diagnose(NAS(config: nasConfig), wifiName: WiFi.currentName(), homeWiFi: home)
            }.value
            steps = result
            testing = false
        }
    }
}

// MARK: When to Sync

struct WhenPane: View {
    @Environment(SettingsModel.self) private var s
    @State private var hold: Double?

    private let wifi = FieldKey.named("home", "wifi")
    private let holdKey = FieldKey.named("battery", "hold_below_percent")
    private let maxKey = FieldKey.named("battery", "but_not_longer_than")

    var body: some View {
        let c = s.config
        let percent = Int(hold ?? Double(c.battery.holdBelowPercent))
        SettingsPage(title: "When to Sync", subtitle: "Backups only run at home, and can wait for the charger.") {
            SettingsGroup(title: "Home") {
                SettingsRow(label: "Home Wi-Fi", fileKey: "home.wifi", help: "Nothing syncs on any other network.", error: s.error(wifi)) {
                    SettingTextField(value: c.home.wifi, placeholder: "Network name", mono: false, width: 190, invalid: s.error(wifi) != nil) { s.setString(wifi, $0) }
                    Button("Use Current Network") {
                        if let name = WiFi.currentName() { s.setString(wifi, name) }
                    }
                    .disabled(WiFi.currentName() == nil)
                }
            }
            SettingsGroup(title: "On battery") {
                SettingsRow(label: "Wait when the charge is below", fileKey: "battery.hold_below_percent",
                            help: percent == 0 ? "Never waits, whatever the charge." : "Syncing waits until you plug in or the charge comes back up. Set to 0% to never wait.",
                            error: s.error(holdKey)) {
                    Slider(value: Binding(get: { hold ?? Double(c.battery.holdBelowPercent) }, set: { hold = $0.rounded() }), in: 0...100, step: 1,
                           onEditingChanged: { editing in
                               if !editing, let h = hold {
                                   s.setInt(holdKey, Int(h))
                                   hold = nil
                               }
                           })
                    .frame(width: 150)
                    Text("\(percent)%").font(.system(size: 12.5)).foregroundStyle(.secondary).monospacedDigit().frame(width: 36, alignment: .trailing)
                }
                SettingsRow(label: "But run anyway after", fileKey: "battery.but_not_longer_than",
                            help: "Once the last backup is older than this, the charge no longer matters.", error: s.error(maxKey)) {
                    SettingDurationField(value: c.battery.butNotLongerThan, invalid: s.error(maxKey) != nil) { s.setDuration(maxKey, $0) }
                }
            }
        }
    }
}

// MARK: All Folders

struct AllFoldersPane: View {
    @Environment(SettingsModel.self) private var s

    private func f(_ key: String) -> FieldKey { .named("folders", key) }

    var body: some View {
        let d = s.config.folderDefaults
        let atMostOn = d.atMostEvery.seconds > 0
        SettingsPage(title: "All Folders", subtitle: "Every folder uses these unless the folder sets its own.") {
            SettingsGroup(title: "Copying changes") {
                SettingsRow(label: "Wait for changes to settle", fileKey: "folders.quiet_period", help: "So a save in progress isn't copied halfway.", error: s.error(f("quiet_period"))) {
                    SettingDurationField(value: d.quietPeriod) { s.setDuration(f("quiet_period"), $0) }
                }
                SettingsRow(label: "Sync changes at most every", fileKey: "folders.at_most_every",
                            help: atMostOn ? "For folders that change constantly." : "Off: changes are copied as they happen.", error: s.error(f("at_most_every"))) {
                    if atMostOn {
                        SettingDurationField(value: d.atMostEvery) { s.setDuration(f("at_most_every"), $0) }
                    }
                    SettingToggle(isOn: atMostOn) { on in s.setDuration(f("at_most_every"), on ? .hours(1) : nil) }
                }
                SettingsRow(label: "Full check every night at", fileKey: "folders.nightly_check", help: "Compares every folder in full, in case a change was missed.") {
                    SettingTimeField(value: d.nightlyCheck) { s.setTime(f("nightly_check"), $0) }
                }
            }
            SettingsGroup(title: "Old versions") {
                SettingsRow(label: "Keep replaced and deleted files for", fileKey: "folders.archive_days",
                            help: "They move to a dated _archive folder on the NAS instead of being lost.", error: s.error(f("archive_days"))) {
                    SettingNumberField(value: d.archiveDays, range: 1...36500, suffix: "days", invalid: s.error(f("archive_days")) != nil) { s.setInt(f("archive_days"), $0) }
                }
            }
            SettingsGroup(title: "Safety limits", footer: "A run that would go over either limit stops and asks you first.") {
                SettingsRow(label: "Archive more than", fileKey: "folders.max_delete_percent", error: s.error(f("max_delete_percent"))) {
                    SettingNumberField(value: d.maxDeletePercent, range: 1...100, suffix: "% of the backup", invalid: s.error(f("max_delete_percent")) != nil) { s.setInt(f("max_delete_percent"), $0) }
                }
                SettingsRow(label: "Or more than", fileKey: "folders.max_delete_files", error: s.error(f("max_delete_files"))) {
                    SettingNumberField(value: d.maxDeleteFiles, range: 1...Int.max, suffix: "files", invalid: s.error(f("max_delete_files")) != nil) { s.setInt(f("max_delete_files"), $0) }
                }
            }
            SettingsGroup(title: "Alerts") {
                SettingsRow(label: "Warn after no backup for", fileKey: "folders.stale_after", help: "Only counts time you were home.", error: s.error(f("stale_after"))) {
                    SettingDurationField(value: d.staleAfter) { s.setDuration(f("stale_after"), $0) }
                }
            }
            SettingsGroup(title: "Skip in every folder",
                          footer: "Patterns follow rsync's rules: node_modules/ matches a folder with that name anywhere, and /build/ only matches one at the top of the folder.") {
                SettingsWideRow(label: "Files and folders never copied", fileKey: "folders.exclude", error: s.error(f("exclude"))) {
                    let list = d.exclude
                    let restore: [(String, () -> Void)] = list == FolderDefaults.builtinExclude ? [] : [("Restore Defaults", { write(FolderDefaults.builtinExclude) })]
                    TokenList(items: list, placeholder: "Add pattern…",
                              remove: { i in write(list.enumerated().filter { $0.offset != i }.map(\.element)) },
                              add: { p in if !list.contains(p) { write(list + [p]) } },
                              buttons: restore)
                    SuggestedPatterns(have: list) { p in write(list + [p]) }
                }
            }
        }
    }

    private func write(_ list: [String]) {
        s.setList(f("exclude"), list == FolderDefaults.builtinExclude ? nil : list)
    }
}

// MARK: One folder

struct FolderPane: View {
    @Environment(SettingsModel.self) private var s
    var index: Int

    private func f(_ key: String) -> FieldKey { .folder(index, key) }

    var body: some View {
        let folders = s.config.allFolders
        if folders.indices.contains(index) {
            content(folders[index])
        } else {
            SettingsNote(text: "This folder isn't in the config any more.")
        }
    }

    @ViewBuilder
    private func content(_ job: FolderJobConfig) -> some View {
        let d = s.config.folderDefaults
        let opened = s.opened?.allFolders[safe: index]
        let source = SettingsModel.abbreviate(job.source)
        let nameWarning = opened.flatMap { $0.name != job.name ? "Renaming starts this folder's record over: its last backup time resets and the next run compares everything." : nil }
        let destWarning = opened.flatMap { $0.dest != job.dest ? "The new NAS folder starts empty, so everything gets copied there again. The old folder stays on the NAS." : nil }
        let prefix = (s.config.nas.path.isEmpty ? "/…" : s.config.nas.path) + "/"

        SettingsPage(title: job.name.isEmpty ? "Untitled folder" : job.name, subtitle: "Backs up one folder from this Mac to the NAS.") {
            SettingsGroup {
                SettingsRow(label: "Back up this folder", fileKey: "folder.enabled",
                            help: job.enabled ? nil : "Paused. Nothing syncs until you turn it back on; the copy on the NAS is kept.") {
                    SettingToggle(isOn: job.enabled) { on in s.setBool(f("enabled"), on ? nil : false) }
                }
                SettingsRow(label: "Name", fileKey: "folder.name", error: s.error(f("name")), warning: s.error(f("name")) == nil ? nameWarning : nil) {
                    SettingTextField(value: job.name, mono: false, width: 190, invalid: s.error(f("name")) != nil) { s.setString(f("name"), $0.trimmingCharacters(in: .whitespaces)) }
                }
                SettingsRow(label: "On this Mac", fileKey: "folder.source", error: s.error(f("source"))) {
                    SettingTextField(value: source, invalid: s.error(f("source")) != nil) { s.setString(f("source"), $0.trimmingCharacters(in: .whitespaces)) }
                    Button("Choose…") {
                        if let url = chooseDirectory(prompt: "Back Up This Folder", message: "Choose the folder to back up.", startingAt: job.source) {
                            s.setString(f("source"), SettingsModel.abbreviate(url))
                        }
                    }
                }
                SettingsRow(label: "On the NAS", fileKey: "folder.dest", error: s.error(f("dest")), warning: s.error(f("dest")) == nil ? destWarning : nil) {
                    Text(prefix).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head).frame(maxWidth: 160, alignment: .trailing)
                    SettingTextField(value: job.dest, placeholder: "Mac/Documents", width: 190, invalid: s.error(f("dest")) != nil) { s.setString(f("dest"), $0.trimmingCharacters(in: .whitespaces)) }
                }
            }

            SettingsGroup(title: "Skip in this folder", footer: "Added to the \(d.exclude.count) patterns skipped in every folder.") {
                SettingsWideRow(label: "Extra files and folders not copied", fileKey: "folder.exclude",
                                help: "Choose picks exact files or folders inside \(source). Patterns match by name anywhere.", error: s.error(f("exclude"))) {
                    let list = job.ownExclude
                    if !list.isEmpty {
                        PathRowList(items: list) { i in writeExclude(list.enumerated().filter { $0.offset != i }.map(\.element)) }
                    }
                    PatternAdder(placeholder: "Add pattern…", add: { p in if !list.contains(p) { writeExclude(list + [p]) } }) {
                        Button("Choose Files or Folders…") { pick(in: job, list: list) }
                    }
                    SuggestedPatterns(have: list + d.exclude) { p in writeExclude(list + [p]) }
                }
            }

            SettingsGroup(title: "Settings for this folder",
                          footer: "Gray values come from All Folders and follow it if it changes. Set a different one and a blue dot marks it as this folder's own.") {
                durationRow("Wait for changes to settle", "quiet_period", job.quietPeriod, d.quietPeriod, job)
                atMostRow(job, d)
                numberRow("Keep replaced and deleted files for", "archive_days", job.archiveDays, d.archiveDays, 1...36500, "days", job)
                numberRow("Ask before archiving more than", "max_delete_percent", job.maxDeletePercent, d.maxDeletePercent, 1...100, "% of the backup", job)
                numberRow("Or more than", "max_delete_files", job.maxDeleteFiles, d.maxDeleteFiles, 1...Int.max, "files", job)
                durationRow("Warn after no backup for", "stale_after", job.staleAfter, d.staleAfter, job)
            }

            HStack {
                Button("Remove Folder…", role: .destructive) { s.removingFolder = index }
                    .foregroundStyle(Palette.red)
            }
        }
    }

    private func durationRow(_ label: String, _ key: String, _ value: Interval, _ inherited: Interval, _ job: FolderJobConfig) -> some View {
        let custom = job.overrides.contains(key)
        return SettingsRow(label: label, fileKey: "folder.\(key)", custom: custom, error: s.error(f(key)),
                           onReset: custom ? { _ = s.set(f(key), nil) } : nil) {
            SettingDurationField(value: value, invalid: s.error(f(key)) != nil, ghost: !custom) { v in
                s.setDuration(f(key), v == inherited ? nil : v)
            }
        }
    }

    private func numberRow(_ label: String, _ key: String, _ value: Int, _ inherited: Int, _ range: ClosedRange<Int>, _ suffix: String, _ job: FolderJobConfig) -> some View {
        let custom = job.overrides.contains(key)
        return SettingsRow(label: label, fileKey: "folder.\(key)", custom: custom, error: s.error(f(key)),
                           onReset: custom ? { _ = s.set(f(key), nil) } : nil) {
            SettingNumberField(value: value, range: range, suffix: suffix, invalid: s.error(f(key)) != nil, ghost: !custom) { v in
                s.setInt(f(key), v == inherited ? nil : v)
            }
        }
    }

    /// On and off, where off on a folder is written as "off" so it can opt out of a shared limit.
    private func atMostRow(_ job: FolderJobConfig, _ d: FolderDefaults) -> some View {
        let key = "at_most_every"
        let custom = job.overrides.contains(key)
        let on = job.atMostEvery.seconds > 0
        func write(_ v: Interval) {
            if v == d.atMostEvery { s.set(f(key), nil) } else if v.seconds == 0 { s.setString(f(key), "off") } else { s.setDuration(f(key), v) }
        }
        return SettingsRow(label: "Sync changes at most every", fileKey: "folder.\(key)", help: on ? nil : "Off: changes are copied as they happen.",
                           custom: custom, error: s.error(f(key)), onReset: custom ? { _ = s.set(f(key), nil) } : nil) {
            if on {
                SettingDurationField(value: job.atMostEvery, ghost: !custom) { write($0) }
            }
            SettingToggle(isOn: on) { write($0 ? .hours(1) : Interval(seconds: 0)) }
        }
    }

    private func writeExclude(_ list: [String]) {
        s.setList(f("exclude"), list.isEmpty ? nil : list)
    }

    /// Adds exact paths inside the folder, like `/Archive/2019/`, as rsync anchored patterns.
    private func pick(in job: FolderJobConfig, list: [String]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = job.source
        panel.prompt = "Skip"
        panel.message = "Choose files or folders inside \(job.name) that shouldn't be copied."
        guard panel.runModal() == .OK else { return }
        let root = job.source.standardizedFileURL.path(percentEncoded: false)
        let base = root.hasSuffix("/") ? root : root + "/"
        var added = list
        for url in panel.urls {
            let p = url.standardizedFileURL.path(percentEncoded: false)
            guard p.hasPrefix(base) else { continue }
            var rel = "/" + p.dropFirst(base.count)
            if url.hasDirectoryPath, !rel.hasSuffix("/") { rel += "/" }
            if !added.contains(rel) { added.append(rel) }
        }
        if added != list { writeExclude(added) }
    }
}

/// A pattern field, with room for buttons after it.
struct PatternAdder<Extra: View>: View {
    var placeholder: String
    var add: (String) -> Void
    @ViewBuilder var content: Extra
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(width: 170)
                .onSubmit {
                    let v = draft.trimmingCharacters(in: .whitespaces)
                    guard !v.isEmpty else { return }
                    draft = ""
                    add(v)
                }
            content
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: Git Repos

/// Shown at the top of each Git Repos page while backups are off.
private struct GitOffNote: View {
    @Environment(SettingsModel.self) private var s

    var body: some View {
        if !s.githubOn {
            SettingsNote(text: "Git backups are off. These settings are kept for when you turn them back on in Git Repos.")
        }
    }
}

struct GitPane: View {
    @Environment(SettingsModel.self) private var s

    private func f(_ key: String) -> FieldKey { .named("github", key) }

    var body: some View {
        let g = s.github
        let on = s.githubOn
        SettingsPage(title: "Git Repos", subtitle: "Backs up each repo as one git mirror on the NAS. Anything deleted at the source stays on the NAS.") {
            SettingsGroup {
                SettingsRow(label: "Back up Git repos", fileKey: "github.enabled",
                            help: on ? nil : "Off. All repo settings are kept for when you turn it back on.", error: s.error(f("enabled"))) {
                    SettingToggle(isOn: on) { setOn($0) }
                }
            }
            SettingsGroup(title: "Schedule", dimmed: !on) {
                SettingsRow(label: "Run every", fileKey: "github.every", error: s.error(f("every"))) {
                    SettingDurationField(value: g.every) { s.setDuration(f("every"), $0) }
                }
                SettingsRow(label: "Preferred time", fileKey: "github.around",
                            help: g.around == nil ? "Off: runs whenever the last run is old enough." : "A missed run catches up later.") {
                    if let around = g.around {
                        SettingTimeField(value: around) { s.setTime(f("around"), $0) }
                    }
                    SettingToggle(isOn: g.around != nil) { s.setTime(f("around"), $0 ? TimeOfDay(hour: 3, minute: 0) : nil) }
                }
            }
            SettingsGroup(title: "Alerts", dimmed: !on) {
                SettingsRow(label: "Warn after no backup for", fileKey: "github.stale_after", help: "Only counts time you were home.", error: s.error(f("stale_after"))) {
                    SettingDurationField(value: g.staleAfter) { s.setDuration(f("stale_after"), $0) }
                }
            }
        }
    }

    private func setOn(_ on: Bool) {
        if s.config.githubSettings == nil {
            // No [github] section yet: start one that looks in the usual place for clones.
            guard on else { return }
            s.set([(f("every"), .string("24h")), (f("scan"), .strings(["~/Documents/GitHub"]))], reportOn: f("enabled"))
        } else {
            s.setBool(f("enabled"), on ? nil : false)
        }
    }
}

struct GitConfigPane: View {
    @Environment(SettingsModel.self) private var s

    private func f(_ key: String) -> FieldKey { .named("github", key) }

    var body: some View {
        let g = s.github
        let on = s.githubOn
        let scan = g.scan.map(SettingsModel.abbreviate)
        SettingsPage(title: "Config", subtitle: "Where the app looks for repos on this Mac, and which ones it leaves out.") {
            GitOffNote()
            SettingsGroup(title: "Repos on this Mac", dimmed: !on) {
                SettingsWideRow(label: "Look for clones in", fileKey: "github.scan",
                                help: "Repos here are backed up from this Mac, so unpushed commits and local branches are included.", error: s.error(f("scan"))) {
                    TokenList(items: scan, placeholder: "Add path…",
                              remove: { i in s.setList(f("scan"), scan.enumerated().filter { $0.offset != i }.map(\.element)) },
                              add: { p in if !scan.contains(p) { s.setList(f("scan"), scan + [p]) } },
                              buttons: [("Add Folder…", {
                                  if let url = chooseDirectory(prompt: "Look Here", message: "Choose a folder to look for git clones in.") {
                                      let p = SettingsModel.abbreviate(url)
                                      if !scan.contains(p) { s.setList(f("scan"), scan + [p]) }
                                  }
                              })])
                }
                SettingsRow(label: "When a new clone turns up", fileKey: "github.new_repos",
                            help: g.newRepos == .prompt ? "The menu asks whether to back it up." : "Either way, the menu tells you about it.") {
                    Picker("", selection: Binding(get: { g.newRepos }, set: { v in s.setString(f("new_repos"), v == .prompt ? nil : v.rawValue) })) {
                        Text("Ask Me").tag(GitHubConfig.NewRepos.prompt)
                        Text("Back It Up").tag(GitHubConfig.NewRepos.include)
                        Text("Only Tell Me").tag(GitHubConfig.NewRepos.ignore)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            SettingsGroup(title: "Skip", dimmed: !on) {
                SettingsWideRow(label: "Skip these repos", fileKey: "github.exclude", help: "owner/* skips everything from one owner.", error: s.error(f("exclude"))) {
                    TokenList(items: g.exclude, placeholder: "owner/repo or owner/*",
                              remove: { i in s.setList(f("exclude"), g.exclude.enumerated().filter { $0.offset != i }.map(\.element)) },
                              add: { p in if !g.exclude.contains(p) { s.setList(f("exclude"), g.exclude + [p]) } })
                }
            }
        }
    }
}

struct GitNASPane: View {
    @Environment(SettingsModel.self) private var s

    private func f(_ key: String) -> FieldKey { .named("github", key) }

    var body: some View {
        let g = s.github
        let on = s.githubOn
        let prefix = (s.config.nas.path.isEmpty ? "/…" : s.config.nas.path) + "/"
        SettingsPage(title: "On the NAS", subtitle: "Where repo backups go, and what happens to branches deleted at the source.") {
            GitOffNote()
            SettingsGroup(title: "Where on the NAS", dimmed: !on) {
                SettingsRow(label: "Folder", fileKey: "github.dest", help: "Each repo is a git mirror in mirrors/<group>/<repo>.git inside this folder.", error: s.error(f("dest"))) {
                    Text(prefix).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head).frame(maxWidth: 160, alignment: .trailing)
                    SettingTextField(value: g.dest, width: 190, invalid: s.error(f("dest")) != nil) { s.setString(f("dest"), $0.trimmingCharacters(in: .whitespaces)) }
                }
                SettingsWideRow(label: "Sort repos into folders by owner", fileKey: "github.groups",
                                help: "Repos with no GitHub remote always go in the \(GitHubConfig.localGroup) folder.", error: s.error(f("groups"))) {
                    GroupsEditor(pairs: g.groupList) { pairs in
                        s.set(f("groups"), pairs.isEmpty ? nil : .stringTable(pairs.map { .init($0.owner, $0.folder) }))
                    }
                }
            }
            SettingsGroup(title: "Deleted at the source",
                          footer: "Kept branches and tags move to refs/deleted/<date>/ in the mirror. A repo deleted from GitHub keeps its mirror either way.",
                          dimmed: !on) {
                SettingsRow(label: "When a branch or tag is deleted", fileKey: "github.on_remote_delete",
                            help: g.onRemoteDelete == .keep ? "Force-pushed and deleted work can still be restored from the NAS." : "The NAS matches the source. Commits only on a deleted branch are lost.") {
                    Picker("", selection: Binding(get: { g.onRemoteDelete }, set: { v in s.setString(f("on_remote_delete"), v == .keep ? nil : v.rawValue) })) {
                        Text("Keep It on the NAS").tag(GitHubConfig.OnRemoteDelete.keep)
                        Text("Delete It There Too").tag(GitHubConfig.OnRemoteDelete.prune)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            NASHelperSection(repoPatterns: g.helperRepos, dimmed: !on)
        }
    }
}

/// The helper on the NAS: its version, health checks and latest run.
struct NASHelperSection: View {
    @Environment(AppModel.self) private var model
    var repoPatterns: [String]
    var dimmed = false

    var body: some View {
        let status = model.engine.status
        let problem = status.helper.flatMap { Diagnosis.forHelper($0) } ?? Diagnosis.forHelperRun(status.helperRun)
        if let problem { ProblemCard(subject: "NAS helper", diagnosis: problem, compact: true) }
        SettingsGroup(title: "NAS helper",
                      footer: "A small program on the NAS that backs up repos straight from GitHub, including Git LFS files. NAS Sync installs and updates it.",
                      dimmed: dimmed) {
            SettingsRow(label: "Version") { valueText(versionText(status)) }
            SettingsRow(label: "Repos it backs up", fileKey: "github.helper_repos",
                        help: repoPatterns.isEmpty ? "This Mac still backs up every repo itself." : nil) {
                valueText(reposText(status))
            }
            ForEach(status.helper?.checks ?? []) { check in
                SettingsRow(label: checkLabel(check)) {
                    HStack(spacing: 6) {
                        StatusDot(color: checkColor(check))
                        valueText(checkDetail(check))
                    }
                }
            }
            SettingsRow(label: "Latest run") { valueText(runText(status.helperRun)) }
            SettingsRow(label: "") {
                Button("Check Again") { model.engine.checkHelperNow() }.disabled(!status.nasConnected)
                Button("Run Now") { model.engine.runHelperNow() }
                    .disabled(!status.nasConnected || repoPatterns.isEmpty || status.helperRun?.isFinished == false)
            }
        }
    }

    private func valueText(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(text)
    }

    private func versionText(_ status: StatusSnapshot) -> String {
        guard let report = status.helper else { return status.nasConnected ? "Not checked yet" : "NAS not connected" }
        guard let installed = report.installedVersion else { return "Not installed" }
        switch report.state {
        case .ready: return "Version \(installed), up to date"
        case .needsInstall: return "Version \(installed), update available"
        case .appTooOld: return "Version \(installed), newer than this app"
        case .failed: return "Version \(installed), couldn't update"
        }
    }

    private func reposText(_ status: StatusSnapshot) -> String {
        if repoPatterns.isEmpty { return "None yet" }
        return status.helperRun?.total.map { Format.count($0, "repo") } ?? repoPatterns.joined(separator: ", ")
    }

    private func checkLabel(_ check: HelperCheck) -> String {
        if let owner = check.tokenOwner { return "GitHub token for \(owner)" }
        return switch check.id {
        case "python": "Python"
        case "git": "Git"
        case "git-lfs": "Git LFS"
        case "git-transport": "Git over SSH"
        case "tokens": "GitHub tokens"
        default: check.id
        }
    }

    private func checkColor(_ check: HelperCheck) -> Color {
        switch check.status {
        case .ok: Palette.green
        case .failed: Palette.red
        case .unknown: Palette.grey
        }
    }

    private func checkDetail(_ check: HelperCheck) -> String {
        guard let expires = check.expires else { return check.detail }
        return "\(check.detail), expires \(expires.formatted(date: .abbreviated, time: .omitted))"
    }

    private func runText(_ run: HelperRunReport?) -> String {
        guard let run else { return "Hasn't run yet" }
        if !run.isFinished {
            let done = "\(run.repos.count) of \(run.total ?? 0) done"
            return run.current.map { "Running: \(done), on \($0)" } ?? "Running: \(done)"
        }
        let when = run.finished.map { StatusText.dayAndTime($0) } ?? ""
        return "\(when): \(run.runRecord().summary)"
    }
}

/// Owner → NAS folder pairs. "Everyone else" (`*`) is always last and can't be removed.
struct GroupsEditor: View {
    var pairs: [(owner: String, folder: String)]
    var commit: ([(owner: String, folder: String)]) -> Void

    var body: some View {
        let named = pairs.filter { $0.owner != "*" }
        let fallback = pairs.first { $0.owner == "*" }?.folder ?? "other"
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Owner on GitHub").frame(width: 170, alignment: .leading)
                Text("").frame(width: 16)
                Text("Folder on the NAS").frame(width: 170, alignment: .leading)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(Array(named.enumerated()), id: \.offset) { i, p in
                HStack(spacing: 6) {
                    SettingTextField(value: p.owner, width: 170) { v in update(named, fallback) { $0[i].owner = v } }
                    Text("→").foregroundStyle(.secondary).frame(width: 16)
                    SettingTextField(value: p.folder, width: 170) { v in update(named, fallback) { $0[i].folder = v } }
                    Button { update(named, fallback) { $0.remove(at: i) } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Remove \(p.owner)")
                }
            }
            HStack(spacing: 6) {
                Text("Everyone else").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
                Text("→").foregroundStyle(.secondary).frame(width: 16)
                SettingTextField(value: fallback, width: 170) { v in commit(named + [(owner: "*", folder: v)]) }
            }
            Button("Add Owner") {
                var n = 1
                var owner = "owner"
                while named.contains(where: { $0.owner == owner }) { n += 1; owner = "owner\(n)" }
                commit(named + [(owner: owner, folder: owner), (owner: "*", folder: fallback)])
            }
        }
    }

    private func update(_ named: [(owner: String, folder: String)], _ fallback: String, _ change: (inout [(owner: String, folder: String)]) -> Void) {
        var list = named
        change(&list)
        commit(list + [(owner: "*", folder: fallback)])
    }
}

// MARK: Git Repos › Repos

/// Every repo the config would back up, where it comes from, and the space its mirror takes.
struct GitReposPane: View {
    @Environment(SettingsModel.self) private var s
    @Environment(AppModel.self) private var model
    @State private var found: (targets: [RepoTarget], excluded: [RepoTarget])?
    @State private var draft = ""
    @State private var message: String?

    private func f(_ key: String) -> FieldKey { .named("github", key) }

    struct Row: Identifiable {
        enum RepoState: Equatable { case on, off, skippedBy(String) }
        var id: String { name.lowercased() }
        var name: String
        var fromMac: Bool
        var location: String
        var size: Int64?
        var state: RepoState
        var noRemote: Bool
    }

    var body: some View {
        let g = s.github
        let on = s.githubOn
        SettingsPage(title: "Repos", subtitle: "Every repo that gets backed up, where it comes from and how much space it takes.") {
            GitOffNote()
            SettingsGroup(footer: "Repos from this Mac don't need a GitHub remote; ones without one go in the \(GitHubConfig.localGroup) folder on the NAS. Repos from GitHub are saved as remote_only. Turning a repo off adds it to the skip list in Config; its copy on the NAS is kept.",
                          dimmed: !on) {
                VStack(spacing: 0) {
                    header
                    if let found {
                        let rows = Self.rows(found, config: g, sizes: sizes())
                        ForEach(rows) { row in
                            Divider()
                            repoRow(row, config: g)
                        }
                        Divider()
                        HStack(spacing: 12) {
                            Text("\(rows.filter { $0.state == .on }.count) of \(rows.count) backed up")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Self.size(rows.compactMap(\.size).reduce(0, +)))
                                .foregroundStyle(.primary).monospacedDigit().frame(width: 70, alignment: .trailing)
                            Spacer().frame(width: 40)
                        }
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    } else {
                        Divider()
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Looking for repos…").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    Divider()
                    adders(g)
                }
                .padding(.bottom, 4)
            }
        }
        .task(id: g) { await discover(g) }
        .onChange(of: g) { message = nil }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Repo").frame(maxWidth: .infinity, alignment: .leading)
            Text("Backed up from").frame(width: 190, alignment: .leading)
            Text("On NAS").frame(width: 70, alignment: .trailing)
            Spacer().frame(width: 40)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.primary.opacity(0.03))
    }

    private func repoRow(_ row: Row, config g: GitHubConfig) -> some View {
        let note: String? = switch row.state {
        case .skippedBy(let p): "Skipped by \(p)"
        case .off: "Off. Nothing new is backed up"
        case .on: row.noRemote ? "No GitHub remote. The NAS has the only other copy" : nil
        }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.fromMac ? "This Mac" : "GitHub").font(.system(size: 12))
                Text(row.location).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head).help(row.location)
            }
            .frame(width: 190, alignment: .leading)
            Text(row.size.map(Self.size) ?? "–").font(.system(size: 12)).monospacedDigit().frame(width: 70, alignment: .trailing)
            HStack {
                if case .skippedBy(let p) = row.state {
                    SettingToggle(isOn: false) { _ in }.disabled(true).help("Change \(p) in Config to back this repo up.")
                } else {
                    SettingToggle(isOn: row.state == .on) { toggle(row, on: $0, config: g) }
                }
            }
            .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .opacity(row.state == .on ? 1 : 0.55)
        .help("Back up this repo")
    }

    private func adders(_ g: GitHubConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button("Add Repo from This Mac…") { addLocal(g) }
                Text("or from GitHub").font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.leading, 6)
                TextField("owner/repo or URL", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(width: 190)
                    .onSubmit { addRemote(g) }
                    .onChange(of: draft) { message = nil }
                Button("Add") { addRemote(g) }.disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let message {
                Text(message).font(.system(size: 11.5)).foregroundStyle(Palette.red)
            }
            if let e = s.error(f("remote_only")) ?? s.error(f("repos")) ?? s.error(f("exclude")) {
                RowMessage(text: e, isError: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: Data

    private func discover(_ g: GitHubConfig) async {
        let result = await Task.detached { RepoDiscovery.targets(config: g) }.value
        found = result
    }

    private func sizes() -> [String: Int64] {
        var out: [String: Int64] = [:]
        for r in model.engine.store.repos() {
            if let size = r.sizeOnNAS { out[r.fullName.lowercased()] = size }
        }
        return out
    }

    static func rows(_ found: (targets: [RepoTarget], excluded: [RepoTarget]), config g: GitHubConfig, sizes: [String: Int64]) -> [Row] {
        func row(_ t: RepoTarget, state: Row.RepoState) -> Row {
            let fromMac = t.source == .localClone
            let location = fromMac ? (t.localPath.map(SettingsModel.abbreviate) ?? "") : "github.com/\(t.fullName)"
            return Row(name: t.fullName, fromMac: fromMac, location: location, size: sizes[t.fullName.lowercased()], state: state, noRemote: !t.hasGitHubRemote)
        }
        let on = found.targets.map { row($0, state: .on) }
        let off = found.excluded.map { t -> Row in
            let name = t.fullName.lowercased()
            if g.exclude.contains(where: { $0.lowercased() == name }) { return row(t, state: .off) }
            let pattern = g.exclude.first { p in GlobSet([p]).matches(t.fullName) || GlobSet([p]).matches(name) } ?? "a skip pattern"
            return row(t, state: .skippedBy(pattern))
        }
        return (on + off).sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func size(_ bytes: Int64) -> String {
        bytes <= 0 ? "–" : bytes < 1_000_000 ? "<1 MB" : Format.bytes(bytes)
    }

    // MARK: Changes

    private func toggle(_ row: Row, on: Bool, config g: GitHubConfig) {
        if on {
            s.setList(f("exclude"), g.exclude.filter { $0.lowercased() != row.id })
        } else if !g.exclude.contains(where: { $0.lowercased() == row.id }) {
            s.setList(f("exclude"), g.exclude + [row.name])
        }
    }

    private func known() -> Set<String> {
        guard let found else { return [] }
        return Set((found.targets + found.excluded).map { $0.fullName.lowercased() })
    }

    private func addLocal(_ g: GitHubConfig) {
        message = nil
        guard let url = chooseDirectory(prompt: "Back Up This Repo", message: "Choose a git repo on this Mac. It doesn't need a GitHub remote.") else { return }
        let dotGit = url.appending(path: ".git").path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: dotGit) else {
            message = "\(url.lastPathComponent) isn't a git repo. Choose the folder that has the .git folder in it."
            return
        }
        let path = SettingsModel.abbreviate(url)
        let name = RepoDiscovery.githubRemote(of: url).map { "\($0.owner)/\($0.repo)" } ?? url.lastPathComponent
        if g.repos.map(SettingsModel.abbreviate).contains(path) || known().contains(name.lowercased()) {
            message = "\(name) is already in the list."
            return
        }
        s.setList(f("repos"), g.repos.map(SettingsModel.abbreviate) + [path])
    }

    private func addRemote(_ g: GitHubConfig) {
        let raw = draft.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        var name = raw
        if let parsed = GitHubRemote.parse(raw) {
            name = "\(parsed.owner)/\(parsed.repo)"
        } else {
            if name.hasSuffix(".git") { name.removeLast(4) }
            while name.hasSuffix("/") { name.removeLast() }
        }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            message = "Use owner/repo, for example acme/keymap-tools."
            return
        }
        if known().contains(name.lowercased()) || g.remoteOnly.contains(where: { $0.lowercased() == name.lowercased() }) {
            message = "\(name) is already in the list."
            return
        }
        if s.set(f("remote_only"), .strings(g.remoteOnly + [name])) {
            draft = ""
            message = nil
        }
    }
}
