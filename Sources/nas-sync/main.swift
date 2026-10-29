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
let verbose = flag("--verbose") || flag("-v")

func usage() {
    print("""
    usage: nas-sync [--config <file>] <command>

      validate [file]              check the config file
      status [--json]              show what the app is doing (reads the app's status file)
      mount                        mount the NAS share if needed
      diagnose                     run the NAS checklist step by step
      run folders [name] [--dry-run] [-v]
                                   compare and copy folder jobs now
      run github [--dry-run] [-v]  back up GitHub repos now
      unpack <archive.bundle.xz> [out]
                                   decompress a GitHub archive to a .bundle you can git clone
      count <folder> [--workers N] list a folder tree and time it (N=1 lists one folder at a time)
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

func mountedRoot(_ config: AppConfig) -> URL {
    switch NASMount.mount(config.nas) {
    case .success(let m):
        guard NASMount.isOnShare(m.mountPoint, config: config.nas) else { fail("\(m.mountPoint.path) isn't on the expected share.") }
        return m.mountPoint
    case .failure(let f):
        fail("Can't mount the NAS: \(f)")
    }
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
        print("Config OK. \(Format.count(c.folders.count, "folder")), NAS \(c.nas.url.absoluteString), home Wi-Fi “\(c.home.wifi)”\(c.github == nil ? "" : ", GitHub backups on").")
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

case "mount":
    let config = loadConfig()
    switch NASMount.mount(config.nas) {
    case .success(let m): print("Mounted at \(m.mountPoint.path(percentEncoded: false))")
    case .failure(let f): fail(f.description)
    }

case "diagnose":
    let config = loadConfig()
    let wifi = WiFi.currentName()
    for step in NASMount.diagnose(config.nas, wifiName: wifi ?? config.home.wifi, homeWiFi: config.home.wifi) {
        let mark = step.state == .ok ? "✓" : step.state == .failed ? "✕" : "–"
        print("\(mark) \(step.title)\(step.detail.map { ": \($0)" } ?? "")")
    }
    if wifi == nil { print("(Wi-Fi name isn't visible to command-line tools, so the Wi-Fi step was assumed.)") }

case "unpack":
    guard args.count > 1 else { fail("usage: nas-sync unpack <archive.bundle.xz> [out]") }
    let input = URL(filePath: (args[1] as NSString).expandingTildeInPath)
    let name = input.lastPathComponent.hasSuffix(".xz") ? String(input.lastPathComponent.dropLast(3)) : input.lastPathComponent + ".out"
    let output = args.count > 2 ? URL(filePath: (args[2] as NSString).expandingTildeInPath) : URL(filePath: FileManager.default.currentDirectoryPath).appending(path: name)
    do { try XZ.decompress(input, to: output) } catch { fail("Couldn't unpack: \(error.localizedDescription)") }
    print("Wrote \(output.path(percentEncoded: false)). Restore with: git clone \"\(output.lastPathComponent)\" <folder>")

case "count":
    let workers = option("--workers").flatMap(Int.init) ?? 8
    guard args.count > 1 else { fail("usage: nas-sync count <folder> [--workers N]") }
    let lister = FileLister(root: URL(filePath: (args[1] as NSString).expandingTildeInPath), exclude: GlobSet([]))
    let start = Date()
    var files = 0, folders = 0
    var bytes: Int64 = 0
    if workers <= 1 {
        for e in try lister.listRecursive("") {
            if e.kind == .file { files += 1; bytes += e.size } else if e.kind == .directory { folders += 1 }
        }
    } else {
        let cache = try lister.prefetch(workers: workers)
        folders = cache.folderCount - 1
        files = cache.allEntries.filter { $0.kind == .file }.count
        bytes = cache.allEntries.reduce(0) { $0 + ($1.kind == .file ? $1.size : 0) }
    }
    print("\(files.formatted()) files, \(folders.formatted()) folders, \(Format.bytes(bytes)) in \(Format.duration(Date().timeIntervalSince(start))) with \(max(1, workers)) worker\(workers > 1 ? "s" : "")")

case "run":
    args.removeFirst()
    let what = args.first
    let config = loadConfig()
    let store = openStore()
    let root = mountedRoot(config)
    let cancel = CancelFlag()
    signal(SIGINT) { _ in exit(130) }
    switch what {
    case "folders":
        let name = args.count > 1 ? args[1] : nil
        let jobs = config.folders.filter { name == nil || $0.name == name }
        if jobs.isEmpty { fail("No folder job named \(name ?? "").") }
        for job in jobs {
            guard let lock = JobLock(job: job.name, directory: store.directory) else { fail("\(job.name) is already running in the app.") }
            let r = FolderRunner.run(job: job, nasRoot: root, store: store,
                                     options: .init(trigger: "command line", scope: .full, dryRun: dryRun), isCancelled: { cancel.isCancelled })
            _ = lock
            printRun(r)
        }
    case "github":
        guard let gh = config.github else { fail("There's no [github] section in the config.") }
        guard let lock = JobLock(job: StoreKey.githubJob, directory: store.directory) else { fail("GitHub backups are already running in the app.") }
        let backup = GitHubBackup(config: gh, destination: root.appending(path: gh.dest), store: store)
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
    default:
        usage()
        exit(1)
    }

default:
    usage()
    exit(args.isEmpty ? 0 : 1)
}
