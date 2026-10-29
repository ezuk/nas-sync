import SwiftUI
import SyncCore

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            content(now: context.date)
        }
        .frame(width: 340)
        .onAppear { WindowOpener.action = openWindow }
    }

    private var status: StatusSnapshot { model.engine.status }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let headline = StatusText.headline(status, now: now)
        VStack(alignment: .leading, spacing: 0) {
            hero(headline, now: now)
            if status.state == .error, !status.mountSteps.isEmpty {
                mountChecklist
            } else if status.state != .syncing {
                chips
            }
            if let blocked = status.jobs.first(where: { $0.needsDeleteConfirmation }) {
                deleteConfirmation(blocked)
            }
            if let repos = status.github?.newRepos, !repos.isEmpty {
                newReposNote(repos)
            }
            if !status.folderJobs.isEmpty { folderSection(now: now) }
            if let gh = status.githubJob { githubSection(gh, now: now) }
            Divider()
            menu
        }
    }

    // MARK: Hero

    private func heroDot() -> (Color, String) {
        switch status.state {
        case .upToDate: (Palette.green, "checkmark")
        case .syncing: (Palette.blue, "arrow.up")
        case .error: (Palette.red, "exclamationmark")
        case .stale: (Palette.orange, "clock")
        case .away: (Palette.grey, "house")
        case .holdingOff: (Palette.grey, "ellipsis")
        case .paused: (Palette.grey, "pause.fill")
        case .starting: (Palette.grey, "ellipsis")
        }
    }

    private func hero(_ h: StatusText.Headline, now: Date) -> some View {
        let (color, symbol) = heroDot()
        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(color)
                Image(systemName: symbol).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(h.title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(h.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if status.state == .syncing, let job = status.runningJob, let p = job.progress {
                    if p.hasFraction { ProgressStrip(fraction: p.fraction).padding(.top, 5).padding(.bottom, 1) }
                    if job.kind == .github {
                        Text("\(p.current) · \(stepLabel(p.step))").font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        pipeline(p.step)
                    } else if !p.current.isEmpty {
                        Text(p.current).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16))
    }

    private static let steps = ["checking", "fetching", "bundling", "verifying", "compressing", "copying", "pruning"]
    private static let stepNames = ["check", "fetch", "bundle", "verify", "xz", "copy", "prune"]

    private func stepLabel(_ step: String?) -> String {
        switch step {
        case "fetching": "fetching from GitHub"
        case "bundling": "bundling"
        case "verifying": "verifying the bundle"
        case "compressing": "compressing"
        case "copying": "copying to the NAS"
        case "pruning": "removing old archives"
        default: "checking for changes"
        }
    }

    private func pipeline(_ step: String?) -> some View {
        let current = Self.steps.firstIndex(of: step ?? "checking") ?? 0
        return HStack(spacing: 4) {
            ForEach(Array(Self.stepNames.enumerated()), id: \.offset) { i, name in
                Text(name)
                    .font(.system(size: 9.5, weight: i == current ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .foregroundStyle(i == current ? Color.white : i < current ? Color(red: 0.11, green: 0.42, blue: 0.19) : Color.secondary.opacity(0.7))
                    .background(i == current ? Palette.blue : i < current ? Palette.green.opacity(0.14) : Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.top, 6)
    }

    // MARK: Chips and notes

    private var chips: some View {
        FlowLayout(spacing: 6) {
            if !status.locationAllowed {
                Chip(color: Palette.orange, text: "Location permission needed")
            } else if status.isHome {
                Chip(color: Palette.green, text: "Home Wi-Fi “\(status.wifiName ?? "")”")
            } else {
                Chip(color: Palette.grey, text: "Not home Wi-Fi")
            }
            if status.isHome {
                Chip(color: status.nasMounted ? Palette.green : Palette.red, text: status.nasMounted ? "NAS mounted" : "NAS not mounted")
            }
            if status.onBattery, let pct = status.batteryPercent {
                Chip(color: pct < status.holdBelowPercent ? Palette.orange : Palette.green, text: "On battery \(pct)%")
            } else if status.isHome {
                Chip(color: Palette.green, text: "On power")
            }
            if status.usingLastGoodConfig {
                Chip(color: Palette.orange, text: "Config has errors, using last good")
            }
            let waiting = status.waitingChanges
            if waiting > 0, status.state != .upToDate {
                Chip(color: status.isHome ? Palette.grey : Palette.orange, text: "\(Format.count(waiting, "change")) waiting")
            }
            if !status.notificationsAllowed {
                Chip(color: Palette.orange, text: "Notifications off")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var mountChecklist: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What I tried").font(.system(size: 12, weight: .semibold))
                ForEach(Array(status.mountSteps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(step.state == .ok ? "✓" : step.state == .failed ? "✕" : "–")
                            .fontWeight(.bold)
                            .foregroundStyle(step.state == .ok ? Palette.green : step.state == .failed ? Palette.red : .secondary)
                        Text(step.title + (step.detail.map { ": \($0)" } ?? ""))
                            .foregroundStyle(step.state == .skipped ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.red.opacity(0.22)))

            HStack(spacing: 8) {
                Button("Try Again") { model.engine.retryMount() }.buttonStyle(.borderedProminent)
                Button("Update Password…") { model.connectInFinder() }
                Button("Details") { openAndActivate(openWindow, id: WindowID.activity) }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private func deleteConfirmation(_ job: JobStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(job.message ?? "").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Allow This Once") { model.engine.allowMassDelete(job: job.name) }.buttonStyle(.borderedProminent)
                Button("Show in Activity") { openAndActivate(openWindow, id: WindowID.activity) }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Palette.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private func newReposNote(_ repos: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            (Text("\(Format.count(repos.count, "new repo")) found").bold()
                + Text(" in your scan folders and added to the backup: ")
                + Text(repos.prefix(4).joined(separator: ", ")).font(.system(size: 11, design: .monospaced))
                + Text(repos.count > 4 ? " and \(repos.count - 4) more." : "."))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Exclude one…") { model.openConfigInEditor() }.buttonStyle(.link)
                Button("Dismiss") { model.engine.dismissNewRepos() }.buttonStyle(.link)
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: Job sections

    private func sectionHeader(_ left: String) -> some View {
        HStack {
            Text(left)
            Spacer()
            Text("Last success")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private func folderSection(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(status.github == nil ? "Folders" : "Folders · live")
                ForEach(status.folderJobs) { job in
                    JobRow(name: job.name, line: StatusText.jobLine(job, now: now), right: StatusText.short(job.lastSuccess, now: now), color: job.dotColor)
                }
            }
            .padding(8)
        }
    }

    private func githubSection(_ job: JobStatus, now: Date) -> some View {
        let every = status.github.map { StatusText.every($0.every) } ?? ""
        let count = status.github?.repoCount ?? 0
        let last = model.engine.lastGitHubRun
        var line = StatusText.jobLine(job, now: now)
        if job.state == .idle, let last, last.outcome != .failed {
            line = "\(last.counts.copied) backed up · \(last.counts.unchanged) unchanged"
            if let next = job.nextRun { line += " · next at \(next.formatted(date: .omitted, time: .shortened))" }
        }
        return VStack(alignment: .leading, spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("GitHub repos · every \(every)")
                Button { openAndActivate(openWindow, id: WindowID.repos) } label: {
                    JobRow(name: count > 0 ? Format.count(count, "repo") : "GitHub repos", line: line,
                           right: StatusText.short(job.lastSuccess, now: now), color: job.dotColor)
                }
                .buttonStyle(.plain)
            }
            .padding(8)
        }
    }

    // MARK: Menu

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            let s = status
            if let running = s.runningJob {
                MenuRow(title: running.kind == .github ? "Stop Repo Backup" : "Stop Sync") { model.engine.stop(job: running.name) }
            }
            if s.state == .holdingOff {
                MenuRow(title: "Run Anyway") { model.engine.runAnyway() }
            }
            if s.isHome, s.nasMounted, s.pausedUntil == nil {
                if !s.folderJobs.isEmpty, !s.folderJobs.contains(where: { $0.state == .running }) {
                    MenuRow(title: s.github == nil ? "Sync Now" : "Sync Folders Now", shortcut: "⌘S", key: "s") { model.engine.syncFoldersNow() }
                }
                if let gh = s.githubJob, gh.state != .running {
                    MenuRow(title: "Back Up Repos Now", shortcut: "⇧⌘S", key: "s", modifiers: [.command, .shift]) { model.engine.backUpReposNow() }
                }
            }
            if s.pausedUntil != nil {
                MenuRow(title: "Resume") { model.engine.resume() }
            } else {
                MenuRow(title: "Pause for 1 Hour") { model.engine.pause(for: 3600) }
            }
            MenuRow(title: "Activity…", shortcut: "⌘L", key: "l") { openAndActivate(openWindow, id: WindowID.activity) }
            if s.github != nil {
                MenuRow(title: "Repos…", shortcut: "⌘R", key: "r") { openAndActivate(openWindow, id: WindowID.repos) }
            }
            MenuRow(title: "Edit Config…", shortcut: "⌘,", key: ",") { openAndActivate(openWindow, id: WindowID.settings) }
            MenuRow(title: "Quit NAS Sync", shortcut: "⌘Q", key: "q") { NSApp.terminate(nil) }
        }
        .padding(6)
    }
}

struct JobRow: View {
    var name: String
    var line: String
    var right: String
    var color: Color
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .medium))
                Text(line).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(right).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(hover ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

struct MenuRow: View {
    var title: String
    var shortcut: String = ""
    var key: KeyEquivalent?
    var modifiers: EventModifiers = .command
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        let button = Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut).foregroundStyle(hover ? Color.white.opacity(0.8) : Color.secondary.opacity(0.7))
            }
            .font(.system(size: 13))
            .foregroundStyle(hover ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(hover ? Palette.blue : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        if let key { button.keyboardShortcut(key, modifiers: modifiers) } else { button }
    }
}

/// Wraps children onto new lines when they don't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}
