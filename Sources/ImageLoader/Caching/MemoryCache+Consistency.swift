import Foundation

extension MemoryCacheStorage {
    func consistencyReport() -> MemoryCache.ConsistencyReport {
        var summedRemnantDataBytes = 0
        var summedWeakOnlyCount = 0
        var summedWeakOnlyDataBytes = 0
        for remnant in remnants.values {
            summedRemnantDataBytes += remnant.dataByteCount
            if entries[remnant.key] == nil {
                summedWeakOnlyCount += 1
                summedWeakOnlyDataBytes += remnant.dataByteCount
            }
        }
        var summedCost = 0
        var linkedCount = 0
        var unmirroredEntryCount = 0
        var isLinkedConsistently = true
        var previous: MemoryCacheEntry?
        var current = head
        while let entry = current {
            summedCost += entry.cost
            linkedCount += 1
            if entry.previous !== previous || entries[entry.key] !== entry {
                isLinkedConsistently = false
            }
            if isWeakCacheEnabled, remnants[entry.key]?.image !== entry.content.image {
                unmirroredEntryCount += 1
            }
            previous = entry
            current = entry.next
        }
        if tail !== previous {
            isLinkedConsistently = false
        }
        return MemoryCache.ConsistencyReport(
            recordedCost: totalCost,
            summedCost: summedCost,
            count: entries.count,
            linkedCount: linkedCount,
            isLinkedConsistently: isLinkedConsistently,
            unmirroredEntryCount: unmirroredEntryCount,
            recordedRemnantDataBytes: remnantDataBytes,
            summedRemnantDataBytes: summedRemnantDataBytes,
            recordedWeakOnlyCount: weakOnlyCount,
            summedWeakOnlyCount: summedWeakOnlyCount,
            recordedWeakOnlyDataBytes: weakOnlyDataBytes,
            summedWeakOnlyDataBytes: summedWeakOnlyDataBytes
        )
    }
}
