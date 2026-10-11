import Foundation

extension DiskCache {
    private final class Registration {
        let id: ObjectIdentifier
        weak var cache: DiskCache?

        init(_ cache: DiskCache) {
            id = ObjectIdentifier(cache)
            self.cache = cache
        }
    }

    struct PathState {
        var releases: [(id: UInt64, staging: Staging)] = []
        var nextReleaseId: UInt64 = 0
        var survivors: Set<String>?

        func lookup(_ name: String) -> Lookup? {
            for release in releases.reversed() {
                switch release.staging.lookup(name) {
                case .add(let data):
                    return .staged(data)
                case .remove:
                    return .missing
                case nil:
                    continue
                }
            }
            if let survivors, !survivors.contains(name) {
                return .missing
            }
            return nil
        }
    }

    final class PathQueue: Sendable {
        let queue: DispatchQueue
        let key = DispatchSpecificKey<Void>()
        let state = LockIsolated(PathState())

        init() {
            queue = DispatchQueue(label: "ImageLoader.DiskCache.WriteQueue", qos: .utility)
            queue.setSpecific(key: key, value: ())
        }

        func beginRelease(_ staging: Staging) -> UInt64 {
            state.withLock { state in
                state.nextReleaseId += 1
                state.releases.append((state.nextReleaseId, staging))
                return state.nextReleaseId
            }
        }

        func endRelease(_ id: UInt64) {
            state.withLock { state in
                state.releases.removeAll { $0.id == id }
            }
        }
    }

    private static let registry = LockIsolated<[String: Registration]>([:])
    private static let pathQueues = LockIsolated<[String: PathQueue]>([:])
    private static let registrationHooks = LockIsolated<[String: @Sendable () -> Void]>([:])

    static func setRegistrationHook(_ hook: (@Sendable () -> Void)?, forRegistryKey key: String) {
        registrationHooks.withLock { $0[key] = hook }
    }

    static func registryKey(for path: URL) -> String {
        path.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func pathQueue(forRegistryKey key: String) -> PathQueue {
        pathQueues.withLock { queues in
            if let existing = queues[key] {
                return existing
            }
            let created = PathQueue()
            queues[key] = created
            return created
        }
    }

    static func directory(named name: String) throws -> URL {
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    static func register(_ cache: DiskCache) throws {
        let existing = registry.withLock { registry -> DiskCache? in
            if let live = registry[cache.registryKey]?.cache {
                return live
            }
            registry[cache.registryKey] = Registration(cache)
            return nil
        }
        if existing != nil {
            throw Error.pathInUse(cache.path)
        }
        let hook = registrationHooks.withLock { $0[cache.registryKey] }
        hook?()
    }

    static func unregister(_ cache: DiskCache) {
        let key = cache.registryKey
        let id = ObjectIdentifier(cache)
        registry.withLock { registry in
            if registry[key]?.id == id {
                registry[key] = nil
            }
        }
    }

    static func registered(at path: URL) throws -> DiskCache {
        try resolve(at: path, initialSizeLimit: nil).cache
    }

    static func registered(name: String) throws -> DiskCache {
        try registered(at: directory(named: name))
    }

    static func shared(name: String, sizeLimit: Int?) throws -> DiskCache {
        let (cache, isCreated) = try resolve(at: directory(named: name), initialSizeLimit: sizeLimit)
        if let sizeLimit, !isCreated {
            cache.raiseSizeLimit(to: sizeLimit)
        }
        return cache
    }

    private static func resolve(at path: URL, initialSizeLimit: Int?) throws -> (cache: DiskCache, isCreated: Bool) {
        var lastError: any Swift.Error = Error.pathInUse(path)
        for _ in 0..<3 {
            let key = registryKey(for: path)
            if let existing = registry.withLock({ $0[key]?.cache }) {
                return (existing, false)
            }
            do {
                let cache = try DiskCache(
                    path: path,
                    filenameGenerator: DiskCache.filename(for:),
                    clock: DiskCache.wallClock,
                    notificationCenter: .default,
                    sizeLimit: initialSizeLimit
                )
                return (cache, true)
            } catch let error as DiskCache.Error {
                lastError = error
            }
        }
        throw lastError
    }
}
