import Foundation

/// A repo that needs the user's attention.
public struct RepoProblem: Sendable, Codable, Equatable, Identifiable {
    public var fullName: String
    public var source: RepoSource
    public var localPath: String?
    public var status: RepoStatus
    public var message: String?
    public var hasGitHubRemote: Bool

    public var id: String { fullName }

    public var githubURL: URL? { hasGitHubRemote ? URL(string: "https://github.com/\(fullName)") : nil }

    public init(fullName: String, source: RepoSource, localPath: String?, status: RepoStatus, message: String?, hasGitHubRemote: Bool) {
        self.fullName = fullName
        self.source = source
        self.localPath = localPath
        self.status = status
        self.message = message
        self.hasGitHubRemote = hasGitHubRemote
    }
}

extension RepoRecord {
    /// True for a repo with history that has no mirror on the NAS yet.
    public var isWaitingForMirror: Bool { status == .ok && mirrorUpdated == nil && !refs.isEmpty }

    public var problem: RepoProblem? {
        guard [.failed, .missingLocally, .goneFromGitHub].contains(status) || isWaitingForMirror else { return nil }
        return RepoProblem(fullName: fullName, source: source, localPath: localPath, status: status, message: message, hasGitHubRemote: hasGitHubRemote)
    }
}

/// A problem in plain language: what happened, and what to do about it.
public struct Diagnosis: Sendable, Equatable {
    public enum Fix: Sendable, Hashable {
        case backUpAgain
        case syncAgain
        case revealClone
        case openOnGitHub
        case copyCommand(String)
        case forgetRepo
        case stopBackingUp
        case openFullDiskAccess
        case openSettings
        case checkHelperAgain

        public var label: String {
            switch self {
            case .backUpAgain: "Back Up Again"
            case .syncAgain: "Sync Again"
            case .revealClone: "Show Clone"
            case .openOnGitHub: "Open on GitHub"
            case .copyCommand: "Copy Command"
            case .forgetRepo: "Forget This Repo"
            case .stopBackingUp: "Stop Backing Up"
            case .openFullDiskAccess: "Open Privacy Settings"
            case .openSettings: "Open Settings"
            case .checkHelperAgain: "Check Again"
            }
        }

        /// Changes what's backed up, so it asks first and isn't offered in the menu.
        public var needsConfirmation: Bool { self == .forgetRepo || self == .stopBackingUp }
    }

    public var title: String
    public var explanation: String
    public var advice: String
    public var fixes: [Fix]
    /// The original error, for "Copy Details".
    public var technical: String
    /// Sorts itself out on the next run.
    public var isTransient = false
    /// True when no explanation matched, so the technical text is all there is.
    public var isUnrecognized = false

    // MARK: Repos

    public static func forRepo(_ p: RepoProblem) -> Diagnosis {
        let text = p.message ?? ""
        switch p.status {
        case .missingLocally:
            return p.source == .localClone
                ? Diagnosis(title: "The local clone is gone",
                            explanation: "NAS Sync can't find this repo in your scan folders any more. Its backup on the NAS is safe, but it isn't being updated.",
                            advice: "If you moved the folder, add its new location in Settings. If you deleted it on purpose, forget it here; the NAS copy stays.",
                            fixes: [.openSettings, .forgetRepo], technical: text)
                : Diagnosis(title: "No longer in your config",
                            explanation: "This repo was removed from remote_only, so it isn't being updated. Its backup on the NAS is safe.",
                            advice: "Forget it here if that's what you wanted; the NAS copy stays.",
                            fixes: [.forgetRepo, .openSettings], technical: text)
        case .goneFromGitHub:
            return p.source == .localClone
                ? Diagnosis(title: "GitHub says this repo is gone",
                            explanation: "GitHub no longer has this repo, or your account lost access to it. It's still being backed up from the clone on this Mac.",
                            advice: "Your clone and the NAS may now be the only copies. No action is needed unless you expected it to still exist.",
                            fixes: [.openOnGitHub, .revealClone], technical: text)
                : Diagnosis(title: "GitHub says this repo is gone",
                            explanation: "GitHub no longer has this repo, or your account lost access to it. The backup on the NAS is safe, but it can't be updated.",
                            advice: "If it was renamed, add the new name in Settings. If you're done with it, stop backing it up; the NAS copy stays.",
                            fixes: [.openOnGitHub, .stopBackingUp], technical: text)
        case .ok where p.message == nil:
            return Diagnosis(title: "Not on the NAS yet",
                             explanation: "This repo has history, but no mirror of it has been copied to the NAS.",
                             advice: "Back up again to copy it.",
                             fixes: [.backUpAgain], technical: "")
        default:
            var d = explain(text, localPath: p.localPath)
            if p.source == .localClone, !d.fixes.contains(.revealClone), d.isUnrecognized { d.fixes.append(.revealClone) }
            if p.hasGitHubRemote, d.isUnrecognized { d.fixes.append(.openOnGitHub) }
            return d
        }
    }

    // MARK: NAS helper

    /// Tokens this close to expiring get a warning.
    static let tokenExpiryWarning: TimeInterval = 14 * 86400

    /// What's wrong with the helper on the NAS. Nil when it's fine, or when a check couldn't tell.
    public static func forHelper(_ report: HelperReport, now: Date = Date()) -> Diagnosis? {
        switch report.state {
        case .appTooOld:
            return Diagnosis(title: "The NAS helper is newer than this app",
                             explanation: "The NAS has helper version \(report.installedVersion ?? 0), which this app can't work with. It was left in place.",
                             advice: "Update NAS Sync to the latest version.",
                             fixes: [.checkHelperAgain], technical: "installed \(report.installedVersion ?? 0), app has \(report.bundledVersion)")
        case .failed:
            let installed = report.installedVersion != nil
            return Diagnosis(title: installed ? "The NAS helper couldn't be updated" : "The NAS helper couldn't be installed",
                             explanation: installed ? "The version already on the NAS is still in place." : "NAS Sync couldn't set up its helper on the NAS.",
                             advice: report.error ?? "Try again. If it keeps happening, the details say what went wrong.",
                             fixes: [.checkHelperAgain], technical: report.error ?? "")
        case .needsInstall:
            return nil
        case .ready:
            break
        }
        let failed = report.failedChecks
        let technical = failed.map { "\($0.id): \($0.detail)" }.joined(separator: "\n")
        if failed.contains(where: { $0.id == "python" }) {
            return Diagnosis(title: "The NAS's Python is too old",
                             explanation: "The helper needs Python 3.8 or newer on the NAS.",
                             advice: "Update DSM or install a newer Python package, then check again.",
                             fixes: [.checkHelperAgain], technical: technical)
        }
        if failed.contains(where: { ["git", "git-lfs", "git-transport"].contains($0.id) }) {
            return Diagnosis(title: "Git isn't ready on the NAS",
                             explanation: "The helper needs Git and Git LFS on the NAS to back up repos from GitHub.",
                             advice: "Install the Git package in Package Center, then check again.",
                             fixes: [.checkHelperAgain], technical: technical)
        }
        if failed.contains(where: { $0.id == "tokens" }) {
            return Diagnosis(title: "The NAS has no GitHub token",
                             explanation: "The helper needs a read-only GitHub token to reach your private repos.",
                             advice: "Save a token in \(NASHelper.stateFolder)/github-token-<owner> on the NAS, then check again.",
                             fixes: [.checkHelperAgain], technical: technical)
        }
        if let token = failed.first(where: { $0.tokenOwner != nil }), let owner = token.tokenOwner {
            let explanation = switch token.detail {
            case "saved twice": "The token file holds the same token twice in a row, so GitHub would reject it."
            case "readable by others": "Other accounts on the NAS can read the token file."
            case "empty": "The token file is empty."
            default: "GitHub rejected this token. It may have expired or been deleted."
            }
            let advice = token.detail == "readable by others"
                ? "Run chmod 600 on \(NASHelper.stateFolder)/github-token-\(owner) on the NAS, then check again."
                : "Save a new read-only token in \(NASHelper.stateFolder)/github-token-\(owner) on the NAS, then check again."
            return Diagnosis(title: "The GitHub token for \(owner) needs attention", explanation: explanation, advice: advice,
                             fixes: [.checkHelperAgain], technical: technical)
        }
        if let token = report.checks.first(where: { $0.tokenOwner != nil && ($0.expires ?? .distantFuture).timeIntervalSince(now) < tokenExpiryWarning }),
           let owner = token.tokenOwner, let expires = token.expires {
            return Diagnosis(title: "The GitHub token for \(owner) expires soon",
                             explanation: "It stops working on \(expires.formatted(date: .abbreviated, time: .omitted)).",
                             advice: "Create a new read-only token and save it in \(NASHelper.stateFolder)/github-token-\(owner) on the NAS.",
                             fixes: [.checkHelperAgain], technical: "\(token.id): expires \(expires)")
        }
        return nil
    }

    /// How long the helper can go without a run before it's reported. Its schedule runs hourly.
    static let helperRunOverdue: TimeInterval = 3 * 3600
    /// A first backup of every repo can take many hours.
    static let helperRunStuck: TimeInterval = 24 * 3600

    /// Scheduled runs on the NAS have stopped, or a run has stalled.
    public static func forHelperRun(_ run: HelperRunReport?, now: Date = Date()) -> Diagnosis? {
        guard let run else { return nil }
        let advice = "Check the task in DSM's Task Scheduler on the NAS, then run the helper from Settings."
        if run.isFinished {
            guard let finished = run.finished, now.timeIntervalSince(finished) > helperRunOverdue else { return nil }
            return Diagnosis(title: "The NAS helper hasn't run lately",
                             explanation: "Its last run finished \(Format.duration(now.timeIntervalSince(finished))) ago, so GitHub changes aren't reaching the NAS.",
                             advice: advice, fixes: [.openSettings, .checkHelperAgain], technical: "last run finished \(finished)")
        }
        guard let started = run.started, now.timeIntervalSince(started) > helperRunStuck else { return nil }
        return Diagnosis(title: "The NAS helper's run looks stuck",
                         explanation: "It started \(Format.duration(now.timeIntervalSince(started))) ago and hasn't finished.",
                         advice: advice, fixes: [.openSettings, .checkHelperAgain], technical: "started \(started), on \(run.current ?? "unknown")")
    }

    // MARK: Runs

    /// The problems in a finished run, each with what it's about. Empty when there's nothing to explain.
    public static func forRun(_ run: RunRecord) -> [(subject: String?, diagnosis: Diagnosis)] {
        guard run.outcome == .warning || run.outcome == .failed else { return [] }
        switch run.kind {
        case .github:
            let failed = run.items.filter { $0.action == .failed }
            if failed.isEmpty { return run.message.map { [(nil, explain($0))] } ?? [] }
            return failed.map { ($0.path, explain($0.detail ?? "")) }
        case .folder, .check:
            return forFolderRun(run).map { [(run.job, $0)] } ?? []
        default:
            return []
        }
    }

    /// What went wrong in a folder run. Permanent problems come before ones that sort themselves out.
    public static func forFolderRun(_ run: RunRecord) -> Diagnosis? {
        guard let message = run.message, run.outcome == .warning || run.outcome == .failed else { return nil }
        let lines = message.split(whereSeparator: \.isNewline).map(String.init)
        let all = lines.map { explain($0) }
        guard var d = all.first(where: { !$0.isTransient }) ?? all.first else { return nil }
        d.fixes = run.outcome == .failed ? d.fixes.map { $0 == .backUpAgain ? .syncAgain : $0 } : d.fixes.filter { $0 != .backUpAgain }
        d.technical = message
        if run.counts.failed > lines.count { d.technical += "\n(and \(run.counts.failed - lines.count) more; see the run in Activity)" }
        return d
    }

    // MARK: Error text

    /// Recognizes an error from git, rsync, ssh or the system, as stored in history.
    public static func explain(_ text: String, localPath: String? = nil) -> Diagnosis {
        let t = text.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { t.contains($0) } }

        if has("bad file descriptor", "too many open files") {
            return Diagnosis(title: "NAS Sync ran out of open files",
                             explanation: "The app had too many files open at once, so it couldn't run the commands it needed. The repo itself is fine, and its copy on the NAS wasn't changed.",
                             advice: "Back up again. Anything else this run missed gets picked up too.",
                             fixes: [.backUpAgain], technical: text)
        }
        if has("reported no branches") {
            return Diagnosis(title: "git reported no branches for this repo",
                             explanation: "It had branches at the last backup, and an empty answer is more likely a glitch than a real change. The mirror on the NAS wasn't changed.",
                             advice: "Back up again. If it keeps happening, check the repo really still has its branches.",
                             fixes: [.backUpAgain, .revealClone, .openOnGitHub], technical: text)
        }
        if has("couldn't sign in to github", "permission denied (publickey)", "host key verification failed") {
            return Diagnosis(title: "GitHub refused the SSH sign-in",
                             explanation: "git couldn't sign in to GitHub, so it couldn't read this repo. This usually means your SSH key isn't loaded.",
                             advice: "Run the command in Terminal to load your key, then back up again.",
                             fixes: [.copyCommand("ssh-add --apple-use-keychain"), .backUpAgain], technical: text)
        }
        if has("could not resolve host", "couldn't reach github") {
            return Diagnosis(title: "Couldn't reach GitHub",
                             explanation: "This Mac couldn't find GitHub on the network. It's most likely an internet problem.",
                             advice: "Check your internet connection, then back up again.",
                             fixes: [.backUpAgain], technical: text)
        }
        if has("no space left", "nas is full", "disk quota exceeded") {
            return Diagnosis(title: "The NAS is full",
                             explanation: "There wasn't enough free space on the NAS to finish copying.",
                             advice: "Free up space on the NAS, then try again.",
                             fixes: [.backUpAgain], technical: text)
        }
        if has("cannot convert filename", "illegal byte sequence") {
            return Diagnosis(title: "A new file's name needs special handling",
                             explanation: "rsync can't convert this name for the NAS, usually because of an emoji, so NAS Sync copies these files separately. This one appeared during the run.",
                             advice: "Nothing to do. It's copied on the next sync.",
                             fixes: [], technical: text, isTransient: true)
        }
        if has("couldn't copy some files") {
            return Diagnosis(title: "Some files couldn't be copied",
                             explanation: "rsync skipped some files, but this run didn't record which ones. Everything else was copied.",
                             advice: "Sync again, and this will name the files.",
                             fixes: [.syncAgain], technical: text)
        }
        if has("skipped deleting files") {
            return Diagnosis(title: "Deleted files weren't cleared from the NAS",
                             explanation: "rsync hit an error, and when that happens it doesn't delete anything for the rest of the run. Files you deleted may still be on the NAS. Nothing was lost.",
                             advice: "Sync again. If this keeps happening, the other problems listed for this run are the cause.",
                             fixes: [.syncAgain], technical: text)
        }
        if has("changed while copying", "file has vanished") {
            return Diagnosis(title: "A file changed while it was being copied",
                             explanation: "The file changed or moved during the copy. This is normal for files that are in use.",
                             advice: "Nothing to do. It's copied again on the next sync.",
                             fixes: [], technical: text, isTransient: true)
        }
        if has("dubious ownership") {
            return Diagnosis(title: "git doesn't trust this folder",
                             explanation: "git refuses to read a repo that looks like it belongs to another user.",
                             advice: "Run the command in Terminal if this folder is yours, then back up again.",
                             fixes: (localPath.map { [.copyCommand("git config --global --add safe.directory \(NAS.quote($0))")] } ?? []) + [.backUpAgain, .revealClone],
                             technical: text)
        }
        if has("didn't pass git's check", "isn't a git repository on the nas") {
            return Diagnosis(title: "The mirror failed git's integrity check",
                             explanation: "Something in the mirror didn't check out, so it wasn't copied. The copy on the NAS wasn't changed.",
                             advice: "Back up again, which rebuilds the local mirror from the NAS copy.",
                             fixes: [.backUpAgain], technical: text)
        }
        if has("not a git repository") {
            return Diagnosis(title: "This folder isn't a working git repo",
                             explanation: "git can't read this folder as a repo. Its .git folder may be damaged or missing.",
                             advice: "Look at the folder, and clone it again if it's damaged.",
                             fixes: [.revealClone, .backUpAgain], technical: text)
        }
        if has("timed out", "lost the connection", "connection closed", "connection reset", "connection refused", "broken pipe",
               "connection unexpectedly closed", "didn't answer over ssh", "unexplained error", "hung up") {
            return Diagnosis(title: "The connection dropped",
                             explanation: "The network connection went away partway through. Nothing is damaged; a copy that doesn't finish doesn't replace what's on the NAS.",
                             advice: "Make sure the NAS is awake and reachable, then try again.",
                             fixes: [.backUpAgain], technical: text)
        }
        if has("permission denied", "operation not permitted") {
            return Diagnosis(title: "macOS or the NAS blocked access",
                             explanation: "NAS Sync wasn't allowed to read or write something it needed.",
                             advice: "Check that NAS Sync has Full Disk Access, restart it, and try again. The details below name the file.",
                             fixes: [.openFullDiskAccess, .backUpAgain], technical: text)
        }
        return Diagnosis(title: "Something unexpected went wrong",
                         explanation: "NAS Sync doesn't recognize this error. The details below are exactly what it got back.",
                         advice: "Try again. If it keeps happening, the details are what's needed to track it down.",
                         fixes: [.backUpAgain], technical: text, isUnrecognized: true)
    }

    /// The path in "cannot convert filename: <path> (Illegal byte sequence)".
    static func fileName(in text: String) -> String? {
        guard let start = text.range(of: "cannot convert filename: ") else { return nil }
        let rest = text[start.upperBound...]
        let end = rest.range(of: " (Illegal byte sequence)")?.lowerBound ?? rest.endIndex
        let name = rest[..<end].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
