import CoreGraphics
import Foundation
import ImageIO
import ImageLoaderTesting
import Testing
import UIKit

@testable import ImageLoader

@Suite("디코더 라우팅, 썸네일, 디코딩 한도")
struct ImageDecodersTests {
    @Test("다중 이미지 ICO, TIFF와 단일 프레임 GIF, WebP는 정적 디코더로 감")
    func multiImageContainersAreNotAnimated() throws {
        let registry = ImageDecoderRegistry()
        let cases: [(String, Data)] = [
            ("ico", DecodingFixtures.ico(sizes: [16, 32])),
            ("tiff", DecodingFixtures.tiff(pageCount: 3)),
            ("gif-single", DecodingFixtures.gif(frameCount: 1)),
            ("png", DecodingFixtures.png(width: 8, height: 8)),
            ("jpeg", DecodingFixtures.jpeg(width: 8, height: 8)),
            ("webp-static", DecodingFixtures.staticWebP()),
            ("webp-single-frame", DecodingFixtures.webp(frameCount: 1)),
        ]
        for (name, data) in cases {
            let context = DecodingFixtures.context(for: data)
            #expect(ImageDecoders.Animated(context: context) == nil, "\(name)")
            let decoder = try #require(registry.decoder(for: context), "\(name)")
            #expect(decoder is ImageDecoders.Default, "\(name)")
            let content = try decoder.decode(data)
            #expect(content.animatedImageSource == nil, "\(name)")
            #expect(content.image.cgImage != nil, "\(name)")
        }
    }

    @Test("움직이는 GIF, APNG, WebP는 애니메이션 디코더로 감")
    func animatedFormatsRouteToAnimatedDecoder() throws {
        let registry = ImageDecoderRegistry()
        let cases: [(String, Data, AssetType, Int)] = [
            ("gif", DecodingFixtures.gif(frameCount: 6), .gif, 6),
            ("apng", DecodingFixtures.apng(frameCount: 4), .png, 4),
            ("webp", DecodingFixtures.webp(frameCount: 5), .webp, 5),
        ]
        for (name, data, type, frameCount) in cases {
            let decoder = try #require(registry.decoder(for: DecodingFixtures.context(for: data)), "\(name)")
            #expect(decoder is ImageDecoders.Animated, "\(name)")
            #expect(decoder.isAsynchronous, "\(name)")
            let content = try decoder.decode(data)
            #expect(content.type == type, "\(name)")
            #expect(content.data == data, "\(name)")
            let source = try #require(content.animatedImageSource, "\(name)")
            #expect(source.frameCount == frameCount, "\(name)")
            #expect(content.image.cgImage === source.cachedFrame(at: 0), "\(name)")
        }
    }

    @Test("컨테이너 검사는 통과했지만 ImageIO가 한 프레임만 보면 정적 결과로 대체")
    func animatedDecoderFallsBackToStaticWhenImageIODisagrees() throws {
        let gif = DecodingFixtures.gif(frameCount: 2)
        let offsets = DecodingFixtures.gifFrameDescriptorOffsets(gif)
        let truncated = Data(gif.prefix(offsets[1] + 1))
        let decoder = try #require(ImageDecoders.Animated(context: DecodingFixtures.context(for: truncated)))
        let content = try decoder.decode(truncated)
        #expect(content.animatedImageSource == nil)
        #expect(content.type == .gif)
        #expect(content.data == truncated)
        #expect(DecodingFixtures.displaySize(of: content.image) == CGSize(width: 40, height: 40))
        #expect(throws: (any Error).self) { try decoder.decode(Data([0x47, 0x49, 0x46])) }
    }

    @Test("Default: 타입, 배율, GIF data 첨부, 동기 여부")
    func defaultDecoderBasics() throws {
        let jpeg = DecodingFixtures.jpeg(width: 30, height: 20)
        var request = ImageRequest(url: Fixtures.url)
        request.scale = 2
        let decoder = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: jpeg, request: request)))
        #expect(decoder.isAsynchronous == false)
        let content = try decoder.decode(jpeg)
        #expect(content.type == .jpeg)
        #expect(content.data == nil)
        #expect(content.image.scale == 2)
        #expect(content.image.size == CGSize(width: 15, height: 10))

        let gif = DecodingFixtures.gif(frameCount: 1)
        let gifContainer = try ImageDecoders.Default().decode(gif)
        #expect(gifContainer.type == .gif)
        #expect(gifContainer.data == gif)

        request.thumbnail = .init(maxPixelSize: 10)
        #expect(ImageDecoders.Default(context: DecodingFixtures.context(for: jpeg, request: request))?.isAsynchronous == true)
        #expect(ImageDecoders.Default().isAsynchronous == false)
        #expect(throws: (any Error).self) { try ImageDecoders.Default().decode(Data("not an image".utf8)) }
    }

    @Test("decompression 표시는 원본 디코딩 결과에만 붙음")
    func decompressionFlagOnlyForPlainDecodes() throws {
        let png = DecodingFixtures.png(width: 30, height: 20)
        let plain = ImageRequest(url: Fixtures.url)
        let plainResponse = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: png, request: plain)))
            .decode(DecodingFixtures.context(for: png, request: plain))
        #expect(ImageDecompression.isDecompressionNeeded(for: plainResponse.image) == true)

        var thumbnailRequest = plain
        thumbnailRequest.thumbnail = .init(maxPixelSize: 10)
        let thumbnailResponse = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: png, request: thumbnailRequest)))
            .decode(DecodingFixtures.context(for: png, request: thumbnailRequest))
        #expect(ImageDecompression.isDecompressionNeeded(for: thumbnailResponse.image) != true)

        let gif = DecodingFixtures.gif(frameCount: 3)
        let animatedContext = DecodingFixtures.context(for: gif, request: plain)
        let animatedResponse = try #require(ImageDecoders.Animated(context: animatedContext, frameCache: AnimatedFrameCache(costLimit: 1 << 20)))
            .decode(animatedContext)
        #expect(animatedResponse.content.animatedImageSource != nil)
        #expect(ImageDecompression.isDecompressionNeeded(for: animatedResponse.image) != true)
    }

    @Test("고정 maxPixelSize 썸네일은 EXIF 1~8 모두 긴 변이 한도", arguments: 1...8)
    func fixedThumbnailRespectsOrientation(rawOrientation: UInt32) throws {
        let orientation = try #require(CGImagePropertyOrientation(rawValue: rawOrientation))
        let data = DecodingFixtures.jpeg(width: 400, height: 200, orientation: orientation)
        var request = ImageRequest(url: Fixtures.url)
        request.thumbnail = .init(maxPixelSize: 100)
        let image = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: data, request: request))).decode(data).image
        let swapped = ImageHeader.swapsDimensions(orientation)
        #expect(image.imageOrientation == .up)
        #expect(DecodingFixtures.displaySize(of: image) == (swapped ? CGSize(width: 50, height: 100) : CGSize(width: 100, height: 50)))
    }

    @Test("가변 크기 썸네일은 EXIF 5~8에서 가로세로를 바꿔 계산", arguments: 1...8)
    func flexibleThumbnailRespectsOrientation(rawOrientation: UInt32) throws {
        let orientation = try #require(CGImagePropertyOrientation(rawValue: rawOrientation))
        let swapped = ImageHeader.swapsDimensions(orientation)
        let data = DecodingFixtures.jpeg(width: 400, height: 200, orientation: orientation)
        let target = CGSize(width: 200, height: 100)
        let expectations: [(ImageFilterOptions.ContentMode, Bool, CGSize)] = [
            (.aspectFill, true, swapped ? CGSize(width: 200, height: 400) : CGSize(width: 200, height: 100)),
            (.aspectFit, true, swapped ? CGSize(width: 50, height: 100) : CGSize(width: 200, height: 100)),
            (.aspectFill, false, swapped ? CGSize(width: 200, height: 400) : CGSize(width: 200, height: 100)),
            (.aspectFit, false, swapped ? CGSize(width: 50, height: 100) : CGSize(width: 200, height: 100)),
        ]
        for (contentMode, withTransform, expected) in expectations {
            var options = ImageRequest.ThumbnailOptions(size: target, unit: .pixels, contentMode: contentMode)
            options.createThumbnailWithTransform = withTransform
            var request = ImageRequest(url: Fixtures.url)
            request.thumbnail = options
            let image = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: data, request: request))).decode(data).image
            let label = "orientation=\(rawOrientation) mode=\(contentMode) transform=\(withTransform)"
            #expect(DecodingFixtures.displaySize(of: image) == expected, "\(label)")
            #expect(image.imageOrientation == (withTransform ? .up : ImageHeader.imageOrientation(orientation)), "\(label)")
        }
    }

    @Test("makeThumbnail(with:)는 디코더와 같은 크기 규칙")
    func makeThumbnailMatchesDecoder() throws {
        let data = DecodingFixtures.jpeg(width: 400, height: 200, orientation: .right)
        let image = try #require(ImageRequest.ThumbnailOptions(size: CGSize(width: 200, height: 100), unit: .pixels).makeThumbnail(with: data))
        #expect(DecodingFixtures.displaySize(of: image) == CGSize(width: 200, height: 400))
        let original = try #require(ImageRequest.ThumbnailOptions(maximumPixelCount: 1_000_000).makeThumbnail(with: data))
        #expect(DecodingFixtures.displaySize(of: original) == CGSize(width: 200, height: 400))
        #expect(ImageRequest.ThumbnailOptions(maxPixelSize: 10).makeThumbnail(with: Data([1, 2, 3])) == nil)
    }

    @Test("썸네일 identifier는 고정 형식이고 옵션마다 다름")
    func thumbnailIdentifiersAreStableAndDistinct() {
        typealias Options = ImageRequest.ThumbnailOptions
        #expect(Options(maxPixelSize: 100).identifier == "imageloader/thumbnail?maxPixelSize=100.0,options=1111")
        #expect(Options(maximumPixelCount: 1000).identifier == "imageloader/thumbnail?maxPixelCount=1000,options=1111")
        #expect(
            Options(size: CGSize(width: 120, height: 80.5), unit: .pixels, contentMode: .aspectFit).identifier
                == "imageloader/thumbnail?width=120,height=81,contentMode=aspectFit,options=1111")
        #expect(
            Options(size: CGSize(width: 120, height: 80), unit: .pixels).identifier
                == "imageloader/thumbnail?width=120,height=80,contentMode=aspectFill,options=1111")
        var noTransform = Options(maxPixelSize: 100)
        noTransform.createThumbnailWithTransform = false
        var noCache = Options(maxPixelSize: 100)
        noCache.shouldCacheImmediately = false
        var notAlways = Options(maxPixelSize: 100)
        notAlways.createThumbnailFromImageAlways = false
        var notIfAbsent = Options(maxPixelSize: 100)
        notIfAbsent.createThumbnailFromImageIfAbsent = false
        let all: [Options] = [
            Options(maxPixelSize: 100),
            Options(maxPixelSize: 101),
            Options(maximumPixelCount: 100),
            Options(size: CGSize(width: 100, height: 100), unit: .pixels),
            Options(size: CGSize(width: 100, height: 100), unit: .pixels, contentMode: .aspectFit),
            Options(size: CGSize(width: 100, height: 101), unit: .pixels),
            noTransform, noCache, notAlways, notIfAbsent,
        ]
        #expect(Set(all.map(\.identifier)).count == all.count)
        #expect(Set(all).count == all.count)
        #expect(Options(maxPixelSize: 100) == Options(maxPixelSize: 100))
        #expect(Options(maxPixelSize: 100).identifier == Options(maxPixelSize: 100).identifier)
        #expect(Options.scaleDownLargeImages() == Options(maximumPixelCount: 60 * 1024 * 1024 / 4))
        #expect(Options.scaleDownLargeImages(limitBytes: 4000) == Options(maximumPixelCount: 1000))
        #expect(Options(maximumPixelCount: 0) == Options(maximumPixelCount: 1))
    }

    @Test("maximumPixelCount는 한도를 넘는 이미지만 줄임")
    func maximumPixelCountDownscalesOnlyLargeImages() throws {
        let small = DecodingFixtures.jpeg(width: 300, height: 200)
        var request = ImageRequest(url: Fixtures.url)
        request.thumbnail = .init(maximumPixelCount: 100_000)
        let smallImage = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: small, request: request))).decode(small).image
        #expect(DecodingFixtures.displaySize(of: smallImage) == CGSize(width: 300, height: 200))
        #expect(ImageDecompression.isDecompressionNeeded(for: smallImage) == true)

        let large = DecodingFixtures.jpeg(width: 1000, height: 800)
        request.thumbnail = .init(maximumPixelCount: 200_000)
        let largeImage = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: large, request: request))).decode(large).image
        let largeSize = DecodingFixtures.displaySize(of: largeImage)
        #expect(largeSize == CGSize(width: 500, height: 400))
        #expect(largeSize.width * largeSize.height <= 200_000)
        #expect(ImageDecompression.isDecompressionNeeded(for: largeImage) != true)

        let rotated = DecodingFixtures.jpeg(width: 1000, height: 800, orientation: .right)
        let rotatedImage = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: rotated, request: request))).decode(rotated).image
        #expect(DecodingFixtures.displaySize(of: rotatedImage) == CGSize(width: 400, height: 500))
        #expect(rotatedImage.imageOrientation == .up)
    }

    @Test("maximumPixelCount로 JPEG를 줄일 때는 1/2, 1/4, 1/8 가운데 한도 안의 가장 큰 비율로 맞추고, 다른 형식과 1/8보다 작은 비율은 정확히 줄임")
    func maximumPixelCountSnapsJPEGToScaledDecodingFactor() throws {
        var request = ImageRequest(url: Fixtures.url)
        request.thumbnail = .init(maximumPixelCount: 1_000_000)
        let jpeg = DecodingFixtures.jpeg(width: 1600, height: 1200)
        let jpegImage = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: jpeg, request: request))).decode(jpeg).image
        #expect(DecodingFixtures.displaySize(of: jpegImage) == CGSize(width: 800, height: 600))

        let png = DecodingFixtures.png(width: 1600, height: 1200)
        let pngImage = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: png, request: request))).decode(png).image
        let pngSize = DecodingFixtures.displaySize(of: pngImage)
        #expect(pngSize.width == 1154)
        #expect(pngSize.width * pngSize.height <= 1_000_000)

        request.thumbnail = .init(maximumPixelCount: 10_000)
        let tinyImage = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: jpeg, request: request))).decode(jpeg).image
        #expect(DecodingFixtures.displaySize(of: tinyImage).width == 115)

        #expect(ImageRequest.ThumbnailOptions.scaledDecodingFactor(atMost: 0.59) == 0.5)
        #expect(ImageRequest.ThumbnailOptions.scaledDecodingFactor(atMost: 0.25) == 0.25)
        #expect(ImageRequest.ThumbnailOptions.scaledDecodingFactor(atMost: 0.2) == 0.125)
        #expect(ImageRequest.ThumbnailOptions.scaledDecodingFactor(atMost: 0.1) == 0.1)
    }

    @Test("디코딩 한도: 원본 크기 디코딩은 maximumPixelCount, 썸네일은 결과 크기와 maximumSourcePixelCount로 판정")
    func decodingLimitsRejectLargeImages() throws {
        let png = DecodingFixtures.png(width: 40, height: 40)
        let limits = ImageDecodingLimits(maximumPixelCount: 1000)
        let expected = ImageDecodingLimits.Error.pixelCountExceeded(pixelCount: 1600, limit: 1000)
        let decoder = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: png, limits: limits)))
        #expect(throws: expected) { try decoder.decode(png) }

        var scaledRequest = ImageRequest(url: Fixtures.url)
        scaledRequest.thumbnail = .scaleDownLargeImages(limitBytes: 1024)
        let scaledDecoder = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: png, request: scaledRequest, limits: limits)))
        let scaled = try scaledDecoder.decode(png).image
        #expect(DecodingFixtures.displaySize(of: scaled) == CGSize(width: 16, height: 16))

        var notShrinking = ImageRequest(url: Fixtures.url)
        notShrinking.thumbnail = .init(maxPixelSize: 1000)
        let notShrinkingDecoder = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: png, request: notShrinking, limits: limits)))
        #expect(throws: expected) { try notShrinkingDecoder.decode(png) }
        let unshrunk = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: png, request: notShrinking, limits: .unlimited))).decode(png).image
        #expect(DecodingFixtures.displaySize(of: unshrunk) == CGSize(width: 40, height: 40))

        let sourceLimits = ImageDecodingLimits(maximumPixelCount: nil, maximumSourcePixelCount: 1000)
        let sourceLimitedDecoder = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: png, request: scaledRequest, limits: sourceLimits)))
        #expect(throws: expected) { try sourceLimitedDecoder.decode(png) }

        let gif = DecodingFixtures.gif(frameCount: 3)
        let animated = try #require(ImageDecoders.Animated(context: DecodingFixtures.context(for: gif, limits: limits)))
        #expect(throws: expected) { try animated.decode(gif) }
        var gifThumbnail = ImageRequest(url: Fixtures.url)
        gifThumbnail.thumbnail = .init(maxPixelSize: 20)
        let animatedThumbnail = try #require(ImageDecoders.Animated(context: DecodingFixtures.context(for: gif, request: gifThumbnail, limits: limits)))
        #expect(try animatedThumbnail.decode(gif).animatedImageSource?.frameCount == 3)
        let animatedSourceLimited = try #require(ImageDecoders.Animated(context: DecodingFixtures.context(for: gif, request: gifThumbnail, limits: sourceLimits)))
        #expect(throws: expected) { try animatedSourceLimited.decode(gif) }

        let unlimited = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: png, limits: .unlimited)))
        #expect(throws: Never.self) { try unlimited.decode(png) }
        #expect(throws: expected) { try limits.validate(png) }
        #expect(throws: expected) { try sourceLimits.validate(png) }
        #expect(throws: Never.self) { try ImageDecodingLimits.unlimited.validate(png) }
    }

    @Test("기본 한도: 원본 디코딩은 기기 메모리 비례(4096²~8192²), 원본 헤더 상한은 16384²")
    func defaultLimitsScaleWithDeviceMemory() throws {
        typealias Limits = ImageDecodingLimits
        let gigabyte: UInt64 = 1 << 30
        #expect(Limits.memoryScaledPixelCount(physicalMemory: gigabyte) == 4_096 * 4_096)
        #expect(Limits.memoryScaledPixelCount(physicalMemory: 2 * gigabyte) == 4_096 * 4_096)
        #expect(Limits.memoryScaledPixelCount(physicalMemory: 3 * gigabyte) == 25_165_824)
        #expect(Limits.memoryScaledPixelCount(physicalMemory: 4 * gigabyte) == 33_554_432)
        #expect(Limits.memoryScaledPixelCount(physicalMemory: 6 * gigabyte) == 50_331_648)
        #expect(Limits.memoryScaledPixelCount(physicalMemory: 8 * gigabyte) == 8_192 * 8_192)
        #expect(Limits.memoryScaledPixelCount(physicalMemory: 64 * gigabyte) == 8_192 * 8_192)
        #expect(Limits.memoryScaledPixelCount(physicalMemory: .max) == 8_192 * 8_192)
        #expect(Limits.default.maximumPixelCount == Limits.memoryScaledPixelCount(physicalMemory: ProcessInfo.processInfo.physicalMemory))
        #expect(Limits.default.maximumSourcePixelCount == 16_384 * 16_384)
        #expect(ImageSession.Configuration().decodingLimits == .default)
        #expect(ImageDecodingContext(request: ImageRequest(url: Fixtures.url), data: Data()).decodingLimits == .default)
        let defaultCount = try #require(Limits.default.maximumPixelCount)
        #expect(defaultCount * 4 <= 256 * 1024 * 1024)
        #expect(UInt64(defaultCount * 4) <= max(ProcessInfo.processInfo.physicalMemory / 32, 64 * 1024 * 1024))
        #expect(Limits.unlimited.maximumPixelCount == nil && Limits.unlimited.maximumSourcePixelCount == nil)
    }

    @Test("기본 한도는 압축 폭탄(20000x20000)을 헤더만 보고 거부하고, 원본 한도를 넘는 9000x9000은 축소 요청에서만 허용")
    func defaultLimitsRejectDecompressionBomb() throws {
        let bomb = DecodingFixtures.zeroFilledPNG(width: 20000, height: 20000)
        #expect(bomb.count < 100_000)
        let expected = ImageDecodingLimits.Error.pixelCountExceeded(pixelCount: 400_000_000, limit: 16_384 * 16_384)
        let start = DispatchTime.now().uptimeNanoseconds
        #expect(throws: expected) { try ImageDecoders.Default().decode(bomb) }
        var request = ImageRequest(url: Fixtures.url)
        request.thumbnail = .scaleDownLargeImages()
        let thumbnailDecoder = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: bomb, request: request)))
        #expect(throws: expected) { try thumbnailDecoder.decode(bomb) }
        #expect(elapsedSeconds(since: start) < 1)

        let large = DecodingFixtures.zeroFilledPNG(width: 9000, height: 9000)
        let plainLimit = try #require(ImageDecodingLimits.default.maximumPixelCount)
        #expect(throws: ImageDecodingLimits.Error.pixelCountExceeded(pixelCount: 81_000_000, limit: plainLimit)) {
            try ImageDecoders.Default().decode(large)
        }
        let scaledDecoder = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: large, request: request)))
        let scaled = try scaledDecoder.decode(large).image
        let size = DecodingFixtures.displaySize(of: scaled)
        #expect(size.width * size.height <= CGFloat(60 * 1024 * 1024 / 4))
        #expect(size.width * size.height <= CGFloat(plainLimit))
    }

    @Test("헤더 스캐너는 ImageIO와 같은 크기를 내고, 잘린 입력에서는 nil이거나 같은 값")
    func headerScannerMatchesImageIO() throws {
        let fixtures: [(String, Data)] = [
            ("jpeg", DecodingFixtures.jpeg(width: 64, height: 48)),
            ("jpeg-exif-right", DecodingFixtures.jpeg(width: 64, height: 48, orientation: .right)),
            ("jpeg-progressive", DecodingFixtures.progressiveJPEG(width: 70, height: 30, orientation: .leftMirrored)),
            ("png", DecodingFixtures.png(width: 33, height: 17)),
            ("png-alpha", DecodingFixtures.png(width: 9, height: 31, opaque: false)),
            ("png-zero-filled", DecodingFixtures.zeroFilledPNG(width: 3000, height: 2000)),
            ("gif", DecodingFixtures.gif(frameCount: 1, width: 21, height: 13)),
            ("gif-animated", DecodingFixtures.gif(frameCount: 4, width: 40, height: 22)),
            ("apng", DecodingFixtures.apng(frameCount: 3, width: 12, height: 34)),
            ("webp-lossless", DecodingFixtures.staticWebP(width: 10, height: 6)),
            ("webp-animated", DecodingFixtures.webp(frameCount: 3, width: 16, height: 8)),
        ]
        #expect(DecodingFixtures.progressiveJPEG(width: 70, height: 30).range(of: Data([0xFF, 0xC2])) != nil)
        for (name, data) in fixtures {
            let scanned = try #require(ImageHeaderScanner.pixelSize(of: data), "\(name)")
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil), "\(name)")
            let properties = try #require(ImageHeader.properties(of: source, at: 0), "\(name)")
            #expect(ImageHeader.pixelSize(from: properties) == scanned, "\(name)")
            for length in 0..<min(data.count, 600) {
                let prefix = ImageHeaderScanner.pixelSize(of: Data(data.prefix(length)))
                #expect(prefix == nil || prefix == scanned, "\(name) prefix \(length)")
            }
        }
        #expect(ImageHeaderScanner.pixelSize(of: DecodingFixtures.lossyWebPHeader(width: 321, height: 123)) == ImageHeader.PixelSize(width: 321, height: 123))
        #expect(ImageHeaderScanner.pixelSize(of: DecodingFixtures.ico(sizes: [16, 32])) == nil)
        #expect(ImageHeaderScanner.pixelSize(of: DecodingFixtures.tiff(pageCount: 1)) == nil)
        #expect(ImageHeaderScanner.pixelSize(of: Data()) == nil)
        #expect(ImageHeaderScanner.pixelSize(of: Data([0xFF, 0xD8, 0xFF, 0xDA, 0, 2, 0, 0, 0, 0, 0, 0])) == nil)
        #expect(ImageHeaderScanner.pixelSize(of: Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0])) == nil)
        #expect(ImageHeaderScanner.pixelSize(of: Data([0xFF, 0xD8] + Array(repeating: 0xFF, count: 64))) == nil)
        #expect(ImageHeaderScanner.pixelSize(of: Data([0xFF, 0xD8, 0xFF, 0xC0, 0, 17, 8, 0, 0, 0, 10] + Array(repeating: 0, count: 12))) == nil)

        var generator = SeededGenerator(seed: 0x4EAD_E125)
        for (_, original) in fixtures {
            for _ in 0..<200 {
                var bytes = [UInt8](original.prefix(256))
                for _ in 0..<Int.random(in: 1...6, using: &generator) {
                    bytes[Int.random(in: 0..<bytes.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
                }
                _ = ImageHeaderScanner.pixelSize(of: Data(bytes))
            }
        }
    }

    @Test("한도 검사는 지원 포맷이면 헤더 바이트만 읽어 동기 디코딩을 유지하고, 못 읽는 포맷만 비동기로 보냄")
    func limitCheckKeepsSynchronousDecodingForScannableFormats() throws {
        let scannable: [(String, Data)] = [
            ("jpeg", DecodingFixtures.jpeg(width: 30, height: 20)),
            ("png", DecodingFixtures.png(width: 30, height: 20)),
            ("gif", DecodingFixtures.gif(frameCount: 1)),
            ("webp", DecodingFixtures.staticWebP()),
        ]
        for (name, data) in scannable {
            let decoder = try #require(ImageDecoders.Default(context: DecodingFixtures.context(for: data)), "\(name)")
            #expect(decoder.isAsynchronous == false, "\(name)")
        }
        let unscannable: [(String, Data)] = [
            ("ico", DecodingFixtures.ico(sizes: [16])),
            ("tiff", DecodingFixtures.tiff(pageCount: 1)),
        ]
        for (name, data) in unscannable {
            #expect(ImageDecoders.Default(context: DecodingFixtures.context(for: data))?.isAsynchronous == true, "\(name)")
            #expect(ImageDecoders.Default(context: DecodingFixtures.context(for: data, limits: .unlimited))?.isAsynchronous == false, "\(name)")
            let limits = ImageDecodingLimits(maximumPixelCount: 10)
            #expect(throws: ImageDecodingLimits.Error.self, "\(name)") {
                try ImageDecoders.Default(context: DecodingFixtures.context(for: data, limits: limits))?.decode(data)
            }
        }
    }

    @Test("파이프라인은 설정의 디코딩 한도를 컨텍스트로 넘김")
    func sessionPassesDecodingLimits() async throws {
        let loader = MockDataLoader(defaultResponse: .data(DecodingFixtures.png(width: 40, height: 40)))
        let session = makeSession(loader: loader) {
            $0.decodingLimits = ImageDecodingLimits(maximumPixelCount: 100)
        }
        let outcome = await result(of: session.imageTask(with: Fixtures.url(1)))
        guard case .failure(.decodingFailed(_, let context, let error)) = outcome else {
            Issue.record("Expected decodingFailed, got \(outcome)")
            return
        }
        #expect(context.decodingLimits.maximumPixelCount == 100)
        #expect(error as? ImageDecodingLimits.Error == .pixelCountExceeded(pixelCount: 1600, limit: 100))

        let allowed = makeSession(loader: loader)
        let image = try await allowed.imageTask(with: Fixtures.url(2)).image
        #expect(DecodingFixtures.displaySize(of: image) == CGSize(width: 40, height: 40))
    }

    @Test("디스크 캐시 히트도 설정의 디코딩 한도로 디코딩: 한도를 넘으면 항목을 남긴 채 다시 받지 않고 실패")
    func diskCacheHitPassesDecodingLimits() async throws {
        let png = DecodingFixtures.png(width: 40, height: 40)
        let request = ImageRequest(url: Fixtures.url(30))

        let limitedCache = InMemoryDiskCache()
        let limitedLoader = MockDataLoader(defaultResponse: .data(png))
        let limited = makeSession(loader: limitedLoader) {
            $0.diskCache = limitedCache
            $0.decodingLimits = ImageDecodingLimits(maximumPixelCount: 100)
        }
        limitedCache.storeData(png, for: limited.cache.makeDiskCacheKey(for: request))
        let outcome = await result(of: limited.imageTask(with: request))
        guard case .failure(.decodingFailed(_, let context, let error)) = outcome else {
            Issue.record("Expected decodingFailed, got \(outcome)")
            return
        }
        #expect(limitedCache.readCount.value >= 1)
        #expect(limitedLoader.counts.started == 0)
        #expect(context.cacheType == .disk)
        #expect(limitedCache.storage.value[limited.cache.makeDiskCacheKey(for: request)] == png)
        #expect(context.decodingLimits.maximumPixelCount == 100)
        #expect(error as? ImageDecodingLimits.Error == .pixelCountExceeded(pixelCount: 1600, limit: 100))

        let defaultCache = InMemoryDiskCache()
        let defaultLoader = MockDataLoader(defaultResponse: .data(png))
        let unlimited = makeSession(loader: defaultLoader) { $0.diskCache = defaultCache }
        defaultCache.storeData(png, for: unlimited.cache.makeDiskCacheKey(for: request))
        let response = try await unlimited.imageTask(with: request).response
        #expect(response.cacheType == .disk)
        #expect(defaultLoader.counts.started == 0)
    }

    @Test("cache.cachedImage(for:caches: [.disk])도 설정의 디코딩 한도를 따름")
    func cachedImageFromDiskPassesDecodingLimits() throws {
        let png = DecodingFixtures.png(width: 40, height: 40)
        let request = ImageRequest(url: Fixtures.url(31))
        let diskCache = InMemoryDiskCache()
        let loader = MockDataLoader(defaultResponse: .data(png))
        let limited = makeSession(loader: loader) {
            $0.diskCache = diskCache
            $0.decodingLimits = ImageDecodingLimits(maximumPixelCount: 100)
        }
        diskCache.storeData(png, for: limited.cache.makeDiskCacheKey(for: request))
        #expect(limited.cache.cachedImage(for: request, caches: [.disk]) == nil)
        #expect(diskCache.readCount.value == 1)

        let allowed = makeSession(loader: loader) {
            $0.diskCache = diskCache
            $0.decodingLimits = ImageDecodingLimits(maximumPixelCount: 1600)
        }
        let content = try #require(allowed.cache.cachedImage(for: request, caches: [.disk]))
        #expect(DecodingFixtures.displaySize(of: content.image) == CGSize(width: 40, height: 40))
        #expect(loader.counts.started == 0)
    }

    @Test("가변 크기 썸네일: 픽셀로 반올림한 값을 저장해 Hashable과 identifier가 항상 같은 판정")
    func flexibleThumbnailKeysAgreeWithIdentifiers() {
        typealias Options = ImageRequest.ThumbnailOptions
        let widths: [CGFloat] = [100, 100.000001, 99.9999, 100.4, 100.5, 100.6, 300.999, 301, 33.4 * 3, 100.333 * 3]
        var all: [Options] = []
        for width in widths {
            for contentMode in [ImageFilterOptions.ContentMode.aspectFill, .aspectFit] {
                all.append(Options(size: CGSize(width: width, height: 50), unit: .pixels, contentMode: contentMode))
            }
        }
        for lhs in all {
            for rhs in all {
                #expect((lhs == rhs) == (lhs.identifier == rhs.identifier), "\(lhs.identifier) vs \(rhs.identifier)")
                if lhs == rhs {
                    #expect(lhs.hashValue == rhs.hashValue)
                }
            }
        }
        #expect(Options(size: CGSize(width: 100.000001, height: 50), unit: .pixels) == Options(size: CGSize(width: 100, height: 50), unit: .pixels))
        #expect(Options(size: CGSize(width: 300.999, height: 50), unit: .pixels) == Options(size: CGSize(width: 301, height: 50), unit: .pixels))
        #expect(Options(size: CGSize(width: 100.6, height: 50), unit: .pixels) != Options(size: CGSize(width: 100, height: 50), unit: .pixels))
        let scale = Screen.scale
        #expect(
            Options(size: CGSize(width: 100.333, height: 20), unit: .points)
                == Options(size: CGSize(width: (100.333 * scale).rounded(), height: (20 * scale).rounded()), unit: .pixels))
        let degenerate = Options(size: CGSize(width: CGFloat.nan, height: CGFloat.infinity), unit: .pixels)
        #expect(degenerate == Options(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude), unit: .pixels))
        #expect(degenerate.identifier == "imageloader/thumbnail?width=0,height=1073741824,contentMode=aspectFill,options=1111")
        #expect(Options(size: CGSize(width: -5, height: 10), unit: .pixels).identifier.contains("width=0,height=10,"))
    }

    @Test("decompression은 Display P3 색공간을 보존")
    func decompressionPreservesDisplayP3() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let data = DecodingFixtures.png(width: 16, height: 16, colorSpace: space)
        let decoded = try ImageDecoders.Default().decode(data).image
        #expect(decoded.cgImage?.colorSpace?.name == CGColorSpace.displayP3)
        let decompressed = ImageDecompression.decompress(image: decoded)
        let bitmap = try #require(decompressed.cgImage)
        #expect(bitmap !== decoded.cgImage)
        #expect(bitmap.colorSpace?.name == CGColorSpace.displayP3)
        #expect(bitmap.bitsPerComponent == 8)

        let frame = DecodingFixtures.frame(index: 2, width: 8, height: 8, colorSpace: space)
        #expect(Bitmap.redraw(frame)?.colorSpace?.name == CGColorSpace.displayP3)
    }

    @Test("손상 데이터 변이 200회 x 픽스처 8종에서 크래시 없음")
    func corruptDataMutationFuzz() {
        let frameCache = AnimatedFrameCache(costLimit: 4 * 1024 * 1024)
        let registry = ImageDecoderRegistry()
        registry.clear()
        registry.register { ImageDecoders.Default(context: $0) }
        registry.register { ImageDecoders.Animated(context: $0, frameCache: frameCache) }
        let fixtures: [(String, Data)] = [
            ("jpeg", DecodingFixtures.jpeg(width: 64, height: 48, orientation: .right)),
            ("png", DecodingFixtures.png(width: 32, height: 32, opaque: false)),
            ("gif", DecodingFixtures.gif(frameCount: 6)),
            ("apng", DecodingFixtures.apng(frameCount: 4)),
            ("webp", DecodingFixtures.webp(frameCount: 4)),
            ("webp-static", DecodingFixtures.staticWebP()),
            ("ico", DecodingFixtures.ico(sizes: [16, 32])),
            ("tiff", DecodingFixtures.tiff(pageCount: 2)),
        ]
        let limits = ImageDecodingLimits(maximumPixelCount: 4_000_000)
        var generator = SeededGenerator(seed: 0x5009_1A6E)
        var decoded = 0
        var rejected = 0
        var animatedFrames = 0
        for (_, original) in fixtures {
            for iteration in 0..<200 {
                let mutated = Self.mutate(original, using: &generator)
                var request = ImageRequest(url: Fixtures.url)
                switch iteration % 3 {
                case 0: request.thumbnail = .init(maxPixelSize: 16)
                case 1: request.thumbnail = .init(maximumPixelCount: 256)
                default: break
                }
                let context = DecodingFixtures.context(for: mutated, request: request, limits: limits)
                guard let decoder = registry.decoder(for: context), let content = try? decoder.decode(mutated) else {
                    rejected += 1
                    continue
                }
                decoded += 1
                if let source = content.animatedImageSource {
                    for index in 0..<source.frameCount + 2 {
                        if source.decodeFrame(at: index) != nil {
                            animatedFrames += 1
                        }
                    }
                }
                _ = ImageDecompression.decompress(image: content.image)
            }
        }
        #expect(decoded + rejected == fixtures.count * 200)
        #expect(decoded > 0)
        #expect(rejected > 0)
        print("BENCH|decoding_fuzz|inputs=\(fixtures.count * 200)|decoded=\(decoded)|rejected=\(rejected)|animated_frames=\(animatedFrames)")
    }

    private static func mutate(_ data: Data, using generator: inout SeededGenerator) -> Data {
        var bytes = [UInt8](data)
        switch Int.random(in: 0..<4, using: &generator) {
        case 0:
            for _ in 0..<Int.random(in: 1...8, using: &generator) {
                let index = Int.random(in: 0..<bytes.count, using: &generator)
                bytes[index] ^= UInt8.random(in: 1...255, using: &generator)
            }
        case 1:
            bytes = Array(bytes.prefix(Int.random(in: 0..<bytes.count, using: &generator)))
        case 2:
            let start = Int.random(in: 0..<bytes.count, using: &generator)
            let end = min(bytes.count, start + Int.random(in: 1...32, using: &generator))
            for index in start..<end {
                bytes[index] = UInt8.random(in: 0...255, using: &generator)
            }
        default:
            let index = Int.random(in: 0...bytes.count, using: &generator)
            let garbage = (0..<Int.random(in: 1...64, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            bytes.insert(contentsOf: garbage, at: index)
        }
        return Data(bytes)
    }
}
