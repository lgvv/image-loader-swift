import CoreGraphics
import Foundation
import ImageIO
@_spi(Testing) @testable import ImageLoader
import ImageLoaderTesting
import Testing
import UIKit

@Suite("애니메이션 소스와 프레임 캐시")
struct AnimatedImageTests {
    private static let gif200 = DecodingFixtures.gif(frameCount: 200, width: 64, height: 64, delay: 0.04)

    private func makeSource(
        _ data: Data,
        cache: AnimatedFrameCache = AnimatedFrameCache(costLimit: 16 * 1024 * 1024),
        thumbnail: ImageRequest.ThumbnailOptions? = nil,
        scale: CGFloat = 1
    ) throws -> AnimatedImageSource {
        try #require(AnimatedImageSource(data: data, scale: scale, thumbnail: thumbnail, frameCache: cache))
    }

    private func frameCost(_ source: AnimatedImageSource) -> Int {
        Bitmap.cost(of: source.cachedFrame(at: 0)!)
    }

    @Test("200프레임 GIF는 디코딩 직후 첫 프레임만 풀어 둠")
    func largeGIFDecodesLazily() throws {
        let cache = AnimatedFrameCache(costLimit: 16 * 1024 * 1024)
        var request = ImageRequest(url: Fixtures.url)
        request.scale = 2
        let context = DecodingFixtures.context(for: Self.gif200, request: request)
        let decoder = try #require(ImageDecoders.Animated(context: context, frameCache: cache))
        let content = try decoder.decode(Self.gif200)
        let source = try #require(content.animatedImageSource)
        #expect(source.frameCount == 200)
        #expect(source.decodeCount == 1)
        #expect(cache.count == 0)
        #expect(source.cachedFrame(at: 1) == nil)
        #expect(source.cachedFrame(at: 0) === content.image.cgImage)
        #expect(source.scale == 2)
        #expect(content.image.scale == 2)
        #expect(content.image.size == CGSize(width: 32, height: 32))
        #expect(source.dataByteCount == Self.gif200.count)
        #expect(source.memoryCost == Bitmap.cost(of: source.firstFrame) + Self.gif200.count)

        let frame = try #require(source.decodeFrame(at: 150))
        #expect(source.decodeCount == 2)
        #expect(cache.count == 1)
        #expect(DecodingFixtures.isClose(DecodingFixtures.centerColor(of: frame), DecodingFixtures.color(for: 150)))
        #expect(source.cachedFrame(at: 150) === frame)
        #expect(source.cachedFrame(at: 350) === frame)
        #expect(source.cachedFrame(at: -50) === frame)
    }

    @Test("loopCount는 컨테이너 값을 쓰고 0은 무한")
    func loopCountComesFromContainer() throws {
        #expect(try makeSource(DecodingFixtures.gif(frameCount: 3, loopCount: 3)).loopCount == 3)
        #expect(try makeSource(DecodingFixtures.gif(frameCount: 3, loopCount: 0)).loopCount == 0)
        #expect(try makeSource(DecodingFixtures.gif(frameCount: 3, loopCount: nil)).loopCount == 1)
        #expect(try makeSource(DecodingFixtures.apng(frameCount: 3, loopCount: 2)).loopCount == 2)
        #expect(try makeSource(DecodingFixtures.apng(frameCount: 3, loopCount: 0)).loopCount == 0)
        #expect(try makeSource(DecodingFixtures.webp(frameCount: 3, loopCount: 4)).loopCount == 4)
        #expect(try makeSource(DecodingFixtures.webp(frameCount: 3, loopCount: 0)).loopCount == 0)
    }

    @Test("10ms 이하 지연은 100ms로 정규화하고 나머지는 그대로")
    func frameDurationsAreNormalized() throws {
        let source = try makeSource(DecodingFixtures.gif(delays: [0, 0.01, 0.02, 0.05, 0.5]))
        #expect(source.frameDurations == [0.1, 0.1, 0.02, 0.05, 0.5])
        #expect(abs(source.totalDuration - 0.77) < 0.000_1)
        #expect(source.frameDuration(at: 5) == 0.1)
        #expect(source.frameDuration(at: -1) == 0.5)

        let apng = try makeSource(DecodingFixtures.apng(frameCount: 3, delay: 0.04))
        #expect(apng.frameDurations.allSatisfy { abs($0 - 0.04) < 0.000_1 })
        #expect(try makeSource(DecodingFixtures.webp(frameCount: 3, durationMilliseconds: 10)).frameDurations == [0.1, 0.1, 0.1])
        #expect(try makeSource(DecodingFixtures.webp(frameCount: 3, durationMilliseconds: 70)).frameDurations.allSatisfy { abs($0 - 0.07) < 0.000_1 })

        #expect(AnimatedImageMetadata.normalizedDuration(nil) == 0.1)
        #expect(AnimatedImageMetadata.normalizedDuration(.nan) == 0.1)
        #expect(AnimatedImageMetadata.normalizedDuration(-1) == 0.1)
        #expect(AnimatedImageMetadata.normalizedDuration(Double(Float(0.01))) == 0.1)
        #expect(AnimatedImageMetadata.normalizedDuration(0.011) == 0.011)
        #expect(AnimatedImageMetadata.normalizedDuration(Double(Float(0.011))) == Double(Float(0.011)))
        #expect(try makeSource(DecodingFixtures.webp(frameCount: 3, durationMilliseconds: 11)).frameDurations.allSatisfy { abs($0 - 0.011) < 0.000_1 })
    }

    @Test("프레임 내용이 인덱스와 일치 (GIF, APNG, WebP)")
    func framesMatchTheirIndex() throws {
        let fixtures: [(String, Data, Int)] = [
            ("gif", DecodingFixtures.gif(frameCount: 8), 8),
            ("apng", DecodingFixtures.apng(frameCount: 6), 6),
            ("webp", DecodingFixtures.webp(frameCount: 5), 5),
        ]
        for (name, data, frameCount) in fixtures {
            let source = try makeSource(data)
            #expect(source.frameCount == frameCount, "\(name)")
            for index in 0..<frameCount {
                let frame = try #require(source.decodeFrame(at: index), "\(name) \(index)")
                let color = DecodingFixtures.centerColor(of: frame)
                #expect(DecodingFixtures.isClose(color, DecodingFixtures.color(for: index)), "\(name) frame \(index): \(color)")
            }
        }
    }

    @Test("썸네일은 모든 프레임에 적용")
    func thumbnailAppliesToEveryFrame() throws {
        let gif = DecodingFixtures.gif(frameCount: 6, width: 40, height: 40)
        let fixed = try makeSource(gif, thumbnail: .init(maxPixelSize: 20))
        #expect(fixed.cachedFrame(at: 0).map { CGSize(width: $0.width, height: $0.height) } == CGSize(width: 20, height: 20))
        let frame = try #require(fixed.decodeFrame(at: 3))
        #expect(CGSize(width: frame.width, height: frame.height) == CGSize(width: 20, height: 20))
        #expect(DecodingFixtures.isClose(DecodingFixtures.centerColor(of: frame), DecodingFixtures.color(for: 3)))

        let limited = try makeSource(gif, thumbnail: .init(maximumPixelCount: 400))
        #expect(limited.decodeFrame(at: 2).map { CGSize(width: $0.width, height: $0.height) } == CGSize(width: 20, height: 20))

        let untouched = try makeSource(gif, thumbnail: .init(maximumPixelCount: 10_000))
        #expect(untouched.decodeFrame(at: 2).map { CGSize(width: $0.width, height: $0.height) } == CGSize(width: 40, height: 40))

        var noCache = ImageRequest.ThumbnailOptions(maxPixelSize: 10)
        noCache.shouldCacheImmediately = false
        let redrawn = try makeSource(gif, thumbnail: noCache)
        #expect(redrawn.decodeFrame(at: 4).map { CGSize(width: $0.width, height: $0.height) } == CGSize(width: 10, height: 10))
    }

    @Test("프레임 캐시는 예산을 넘지 않음: totalCost <= 한도 + 한 프레임")
    func frameCacheStaysWithinBudget() throws {
        let probe = try makeSource(DecodingFixtures.gif(frameCount: 2))
        let cost = frameCost(probe)
        let cache = AnimatedFrameCache(costLimit: cost * 10)
        let source = try makeSource(DecodingFixtures.gif(frameCount: 60), cache: cache)
        var maximumCost = 0
        for loop in 0..<2 {
            for index in 0..<source.frameCount {
                let frame = source.decodeFrame(at: index)
                #expect(frame != nil, "loop \(loop) frame \(index)")
                maximumCost = max(maximumCost, cache.totalCost)
                #expect(cache.totalCost <= cache.costLimit + cost)
            }
        }
        #expect(maximumCost > cost * 5)
        #expect(cache.count <= 10)
    }

    @Test("프레임 캐시 LRU: 90%까지 축출, 방금 넣은 프레임은 보존, 한도 변경과 메모리 경고")
    func frameCacheEvictionPolicy() throws {
        let frame = DecodingFixtures.frame(index: 0, width: 10, height: 10)
        let cost = Bitmap.cost(of: frame)
        let center = NotificationCenter()
        let cache = AnimatedFrameCache(costLimit: cost * 10, notificationCenter: center)
        let key = { (index: Int) in AnimatedFrameKey(sourceID: 7, index: index) }
        for index in 0..<10 {
            cache.insert(frame, for: key(index))
        }
        #expect(cache.count == 10)
        #expect(cache.totalCost == cost * 10)
        _ = cache.frame(for: key(0))
        cache.insert(frame, for: key(10))
        #expect(cache.count == 9)
        #expect(cache.contains(key(0)))
        #expect(!cache.contains(key(1)))
        #expect(!cache.contains(key(2)))
        #expect(cache.contains(key(10)))

        cache.insert(frame, for: key(10))
        #expect(cache.count == 9)
        #expect(cache.totalCost == cost * 9)

        cache.costLimit = cost * 3
        #expect(cache.totalCost <= cost * 3 - cost * 3 / 10)
        #expect(cache.contains(key(10)))

        let tiny = AnimatedFrameCache(costLimit: cost / 2, notificationCenter: center)
        tiny.insert(frame, for: key(1))
        #expect(tiny.count == 1)
        tiny.insert(frame, for: key(2))
        #expect(tiny.count == 1)
        #expect(tiny.contains(key(2)))

        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #expect(cache.count == 0)
        #expect(cache.totalCost == 0)
        #expect(tiny.count == 0)

        cache.insert(frame, for: key(3))
        cache.removeAll()
        #expect(cache.count == 0)
        #expect(cache.totalCost == 0)
        #expect(AnimatedFrameCache.shared.costLimit == 32 * 1024 * 1024)
    }

    @Test("여러 곳에서 같은 프레임을 동시에 요청해도 디코딩은 한 번")
    func concurrentRequestsShareOneDecode() async throws {
        let source = try makeSource(DecodingFixtures.gif(frameCount: 10))
        let frames = Box<[CGImage]>([])
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            if let frame = source.decodeFrame(at: 3) {
                frames.mutate { $0.append(frame) }
            }
        }
        #expect(source.decodeCount == 2)
        #expect(frames.value.count == 16)
        #expect(frames.value.allSatisfy { $0 === frames.value[0] })

        let results = await withTaskGroup(of: CGImage?.self) { group in
            for _ in 0..<8 {
                group.addTask { await source.frame(at: 4) }
            }
            var results: [CGImage?] = []
            for await frame in group {
                results.append(frame)
            }
            return results
        }
        #expect(results.allSatisfy { $0 != nil && $0 === results[0] })
        #expect(source.decodeCount == 3)
    }

    @Test("프레임 디코딩은 락 밖에서 함: 디코딩이 멈춰 있어도 다른 프레임과 다른 소스는 바로 진행하고, 같은 프레임 요청은 결과를 기다려 공유")
    func decodingRunsOutsideLocks() async throws {
        let cache = AnimatedFrameCache(costLimit: 16 * 1024 * 1024)
        let source = try makeSource(DecodingFixtures.gif(frameCount: 10), cache: cache)
        let gate = DispatchSemaphore(value: 0)
        let blocked = Box(false)
        source.setWillDecodeFrameHandler { index in
            guard index == 1 else {
                return
            }
            blocked.value = true
            gate.wait()
        }
        let first = Box<CGImage?>(nil)
        let second = Box<CGImage?>(nil)
        let finished = Box(0)
        DispatchQueue(label: "ImageLoaderTests.AnimatedImageTests", qos: .userInitiated).async {
            first.value = source.decodeFrame(at: 1)
            finished.mutate { $0 += 1 }
        }
        #expect(await waitUntil { blocked.value })
        #expect(source.inFlightFrameCount == 1)

        let other = source.decodeFrame(at: 2)
        #expect(other != nil)
        #expect(source.cachedFrame(at: 2) === other)
        #expect(source.cachedFrame(at: 1) == nil)
        #expect(source.isFrameFailed(at: 1) == false)
        source.prefetchFrames([1])
        let unrelated = try makeSource(DecodingFixtures.gif(frameCount: 4), cache: cache)
        #expect(unrelated.decodeFrame(at: 2) != nil)
        #expect(cache.count == 2)

        DispatchQueue(label: "ImageLoaderTests.AnimatedImageTests", qos: .userInitiated).async {
            second.value = source.decodeFrame(at: 1)
            finished.mutate { $0 += 1 }
        }
        #expect(await waitUntil { source.sharedDecodeWaitCount == 1 })
        #expect(finished.value == 0)
        gate.signal()
        #expect(await waitUntil { finished.value == 2 })
        #expect(first.value != nil)
        #expect(first.value === second.value)
        #expect(source.decodeCount == 1 + 2)
        #expect(source.inFlightFrameCount == 0)
        source.setWillDecodeFrameHandler(nil)
    }

    private func playLoops(
        _ data: Data,
        loops: Int,
        cacheFrames: Int,
        policy: AnimatedFrameCache.EvictionPolicy
    ) throws -> (hitsAfterFirstLoop: Int, maximumCost: Int, frameCost: Int, decodeCount: Int) {
        let cost = frameCost(try makeSource(data))
        let cache = AnimatedFrameCache(costLimit: cost * cacheFrames, notificationCenter: NotificationCenter(), policy: policy)
        let source = try makeSource(data, cache: cache)
        var hits = 0
        var maximumCost = 0
        for loop in 0..<loops {
            for index in 1..<source.frameCount {
                if source.cachedFrame(at: index) != nil {
                    hits += loop > 0 ? 1 : 0
                } else {
                    _ = source.decodeFrame(at: index)
                }
                maximumCost = max(maximumCost, cache.totalCost)
            }
        }
        return (hits, maximumCost, cost, source.decodeCount)
    }

    @Test("예산보다 큰 애니메이션은 자기 프레임만 밀어내 앞쪽 프레임을 유지함 (순수 LRU는 두 번째 바퀴부터 적중 0)")
    func oversizedSourceKeepsStableWindow() throws {
        let gif = DecodingFixtures.gif(frameCount: 40)
        let window = try playLoops(gif, loops: 3, cacheFrames: 10, policy: .windowForOversizedSources)
        let lru = try playLoops(gif, loops: 3, cacheFrames: 10, policy: .leastRecentlyUsed)
        #expect(lru.hitsAfterFirstLoop == 0)
        #expect(window.hitsAfterFirstLoop >= 14)
        #expect(window.decodeCount < lru.decodeCount)
        #expect(window.maximumCost <= window.frameCost * 10 + window.frameCost)
        #expect(lru.maximumCost <= lru.frameCost * 10 + lru.frameCost)
        print(
            "BENCH|animation|oversized_40_frames_cache_10|window_hits=\(window.hitsAfterFirstLoop)|lru_hits=\(lru.hitsAfterFirstLoop)|window_decodes=\(window.decodeCount)|lru_decodes=\(lru.decodeCount)"
        )

        let fitting = try playLoops(DecodingFixtures.gif(frameCount: 8), loops: 3, cacheFrames: 10, policy: .windowForOversizedSources)
        #expect(fitting.hitsAfterFirstLoop == 2 * 7)
        #expect(fitting.decodeCount == 8)
    }

    @Test("예산보다 큰 애니메이션은 다른 소스의 프레임을 밀어내지 않음")
    func oversizedSourceDoesNotEvictOtherSources() throws {
        for policy in [AnimatedFrameCache.EvictionPolicy.windowForOversizedSources, .leastRecentlyUsed] {
            let small = DecodingFixtures.gif(frameCount: 3)
            let cost = frameCost(try makeSource(small))
            let cache = AnimatedFrameCache(costLimit: cost * 10, notificationCenter: NotificationCenter(), policy: policy)
            let smallSource = try makeSource(small, cache: cache)
            #expect(smallSource.decodeFrame(at: 1) != nil)
            #expect(smallSource.decodeFrame(at: 2) != nil)
            let large = try makeSource(DecodingFixtures.gif(frameCount: 40), cache: cache)
            for _ in 0..<2 {
                for index in 1..<large.frameCount {
                    _ = large.cachedFrame(at: index) ?? large.decodeFrame(at: index)
                }
            }
            let kept = smallSource.hasCachedFrame(at: 1) && smallSource.hasCachedFrame(at: 2)
            #expect(kept == (policy == .windowForOversizedSources), "\(policy)")
            #expect(cache.totalCost <= cost * 11)
        }
    }

    @Test("자기 프레임을 밀어낼 때 기준은 재생 위치: 미리 디코딩한 다음 프레임은 남기고 지나간 프레임부터 뺌")
    func windowEvictionKeepsLookaheadFrames() throws {
        let gif = DecodingFixtures.gif(frameCount: 40)
        let cost = frameCost(try makeSource(gif))
        let cache = AnimatedFrameCache(costLimit: cost * 10, notificationCenter: NotificationCenter(), policy: .windowForOversizedSources)
        let source = try makeSource(gif, cache: cache)
        var displayMisses = 0
        var lookaheadLost = 0
        for tick in 0..<120 {
            if source.cachedFrame(at: tick) == nil {
                displayMisses += 1
                _ = source.decodeFrame(at: tick)
            }
            for ahead in 1...3 where !source.hasCachedFrame(at: tick + ahead) {
                _ = source.decodeFrame(at: tick + ahead)
            }
            lookaheadLost += (1...3).filter { !source.hasCachedFrame(at: tick + $0) }.count
        }
        #expect(lookaheadLost == 0)
        #expect(displayMisses == 0)
        #expect(cache.totalCost <= cost * 11)
    }

    @Test("소스 해제 시 그 소스에 실제로 캐시된 프레임만 지우고 다른 소스는 그대로 둠")
    func removeFramesTouchesOnlyCachedFramesOfSource() {
        let frame = DecodingFixtures.frame(index: 0, width: 4, height: 4)
        let cost = Bitmap.cost(of: frame)
        let cache = AnimatedFrameCache(costLimit: cost * 10_000, notificationCenter: NotificationCenter())
        for sourceID in UInt64(1)...300 {
            for index in [1, 5, 1_000_000] {
                cache.insert(frame, for: AnimatedFrameKey(sourceID: sourceID, index: index))
            }
        }
        #expect(cache.count == 900)
        cache.removeFrames(of: 7)
        #expect(cache.count == 897)
        #expect(cache.totalCost == cost * 897)
        #expect(cache.cachedFrameCount(of: 7) == 0)
        #expect(cache.cachedFrameCount(of: 8) == 3)
        #expect(cache.contains(AnimatedFrameKey(sourceID: 8, index: 1_000_000)))
        cache.removeFrames(of: 9_999)
        #expect(cache.count == 897)
        cache.costLimit = cost * 3
        #expect(cache.totalCost <= cost * 3)
        #expect(cache.count == cache.totalCost / cost)
    }

    @Test("prefetch는 비동기로 채우고 이미 있거나 진행 중인 프레임은 다시 디코딩하지 않음")
    func prefetchFillsCacheWithoutDuplicates() async throws {
        let source = try makeSource(DecodingFixtures.gif(frameCount: 10))
        source.prefetchFrames([1, 2, 3, 2, 1, 0, 13])
        source.prefetchFrames([1, 2, 3])
        #expect(await waitUntil { (1...3).allSatisfy { source.cachedFrame(at: $0) != nil } })
        #expect(await waitUntil { source.decodeCount == 4 })
        source.prefetchFrames([1, 2, 3, 0])
        #expect(source.decodeCount == 4)
        let frame = await source.frame(at: 2)
        #expect(frame != nil)
        #expect(source.decodeCount == 4)
    }

    @Test("깨진 프레임은 1회만 재시도하고 이후에는 디코딩하지 않음")
    func failedFrameIsRetriedAtMostOnce() async throws {
        let cache = AnimatedFrameCache(costLimit: 16 * 1024 * 1024)
        let source = try makeSource(DecodingFixtures.gif(frameCount: 10), cache: cache)
        source.simulateDecodeFailures(at: [5])
        #expect(source.frameCount == 10)
        #expect(source.decodeFrame(at: 5) == nil)
        #expect(source.decodeCount == 2)
        #expect(source.isFrameFailed(at: 5) == false)
        #expect(source.decodeFrame(at: 5) == nil)
        #expect(source.decodeCount == 3)
        #expect(source.isFrameFailed(at: 5))
        #expect(source.isFrameFailed(at: 15))
        #expect(source.decodeFrame(at: 5) == nil)
        #expect(await source.frame(at: 5) == nil)
        source.prefetchFrames([5])
        #expect(source.decodeCount == 3)

        for _ in 0..<20 {
            for index in 0..<source.frameCount {
                _ = source.cachedFrame(at: index) ?? source.decodeFrame(at: index)
            }
        }
        #expect(source.decodeCount == 1 + 8 + 2)
        #expect(source.failedFrameCount == 1)
        #expect(source.canAnimate)
    }

    @Test("모든 프레임이 깨지면 canAnimate가 false")
    func allFramesFailedStopsAnimation() throws {
        let source = try makeSource(DecodingFixtures.gif(frameCount: 6))
        source.simulateDecodeFailures(at: Set(1..<6))
        #expect(source.canAnimate)
        for _ in 0..<3 {
            for index in 0..<source.frameCount {
                _ = source.decodeFrame(at: index)
            }
        }
        #expect(source.failedFrameCount == 5)
        #expect(source.canAnimate == false)
        #expect(source.decodeCount == 1 + 5 * 2)
        #expect(source.cachedFrame(at: 0) != nil)
    }

    @Test("잘린 GIF는 온전한 프레임만 노출하고 첫 프레임조차 없으면 nil")
    func truncatedGIFExposesCompleteFrames() throws {
        let gif = DecodingFixtures.gif(frameCount: 50)
        let truncated = gif.prefix(gif.count * 6 / 10)
        let source = try makeSource(Data(truncated))
        #expect(source.frameCount > 1)
        #expect(source.frameCount < 50)
        for index in 0..<source.frameCount {
            #expect(source.decodeFrame(at: index) != nil, "frame \(index)")
        }
        #expect(source.failedFrameCount == 0)
        let offsets = DecodingFixtures.gifFrameDescriptorOffsets(gif)
        #expect(AnimatedImageSource(data: Data(gif.prefix(offsets[1])), scale: 1, thumbnail: nil) == nil)
        #expect(AnimatedImageSource(data: Data(gif.prefix(40)), scale: 1, thumbnail: nil) == nil)
    }

    @Test("소스가 해제되면 프레임 캐시에서 프레임이 빠짐 (메인 밖 해제 포함)")
    func deinitRemovesFramesFromCache() async throws {
        let cache = AnimatedFrameCache(costLimit: 16 * 1024 * 1024)
        weak var weakSource: AnimatedImageSource?
        do {
            let source = try makeSource(DecodingFixtures.gif(frameCount: 8), cache: cache)
            weakSource = source
            for index in 1...5 {
                _ = source.decodeFrame(at: index)
            }
            #expect(cache.count == 5)
        }
        #expect(weakSource == nil)
        SessionWorkers.release.sync {}
        #expect(cache.count == 0)
        #expect(cache.totalCost == 0)

        let released = Box(false)
        let other = Box<AnimatedImageSource?>(try makeSource(DecodingFixtures.gif(frameCount: 8), cache: cache))
        other.value?.prefetchFrames(Array(1..<8))
        DispatchQueue(label: "ImageLoaderTests.AnimatedImageTests", qos: .userInitiated).async {
            other.value = nil
            released.value = true
        }
        #expect(await waitUntil { released.value })
        #expect(await waitUntil { cache.count == 0 })
    }

    @Test("소스 해제는 프레임 캐시 정리를 해제 큐로 넘겨, 잎 락 안에서 마지막 참조가 풀려도 다른 잎 락을 잡지 않음", .enabled(if: LockOrder.isChecking))
    func deinitHandsFrameCleanupToReleaseQueue() throws {
        let cache = AnimatedFrameCache(costLimit: 16 * 1024 * 1024, notificationCenter: NotificationCenter())
        let holder = LockIsolated<AnimatedImageSource?>(nil)
        weak var weakSource: AnimatedImageSource?
        let sourceID: UInt64
        do {
            let source = try makeSource(DecodingFixtures.gif(frameCount: 8), cache: cache)
            for index in 1...5 {
                _ = source.decodeFrame(at: index)
            }
            sourceID = source.sourceID
            weakSource = source
            holder.withLock { $0 = source }
        }
        #expect(cache.cachedFrameCount(of: sourceID) == 5)
        #expect(weakSource != nil)

        let gate = DispatchSemaphore(value: 0)
        SessionWorkers.release.async {
            gate.wait()
        }
        let nestedBefore = LockOrder.nestedLeafAcquisitions
        holder.withLock { $0 = nil }
        let nestedAfter = LockOrder.nestedLeafAcquisitions
        #expect(weakSource == nil)
        #expect(nestedAfter == nestedBefore)
        #expect(cache.cachedFrameCount(of: sourceID) == 5)
        gate.signal()
        SessionWorkers.release.sync {}
        #expect(cache.cachedFrameCount(of: sourceID) == 0)
        #expect(cache.count == 0)
    }

    @Test("프레임 캐시를 여러 스레드가 계속 쓰는 중에 소스가 여러 스레드와 잎 락 안에서 해제돼도 멈추지 않고, 정리는 해제 큐에서만 일어나 프레임 캐시 잎 락이 중첩되지 않음")
    func deinitDuringHeavyCacheAccessDoesNotDeadlock() async throws {
        let cache = AnimatedFrameCache(costLimit: 64 * 1024 * 1024, notificationCenter: NotificationCenter())
        let gif = DecodingFixtures.gif(frameCount: 6)
        let filler = DecodingFixtures.frame(index: 0, width: 4, height: 4)
        let gate = DispatchSemaphore(value: 0)
        let gateOpened = Box(false)
        let openGate: @Sendable () -> Void = {
            if gateOpened.mutate({ opened in
                defer { opened = true }
                return !opened
            }) {
                gate.signal()
            }
        }
        defer { openGate() }
        SessionWorkers.release.async {
            gate.wait()
        }

        let stoppedWorkers = Box(0)
        let workerCount = 3
        for worker in 0..<workerCount {
            DispatchQueue(label: "ImageLoaderTests.AnimatedImageTests", qos: .default).async {
                for round in 0..<4_000 {
                    let key = AnimatedFrameKey(sourceID: UInt64.max - UInt64(worker), index: round % 32)
                    cache.insert(filler, for: key)
                    _ = cache.frame(for: key)
                    _ = cache.contains(key)
                    _ = cache.totalCost
                    if round % 64 == 0 {
                        cache.removeFrames(of: key.sourceID)
                    }
                }
                stoppedWorkers.mutate { $0 += 1 }
            }
        }

        let sourceCount = 24
        let weakSources = (0..<sourceCount).map { _ in WeakAnimatedSourceRef() }
        var sourceIDs: [UInt64] = []
        for round in 0..<sourceCount {
            let source = try makeSource(gif, cache: cache)
            sourceIDs.append(source.sourceID)
            weakSources[round].set(source)
            for index in 1..<4 {
                _ = source.decodeFrame(at: index)
            }
            source.prefetchFrames([4, 5])
            switch round % 4 {
            case 0:
                let box = Box<AnimatedImageSource?>(source)
                DispatchQueue(label: "ImageLoaderTests.AnimatedImageTests", qos: .userInitiated).async {
                    box.value = nil
                }
            case 1:
                DispatchQueue(label: "ImageLoaderTests.AnimatedImageTests", qos: .userInitiated).async { [source] in
                    _ = source.frameCount
                }
            case 2:
                let holder = LockIsolated<AnimatedImageSource?>(source)
                DispatchQueue(label: "ImageLoaderTests.AnimatedImageTests", qos: .userInitiated).async {
                    holder.withLock { $0 = nil }
                }
            default:
                Task.detached { [source] in
                    _ = await source.frame(at: 5)
                }
            }
        }

        #expect(await waitUntil(timeout: 10) { weakSources.allSatisfy { $0.isReleased } })
        let ids = sourceIDs
        #expect(ids.allSatisfy { cache.cachedFrameCount(of: $0) > 0 })
        #expect(cache.leafLockNestingCount == 0)
        openGate()
        #expect(await waitUntil(timeout: 10) { stoppedWorkers.value == workerCount })
        #expect(
            await waitUntil(timeout: 10) {
                SessionWorkers.release.sync {}
                return ids.allSatisfy { cache.cachedFrameCount(of: $0) == 0 }
            })
        #expect(cache.leafLockNestingCount == 0)
    }

    @Test("디코딩은 잎 락 밖에서, 디코딩 락 안에서는 잎 락을 잡지 않음: 동기, 비동기, prefetch 요청이 섞여도 프레임마다 디코딩 1회", .enabled(if: LockOrder.isChecking))
    func frameDecodeDoesNotNestLeafLocks() async throws {
        let outer = LockIsolated(0)
        let inner = LockIsolated(0)
        let depthInsideLeaf = outer.withLock { _ in LockOrder.leafDepth }
        let nestedBefore = LockOrder.nestedLeafAcquisitions
        outer.withLock { _ in
            inner.withLock { _ in }
        }
        #expect(depthInsideLeaf == 1)
        #expect(LockOrder.nestedLeafAcquisitions == nestedBefore + 1)
        #expect(LockOrder.leafDepth == 0)
        let observed = AnimatedFrameDecodeLock().withLock { (decode: LockOrder.decodeLockDepth, leaf: LockOrder.leafDepth) }
        #expect(observed.decode == 1)
        #expect(observed.leaf == 0)
        #expect(LockOrder.decodeLockDepth == 0)

        let crossOuter = LockIsolated(0)
        let crossInner = LockIsolated(0)
        let crossThreadDone = Box(false)
        DispatchQueue(label: "ImageLoaderTests.AnimatedImageTests", qos: .userInitiated).async {
            crossOuter.withLock { _ in
                crossInner.withLock { _ in }
            }
            crossInner.withLock { _ in }
            crossThreadDone.value = true
        }
        #expect(await waitUntil { crossThreadDone.value })
        #expect(crossOuter.nestedAcquisitionCount == 1)
        #expect(crossInner.nestedAcquisitionCount == 1)

        let cache = AnimatedFrameCache(costLimit: 64 * 1024 * 1024, notificationCenter: NotificationCenter())
        let source = try makeSource(DecodingFixtures.gif(frameCount: 12), cache: cache)
        let targets = Array(1...6)
        DispatchQueue.concurrentPerform(iterations: 48) { iteration in
            let index = targets[iteration % targets.count]
            switch iteration % 3 {
            case 0:
                _ = source.decodeFrame(at: index)
            case 1:
                source.prefetchFrames([index, targets[(iteration + 1) % targets.count]])
            default:
                _ = source.cachedFrame(at: index)
                _ = cache.totalCost
            }
        }
        let frames = await withTaskGroup(of: CGImage?.self) { group in
            for iteration in 0..<24 {
                group.addTask { await source.frame(at: targets[iteration % targets.count]) }
            }
            var frames: [CGImage?] = []
            for await frame in group {
                frames.append(frame)
            }
            return frames
        }
        #expect(frames.allSatisfy { $0 != nil })
        #expect(await waitUntil { targets.allSatisfy { source.hasCachedFrame(at: $0) } && source.inFlightFrameCount == 0 })
        #expect(source.decodeCount == 1 + targets.count)
        #expect(source.hasCachedFrame(at: 7) == false)
        #expect(source.leafLockNestingCount == 0)
        #expect(cache.leafLockNestingCount == 0)
        #expect(LockOrder.leafDepth == 0)
        #expect(LockOrder.decodeLockDepth == 0)
    }

    @Test("frame(at:)은 같은 프레임 디코딩을 기다리는 동안 스레드를 막지 않아, 같은 소스의 다른 프레임 요청이 먼저 끝남")
    func asyncFrameRequestDoesNotBlockWhileSharingDecode() async throws {
        let source = try makeSource(DecodingFixtures.gif(frameCount: 10))
        let gate = DispatchSemaphore(value: 0)
        let blocked = Box(false)
        source.setWillDecodeFrameHandler { index in
            guard index == 1 else {
                return
            }
            blocked.value = true
            gate.wait()
        }
        let first = Box<CGImage?>(nil)
        let shared = Box<CGImage?>(nil)
        let other = Box<CGImage?>(nil)
        let finished = Box(0)
        DispatchQueue(label: "ImageLoaderTests.AnimatedImageTests", qos: .userInitiated).async {
            first.value = source.decodeFrame(at: 1)
            finished.mutate { $0 += 1 }
        }
        #expect(await waitUntil { blocked.value })
        let sharedTask = Task.detached {
            shared.value = await source.frame(at: 1)
            finished.mutate { $0 += 1 }
        }
        #expect(await waitUntil { source.sharedDecodeWaitCount == 1 })
        let otherTask = Task.detached {
            other.value = await source.frame(at: 2)
        }
        #expect(await waitUntil { other.value != nil })
        #expect(finished.value == 0)
        gate.signal()
        #expect(await waitUntil { finished.value == 2 })
        _ = await sharedTask.value
        _ = await otherTask.value
        #expect(first.value != nil)
        #expect(first.value === shared.value)
        #expect(source.decodeCount == 1 + 2)
        #expect(source.inFlightFrameCount == 0)
        source.setWillDecodeFrameHandler(nil)
    }

    @Test("파이프라인: GIF 응답은 애니메이션 소스와 원본 data를 담고 메모리 캐시에서도 같은 소스")
    func sessionReturnsAnimatedContainer() async throws {
        let gif = DecodingFixtures.gif(frameCount: 6)
        let loader = MockDataLoader(defaultResponse: .data(gif))
        let session = makeSession(loader: loader)
        let response = try await session.imageTask(with: Fixtures.url(10)).response
        let source = try #require(response.content.animatedImageSource)
        #expect(response.content.type == .gif)
        #expect(response.content.data == gif)
        #expect(source.frameCount == 6)
        let cached = try await session.imageTask(with: Fixtures.url(10)).response
        #expect(cached.cacheType == .memory)
        #expect(cached.content.animatedImageSource === source)
        #expect(loader.counts.started == 1)
    }

    @Test("파이프라인: 동시 요청 5개는 하나의 소스를 공유")
    func sessionSharesSourceAcrossCoalescedRequests() async throws {
        let loader = MockDataLoader(defaultResponse: .data(DecodingFixtures.gif(frameCount: 6)))
        loader.isSuspended = true
        let session = makeSession(loader: loader)
        let tasks = (0..<5).map { _ in session.imageTask(with: Fixtures.url(11)) }
        #expect(await waitUntil { loader.counts.started == 1 })
        loader.isSuspended = false
        var sources: [AnimatedImageSource] = []
        for task in tasks {
            sources.append(try #require(try await task.response.content.animatedImageSource))
        }
        #expect(sources.allSatisfy { $0 === sources[0] })
        let shared = sources
        DispatchQueue.concurrentPerform(iterations: 5) { index in
            _ = shared[index].decodeFrame(at: 2)
        }
        #expect(sources[0].decodeCount == 2)
    }

    @Test("파이프라인: 프로세서가 있으면 정적 결과로 만들고 data와 소스를 뺌")
    func sessionProcessorProducesStaticImage() async throws {
        let gif = DecodingFixtures.gif(frameCount: 6)
        let loader = MockDataLoader(defaultResponse: .data(gif))
        let session = makeSession(loader: loader)
        let request = ImageRequest(url: Fixtures.url(12), filters: [TintFilter(name: "animated")])
        let response = try await session.imageTask(with: request).response
        #expect(response.content.animatedImageSource == nil)
        #expect(response.content.data == nil)
        #expect(response.image.size == CGSize(width: 40, height: 40))
    }

    @Test("파이프라인: 썸네일 요청은 모든 프레임에 적용")
    func sessionThumbnailAppliesToFrames() async throws {
        let loader = MockDataLoader(defaultResponse: .data(DecodingFixtures.gif(frameCount: 6)))
        let session = makeSession(loader: loader)
        var request = ImageRequest(url: Fixtures.url(13))
        request.thumbnail = .init(maxPixelSize: 20)
        let response = try await session.imageTask(with: request).response
        let source = try #require(response.content.animatedImageSource)
        #expect(DecodingFixtures.displaySize(of: response.image) == CGSize(width: 20, height: 20))
        let frame = try #require(await source.frame(at: 4))
        #expect(CGSize(width: frame.width, height: frame.height) == CGSize(width: 20, height: 20))
    }

    @Test("파이프라인: APNG와 WebP에도 data를 붙이고 정적 GIF는 소스 없이 data만")
    func sessionAttachesDataForAllAnimatedFormats() async throws {
        let apng = DecodingFixtures.apng(frameCount: 4)
        let webp = DecodingFixtures.webp(frameCount: 4)
        let staticGIF = DecodingFixtures.gif(frameCount: 1)
        let loader = MockDataLoader()
        loader.setResponse(.data(apng), for: Fixtures.url(14))
        loader.setResponse(.data(webp), for: Fixtures.url(15))
        loader.setResponse(.data(staticGIF), for: Fixtures.url(16))
        let session = makeSession(loader: loader)

        let apngResponse = try await session.imageTask(with: Fixtures.url(14)).response
        #expect(apngResponse.content.type == .png)
        #expect(apngResponse.content.data == apng)
        #expect(apngResponse.content.animatedImageSource?.frameCount == 4)

        let webpResponse = try await session.imageTask(with: Fixtures.url(15)).response
        #expect(webpResponse.content.type == .webp)
        #expect(webpResponse.content.data == webp)
        #expect(webpResponse.content.animatedImageSource?.frameCount == 4)

        let gifResponse = try await session.imageTask(with: Fixtures.url(16)).response
        #expect(gifResponse.content.type == .gif)
        #expect(gifResponse.content.data == staticGIF)
        #expect(gifResponse.content.animatedImageSource == nil)
    }
}

private final class WeakAnimatedSourceRef: Sendable {
    private let reference = LockIsolated(WeakAnimatedSourceBox())

    func set(_ source: AnimatedImageSource) {
        reference.withLock { $0.source = source }
    }

    var isReleased: Bool {
        reference.withLock { $0.source == nil }
    }
}

private struct WeakAnimatedSourceBox {
    weak var source: AnimatedImageSource?
}
