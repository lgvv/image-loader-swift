import Foundation
import UIKit

/// ``loadImage(with:options:into:completion:)-(URL?,_,_,_)``로 이미지를 보여 줄 때의 플레이스홀더, 실패 이미지, 전환 효과입니다.
///
/// ```swift
/// var options = ImageLoadingOptions(
///     placeholder: UIImage(named: "placeholder"),
///     transition: .fadeIn(duration: 0.25)
/// )
/// options.failureImage = UIImage(named: "broken")
/// loadImage(with: url, options: options, into: imageView)
/// ```
public struct ImageLoadingOptions {
    /// `options`를 넘기지 않았을 때 쓰는 기본값입니다. 앱 전체의 기본 설정을 바꿀 때 고칩니다.
    @MainActor public static var shared = ImageLoadingOptions()

    /// 불러오는 동안 보여 줄 이미지입니다. 메모리 캐시에 이미지가 있으면 보여 주지 않습니다.
    public var placeholder: UIImage?

    /// 불러오지 못했을 때 보여 줄 이미지입니다. `nil`이면 실패해도 뷰를 바꾸지 않습니다.
    public var failureImage: UIImage?

    /// 불러온 이미지를 보여 줄 때의 전환 효과입니다. 메모리 캐시에서 바로 보여 줄 때는 쓰지 않습니다.
    public var transition: Transition?

    /// ``failureImage``를 보여 줄 때의 전환 효과입니다.
    public var failureImageTransition: Transition?

    /// 메모리 캐시에서 바로 보여 줄 때도 전환 효과를 쓸지 정합니다. 기본값은 `false`입니다.
    public var alwaysTransition = false

    /// 새로 불러오기 시작할 때 뷰를 비울지 정합니다. 기본값은 `true`입니다.
    ///
    /// 켜 두면 재생 중인 전환 애니메이션을 멈추고, ``placeholder``가 없으면 이전 이미지를 지웁니다. 재사용한 셀에 이전 이미지가 잠깐 보이는 일을 막습니다.
    public var isPrepareForReuseEnabled = true

    /// 다운로드 도중의 미리보기를 뷰에 보여 줄지 정합니다. 기본값은 `true`입니다.
    ///
    /// 세션의 ``ImageSession/Configuration/isProgressiveDecodingEnabled``를 켰을 때만 미리보기가 만들어집니다.
    public var isProgressiveRenderingEnabled = true

    /// 이미지를 불러올 세션입니다. `nil`이면 ``ImageSession/shared``를 씁니다.
    public var session: ImageSession?

    /// 요청에 필터가 없을 때 적용할 필터입니다. 요청에 필터가 있으면 요청의 필터를 씁니다.
    public var filters: [any ImageFilter] = []

    /// 성공, 실패, 플레이스홀더마다 다르게 쓸 `contentMode`입니다. `nil`이면 뷰의 `contentMode`를 바꾸지 않습니다.
    public var contentModes: ContentModes?

    /// 성공, 실패, 플레이스홀더마다 다르게 쓸 틴트 색입니다. 색을 정하면 이미지를 템플릿 이미지로 바꿔 그 색으로 칠합니다.
    public var tintColors: TintColors?

    /// 기본값으로 만듭니다.
    public init() {}

    /// 자주 바꾸는 값을 정해 만듭니다. 각 값의 뜻은 같은 이름의 프로퍼티를 확인해 주세요.
    public init(
        placeholder: UIImage? = nil,
        transition: Transition? = nil,
        failureImage: UIImage? = nil,
        failureImageTransition: Transition? = nil,
        contentModes: ContentModes? = nil,
        tintColors: TintColors? = nil
    ) {
        self.placeholder = placeholder
        self.transition = transition
        self.failureImage = failureImage
        self.failureImageTransition = failureImageTransition
        self.contentModes = contentModes
        self.tintColors = tintColors
    }

    /// 결과마다 쓸 `contentMode`입니다.
    public struct ContentModes {
        /// 불러온 이미지를 보여 줄 때의 `contentMode`입니다.
        public var success: UIView.ContentMode
        /// 실패 이미지를 보여 줄 때의 `contentMode`입니다.
        public var failure: UIView.ContentMode
        /// 플레이스홀더를 보여 줄 때의 `contentMode`입니다.
        public var placeholder: UIView.ContentMode

        /// 결과마다 쓸 `contentMode`를 정합니다.
        public init(success: UIView.ContentMode, failure: UIView.ContentMode, placeholder: UIView.ContentMode) {
            self.success = success
            self.failure = failure
            self.placeholder = placeholder
        }
    }

    /// 결과마다 쓸 틴트 색입니다. `nil`인 결과는 이미지를 그대로 보여 줍니다.
    public struct TintColors {
        /// 불러온 이미지에 칠할 색입니다.
        public var success: UIColor?
        /// 실패 이미지에 칠할 색입니다.
        public var failure: UIColor?
        /// 플레이스홀더에 칠할 색입니다.
        public var placeholder: UIColor?

        /// 결과마다 쓸 틴트 색을 정합니다.
        public init(success: UIColor?, failure: UIColor?, placeholder: UIColor?) {
            self.success = success
            self.failure = failure
            self.placeholder = placeholder
        }
    }

    /// 이미지를 바꿔 보여 줄 때의 전환 효과입니다.
    public struct Transition {
        enum Kind {
            case fadeIn(duration: TimeInterval, animationOptions: UIView.AnimationOptions)
            case custom((ImageDisplayingView, UIImage) -> Void)
        }

        let kind: Kind

        /// 이전 이미지에서 새 이미지로 서서히 바꿉니다.
        ///
        /// ``ImageLoadingOptions/contentModes``로 `contentMode`가 바뀌면, 이전 이미지의 스냅숏을 겹쳐 두고 바꿔서 이전 이미지가 늘어나 보이지 않게 합니다.
        ///
        /// - Parameters:
        ///   - duration: 바뀌는 데 걸리는 초입니다.
        ///   - options: `UIView` 애니메이션 옵션입니다. 기본값은 바뀌는 동안에도 터치를 받는 `.allowUserInteraction`입니다.
        public static func fadeIn(duration: TimeInterval, options: UIView.AnimationOptions = .allowUserInteraction) -> Transition {
            Transition(kind: .fadeIn(duration: duration, animationOptions: options))
        }

        /// 전환 효과를 직접 정합니다. 클로저가 뷰에 이미지를 넣는 일까지 맡습니다.
        public static func custom(_ closure: @escaping (ImageDisplayingView, UIImage) -> Void) -> Transition {
            Transition(kind: .custom(closure))
        }
    }
}

extension ImageLoadingOptions {
    enum Outcome {
        case success
        case failure
        case placeholder
    }

    struct Presentation {
        var transition: Transition?
        var contentMode: UIView.ContentMode?
        var tintColor: UIColor?
    }

    func presentation(for outcome: Outcome) -> Presentation {
        switch outcome {
        case .success:
            Presentation(transition: transition, contentMode: contentModes?.success, tintColor: tintColors?.success)
        case .failure:
            Presentation(transition: failureImageTransition, contentMode: contentModes?.failure, tintColor: tintColors?.failure)
        case .placeholder:
            Presentation(transition: nil, contentMode: contentModes?.placeholder, tintColor: tintColors?.placeholder)
        }
    }
}
