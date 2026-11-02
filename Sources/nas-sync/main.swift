import Foundation
import SyncCore

var args = Array(CommandLine.arguments.dropFirst())

@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

@MainActor func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

let configURL = option("--config").map { URL(filePath: ($0 as NSString).expandingTildeInPath) } ?? ConfigLoader.defaultURL()
let stateDir = option("--state").map { URL(filePath: ($0 as NSString).expandingTildeInPath) }
let dryRun = flag("--dry-run")
let json = flag("--json")
let allowMassDelete = flag("--allow-mass-delete")
let verbose = flag("--verbose") || flag("-v")

func usage() {
    print("""
    usage: nas-sync [--config <file>] <command>

      validate [file]              check the config file
      status [--json]              show what the app is doing (reads the app's status file)
      watch [--every N]            print a line whenever the app's status changes, and each finished run
      check                        check the NAS answers over SSH and rsync is installed
      diagnose                     run the NAS checklist step by step
      run folders [name] [--dry-run] [-v] [--allow-mass-delete]
                                   compare and copy folder jobs now
      run github [--dry-run] [-v]  back up git repos now
      mirror [repo]                show where each repo's git mirror is on the NAS and how to clone it
      helper status [--json]       show the helper on the NAS and its health, without changing anything
      helper install [--json]      install or update the helper on the NAS if needed, then show its health
      unpack <archive.bundle.xz> [out]
                                   decompress an archive made by older versions to a .bundle you can git clone
    """)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadConfig() -> AppConfig {
    let result = ConfigLoader.load(from: configURL)
    for issue in result.issues { FileHandle.standardError.write(Data("\(issue.severity.rawValue): \(issue)\n".utf8)) }
    guard result.isValid, let config = result.config else { fail("The config has errors, nothing was run.") }
    return config
}

func openStore() -> Store {
    do { return try stateDir.map { try Store(directory: $0) } ?? Store() } catch { fail("Can't open the state database: \(error)") }
}

func connectedNAS(_ config: AppConfig) -> NAS {
    let nas = NAS(config: config.nas)
    if case .failure(let problem) = nas.check() { fail("Can't use the NAS: \(problem)") }
    return nas
}

@MainActor func printRun(_ r: RunRecord) {
    let when = r.duration.map { " in \(Format.duration($0))" } ?? ""
    print("\(r.job): \(r.outcome.rawValue). \(r.summary)\(when)")
    if let m = r.message { print("  " + m.replacingOccurrences(of: "\n", with: "\n  ")) }
    let shown = verbose ? r.items : r.items.filter { $0.action != .unchanged }
    for item in shown.prefix(verbose ? .max : 40) {
        let size = item.size.map { " (\(Format.bytes($0)))" } ?? ""
        let detail = item.detail.map { " · \($0)" } ?? ""
        print("  \(item.action.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(item.path)\(size)\(detail)")
    }
    if !verbose, shown.count > 40 { print("  … \(shown.count - 40) more (use -v)") }
}

switch args.first {
case "validate":
    let url = args.count > 1 ? URL(filePath: args[1]) : configURL
    let result = ConfigLoader.load(from: url)
    for issue in result.issues { print("\(issue.severity.rawValue): \(issue)") }
    if result.isValid, let c = result.config {
        print("Config OK. \(Format.count(c.folders.count, "folder")), NAS \(c.nas.ssh.map { "\($0):" } ?? "")\(c.nas.path), home Wi-Fi “\(c.home.wifi)”\(c.github == nil ? "" : ", GitHub backups on").")
    }
    exit(result.isValid ? 0 : 1)

case "status":
    let url = stateDir?.appending(path: "status.json") ?? StatusSnapshot.fileURL()
    guard let s = StatusSnapshot.read(from: url) else { fail("No status yet. Is the NAS Sync app running?") }
    if json {
        FileHandle.standardOutput.write(s.jsonData())
        print()
        exit(0)
    }
    let h = StatusText.headline(s)
    print("\(h.title)\n\(h.detail)\n")
    for j in s.jobs {
        print("  \(j.name): \(j.state.rawValue), last success \(StatusText.short(j.lastSuccess)). \(StatusText.jobLine(j))")
    }
    let age = Date().timeIntervalSince(s.updated)
    if age > 120 { print("\nStatus is \(Format.duration(age)) old; the app may not be running.") }

case "watch":
    let url = stateDir?.appending(path: "status.json") ?? StatusSnapshot.fileURL()
    let every = option("--every").flatMap(Double.init) ?? 5
    let store = openStore()
    signal(SIGINT) { _ in exit(0) }
    setvbuf(stdout, nil, _IOLBF, 0)
    func stamp() -> String { Date().formatted(date: .omitted, time: .standard) }
    func describe(_ r: RunRecord) -> String {
        let when = r.duration.map { " in \(Format.duration($0))" } ?? ""
        return "\(r.job) finished: \(r.outcome.rawValue). \(r.summary)\(when)"
    }
    var lastRunID = (try? store.recentRuns(limit: 1).first?.id) ?? 0
    for r in ((try? store.recentRuns(limit: 3)) ?? []).reversed() {
        print("[earlier] \(describe(r)) (\(StatusText.relative(r.finished ?? r.started, now: Date())))")
    }
    var lastHeadline = ""
    var lastLines: [String: String] = [:]
    var warnedStale = false
    while true {
        if let s = StatusSnapshot.read(from: url) {
            let h = StatusText.headline(s)
            let headline = "\(h.title). \(h.detail)"
            if headline != lastHeadline { print("[\(stamp())] \(headline)"); lastHeadline = headline }
            for j in s.jobs {
                let line = "\(j.state.rawValue): \(StatusText.jobLine(j, showElapsed: false))"
                if lastLines[j.name] != line { print("[\(stamp())]   \(j.name) · \(line)"); lastLines[j.name] = line }
            }
            let age = Date().timeIntervalSince(s.updated)
            if age > 120, !warnedStale { print("[\(stamp())] Status is \(Format.duration(age)) old; the app may not be running."); warnedStale = true }
            if age <= 120 { warnedStale = false }
        }
        let fresh = ((try? store.recentRuns(limit: 20)) ?? []).filter { ($0.id ?? 0) > lastRunID }
        for r in fresh.reversed() { print("[\(stamp())] \(describe(r))") }
        if let top = fresh.first?.id { lastRunID = top }
        Thread.sleep(forTimeInterval: every)
    }

case "check":
    let nas = connectedNAS(loadConfig())
    print("OK: \(nas.rsyncTarget("")) answers, using \(nas.rsync?.path(percentEncoded: false) ?? "rsync").")

case "diagnose":
    let config = loadConfig()
    let wifi = WiFi.currentName()
    for step in NASCheck.diagnose(NAS(config: config.nas), wifiName: wifi ?? config.home.wifi, homeWiFi: config.home.wifi) {
        let mark = step.state == .ok ? "✓" : step.state == .failed ? "✕" : "–"
        print("\(mark) \(step.title)\(step.detail.map { ": \($0)" } ?? "")")
    }
    if wifi == nil { print("(Wi-Fi name isn't visible to command-line tools, so the Wi-Fi step was assumed.)") }

case "mirror":
    let config = loadConfig()
    guard let gh = config.githubSettings else { fail("There's no [github] section in the config.") }
    let nas = NAS(config: config.nas)
    let query = args.count > 1 ? args[1].lowercased() : nil
    let repos = openStore().repos().filter { r in r.mirrorPath != nil && (query.map { r.fullName.lowercased().contains($0) } ?? true) }
    if repos.isEmpty { fail(query == nil ? "No repo has a mirror on the NAS yet." : "No backed-up repo matches \(args[1]).") }
    for r in repos {
        let path = GitHubBackup.nasMirrorPath(dest: gh.dest, mirrorPath: r.mirrorPath!)
        let folder = (path as NSString).lastPathComponent
        let kept = r.deletedRefsKept.isEmpty ? "" : " · \(Format.count(r.deletedRefsKept.count, "deleted ref")) kept"
        print("\(r.fullName)\(r.sizeOnNAS.map { " (\(Format.bytes($0)))" } ?? "")\(kept)")
        print("  git clone \(nas.gitCloneURL(path))")
        print("  no git on the NAS: \(nas.copyDownCommand(path, to: folder)) && git clone \(folder)")
    }
    print("""

    git clone over SSH needs git on the NAS. Without it, git says git-upload-pack isn't found; use the rsync line.
    A clone gets every branch and tag. Branches and tags deleted at the source are kept in the mirror
    under refs/deleted/<day>/. To see them, clone with --mirror and run: git for-each-ref refs/deleted
    or fetch them into a clone with: git fetch origin 'refs/deleted/*:refs/deleted/*'
    """)

case "helper":
    let config = loadConfig()
    let nas = NAS(config: config.nas)
    guard nas.isRemote else { fail("The helper runs on the NAS, so it needs an SSH login: set ssh under [nas].") }
    if case .failure(let problem) = nas.check() { fail("Can't use the NAS: \(problem)") }
    let helper = NASHelper(nas: nas)
    let started = Date()
    let report: HelperReport
    do {
        switch args.dropFirst().first {
        case "status": report = try helper.status()
        case "install":
            report = try helper.ensure()
            if report.change != nil || report.state == .failed, let run = report.runRecord(started: started) { _ = try? openStore().saveRun(run) }
        default: fail("usage: nas-sync helper status|install [--json]")
        }
    } catch {
        fail("\(error)")
    }
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write((try? encoder.encode(report)) ?? Data())
        print()
    } else {
        let installed = report.installedVersion.map { "version \($0)" } ?? "not installed"
        let line: String = switch report.state {
        case .ready:
            switch report.change {
            case .installed?: "installed \(installed)"
            case .updated?: "updated to \(installed)"
            case .repaired?: "reinstalled \(installed)"
            case nil: "\(installed), up to date"
            }
        case .needsInstall:
            switch report.reason {
            case .damaged?: "installed but won't run. Run: nas-sync helper install"
            case .different?: "\(installed), but it doesn't match this tool's copy. Run: nas-sync helper install"
            case .older?: "\(installed); this tool has version \(report.bundledVersion). Run: nas-sync helper install"
            default: "\(installed). Run: nas-sync helper install"
            }
        case .appTooOld: "\(installed), newer than this tool's version \(report.bundledVersion). Update this tool."
        case .failed: "\(installed). \(report.error ?? "Something went wrong.")"
        }
        print("NAS helper: \(line)")
        for c in report.checks {
            let mark = c.status == .ok ? "✓" : c.status == .failed ? "✕" : "–"
            let expiry = c.expires.map { ", expires \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
            print("  \(mark) \(c.id): \(c.detail)\(expiry)")
        }
        if let d = Diagnosis.forHelper(report) { print("\n\(d.title). \(d.explanation) \(d.advice)") }
    }
    let healthy = report.state == .ready && report.failedChecks.isEmpty
    exit(healthy || report.state == .needsInstall ? 0 : 1)

case "unpack":
    guard args.count > 1 else { fail("usage: nas-sync unpack <archive.bundle.xz> [out]") }
    let input = URL(filePath: (args[1] as NSString).expandingTildeInPath)
    let name = input.lastPathComponent.hasSuffix(".xz") ? String(input.lastPathComponent.dropLast(3)) : input.lastPathComponent + ".out"
    let output = args.count > 2 ? URL(filePath: (args[2] as NSString).expandingTildeInPath) : URL(filePath: FileManager.default.currentDirectoryPath).appending(path: name)
    do { try XZ.decompress(input, to: output) } catch { fail("Couldn't unpack: \(error.localizedDescription)") }
    print("Wrote \(output.path(percentEncoded: false)). Restore with: git clone \"\(output.lastPathComponent)\" <folder>")
    print("(Newer backups are git mirrors you can clone directly; see: nas-sync mirror)")

case "run":
    args.removeFirst()
    let what = args.first
    let config = loadConfig()
    let store = openStore()
    let nas = connectedNAS(config)
    let cancel = CancelFlag()
    signal(SIGINT) { _ in exit(130) }
    switch what {
    case "folders":
        let name = args.count > 1 ? args[1] : nil
        let jobs = config.folders.filter { name == nil || $0.name == name }
        if jobs.isEmpty { fail("No folder job named \(name ?? "").") }
        for job in jobs {
            guard let lock = JobLock(job: job.name, directory: store.directory) else { fail("\(job.name) is already running in the app.") }
            let r = FolderRunner.run(job: job, nas: nas, store: store,
                                     options: .init(trigger: "command line", scope: .full, dryRun: dryRun, allowMassDelete: allowMassDelete), isCancelled: { cancel.isCancelled })
            _ = lock
            printRun(r)
        }
    case "github":
        guard let gh = config.github else { fail("GitHub backups are off: there's no [github] section, or it has enabled = false.") }
        guard let lock = JobLock(job: StoreKey.githubJob, directory: store.directory) else { fail("GitHub backups are already running in the app.") }
        let backup = GitHubBackup(config: gh, nas: nas, store: store)
        let result = backup.run(trigger: "command line", dryRun: dryRun, isCancelled: { cancel.isCancelled }, progress: { p in
            if verbose { FileHandle.standardError.write(Data("[\(p.index + 1)/\(p.total)] \(p.repo): \(p.step.rawValue)\n".utf8)) }
        })
        _ = lock
        if !dryRun {
            _ = try? store.saveRun(result.record)
            if result.record.outcome == .success || result.record.outcome == .warning {
                store.setDate(result.record.started, for: StoreKey.lastSuccess(StoreKey.githubJob))
            }
        }
        printRun(result.record)
        if gh.newRepos == .prompt, !result.newRepos.isEmpty {
            print("\(Format.count(result.newRepos.count, "new repo")) waiting for you to decide in the menu (or add them to repos or exclude): \(result.newRepos.joined(separator: ", "))")
        }
    default:
        usage()
        exit(1)
    }

default:
    usage()
    exit(args.isEmpty ? 0 : 1)
}
