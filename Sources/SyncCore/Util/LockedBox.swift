import Foundation

/// A value shared between threads.
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

    /// Changes the value in place and returns the new value.
    @discardableResult func update(_ body: (inout T) -> Void) -> T {
        lock.lock()
        defer { lock.unlock() }
        body(&value)
        return value
    }

    /// Changes the value in place and returns what `body` returns.
    @discardableResult func update<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
