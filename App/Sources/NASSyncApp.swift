import AppKit
import SwiftUI
import SyncCore

@main
struct NASSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
        } label: {
            MenuBarIcon(state: model.engine.status.state)
        }
        .menuBarExtraStyle(.window)

        Window("Activity", id: WindowID.activity) {
            ActivityView()
                .environment(model)
        }
        .defaultSize(width: 980, height: 620)

        Window("Repos", id: WindowID.repos) {
            ReposView()
                .environment(model)
        }
        .defaultSize(width: 1040, height: 620)

        Window("Settings", id: WindowID.settings) {
            SettingsView()
                .environment(model)
        }
        .defaultSize(width: 900, height: 640)
        .windowResizability(.contentMinSize)
    }
}

enum WindowID {
    static let activity = "activity"
    static let repos = "repos"
    static let settings = "settings"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if SampleData.isRendering {
                SampleData.renderAll()
                exit(0)
            }
            AppModel.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.engine.stop() }
    }
}

extension View {
    /// Opens a window and brings the app forward, since a menu bar app isn't active by default.
    func openAndActivate(_ open: OpenWindowAction, id: String) {
        open(id: id)
        NSApp.activate()
    }
}
