import AppKit
import CoreLocation
import Observation
import ServiceManagement
import SwiftUI
import SyncCore
import UserNotifications

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var engine: Engine
    let location = LocationAccess()
    private(set) var notificationsAllowed = false
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    var editorBundleID: String? = UserDefaults.standard.string(forKey: "editorBundleID") {
        didSet { UserDefaults.standard.set(editorBundleID, forKey: "editorBundleID") }
    }
    private var started = false
    /// Asks the Repos window to show its problems. Bumped each time.
    private(set) var repoProblemsRequest = 0

    static var configURL: URL {
        if let path = UserDefaults.standard.string(forKey: "configPath") { return URL(filePath: path) }
        return ConfigLoader.defaultURL()
    }

    private init() {
        let store: Store
        do {
            store = try SampleData.isRendering ? Store(directory: SampleData.storeDirectory) : Store()
        } catch {
            let alert = NSAlert()
            alert.messageText = "NAS Sync can't open its database"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            exit(1)
        }
        engine = Engine(configURL: Self.configURL, store: store)
    }

    func start() {
        guard !started else { return }
        started = true
        engine.onNotice = { notice in Notifier.post(notice) }
        location.onChange = { [weak self] allowed in self?.engine.locationAllowed = allowed }
        location.start()
        engine.start()
        Task { await refreshNotificationPermission(request: true) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.engine.systemDidWake() }
        }
        if !FileManager.default.fileExists(atPath: Self.configURL.path(percentEncoded: false)) || location.status == .notDetermined {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { WindowOpener.open(WindowID.settings) }
        }
    }

    /// Points the app at a different config file and restarts the engine.
    func useConfig(at url: URL) {
        UserDefaults.standard.set(url.path(percentEncoded: false), forKey: "configPath")
        engine.stop()
        engine = Engine(configURL: url, store: engine.store)
        engine.onNotice = { notice in Notifier.post(notice) }
        engine.locationAllowed = location.isAllowed
        engine.start()
    }

    #if DEBUG
    func useConfigForSamples(_ url: URL) {
        engine = Engine(configURL: url, store: engine.store)
        engine.reloadConfig()
        notificationsAllowed = true
    }
    #endif

    func refreshNotificationPermission(request: Bool) async {
        let center = UNUserNotificationCenter.current()
        if request { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
        let settings = await center.notificationSettings()
        notificationsAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        engine.notificationsAllowed = notificationsAllowed
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Launch at login change failed: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Config file

    func openConfigInEditor() {
        let url = engine.configURL
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { createStarterConfig() }
        if let id = editorBundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit"),
                  NSWorkspace.shared.urlForApplication(toOpen: url) == nil {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([engine.configURL])
    }

    func createStarterConfig() {
        let url = engine.configURL
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wifi = WiFi.currentName() ?? "Your Wi-Fi name"
        try? StarterConfig.text(wifi: wifi).write(to: url, atomically: true, encoding: .utf8)
        engine.reloadConfig()
    }

    // MARK: Fixing problems

    func requestRepoProblems() { repoProblemsRequest += 1 }

    /// False for fixes that can't work right now, like backing up while away from home.
    func canRun(_ fix: Diagnosis.Fix) -> Bool {
        let s = engine.status
        switch fix {
        case .backUpAgain:
            return s.isHome && s.nasConnected && s.pausedUntil == nil && s.githubJob?.state != .running
        case .syncAgain:
            return s.isHome && s.nasConnected && s.pausedUntil == nil && !s.folderJobs.contains { $0.state == .running }
        default:
            return true
        }
    }

    func perform(_ fix: Diagnosis.Fix, repo: RepoProblem?, folderJob: String?) throws {
        switch fix {
        case .backUpAgain:
            engine.backUpReposNow()
        case .syncAgain:
            engine.syncFoldersNow()
        case .revealClone:
            if let path = repo?.localPath { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
        case .revealFile(let path):
            if let source = engine.config?.folders.first(where: { $0.name == folderJob })?.source {
                NSWorkspace.shared.activateFileViewerSelecting([source.appending(path: path)])
            }
        case .openOnGitHub:
            if let url = repo?.githubURL { NSWorkspace.shared.open(url) }
        case .copyCommand(let command):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        case .forgetRepo:
            if let repo { try engine.forgetRepo(repo.fullName) }
        case .stopBackingUp:
            if let repo { try engine.stopBackingUp(repo.fullName) }
        case .openFullDiskAccess:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
        case .openSettings:
            WindowOpener.open(WindowID.settings)
        }
    }

    /// Copies the full path of a folder on the NAS.
    func copyNASPath(_ relative: String) {
        guard let nas = engine.nas else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(nas.absolute(relative), forType: .string)
    }
}

/// Opens windows from places that don't have SwiftUI's environment.
@MainActor
enum WindowOpener {
    static var action: OpenWindowAction? {
        didSet {
            if let id = pending {
                pending = nil
                open(id)
            }
        }
    }
    /// A window asked for before SwiftUI provided `action`.
    private static var pending: String?

    static func open(_ id: String) {
        guard let action else {
            pending = id
            return
        }
        action(id: id)
        NSApp.activate()
    }
}

enum Notifier {
    static func post(_ notice: Notice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        let request = UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Tracks Location permission, which macOS requires before it reveals the Wi-Fi name.
@MainActor
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onChange: ((Bool) -> Void)?
    private(set) var status: CLAuthorizationStatus = .notDetermined

    var isAllowed: Bool { status == .authorizedAlways || status == .authorized }

    func start() {
        manager.delegate = self
        status = manager.authorizationStatus
        onChange?(isAllowed)
    }

    func request() {
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        MainActor.assumeIsolated {
            status = s
            onChange?(isAllowed)
        }
    }
}
