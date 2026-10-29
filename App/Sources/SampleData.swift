#if DEBUG
import AppKit
import SwiftUI
import SyncCore

/// Renders every screen with made-up data: `NAS Sync --render-samples <folder>`. Debug builds only.
@MainActor
enum SampleData {
    static var outputFolder: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-samples"), i + 1 < args.count else { return nil }
        return URL(filePath: args[i + 1])
    }

    static var isRendering: Bool { outputFolder != nil }
    static var storeDirectory: URL { FileManager.default.temporaryDirectory.appending(path: "nassync-samples-\(ProcessInfo.processInfo.processIdentifier)") }
    static var configURL: URL { storeDirectory.appending(path: "config.toml") }

    static let now = Date()
    static func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    static let config = """
    [home]
    wifi = "Hearth"

    [nas]
    ssh = "me@nas.local"             # SSH login with your key
    path = "/volume1/homes/me"       # every dest is inside this folder

    [folders]
    archive_days = 90                # keep deleted or replaced files this long
    stale_after = "24h"              # warn if no success for this long while home

    [[folder]]
    name = "Tresorit"
    source = "/tmp"
    dest = "Tresorit Backup"         # folder on the NAS

    [[folder]]
    name = "Documents"
    source = "/tmp"
    dest = "Mac/Documents"
    exclude = ["**/node_modules"]    # added to the defaults

    [github]
    every = "24h"
    around = "03:00"                 # preferred time; catches up if missed
    dest = "github-backups"
    scan = ["/tmp"]
    exclude = ["someone/big-fork", "vendor/*"]
    remote_only = ["acme/keymap-tools"]

    """

    static func job(_ name: String, _ state: JobStatus.State, last: Date?, summary: String?, waiting: Int = 0, files: Int? = nil,
                    kind: JobStatus.Kind = .folder, progress: JobProgress? = nil, message: String? = nil) -> JobStatus {
        JobStatus(name: name, kind: kind, state: state, lastSuccess: last, lastSummary: summary, lastOutcome: .success, message: message,
                  waitingChanges: waiting, fileCount: files, progress: progress, nextRun: kind == .github ? Calendar.current.date(bySettingHour: 3, minute: 0, second: 0, of: now.addingTimeInterval(86400)) : nil,
                  holdUntil: nil, needsDeleteConfirmation: false, staleAfter: 86400)
    }

    static func base(_ state: OverallState) -> StatusSnapshot {
        var s = StatusSnapshot.initial(configPath: configURL.path(percentEncoded: false))
        s.state = state
        s.wifiName = "Hearth"
        s.homeWiFi = "Hearth"
        s.isHome = true
        s.locationAllowed = true
        s.nasConnected = true
        s.nasLocation = "me@nas.local:/volume1/homes/me"
        s.configValid = true
        s.github = GitHubSummary(repoCount: 171, localClones: 121, remoteOnly: 50, problems: 1, excluded: 9, every: 86400, newRepos: [])
        return s
    }

    static func ghRun() -> RunRecord {
        var c = RunCounts()
        c.changed = 5; c.new = 1; c.unchanged = 164; c.failed = 1; c.bytes = 46_000_000; c.total = 171; c.pruned = 2
        return RunRecord(kind: .github, job: StoreKey.githubJob, trigger: "scheduled (every 24h)", started: Calendar.current.date(bySettingHour: 3, minute: 0, second: 4, of: now)!,
                         finished: Calendar.current.date(bySettingHour: 3, minute: 14, second: 22, of: now)!, outcome: .warning, counts: c,
                         summary: "6 backed up, 164 unchanged, 1 failed, 2 old archives pruned",
                         message: "acme/old-prototype: GitHub says this repo doesn't exist any more. Archives on the NAS are kept.",
                         items: [
                            RunItem(action: .changed, path: "acme/firmware", size: 38_000_000, detail: "14 new commits on main, new branch fix/usb-wake"),
                            RunItem(action: .new, path: "personal/led-clock", size: 2_100_000, detail: "new repo, first backup"),
                            RunItem(action: .changed, path: "personal/dotfiles", size: 100_000, detail: "1 new commit on main, 2 commits not pushed to GitHub yet"),
                            RunItem(action: .changed, path: "acme/docs-site", size: 5_800_000, detail: "3 new commits on main, 1 branch deleted"),
                            RunItem(action: .failed, path: "acme/old-prototype", detail: "GitHub says this repo doesn't exist any more. Archives on the NAS are kept."),
                            RunItem(action: .unchanged, path: "acme/keymap-tools", detail: "unchanged since 27 Nov 2025"),
                         ],
                         stepTimings: ["bundling": 212, "compressing": 401, "copying": 88, "checking": 140, "verifying": 31])
    }

    static func seedStore(_ store: Store) {
        var c = RunCounts()
        c.new = 2; c.changed = 10; c.archived = 2; c.bytes = 38_000_000; c.total = 48_210
        _ = try? store.saveRun(RunRecord(kind: .folder, job: "Tresorit", trigger: "changes", started: ago(8), finished: ago(7.7), outcome: .success, counts: c,
                                         summary: "12 files copied (38 MB), 2 archived", items: [
                                            RunItem(action: .new, path: "Finance/2026/Invoices/INV-1042.pdf", size: 212_000),
                                            RunItem(action: .new, path: "Finance/2026/Invoices/INV-1043.pdf", size: 198_000),
                                            RunItem(action: .changed, path: "Work/Clients/2026/Q4 proposal.key", size: 31_400_000),
                                            RunItem(action: .changed, path: "Notes/Reading list.md", size: 6_000),
                                            RunItem(action: .archived, path: "Work/Clients/2026/Q4 proposal (old).key", size: 29_800_000, detail: "Deleted in source, moved to _archive/2026-10-29/185830"),
                                         ]))
        var w = RunCounts(); w.new = 40; w.skipped = 1; w.bytes = 120_000_000
        _ = try? store.saveRun(RunRecord(kind: .folder, job: "Tresorit", trigger: "changes", started: ago(220), finished: ago(219.5), outcome: .warning, counts: w,
                                         summary: "40 files copied (120 MB), 1 skipped", items: [RunItem(action: .skipped, path: "Work/open.xlsx", detail: "File changed while copying, will retry")]))
        _ = try? store.saveRun(RunRecord(kind: .mount, job: "", trigger: "connection", started: ago(300), finished: ago(300), outcome: .failed, summary: "Can't reach the NAS", message: "The NAS didn't answer."))
        _ = try? store.saveRun(ghRun())
        _ = try? store.saveRun(RunRecord(kind: .away, job: "", trigger: "wifi", started: ago(1300), finished: ago(1020), outcome: .success, summary: "Not on home Wi-Fi, nothing attempted"))
        var fc = RunCounts(); fc.total = 61_131
        _ = try? store.saveRun(RunRecord(kind: .check, job: "Documents", trigger: "full check", started: ago(1500), finished: ago(1497), outcome: .success, counts: fc, summary: "Nothing to copy"))

        func repo(_ name: String, _ source: RepoSource, change: Double, archive: Double, count: Int, size: Int64, status: RepoStatus = .ok, unpushed: Int? = nil) {
            var r = RepoRecord(fullName: name, source: source, localPath: source == .localClone ? "/tmp/\(name)" : nil, firstSeen: ago(90 * 1440))
            r.lastChangeSeen = ago(change); r.newestArchive = ago(archive); r.archiveCount = count; r.newestArchiveSize = size
            r.status = status; r.unpushedCommits = unpushed
            r.newestArchiveName = "x"
            if status == .goneFromGitHub { r.message = "GitHub says this repo doesn't exist any more." }
            try? store.saveRepo(r)
        }
        repo("acme/docs-site", .localClone, change: 120, archive: 100, count: 6, size: 41_000_000)
        repo("personal/dotfiles", .localClone, change: 600, archive: 101, count: 5, size: 400_000, unpushed: 2)
        repo("acme/keymap-tools", .remoteOnly, change: 480 * 1440, archive: 480 * 1440, count: 1, size: 12_000_000)
        repo("acme/firmware", .localClone, change: 140, archive: 102, count: 6, size: 38_000_000)
        repo("acme/old-prototype", .remoteOnly, change: 230 * 1440, archive: 230 * 1440, count: 3, size: 96_000_000, status: .goneFromGitHub)
    }

    static func renderAll() {
        guard let out = outputFolder else { return }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try? config.write(to: configURL, atomically: true, encoding: .utf8)
        let model = AppModel.shared
        model.useConfigForSamples(configURL)
        seedStore(model.engine.store)
        let engine = model.engine

        // 2a: everything backed up.
        var s = base(.upToDate)
        s.jobs = [job("Tresorit", .idle, last: ago(4), summary: "12 copied · 2 archived", files: 48_210),
                  job("Documents", .idle, last: ago(4), summary: "No changes", files: 9_804),
                  job(StoreKey.githubJob, .idle, last: Calendar.current.date(bySettingHour: 3, minute: 12, second: 0, of: now), summary: "", kind: .github)]
        engine.showSample(s, lastGitHubRun: ghRun())
        render(PopoverView(), "2a-popover-ok", width: 340)

        // 1c: copying a folder.
        s = base(.syncing)
        s.jobs = [job("Tresorit", .running, last: ago(120), summary: nil,
                      progress: JobProgress(done: 38, total: 64, bytesDone: 212_000_000, bytesTotal: 410_000_000, current: "Work/Clients/2026/Q4 proposal.key", step: nil, changedSoFar: nil, started: ago(0.7))),
                  job("Documents", .queued, last: ago(120), summary: nil, waiting: 3)]
        s.github = nil
        engine.showSample(s)
        render(PopoverView(), "1c-popover-syncing", width: 340)

        // 2b: repos backing up.
        s = base(.syncing)
        s.jobs = [job("Tresorit", .idle, last: ago(2), summary: "Up to date, still watching"),
                  job(StoreKey.githubJob, .running, last: ago(1440), summary: nil, kind: .github,
                      progress: JobProgress(done: 112, total: 171, bytesDone: 0, bytesTotal: 0, current: "acme/firmware", step: "fetching", changedSoFar: 5, started: ago(6)))]
        engine.showSample(s)
        render(PopoverView(), "2b-popover-repos", width: 340)

        // 1d: away.
        s = base(.away)
        s.wifiName = "Cafe-Guest"; s.isHome = false; s.nasConnected = false
        s.jobs = [job("Tresorit", .away, last: ago(1200), summary: nil, waiting: 206),
                  job("Documents", .away, last: ago(1200), summary: nil, waiting: 8),
                  job("Photo Exports", .away, last: ago(1200), summary: nil)]
        s.github = nil
        engine.showSample(s)
        render(PopoverView(), "1d-popover-away", width: 340)

        // 1e: NAS doesn't answer.
        s = base(.error)
        s.nasConnected = false
        s.connectError = "The NAS refused the SSH login for me@nas.local. Set up key login with ssh-copy-id."
        s.connectSteps = [.init(title: "On the home Wi-Fi", state: .ok, detail: "Hearth"),
                          .init(title: "rsync 3 installed", state: .ok, detail: nil),
                          .init(title: "NAS answers over SSH", state: .failed, detail: s.connectError),
                          .init(title: "Sync skipped", state: .skipped, detail: nil)]
        s.jobs = [job("Tresorit", .error, last: ago(1200), summary: nil, message: s.connectError)]
        s.github = nil
        engine.showSample(s)
        render(PopoverView(), "1e-popover-nas-error", width: 340)

        // 2c: holding off on battery, new repos found.
        s = base(.holdingOff)
        s.onBattery = true; s.batteryPercent = 24
        s.github?.newRepos = ["personal/led-clock", "acme/docs-site"]
        var t = job("Tresorit", .holdingOff, last: ago(180), summary: nil, waiting: 38)
        t.holdUntil = ago(-540)
        var g = job(StoreKey.githubJob, .holdingOff, last: ago(1500), summary: nil, kind: .github)
        g.holdUntil = ago(-540)
        s.jobs = [t, g]
        engine.showSample(s)
        render(PopoverView(), "2c-popover-battery", width: 340)

        // Windows.
        s = base(.upToDate)
        s.jobs = [job("Tresorit", .idle, last: ago(4), summary: "12 copied")]
        engine.showSample(s, lastGitHubRun: ghRun())
        render(ActivityView(), "1g-activity", width: 980, height: 600)

        // Live runs in Activity: a full check comparing with the NAS, repos backing up.
        s = base(.syncing)
        let comparing = JobProgress(done: 0, total: 0, bytesDone: 0, bytesTotal: 0, current: "", step: "comparing", changedSoFar: nil, started: ago(6))
        s.jobs = [job("Tresorit", .running, last: ago(120), summary: nil, progress: comparing),
                  job(StoreKey.githubJob, .running, last: ago(1440), summary: nil, kind: .github,
                      progress: JobProgress(done: 112, total: 171, bytesDone: 0, bytesTotal: 0, current: "acme/firmware", step: "compressing", changedSoFar: 5, started: ago(6)))]
        engine.showSample(s, lastGitHubRun: ghRun())
        render(ActivityView(), "1k-activity-live", width: 980, height: 600)
        render(LiveRunView(job: s.jobs[0]).frame(width: 640), "1l-live-run", width: 640, height: 360)
        render(PopoverView(), "1m-popover-comparing", width: 340)
        render(RunDetailView(run: ghRun()).frame(width: 720), "2d-github-run", width: 720, height: 560)
        render(ReposView(), "2e-repos", width: 1040, height: 360)
        render(ConfigPane().padding(24), "1h-settings-config", width: 720, height: 980)
        render(GeneralPane().padding(24), "1i-settings-general", width: 720, height: 520)
        render(PermissionsPane().padding(24), "1j-settings-permissions", width: 720, height: 460)
        for state in [OverallState.upToDate, .syncing, .away, .paused, .stale, .error] {
            let image = MenuBarIcon.image(for: state, frame: 2)
            image.isTemplate = false
            if let tiff = image.tiffRepresentation(using: .none, factor: 4) { try? tiff.write(to: out.appending(path: "icon-\(state.rawValue).tiff")) }
        }
    }

    static func render<V: View>(_ view: V, _ name: String, width: CGFloat, height: CGFloat? = nil) {
        guard let out = outputFolder else { return }
        let root = view.environment(AppModel.shared).frame(width: width, height: height, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        let size = height.map { NSSize(width: width, height: $0) } ?? host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: "\(name).png"))
        window.orderOut(nil)
    }
}
#else
import Foundation

enum SampleData {
    static let isRendering = false
    static var storeDirectory: URL { FileManager.default.temporaryDirectory }
    @MainActor static func renderAll() {}
}
#endif
