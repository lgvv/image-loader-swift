import CoreGraphics
import Darwin
import Foundation
import ImageIO
@_spi(Testing) @testable import ImageLoader
import Testing
import UIKit

@Suite("DecodingBenchmarks", .serialized, .enabled(if: !isThreadSanitizerActive))
struct DecodingBenchmarks {
    private static let gif400 = DecodingFixtures.gif(frameCount: 200, width: 400, height: 400, delay: 0.04)
    private static let budget = 32 * 1024 * 1024

    private struct Sample {
        let cpu: Double
        let wall: Double
    }

    private static func measure<T>(_ body: () -> T) -> (T, Sample) {
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let value = body()
        let wall = Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000
        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000
        return (value, Sample(cpu: cpu, wall: wall))
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else {
            return 0
        }
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))
        return sorted[index]
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    @Test("400x400 프레임 강제 디코딩 4ms 이하")
    func forcedFrameDecode400() throws {
        let cache = AnimatedFrameCache(costLimit: Self.budget)
        let source = try #require(AnimatedImageSource(data: Self.gif400, scale: 1, thumbnail: nil, frameCache: cache))
        var samples: [Sample] = []
        for index in 1..<source.frameCount {
            let (frame, sample) = Self.measure { source.decodeFrame(at: index) }
            #expect(frame != nil)
            samples.append(sample)
        }
        let cpuMedian = Self.percentile(samples.map(\.cpu), 0.5)
        let cpuP95 = Self.percentile(samples.map(\.cpu), 0.95)
        let wallMedian = Self.percentile(samples.map(\.wall), 0.5)
        let wallP95 = Self.percentile(samples.map(\.wall), 0.95)
        print(
            "BENCH|decoding|frame_decode_400x400|frames=\(samples.count)|cpu_median_ms=\(Self.format(cpuMedian))|cpu_p95_ms=\(Self.format(cpuP95))|wall_median_ms=\(Self.format(wallMedian))|wall_p95_ms=\(Self.format(wallP95))|threshold_ms=4"
        )
        if enforcesTimingBudgets {
            #expect(cpuMedian <= 4)
        }
    }

    @Test("200프레임 400x400 GIF 전체를 32MB 예산 안에서 디코딩, 두 번째 바퀴는 앞쪽 창이 적중")
    func allFramesWithinBudget() throws {
        let cache = AnimatedFrameCache(costLimit: Self.budget)
        let source = try #require(AnimatedImageSource(data: Self.gif400, scale: 1, thumbnail: nil, frameCache: cache))
        let frameBytes = Bitmap.cost(of: source.firstFrame)
        var decodedBytes = frameBytes
        var maximumCacheCost = 0
        var missing = 0
        var secondLoopHits = 0
        let (_, sample) = Self.measure {
            for loop in 0..<2 {
                for index in 0..<source.frameCount {
                    let cached = source.cachedFrame(at: index)
                    if loop == 1, index > 0, cached != nil {
                        secondLoopHits += 1
                    }
                    guard let frame = cached ?? source.decodeFrame(at: index) else {
                        missing += 1
                        continue
                    }
                    if loop == 0, index > 0 {
                        decodedBytes += Bitmap.cost(of: frame)
                    }
                    maximumCacheCost = max(maximumCacheCost, cache.totalCost)
                }
            }
        }
        print(
            "BENCH|decoding|frames_200_400x400_budget|decoded_mb=\(Self.format(Double(decodedBytes) / 1_048_576))|frame_kb=\(frameBytes / 1024)|max_cache_mb=\(Self.format(Double(maximumCacheCost) / 1_048_576))|budget_mb=32|decode_count=\(source.decodeCount)|second_loop_hits=\(secondLoopHits)|two_loops_cpu_ms=\(Self.format(sample.cpu))|two_loops_wall_ms=\(Self.format(sample.wall))|missing=\(missing)"
        )
        #expect(missing == 0)
        #expect(decodedBytes > 100 * 1_048_576)
        #expect(maximumCacheCost <= Self.budget + frameBytes)
        #expect(secondLoopHits >= Self.budget / frameBytes - 2)
        #expect(source.decodeCount < 1 + 2 * (source.frameCount - 1))
    }

    @Test("사진형, 잡음 400x400 GIF 프레임 강제 디코딩 비용")
    func texturedFrameDecode400() throws {
        for (name, texture) in [("photo", DecodingFixtures.Texture.photo), ("noise", .noise)] {
            let gif = DecodingFixtures.texturedGIF(texture, frameCount: 24, width: 400, height: 400, seed: 0x6A1F_0400)
            let source = try #require(AnimatedImageSource(data: gif, scale: 1, thumbnail: nil, frameCache: AnimatedFrameCache(costLimit: Self.budget)))
            var samples: [Sample] = []
            for index in 1..<source.frameCount {
                let (frame, sample) = Self.measure { source.decodeFrame(at: index) }
                #expect(frame != nil)
                samples.append(sample)
            }
            let cpuMedian = Self.percentile(samples.map(\.cpu), 0.5)
            print(
                "BENCH|decoding|frame_decode_400x400_\(name)|gif_kb=\(gif.count / 1024)|frames=\(samples.count)|cpu_median_ms=\(Self.format(cpuMedian))|cpu_p95_ms=\(Self.format(Self.percentile(samples.map(\.cpu), 0.95)))|wall_median_ms=\(Self.format(Self.percentile(samples.map(\.wall), 0.5)))|wall_p95_ms=\(Self.format(Self.percentile(samples.map(\.wall), 0.95)))|threshold_ms=4"
            )
            if texture == .photo, enforcesTimingBudgets {
                #expect(cpuMedian <= 4)
            }
        }
    }

    @Test("Default 동기 디코딩(조정 큐에서 실행) 비용: 기본 한도, 한도 없음, UIImage(data:)만, ImageIO 헤더 검사")
    func defaultSynchronousDecodeCost() throws {
        let cases: [(String, Data)] = [
            ("jpeg_4000x3000", DecodingFixtures.jpeg(width: 4000, height: 3000)),
            ("png_1000x1000", DecodingFixtures.png(width: 1000, height: 1000)),
            ("gif_static_400x400", DecodingFixtures.gif(frameCount: 1, width: 400, height: 400)),
            ("webp_lossless", DecodingFixtures.staticWebP()),
        ]
        for (name, data) in cases {
            let limited = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: data)))
            let unlimited = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: data, limits: .unlimited)))
            #expect(limited.isAsynchronous == false, "\(name)")
            var samples: [String: [Double]] = [:]
            for _ in 0..<60 {
                samples["default_limits", default: []].append(Self.measure { try? limited.decode(data) }.1.cpu)
                samples["unlimited", default: []].append(Self.measure { try? unlimited.decode(data) }.1.cpu)
                samples["uiimage_only", default: []].append(Self.measure { UIImage(data: data) }.1.cpu)
                samples["imageio_header", default: []].append(
                    Self.measure { () -> [CFString: Any]? in
                        guard let source = CGImageSourceCreateWithData(data as CFData, ImageHeader.sourceOptions) else {
                            return nil
                        }
                        return ImageHeader.properties(of: source, at: 0)
                    }.1.cpu)
                samples["header_scan", default: []].append(Self.measure { ImageHeaderScanner.pixelSize(of: data) }.1.cpu)
            }
            let medians = samples.mapValues { Self.percentile($0, 0.5) * 1000 }
            let fields = ["default_limits", "unlimited", "uiimage_only", "imageio_header", "header_scan"]
                .map { "\($0)_us=\(Self.format(medians[$0] ?? 0))" }
                .joined(separator: "|")
            print("BENCH|decoding|sync_decode_\(name)|\(fields)")
            if enforcesTimingBudgets {
                #expect((medians["header_scan"] ?? .infinity) < 20, "\(name)")
            }
        }
    }

    private static func simulatePlayback(_ sources: [AnimatedImageSource], ticks: Int, lookahead: Int) -> (hits: Int, misses: Int) {
        var hits = 0
        var misses = 0
        for tick in 0..<ticks {
            for source in sources {
                if source.cachedFrame(at: tick) != nil {
                    hits += 1
                } else {
                    misses += 1
                    _ = source.decodeFrame(at: tick)
                }
                for ahead in 1...lookahead where !source.hasCachedFrame(at: tick + ahead) {
                    _ = source.decodeFrame(at: tick + ahead)
                }
            }
        }
        return (hits, misses)
    }

    @Test("30개 동시 재생: 프레임 캐시 정책별 디코딩 횟수와 CPU")
    func concurrentPlaybackPolicies() throws {
        let small = DecodingFixtures.gif(frameCount: 40, width: 100, height: 100)
        let tiny = DecodingFixtures.gif(frameCount: 20, width: 100, height: 100)
        let large = DecodingFixtures.gif(frameCount: 100, width: 400, height: 400)
        let scenarios: [(String, [Data], Int)] = [
            ("30x_100x100x40_over_budget", Array(repeating: small, count: 30), 120),
            ("1x_400x400x100_plus_29x_100x100x20", [large] + Array(repeating: tiny, count: 29), 200),
        ]
        let policies: [(String, AnimatedFrameCache.EvictionPolicy)] = [
            ("lru", .leastRecentlyUsed),
            ("window_oversized", .windowForOversizedSources),
            ("window_all", .windowForAllSources),
        ]
        for (scenario, datas, ticks) in scenarios {
            var decodesByPolicy: [String: Int] = [:]
            for (policyName, policy) in policies {
                let cache = AnimatedFrameCache(costLimit: Self.budget, notificationCenter: NotificationCenter(), policy: policy)
                let sources = try datas.map { try #require(AnimatedImageSource(data: $0, scale: 1, thumbnail: nil, frameCache: cache)) }
                var maximumCost = 0
                let (result, sample) = Self.measure { () -> (hits: Int, misses: Int) in
                    let result = Self.simulatePlayback(sources, ticks: ticks, lookahead: 2)
                    maximumCost = cache.totalCost
                    return result
                }
                let decodes = sources.reduce(0) { $0 + $1.decodeCount - 1 }
                decodesByPolicy[policyName] = decodes
                let largestFrame = sources.map { Bitmap.cost(of: $0.firstFrame) }.max() ?? 0
                #expect(maximumCost <= Self.budget + largestFrame)
                print(
                    "BENCH|animation|playback_\(scenario)|policy=\(policyName)|ticks=\(ticks)|decodes=\(decodes)|display_hits=\(result.hits)|display_misses=\(result.misses)|cpu_ms=\(Self.format(sample.cpu))|wall_ms=\(Self.format(sample.wall))|cache_mb=\(Self.format(Double(maximumCost) / 1_048_576))"
                )
            }
            #expect((decodesByPolicy["window_oversized"] ?? .max) <= (decodesByPolicy["lru"] ?? 0))
        }
    }

    @Test("한도 바로 아래 크기의 원본 디코딩은 비트맵이 한도에 묶이고, 한 픽셀 넘으면 할당 없이 거부")
    func footprintJustUnderLimit() throws {
        let limits = ImageDecodingLimits(maximumPixelCount: 3000 * 3000)
        let atLimit = DecodingFixtures.zeroFilledPNG(width: 3000, height: 3000)
        let overLimit = DecodingFixtures.zeroFilledPNG(width: 3001, height: 3000)
        let before = Self.footprint()
        let decoded = try autoreleasepool { () throws -> CGImage? in
            let image = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: atLimit, limits: limits))).decode(atLimit).image
            return ImageDecompression.decompress(image: image).cgImage
        }
        let growth = Self.footprint() - before
        let bitmap = try #require(decoded)
        let bitmapBytes = Bitmap.cost(of: bitmap)
        #expect(bitmap.width * bitmap.height == 3000 * 3000)
        #expect(bitmapBytes <= 4 * 3000 * 3000 + 64 * 3000)

        let rejectBefore = Self.footprint()
        #expect(throws: ImageDecodingLimits.Error.pixelCountExceeded(pixelCount: 3001 * 3000, limit: 3000 * 3000)) {
            try ImageDecoders.Default(context: DecodingFixtures.context(for: overLimit, limits: limits))?.decode(overLimit)
        }
        let rejectGrowth = Self.footprint() - rejectBefore
        let defaultLimit = ImageDecodingLimits.default.maximumPixelCount ?? 0
        print(
            "BENCH|decoding|footprint_at_limit_3000x3000|bitmap_mb=\(Self.format(Double(bitmapBytes) / 1_048_576))|growth_mb=\(Self.format(Double(growth) / 1_048_576))|reject_growth_mb=\(Self.format(Double(rejectGrowth) / 1_048_576))|default_limit_px=\(defaultLimit)|default_limit_bitmap_mb=\(defaultLimit * 4 / 1_048_576)|physical_memory_mb=\(ProcessInfo.processInfo.physicalMemory / 1_048_576)"
        )
        #expect(growth < bitmapBytes * 4 + 64 * 1_048_576)
        #expect(rejectGrowth < 32 * 1_048_576)
        withExtendedLifetime(bitmap) {}
    }

    @Test("디코더 선택(조정 큐에서 실행)과 소스 생성 비용")
    func probeAndSourceCreationCost() throws {
        let png = DecodingFixtures.png(width: 64, height: 64)
        let context = DecodingFixtures.context(for: Self.gif400)
        let pngContext = DecodingFixtures.context(for: png)
        var gifProbe: [Sample] = []
        var pngProbe: [Sample] = []
        var creation: [Sample] = []
        for _ in 0..<20 {
            let (decoder, probeSample) = Self.measure { ImageDecoders.Animated(context: context, frameCache: AnimatedFrameCache(costLimit: Self.budget)) }
            gifProbe.append(probeSample)
            let animated = try #require(decoder)
            let (content, creationSample) = Self.measure { try? animated.decode(Self.gif400) }
            #expect(content?.animatedImageSource != nil)
            creation.append(creationSample)
            let (staticDecoder, pngSample) = Self.measure { ImageDecoders.Animated(context: pngContext) }
            #expect(staticDecoder == nil)
            pngProbe.append(pngSample)
        }
        print(
            "BENCH|decoding|select_animated_gif200_400x400|bytes=\(Self.gif400.count)|cpu_median_ms=\(Self.format(Self.percentile(gifProbe.map(\.cpu), 0.5)))|wall_median_ms=\(Self.format(Self.percentile(gifProbe.map(\.wall), 0.5)))"
        )
        print(
            "BENCH|decoding|select_static_png|cpu_median_ms=\(Self.format(Self.percentile(pngProbe.map(\.cpu), 0.5)))|wall_median_ms=\(Self.format(Self.percentile(pngProbe.map(\.wall), 0.5)))"
        )
        print(
            "BENCH|decoding|create_source_gif200_400x400|cpu_median_ms=\(Self.format(Self.percentile(creation.map(\.cpu), 0.5)))|wall_median_ms=\(Self.format(Self.percentile(creation.map(\.wall), 0.5)))"
        )
    }

    private static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    @Test("압축 폭탄 거부 시 메모리 증가 50MB 미만")
    func decompressionBombFootprint() throws {
        let bomb = DecodingFixtures.zeroFilledPNG(width: 20000, height: 20000)
        var request = ImageRequest(url: Fixtures.url)
        request.thumbnail = .scaleDownLargeImages()
        let thumbnailContext = DecodingFixtures.context(for: bomb, request: request)
        let before = Self.footprint()
        var rejected = 0
        let (_, sample) = Self.measure {
            for _ in 0..<10 {
                if (try? ImageDecoders.Default().decode(bomb)) == nil {
                    rejected += 1
                }
                if (try? ImageDecoders.Default(context: thumbnailContext)?.decode(bomb)) == nil {
                    rejected += 1
                }
            }
        }
        let growth = Self.footprint() - before
        print(
            "BENCH|decoding|bomb_20000x20000_png|bytes=\(bomb.count)|rejected=\(rejected)/20|footprint_growth_mb=\(Self.format(Double(growth) / 1_048_576))|threshold_mb=50|cpu_ms=\(Self.format(sample.cpu))"
        )
        #expect(rejected == 20)
        #expect(growth < 50 * 1_048_576)
    }

    @Test("큰 JPEG: 원본 디코딩+decompression 대비 scaleDownLargeImages")
    func scaleDownLargeImagesCost() throws {
        let jpeg = DecodingFixtures.jpeg(width: 4000, height: 3000)
        var full: [Sample] = []
        var scaled: [Sample] = []
        var scaledSize = CGSize.zero
        var request = ImageRequest(url: Fixtures.url)
        request.thumbnail = .scaleDownLargeImages(limitBytes: 16 * 1024 * 1024)
        let scaledContext = DecodingFixtures.context(for: jpeg, request: request)
        for _ in 0..<5 {
            let (_, fullSample) = Self.measure {
                let image = try? ImageDecoders.Default().decode(jpeg).image
                return image.map { ImageDecompression.decompress(image: $0) }
            }
            full.append(fullSample)
            let (image, scaledSample) = Self.measure { try? ImageDecoders.Default(context: scaledContext)?.decode(jpeg).image }
            scaled.append(scaledSample)
            scaledSize = image.map(DecodingFixtures.displaySize(of:)) ?? .zero
        }
        #expect(scaledSize.width * scaledSize.height <= 4 * 1024 * 1024)
        print(
            "BENCH|decoding|jpeg_4000x3000_full_decompress|cpu_median_ms=\(Self.format(Self.percentile(full.map(\.cpu), 0.5)))|wall_median_ms=\(Self.format(Self.percentile(full.map(\.wall), 0.5)))"
        )
        print(
            "BENCH|decoding|jpeg_4000x3000_scale_down_16mb|size=\(Int(scaledSize.width))x\(Int(scaledSize.height))|cpu_median_ms=\(Self.format(Self.percentile(scaled.map(\.cpu), 0.5)))|wall_median_ms=\(Self.format(Self.percentile(scaled.map(\.wall), 0.5)))"
        )
    }
}

private let isThreadSanitizerActive = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil
