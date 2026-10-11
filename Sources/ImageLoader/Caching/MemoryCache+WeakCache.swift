import Foundation
import UIKit

extension MemoryCacheStorage {
    mutating func setWeakCacheEnabled(_ isEnabled: Bool, disposal: inout MemoryCacheDisposal) {
        guard isEnabled != isWeakCacheEnabled else {
            return
        }
        isWeakCacheEnabled = isEnabled
        guard isEnabled else {
            dropAllRemnants(disposal: &disposal)
            return
        }
        var current = head
        while let entry = current {
            retainWeakly(entry, disposal: &disposal)
            current = entry.next
        }
    }

    mutating func didReleasePurgedEntries() {
        pendingPurgeReleases -= 1
    }

    mutating func sweepPurgedRemnants(forKeys keys: ArraySlice<MemoryCacheKey>, disposal: inout MemoryCacheDisposal) {
        guard !remnants.isEmpty else {
            return
        }
        var visits = 0
        for key in keys {
            visits += 1
            guard let remnant = remnants[key], isWeakOnly(remnant) else {
                continue
            }
            if remnant.isAlive(retainingInto: &disposal) {
                enqueueForSweep(key)
            } else {
                removeRemnant(remnant, disposal: &disposal)
            }
        }
        recordSweep(visits: visits)
    }

    mutating func resetRemnantSweepThresholds() {
        remnantSweepThreshold = max(Self.minimumRemnantSweepThreshold, weakOnlyCount * 2)
        remnantDataSweepThreshold = max(Self.minimumRemnantDataSweepThreshold, weakOnlyDataBytes * 2)
    }

    mutating func revive(_ key: MemoryCacheKey, disposal: inout MemoryCacheDisposal) -> ImageContent? {
        guard let remnant = remnants[key] else {
            return nil
        }
        guard remnant.epoch == epoch || pendingPurgeReleases == 0 else {
            return nil
        }
        guard !isExpired(remnant.expiration), let content = remnant.content(retainingInto: &disposal) else {
            removeRemnant(remnant, disposal: &disposal)
            return nil
        }
        guard canAdmit(cost: remnant.cost) else {
            return content
        }
        let entry = MemoryCacheEntry(key: key, content: content, cost: remnant.cost, expiration: remnant.expiration)
        entry.isReferenced = true
        _ = admit(entry, disposal: &disposal)
        markMirrored(remnant)
        sweepRemnantsIfNeeded(disposal: &disposal)
        return content
    }

    func isWeakOnly(_ remnant: MemoryCacheRemnant) -> Bool {
        !remnant.isMirrored || remnant.epoch != epoch
    }

    mutating func retainWeakly(_ entry: MemoryCacheEntry, disposal: inout MemoryCacheDisposal) {
        workStatistics.operations += 1
        let remnant = MemoryCacheRemnant(entry, epoch: epoch)
        if let replaced = remnants[entry.key] {
            removeRemnant(replaced, disposal: &disposal)
        }
        remnants[entry.key] = remnant
        remnantDataBytes += remnant.dataByteCount
    }

    mutating func markMirrored(_ remnant: MemoryCacheRemnant) {
        workStatistics.operations += 1
        if isWeakOnly(remnant) {
            weakOnlyCount -= 1
            weakOnlyDataBytes -= remnant.dataByteCount
        }
        remnant.isMirrored = true
        remnant.epoch = epoch
    }

    mutating func markWeakOnly(_ remnant: MemoryCacheRemnant) {
        workStatistics.operations += 1
        remnant.isMirrored = false
        weakOnlyCount += 1
        weakOnlyDataBytes += remnant.dataByteCount
        enqueueForSweep(remnant.key)
        enqueuedSinceSweep += 1
    }

    mutating func enqueueForSweep(_ key: MemoryCacheKey) {
        sweepQueue.append(key)
    }

    mutating func removeRemnant(_ remnant: MemoryCacheRemnant, disposal: inout MemoryCacheDisposal) {
        workStatistics.operations += 1
        if isWeakOnly(remnant) {
            weakOnlyCount -= 1
            weakOnlyDataBytes -= remnant.dataByteCount
        }
        remnants.removeValue(forKey: remnant.key)
        remnantDataBytes -= remnant.dataByteCount
        disposal.remnants.append(remnant)
    }

    mutating func discardRemnant(forKey key: MemoryCacheKey, disposal: inout MemoryCacheDisposal) {
        guard !remnants.isEmpty, let remnant = remnants[key] else {
            return
        }
        removeRemnant(remnant, disposal: &disposal)
    }

    mutating func sweepRemnantsIfNeeded(disposal: inout MemoryCacheDisposal) {
        guard sweepQueue.count > 0 else {
            return
        }
        let batch = MemoryCache.weakSweepBatchSize
        let isDue =
            writesSinceSweep >= batch
            || enqueuedSinceSweep >= batch
            || weakOnlyCount >= remnantSweepThreshold
            || weakOnlyDataBytes >= remnantDataSweepThreshold
        guard isDue else {
            return
        }
        writesSinceSweep = 0
        enqueuedSinceSweep = 0
        if sweepCycleRemaining == 0 {
            sweepCycleRemaining = sweepQueue.count
        }
        var visits = 0
        while visits < batch, sweepCycleRemaining > 0, let key = sweepQueue.popFirst() {
            visits += 1
            sweepCycleRemaining -= 1
            guard let remnant = remnants[key], isWeakOnly(remnant) else {
                continue
            }
            if remnant.isAlive(retainingInto: &disposal) {
                enqueueForSweep(key)
            } else {
                removeRemnant(remnant, disposal: &disposal)
            }
        }
        recordSweep(visits: visits)
        if sweepCycleRemaining == 0 {
            resetRemnantSweepThresholds()
        }
    }

    mutating func recordSweep(visits: Int) {
        workStatistics.operations += visits
        workStatistics.sweepVisits += visits
        workStatistics.largestSweepBatch = max(workStatistics.largestSweepBatch, visits)
    }

    mutating func dropAllRemnants(disposal: inout MemoryCacheDisposal) {
        disposal.remnantTable = remnants
        remnants = [:]
        remnantDataBytes = 0
        weakOnlyCount = 0
        weakOnlyDataBytes = 0
        sweepQueue.removeAll()
        sweepCycleRemaining = 0
        writesSinceSweep = 0
        enqueuedSinceSweep = 0
        remnantSweepThreshold = Self.minimumRemnantSweepThreshold
        remnantDataSweepThreshold = Self.minimumRemnantDataSweepThreshold
    }
}

final class MemoryCacheRemnant {
    let key: MemoryCacheKey
    weak var image: UIImage?
    let type: AssetType?
    let isPreview: Bool
    let data: Data?
    let values: [ImageContent.UserInfoKey: any Sendable]
    let objects: [MemoryCacheWeakValue]
    let cost: Int
    let expiration: TimeInterval
    var epoch: Int
    var isMirrored = true

    init(_ entry: MemoryCacheEntry, epoch: Int) {
        let content = entry.content
        var values: [ImageContent.UserInfoKey: any Sendable] = [:]
        var objects: [MemoryCacheWeakValue] = []
        for (key, value) in content.userInfo {
            if let object = MemoryCacheWeakValue(key: key, value: value) {
                objects.append(object)
            } else {
                values[key] = value
            }
        }
        key = entry.key
        image = content.image
        type = content.type
        isPreview = content.isPreview
        data = content.data
        self.values = values
        self.objects = objects
        cost = entry.cost
        expiration = entry.expiration
        self.epoch = epoch
    }

    var dataByteCount: Int {
        data?.count ?? 0
    }

    func isAlive(retainingInto disposal: inout MemoryCacheDisposal) -> Bool {
        guard let image else {
            return false
        }
        disposal.values.append(image)
        for weakValue in objects {
            guard let object = weakValue.object else {
                return false
            }
            disposal.values.append(object)
        }
        return true
    }

    func content(retainingInto disposal: inout MemoryCacheDisposal) -> ImageContent? {
        guard let image else {
            return nil
        }
        disposal.values.append(image)
        var userInfo = values
        for weakValue in objects {
            guard let object = weakValue.object else {
                return nil
            }
            disposal.values.append(object)
            guard let value = weakValue.restore(object) else {
                return nil
            }
            userInfo[weakValue.key] = value
        }
        return ImageContent(image: image, type: type, isPreview: isPreview, data: data, userInfo: userInfo)
    }
}

struct MemoryCacheWeakValue {
    let key: ImageContent.UserInfoKey
    weak var object: AnyObject?
    let restore: (AnyObject) -> (any Sendable)?

    init?(key: ImageContent.UserInfoKey, value: any Sendable) {
        guard let reference = Self.reference(to: value) else {
            return nil
        }
        self.key = key
        object = reference.object
        restore = reference.restore
    }

    private static func reference<T: Sendable>(to value: T) -> (object: AnyObject, restore: (AnyObject) -> (any Sendable)?)? {
        guard T.self is AnyClass else {
            return nil
        }
        return (value as AnyObject, { $0 as? T })
    }
}

struct MemoryCacheKeyQueue {
    private var slots: [MemoryCacheKey?] = []
    private var head = 0
    private var members: Set<MemoryCacheKey> = []

    var count: Int {
        members.count
    }

    mutating func append(_ key: MemoryCacheKey) {
        guard members.insert(key).inserted else {
            return
        }
        if members.count > slots.count {
            grow()
        }
        slots[(head + members.count - 1) % slots.count] = key
    }

    mutating func popFirst() -> MemoryCacheKey? {
        guard !members.isEmpty, let key = slots[head] else {
            return nil
        }
        slots[head] = nil
        head = (head + 1) % slots.count
        members.remove(key)
        return key
    }

    mutating func removeAll() {
        slots = []
        head = 0
        members = []
    }

    private mutating func grow() {
        let queued = members.count - 1
        var grown = [MemoryCacheKey?](repeating: nil, count: max(16, slots.count * 2))
        for index in 0..<queued {
            grown[index] = slots[(head + index) % slots.count]
        }
        slots = grown
        head = 0
    }
}
