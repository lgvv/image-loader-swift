import Accelerate
import CoreGraphics
import Foundation
import UIKit

extension ImageFilters {
    /// 이미지를 흐리게 만듭니다. Accelerate로 박스 블러를 세 번 겹쳐 가우시안 블러에 가깝게 만듭니다.
    public struct GaussianBlur: ImageFilter, Hashable, CustomStringConvertible {
        private let radius: Int

        /// 흐림 정도를 정해 필터를 만듭니다.
        ///
        /// - Parameter radius: 흐림 반지름입니다. 단위는 픽셀이고, 0이면 이미지를 바꾸지 않습니다. 기본값은 8입니다.
        public init(radius: Int = 8) {
            self.radius = max(0, radius)
        }

        /// 이미지를 흐리게 만듭니다.
        public func process(_ image: UIImage) -> UIImage? {
            guard radius > 0 else { return image }
            guard let cgImage = image.cgImage, let output = Self.blur(cgImage, radius: radius) else {
                return nil
            }
            return ProcessingCanvas.image(output, like: image)
        }

        /// 반지름을 담은 문자열입니다.
        public var identifier: String {
            "imageloader/gaussian_blur?radius=\(radius)"
        }

        public var description: String {
            "GaussianBlur(radius: \(radius))"
        }

        static func boxKernelSize(radius: Int) -> UInt32 {
            let estimate = (Double(radius) * 3 * (2 * Double.pi).squareRoot() / 4 + 0.5).rounded(.down)
            let size = UInt32(max(1, estimate))
            return size.isMultiple(of: 2) ? size + 1 : size
        }

        private static func blur(_ cgImage: CGImage, radius: Int) -> CGImage? {
            let alphaInfo: CGImageAlphaInfo = Bitmap.isOpaque(cgImage) ? .noneSkipLast : .premultipliedLast
            let space = CGColorSpaceCreateDeviceRGB()
            let width = cgImage.width
            let height = cgImage.height
            guard let source = ProcessingCanvas.makeContext(width: width, height: height, space: space, alphaInfo: alphaInfo),
                let target = ProcessingCanvas.makeContext(width: width, height: height, space: space, alphaInfo: alphaInfo),
                source.bitsPerPixel == 32, target.bitsPerPixel == 32
            else {
                return nil
            }
            source.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            var first = vImage_Buffer(data: source.data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: source.bytesPerRow)
            var second = vImage_Buffer(data: target.data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: target.bytesPerRow)
            let kernel = boxKernelSize(radius: radius)
            let flags = vImage_Flags(kvImageEdgeExtend)
            guard vImageBoxConvolve_ARGB8888(&first, &second, nil, 0, 0, kernel, kernel, nil, flags) == kvImageNoError,
                vImageBoxConvolve_ARGB8888(&second, &first, nil, 0, 0, kernel, kernel, nil, flags) == kvImageNoError,
                vImageBoxConvolve_ARGB8888(&first, &second, nil, 0, 0, kernel, kernel, nil, flags) == kvImageNoError
            else {
                return nil
            }
            return target.makeImage()
        }
    }
}

extension ImageFilter where Self == ImageFilters.GaussianBlur {
    /// ``ImageFilters/GaussianBlur``를 만듭니다.
    public static func gaussianBlur(radius: Int = 8) -> ImageFilters.GaussianBlur {
        ImageFilters.GaussianBlur(radius: radius)
    }
}
