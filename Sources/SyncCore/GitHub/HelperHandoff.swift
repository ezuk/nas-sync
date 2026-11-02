import Foundation

/// The Mac's side of repos the NAS helper backs up. The helper fetches from GitHub itself, so the Mac only sends
/// what a local clone holds, with `git push` into `refs/mac/` in the helper's mirror. rsync is never used on these
/// mirrors: it would delete whatever the helper fetched.
extension GitHubBackup {
    /// Installs or updates the helper and reads its latest run. Returns why it can't be used, or nil.
    func prepareHelper(_ helper: NASHelper) -> String? {
        let started = Date()
        do {
            let report = try helper.ensure()
            if report.change != nil, let run = report.runRecord(started: started) { store.saveHelperChange(run) }
            guard report.state == .ready else {
                return "The NAS helper isn't ready: \(report.error ?? report.state.rawValue)"
            }
            if let last = try helper.lastRun() { Self.applyHelperRun(last, config: config, store: store) }
            return nil
        } catch {
            return "Couldn't check the NAS helper: \(error)"
        }
    }

    /// Saves the list of repos for the helper's scheduled runs and starts a run now.
    func handOffToHelper(_ helper: NASHelper) throws {
        let manifest = HelperManifest.build(config: config, nas: nas, store: store)
        try helper.save(manifest)
        if startsHelperRuns, !manifest.repos.isEmpty { try helper.startRun() }
    }

    /// Copies what a helper run found into the repo records. Repos no longer using the helper are left alone.
    public static func applyHelperRun(_ report: HelperRunReport, config: GitHubConfig, store: Store) {
        let known = Dictionary(store.repos().map { ($0.fullName.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let when = report.finished ?? report.started ?? Date()
        for repo in report.repos where config.usesHelper(repo.name) {
            guard let old = known[repo.name.lowercased()] else { continue }
            var r = old
            r.usesHelper = true
            if let bytes = repo.bytes { r.sizeOnNAS = bytes }
            if repo.action == "new" || repo.action == "changed" {
                r.lastChangeSeen = when
                r.mirrorUpdated = when
            } else if r.mirrorUpdated == nil, repo.action == "unchanged" {
                r.mirrorUpdated = when
            }
            if let kept = repo.keptRefs { r.deletedRefsKept = Array(Set(r.deletedRefsKept).union(kept)).sorted() }
            r.helperProblem = repo.action == "failed" || repo.action == "warning" ? repo.detail ?? "The NAS helper couldn't back this up." : nil
            r.helperGone = repo.gone == true
            if r.status != .excluded, r.status != .missingLocally { r.refreshHelperStatus() }
            if r != old { try? store.saveRepo(r) }
        }
    }

    /// Sends a local clone's branches, tags and stash to the helper's mirror when they've changed. Remote-only repos
    /// need nothing from this Mac. The first send waits until the helper has made the mirror, so the Mac doesn't
    /// have to upload what the helper can get from GitHub.
    func sendToHelper(
        _ t: RepoTarget, existing: RepoRecord?, mirrorPath: String, dryRun: Bool,
        isCancelled: @escaping @Sendable () -> Bool, report: (Step) -> Void
    ) throws -> RepoResult {
        report(.checking)
        var record = existing ?? newRecord(t, now: Date())
        record.source = t.source
        record.localPath = t.localPath?.path(percentEncoded: false)
        record.hasGitHubRemote = t.hasGitHubRemote
        if record.mirrorPath != mirrorPath {
            record.usesHelper = false
            record.mirrorPath = mirrorPath
        }
        if record.status == .excluded || record.status == .missingLocally { record.refreshHelperStatus() }
        func save() { if !dryRun { try? store.saveRepo(record) } }

        guard t.source == .localClone, let dir = t.localPath else {
            save()
            return RepoResult(fullName: t.fullName, action: .onNAS, reason: "backed up from GitHub by the NAS helper", size: record.sizeOnNAS)
        }
        let refs = try localRefs(dir)
        record.unpushedCommits = Int((try? git.run(["rev-list", "--count", "--branches", "--not", "--remotes"], in: dir, timeout: 60))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        record.usesLFS = usesLFS(dir)
        guard record.usesHelper else {
            save()
            return RepoResult(fullName: t.fullName, action: .onNAS, reason: "waiting for the NAS helper's first backup", size: record.sizeOnNAS)
        }
        let fingerprint = Self.fingerprint(refs)
        guard fingerprint != record.macFingerprint || record.pushError != nil else {
            save()
            return RepoResult(fullName: t.fullName, action: .onNAS, reason: "nothing new on this Mac", size: record.sizeOnNAS)
        }
        let unpushed = record.unpushedCommits ?? 0
        let reason = unpushed > 0 ? "sent \(Format.count(unpushed, "commit")) not on GitHub yet" : "sent this Mac's branches to the NAS"
        if dryRun { return RepoResult(fullName: t.fullName, action: .wouldBackUp, reason: reason) }

        report(.copying)
        do {
            if !refs.isEmpty { try pushToHelper(dir, mirrorPath: mirrorPath, hasStash: refs["refs/stash"] != nil, isCancelled: isCancelled) }
            record.macFingerprint = fingerprint
            record.pushError = nil
            record.refreshHelperStatus()
            save()
            return RepoResult(fullName: t.fullName, action: refs.isEmpty ? .onNAS : .backedUp, reason: refs.isEmpty ? "no branches on this Mac" : reason, size: record.sizeOnNAS)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let message = "\(Self.stepPhrase(.copying)): \(Self.plain(error))"
            record.pushError = message
            record.refreshHelperStatus()
            save()
            return RepoResult(fullName: t.fullName, action: .failed, reason: message)
        }
    }

    /// Never touches the clone's working folder, branches or remotes, and skips its hooks.
    private func pushToHelper(_ dir: URL, mirrorPath: String, hasStash: Bool, isCancelled: @escaping @Sendable () -> Bool) throws {
        let url = nas.gitCloneURL("\(dest)/\(HelperManifest.mirrorsFolder)/\(mirrorPath)")
        let ssh = nas.isRemote ? ["-c", "core.sshCommand=\(nas.rsyncShell)"] : []
        var specs = ["+refs/heads/*:refs/mac/heads/*", "+refs/tags/*:refs/mac/tags/*"]
        if hasStash {
            specs.append("+refs/stash:refs/mac/stash")
        } else {
            let found = try git.run(ssh + ["ls-remote"] + (nas.isRemote ? ["--upload-pack=\(NAS.gitPathOnNAS) git-upload-pack"] : []) + [url, "refs/mac/stash"],
                                    in: dir, timeout: 120, isCancelled: isCancelled)
            if !found.isEmpty { specs.append(":refs/mac/stash") }
        }
        let receive = nas.isRemote ? ["--receive-pack=\(NAS.gitPathOnNAS) git-receive-pack"] : []
        try git.run(ssh + ["push", "--quiet", "--no-verify", "--no-recurse-submodules", "--no-signed", "--prune"] + receive + [url] + specs,
                    in: dir, isCancelled: isCancelled)
    }
}
