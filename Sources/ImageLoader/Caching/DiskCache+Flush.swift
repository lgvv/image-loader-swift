import Foundation

extension DiskCache {
    static let evictionTargetRatio = 0.9
    static let evictionBatchSize = 256

    func performFlush(_ trigger: FlushTrigger, name: String? = nil) {
        assertOnQueue()
        var failures = Failures()
        DiskCache.purgeIfNeeded(directoryPath: directoryPath, pathState: pathQueue.state, failures: &failures)
        guard let snapshot = takeFlushSnapshot(trigger, name: name) else {
            report(failures)
            return
        }
        if snapshot.removeAllId == nil {
            loadIndexIfNeeded(&failures)
        }
        let (outcomes, isIndexStale) = DiskCache.apply(snapshot, directoryPath: directoryPath, pathState: pathQueue.state, failures: &failures)
        commitFlush(snapshot, outcomes: outcomes, isIndexStale: isIndexStale)
        if isIndexStale {
            loadIndexIfNeeded(&failures)
        }
        evictIfNeeded(&failures)
        report(failures)
    }

    private func takeFlushSnapshot(_ trigger: FlushTrigger, name: String?) -> Staging? {
        state.withLock { state -> Staging? in
            switch trigger {
            case .timer:
                state.isFlushScheduled = false
            case .immediate:
                state.isImmediateFlushScheduled = false
            case .manual:
                break
            }
            if let name, state.staging.removeAllId == nil {
                return state.staging.snapshot(for: name)
            }
            return state.staging.isEmpty ? nil : state.staging
        }
    }

    private func commitFlush(_ snapshot: Staging, outcomes: [(name: String, outcome: WriteOutcome)], isIndexStale: Bool) {
        let now = clock.now.timeIntervalSinceReferenceDate
        state.withLock { state in
            if snapshot.removeAllId != nil {
                state.index = Index()
                state.pendingTouches.removeAll()
            }
            for (name, outcome) in outcomes {
                switch outcome {
                case .stored(let size):
                    state.index?.set(name, size: size, accessTime: now)
                case .removed:
                    state.index?.remove(name)
                }
            }
            state.staging.flushed(snapshot)
            if isIndexStale {
                state.index = nil
            }
        }
    }

    func performSweep() {
        assertOnQueue()
        performFlush(.manual)
        var failures = Failures()
        loadIndexIfNeeded(&failures)
        let now = clock.now.timeIntervalSinceReferenceDate
        let aged = state.withLock { state -> [String] in
            guard let ageLimit = state.settings.ageLimit else { return [] }
            return state.index?.removeEntries(accessedBefore: now - ageLimit) ?? []
        }
        let trimmed = removeLeastRecentlyUsed { settings in
            let ratio = settings.trimRatio.isFinite ? min(max(settings.trimRatio, 0), 1) : 0.7
            return Int(Double(settings.sizeLimit) * ratio)
        }
        for name in aged + trimmed {
            if let error = DiskCacheFile.remove(atPath: filePath(for: name)) {
                failures.record(.sweep, error)
            }
        }
        report(failures)
    }

    func loadIndexIfNeeded(_ failures: inout Failures) {
        assertOnQueue()
        guard state.withLock({ $0.index == nil }) else { return }
        DiskCache.purgeIfNeeded(directoryPath: directoryPath, pathState: pathQueue.state, failures: &failures)
        let now = clock.now.timeIntervalSinceReferenceDate
        let scan: DiskCacheFile.Scan
        do {
            scan = try DiskCacheFile.scan(directoryPath: directoryPath, staleTemporaryBefore: now - DiskCacheFile.staleTemporaryAge)
        } catch {
            failures.record(.initialize, error)
            state.withLock { $0.isIndexBuildScheduled = false }
            return
        }
        for name in scan.staleTemporaryNames {
            if let error = DiskCacheFile.remove(atPath: filePath(for: name)) {
                failures.record(.initialize, error)
            }
        }
        indexScanHook?()
        var files = scan.files
        if let survivors = pathQueue.state.withLock({ $0.survivors }) {
            files.removeAll { !survivors.contains($0.name) }
        }
        var index = Index(files: files)
        state.withLock { state in
            state.isIndexBuildScheduled = false
            guard state.index == nil else { return }
            for (name, time) in state.pendingTouches.sorted(by: { $0.value < $1.value }) {
                index.touch(name, at: time)
            }
            state.pendingTouches.removeAll()
            state.index = index
        }
    }

    func scheduleSweep() {
        let interval = state.withLock { $0.settings.sweepInterval }
        queue.asyncAfter(deadline: SystemClock.dispatchDeadline(after: DiskCache.dispatchInterval(max(interval, 0.01))), qos: .background) { [weak self] in
            self?.performScheduledSweep()
        }
    }

    func performBackgroundMaintenance() {
        if state.withLock({ $0.settings.isSweepEnabled }) {
            performSweep()
        } else {
            performFlush(.manual)
        }
    }

    private func performScheduledSweep() {
        if state.withLock({ $0.settings.isSweepEnabled }) {
            performSweep()
        }
        scheduleSweep()
    }

    private func evictIfNeeded(_ failures: inout Failures) {
        let victims = removeLeastRecentlyUsed { settings in
            Int(Double(settings.sizeLimit) * DiskCache.evictionTargetRatio)
        }
        for name in victims {
            if let error = DiskCacheFile.remove(atPath: filePath(for: name)) {
                failures.record(.remove, error)
            }
        }
    }

    private func removeLeastRecentlyUsed(target: (Settings) -> Int) -> [String] {
        var victims: [String] = []
        while true {
            let isStarted = !victims.isEmpty
            let batch = state.withLock { state -> [String] in
                guard let totalSize = state.index?.totalSize else { return [] }
                guard isStarted || totalSize > state.settings.sizeLimit else { return [] }
                return state.index?.removeLeastRecentlyUsed(untilSizeAtMost: target(state.settings), limit: DiskCache.evictionBatchSize) ?? []
            }
            victims.append(contentsOf: batch)
            guard batch.count == DiskCache.evictionBatchSize else { return victims }
        }
    }

    static func purgeIfNeeded(directoryPath: String, pathState: LockIsolated<PathState>, failures: inout Failures) {
        guard let survivors = pathState.withLock({ $0.survivors }) else { return }
        do {
            try DiskCacheFile.removeAllFiles(directoryPath: directoryPath, keeping: survivors)
            pathState.withLock { $0.survivors = nil }
        } catch {
            failures.record(.remove, error)
        }
    }

    static func apply(
        _ snapshot: Staging,
        directoryPath: String,
        pathState: LockIsolated<PathState>,
        failures: inout Failures
    ) -> (outcomes: [(name: String, outcome: WriteOutcome)], isIndexStale: Bool) {
        var isIndexStale = false
        if snapshot.removeAllId != nil {
            pathState.withLock { $0.survivors = [] }
            purgeIfNeeded(directoryPath: directoryPath, pathState: pathState, failures: &failures)
        }
        var outcomes: [(name: String, outcome: WriteOutcome)] = []
        outcomes.reserveCapacity(snapshot.entries.count)
        for (name, entry) in snapshot.entries.sorted(by: { $0.value.id < $1.value.id }) {
            switch entry.change {
            case .add(let data):
                outcomes.append((name, write(data, name: name, directoryPath: directoryPath, isDirectoryRecreated: &isIndexStale, failures: &failures)))
            case .remove:
                if let error = DiskCacheFile.remove(atPath: DiskCacheFile.path(directoryPath, name)) {
                    failures.record(.remove, error)
                }
                outcomes.append((name, .removed))
            }
        }
        pathState.withLock { state in
            guard state.survivors != nil else { return }
            for (name, outcome) in outcomes {
                switch outcome {
                case .stored:
                    state.survivors?.insert(name)
                case .removed:
                    state.survivors?.remove(name)
                }
            }
        }
        return (outcomes, isIndexStale)
    }

    private static func write(_ data: Data, name: String, directoryPath: String, isDirectoryRecreated: inout Bool, failures: inout Failures) -> WriteOutcome {
        let target = DiskCacheFile.path(directoryPath, name)
        do {
            try DiskCacheFile.write(data, toPath: target, temporaryPath: DiskCacheFile.path(directoryPath, DiskCacheFile.temporaryName(for: name)))
            return .stored(data.count)
        } catch {
            failures.record(.write, error)
        }
        if !DiskCacheFile.isDirectory(atPath: directoryPath) {
            do {
                try DiskCacheFile.createDirectory(atPath: directoryPath)
                isDirectoryRecreated = true
                try DiskCacheFile.write(data, toPath: target, temporaryPath: DiskCacheFile.path(directoryPath, DiskCacheFile.temporaryName(for: name)))
                return .stored(data.count)
            } catch {
                failures.record(.write, error)
            }
        }
        _ = DiskCacheFile.remove(atPath: target)
        return .removed
    }
}
