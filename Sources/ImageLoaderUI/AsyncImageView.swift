import Foundation
import UIKit

/// ``url``이나 ``request``를 넣으면 이미지를 불러와 보여 주는 UIKit 뷰입니다.
///
/// 불러오는 동안 플레이스홀더를, 실패하면 실패 뷰를 보여 줍니다. 애니메이션 이미지는 ``AnimatedImageView``로 재생합니다.
/// 기본 플레이스홀더는 `secondarySystemBackground` 색 뷰이고, 기본 전환 효과는 0.33초 페이드인입니다.
///
/// ```swift
/// let imageView = AsyncImageView()
/// imageView.filters = [.resize(width: 80)]
/// imageView.url = url
/// ```
@MainActor
public final class AsyncImageView: UIView {
    /// 불러오는 동안 보여 줄 이미지입니다. 넣으면 그 이미지를 담은 `UIImageView`로 ``placeholderView``를 바꿉니다.
    public var placeholderImage: UIImage? {
        didSet {
            setPlaceholderImage(placeholderImage)
        }
    }

    /// 불러오는 동안 보여 줄 뷰입니다. `nil`이면 플레이스홀더를 보여 주지 않습니다.
    public var placeholderView: UIView? {
        didSet {
            replacePlaceholderView(oldValue, with: placeholderView)
        }
    }

    /// ``placeholderView``의 배치입니다. 기본값은 ``SubviewPosition/fill``입니다.
    public var placeholderViewPosition: SubviewPosition = .fill {
        didSet {
            guard oldValue != placeholderViewPosition, placeholderView != nil else {
                return
            }
            setNeedsUpdateConstraints()
        }
    }

    /// 실패했을 때 실패 뷰 대신 플레이스홀더를 보여 줄지 정합니다. 기본값은 `false`입니다.
    public var showPlaceholderOnFailure = false

    /// 실패했을 때 보여 줄 이미지입니다. 넣으면 그 이미지를 담은 `UIImageView`로 ``failureView``를 바꿉니다.
    public var failureImage: UIImage? {
        didSet {
            setFailureImage(failureImage)
        }
    }

    /// 실패했을 때 보여 줄 뷰입니다. `nil`이면 실패해도 아무것도 보여 주지 않습니다.
    public var failureView: UIView? {
        didSet {
            replaceFailureView(oldValue, with: failureView)
        }
    }

    /// ``failureView``의 배치입니다. 기본값은 ``SubviewPosition/fill``입니다.
    public var failureViewPosition: SubviewPosition = .fill {
        didSet {
            guard oldValue != failureViewPosition, failureView != nil else {
                return
            }
            setNeedsUpdateConstraints()
        }
    }

    /// 네트워크나 디스크에서 불러온 이미지를 보여 줄 때의 전환 효과입니다. 메모리 캐시에서 바로 보여 줄 때는 쓰지 않습니다.
    public var transition: Transition?

    /// 이미지를 보여 줄 때의 전환 효과입니다.
    @frozen public enum Transition {
        /// 투명한 상태에서 `duration`초 동안 서서히 나타납니다.
        case fadeIn(duration: TimeInterval)
        /// 전환 효과를 직접 정합니다. 이미지는 이미 뷰에 들어간 상태로 클로저를 부릅니다.
        case custom(closure: (AsyncImageView, ImageContent) -> Void)
    }

    /// 플레이스홀더와 실패 뷰의 배치입니다.
    @frozen public enum SubviewPosition {
        /// 원래 크기로 가운데에 둡니다.
        case center
        /// 뷰 전체를 채웁니다.
        case fill
    }

    /// 이미지를 보여 주는 뷰입니다. `contentMode`나 `clipsToBounds`를 바꿀 때 씁니다.
    public var imageView: UIImageView {
        animatedImageView
    }

    /// 이미지마다 보여 줄 뷰를 직접 만듭니다. `nil`을 돌려주면 ``imageView``로 보여 줍니다.
    ///
    /// 동영상처럼 `UIImageView`로 보여 줄 수 없는 형식을 다룰 때 씁니다.
    public var makeImageView: ((ImageContent) -> UIView?)?

    /// 요청에 필터가 없을 때 적용할 필터입니다. ``url``이나 ``request``보다 먼저 넣어 주세요.
    public var filters: [any ImageFilter]?

    /// 요청의 우선순위를 덮어씁니다. 바꾸면 끝나지 않은 요청에도 적용합니다. `nil`이면 요청의 우선순위를 그대로 씁니다.
    public var priority: ImageRequest.Priority? {
        didSet {
            guard let priority else {
                return
            }
            imageTask?.priority = priority
        }
    }

    /// 끝나지 않은 작업입니다. 끝났거나 메모리 캐시에서 바로 보여 줬으면 `nil`입니다.
    public var imageTask: ImageTask?

    /// 이미지를 불러올 세션입니다.
    public var session: ImageSession = .shared

    /// 네트워크나 디스크에서 불러오기 시작할 때 작업을 넘겨받습니다.
    public var onStart: (@MainActor @Sendable (ImageTask) -> Void)?

    /// 다운로드 도중에 미리보기를 받을 때마다 부릅니다.
    public var onPreview: (@MainActor @Sendable (ImageResponse) -> Void)?

    /// 데이터를 받을 때마다 진행률을 넘겨 부릅니다.
    public var onProgress: (@MainActor @Sendable (ImageTask.Progress) -> Void)?

    /// 이미지를 보여 준 뒤에 부릅니다.
    public var onSuccess: (@MainActor @Sendable (ImageResponse) -> Void)?

    /// 실패 뷰를 보여 준 뒤에 부릅니다.
    public var onFailure: (@MainActor @Sendable (Error) -> Void)?

    /// 성공이나 실패 뒤에 결과를 넘겨 부릅니다. 취소한 요청에서는 부르지 않습니다.
    public var onCompletion: (@MainActor @Sendable (Result<ImageResponse, Error>) -> Void)?

    /// 다운로드 도중의 미리보기를 보여 줄지 정합니다. 기본값은 `true`입니다.
    public var isProgressiveImageRenderingEnabled = true

    /// 새로 불러오기 시작할 때 이전 이미지를 바로 지울지 정합니다. 기본값은 `true`입니다.
    ///
    /// `false`면 새 이미지가 도착할 때까지 이전 이미지를 남겨 둡니다. 같은 자리에서 이미지만 바꿀 때 깜빡임이 생기지 않습니다.
    public var isResetEnabled = true

    /// 보여 줄 이미지의 주소입니다. 넣으면 바로 불러오기 시작하고, 끝나지 않은 요청은 취소합니다.
    public var url: URL? {
        get {
            request?.url
        }
        set {
            request = newValue.map { ImageRequest(url: $0) }
        }
    }

    /// 보여 줄 이미지의 요청입니다. 넣으면 바로 불러오기 시작하고, 끝나지 않은 요청은 취소합니다.
    ///
    /// `nil`을 넣으면 이미지를 지우고 ``ImageSession/Error/imageRequestMissing``으로 끝냅니다.
    public var request: ImageRequest? {
        didSet {
            load(request)
        }
    }

    let animatedImageView = AnimatedImageView()
    var customImageView: UIView?
    private var placeholderViewConstraints: [NSLayoutConstraint] = []
    private var failureViewConstraints: [NSLayoutConstraint] = []
    private(set) var isResetNeeded = false
    private(set) var loadGeneration: UInt64 = 0

    deinit {
        imageTask?.cancel()
    }

    /// 뷰를 만듭니다.
    override public init(frame: CGRect) {
        super.init(frame: frame)
        configureSubviews()
    }

    /// 스토리보드에서 뷰를 만듭니다.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSubviews()
    }

    override public func updateConstraints() {
        super.updateConstraints()
        NSLayoutConstraint.deactivate(placeholderViewConstraints)
        placeholderViewConstraints = placeholderView?.layoutInSuperview(placeholderViewPosition) ?? []
        NSLayoutConstraint.deactivate(failureViewConstraints)
        failureViewConstraints = failureView?.layoutInSuperview(failureViewPosition) ?? []
    }

    /// 끝나지 않은 요청을 취소하고 이미지, 플레이스홀더, 실패 뷰를 모두 숨깁니다. 셀을 재사용하기 전에 불러 주세요.
    public func reset() {
        reset(clearsImage: true)
    }

    /// 끝나지 않은 요청을 취소합니다. 보여 주던 이미지는 그대로 둡니다.
    public func cancel() {
        loadGeneration &+= 1
        let task = imageTask
        imageTask = nil
        task?.cancel()
    }

    private func configureSubviews() {
        animatedImageView.isHidden = true
        addSubview(animatedImageView)
        animatedImageView.layoutInSuperview(.fill)
        let defaultPlaceholder = UIView()
        defaultPlaceholder.backgroundColor = .secondarySystemBackground
        placeholderView = defaultPlaceholder
        transition = .fadeIn(duration: 0.33)
    }

    private func load(_ request: ImageRequest?) {
        cancel()
        guard var request else {
            resetOrDefer(clearsImage: true)
            handle(.failure(ImageSession.Error.imageRequestMissing), isFromMemory: true)
            return
        }
        if let filters, !filters.isEmpty, request.filters.isEmpty {
            request.filters = filters
        }
        if let priority {
            request.priority = priority
        }
        let cached = session.cache[request]
        if let cached, !cached.isPreview {
            resetOrDefer(clearsImage: false)
            handle(.success(ImageResponse(content: cached, request: request, cacheType: .memory)), isFromMemory: true)
            return
        }
        resetOrDefer(clearsImage: true)
        if let cached {
            display(cached, isFromMemory: true)
        }
        setPlaceholderViewHidden(false)
        let started = loadGeneration
        let task = session.loadImage(
            with: request,
            progress: { [weak self] response, completed, total in
                guard let self, self.loadGeneration == started else {
                    return
                }
                if let response {
                    self.handlePreview(response)
                    self.onPreview?(response)
                } else {
                    self.onProgress?(ImageTask.Progress(completed: completed, total: total))
                }
            },
            completion: { [weak self] result in
                guard let self, self.loadGeneration == started else {
                    return
                }
                self.handle(result.mapError { $0 }, isFromMemory: false)
            }
        )
        imageTask = task
        onStart?(task)
    }

    private func handlePreview(_ response: ImageResponse) {
        guard isProgressiveImageRenderingEnabled else {
            return
        }
        setPlaceholderViewHidden(true)
        display(response.content, isFromMemory: false)
    }

    private func handle(_ result: Result<ImageResponse, Error>, isFromMemory: Bool) {
        if isResetNeeded {
            if case .success = result {
                reset(clearsImage: false)
            } else {
                reset(clearsImage: true)
            }
        }
        setPlaceholderViewHidden(true)
        switch result {
        case .success(let response):
            display(response.content, isFromMemory: isFromMemory)
        case .failure:
            if showPlaceholderOnFailure {
                setPlaceholderViewHidden(false)
            } else {
                setFailureViewHidden(false)
            }
        }
        imageTask = nil
        switch result {
        case .success(let response):
            onSuccess?(response)
        case .failure(let error):
            onFailure?(error)
        }
        onCompletion?(result)
    }

    func reset(clearsImage: Bool, cancels: Bool = true) {
        if cancels {
            cancel()
        }
        if clearsImage {
            if animatedImageView.image != nil {
                animatedImageView.image = nil
            }
            if !animatedImageView.isHidden {
                animatedImageView.isHidden = true
            }
        }
        removeCustomImageView()
        setPlaceholderViewHidden(true)
        setFailureViewHidden(true)
        isResetNeeded = false
    }

    private func resetOrDefer(clearsImage: Bool) {
        if isResetEnabled {
            reset(clearsImage: clearsImage)
        } else {
            isResetNeeded = true
        }
    }
}
