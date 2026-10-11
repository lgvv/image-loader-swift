import CoreGraphics
import Foundation
import ImageIO

extension AnimatedImageSource {
    static func makeFrame(
        source: CGImageSource,
        index: Int,
        decision: ImageRequest.ThumbnailOptions.Decision,
        thumbnail: ImageRequest.ThumbnailOptions?
    ) -> CGImage? {
        autoreleasepool {
            guard isFrameDataAvailable(source: source, index: index) else {
                return nil
            }
            switch (decision, thumbnail) {
            case (.thumbnail(let maxPixelSize), .some(let thumbnail)):
                guard let image = thumbnail.makeThumbnailImage(source: source, index: index, maxPixelSize: maxPixelSize) else {
                    return nil
                }
                return thumbnail.shouldCacheImmediately ? image : (Bitmap.redraw(image) ?? image)
            default:
                guard let image = CGImageSourceCreateImageAtIndex(source, index, ImageHeader.sourceOptions) else {
                    return nil
                }
                return Bitmap.redraw(image) ?? image
            }
        }
    }

    private static func isFrameDataAvailable(source: CGImageSource, index: Int) -> Bool {
        switch CGImageSourceGetStatusAtIndex(source, index) {
        case .statusIncomplete, .statusInvalidData, .statusUnexpectedEOF, .statusUnknownType, .statusReadingHeader:
            false
        default:
            true
        }
    }

    private static let decodeQueues: [DispatchQueue] = (0..<max(2, ProcessInfo.processInfo.activeProcessorCount / 2)).map {
        DispatchQueue(label: "ImageLoader.AnimatedFrameDecode.\($0)", qos: .userInitiated)
    }

    private static let counters = LockIsolated((queueCursor: 0, nextSourceID: UInt64(0)))

    static func nextDecodeQueue() -> DispatchQueue {
        let index = counters.withLock { counters -> Int in
            let index = counters.queueCursor
            counters.queueCursor = (index + 1) % decodeQueues.count
            return index
        }
        return decodeQueues[index]
    }

    static func makeSourceID() -> UInt64 {
        counters.withLock { counters in
            counters.nextSourceID &+= 1
            return counters.nextSourceID
        }
    }
}
