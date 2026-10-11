import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// 디코딩할 수 있는 최대 픽셀 수입니다.
///
/// 디코딩한 이미지는 픽셀 하나에 4바이트를 쓰므로, 8000×8000 이미지 하나가 약 244MB를 씁니다.
/// 디코딩하기 전에 헤더에서 크기를 읽어 한도를 넘으면 디코딩하지 않습니다.
public struct ImageDecodingLimits: Hashable, Sendable {
    /// 디코딩한 결과의 최대 픽셀 수입니다. 썸네일로 줄여 디코딩하면 줄인 크기로 셉니다. `nil`이면 제한하지 않습니다.
    public var maximumPixelCount: Int?
    /// 원본 파일의 최대 픽셀 수입니다. 썸네일로 줄여도 원본이 이 값을 넘으면 디코딩하지 않습니다. `nil`이면 제한하지 않습니다.
    public var maximumSourcePixelCount: Int?

    /// 한도를 정해 만듭니다.
    ///
    /// - Parameters:
    ///   - maximumPixelCount: 디코딩한 결과의 최대 픽셀 수입니다.
    ///   - maximumSourcePixelCount: 원본 파일의 최대 픽셀 수입니다.
    public init(
        maximumPixelCount: Int? = ImageDecodingLimits.defaultMaximumPixelCount,
        maximumSourcePixelCount: Int? = ImageDecodingLimits.defaultMaximumSourcePixelCount
    ) {
        self.maximumPixelCount = maximumPixelCount
        self.maximumSourcePixelCount = maximumSourcePixelCount
    }

    /// 기기 메모리에 맞춘 기본 한도입니다.
    ///
    /// 기기 메모리의 32분의 1을 비트맵 바이트로 보고 픽셀 수로 바꾼 값이고, 4096×4096부터 8192×8192 사이로 맞춥니다.
    /// 메모리가 4GB인 기기는 약 3,355만 픽셀입니다.
    public static let defaultMaximumPixelCount = memoryScaledPixelCount(physicalMemory: ProcessInfo.processInfo.physicalMemory)

    /// 원본 파일의 기본 한도입니다. 16384×16384, 약 2억 6,800만 픽셀입니다.
    public static let defaultMaximumSourcePixelCount = 16_384 * 16_384

    /// 두 기본 한도를 쓰는 값입니다.
    public static let `default` = ImageDecodingLimits()

    /// 제한하지 않는 값입니다.
    public static let unlimited = ImageDecodingLimits(maximumPixelCount: nil, maximumSourcePixelCount: nil)

    static let minimumDefaultPixelCount = 4_096 * 4_096
    static let maximumDefaultPixelCount = 8_192 * 8_192

    static func memoryScaledPixelCount(physicalMemory: UInt64) -> Int {
        let bitmapBytes = physicalMemory / 32
        let pixelCount = Int(clamping: bitmapBytes / 4)
        return min(max(pixelCount, minimumDefaultPixelCount), maximumDefaultPixelCount)
    }

    /// 한도를 넘었을 때의 오류입니다. ``ImageSession/Error/decodingFailed(decoder:context:error:)``의 `error`로 전달합니다.
    public enum Error: Swift.Error, CustomStringConvertible, Sendable, Equatable {
        /// 픽셀 수가 `limit`를 넘었습니다. `pixelCount`는 이미지의 픽셀 수입니다.
        case pixelCountExceeded(pixelCount: Int, limit: Int)

        public var description: String {
            switch self {
            case .pixelCountExceeded(let pixelCount, let limit):
                "Image pixel count \(pixelCount) exceeds the decoding limit \(limit)"
            }
        }
    }

    var isEnabled: Bool {
        maximumPixelCount != nil || maximumSourcePixelCount != nil
    }

    /// 데이터의 헤더를 읽어 한도를 넘는지 확인합니다. 직접 만든 디코더에서 디코딩 전에 불러 주세요.
    ///
    /// 헤더에서 크기를 읽지 못하면 확인하지 않고 넘어갑니다.
    ///
    /// - Throws: 픽셀 수가 한도를 넘으면 ``Error/pixelCountExceeded(pixelCount:limit:)``를 일으킵니다.
    public func validate(_ data: Data) throws(ImageDecodingLimits.Error) {
        guard isEnabled, let size = ImageHeaderScanner.pixelSize(of: data) ?? Self.imageIOPixelSize(of: data) else {
            return
        }
        try validate(sourceSize: size, decodedPixelCount: size.pixelCount)
    }

    func validate(_ properties: [CFString: Any]?, decision: ImageRequest.ThumbnailOptions.Decision) throws(ImageDecodingLimits.Error) {
        guard isEnabled, let size = properties.flatMap(ImageHeader.pixelSize(from:)) else {
            return
        }
        try validate(sourceSize: size, decodedPixelCount: decision.decodedPixelCount(for: size))
    }

    func validate(sourceSize: ImageHeader.PixelSize, decodedPixelCount: Int) throws(ImageDecodingLimits.Error) {
        let sourcePixelCount = sourceSize.pixelCount
        if let limit = maximumSourcePixelCount, sourcePixelCount > limit {
            throw .pixelCountExceeded(pixelCount: sourcePixelCount, limit: limit)
        }
        if let limit = maximumPixelCount, decodedPixelCount > limit {
            throw .pixelCountExceeded(pixelCount: decodedPixelCount, limit: limit)
        }
    }

    private static func imageIOPixelSize(of data: Data) -> ImageHeader.PixelSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, ImageHeader.sourceOptions) else {
            return nil
        }
        let sizes = Set([0, CGImageSourceGetPrimaryImageIndex(source)]).compactMap {
            ImageHeader.properties(of: source, at: $0).flatMap(ImageHeader.pixelSize(from:))
        }
        return sizes.max { $0.pixelCount < $1.pixelCount }
    }
}

extension ImageRequest.ThumbnailOptions.Decision {
    func decodedPixelCount(for size: ImageHeader.PixelSize) -> Int {
        guard case .thumbnail(let maxPixelSize) = self, maxPixelSize >= 1, Double(maxPixelSize) < Double(size.longSide) else {
            return size.pixelCount
        }
        let ratio = Double(maxPixelSize) / Double(size.longSide)
        let estimate = (Double(size.pixelCount) * ratio * ratio).rounded(.up)
        return estimate < Double(Int.max) ? Int(estimate) : Int.max
    }
}

enum ImageHeader {
    struct PixelSize: Hashable {
        let width: Int
        let height: Int

        var pixelCount: Int {
            let result = width.multipliedReportingOverflow(by: height)
            return result.overflow ? Int.max : result.partialValue
        }

        var longSide: Int {
            max(width, height)
        }
    }

    static var sourceOptions: CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }

    static func properties(of source: CGImageSource, at index: Int) -> [CFString: Any]? {
        guard index >= 0, index < CGImageSourceGetCount(source) else {
            return nil
        }
        return CGImageSourceCopyPropertiesAtIndex(source, index, sourceOptions) as? [CFString: Any]
    }

    static func pixelSize(from properties: [CFString: Any]) -> PixelSize? {
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0, height > 0
        else {
            return nil
        }
        return PixelSize(width: width, height: height)
    }

    static func orientation(from properties: [CFString: Any]) -> CGImagePropertyOrientation {
        (properties[kCGImagePropertyOrientation] as? NSNumber)
            .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
    }

    static func swapsDimensions(_ orientation: CGImagePropertyOrientation) -> Bool {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            true
        default:
            false
        }
    }

    static func imageOrientation(_ orientation: CGImagePropertyOrientation) -> UIImage.Orientation {
        switch orientation {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        }
    }
}
