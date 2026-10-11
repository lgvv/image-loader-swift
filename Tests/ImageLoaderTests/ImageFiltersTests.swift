import CoreImage
import Foundation
import ImageLoaderTesting
import Testing
import UIKit

@testable import ImageLoader

private struct Pixel: Equatable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8
}

private struct PixelMap {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        bytes = buffer
    }

    subscript(x: Int, y: Int) -> Pixel {
        let offset = (y * width + x) * 4
        return Pixel(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2], alpha: bytes[offset + 3])
    }
}

private enum Images {
    static func solid(width: Int, height: Int, color: UIColor, opaque: Bool = true, scale: CGFloat = 1, orientation: UIImage.Orientation = .up) -> UIImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue
        )!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return UIImage(cgImage: context.makeImage()!, scale: scale, orientation: orientation)
    }

    static func halves(width: Int, height: Int) -> UIImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return UIImage(cgImage: context.makeImage()!, scale: 2, orientation: .up)
    }
}

private func processingContext(for image: UIImage) -> ImageFilterContext {
    let request = ImageRequest(url: Fixtures.url)
    return ImageFilterContext(request: request, response: ImageResponse(content: ImageContent(image: image), request: request), isCompleted: true)
}

@Suite("ImageFilters 식별자")
struct ImageProcessorIdentifierTests {
    @Test("Resize 식별자는 라이브러리 접두어와 정수 픽셀 크기를 씀")
    func resizeIdentifierUsesLibraryPrefix() {
        let resize = ImageFilters.Resize(size: CGSize(width: 100, height: 50.4), unit: .pixels)
        #expect(resize.identifier == "imageloader/resize?s=100x50,cm=aspectFill,crop=false,upscale=false")
        #expect(
            ImageFilters.Resize(size: CGSize(width: 100, height: 50), unit: .pixels, contentMode: .aspectFit, crop: true, upscale: true).identifier
                == "imageloader/resize?s=100x50,cm=aspectFit,crop=true,upscale=true")
    }

    @Test("Circle, RoundedCorners, GaussianBlur, CoreImageFilter 식별자는 imageloader/ 접두어와 고정 쿼리 형식을 씀")
    func identifiersUseLibraryPrefix() {
        let border = ImageFilterOptions.Border(color: .red, width: 2, unit: .pixels)
        #expect(ImageFilters.Circle().identifier == "imageloader/circle")
        #expect(ImageFilters.Circle(border: border).identifier == "imageloader/circle?border=Border(color: #FF0000, width: 2.0 pixels)")
        #expect(ImageFilters.RoundedCorners(radius: 16, unit: .pixels).identifier == "imageloader/rounded_corners?radius=16.0")
        #expect(
            ImageFilters.RoundedCorners(radius: 16, unit: .pixels, border: border).identifier
                == "imageloader/rounded_corners?radius=16.0,border=Border(color: #FF0000, width: 2.0 pixels)")
        #expect(ImageFilters.GaussianBlur().identifier == "imageloader/gaussian_blur?radius=8")
        #expect(ImageFilters.GaussianBlur(radius: 3).identifier == "imageloader/gaussian_blur?radius=3")
        #expect(ImageFilters.GaussianBlur(radius: -4).identifier == "imageloader/gaussian_blur?radius=0")
        #expect(ImageFilters.CoreImageFilter(name: "CISepiaTone").identifier == "imageloader/core_image?name=CISepiaTone")
        #expect(ImageFilters.CoreImageFilter(name: "CISepiaTone", parameters: [kCIInputIntensityKey: 0.5], identifier: "sepia-half").identifier == "sepia-half")
        #expect(ImageFilters.CoreImageFilter(CIFilter(name: "CISepiaTone")!, identifier: "custom-sepia").identifier == "custom-sepia")
    }

    @Test("points 단위는 생성 시점의 화면 배율로 픽셀로 바꿔 식별자에 넣음")
    func pointsAreConvertedToPixels() {
        let scale = Screen.scale
        let processor = ImageFilters.RoundedCorners(radius: 8)
        #expect(processor.identifier == "imageloader/rounded_corners?radius=\(8 * scale)")
        #expect(processor.description == "RoundedCorners(radius: \(8 * scale) pixels, border: nil)")
        let border = ImageFilterOptions.Border(color: .blue)
        #expect(border.width == Screen.scale)
    }

    @Test("Border.description은 불투명이면 #RRGGBB, 반투명이면 #RRGGBBAA, sRGB 성분이 없으면 색 설명을 씀")
    func borderDescriptionUsesHexOrColorDescription() {
        #expect(ImageFilterOptions.Border(color: .red, width: 1, unit: .pixels).description == "Border(color: #FF0000, width: 1.0 pixels)")
        #expect(
            ImageFilterOptions.Border(color: UIColor(red: 1, green: 0, blue: 0, alpha: 0.5), width: 1, unit: .pixels).description
                == "Border(color: #FF000080, width: 1.0 pixels)")
        #expect(ImageFilterOptions.Border(color: .white, width: 3, unit: .pixels).description == "Border(color: #FFFFFF, width: 3.0 pixels)")
        let pattern = UIColor(patternImage: Images.solid(width: 2, height: 2, color: .green))
        let description = ImageFilterOptions.Border(color: pattern, width: 1, unit: .pixels).description
        #expect(description == "Border(color: \(String(describing: pattern)), width: 1.0 pixels)")
        #expect(!description.contains("#"))
    }

    @Test("Hashable 프로세서는 값 자체가, CoreImageFilter는 식별자 문자열이 hashableIdentifier임")
    func hashableIdentifiers() {
        let border = ImageFilterOptions.Border(color: .red, width: 2, unit: .pixels)
        #expect(ImageFilters.Circle().hashableIdentifier == AnyHashable(ImageFilters.Circle()))
        #expect(ImageFilters.Circle(border: border).hashableIdentifier == ImageFilters.Circle(border: border).hashableIdentifier)
        #expect(ImageFilters.Circle(border: border).hashableIdentifier != ImageFilters.Circle().hashableIdentifier)
        #expect(ImageFilters.RoundedCorners(radius: 4, unit: .pixels).hashableIdentifier == AnyHashable(ImageFilters.RoundedCorners(radius: 4, unit: .pixels)))
        #expect(ImageFilters.RoundedCorners(radius: 4, unit: .pixels).hashableIdentifier != ImageFilters.RoundedCorners(radius: 5, unit: .pixels).hashableIdentifier)
        #expect(ImageFilters.GaussianBlur().hashableIdentifier == AnyHashable(ImageFilters.GaussianBlur(radius: 8)))
        #expect(ImageFilters.GaussianBlur(radius: -1).hashableIdentifier == ImageFilters.GaussianBlur(radius: 0).hashableIdentifier)
        let filter = ImageFilters.CoreImageFilter(name: "CISepiaTone")
        #expect(filter.hashableIdentifier == AnyHashable("imageloader/core_image?name=CISepiaTone"))
        #expect(filter.hashableIdentifier == ImageFilters.CoreImageFilter(name: "CISepiaTone").hashableIdentifier)
    }

    @Test("ImageFilter 정적 축약형이 같은 프로세서를 만듦")
    func staticShortcuts() {
        let border = ImageFilterOptions.Border(color: .red, width: 2, unit: .pixels)
        let request = ImageRequest(
            url: Fixtures.url,
            filters: [
                .circle(),
                .circle(border: border),
                .roundedCorners(radius: 4, unit: .pixels),
                .roundedCorners(radius: 4, unit: .pixels, border: border),
                .gaussianBlur(),
                .gaussianBlur(radius: 2),
                .coreImageFilter(name: "CISepiaTone"),
                .coreImageFilter(name: "CISepiaTone", parameters: [:], identifier: "a"),
                .coreImageFilter(CIFilter(name: "CISepiaTone")!, identifier: "b"),
            ])
        #expect(
            request.filters.map(\.identifier) == [
                ImageFilters.Circle().identifier,
                ImageFilters.Circle(border: border).identifier,
                ImageFilters.RoundedCorners(radius: 4, unit: .pixels).identifier,
                ImageFilters.RoundedCorners(radius: 4, unit: .pixels, border: border).identifier,
                ImageFilters.GaussianBlur(radius: 8).identifier,
                ImageFilters.GaussianBlur(radius: 2).identifier,
                ImageFilters.CoreImageFilter(name: "CISepiaTone").identifier,
                "a",
                "b",
            ])
        #expect(ImageFilters.RoundedCorners(radius: 4).identifier == ImageFilters.RoundedCorners(radius: 4, unit: .points).identifier)
    }

    @Test("description 형식 고정")
    func descriptions() {
        let border = ImageFilterOptions.Border(color: .red, width: 2, unit: .pixels)
        #expect(ImageFilters.Circle().description == "Circle(border: nil)")
        #expect(ImageFilters.Circle(border: border).description == "Circle(border: Border(color: #FF0000, width: 2.0 pixels))")
        #expect(
            ImageFilters.RoundedCorners(radius: 3, unit: .pixels, border: border).description
                == "RoundedCorners(radius: 3.0 pixels, border: Border(color: #FF0000, width: 2.0 pixels))")
        #expect(ImageFilters.GaussianBlur().description == "GaussianBlur(radius: 8)")
        #expect(ImageFilters.CoreImageFilter(name: "CISepiaTone").description == "CoreImageFilter(name: CISepiaTone, parameters: [:])")
    }
}

@Suite("ImageFilters 모양 처리")
struct ImageProcessorShapeTests {
    @Test("Circle은 가운데를 정사각형으로 잘라 원 밖을 투명하게 하고 scale과 방향을 유지함")
    func circleCropsToSquareAndClearsCorners() throws {
        let input = Images.solid(width: 30, height: 20, color: .red, scale: 2, orientation: .right)
        let output = try #require(ImageFilters.Circle().process(input))
        let cgImage = try #require(output.cgImage)
        #expect(cgImage.width == 20)
        #expect(cgImage.height == 20)
        #expect(output.scale == 2)
        #expect(output.imageOrientation == .right)
        let pixels = PixelMap(cgImage)
        #expect(pixels[0, 0].alpha == 0)
        #expect(pixels[19, 19].alpha == 0)
        #expect(pixels[10, 10] == Pixel(red: 255, green: 0, blue: 0, alpha: 255))
    }

    @Test("Circle은 정사각형 입력을 자르지 않고 원으로 그림")
    func circleKeepsSquareSize() throws {
        let output = try #require(ImageFilters.Circle().process(Images.solid(width: 16, height: 16, color: .blue)))
        let cgImage = try #require(output.cgImage)
        #expect(cgImage.width == 16)
        #expect(cgImage.height == 16)
        #expect(PixelMap(cgImage)[0, 15].alpha == 0)
    }

    @Test("RoundedCorners는 크기를 유지하고 모서리만 투명하게 하며 불투명 입력에도 알파를 둠")
    func roundedCornersClearCorners() throws {
        let input = Images.solid(width: 24, height: 16, color: .red, scale: 3, orientation: .upMirrored)
        let output = try #require(ImageFilters.RoundedCorners(radius: 6, unit: .pixels).process(input))
        let cgImage = try #require(output.cgImage)
        #expect(cgImage.width == 24)
        #expect(cgImage.height == 16)
        #expect(output.scale == 3)
        #expect(output.imageOrientation == .upMirrored)
        #expect(!Bitmap.isOpaque(cgImage))
        let pixels = PixelMap(cgImage)
        #expect(pixels[0, 0].alpha == 0)
        #expect(pixels[23, 0].alpha == 0)
        #expect(pixels[0, 15].alpha == 0)
        #expect(pixels[23, 15].alpha == 0)
        #expect(pixels[12, 8] == Pixel(red: 255, green: 0, blue: 0, alpha: 255))
        #expect(pixels[12, 0].alpha == 255)
    }

    @Test("테두리는 경계를 따라 테두리 색으로 그림")
    func borderIsStroked() throws {
        let border = ImageFilterOptions.Border(color: .blue, width: 4, unit: .pixels)
        let output = try #require(ImageFilters.RoundedCorners(radius: 4, unit: .pixels, border: border).process(Images.solid(width: 20, height: 20, color: .red)))
        let pixels = PixelMap(try #require(output.cgImage))
        let edge = pixels[10, 0]
        #expect(edge.blue == 255)
        #expect(edge.red == 0)
        #expect(pixels[10, 10] == Pixel(red: 255, green: 0, blue: 0, alpha: 255))
        let circle = try #require(ImageFilters.Circle(border: border).process(Images.solid(width: 20, height: 20, color: .red)))
        let circlePixels = PixelMap(try #require(circle.cgImage))
        #expect(circlePixels[10, 1].blue > 200)
        #expect(circlePixels[10, 1].red < 60)
        #expect(circlePixels[0, 0].alpha == 0)
    }
}

@Suite("ImageFilters 흐림과 Core Image")
struct ImageProcessorFilterTests {
    @Test("GaussianBlur는 선명한 경계를 중간값으로 바꾸고 크기, scale, 불투명 여부를 유지함")
    func blurSoftensSharpEdge() throws {
        let input = Images.halves(width: 32, height: 8)
        let before = PixelMap(try #require(input.cgImage))
        #expect(before[15, 4].red == 0)
        #expect(before[16, 4].red == 255)
        let output = try #require(ImageFilters.GaussianBlur(radius: 4).process(input))
        let cgImage = try #require(output.cgImage)
        #expect(cgImage.width == 32)
        #expect(cgImage.height == 8)
        #expect(output.scale == 2)
        #expect(Bitmap.isOpaque(cgImage))
        let after = PixelMap(cgImage)
        #expect(after[15, 4].red > 0)
        #expect(after[16, 4].red < 255)
        #expect(after[0, 4].red == 0)
        #expect(after[31, 4].red == 255)
    }

    @Test("GaussianBlur는 투명 입력의 알파를 유지함")
    func blurKeepsAlpha() throws {
        let input = Images.solid(width: 8, height: 8, color: UIColor(red: 0, green: 1, blue: 0, alpha: 0.5), opaque: false)
        let output = try #require(ImageFilters.GaussianBlur(radius: 2).process(input))
        let cgImage = try #require(output.cgImage)
        #expect(!Bitmap.isOpaque(cgImage))
        let alpha = PixelMap(cgImage)[4, 4].alpha
        #expect(alpha > 120 && alpha < 135)
    }

    @Test("반지름 0 이하의 GaussianBlur는 입력 이미지를 그대로 돌려줌")
    func zeroRadiusIsIdentity() throws {
        let input = Images.solid(width: 4, height: 4, color: .red)
        #expect(ImageFilters.GaussianBlur(radius: 0).process(input) === input)
        #expect(ImageFilters.GaussianBlur(radius: -2).process(input) === input)
        let empty = UIImage()
        #expect(ImageFilters.GaussianBlur(radius: 0).process(empty) === empty)
    }

    @Test("상자 커널 크기는 SVG 근사식을 따르고 늘 홀수임")
    func boxKernelSize() {
        #expect(ImageFilters.GaussianBlur.boxKernelSize(radius: 1) == 3)
        #expect(ImageFilters.GaussianBlur.boxKernelSize(radius: 4) == 9)
        #expect(ImageFilters.GaussianBlur.boxKernelSize(radius: 8) == 15)
        #expect(ImageFilters.GaussianBlur.boxKernelSize(radius: 20) == 39)
        for radius in 1...64 {
            #expect(!ImageFilters.GaussianBlur.boxKernelSize(radius: radius).isMultiple(of: 2))
        }
    }

    @Test("CISepiaTone 필터가 색을 바꾸고 크기, scale, 방향을 유지함")
    func sepiaChangesColor() throws {
        let input = Images.solid(width: 8, height: 8, color: .blue, scale: 2, orientation: .left)
        let output = try #require(ImageFilters.CoreImageFilter(name: "CISepiaTone").process(input))
        let cgImage = try #require(output.cgImage)
        #expect(cgImage.width == 8)
        #expect(cgImage.height == 8)
        #expect(output.scale == 2)
        #expect(output.imageOrientation == .left)
        let pixel = PixelMap(cgImage)[4, 4]
        #expect(pixel != Pixel(red: 0, green: 0, blue: 255, alpha: 255))
        #expect(pixel.red > pixel.blue)
    }

    @Test("CIImage로만 만든 UIImage도 처리함")
    func ciImageBackedInput() throws {
        let source = try #require(Images.solid(width: 6, height: 6, color: .blue).cgImage)
        let input = UIImage(ciImage: CIImage(cgImage: source))
        #expect(input.cgImage == nil)
        let output = try #require(ImageFilters.CoreImageFilter(name: "CISepiaTone").process(input))
        #expect(output.cgImage?.width == 6)
    }

    @Test("CIFilter를 직접 준 프로세서는 사본에 적용해 원래 필터를 바꾸지 않음")
    func customFilterIsCopied() throws {
        let filter = try #require(CIFilter(name: "CISepiaTone"))
        let processor = ImageFilters.CoreImageFilter(filter, identifier: "sepia")
        let output = try #require(processor.process(Images.solid(width: 4, height: 4, color: .blue)))
        #expect(output.cgImage != nil)
        #expect(filter.value(forKey: kCIInputImageKey) == nil)
        let applied = try ImageFilters.CoreImageFilter.apply(filter: filter, to: Images.solid(width: 4, height: 4, color: .blue))
        #expect(applied.cgImage?.width == 4)
        #expect(filter.value(forKey: kCIInputImageKey) == nil)
    }

    @Test("공유 CIContext는 한 번만 만들고 바꿔 끼울 수 있음")
    func sharedContext() {
        let original = ImageFilters.CoreImageFilter.context
        #expect(ImageFilters.CoreImageFilter.context === original)
        let replacement = CIContext(options: [.priorityRequestLow: true])
        ImageFilters.CoreImageFilter.context = replacement
        #expect(ImageFilters.CoreImageFilter.context === replacement)
        ImageFilters.CoreImageFilter.context = original
        #expect(ImageFilters.CoreImageFilter.context === original)
    }

    @Test("없는 필터 이름은 process(_:)에서 nil, 컨테이너 처리에서 failedToCreateFilter를 던짐")
    func invalidFilterName() throws {
        let processor = ImageFilters.CoreImageFilter(name: "NoSuchFilter", parameters: ["k": 1], identifier: "missing")
        let image = Images.solid(width: 4, height: 4, color: .red)
        #expect(processor.process(image) == nil)
        do {
            _ = try processor.process(ImageContent(image: image), context: processingContext(for: image))
            Issue.record("에러를 던지지 않았습니다")
        } catch let ImageFilters.CoreImageFilter.Error.failedToCreateFilter(name, parameters) {
            #expect(name == "NoSuchFilter")
            #expect(parameters["k"] as? Int == 1)
        } catch {
            Issue.record("다른 에러: \(error)")
        }
    }

    @Test("CGImage가 없는 UIImage는 모양과 흐림 프로세서에서 nil, 컨테이너 처리에서 ImageFilterError.unknown, Core Image에서 inputImageIsEmpty")
    func imageWithoutBitmap() throws {
        let empty = UIImage()
        #expect(ImageFilters.Circle().process(empty) == nil)
        #expect(ImageFilters.RoundedCorners(radius: 2, unit: .pixels).process(empty) == nil)
        #expect(ImageFilters.GaussianBlur().process(empty) == nil)
        #expect(ImageFilters.CoreImageFilter(name: "CISepiaTone").process(empty) == nil)
        let context = processingContext(for: empty)
        #expect(throws: ImageFilterError.self) {
            try ImageFilters.Circle().process(ImageContent(image: empty), context: context)
        }
        #expect(throws: ImageFilterError.self) {
            try ImageFilters.GaussianBlur().process(ImageContent(image: empty), context: context)
        }
        do {
            _ = try ImageFilters.CoreImageFilter(name: "CISepiaTone").process(ImageContent(image: empty), context: context)
            Issue.record("에러를 던지지 않았습니다")
        } catch ImageFilters.CoreImageFilter.Error.inputImageIsEmpty {
        } catch {
            Issue.record("다른 에러: \(error)")
        }
    }

    @Test("CoreImageFilter.Error의 description에 원인이 드러남")
    func errorDescriptions() {
        let error = ImageFilters.CoreImageFilter.Error.failedToCreateFilter(name: "NoSuchFilter", parameters: [:])
        #expect(error.description.contains("NoSuchFilter"))
    }
}

@Suite("ImageFilters 파이프라인 연동")
struct ImageProcessorSessionTests {
    @Test("Circle 결과를 메모리 캐시와 프로세서 식별자가 붙은 디스크 키에 저장하고 다시 읽음")
    func processedImageIsCachedUnderProcessorKey() async throws {
        let diskCache = InMemoryDiskCache()
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.png(width: 12, height: 8, color: .red)))
        let session = makeSession(loader: loader) {
            $0.diskCache = diskCache
            $0.diskCachePolicy = .storeEncodedImages
        }
        let request = ImageRequest(url: Fixtures.url, filters: [.circle()])
        let image = try await session.image(for: request)
        let cgImage = try #require(image.cgImage)
        #expect(cgImage.width == 8)
        #expect(PixelMap(cgImage)[0, 0].alpha == 0)
        #expect(session.cache[request] != nil)
        #expect(session.cache[ImageRequest(url: Fixtures.url)] == nil)
        let key = session.cache.makeDiskCacheKey(for: request)
        #expect(key == "https://example.com/image.png\u{1F}\u{1F}imageloader/circle")
        #expect(await waitUntil { diskCache.storage.value[key] != nil })
        session.cache.removeAll(caches: .memory)
        let response = try await session.imageTask(with: request).response
        #expect(response.cacheType == .disk)
        #expect(loader.counts.started == 1)
        #expect(PixelMap(try #require(response.image.cgImage))[0, 0].alpha == 0)
    }

    @Test("프로세서가 다르면 메모리 캐시 키가 다르고, 같은 프로세서를 새로 만들어도 같은 키를 씀")
    func memoryKeysFollowHashableIdentifier() async throws {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.png(width: 8, height: 8, color: .blue)))
        let session = makeSession(loader: loader)
        let blurred = ImageRequest(url: Fixtures.url, filters: [.gaussianBlur(radius: 2)])
        _ = try await session.image(for: blurred)
        #expect(session.cache[ImageRequest(url: Fixtures.url, filters: [ImageFilters.GaussianBlur(radius: 2)])] != nil)
        #expect(session.cache[ImageRequest(url: Fixtures.url, filters: [.gaussianBlur(radius: 3)])] == nil)
        #expect(session.cache[ImageRequest(url: Fixtures.url, filters: [.roundedCorners(radius: 2, unit: .pixels)])] == nil)
        let sepia = ImageRequest(url: Fixtures.url, filters: [.coreImageFilter(name: "CISepiaTone")])
        let output = try await session.image(for: sepia)
        #expect(output.cgImage?.width == 8)
        #expect(session.cache[ImageRequest(url: Fixtures.url, filters: [.coreImageFilter(name: "CISepiaTone")])] != nil)
    }

    @Test("없는 필터 이름은 processingFailed로 끝나고 원인으로 CoreImageFilter.Error를 담음")
    func invalidFilterFailsSession() async throws {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader)
        let request = ImageRequest(url: Fixtures.url, filters: [.coreImageFilter(name: "NoSuchFilter")])
        let outcome = await result(of: session.imageTask(with: request))
        guard case .failure(.processingFailed(let processor, _, let error)) = outcome else {
            Issue.record("processingFailed가 아닙니다: \(outcome)")
            return
        }
        #expect(processor.identifier == "imageloader/core_image?name=NoSuchFilter")
        guard case .failedToCreateFilter(let name, _) = error as? ImageFilters.CoreImageFilter.Error else {
            Issue.record("원인이 failedToCreateFilter가 아닙니다: \(error)")
            return
        }
        #expect(name == "NoSuchFilter")
        #expect(session.cache[request] == nil)
    }
}
