import Foundation
import UIKit

struct MemoryCacheStorage {
    static let minimumRemnantSweepThreshold = 64
    static let minimumRemnantDataSweepThreshold = MemoryCache.weakCacheDataSweepThreshold

    let clock: any SessionClock
    var costLimit: Int {
        didSet { updateEntryMaxCost() }
    }
    var countLimit: Int
    var entryCostLimit = 0.1 {
        didSet { updateEntryMaxCost() }
    }
    var ttl: TimeInterval?
    var lifecyclePolicy = MemoryCacheLifecyclePolicy()
    var isWeakCacheEnabled = false
    private(set) var entryMaxCost = Int.max
    private(set) var totalCost = 0
    var weakOnlyCount = 0
    var weakOnlyDataBytes = 0
    var workStatistics = MemoryCache.WorkStatistics()
    var entries: [MemoryCacheKey: MemoryCacheEntry] = [:]
    var head: MemoryCacheEntry?
    var tail: MemoryCacheEntry?
    var remnants: [MemoryCacheKey: MemoryCacheRemnant] = [:]
    var remnantDataBytes = 0
    var remnantSweepThreshold = MemoryCacheStorage.minimumRemnantSweepThreshold
    var remnantDataSweepThreshold = MemoryCacheStorage.minimumRemnantDataSweepThreshold
    var sweepQueue = MemoryCacheKeyQueue()
    var sweepCycleRemaining = 0
    var writesSinceSweep = 0
    var enqueuedSinceSweep = 0
    var epoch = 0
    var pendingPurgeReleases = 0
    var lastPressureTrim: TimeInterval?
    var recoveryDeadline: TimeInterval?
    var recovery: MemoryCacheRecoveryWindow?
    var isOverflowTrimScheduled = false

    init(costLimit: Int, countLimit: Int, clock: any SessionClock) {
        self.costLimit = costLimit
        self.countLimit = countLimit
        self.clock = clock
        updateEntryMaxCost()
    }

    var count: Int {
        entries.count
    }

    mutating func value(forKey key: MemoryCacheKey, disposal: inout MemoryCacheDisposal) -> ImageContent? {
        if let entry = entries[key] {
            if isExpired(entry.expiration) {
                detach(entry, disposal: &disposal)
                discardRemnant(forKey: key, disposal: &disposal)
                return nil
            }
            if !entry.isReferenced {
                entry.isReferenced = true
            }
            return entry.content
        }
        guard isWeakCacheEnabled, !remnants.isEmpty else {
            return nil
        }
        return revive(key, disposal: &disposal)
    }

    mutating func insert(_ content: ImageContent, cost: Int, forKey key: MemoryCacheKey, disposal: inout MemoryCacheDisposal) -> Bool {
        if let existing = entries[key] {
            detach(existing, disposal: &disposal)
        }
        guard canAdmit(cost: cost) else {
            discardRemnant(forKey: key, disposal: &disposal)
            return false
        }
        let expiration = ttl.map { clock.monotonicIncludingSleep + $0 } ?? .infinity
        let entry = MemoryCacheEntry(key: key, content: content, cost: cost, expiration: expiration)
        let isWithinLimits = admit(entry, disposal: &disposal)
        recovery?.noteStored(key)
        if isWeakCacheEnabled {
            retainWeakly(entry, disposal: &disposal)
            writesSinceSweep += 1
            sweepRemnantsIfNeeded(disposal: &disposal)
        }
        guard !isWithinLimits, !isOverflowTrimScheduled else {
            return false
        }
        isOverflowTrimScheduled = true
        return true
    }

    mutating func didFinishOverflowTrim() {
        isOverflowTrimScheduled = false
    }

    mutating func removeValue(forKey key: MemoryCacheKey, disposal: inout MemoryCacheDisposal) {
        if let entry = entries[key] {
            detach(entry, disposal: &disposal)
        }
        discardRemnant(forKey: key, disposal: &disposal)
    }

    mutating func removeAll(disposal: inout MemoryCacheDisposal) {
        disposal.detached = detachAllEntries(collectsKeys: false)
        dropAllRemnants(disposal: &disposal)
    }

    mutating func trimStep(toward target: MemoryCacheTrimTarget, disposal: inout MemoryCacheDisposal) -> Bool {
        let limits: (cost: Int, count: Int)
        switch target {
        case .limits:
            limits = (costLimit, countLimit)
        case .fixed(let cost, let count):
            limits = (cost, count)
        }
        let isWithinLimits = trim(
            toCost: limits.cost,
            toCount: limits.count,
            maximumVisits: MemoryCache.evictionBatchSize,
            disposal: &disposal
        )
        sweepRemnantsIfNeeded(disposal: &disposal)
        return !isWithinLimits
    }

    static func scale(_ limit: Int, by fraction: Double) -> Int {
        let clamped = fraction.isNaN ? 0 : max(0, min(fraction, 1))
        return integer(Double(limit) * clamped)
    }

    static func integer(_ value: Double) -> Int {
        guard value.isFinite else {
            return value > 0 ? Int.max : 0
        }
        if value >= Double(Int.max) {
            return Int.max
        }
        if value <= Double(Int.min) {
            return Int.min
        }
        return Int(value)
    }

    mutating func updateEntryMaxCost() {
        entryMaxCost = Self.scale(costLimit, by: entryCostLimit)
    }

    func canAdmit(cost: Int) -> Bool {
        cost < entryMaxCost && cost <= costLimit && countLimit > 0
    }

    mutating func admit(_ entry: MemoryCacheEntry, disposal: inout MemoryCacheDisposal) -> Bool {
        let evictionsNeeded = max(1, entries.count + 1 - countLimit)
        trim(toCost: costLimit - entry.cost, toCount: countLimit - 1, maximumVisits: MemoryCache.maximumAdmissionVisits(evictionsNeeded: evictionsNeeded), disposal: &disposal)
        entries[entry.key] = entry
        link(entry)
        totalCost += entry.cost
        return totalCost <= costLimit && entries.count <= countLimit
    }

    @discardableResult
    mutating func trim(toCost costLimit: Int, toCount countLimit: Int, maximumVisits: Int, disposal: inout MemoryCacheDisposal) -> Bool {
        var now: TimeInterval?
        var visits = 0
        while totalCost > costLimit || entries.count > countLimit, let entry = head {
            guard visits < maximumVisits else {
                break
            }
            visits += 1
            if isExpired(entry.expiration, now: &now) {
                detach(entry, disposal: &disposal)
                discardRemnant(forKey: entry.key, disposal: &disposal)
            } else if entry.isReferenced {
                entry.isReferenced = false
                moveToTail(entry)
            } else {
                detach(entry, disposal: &disposal)
            }
        }
        if maximumVisits != Int.max {
            workStatistics.largestEvictionBatch = max(workStatistics.largestEvictionBatch, visits)
        }
        return totalCost <= costLimit && entries.count <= countLimit
    }

    mutating func detachAllEntries(collectsKeys: Bool) -> MemoryCacheDetachedEntries? {
        guard let first = head else {
            return nil
        }
        let detached = MemoryCacheDetachedEntries(head: first, table: entries, collectsKeys: collectsKeys)
        entries = [:]
        head = nil
        tail = nil
        totalCost = 0
        return detached
    }

    mutating func detach(_ entry: MemoryCacheEntry, disposal: inout MemoryCacheDisposal) {
        entries.removeValue(forKey: entry.key)
        unlink(entry)
        totalCost -= entry.cost
        disposal.entries.append(entry)
        if !remnants.isEmpty, let remnant = remnants[entry.key], !isWeakOnly(remnant) {
            markWeakOnly(remnant)
        }
    }

    func isExpired(_ expiration: TimeInterval) -> Bool {
        expiration != .infinity && expiration < clock.monotonicIncludingSleep
    }

    func isExpired(_ expiration: TimeInterval, now: inout TimeInterval?) -> Bool {
        guard expiration != .infinity else {
            return false
        }
        let time = now ?? clock.monotonicIncludingSleep
        now = time
        return expiration < time
    }

    mutating func link(_ entry: MemoryCacheEntry) {
        workStatistics.operations += 1
        if let last = tail {
            last.next = entry
            entry.previous = last
        } else {
            head = entry
        }
        tail = entry
    }

    mutating func unlink(_ entry: MemoryCacheEntry) {
        workStatistics.operations += 1
        if let previous = entry.previous {
            previous.next = entry.next
        } else {
            head = entry.next
        }
        if let next = entry.next {
            next.previous = entry.previous
        } else {
            tail = entry.previous
        }
        entry.previous = nil
        entry.next = nil
    }

    mutating func moveToTail(_ entry: MemoryCacheEntry) {
        guard entry !== tail else {
            return
        }
        unlink(entry)
        link(entry)
    }
}

enum MemoryCacheTrimTarget {
    case limits
    case fixed(cost: Int, count: Int)
}

final class MemoryCacheEntry {
    let key: MemoryCacheKey
    let content: ImageContent
    let cost: Int
    let expiration: TimeInterval
    var isReferenced = false
    var previous: MemoryCacheEntry?
    var next: MemoryCacheEntry?

    init(key: MemoryCacheKey, content: ImageContent, cost: Int, expiration: TimeInterval) {
        self.key = key
        self.content = content
        self.cost = cost
        self.expiration = expiration
    }
}

final class MemoryCacheDetachedEntries: @unchecked Sendable {
    private var head: MemoryCacheEntry?
    private var table: [MemoryCacheKey: MemoryCacheEntry]
    private let collectsKeys: Bool

    init(head: MemoryCacheEntry, table: [MemoryCacheKey: MemoryCacheEntry], collectsKeys: Bool) {
        self.head = head
        self.table = table
        self.collectsKeys = collectsKeys
    }

    func release() -> [MemoryCacheKey] {
        var keys: [MemoryCacheKey] = []
        if collectsKeys {
            keys.reserveCapacity(table.count)
        }
        table = [:]
        var current = head
        head = nil
        while let entry = current {
            if collectsKeys {
                keys.append(entry.key)
            }
            current = entry.next
            entry.next = nil
            entry.previous = nil
        }
        return keys
    }
}

struct MemoryCacheDisposal {
    var entries: [MemoryCacheEntry] = []
    var remnants: [MemoryCacheRemnant] = []
    var values: [Any] = []
    var remnantTable: [MemoryCacheKey: MemoryCacheRemnant] = [:]
    var detached: MemoryCacheDetachedEntries?

    func release() {
        _ = detached?.release()
    }
}
