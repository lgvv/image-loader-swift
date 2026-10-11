import Foundation
import ImageLoaderTesting
import Testing
import UIKit

@testable import ImageLoader

@Suite("이미지 형식 확장")
struct FormatExtensionTests {
    private static let customType: AssetType = "test.imageloader.ilxf"
    private static let magic = Data("ILXF".utf8)

    private static func registerCustomType() {
        AssetType.registerSignature(for: customType) { $0.starts(with: magic) }
    }

    private static func customData() -> Data {
        magic + Fixtures.pngData
    }

    private struct CustomDecoder: ImageDecoding {
        func decode(_ data: Data) throws -> ImageContent {
            guard let image = UIImage(data: data.dropFirst(FormatExtensionTests.magic.count)) else {
                throw ImageDecodingError.unknown
            }
            return ImageContent(image: image, type: FormatExtensionTests.customType, data: data)
        }
    }

    @Test("등록한 판정은 내장 판정이 알아보지 못한 데이터에만 쓰임")
    func registeredSignatureRunsAfterBuiltIns() {
        Self.registerCustomType()
        AssetType.registerSignature(for: "test.imageloader.fake-png") { $0.starts(with: [0x89, 0x50, 0x4E, 0x47]) }
        #expect(AssetType(Self.customData()) == Self.customType)
        #expect(AssetType(Fixtures.pngData) == .png)
        #expect(AssetType(Data("ILXX-unregistered".utf8)) == nil)
    }

    @Test("등록한 형식은 MIME이 이미지가 아니어도 디스크 캐시 저장 대상")
    func registeredTypeIsStorable() {
        Self.registerCustomType()
        let response = HTTPURLResponse(url: Fixtures.url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/octet-stream"])
        #expect(FetchDataStage.isStorableImageData(Self.customData(), response: response))
        #expect(!FetchDataStage.isStorableImageData(Data("ILXX-unregistered".utf8), response: response))
    }

    @Test("등록한 형식을 디코더와 함께 쓰면 불러오기와 디스크 저장까지 이어짐")
    func registeredFormatLoadsAndIsStored() async throws {
        Self.registerCustomType()
        let diskCache = InMemoryDiskCache()
        let loader = MockDataLoader(defaultResponse: .data(Self.customData(), headers: ["Content-Type": "application/octet-stream"]))
        let session = makeSession(loader: loader) {
            $0.diskCache = diskCache
            $0.makeImageDecoder = { context in
                AssetType(context.data) == Self.customType ? CustomDecoder() : ImageDecoderRegistry.shared.decoder(for: context)
            }
        }
        let response = try await session.imageTask(with: ImageRequest(url: Fixtures.url)).response
        #expect(response.content.type == Self.customType)
        #expect(response.image.size.width > 0)
        drainSessionQueue()
        #expect(await waitUntil { !diskCache.storage.value.isEmpty })
    }
}
