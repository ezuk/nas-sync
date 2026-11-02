import AppKit
import SwiftUI
import SyncCore

/// Every setting NAS Sync has, as a native form over the config file.
///
/// The sidebar follows three questions: where backups go (NAS), when they run (When to Sync), and what gets
/// backed up (All Folders, each folder, Git Repos). App settings that aren't in the file come last.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var settings = SettingsModel()
    /// Opens on this page instead of the usual one (used to render screenshots).
    var initialPane: SettingsPane? = nil

    var body: some View {
        NavigationSplitView {
            SettingsSidebar()
                .navigationSplitViewColumnWidth(190)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    banners
                    Group {
                        switch settings.pane {
                        case .nas: NASPane()
                        case .when: WhenPane()
                        case .allFolders: AllFoldersPane()
                        case .folder(let i): FolderPane(index: i).id(i)
                        case .git: GitPane()
                        case .gitConfig: GitConfigPane()
                        case .gitRepos: GitReposPane()
                        case .gitNAS: GitNASPane()
                        case .general: GeneralPane()
                        case .permissions: PermissionsPane()
                        case .file: ConfigFilePane()
                        }
                    }
                    .disabled(settings.isLocked && settings.pane.isInFile)
                    .opacity(settings.isLocked && settings.pane.isInFile ? 0.5 : 1)
                }
                .padding(EdgeInsets(top: 20, leading: 24, bottom: 22, trailing: 24))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { SettingsFooter() }
        }
        .navigationTitle("Settings")
        .frame(minWidth: 820, minHeight: 560)
        .environment(settings)
        .onAppear {
            settings.attach(model.engine)
            if let initialPane {
                settings.pane = initialPane
            } else if let requested = model.requestedSettingsPane {
                settings.pane = requested
                model.clearRequestedSettingsPane()
            } else if !model.location.isAllowed, !settings.isSetup {
                settings.pane = .permissions
            }
        }
        .onChange(of: model.requestedSettingsPane) {
            guard let requested = model.requestedSettingsPane else { return }
            settings.pane = requested
            model.clearRequestedSettingsPane()
        }
        .onChange(of: model.engine.configURL) { settings.attach(model.engine) }
        .onChange(of: model.engine.config) { settings.reload() }
        .onChange(of: model.engine.status.configIssues) { settings.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in settings.reload() }
        .sheet(isPresented: Binding(get: { settings.removingFolder != nil }, set: { if !$0 { settings.removingFolder = nil } })) {
            RemoveFolderSheet().environment(settings)
        }
    }

    @ViewBuilder
    private var banners: some View {
        if settings.isLocked, settings.pane.isInFile, let e = settings.firstError {
            let name = model.engine.configURL.lastPathComponent
            let at = e.line.map { " on line \($0)" } ?? ""
            let after = model.engine.status.usingLastGoodConfig
                ? "Still running the last valid version of this file until it's fixed."
                : "Nothing syncs until it's fixed."
            SettingsBanner(kind: .error, title: "\(name) has a mistake\(at), so these settings are locked.",
                           detail: "\(e.description.prefix(1).uppercased() + e.description.dropFirst()). \(after)") {
                Button("Open in Editor") { model.openConfigInEditor() }.buttonStyle(.borderedProminent)
            }
        } else if settings.isSetup, settings.pane.isInFile {
            SetupBanner()
        }
    }
}

extension SettingsPane {
    /// Pages whose settings are stored in the config file.
    var isInFile: Bool {
        switch self {
        case .general, .permissions, .file: false
        default: true
        }
    }
}

// MARK: Sidebar

struct SettingsSidebar: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        List(selection: Binding(get: { settings.pane }, set: { if let p = $0 { settings.pane = p } })) {
            Section("Backups") {
                item("NAS", .nas)
                item("When to Sync", .when)
                item("All Folders", .allFolders)
                ForEach(Array(settings.config.allFolders.enumerated()), id: \.offset) { i, f in
                    item(f.name.isEmpty ? "Untitled folder" : f.name, .folder(i), sub: true, paused: !f.enabled)
                }
                Button { chooseFolder() } label: {
                    Text("+ Add Folder").font(.system(size: 12.5)).foregroundStyle(Palette.blue).padding(.leading, 14)
                }
                .buttonStyle(.plain)
                .disabled(settings.isLocked)
                item("Git Repos", .git)
                item("Config", .gitConfig, sub: true)
                item("Repos", .gitRepos, sub: true)
                item("On the NAS", .gitNAS, sub: true)
            }
            Section("App") {
                item("General", .general)
                item("Permissions", .permissions)
                item("Config File", .file)
            }
        }
        .listStyle(.sidebar)
    }

    private func item(_ title: String, _ pane: SettingsPane, sub: Bool = false, paused: Bool = false) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: sub ? 12.5 : 13))
                .foregroundStyle(paused ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if settings.paneHasError(pane) {
                Circle().fill(Palette.red).frame(width: 7, height: 7).accessibilityLabel("Has a problem")
            }
        }
        .padding(.leading, sub ? 14 : 0)
        .tag(pane)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Back Up This Folder"
        panel.message = "Choose a folder to back up to the NAS."
        if panel.runModal() == .OK, let url = panel.url { settings.addFolder(source: url) }
    }
}

// MARK: Banners and footer

struct SetupBanner: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        let c = settings.config
        let wifi = !c.home.wifi.isEmpty
        let nas = !c.nas.path.isEmpty && settings.error(.named("nas", "path")) == nil && settings.error(.named("nas", "ssh")) == nil
        let folder = !c.allFolders.isEmpty
        VStack(alignment: .leading, spacing: 6) {
            Text("Three things to fill in and NAS Sync can start.").font(.system(size: 12.5, weight: .semibold))
            VStack(alignment: .leading, spacing: 3) {
                check(wifi, wifi ? "Home Wi-Fi: filled in from the network you're on now" : "Your home Wi-Fi, under When to Sync")
                check(nas, "Your NAS login and base folder, on the NAS page")
                check(folder, "A first folder to back up: + Add Folder in the sidebar")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(Palette.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.09)))
    }

    private func check(_ done: Bool, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(done ? "✓" : "○").fontWeight(done ? .bold : .regular).foregroundStyle(done ? Palette.green : .secondary)
            Text(text)
        }
        .font(.system(size: 12))
    }
}

struct SettingsFooter: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(AppModel.self) private var model

    var body: some View {
        let (mark, color, text) = status
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(mark).fontWeight(.bold).foregroundStyle(color)
                Text(text)
            }
            Spacer()
            if settings.pane != .file {
                Button("View \(model.engine.configURL.lastPathComponent)") { settings.pane = .file }
                    .buttonStyle(.link)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var status: (String, Color, String) {
        if settings.isLocked { return ("✕", Palette.red, "Read-only until the file is fixed") }
        if settings.isSetup { return ("○", .secondary, "Saved as soon as you fill this in") }
        if !settings.fieldErrors.isEmpty { return ("✕", Palette.red, "Not saved. Everything else keeps running on the last good settings.") }
        if settings.savedOnce { return ("✓", Palette.green, "Saved. NAS Sync is using this now.") }
        return ("✓", Palette.green, "All changes are saved automatically")
    }
}

struct RemoveFolderSheet: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        let index = settings.removingFolder ?? 0
        let name = settings.config.allFolders.indices.contains(index) ? settings.config.allFolders[index].name : "this folder"
        VStack(alignment: .leading, spacing: 6) {
            Text("Stop backing up “\(name)”?").font(.system(size: 13.5, weight: .semibold))
            Text("Nothing is deleted. The copy and its old versions stay on the NAS, and your folder on this Mac isn't touched.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { settings.removingFolder = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Remove Folder") {
                    settings.removingFolder = nil
                    settings.removeFolder(index)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

// MARK: Config File

struct ConfigFilePane: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsModel.self) private var settings

    private static let editors: [(String, String)] = [
        ("com.microsoft.VSCode", "Visual Studio Code"), ("dev.zed.Zed", "Zed"), ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.sublimetext.4", "Sublime Text"), ("com.panic.Nova", "Nova"), ("com.barebones.bbedit", "BBEdit"),
        ("com.apple.dt.Xcode", "Xcode"), ("com.apple.TextEdit", "TextEdit"),
    ]

    var body: some View {
        @Bindable var model = model
        SettingsPage(title: "Config File", subtitle: "Everything under Backups is stored in this one text file.") {
            SettingsGroup {
                SettingsRow(label: "Location", help: "Point several Macs at the same file to share one setup.") {
                    Text(SettingsModel.abbreviate(model.engine.configURL)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                    Button("Change…", action: chooseConfig)
                    if settings.fileExists { Button("Reveal in Finder") { model.revealConfig() } }
                }
                SettingsRow(label: "Open with") {
                    Picker("", selection: $model.editorBundleID) {
                        Text("Default app").tag(String?.none)
                        ForEach(Self.editors.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.0) != nil }, id: \.0) { id, name in
                            Text(name).tag(String?.some(id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Open in Editor") { model.openConfigInEditor() }.buttonStyle(.borderedProminent)
                }
            }
            if settings.fileExists {
                VStack(alignment: .leading, spacing: 6) {
                    ConfigCodeView(text: settings.doc.text,
                                   issueLines: Set(settings.result.issues.compactMap(\.line)),
                                   changed: settings.baselineLines)
                    validation
                    SettingsNote(text: "The form and this file are the same settings. Edit the file by hand and the form updates. Change the form and only the affected lines change: comments and order stay as you left them.")
                }
            } else {
                SettingsNote(text: "There's no config file yet. Fill in the NAS page and it's created, with comments explaining each setting.")
            }
        }
    }

    @ViewBuilder
    private var validation: some View {
        let s = model.engine.status
        VStack(alignment: .leading, spacing: 6) {
            if !settings.fieldErrors.isEmpty {
                let n = settings.fieldErrors.count
                ValidationRow(kind: .error, text: "Not saved yet. Fix the highlighted \(n == 1 ? "setting" : "settings") first.")
            } else if let c = settings.result.config, settings.result.errors.isEmpty {
                ValidationRow(kind: .ok, text: "Valid. " + Self.summary(c) + ".")
            }
            ForEach(settings.result.issues, id: \.description) { issue in
                ValidationRow(kind: issue.severity == .error ? .error : .warning, text: issue.description)
            }
            if s.usingLastGoodConfig {
                ValidationRow(kind: .warning, text: "Still running the last valid version of this file until the errors are fixed.")
            }
            if Rsync.find(override: model.engine.config?.nas.rsync) == nil {
                ValidationRow(kind: .warning, text: Rsync.missingMessage)
            }
        }
    }

    static func summary(_ c: AppConfig) -> String {
        var parts = [Format.count(c.folders.count, "folder"), "1 NAS", "home network “\(c.home.wifi)”"]
        if let gh = c.github { parts.append("GitHub backups every \(StatusText.every(gh.every.seconds))") }
        return parts.joined(separator: ", ")
    }

    private func chooseConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "toml") ?? .plainText]
        panel.directoryURL = model.engine.configURL.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { model.useConfig(at: url) }
    }
}

struct ValidationRow: View {
    enum Kind { case ok, warning, error }
    var kind: Kind
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(kind == .ok ? "✓" : kind == .warning ? "!" : "✕")
                .fontWeight(.bold)
                .foregroundStyle(kind == .ok ? Palette.green : kind == .warning ? Palette.orange : Palette.red)
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .font(.system(size: 12))
    }
}

/// Read-only TOML with simple highlighting and line numbers. Lines that weren't in the file when the window
/// opened (`changed` holds the original lines) are tinted, so you can see what the form wrote.
struct ConfigCodeView: View {
    var text: String
    var issueLines: Set<Int>
    var changed: Set<String> = []

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        ScrollView([.horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(i + 1)").foregroundStyle(.tertiary).frame(width: 28, alignment: .trailing)
                        Text(highlight(line)).fixedSize()
                    }
                    .frame(minHeight: 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(line: i + 1, text: line))
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
            .padding(.vertical, 10)
            .padding(.horizontal, 10)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.09)))
    }

    private func background(line: Int, text: String) -> Color {
        if issueLines.contains(line) { return Palette.red.opacity(0.1) }
        if !changed.isEmpty, !changed.contains(text), !text.trimmingCharacters(in: .whitespaces).isEmpty { return Palette.blue.opacity(0.1) }
        return .clear
    }

    private func highlight(_ line: String) -> AttributedString {
        var out = AttributedString()
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            var a = AttributedString(line)
            a.foregroundColor = Palette.tomlHeader
            a.font = .system(size: 11.5, weight: .semibold, design: .monospaced)
            return a
        }
        var code = Substring(line)
        var comment = Substring("")
        var inString = false
        for idx in line.indices {
            let c = line[idx]
            if c == "\"" { inString.toggle() }
            if c == "#", !inString {
                code = line[..<idx]
                comment = line[idx...]
                break
            }
        }
        if let eq = code.firstIndex(of: "="), !trimmed.hasPrefix("#") {
            var key = AttributedString(code[..<eq])
            key.foregroundColor = Palette.tomlKey
            out += key
            out += AttributedString("=")
            var rest = AttributedString()
            var buffer = ""
            var quoted = false
            for c in code[code.index(after: eq)...] {
                if c == "\"" {
                    if quoted {
                        var s = AttributedString(buffer + "\"")
                        s.foregroundColor = Palette.tomlString
                        rest += s
                        buffer = ""
                    } else {
                        rest += AttributedString(buffer)
                        buffer = "\""
                    }
                    quoted.toggle()
                } else {
                    buffer.append(c)
                }
            }
            rest += AttributedString(buffer)
            out += rest
        } else {
            out += AttributedString(code)
        }
        if !comment.isEmpty {
            var c = AttributedString(comment)
            c.foregroundColor = .secondary
            out += c
        }
        return out
    }
}

// MARK: General

struct GeneralPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPage(title: "General", subtitle: "Settings for this Mac. They aren't in the config file.") {
            SettingsGroup {
                SettingsRow(label: "Launch at login", help: "Starts in the menu bar. Nothing syncs until the app is running.") {
                    SettingToggle(isOn: model.launchAtLogin) { model.setLaunchAtLogin($0) }
                }
                SettingsRow(label: "Notifications", help: "Only when backups break, recover, or go stale.") {
                    Chip(color: model.notificationsAllowed ? Palette.green : Palette.orange, text: model.notificationsAllowed ? "On" : "Off in System Settings")
                    if !model.notificationsAllowed {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                    Button("Send Test") {
                        Notifier.post(Notice(id: "test", title: "NAS Sync notifications work", body: "You'll hear from NAS Sync only when something breaks, recovers, or goes stale."))
                    }
                }
                SettingsRow(label: "Command-line tool", help: "Run nas-sync status, run, check or diagnose from a terminal. Build it with swift build in the repo.") {
                    Text("nas-sync").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
        .task { await model.refreshNotificationPermission(request: false) }
    }
}

// MARK: Permissions

struct PermissionsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let home = model.engine.config?.home.wifi ?? "your home Wi-Fi"
        let host = model.engine.config?.nas.host ?? "the NAS"
        SettingsPage(title: "Permissions", subtitle: "macOS asks for these separately. The app checks them on every sync and warns in the menu bar if one goes missing.") {
            SettingsGroup {
                permission("Location", ok: model.location.isAllowed,
                           help: "Needed to read the Wi-Fi name, so the app knows when you are on “\(home)”. Without it, syncing never starts.") {
                    model.location.request()
                }
                permission("Full Disk Access", ok: FullDiskAccess.isGranted,
                           help: "Needed to read protected folders such as ~/Documents or ~/Desktop.") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                permission("Local Network", ok: model.engine.status.nasConnected || model.engine.status.connectSteps.contains { $0.title.hasPrefix("NAS answers") && $0.state == .ok },
                           help: "Needed to reach \(host). macOS asks the first time the app connects.", unknownWhenFalse: !model.engine.status.isHome) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                }
                permission("Notifications", ok: model.notificationsAllowed, help: "Needed to alert you when backups break or recover.") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            }
        }
        .task { await model.refreshNotificationPermission(request: false) }
    }

    private func permission(_ name: String, ok: Bool, help: String, unknownWhenFalse: Bool = false, grant: @escaping () -> Void) -> some View {
        SettingsRow(label: name, help: help) {
            Chip(color: ok ? Palette.green : unknownWhenFalse ? Palette.grey : Palette.orange,
                 text: ok ? "Allowed" : unknownWhenFalse ? "Checked when home" : "Not allowed")
            if !ok, !unknownWhenFalse { Button("Grant…", action: grant).buttonStyle(.borderedProminent) }
        }
    }
}

enum FullDiskAccess {
    /// Reading a TCC-protected folder only works with Full Disk Access.
    static var isGranted: Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Safari")
        return (try? FileManager.default.contentsOfDirectory(atPath: probe.path(percentEncoded: false))) != nil
    }
}
