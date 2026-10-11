import CoreGraphics
import Foundation
import ImageIO
import UIKit

extension ImageDecoders {
    /// 애니메이션 GIF, APNG, 애니메이션 WebP를 디코딩하는 디코더입니다.
    ///
    /// 첫 프레임만 바로 디코딩하고, 나머지 프레임은 재생할 때 필요한 만큼 디코딩합니다.
    /// 프레임은 ``ImageContent/animatedImageSource``로 꺼내고, ``AnimatedFrameCache``에 보관합니다.
    public final class Animated: ImageDecoding, Sendable {
        private let scale: CGFloat
        private let thumbnail: ImageRequest.ThumbnailOptions?
        private let limits: ImageDecodingLimits
        private let frameCache: AnimatedFrameCache

        /// 데이터가 프레임이 두 개 이상인 GIF, PNG, WebP일 때만 디코더를 만듭니다. 정지 이미지면 `nil`을 돌려줍니다.
        public convenience init?(context: ImageDecodingContext) {
            self.init(context: context, frameCache: .shared)
        }

        init?(context: ImageDecodingContext, frameCache: AnimatedFrameCache) {
            guard AnimatedImageProbe.isAnimatedContainer(context.data) else {
                return nil
            }
            scale = CGFloat(context.request.scale)
            thumbnail = context.request.thumbnail
            limits = context.decodingLimits
            self.frameCache = frameCache
        }

        /// 항상 `true`입니다.
        public var isAsynchronous: Bool {
            true
        }

        /// 첫 프레임을 디코딩하고 나머지 프레임을 꺼낼 수 있는 ``AnimatedImageSource``를 함께 담아 돌려줍니다.
        ///
        /// 애니메이션으로 읽지 못하면 ``Default``로 정지 이미지를 디코딩합니다. 픽셀 수가 ``ImageDecodingLimits``를 넘으면 오류를 일으킵니다.
        public func decode(_ data: Data) throws -> ImageContent {
            guard let probe = AnimatedImageProbe(data: data) else {
                return try ImageDecoders.Default(scale: scale, thumbnail: thumbnail, limits: limits).decode(data)
            }
            let properties = ImageHeader.properties(of: probe.imageSource, at: 0)
            let decision = thumbnail?.decision(for: properties) ?? .original
            try limits.validate(properties, decision: decision)
            guard let source = AnimatedImageSource(probe: probe, scale: scale, thumbnail: thumbnail, decision: decision, frameCache: frameCache) else {
                throw ImageDecodingError.unknown
            }
            let image = UIImage(cgImage: source.firstFrame, scale: scale, orientation: .up)
            return ImageContent(image: image, type: probe.type, data: data, userInfo: [.animatedImageKey: source])
        }
    }
}

struct AnimatedImageProbe {
    let data: Data
    let type: AssetType
    nonisolated(unsafe) let imageSource: CGImageSource

    init?(data: Data) {
        guard let type = Self.animatedContainerType(data),
            let imageSource = CGImageSourceCreateWithData(data as CFData, ImageHeader.sourceOptions),
            CGImageSourceGetCount(imageSource) > 1,
            let properties = ImageHeader.properties(of: imageSource, at: 0),
            AnimatedImageMetadata.hasAnimationTiming(properties, type: type)
        else {
            return nil
        }
        self.data = data
        self.type = type
        self.imageSource = imageSource
    }

    static func isAnimatedContainer(_ data: Data) -> Bool {
        animatedContainerType(data) != nil
    }

    private static func animatedContainerType(_ data: Data) -> AssetType? {
        guard let type = AssetType(data) else {
            return nil
        }
        let isAnimated = data.withUnsafeBytes { buffer -> Bool in
            let bytes = buffer.bindMemory(to: UInt8.self)
            switch type {
            case .gif:
                return ContainerScanner.gifHasAnimation(bytes)
            case .png:
                return ContainerScanner.pngHasAnimation(bytes)
            case .webp:
                return ContainerScanner.webpHasAnimation(bytes)
            default:
                return false
            }
        }
        return isAnimated ? type : nil
    }
}

enum AnimatedImageMetadata {
    static let defaultFrameDuration: TimeInterval = 0.1
    static let minimumFrameDuration: TimeInterval = 0.01

    private struct Keys {
        let dictionary: CFString
        let frameInfo: CFString
        let unclampedDelay: CFString
        let delay: CFString
        let loopCount: CFString
        let defaultLoopCount: Int
    }

    private static func keys(for type: AssetType) -> Keys? {
        switch type {
        case .gif:
            Keys(
                dictionary: kCGImagePropertyGIFDictionary,
                frameInfo: kCGImagePropertyGIFFrameInfoArray,
                unclampedDelay: kCGImagePropertyGIFUnclampedDelayTime,
                delay: kCGImagePropertyGIFDelayTime,
                loopCount: kCGImagePropertyGIFLoopCount,
                defaultLoopCount: 1
            )
        case .webp:
            Keys(
                dictionary: kCGImagePropertyWebPDictionary,
                frameInfo: kCGImagePropertyWebPFrameInfoArray,
                unclampedDelay: kCGImagePropertyWebPUnclampedDelayTime,
                delay: kCGImagePropertyWebPDelayTime,
                loopCount: kCGImagePropertyWebPLoopCount,
                defaultLoopCount: 0
            )
        case .png:
            Keys(
                dictionary: kCGImagePropertyPNGDictionary,
                frameInfo: kCGImagePropertyAPNGFrameInfoArray,
                unclampedDelay: kCGImagePropertyAPNGUnclampedDelayTime,
                delay: kCGImagePropertyAPNGDelayTime,
                loopCount: kCGImagePropertyAPNGLoopCount,
                defaultLoopCount: 0
            )
        default:
            nil
        }
    }

    static func hasAnimationTiming(_ frameProperties: [CFString: Any], type: AssetType) -> Bool {
        guard let keys = keys(for: type),
            let dictionary = frameProperties[keys.dictionary] as? [CFString: Any]
        else {
            return false
        }
        return dictionary[keys.unclampedDelay] is NSNumber || dictionary[keys.delay] is NSNumber
    }

    static func timing(source: CGImageSource, frameCount: Int, type: AssetType) -> (loopCount: Int, frameDurations: [TimeInterval]) {
        guard let keys = keys(for: type) else {
            return (0, Array(repeating: defaultFrameDuration, count: frameCount))
        }
        let properties = CGImageSourceCopyProperties(source, ImageHeader.sourceOptions) as? [CFString: Any]
        let dictionary = properties?[keys.dictionary] as? [CFString: Any]
        let loopCount = (dictionary?[keys.loopCount] as? NSNumber).map { max(0, $0.intValue) } ?? keys.defaultLoopCount
        let frameInfo = (dictionary?[keys.frameInfo] as? [[CFString: Any]]).flatMap { $0.count == frameCount ? $0 : nil }
        let durations = (0..<frameCount).map { index -> TimeInterval in
            if let delay = (frameInfo?[index][keys.unclampedDelay] as? NSNumber)?.doubleValue {
                return normalizedDuration(delay)
            }
            return frameDuration(source: source, index: index, keys: keys)
        }
        return (loopCount, durations)
    }

    private static func frameDuration(source: CGImageSource, index: Int, keys: Keys) -> TimeInterval {
        guard let properties = ImageHeader.properties(of: source, at: index),
            let dictionary = properties[keys.dictionary] as? [CFString: Any]
        else {
            return defaultFrameDuration
        }
        let delay =
            (dictionary[keys.unclampedDelay] as? NSNumber)?.doubleValue
            ?? (dictionary[keys.delay] as? NSNumber)?.doubleValue
        return normalizedDuration(delay)
    }

    static func normalizedDuration(_ delay: TimeInterval?) -> TimeInterval {
        guard let delay, delay.isFinite, delay > minimumFrameDuration + 0.000_1 else {
            return defaultFrameDuration
        }
        return delay
    }
}

enum ContainerScanner {
    static func gifHasAnimation(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard bytes.count >= 13 else {
            return false
        }
        var offset = 13 + colorTableSize(bytes[10])
        var descriptorCount = 0
        var hasFirstFrameTiming = false
        while offset < bytes.count {
            switch bytes[offset] {
            case 0x21:
                guard offset + 1 < bytes.count else {
                    return false
                }
                if bytes[offset + 1] == 0xF9, descriptorCount == 0 {
                    hasFirstFrameTiming = true
                }
                offset = skipGIFSubBlocks(bytes, from: offset + 2)
            case 0x2C:
                descriptorCount += 1
                if descriptorCount == 2 {
                    return hasFirstFrameTiming
                }
                guard offset + 10 <= bytes.count else {
                    return false
                }
                offset += 10 + colorTableSize(bytes[offset + 9])
                offset = skipGIFSubBlocks(bytes, from: offset + 1)
            default:
                return false
            }
        }
        return false
    }

    static func pngHasAnimation(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var offset = 8
        var declaredFrameCount = 0
        var hasFirstFrameControl = false
        while offset + 8 <= bytes.count {
            let length = readBigEndian32(bytes, at: offset)
            switch (bytes[offset + 4], bytes[offset + 5], bytes[offset + 6], bytes[offset + 7]) {
            case (0x61, 0x63, 0x54, 0x4C):
                guard offset + 12 <= bytes.count else {
                    return false
                }
                declaredFrameCount = readBigEndian32(bytes, at: offset + 8)
            case (0x66, 0x63, 0x54, 0x4C):
                hasFirstFrameControl = true
            case (0x49, 0x44, 0x41, 0x54):
                return declaredFrameCount > 1 && hasFirstFrameControl
            default:
                break
            }
            offset += 12 + length
        }
        return false
    }

    static func webpHasAnimation(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard bytes.count > 20,
            (bytes[12], bytes[13], bytes[14], bytes[15]) == (0x56, 0x50, 0x38, 0x58),
            bytes[20] & 0x02 != 0
        else {
            return false
        }
        var offset = 12
        var frameCount = 0
        while offset + 8 <= bytes.count {
            if (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]) == (0x41, 0x4E, 0x4D, 0x46) {
                frameCount += 1
                if frameCount == 2 {
                    return true
                }
            }
            let size = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8 | Int(bytes[offset + 6]) << 16 | Int(bytes[offset + 7]) << 24
            offset += 8 + size + (size & 1)
        }
        return false
    }

    private static func colorTableSize(_ packed: UInt8) -> Int {
        packed & 0x80 != 0 ? 3 << (Int(packed & 0x07) + 1) : 0
    }

    private static func skipGIFSubBlocks(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var offset = start
        while offset < bytes.count {
            let length = Int(bytes[offset])
            offset += 1
            if length == 0 {
                return offset
            }
            offset += length
        }
        return offset
    }

    private static func readBigEndian32(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> Int {
        Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }
}
