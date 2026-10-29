import AppKit
import SwiftUI
import SyncCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pane: Pane = .config

    enum Pane: String, CaseIterable, Identifiable {
        case config = "Config", general = "General", permissions = "Permissions"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .config: "doc.text"
            case .general: "gearshape"
            case .permissions: "lock.shield"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label(p.rawValue, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            ScrollView {
                Group {
                    switch pane {
                    case .config: ConfigPane()
                    case .general: GeneralPane()
                    case .permissions: PermissionsPane()
                    }
                }
                .padding(EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Settings")
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            if !model.location.isAllowed { pane = .permissions }
            if !FileManager.default.fileExists(atPath: model.engine.configURL.path(percentEncoded: false)) { pane = .config }
        }
    }
}

// MARK: Config

struct ConfigPane: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var hasPassword = false

    private var exists: Bool { FileManager.default.fileExists(atPath: model.engine.configURL.path(percentEncoded: false)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.engine.configURL.lastPathComponent).font(.system(size: 15, weight: .semibold))
                    Text("\(abbreviated(model.engine.configURL)) · reloaded automatically when saved")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if exists {
                    Button("Reveal in Finder") { model.revealConfig() }
                    Button("Open in Editor") { model.openConfigInEditor() }.buttonStyle(.borderedProminent)
                }
            }
            if exists {
                ConfigCodeView(text: text, issueLines: Set(model.engine.configIssues.compactMap(\.line)))
                validation
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("There's no config file yet.").font(.system(size: 13, weight: .medium))
                    Text("NAS Sync is set up with a text file, so you (or an LLM) can edit it directly. Create a starter file with comments explaining each setting, then fill in your NAS address and folders.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Create Starter Config") {
                        model.createStarterConfig()
                        model.openConfigInEditor()
                        reload()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(16)
                .background(.background, in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.engine.status.configIssues) { reload() }
        .onChange(of: model.engine.config) { reload() }
    }

    private func reload() {
        text = (try? String(contentsOf: model.engine.configURL, encoding: .utf8)) ?? ""
        if let host = model.engine.config?.nas.host { hasPassword = KeychainCheck.hasPassword(host: host) }
    }

    @ViewBuilder
    private var validation: some View {
        let s = model.engine.status
        VStack(alignment: .leading, spacing: 6) {
            if let c = model.engine.config, s.configValid {
                var parts = [Format.count(c.folders.count, "folder"), "1 NAS", "home network “\(c.home.wifi)”"]
                let _ = c.github.map { parts.append("GitHub backups every \(StatusText.every($0.every.seconds))") }
                ValidationRow(kind: .ok, text: "Valid. " + parts.joined(separator: ", ") + ".")
            }
            ForEach(model.engine.configIssues, id: \.description) { issue in
                ValidationRow(kind: issue.severity == .error ? .error : .warning, text: issue.description)
            }
            if s.usingLastGoodConfig {
                ValidationRow(kind: .warning, text: "Still running the last valid version of this file until the errors are fixed.")
            }
            if let host = model.engine.config?.nas.host {
                ValidationRow(kind: hasPassword ? .ok : .warning,
                              text: hasPassword ? "Keychain has a password for \(host)." : "No Keychain password found for \(host). Connect once in Finder and save the password.")
            }
            if !model.location.isAllowed {
                HStack(spacing: 4) {
                    ValidationRow(kind: .warning, text: "Location access is needed to read the Wi-Fi name.")
                    Button("Grant…") { model.location.request() }.buttonStyle(.link).font(.system(size: 12))
                }
            }
        }
    }

    private func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let p = url.path(percentEncoded: false)
        return p.hasPrefix(home) ? "~/" + p.dropFirst(home.count).drop { $0 == "/" } : p
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

/// Read-only TOML with simple highlighting and line numbers.
struct ConfigCodeView: View {
    var text: String
    var issueLines: Set<Int>

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
                    .background(issueLines.contains(i + 1) ? Palette.red.opacity(0.1) : .clear)
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.09)))
    }

    private func highlight(_ line: String) -> AttributedString {
        var out = AttributedString()
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            var a = AttributedString(line)
            a.foregroundColor = Color(red: 0.04, green: 0.31, blue: 0.47)
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
            key.foregroundColor = Color(red: 0.61, green: 0.14, blue: 0.58)
            out += key
            out += AttributedString("=")
            var rest = AttributedString()
            var buffer = ""
            var quoted = false
            for c in code[code.index(after: eq)...] {
                if c == "\"" {
                    if quoted {
                        var s = AttributedString(buffer + "\"")
                        s.foregroundColor = Color(red: 0.77, green: 0.10, blue: 0.09)
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

    private static let editors: [(String, String)] = [
        ("com.microsoft.VSCode", "Visual Studio Code"), ("dev.zed.Zed", "Zed"), ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.sublimetext.4", "Sublime Text"), ("com.panic.Nova", "Nova"), ("com.barebones.bbedit", "BBEdit"),
        ("com.apple.dt.Xcode", "Xcode"), ("com.apple.TextEdit", "TextEdit"),
    ]

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            Text("General").font(.system(size: 15, weight: .semibold)).padding(.bottom, 6)
            PrefRow(label: "Launch at login", help: "Starts in the menu bar. Nothing syncs until the app is running.") {
                Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })).toggleStyle(.switch).labelsHidden()
            } value: { Text(model.launchAtLogin ? "On" : "Off") }
            PrefRow(label: "Notifications", help: "Only when backups break, recover, or go stale.") {
                HStack {
                    Button("Send test") { Notifier.post(Notice(id: "test", title: "NAS Sync notifications work", body: "You'll hear from NAS Sync only when something breaks, recovers, or goes stale.")) }
                    if !model.notificationsAllowed {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                }
            } value: { Text(model.notificationsAllowed ? "On" : "Off in System Settings") }
            PrefRow(label: "Open config with", help: "Used by “Open in Editor”.") {
                EmptyView()
            } value: {
                Picker("", selection: $model.editorBundleID) {
                    Text("Default app").tag(String?.none)
                    ForEach(Self.editors.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.0) != nil }, id: \.0) { id, name in
                        Text(name).tag(String?.some(id))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            PrefRow(label: "Config file", help: "Point several Macs at the same file to share one setup.") {
                Button("Change…", action: chooseConfig)
            } value: { Text(model.engine.configURL.path(percentEncoded: false).replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false), with: "~/")).font(.system(size: 11, design: .monospaced)) }
            PrefRow(label: "NAS password", help: "Stored in your login Keychain, never in the config file. Finder asks for it and offers to save it.") {
                Button("Change…") { model.connectInFinder() }
            } value: {
                let host = model.engine.config?.nas.host ?? "your NAS"
                Text(KeychainCheck.hasPassword(host: host) ? "Saved for \(host)" : "Not saved for \(host)")
            }
            PrefRow(label: "Command-line tool", help: "Run nas-sync status, run, mount or diagnose from a terminal. Build it with swift build in the repo.") {
                EmptyView()
            } value: { Text("nas-sync").font(.system(size: 11, design: .monospaced)) }
        }
    }

    private func chooseConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "toml") ?? .plainText]
        panel.directoryURL = model.engine.configURL.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { model.useConfig(at: url) }
    }
}

struct PrefRow<Control: View, Value: View>: View {
    var label: String
    var help: String
    @ViewBuilder var control: Control
    @ViewBuilder var value: Value

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                Text(label).font(.system(size: 13, weight: .medium)).frame(width: 170, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    value.font(.system(size: 12.5))
                    Text(help).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.vertical, 13)
            Divider()
        }
    }
}

// MARK: Permissions

struct PermissionsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Permissions").font(.system(size: 15, weight: .semibold))
            Text("macOS asks for these separately. The app checks them on every sync and warns in the menu bar if one goes missing.")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 2).padding(.bottom, 6)
            let home = model.engine.config?.home.wifi ?? "your home Wi-Fi"
            permission("Location", ok: model.location.isAllowed,
                       help: "Needed to read the Wi-Fi name, so the app knows when you are on “\(home)”. Without it, syncing never starts.") {
                model.location.request()
            }
            permission("Full Disk Access", ok: FullDiskAccess.isGranted,
                       help: "Needed to read protected folders such as ~/Documents or ~/Desktop.") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
            let host = model.engine.config?.nas.host ?? "the NAS"
            permission("Local Network", ok: model.engine.status.nasMounted || model.engine.status.mountSteps.contains { $0.title.hasPrefix("NAS found") && $0.state == .ok },
                       help: "Needed to reach \(host). macOS asks the first time the app connects.", unknownWhenFalse: !model.engine.status.isHome) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
            }
            permission("Notifications", ok: model.notificationsAllowed, help: "Needed to alert you when backups break or recover.") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            }
        }
        .task { await model.refreshNotificationPermission(request: false) }
    }

    private func permission(_ name: String, ok: Bool, help: String, unknownWhenFalse: Bool = false, grant: @escaping () -> Void) -> some View {
        PrefRow(label: name, help: help) {
            if !ok, !unknownWhenFalse { Button("Grant…", action: grant).buttonStyle(.borderedProminent) }
        } value: {
            Chip(color: ok ? Palette.green : unknownWhenFalse ? Palette.grey : Palette.orange,
                 text: ok ? "Allowed" : unknownWhenFalse ? "Checked when home" : "Not allowed")
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

enum KeychainCheck {
    /// Looks up the item's attributes only, so macOS doesn't ask for permission to read the password.
    static func hasPassword(host: String) -> Bool {
        let short = String(host.lowercased().split(separator: ".").first ?? "")
        for server in [host, short + ".local", short] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrServer as String: server,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnAttributes as String: true,
            ]
            if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess { return true }
        }
        return false
    }
}
