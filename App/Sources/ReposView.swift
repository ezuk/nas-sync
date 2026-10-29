import SwiftUI
import SyncCore

/// Every known repo and where its newest archive stands (design 2e).
struct ReposView: View {
    @Environment(AppModel.self) private var model
    @State private var repos: [RepoRecord] = []
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var showAdd = false
    @State private var sortOrder = [KeyPathComparator(\RepoRecord.fullName)]

    enum Filter: Hashable { case all, local, remote, problems, excluded }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $filter) {
                    Text("All \(count(.all))").tag(Filter.all)
                    Text("Local clones \(count(.local))").tag(Filter.local)
                    Text("Remote only \(count(.remote))").tag(Filter.remote)
                    Text("Problems \(count(.problems))").tag(Filter.problems)
                    Text("Excluded \(count(.excluded))").tag(Filter.excluded)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Add Repo…") { showAdd = true }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            table
            Text("“Unchanged since” is fine: the newest archive already holds every branch and tag up to that day.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search \(repos.count) repos")
        .navigationTitle("Repos")
        .onAppear(perform: load)
        .onChange(of: model.engine.historyVersion) { load() }
        .sheet(isPresented: $showAdd) { AddRepoSheet() }
    }

    private func load() { repos = model.engine.store.repos() }

    private func matches(_ r: RepoRecord, _ f: Filter) -> Bool {
        switch f {
        case .all: r.status != .excluded
        case .local: r.source == .localClone && r.status != .excluded
        case .remote: r.source == .remoteOnly && r.status != .excluded
        case .problems: [.failed, .missingLocally, .goneFromGitHub].contains(r.status)
        case .excluded: r.status == .excluded
        }
    }

    private func count(_ f: Filter) -> Int { repos.filter { matches($0, f) }.count }

    private var visible: [RepoRecord] {
        repos.filter { matches($0, filter) && (search.isEmpty || $0.fullName.localizedCaseInsensitiveContains(search)) }
            .sorted(using: sortOrder)
    }

    private var table: some View {
        Table(visible, sortOrder: $sortOrder) {
            TableColumn("") { r in StatusDot(color: color(r)) }.width(14)
            TableColumn("Repo", value: \.fullName) { r in
                Text(r.fullName).font(.system(size: 11.5, design: .monospaced)).help(r.localPath ?? "")
            }
            .width(min: 180, ideal: 240)
            TableColumn("Source") { r in
                HStack(spacing: 6) {
                    Text(r.source == .localClone ? "Local clone" : "Remote only")
                    if let n = r.unpushedCommits, n > 0 { Tag(text: "\(n) unpushed", style: .local) }
                    if r.usesLFS { Tag(text: "LFS not included", style: .archived) }
                    switch r.status {
                    case .goneFromGitHub: Tag(text: "Gone from GitHub", style: .bad)
                    case .missingLocally: Tag(text: r.source == .localClone ? "Clone missing" : "Removed from config", style: .bad)
                    case .failed: Tag(text: "Failed", style: .bad)
                    default: EmptyView()
                    }
                    if Date().timeIntervalSince(r.firstSeen) < 3 * 86400, r.status == .ok, r.archiveCount <= 1 { Tag(text: "New", style: .new) }
                }
                .help(r.message ?? "")
            }
            .width(min: 140, ideal: 220)
            TableColumn("Last change seen") { r in Text(date(r.lastChangeSeen)) }.width(min: 90, ideal: 120)
            TableColumn("Newest archive") { r in Text(date(r.newestArchive)).help(r.newestArchiveName ?? "") }.width(min: 90, ideal: 120)
            TableColumn("Archives kept") { r in Text(r.archiveCount.formatted()).monospacedDigit() }.width(min: 60, ideal: 90)
            TableColumn("Size") { r in
                Text(r.newestArchiveSize.map(Format.bytes) ?? "–").monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: RepoRecord.ID.self) { ids in
            if let id = ids.first, let r = repos.first(where: { $0.id == id }) {
                if let path = r.localPath { Button("Show Local Clone") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) } }
                Button("Open on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/\(r.fullName)")!) }
                if let gh = model.engine.config?.github {
                    Button("Copy Archive Path on NAS") {
                        let parts = r.fullName.split(separator: "/").map(String.init)
                        model.copyNASPath("\(gh.dest)/bundles/\(gh.group(forOwner: parts[0]))/\(parts[1])")
                    }
                }
                Divider()
                Button("Exclude in Config…") { model.openConfigInEditor() }
            }
        }
    }

    private func color(_ r: RepoRecord) -> Color {
        switch r.status {
        case .ok: r.newestArchive == nil ? Palette.grey : Palette.green
        case .excluded: Palette.grey
        case .failed, .goneFromGitHub, .missingLocally: Palette.red
        }
    }

    private func date(_ d: Date?) -> String {
        guard let d else { return "–" }
        return StatusText.dayAndTime(d)
    }
}

/// Adds a remote-only repo to the config (design 2g).
struct AddRepoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?

    private var parsed: String? {
        let t = name.trimmingCharacters(in: .whitespaces)
        if let p = GitHubRemote.parse(t) { return "\(p.owner)/\(p.repo)" }
        let parts = t.split(separator: "/")
        return parts.count == 2 && !t.contains(" ") ? t : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a repo to back up").font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("GitHub repo").font(.system(size: 12, weight: .medium))
                TextField("owner/repo or URL", text: $name).font(.system(size: 12.5, design: .monospaced))
                Text(hint).font(.system(size: 11.5)).foregroundStyle(error == nil ? Color.secondary : Palette.red)
            }
            Text("Local clones under your scan folders are found automatically. This adds the repo to remote_only, so it's backed up straight from GitHub.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add and Back Up Now", action: add).keyboardShortcut(.defaultAction).disabled(parsed == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var hint: String {
        if let error { return error }
        guard let p = parsed else { return "Name or URL, like acme/firmware." }
        if model.engine.config?.github?.excludeSet.matches(p) == true { return "\(p) matches an exclude pattern; remove it from exclude too." }
        return "Will be added as \(p)."
    }

    private func add() {
        guard let p = parsed else { return }
        do {
            try ConfigEditor.addRemoteOnly(p, in: model.engine.configURL)
            model.engine.reloadConfig()
            model.engine.backUpReposNow()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
