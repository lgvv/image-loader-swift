import Foundation
import ImageLoaderTesting
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import ImageLoader

@Suite("처리기 조합과 익명 처리기")
struct ProcessorCompositionTests {
    private func image(width: Int = 40, height: Int = 20) throws -> UIImage {
        try #require(UIImage(data: Fixtures.png(width: width, height: height)))
    }

    @Test("Composition은 처리기를 순서대로 적용하고, 중간에 nil이 나오면 nil")
    func compositionAppliesProcessorsInOrder() throws {
        let order = Box<[String]>([])
        let first = ImageFilters.Anonymous(id: "first") { image in
            order.mutate { $0.append("first") }
            return image
        }
        let second: ImageFilters.Anonymous = .process(id: "second") { image in
            order.mutate { $0.append("second") }
            return image
        }
        let resize: ImageFilters.Resize = .resize(width: 10, unit: .pixels)
        let composition = ImageFilters.Composition([first, resize, second])
        let output = try #require(composition.process(try image()))
        #expect(order.value == ["first", "second"])
        #expect(output.cgImage?.width == 10)
        #expect(ImageFilters.Composition([first, ImageFilters.Anonymous(id: "nil") { _ in nil }, second]).process(try image()) == nil)
    }

    @Test("Composition의 context 처리, 식별자, 설명, 동등성")
    func compositionContextIdentityAndDescription() throws {
        let resize = ImageFilters.Resize(height: 10, unit: .pixels)
        let tag = ImageFilters.Anonymous(id: "tag") { $0 }
        let composition = ImageFilters.Composition([resize, tag])
        let request = ImageRequest(url: Fixtures.url)
        let content = ImageContent(image: try image())
        let context = ImageFilterContext(request: request, response: ImageResponse(content: content, request: request), isCompleted: true)
        let output = try composition.process(content, context: context)
        #expect(output.image.cgImage?.height == 10)
        #expect(composition.identifier == resize.identifier + ImageSession.Cache.dataKeySeparator + "tag")
        #expect(composition == ImageFilters.Composition([ImageFilters.Resize(height: 10, unit: .pixels), ImageFilters.Anonymous(id: "tag") { $0 }]))
        #expect(composition != ImageFilters.Composition([resize]))
        #expect(Set([composition, composition]).count == 1)
        #expect(composition.hashableIdentifier == ImageFilters.Composition([resize, tag]).hashableIdentifier)
        #expect(composition.description == "Composition(\(resize.description), AnonymousFilter(identifier: tag))")
        #expect(tag.description == "AnonymousFilter(identifier: tag)")
        #expect(resize.description.hasPrefix("Resize(size: "))
    }

    @Test("크기 조정 단축 함수는 같은 설정의 Resize를 만듦")
    func resizeShortcutsMatchInitializers() {
        let size = CGSize(width: 30, height: 20)
        let bySize: ImageFilters.Resize = .resize(size: size, unit: .pixels, contentMode: .aspectFit, crop: true, upscale: true)
        let byWidth: ImageFilters.Resize = .resize(width: 30, unit: .pixels)
        let byHeight: ImageFilters.Resize = .resize(height: 20, unit: .pixels, upscale: true)
        #expect(bySize == ImageFilters.Resize(size: size, unit: .pixels, contentMode: .aspectFit, crop: true, upscale: true))
        #expect(byWidth == ImageFilters.Resize(width: 30, unit: .pixels))
        #expect(byHeight == ImageFilters.Resize(height: 20, unit: .pixels, upscale: true))
    }
}

@Suite("AssetType 판별표")
struct AssetTypeDetectionTests {
    private func data(_ bytes: [UInt8], padding: Int = 16) -> Data {
        Data(bytes + Array(repeating: 0, count: padding))
    }

    private func isoBaseMedia(_ brand: String) -> Data {
        Data([0, 0, 0, 0x18] + Array("ftyp".utf8) + Array(brand.utf8) + Array(repeating: 0, count: 8))
    }

    @Test("시그니처마다 형식을 판별하고, 모르는 데이터와 짧은 데이터는 nil")
    func signaturesAreDetected() {
        #expect(AssetType(data([0xFF, 0xD8, 0xFF])) == .jpeg)
        #expect(AssetType(data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == .png)
        #expect(AssetType(data(Array("GIF87a".utf8))) == .gif)
        #expect(AssetType(data(Array("GIF89a".utf8))) == .gif)
        #expect(AssetType(data(Array("RIFF".utf8) + [1, 2, 3, 4] + Array("WEBP".utf8))) == .webp)
        #expect(AssetType(data([0x00, 0x00, 0x01, 0x00])) == .ico)
        #expect(AssetType(data([0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20])) == .jpeg2000)
        #expect(AssetType(data([0xFF, 0x4F, 0xFF, 0x51])) == .jpeg2000)
        #expect(AssetType(data([0x49, 0x49, 0x2A, 0x00])) == .tiff)
        #expect(AssetType(data([0x4D, 0x4D, 0x00, 0x2A])) == .tiff)
        #expect(AssetType(data([0x42, 0x4D])) == .bmp)
        #expect(AssetType(data([0x01, 0x02, 0x03])) == nil)
        #expect(AssetType(Data([0xFF, 0xD8])) == nil)
        #expect(AssetType(Data()) == nil)
    }

    @Test("ISO 미디어 브랜드로 HEIC, AVIF, 동영상을 가리고, 모르는 브랜드는 nil")
    func isoBaseMediaBrandsAreDetected() {
        for brand in ["heic", "heix", "mif1", "msf1"] {
            #expect(AssetType(isoBaseMedia(brand)) == .heic)
        }
        #expect(AssetType(isoBaseMedia("avif")) == .avif)
        #expect(AssetType(isoBaseMedia("isom")) == .mp4)
        #expect(AssetType(isoBaseMedia("M4V ")) == .m4v)
        #expect(AssetType(isoBaseMedia("qt  ")) == .mov)
        #expect(AssetType(isoBaseMedia("zzzz")) == nil)
        #expect(AssetType(Data([0, 0, 0, 0x18] + Array("ftyp".utf8) + [0xFF, 0xFE])) == nil)
    }

    @Test("UTType 변환과 동영상 여부")
    func utTypeAndVideoFlags() {
        #expect(AssetType(rawValue: "public.png") == .png)
        #expect(AssetType(UTType.jpeg) == .jpeg)
        #expect(AssetType.png.utType == .png)
        #expect(AssetType.mp4.isVideo && AssetType.m4v.isVideo && AssetType.mov.isVideo)
        #expect(!AssetType.gif.isVideo)
    }
}

@Suite("캐시 파사드 저장과 삭제")
struct CacheFacadeStorageTests {
    @Test("storeCachedImage는 메모리와 디스크(인코딩 뒤)에 저장하고, removeCachedImage와 removeCachedData가 지움")
    func storeAndRemoveCachedImage() async throws {
        let diskCache = InMemoryDiskCache()
        let session = makeSession(loader: MockDataLoader()) { $0.diskCache = diskCache }
        let request = ImageRequest(url: Fixtures.url(70))
        let content = ImageContent(image: try #require(UIImage(data: Fixtures.pngData)))

        session.cache.storeCachedImage(content, for: request, caches: [.memory])
        #expect(session.cache.containsCachedImage(for: request, caches: [.memory]))
        #expect(!session.cache.containsCachedImage(for: request, caches: [.disk]))

        session.cache.storeCachedImage(content, for: request, caches: [.disk])
        #expect(await waitUntil { session.cache.containsCachedImage(for: request, caches: [.disk]) })
        #expect(session.cache.cachedData(for: request) != nil)

        session.cache.removeCachedImage(for: request, caches: [.memory])
        #expect(!session.cache.containsCachedImage(for: request, caches: [.memory]))
        #expect(session.cache.containsCachedImage(for: request))

        session.cache.removeCachedImage(for: request)
        #expect(!session.cache.containsCachedImage(for: request))

        session.cache.storeCachedData(Fixtures.pngData, for: request)
        #expect(session.cache.containsData(for: request))
        session.cache.removeCachedData(for: request)
        #expect(!session.cache.containsData(for: request))
    }

    @Test("미리보기와 디스크 쓰기 금지 요청은 디스크에 저장하지 않고, 디스크 읽기 금지 요청은 디스크를 보지 않음")
    func diskOptionsAreRespected() async throws {
        let diskCache = InMemoryDiskCache()
        let session = makeSession(loader: MockDataLoader()) { $0.diskCache = diskCache }
        let image = try #require(UIImage(data: Fixtures.pngData))
        let preview = ImageContent(image: image, isPreview: true)
        let request = ImageRequest(url: Fixtures.url(71))
        session.cache.storeCachedImage(preview, for: request, caches: [.disk])
        let noWrites = ImageRequest(url: Fixtures.url(72), options: [.disableDiskCacheWrites])
        session.cache.storeCachedImage(ImageContent(image: image), for: noWrites, caches: [.disk])
        let probe = ImageRequest(url: Fixtures.url(73))
        session.cache.storeCachedImage(ImageContent(image: image), for: probe, caches: [.disk])
        #expect(await waitUntil { session.cache.containsData(for: probe) })
        #expect(!session.cache.containsData(for: request))
        #expect(!session.cache.containsData(for: noWrites))
        let noReads = ImageRequest(url: Fixtures.url(73), options: [.disableDiskCacheReads])
        #expect(!session.cache.containsCachedImage(for: noReads, caches: [.disk]))
    }
}

@Suite("인코더 단축 함수")
struct EncoderShortcutTests {
    @Test("default와 imageIO 단축 함수, ImageIO 지원 형식 판정")
    func encoderShortcuts() throws {
        let image = try #require(UIImage(data: Fixtures.png(width: 16, height: 16)))
        let context = ImageEncodingContext(request: ImageRequest(url: Fixtures.url), image: image, urlResponse: nil)
        let byDefault: ImageEncoders.Default = .default(compressionQuality: 0.5)
        #expect(byDefault.encode(ImageContent(image: image), context: context) != nil)
        #expect(ImageEncoders.ImageIO.isSupported(type: .png))
        #expect(ImageEncoders.ImageIO.isSupported(type: .png))
        #expect(!ImageEncoders.ImageIO.isSupported(type: AssetType(rawValue: "com.example.unknown")))
        let png: ImageEncoders.ImageIO = .imageIO(type: .png, compressionRatio: 1)
        let encoded = try #require(png.encode(ImageContent(image: image), context: context))
        #expect(AssetType(encoded) == .png)
    }
}

@Suite("이미지 클로저로 만든 요청")
struct ImageClosureRequestTests {
    @Test("ImageRequest(id:image:)는 클로저의 이미지를 돌려주고, 던진 에러는 dataLoadingFailed로 감쌈")
    func imageClosureRequests() async throws {
        let session = makeSession(loader: MockDataLoader())
        let image = try #require(UIImage(data: Fixtures.pngData))
        let response = try await session.imageTask(with: ImageRequest(id: "closure-ok", image: { ImageContent(image: image) })).response
        #expect(response.image === image)

        struct Failure: Error {}
        let failed = await result(of: session.imageTask(with: ImageRequest(id: "closure-fail", image: { throw Failure() })))
        #expect(failed.failureValue?.caseName == "dataLoadingFailed")
        #expect(failed.failureValue?.dataLoadingError is Failure)
    }
}

private final class ResumingLoader: DataLoading, @unchecked Sendable {
    struct Step {
        let status: Int
        let headers: [String: String]
        let body: Data
        let error: URLError?
    }

    private let lock = NSLock()
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        lock.lock()
        requests.append(request)
        let step = steps.removeFirst()
        lock.unlock()
        DispatchQueue.global().async {
            let response = HTTPURLResponse(url: request.url!, statusCode: step.status, httpVersion: "HTTP/1.1", headerFields: step.headers)!
            if !step.body.isEmpty {
                didReceiveData(step.body, response)
            }
            completion(step.error)
        }
        return AnonymousCancellable {}
    }

    var recordedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

@Suite("이어받기 파이프라인 경로")
struct ResumableDownloadSessionTests {
    private let image = Fixtures.png(width: 64, height: 64)

    private func interrupted(_ split: Int) -> ResumingLoader.Step {
        .init(
            status: 200, headers: ["Accept-Ranges": "bytes", "ETag": "\"v1\"", "Content-Length": "\(image.count)"], body: image.prefix(split),
            error: URLError(.networkConnectionLost))
    }

    @Test("끊긴 다운로드는 Range와 If-Range로 이어 받고, 이어 붙인 데이터로 디코딩")
    func interruptedDownloadResumes() async throws {
        let split = 100
        let loader = ResumingLoader([
            interrupted(split),
            .init(
                status: 206, headers: ["Content-Range": "bytes \(split)-\(image.count - 1)/\(image.count)", "ETag": "\"v1\"", "Content-Length": "\(image.count - split)"],
                body: image.dropFirst(split), error: nil),
        ])
        var configuration = ImageSession.Configuration(dataLoader: loader)
        configuration.memoryCache = nil
        configuration.isRateLimiterEnabled = false
        let session = ImageSession(configuration: configuration)
        let request = ImageRequest(url: Fixtures.url(80))
        let first = await result(of: session.imageTask(with: request))
        #expect(first.failureValue?.caseName == "dataLoadingFailed")
        let response = try await session.imageTask(with: request).response
        #expect(response.image.cgImage?.width == 64)
        let resumed = try #require(loader.recordedRequests.last)
        #expect(resumed.value(forHTTPHeaderField: "Range") == "bytes=\(split)-")
        #expect(resumed.value(forHTTPHeaderField: "If-Range") == "\"v1\"")
    }

    @Test("206의 Content-Range가 받아 둔 길이와 다르면 이어 붙이지 않고 실패")
    func mismatchedResumptionFails() async throws {
        let split = 100
        let loader = ResumingLoader([
            interrupted(split),
            .init(status: 206, headers: ["Content-Range": "bytes 0-\(image.count - 1)/\(image.count)", "ETag": "\"v1\""], body: image, error: nil),
        ])
        var configuration = ImageSession.Configuration(dataLoader: loader)
        configuration.memoryCache = nil
        configuration.isRateLimiterEnabled = false
        let session = ImageSession(configuration: configuration)
        let request = ImageRequest(url: Fixtures.url(81))
        _ = await result(of: session.imageTask(with: request))
        let second = await result(of: session.imageTask(with: request))
        #expect((second.failureValue?.dataLoadingError as? URLError)?.code == .cannotParseResponse)
    }

    @Test("받다 만 데이터 저장소는 개수 한도를 넘으면 오래된 것부터 지우고, removeAll로 비움")
    func storageEvictsOldestAndClears() throws {
        let storage = ResumableDataStorage()
        let sessionID = UUID()
        let response = HTTPURLResponse(
            url: Fixtures.url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Accept-Ranges": "bytes", "ETag": "\"v1\"", "Content-Length": "100"])!
        let resumable = try #require(ResumableData(response: response, data: Data(repeating: 1, count: 10)))
        let requests = (0..<101).map { ImageRequest(url: Fixtures.url(200 + $0)) }
        for request in requests {
            storage.storeResumableData(resumable, for: request, sessionID: sessionID)
        }
        #expect(storage.removeResumableData(for: requests[0], sessionID: sessionID) == nil)
        #expect(storage.removeResumableData(for: requests[100], sessionID: sessionID) != nil)
        storage.storeResumableData(resumable, for: requests[1], sessionID: sessionID)
        storage.removeAll()
        #expect(storage.removeResumableData(for: requests[1], sessionID: sessionID) == nil)

        var urlRequest = URLRequest(url: Fixtures.url)
        urlRequest.setValue("keep", forHTTPHeaderField: "X-Test-Keep")
        resumable.resume(request: &urlRequest)
        #expect(urlRequest.value(forHTTPHeaderField: "Range") == "bytes=10-")
        #expect(urlRequest.value(forHTTPHeaderField: "If-Range") == "\"v1\"")
        #expect(urlRequest.value(forHTTPHeaderField: "X-Test-Keep") == "keep")
        #expect(ResumableData.isResumedResponse(HTTPURLResponse(url: Fixtures.url, statusCode: 206, httpVersion: nil, headerFields: nil)!))
        #expect(!ResumableData.isResumedResponse(response))
    }
}
