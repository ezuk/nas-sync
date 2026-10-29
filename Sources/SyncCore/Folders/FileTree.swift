import Foundation

/// One file or folder found while listing a tree.
public struct FileEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case file, directory, symlink, other }

    public var relativePath: String
    public var kind: Kind
    public var size: Int64
    public var modified: TimeInterval

    public var name: String { (relativePath as NSString).lastPathComponent }
}

/// Lists directories while skipping excluded paths.
public struct FileLister: Sendable {
    public var root: URL
    public var exclude: GlobSet
    /// Names skipped at the root only, such as the archive folder.
    public var reservedRootNames: Set<String>
    /// Listings fetched ahead of time. Folders not in it are listed on demand.
    public var cache: ListingCache?

    public init(root: URL, exclude: GlobSet, reservedRootNames: Set<String> = [], cache: ListingCache? = nil) {
        self.root = root
        self.exclude = exclude
        self.reservedRootNames = reservedRootNames
        self.cache = cache
    }

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
    ]

    /// Lists the direct children of `relativeDir` ("" for the root). Returns nil if the folder doesn't exist.
    public func list(_ relativeDir: String) throws -> [FileEntry]? {
        if let cache, let hit = cache.get(relativeDir) { return hit }
        return try listUncached(relativeDir)
    }

    func listUncached(_ relativeDir: String) throws -> [FileEntry]? {
        let dir = relativeDir.isEmpty ? root : root.appending(path: relativeDir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path(percentEncoded: false), isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Self.keys, options: [])
        var result: [FileEntry] = []
        result.reserveCapacity(urls.count)
        for url in urls {
            let name = url.lastPathComponent
            if relativeDir.isEmpty, reservedRootNames.contains(name) { continue }
            if name.hasPrefix(FolderSync.tempPrefix) { continue }
            let rel = relativeDir.isEmpty ? name : relativeDir + "/" + name
            let values = try? url.resourceValues(forKeys: Set(Self.keys))
            let kind: FileEntry.Kind
            if values?.isSymbolicLink == true {
                kind = .symlink
            } else if values?.isDirectory == true {
                kind = .directory
            } else if values?.isRegularFile == true {
                kind = .file
            } else {
                kind = .other
            }
            if exclude.matches(rel, isDirectory: kind == .directory) { continue }
            result.append(FileEntry(
                relativePath: rel,
                kind: kind,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            ))
        }
        return result
    }

    /// Lists every file and folder under `relativeDir`, depth first.
    public func listRecursive(_ relativeDir: String, isCancelled: () -> Bool = { false }) throws -> [FileEntry] {
        var result: [FileEntry] = []
        var stack = [relativeDir]
        while let dir = stack.popLast() {
            if isCancelled() { throw CancellationError() }
            guard let children = try list(dir) else { continue }
            for child in children {
                result.append(child)
                if child.kind == .directory { stack.append(child.relativePath) }
            }
        }
        return result
    }

    /// Lists the whole tree with several folders in flight at once, which is much faster over SMB.
    public func prefetch(workers: Int = 8, isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> ListingCache {
        let cache = ListingCache()
        let state = CrawlState()
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while let dir = state.next() {
                var found: [String] = []
                var error: Error?
                do {
                    if isCancelled() { throw CancellationError() }
                    let entries = try listUncached(dir)
                    cache.set(dir, entries)
                    found = entries?.filter { $0.kind == .directory }.map(\.relativePath) ?? []
                } catch let e {
                    error = e
                }
                state.finish(found: found, error: error)
            }
        }
        if let failure = state.failure { throw failure }
        return cache
    }
}

/// Work queue for `prefetch`: folders waiting to be listed and how many are in flight.
final class CrawlState: @unchecked Sendable {
    private let cond = NSCondition()
    private var queue = [""]
    private var active = 0
    private(set) var failure: Error?

    /// The next folder to list, or nil when everything is done.
    func next() -> String? {
        cond.lock()
        defer { cond.unlock() }
        while queue.isEmpty, active > 0, failure == nil { cond.wait() }
        guard failure == nil, let dir = queue.popLast() else {
            cond.broadcast()
            return nil
        }
        active += 1
        return dir
    }

    func finish(found: [String], error: Error?) {
        cond.lock()
        queue.append(contentsOf: found)
        active -= 1
        if let error, failure == nil { failure = error }
        cond.broadcast()
        cond.unlock()
    }
}

/// Folder listings shared between threads. A stored nil means the folder doesn't exist.
public final class ListingCache: @unchecked Sendable {
    private var entries: [String: [FileEntry]?] = [:]
    private let lock = NSLock()

    public init() {}

    public func get(_ dir: String) -> [FileEntry]?? {
        lock.lock()
        defer { lock.unlock() }
        return entries[dir]
    }

    func set(_ dir: String, _ list: [FileEntry]?) {
        lock.lock()
        entries[dir] = .some(list)
        lock.unlock()
    }

    public var folderCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
