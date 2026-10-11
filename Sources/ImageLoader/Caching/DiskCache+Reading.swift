import Foundation

extension DiskCache {
    /// 키의 데이터를 읽습니다. 파일로 쓰기 전이면 메모리에서 돌려줍니다. 파일을 읽으므로 메인 스레드에서는 부르지 않는 것이 좋습니다.
    public func cachedData(for key: String) -> Data? {
        guard let name = filename(for: key) else { return nil }
        let generation: UInt64?
        switch lookup(name) {
        case .staged(let data):
            return data
        case .missing:
            return nil
        case .indexed(let value):
            generation = value
        case .unknown:
            generation = nil
        }
        let now = clock.now.timeIntervalSinceReferenceDate
        switch DiskCacheFile.read(atPath: filePath(for: name), now: now) {
        case .success(let data):
            recordAccess(to: name, at: now)
            return data
        case .failure(let error):
            if error.code != .ENOENT {
                report(.read, error)
            } else if let generation, removeDriftedEntry(name, generation: generation) {
                report(.read, error)
            }
            return nil
        }
    }

    /// 키의 데이터가 있는지 알려 줍니다. 파일 내용은 읽지 않습니다.
    public func containsData(for key: String) -> Bool {
        guard let name = filename(for: key) else { return false }
        let generation: UInt64?
        switch lookup(name) {
        case .staged:
            return true
        case .missing:
            return false
        case .indexed(let value):
            generation = value
        case .unknown:
            generation = nil
        }
        guard DiskCacheFile.exists(atPath: filePath(for: name)) else {
            if let generation {
                removeDriftedEntry(name, generation: generation)
            }
            return false
        }
        return true
    }

    private func lookup(_ name: String) -> Lookup {
        let local = access { $0.lookup(name) }
        guard case .unknown = local else { return local }
        return pathQueue.state.withLock { $0.lookup(name) } ?? .unknown
    }

    private func recordAccess(to name: String, at time: TimeInterval) {
        let shouldBuildIndex = state.withLock { state -> Bool in
            guard state.index != nil else {
                if state.pendingTouches.count < DiskCache.pendingTouchLimit || state.pendingTouches[name] != nil {
                    state.pendingTouches[name] = time
                }
                guard state.pendingTouches.count >= DiskCache.pendingTouchLimit, !state.isIndexBuildScheduled else { return false }
                state.isIndexBuildScheduled = true
                return true
            }
            state.index?.touch(name, at: time)
            return false
        }
        if shouldBuildIndex {
            queue.async { [weak self] in
                guard let self else { return }
                var failures = Failures()
                self.loadIndexIfNeeded(&failures)
                self.report(failures)
            }
        }
    }

    @discardableResult
    private func removeDriftedEntry(_ name: String, generation: UInt64) -> Bool {
        state.withLock { state in
            guard state.staging.lookup(name) == nil, state.index?.entries[name]?.generation == generation else { return false }
            state.index?.remove(name)
            return true
        }
    }
}
