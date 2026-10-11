import Foundation
@_spi(Testing) @testable import ImageLoader
@_spi(Testing) import ImageLoaderTesting
import Testing

@Suite("TaskQueue")
struct TaskQueueTests {
    @Test("동시 실행 수를 넘지 않고, 높은 우선순위부터 같은 우선순위는 들어온 순서로 실행")
    func runsByPriorityWithinLimit() async {
        let queue = TaskQueue(maxConcurrentOperationCount: 1)
        let order = Box<[String]>([])
        let finishers = Box<[@Sendable () -> Void]>([])
        SessionQueue.sync {
            for (name, priority) in [("blocker", ImageRequest.Priority.normal), ("low", .low), ("high1", .high), ("normal", .normal), ("high2", .high)] {
                queue.add(priority: priority) { finish in
                    order.mutate { $0.append(name) }
                    finishers.mutate { $0.append(finish) }
                }
            }
        }
        for expected in 1...5 {
            #expect(await waitUntil { order.value.count == expected })
            SessionQueue.sync {
                #expect(queue.operationCount.running == 1)
            }
            finishers.value[expected - 1]()
        }
        #expect(order.value == ["blocker", "high1", "high2", "normal", "low"])
    }

    @Test("대기 중인 작업을 취소하면 실행하지 않고, 실행 중 취소는 onCancelled만 부름")
    func cancellation() async {
        let queue = TaskQueue(maxConcurrentOperationCount: 1)
        let started = Box<[String]>([])
        let cancelledRunning = Box(false)
        let finish = Box<(@Sendable () -> Void)?>(nil)
        var running: TaskQueue.Operation!
        var pending: TaskQueue.Operation!
        SessionQueue.sync {
            running = queue.add { done in
                started.mutate { $0.append("running") }
                finish.value = done
            }
            running.onCancelled = { cancelledRunning.value = true }
            pending = queue.add { _ in
                started.mutate { $0.append("pending") }
            }
        }
        SessionQueue.sync {
            pending.cancel()
            running.cancel()
        }
        #expect(cancelledRunning.value)
        finish.value?()
        drainSessionQueue()
        drainSessionQueue()
        #expect(started.value == ["running"])
        SessionQueue.sync {
            #expect(queue.operationCount.pending == 0)
            #expect(queue.operationCount.running == 0)
        }
    }

    @Test("우선순위가 오르면 새 버킷 뒤에, 내리면 새 버킷 앞에 놓임")
    func priorityChangeReordersPending() async {
        let queue = TaskQueue(maxConcurrentOperationCount: 1)
        let order = Box<[String]>([])
        let finishers = Box<[@Sendable () -> Void]>([])
        SessionQueue.sync {
            queue.add(priority: .veryHigh) { finish in
                order.mutate { $0.append("blocker") }
                finishers.mutate { $0.append(finish) }
            }
            queue.add(priority: .high) { finish in
                order.mutate { $0.append("high") }
                finishers.mutate { $0.append(finish) }
            }
            let raised = queue.add(priority: .low) { finish in
                order.mutate { $0.append("raised") }
                finishers.mutate { $0.append(finish) }
            }
            queue.add(priority: .normal) { finish in
                order.mutate { $0.append("normal") }
                finishers.mutate { $0.append(finish) }
            }
            let lowered = queue.add(priority: .veryHigh) { finish in
                order.mutate { $0.append("lowered") }
                finishers.mutate { $0.append(finish) }
            }
            raised.priority = .high
            lowered.priority = .normal
        }
        for expected in 1...5 {
            #expect(await waitUntil { order.value.count == expected })
            finishers.value[expected - 1]()
        }
        #expect(order.value == ["blocker", "high", "raised", "lowered", "normal"])
    }

    @Test("finish를 여러 번 불러도 슬롯은 한 번만 반납")
    func finishIsIdempotent() async {
        let queue = TaskQueue(maxConcurrentOperationCount: 1)
        let started = Box(0)
        SessionQueue.sync {
            queue.add { finish in
                started.mutate { $0 += 1 }
                finish()
                finish()
                finish()
            }
            queue.add { _ in started.mutate { $0 += 1 } }
            queue.add { _ in started.mutate { $0 += 1 } }
        }
        #expect(await waitUntil { started.value == 2 })
        drainSessionQueue()
        drainSessionQueue()
        #expect(started.value == 2)
        SessionQueue.sync {
            #expect(queue.operationCount.running == 1)
        }
    }

    @Test("일시정지하면 새 작업을 시작하지 않고, 풀면 이어서 실행")
    func suspension() async {
        let queue = TaskQueue(maxConcurrentOperationCount: 2)
        queue.isSuspended = true
        let started = Box(0)
        SessionQueue.sync {
            for _ in 0..<3 {
                queue.add { finish in
                    started.mutate { $0 += 1 }
                    finish()
                }
            }
        }
        drainSessionQueue()
        #expect(started.value == 0)
        queue.isSuspended = false
        #expect(await waitUntil { started.value == 3 })
    }
}

@Suite("RateLimiter")
struct RateLimiterTests {
    @Test("버스트를 넘으면 대기하고, 시간이 흐른 만큼 토큰을 채워 FIFO로 실행")
    func tokenBucket() {
        let clock = TestClock()
        let executed = Box<[Int]>([])
        SessionQueue.sync {
            let limiter = RateLimiter(rate: 10, burst: 3, clock: clock)
            for index in 0..<6 {
                limiter.execute {
                    executed.mutate { $0.append(index) }
                    return true
                }
            }
            #expect(executed.value == [0, 1, 2])
            #expect(limiter.pendingCount == 3)
            clock.advance(by: 0.2)
            limiter.executePendingTasks()
            #expect(executed.value == [0, 1, 2, 3, 4])
            clock.advance(by: 1)
            limiter.executePendingTasks()
            #expect(executed.value == [0, 1, 2, 3, 4, 5])
            #expect(limiter.pendingCount == 0)
        }
    }

    @Test("취소된 작업(false 반환)은 토큰을 쓰지 않음")
    func cancelledWorkDoesNotConsumeTokens() {
        let clock = TestClock()
        let executed = Box(0)
        SessionQueue.sync {
            let limiter = RateLimiter(rate: 10, burst: 2, clock: clock)
            for _ in 0..<5 {
                limiter.execute { false }
            }
            limiter.execute {
                executed.mutate { $0 += 1 }
                return true
            }
            limiter.execute {
                executed.mutate { $0 += 1 }
                return true
            }
            #expect(executed.value == 2)
        }
    }
}

@Suite("기반 자료구조")
struct InternalStructureTests {
    @Test("LinkedList 추가, 앞에 추가, 삭제, 끝으로 이동")
    func linkedList() {
        let list = LinkedList<Int>()
        let a = list.append(1)
        list.append(2)
        list.prepend(0)
        list.moveToLast(a)
        var values: [Int] = []
        var node = list.first
        while let current = node {
            values.append(current.value)
            node = current.next
        }
        #expect(values == [0, 2, 1])
        list.remove(a)
        #expect(list.count == 2)
        #expect(list.last?.value == 2)
        list.removeAllElements()
        #expect(list.isEmpty)
    }

    @Test("LockIsolated 제자리 수정과 testAndSet")
    func lockIsolated() async {
        let counter = LockIsolated(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<1000 {
                        counter.withLock { $0 += 1 }
                    }
                }
            }
        }
        #expect(counter.value == 8000)
        let flag = LockIsolated(false)
        #expect(flag.testAndSet(true))
        #expect(!flag.testAndSet(true))
    }

    @Test("ImageRequest는 복사 후 수정해도 원본이 바뀌지 않음 (copy-on-write)")
    func requestCopyOnWrite() {
        var original = ImageRequest(url: Fixtures.url, priority: .low)
        let copy = original
        original.priority = .high
        original.filters = [TintFilter(name: "a")]
        #expect(copy.priority == .low)
        #expect(copy.filters.isEmpty)
        #expect(original.priority == .high)
        #expect(ImageRequest(stringLiteral: "https://example.com/a.png").url?.absoluteString == "https://example.com/a.png")
    }

    @Test("Options 비트 배치는 고정 값")
    func optionBits() {
        #expect(ImageRequest.Options.disableMemoryCacheReads.rawValue == 1 << 0)
        #expect(ImageRequest.Options.disableMemoryCacheWrites.rawValue == 1 << 1)
        #expect(ImageRequest.Options.disableDiskCacheReads.rawValue == 1 << 2)
        #expect(ImageRequest.Options.disableDiskCacheWrites.rawValue == 1 << 3)
        #expect(ImageRequest.Options.returnCacheDataDontLoad.rawValue == 1 << 4)
        #expect(ImageRequest.Options.skipDecompression.rawValue == 1 << 5)
        #expect(ImageRequest.Options.skipDataLoadingQueue.rawValue == 1 << 6)
        #expect(ImageRequest.Options.reloadIgnoringCachedData == [.disableMemoryCacheReads, .disableDiskCacheReads])
    }

    @Test("요청 확장 플래그는 userInfo에 저장되고 데이터 키에 반영")
    func requestExtensions() {
        var request = ImageRequest(url: Fixtures.url)
        request.revalidatesCachedData = true
        request.bypassesFailureCooldown = true
        #expect(request.revalidatesCachedData)
        #expect(request.bypassesFailureCooldown)
        #expect(request.effectiveOptions.contains(.disableMemoryCacheReads))
        #expect(FetchDataStageKey(request) != FetchDataStageKey(ImageRequest(url: Fixtures.url)))
    }

    @Test("백그라운드 스레드의 화면 배율은 메인 스레드에서 읽은 값과 같음")
    func screenScaleOffMainMatchesMain() async {
        let mainScale = await MainActor.run { Screen.scale }
        let backgroundScale = await Task.detached { Screen.scale }.value
        #expect(mainScale > 0)
        #expect(backgroundScale == mainScale)
    }
}
