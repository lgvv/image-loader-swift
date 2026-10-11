import Foundation
import UIKit

extension MemoryCacheStorage {
    mutating func noteDiskReload(forKey key: MemoryCacheKey) {
        recovery?.noteDiskReload(key)
    }

    mutating func beginRecovery(reason: MemoryPressureEvent, pending: Set<MemoryCacheKey>) -> MemoryCacheRecoveryWindow? {
        let previous = recovery
        let deadline = recoveryDeadline ?? clock.monotonicIncludingSleep + MemoryCache.recoveryWindow
        recoveryDeadline = nil
        recovery = MemoryCacheRecoveryWindow(reason: reason, deadline: deadline, pending: pending)
        return previous
    }

    mutating func takeRecoveryIfDue() -> MemoryCacheRecoveryWindow? {
        guard let window = recovery, clock.monotonicIncludingSleep >= window.deadline else { return nil }
        recovery = nil
        return window
    }

    mutating func respond(to event: MemoryPressureEvent) -> MemoryCachePressureResponse {
        let policy = lifecyclePolicy
        switch event {
        case .critical:
            return purge(policy, event)
        case .applicationMemoryWarning:
            guard policy.observesApplicationMemoryWarning else {
                return .ignored
            }
            return purge(policy, event)
        case .warning:
            guard let ratio = policy.pressureWarningTrimRatio else {
                return purge(policy, event)
            }
            let now = clock.monotonicIncludingSleep
            if let last = lastPressureTrim, now - last < MemoryCache.pressureWarningTrimInterval {
                return .ignored
            }
            lastPressureTrim = now
            return .trim(cost: Self.scale(costLimit, by: ratio), count: Self.scale(countLimit, by: ratio))
        }
    }

    func backgroundTrimTarget() -> MemoryCacheTrimTarget? {
        guard let ratio = lifecyclePolicy.backgroundTrimRatio else {
            return nil
        }
        return .fixed(cost: Self.scale(costLimit, by: ratio), count: Self.scale(countLimit, by: ratio))
    }

    mutating func purge(_ policy: MemoryCacheLifecyclePolicy, _ event: MemoryPressureEvent) -> MemoryCachePressureResponse {
        let entryCount = entries.count
        let cost = totalCost
        let sweepsRemnants = isWeakCacheEnabled && !remnants.isEmpty
        guard policy.purgesOnMemoryPressure,
            let detached = detachAllEntries(collectsKeys: true)
        else {
            return .ignored
        }
        recoveryDeadline = clock.monotonicIncludingSleep + MemoryCache.recoveryWindow
        epoch &+= 1
        pendingPurgeReleases += 1
        weakOnlyCount = remnants.count
        weakOnlyDataBytes = remnantDataBytes
        return .purged(detached, entryCount: entryCount, cost: cost, sweepsRemnants: sweepsRemnants, reason: event)
    }
}

enum MemoryCachePressureResponse {
    case ignored
    case trim(cost: Int, count: Int)
    case purged(MemoryCacheDetachedEntries, entryCount: Int, cost: Int, sweepsRemnants: Bool, reason: MemoryPressureEvent)
}

struct MemoryCacheRecoveryWindow {
    let reason: MemoryPressureEvent
    let deadline: TimeInterval
    var pending: Set<MemoryCacheKey>
    var restored: Set<MemoryCacheKey> = []
    var redecodedCount = 0
    var diskReadCount = 0

    mutating func noteStored(_ key: MemoryCacheKey) {
        guard pending.remove(key) != nil else { return }
        restored.insert(key)
        redecodedCount += 1
    }

    mutating func noteDiskReload(_ key: MemoryCacheKey) {
        guard restored.remove(key) != nil else { return }
        diskReadCount += 1
    }

    var diagnostic: ImageSession.Diagnostic {
        .memoryPressureRecovery(reason: reason.diagnosticReason, redecodedCount: redecodedCount, diskReadCount: diskReadCount)
    }
}

extension MemoryPressureEvent {
    var diagnosticReason: ImageSession.MemoryPressureReason {
        switch self {
        case .warning: .warning
        case .critical: .critical
        case .applicationMemoryWarning: .applicationMemoryWarning
        }
    }
}
