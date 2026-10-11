import Foundation
import SwiftUI

/// ``ImageSession``의 캐시를 쓰는 SwiftUI 이미지 뷰입니다.
///
/// SwiftUI의 `AsyncImage`와 쓰는 법이 비슷합니다. 메모리 캐시에 이미지가 있으면 네트워크를 기다리지 않고 바로 보여 줍니다.
/// 기본으로 뷰가 화면에서 사라지면 요청을 취소합니다.
///
/// ```swift
/// CachedAsyncImage(url: url) { phase in
///     if let image = phase.image {
///         image.resizable().scaledToFill()
///     } else if phase.error != nil {
///         Image(systemName: "exclamationmark.triangle")
///     } else {
///         ProgressView()
///     }
/// }
/// .filters([.resize(width: 120)])
/// ```
@MainActor
public struct CachedAsyncImage<Content: View>: View {
    @StateObject private var model = AsyncImageModel()

    private var context: CachedAsyncImageContext?
    private var makeContent: ((CachedAsyncImagePhase) -> Content)?
    private var transaction: Transaction
    private var session: ImageSession = .shared
    private var onStart: (@MainActor @Sendable (ImageTask) -> Void)?
    private var onDisappearBehavior: DisappearBehavior? = .cancel
    private var onCompletion: (@MainActor @Sendable (Result<ImageResponse, Error>) -> Void)?

    /// 주소의 이미지를 원래 크기로 보여 줍니다.
    ///
    /// 불러오는 동안과 실패했을 때는 `secondarySystemBackground` 색을 채웁니다. 크기를 맞추려면 `content`를 받는 초기화 메서드를 써 주세요.
    ///
    /// - Parameter url: 불러올 이미지의 주소입니다. `nil`이면 ``ImageSession/Error/imageRequestMissing``으로 끝납니다.
    public init(url: URL?) where Content == Image {
        self.init(request: url.map { ImageRequest(url: $0) })
    }

    /// 요청한 이미지를 원래 크기로 보여 줍니다.
    ///
    /// 불러오는 동안과 실패했을 때는 `secondarySystemBackground` 색을 채웁니다. 크기를 맞추려면 `content`를 받는 초기화 메서드를 써 주세요.
    ///
    /// 주소, 우선순위, 옵션, 필터 중 하나가 바뀌면 다시 불러옵니다. ``ImageRequest/scale``이나 ``ImageRequest/thumbnail``만 바꿔서는 다시 불러오지 않습니다.
    ///
    /// - Parameter request: 주소와 필터, 캐시 옵션을 담습니다. `nil`이면 ``ImageSession/Error/imageRequestMissing``으로 끝납니다.
    public init(request: ImageRequest?) where Content == Image {
        context = request.map { CachedAsyncImageContext(request: $0) }
        transaction = Transaction(animation: nil)
    }

    /// 주소의 이미지를 불러오고, 단계마다 보여 줄 뷰를 직접 정합니다.
    ///
    /// - Parameters:
    ///   - url: 불러올 이미지의 주소입니다. `nil`이면 ``ImageSession/Error/imageRequestMissing``으로 끝납니다.
    ///   - transaction: 이미지가 바뀔 때 쓸 애니메이션입니다. 기본값은 애니메이션 없음입니다.
    ///   - content: 불러오는 중, 성공, 실패 단계를 받아 보여 줄 뷰를 만듭니다. 단계가 바뀔 때마다 다시 부릅니다.
    public init(
        url: URL?,
        transaction: Transaction = Transaction(animation: nil),
        @ViewBuilder content: @escaping (CachedAsyncImagePhase) -> Content
    ) {
        self.init(request: url.map { ImageRequest(url: $0) }, transaction: transaction, content: content)
    }

    /// 요청한 이미지를 불러오고, 단계마다 보여 줄 뷰를 직접 정합니다.
    ///
    /// 주소, 우선순위, 옵션, 필터 중 하나가 바뀌면 다시 불러옵니다. ``ImageRequest/scale``이나 ``ImageRequest/thumbnail``만 바꿔서는 다시 불러오지 않습니다.
    ///
    /// - Parameters:
    ///   - request: 주소와 필터, 캐시 옵션을 담습니다. `nil`이면 ``ImageSession/Error/imageRequestMissing``으로 끝납니다.
    ///   - transaction: 이미지가 바뀔 때 쓸 애니메이션입니다. 기본값은 애니메이션 없음입니다.
    ///   - content: 불러오는 중, 성공, 실패 단계를 받아 보여 줄 뷰를 만듭니다. 단계가 바뀔 때마다 다시 부릅니다.
    public init(
        request: ImageRequest?,
        transaction: Transaction = Transaction(animation: nil),
        @ViewBuilder content: @escaping (CachedAsyncImagePhase) -> Content
    ) {
        context = request.map { CachedAsyncImageContext(request: $0) }
        self.transaction = transaction
        makeContent = content
    }

    /// 뷰가 화면에서 사라질 때 아직 끝나지 않은 요청을 어떻게 할지 정합니다.
    @frozen public enum DisappearBehavior {
        /// 요청을 취소합니다. 다시 나타나면 처음부터 불러오고, 그사이 캐시에 저장됐으면 캐시에서 읽습니다.
        case cancel
        /// 요청은 이어 가고 우선순위를 ``ImageRequest/Priority/veryLow``로 낮춥니다. 빠르게 스크롤하는 목록에서 다시 돌아올 가능성이 높을 때 씁니다.
        case lowerPriority
    }

    /// 요청에 적용할 필터를 바꿉니다. `nil`을 넣으면 필터를 모두 뺍니다.
    public consuming func filters(_ filters: [any ImageFilter]?) -> Self {
        modified { $0.context?.request.filters = filters ?? [] }
    }

    /// 요청의 우선순위를 바꿉니다. `nil`을 넣으면 ``ImageRequest/Priority/normal``이 됩니다.
    public consuming func priority(_ priority: ImageRequest.Priority?) -> Self {
        modified { $0.context?.request.priority = priority ?? .normal }
    }

    /// 이미지를 불러올 세션을 정합니다. 기본값은 ``ImageSession/shared``입니다.
    public consuming func session(_ session: ImageSession) -> Self {
        modified { $0.session = session }
    }

    /// 네트워크나 디스크에서 불러오기 시작할 때 작업을 넘겨받습니다. 메모리 캐시에서 바로 보여 주면 부르지 않습니다.
    public consuming func onStart(_ closure: @escaping @MainActor @Sendable (ImageTask) -> Void) -> Self {
        modified { $0.onStart = closure }
    }

    /// 뷰가 화면에서 사라질 때 요청을 어떻게 할지 정합니다. 기본값은 ``DisappearBehavior/cancel``이고, `nil`이면 아무것도 바꾸지 않습니다.
    public consuming func onDisappear(_ behavior: DisappearBehavior?) -> Self {
        modified { $0.onDisappearBehavior = behavior }
    }

    /// 이미지를 받았거나 실패했을 때 메인 스레드에서 결과를 받습니다. 취소된 요청에서는 부르지 않습니다.
    public consuming func onCompletion(_ closure: @escaping @MainActor @Sendable (Result<ImageResponse, Error>) -> Void) -> Self {
        modified { $0.onCompletion = closure }
    }

    public var body: some View {
        ZStack {
            if let makeContent {
                makeContent(model)
            } else {
                defaultContent(for: model)
            }
        }
        .onAppear { appear() }
        .onDisappear { disappear() }
        .onChange(of: context) { newContext in
            model.load(newContext?.request)
        }
    }

    private consuming func modified(_ change: (inout CachedAsyncImage) -> Void) -> Self {
        var copy = self
        change(&copy)
        return copy
    }

    @ViewBuilder
    private func defaultContent(for state: CachedAsyncImagePhase) -> some View {
        if let image = state.image {
            image
        } else {
            Color(.secondarySystemBackground)
        }
    }

    private func appear() {
        model.transaction = transaction
        model.session = session
        model.onStart = onStart
        model.onCompletion = onCompletion
        model.priority = nil
        model.load(context?.request)
    }

    private func disappear() {
        switch onDisappearBehavior {
        case .cancel:
            model.cancel()
        case .lowerPriority:
            model.priority = .veryLow
        case nil:
            break
        }
    }
}

private struct CachedAsyncImageContext: Equatable {
    var request: ImageRequest

    static func == (lhs: CachedAsyncImageContext, rhs: CachedAsyncImageContext) -> Bool {
        lhs.request.imageID == rhs.request.imageID
            && lhs.request.priority == rhs.request.priority
            && lhs.request.options == rhs.request.options
            && lhs.request.filters.map(\.hashableIdentifier) == rhs.request.filters.map(\.hashableIdentifier)
    }
}
