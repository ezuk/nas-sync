import Foundation

/// Finds a folder on the NAS through its file share on this Mac.
public struct NASShare: Sendable {
    /// A mounted network volume.
    public struct Mount: Sendable, Equatable {
        public var path: String
        /// The volume's address, such as `smb://me@nas._smb._tcp.local/home`.
        public var address: URL?

        public init(path: String, address: URL?) {
            self.path = path
            self.address = address
        }
    }

    public let config: NASConfig

    public init(config: NASConfig) {
        self.config = config
    }

    /// Network volumes mounted on this Mac.
    public static func mounted() -> [Mount] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeURLForRemountingKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsLocal == false else { return nil }
            return Mount(path: url.path(percentEncoded: false), address: values.volumeURLForRemounting)
        }
    }

    /// Where a folder under the NAS base folder is on this Mac. A share usually starts partway down the
    /// base folder, so this tries the longest path first.
    public func localPath(of relative: String, mounts: [Mount], exists: (String) -> Bool) -> String? {
        guard config.ssh != nil else {
            let base = config.path.hasSuffix("/") ? String(config.path.dropLast()) : config.path
            let path = "\(base)/\(relative)"
            return exists(path) ? path : nil
        }
        let base = config.path.split(separator: "/").map(String.init)
        for mount in mounts where Self.host(of: mount.address) == host {
            let root = mount.path.hasSuffix("/") ? String(mount.path.dropLast()) : mount.path
            for start in 0...base.count {
                let path = ([root] + base[start...] + [relative]).joined(separator: "/")
                if exists(path) { return path }
            }
        }
        return nil
    }

    /// The share to connect to when it isn't mounted. On a Synology, `/volume1/homes/me` is the `home` share
    /// for `me`, and `/volume1/name` is the share called `name`.
    public var shareURL: URL? {
        guard let login = config.ssh else { return nil }
        let parts = config.path.split(separator: "/").map(String.init)
        let user = login.contains("@") ? login.split(separator: "@").first.map(String.init) : nil
        var share: String?
        if parts.count >= 2, parts[0].hasPrefix("volume") {
            share = parts[1] == "homes" && parts.count >= 3 && parts[2] == user ? "home" : parts[1]
        }
        var c = URLComponents()
        c.scheme = "smb"
        c.user = user
        c.host = login.split(separator: "@").last.map(String.init)
        c.path = share.map { "/\($0)" } ?? ""
        return c.url
    }

    private var host: String? {
        config.ssh.flatMap { $0.split(separator: "@").last }.map { Self.simplified(String($0)) }
    }

    private static func host(of address: URL?) -> String? {
        address?.host(percentEncoded: false).map(simplified)
    }

    /// `nas._smb._tcp.local` and `nas.local` are the same machine.
    private static func simplified(_ host: String) -> String {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        for suffix in [".local", "._smb._tcp", "._afpovertcp._tcp"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return name
    }
}
