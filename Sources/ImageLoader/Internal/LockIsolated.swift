import os

final class LockIsolated<Value>: @unchecked Sendable {
    private var storage: Value
    private let lock: os_unfair_lock_t
    #if DEBUG
        private let nesting: UnsafeMutablePointer<Int>
    #endif

    init(_ value: Value) {
        storage = value
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        #if DEBUG
            nesting = .allocate(capacity: 1)
            nesting.initialize(to: 0)
        #endif
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
        #if DEBUG
            nesting.deinitialize(count: 1)
            nesting.deallocate()
        #endif
    }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        #if DEBUG
            let outer = LockOrder.willAcquireLeaf(nesting)
            os_unfair_lock_lock(lock)
            if outer != nil {
                nesting.pointee += 1
            }
            defer {
                os_unfair_lock_unlock(lock)
                LockOrder.didReleaseLeaf(restoring: outer)
            }
        #else
            os_unfair_lock_lock(lock)
            defer {
                os_unfair_lock_unlock(lock)
            }
        #endif
        return try body(&storage)
    }

    var value: Value {
        withLock { $0 }
    }

    var nestedAcquisitionCount: Int {
        #if DEBUG
            withLock { _ in nesting.pointee }
        #else
            0
        #endif
    }
}

extension LockIsolated where Value: Equatable {
    @discardableResult
    func testAndSet(_ newValue: Value) -> Bool {
        withLock { value in
            guard value != newValue else { return false }
            value = newValue
            return true
        }
    }
}
