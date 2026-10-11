import CoreGraphics
import Foundation
import UIKit

/// 라이브러리가 제공하는 필터 모음입니다. `filters: [.resize(width: 120), .circle()]`처럼 짧게 쓸 수 있습니다.
public enum ImageFilters {}

extension ImageFilters {
    /// 원본 비율을 지키면서 크기를 바꿉니다.
    ///
    /// 크기만 줄여 화면에 보여 주는 용도라면, 원본을 모두 디코딩한 뒤 줄이는 이 필터보다 ``ImageRequest/ThumbnailOptions``가 메모리를 덜 씁니다.
    public struct Resize: ImageFilter, Hashable, CustomStringConvertible {
        /// 맞출 크기입니다. 단위는 픽셀입니다.
        public let size: CGSize
        /// 크기를 맞추는 방식입니다.
        public let contentMode: ImageFilterOptions.ContentMode
        /// `true`이고 ``contentMode``가 `.aspectFill`이면 ``size``를 넘는 부분을 가운데 기준으로 잘라 냅니다.
        public let crop: Bool
        /// `false`면 원본이 ``size``보다 작을 때 늘리지 않고 원본 크기를 유지합니다.
        public let upscale: Bool

        /// 크기와 맞추는 방식을 정해 필터를 만듭니다.
        ///
        /// - Parameters:
        ///   - size: 맞출 크기입니다.
        ///   - unit: `.points`면 화면 배율을 곱해 픽셀로 바꿉니다. 3배율 기기에서 100은 300픽셀이 됩니다.
        ///   - contentMode: `.aspectFill`이면 영역을 빈틈없이 채우고, `.aspectFit`이면 영역 안에 다 들어가게 맞춥니다.
        ///   - crop: `true`이고 `contentMode`가 `.aspectFill`이면 영역을 넘는 부분을 잘라 냅니다.
        ///   - upscale: `false`면 원본이 영역보다 작을 때 늘리지 않습니다.
        public init(
            size: CGSize,
            unit: ImageFilterOptions.Unit = .points,
            contentMode: ImageFilterOptions.ContentMode = .aspectFill,
            crop: Bool = false,
            upscale: Bool = false
        ) {
            self.size = unit == .points ? size.scaled(by: Screen.scale) : size
            self.contentMode = contentMode
            self.crop = crop
            self.upscale = upscale
        }

        /// 원본 비율을 지키면서 너비를 맞춥니다. 높이는 원본 비율에 따라 정해집니다.
        ///
        /// - Parameters:
        ///   - width: 맞출 너비입니다.
        ///   - unit: `.points`면 화면 배율을 곱해 픽셀로 바꿉니다.
        ///   - upscale: `false`면 원본이 `width`보다 좁을 때 늘리지 않습니다.
        public init(width: CGFloat, unit: ImageFilterOptions.Unit = .points, upscale: Bool = false) {
            self.init(size: CGSize(width: width, height: 9999), unit: unit, contentMode: .aspectFit, crop: false, upscale: upscale)
        }

        /// 원본 비율을 지키면서 높이를 맞춥니다. 너비는 원본 비율에 따라 정해집니다.
        ///
        /// - Parameters:
        ///   - height: 맞출 높이입니다.
        ///   - unit: `.points`면 화면 배율을 곱해 픽셀로 바꿉니다.
        ///   - upscale: `false`면 원본이 `height`보다 낮을 때 늘리지 않습니다.
        public init(height: CGFloat, unit: ImageFilterOptions.Unit = .points, upscale: Bool = false) {
            self.init(size: CGSize(width: 9999, height: height), unit: unit, contentMode: .aspectFit, crop: false, upscale: upscale)
        }

        /// 이미지 크기를 바꿉니다. 크기가 1픽셀보다 작게 계산되면 `nil`입니다.
        public func process(_ image: UIImage) -> UIImage? {
            guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
                let cgImage = image.cgImage
            else {
                return nil
            }
            let original = CGSize(width: cgImage.width, height: cgImage.height)
            let scaleX = size.width / original.width
            let scaleY = size.height / original.height
            var scale = contentMode == .aspectFill ? max(scaleX, scaleY) : min(scaleX, scaleY)
            if !upscale {
                scale = min(scale, 1)
            }
            let scaled = CGSize(width: (original.width * scale).rounded(), height: (original.height * scale).rounded())
            let canvas: CGSize
            if crop, contentMode == .aspectFill {
                canvas = CGSize(width: min(scaled.width, size.width.rounded()), height: min(scaled.height, size.height.rounded()))
            } else {
                canvas = scaled
            }
            guard canvas.width >= 1, canvas.height >= 1,
                let context = Bitmap.makeContext(width: Int(canvas.width), height: Int(canvas.height), like: cgImage)
            else {
                return nil
            }
            context.interpolationQuality = .high
            let origin = CGPoint(x: (canvas.width - scaled.width) / 2, y: (canvas.height - scaled.height) / 2)
            context.draw(cgImage, in: CGRect(origin: origin, size: scaled))
            guard let output = context.makeImage() else { return nil }
            return UIImage(cgImage: output, scale: image.scale, orientation: image.imageOrientation)
        }

        /// 크기, 맞추는 방식, 자르기, 늘리기 설정을 담은 문자열입니다.
        public var identifier: String {
            "imageloader/resize?s=\(Int(size.width))x\(Int(size.height)),cm=\(contentMode),crop=\(crop),upscale=\(upscale)"
        }

        public var description: String {
            "Resize(size: \(size) pixels, contentMode: \(contentMode), crop: \(crop), upscale: \(upscale))"
        }
    }

    /// 여러 필터를 하나로 묶습니다. 필터를 차례로 적용하고, 하나라도 실패하면 전체가 실패합니다.
    ///
    /// ``ImageRequest/filters``에 여러 개를 넣는 것과 결과는 같습니다. 필터 하나만 받는 API에 여러 필터를 넘길 때 씁니다.
    public struct Composition: ImageFilter, Hashable, CustomStringConvertible {
        let filters: [any ImageFilter]

        /// 묶을 필터를 적용할 순서대로 넘깁니다.
        public init(_ filters: [any ImageFilter]) {
            self.filters = filters
        }

        /// 필터를 차례로 적용합니다.
        public func process(_ image: UIImage) -> UIImage? {
            var image = image
            for filter in filters {
                guard let output = autoreleasepool(invoking: { filter.process(image) }) else { return nil }
                image = output
            }
            return image
        }

        /// 필터를 차례로 적용합니다. 실패한 필터의 오류를 그대로 일으킵니다.
        public func process(_ content: ImageContent, context: ImageFilterContext) throws -> ImageContent {
            var content = content
            for filter in filters {
                content = try autoreleasepool {
                    try filter.process(content, context: context)
                }
            }
            return content
        }

        /// 묶은 필터의 ``ImageFilter/identifier``를 순서대로 이어 붙인 문자열입니다.
        public var identifier: String {
            filters.map(\.identifier).joined(separator: ImageSession.Cache.dataKeySeparator)
        }

        /// 묶은 필터의 ``ImageFilter/hashableIdentifier``를 순서대로 담은 값입니다.
        public var hashableIdentifier: AnyHashable {
            AnyHashable(filters.map(\.hashableIdentifier))
        }

        public var description: String {
            "Composition(\(filters.map { "\($0)" }.joined(separator: ", ")))"
        }

        public static func == (lhs: Composition, rhs: Composition) -> Bool {
            lhs.filters.isEquivalent(to: rhs.filters)
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(filters.map(\.hashableIdentifier))
        }
    }

    /// 클로저로 만드는 필터입니다. 필터 타입을 따로 만들기 번거로울 때 씁니다.
    public struct Anonymous: ImageFilter, CustomStringConvertible {
        /// 필터를 구분하는 문자열입니다. 클로저가 하는 일이 달라지면 이 값도 바꿔 주세요.
        public let identifier: String
        private let closure: @Sendable (UIImage) -> UIImage?

        /// 클로저로 필터를 만듭니다.
        ///
        /// - Parameters:
        ///   - id: 필터를 구분하는 문자열입니다. 디스크 캐시 키에 들어가므로, 클로저가 하는 일이 달라지면 이 값도 바꿔 주세요.
        ///   - closure: 이미지를 바꿔 돌려줍니다. `nil`을 돌려주면 필터가 실패합니다.
        public init(id: String, _ closure: @escaping @Sendable (UIImage) -> UIImage?) {
            identifier = id
            self.closure = closure
        }

        /// 클로저를 부릅니다.
        public func process(_ image: UIImage) -> UIImage? {
            closure(image)
        }

        public var description: String {
            "AnonymousFilter(identifier: \(identifier))"
        }
    }
}

extension ImageFilter where Self == ImageFilters.Resize {
    /// 크기와 맞추는 방식을 정한 ImageFilters/Resize를 만듭니다.
    public static func resize(
        size: CGSize,
        unit: ImageFilterOptions.Unit = .points,
        contentMode: ImageFilterOptions.ContentMode = .aspectFill,
        crop: Bool = false,
        upscale: Bool = false
    ) -> ImageFilters.Resize {
        ImageFilters.Resize(size: size, unit: unit, contentMode: contentMode, crop: crop, upscale: upscale)
    }

    /// 원본 비율을 지키면서 너비를 맞추는 ImageFilters/Resize를 만듭니다.
    public static func resize(width: CGFloat, unit: ImageFilterOptions.Unit = .points, upscale: Bool = false) -> ImageFilters.Resize {
        ImageFilters.Resize(width: width, unit: unit, upscale: upscale)
    }

    /// 원본 비율을 지키면서 높이를 맞추는 ImageFilters/Resize를 만듭니다.
    public static func resize(height: CGFloat, unit: ImageFilterOptions.Unit = .points, upscale: Bool = false) -> ImageFilters.Resize {
        ImageFilters.Resize(height: height, unit: unit, upscale: upscale)
    }
}

extension ImageFilter where Self == ImageFilters.Anonymous {
    /// 클로저로 ImageFilters/Anonymous 필터를 만듭니다.
    public static func process(id: String, _ closure: @escaping @Sendable (UIImage) -> UIImage?) -> ImageFilters.Anonymous {
        ImageFilters.Anonymous(id: id, closure)
    }
}
