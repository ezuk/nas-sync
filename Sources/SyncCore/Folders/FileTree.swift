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

    public init(root: URL, exclude: GlobSet, reservedRootNames: Set<String> = []) {
        self.root = root
        self.exclude = exclude
        self.reservedRootNames = reservedRootNames
    }

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
    ]

    /// Lists the direct children of `relativeDir` ("" for the root). Returns nil if the folder doesn't exist.
    public func list(_ relativeDir: String) throws -> [FileEntry]? {
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
}
