import CoreGraphics
import Foundation
import ImageIO
import ImageLoader
import ImageLoaderTesting
import Testing
import UniformTypeIdentifiers

extension AnimatedImageSource {
    fileprivate func decodeFrame(at index: Int) -> String {
        "outside-module"
    }
}

@Suite("AnimatedImageSource 공개 표면")
struct AnimatedImageSourcePublicSurfaceTests {
    private static func makeGIF(frameCount: Int) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frameCount, nil))
        for index in 0..<frameCount {
            let context = try #require(
                CGContext(
                    data: nil,
                    width: 8,
                    height: 8,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                ))
            context.setFillColor(red: CGFloat(index) / CGFloat(frameCount), green: 0.5, blue: 0.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let image = try #require(context.makeImage())
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary
            CGImageDestinationAddImage(destination, image, properties)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test("동기 decodeFrame(at:)은 모듈 밖에 보이지 않고, 프레임은 cachedFrame, frame(at:), prefetchFrames로만 얻음")
    func synchronousDecodeIsNotPublic() async throws {
        let loader = MockDataLoader(defaultResponse: .data(try Self.makeGIF(frameCount: 4)))
        let session = ImageSession(configuration: ImageSession.Configuration(dataLoader: loader))
        let url = try #require(URL(string: "https://example.com/surface.gif"))
        let response = try await session.imageTask(with: url).response
        let source = try #require(response.content.animatedImageSource)

        let resolved = source.decodeFrame(at: 1)
        #expect(resolved == "outside-module")

        #expect(source.frameCount == 4)
        #expect(source.cachedFrame(at: 0) != nil)
        let frame = await source.frame(at: 2)
        #expect(frame != nil)
        #expect(source.cachedFrame(at: 2) === frame)
        source.prefetchFrames([3])
        #expect(await pollUntil { source.cachedFrame(at: 3) != nil })
        #expect(source.isFrameFailed(at: 1) == false)
    }

    private func pollUntil(_ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }
}
