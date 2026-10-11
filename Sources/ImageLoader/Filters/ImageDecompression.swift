import CoreGraphics
import Foundation
import ObjectiveC
import UIKit

enum ImageDecompression {
    nonisolated(unsafe) private static let isDecompressionNeededKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    static func isDecompressionNeeded(for response: ImageResponse) -> Bool {
        isDecompressionNeeded(for: response.image) ?? false
    }

    static func isDecompressionNeeded(for image: UIImage) -> Bool? {
        objc_getAssociatedObject(image, isDecompressionNeededKey) as? Bool
    }

    static func setDecompressionNeeded(_ isNeeded: Bool, for image: UIImage) {
        objc_setAssociatedObject(image, isDecompressionNeededKey, isNeeded, .OBJC_ASSOCIATION_RETAIN)
    }

    static func decompress(image: UIImage, isUsingPrepareForDisplay: Bool = false) -> UIImage {
        if isUsingPrepareForDisplay, let prepared = image.preparingForDisplay() {
            return prepared
        }
        guard let cgImage = image.cgImage, let decoded = Bitmap.redraw(cgImage) else {
            return image
        }
        return UIImage(cgImage: decoded, scale: image.scale, orientation: image.imageOrientation)
    }
}

enum Bitmap {
    static func redraw(_ image: CGImage) -> CGImage? {
        guard let context = makeContext(width: image.width, height: image.height, like: image) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    static func makeContext(width: Int, height: Int, like image: CGImage?) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let isOpaque = image.map(isOpaque) ?? false
        let alphaInfo: CGImageAlphaInfo = isOpaque ? .noneSkipLast : .premultipliedLast
        let preferredSpace = image?.colorSpace
        if let preferredSpace, preferredSpace.model == .rgb,
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: preferredSpace, bitmapInfo: alphaInfo.rawValue)
        {
            return context
        }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: alphaInfo.rawValue)
    }

    static func isOpaque(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return true
        default:
            return false
        }
    }

    static func cost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }
}
