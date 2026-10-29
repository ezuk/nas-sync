import Foundation
import NetFS
import Network
import Security

/// Finds, mounts and checks the NAS share.
public enum NASMount {
    public struct Mounted: Sendable, Equatable {
        public var mountPoint: URL
        public var from: String
    }

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case notFound(String)
        case mountFailed(code: Int32, reason: String)

        public var description: String {
            switch self {
            case .notFound(let s): s
            case .mountFailed(_, let reason): reason
            }
        }
    }

    /// One line of the "can't reach the NAS" checklist.
    public struct Step: Sendable, Equatable, Codable {
        public enum State: String, Sendable, Codable { case ok, failed, skipped }
        public var title: String
        public var state: State
        public var detail: String?

        public init(title: String, state: State, detail: String?) {
        self.title = title
        self.state = state
        self.detail = detail
    }
    }

    // MARK: Finding mounts

    static func normalizedHost(_ host: String) -> String {
        let h = host.lowercased()
        return String(h.split(separator: ".").first ?? Substring(h))
    }

    static func matches(from: String, config: NASConfig) -> Bool {
        // //user@host/share or //host/share
        var s = from.removingPercentEncoding ?? from
        while s.hasPrefix("/") { s.removeFirst() }
        if let at = s.firstIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        let parts = s.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        return normalizedHost(parts[0]) == normalizedHost(config.host)
            && parts[1].lowercased() == config.share.lowercased()
    }

    /// The current mount point of the share, whoever mounted it.
    public static func find(_ config: NASConfig) -> Mounted? {
        var buf: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buf, MNT_NOWAIT)
        guard count > 0, let buf else { return nil }
        for i in 0..<Int(count) {
            var fs = buf[i]
            let type = withUnsafeBytes(of: &fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard type == "smbfs" else { continue }
            let from = withUnsafeBytes(of: &fs.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let on = withUnsafeBytes(of: &fs.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if matches(from: from, config: config) {
                return Mounted(mountPoint: URL(filePath: on, directoryHint: .isDirectory), from: from)
            }
        }
        return nil
    }

    /// True when `path` lives on the expected SMB share, not a leftover folder under /Volumes.
    public static func isOnShare(_ path: URL, config: NASConfig) -> Bool {
        var fs = statfs()
        guard statfs(path.path(percentEncoded: false), &fs) == 0 else { return false }
        let type = withUnsafeBytes(of: &fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let from = withUnsafeBytes(of: &fs.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return type == "smbfs" && matches(from: from, config: config)
    }

    // MARK: Mounting

    /// Mounts the share using saved Keychain credentials. Never shows a password dialog.
    public static func mount(_ config: NASConfig) -> Result<Mounted, Failure> {
        if let m = find(config) { return .success(m) }
        var status = netfsMount(config.url, user: nil, password: nil)
        if isAuthError(status), let cred = keychainCredential(for: config) {
            status = netfsMount(config.url, user: cred.user, password: cred.password)
        }
        if status == 0, let m = find(config) { return .success(m) }
        if status == 0 { return .failure(.mountFailed(code: 0, reason: "The share mounted but couldn't be found afterwards.")) }
        return .failure(.mountFailed(code: status, reason: reason(for: status)))
    }

    private static func netfsMount(_ url: URL, user: String?, password: String?) -> Int32 {
        let open = NSMutableDictionary()
        open[kNAUIOptionKey] = kNAUIOptionNoUI
        let mountOptions = NSMutableDictionary()
        var points: Unmanaged<CFArray>?
        return NetFSMountURLSync(url as CFURL, nil, user as CFString?, password as CFString?, open as CFMutableDictionary, mountOptions as CFMutableDictionary, &points)
    }

    static func isAuthError(_ status: Int32) -> Bool {
        [EAUTH, EACCES, EPERM, -128, -6600, -5045, -5046].contains(status)
    }

    static func reason(for status: Int32) -> String {
        switch status {
        case EAUTH, EACCES, EPERM, -5045, -5046, -128:
            "The NAS rejected the user name or password. Connect once in Finder and tick \"Remember this password in my keychain\"."
        case ENOENT, -6003, -5998:
            "The NAS doesn't have a share with that name. Check nas.url in the config."
        case ETIMEDOUT, EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, ECONNREFUSED:
            "The NAS didn't answer. Is it switched on and on this network?"
        case -5999:
            "The NAS account is restricted or disabled."
        default:
            status > 0 ? "Mount failed: \(String(cString: strerror(status)))." : "Mount failed (error \(status))."
        }
    }

    static func keychainCredential(for config: NASConfig) -> (user: String, password: String)? {
        let hosts = [config.host, normalizedHost(config.host) + ".local", normalizedHost(config.host)]
        for host in hosts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrServer as String: host,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: true,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let dict = item as? [String: Any],
                  let user = dict[kSecAttrAccount as String] as? String,
                  let data = dict[kSecValueData as String] as? Data,
                  let password = String(data: data, encoding: .utf8) else { continue }
            return (user, password)
        }
        return nil
    }

    /// Unmounts a share the app mounted itself.
    public static func unmount(_ mounted: Mounted) -> Bool {
        Darwin.unmount(mounted.mountPoint.path(percentEncoded: false), 0) == 0
    }

    // MARK: Diagnosis

    /// Whether the NAS answers on the SMB port. Handles Bonjour names like `nas._smb._tcp.local`.
    public static func reachable(_ config: NASConfig, timeout: TimeInterval = 5) -> Bool {
        let host = config.host
        let endpoint: NWEndpoint
        if let r = host.range(of: "._smb._tcp", options: .caseInsensitive) {
            let domain = host[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "."))
            endpoint = .service(name: String(host[..<r.lowerBound]), type: "_smb._tcp", domain: domain.isEmpty ? "local." : domain + ".", interface: nil)
        } else {
            endpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(config.url.port ?? 445)))
        }
        let connection = NWConnection(to: endpoint, using: .tcp)
        let done = DispatchSemaphore(value: 0)
        let result = LockedBox(false)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                result.set(true)
                done.signal()
            case .failed, .cancelled:
                done.signal()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
        _ = done.wait(timeout: .now() + timeout)
        connection.cancel()
        return result.get()
    }

    /// Runs the checklist shown when the NAS can't be reached.
    public static func diagnose(_ config: NASConfig, wifiName: String?, homeWiFi: String) -> [Step] {
        var steps: [Step] = []
        let onHome = wifiName == homeWiFi
        steps.append(Step(title: "On the home Wi-Fi", state: onHome ? .ok : .failed,
                          detail: onHome ? homeWiFi : (wifiName.map { "Connected to \($0)" } ?? "Wi-Fi name unknown")))
        guard onHome else { return steps }
        let found = reachable(config)
        steps.append(Step(title: "NAS found on the network", state: found ? .ok : .failed,
                          detail: found ? config.host : "\(config.host) didn't answer"))
        guard found else {
            steps.append(Step(title: "Share mounted", state: .skipped, detail: nil))
            return steps
        }
        switch mount(config) {
        case .success(let m):
            steps.append(Step(title: "Share mounted", state: .ok, detail: m.mountPoint.path(percentEncoded: false)))
        case .failure(let f):
            steps.append(Step(title: "Share mounted", state: .failed, detail: f.description))
        }
        return steps
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    init(_ value: T) { self.value = value }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ v: T) {
        lock.lock()
        value = v
        lock.unlock()
    }
}
