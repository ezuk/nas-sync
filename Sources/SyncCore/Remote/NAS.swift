import CryptoKit
import Foundation

/// File operations on the NAS: over SSH, or on a local folder when no SSH login is configured.
/// Paths are relative to `config.path`.
public final class NAS: Sendable {
    public struct Entry: Sendable, Equatable {
        public var path: String
        public var isDirectory: Bool
        public var size: Int64
        public var modified: Date
    }

    public enum ConnectProblem: Error, Sendable, Equatable, CustomStringConvertible {
        case unreachable(String)
        case signIn(String)
        case hostKey(String)
        case pathMissing(String)
        case rsyncMissing(String)

        public var description: String {
            switch self {
            case .unreachable(let host): "The NAS (\(host)) didn't answer over SSH."
            case .signIn(let login): "The NAS refused the SSH login for \(login). Set up key login with ssh-copy-id."
            case .hostKey(let host): "SSH doesn't know the NAS's host key yet. Connect once in Terminal with ssh \(host) and accept it."
            case .pathMissing(let path): "The folder \(path) doesn't exist on the NAS."
            case .rsyncMissing(let detail): detail
            }
        }
    }

    public let config: NASConfig
    public let rsync: URL?
    static let ssh = URL(filePath: "/usr/bin/ssh")

    public init(config: NASConfig) {
        self.config = config
        rsync = Rsync.find(override: config.rsync)
    }

    public var isRemote: Bool { config.ssh != nil }

    /// Absolute path on the NAS.
    public func absolute(_ rel: String) -> String {
        let base = config.path.hasSuffix("/") ? String(config.path.dropLast()) : config.path
        return rel.isEmpty ? base : base + "/" + rel
    }

    // MARK: SSH

    /// Options shared by every SSH connection. One connection is reused for a couple of minutes.
    var sshOptions: [String] {
        let socketDir = "/tmp/nas-sync-\(getuid())"
        try? FileManager.default.createDirectory(atPath: socketDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return ["-p", String(config.port),
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4",
                "-o", "LogLevel=ERROR",
                "-o", "ControlMaster=auto", "-o", "ControlPath=\(socketDir)/cm-%C", "-o", "ControlPersist=120"]
    }

    /// The `-e` value for rsync.
    var rsyncShell: String { (["ssh"] + sshOptions).joined(separator: " ") }

    /// Where rsync should write `rel`: `user@host:/abs/path` or a local path.
    public func rsyncTarget(_ rel: String) -> String {
        let path = absolute(rel)
        return config.ssh.map { "\($0):\(path)" } ?? path
    }

    /// Arguments that make rsync talk to the NAS.
    public var rsyncTransportArgs: [String] {
        guard isRemote else { return [] }
        return ["-e", rsyncShell, "--rsync-path=\(config.remoteRsync)", "--iconv=utf-8-mac,utf-8"]
    }

    /// Runs a shell script on the NAS and returns stdout.
    @discardableResult
    public func shell(_ script: String, timeout: TimeInterval = 120, isCancelled: @Sendable () -> Bool = { false }) throws -> String {
        let r = try shellRaw(script, timeout: timeout, isCancelled: isCancelled)
        guard r.status == 0 else { throw CommandError(tool: "ssh", status: r.status, output: r.stderr.isEmpty ? r.stdout : r.stderr) }
        return r.stdout
    }

    func shellRaw(_ script: String, timeout: TimeInterval = 120, isCancelled: @Sendable () -> Bool = { false }) throws -> Command.Result {
        if let login = config.ssh {
            return try Command.run(Self.ssh, sshOptions + [login, script], timeout: timeout, isCancelled: isCancelled)
        }
        return try Command.run(URL(filePath: "/bin/sh"), ["-c", script], timeout: timeout, isCancelled: isCancelled)
    }

    /// Single-quotes a value for the remote shell.
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Checks

    /// Checks that the NAS answers, the login works and the base folder exists.
    public func check(timeout: TimeInterval = 20) -> Result<Void, ConnectProblem> {
        guard rsync != nil else { return .failure(.rsyncMissing(Rsync.missingMessage)) }
        guard isRemote else {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: config.path, isDirectory: &isDir) && isDir.boolValue
                ? .success(()) : .failure(.pathMissing(config.path))
        }
        let login = config.ssh ?? ""
        guard let r = try? shellRaw("test -d \(Self.quote(config.path)) && echo ok", timeout: timeout) else {
            return .failure(.unreachable(config.host))
        }
        if r.status == 0, r.stdout.contains("ok") { return .success(()) }
        let err = r.stderr.lowercased()
        if err.contains("permission denied") { return .failure(.signIn(login)) }
        if err.contains("host key verification failed") { return .failure(.hostKey(login)) }
        if r.status == 255 { return .failure(.unreachable(config.host)) }
        return .failure(.pathMissing(config.path))
    }

    // MARK: Files

    /// Everything under `rel` (files and folders), with paths relative to `rel`. Nil if `rel` doesn't exist.
    public func listTree(_ rel: String, maxDepth: Int? = nil, isCancelled: @Sendable () -> Bool = { false }) throws -> [Entry]? {
        let dir = absolute(rel)
        guard isRemote else { return localTree(dir, maxDepth: maxDepth) }
        let depth = maxDepth.map { " -maxdepth \($0)" } ?? ""
        let r = try shellRaw("cd \(Self.quote(dir)) 2>/dev/null || exit 3; find . -mindepth 1\(depth) -printf '%y\\t%s\\t%T@\\t%P\\n'",
                             timeout: 600, isCancelled: isCancelled)
        if r.status == 3 { return nil }
        guard r.status == 0 else { throw CommandError(tool: "find", status: r.status, output: r.stderr) }
        return r.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            return Entry(path: String(parts[3]), isDirectory: parts[0] == "d", size: Int64(parts[1]) ?? 0,
                         modified: Date(timeIntervalSince1970: Double(parts[2]) ?? 0))
        }
    }

    private func localTree(_ dir: String, maxDepth: Int?) -> [Entry]? {
        let root = URL(filePath: dir, directoryHint: .isDirectory)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return nil }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var out: [Entry] = []
        let prefix = root.standardizedFileURL.path(percentEncoded: false)
        for case let url as URL in e {
            let path = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let maxDepth, path.split(separator: "/").count >= maxDepth { e.skipDescendants() }
            let v = try? url.resourceValues(forKeys: Set(keys))
            out.append(Entry(path: path, isDirectory: v?.isDirectory == true, size: Int64(v?.fileSize ?? 0),
                             modified: v?.contentModificationDate ?? .distantPast))
        }
        return out
    }

    public func makeDirectory(_ rel: String) throws {
        guard isRemote else {
            try FileManager.default.createDirectory(atPath: absolute(rel), withIntermediateDirectories: true)
            return
        }
        try shell("mkdir -p \(Self.quote(absolute(rel)))")
    }

    /// Removes files or folders.
    public func remove(_ rels: [String]) throws {
        guard !rels.isEmpty else { return }
        guard isRemote else {
            for rel in rels { try? FileManager.default.removeItem(atPath: absolute(rel)) }
            return
        }
        try shell("rm -rf -- " + rels.map { Self.quote(absolute($0)) }.joined(separator: " "))
    }

    public func sha256(_ rel: String) throws -> String {
        guard isRemote else { return try XZ.sha256(of: URL(filePath: absolute(rel))) }
        let out = try shell("sha256sum \(Self.quote(absolute(rel)))", timeout: 1800)
        return String(out.prefix(while: { !$0.isWhitespace }))
    }

    /// Copies a local file to `rel` (written under a temporary name, then renamed), then checks size and checksum.
    /// Returns the size.
    @discardableResult
    public func upload(_ file: URL, to rel: String, isCancelled: @Sendable () -> Bool = { false }) throws -> Int64 {
        guard let rsync else { throw CommandError(tool: "rsync", status: -1, output: Rsync.missingMessage) }
        let parent = (rel as NSString).deletingLastPathComponent
        if !parent.isEmpty { try makeDirectory(parent) }
        let r = try Command.run(rsync, ["-t"] + rsyncTransportArgs.filter { !$0.hasPrefix("--iconv") }
                                + [file.path(percentEncoded: false), rsyncTarget(rel)], isCancelled: isCancelled)
        guard r.status == 0 else { throw CommandError(tool: "rsync", status: r.status, output: r.stderr) }
        let local = try XZ.sha256(of: file)
        guard try sha256(rel) == local else {
            try? remove([rel])
            throw CommandError(tool: "rsync", status: -1, output: "The copy on the NAS didn't match, so it was removed.")
        }
        return Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    /// Writes data to `rel`.
    public func write(_ data: Data, to rel: String) throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "nas-sync-\(UUID().uuidString)-" + (rel as NSString).lastPathComponent)
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        try upload(temp, to: rel)
    }
}

/// Finds an rsync 3.x on this Mac. The one built into macOS (openrsync) lacks options this app needs.
public enum Rsync {
    public static let candidates = ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync"]
    public static let missingMessage = "NAS Sync needs rsync 3 on this Mac. Install it with: brew install rsync"

    nonisolated(unsafe) private static var cache: [String: URL?] = [:]
    private static let lock = NSLock()

    public static func find(override: String? = nil) -> URL? {
        let key = override ?? ""
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let paths = (override.map { [($0 as NSString).expandingTildeInPath] } ?? []) + candidates
        let found = paths.lazy.map { URL(filePath: $0) }.first { url in
            guard FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)),
                  let r = try? Command.run(url, ["--version"], timeout: 10) else { return false }
            return r.stdout.contains("rsync  version 3.")
        }
        lock.lock()
        cache[key] = found
        lock.unlock()
        return found
    }
}
