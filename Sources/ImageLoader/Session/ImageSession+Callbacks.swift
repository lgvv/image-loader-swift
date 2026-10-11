import Combine
import Foundation
import UIKit

extension ImageSession {
    /// 주소의 이미지를 불러오고 결과를 클로저로 받습니다. `async`를 쓸 수 없는 곳에서 씁니다.
    ///
    /// - Parameters:
    ///   - url: 불러올 이미지의 주소입니다.
    ///   - completion: 끝나면 메인 스레드에서 한 번 부릅니다. 작업을 취소하면 부르지 않습니다.
    /// - Returns: 이미 시작한 작업입니다. 취소하거나 우선순위를 바꿀 때 씁니다.
    @discardableResult
    public func loadImage(
        with url: URL,
        completion: @escaping @MainActor @Sendable (Result<ImageResponse, ImageSession.Error>) -> Void
    ) -> ImageTask {
        loadImage(with: ImageRequest(url: url), progress: nil, completion: completion)
    }

    /// 요청한 이미지를 불러오고 결과를 클로저로 받습니다. `async`를 쓸 수 없는 곳에서 씁니다.
    ///
    /// - Parameters:
    ///   - request: 주소와 필터, 캐시 옵션을 담습니다.
    ///   - completion: 끝나면 메인 스레드에서 한 번 부릅니다. 작업을 취소하면 부르지 않습니다.
    /// - Returns: 이미 시작한 작업입니다. 취소하거나 우선순위를 바꿀 때 씁니다.
    @discardableResult
    public func loadImage(
        with request: ImageRequest,
        completion: @escaping @MainActor @Sendable (Result<ImageResponse, ImageSession.Error>) -> Void
    ) -> ImageTask {
        loadImage(with: request, progress: nil, completion: completion)
    }

    /// 요청한 이미지를 불러오고 진행률과 결과를 클로저로 받습니다.
    ///
    /// - Parameters:
    ///   - request: 주소와 필터, 캐시 옵션을 담습니다.
    ///   - progress: 데이터를 받을 때마다 메인 스레드에서 부릅니다. 미리보기를 만들었으면 첫 번째 값으로 넘기고, 받은 바이트 수와 전체 바이트 수를 함께 넘깁니다.
    ///   - completion: 끝나면 메인 스레드에서 한 번 부릅니다. 작업을 취소하면 부르지 않습니다.
    /// - Returns: 이미 시작한 작업입니다. 취소하거나 우선순위를 바꿀 때 씁니다.
    @discardableResult
    public func loadImage(
        with request: ImageRequest,
        progress: (@MainActor @Sendable (ImageResponse?, Int64, Int64) -> Void)?,
        completion: @escaping @MainActor @Sendable (Result<ImageResponse, ImageSession.Error>) -> Void
    ) -> ImageTask {
        makeStartedImageTask(with: request) { event, task in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !task.isCancelled else { return }
                    switch event {
                    case .started:
                        break
                    case .progress(let value):
                        progress?(nil, value.completed, value.total)
                    case .preview(let response):
                        progress?(response, task.currentProgress.completed, task.currentProgress.total)
                    case .finished(let result):
                        completion(result)
                    }
                }
            }
        }
    }

    /// 이미지를 디코딩하지 않고 원본 바이트로 받습니다. 필터와 썸네일 설정은 무시합니다.
    ///
    /// - Parameters:
    ///   - request: 주소와 캐시 옵션을 담습니다.
    ///   - completion: 끝나면 메인 스레드에서 한 번 부릅니다. 작업을 취소하면 부르지 않습니다. 디스크 캐시에서 읽었으면 응답은 `nil`입니다.
    /// - Returns: 이미 시작한 작업입니다. 취소하거나 우선순위를 바꿀 때 씁니다.
    @discardableResult
    public func loadData(
        with request: ImageRequest,
        completion: @escaping @MainActor @Sendable (Result<(data: Data, response: URLResponse?), ImageSession.Error>) -> Void
    ) -> ImageTask {
        loadData(with: request, progress: nil, completion: completion)
    }

    /// 이미지를 디코딩하지 않고 원본 바이트로 받으면서 진행률도 받습니다. 필터와 썸네일 설정은 무시합니다.
    ///
    /// - Parameters:
    ///   - request: 주소와 캐시 옵션을 담습니다.
    ///   - progress: 데이터를 받을 때마다 메인 스레드에서 받은 바이트 수와 전체 바이트 수를 넘깁니다. 전체 크기를 모르면 두 번째 값은 0입니다.
    ///   - completion: 끝나면 메인 스레드에서 한 번 부릅니다. 작업을 취소하면 부르지 않습니다. 디스크 캐시에서 읽었으면 응답은 `nil`입니다.
    /// - Returns: 이미 시작한 작업입니다. 취소하거나 우선순위를 바꿀 때 씁니다.
    @discardableResult
    public func loadData(
        with request: ImageRequest,
        progress: (@MainActor @Sendable (Int64, Int64) -> Void)?,
        completion: @escaping @MainActor @Sendable (Result<(data: Data, response: URLResponse?), ImageSession.Error>) -> Void
    ) -> ImageTask {
        makeStartedImageTask(with: request, isDataTask: true) { event, task in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !task.isCancelled else { return }
                    switch event {
                    case .started, .preview:
                        break
                    case .progress(let value):
                        progress?(value.completed, value.total)
                    case .finished(let result):
                        completion(
                            result.flatMap { response in
                                guard let data = response.content.data else {
                                    return .failure(.dataIsEmpty)
                                }
                                return .success((data: data, response: response.urlResponse))
                            })
                    }
                }
            }
        }
    }

    /// 주소의 이미지를 Combine 퍼블리셔로 받습니다.
    ///
    /// 구독하면 시작하고, 구독을 취소하면 작업도 취소합니다. 메모리 캐시에 있으면 바로 값을 보내고 끝납니다.
    /// 미리보기를 만들면 최종 이미지보다 먼저 보내고, 네트워크에서 받은 값은 메인 스레드에서 보냅니다.
    public func imagePublisher(with url: URL) -> AnyPublisher<ImageResponse, ImageSession.Error> {
        imagePublisher(with: ImageRequest(url: url))
    }

    /// 요청한 이미지를 Combine 퍼블리셔로 받습니다.
    ///
    /// 구독하면 시작하고, 구독을 취소하면 작업도 취소합니다. 메모리 캐시에 있으면 바로 값을 보내고 끝납니다.
    /// 미리보기를 만들면 최종 이미지보다 먼저 보내고, 네트워크에서 받은 값은 메인 스레드에서 보냅니다.
    public func imagePublisher(with request: ImageRequest) -> AnyPublisher<ImageResponse, ImageSession.Error> {
        ImagePublisher(request: request, session: self).eraseToAnyPublisher()
    }
}

private struct ImagePublisher: Publisher, Sendable {
    typealias Output = ImageResponse
    typealias Failure = ImageSession.Error

    let request: ImageRequest
    let session: ImageSession

    func receive<S>(subscriber: S) where S: Subscriber, S.Failure == Failure, S.Input == Output {
        let subscription = ImageSubscription(request: request, session: session, subscriber: subscriber)
        subscriber.receive(subscription: subscription)
    }
}

private final class ImageSubscription<S: Subscriber>: Subscription, @unchecked Sendable where S.Input == ImageResponse, S.Failure == ImageSession.Error {
    private let lock = LockIsolated<State>(State())
    private let request: ImageRequest
    private let session: ImageSession

    private struct State {
        var subscriber: S?
        var task: ImageTask?
        var isStarted = false
        var isCancelled = false
    }

    init(request: ImageRequest, session: ImageSession, subscriber: S) {
        self.request = request
        self.session = session
        lock.withLock { $0.subscriber = subscriber }
    }

    func request(_ demand: Subscribers.Demand) {
        guard demand > 0 else { return }
        let shouldStart = lock.withLock { state -> Bool in
            guard !state.isStarted, !state.isCancelled, state.subscriber != nil else { return false }
            state.isStarted = true
            return true
        }
        guard shouldStart else { return }
        if let content = session.cache[request], !content.isPreview {
            let subscriber = lock.withLock { state -> S? in
                defer { state.subscriber = nil }
                return state.subscriber
            }
            _ = subscriber?.receive(ImageResponse(content: content, request: request, cacheType: .memory))
            subscriber?.receive(completion: .finished)
            return
        }
        let task = session.makeStartedImageTask(with: request) { [weak self] event, _ in
            DispatchQueue.main.async {
                self?.handle(event)
            }
        }
        let isCancelled = lock.withLock { state -> Bool in
            guard !state.isCancelled else { return true }
            if state.subscriber != nil {
                state.task = task
            }
            return false
        }
        if isCancelled {
            task.cancel()
        }
    }

    private func handle(_ event: ImageTask.Event) {
        switch event {
        case .started, .progress:
            break
        case .preview(let response):
            let subscriber = lock.withLock { $0.subscriber }
            _ = subscriber?.receive(response)
        case .finished(let result):
            let subscriber = lock.withLock { state -> S? in
                defer {
                    state.subscriber = nil
                    state.task = nil
                }
                return state.subscriber
            }
            switch result {
            case .success(let response):
                _ = subscriber?.receive(response)
                subscriber?.receive(completion: .finished)
            case .failure(let error):
                subscriber?.receive(completion: .failure(error))
            }
        }
    }

    func cancel() {
        let task = lock.withLock { state -> ImageTask? in
            state.isCancelled = true
            defer {
                state.subscriber = nil
                state.task = nil
            }
            return state.task
        }
        task?.cancel()
    }
}
