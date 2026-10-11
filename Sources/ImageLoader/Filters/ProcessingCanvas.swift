import CoreGraphics
import Foundation
import UIKit

enum ProcessingCanvas {
    static func makeContext(like image: CGImage, width: Int, height: Int, alphaInfo: CGImageAlphaInfo) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        if let space = image.colorSpace,
            let context = makeContext(width: width, height: height, space: space, alphaInfo: alphaInfo)
        {
            return context
        }
        return makeContext(width: width, height: height, space: CGColorSpaceCreateDeviceRGB(), alphaInfo: alphaInfo)
    }

    static func makeContext(width: Int, height: Int, space: CGColorSpace, alphaInfo: CGImageAlphaInfo) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: alphaInfo.rawValue)
    }

    static func image(_ cgImage: CGImage, like source: UIImage) -> UIImage {
        UIImage(cgImage: cgImage, scale: source.scale, orientation: source.imageOrientation)
    }

    static func croppedToSquare(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width != height else { return image }
        let side = min(width, height)
        let rect = CGRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side)
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        return self.image(cropped, like: image)
    }

    static func roundingCorners(of image: UIImage, radius: CGFloat, border: ImageFilterOptions.Border?) -> UIImage? {
        guard let cgImage = image.cgImage,
            let context = makeContext(like: cgImage, width: cgImage.width, height: cgImage.height, alphaInfo: .premultipliedLast)
        else {
            return nil
        }
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path)
        context.clip()
        context.draw(cgImage, in: bounds)
        if let border {
            context.setStrokeColor(border.color.cgColor)
            context.setLineWidth(border.width)
            context.addPath(path)
            context.strokePath()
        }
        guard let output = context.makeImage() else { return nil }
        return self.image(output, like: image)
    }
}
