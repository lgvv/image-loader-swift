import Foundation
@_spi(Testing) @testable import ImageLoader
@_spi(Testing) import ImageLoaderTesting
import Testing
import os

@Suite("signpost", .serialized)
struct SignpostTests {
    private struct ExpectedFailure: Error {}

    private func withSignpostLogging<T>(_ isEnabled: Bool, _ body: () async throws -> T) async rethrows -> T {
        let previous = ImageSession.Configuration.isSignpostLoggingEnabled
        ImageSession.Configuration.isSignpostLoggingEnabled = isEnabled
        defer { ImageSession.Configuration.isSignpostLoggingEnabled = previous }
        return try await body()
    }

    @Test("꺼져 있으면 signposter를 만들지 않고 작업 결과만 돌려줌")
    func disabledPathCreatesNoHandle() throws {
        let created = Box(0)
        let signposter = SessionSignposter(
            isEnabled: { false },
            makeSignposter: {
                created.mutate { $0 += 1 }
                return .disabled
            })
        #expect(signposter.interval("DecodeImageData") { 42 } == 42)
        #expect(throws: ExpectedFailure.self) {
            try signposter.interval("ProcessImage") { () throws -> Int in throw ExpectedFailure() }
        }
        #expect(signposter.beginInterval("LoadImageData") == nil)
        #expect(created.value == 0)
        #expect(!signposter.hasCreatedSignposter)
    }

    @Test("켜져 있으면 signposter를 한 번만 만들고 구간 안의 작업 결과와 에러를 그대로 전달")
    func enabledPathCreatesHandleOnce() throws {
        let created = Box(0)
        let signposter = SessionSignposter(
            isEnabled: { true },
            makeSignposter: {
                created.mutate { $0 += 1 }
                return OSSignposter(subsystem: "ImageLoaderTests", category: "Signpost")
            })
        #expect(signposter.interval("DecodeImageData") { "decoded" } == "decoded")
        #expect(throws: ExpectedFailure.self) {
            try signposter.interval("ProcessImage") { () throws -> Int in throw ExpectedFailure() }
        }
        let interval = try #require(signposter.beginInterval("LoadImageData"))
        interval.resumed(byteCount: 10)
        interval.end(.finished(byteCount: 20))
        signposter.beginInterval("LoadImageData")?.end(.cancelled)
        signposter.beginInterval("LoadImageData")?.end(.failed)
        #expect(created.value == 1)
        #expect(signposter.hasCreatedSignposter)
    }

    @Test("기본 signposter는 Configuration.isSignpostLoggingEnabled를 호출 때마다 읽음")
    func sharedSignposterFollowsConfigurationFlag() async {
        await withSignpostLogging(false) {
            #expect(SessionSignposter.shared.beginInterval("LoadImageData") == nil)
        }
        await withSignpostLogging(true) {
            let interval = SessionSignposter.shared.beginInterval("LoadImageData")
            #expect(interval != nil)
            interval?.end(.cancelled)
            #expect(SessionSignposter.shared.hasCreatedSignposter)
        }
    }

    @Test("signpost를 켜고 끈 상태 모두에서 디코딩, 처리, 압축 해제, 인코딩 경로가 같은 결과를 냄", arguments: [true, false])
    func sessionWorksWithFlag(isEnabled: Bool) async throws {
        try await withSignpostLogging(isEnabled) {
            let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData, chunkCount: 3))
            let diskCache = InMemoryDiskCache()
            let session = makeSession(loader: loader) {
                $0.diskCache = diskCache
                $0.diskCachePolicy = .storeAll
            }
            let request = ImageRequest(url: Fixtures.url(1), filters: [TintFilter(name: "signpost")])
            let image = try await session.image(for: request)
            #expect(image.size.width == 8)
            #expect(await waitUntil { diskCache.storage.value.count == 2 })
            let data = try await session.data(for: ImageRequest(url: Fixtures.url(2)))
            #expect(data.0 == Fixtures.pngData)
        }
    }

    @Test("signpost를 켠 상태에서 실패와 취소도 그대로 전달", arguments: [true, false])
    func failureAndCancellationWithFlag(isEnabled: Bool) async {
        await withSignpostLogging(isEnabled) {
            let failing = makeSession(loader: MockDataLoader(defaultResponse: .failure(.notConnectedToInternet)))
            let failed = await result(of: failing.imageTask(with: ImageRequest(url: Fixtures.url(3))))
            #expect(failed.failureValue?.caseName == "dataLoadingFailed")

            let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
            loader.isSuspended = true
            let session = makeSession(loader: loader)
            let task = session.imageTask(with: ImageRequest(url: Fixtures.url(4)))
            #expect(await waitUntil { loader.counts.started == 1 })
            task.cancel()
            let cancelled = await result(of: task)
            #expect(cancelled.failureValue?.caseName == "cancelled")
            loader.isSuspended = false
        }
    }
}

@Suite("지연 예약 주입")
struct SessionSchedulerTests {
    @Test("TestClock.advance는 기한이 지난 예약 작업만 기한 순서대로 실행")
    func testClockRunsDueWorkInDeadlineOrder() {
        let clock = TestClock()
        let order = Box<[Int]>([])
        clock.schedule(after: 0.3) { order.mutate { $0.append(3) } }
        clock.schedule(after: 0.1) { order.mutate { $0.append(1) } }
        clock.schedule(after: 0.2) { order.mutate { $0.append(2) } }
        clock.schedule(after: 0.2) { order.mutate { $0.append(22) } }
        #expect(clock.scheduledWorkCount == 4)
        clock.advance(by: 0.05)
        #expect(order.value.isEmpty)
        clock.advance(by: 0.1)
        #expect(order.value == [1])
        clock.advanceMonotonic(by: 0.1)
        #expect(order.value == [1, 2, 22])
        clock.advanceWallClock(by: 10)
        #expect(order.value == [1, 2, 22])
        clock.advance(by: 1)
        #expect(order.value == [1, 2, 22, 3])
        #expect(clock.scheduledWorkCount == 0)
    }

    @Test("예약 작업이 다시 예약한 작업은 기한이 지났을 때만 같은 advance에서 실행")
    func reschedulingFromScheduledWork() {
        let clock = TestClock()
        let runs = Box<[String]>([])
        clock.schedule(after: 0.1) {
            runs.mutate { $0.append("first") }
            clock.schedule(after: 0) { runs.mutate { $0.append("immediate") } }
            clock.schedule(after: 1) { runs.mutate { $0.append("later") } }
        }
        clock.advance(by: 0.1)
        #expect(runs.value == ["first", "immediate"])
        #expect(clock.scheduledWorkCount == 1)
        clock.advance(by: 1)
        #expect(runs.value == ["first", "immediate", "later"])
    }

    @Test("기본 스케줄러는 SystemClock이고 조정 큐에서 실행")
    func systemSchedulerRunsOnSessionQueue() async {
        #expect(ImageSession.Configuration().scheduler is SystemClock)
        #expect(RateLimiter().scheduler is SystemClock)
        let ranOnQueue = Box<Bool?>(nil)
        SystemClock().schedule(after: 0) {
            ranOnQueue.mutate { $0 = SessionQueue.isCurrent }
        }
        #expect(await waitUntil { ranOnQueue.value != nil })
        #expect(ranOnQueue.value == true)
    }

    @Test("RateLimiter 재시도는 실제 시간을 기다리지 않고 TestClock.advance로만 토큰을 채워 실행")
    func rateLimiterRefillDrivenByTestClock() {
        let clock = TestClock()
        let executed = Box<[Int]>([])
        let limiter = SessionQueue.sync {
            let limiter = RateLimiter(rate: 10, burst: 2, clock: clock, scheduler: clock)
            for index in 0..<5 {
                limiter.execute {
                    executed.mutate { $0.append(index) }
                    return true
                }
            }
            return limiter
        }
        #expect(executed.value == [0, 1])
        #expect(clock.scheduledWorkCount == 1)
        drainSessionQueue()
        #expect(executed.value == [0, 1])

        clock.advance(by: 0.05)
        drainSessionQueue()
        #expect(executed.value == [0, 1])
        #expect(clock.scheduledWorkCount == 1)

        clock.advance(by: 0.06)
        drainSessionQueue()
        #expect(executed.value == [0, 1, 2])
        #expect(clock.scheduledWorkCount == 1)

        clock.advance(by: 0.12)
        drainSessionQueue()
        #expect(executed.value == [0, 1, 2, 3])

        clock.advance(by: 0.15)
        drainSessionQueue()
        #expect(executed.value == [0, 1, 2, 3, 4])
        #expect(SessionQueue.sync { limiter.pendingCount } == 0)
        #expect(clock.scheduledWorkCount == 0)
    }

    @Test("파이프라인의 RateLimiter는 Configuration.scheduler로 재시도를 예약")
    func sessionRateLimiterUsesConfiguredScheduler() async {
        let clock = TestClock()
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        loader.isSuspended = true
        let session = makeSession(loader: loader) {
            $0.isRateLimiterEnabled = true
            $0.clock = clock
            $0.scheduler = clock
            $0.memoryCache = nil
            $0.dataLoadingQueue.maxConcurrentOperationCount = 64
        }
        #expect(session.rateLimiter?.scheduler is TestClock)
        let tasks = (0..<27).map { session.imageTask(with: ImageRequest(url: Fixtures.url(100 + $0))) }
        #expect(await waitUntil { loader.counts.started == 25 })
        drainSessionQueue()
        #expect(SessionQueue.sync { session.rateLimiter?.pendingCount } == 2)
        #expect(clock.scheduledWorkCount == 1)
        #expect(loader.counts.started == 25)

        clock.advance(by: 0.03)
        #expect(await waitUntil { loader.counts.started == 27 })
        #expect(SessionQueue.sync { session.rateLimiter?.pendingCount } == 0)
        for task in tasks {
            task.cancel()
        }
        loader.isSuspended = false
    }
}
