import Foundation
import UIKit

/// 이미지를 내려받아 디코딩하고 캐시에 보관하는 세션입니다.
///
/// 같은 이미지를 여러 곳에서 동시에 요청하면 다운로드와 디코딩은 한 번만 하고, 결과를 요청한 곳마다 나눠 줍니다.
/// 요청한 곳 하나가 취소해도 다른 곳이 기다리고 있으면 다운로드는 이어집니다.
///
/// 대부분은 ``shared``를 그대로 쓰면 됩니다. 디스크 캐시나 동시 다운로드 수를 바꾸려면
/// ``Configuration``으로 세션을 새로 만들어 주세요.
public final class ImageSession: @unchecked Sendable {
    /// 앱 전체가 함께 쓰는 세션입니다.
    ///
    /// 메모리 캐시와 `URLCache`(디스크 150MB)를 씁니다. `URLCache`는 서버가 보낸 `Cache-Control` 헤더를 따르므로,
    /// 헤더와 상관없이 디스크에 남기려면 ``Configuration/withDiskCache``로 만든 세션을 넣어 주세요.
    /// 새 세션을 넣어도 이전 세션에서 이미 시작한 요청은 그대로 이어집니다.
    public static var shared: ImageSession {
        get { _shared.value }
        set { _shared.withLock { $0 = newValue } }
    }

    private static let _shared = LockIsolated(ImageSession(configuration: .withURLCache))

    /// 세션을 만들 때 넘긴 설정입니다. 만든 뒤에는 바꿀 수 없습니다.
    public let configuration: Configuration

    /// 이 세션의 메모리 캐시와 디스크 캐시를 요청 단위로 읽고 지웁니다.
    public var cache: ImageSession.Cache {
        ImageSession.Cache(session: self)
    }

    let delegate: any ImageSession.Delegate
    let isDefaultDelegate: Bool
    let id = UUID()

    private let tasks = LinkedList<ImageTask>()
    let rawDataStages: InFlightTasks<PrepareImageStageKey, ImageResponse>
    let prepareImageStages: InFlightTasks<PrepareImageStageKey, ImageResponse>
    let decodeImageStages: InFlightTasks<DecodeImageStageKey, ImageResponse>
    let fetchDataStages: InFlightTasks<FetchDataStageKey, (Data, URLResponse?)>
    let rateLimiter: RateLimiter?
    let failureCooldown: FailureCooldownTable?
    let diskCacheReadingQueue = TaskQueue(maxConcurrentOperationCount: 4)

    private let isInvalidatedFlag = LockIsolated(false)
    private let nextTaskId = LockIsolated<UInt64>(0)
    private let reportedUnexpectedErrorTypes = LockIsolated<Set<String>>([])

    /// 설정과 델리게이트로 세션을 만듭니다.
    ///
    /// - Parameters:
    ///   - configuration: 캐시, 디코더, 동시 작업 수를 정합니다. 기본값은 ``shared``와 같은 `URLCache` 기반 설정입니다.
    ///   - delegate: 요청마다 캐시나 디코더를 바꾸고 진단 이벤트를 받습니다. `nil`이면 `configuration` 값을 그대로 씁니다.
    public init(configuration: Configuration = Configuration(), delegate: (any ImageSession.Delegate)? = nil) {
        self.configuration = configuration
        self.delegate = delegate ?? ImageSessionDefaultDelegate()
        isDefaultDelegate = delegate == nil
        let isCoalescingEnabled = configuration.isTaskCoalescingEnabled
        rawDataStages = InFlightTasks(isCoalescingEnabled)
        prepareImageStages = InFlightTasks(isCoalescingEnabled)
        decodeImageStages = InFlightTasks(isCoalescingEnabled)
        fetchDataStages = InFlightTasks(isCoalescingEnabled)
        rateLimiter = configuration.isRateLimiterEnabled ? RateLimiter(clock: configuration.clock, scheduler: configuration.scheduler) : nil
        failureCooldown = configuration.failureCooldown.map { FailureCooldownTable(policy: $0, clock: configuration.clock) }
        if let memoryCache = configuration.memoryCache as? MemoryCache {
            memoryCache.installDiagnosticHandlerIfNeeded { [weak self] diagnostic in
                self?.record(diagnostic)
            }
        }
        if let diskCache = configuration.diskCache as? DiskCache {
            diskCache.installDiagnosticHandlerIfNeeded { [weak self] diagnostic in
                self?.record(diagnostic)
            }
        }
    }

    /// 기본 설정에서 일부만 바꿔 세션을 만듭니다.
    ///
    /// ```swift
    /// let session = ImageSession {
    ///     $0.isProgressiveDecodingEnabled = true
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - delegate: 요청마다 캐시나 디코더를 바꾸고 진단 이벤트를 받습니다. `nil`이면 설정 값을 그대로 씁니다.
    ///   - configure: 기본 ``Configuration``을 받아 바꿀 값만 고칩니다.
    public convenience init(delegate: (any ImageSession.Delegate)? = nil, _ configure: (inout Configuration) -> Void) {
        var configuration = Configuration()
        configure(&configuration)
        self.init(configuration: configuration, delegate: delegate)
    }

    /// 세션을 닫습니다.
    ///
    /// 끝나지 않은 요청은 ``Error/cancelled``로 끝나고, 이후 요청은 ``Error/sessionInvalidated``로 바로 실패합니다.
    /// 두 번 이상 불러도 결과는 같습니다.
    public func invalidate() {
        guard isInvalidatedFlag.testAndSet(true) else { return }
        SessionQueue.async { [self] in
            var node = tasks.first
            while let current = node {
                node = current.next
                current.value.cancelForInvalidation()
            }
        }
    }

    var isInvalidated: Bool {
        isInvalidatedFlag.value
    }

    /// 주소로 이미지 작업을 만들고 바로 시작합니다.
    ///
    /// 진행률과 미리보기를 받거나 우선순위를 바꿔야 할 때 씁니다. 결과만 필요하면 ``image(for:)-(URL)``이 간단합니다.
    ///
    /// - Parameter url: 불러올 이미지의 주소입니다.
    /// - Returns: 이미 시작한 작업입니다. 결과는 ``ImageTask/image``나 ``ImageTask/response``로 기다립니다.
    public func imageTask(with url: URL) -> ImageTask {
        imageTask(with: ImageRequest(url: url))
    }

    /// 요청으로 이미지 작업을 만들고 바로 시작합니다.
    ///
    /// 진행률과 미리보기를 받거나 우선순위를 바꿔야 할 때 씁니다. 결과만 필요하면 ``image(for:)-(ImageRequest)``가 간단합니다.
    ///
    /// - Parameter request: 주소와 필터, 캐시 옵션을 담습니다.
    /// - Returns: 이미 시작한 작업입니다. 결과는 ``ImageTask/image``나 ``ImageTask/response``로 기다립니다.
    public func imageTask(with request: ImageRequest) -> ImageTask {
        makeStartedImageTask(with: request)
    }

    /// 주소의 이미지를 가져옵니다.
    ///
    /// 메모리 캐시, 디스크 캐시, 네트워크 순서로 찾습니다. 네트워크에서 받은 이미지는 다음 요청에 쓰도록 캐시에 저장합니다.
    ///
    /// - Parameter url: 불러올 이미지의 주소입니다. 같은 주소는 같은 캐시 항목을 씁니다.
    /// - Returns: 기본 설정에서는 디코딩까지 마친 이미지라서, 메인 스레드에서 그릴 때 디코딩으로 멈추지 않습니다.
    /// - Throws: 다음 ``Error`` 중 하나를 일으킵니다.
    ///   - ``Error/cancelled``: 결과가 나오기 전에 호출한 `Task`가 취소됐거나 ``invalidate()``를 불렀습니다.
    ///   - ``Error/sessionInvalidated``: ``invalidate()``를 부른 뒤에 요청했습니다.
    ///   - ``Error/dataMissingInCache``: ``ImageRequest/Options/returnCacheDataDontLoad``를 켰는데 캐시에 이미지가 없습니다.
    ///   - ``Error/dataLoadingFailed(error:)``: 주소가 비었거나, 네트워크 오류가 났거나, 상태 코드가 200부터 299 사이가 아닙니다.
    ///     ``Configuration/failureCooldown``이 실패가 이어진 주소의 요청을 막았을 때도 이 오류로 끝납니다. 원인은 `error`에 담겨 있습니다.
    ///   - ``Error/dataIsEmpty``: 서버가 0바이트를 보냈습니다.
    ///   - ``Error/dataDownloadExceededMaximumSize``: 받은 데이터가 ``Configuration/maximumResponseDataSize``를 넘었습니다.
    ///   - ``Error/decoderNotRegistered(context:)``: ``Configuration/makeImageDecoder``나 델리게이트가 디코더를 돌려주지 않았습니다. 기본 설정에서는 일어나지 않습니다.
    ///   - ``Error/decodingFailed(decoder:context:error:)``: 데이터가 이미지가 아니거나 손상됐습니다. 픽셀 수가 ``Configuration/decodingLimits``를 넘었을 때도 일어납니다.
    ///   - ``Error/processingFailed(filter:context:error:)``: ``ImageRequest/filters`` 중 하나가 결과 이미지를 만들지 못했습니다.
    ///   - ``Error/imageRequestMissing``: 이 메서드에서는 일어나지 않습니다. UIKit과 SwiftUI 뷰에 `nil` 요청을 넘겼을 때 생깁니다.
    public func image(for url: URL) async throws(ImageSession.Error) -> UIImage {
        try await image(for: ImageRequest(url: url))
    }

    /// 요청한 이미지를 가져옵니다.
    ///
    /// 메모리 캐시, 디스크 캐시, 네트워크 순서로 찾습니다. 캐시에 필터를 적용한 결과가 있으면 그대로 쓰고,
    /// 없으면 원본을 받아 필터를 적용합니다. 네트워크에서 받은 이미지는 다음 요청에 쓰도록 캐시에 저장합니다.
    ///
    /// - Parameter request: 주소, 필터, 배율, 썸네일 설정이 모두 같은 요청끼리 같은 캐시 항목을 씁니다.
    /// - Returns: 기본 설정에서는 디코딩까지 마친 이미지라서, 메인 스레드에서 그릴 때 디코딩으로 멈추지 않습니다.
    /// - Throws: 다음 ``Error`` 중 하나를 일으킵니다.
    ///   - ``Error/cancelled``: 결과가 나오기 전에 호출한 `Task`가 취소됐거나 ``invalidate()``를 불렀습니다.
    ///   - ``Error/sessionInvalidated``: ``invalidate()``를 부른 뒤에 요청했습니다.
    ///   - ``Error/dataMissingInCache``: ``ImageRequest/Options/returnCacheDataDontLoad``를 켰는데 캐시에 이미지가 없습니다.
    ///   - ``Error/dataLoadingFailed(error:)``: 주소가 비었거나, 네트워크 오류가 났거나, 상태 코드가 200부터 299 사이가 아닙니다.
    ///     ``Configuration/failureCooldown``이 실패가 이어진 주소의 요청을 막았을 때도 이 오류로 끝납니다. 원인은 `error`에 담겨 있습니다.
    ///   - ``Error/dataIsEmpty``: 서버가 0바이트를 보냈습니다.
    ///   - ``Error/dataDownloadExceededMaximumSize``: 받은 데이터가 ``Configuration/maximumResponseDataSize``를 넘었습니다.
    ///   - ``Error/decoderNotRegistered(context:)``: ``Configuration/makeImageDecoder``나 델리게이트가 디코더를 돌려주지 않았습니다. 기본 설정에서는 일어나지 않습니다.
    ///   - ``Error/decodingFailed(decoder:context:error:)``: 데이터가 이미지가 아니거나 손상됐습니다. 픽셀 수가 ``Configuration/decodingLimits``를 넘었을 때도 일어납니다.
    ///   - ``Error/processingFailed(filter:context:error:)``: ``ImageRequest/filters`` 중 하나가 결과 이미지를 만들지 못했습니다.
    ///   - ``Error/imageRequestMissing``: 이 메서드에서는 일어나지 않습니다. UIKit과 SwiftUI 뷰에 `nil` 요청을 넘겼을 때 생깁니다.
    public func image(for request: ImageRequest) async throws(ImageSession.Error) -> UIImage {
        try await imageTask(with: request).image
    }

    /// 이미지를 디코딩하지 않고 원본 바이트로 가져옵니다.
    ///
    /// 필터와 썸네일 설정은 무시합니다. 디스크 캐시에 원본이 있으면 네트워크 요청을 보내지 않습니다.
    ///
    /// - Parameter request: 주소와 캐시 옵션을 담습니다. 필터와 썸네일 설정은 결과에 영향을 주지 않습니다.
    /// - Returns: 내려받은 바이트와 서버 응답입니다. 디스크 캐시에서 읽었으면 응답은 `nil`입니다.
    /// - Throws: 다음 ``Error`` 중 하나를 일으킵니다.
    ///   - ``Error/cancelled``: 결과가 나오기 전에 호출한 `Task`가 취소됐거나 ``invalidate()``를 불렀습니다.
    ///   - ``Error/sessionInvalidated``: ``invalidate()``를 부른 뒤에 요청했습니다.
    ///   - ``Error/dataMissingInCache``: ``ImageRequest/Options/returnCacheDataDontLoad``를 켰는데 디스크 캐시에 원본이 없습니다.
    ///   - ``Error/dataLoadingFailed(error:)``: 주소가 비었거나, 네트워크 오류가 났거나, 상태 코드가 200부터 299 사이가 아닙니다.
    ///     ``Configuration/failureCooldown``이 실패가 이어진 주소의 요청을 막았을 때도 이 오류로 끝납니다. 원인은 `error`에 담겨 있습니다.
    ///   - ``Error/dataIsEmpty``: 서버가 0바이트를 보냈습니다.
    ///   - ``Error/dataDownloadExceededMaximumSize``: 받은 데이터가 ``Configuration/maximumResponseDataSize``를 넘었습니다.
    ///   - ``Error/decoderNotRegistered(context:)``, ``Error/decodingFailed(decoder:context:error:)``,
    ///     ``Error/processingFailed(filter:context:error:)``, ``Error/imageRequestMissing``: 디코딩과 필터를 거치지 않으므로 일어나지 않습니다.
    public func data(for request: ImageRequest) async throws(ImageSession.Error) -> (Data, URLResponse?) {
        let response = try await makeStartedImageTask(with: request, isDataTask: true).response
        guard let data = response.content.data else {
            throw .dataIsEmpty
        }
        return (data, response.urlResponse)
    }

    func makeStartedImageTask(with request: ImageRequest, isDataTask: Bool = false, onEvent: (@Sendable (ImageTask.Event, ImageTask) -> Void)? = nil) -> ImageTask {
        let taskId = nextTaskId.withLock { value -> UInt64 in
            value += 1
            return value
        }
        let task = ImageTask(taskId: taskId, request: request, isDataTask: isDataTask, onEvent: onEvent)
        task.session = self
        delegate.imageTaskCreated(task, session: self)
        SessionQueue.async { [self] in
            startImageTask(task)
        }
        return task
    }

    private func startImageTask(_ task: ImageTask) {
        SessionQueue.assertOnQueue()
        guard task.state == .running else { return }
        guard !isInvalidated else {
            dispatch(.finished(.failure(.sessionInvalidated)), to: task)
            return
        }
        task.registryNode = tasks.append(task)
        task.startTime = configuration.clock.monotonicIncludingSleep
        dispatch(.started, to: task)
        let publisher = task.isDataTask ? makeRawDataStage(for: task.request) : makePrepareImageStage(for: task.request)
        let subscription = publisher.subscribe(priority: task.priority, subscriber: task) { [weak self, weak task] event in
            guard let self, let task else { return }
            self.imageTask(task, didReceive: event)
        }
        if task.registryNode != nil {
            task.subscription = subscription
        }
    }

    private func imageTask(_ task: ImageTask, didReceive event: SharedTask<ImageResponse>.Event) {
        switch event {
        case .value(let response, let isCompleted):
            if isCompleted {
                finish(task, with: .success(response))
            } else {
                dispatch(.preview(response), to: task)
            }
        case .progress(let progress):
            dispatch(.progress(progress), to: task)
        case .error(let error):
            finish(task, with: .failure(error))
        }
    }

    private func finish(_ task: ImageTask, with result: Result<ImageResponse, ImageSession.Error>) {
        if let node = task.registryNode {
            tasks.remove(node)
            task.registryNode = nil
        }
        task.subscription = nil
        guard dispatch(.finished(result), to: task) else { return }
        recordMetrics(for: task, result: result)
    }

    private func recordMetrics(for task: ImageTask, result: Result<ImageResponse, ImageSession.Error>) {
        guard configuration.isMetricsCollectionEnabled else { return }
        let metrics = ImageTaskMetrics(
            taskId: task.taskId,
            duration: max(0, configuration.clock.monotonicIncludingSleep - task.startTime),
            cacheType: (try? result.get())?.cacheType,
            errorCode: result.failureValue?.diagnosticCode,
            isDataTask: task.isDataTask
        )
        delegate.session(self, didRecord: .taskMetrics(metrics))
    }

    @discardableResult
    private func dispatch(_ event: ImageTask.Event, to task: ImageTask) -> Bool {
        guard task.process(event) else { return false }
        delegate.imageTask(task, didReceiveEvent: event, session: self)
        return true
    }

    func imageTaskCancelCalled(_ task: ImageTask) {
        SessionQueue.assertOnQueue()
        if let node = task.registryNode {
            tasks.remove(node)
            task.registryNode = nil
        }
        task.subscription?.unsubscribe()
        task.subscription = nil
        delegate.imageTask(task, didReceiveEvent: .finished(.failure(.cancelled)), session: self)
        recordMetrics(for: task, result: .failure(.cancelled))
    }

    func imageTaskUpdatePriorityCalled(_ task: ImageTask, priority: ImageRequest.Priority) {
        SessionQueue.assertOnQueue()
        task.subscription?.setPriority(priority)
    }

    var runningTaskCount: Int {
        SessionQueue.sync { tasks.count }
    }

    func makePrepareImageStage(for request: ImageRequest) -> SharedTask<ImageResponse>.Publisher {
        prepareImageStages.publisher(for: PrepareImageStageKey(request)) {
            PrepareImageStage(self, request)
        }
    }

    func makeRawDataStage(for request: ImageRequest) -> SharedTask<ImageResponse>.Publisher {
        rawDataStages.publisher(for: PrepareImageStageKey(request)) {
            RawDataStage(self, request)
        }
    }

    func makeDecodeImageStage(for request: ImageRequest) -> SharedTask<ImageResponse>.Publisher {
        decodeImageStages.publisher(for: DecodeImageStageKey(request)) {
            DecodeImageStage(self, request)
        }
    }

    func makeFetchDataStage(for request: ImageRequest) -> SharedTask<(Data, URLResponse?)>.Publisher {
        fetchDataStages.publisher(for: FetchDataStageKey(request)) {
            FetchDataStage(self, request)
        }
    }

    func wrapBoundaryError(_ error: Swift.Error, at boundary: ImageSession.Error.Boundary) -> ImageSession.Error {
        let wrapped = ImageSession.Error.wrapping(error, at: boundary, onUnexpected: configuration.unexpectedErrorAssertion)
        guard boundary != .willLoadData, !ImageSession.Error.isExpectedLoaderError(error) else { return wrapped }
        let typeName = String(reflecting: type(of: error))
        let isFirst = reportedUnexpectedErrorTypes.withLock { $0.insert(typeName).inserted }
        if isFirst {
            record(.unexpectedErrorWrapped(typeName))
        }
        return wrapped
    }

    func record(_ diagnostic: Diagnostic) {
        if SessionQueue.isCurrent {
            delegate.session(self, didRecord: diagnostic)
        } else {
            SessionQueue.async { [self] in
                delegate.session(self, didRecord: diagnostic)
            }
        }
    }
}

extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self {
            return error
        }
        return nil
    }
}
