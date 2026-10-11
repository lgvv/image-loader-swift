import CoreGraphics
import Foundation
import UIKit

extension ImageFilters {
    /// 이미지를 원 모양으로 자릅니다. 정사각형이 아니면 가운데를 기준으로 정사각형으로 먼저 자릅니다.
    public struct Circle: ImageFilter, Hashable, CustomStringConvertible {
        private let border: ImageFilterOptions.Border?

        /// 원 모양 필터를 만듭니다.
        ///
        /// - Parameter border: 원 둘레에 그릴 테두리입니다. `nil`이면 그리지 않습니다.
        public init(border: ImageFilterOptions.Border? = nil) {
            self.border = border
        }

        /// 이미지를 원 모양으로 자릅니다. 원 바깥은 투명합니다.
        public func process(_ image: UIImage) -> UIImage? {
            guard let square = ProcessingCanvas.croppedToSquare(image), let cgImage = square.cgImage else {
                return nil
            }
            return ProcessingCanvas.roundingCorners(of: square, radius: CGFloat(cgImage.width) / 2, border: border)
        }

        /// 테두리 설정을 담은 문자열입니다.
        public var identifier: String {
            guard let border else { return "imageloader/circle" }
            return "imageloader/circle?border=\(border)"
        }

        public var description: String {
            "Circle(border: \(border.map { "\($0)" } ?? "nil"))"
        }
    }

    /// 이미지의 모서리를 둥글게 자릅니다.
    public struct RoundedCorners: ImageFilter, Hashable, CustomStringConvertible {
        private let radius: CGFloat
        private let border: ImageFilterOptions.Border?

        /// 둥근 모서리 필터를 만듭니다.
        ///
        /// - Parameters:
        ///   - radius: 모서리 반지름입니다.
        ///   - unit: `.points`면 화면 배율을 곱해 픽셀로 바꿉니다.
        ///   - border: 가장자리에 그릴 테두리입니다. `nil`이면 그리지 않습니다.
        public init(radius: CGFloat, unit: ImageFilterOptions.Unit = .points, border: ImageFilterOptions.Border? = nil) {
            self.radius = unit == .points ? radius * Screen.scale : radius
            self.border = border
        }

        /// 모서리를 둥글게 자릅니다. 모서리 바깥은 투명합니다.
        public func process(_ image: UIImage) -> UIImage? {
            ProcessingCanvas.roundingCorners(of: image, radius: radius, border: border)
        }

        /// 반지름과 테두리 설정을 담은 문자열입니다.
        public var identifier: String {
            let base = "imageloader/rounded_corners?radius=\(radius)"
            guard let border else { return base }
            return base + ",border=\(border)"
        }

        public var description: String {
            "RoundedCorners(radius: \(radius) pixels, border: \(border.map { "\($0)" } ?? "nil"))"
        }
    }
}

extension ImageFilter where Self == ImageFilters.Circle {
    /// ``ImageFilters/Circle``을 만듭니다.
    public static func circle(border: ImageFilterOptions.Border? = nil) -> ImageFilters.Circle {
        ImageFilters.Circle(border: border)
    }
}

extension ImageFilter where Self == ImageFilters.RoundedCorners {
    /// ``ImageFilters/RoundedCorners``를 만듭니다.
    public static func roundedCorners(
        radius: CGFloat,
        unit: ImageFilterOptions.Unit = .points,
        border: ImageFilterOptions.Border? = nil
    ) -> ImageFilters.RoundedCorners {
        ImageFilters.RoundedCorners(radius: radius, unit: unit, border: border)
    }
}
