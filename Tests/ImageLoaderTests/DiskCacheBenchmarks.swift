import Foundation
import Testing

@testable import ImageLoader

private let isThreadSanitizerEnabled = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil

private func benchmarkDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("DiskCacheBenchmarks-\(UUID().uuidString)", isDirectory: true)
}

private func monotonicSeconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

private func threadCPUSeconds() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
    return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let middle = sorted.count / 2
    return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}

private func percentile(_ values: [Double], _ ratio: Double) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * ratio))]
}

private func format(_ value: Double) -> String {
    String(format: "%.3f", value)
}

private func fillDirectory(_ directory: URL, count: Int, size: Int) throws {
    let cache = try DiskCache(path: directory)
    cache.flushInterval = 3600
    let payload = Data(repeating: 1, count: size)
    for index in 0..<count {
        cache.storeData(payload, for: "key.\(index)")
        if index % 500 == 499 {
            cache.flush()
        }
    }
    cache.flush()
}

private struct SortingEvictionReference {
    private struct Entry {
        var size: Int
        var accessTime: TimeInterval
        var order: UInt64
        let generation: UInt64
    }

    private var entries: [String: Entry] = [:]
    private(set) var totalSize = 0
    private var nextOrder: UInt64 = 0
    private var nextGeneration: UInt64 = 0

    mutating func set(_ name: String, size: Int, accessTime: TimeInterval) {
        if let previous = entries[name] {
            totalSize -= previous.size
        }
        nextOrder += 1
        nextGeneration += 1
        entries[name] = Entry(size: size, accessTime: accessTime, order: nextOrder, generation: nextGeneration)
        totalSize += size
    }

    mutating func touch(_ name: String, at time: TimeInterval) {
        guard entries[name] != nil else { return }
        nextOrder += 1
        entries[name]?.order = nextOrder
        if time > entries[name]?.accessTime ?? time {
            entries[name]?.accessTime = time
        }
    }

    func candidates() -> [(name: String, order: UInt64)] {
        var candidates: [(name: String, order: UInt64)] = []
        candidates.reserveCapacity(entries.count)
        for (name, entry) in entries {
            candidates.append((name, entry.order))
        }
        return candidates
    }

    mutating func removeLeastRecentlyUsed(_ ordered: [(name: String, order: UInt64)], untilSizeAtMost target: Int) -> [String] {
        var victims: [String] = []
        for candidate in ordered {
            guard totalSize > target else { break }
            guard entries[candidate.name]?.order == candidate.order else { continue }
            if let entry = entries.removeValue(forKey: candidate.name) {
                totalSize -= entry.size
            }
            victims.append(candidate.name)
        }
        return victims
    }
}

@Suite(.serialized, .enabled(if: !isThreadSanitizerEnabled)) struct DiskCacheBenchmarks {
    @Test(arguments: [("no_eviction", 150 * 1024 * 1024), ("eviction_500_entries", 500 * 8 * 1024)])
    func batchedWriteCost(label: String, sizeLimit: Int) throws {
        let directory = benchmarkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try DiskCache(path: directory)
        cache.sizeLimit = sizeLimit
        cache.flushInterval = 3600
        let payload = Data(repeating: 9, count: 8 * 1024)
        var wall: [Double] = []
        var cpu: [Double] = []
        for batch in 0..<10 {
            let start = monotonicSeconds()
            let cpuStart = threadCPUSeconds()
            for index in batch * 100..<(batch + 1) * 100 {
                cache.storeData(payload, for: "key.\(index)")
            }
            cache.flush()
            wall.append((monotonicSeconds() - start) * 1000 / 100)
            cpu.append((threadCPUSeconds() - cpuStart) * 1000 / 100)
        }
        print(
            "BENCH|disk_write_batch|\(label)|ms_per_write_by_100_batch=\(wall.map(format).joined(separator: ","))|median_ms=\(format(median(wall)))|last_first_ratio=\(format(wall[9] / wall[0]))|cpu_ms_per_write=\(cpu.map(format).joined(separator: ","))|cpu_median_ms=\(format(median(cpu)))|cpu_last_first_ratio=\(format(cpu[9] / cpu[0]))|total_count=\(cache.totalCount)"
        )
    }

    @Test(arguments: [("no_eviction", 150 * 1024 * 1024), ("eviction_500_entries", 500 * 8 * 1024)])
    func singleWriteCost(label: String, sizeLimit: Int) throws {
        let directory = benchmarkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try DiskCache(path: directory)
        cache.sizeLimit = sizeLimit
        cache.flushInterval = 3600
        let payload = Data(repeating: 9, count: 8 * 1024)
        var wall: [Double] = []
        var cpu: [Double] = []
        for index in 0..<1000 {
            let key = "key.\(index)"
            let start = monotonicSeconds()
            let cpuStart = threadCPUSeconds()
            cache.storeData(payload, for: key)
            cache.flush(for: key)
            wall.append((monotonicSeconds() - start) * 1000)
            cpu.append((threadCPUSeconds() - cpuStart) * 1000)
        }
        let first = median(Array(wall.prefix(100)))
        let last = median(Array(wall.suffix(100)))
        let cpuFirst = median(Array(cpu.prefix(100)))
        let cpuLast = median(Array(cpu.suffix(100)))
        print(
            "BENCH|disk_write_single|\(label)|median_ms=\(format(median(wall)))|p95_ms=\(format(percentile(wall, 0.95)))|first100_median_ms=\(format(first))|last100_median_ms=\(format(last))|last_first_ratio=\(format(last / first))|cpu_median_ms=\(format(median(cpu)))|cpu_last_first_ratio=\(format(cpuLast / cpuFirst))"
        )
    }

    @Test func readCost() throws {
        let directory = benchmarkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try fillDirectory(directory, count: 500, size: 8 * 1024)

        let cold = try measureReads(directory: directory, warmIndex: false)
        let warm = try measureReads(directory: directory, warmIndex: true)
        print(
            "BENCH|disk_read|cold_index|median_us=\(format(median(cold.wall)))|p95_us=\(format(percentile(cold.wall, 0.95)))|cpu_median_us=\(format(median(cold.cpu)))|misses=\(cold.misses)"
        )
        print(
            "BENCH|disk_read|warm_index|median_us=\(format(median(warm.wall)))|p95_us=\(format(percentile(warm.wall, 0.95)))|cpu_median_us=\(format(median(warm.cpu)))|misses=\(warm.misses)"
        )
    }

    private func measureReads(directory: URL, warmIndex: Bool) throws -> (wall: [Double], cpu: [Double], misses: Int) {
        let cache = try DiskCache(path: directory)
        if warmIndex {
            _ = cache.totalCount
        }
        var wall: [Double] = []
        var cpu: [Double] = []
        var misses = 0
        for index in 0..<500 {
            let key = "key.\(index)"
            let start = monotonicSeconds()
            let cpuStart = threadCPUSeconds()
            if cache.cachedData(for: key) == nil {
                misses += 1
            }
            wall.append((monotonicSeconds() - start) * 1_000_000)
            cpu.append((threadCPUSeconds() - cpuStart) * 1_000_000)
        }
        return (wall, cpu, misses)
    }

    @Test(arguments: [1000, 10000])
    func indexBuildCost(entries: Int) throws {
        let directory = benchmarkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try fillDirectory(directory, count: entries, size: 4 * 1024)
        var wall: [Double] = []
        var cpu: [Double] = []
        var counts: [Int] = []
        for _ in 0..<3 {
            let sample = try measureIndexBuild(directory: directory)
            wall.append(sample.wall)
            cpu.append(sample.cpu)
            counts.append(sample.count)
        }
        print(
            "BENCH|disk_index_build|entries=\(entries)|ms=\(wall.map(format).joined(separator: ","))|median_ms=\(format(median(wall)))|cpu_median_ms=\(format(median(cpu)))|counts=\(counts.map(String.init).joined(separator: ","))"
        )
        #expect(counts.allSatisfy { $0 == entries })
    }

    @Test func evictionSelectionCost() {
        let entries = 10000
        var index = DiskCache.Index()
        var next = 0
        for _ in 0..<entries {
            index.set("key.\(next)", size: 1, accessTime: 0)
            next += 1
        }
        var totals: [Double] = []
        var batches: [Double] = []
        var evicted: [Int] = []
        for _ in 0..<20 {
            while index.totalSize <= entries {
                index.set("key.\(next)", size: 1, accessTime: 0)
                next += 1
            }
            for offset in stride(from: 0, to: entries, by: 7) {
                index.touch("key.\(next - 1 - offset)", at: 1)
            }
            var victims = 0
            let start = monotonicSeconds()
            while true {
                let batchStart = monotonicSeconds()
                let batch = index.removeLeastRecentlyUsed(untilSizeAtMost: Int(Double(entries) * DiskCache.evictionTargetRatio), limit: DiskCache.evictionBatchSize)
                batches.append((monotonicSeconds() - batchStart) * 1000)
                victims += batch.count
                guard batch.count == DiskCache.evictionBatchSize else { break }
            }
            totals.append((monotonicSeconds() - start) * 1000)
            evicted.append(victims)
        }
        print(
            "BENCH|disk_eviction_select|scope=index_only|entries=\(entries)|victims=\(evicted[0])|median_total_ms=\(format(median(totals)))|median_lock_hold_ms=\(format(median(batches)))|max_lock_hold_ms=\(format(batches.max() ?? 0))"
        )
        #expect(evicted.allSatisfy { $0 == entries / 10 + 1 })
    }

    @Test func sortingEvictionSelectionReferenceCost() {
        let entries = 10000
        var reference = SortingEvictionReference()
        var index = DiskCache.Index()
        var next = 0
        for _ in 0..<entries {
            reference.set("key.\(next)", size: 1, accessTime: 0)
            index.set("key.\(next)", size: 1, accessTime: 0)
            next += 1
        }
        var totals: [Double] = []
        var holds: [Double] = []
        var evicted: [Int] = []
        var isSameSelection = true
        let target = Int(Double(entries) * DiskCache.evictionTargetRatio)
        for _ in 0..<20 {
            while reference.totalSize <= entries {
                reference.set("key.\(next)", size: 1, accessTime: 0)
                index.set("key.\(next)", size: 1, accessTime: 0)
                next += 1
            }
            for offset in stride(from: 0, to: entries, by: 7) {
                reference.touch("key.\(next - 1 - offset)", at: 1)
                index.touch("key.\(next - 1 - offset)", at: 1)
            }
            let start = monotonicSeconds()
            let copyStart = monotonicSeconds()
            let candidates = reference.candidates()
            let copyHold = (monotonicSeconds() - copyStart) * 1000
            let ordered = candidates.sorted { $0.order < $1.order }
            let removeStart = monotonicSeconds()
            let victims = reference.removeLeastRecentlyUsed(ordered, untilSizeAtMost: target)
            let removeHold = (monotonicSeconds() - removeStart) * 1000
            totals.append((monotonicSeconds() - start) * 1000)
            holds.append(contentsOf: [copyHold, removeHold])
            evicted.append(victims.count)
            var selected: [String] = []
            while true {
                let batch = index.removeLeastRecentlyUsed(untilSizeAtMost: target, limit: DiskCache.evictionBatchSize)
                selected.append(contentsOf: batch)
                guard batch.count == DiskCache.evictionBatchSize else { break }
            }
            isSameSelection = isSameSelection && selected == victims
        }
        print(
            "BENCH|disk_eviction_select_sorting_reference|scope=index_only|entries=\(entries)|victims=\(evicted[0])|median_total_ms=\(format(median(totals)))|median_lock_hold_ms=\(format(median(holds)))|max_lock_hold_ms=\(format(holds.max() ?? 0))"
        )
        #expect(evicted.allSatisfy { $0 == entries / 10 + 1 })
        #expect(isSameSelection)
    }

    private func measureIndexBuild(directory: URL) throws -> (wall: Double, cpu: Double, count: Int) {
        let cache = try DiskCache(path: directory)
        let start = monotonicSeconds()
        let cpuStart = threadCPUSeconds()
        let count = cache.totalCount
        return ((monotonicSeconds() - start) * 1000, (threadCPUSeconds() - cpuStart) * 1000, count)
    }
}
