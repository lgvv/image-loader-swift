import CoreImage
import Foundation
import UIKit

extension ImageFilters {
    /// Core Image 필터를 적용합니다.
    ///
    /// 필터를 적용할 때마다 `CIFilter`를 새로 만들거나 복사하므로, 여러 이미지에 동시에 적용해도 서로 영향을 주지 않습니다.
    ///
    /// ```swift
    /// let sepia = ImageFilters.CoreImageFilter(name: "CISepiaTone")
    /// ```
    public struct CoreImageFilter: ImageFilter, CustomStringConvertible, @unchecked Sendable {
        let filter: Filter
        /// 필터를 구분하는 문자열입니다. 디스크 캐시 키에 들어갑니다.
        public let identifier: String

        enum Filter {
            case named(String, parameters: [String: Any])
            case custom(CIFilter)
        }

        /// 이름과 파라미터로 Core Image 필터를 만듭니다.
        ///
        /// - Parameters:
        ///   - name: `CIFilter` 이름입니다. 예를 들어 `CISepiaTone`입니다.
        ///   - parameters: 필터에 넘길 값입니다. 입력 이미지는 넣지 않아도 됩니다.
        ///   - identifier: 필터를 구분하는 문자열입니다. 파라미터가 달라지면 이 값도 바꿔 주세요.
        public init(name: String, parameters: [String: Any], identifier: String) {
            filter = .named(name, parameters: parameters)
            self.identifier = identifier
        }

        /// 기본 파라미터로 Core Image 필터를 만듭니다. 식별자는 `imageloader/core_image?name=` 뒤에 이름을 붙인 값입니다.
        public init(name: String) {
            filter = .named(name, parameters: [:])
            identifier = "imageloader/core_image?name=\(name)"
        }

        /// 값을 정해 둔 `CIFilter`로 필터를 만듭니다. 적용할 때마다 복사해서 쓰므로 원래 필터는 바뀌지 않습니다.
        ///
        /// - Parameters:
        ///   - filter: 적용할 필터입니다.
        ///   - identifier: 필터를 구분하는 문자열입니다. 필터 값이 달라지면 이 값도 바꿔 주세요.
        public init(_ filter: CIFilter, identifier: String) {
            self.filter = .custom(filter)
            self.identifier = identifier
        }

        /// 필터를 적용합니다. 실패하면 `nil`입니다.
        public func process(_ image: UIImage) -> UIImage? {
            try? apply(to: image)
        }

        /// 필터를 적용합니다. 실패하면 이유를 담은 ``Error``를 일으킵니다.
        public func process(_ content: ImageContent, context: ImageFilterContext) throws -> ImageContent {
            try content.map(apply(to:))
        }

        private func apply(to image: UIImage) throws -> UIImage {
            switch filter {
            case .named(let name, let parameters):
                guard let instance = CIFilter(name: name, parameters: parameters) else {
                    throw Error.failedToCreateFilter(name: name, parameters: parameters)
                }
                return try Self.render(instance, image: image)
            case .custom(let filter):
                return try Self.apply(filter: filter, to: image)
            }
        }

        /// 모든 Core Image 필터가 함께 쓰는 `CIContext`입니다. 처음 쓸 때 낮은 우선순위로 만듭니다.
        public static var context: CIContext {
            get {
                if let existing = sharedContext.value {
                    return existing
                }
                let created = CIContext(options: [.priorityRequestLow: true])
                return sharedContext.withLock { stored in
                    if let stored {
                        return stored
                    }
                    stored = created
                    return created
                }
            }
            set {
                sharedContext.withLock { $0 = newValue }
            }
        }

        private static let sharedContext = LockIsolated<CIContext?>(nil)

        /// `CIFilter`를 복사해 이미지에 적용합니다. 원래 필터는 바뀌지 않습니다.
        ///
        /// - Throws: 입력 이미지가 비었거나 필터가 결과를 만들지 못하면 ``Error``를 일으킵니다.
        public static func apply(filter: CIFilter, to image: UIImage) throws -> UIImage {
            let copy = (filter.copy() as? CIFilter) ?? filter
            return try render(copy, image: image)
        }

        private static func render(_ filter: CIFilter, image: UIImage) throws -> UIImage {
            let input: CIImage
            if let ciImage = image.ciImage {
                input = ciImage
            } else if let cgImage = image.cgImage {
                input = CIImage(cgImage: cgImage)
            } else {
                throw Error.inputImageIsEmpty(inputImage: image)
            }
            filter.setValue(input, forKey: kCIInputImageKey)
            guard let output = filter.outputImage else {
                throw Error.failedToApplyFilter(filter: filter)
            }
            guard let rendered = context.createCGImage(output, from: output.extent) else {
                throw Error.failedToCreateOutputCGImage(image: output)
            }
            return ProcessingCanvas.image(rendered, like: image)
        }

        public var description: String {
            switch filter {
            case .named(let name, let parameters):
                "CoreImageFilter(name: \(name), parameters: \(parameters))"
            case .custom(let filter):
                "CoreImageFilter(filter: \(filter))"
            }
        }

        /// Core Image 필터를 적용하지 못한 이유입니다.
        public enum Error: Swift.Error, CustomStringConvertible, @unchecked Sendable {
            /// 이름이나 파라미터가 잘못돼 `CIFilter`를 만들지 못했습니다.
            case failedToCreateFilter(name: String, parameters: [String: Any])
            /// 입력 이미지에 `CGImage`와 `CIImage`가 모두 없습니다.
            case inputImageIsEmpty(inputImage: UIImage)
            /// 필터가 결과 이미지를 만들지 않았습니다.
            case failedToApplyFilter(filter: CIFilter)
            /// 결과를 `CGImage`로 그리지 못했습니다. 결과 영역이 무한대인 필터에서 생길 수 있습니다.
            case failedToCreateOutputCGImage(image: CIImage)

            public var description: String {
                switch self {
                case .failedToCreateFilter(let name, let parameters):
                    "CIFilter \(name) could not be created with parameters \(parameters)"
                case .inputImageIsEmpty(let inputImage):
                    "No CIImage or CGImage backs \(inputImage)"
                case .failedToApplyFilter(let filter):
                    "CIFilter \(filter.name) produced no output image"
                case .failedToCreateOutputCGImage(let image):
                    "CIContext could not render \(image) in extent \(image.extent)"
                }
            }
        }
    }
}

extension ImageFilter where Self == ImageFilters.CoreImageFilter {
    /// 이름과 파라미터로 ``ImageFilters/CoreImageFilter``를 만듭니다.
    public static func coreImageFilter(name: String, parameters: [String: Any], identifier: String) -> ImageFilters.CoreImageFilter {
        ImageFilters.CoreImageFilter(name: name, parameters: parameters, identifier: identifier)
    }

    /// 기본 파라미터로 ``ImageFilters/CoreImageFilter``를 만듭니다.
    public static func coreImageFilter(name: String) -> ImageFilters.CoreImageFilter {
        ImageFilters.CoreImageFilter(name: name)
    }

    /// 값을 정해 둔 `CIFilter`로 ``ImageFilters/CoreImageFilter``를 만듭니다.
    public static func coreImageFilter(_ filter: CIFilter, identifier: String) -> ImageFilters.CoreImageFilter {
        ImageFilters.CoreImageFilter(filter, identifier: identifier)
    }
}
