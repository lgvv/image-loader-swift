import Foundation

enum LockOrder {
    #if DEBUG
        static let isChecking = true

        private static let leafDepthKey = makeKey()
        private static let nestedLeafKey = makeKey()
        private static let decodeDepthKey = makeKey()
        private static let heldLeafKey = makeKey()

        private static func makeKey() -> pthread_key_t {
            var key = pthread_key_t()
            pthread_key_create(&key, nil)
            return key
        }

        private static func read(_ key: pthread_key_t) -> Int {
            Int(bitPattern: pthread_getspecific(key))
        }

        private static func write(_ value: Int, to key: pthread_key_t) {
            pthread_setspecific(key, UnsafeRawPointer(bitPattern: value))
        }
    #else
        static let isChecking = false
    #endif

    #if DEBUG
        static func willAcquireLeaf(_ nesting: UnsafeMutablePointer<Int>) -> UnsafeMutablePointer<Int>? {
            assert(read(decodeDepthKey) == 0, "ImageLoader: leaf lock acquired while holding a per-source decode lock")
            let depth = read(leafDepthKey)
            if depth > 0 {
                write(read(nestedLeafKey) + 1, to: nestedLeafKey)
            }
            write(depth + 1, to: leafDepthKey)
            let outer = pthread_getspecific(heldLeafKey).map { $0.assumingMemoryBound(to: Int.self) }
            outer?.pointee += 1
            pthread_setspecific(heldLeafKey, UnsafeRawPointer(nesting))
            return outer
        }

        static func didReleaseLeaf(restoring outer: UnsafeMutablePointer<Int>?) {
            pthread_setspecific(heldLeafKey, outer.map { UnsafeRawPointer($0) })
            write(read(leafDepthKey) - 1, to: leafDepthKey)
        }
    #endif

    @inline(__always)
    static func willAcquireDecodeLock(allowsMainThread: Bool = false) {
        #if DEBUG
            assert(allowsMainThread || !Thread.isMainThread, "ImageLoader: per-source decode lock acquired on the main thread")
            assert(read(leafDepthKey) == 0, "ImageLoader: per-source decode lock acquired while holding a leaf lock")
            assert(read(decodeDepthKey) == 0, "ImageLoader: per-source decode locks nested")
            write(read(decodeDepthKey) + 1, to: decodeDepthKey)
        #endif
    }

    @inline(__always)
    static func didReleaseDecodeLock() {
        #if DEBUG
            write(read(decodeDepthKey) - 1, to: decodeDepthKey)
        #endif
    }

    static var leafDepth: Int {
        #if DEBUG
            read(leafDepthKey)
        #else
            0
        #endif
    }

    static var nestedLeafAcquisitions: Int {
        #if DEBUG
            read(nestedLeafKey)
        #else
            0
        #endif
    }

    static var decodeLockDepth: Int {
        #if DEBUG
            read(decodeDepthKey)
        #else
            0
        #endif
    }
}

final class AnimatedFrameDecodeLock: Sendable {
    private let lock = NSLock()

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        LockOrder.willAcquireDecodeLock()
        lock.lock()
        defer {
            lock.unlock()
            LockOrder.didReleaseDecodeLock()
        }
        return try body()
    }
}

final class DecoderStateLock<Value>: @unchecked Sendable {
    private var storage: Value
    private let lock = NSLock()

    init(_ value: Value) {
        storage = value
    }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        LockOrder.willAcquireDecodeLock(allowsMainThread: true)
        lock.lock()
        defer {
            lock.unlock()
            LockOrder.didReleaseDecodeLock()
        }
        return try body(&storage)
    }
}
