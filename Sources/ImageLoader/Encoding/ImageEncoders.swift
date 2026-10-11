import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// 라이브러리가 제공하는 인코더 모음입니다.
public enum ImageEncoders {}

extension ImageEncoders {
    /// 투명도에 따라 형식을 고르는 기본 인코더입니다.
    ///
    /// 투명한 픽셀이 없으면 JPEG으로, 있으면 PNG로 인코딩합니다. ``isHEIFPreferred``를 켜면 JPEG 대신 HEIF를 씁니다.
    public struct Default: ImageEncoding, Sendable {
        /// 손실 압축 품질입니다. 0부터 1 사이이고, 기본값은 0.8입니다. PNG에는 쓰지 않습니다.
        public var compressionQuality: Float
        /// 투명한 픽셀이 없는 이미지를 HEIF로 인코딩할지 정합니다. 기본값은 `false`입니다.
        ///
        /// HEIF는 같은 품질에서 JPEG보다 파일이 작습니다. 기기가 HEIF 인코딩을 지원하지 않으면 JPEG을 씁니다.
        public var isHEIFPreferred = false

        /// 압축 품질을 정해 인코더를 만듭니다.
        public init(compressionQuality: Float = 0.8) {
            self.compressionQuality = compressionQuality
        }

        /// 이미지의 투명도를 보고 형식을 골라 인코딩합니다. `cgImage`가 없는 이미지면 `nil`입니다.
        public func encode(_ image: UIImage) -> Data? {
            guard let cgImage = image.cgImage else { return nil }
            let type: AssetType
            if Bitmap.isOpaque(cgImage) {
                type = isHEIFPreferred && ImageEncoders.ImageIO.isSupported(type: .heic) ? .heic : .jpeg
            } else {
                type = .png
            }
            return ImageEncoders.ImageIO(type: type, compressionRatio: compressionQuality).encode(image)
        }
    }

    /// ImageIO로 정한 형식으로 인코딩하는 인코더입니다.
    public struct ImageIO: ImageEncoding, Sendable {
        /// 인코딩할 형식입니다.
        public let type: AssetType
        /// 손실 압축 품질입니다. 0부터 1 사이이고, 손실 압축을 쓰지 않는 형식에서는 무시합니다.
        public let compressionRatio: Float

        /// 형식과 압축 품질을 정해 인코더를 만듭니다.
        public init(type: AssetType, compressionRatio: Float = 0.8) {
            self.type = type
            self.compressionRatio = compressionRatio
        }

        private static let supportedTypes = LockIsolated<[AssetType: Bool]>([:])

        /// 이 기기에서 형식을 인코딩할 수 있는지 알려 줍니다. 처음 확인한 결과를 기억해 두고 다시 씁니다.
        public static func isSupported(type: AssetType) -> Bool {
            if let cached = supportedTypes.withLock({ $0[type] }) {
                return cached
            }
            let identifiers = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
            let isSupported = identifiers.contains(type.rawValue)
            supportedTypes.withLock { $0[type] = isSupported }
            return isSupported
        }

        /// 이미지를 ``type`` 형식으로 인코딩합니다. 이미지 방향은 메타데이터로 함께 저장합니다. 인코딩하지 못하면 `nil`입니다.
        public func encode(_ image: UIImage) -> Data? {
            guard let cgImage = image.cgImage else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.rawValue as CFString, 1, nil) else {
                return nil
            }
            let properties: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: compressionRatio,
                kCGImagePropertyOrientation: CGImagePropertyOrientation(image.imageOrientation).rawValue,
            ]
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        }
    }
}

extension ImageEncoding where Self == ImageEncoders.Default {
    /// ``ImageEncoders/Default``를 만듭니다.
    public static func `default`(compressionQuality: Float = 0.8) -> ImageEncoders.Default {
        ImageEncoders.Default(compressionQuality: compressionQuality)
    }
}

extension ImageEncoding where Self == ImageEncoders.ImageIO {
    /// ``ImageEncoders/ImageIO``를 만듭니다.
    public static func imageIO(type: AssetType, compressionRatio: Float = 0.8) -> ImageEncoders.ImageIO {
        ImageEncoders.ImageIO(type: type, compressionRatio: compressionRatio)
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
