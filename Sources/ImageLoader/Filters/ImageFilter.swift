import CoreGraphics
import Foundation
import UIKit

/// 디코딩한 이미지를 바꾸는 필터가 따르는 프로토콜입니다.
///
/// 필터는 ``ImageSession/Configuration/imageFilteringQueue``에서 적용하고, 결과는 캐시에 저장합니다. 같은 요청을 다시 하면 필터를 다시 적용하지 않습니다.
/// 필터를 적용하면 애니메이션 이미지는 첫 프레임만 남은 정지 이미지가 됩니다.
///
/// ```swift
/// struct FlipFilter: ImageFilter {
///     var identifier: String { "com.example/flip" }
///
///     func process(_ image: UIImage) -> UIImage? {
///         image.withHorizontallyFlippedOrientation()
///     }
/// }
/// ```
public protocol ImageFilter: Sendable {
    /// 이미지를 바꿉니다. 바꾸지 못하면 `nil`을 돌려주고, 요청은 ``ImageSession/Error/processingFailed(filter:context:error:)``로 끝납니다.
    func process(_ image: UIImage) -> UIImage?

    /// 이미지와 그 정보를 바꿉니다. 요청이나 서버 응답을 보고 다르게 바꿔야 할 때 구현합니다.
    ///
    /// 다운로드 도중의 미리보기에도 부르므로, ``ImageFilterContext/isCompleted``로 구분할 수 있습니다.
    func process(_ content: ImageContent, context: ImageFilterContext) throws -> ImageContent

    /// 필터를 구분하는 문자열입니다. 디스크 캐시 키에 들어갑니다.
    ///
    /// 필터 종류와 설정값이 같으면 같은 문자열을, 다르면 다른 문자열을 돌려주세요. 설정값이 바뀌어도 같은 문자열을 돌려주면 이전 결과를 캐시에서 잘못 꺼냅니다.
    /// 라이브러리 필터는 `imageloader/`로 시작하니 다른 접두어를 써 주세요.
    var identifier: String { get }

    /// 메모리 캐시 키에 쓰는 값입니다. 필터가 `Hashable`이면 필터 자신을, 아니면 ``identifier``를 씁니다.
    var hashableIdentifier: AnyHashable { get }
}

extension ImageFilter {
    /// 기본 구현은 ``process(_:)``를 부르고, `nil`이면 ``ImageFilterError/unknown`` 오류를 일으킵니다.
    public func process(_ content: ImageContent, context: ImageFilterContext) throws -> ImageContent {
        guard let output = process(content.image) else {
            throw ImageFilterError.unknown
        }
        var content = content
        content.image = output
        return content
    }

    /// 기본 구현은 ``identifier``를 돌려줍니다.
    public var hashableIdentifier: AnyHashable {
        identifier
    }
}

extension ImageFilter where Self: Hashable {
    /// 필터가 `Hashable`이면 필터 자신을 돌려줍니다. 문자열을 만들지 않아 메모리 캐시 조회가 빠릅니다.
    public var hashableIdentifier: AnyHashable {
        self
    }
}

/// 필터를 적용할 때 쓰는 정보입니다.
public struct ImageFilterContext: Sendable {
    /// 필터를 적용할 이미지를 요청한 요청입니다.
    public var request: ImageRequest
    /// 필터를 적용하기 전의 결과입니다. 서버 응답과 캐시 출처를 여기서 읽습니다.
    public var response: ImageResponse
    /// 최종 이미지면 `true`, 다운로드 도중의 미리보기면 `false`입니다.
    public var isCompleted: Bool

    /// 필터 정보를 만듭니다. 테스트에서 필터를 직접 부를 때 씁니다.
    public init(request: ImageRequest, response: ImageResponse, isCompleted: Bool) {
        self.request = request
        self.response = response
        self.isCompleted = isCompleted
    }
}

/// 필터가 이유를 밝히지 않고 실패했을 때의 오류입니다.
public enum ImageFilterError: Error, CustomStringConvertible, Sendable {
    /// ``ImageFilter/process(_:)``가 `nil`을 돌려줬습니다.
    case unknown

    public var description: String {
        "Unknown"
    }
}

/// 필터 설정에 쓰는 값 모음입니다.
public enum ImageFilterOptions: Sendable {
    /// 크기 값의 단위입니다.
    @frozen public enum Unit: CustomStringConvertible, Sendable {
        /// 포인트입니다. 화면 배율을 곱해 픽셀로 바꿉니다. 3배율 기기에서 100포인트는 300픽셀입니다.
        case points
        /// 픽셀입니다. 값을 그대로 씁니다.
        case pixels

        public var description: String {
            switch self {
            case .points: "points"
            case .pixels: "pixels"
            }
        }
    }

    /// 원본 비율을 지키면서 크기를 맞추는 방식입니다.
    @frozen public enum ContentMode: CustomStringConvertible, Sendable {
        /// 영역을 빈틈없이 채웁니다. 한쪽이 영역보다 클 수 있습니다.
        case aspectFill
        /// 영역 안에 이미지 전체가 들어가게 맞춥니다. 한쪽이 영역보다 작을 수 있습니다.
        case aspectFit

        public var description: String {
            switch self {
            case .aspectFill: "aspectFill"
            case .aspectFit: "aspectFit"
            }
        }
    }

    /// 원 모양과 둥근 모서리 필터에 그릴 테두리입니다.
    public struct Border: Hashable, CustomStringConvertible, Sendable {
        /// 테두리 색입니다.
        public let color: UIColor
        /// 테두리 두께입니다. 단위는 픽셀입니다.
        public let width: CGFloat

        /// 테두리를 만듭니다.
        ///
        /// - Parameters:
        ///   - color: 테두리 색입니다.
        ///   - width: 테두리 두께입니다. 기본값은 1입니다.
        ///   - unit: `.points`면 화면 배율을 곱해 픽셀로 바꿉니다.
        public init(color: UIColor, width: CGFloat = 1, unit: Unit = .points) {
            self.color = color
            self.width = unit == .points ? width * Screen.scale : width
        }

        public var description: String {
            "Border(color: \(color.rgbHexString ?? String(describing: color)), width: \(width) pixels)"
        }
    }
}

extension [any ImageFilter] {
    func isEquivalent(to other: [any ImageFilter]) -> Bool {
        count == other.count && zip(self, other).allSatisfy { $0.hashableIdentifier == $1.hashableIdentifier }
    }
}

extension UIColor {
    var rgbHexString: String? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        let components = alpha < 1 ? [red, green, blue, alpha] : [red, green, blue]
        let bytes = components.map { component in
            Int((Float(min(max(component, 0), 1)) * 255).rounded())
        }
        return bytes.reduce(into: "#") { text, byte in
            text += String(format: "%02X", byte)
        }
    }
}
