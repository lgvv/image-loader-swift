import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

extension ImageRequest {
    /// 원본을 모두 디코딩하지 않고 처음부터 작은 크기로 디코딩하는 설정입니다.
    ///
    /// 4000×3000 사진을 디코딩하면 약 46MB를 쓰지만, 300픽셀 썸네일로 디코딩하면 약 0.3MB만 씁니다.
    /// 목록에 큰 사진을 띄울 때 ``ImageRequest/thumbnail``에 넣어 주세요.
    ///
    /// ```swift
    /// var request = ImageRequest(url: url)
    /// request.thumbnail = .init(size: CGSize(width: 120, height: 120))
    /// ```
    public struct ThumbnailOptions: Hashable, Sendable {
        enum TargetSize: Hashable, Sendable {
            case fixed(Float)
            case flexible(width: Int, height: Int, contentMode: ImageFilterOptions.ContentMode)
            case maximumPixelCount(Int)
        }

        enum Decision: Equatable, Sendable {
            case thumbnail(maxPixelSize: CGFloat)
            case original
        }

        let targetSize: TargetSize

        /// 파일에 썸네일이 없으면 원본에서 만들지 정합니다. 기본값은 `true`입니다.
        public var createThumbnailFromImageIfAbsent = true
        /// 파일에 썸네일이 있어도 원본에서 새로 만들지 정합니다. 기본값은 `true`입니다.
        ///
        /// 파일에 든 썸네일은 크기가 정해져 있어 원하는 크기보다 작을 수 있습니다. 끄면 파일의 썸네일을 그대로 씁니다.
        public var createThumbnailFromImageAlways = true
        /// EXIF 방향 정보에 맞게 회전한 썸네일을 만들지 정합니다. 기본값은 `true`입니다.
        ///
        /// 끄면 회전하지 않은 픽셀을 그대로 두고 `UIImage.imageOrientation`으로 방향을 표시합니다.
        public var createThumbnailWithTransform = true
        /// 썸네일을 만들 때 바로 디코딩할지 정합니다. 기본값은 `true`입니다. 끄면 처음 그릴 때 디코딩합니다.
        public var shouldCacheImmediately = true

        /// 긴 변을 정한 픽셀 수에 맞춥니다.
        ///
        /// - Parameter maxPixelSize: 썸네일 긴 변의 최대 픽셀 수입니다.
        public init(maxPixelSize: Float) {
            targetSize = .fixed(maxPixelSize)
        }

        /// 보여 줄 영역의 크기에 맞춥니다.
        ///
        /// 원본의 가로세로 비율을 지키면서 `contentMode`에 맞게 줄이고, 원본보다 크게 늘리지는 않습니다.
        /// EXIF 방향 정보로 원본이 회전돼 있으면 가로와 세로를 바꿔서 계산합니다.
        ///
        /// - Parameters:
        ///   - size: 보여 줄 영역의 크기입니다.
        ///   - unit: `.points`면 화면 배율을 곱해 픽셀로 바꿉니다.
        ///   - contentMode: `.aspectFill`이면 영역을 가득 채우는 크기로, `.aspectFit`이면 영역 안에 다 들어가는 크기로 줄입니다.
        public init(size: CGSize, unit: ImageFilterOptions.Unit = .points, contentMode: ImageFilterOptions.ContentMode = .aspectFill) {
            let pixelSize = unit == .points ? size.scaled(by: Screen.scale) : size
            targetSize = .flexible(width: Self.pixelDimension(pixelSize.width), height: Self.pixelDimension(pixelSize.height), contentMode: contentMode)
        }

        private static func pixelDimension(_ value: CGFloat) -> Int {
            guard !value.isNaN else {
                return 0
            }
            return Int(min(max(value.rounded(), 0), CGFloat(1 << 30)))
        }

        /// 전체 픽셀 수가 정한 값을 넘을 때만 줄입니다.
        ///
        /// 넘지 않으면 원본 그대로 디코딩합니다. JPEG은 디코딩이 빠른 2분의 1, 4분의 1, 8분의 1 크기 중 하나로 줄입니다.
        ///
        /// - Parameter maximumPixelCount: 허용할 최대 픽셀 수입니다. 1보다 작으면 1로 봅니다.
        public init(maximumPixelCount: Int) {
            targetSize = .maximumPixelCount(max(1, maximumPixelCount))
        }

        /// 디코딩한 크기가 정한 바이트 수를 넘는 이미지만 줄이는 설정입니다.
        ///
        /// 픽셀 하나에 4바이트를 쓴다고 보고 ``init(maximumPixelCount:)``로 만듭니다. 기본값 60MB는 약 1,570만 픽셀입니다.
        ///
        /// - Parameter limitBytes: 디코딩한 이미지 하나가 쓸 수 있는 최대 바이트 수입니다.
        public static func scaleDownLargeImages(limitBytes: Int = 60 * 1024 * 1024) -> ThumbnailOptions {
            ThumbnailOptions(maximumPixelCount: limitBytes / 4)
        }

        /// 크기를 맞추는 방식입니다. ``init(size:unit:contentMode:)``로 만들지 않았으면 `.aspectFit`입니다.
        public var contentMode: ImageFilterOptions.ContentMode {
            if case .flexible(_, _, let contentMode) = targetSize {
                return contentMode
            }
            return .aspectFit
        }

        var identifier: String {
            let options = [createThumbnailFromImageIfAbsent, createThumbnailFromImageAlways, createThumbnailWithTransform, shouldCacheImmediately]
                .map { $0 ? "1" : "0" }
                .joined()
            switch targetSize {
            case .fixed(let size):
                return "imageloader/thumbnail?maxPixelSize=\(size),options=\(options)"
            case .flexible(let width, let height, let contentMode):
                return "imageloader/thumbnail?width=\(width),height=\(height),contentMode=\(contentMode),options=\(options)"
            case .maximumPixelCount(let count):
                return "imageloader/thumbnail?maxPixelCount=\(count),options=\(options)"
            }
        }

        /// 데이터에서 이 설정대로 썸네일을 만듭니다. 호출한 스레드에서 바로 디코딩하므로 메인 스레드에서는 부르지 않는 것이 좋습니다.
        ///
        /// - Parameter data: 이미지 데이터입니다.
        /// - Returns: 데이터가 이미지가 아니면 `nil`입니다.
        public func makeThumbnail(with data: Data) -> UIImage? {
            guard let source = CGImageSourceCreateWithData(data as CFData, ImageHeader.sourceOptions) else {
                return nil
            }
            switch decision(for: ImageHeader.properties(of: source, at: 0), sourceType: CGImageSourceGetType(source) as String?) {
            case .thumbnail(let maxPixelSize):
                return makeImage(source: source, index: 0, maxPixelSize: maxPixelSize, scale: 1)
            case .original:
                return UIImage(data: data)
            }
        }

        func decision(for properties: [CFString: Any]?, sourceType: String? = nil) -> Decision {
            let pixelSize = properties.flatMap(ImageHeader.pixelSize(from:))
            switch targetSize {
            case .fixed(let size):
                return .thumbnail(maxPixelSize: CGFloat(size))
            case .flexible(let targetWidth, let targetHeight, let contentMode):
                guard let properties, let pixelSize else {
                    return .thumbnail(maxPixelSize: CGFloat(max(targetWidth, targetHeight)))
                }
                let target =
                    ImageHeader.swapsDimensions(ImageHeader.orientation(from: properties))
                    ? CGSize(width: targetHeight, height: targetWidth)
                    : CGSize(width: targetWidth, height: targetHeight)
                let width = CGFloat(pixelSize.width)
                let height = CGFloat(pixelSize.height)
                let scaleX = target.width / width
                let scaleY = target.height / height
                let scale = min(1, contentMode == .aspectFill ? max(scaleX, scaleY) : min(scaleX, scaleY))
                let scaledWidth = (width * scale).rounded()
                let scaledHeight = (height * scale).rounded()
                return .thumbnail(maxPixelSize: max(1, scaledWidth, scaledHeight))
            case .maximumPixelCount(let limit):
                guard let pixelSize, pixelSize.pixelCount > limit else {
                    return .original
                }
                let ratio = (Double(limit) / Double(pixelSize.pixelCount)).squareRoot()
                let scale = sourceType == UTType.jpeg.identifier ? Self.scaledDecodingFactor(atMost: ratio) : ratio
                let longSide = (Double(pixelSize.longSide) * scale).rounded(.down)
                return .thumbnail(maxPixelSize: CGFloat(max(1, longSide)))
            }
        }

        static func scaledDecodingFactor(atMost ratio: Double) -> Double {
            [0.5, 0.25, 0.125].first { $0 <= ratio } ?? ratio
        }

        func makeThumbnailImage(source: CGImageSource, index: Int, maxPixelSize: CGFloat) -> CGImage? {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: createThumbnailFromImageIfAbsent,
                kCGImageSourceCreateThumbnailFromImageAlways: createThumbnailFromImageAlways,
                kCGImageSourceCreateThumbnailWithTransform: createThumbnailWithTransform,
                kCGImageSourceShouldCacheImmediately: shouldCacheImmediately,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
        }

        func makeImage(source: CGImageSource, index: Int, maxPixelSize: CGFloat, scale: CGFloat) -> UIImage? {
            guard let image = makeThumbnailImage(source: source, index: index, maxPixelSize: maxPixelSize) else {
                return nil
            }
            guard !createThumbnailWithTransform, let properties = ImageHeader.properties(of: source, at: index) else {
                return UIImage(cgImage: image, scale: scale, orientation: .up)
            }
            let orientation = ImageHeader.imageOrientation(ImageHeader.orientation(from: properties))
            return UIImage(cgImage: image, scale: scale, orientation: orientation)
        }
    }
}
