import CoreServices
import Foundation

/// Watches a source folder with FSEvents and reports which folders changed.
/// Events are collected until the folder has been quiet for the configured period.
public final class FolderWatcher: @unchecked Sendable {
    public struct Changes: Sendable, Equatable {
        public var scope: FolderSync.Scope
        /// Highest event ID included, to save once the sync succeeds.
        public var eventID: UInt64
    }

    public let source: URL
    public let quietPeriod: TimeInterval
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?
    private var pending: [String: Bool] = [:]
    private var needsFullScan = false
    private var lastEventID: UInt64 = 0
    private var eventCount = 0
    private var flushWork: DispatchWorkItem?
    private let lock = NSLock()
    private let onChanges: @Sendable (Changes) -> Void

    /// Calls `onChanges` on a background queue once the folder has been quiet.
    public init(source: URL, quietPeriod: TimeInterval, onChanges: @escaping @Sendable (Changes) -> Void) {
        // realpath keeps /private, which FSEvents reports and Foundation's resolver drops.
        if let real = realpath(source.path(percentEncoded: false), nil) {
            self.source = URL(filePath: String(cString: real), directoryHint: .isDirectory)
            free(real)
        } else {
            self.source = source
        }
        self.quietPeriod = quietPeriod
        self.onChanges = onChanges
        queue = DispatchQueue(label: "nassync.watcher", qos: .utility)
    }

    deinit { stop() }

    /// Number of change events waiting for the quiet period to end.
    public var waitingEvents: Int {
        lock.lock()
        defer { lock.unlock() }
        return eventCount
    }

    /// Device UUID for the source volume. A different value means saved event IDs are no longer valid.
    public static func eventSourceID(for url: URL) -> String? {
        var st = stat()
        guard stat(url.path(percentEncoded: false), &st) == 0,
              let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    public static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }

    /// Starts watching. With `since`, replays changes made while the app wasn't running.
    public func start(since: UInt64?) {
        stop()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents)
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, ids in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handle(paths: list, flags: Array(UnsafeBufferPointer(start: eventFlags, count: count)), ids: Array(UnsafeBufferPointer(start: ids, count: count)))
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, [source.path(percentEncoded: false)] as CFArray,
                                          since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, FSEventStreamCreateFlags(flags)) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        lock.lock()
        flushWork?.cancel()
        flushWork = nil
        lock.unlock()
    }

    func handle(paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId]) {
        let root = source.path(percentEncoded: false).hasSuffix("/") ? source.path(percentEncoded: false) : source.path(percentEncoded: false) + "/"
        lock.lock()
        for (i, path) in paths.enumerated() {
            let f = Int(flags[i])
            lastEventID = max(lastEventID, ids[i])
            if f & kFSEventStreamEventFlagHistoryDone != 0 { continue }
            eventCount += 1
            let rescan = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
            if f & rescan != 0 { needsFullScan = true; continue }
            guard let rel = Self.relative(path, root: root) else { continue }
            // File events: compare the containing folder. Folder events: compare the folder and below.
            let isDir = f & kFSEventStreamEventFlagItemIsDir != 0
            let isFile = f & kFSEventStreamEventFlagItemIsFile != 0
            if isDir {
                pending[rel] = true
                let parent = (rel as NSString).deletingLastPathComponent
                if pending[parent] == nil { pending[parent] = false }
            } else if isFile || f & kFSEventStreamEventFlagItemIsSymlink != 0 {
                let parent = (rel as NSString).deletingLastPathComponent
                if pending[parent] == nil { pending[parent] = false }
            } else {
                pending[rel] = true
            }
        }
        scheduleFlush()
        lock.unlock()
    }

    static func relative(_ path: String, root: String) -> String? {
        let p = path.hasSuffix("/") ? path : path + "/"
        guard p.hasPrefix(root) else { return p == root ? "" : nil }
        var rel = String(p.dropFirst(root.count))
        if rel.hasSuffix("/") { rel.removeLast() }
        return rel
    }

    /// Must be called with the lock held.
    private func scheduleFlush() {
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        flushWork = work
        queue.asyncAfter(deadline: .now() + quietPeriod, execute: work)
    }

    /// Hands over collected changes now, without waiting for the quiet period.
    public func flush() {
        lock.lock()
        guard needsFullScan || !pending.isEmpty else {
            lock.unlock()
            return
        }
        let changes = Changes(scope: needsFullScan ? .full : .directories(pending), eventID: lastEventID)
        pending = [:]
        needsFullScan = false
        eventCount = 0
        flushWork?.cancel()
        flushWork = nil
        lock.unlock()
        onChanges(changes)
    }
}
