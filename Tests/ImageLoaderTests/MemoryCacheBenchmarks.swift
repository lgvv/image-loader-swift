import Foundation
@_spi(Testing) @testable import ImageLoader
@_spi(Testing) import ImageLoaderTesting
import Testing
import UIKit

private let isThreadSanitizerActive = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil

@Suite("MemoryCache 벤치마크", .serialized, .enabled(if: !isThreadSanitizerActive, "ThreadSanitizer 아래에서는 시간을 재지 않습니다"))
struct MemoryCacheBenchmarks {
    @Test("subscript get 히트 20,000회 평균")
    func subscriptGetHits() throws {
        let operations = 20000
        let fixture = try MemoryCacheBenchFixture(entryCount: 1000)
        let cache = fixture.cache
        let keys = fixture.requestKeys
        for key in keys {
            cache[key] = fixture.content
        }

        var hits = 0
        for index in 0..<2000 {
            if cache[keys[index % keys.count]] != nil {
                hits += 1
            }
        }
        hits = 0
        let cacheTime = MemoryCacheBenchFixture.measure {
            for index in 0..<operations {
                if cache[keys[index % keys.count]] != nil {
                    hits += 1
                }
            }
        }
        #expect(hits == operations)

        let session = makeSession(loader: MockDataLoader()) {
            $0.memoryCache = cache
        }
        let requests = fixture.requests
        var facadeHits = 0
        let facadeTime = MemoryCacheBenchFixture.measure {
            for index in 0..<operations {
                if session.cache[requests[index % requests.count]] != nil {
                    facadeHits += 1
                }
            }
        }
        #expect(facadeHits == operations)

        let baseline = NSCache<NSString, UIImage>()
        let names = fixture.requests.map { $0.url!.absoluteString as NSString }
        for name in names {
            baseline.setObject(fixture.content.image, forKey: name)
        }
        var baselineHits = 0
        let baselineTime = MemoryCacheBenchFixture.measure {
            for index in 0..<operations {
                if baseline.object(forKey: names[index % names.count]) != nil {
                    baselineHits += 1
                }
            }
        }
        #expect(baselineHits == operations)

        MemoryCacheBenchFixture.report("memory_cache_get_hit", operations: operations, time: cacheTime, extra: "threshold_us=5")
        MemoryCacheBenchFixture.report("memory_cache_session_cache_request_hit", operations: operations, time: facadeTime, extra: "threshold_us=5")
        MemoryCacheBenchFixture.report(
            "memory_cache_nscache_get_baseline", operations: operations, time: baselineTime,
            extra: "ratio_vs_imagecache_cpu=\(MemoryCacheBenchFixture.ratio(cacheTime.cpu, baselineTime.cpu))")
    }

    @Test("subscript set 처리량")
    func subscriptSetThroughput() throws {
        let operations = 20000
        let fixture = try MemoryCacheBenchFixture(entryCount: 1000)
        let cache = fixture.cache
        let keys = fixture.requestKeys
        let content = fixture.content

        let insertTime = MemoryCacheBenchFixture.measure {
            for index in 0..<operations {
                cache[keys[index % keys.count]] = content
            }
        }
        #expect(cache.totalCount == keys.count)

        let evicting = MemoryCacheBenchFixture.makeCache()
        evicting.countLimit = 500
        let evictTime = MemoryCacheBenchFixture.measure {
            for index in 0..<operations {
                evicting[keys[index % keys.count]] = content
            }
        }
        #expect(evicting.totalCount == 500)

        let baseline = NSCache<NSString, UIImage>()
        let names = fixture.requests.map { $0.url!.absoluteString as NSString }
        let baselineTime = MemoryCacheBenchFixture.measure {
            for index in 0..<operations {
                baseline.setObject(content.image, forKey: names[index % names.count], cost: 400)
            }
        }

        MemoryCacheBenchFixture.report(
            "memory_cache_set_overwrite", operations: operations, time: insertTime, extra: "ops_per_s=\(MemoryCacheBenchFixture.throughput(operations, insertTime.wall))")
        MemoryCacheBenchFixture.report(
            "memory_cache_set_evicting_count500", operations: operations, time: evictTime, extra: "ops_per_s=\(MemoryCacheBenchFixture.throughput(operations, evictTime.wall))")
        MemoryCacheBenchFixture.report(
            "memory_cache_nscache_set_baseline", operations: operations, time: baselineTime,
            extra:
                "ops_per_s=\(MemoryCacheBenchFixture.throughput(operations, baselineTime.wall))|ratio_vs_imagecache_cpu=\(MemoryCacheBenchFixture.ratio(insertTime.cpu, baselineTime.cpu))"
        )
    }

    @Test("8개 스레드 동시 get 히트 처리량")
    func contendedGetHits() throws {
        let fixture = try MemoryCacheBenchFixture(entryCount: 1000)
        let cache = fixture.cache
        let keys = fixture.requestKeys
        for key in keys {
            cache[key] = fixture.content
        }
        let threadCount = 8
        let operationsPerThread = 20000
        let hits = Box(0)
        let time = MemoryCacheBenchFixture.measure {
            DispatchQueue.concurrentPerform(iterations: threadCount) { thread in
                var local = 0
                for index in 0..<operationsPerThread where cache[keys[(index + thread * 97) % keys.count]] != nil {
                    local += 1
                }
                hits.mutate { $0 += local }
            }
        }
        let operations = threadCount * operationsPerThread
        #expect(hits.value == operations)
        print(
            "BENCH|memory_cache_get_hit_8threads|ops=\(operations)|wall_ms=\(MemoryCacheBenchFixture.format(time.wall * 1000))|ops_per_s=\(MemoryCacheBenchFixture.throughput(operations, time.wall))"
        )
    }

    @Test("메모리 압박 처리 시간 (엔트리 5,000개)", arguments: [false, true])
    func memoryPressurePurgeTime(weakCacheEnabled: Bool) throws {
        let monitor = MemoryPressureMonitor(notificationCenter: NotificationCenter())
        let cache = MemoryCache(costLimit: 1 << 30, clock: SystemClock(), monitor: monitor)
        cache.isWeakCacheEnabled = weakCacheEnabled
        let entryCount = 5000
        let retainedCount = weakCacheEnabled ? 50 : 0
        var retained: [UIImage] = []
        for index in 0..<entryCount {
            let image = try MemoryCacheBenchFixture.makeImage(side: 16)
            if index < retainedCount {
                retained.append(image)
            }
            cache[MemoryCacheKey(key: "purge-\(index)")] = ImageContent(image: image)
        }
        #expect(cache.totalCount == entryCount)
        MemoryCache.releaseQueue.sync {}

        let isReading = Box(true)
        let readerStarted = DispatchSemaphore(value: 0)
        let latencies = Box<[Double]>([])
        let reader = DispatchGroup()
        DispatchQueue(label: "ImageLoaderTests.MemoryCacheBenchmarks", qos: .userInitiated).async(group: reader) {
            let probe = MemoryCacheKey(key: "absent")
            var local: [Double] = []
            local.reserveCapacity(100_000)
            readerStarted.signal()
            while isReading.value {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = cache[probe]
                local.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
            }
            latencies.value = local
        }
        readerStarted.wait()

        let handler = MemoryCacheBenchFixture.measure {
            monitor.deliver(systemEvent: .critical)
        }
        #expect(cache.totalCount == 0)
        let release = MemoryCacheBenchFixture.measure {
            MemoryCache.releaseQueue.sync {}
        }
        isReading.value = false
        reader.wait()
        #expect(cache.weakCacheCount == retainedCount)
        let sorted = latencies.value.sorted()
        let p99 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 99 / 100)]
        let maximum = sorted.last ?? 0
        if enforcesTimingBudgets {
            #expect(handler.cpu * 1000 <= 1)
        }
        let name = weakCacheEnabled ? "memory_cache_memory_pressure_purge_weak" : "memory_cache_memory_pressure_purge"
        print(
            "BENCH|\(name)|entries=\(entryCount)|handler_wall_ms=\(MemoryCacheBenchFixture.format(handler.wall * 1000))|handler_cpu_ms=\(MemoryCacheBenchFixture.format(handler.cpu * 1000))|release_queue_wall_ms=\(MemoryCacheBenchFixture.format(release.wall * 1000))|concurrent_get_p99_us=\(MemoryCacheBenchFixture.format(p99))|concurrent_get_max_us=\(MemoryCacheBenchFixture.format(maximum))|concurrent_gets=\(sorted.count)|threshold_ms=1"
        )
        withExtendedLifetime(retained) {}
    }
}

private struct MemoryCacheBenchFixture {
    struct Time {
        var wall: Double
        var cpu: Double
    }

    let cache: MemoryCache
    let requests: [ImageRequest]
    let requestKeys: [MemoryCacheKey]
    let content: ImageContent

    init(entryCount: Int) throws {
        cache = Self.makeCache()
        requests = (0..<entryCount).map { ImageRequest(url: Fixtures.url($0)) }
        requestKeys = requests.map(MemoryCacheKey.init(request:))
        content = ImageContent(image: try Self.makeImage(side: 10))
    }

    static func makeCache() -> MemoryCache {
        MemoryCache(costLimit: 1 << 30, clock: SystemClock(), monitor: MemoryPressureMonitor(notificationCenter: NotificationCenter()))
    }

    static func makeImage(side: Int) throws -> UIImage {
        let context = try #require(
            CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
        context.setFillColor(UIColor.systemPink.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return UIImage(cgImage: try #require(context.makeImage()))
    }

    static func measure(_ body: () -> Void) -> Time {
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        body()
        let cpuEnd = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let wallEnd = DispatchTime.now().uptimeNanoseconds
        return Time(wall: Double(wallEnd - wallStart) / 1_000_000_000, cpu: Double(cpuEnd - cpuStart) / 1_000_000_000)
    }

    static func report(_ name: String, operations: Int, time: Time, extra: String) {
        let wallMicros = time.wall * 1_000_000 / Double(operations)
        let cpuMicros = time.cpu * 1_000_000 / Double(operations)
        print("BENCH|\(name)|ops=\(operations)|avg_wall_us=\(format(wallMicros))|avg_cpu_us=\(format(cpuMicros))|\(extra)")
    }

    static func throughput(_ operations: Int, _ seconds: Double) -> String {
        guard seconds > 0 else {
            return "inf"
        }
        return String(Int(Double(operations) / seconds))
    }

    static func ratio(_ value: Double, _ baseline: Double) -> String {
        guard baseline > 0 else {
            return "inf"
        }
        return format(value / baseline)
    }

    static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
