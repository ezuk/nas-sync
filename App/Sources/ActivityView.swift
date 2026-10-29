import SwiftUI
import SyncCore

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: Filter = .all
    @State private var runs: [RunRecord] = []
    @State private var selection: Int64?
    @State private var detail: RunRecord?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", folders = "Folders", repos = "Repos", problems = "Problems"
        var id: String { rawValue }
    }

    var body: some View {
        HSplitView {
            list.frame(minWidth: 260, idealWidth: 290, maxWidth: 380)
            Group {
                if let detail { RunDetailView(run: detail) } else { emptyDetail }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("Activity")
        .onAppear(perform: load)
        .onChange(of: model.engine.historyVersion) { load() }
        .onChange(of: filter) { load() }
        .onChange(of: selection) { loadDetail() }
    }

    private var emptyDetail: some View {
        VStack(spacing: 6) {
            Text("No run selected").font(.headline)
            Text("Each sync, repo backup, nightly check and away period is listed here.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() {
        let kinds: Set<RunKind>? = switch filter {
        case .all, .problems: nil
        case .folders: [.folder, .check]
        case .repos: [.github]
        }
        var all = (try? model.engine.store.recentRuns(limit: 400, kinds: kinds)) ?? []
        if filter == .problems { all = all.filter { $0.outcome != .success && $0.outcome != .cancelled } }
        runs = all
        if selection == nil || !all.contains(where: { $0.id == selection }) { selection = all.first?.id }
        loadDetail()
    }

    private func loadDetail() {
        detail = selection.flatMap { try? model.engine.store.run(id: $0) }
    }

    private var grouped: [(String, [RunRecord])] {
        let cal = Calendar.current
        var out: [(String, [RunRecord])] = []
        for run in runs {
            let key: String
            if cal.isDateInToday(run.started) { key = "Today" }
            else if cal.isDateInYesterday(run.started) { key = "Yesterday" }
            else { key = run.started.formatted(.dateTime.weekday(.wide).day().month(.wide)) }
            if out.last?.0 == key { out[out.count - 1].1.append(run) } else { out.append((key, [run])) }
        }
        return out
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(grouped, id: \.0) { day, items in
                Section(day) {
                    ForEach(items) { run in
                        RunRow(run: run).tag(run.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if runs.isEmpty {
                Text(filter == .problems ? "No problems." : "Nothing has run yet.").foregroundStyle(.secondary)
            }
        }
    }
}

struct RunRow: View {
    var run: RunRecord

    var title: String {
        let time = run.started.formatted(date: .omitted, time: .shortened)
        switch run.kind {
        case .away:
            let end = run.finished.map { " – " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
            return "\(time)\(end) · Away"
        case .mount: return "\(time) · Mount"
        case .check: return "\(time) · Full check · \(run.job)"
        case .github: return "\(time) · GitHub repos"
        default: return "\(time) · \(run.job)"
        }
    }

    var subtitle: String {
        var s = run.summary
        if let d = run.duration, run.kind != .away, run.kind != .mount, d >= 1 { s += " · " + Format.duration(d) }
        if run.trigger.contains("dry run") { s += " · dry run" }
        return s
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(color: run.dotColor).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

struct RunDetailView: View {
    @Environment(AppModel.self) private var model
    var run: RunRecord
    @State private var showAll = false
    @State private var showTimings = false

    private var title: String {
        switch run.kind {
        case .github: "GitHub repos → NAS"
        case .away: "Away from home"
        case .mount: "Mounting the NAS"
        case .check: "\(run.job) → NAS (full check)"
        default: "\(run.job) → NAS"
        }
    }

    private var meta: String {
        let start = run.started.formatted(date: .abbreviated, time: .standard)
        let end = run.finished.map { " – " + $0.formatted(date: .omitted, time: .standard) } ?? " · still running"
        let outcome: String = switch run.outcome {
        case .success: "succeeded"
        case .warning: run.kind == .github ? "finished with \(Format.count(run.counts.failed, "problem"))" : "finished with warnings"
        case .failed: "failed"
        case .cancelled: "stopped"
        case .blocked: "stopped by a safety check"
        }
        return "\(start)\(end) · \(run.trigger) · \(outcome)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(meta).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 4).padding(.bottom, 16)
                if let message = run.message {
                    Text(message)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background((run.outcome == .success ? Palette.grey : Palette.red).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 16)
                }
                if run.kind == .github { githubBody } else if run.kind == .folder || run.kind == .check { folderBody }
            }
            .padding(EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24))
        }
    }

    // MARK: Folder runs

    private var folderBody: some View {
        let c = run.counts
        let items = run.items.filter { $0.action != .unchanged }
        let shown = showAll ? items : Array(items.prefix(60))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                KPI(value: c.copied.formatted(), label: "Copied")
                KPI(value: c.archived.formatted(), label: "Archived")
                KPI(value: c.failed.formatted(), label: "Failed", color: c.failed > 0 ? Palette.red : .primary)
                KPI(value: Format.bytes(c.bytes), label: "Transferred")
            }
            .padding(.bottom, 18)
            if run.kind == .check {
                Text("Compared \(Format.count(c.total, "file")).").font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 8)
            }
            if !items.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                    GridRow {
                        Text("Action").frame(width: 76, alignment: .leading)
                        Text("File")
                        Text("Size").gridColumnAlignment(.trailing)
                    }
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    Divider()
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                        GridRow(alignment: .top) {
                            Tag(text: label(item.action), style: style(item.action))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                if let d = item.detail { Text(d).font(.system(size: 11)).foregroundStyle(.tertiary) }
                            }
                            Text(item.size.map(Format.bytes) ?? "").font(.system(size: 12)).monospacedDigit()
                        }
                        .padding(.vertical, 6)
                        Divider().opacity(0.5)
                    }
                }
            }
            footer(remaining: items.count - shown.count, revealPath: folderDest)
        }
    }

    private var folderDest: String? {
        model.engine.config?.folders.first { $0.name == run.job }?.dest
    }

    private func label(_ a: ItemAction) -> String {
        switch a {
        case .new: "New"
        case .changed: "Changed"
        case .archived: "Archived"
        case .skipped: "Skipped"
        case .ignored: "Ignored"
        case .failed: "Failed"
        case .unchanged: "Same"
        case .pruned: "Removed"
        }
    }

    private func style(_ a: ItemAction) -> Tag.Style {
        switch a {
        case .new: .new
        case .changed: .changed
        case .archived, .pruned: .archived
        case .failed, .skipped: .bad
        case .ignored, .unchanged: .same
        }
    }

    // MARK: GitHub runs

    private var githubBody: some View {
        let c = run.counts
        let interesting = run.items.filter { $0.action != .unchanged && $0.action != .pruned }
        let unchanged = run.items.filter { $0.action == .unchanged }
        let shown = showAll ? interesting + unchanged : interesting + unchanged.prefix(max(0, 8 - interesting.count))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                KPI(value: c.copied.formatted(), label: "Backed up")
                KPI(value: c.unchanged.formatted(), label: "Unchanged")
                KPI(value: c.failed.formatted(), label: "Failed", color: c.failed > 0 ? Palette.red : .primary)
                KPI(value: Format.bytes(c.bytes), label: "Sent to NAS")
                KPI(value: c.pruned.formatted(), label: "Pruned")
            }
            .padding(.bottom, 18)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    Text("Repo")
                    Text("What changed")
                    Text("Archive").gridColumnAlignment(.trailing)
                    Text("Result")
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.vertical, 6)
                Divider()
                ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                    githubRow(item)
                    Divider().opacity(0.5)
                }
            }
            footer(remaining: (interesting.count + unchanged.count) - shown.count,
                   revealPath: model.engine.config?.github.map { "\($0.dest)/bundles" })
            if showTimings, !run.stepTimings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(run.stepTimings.sorted { $0.value > $1.value }, id: \.key) { step, secs in
                        Text("\(step): \(Format.duration(secs))").font(.system(size: 11.5, design: .monospaced))
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    private func githubRow(_ item: RunItem) -> some View {
        let dim = item.action == .unchanged
        let detail = item.detail ?? ""
        let unpushed = detail.contains("not pushed")
        return GridRow(alignment: .top) {
            Text(item.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(dim ? .tertiary : .primary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if unpushed { Tag(text: "Local only", style: .local) }
                Text(detail.prefix(1).uppercased() + detail.dropFirst()).font(.system(size: 12))
                    .foregroundStyle(dim ? .tertiary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(item.size.map(Format.bytes) ?? "–").font(.system(size: 12)).monospacedDigit().foregroundStyle(item.size == nil ? .tertiary : .primary)
            switch item.action {
            case .new, .changed: Tag(text: run.trigger.contains("dry run") ? "Would back up" : "On NAS", style: .new)
            case .failed: Tag(text: "Failed", style: .bad)
            case .skipped: Tag(text: "Skipped", style: .same)
            default: Tag(text: "Unchanged", style: .same)
            }
        }
        .padding(.vertical, 7)
    }

    private var dot: some View { Text("·").foregroundStyle(.secondary) }

    private func footer(remaining: Int, revealPath: String?) -> some View {
        HStack(spacing: 6) {
            if remaining > 0 {
                Text("+ \(remaining.formatted()) more").foregroundStyle(.secondary)
                dot
                Button("Show all") { showAll = true }.buttonStyle(.link)
            } else if showAll {
                Button("Show fewer") { showAll = false }.buttonStyle(.link)
            }
            if run.kind == .github, !run.stepTimings.isEmpty {
                if remaining > 0 || showAll { dot }
                Button(showTimings ? "Hide step timings" : "Step timings") { showTimings.toggle() }.buttonStyle(.link)
            }
            if let revealPath, model.engine.status.nasMounted {
                if remaining > 0 || showAll || (run.kind == .github && !run.stepTimings.isEmpty) { dot }
                Button("Reveal on NAS") { model.revealOnNAS(revealPath) }.buttonStyle(.link)
            }
        }
        .font(.system(size: 12))
        .padding(.top, 10)
    }
}
