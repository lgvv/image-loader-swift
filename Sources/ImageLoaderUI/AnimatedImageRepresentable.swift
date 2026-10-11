import Foundation
import SwiftUI
import UIKit

/// SwiftUI에서 애니메이션 이미지를 재생하는 뷰입니다. 안에서 ``AnimatedImageView``를 씁니다.
///
/// 주소나 요청을 넘기면 직접 불러오고, 이미 받은 ``ImageContent``를 넘기면 그대로 재생합니다.
/// 같은 이미지로 뷰를 다시 그리면 처음부터 다시 불러오지 않습니다. 뷰가 사라지면 요청을 취소합니다.
@MainActor
public struct AnimatedImageRepresentable: UIViewRepresentable {
    enum Payload {
        case request(ImageRequest?, session: ImageSession?)
        case content(ImageContent)
    }

    enum Identity: Equatable {
        case missingRequest
        case request(session: ImageSession, key: MemoryCacheKey)
        case content(AnyObject)

        static func == (lhs: Identity, rhs: Identity) -> Bool {
            switch (lhs, rhs) {
            case (.missingRequest, .missingRequest):
                true
            case (.request(let lhsSession, let lhsKey), .request(let rhsSession, let rhsKey)):
                lhsSession === rhsSession && lhsKey == rhsKey
            case (.content(let lhsObject), .content(let rhsObject)):
                lhsObject === rhsObject
            default:
                false
            }
        }
    }

    let payload: Payload
    /// 재생할지 정합니다. `false`면 첫 프레임에 머뭅니다.
    public var isAnimating: Bool
    /// 파일에 적힌 반복 횟수 대신 쓸 횟수입니다. 0이면 계속 반복합니다.
    public var loopCountOverride: Int?
    /// 이미지를 뷰 크기에 맞추는 방식입니다.
    public var contentMode: UIView.ContentMode

    /// 주소의 이미지를 불러와 재생합니다.
    ///
    /// - Parameters:
    ///   - url: 불러올 이미지의 주소입니다.
    ///   - session: 이미지를 불러올 세션입니다. `nil`이면 ``ImageSession/shared``를 씁니다.
    ///   - isAnimating: 재생할지 정합니다. `false`면 첫 프레임에 머뭅니다.
    ///   - loopCountOverride: 파일에 적힌 반복 횟수 대신 쓸 횟수입니다. `nil`이면 파일의 값을 따릅니다.
    ///   - contentMode: 이미지를 뷰 크기에 맞추는 방식입니다. 기본값은 `.scaleAspectFit`입니다.
    public init(
        url: URL?,
        session: ImageSession? = nil,
        isAnimating: Bool = true,
        loopCountOverride: Int? = nil,
        contentMode: UIView.ContentMode = .scaleAspectFit
    ) {
        self.init(
            request: url.map { ImageRequest(url: $0) },
            session: session,
            isAnimating: isAnimating,
            loopCountOverride: loopCountOverride,
            contentMode: contentMode
        )
    }

    /// 요청한 이미지를 불러와 재생합니다.
    ///
    /// - Parameters:
    ///   - request: 주소와 필터, 캐시 옵션을 담습니다.
    ///   - session: 이미지를 불러올 세션입니다. `nil`이면 ``ImageSession/shared``를 씁니다.
    ///   - isAnimating: 재생할지 정합니다. `false`면 첫 프레임에 머뭅니다.
    ///   - loopCountOverride: 파일에 적힌 반복 횟수 대신 쓸 횟수입니다. `nil`이면 파일의 값을 따릅니다.
    ///   - contentMode: 이미지를 뷰 크기에 맞추는 방식입니다. 기본값은 `.scaleAspectFit`입니다.
    public init(
        request: ImageRequest?,
        session: ImageSession? = nil,
        isAnimating: Bool = true,
        loopCountOverride: Int? = nil,
        contentMode: UIView.ContentMode = .scaleAspectFit
    ) {
        payload = .request(request, session: session)
        self.isAnimating = isAnimating
        self.loopCountOverride = loopCountOverride
        self.contentMode = contentMode
    }

    /// 이미 받은 이미지를 재생합니다. ``CachedAsyncImagePhase/animatedImage``가 이 초기화 메서드를 씁니다.
    ///
    /// - Parameters:
    ///   - content: 재생할 이미지입니다. 정지 이미지면 그대로 보여 줍니다.
    ///   - isAnimating: 재생할지 정합니다. `false`면 첫 프레임에 머뭅니다.
    ///   - loopCountOverride: 파일에 적힌 반복 횟수 대신 쓸 횟수입니다. `nil`이면 파일의 값을 따릅니다.
    ///   - contentMode: 이미지를 뷰 크기에 맞추는 방식입니다. 기본값은 `.scaleAspectFit`입니다.
    public init(
        _ content: ImageContent,
        isAnimating: Bool = true,
        loopCountOverride: Int? = nil,
        contentMode: UIView.ContentMode = .scaleAspectFit
    ) {
        payload = .content(content)
        self.isAnimating = isAnimating
        self.loopCountOverride = loopCountOverride
        self.contentMode = contentMode
    }

    var identity: Identity {
        switch payload {
        case .request(let request, let session):
            guard let request else {
                return .missingRequest
            }
            let resolved = session ?? ImageSession.shared
            return .request(session: resolved, key: resolved.cache.makeMemoryCacheKey(for: request))
        case .content(let content):
            return .content(content.animatedImageSource ?? content.image)
        }
    }

    /// 마지막으로 불러온 이미지를 기억하는 코디네이터를 만듭니다.
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// AnimatedImageView를 만들고 이미지를 불러옵니다.
    public func makeUIView(context: Context) -> AnimatedImageView {
        let view = AnimatedImageView()
        view.clipsToBounds = true
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            view.setContentHuggingPriority(.defaultLow, for: axis)
            view.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        context.coordinator.apply(self, to: view)
        return view
    }

    /// 설정을 반영합니다. 이미지가 바뀌었을 때만 다시 불러옵니다.
    public func updateUIView(_ view: AnimatedImageView, context: Context) {
        context.coordinator.apply(self, to: view)
    }

    /// 끝나지 않은 요청을 취소합니다.
    public static func dismantleUIView(_ view: AnimatedImageView, coordinator: Coordinator) {
        coordinator.dismantle(view)
    }

    /// 같은 이미지를 다시 불러오지 않도록 마지막으로 불러온 이미지를 기억합니다.
    @MainActor
    public final class Coordinator {
        private var lastIdentity: Identity?
        private(set) var loadCount = 0

        init() {}

        func apply(_ representable: AnimatedImageRepresentable, to view: AnimatedImageView) {
            if view.contentMode != representable.contentMode {
                view.contentMode = representable.contentMode
            }
            view.loopCountOverride = representable.loopCountOverride
            view.autoPlayAnimatedImage = representable.isAnimating
            let identity = representable.identity
            guard identity != lastIdentity else {
                return
            }
            lastIdentity = identity
            loadCount += 1
            switch representable.payload {
            case .request(let request, let session):
                var options = ImageLoadingOptions()
                options.session = session
                loadImage(with: request, options: options, into: view)
            case .content(let content):
                cancelRequest(for: view)
                ImageViewController.show(content, in: view)
            }
        }

        func dismantle(_ view: AnimatedImageView) {
            cancelRequest(for: view)
            lastIdentity = nil
        }
    }
}
