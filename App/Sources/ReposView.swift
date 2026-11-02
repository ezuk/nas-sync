import SwiftUI
import SyncCore

/// Every known repo and the state of its git mirror on the NAS (design 2e).
struct ReposView: View {
    @Environment(AppModel.self) private var model
    @State private var repos: [RepoRecord] = []
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var showAdd = false
    @State private var sortOrder = [KeyPathComparator(\RepoRecord.fullName)]
    @State private var selection: RepoRecord.ID?

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
            if let problem = selectedProblem {
                Divider()
                ProblemCard(subject: problem.fullName, diagnosis: Diagnosis.forRepo(problem), repo: problem)
                    .id(problem.fullName)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            Text("Each repo is one git mirror on the NAS. Work that's only on this Mac is in from-mac/ branches. Branches and tags deleted or force-pushed at the source stay in it under refs/deleted.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search \(repos.count) repos")
        .navigationTitle("Repos")
        .onAppear {
            load()
            if model.repoProblemsRequest > 0 { showProblems() }
        }
        .onChange(of: model.engine.historyVersion) { load() }
        .onChange(of: model.repoProblemsRequest) { showProblems() }
        .onChange(of: filter) { if filter == .problems, selectedProblem == nil { selection = visible.first?.id } }
        .sheet(isPresented: $showAdd) { AddRepoSheet() }
    }

    private func load() { repos = model.engine.store.repos() }

    private var selectedProblem: RepoProblem? {
        selection.flatMap { id in repos.first { $0.id == id } }?.problem
    }

    /// Switches to the Problems filter with the worst repo selected.
    private func showProblems() {
        filter = .problems
        selection = (visible.first { $0.status == .failed } ?? visible.first)?.id
    }

    private func matches(_ r: RepoRecord, _ f: Filter) -> Bool {
        switch f {
        case .all: r.status != .excluded
        case .local: r.source == .localClone && r.status != .excluded
        case .remote: r.source == .remoteOnly && r.status != .excluded
        case .problems: r.problem != nil
        case .excluded: r.status == .excluded
        }
    }

    private func count(_ f: Filter) -> Int { repos.filter { matches($0, f) }.count }

    private var visible: [RepoRecord] {
        repos.filter { matches($0, filter) && (search.isEmpty || $0.fullName.localizedCaseInsensitiveContains(search)) }
            .sorted(using: sortOrder)
    }

    private var table: some View {
        Table(visible, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { r in StatusDot(color: color(r)) }.width(14)
            TableColumn("Repo", value: \.fullName) { r in
                Text(r.fullName).font(.system(size: 11.5, design: .monospaced)).help(r.localPath ?? "")
            }
            .width(min: 180, ideal: 240)
            TableColumn("Source") { r in
                HStack(spacing: 6) {
                    Text(r.source == .localClone ? "Local clone" : "Remote only")
                    if !r.hasGitHubRemote { Tag(text: "No GitHub remote", style: .local).help("No GitHub remote. The NAS has the only other copy.") }
                    if let n = r.unpushedCommits, n > 0 { Tag(text: "\(n) unpushed", style: .local) }
                    if r.usesLFS, !r.usesHelper { Tag(text: "LFS not included", style: .archived) }
                    switch r.status {
                    case .goneFromGitHub: Tag(text: "Gone from GitHub", style: .bad)
                    case .missingLocally: Tag(text: r.source == .localClone ? "Clone missing" : "Removed from config", style: .bad)
                    case .failed: Tag(text: "Failed", style: .bad)
                    default:
                        if r.isWaitingForMirror { Tag(text: "Not on NAS yet", style: .archived) }
                    }
                    if Date().timeIntervalSince(r.firstSeen) < 3 * 86400, r.status == .ok { Tag(text: "New", style: .new) }
                }
                .help(r.message ?? (r.hasGitHubRemote ? "" : "No GitHub remote. The NAS has the only other copy."))
            }
            .width(min: 140, ideal: 220)
            TableColumn("Last change seen") { r in Text(date(r.lastChangeSeen)) }.width(min: 90, ideal: 120)
            TableColumn("Mirror updated") { r in Text(date(r.mirrorUpdated)).help(r.mirrorPath ?? "") }.width(min: 90, ideal: 120)
            TableColumn("Deleted at source, kept") { r in
                Text(r.deletedRefsKept.isEmpty ? "–" : r.deletedRefsKept.count.formatted()).monospacedDigit()
                    .help(r.deletedRefsKept.prefix(20).map { String($0.dropFirst(GitHubBackup.deletedRefsPrefix.count)) }.joined(separator: "\n"))
            }
            .width(min: 60, ideal: 130)
            TableColumn("On NAS") { r in
                Text(r.sizeOnNAS.map(Format.bytes) ?? "–").monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: RepoRecord.ID.self) { ids in
            if let id = ids.first, let r = repos.first(where: { $0.id == id }) {
                if let path = r.localPath { Button("Show Local Clone") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) } }
                if let url = r.githubURL { Button("Open on GitHub") { NSWorkspace.shared.open(url) } }
                if let gh = model.engine.config?.githubSettings, let path = GitHubBackup.nasMirrorPath(dest: gh.dest, record: r) {
                    Button("Copy Mirror Path on NAS") { model.copyNASPath(path) }
                }
                Divider()
                Button("Exclude in Config…") { model.openConfigInEditor() }
            }
        }
    }

    private func color(_ r: RepoRecord) -> Color {
        switch r.status {
        case .ok: r.mirrorUpdated == nil ? Palette.grey : Palette.green
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
            Text("Local clones under your scan folders are found automatically. This adds the repo to remote_only, so it's mirrored straight from GitHub.")
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
        if let known = model.engine.store.repos().first(where: { $0.fullName.lowercased() == p.lowercased() }), known.source == .localClone {
            return "You have a local clone of \(known.fullName), so it's listed under Local clones, not Remote only."
        }
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
