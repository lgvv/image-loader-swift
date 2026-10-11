import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// 라이브러리가 제공하는 디코더 모음입니다.
public enum ImageDecoders {}

extension ImageDecoders {
    /// `UIImage`와 ImageIO로 디코딩하는 기본 디코더입니다. 시스템이 지원하는 모든 정지 이미지 형식을 디코딩합니다.
    ///
    /// ``ImageRequest/thumbnail``이 있으면 처음부터 작은 크기로 디코딩하고, 프로그레시브 JPEG은 받은 만큼 미리보기를 만듭니다.
    /// 디코딩 전에 이미지 헤더에서 픽셀 수를 읽어 ``ImageDecodingLimits``를 넘으면 디코딩하지 않습니다.
    public final class Default: ImageDecoding, Sendable {
        private let scale: CGFloat
        private let thumbnail: ImageRequest.ThumbnailOptions?
        private let limits: ImageDecodingLimits
        private let prefersAsynchronousDecoding: Bool
        let previewPolicy: ImageSession.PreviewPolicy
        private let progressive = DecoderStateLock(ProgressiveState())

        /// 요청 정보 없이 배율 1로 디코딩하는 디코더를 만듭니다.
        public init() {
            scale = 1
            thumbnail = nil
            limits = .default
            prefersAsynchronousDecoding = false
            previewPolicy = .incremental
        }

        /// 요청의 배율, 썸네일 설정, 디코딩 한도를 따르는 디코더를 만듭니다. 항상 성공합니다.
        public init?(context: ImageDecodingContext) {
            scale = CGFloat(context.request.scale)
            thumbnail = context.request.thumbnail
            limits = context.decodingLimits
            prefersAsynchronousDecoding =
                thumbnail != nil
                || (limits.isEnabled && ImageHeaderScanner.pixelSize(of: context.data) == nil)
            previewPolicy = context.previewPolicy
        }

        init(scale: CGFloat, thumbnail: ImageRequest.ThumbnailOptions?, limits: ImageDecodingLimits) {
            self.scale = scale
            self.thumbnail = thumbnail
            self.limits = limits
            prefersAsynchronousDecoding = true
            previewPolicy = .incremental
        }

        var numberOfScans: Int {
            progressive.withLock { $0.numberOfScans }
        }

        /// 썸네일을 만들 때와 헤더에서 크기를 읽지 못했을 때만 `true`입니다.
        ///
        /// 나머지는 `UIImage`만 만들고 실제 디코딩은 미리 그리는 단계로 미루므로, 내부 큐에서 바로 끝납니다.
        public var isAsynchronous: Bool {
            prefersAsynchronousDecoding
        }

        /// 데이터를 디코딩합니다. GIF는 첫 프레임만 이미지로 만들고 원본 데이터를 ``ImageContent/data``에 함께 담습니다.
        public func decode(_ data: Data) throws -> ImageContent {
            let type = AssetType(data)
            let image = try makeImage(data)
            var content = ImageContent(image: image, type: type)
            if type == .gif {
                content.data = data
            }
            let scans = progressive.withLock { state -> Int in
                state.incrementalSource = nil
                return state.numberOfScans
            }
            if scans > 0 {
                content.userInfo[.scanNumberKey] = scans
            }
            return content
        }

        /// 다운로드 도중의 데이터로 미리보기를 만듭니다. 미리보기 종류는 ``ImageDecodingContext/previewPolicy``를 따릅니다.
        public func decodePartiallyDownloadedData(_ data: Data) -> ImageContent? {
            guard previewPolicy != .disabled else {
                return nil
            }
            let type = AssetType(data)
            return progressive.withLock { state in
                if type == .gif {
                    return makeGIFPreview(data, state: &state)
                }
                switch previewPolicy {
                case .disabled:
                    return nil
                case .thumbnail:
                    return makeEmbeddedThumbnailPreview(data, type: type, state: &state)
                case .incremental:
                    return makeIncrementalPreview(data, type: type, state: &state)
                }
            }
        }

        private func makeGIFPreview(_ data: Data, state: inout ProgressiveState) -> ImageContent? {
            guard !state.isGIFPreviewGenerated,
                (try? limits.validate(data)) != nil,
                let image = UIImage(data: data, scale: scale)
            else {
                return nil
            }
            state.isGIFPreviewGenerated = true
            return ImageContent(image: image, type: .gif, isPreview: true)
        }

        private func makeEmbeddedThumbnailPreview(_ data: Data, type: AssetType?, state: inout ProgressiveState) -> ImageContent? {
            guard state.numberOfScans == 0,
                (try? limits.validate(data)) != nil,
                let source = CGImageSourceCreateWithData(data as CFData, ImageHeader.sourceOptions),
                let cgImage = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: false,
                        kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: Self.embeddedThumbnailMaxPixelSize,
                    ] as CFDictionary)
            else {
                return nil
            }
            return makePreview(UIImage(cgImage: cgImage, scale: scale, orientation: .up), type: type, state: &state)
        }

        private func makeIncrementalPreview(_ data: Data, type: AssetType?, state: inout ProgressiveState) -> ImageContent? {
            let source: CGImageSource
            if let existing = state.incrementalSource {
                source = existing
            } else {
                source = CGImageSourceCreateIncremental(ImageHeader.sourceOptions)
                state.incrementalSource = source
            }
            CGImageSourceUpdateData(source, data as CFData, false)
            guard let properties = ImageHeader.properties(of: source, at: 0),
                let size = ImageHeader.pixelSize(from: properties)
            else {
                return makeFallbackThumbnailPreview(data, type: type, state: &state)
            }
            guard (try? limits.validate(sourceSize: size, decodedPixelCount: size.pixelCount)) != nil,
                let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                return nil
            }
            let orientation = ImageHeader.imageOrientation(ImageHeader.orientation(from: properties))
            return makePreview(UIImage(cgImage: cgImage, scale: scale, orientation: orientation), type: type, state: &state)
        }

        private func makeFallbackThumbnailPreview(_ data: Data, type: AssetType?, state: inout ProgressiveState) -> ImageContent? {
            guard !state.didAttemptFallbackThumbnail,
                let source = CGImageSourceCreateWithData(data as CFData, ImageHeader.sourceOptions),
                let cgImage = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                        kCGImageSourceThumbnailMaxPixelSize: Self.fallbackThumbnailMaxPixelSize,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                    ] as CFDictionary)
            else {
                return nil
            }
            state.didAttemptFallbackThumbnail = true
            return makePreview(UIImage(cgImage: cgImage, scale: scale, orientation: .up), type: type, state: &state)
        }

        private func makePreview(_ image: UIImage, type: AssetType?, state: inout ProgressiveState) -> ImageContent {
            state.numberOfScans += 1
            return ImageContent(image: image, type: type, isPreview: true, userInfo: [.scanNumberKey: state.numberOfScans])
        }

        private static let fallbackThumbnailMaxPixelSize = 160
        private static let embeddedThumbnailMaxPixelSize = 1024

        private struct ProgressiveState {
            var incrementalSource: CGImageSource?
            var numberOfScans = 0
            var isGIFPreviewGenerated = false
            var didAttemptFallbackThumbnail = false
        }

        private func makeImage(_ data: Data) throws -> UIImage {
            guard let thumbnail else {
                try limits.validate(data)
                return try decodeOriginal(data)
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, ImageHeader.sourceOptions) else {
                throw ImageDecodingError.unknown
            }
            let properties = ImageHeader.properties(of: source, at: 0)
            let decision = thumbnail.decision(for: properties, sourceType: CGImageSourceGetType(source) as String?)
            try limits.validate(properties, decision: decision)
            switch decision {
            case .thumbnail(let maxPixelSize):
                guard let image = thumbnail.makeImage(source: source, index: 0, maxPixelSize: maxPixelSize, scale: scale) else {
                    throw ImageDecodingError.unknown
                }
                return image
            case .original:
                let image = try decodeOriginal(data)
                ImageDecompression.setDecompressionNeeded(true, for: image)
                return image
            }
        }

        private func decodeOriginal(_ data: Data) throws -> UIImage {
            guard let image = UIImage(data: data, scale: scale) else {
                throw ImageDecodingError.unknown
            }
            return image
        }
    }

    /// 이미지를 만들지 않고 데이터만 그대로 담는 디코더입니다.
    ///
    /// 동영상처럼 디코딩하지 않고 데이터만 넘겨받아야 하는 형식에 씁니다. ``ImageContent/image``는 빈 이미지입니다.
    public struct Empty: ImageDecoding, Sendable {
        /// 다운로드 도중에도 받은 데이터를 미리보기로 넘길지 정합니다.
        public let isProgressive: Bool
        private let assetType: AssetType?

        /// 디코더를 만듭니다.
        ///
        /// - Parameters:
        ///   - assetType: 결과의 ``ImageContent/type``에 넣을 형식입니다.
        ///   - isProgressive: `true`면 다운로드 도중에도 받은 데이터를 미리보기로 넘깁니다.
        public init(assetType: AssetType? = nil, isProgressive: Bool = false) {
            self.assetType = assetType
            self.isProgressive = isProgressive
        }

        /// 항상 `false`입니다. 디코딩하지 않으므로 바로 끝납니다.
        public var isAsynchronous: Bool {
            false
        }

        /// 빈 이미지와 데이터를 담아 돌려줍니다.
        public func decode(_ data: Data) throws -> ImageContent {
            ImageContent(image: UIImage(), type: assetType, data: data)
        }

        /// ``isProgressive``가 `true`면 받은 데이터를 미리보기로 담아 돌려줍니다.
        public func decodePartiallyDownloadedData(_ data: Data) -> ImageContent? {
            isProgressive ? ImageContent(image: UIImage(), type: assetType, isPreview: true, data: data) : nil
        }
    }
}
