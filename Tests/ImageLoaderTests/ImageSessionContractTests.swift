import Combine
import Foundation
import ImageLoaderTesting
import Testing
import UIKit

@testable import ImageLoader

@Suite("파이프라인 기본 계약")
struct ImageSessionContractTests {
    @Test("작업은 만들자마자 시작")
    func taskStartsImmediately() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        loader.isSuspended = true
        let session = makeSession(loader: loader)
        let task = session.imageTask(with: Fixtures.url)
        #expect(await waitUntil { loader.counts.started == 1 })
        #expect(task.state == .running)
        loader.isSuspended = false
        _ = try? await task.image
        #expect(task.state == .completed)
    }

    @Test("네트워크에서 받고, 두 번째는 메모리 캐시에서")
    func loadsThenHitsMemoryCache() async throws {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader)
        let first = try await session.imageTask(with: Fixtures.url).response
        #expect(first.cacheType == nil)
        #expect(first.urlResponse != nil)
        let second = try await session.imageTask(with: Fixtures.url).response
        #expect(second.cacheType == .memory)
        #expect(loader.counts.started == 1)
        #expect(session.cache[Fixtures.url] != nil)
    }

    @Test("같은 요청 10개는 다운로드 한 번으로 합침")
    func coalescesIdenticalRequests() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        loader.isSuspended = true
        let session = makeSession(loader: loader)
        let tasks = (0..<10).map { _ in session.imageTask(with: Fixtures.url) }
        #expect(await waitUntil { loader.counts.started == 1 })
        loader.isSuspended = false
        for task in tasks {
            #expect((try? await task.image) != nil)
        }
        #expect(loader.counts.started == 1)
    }

    @Test("프로세서가 달라도 다운로드와 디코딩은 한 번")
    func sharesDataAndDecodingAcrossFilters() async {
        let decodeCount = Box(0)
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        loader.isSuspended = true
        let session = makeSession(loader: loader) {
            $0.makeImageDecoder = { _ in CountingDecoder(counter: decodeCount) }
        }
        let plain = session.imageTask(with: ImageRequest(url: Fixtures.url))
        let tintA = session.imageTask(with: ImageRequest(url: Fixtures.url, filters: [TintFilter(name: "a")]))
        let tintB = session.imageTask(with: ImageRequest(url: Fixtures.url, filters: [TintFilter(name: "b")]))
        #expect(await waitUntil { loader.counts.started == 1 })
        loader.isSuspended = false
        for task in [plain, tintA, tintB] {
            #expect((try? await task.image) != nil)
        }
        #expect(loader.counts.started == 1)
        #expect(decodeCount.value == 1)
    }

    @Test("합치기를 끄면 요청마다 따로 받음")
    func coalescingDisabled() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        loader.isSuspended = true
        let session = makeSession(loader: loader) {
            $0.isTaskCoalescingEnabled = false
            $0.memoryCache = nil
        }
        let tasks = (0..<3).map { _ in session.imageTask(with: Fixtures.url) }
        #expect(await waitUntil { loader.counts.started == 3 })
        loader.isSuspended = false
        for task in tasks {
            _ = try? await task.image
        }
        #expect(loader.counts.started == 3)
    }

    @Test("이벤트 스트림: started, progress, finished 순서, 끝난 뒤 구독하면 빈 스트림")
    func eventStream() async throws {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.png(width: 64, height: 64), chunkCount: 4))
        loader.isSuspended = true
        let session = makeSession(loader: loader)
        let task = session.imageTask(with: Fixtures.url)
        let events = task.events
        loader.isSuspended = false
        var progressCount = 0
        var finished = false
        for await event in events {
            switch event {
            case .started:
                break
            case .progress:
                progressCount += 1
            case .preview:
                break
            case .finished(let result):
                finished = (try? result.get()) != nil
            }
        }
        #expect(progressCount == 4)
        #expect(finished)
        #expect(task.currentProgress.completed == task.currentProgress.total)
        var lateEvents = 0
        for await _ in task.events {
            lateEvents += 1
        }
        #expect(lateEvents == 0)
    }

    @Test("delegate: imageTaskCreated는 호출 스레드에서 동기로, 이벤트는 started와 finished")
    func delegateEvents() async throws {
        let delegate = RecordingDelegate()
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader, delegate: delegate)
        let task = session.imageTask(with: Fixtures.url)
        #expect(delegate.createdTaskIDs.value == [task.taskId])
        _ = try await task.image
        #expect(await waitUntil { delegate.finishedEvents(for: task.taskId).count == 1 })
        let kinds = delegate.events.value.filter { $0.0 == task.taskId }.map { event -> String in
            switch event.1 {
            case .started: "started"
            case .progress: "progress"
            case .preview: "preview"
            case .finished: "finished"
            }
        }
        #expect(kinds.first == "started")
        #expect(kinds.last == "finished")
    }

    @Test("willLoadData로 헤더를 붙임")
    func willLoadDataInjectsHeaders() async throws {
        let delegate = RecordingDelegate(headers: ["X-Test-Token": "value"])
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader, delegate: delegate)
        _ = try await session.image(for: Fixtures.url)
        #expect(loader.requests.first?.value(forHTTPHeaderField: "X-Test-Token") == "value")
    }

    @Test("data(for:)는 디코딩 없이 원본 데이터를 돌려줌")
    func dataTask() async throws {
        let decodeCount = Box(0)
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader) {
            $0.makeImageDecoder = { _ in CountingDecoder(counter: decodeCount) }
        }
        let (data, response) = try await session.data(for: ImageRequest(url: Fixtures.url))
        #expect(data == Fixtures.pngData)
        #expect(response != nil)
        #expect(decodeCount.value == 0)
    }

    @Test("프로세서를 적용하고, 결과는 프로세서별 키로 메모리에 저장")
    func appliesFilters() async throws {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader)
        let request = ImageRequest(url: Fixtures.url, filters: [ImageFilters.Resize(size: CGSize(width: 2, height: 2), unit: .pixels)])
        let image = try await session.image(for: request)
        #expect(image.cgImage?.width == 2)
        #expect(session.cache[request] != nil)
        #expect(session.cache.makeMemoryCacheKey(for: request) != session.cache.makeMemoryCacheKey(for: ImageRequest(url: Fixtures.url)))
    }

    @Test("디스크 캐시: 받은 원본을 저장하고, 메모리를 비운 뒤에는 디스크에서 읽음")
    func diskCacheRoundTrip() async throws {
        let diskCache = InMemoryDiskCache()
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader) {
            $0.diskCache = diskCache
        }
        _ = try await session.image(for: Fixtures.url)
        #expect(await waitUntil { diskCache.storage.value[Fixtures.url.absoluteString] != nil })
        session.cache.removeAll(caches: .memory)
        let response = try await session.imageTask(with: Fixtures.url).response
        #expect(response.cacheType == .disk)
        #expect(loader.counts.started == 1)
    }

    @Test("디스크의 손상 데이터는 지우고 네트워크로 다시 받음")
    func corruptedDiskDataIsReplaced() async throws {
        let diskCache = InMemoryDiskCache()
        diskCache.storeData(Data("not an image".utf8), for: Fixtures.url.absoluteString)
        let delegate = RecordingDelegate()
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader, delegate: delegate) {
            $0.diskCache = diskCache
        }
        let response = try await session.imageTask(with: Fixtures.url).response
        #expect(response.cacheType == nil)
        #expect(loader.counts.started == 1)
        #expect(await waitUntil { diskCache.storage.value[Fixtures.url.absoluteString] == Fixtures.pngData })
        #expect(delegate.diagnostics.value.contains { if case .corruptedDiskCacheEntryRemoved = $0 { return true } else { return false } })
    }

    @Test("이미지가 아닌 응답은 디스크에 저장하지 않음")
    func nonImageResponsesAreNotStored() async {
        let diskCache = InMemoryDiskCache()
        let loader = MockDataLoader(defaultResponse: .data(Data("<html>error</html>".utf8)))
        let session = makeSession(loader: loader) {
            $0.diskCache = diskCache
        }
        _ = try? await session.image(for: Fixtures.url)
        drainSessionQueue()
        #expect(diskCache.storage.value.isEmpty)
    }

    @Test("작업 지표: 켜면 끝날 때 진단으로 보냄")
    func metrics() async throws {
        let delegate = RecordingDelegate()
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader, delegate: delegate) {
            $0.isMetricsCollectionEnabled = true
        }
        _ = try await session.image(for: Fixtures.url)
        #expect(
            await waitUntil {
                delegate.diagnostics.value.contains { if case .taskMetrics = $0 { return true } else { return false } }
            })
    }

    @Test("우선순위를 올리면 대기 중인 다운로드 순서에 반영")
    func priorityChangeAffectsQueueOrder() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        loader.isSuspended = true
        let session = makeSession(loader: loader) {
            $0.dataLoadingQueue = TaskQueue(maxConcurrentOperationCount: 1)
        }
        let blocker = session.imageTask(with: ImageRequest(url: Fixtures.url(0)))
        #expect(await waitUntil { loader.counts.started == 1 })
        let low = session.imageTask(with: ImageRequest(url: Fixtures.url(1), priority: .low))
        let raised = session.imageTask(with: ImageRequest(url: Fixtures.url(2), priority: .veryLow))
        drainSessionQueue()
        raised.priority = .veryHigh
        drainSessionQueue()
        loader.isSuspended = false
        for task in [blocker, low, raised] {
            _ = try? await task.image
        }
        let order = loader.requests.compactMap(\.url)
        #expect(order == [Fixtures.url(0), Fixtures.url(2), Fixtures.url(1)])
    }

    @Test("invalidate 뒤에는 진행 중 작업이 취소되고 새 요청은 sessionInvalidated")
    func invalidate() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        loader.isSuspended = true
        let session = makeSession(loader: loader)
        let running = session.imageTask(with: Fixtures.url)
        #expect(await waitUntil { loader.counts.started == 1 })
        session.invalidate()
        drainSessionQueue()
        drainSessionQueue()
        let first = await result(of: running)
        #expect(first.failureValue?.caseName == "cancelled")
        let next = await result(of: session.imageTask(with: Fixtures.url(1)))
        #expect(next.failureValue?.caseName == "sessionInvalidated")
        loader.isSuspended = false
    }
}

@Suite("completion과 Combine 어댑터")
struct CallbackAdapterTests {
    @Test("completion은 main에서 한 번 불림")
    func completionOnMain() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader)
        let calls = Box<[Bool]>([])
        session.loadImage(with: Fixtures.url) { result in
            calls.mutate { $0.append(Thread.isMainThread && (try? result.get()) != nil) }
        }
        #expect(await waitUntil { calls.value.count == 1 })
        #expect(calls.value == [true])
    }

    @Test("취소한 뒤에는 completion을 부르지 않음")
    func noCompletionAfterCancel() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        loader.isSuspended = true
        let session = makeSession(loader: loader)
        let calls = Box(0)
        let task = session.loadImage(with: Fixtures.url) { _ in
            calls.mutate { $0 += 1 }
        }
        #expect(await waitUntil { loader.counts.started == 1 })
        task.cancel()
        drainSessionQueue()
        drainSessionQueue()
        loader.isSuspended = false
        #expect(await waitUntil { loader.counts.cancelled == 1 })
        await MainActor.run {}
        drainSessionQueue()
        await MainActor.run {}
        #expect(calls.value == 0)
    }

    @Test("끝났지만 main에 아직 닿지 않은 completion은 그 사이 cancel을 부르면 버려지고, 작업 결과는 그대로")
    func completedTaskCancelledBeforeMainDeliveryDropsCompletion() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader)
        let imageCalls = Box(0)
        let dataCalls = Box(0)
        let tasks = Box<(image: ImageTask, data: ImageTask)?>(nil)
        let completedOnMain = Box<Bool?>(nil)
        DispatchQueue.main.async {
            let completed = spinUntil {
                guard let tasks = tasks.value else { return false }
                return tasks.image.state == .completed && tasks.data.state == .completed
            }
            tasks.value?.image.cancel()
            tasks.value?.data.cancel()
            completedOnMain.value = completed
        }
        let imageTask = session.loadImage(with: Fixtures.url) { _ in
            imageCalls.mutate { $0 += 1 }
        }
        let dataTask = session.loadData(with: ImageRequest(url: Fixtures.url(1))) { _ in
            dataCalls.mutate { $0 += 1 }
        }
        tasks.value = (imageTask, dataTask)
        #expect(await waitUntil { completedOnMain.value != nil })
        #expect(completedOnMain.value == true)
        await MainActor.run {}
        drainSessionQueue()
        await MainActor.run {}
        #expect(imageCalls.value == 0)
        #expect(dataCalls.value == 0)
        #expect(imageTask.state == .completed)
        #expect(imageTask.isCancelled)
        #expect((try? await imageTask.image) != nil)
    }

    @Test("Combine: 구독 시작과 취소가 다른 스레드에서 경쟁해도 진행 중 작업이 남지 않고 다운로드도 모두 취소 (ST-14)")
    func publisherCancelDuringStartDoesNotLeakTask() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        loader.isSuspended = true
        let session = makeSession(loader: loader) {
            $0.memoryCache = nil
        }
        let probes = Box<[PublisherRaceProbe]>([])
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                for index in 0..<10_000 {
                    let probe = PublisherRaceProbe()
                    session.imagePublisher(with: Fixtures.url(index)).subscribe(probe)
                    guard probe.hasSubscription else { continue }
                    DispatchQueue.concurrentPerform(iterations: 2) { lane in
                        if lane == 0 {
                            probe.requestUnlimited()
                        } else {
                            probe.cancelSubscription()
                        }
                    }
                    probes.mutate { $0.append(probe) }
                }
                continuation.resume()
            }
        }
        drainSessionQueue()
        drainSessionQueue()
        #expect(probes.value.count == 10_000)
        #expect(await waitUntil(timeout: 10) { session.runningTaskCount == 0 })
        loader.isSuspended = false
        #expect(await waitUntil(timeout: 10) { loader.counts.cancelled == loader.counts.started })
        #expect(loader.counts.completed == 0)
    }

    @Test("Combine: 작업이 끝나 main 전달만 남은 사이에 구독을 끊으면 값과 완료를 내보내지 않음")
    func publisherCancelledBeforeMainDeliveryDropsValue() async {
        let delegate = RecordingDelegate()
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader, delegate: delegate) {
            $0.memoryCache = nil
        }
        let probe = PublisherRaceProbe()
        session.imagePublisher(with: Fixtures.url).subscribe(probe)
        let finishedOnMain = Box<Bool?>(nil)
        DispatchQueue.main.async {
            let finished = spinUntil {
                delegate.events.value.contains { _, event in
                    if case .finished(.success) = event { return true }
                    return false
                }
            }
            probe.cancelSubscription()
            finishedOnMain.value = finished
        }
        probe.requestUnlimited()
        #expect(await waitUntil { finishedOnMain.value != nil })
        #expect(finishedOnMain.value == true)
        await MainActor.run {}
        drainSessionQueue()
        await MainActor.run {}
        #expect(probe.deliveries == 0)
    }

    @Test("invalidate로 취소된 진행 중 작업은 completion, loadData, Combine에 .cancelled를 main에서 한 번 전달하고 취소 플래그는 세우지 않음")
    func invalidateDeliversCancelledToAdapters() async {
        let delegate = RecordingDelegate()
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        loader.isSuspended = true
        let session = makeSession(loader: loader, delegate: delegate) {
            $0.memoryCache = nil
        }
        let imageResults = Box<[String]>([])
        let dataResults = Box<[String]>([])
        let publisherResults = Box<[String]>([])
        let imageTask = session.loadImage(with: Fixtures.url(0)) { result in
            imageResults.mutate { $0.append("\(Thread.isMainThread):\(result.failureValue?.caseName ?? "success")") }
        }
        let dataTask = session.loadData(with: ImageRequest(url: Fixtures.url(1))) { result in
            dataResults.mutate { $0.append("\(Thread.isMainThread):\(result.failureValue?.caseName ?? "success")") }
        }
        let cancellable = session.imagePublisher(with: Fixtures.url(2)).sink { completion in
            if case .failure(let error) = completion {
                publisherResults.mutate { $0.append("\(Thread.isMainThread):\(error.caseName)") }
            } else {
                publisherResults.mutate { $0.append("finished") }
            }
        } receiveValue: { _ in
            publisherResults.mutate { $0.append("value") }
        }
        #expect(await waitUntil { loader.counts.started == 3 })
        session.invalidate()
        #expect(await waitUntil { imageResults.value.count == 1 && dataResults.value.count == 1 && publisherResults.value.count == 1 })
        drainSessionQueue()
        await MainActor.run {}
        #expect(imageResults.value == ["true:cancelled"])
        #expect(dataResults.value == ["true:cancelled"])
        #expect(publisherResults.value == ["true:cancelled"])
        #expect(imageTask.state == .cancelled)
        #expect(!imageTask.isCancelled)
        #expect(!dataTask.isCancelled)
        #expect(delegate.finishedEvents(for: imageTask.taskId).map { $0.failureValue?.caseName } == ["cancelled"])
        cancellable.cancel()
        loader.isSuspended = false
    }

    @Test("Combine publisher: 값 하나와 완료, 구독을 끊으면 작업 취소")
    func publisher() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader)
        let received = Box<[String]>([])
        let cancellable = session.imagePublisher(with: Fixtures.url).sink { completion in
            if case .finished = completion {
                received.mutate { $0.append("finished") }
            }
        } receiveValue: { _ in
            received.mutate { $0.append("value") }
        }
        #expect(await waitUntil { received.value == ["value", "finished"] })
        cancellable.cancel()

        loader.isSuspended = true
        let other = session.imagePublisher(with: Fixtures.url(9)).sink { _ in
        } receiveValue: { _ in
        }
        #expect(await waitUntil { loader.counts.started == 2 })
        other.cancel()
        drainSessionQueue()
        drainSessionQueue()
        loader.isSuspended = false
        #expect(await waitUntil { loader.counts.cancelled == 1 })
    }

    @Test("메모리에 있으면 publisher는 구독 즉시 동기로 값을 내보냄")
    func publisherMemoryHit() async throws {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader)
        _ = try await session.image(for: Fixtures.url)
        var received = 0
        let cancellable = session.imagePublisher(with: Fixtures.url).sink { _ in
        } receiveValue: { _ in
            received += 1
        }
        #expect(received == 1)
        cancellable.cancel()
    }
}

@Suite("캐시 facade")
struct CacheFacadeTests {
    @Test("메모리 저장, 조회, 삭제와 읽기 옵션")
    func memoryFacade() {
        let session = makeSession(loader: MockDataLoader())
        let content = ImageContent(image: UIImage(data: Fixtures.pngData)!)
        let request = ImageRequest(url: Fixtures.url)
        session.cache[request] = content
        #expect(session.cache[request] != nil)
        #expect(session.cache.containsCachedImage(for: request, caches: .memory))
        var bypass = request
        bypass.options = [.disableMemoryCacheReads]
        #expect(session.cache[bypass] == nil)
        session.cache[request] = nil
        #expect(session.cache[request] == nil)
    }

    @Test("미리보기는 설정에 따라 저장, 쓰기 끄기 옵션 존중")
    func memoryWriteRules() {
        let session = makeSession(loader: MockDataLoader()) {
            $0.isStoringPreviewsInMemoryCache = false
        }
        let preview = ImageContent(image: UIImage(data: Fixtures.pngData)!, isPreview: true)
        session.cache[Fixtures.url] = preview
        #expect(session.cache[Fixtures.url] == nil)
        var request = ImageRequest(url: Fixtures.url)
        request.options = [.disableMemoryCacheWrites]
        session.cache[request] = ImageContent(image: UIImage(data: Fixtures.pngData)!)
        #expect(session.cache[Fixtures.url] == nil)
    }

    @Test("데이터 키: imageID, 썸네일, 프로세서를 U+001F로 잇고, 요소가 imageID뿐이면 구분자 없음")
    func dataKeys() {
        let session = makeSession(loader: MockDataLoader())
        let separator = "\u{1F}"
        #expect(ImageSession.Cache.dataKeySeparator == separator)
        let thumbnail = ImageRequest.ThumbnailOptions(maxPixelSize: 100)
        #expect(session.cache.makeDiskCacheKey(for: ImageRequest(url: Fixtures.url)) == "https://example.com/image.png")
        var request = ImageRequest(url: Fixtures.url, filters: [TintFilter(name: "x")])
        #expect(session.cache.makeDiskCacheKey(for: request) == "https://example.com/image.png\u{1F}\u{1F}test/tint?x")
        request.thumbnail = thumbnail
        #expect(session.cache.makeDiskCacheKey(for: request) == "https://example.com/image.png\u{1F}imageloader/thumbnail?maxPixelSize=100.0,options=1111\u{1F}test/tint?x")
        var thumbnailOnly = ImageRequest(url: Fixtures.url)
        thumbnailOnly.thumbnail = thumbnail
        #expect(session.cache.makeDiskCacheKey(for: thumbnailOnly) == "https://example.com/image.png\u{1F}imageloader/thumbnail?maxPixelSize=100.0,options=1111")
        let twoFilters = ImageRequest(url: Fixtures.url, filters: [TintFilter(name: "a"), TintFilter(name: "b")])
        #expect(session.cache.makeDiskCacheKey(for: twoFilters) == "https://example.com/image.png\u{1F}\u{1F}test/tint?a\u{1F}test/tint?b")
        var custom = ImageRequest(url: URL(string: "https://cdn.example.com/a.png?sig=1")!)
        custom.imageID = "a.png"
        #expect(session.cache.makeDiskCacheKey(for: custom) == "a.png")
        #expect(!session.cache.makeDiskCacheKey(for: twoFilters).contains("|"))
    }

    @Test("데이터 키 구분자가 경계 모호성을 없앰: 같은 문자열로 이어지는 다른 조합의 키가 다름")
    func dataKeySeparatorRemovesBoundaryAmbiguity() {
        let session = makeSession(loader: MockDataLoader())
        let split = ImageRequest(url: Fixtures.url, filters: [TintFilter(name: "a"), TintFilter(name: "b")])
        let joined = ImageRequest(url: Fixtures.url, filters: [TintFilter(name: "atest/tint?b")])
        #expect(session.cache.makeDiskCacheKey(for: split) != session.cache.makeDiskCacheKey(for: joined))
        let composition = ImageFilters.Composition([TintFilter(name: "a"), TintFilter(name: "b")])
        #expect(composition.identifier == "test/tint?a\u{1F}test/tint?b")
    }

    @Test("removeAll은 메모리와 디스크를 비움")
    func removeAll() {
        let diskCache = InMemoryDiskCache()
        let session = makeSession(loader: MockDataLoader()) {
            $0.diskCache = diskCache
        }
        session.cache.storeCachedData(Fixtures.pngData, for: ImageRequest(url: Fixtures.url))
        session.cache[Fixtures.url] = ImageContent(image: UIImage(data: Fixtures.pngData)!)
        session.cache.removeAll()
        #expect(session.cache[Fixtures.url] == nil)
        #expect(!session.cache.containsData(for: ImageRequest(url: Fixtures.url)))
    }
}

private final class PublisherRaceProbe: Subscriber, @unchecked Sendable {
    typealias Input = ImageResponse
    typealias Failure = ImageSession.Error

    private struct State {
        var subscription: (any Subscription)?
        var deliveries = 0
    }

    private let state = Box(State())

    var hasSubscription: Bool {
        state.value.subscription != nil
    }

    var deliveries: Int {
        state.value.deliveries
    }

    func requestUnlimited() {
        state.value.subscription?.request(.unlimited)
    }

    func cancelSubscription() {
        state.value.subscription?.cancel()
    }

    func receive(subscription: any Subscription) {
        state.mutate { $0.subscription = subscription }
    }

    func receive(_ input: ImageResponse) -> Subscribers.Demand {
        state.mutate { $0.deliveries += 1 }
        return .none
    }

    func receive(completion: Subscribers.Completion<ImageSession.Error>) {
        state.mutate { $0.deliveries += 1 }
    }
}
