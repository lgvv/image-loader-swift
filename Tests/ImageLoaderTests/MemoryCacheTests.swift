import CoreGraphics
import CoreImage
import Foundation
@_spi(Testing) @testable import ImageLoader
@_spi(Testing) import ImageLoaderTesting
import Testing
import UIKit

@Suite("MemoryCache 메모리 캐시")
struct MemoryCacheTests {
    @Test("기본값 고정")
    func defaultsArePinned() {
        let cache = MemoryCache()
        #expect(cache.costLimit == MemoryCache.defaultCostLimit())
        #expect(cache.countLimit == Int.max)
        #expect(cache.entryCostLimit == 0.1)
        #expect(cache.ttl == nil)
        #expect(cache.isWeakCacheEnabled == false)
        #expect(cache.lifecyclePolicy == MemoryCacheLifecyclePolicy())
        #expect(cache.lifecyclePolicy.purgesOnMemoryPressure)
        #expect(cache.lifecyclePolicy.pressureWarningTrimRatio == nil)
        #expect(cache.lifecyclePolicy.observesApplicationMemoryWarning == false)
        #expect(cache.lifecyclePolicy.backgroundTrimRatio == 0.1)
        #expect(cache.totalCount == 0)
        #expect(cache.totalCost == 0)
        #expect(MemoryCache.shared === MemoryCache.shared)
    }

    @Test("기본 비용 한도는 물리 메모리의 15%, 최대 768MB")
    func defaultCostLimitIsFifteenPercentOfPhysicalMemoryCappedAt768MB() {
        let expected = min(Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.15), 768 * 1024 * 1024)
        #expect(MemoryCache.defaultCostLimit() == expected)
    }

    @Test("미스, 히트, 덮어쓰기")
    func missHitAndOverwrite() throws {
        let cache = CacheFixture.cache()
        let key = MemoryCacheKey(key: "a")
        #expect(cache[key] == nil)

        let first = try CacheFixture.image()
        cache[key] = ImageContent(image: first)
        #expect(cache[key]?.image === first)
        #expect(cache.totalCount == 1)

        let second = try CacheFixture.image(width: 20, height: 20)
        cache[key] = ImageContent(image: second)
        #expect(cache[key]?.image === second)
        #expect(cache.totalCount == 1)
        #expect(cache.totalCost == MemoryCache.cost(for: ImageContent(image: second)))
    }

    @Test("nil을 넣으면 엔트리 삭제")
    func settingNilRemovesEntry() throws {
        let cache = CacheFixture.cache()
        let key = MemoryCacheKey(key: "a")
        cache[key] = ImageContent(image: try CacheFixture.image())
        cache[key] = nil
        #expect(cache[key] == nil)
        #expect(cache.totalCount == 0)
        #expect(cache.totalCost == 0)
    }

    @Test("컨테이너의 type, isPreview, data, userInfo를 그대로 돌려줌")
    func storesContainerMetadata() throws {
        let cache = CacheFixture.cache()
        let key = MemoryCacheKey(key: "a")
        let data = Data(repeating: 7, count: 32)
        cache[key] = ImageContent(image: try CacheFixture.image(), type: .gif, isPreview: true, data: data, userInfo: ["k": 1])
        let cached = try #require(cache[key])
        #expect(cached.type == .gif)
        #expect(cached.isPreview)
        #expect(cached.data == data)
        #expect(cached.userInfo["k"] as? Int == 1)
    }

    @Test("비용은 bytesPerRow × height + data 크기, userInfo는 세지 않음")
    func costCountsBitmapBytesAndData() throws {
        let image = try CacheFixture.image(width: 13, height: 7)
        let cgImage = try #require(image.cgImage)
        let bitmapCost = cgImage.bytesPerRow * cgImage.height
        #expect(bitmapCost >= 13 * 7 * 4)
        #expect(MemoryCache.cost(for: ImageContent(image: image)) == bitmapCost)
        #expect(MemoryCache.cost(for: ImageContent(image: image, data: Data(count: 100))) == bitmapCost + 100)
        let withObject = ImageContent(image: image, type: .gif, data: Data(count: 10), userInfo: ["object": CacheFixture.Token()])
        #expect(MemoryCache.cost(for: withObject) == bitmapCost + 10)
    }

    @Test("비트맵이 없는 이미지는 1 + data 크기로 계산")
    func costOfImageWithoutBitmapIsOnePlusDataSize() {
        let ciImage = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 5))
        let image = UIImage(ciImage: ciImage, scale: 2, orientation: .up)
        #expect(image.cgImage == nil)
        #expect(MemoryCache.cost(for: ImageContent(image: image)) == 1)
        #expect(MemoryCache.cost(for: ImageContent(image: image, data: Data(count: 3))) == 4)
    }

    @Test("비용 한도를 넘으면 가장 오래 쓰지 않은 엔트리부터 축출")
    func costLimitEvictsLeastRecentlyUsed() throws {
        let unit = try CacheFixture.unitCost()
        let cache = CacheFixture.cache(costLimit: unit * 3)
        cache.entryCostLimit = 1
        let keys = CacheFixture.keys(4)
        for key in keys.prefix(3) {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        _ = cache[keys[0]]
        cache[keys[3]] = ImageContent(image: try CacheFixture.image())

        #expect(cache[keys[0]] != nil)
        #expect(cache[keys[1]] == nil)
        #expect(cache[keys[2]] != nil)
        #expect(cache[keys[3]] != nil)
        #expect(cache.totalCost == unit * 3)
        #expect(cache.totalCount == 3)
    }

    @Test("개수 한도를 넘으면 가장 오래 쓰지 않은 엔트리부터 축출")
    func countLimitEvictsLeastRecentlyUsed() throws {
        let cache = CacheFixture.cache(countLimit: 3)
        let keys = CacheFixture.keys(4)
        for key in keys.prefix(3) {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        _ = cache[keys[0]]
        _ = cache[keys[2]]
        cache[keys[3]] = ImageContent(image: try CacheFixture.image())

        #expect(cache.totalCount == 3)
        #expect(cache[keys[0]] != nil)
        #expect(cache[keys[1]] == nil)
        #expect(cache[keys[2]] != nil)
        #expect(cache[keys[3]] != nil)
    }

    @Test("읽기 한 번은 축출 한 번만 막음")
    func referencedEntryGetsOneSecondChance() throws {
        let cache = CacheFixture.cache(countLimit: 2)
        let keys = CacheFixture.keys(4)
        cache[keys[0]] = ImageContent(image: try CacheFixture.image())
        cache[keys[1]] = ImageContent(image: try CacheFixture.image())
        _ = cache[keys[0]]
        cache[keys[2]] = ImageContent(image: try CacheFixture.image())
        #expect(cache.consistencyReport().linkedCount == 2)
        cache[keys[3]] = ImageContent(image: try CacheFixture.image())

        #expect(cache[keys[0]] == nil)
        #expect(cache[keys[1]] == nil)
        #expect(cache[keys[2]] != nil)
        #expect(cache[keys[3]] != nil)
    }

    @Test("모든 엔트리를 읽은 뒤 넣어도 새 엔트리는 남고 가장 오래된 엔트리가 빠짐 (개수 한도)")
    func insertAfterReadingEveryEntryKeepsNewEntryUnderCountLimit() throws {
        let cache = CacheFixture.cache(countLimit: 3)
        let keys = CacheFixture.keys(4)
        for key in keys.prefix(3) {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        for key in keys.prefix(3) {
            #expect(cache[key] != nil)
        }
        cache[keys[3]] = ImageContent(image: try CacheFixture.image())

        #expect(cache[keys[3]] != nil)
        #expect(cache[keys[0]] == nil)
        #expect(cache[keys[1]] != nil)
        #expect(cache[keys[2]] != nil)
        #expect(cache.totalCount == 3)
    }

    @Test("모든 엔트리를 읽은 뒤 넣어도 새 엔트리는 남고 가장 오래된 엔트리가 빠짐 (비용 한도)")
    func insertAfterReadingEveryEntryKeepsNewEntryUnderCostLimit() throws {
        let unit = try CacheFixture.unitCost()
        let cache = CacheFixture.cache(costLimit: unit * 3)
        cache.entryCostLimit = 1
        let keys = CacheFixture.keys(4)
        for key in keys.prefix(3) {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        for key in keys.prefix(3) {
            #expect(cache[key] != nil)
        }
        cache[keys[3]] = ImageContent(image: try CacheFixture.image())

        #expect(cache[keys[3]] != nil)
        #expect(cache[keys[0]] == nil)
        #expect(cache[keys[1]] != nil)
        #expect(cache[keys[2]] != nil)
        #expect(cache.totalCost == unit * 3)
    }

    @Test("모든 엔트리를 읽은 뒤 더 큰 값으로 덮어써도 덮어쓴 값이 남음")
    func overwriteAfterReadingEveryEntryKeepsNewValue() throws {
        let unit = try CacheFixture.unitCost()
        let cache = CacheFixture.cache(costLimit: unit * 3)
        cache.entryCostLimit = 1
        let keys = CacheFixture.keys(3)
        for key in keys {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        for key in keys {
            #expect(cache[key] != nil)
        }
        let larger = try CacheFixture.image(width: 10, height: 20)
        cache[keys[2]] = ImageContent(image: larger)

        #expect(cache[keys[2]]?.image === larger)
        #expect(cache[keys[0]] == nil)
        #expect(cache[keys[1]] != nil)
        #expect(cache.totalCost == unit * 3)
        #expect(cache.consistencyReport().isLinkedConsistently)
    }

    @Test("자주 읽는 묶음이 꽉 채운 상태에서도 새로 넣은 엔트리는 바로 다음 읽기에서 히트")
    func freshInsertsHitWhileAHotSetFillsTheCache() throws {
        let cache = CacheFixture.cache(countLimit: 3)
        let hot = CacheFixture.keys(3)
        for key in hot {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        var misses = 0
        for index in 0..<10 {
            for key in hot where cache[key] == nil {
                cache[key] = ImageContent(image: try CacheFixture.image())
            }
            let fresh = MemoryCacheKey(key: "fresh-\(index)")
            cache[fresh] = ImageContent(image: try CacheFixture.image())
            if cache[fresh] == nil {
                misses += 1
            }
            #expect(cache.totalCount <= 3)
        }
        #expect(misses == 0)
    }

    @Test("무작위 연산 중에도 받아들인 set 직후의 읽기는 항상 히트")
    func admittedSetIsAlwaysReadableImmediately() throws {
        let unit = try CacheFixture.unitCost()
        let cache = CacheFixture.cache(costLimit: unit * 12, countLimit: 8)
        cache.entryCostLimit = 0.5
        let keys = CacheFixture.keys(24)
        let images = try (1...3).map { try CacheFixture.image(width: 10, height: 10 * $0) }
        var generator = SeededGenerator(seed: 7)
        var misses = 0
        var admitted = 0
        for _ in 0..<3000 {
            let key = keys[Int(generator.next() % UInt64(keys.count))]
            switch generator.next() % 3 {
            case 0:
                let content = ImageContent(image: images[Int(generator.next() % UInt64(images.count))])
                cache[key] = content
                guard MemoryCache.cost(for: content) < unit * 6 else {
                    #expect(cache[key] == nil)
                    continue
                }
                admitted += 1
                if cache[key]?.image !== content.image {
                    misses += 1
                }
            default:
                _ = cache[key]
            }
            #expect(cache.totalCost <= unit * 12)
            #expect(cache.totalCount <= 8)
        }
        #expect(admitted > 500)
        #expect(misses == 0)
        let report = cache.consistencyReport()
        #expect(report.isLinkedConsistently)
        #expect(report.recordedCost == report.summedCost)
    }

    @Test("읽지 않은 엔트리는 넣은 순서대로 축출")
    func untouchedEntriesAreEvictedInInsertionOrder() throws {
        let cache = CacheFixture.cache(countLimit: 2)
        let keys = CacheFixture.keys(3)
        for key in keys {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        #expect(cache[keys[0]] == nil)
        #expect(cache[keys[1]] != nil)
        #expect(cache[keys[2]] != nil)
    }

    @Test("덮어쓰면 최근 사용으로 갱신")
    func overwriteRefreshesRecency() throws {
        let cache = CacheFixture.cache(countLimit: 2)
        let keys = CacheFixture.keys(3)
        cache[keys[0]] = ImageContent(image: try CacheFixture.image())
        cache[keys[1]] = ImageContent(image: try CacheFixture.image())
        cache[keys[0]] = ImageContent(image: try CacheFixture.image())
        cache[keys[2]] = ImageContent(image: try CacheFixture.image())
        #expect(cache[keys[0]] != nil)
        #expect(cache[keys[1]] == nil)
        #expect(cache[keys[2]] != nil)
    }

    @Test("entryCostLimit 비교는 엄격한 <")
    func entryCostLimitIsStrict() throws {
        let unit = try CacheFixture.unitCost()
        let cache = CacheFixture.cache(costLimit: unit * 2)
        cache.entryCostLimit = 0.5
        let key = MemoryCacheKey(key: "a")
        cache[key] = ImageContent(image: try CacheFixture.image())
        #expect(cache[key] == nil)
        #expect(cache.totalCount == 0)

        cache.costLimit = unit * 2 + 2
        cache[key] = ImageContent(image: try CacheFixture.image())
        #expect(cache[key] != nil)
    }

    @Test("entryCostLimit은 0과 1 사이로 고정, NaN은 0")
    func entryCostLimitIsClamped() throws {
        let unit = try CacheFixture.unitCost()
        let cache = CacheFixture.cache(costLimit: unit * 2)
        cache.entryCostLimit = 5
        cache[MemoryCacheKey(key: "a")] = ImageContent(image: try CacheFixture.image())
        #expect(cache.totalCount == 1)
        cache.entryCostLimit = -1
        cache[MemoryCacheKey(key: "b")] = ImageContent(image: try CacheFixture.image())
        #expect(cache[MemoryCacheKey(key: "b")] == nil)
        cache.entryCostLimit = .nan
        cache[MemoryCacheKey(key: "c")] = ImageContent(image: try CacheFixture.image())
        #expect(cache[MemoryCacheKey(key: "c")] == nil)
    }

    @Test("한도를 넘는 값을 넣으면 기존 엔트리도 제거")
    func oversizedSetRemovesExistingEntry() throws {
        let unit = try CacheFixture.unitCost()
        let cache = CacheFixture.cache(costLimit: unit * 4)
        cache.entryCostLimit = 0.5
        let key = MemoryCacheKey(key: "a")
        cache[key] = ImageContent(image: try CacheFixture.image())
        #expect(cache[key] != nil)

        cache[key] = ImageContent(image: try CacheFixture.image(width: 40, height: 40))
        #expect(cache[key] == nil)
        #expect(cache.totalCount == 0)
        #expect(cache.totalCost == 0)
    }

    @Test("한도를 넘는 set은 약한 참조 엔트리도 지움")
    func oversizedSetDoesNotReviveWeakEntry() throws {
        let unit = try CacheFixture.unitCost()
        let cache = CacheFixture.cache(costLimit: unit * 4, countLimit: 1)
        cache.entryCostLimit = 0.5
        cache.isWeakCacheEnabled = true
        let keys = CacheFixture.keys(2)
        let retained = try CacheFixture.image()
        cache[keys[0]] = ImageContent(image: retained)
        cache[keys[1]] = ImageContent(image: try CacheFixture.image())
        #expect(cache.weakCacheCount == 1)

        cache[keys[0]] = ImageContent(image: try CacheFixture.image(width: 40, height: 40))
        #expect(cache[keys[0]] == nil)
        #expect(cache.weakCacheCount == 0)
        withExtendedLifetime(retained) {}
    }

    @Test("ttl은 주입한 시계로 만료")
    func ttlExpiresEntriesUsingInjectedClock() throws {
        let clock = TestClock()
        let cache = CacheFixture.cache(clock: clock)
        let key = MemoryCacheKey(key: "a")
        cache.ttl = 10
        cache[key] = ImageContent(image: try CacheFixture.image())

        clock.advance(by: 10)
        #expect(cache[key] != nil)
        clock.advance(by: 0.5)
        #expect(cache[key] == nil)
        #expect(cache.totalCount == 0)
        #expect(cache.totalCost == 0)
    }

    @Test("ttl 변경은 이후에 넣는 엔트리에만 적용")
    func ttlAppliesToEntriesStoredAfterTheChange() throws {
        let clock = TestClock()
        let cache = CacheFixture.cache(clock: clock)
        let keys = CacheFixture.keys(2)
        cache[keys[0]] = ImageContent(image: try CacheFixture.image())
        cache.ttl = 1
        cache[keys[1]] = ImageContent(image: try CacheFixture.image())
        clock.advance(by: 100)
        #expect(cache[keys[0]] != nil)
        #expect(cache[keys[1]] == nil)
    }

    @Test("축출할 때 만료된 엔트리는 참조 비트와 무관하게 먼저 제거")
    func expiredEntriesAreEvictedBeforeReferencedOnes() throws {
        let clock = TestClock()
        let cache = CacheFixture.cache(countLimit: 2, clock: clock)
        let keys = CacheFixture.keys(3)
        cache[keys[0]] = ImageContent(image: try CacheFixture.image())
        cache.ttl = 1
        cache[keys[1]] = ImageContent(image: try CacheFixture.image())
        cache.ttl = nil
        _ = cache[keys[0]]
        _ = cache[keys[1]]
        clock.advance(by: 5)
        cache[keys[2]] = ImageContent(image: try CacheFixture.image())
        #expect(cache.totalCount == 2)
        #expect(cache[keys[0]] != nil)
        #expect(cache[keys[2]] != nil)
    }

    @Test("trim(toCost:), trim(toCount:)는 한도 설정을 바꾸지 않고 줄임")
    func trimToCostAndCount() throws {
        let unit = try CacheFixture.unitCost()
        let cache = CacheFixture.cache(costLimit: unit * 100)
        let keys = CacheFixture.keys(6)
        for key in keys {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        cache.trim(toCost: unit * 4)
        #expect(cache.totalCost == unit * 4)
        #expect(cache.totalCount == 4)
        #expect(cache[keys[0]] == nil)
        #expect(cache[keys[1]] == nil)

        cache.trim(toCount: 1)
        #expect(cache.totalCount == 1)
        #expect(cache[keys[5]] != nil)

        cache.trim(toCount: 0)
        #expect(cache.totalCount == 0)
        #expect(cache.totalCost == 0)
        #expect(cache.costLimit == unit * 100)
        #expect(cache.countLimit == Int.max)
    }

    @Test("한도 setter는 즉시 trim")
    func limitSettersTrimImmediately() throws {
        let unit = try CacheFixture.unitCost()
        let cache = CacheFixture.cache(costLimit: unit * 100)
        for key in CacheFixture.keys(10) {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        cache.costLimit = unit * 5
        #expect(cache.totalCount == 5)
        #expect(cache.totalCost == unit * 5)

        cache.countLimit = 2
        #expect(cache.totalCount == 2)

        cache.countLimit = 10
        cache.entryCostLimit = 0.02
        #expect(cache.totalCount == 2)
    }

    @Test("removeAll은 강한 쪽과 약한 쪽을 모두 비움")
    func removeAllClearsEverything() throws {
        let cache = CacheFixture.cache()
        cache.isWeakCacheEnabled = true
        let keys = CacheFixture.keys(10)
        let retained = try keys.map { _ in try CacheFixture.image() }
        for (key, image) in zip(keys, retained) {
            cache[key] = ImageContent(image: image)
        }
        cache.countLimit = 5
        #expect(cache.weakCacheCount == 5)
        cache.removeAll()
        #expect(cache.totalCount == 0)
        #expect(cache.totalCost == 0)
        #expect(cache.weakCacheCount == 0)
        for key in keys {
            #expect(cache[key] == nil)
        }
        withExtendedLifetime(retained) {}
    }

    @Test("축출됐어도 밖에서 잡고 있는 이미지는 약한 참조로 찾아 다시 넣음")
    func weakCacheRevivesImagesStillRetainedElsewhere() throws {
        let cache = CacheFixture.cache(countLimit: 1)
        cache.isWeakCacheEnabled = true
        let keys = CacheFixture.keys(2)
        let retained = try CacheFixture.image()
        cache[keys[0]] = ImageContent(image: retained, type: .png, isPreview: true, userInfo: ["n": 3])
        cache[keys[1]] = ImageContent(image: try CacheFixture.image())
        #expect(cache.totalCount == 1)
        #expect(cache.weakCacheCount == 1)

        let revived = try #require(cache[keys[0]])
        #expect(revived.image === retained)
        #expect(revived.type == .png)
        #expect(revived.isPreview)
        #expect(revived.userInfo["n"] as? Int == 3)
        #expect(cache.totalCount == 1)
        #expect(cache.totalCost == MemoryCache.cost(for: ImageContent(image: retained)))
        #expect(cache.consistencyReport().isLinkedConsistently)
        withExtendedLifetime(retained) {}
    }

    @Test("아무도 잡지 않은 이미지는 약한 쪽에서도 사라짐")
    func weakCacheDropsReleasedImages() throws {
        let cache = CacheFixture.cache(countLimit: 1)
        cache.isWeakCacheEnabled = true
        let keys = CacheFixture.keys(2)
        weak var probe: UIImage?
        try autoreleasepool {
            let image = try CacheFixture.image()
            probe = image
            cache[keys[0]] = ImageContent(image: image)
        }
        cache[keys[1]] = ImageContent(image: try CacheFixture.image())
        #expect(probe == nil)
        #expect(cache[keys[0]] == nil)
        #expect(cache.weakCacheCount == 0)
    }

    @Test("약한 참조 캐시는 기본으로 꺼져 있음")
    func weakCacheIsOffByDefault() throws {
        let cache = CacheFixture.cache(countLimit: 1)
        let keys = CacheFixture.keys(2)
        let retained = try CacheFixture.image()
        cache[keys[0]] = ImageContent(image: retained)
        cache[keys[1]] = ImageContent(image: try CacheFixture.image())
        #expect(cache[keys[0]] == nil)
        #expect(cache.weakCacheCount == 0)
        withExtendedLifetime(retained) {}
    }

    @Test("애니메이션 컨테이너는 이미지와 소스 객체가 살아 있으면 data와 userInfo까지 그대로 되살림")
    func weakCacheRevivesAnimatedContainersWhileImageAndSourceAreAlive() throws {
        let cache = CacheFixture.cache(countLimit: 1)
        cache.isWeakCacheEnabled = true
        let keys = CacheFixture.keys(2)
        let image = try CacheFixture.image()
        let source = CacheFixture.Token()
        let data = Data(repeating: 9, count: 128)
        let original = ImageContent(
            image: image,
            type: .webp,
            data: data,
            userInfo: [.animatedImageKey: source, "n": 5]
        )
        cache[keys[0]] = original
        cache[keys[1]] = ImageContent(image: try CacheFixture.image())
        #expect(cache.weakCacheCount == 1)
        #expect(cache.weakCacheDataBytes == data.count)

        let revived = try #require(cache[keys[0]])
        #expect(revived.image === image)
        #expect(revived.type == .webp)
        #expect(revived.data == data)
        #expect((revived.userInfo[.animatedImageKey] as? CacheFixture.Token) === source)
        #expect(revived.userInfo["n"] as? Int == 5)
        #expect(cache.totalCost == MemoryCache.cost(for: original))
        #expect(cache.weakCacheDataBytes == 0)
        #expect(cache.consistencyReport().recordedRemnantDataBytes == cache.consistencyReport().summedRemnantDataBytes)
        withExtendedLifetime((image, source)) {}
    }

    @Test("이미지는 살아 있어도 userInfo 객체가 해제됐으면 되살리지 않음")
    func weakCacheDoesNotReviveWhenAUserInfoObjectWasReleased() throws {
        let cache = CacheFixture.cache(countLimit: 1)
        cache.isWeakCacheEnabled = true
        let keys = CacheFixture.keys(2)
        let image = try CacheFixture.image()
        weak var probe: CacheFixture.Token?
        autoreleasepool {
            let source = CacheFixture.Token()
            probe = source
            cache[keys[0]] = ImageContent(image: image, type: .gif, data: Data(count: 16), userInfo: [.animatedImageKey: source])
        }
        cache[keys[1]] = ImageContent(image: try CacheFixture.image())
        #expect(probe == nil)
        #expect(cache.weakCacheCount == 1)

        #expect(cache[keys[0]] == nil)
        #expect(cache.weakCacheCount == 0)
        #expect(cache.weakCacheDataBytes == 0)
        withExtendedLifetime(image) {}
    }

    @Test("data가 있는 약한 엔트리가 해제되면 바이트 기준으로 일찍 정리")
    func deadWeakEntriesCarryingDataAreSweptByBytes() throws {
        let cache = CacheFixture.cache(countLimit: 1)
        cache.isWeakCacheEnabled = true
        let chunk = 512 * 1024
        let keys = CacheFixture.keys(20)
        for key in keys {
            try autoreleasepool {
                cache[key] = ImageContent(image: try CacheFixture.image(width: 2, height: 2), data: Data(count: chunk))
            }
        }
        #expect(cache.weakCacheCount < 10)
        #expect(cache.weakCacheDataBytes < MemoryCache.weakCacheDataSweepThreshold)
        let report = cache.consistencyReport()
        #expect(report.recordedRemnantDataBytes == report.summedRemnantDataBytes)
    }

    @Test("메모리 압박 뒤 해제된 data 보유 엔트리는 해제 큐가 끝나면 바이트까지 정리")
    func memoryPressureSweepsDataOfReleasedWeakEntries() throws {
        let monitor = CacheFixture.isolatedMonitor()
        let cache = CacheFixture.cache(monitor: monitor)
        cache.isWeakCacheEnabled = true
        let retained = try CacheFixture.image()
        let keys = CacheFixture.keys(6)
        cache[keys[0]] = ImageContent(image: retained, data: Data(count: 100))
        try autoreleasepool {
            for key in keys.dropFirst() {
                cache[key] = ImageContent(image: try CacheFixture.image(), data: Data(count: 1000))
            }
        }

        monitor.deliver(systemEvent: .critical)
        #expect(cache.totalCount == 0)
        CacheFixture.drainReleases()

        #expect(cache.weakCacheCount == 1)
        #expect(cache.weakCacheDataBytes == 100)
        #expect(cache.consistencyReport().recordedRemnantDataBytes == 100)
        #expect(cache[keys[0]]?.data?.count == 100)
        withExtendedLifetime(retained) {}
    }

    @Test("명시적 삭제는 약한 쪽도 지움")
    func explicitRemovalClearsWeakEntry() throws {
        let cache = CacheFixture.cache(countLimit: 1)
        cache.isWeakCacheEnabled = true
        let keys = CacheFixture.keys(2)
        let retained = try CacheFixture.image()
        cache[keys[0]] = ImageContent(image: retained)
        cache[keys[1]] = ImageContent(image: try CacheFixture.image())
        cache[keys[0]] = nil
        #expect(cache[keys[0]] == nil)
        #expect(cache.weakCacheCount == 0)
        withExtendedLifetime(retained) {}
    }

    @Test("끄면 약한 쪽을 비우고, 다시 켜도 되살아나지 않음")
    func disablingWeakCacheDropsWeakEntries() throws {
        let cache = CacheFixture.cache(countLimit: 1)
        cache.isWeakCacheEnabled = true
        let keys = CacheFixture.keys(2)
        let retained = try CacheFixture.image()
        cache[keys[0]] = ImageContent(image: retained)
        cache[keys[1]] = ImageContent(image: try CacheFixture.image())
        #expect(cache.weakCacheCount == 1)
        cache.isWeakCacheEnabled = false
        #expect(cache.weakCacheCount == 0)
        cache.isWeakCacheEnabled = true
        #expect(cache[keys[0]] == nil)
        withExtendedLifetime(retained) {}
    }

    @Test("약한 쪽 엔트리도 ttl을 지킴")
    func weakEntriesRespectTTL() throws {
        let clock = TestClock()
        let cache = CacheFixture.cache(countLimit: 1, clock: clock)
        cache.isWeakCacheEnabled = true
        cache.ttl = 5
        let keys = CacheFixture.keys(2)
        let retained = try CacheFixture.image()
        cache[keys[0]] = ImageContent(image: retained)
        cache.ttl = nil
        cache[keys[1]] = ImageContent(image: try CacheFixture.image())
        clock.advance(by: 10)
        #expect(cache[keys[0]] == nil)
        #expect(cache.weakCacheCount == 0)
        withExtendedLifetime(retained) {}
    }

    @Test("죽은 약한 참조는 테이블이 커질 때 정리")
    func deadWeakEntriesAreSweptAsTheTableGrows() throws {
        let cache = CacheFixture.cache(countLimit: 1)
        cache.isWeakCacheEnabled = true
        let keys = CacheFixture.keys(400)
        for key in keys {
            try autoreleasepool {
                cache[key] = ImageContent(image: try CacheFixture.image(width: 2, height: 2))
            }
        }
        #expect(cache.weakCacheCount < 64)
    }

    @Test("되살릴 때도 현재 entryCostLimit을 지키고, 넘으면 돌려만 줌")
    func weakRevivalRespectsCurrentEntryCostLimit() throws {
        let cache = CacheFixture.cache(countLimit: 1)
        cache.isWeakCacheEnabled = true
        let keys = CacheFixture.keys(2)
        let retained = try CacheFixture.image()
        cache[keys[0]] = ImageContent(image: retained)
        cache[keys[1]] = ImageContent(image: try CacheFixture.image())
        cache.entryCostLimit = 0

        #expect(cache[keys[0]]?.image === retained)
        #expect(cache.totalCount == 1)
        #expect(cache.weakCacheCount == 1)
        #expect(cache[keys[1]] != nil)
        withExtendedLifetime(retained) {}
    }

    @Test("메모리 압박을 받으면 같은 호출 안에서 비움")
    func memoryPressureClearsInTheSameCall() throws {
        let monitor = CacheFixture.isolatedMonitor()
        let cache = CacheFixture.cache(monitor: monitor)
        for key in CacheFixture.keys(20) {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        #expect(cache.totalCount == 20)

        monitor.deliver(systemEvent: .critical)

        #expect(cache.totalCount == 0)
        #expect(cache.totalCost == 0)
        #expect(cache.consistencyReport().linkedCount == 0)
        CacheFixture.drainReleases()
    }

    @Test("UIKit 메모리 경고를 켜면 보낸 스레드에서 동기로 비움")
    func applicationMemoryWarningIsHandledSynchronouslyOnThePostingThreadWhenObserved() throws {
        let center = NotificationCenter()
        let monitor = MemoryPressureMonitor(notificationCenter: center)
        let cache = CacheFixture.cache(monitor: monitor)
        cache.lifecyclePolicy = MemoryCacheLifecyclePolicy(observesApplicationMemoryWarning: true)
        let responder = CacheFixture.RecordingResponder()
        monitor.register(responder)
        for key in CacheFixture.keys(5) {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }

        let observed = DispatchQueue(label: "memory-cache.poster").sync {
            center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
            return (thread: CacheFixture.currentThreadID(), count: cache.totalCount)
        }

        #expect(observed.count == 0)
        #expect(responder.warningThreads.value == [observed.thread])
        #expect(responder.events.value == [.applicationMemoryWarning])
        #expect(responder.backgroundThreads.value.isEmpty)
        CacheFixture.drainReleases()
        withExtendedLifetime(monitor) {}
    }

    @Test("메모리 압박 뒤에도 밖에서 잡고 있는 이미지는 약한 쪽으로 찾음")
    func memoryPressureKeepsImagesRetainedElsewhereInWeakCache() throws {
        let monitor = CacheFixture.isolatedMonitor()
        let cache = CacheFixture.cache(monitor: monitor)
        cache.isWeakCacheEnabled = true
        let keys = CacheFixture.keys(2)
        let retained = try CacheFixture.image()
        cache[keys[0]] = ImageContent(image: retained)
        try autoreleasepool {
            cache[keys[1]] = ImageContent(image: try CacheFixture.image())
        }

        monitor.deliver(systemEvent: .critical)
        #expect(cache.totalCount == 0)
        CacheFixture.drainReleases()

        #expect(cache[keys[0]]?.image === retained)
        #expect(cache[keys[1]] == nil)
        withExtendedLifetime(retained) {}
    }

    @Test("메모리 압박으로 해제된 이미지의 약한 엔트리는 해제 큐에서 정리")
    func memoryPressureSweepsDeadWeakEntriesOnTheReleaseQueue() throws {
        let monitor = CacheFixture.isolatedMonitor()
        let cache = CacheFixture.cache(monitor: monitor)
        cache.isWeakCacheEnabled = true
        let keys = CacheFixture.keys(10)
        let retained = try [CacheFixture.image(), CacheFixture.image()]
        try autoreleasepool {
            for (index, key) in keys.enumerated() {
                let image = index < retained.count ? retained[index] : try CacheFixture.image()
                cache[key] = ImageContent(image: image)
            }
        }
        #expect(cache.weakCacheCount == 0)
        #expect(cache.consistencyReport().unmirroredEntryCount == 0)

        monitor.deliver(systemEvent: .critical)
        #expect(cache.totalCount == 0)
        CacheFixture.drainReleases()

        #expect(cache.weakCacheCount == retained.count)
        #expect(cache.consistencyReport().summedRemnantDataBytes == 0)
        withExtendedLifetime(retained) {}
    }

    @Test("라이브러리 기본값은 시스템 압박 warning과 critical 모두 비우고 UIKit 경고는 보지 않음")
    func defaultPressureHandlingPurgesOnSystemPressure() throws {
        let center = NotificationCenter()
        let monitor = MemoryPressureMonitor(notificationCenter: center)
        let cache = CacheFixture.cache(monitor: monitor)
        let keys = CacheFixture.keys(5)
        func fill() throws {
            for key in keys {
                cache[key] = ImageContent(image: try CacheFixture.image())
            }
        }

        try fill()
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #expect(cache.totalCount == keys.count)

        monitor.deliver(systemEvent: .warning)
        CacheFixture.drainReleases()
        #expect(cache.totalCount == 0)

        try fill()
        monitor.deliver(systemEvent: .critical)
        #expect(cache.totalCount == 0)

        try fill()
        monitor.deliver(systemEvent: [.warning, .critical])
        #expect(cache.totalCount == 0)

        try fill()
        monitor.deliver(systemEvent: .normal)
        #expect(cache.totalCount == keys.count)
        CacheFixture.drainReleases()
    }

    @Test("시스템 압박 이벤트는 critical을 warning보다 먼저 보고, normal은 버림")
    func systemPressureEventMapping() {
        #expect(MemoryPressureEvent(systemEvent: .warning) == .warning)
        #expect(MemoryPressureEvent(systemEvent: .critical) == .critical)
        #expect(MemoryPressureEvent(systemEvent: [.warning, .critical]) == .critical)
        #expect(MemoryPressureEvent(systemEvent: .normal) == nil)
    }

    @Test("공유 모니터는 DispatchSource [.warning, .critical]를 main이 아닌 큐에서 받음")
    func sharedMonitorObservesSystemMemoryPressure() throws {
        let shared = MemoryPressureMonitor.shared
        #expect(MemoryPressureMonitor.systemEventMask == [.warning, .critical])
        let honoredMask = try #require(shared.systemPressureSourceMask)
        #expect(honoredMask.contains(.warning))
        #expect(honoredMask.isSubset(of: MemoryPressureMonitor.systemEventMask))
        #expect(shared.isSystemPressureSourceActive)
        #expect(shared.pressureQueue !== DispatchQueue.main)
        #expect(shared.pressureQueue.qos.qosClass == .utility)

        let isolated = CacheFixture.isolatedMonitor()
        #expect(isolated.systemPressureSourceMask == nil)
        #expect(isolated.isSystemPressureSourceActive == false)
    }

    @Test("purgesOnMemoryPressure를 끄면 압박과 UIKit 경고에서 비우지 않음")
    func disablingPressurePurgeKeepsEntries() throws {
        let center = NotificationCenter()
        let monitor = MemoryPressureMonitor(notificationCenter: center)
        let cache = CacheFixture.cache(monitor: monitor)
        cache.lifecyclePolicy = MemoryCacheLifecyclePolicy(purgesOnMemoryPressure: false, observesApplicationMemoryWarning: true)
        for key in CacheFixture.keys(5) {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        monitor.deliver(systemEvent: .warning)
        CacheFixture.drainReleases()
        monitor.deliver(systemEvent: .critical)
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #expect(cache.totalCount == 5)
    }

    @Test("pressureWarningTrimRatio는 warning에서 비용과 개수 모두 그 비율까지 줄이고 30초 안에는 한 번만")
    func pressureWarningTrimsCostAndCountWithDebounce() throws {
        let unit = try CacheFixture.unitCost()
        let clock = TestClock()
        let monitor = CacheFixture.isolatedMonitor()
        let byCount = CacheFixture.cache(costLimit: unit * 100, countLimit: 20, clock: clock, monitor: monitor)
        let byCost = CacheFixture.cache(costLimit: unit * 20, clock: clock, monitor: monitor)
        let policy = MemoryCacheLifecyclePolicy(pressureWarningTrimRatio: 0.5)
        byCount.lifecyclePolicy = policy
        byCost.lifecyclePolicy = policy
        let keys = CacheFixture.keys(20)
        func fill() throws {
            for cache in [byCount, byCost] {
                for key in keys {
                    cache[key] = ImageContent(image: try CacheFixture.image())
                }
            }
        }

        try fill()
        #expect(byCount.totalCount == 20)
        #expect(byCost.totalCost == unit * 20)
        monitor.deliver(systemEvent: .warning)
        CacheFixture.drainReleases()
        #expect(byCount.totalCount == 10)
        #expect(byCost.totalCost == unit * 10)
        #expect(byCount.countLimit == 20)
        #expect(byCost.costLimit == unit * 20)

        try fill()
        clock.advance(by: 29)
        monitor.deliver(systemEvent: .warning)
        CacheFixture.drainReleases()
        #expect(byCount.totalCount == 20)
        #expect(byCost.totalCost == unit * 20)

        clock.advance(by: 2)
        monitor.deliver(systemEvent: .warning)
        CacheFixture.drainReleases()
        #expect(byCount.totalCount == 10)
        #expect(byCost.totalCost == unit * 10)

        monitor.deliver(systemEvent: .critical)
        #expect(byCount.totalCount == 0)
        #expect(byCost.totalCount == 0)
        CacheFixture.drainReleases()
    }

    @Test("메모리 압박으로 비운 값은 보낸 스레드가 아닌 해제 큐에서 해제")
    func memoryPressurePurgeReleasesValuesOnTheReleaseQueue() throws {
        let monitor = CacheFixture.isolatedMonitor()
        let cache = CacheFixture.cache(monitor: monitor)
        let releaseThreads = Box<[UInt64]>([])
        let keys = CacheFixture.keys(8)
        for key in keys {
            autoreleasepool {
                let image = CacheFixture.reentrantImage {
                    _ = cache.totalCount
                    _ = cache[MemoryCacheKey(key: "probe")]
                    releaseThreads.mutate { $0.append(CacheFixture.currentThreadID()) }
                }
                cache[key] = ImageContent(image: image)
            }
        }

        let postingThread = DispatchQueue(label: "memory-cache.pressure-poster").sync {
            monitor.deliver(systemEvent: .critical)
            return CacheFixture.currentThreadID()
        }
        #expect(cache.totalCount == 0)
        CacheFixture.drainReleases()

        #expect(releaseThreads.value.count == keys.count)
        #expect(!releaseThreads.value.contains(postingThread))
    }

    @Test("약한 엔트리는 set 때 강한 엔트리와 함께 만들어 purge가 엔트리를 훑지 않음")
    func weakEntriesAreCreatedWhenStoring() throws {
        let monitor = CacheFixture.isolatedMonitor()
        let cache = CacheFixture.cache(countLimit: 4, monitor: monitor)
        cache.isWeakCacheEnabled = true
        let keys = CacheFixture.keys(6)
        let retained = try keys.map { _ in try CacheFixture.image() }
        for (key, image) in zip(keys, retained) {
            cache[key] = ImageContent(image: image)
        }
        let report = cache.consistencyReport()
        #expect(report.count == 4)
        #expect(report.unmirroredEntryCount == 0)
        #expect(cache.weakCacheCount == 2)

        _ = cache[keys[0]]
        #expect(cache.consistencyReport().unmirroredEntryCount == 0)

        monitor.deliver(systemEvent: .critical)
        #expect(cache.totalCount == 0)
        CacheFixture.drainReleases()
        for (key, image) in zip(keys, retained) {
            #expect(cache[key]?.image === image)
        }
        withExtendedLifetime(retained) {}
    }

    @Test("압박으로 비운 뒤 해제 큐가 돌기 전에는 캐시만 잡던 이미지를 되살리지 않음")
    func purgedImageIsNotRevivedBeforeTheReleaseQueueRuns() throws {
        let monitor = CacheFixture.isolatedMonitor()
        let releaseQueue = DispatchQueue(label: "memory-cache.release.held")
        let cache = MemoryCache(costLimit: 1 << 30, clock: SystemClock(), monitor: monitor, releaseQueue: releaseQueue)
        cache.isWeakCacheEnabled = true
        let key = MemoryCacheKey(key: "purged-only-by-cache")
        weak var probe: UIImage?
        try autoreleasepool {
            let image = try CacheFixture.image()
            probe = image
            cache[key] = ImageContent(image: image)
        }

        releaseQueue.suspend()
        monitor.deliver(systemEvent: .critical)
        let revivedDuringRelease = cache[key] != nil
        let countAfterRead = cache.totalCount
        releaseQueue.resume()
        releaseQueue.sync {}

        #expect(revivedDuringRelease == false)
        #expect(countAfterRead == 0)
        #expect(probe == nil)
        #expect(cache[key] == nil)
        #expect(cache.totalCount == 0)
        #expect(cache.weakCacheCount == 0)
    }

    @Test("밖에서 잡고 있는 이미지도 압박 해제가 끝난 뒤에 다시 찾음")
    func retainedImageIsFoundAgainOnceThePurgeReleaseFinishes() throws {
        let monitor = CacheFixture.isolatedMonitor()
        let releaseQueue = DispatchQueue(label: "memory-cache.release.held")
        let cache = MemoryCache(costLimit: 1 << 30, clock: SystemClock(), monitor: monitor, releaseQueue: releaseQueue)
        cache.isWeakCacheEnabled = true
        let key = MemoryCacheKey(key: "purged-but-retained")
        let retained = try CacheFixture.image()
        cache[key] = ImageContent(image: retained)

        releaseQueue.suspend()
        monitor.deliver(systemEvent: .critical)
        let revivedDuringRelease = cache[key] != nil
        releaseQueue.resume()
        releaseQueue.sync {}

        #expect(revivedDuringRelease == false)
        #expect(cache[key]?.image === retained)
        #expect(cache.totalCount == 1)
        let report = cache.consistencyReport()
        #expect(report.recordedWeakOnlyCount == report.summedWeakOnlyCount)
        withExtendedLifetime(retained) {}
    }

    @Test("캐시만 잡던 data 보유 엔트리가 축출돼도 약한 쪽 data 합은 4MB 근처에 머묾")
    func deadWeakOnlyDataStaysBoundedWhileStoring() throws {
        let cache = CacheFixture.cache(countLimit: 20)
        cache.isWeakCacheEnabled = true
        let megabyte = 1024 * 1024
        var peak = 0
        for key in CacheFixture.keys(80) {
            try autoreleasepool {
                cache[key] = ImageContent(image: try CacheFixture.image(width: 2, height: 2), data: Data(count: megabyte))
            }
            peak = max(peak, cache.weakCacheDataBytes)
        }
        #expect(peak <= 5 * megabyte)
        let report = cache.consistencyReport()
        #expect(report.recordedWeakOnlyCount == report.summedWeakOnlyCount)
        #expect(report.recordedWeakOnlyDataBytes == report.summedWeakOnlyDataBytes)
        #expect(report.recordedRemnantDataBytes == report.summedRemnantDataBytes)
    }

    @Test("약한 쪽 정리는 락 한 번에 최대 256개만 훑음")
    func remnantSweepVisitsAtMostOneBatchPerLock() throws {
        let cache = CacheFixture.cache(countLimit: 10)
        cache.isWeakCacheEnabled = true
        let image = try CacheFixture.image(width: 1, height: 1)
        let entryCount = 3000
        for index in 0..<entryCount {
            cache[MemoryCacheKey(key: "sweep-\(index)")] = ImageContent(image: image)
        }
        let statistics = cache.workStatistics
        #expect(statistics.sweepVisits > 0)
        #expect(statistics.largestSweepBatch <= MemoryCache.weakSweepBatchSize)
        #expect(cache.weakCacheCount == entryCount - 10)
        let report = cache.consistencyReport()
        #expect(report.recordedWeakOnlyCount == report.summedWeakOnlyCount)
        #expect(report.unmirroredEntryCount == 0)
        withExtendedLifetime(image) {}
    }

    @Test("압박 purge는 엔트리 수와 무관하게 락 안에서 엔트리를 훑지 않음")
    func memoryPressurePurgeDoesNoPerEntryWorkUnderTheLock() throws {
        let image = try CacheFixture.image(width: 1, height: 1)
        for entryCount in [10, 5000] {
            let monitor = CacheFixture.isolatedMonitor()
            let releaseQueue = DispatchQueue(label: "memory-cache.release.held")
            let cache = MemoryCache(costLimit: 1 << 30, clock: SystemClock(), monitor: monitor, releaseQueue: releaseQueue)
            cache.isWeakCacheEnabled = true
            for index in 0..<entryCount {
                cache[MemoryCacheKey(key: "constant-\(index)")] = ImageContent(image: image)
            }
            releaseQueue.suspend()
            let before = cache.workStatistics.operations
            monitor.deliver(systemEvent: .critical)
            let after = cache.workStatistics.operations
            let countAfterPurge = cache.totalCount
            releaseQueue.resume()
            releaseQueue.sync {}

            #expect(after == before, "entries=\(entryCount)")
            #expect(countAfterPurge == 0)
            #expect(cache.weakCacheCount == entryCount)
        }
        withExtendedLifetime(image) {}
    }

    @Test("trim, 백그라운드 trim, 한도 축소는 락 한 번에 최대 256개씩 축출")
    func trimsEvictAtMostOneBatchPerLock() throws {
        let center = NotificationCenter()
        let monitor = MemoryPressureMonitor(notificationCenter: center)
        let cache = CacheFixture.cache(monitor: monitor)
        let image = try CacheFixture.image(width: 1, height: 1)
        func fill() {
            for index in 0..<2000 {
                cache[MemoryCacheKey(key: "trim-\(index)")] = ImageContent(image: image)
            }
        }

        fill()
        cache.trim(toCount: 100)
        #expect(cache.totalCount == 100)
        fill()
        cache.countLimit = 1000
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        CacheFixture.drainReleases()
        #expect(cache.totalCount == 100)
        let largest = cache.workStatistics.largestEvictionBatch
        #expect(largest > 0)
        #expect(largest <= MemoryCache.evictionBatchSize)
        #expect(cache.consistencyReport().isLinkedConsistently)
        withExtendedLifetime(image) {}
    }

    @Test("시스템 압박 소스의 이벤트가 모니터를 거쳐 캐시까지 전달됨")
    func systemPressureSourceEventsReachTheCache() throws {
        let captured = Box<(mask: DispatchSource.MemoryPressureEvent, queue: DispatchQueue, handler: MemoryPressureSourceFactory.Handler)?>(nil)
        let source = ScriptedPressureSource()
        let factory = MemoryPressureSourceFactory { mask, queue, handler in
            captured.value = (mask, queue, handler)
            source.recordedMask.value = mask
            return source
        }
        var monitor: MemoryPressureMonitor? = MemoryPressureMonitor(notificationCenter: NotificationCenter(), systemSource: factory)
        let pressureQueue = try #require(monitor?.pressureQueue)
        let responder = CacheFixture.RecordingResponder()
        monitor?.register(responder)
        let cache = CacheFixture.cache(monitor: monitor)
        for key in CacheFixture.keys(3) {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        let installed = try #require(captured.value)
        #expect(installed.mask == MemoryPressureMonitor.systemEventMask)
        #expect(installed.queue === pressureQueue)
        #expect(monitor?.systemPressureSourceMask == MemoryPressureMonitor.systemEventMask)
        #expect(monitor?.isSystemPressureSourceActive == true)

        pressureQueue.sync { installed.handler(.normal) }
        #expect(responder.events.value.isEmpty)
        #expect(cache.totalCount == 3)

        pressureQueue.sync { installed.handler(.warning) }
        #expect(responder.events.value == [.warning])
        #expect(cache.totalCount == 0)

        monitor = nil
        #expect(source.cancelled.value)
        CacheFixture.drainReleases()
    }

    @Test("약한 참조 캐시를 나중에 켜도 이미 있던 엔트리를 압박 뒤에 다시 찾음")
    func enablingWeakCacheMirrorsExistingEntries() throws {
        let monitor = CacheFixture.isolatedMonitor()
        let cache = CacheFixture.cache(monitor: monitor)
        let keys = CacheFixture.keys(3)
        let retained = try keys.map { _ in try CacheFixture.image() }
        for (key, image) in zip(keys, retained) {
            cache[key] = ImageContent(image: image)
        }
        cache.isWeakCacheEnabled = true
        #expect(cache.consistencyReport().unmirroredEntryCount == 0)

        monitor.deliver(systemEvent: .critical)
        CacheFixture.drainReleases()

        for (key, image) in zip(keys, retained) {
            #expect(cache[key]?.image === image)
        }
        withExtendedLifetime(retained) {}
    }

    @Test("메모리 압박 뒤에도 이미지와 소스가 살아 있는 애니메이션 컨테이너는 data와 userInfo까지 되살림")
    func memoryPressureKeepsRetainedAnimatedContainersRestorable() throws {
        let monitor = CacheFixture.isolatedMonitor()
        let cache = CacheFixture.cache(monitor: monitor)
        cache.isWeakCacheEnabled = true
        let keys = CacheFixture.keys(2)
        let image = try CacheFixture.image()
        let source = CacheFixture.Token()
        let data = Data(repeating: 3, count: 256)
        cache[keys[0]] = ImageContent(image: image, type: .webp, data: data, userInfo: [.animatedImageKey: source])
        try autoreleasepool {
            cache[keys[1]] = ImageContent(
                image: try CacheFixture.image(),
                type: .gif,
                data: Data(count: 512),
                userInfo: [.animatedImageKey: CacheFixture.Token()]
            )
        }

        monitor.deliver(systemEvent: .critical)
        CacheFixture.drainReleases()

        #expect(cache.weakCacheCount == 1)
        #expect(cache.weakCacheDataBytes == data.count)
        let revived = try #require(cache[keys[0]])
        #expect(revived.image === image)
        #expect(revived.type == .webp)
        #expect(revived.data == data)
        #expect((revived.userInfo[.animatedImageKey] as? CacheFixture.Token) === source)
        #expect(cache[keys[1]] == nil)
        withExtendedLifetime((image, source)) {}
    }

    @Test("긴 엔트리 사슬을 비워도 재귀 해제 없이 끝남")
    func releasingALongEntryChainIsIterative() throws {
        let monitor = CacheFixture.isolatedMonitor()
        let cache = CacheFixture.cache(monitor: monitor)
        cache.isWeakCacheEnabled = true
        let content = ImageContent(image: try CacheFixture.image(width: 1, height: 1))
        let entryCount = 50000
        for index in 0..<entryCount {
            cache[MemoryCacheKey(key: "chain-\(index)")] = content
        }
        #expect(cache.totalCount == entryCount)
        monitor.deliver(systemEvent: .critical)
        CacheFixture.drainReleases()
        #expect(cache.totalCount == 0)
        for index in 0..<entryCount {
            cache[MemoryCacheKey(key: "chain-\(index)")] = content
        }
        cache.removeAll()
        #expect(cache.totalCount == 0)
        #expect(cache.weakCacheCount == 0)
    }

    @Test("백그라운드 진입 시 비용 한도의 10%까지 trim")
    func backgroundTrimsToCostFraction() throws {
        let unit = try CacheFixture.unitCost()
        let center = NotificationCenter()
        let monitor = MemoryPressureMonitor(notificationCenter: center)
        let cache = CacheFixture.cache(costLimit: unit * 100, monitor: monitor)
        for key in CacheFixture.keys(50) {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        #expect(cache.totalCost == unit * 50)

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        CacheFixture.drainReleases()

        #expect(cache.totalCost == unit * 10)
        #expect(cache.totalCount == 10)
        #expect(cache.costLimit == unit * 100)
    }

    @Test("백그라운드 trim은 알림을 보낸 스레드가 아니라 해제 큐에서 함")
    func backgroundTrimRunsOffTheNotifyingThread() throws {
        let center = NotificationCenter()
        let monitor = MemoryPressureMonitor(notificationCenter: center)
        let cache = CacheFixture.cache(countLimit: 20, monitor: monitor)
        for key in CacheFixture.keys(20) {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        let gate = DispatchSemaphore(value: 0)
        MemoryCache.releaseQueue.async { gate.wait() }
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(cache.totalCount == 20)
        gate.signal()
        CacheFixture.drainReleases()
        #expect(cache.totalCount == 2)
    }

    @Test("메모리 압박 purge, warning trim, 백그라운드 trim은 비운 개수와 비용을 파이프라인 진단으로 보냄")
    func lifecycleEventsAreReportedAsDiagnostics() async throws {
        let unit = try CacheFixture.unitCost()
        let center = NotificationCenter()
        let monitor = MemoryPressureMonitor(notificationCenter: center)
        let cache = CacheFixture.cache(countLimit: 20, monitor: monitor)
        cache.lifecyclePolicy = MemoryCacheLifecyclePolicy(pressureWarningTrimRatio: 0.5)
        let delegate = RecordingDelegate()
        let session = makeSession(loader: MockDataLoader(), delegate: delegate) { $0.memoryCache = cache }
        func fill() throws {
            for key in CacheFixture.keys(20) {
                cache[key] = ImageContent(image: try CacheFixture.image())
            }
        }
        @Sendable func recorded() -> [String] {
            delegate.diagnostics.value.compactMap { diagnostic in
                switch diagnostic {
                case .memoryPressurePurge(let reason, let count, let cost): "purge:\(reason):\(count):\(cost / unit)"
                case .memoryPressureTrim(let count, let cost): "trim:\(count):\(cost / unit)"
                case .backgroundTrim(let count, let cost): "background:\(count):\(cost / unit)"
                default: nil
                }
            }
        }
        try fill()
        monitor.deliver(systemEvent: .critical)
        #expect(await waitUntil { recorded() == ["purge:critical:20:20"] })
        try fill()
        monitor.deliver(systemEvent: .warning)
        CacheFixture.drainReleases()
        #expect(await waitUntil { recorded() == ["purge:critical:20:20", "trim:10:10"] })
        try fill()
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        CacheFixture.drainReleases()
        #expect(await waitUntil { recorded() == ["purge:critical:20:20", "trim:10:10", "background:18:18"] })
        withExtendedLifetime(session) {}
    }

    @Test("purge 뒤 10초 동안 비운 이미지가 다시 저장된 수와 디스크에서 다시 읽힌 수를 세어 기한이 지나면 진단으로 보냄")
    func recoveryAfterPurgeIsCounted() throws {
        let clock = TestClock()
        let monitor = MemoryPressureMonitor(notificationCenter: NotificationCenter())
        let cache = CacheFixture.cache(clock: clock, monitor: monitor)
        let reports = Box<[ImageSession.Diagnostic]>([])
        cache.installDiagnosticHandlerIfNeeded { diagnostic in reports.mutate { $0.append(diagnostic) } }
        let keys = CacheFixture.keys(10)
        for key in keys {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        monitor.deliver(systemEvent: .critical)
        CacheFixture.drainReleases()
        for key in keys.prefix(5) {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        cache.noteDiskReload(forKey: keys[0])
        cache.noteDiskReload(forKey: keys[1])
        cache.noteDiskReload(forKey: keys[1])
        cache.noteDiskReload(forKey: keys[9])
        cache[keys[0]] = ImageContent(image: try CacheFixture.image())
        cache[MemoryCacheKey(key: "not-purged")] = ImageContent(image: try CacheFixture.image())

        clock.advance(by: 9)
        cache.finishRecoveryIfDue()
        let recoveries: () -> [String] = {
            reports.value.compactMap {
                guard case .memoryPressureRecovery(let reason, let redecoded, let disk) = $0 else { return nil }
                return "\(reason):\(redecoded):\(disk)"
            }
        }
        #expect(recoveries().isEmpty)
        clock.advance(by: 1)
        cache.finishRecoveryIfDue()
        #expect(recoveries() == ["critical:5:2"])
        cache.finishRecoveryIfDue()
        #expect(recoveries() == ["critical:5:2"])
    }

    @Test("파이프라인이 purge 뒤 디스크에서 다시 읽어 메모리에 넣으면 재디코딩과 디스크 재읽기로 셈")
    func sessionDiskReloadAfterPurgeIsCounted() async throws {
        let clock = TestClock()
        let monitor = MemoryPressureMonitor(notificationCenter: NotificationCenter())
        let cache = CacheFixture.cache(clock: clock, monitor: monitor)
        let delegate = RecordingDelegate()
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader, delegate: delegate) {
            $0.memoryCache = cache
            $0.diskCache = InMemoryDiskCache()
        }
        _ = try await session.imageTask(with: Fixtures.url(40)).response
        #expect(cache.totalCount == 1)
        monitor.deliver(systemEvent: .critical)
        CacheFixture.drainReleases()
        let reloaded = try await session.imageTask(with: Fixtures.url(40)).response
        #expect(reloaded.cacheType == .disk)
        #expect(loader.counts.started == 1)
        clock.advance(by: MemoryCache.recoveryWindow)
        cache.finishRecoveryIfDue()
        #expect(
            await waitUntil {
                delegate.diagnostics.value.contains {
                    if case .memoryPressureRecovery(.critical, 1, 1) = $0 { return true }
                    return false
                }
            })
    }

    @Test("저장 한 번의 축출 탐색은 max(16, 2 x 필요한 축출 수)로 제한하고, 남은 초과분은 해제 큐에서 정리")
    func admissionScanIsBoundedAndOverflowIsTrimmedLater() throws {
        #expect(MemoryCache.maximumAdmissionVisits(evictionsNeeded: 1) == 16)
        #expect(MemoryCache.maximumAdmissionVisits(evictionsNeeded: 30) == 60)
        #expect(MemoryCache.maximumAdmissionVisits(evictionsNeeded: Int.max) == Int.max)

        let cache = CacheFixture.cache(countLimit: 100)
        let keys = CacheFixture.keys(100)
        let image = try CacheFixture.image()
        for key in keys {
            cache[key] = ImageContent(image: image)
        }
        for key in keys {
            _ = cache[key]
        }
        let gate = DispatchSemaphore(value: 0)
        MemoryCache.releaseQueue.async { gate.wait() }
        cache[MemoryCacheKey(key: "newcomer")] = ImageContent(image: image)
        #expect(cache.workStatistics.largestEvictionBatch <= 16)
        #expect(cache.totalCount == 101)
        gate.signal()
        CacheFixture.drainReleases()
        #expect(cache.totalCount == 100)
        #expect(cache[MemoryCacheKey(key: "newcomer")] != nil)
    }

    @Test("백그라운드 trim은 개수 한도에도 같은 비율을 적용")
    func backgroundTrimAlsoScalesCountLimit() throws {
        let center = NotificationCenter()
        let monitor = MemoryPressureMonitor(notificationCenter: center)
        let cache = CacheFixture.cache(countLimit: 20, monitor: monitor)
        cache.lifecyclePolicy = MemoryCacheLifecyclePolicy(backgroundTrimRatio: 0.25)
        for key in CacheFixture.keys(20) {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        CacheFixture.drainReleases()
        #expect(cache.totalCount == 5)
        #expect(cache.countLimit == 20)
    }

    @Test("backgroundTrimRatio가 nil이면 백그라운드에서 그대로 둠")
    func nilBackgroundTrimRatioLeavesEntries() throws {
        let center = NotificationCenter()
        let monitor = MemoryPressureMonitor(notificationCenter: center)
        let cache = CacheFixture.cache(monitor: monitor)
        cache.lifecyclePolicy = MemoryCacheLifecyclePolicy(backgroundTrimRatio: nil)
        for key in CacheFixture.keys(10) {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        CacheFixture.drainReleases()
        #expect(cache.totalCount == 10)
    }

    @Test("비율은 0과 1 사이로 고정, NaN은 0")
    func backgroundFractionIsClamped() throws {
        let unit = try CacheFixture.unitCost()
        let center = NotificationCenter()
        let monitor = MemoryPressureMonitor(notificationCenter: center)
        let cache = CacheFixture.cache(costLimit: unit * 100, monitor: monitor)
        let keys = CacheFixture.keys(20)
        for key in keys {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        cache.lifecyclePolicy = MemoryCacheLifecyclePolicy(backgroundTrimRatio: 3)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        CacheFixture.drainReleases()
        #expect(cache.totalCount == 20)

        cache.lifecyclePolicy = MemoryCacheLifecyclePolicy(backgroundTrimRatio: .nan)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        CacheFixture.drainReleases()
        #expect(cache.totalCount == 0)

        for key in keys {
            cache[key] = ImageContent(image: try CacheFixture.image())
        }
        cache.lifecyclePolicy = MemoryCacheLifecyclePolicy(backgroundTrimRatio: -1)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        CacheFixture.drainReleases()
        #expect(cache.totalCount == 0)
    }

    @Test("백그라운드 trim으로 빠진 이미지도 밖에서 잡고 있으면 다시 찾음")
    func backgroundTrimMovesRetainedImagesToWeakCache() throws {
        let center = NotificationCenter()
        let monitor = MemoryPressureMonitor(notificationCenter: center)
        let cache = CacheFixture.cache(countLimit: 10, monitor: monitor)
        cache.isWeakCacheEnabled = true
        let keys = CacheFixture.keys(10)
        let retained = try keys.map { _ in try CacheFixture.image() }
        for (key, image) in zip(keys, retained) {
            cache[key] = ImageContent(image: image)
        }
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        CacheFixture.drainReleases()
        #expect(cache.totalCount == 1)
        for (key, image) in zip(keys, retained) {
            #expect(cache[key]?.image === image)
        }
        withExtendedLifetime(retained) {}
    }

    @Test("모니터는 등록한 응답자 모두에 한 번씩 알림")
    func monitorNotifiesEveryRegisteredCache() throws {
        let center = NotificationCenter()
        let monitor = MemoryPressureMonitor(notificationCenter: center)
        let caches = [CacheFixture.cache(monitor: monitor), CacheFixture.cache(monitor: monitor)]
        let responder = CacheFixture.RecordingResponder()
        monitor.register(responder)
        for cache in caches {
            cache[MemoryCacheKey(key: "a")] = ImageContent(image: try CacheFixture.image())
        }
        #expect(monitor.registeredCount == 3)

        monitor.deliver(systemEvent: .critical)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        CacheFixture.drainReleases()

        #expect(caches.allSatisfy { $0.totalCount == 0 })
        #expect(responder.events.value == [.critical])
        #expect(responder.backgroundThreads.value.count == 1)
        CacheFixture.drainReleases()
    }

    @Test("모니터는 캐시를 약하게 잡음")
    func monitorHoldsCachesWeakly() {
        let monitor = CacheFixture.isolatedMonitor()
        var cache: MemoryCache? = CacheFixture.cache(costLimit: 100, monitor: monitor)
        #expect(monitor.registeredCount == 1)
        if let cache {
            #expect(monitor.isRegistered(cache))
        }
        cache = nil
        #expect(monitor.registeredCount == 0)
    }

    @Test("모니터가 해제되면 알림 구독도 끊김")
    func releasedMonitorStopsObserving() throws {
        let center = NotificationCenter()
        let responder = CacheFixture.RecordingResponder()
        var monitor: MemoryPressureMonitor? = MemoryPressureMonitor(notificationCenter: center)
        monitor?.register(responder)
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #expect(responder.warningThreads.value.count == 1)
        monitor = nil
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        CacheFixture.drainReleases()
        #expect(responder.warningThreads.value.count == 1)
        #expect(responder.backgroundThreads.value.isEmpty)
        #expect(monitor == nil)
    }

    @Test("ttl 시계는 잠자기 중에도 흐르는 CLOCK_MONOTONIC을 씀")
    func expirationClockKeepsCountingDuringSleep() {
        let monotonic = TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
        let expiration = MemoryCache.expirationClock.monotonicIncludingSleep
        let uptime = TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
        #expect(abs(expiration - monotonic) < 1)
        #expect(expiration >= uptime - 1)
        #expect(MemoryCache.expirationClock.monotonicIncludingSleep >= expiration)
    }

    @Test("공개 init은 기본 NotificationCenter의 공유 모니터에 등록")
    func publicInitializerRegistersWithSharedMonitorOnDefaultCenter() {
        let cache = MemoryCache(costLimit: 100)
        #expect(MemoryPressureMonitor.shared.notificationCenter === NotificationCenter.default)
        #expect(MemoryPressureMonitor.shared.isRegistered(cache))
        #expect(MemoryPressureMonitor.shared.isRegistered(MemoryCache.shared))
    }

    @Test("MemoryCacheKey(key:)와 요청 키는 같은 문자열이어도 서로 다른 엔트리")
    func customKeysAndRequestKeysAreDistinct() throws {
        let url = "https://example.com/image.jpg"
        let custom = MemoryCacheKey(key: url)
        let request = MemoryCacheKey(request: ImageRequest(url: URL(string: url)))
        #expect(custom != request)
        #expect(MemoryCacheKey(key: url) == custom)
        #expect(MemoryCacheKey(request: ImageRequest(url: URL(string: url))) == request)

        let cache = CacheFixture.cache()
        let first = try CacheFixture.image()
        let second = try CacheFixture.image()
        cache[custom] = ImageContent(image: first)
        cache[request] = ImageContent(image: second)
        #expect(cache.totalCount == 2)
        #expect(cache[custom]?.image === first)
        #expect(cache[request]?.image === second)
    }

    @Test("요청 키는 프로세서, scale, 썸네일을 구분하고 imageID를 따름")
    func requestKeysReflectProcessorsScaleAndThumbnail() {
        let url = URL(string: "https://example.com/image.jpg")
        let plain = MemoryCacheKey(request: ImageRequest(url: url))
        let resized = MemoryCacheKey(request: ImageRequest(url: url, filters: [ImageFilters.Resize(width: 44)]))
        let resizedAgain = MemoryCacheKey(request: ImageRequest(url: url, filters: [ImageFilters.Resize(width: 44)]))
        var scaledRequest = ImageRequest(url: url)
        scaledRequest.scale = 3
        var thumbnailRequest = ImageRequest(url: url)
        thumbnailRequest.thumbnail = ImageRequest.ThumbnailOptions(maxPixelSize: 100)
        var customIDRequest = ImageRequest(url: URL(string: "https://example.com/other.jpg"))
        customIDRequest.imageID = url?.absoluteString

        #expect(resized == resizedAgain)
        #expect(plain != resized)
        #expect(plain != MemoryCacheKey(request: scaledRequest))
        #expect(plain != MemoryCacheKey(request: thumbnailRequest))
        #expect(plain == MemoryCacheKey(request: customIDRequest))
    }

    @Test("파이프라인이 디코딩 결과를 비트맵 비용으로 저장하고 두 번째는 메모리에서")
    func sessionStoresDecodedImagesInTheCache() async throws {
        let cache = CacheFixture.cache()
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader) {
            $0.memoryCache = cache
        }
        let first = try await session.imageTask(with: Fixtures.url).response
        #expect(cache.totalCount == 1)
        #expect(cache.totalCost == MemoryCache.cost(for: first.content))
        #expect(cache[MemoryCacheKey(request: ImageRequest(url: Fixtures.url))]?.image === first.image)

        let second = try await session.imageTask(with: Fixtures.url).response
        #expect(second.cacheType == .memory)
        #expect(loader.counts.started == 1)
    }

    @Test("축출한 값은 락을 푼 뒤에 해제")
    func evictedValuesAreReleasedOutsideTheLock() throws {
        let center = NotificationCenter()
        let monitor = MemoryPressureMonitor(notificationCenter: center)
        let cache = CacheFixture.cache(countLimit: 1, monitor: monitor)
        let releases = Box(0)
        func store(_ key: MemoryCacheKey) {
            autoreleasepool {
                let image = CacheFixture.reentrantImage {
                    _ = cache.totalCount
                    _ = cache[MemoryCacheKey(key: "probe")]
                    releases.mutate { $0 += 1 }
                }
                cache[key] = ImageContent(image: image)
            }
        }
        let keys = CacheFixture.keys(4)
        store(keys[0])
        store(keys[1])
        #expect(releases.value == 1)
        store(keys[1])
        #expect(releases.value == 2)
        cache[keys[1]] = nil
        #expect(releases.value == 3)
        store(keys[2])
        cache.removeAll()
        #expect(releases.value == 4)
        store(keys[3])
        cache.trim(toCount: 0)
        #expect(releases.value == 5)
        store(keys[0])
        monitor.deliver(systemEvent: .critical)
        CacheFixture.drainReleases()
        #expect(releases.value == 6)
        cache.countLimit = 10
        store(keys[1])
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        CacheFixture.drainReleases()
        cache.lifecyclePolicy = MemoryCacheLifecyclePolicy(backgroundTrimRatio: 0)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        CacheFixture.drainReleases()
        #expect(releases.value == 7)
        store(keys[2])
        cache.costLimit = 0
        #expect(releases.value == 8)
    }

    @Test("만료된 값도 락을 푼 뒤에 해제")
    func expiredValuesAreReleasedOutsideTheLock() {
        let clock = TestClock()
        let cache = CacheFixture.cache(clock: clock)
        cache.ttl = 1
        let releases = Box(0)
        let key = MemoryCacheKey(key: "a")
        autoreleasepool {
            let image = CacheFixture.reentrantImage {
                _ = cache.totalCount
                releases.mutate { $0 += 1 }
            }
            cache[key] = ImageContent(image: image)
        }
        clock.advance(by: 2)
        #expect(cache[key] == nil)
        #expect(releases.value == 1)
    }

    @Test("캐시가 해제되면 저장한 이미지도 해제")
    func deinitReleasesStoredImages() throws {
        weak var probe: UIImage?
        var cache: MemoryCache? = CacheFixture.cache()
        try autoreleasepool {
            for key in CacheFixture.keys(5) {
                let image = try CacheFixture.image()
                probe = image
                cache?[key] = ImageContent(image: image)
            }
        }
        #expect(probe != nil)
        cache = nil
        #expect(probe == nil)
        #expect(cache == nil)
    }

    @Test("8개 스레드에서 혼합 연산 10,000회 뒤에도 합계가 엔트리 비용 합과 같음")
    func concurrentMixedOperationsKeepTotalsConsistent() throws {
        let unit = try CacheFixture.unitCost()
        let center = NotificationCenter()
        let monitor = MemoryPressureMonitor(notificationCenter: center)
        let cache = CacheFixture.cache(costLimit: unit * 40, countLimit: 48, monitor: monitor)
        cache.entryCostLimit = 0.2
        cache.isWeakCacheEnabled = true
        let keys = CacheFixture.keys(96)
        let images = try (0..<16).map { index in try CacheFixture.image(width: 10 + index % 4, height: 10) }
        let threadCount = 8
        let operationsPerThread = 1250
        let performed = Box(0)

        DispatchQueue.concurrentPerform(iterations: threadCount) { thread in
            var generator = SeededGenerator(seed: UInt64(thread + 1))
            var count = 0
            for step in 0..<operationsPerThread {
                let key = keys[Int(generator.next() % UInt64(keys.count))]
                let roll = generator.next() % 100
                switch roll {
                case 0..<40:
                    _ = cache[key]
                case 40..<78:
                    let image = images[Int(generator.next() % UInt64(images.count))]
                    let data = roll.isMultiple(of: 7) ? Data(count: 64) : nil
                    cache[key] = ImageContent(image: image, data: data)
                case 78..<86:
                    cache[key] = nil
                case 86..<90:
                    cache.trim(toCount: 24)
                case 90..<93:
                    cache.trim(toCost: unit * 20)
                case 93..<95:
                    cache.countLimit = step.isMultiple(of: 2) ? 32 : 48
                case 95:
                    monitor.deliver(systemEvent: step.isMultiple(of: 2) ? .warning : .critical)
                case 96:
                    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
                    CacheFixture.drainReleases()
                case 97:
                    cache.isWeakCacheEnabled = !step.isMultiple(of: 3)
                case 98:
                    if step.isMultiple(of: 10) {
                        cache.removeAll()
                    } else {
                        _ = cache.totalCount
                    }
                default:
                    _ = cache.totalCost
                }
                count += 1
            }
            performed.mutate { $0 += count }
        }

        #expect(performed.value == 10000)
        CacheFixture.drainReleases()
        let report = cache.consistencyReport()
        #expect(report.isLinkedConsistently)
        #expect(report.recordedCost == report.summedCost)
        #expect(report.count == report.linkedCount)
        #expect(cache.totalCost == report.summedCost)
        #expect(cache.totalCount == report.count)
        #expect(cache.totalCost <= cache.costLimit)
        #expect(cache.totalCount <= cache.countLimit)
        #expect(report.recordedRemnantDataBytes == report.summedRemnantDataBytes)
        #expect(report.unmirroredEntryCount == 0)
        withExtendedLifetime(images) {}
    }
}

private final class ScriptedPressureSource: MemoryPressureEventSource {
    let recordedMask = Box<DispatchSource.MemoryPressureEvent>([])
    let cancelled = Box(false)

    var mask: DispatchSource.MemoryPressureEvent {
        recordedMask.value
    }

    var isCancelled: Bool {
        cancelled.value
    }

    func cancel() {
        cancelled.value = true
    }
}

private enum CacheFixture {
    final class Token: Sendable {}

    final class ReentrantImage: UIImage, @unchecked Sendable {
        nonisolated(unsafe) var onDeinit: (@Sendable () -> Void)?

        deinit {
            onDeinit?()
        }
    }

    final class RecordingResponder: MemoryPressureResponding {
        let warningThreads = Box<[UInt64]>([])
        let backgroundThreads = Box<[UInt64]>([])
        let events = Box<[MemoryPressureEvent]>([])

        func didReceiveMemoryPressure(_ event: MemoryPressureEvent) {
            events.mutate { $0.append(event) }
            warningThreads.mutate { $0.append(CacheFixture.currentThreadID()) }
        }

        func didEnterBackground() {
            backgroundThreads.mutate { $0.append(CacheFixture.currentThreadID()) }
        }
    }

    static func cache(
        costLimit: Int = 1 << 30,
        countLimit: Int = Int.max,
        clock: any SessionClock = SystemClock(),
        monitor: MemoryPressureMonitor? = nil
    ) -> MemoryCache {
        MemoryCache(costLimit: costLimit, countLimit: countLimit, clock: clock, monitor: monitor ?? isolatedMonitor())
    }

    static func isolatedMonitor() -> MemoryPressureMonitor {
        MemoryPressureMonitor(notificationCenter: NotificationCenter())
    }

    static func drainReleases() {
        MemoryCache.releaseQueue.sync {}
    }

    static func currentThreadID() -> UInt64 {
        var identifier: UInt64 = 0
        pthread_threadid_np(nil, &identifier)
        return identifier
    }

    static func image(width: Int = 10, height: Int = 10) throws -> UIImage {
        UIImage(cgImage: try cgImage(width: width, height: height))
    }

    static func cgImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
        context.setFillColor(UIColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    static func reentrantImage(onDeinit: @escaping @Sendable () -> Void) -> UIImage {
        let context = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let image = ReentrantImage(cgImage: context!.makeImage()!)
        image.onDeinit = onDeinit
        return image
    }

    static func unitCost() throws -> Int {
        MemoryCache.cost(for: ImageContent(image: try image()))
    }

    static func keys(_ count: Int) -> [MemoryCacheKey] {
        (0..<count).map { MemoryCacheKey(key: "key-\($0)") }
    }
}
