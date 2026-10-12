import Foundation
import ImageLoaderTesting
import Testing
import UIKit

@testable import ImageLoader

@Suite("ImagePrefetcher")
struct ImagePrefetcherTests {
    @Test("미리 받아 메모리에 넣고 끝나면 didComplete를 main에서 부름")
    func prefetchesIntoMemory() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader)
        let prefetcher = ImagePrefetcher(session: session)
        let completed = Box(false)
        prefetcher.didComplete = { completed.value = Thread.isMainThread }
        let urls = (0..<5).map(Fixtures.url)
        prefetcher.startPrefetching(with: urls)
        #expect(await waitUntil { completed.value })
        for url in urls {
            #expect(session.cache[url] != nil)
        }
        #expect(loader.counts.started == 5)
    }

    @Test("동시 실행은 기본 2개, 우선순위는 .low")
    func concurrencyLimit() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        loader.isSuspended = true
        let session = makeSession(loader: loader)
        let prefetcher = ImagePrefetcher(session: session)
        prefetcher.startPrefetching(with: (0..<6).map(Fixtures.url))
        #expect(await waitUntil { loader.counts.started == 2 })
        drainSessionQueue()
        #expect(loader.counts.started == 2)
        #expect(prefetcher.priority == .low)
        loader.isSuspended = false
        #expect(await waitUntil { loader.counts.started == 6 })
    }

    @Test("메모리에 있으면 건너뛰고, 같은 요청은 한 번만")
    func skipsAndDeduplicates() async throws {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader)
        _ = try await session.image(for: Fixtures.url(0))
        let prefetcher = ImagePrefetcher(session: session)
        prefetcher.startPrefetching(with: [Fixtures.url(0), Fixtures.url(1), Fixtures.url(1)])
        #expect(await waitUntil { prefetcher.pendingTaskCount == 0 && loader.counts.started == 2 })
        drainSessionQueue()
        #expect(loader.counts.started == 2)
    }

    @Test("멈추면 대기 중과 진행 중 작업을 취소하고 슬롯을 돌려줌")
    func stopCancelsAndReleasesSlots() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        loader.isSuspended = true
        let session = makeSession(loader: loader)
        let prefetcher = ImagePrefetcher(session: session)
        prefetcher.startPrefetching(with: (0..<4).map(Fixtures.url))
        #expect(await waitUntil { loader.counts.started == 2 })
        prefetcher.stopPrefetching(with: [Fixtures.url(0)])
        #expect(await waitUntil { loader.counts.started == 3 })
        prefetcher.stopPrefetching()
        #expect(await waitUntil { prefetcher.pendingTaskCount == 0 })
        drainSessionQueue()
        drainSessionQueue()
        loader.isSuspended = false
        #expect(await waitUntil { loader.counts.cancelled == 3 })
        prefetcher.startPrefetching(with: [Fixtures.url(10), Fixtures.url(11)])
        #expect(await waitUntil { loader.counts.started == 5 })
    }

    @Test("멈춘 작업의 취소 이벤트가 나중에 와도 didComplete를 다시 부르지 않고, invalidate로 취소된 작업은 목록에서 빠져 didComplete를 부름")
    func cancelledTaskEventDoesNotRepeatDidComplete() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        loader.isSuspended = true
        let session = makeSession(loader: loader)
        let prefetcher = ImagePrefetcher(session: session)
        let completions = Box(0)
        prefetcher.didComplete = { completions.mutate { $0 += 1 } }
        prefetcher.startPrefetching(with: [Fixtures.url(0)])
        #expect(await waitUntil { loader.counts.started == 1 })
        prefetcher.stopPrefetching(with: [Fixtures.url(0)])
        #expect(await waitUntil { completions.value == 1 })
        drainSessionQueue()
        drainSessionQueue()
        await MainActor.run {}
        #expect(completions.value == 1)

        prefetcher.startPrefetching(with: [Fixtures.url(1)])
        #expect(await waitUntil { loader.counts.started == 2 })
        session.invalidate()
        #expect(await waitUntil { completions.value == 2 && prefetcher.pendingTaskCount == 0 })
        drainSessionQueue()
        await MainActor.run {}
        #expect(completions.value == 2)
        loader.isSuspended = false
    }

    @Test("디스크 대상은 디코딩 없이 원본만 저장")
    func diskDestination() async {
        let decodeCount = Box(0)
        let diskCache = InMemoryDiskCache()
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader) {
            $0.diskCache = diskCache
            $0.makeImageDecoder = { _ in CountingDecoder(counter: decodeCount) }
        }
        let prefetcher = ImagePrefetcher(session: session, destination: .diskCache)
        prefetcher.startPrefetching(with: [Fixtures.url])
        #expect(await waitUntil { diskCache.storage.value[Fixtures.url.absoluteString] != nil })
        #expect(decodeCount.value == 0)
        #expect(session.cache[Fixtures.url] == nil)
    }

    @Test("일시정지하면 새 작업을 시작하지 않음")
    func pause() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader)
        let prefetcher = ImagePrefetcher(session: session)
        prefetcher.isPaused = true
        prefetcher.startPrefetching(with: [Fixtures.url])
        drainSessionQueue()
        drainSessionQueue()
        #expect(loader.counts.started == 0)
        prefetcher.isPaused = false
        #expect(await waitUntil { loader.counts.started == 1 })
    }
}

@Suite("파이프라인 스트레스", .serialized)
struct ImageSessionStressTests {
    @Test("요청 2,000개(URL 50개, 1/3 취소) 뒤 진행 중 작업과 풀이 모두 비고, 같은 URL의 다운로드는 동시에 하나만 진행")
    func randomizedLoadAndCancel() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData, chunkCount: 2))
        let session = makeSession(loader: loader) {
            $0.isRateLimiterEnabled = true
        }
        var generator = SeededGenerator(seed: 42)
        var tasks: [ImageTask] = []
        for index in 0..<2_000 {
            let url = Fixtures.url(Int.random(in: 0..<50, using: &generator))
            let priority = ImageRequest.Priority.allCases.randomElement(using: &generator)!
            let task = session.imageTask(with: ImageRequest(url: url, priority: priority))
            tasks.append(task)
            if index % 3 == 0 {
                task.cancel()
            } else if index % 7 == 0 {
                task.priority = .veryHigh
            }
        }
        for task in tasks {
            _ = await result(of: task)
        }
        #expect(await waitUntil(timeout: 10) { session.runningTaskCount == 0 })
        SessionQueue.sync {
            #expect(session.prepareImageStages.count == 0)
            #expect(session.decodeImageStages.count == 0)
            #expect(session.fetchDataStages.count == 0)
        }
        #expect(
            await waitUntil {
                let counts = loader.counts
                return counts.started == counts.completed + counts.cancelled
            })
        let counts = loader.counts
        #expect(loader.maximumConcurrentLoadsPerURL == 1)
        print(
            "BENCH|core_stress|requests=2000|started=\(counts.started)|completed=\(counts.completed)|cancelled=\(counts.cancelled)|max_concurrent_per_url=\(loader.maximumConcurrentLoadsPerURL)"
        )
    }
}

extension ImageSessionStressTests {
    @Test("스트림: 청크 200개짜리 작업 1만 개에 임의 스레드 cancel()을 한 번씩 불러 progress와 경쟁시켜도 .finished는 한 번이고 항상 마지막 (ST-13)")
    func noStreamEventAfterFinishedUnderCancelRace() async {
        let iterations = 10_000
        let loader = MockDataLoader(defaultResponse: .data(streamRaceFixture, chunkCount: 200))
        let streams = StreamCapturingDelegate()
        let session = makeSession(loader: loader, delegate: streams) {
            $0.memoryCache = nil
            $0.dataLoadingQueue = TaskQueue(maxConcurrentOperationCount: 16)
        }
        var generator = SeededGenerator(seed: 13)
        let cancelPoints = (0..<iterations).map { _ in Int.random(in: 0..<200, using: &generator) }
        let outcomes = await withTaskGroup(of: StreamRaceOutcome.self, returning: [StreamRaceOutcome].self) { group in
            var next = 0
            var outcomes: [StreamRaceOutcome] = []
            func addNext() {
                let index = next
                next += 1
                group.addTask {
                    await runStreamRace(session: session, streams: streams, index: index, cancelAfterProgress: cancelPoints[index])
                }
            }
            for _ in 0..<16 {
                addNext()
            }
            for await outcome in group {
                outcomes.append(outcome)
                if next < iterations {
                    addNext()
                }
            }
            return outcomes
        }
        #expect(outcomes.count == iterations)
        #expect(outcomes.filter { !$0.didCallCancel }.isEmpty)
        #expect(outcomes.filter { $0.finishedCount != 1 }.isEmpty)
        #expect(outcomes.filter { $0.eventsAfterFinished > 0 }.isEmpty)
        #expect(await waitUntil(timeout: 10) { session.runningTaskCount == 0 })
        SessionQueue.sync {
            #expect(session.prepareImageStages.count == 0)
            #expect(session.decodeImageStages.count == 0)
            #expect(session.fetchDataStages.count == 0)
        }
        let cancelled = outcomes.filter(\.wasCancelled).count
        let maxProgress = outcomes.map(\.progressCount).max() ?? 0
        let cancelCalls = outcomes.filter(\.didCallCancel).count
        print("BENCH|stream_cancel_race|iterations=\(iterations)|cancel_calls=\(cancelCalls)|cancelled=\(cancelled)|max_progress=\(maxProgress)")
    }
}

private let streamRaceFixture: Data = {
    var generator = SeededGenerator(seed: 7)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48), format: format).image { context in
        for y in 0..<48 {
            for x in 0..<48 {
                let value = CGFloat(generator.next() % 256) / 255
                UIColor(red: value, green: 1 - value, blue: 0.5, alpha: 1).setFill()
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
    }
    return image.pngData()!
}()

private struct StreamRaceOutcome: Sendable {
    var finishedCount = 0
    var eventsAfterFinished = 0
    var progressCount = 0
    var wasCancelled = false
    var didCallCancel = false
}

private final class StreamCapturingDelegate: ImageSession.Delegate, @unchecked Sendable {
    private let streams = Box<[UInt64: AsyncStream<ImageTask.Event>]>([:])

    func imageTaskCreated(_ task: ImageTask, session: ImageSession) {
        let stream = task.events
        streams.mutate { $0[task.taskId] = stream }
    }

    func takeStream(for task: ImageTask) -> AsyncStream<ImageTask.Event>? {
        streams.mutate { $0.removeValue(forKey: task.taskId) }
    }
}

private func runStreamRace(session: ImageSession, streams: StreamCapturingDelegate, index: Int, cancelAfterProgress: Int) async -> StreamRaceOutcome {
    let task = session.imageTask(with: Fixtures.url(index))
    guard let stream = streams.takeStream(for: task) else {
        return StreamRaceOutcome()
    }
    var outcome = StreamRaceOutcome()
    if cancelAfterProgress == 0 {
        outcome.didCallCancel = true
        DispatchQueue(label: "ImageLoaderTests.ImagePrefetcherAndStressTests").async { task.cancel() }
    }
    for await event in stream {
        if outcome.finishedCount > 0 {
            outcome.eventsAfterFinished += 1
        }
        switch event {
        case .started, .preview:
            break
        case .progress:
            outcome.progressCount += 1
            if outcome.progressCount == cancelAfterProgress {
                outcome.didCallCancel = true
                DispatchQueue(label: "ImageLoaderTests.ImagePrefetcherAndStressTests").async { task.cancel() }
            }
        case .finished(let result):
            outcome.finishedCount += 1
            outcome.wasCancelled = result.failureValue?.caseName == "cancelled"
        }
    }
    return outcome
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
