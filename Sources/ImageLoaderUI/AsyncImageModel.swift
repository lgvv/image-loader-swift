import Combine
import Foundation
import SwiftUI

/// SwiftUI에서 이미지를 불러오고 상태를 알려 주는 모델입니다. ``CachedAsyncImage``가 안에서 씁니다.
///
/// 뷰를 직접 구성하고 싶을 때 `@StateObject`로 들고 ``load(_:)-(ImageRequest?)``를 부르면 됩니다.
///
/// ```swift
/// struct Avatar: View {
///     let url: URL
///     @StateObject private var model = AsyncImageModel()
///
///     var body: some View {
///         ZStack {
///             model.image?.resizable()
///         }
///         .onAppear { model.load(url) }
///         .onDisappear { model.cancel() }
///     }
/// }
/// ```
@MainActor
public final class AsyncImageModel: ObservableObject, Identifiable {
    /// 마지막으로 끝난 요청의 결과입니다. 불러오는 중이거나 시작하기 전이면 `nil`입니다.
    @Published public private(set) var result: Result<ImageResponse, Error>?

    /// 지금 보여 줄 이미지입니다. 다운로드 도중에는 미리보기가 들어올 수 있습니다.
    @Published public private(set) var imageContent: ImageContent?

    /// 요청이 끝나지 않았으면 `true`입니다.
    @Published public private(set) var isLoading = false

    /// ``imageContent``를 SwiftUI `Image`로 바꾼 값입니다.
    public var image: Image? {
        imageContent.map { Image(uiImage: $0.image) }
    }

    /// 이미지가 바뀔 때 쓸 애니메이션입니다. 기본값은 애니메이션 없음입니다.
    public var transaction = Transaction(animation: nil)

    /// 다운로드 진행률입니다. 처음 읽을 때 만들므로, 읽지 않으면 진행률 때문에 뷰를 다시 그리지 않습니다.
    public var progress: Progress {
        if let lazyProgress {
            return lazyProgress
        }
        let created = Progress()
        lazyProgress = created
        return created
    }

    /// 다운로드 진행률입니다. 받은 바이트 수가 바뀔 때마다 뷰를 다시 그립니다.
    public final class Progress: ObservableObject {
        /// 지금까지 받은 바이트 수입니다.
        @Published public internal(set) var completed: Int64 = 0

        /// 전체 바이트 수입니다. 서버가 `Content-Length` 헤더를 보내지 않으면 0입니다.
        @Published public internal(set) var total: Int64 = 0

        /// 0부터 1 사이의 진행률입니다. ``total``이 0이면 0입니다.
        public var fraction: Float {
            total > 0 ? min(1, Float(completed) / Float(total)) : 0
        }
    }

    /// 요청의 우선순위를 덮어씁니다. 바꾸면 끝나지 않은 요청에도 적용합니다. `nil`이면 요청의 우선순위를 그대로 씁니다.
    public var priority: ImageRequest.Priority? {
        didSet {
            guard let priority else {
                return
            }
            imageTask?.priority = priority
        }
    }

    /// 이미지를 불러올 세션입니다.
    public var session: ImageSession = .shared

    /// 요청에 필터가 없을 때 적용할 필터입니다.
    public var filters: [any ImageFilter] = []

    /// 네트워크나 디스크에서 불러오기 시작할 때 작업을 넘겨받습니다. 메모리 캐시에서 바로 보여 주면 부르지 않습니다.
    public var onStart: (@MainActor @Sendable (ImageTask) -> Void)?

    /// 요청이 끝났을 때 결과를 받습니다. 취소한 요청과 ``load(_:)-(P)``로 시작한 요청에서는 부르지 않습니다.
    public var onCompletion: (@MainActor @Sendable (Result<ImageResponse, Error>) -> Void)?

    private var lazyProgress: Progress?
    private var imageTask: ImageTask?
    private var subscription: AnyCancellable?
    private var publishedResponse: ImageResponse?
    private(set) var loadGeneration: UInt64 = 0
    private(set) var actionTask: Task<Void, Never>?

    /// 모델을 만듭니다.
    public init() {}

    deinit {
        imageTask?.cancel()
    }

    /// 주소의 이미지를 불러옵니다. 끝나지 않은 요청은 먼저 취소합니다.
    ///
    /// 메모리 캐시에 있으면 바로 ``imageContent``와 ``result``를 채웁니다. `url`이 `nil`이면 ``ImageSession/Error/imageRequestMissing``으로 끝납니다.
    public func load(_ url: URL?) {
        load(url.map { ImageRequest(url: $0) })
    }

    /// 요청한 이미지를 불러옵니다. 끝나지 않은 요청은 먼저 취소합니다.
    ///
    /// 메모리 캐시에 있으면 바로 ``imageContent``와 ``result``를 채웁니다. `request`가 `nil`이면 ``ImageSession/Error/imageRequestMissing``으로 끝납니다.
    public func load(_ request: ImageRequest?) {
        cancel()
        guard let request else {
            reset()
            complete(with: .failure(ImageSession.Error.imageRequestMissing))
            return
        }
        let prepared = applyingDefaults(to: request)
        let cached = session.cache[prepared]
        if let cached, !cached.isPreview {
            completeFromMemoryCache(cached, request: prepared)
            return
        }
        reset()
        if let cached {
            imageContent = cached
        }
        isLoading = true
        let task = startSessionLoad(prepared)
        imageTask = task
        onStart?(task)
    }

    private func applyingDefaults(to request: ImageRequest) -> ImageRequest {
        var request = request
        if request.filters.isEmpty, !filters.isEmpty {
            request.filters = filters
        }
        if let priority {
            request.priority = priority
        }
        return request
    }

    private func completeFromMemoryCache(_ cached: ImageContent, request: ImageRequest) {
        clearLoadingState()
        let response = ImageResponse(content: cached, request: request, cacheType: .memory)
        imageContent = cached
        result = .success(response)
        onCompletion?(.success(response))
    }

    private func startSessionLoad(_ request: ImageRequest) -> ImageTask {
        let started = loadGeneration
        return session.loadImage(
            with: request,
            progress: { [weak self] response, completed, total in
                guard let self, self.loadGeneration == started else {
                    return
                }
                if let response {
                    withTransaction(self.transaction) {
                        self.imageContent = response.content
                    }
                } else if let progress = self.lazyProgress {
                    progress.completed = completed
                    progress.total = total
                }
            },
            completion: { [weak self] result in
                guard let self, self.loadGeneration == started else {
                    return
                }
                withTransaction(self.transaction) {
                    self.complete(with: result.mapError { $0 })
                }
            }
        )
    }

    /// 비동기 클로저가 돌려주는 이미지를 보여 줍니다. 세션을 거치지 않고 이미지를 만들 때 씁니다.
    ///
    /// 끝나지 않은 요청은 먼저 취소하고, 클로저가 오류를 일으키면 그 오류로 끝납니다.
    public func load(_ action: @escaping () async throws -> ImageResponse) {
        reset()
        isLoading = true
        let started = loadGeneration
        let task = Task { [weak self] in
            let outcome: Result<ImageResponse, Error>
            do {
                outcome = .success(try await action())
            } catch {
                outcome = .failure(error)
            }
            guard let self, self.loadGeneration == started else {
                return
            }
            if case .success = outcome {
                withTransaction(self.transaction) {
                    self.complete(with: outcome)
                }
            } else {
                self.complete(with: outcome)
            }
        }
        actionTask = task
        subscription = AnyCancellable { task.cancel() }
    }

    /// 퍼블리셔가 보내는 이미지를 차례로 보여 줍니다. 저해상도 이미지 뒤에 고해상도 이미지를 이어 보여 줄 때 씁니다.
    ///
    /// 퍼블리셔가 끝나면 마지막으로 받은 값으로 ``result``를 채웁니다.
    public func load<P: Publisher>(_ publisher: P) where P.Output == ImageResponse {
        reset()
        isLoading = true
        let started = loadGeneration
        subscription = publisher.sink(
            receiveCompletion: { @Sendable [weak self] completion in
                let failure: Error? = if case .failure(let error) = completion { error } else { nil }
                Self.onMain {
                    self?.publisherDidFinish(failure: failure, generation: started)
                }
            },
            receiveValue: { @Sendable [weak self] response in
                Self.onMain {
                    self?.publisherDidEmit(response, generation: started)
                }
            }
        )
    }

    /// 끝나지 않은 요청을 취소합니다. 보여 주던 이미지는 그대로 둡니다.
    public func cancel() {
        loadGeneration &+= 1
        let task = imageTask
        imageTask = nil
        subscription = nil
        actionTask = nil
        task?.cancel()
    }

    /// 끝나지 않은 요청을 취소하고 이미지와 결과를 지웁니다.
    public func reset() {
        cancel()
        clearLoadingState()
        if imageContent != nil {
            imageContent = nil
        }
        if result != nil {
            result = nil
        }
        publishedResponse = nil
    }

    private func complete(with result: Result<ImageResponse, Error>) {
        isLoading = false
        imageTask = nil
        if case .success(let response) = result {
            imageContent = response.content
        }
        self.result = result
        onCompletion?(result)
    }

    private func publisherDidEmit(_ response: ImageResponse, generation: UInt64) {
        guard generation == loadGeneration else {
            return
        }
        publishedResponse = response
        imageContent = response.content
    }

    private func publisherDidFinish(failure: Error?, generation: UInt64) {
        guard generation == loadGeneration else {
            return
        }
        isLoading = false
        if let failure {
            result = .failure(failure)
        } else if let publishedResponse {
            result = .success(publishedResponse)
        }
    }

    private func clearLoadingState() {
        if isLoading {
            isLoading = false
        }
        lazyProgress = nil
    }

    private nonisolated static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated(body)
            }
        }
    }
}
