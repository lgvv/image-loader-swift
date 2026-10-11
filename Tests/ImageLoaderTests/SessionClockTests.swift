import Darwin
import Foundation
@_spi(Testing) @testable import ImageLoader
@_spi(Testing) import ImageLoaderTesting
import Testing

@Suite("파이프라인 시계")
struct SessionClockTests {
    private func expectReading(of clock: SystemClock, bracketedBy clockID: clockid_t, sourceLocation: SourceLocation = #_sourceLocation) {
        let before = clock_gettime_nsec_np(clockID)
        let reading = clock.monotonicIncludingSleep
        let after = clock_gettime_nsec_np(clockID)
        #expect(TimeInterval(before) / 1_000_000_000 <= reading, sourceLocation: sourceLocation)
        #expect(reading <= TimeInterval(after) / 1_000_000_000, sourceLocation: sourceLocation)
    }

    private func expectMonotonicIncludingSleep(_ clock: any SessionClock, sourceLocation: SourceLocation = #_sourceLocation) {
        let system = clock as? SystemClock
        #expect(system?.clockID == CLOCK_MONOTONIC, sourceLocation: sourceLocation)
        if let system {
            expectReading(of: system, bracketedBy: CLOCK_MONOTONIC, sourceLocation: sourceLocation)
        }
    }

    @Test("기본 시계는 잠자기 중에도 흐르는 CLOCK_MONOTONIC이고 uptime 시계가 아님")
    func clockSourceIncludesSleep() {
        #expect(SystemClock.monotonicClockID == CLOCK_MONOTONIC)
        #expect(SystemClock.monotonicClockID != CLOCK_UPTIME_RAW)
        #expect(SystemClock.monotonicClockID != CLOCK_UPTIME_RAW_APPROX)
        expectMonotonicIncludingSleep(SystemClock())
        expectMonotonicIncludingSleep(ImageSession.Configuration().clock)
    }

    @Test("SystemClock은 저장한 clockID를 읽음 (호스트의 잠자기 누적과 무관한 소스 고정)")
    func systemClockReadsItsClockID() {
        expectReading(of: SystemClock(clockID: CLOCK_PROCESS_CPUTIME_ID), bracketedBy: CLOCK_PROCESS_CPUTIME_ID)
        expectReading(of: SystemClock(clockID: CLOCK_MONOTONIC), bracketedBy: CLOCK_MONOTONIC)
        let cpu = SystemClock(clockID: CLOCK_PROCESS_CPUTIME_ID).monotonicIncludingSleep
        let monotonic = SystemClock().monotonicIncludingSleep
        #expect(monotonic - cpu > 1)
    }

    @Test("RateLimiter의 기본 시계는 잠자기를 포함하는 단조 시계")
    func rateLimiterClockSourceIncludesSleep() {
        expectMonotonicIncludingSleep(RateLimiter().clock)
        let session = ImageSession(configuration: ImageSession.Configuration(dataLoader: MockDataLoader()))
        #expect(session.rateLimiter != nil)
        if let limiter = session.rateLimiter {
            expectMonotonicIncludingSleep(limiter.clock)
        }
    }

    @Test("RateLimiter.clock은 생성 때 정한 저장 프로퍼티라 조정 큐 밖에서 읽어도 토큰 보충과 겹치지 않음")
    func rateLimiterClockIsStoredOutsideBucket() async {
        let clock = TestClock()
        let limiter = RateLimiter(rate: 1_000, burst: 1, clock: clock)
        #expect(Mirror(reflecting: limiter).children.contains { $0.label == "clock" && $0.value is TestClock })
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<200 {
                    SessionQueue.sync {
                        limiter.execute { true }
                        clock.advanceMonotonic(by: 0.001)
                        limiter.executePendingTasks()
                    }
                }
            }
            group.addTask {
                for _ in 0..<200 {
                    #expect(limiter.clock is TestClock)
                }
            }
        }
    }

    @Test("RateLimiter 토큰 보충은 벽시계가 앞뒤로 바뀌어도 움직이지 않고 단조 값으로만 채워짐")
    func rateLimiterRefillIgnoresWallClock() {
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000), monotonicIncludingSleep: 50)
        let executed = Box<[Int]>([])
        SessionQueue.sync {
            let limiter = RateLimiter(rate: 10, burst: 1, clock: clock)
            for index in 0..<2 {
                limiter.execute {
                    executed.mutate { $0.append(index) }
                    return true
                }
            }
            #expect(executed.value == [0])
            clock.advanceWallClock(by: 3_600)
            limiter.executePendingTasks()
            #expect(executed.value == [0])
            clock.advanceWallClock(by: -7_200)
            limiter.executePendingTasks()
            #expect(executed.value == [0])
            clock.advanceMonotonic(by: 0.05)
            limiter.executePendingTasks()
            #expect(executed.value == [0])
            clock.advanceMonotonic(by: 0.06)
            limiter.executePendingTasks()
            #expect(executed.value == [0, 1])
            #expect(limiter.pendingCount == 0)
        }
    }

    @Test("쿨다운 만료는 벽시계 변경과 무관하게 단조 값으로 판정하고, until은 벽시계 오프셋을 따라감")
    func cooldownExpiryIgnoresWallClock() async {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let clock = TestClock(now: start, monotonicIncludingSleep: 50)
        let loader = MockDataLoader(defaultResponse: .data(Data(), statusCode: 404))
        let session = makeSession(loader: loader) {
            $0.failureCooldown = ImageSession.FailureCooldownPolicy(baseInterval: 2, maximumInterval: 300, countLimit: 512)
            $0.clock = clock
            $0.memoryCache = nil
        }
        _ = await result(of: session.imageTask(with: Fixtures.url))
        #expect(loader.counts.started == 1)

        clock.advanceWallClock(by: 3_600)
        let afterForwardJump = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(afterForwardJump?.cooldown?.until == start.addingTimeInterval(3_602))
        #expect(loader.counts.started == 1)

        clock.advanceWallClock(by: -7_200)
        let afterBackwardJump = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(afterBackwardJump?.cooldown?.until == start.addingTimeInterval(-3_598))
        #expect(loader.counts.started == 1)

        clock.advanceMonotonic(by: 1.5)
        let afterMonotonicStep = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(afterMonotonicStep?.cooldown?.until == start.addingTimeInterval(-3_599.5))
        #expect(loader.counts.started == 1)

        clock.advanceMonotonic(by: 0.6)
        _ = await result(of: session.imageTask(with: Fixtures.url))
        #expect(loader.counts.started == 2)
    }

    @Test("쿨다운의 기본 시계는 잠자기를 포함하는 단조 시계이고, until은 벽시계로 환산")
    func cooldownClockSourceIncludesSleep() async {
        let loader = MockDataLoader(defaultResponse: .data(Data(), statusCode: 404))
        let session = makeSession(loader: loader) {
            $0.failureCooldown = ImageSession.FailureCooldownPolicy(baseInterval: 300, maximumInterval: 300, countLimit: 512)
            $0.memoryCache = nil
        }
        #expect(session.failureCooldown != nil)
        if let table = session.failureCooldown {
            expectMonotonicIncludingSleep(table.clock)
        }
        _ = await result(of: session.imageTask(with: Fixtures.url))
        let blocked = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        let until = blocked?.cooldown?.until
        #expect(until != nil)
        if let until {
            let remaining = until.timeIntervalSince(Date())
            #expect(remaining > 240 && remaining <= 300)
        }
    }

    @Test("쿨다운은 주입한 시계의 단조 값으로 만료를 판정하고 until은 주입 시계의 now로 환산")
    func cooldownUsesInjectedClock() async {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let clock = TestClock(now: start, monotonicIncludingSleep: 50)
        let loader = MockDataLoader(defaultResponse: .data(Data(), statusCode: 404))
        let session = makeSession(loader: loader) {
            $0.failureCooldown = ImageSession.FailureCooldownPolicy(baseInterval: 2, maximumInterval: 300, countLimit: 512)
            $0.clock = clock
            $0.memoryCache = nil
        }
        #expect(session.failureCooldown?.clock is TestClock)
        _ = await result(of: session.imageTask(with: Fixtures.url))
        clock.advance(by: 0.5)
        let blocked = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(blocked?.cooldown?.until == start.addingTimeInterval(2))
        #expect(loader.counts.started == 1)
        clock.advance(by: 1.6)
        _ = await result(of: session.imageTask(with: Fixtures.url))
        #expect(loader.counts.started == 2)
    }

    @Test("TestClock.advance는 두 값을 함께, advanceWallClock과 advanceMonotonic은 한쪽만 옮김")
    func testClockAdvancesReadings() {
        let clock = TestClock()
        #expect(clock.now == Date(timeIntervalSinceReferenceDate: 0))
        #expect(clock.monotonicIncludingSleep == 0)
        clock.advance(by: 3)
        #expect(clock.now == Date(timeIntervalSinceReferenceDate: 3))
        #expect(clock.monotonicIncludingSleep == 3)
        clock.advanceWallClock(by: -10)
        #expect(clock.now == Date(timeIntervalSinceReferenceDate: -7))
        #expect(clock.monotonicIncludingSleep == 3)
        clock.advanceMonotonic(by: 4)
        #expect(clock.now == Date(timeIntervalSinceReferenceDate: -7))
        #expect(clock.monotonicIncludingSleep == 7)
    }
}
