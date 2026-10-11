import Foundation
import ImageIO
import ImageLoaderTesting
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import ImageLoader

@Suite("보안 강화")
struct SecurityHardeningTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("로컬 파일은 일반 파일이고 크기 상한 안일 때만 읽음")
    func localResourceReadsOnlyBoundedRegularFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("image.png")
        try Fixtures.pngData.write(to: file)

        let ok = FetchDataStage.readLocalResource(file, limit: Fixtures.pngData.count)
        #expect((try? ok.get()) == Fixtures.pngData)

        let tooLarge = FetchDataStage.readLocalResource(file, limit: Fixtures.pngData.count - 1)
        #expect(tooLarge.failureValue?.caseName == "dataDownloadExceededMaximumSize")

        let link = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect((try? FetchDataStage.readLocalResource(link, limit: nil).get()) == Fixtures.pngData)

        let folder = FetchDataStage.readLocalResource(directory, limit: nil)
        #expect((folder.failureValue?.dataLoadingError as? URLError)?.code == .cannotOpenFile)

        let missing = FetchDataStage.readLocalResource(directory.appendingPathComponent("missing.png"), limit: nil)
        #expect(missing.failureValue?.caseName == "dataLoadingFailed")
    }

    private func response(status: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com/a.png")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    @Test("이어받기 검증값으로 약한 ETag는 쓰지 않고 Last-Modified로 대신함")
    func resumableDataIgnoresWeakETag() {
        let partial = Data(repeating: 1, count: 10)
        let weak = ResumableData(response: response(status: 200, headers: ["Content-Length": "100", "Accept-Ranges": "bytes", "ETag": "W/\"v1\""]), data: partial)
        #expect(weak == nil)
        let weakWithDate = ResumableData(
            response: response(status: 200, headers: ["Content-Length": "100", "Accept-Ranges": "bytes", "ETag": "W/\"v1\"", "Last-Modified": "Wed, 07 Oct 2026 00:00:00 GMT"]),
            data: partial)
        #expect(weakWithDate?.validator == "Wed, 07 Oct 2026 00:00:00 GMT")
        let strong = ResumableData(response: response(status: 200, headers: ["Content-Length": "100", "Accept-Ranges": "bytes", "ETag": "\"v1\""]), data: partial)
        #expect(strong?.validator == "\"v1\"")
    }

    @Test("206 응답은 Content-Range 시작이 받아 둔 길이와 같고 강한 ETag가 같을 때만 이어 붙임")
    func resumptionRequiresMatchingRangeAndValidator() throws {
        let partial = Data(repeating: 1, count: 10)
        let resumable = try #require(ResumableData(response: response(status: 200, headers: ["Content-Length": "100", "Accept-Ranges": "bytes", "ETag": "\"v1\""]), data: partial))
        #expect(resumable.isValidResumption(response(status: 206, headers: ["Content-Range": "bytes 10-99/100", "ETag": "\"v1\""])))
        #expect(resumable.isValidResumption(response(status: 206, headers: ["Content-Range": "bytes 10-99/*"])))
        #expect(!resumable.isValidResumption(response(status: 206, headers: ["Content-Range": "bytes 0-99/100", "ETag": "\"v1\""])))
        #expect(!resumable.isValidResumption(response(status: 206, headers: ["Content-Range": "bytes 10-99/100", "ETag": "\"v2\""])))
        #expect(!resumable.isValidResumption(response(status: 206, headers: ["ETag": "\"v1\""])))
        #expect(!resumable.isValidResumption(response(status: 200, headers: ["Content-Range": "bytes 10-99/100"])))
        #expect(ResumableData.rangeStart("bytes 10-99/100") == 10)
        #expect(ResumableData.rangeStart(" BYTES 7-8/9 ") == 7)
        #expect(ResumableData.rangeStart("items 1-2/3") == nil)
        #expect(ResumableData.rangeStart("bytes */100") == nil)
    }

    @Test("받다 만 데이터는 같은 imageID라도 URL이 다르면 섞지 않고, 파이프라인별로 지울 수 있음")
    func resumableStorageIsKeyedByURLAndClearable() throws {
        let storage = ResumableDataStorage()
        let sessionID = UUID()
        let resumable = try #require(
            ResumableData(response: response(status: 200, headers: ["Content-Length": "100", "Accept-Ranges": "bytes", "ETag": "\"v1\""]), data: Data(repeating: 1, count: 10)))
        var first = ImageRequest(url: URL(string: "https://example.com/a.png"))
        first.imageID = "shared"
        var second = ImageRequest(url: URL(string: "https://example.com/b.png"))
        second.imageID = "shared"
        storage.storeResumableData(resumable, for: first, sessionID: sessionID)
        #expect(storage.removeResumableData(for: second, sessionID: sessionID) == nil)
        #expect(storage.removeResumableData(for: first, sessionID: sessionID)?.data.count == 10)

        let other = UUID()
        storage.storeResumableData(resumable, for: first, sessionID: sessionID)
        storage.storeResumableData(resumable, for: first, sessionID: other)
        storage.removeAll(sessionID: sessionID)
        #expect(storage.removeResumableData(for: first, sessionID: sessionID) == nil)
        #expect(storage.removeResumableData(for: first, sessionID: other) != nil)
    }

    @Test("cache.removeAll(.disk)는 DataLoader의 URLCache와 받다 만 데이터도 지움")
    func removeAllClearsURLCacheAndResumableData() throws {
        let urlCache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = urlCache
        var sessionConfiguration = ImageSession.Configuration(dataLoader: DataLoader(configuration: configuration))
        sessionConfiguration.memoryCache = nil
        let session = ImageSession(configuration: sessionConfiguration)

        let url = URL(string: "https://example.com/cached.png")!
        let request = URLRequest(url: url)
        let cached = CachedURLResponse(response: response(status: 200, headers: ["Content-Type": "image/png"]), data: Fixtures.pngData)
        urlCache.storeCachedResponse(cached, for: request)
        #expect(urlCache.cachedResponse(for: request) != nil)

        let resumable = try #require(
            ResumableData(response: response(status: 200, headers: ["Content-Length": "100", "Accept-Ranges": "bytes", "ETag": "\"v1\""]), data: Data(repeating: 1, count: 10)))
        let imageRequest = ImageRequest(url: url)
        ResumableDataStorage.shared.storeResumableData(resumable, for: imageRequest, sessionID: session.id)

        session.cache.removeAll(caches: .disk)
        #expect(urlCache.cachedResponse(for: request) == nil)
        #expect(ResumableDataStorage.shared.removeResumableData(for: imageRequest, sessionID: session.id) == nil)
    }

    @Test("사용자 파일 이름 생성기가 경로를 벗어나는 이름을 주면 저장하지 않음")
    func unsafeGeneratedFilenamesAreRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheDirectory = directory.appendingPathComponent("cache", isDirectory: true)
        let cache = try DiskCache(path: cacheDirectory, filenameGenerator: { key in key })
        for name in ["../escape", "nested/name", ".hidden", "", "nul\u{0}name"] {
            #expect(cache.filename(for: name) == nil)
            cache.storeData(Data([1, 2, 3]), for: name)
        }
        cache.storeData(Data([4]), for: "plain")
        cache.flush()
        #expect(cache.filename(for: "plain") == "plain")
        #expect(cache.cachedData(for: "plain") == Data([4]))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("escape").path))
        #expect(cache.cachedData(for: "../escape") == nil)
    }

    @Test("데이터 로딩 에러 설명에 URL과 쿼리를 넣지 않음")
    func dataLoadingErrorDescriptionHasNoURL() {
        let failing = "https://example.com/a.png?token=placeholder-value"
        let error = ImageSession.Error.dataLoadingFailed(
            error: URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLStringErrorKey: failing, NSURLErrorFailingURLErrorKey: URL(string: failing)!]))
        #expect(!error.description.contains("example.com"))
        #expect(!error.description.contains("placeholder-value"))
        #expect(error.description.contains(error.diagnosticCode))
    }

    @Test("GIF 프레임이 헤더의 화면 크기보다 커도 화면 크기로 잘려 디코딩되므로, 화면 크기 기준 한도 판정이 우회되지 않음")
    func oversizedGIFFrameIsClippedToLogicalScreen() throws {
        var gif = DecodingFixtures.gif(frameCount: 2, width: 64, height: 64)
        gif[6] = 1
        gif[7] = 0
        gif[8] = 1
        gif[9] = 0
        #expect(ImageHeaderScanner.pixelSize(of: gif) == ImageHeader.PixelSize(width: 1, height: 1))
        let source = try #require(CGImageSourceCreateWithData(gif as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 1, nil))
        #expect(decoded.width * decoded.height <= 1)
        let animated = try #require(AnimatedImageSource(data: gif, scale: 1, thumbnail: nil))
        #expect(animated.firstFrame.width * animated.firstFrame.height <= 1)
        let second = try #require(animated.decodeFrame(at: 1))
        #expect(second.width * second.height <= 1)
    }

    @Test("원본 크기 디코딩의 한도 검사는 0번 이미지와 대표 이미지 가운데 큰 쪽으로 함")
    func decodingLimitsUsePrimaryImage() throws {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, DecodingFixtures.frame(index: 0, width: 8, height: 8), nil)
        CGImageDestinationAddImage(destination, DecodingFixtures.frame(index: 1, width: 64, height: 64), nil)
        try #require(CGImageDestinationFinalize(destination))
        var bytes = [UInt8](data as Data)
        let marker = Array("pitm".utf8)
        let box = try #require((0..<bytes.count - 4).first { Array(bytes[$0..<$0 + 4]) == marker })
        try #require(bytes[box + 4] == 0 && bytes[box + 8] == 0 && bytes[box + 9] == 1)
        bytes[box + 9] = 2
        let heic = Data(bytes)
        let source = try #require(CGImageSourceCreateWithData(heic as CFData, nil))
        try #require(CGImageSourceGetPrimaryImageIndex(source) == 1)
        #expect(throws: (any Error).self) { try ImageDecodingLimits(maximumPixelCount: 8 * 8, maximumSourcePixelCount: nil).validate(heic) }
        #expect(throws: Never.self) { try ImageDecodingLimits(maximumPixelCount: 64 * 64, maximumSourcePixelCount: nil).validate(heic) }
    }
}
