import Foundation
import UIKit

/// 이미지 하나를 불러오는 작업입니다.
///
/// ``ImageSession/imageTask(with:)-(ImageRequest)``로 만들면 바로 시작합니다. 결과를 기다리는 동안 진행률과
/// 미리보기를 받을 수 있고, 우선순위를 바꾸거나 취소할 수 있습니다.
///
/// ```swift
/// let task = ImageSession.shared.imageTask(with: url)
/// for await progress in task.progress {
///     progressView.progress = progress.fraction
/// }
/// let image = try await task.image
/// ```
public final class ImageTask: Hashable, CustomStringConvertible, @unchecked Sendable {
    /// 세션 안에서 작업을 구분하는 번호입니다. 1부터 시작해 작업을 만들 때마다 1씩 커집니다.
    public let taskId: UInt64
    /// 작업을 시작한 요청입니다. 시작한 뒤 ``priority``를 바꿔도 이 값은 그대로입니다.
    public let request: ImageRequest
    let isDataTask: Bool

    private let mutableState: LockIsolated<MutableState>

    weak var session: ImageSession?
    var subscription: TaskSubscription?
    var registryNode: LinkedList<ImageTask>.Node?
    var startTime: TimeInterval = 0
    let onEvent: (@Sendable (Event, ImageTask) -> Void)?

    private typealias Waiter = CheckedContinuation<Result<ImageResponse, ImageSession.Error>, Never>

    private struct MutableState {
        var state: State = .running
        var isCancelled = false
        var priority: ImageRequest.Priority
        var progress = Progress(completed: 0, total: 0)
        var result: Result<ImageResponse, ImageSession.Error>?
        var waiters: [Int: Waiter] = [:]
        var streams: [Int: AsyncStream<Event>.Continuation] = [:]
        var nextID = 0
    }

    init(taskId: UInt64, request: ImageRequest, isDataTask: Bool, onEvent: (@Sendable (Event, ImageTask) -> Void)?) {
        self.taskId = taskId
        self.request = request
        self.isDataTask = isDataTask
        self.onEvent = onEvent
        mutableState = LockIsolated(MutableState(priority: request.priority))
    }

    /// 작업 큐에서 기다리는 순서입니다.
    ///
    /// 셀이 화면에서 벗어날 때 낮추면, 보이는 이미지가 먼저 다운로드를 시작합니다. 작업이 끝난 뒤에 바꾸면 무시합니다.
    public var priority: ImageRequest.Priority {
        get { mutableState.withLock { $0.priority } }
        set {
            let didChange = mutableState.withLock { state -> Bool in
                guard state.priority != newValue, state.state == .running else { return false }
                state.priority = newValue
                return true
            }
            guard didChange else { return }
            SessionQueue.async { [self] in
                session?.imageTaskUpdatePriorityCalled(self, priority: newValue)
            }
        }
    }

    /// 지금까지 받은 바이트 수입니다. 아직 받기 전이면 둘 다 0입니다.
    public var currentProgress: Progress {
        mutableState.withLock { $0.progress }
    }

    /// 작업이 결과를 기다리는 중인지, 끝났는지, 취소됐는지 알려 줍니다.
    public var state: State {
        mutableState.withLock { $0.state }
    }

    var isCancelled: Bool {
        mutableState.withLock { $0.isCancelled }
    }

    /// 작업이 끝날 때까지 기다린 뒤 이미지를 돌려줍니다.
    ///
    /// 여러 곳에서 동시에 기다려도 됩니다. 이미 끝난 작업이면 기다리지 않고 결과를 바로 돌려줍니다.
    ///
    /// - Throws: 다음 ``ImageSession/Error`` 중 하나를 일으킵니다.
    ///   - ``ImageSession/Error/cancelled``: 결과가 나오기 전에 ``cancel()``을 불렀거나, 기다리던 `Task`가 취소됐거나, 세션을 닫았습니다.
    ///   - ``ImageSession/Error/sessionInvalidated``: ``ImageSession/invalidate()``를 부른 세션에서 만든 작업입니다.
    ///   - ``ImageSession/Error/dataMissingInCache``: ``ImageRequest/Options/returnCacheDataDontLoad``를 켰는데 캐시에 이미지가 없습니다.
    ///   - ``ImageSession/Error/dataLoadingFailed(error:)``: 주소가 비었거나, 네트워크 오류가 났거나, 상태 코드가 200부터 299 사이가 아닙니다.
    ///     ``ImageSession/Configuration/failureCooldown``이 실패가 이어진 주소의 요청을 막았을 때도 이 오류로 끝납니다. 원인은 `error`에 담겨 있습니다.
    ///   - ``ImageSession/Error/dataIsEmpty``: 서버가 0바이트를 보냈습니다.
    ///   - ``ImageSession/Error/dataDownloadExceededMaximumSize``: 받은 데이터가 ``ImageSession/Configuration/maximumResponseDataSize``를 넘었습니다.
    ///   - ``ImageSession/Error/decoderNotRegistered(context:)``: ``ImageSession/Configuration/makeImageDecoder``나 델리게이트가 디코더를 돌려주지 않았습니다. 기본 설정에서는 일어나지 않습니다.
    ///   - ``ImageSession/Error/decodingFailed(decoder:context:error:)``: 데이터가 이미지가 아니거나 손상됐습니다. 픽셀 수가 ``ImageSession/Configuration/decodingLimits``를 넘었을 때도 일어납니다.
    ///   - ``ImageSession/Error/processingFailed(filter:context:error:)``: ``ImageRequest/filters`` 중 하나가 결과 이미지를 만들지 못했습니다.
    ///   - ``ImageSession/Error/imageRequestMissing``: 이 프로퍼티에서는 일어나지 않습니다. UIKit과 SwiftUI 뷰에 `nil` 요청을 넘겼을 때 생깁니다.
    public var image: UIImage {
        get async throws(ImageSession.Error) {
            try await response.image
        }
    }

    /// 작업이 끝날 때까지 기다린 뒤 이미지와 서버 응답, 캐시 출처를 함께 돌려줍니다.
    ///
    /// 이미지가 어느 캐시에서 왔는지 알아야 할 때 씁니다. 이미지만 필요하면 ``image``가 간단합니다.
    ///
    /// - Throws: 다음 ``ImageSession/Error`` 중 하나를 일으킵니다.
    ///   - ``ImageSession/Error/cancelled``: 결과가 나오기 전에 ``cancel()``을 불렀거나, 기다리던 `Task`가 취소됐거나, 세션을 닫았습니다.
    ///   - ``ImageSession/Error/sessionInvalidated``: ``ImageSession/invalidate()``를 부른 세션에서 만든 작업입니다.
    ///   - ``ImageSession/Error/dataMissingInCache``: ``ImageRequest/Options/returnCacheDataDontLoad``를 켰는데 캐시에 이미지가 없습니다.
    ///   - ``ImageSession/Error/dataLoadingFailed(error:)``: 주소가 비었거나, 네트워크 오류가 났거나, 상태 코드가 200부터 299 사이가 아닙니다.
    ///     ``ImageSession/Configuration/failureCooldown``이 실패가 이어진 주소의 요청을 막았을 때도 이 오류로 끝납니다. 원인은 `error`에 담겨 있습니다.
    ///   - ``ImageSession/Error/dataIsEmpty``: 서버가 0바이트를 보냈습니다.
    ///   - ``ImageSession/Error/dataDownloadExceededMaximumSize``: 받은 데이터가 ``ImageSession/Configuration/maximumResponseDataSize``를 넘었습니다.
    ///   - ``ImageSession/Error/decoderNotRegistered(context:)``: ``ImageSession/Configuration/makeImageDecoder``나 델리게이트가 디코더를 돌려주지 않았습니다. 기본 설정에서는 일어나지 않습니다.
    ///   - ``ImageSession/Error/decodingFailed(decoder:context:error:)``: 데이터가 이미지가 아니거나 손상됐습니다. 픽셀 수가 ``ImageSession/Configuration/decodingLimits``를 넘었을 때도 일어납니다.
    ///   - ``ImageSession/Error/processingFailed(filter:context:error:)``: ``ImageRequest/filters`` 중 하나가 결과 이미지를 만들지 못했습니다.
    ///   - ``ImageSession/Error/imageRequestMissing``: 이 프로퍼티에서는 일어나지 않습니다. UIKit과 SwiftUI 뷰에 `nil` 요청을 넘겼을 때 생깁니다.
    public var response: ImageResponse {
        get async throws(ImageSession.Error) {
            let result = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Result<ImageResponse, ImageSession.Error>, Never>) in
                    let finished = mutableState.withLock { state -> Result<ImageResponse, ImageSession.Error>? in
                        if let result = state.result {
                            return result
                        }
                        let id = state.nextID
                        state.nextID += 1
                        state.waiters[id] = continuation
                        return nil
                    }
                    if let finished {
                        continuation.resume(returning: finished)
                    }
                }
            } onCancel: {
                cancel()
            }
            return try result.get()
        }
    }

    /// 작업에서 일어나는 일을 차례로 전달합니다.
    ///
    /// 스트림을 만든 뒤에 일어난 일만 전달하고, ``Event/finished(_:)``를 보낸 뒤 끝납니다.
    /// 이미 끝난 작업에서 만들면 아무것도 전달하지 않고 바로 끝납니다.
    public var events: AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        let id = mutableState.withLock { state -> Int? in
            guard state.state == .running else { return nil }
            let id = state.nextID
            state.nextID += 1
            state.streams[id] = continuation
            return id
        }
        guard let id else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.mutableState.withLock { _ = $0.streams.removeValue(forKey: id) }
        }
        return stream
    }

    /// ``events``에서 다운로드 진행률만 골라 전달합니다.
    public var progress: AsyncCompactMapSequence<AsyncStream<Event>, Progress> {
        events.compactMap {
            if case .progress(let progress) = $0 { return progress }
            return nil
        }
    }

    /// ``events``에서 다운로드 도중에 만든 미리보기만 골라 전달합니다.
    ///
    /// ``ImageSession/Configuration/isProgressiveDecodingEnabled``를 켠 세션에서만 전달합니다. 기본값은 꺼져 있습니다.
    public var previews: AsyncCompactMapSequence<AsyncStream<Event>, ImageResponse> {
        events.compactMap {
            if case .preview(let response) = $0 { return response }
            return nil
        }
    }

    /// 작업을 취소합니다.
    ///
    /// 결과를 기다리던 곳은 바로 ``ImageSession/Error/cancelled``를 받습니다. 같은 이미지를 기다리는 다른 작업이 있으면
    /// 다운로드는 이어지고, 이 작업만 결과를 받지 않습니다. 이미 끝난 작업에서 부르면 아무 일도 하지 않습니다.
    public func cancel() {
        cancel(setsCancelledFlag: true)
    }

    func cancelForInvalidation() {
        cancel(setsCancelledFlag: false)
    }

    private func cancel(setsCancelledFlag: Bool) {
        let waiters = mutableState.withLock { state -> [Waiter]? in
            if setsCancelledFlag {
                state.isCancelled = true
            }
            guard state.state == .running else { return nil }
            state.state = .cancelled
            state.result = .failure(.cancelled)
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        guard let waiters else { return }
        for waiter in waiters {
            waiter.resume(returning: .failure(.cancelled))
        }
        SessionQueue.async { [self] in
            let event = Event.finished(.failure(.cancelled))
            finishStreams(with: event)
            onEvent?(event, self)
            session?.imageTaskCancelCalled(self)
        }
    }

    @discardableResult
    func process(_ event: Event) -> Bool {
        SessionQueue.assertOnQueue()
        let isDelivered: Bool
        switch event {
        case .started, .preview:
            isDelivered = yieldToRunningStreams(event) { _ in }
        case .progress(let progress):
            isDelivered = yieldToRunningStreams(event) { $0.progress = progress }
        case .finished(let result):
            isDelivered = complete(with: result, event: event)
        }
        guard isDelivered else { return false }
        onEvent?(event, self)
        return true
    }

    private func yieldToRunningStreams(_ event: Event, updating update: (inout MutableState) -> Void) -> Bool {
        let streams = mutableState.withLock { state -> [AsyncStream<Event>.Continuation]? in
            guard state.state == .running else { return nil }
            update(&state)
            return Array(state.streams.values)
        }
        guard let streams else { return false }
        for stream in streams {
            stream.yield(event)
        }
        return true
    }

    private func complete(with result: Result<ImageResponse, ImageSession.Error>, event: Event) -> Bool {
        let waiters = mutableState.withLock { state -> [Waiter]? in
            guard state.state == .running else { return nil }
            state.state = .completed
            state.result = result
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        guard let waiters else { return false }
        for waiter in waiters {
            waiter.resume(returning: result)
        }
        finishStreams(with: event)
        return true
    }

    private func finishStreams(with event: Event) {
        SessionQueue.assertOnQueue()
        let streams = mutableState.withLock { state -> [AsyncStream<Event>.Continuation] in
            defer { state.streams.removeAll() }
            return Array(state.streams.values)
        }
        for stream in streams {
            stream.yield(event)
            stream.finish()
        }
    }

    public static func == (lhs: ImageTask, rhs: ImageTask) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public var description: String {
        let progress = currentProgress
        return "ImageTask(id: \(taskId), priority: \(priority), progress: \(progress.completed) / \(progress.total), state: \(state))"
    }

    /// 작업이 어느 단계에 있는지 나타냅니다.
    @frozen public enum State: Sendable {
        /// 결과를 기다리고 있습니다.
        case running
        /// 결과가 나오기 전에 취소됐습니다.
        case cancelled
        /// 이미지를 받았거나 오류로 끝났습니다.
        case completed
    }

    /// 다운로드한 바이트 수입니다.
    public struct Progress: Hashable, Sendable {
        /// 지금까지 받은 바이트 수입니다. 이어받기를 했으면 앞서 받아 둔 바이트도 포함합니다.
        public let completed: Int64
        /// 전체 바이트 수입니다. 서버가 `Content-Length` 헤더를 보내지 않으면 0입니다.
        public let total: Int64

        /// 0부터 1 사이의 진행률입니다. ``total``이 0이면 0을 돌려줍니다.
        public var fraction: Float {
            guard total > 0 else { return 0 }
            return min(1, Float(completed) / Float(total))
        }

        /// 받은 바이트 수와 전체 바이트 수로 진행률을 만듭니다.
        public init(completed: Int64, total: Int64) {
            self.completed = completed
            self.total = total
        }
    }

    /// ``events``가 전달하는 일입니다.
    @frozen public enum Event: Sendable {
        /// 작업이 세션에 등록됐습니다. 아직 캐시를 확인하기 전입니다.
        case started
        /// 데이터를 더 받았습니다.
        case progress(Progress)
        /// 다운로드 도중에 만든 미리보기입니다. 최종 이미지보다 흐리거나 일부만 보일 수 있습니다.
        case preview(ImageResponse)
        /// 작업이 끝났습니다. 이 일을 보낸 뒤에는 아무것도 보내지 않습니다.
        case finished(Result<ImageResponse, ImageSession.Error>)
    }
}
