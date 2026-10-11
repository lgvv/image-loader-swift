import Foundation
import ImageIO
@_spi(Testing) @testable import ImageLoader
@_spi(Testing) import ImageLoaderTesting
import Testing
import UIKit
import UniformTypeIdentifiers

enum ProgressiveFixtures {
    static func jpeg(width: Int = 240, height: Int = 160, isProgressive: Bool, embedsThumbnail: Bool = false) -> Data {
        var generator = SeededGenerator(seed: 11)
        let image = DecodingFixtures.texturedFrame(.photo, index: 0, width: width, height: height, generator: &generator)
        return DecodingFixtures.encode(type: .jpeg, images: [image]) { _ in
            [
                kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: isProgressive],
                kCGImageDestinationLossyCompressionQuality: 0.9,
                kCGImageDestinationEmbedThumbnail: embedsThumbnail,
            ]
        }
    }

    static let progressive = jpeg(isProgressive: true)
    static let baseline = jpeg(isProgressive: false)

    static func context(for data: Data, policy: ImageSession.PreviewPolicy) -> ImageDecodingContext {
        var context = ImageDecodingContext(request: ImageRequest(url: Fixtures.url), data: data, isCompleted: false)
        context.previewPolicy = policy
        return context
    }

    static func url(_ name: String) -> URL {
        URL(string: "https://example.com/progressive/\(name).jpg")!
    }
}

final class SteppedDataLoader: DataLoading, Sendable {
    private struct Load: Sendable {
        let didReceiveData: @Sendable (Data, URLResponse) -> Void
        let completion: @Sendable (Swift.Error?) -> Void
        let response: URLResponse
        var isCancelled = false
    }

    let data: Data
    private let load = Box<Load?>(nil)
    private let sentCount = Box(0)

    init(data: Data) {
        self.data = data
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Swift.Error?) -> Void
    ) -> any Cancellable {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(data.count)"])!
        load.value = Load(didReceiveData: didReceiveData, completion: completion, response: response)
        return SteppedCancellable(load: load)
    }

    var isStarted: Bool {
        load.value != nil
    }

    func send(upTo end: Int) {
        guard let load = load.value, !load.isCancelled else { return }
        let start = sentCount.value
        let end = min(end, data.count)
        guard end > start else { return }
        sentCount.value = end
        load.didReceiveData(data.subdata(in: start..<end), load.response)
    }

    func finish() {
        send(upTo: data.count)
        guard let load = load.value, !load.isCancelled else { return }
        load.completion(nil)
    }

    private struct SteppedCancellable: Cancellable {
        let load: Box<Load?>

        func cancel() {
            let completion = load.mutate { load -> (@Sendable (Swift.Error?) -> Void)? in
                guard load?.isCancelled == false else { return nil }
                load?.isCancelled = true
                return load?.completion
            }
            completion?(URLError(.cancelled))
        }
    }
}

final class ProgressiveDelegate: ImageSession.Delegate, Sendable {
    let events = Box<[ImageTask.Event]>([])
    let cachedImages = Box<[ImageContent?]>([])
    let policyEvaluations = Box(0)
    let policy: ImageSession.PreviewPolicy?
    let decoder: (any ImageDecoding)?

    init(policy: ImageSession.PreviewPolicy? = nil, decoder: (any ImageDecoding)? = nil) {
        self.policy = policy
        self.decoder = decoder
    }

    func imageDecoder(for context: ImageDecodingContext, session: ImageSession) -> (any ImageDecoding)? {
        decoder ?? session.configuration.makeImageDecoder(context)
    }

    func previewPolicy(for context: ImageDecodingContext, session: ImageSession) -> ImageSession.PreviewPolicy {
        policyEvaluations.mutate { $0 += 1 }
        return policy ?? .default(for: context.data)
    }

    func willCache(data: Data, image: ImageContent?, for request: ImageRequest, session: ImageSession, completion: @escaping @Sendable (Data?) -> Void) {
        cachedImages.mutate { $0.append(image) }
        completion(data)
    }

    func imageTask(_ task: ImageTask, didReceiveEvent event: ImageTask.Event, session: ImageSession) {
        events.mutate { $0.append(event) }
    }

    var previews: [ImageResponse] {
        events.value.compactMap {
            if case .preview(let response) = $0 { return response }
            return nil
        }
    }

    var labels: [String] {
        events.value.compactMap {
            switch $0 {
            case .started: "started"
            case .progress: nil
            case .preview: "preview"
            case .finished(.success): "success"
            case .finished(.failure(.cancelled)): "cancelled"
            case .finished(.failure): "failure"
            }
        }
    }
}

final class RecordingPartialDecoder: ImageDecoding, Sendable {
    let partialDataCounts = Box<[Int]>([])
    let entered = Box(0)
    private let gate: DispatchSemaphore?

    init(gate: DispatchSemaphore? = nil) {
        self.gate = gate
    }

    func decode(_ data: Data) throws -> ImageContent {
        guard let image = UIImage(data: data) else {
            throw ImageDecodingError.unknown
        }
        return ImageContent(image: image, type: AssetType(data))
    }

    func decodePartiallyDownloadedData(_ data: Data) -> ImageContent? {
        partialDataCounts.mutate { $0.append(data.count) }
        entered.mutate { $0 += 1 }
        gate?.wait()
        return ImageContent(image: UIImage(data: Fixtures.pngData)!, isPreview: true)
    }
}

@Suite("Default 디코더의 부분 디코딩")
struct ProgressiveDecoderTests {
    @Test("프로그레시브 JPEG은 SOF2 전에는 nil, 그 뒤로는 받은 만큼 미리보기를 만들고 번호를 붙임")
    func progressiveJPEGProducesNumberedPreviews() throws {
        let data = ProgressiveFixtures.progressive
        let sof2 = try #require(data.range(of: Data([0xFF, 0xC2]))).lowerBound
        let decoder = try #require(ImageDecoders.Default(context: ProgressiveFixtures.context(for: data, policy: .incremental)))

        #expect(decoder.decodePartiallyDownloadedData(data.prefix(sof2)) == nil)
        #expect(decoder.numberOfScans == 0)

        let first = try #require(decoder.decodePartiallyDownloadedData(data.prefix(data.count / 2)))
        #expect(first.isPreview)
        #expect(first.type == .jpeg)
        #expect(first.userInfo[.scanNumberKey] as? Int == 1)
        #expect(DecodingFixtures.displaySize(of: first.image) == CGSize(width: 240, height: 160))

        let second = try #require(decoder.decodePartiallyDownloadedData(data.prefix(data.count * 3 / 4)))
        #expect(second.userInfo[.scanNumberKey] as? Int == 2)
        #expect(decoder.numberOfScans == 2)

        let final = try decoder.decode(data)
        #expect(!final.isPreview)
        #expect(final.userInfo[.scanNumberKey] as? Int == 2)
    }

    @Test("disabled 정책이면 프로그레시브 JPEG에서도 미리보기를 만들지 않음")
    func disabledPolicyProducesNothing() throws {
        let data = ProgressiveFixtures.progressive
        let decoder = try #require(ImageDecoders.Default(context: ProgressiveFixtures.context(for: data, policy: .disabled)))
        #expect(decoder.decodePartiallyDownloadedData(data.prefix(data.count / 2)) == nil)
        #expect(decoder.decodePartiallyDownloadedData(data) == nil)
        #expect(decoder.numberOfScans == 0)
        #expect(try decoder.decode(data).userInfo.isEmpty)
    }

    @Test("기본 정책은 프로그레시브 JPEG만 incremental이고 baseline은 disabled, baseline도 incremental이면 위에서부터 그림")
    func baselineJPEGFollowsPolicy() throws {
        let data = ProgressiveFixtures.baseline
        #expect(ImageSession.PreviewPolicy.default(for: data) == .disabled)
        #expect(ImageSession.PreviewPolicy.default(for: ProgressiveFixtures.progressive) == .incremental)

        let disabled = try #require(ImageDecoders.Default(context: ProgressiveFixtures.context(for: data, policy: .default(for: data))))
        #expect(disabled.decodePartiallyDownloadedData(data.prefix(data.count / 2)) == nil)

        let incremental = try #require(ImageDecoders.Default(context: ProgressiveFixtures.context(for: data, policy: .incremental)))
        let preview = try #require(incremental.decodePartiallyDownloadedData(data.prefix(data.count / 2)))
        #expect(preview.isPreview)
        #expect(!(try incremental.decode(data)).isPreview)
    }

    @Test("thumbnail 정책은 내장 썸네일을 한 번만 꺼냄")
    func thumbnailPolicyExtractsEmbeddedThumbnailOnce() throws {
        let data = ProgressiveFixtures.jpeg(isProgressive: false, embedsThumbnail: true)
        let decoder = try #require(ImageDecoders.Default(context: ProgressiveFixtures.context(for: data, policy: .thumbnail)))
        let preview = try #require(decoder.decodePartiallyDownloadedData(data))
        #expect(preview.isPreview)
        #expect(preview.userInfo[.scanNumberKey] as? Int == 1)
        #expect(decoder.decodePartiallyDownloadedData(data) == nil)

        let plain = ProgressiveFixtures.baseline
        let other = try #require(ImageDecoders.Default(context: ProgressiveFixtures.context(for: plain, policy: .thumbnail)))
        _ = other.decodePartiallyDownloadedData(plain)
        #expect(other.decodePartiallyDownloadedData(plain) == nil)
        #expect(other.numberOfScans <= 1)
    }

    @Test("부분 디코딩도 디코딩 한도를 넘는 이미지는 그리지 않음")
    func partialDecodingRespectsLimits() throws {
        let data = ProgressiveFixtures.progressive
        var context = ProgressiveFixtures.context(for: data, policy: .incremental)
        context.decodingLimits = ImageDecodingLimits(maximumPixelCount: 100, maximumSourcePixelCount: nil)
        let decoder = try #require(ImageDecoders.Default(context: context))
        #expect(decoder.decodePartiallyDownloadedData(data.prefix(data.count / 2)) == nil)

        let withThumbnail = ProgressiveFixtures.jpeg(isProgressive: false, embedsThumbnail: true)
        var thumbnailContext = ProgressiveFixtures.context(for: withThumbnail, policy: .thumbnail)
        thumbnailContext.decodingLimits = ImageDecodingLimits(maximumPixelCount: 100, maximumSourcePixelCount: nil)
        let limited = try #require(ImageDecoders.Default(context: thumbnailContext))
        #expect(limited.decodePartiallyDownloadedData(withThumbnail) == nil)
    }
}

@Suite("파이프라인 프로그레시브 디코딩")
struct ProgressiveSessionTests {
    private func makeProgressiveSession(
        loader: any DataLoading,
        delegate: ProgressiveDelegate,
        configure: (inout ImageSession.Configuration) -> Void = { _ in }
    ) -> ImageSession {
        var configuration = ImageSession.Configuration(dataLoader: loader)
        configuration.memoryCache = MemoryCache(costLimit: 64 * 1024 * 1024)
        configuration.isRateLimiterEnabled = false
        configuration.isProgressiveDecodingEnabled = true
        configuration.progressiveDecodingInterval = 0
        configure(&configuration)
        return ImageSession(configuration: configuration, delegate: delegate)
    }

    @Test("청크로 받은 프로그레시브 JPEG은 미리보기를 하나 이상 내고 마지막에 최종 이미지를 냄, 메모리 캐시는 미리보기를 최종으로 바꿈")
    func progressiveJPEGDeliversPreviewsThenFinal() async throws {
        let data = ProgressiveFixtures.progressive
        let loader = SteppedDataLoader(data: data)
        let delegate = ProgressiveDelegate()
        let session = makeProgressiveSession(loader: loader, delegate: delegate)
        let request = ImageRequest(url: ProgressiveFixtures.url("final"))
        let task = session.imageTask(with: request)
        let previewStream = Task { () -> [ImageResponse] in
            var previews: [ImageResponse] = []
            for await preview in task.previews {
                previews.append(preview)
            }
            return previews
        }

        #expect(await waitUntil { loader.isStarted })
        loader.send(upTo: data.count / 2)
        #expect(await waitUntil { delegate.previews.count == 1 })
        #expect(session.cache[request]?.isPreview == true)

        loader.send(upTo: data.count * 3 / 4)
        #expect(await waitUntil { delegate.previews.count == 2 })
        loader.finish()
        let response = try await task.response

        #expect(!response.content.isPreview)
        #expect(response.content.userInfo[.scanNumberKey] as? Int == 2)
        #expect(delegate.previews.allSatisfy { $0.content.isPreview })
        #expect(delegate.labels == ["started", "preview", "preview", "success"])
        #expect(session.cache[request]?.isPreview == false)
        #expect(await previewStream.value.count <= 2)
    }

    @Test("isProgressiveDecodingEnabled가 꺼져 있으면 MockDataLoader가 청크로 보내도 미리보기가 없음")
    func disabledFlagProducesNoPreviews() async throws {
        let loader = MockDataLoader(defaultResponse: .data(ProgressiveFixtures.progressive, chunkCount: 16))
        let delegate = ProgressiveDelegate()
        let session = makeProgressiveSession(loader: loader, delegate: delegate) {
            $0.isProgressiveDecodingEnabled = false
        }
        let response = try await session.imageTask(with: ImageRequest(url: ProgressiveFixtures.url("disabled"))).response
        drainSessionQueue()
        #expect(!response.content.isPreview)
        #expect(delegate.previews.isEmpty)
        #expect(delegate.policyEvaluations.value == 0)
    }

    @Test("baseline JPEG은 기본 정책으로 미리보기가 없고, delegate가 incremental을 주면 미리보기가 생김")
    func baselineJPEGFollowsDelegatePolicy() async throws {
        let data = ProgressiveFixtures.baseline
        let mockLoader = MockDataLoader(defaultResponse: .data(data, chunkCount: 16))
        let defaultDelegate = ProgressiveDelegate()
        let defaultSession = makeProgressiveSession(loader: mockLoader, delegate: defaultDelegate)
        _ = try await defaultSession.imageTask(with: ImageRequest(url: ProgressiveFixtures.url("baseline-default"))).response
        drainSessionQueue()
        #expect(defaultDelegate.previews.isEmpty)
        #expect(defaultDelegate.policyEvaluations.value >= 1)
        #expect(defaultDelegate.policyEvaluations.value <= DecodeImageStage.maximumPreviewPolicyEvaluationCount)

        let loader = SteppedDataLoader(data: data)
        let delegate = ProgressiveDelegate(policy: .incremental)
        let session = makeProgressiveSession(loader: loader, delegate: delegate)
        let task = session.imageTask(with: ImageRequest(url: ProgressiveFixtures.url("baseline-incremental")))
        #expect(await waitUntil { loader.isStarted })
        loader.send(upTo: data.count / 2)
        #expect(await waitUntil { delegate.previews.count == 1 })
        loader.finish()
        let response = try await task.response
        #expect(!response.content.isPreview)
        #expect(delegate.labels == ["started", "preview", "success"])
    }

    @Test("progressiveDecodingInterval 안에 온 청크는 주입한 시계 기준으로 건너뜀")
    func intervalThrottlesPartialDecodes() async throws {
        let data = ProgressiveFixtures.progressive
        let loader = SteppedDataLoader(data: data)
        let decoder = RecordingPartialDecoder()
        let delegate = ProgressiveDelegate(policy: .incremental, decoder: decoder)
        let clock = TestClock()
        let session = makeProgressiveSession(loader: loader, delegate: delegate) {
            $0.progressiveDecodingInterval = 10
            $0.clock = clock
        }
        let task = session.imageTask(with: ImageRequest(url: ProgressiveFixtures.url("throttle")))
        #expect(await waitUntil { loader.isStarted })

        loader.send(upTo: 100)
        #expect(await waitUntil { delegate.previews.count == 1 })
        clock.advance(by: 9)
        loader.send(upTo: 200)
        drainSessionQueue()
        clock.advance(by: 1)
        loader.send(upTo: 300)
        #expect(await waitUntil { delegate.previews.count == 2 })
        loader.finish()
        _ = try await task.response

        #expect(decoder.partialDataCounts.value == [100, 300])
        #expect(delegate.labels == ["started", "preview", "preview", "success"])
    }

    @Test("부분 디코딩이 진행 중이면 다음 청크는 건너뛰고, 디코딩은 조정 큐가 아니라 디코딩 워커에서 함")
    func busyDecoderSkipsChunksAndRunsOffCoordinator() async throws {
        let data = ProgressiveFixtures.progressive
        let loader = SteppedDataLoader(data: data)
        let gate = DispatchSemaphore(value: 0)
        let decoder = RecordingPartialDecoder(gate: gate)
        let delegate = ProgressiveDelegate(policy: .incremental, decoder: decoder)
        let session = makeProgressiveSession(loader: loader, delegate: delegate)
        let task = session.imageTask(with: ImageRequest(url: ProgressiveFixtures.url("busy")))
        #expect(await waitUntil { loader.isStarted })

        loader.send(upTo: 100)
        #expect(await waitUntil { decoder.entered.value == 1 })
        drainSessionQueue()
        loader.send(upTo: 200)
        drainSessionQueue()
        gate.signal()
        #expect(await waitUntil { delegate.previews.count == 1 })
        loader.finish()
        _ = try await task.response

        #expect(decoder.partialDataCounts.value == [100])
    }

    @Test("부분 디코딩 도중 취소하면 그 뒤로 미리보기가 delegate, 스트림, progress 콜백 어디에도 오지 않음")
    func cancellationDuringPartialDecodeDropsPreview() async throws {
        let data = ProgressiveFixtures.progressive
        let loader = SteppedDataLoader(data: data)
        let gate = DispatchSemaphore(value: 0)
        let decoder = RecordingPartialDecoder(gate: gate)
        let delegate = ProgressiveDelegate(policy: .incremental, decoder: decoder)
        let session = makeProgressiveSession(loader: loader, delegate: delegate)
        let callbackPreviews = Box(0)
        let task = session.loadImage(
            with: ImageRequest(url: ProgressiveFixtures.url("cancel")),
            progress: { response, _, _ in
                if response != nil {
                    callbackPreviews.mutate { $0 += 1 }
                }
            }, completion: { _ in })
        let stream = Task { () -> [String] in
            var labels: [String] = []
            for await event in task.events {
                if case .preview = event {
                    labels.append("preview")
                } else if case .finished = event {
                    labels.append("finished")
                }
            }
            return labels
        }
        #expect(await waitUntil { loader.isStarted })

        loader.send(upTo: data.count / 2)
        #expect(await waitUntil { decoder.entered.value == 1 })
        task.cancel()
        gate.signal()
        SessionWorkers.decoding.sync(flags: .barrier) {}
        drainSessionQueue()
        await MainActor.run {}

        #expect(delegate.previews.isEmpty)
        #expect(delegate.labels == ["started", "cancelled"])
        #expect(callbackPreviews.value == 0)
        #expect(await stream.value.filter { $0 == "preview" }.isEmpty)
    }

    @Test("progress 콜백 어댑터는 미리보기를 응답과 함께 main에서 최종 completion보다 먼저 받음")
    func progressCallbackReceivesPreviewsBeforeCompletion() async throws {
        let data = ProgressiveFixtures.progressive
        let loader = SteppedDataLoader(data: data)
        let delegate = ProgressiveDelegate()
        let session = makeProgressiveSession(loader: loader, delegate: delegate)
        let order = Box<[String]>([])
        let finished = Box(false)
        session.loadImage(
            with: ImageRequest(url: ProgressiveFixtures.url("callback")),
            progress: { response, _, _ in
                MainActor.preconditionIsolated()
                if let response {
                    order.mutate { $0.append(response.content.isPreview ? "preview" : "final-in-progress") }
                }
            },
            completion: { result in
                order.mutate { $0.append((try? result.get())?.content.isPreview == false ? "completion" : "failure") }
                finished.value = true
            })
        #expect(await waitUntil { loader.isStarted })
        loader.send(upTo: data.count / 2)
        #expect(await waitUntil { order.value.count == 1 })
        loader.finish()
        #expect(await waitUntil { finished.value })
        #expect(order.value == ["preview", "completion"])
    }

    @Test("미리보기는 디스크 캐시에 쓰지 않고 최종 이미지만 인코딩해 저장")
    func previewsAreNotWrittenToDiskCache() async throws {
        let data = ProgressiveFixtures.progressive
        let loader = SteppedDataLoader(data: data)
        let delegate = ProgressiveDelegate()
        let diskCache = InMemoryDiskCache()
        let session = makeProgressiveSession(loader: loader, delegate: delegate) {
            $0.diskCache = diskCache
            $0.diskCachePolicy = .storeEncodedImages
        }
        let task = session.imageTask(with: ImageRequest(url: ProgressiveFixtures.url("disk")))
        #expect(await waitUntil { loader.isStarted })
        loader.send(upTo: data.count / 2)
        #expect(await waitUntil { delegate.previews.count == 1 })
        loader.finish()
        _ = try await task.response
        #expect(await waitUntil { diskCache.storage.value.count == 1 })

        #expect(delegate.cachedImages.value.count == 1)
        #expect(delegate.cachedImages.value.allSatisfy { $0?.isPreview == false })
        let stored = try #require(diskCache.storage.value.values.first)
        #expect(UIImage(data: stored).map(DecodingFixtures.displaySize) == CGSize(width: 240, height: 160))
    }

    @Test("isStoringPreviewsInMemoryCache가 꺼져 있으면 미리보기를 메모리 캐시에 넣지 않음")
    func previewsAreNotStoredInMemoryWhenDisabled() async throws {
        let data = ProgressiveFixtures.progressive
        let loader = SteppedDataLoader(data: data)
        let delegate = ProgressiveDelegate()
        let session = makeProgressiveSession(loader: loader, delegate: delegate) {
            $0.isStoringPreviewsInMemoryCache = false
        }
        let request = ImageRequest(url: ProgressiveFixtures.url("memory-off"))
        let task = session.imageTask(with: request)
        #expect(await waitUntil { loader.isStarted })
        loader.send(upTo: data.count / 2)
        #expect(await waitUntil { delegate.previews.count == 1 })
        #expect(session.cache[request] == nil)
        loader.finish()
        _ = try await task.response
        #expect(session.cache[request]?.isPreview == false)
    }
}
