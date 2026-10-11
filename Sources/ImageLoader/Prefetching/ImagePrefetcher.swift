import Foundation

/// 곧 보일 이미지를 미리 받아 캐시에 넣습니다.
///
/// `UICollectionViewDataSourcePrefetching`과 함께 쓰면, 셀이 화면에 나타날 때 이미지가 이미 캐시에 있습니다.
/// 미리 받는 요청은 기본으로 ``ImageRequest/Priority/low`` 우선순위로 보내고, 동시에 2개까지만 받습니다.
///
/// ```swift
/// func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
///     prefetcher.startPrefetching(with: indexPaths.map { photos[$0.item].url })
/// }
///
/// func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
///     prefetcher.stopPrefetching(with: indexPaths.map { photos[$0.item].url })
/// }
/// ```
public final class ImagePrefetcher: Sendable {
    /// 미리 받은 이미지를 어디까지 준비해 둘지 정합니다.
    @frozen public enum Destination: Sendable {
        /// 디코딩까지 마쳐 메모리 캐시에 넣습니다. 셀이 나타나면 바로 보여 줄 수 있지만 메모리를 씁니다.
        case memoryCache
        /// 데이터만 받아 디스크 캐시에 넣고 디코딩하지 않습니다. 메모리를 아끼는 대신 셀이 나타날 때 디코딩합니다.
        case diskCache
    }

    /// 이미지를 받을 세션입니다.
    public let session: ImageSession
    /// 미리 받은 이미지를 어디까지 준비해 둘지 정합니다.
    public let destination: Destination

    private let queue: TaskQueue
    private let state = LockIsolated(State())

    private struct State {
        var tasks: [PrepareImageStageKey: PrefetchTask] = [:]
        var priority: ImageRequest.Priority = .low
        var didComplete: (@MainActor @Sendable () -> Void)?
    }

    private final class PrefetchTask: Sendable {
        let key: PrepareImageStageKey
        let request: ImageRequest
        private let handles = LockIsolated(Handles())

        private struct Handles {
            var operation: TaskQueue.Operation?
            var imageTask: ImageTask?
            var finish: (@Sendable () -> Void)?
        }

        init(key: PrepareImageStageKey, request: ImageRequest) {
            self.key = key
            self.request = request
        }

        var operation: TaskQueue.Operation? {
            get { handles.withLock { $0.operation } }
            set { handles.withLock { $0.operation = newValue } }
        }

        var imageTask: ImageTask? {
            get { handles.withLock { $0.imageTask } }
            set { handles.withLock { $0.imageTask = newValue } }
        }

        func setFinish(_ finish: @escaping @Sendable () -> Void) {
            handles.withLock { $0.finish = finish }
        }

        func takeFinish() -> (@Sendable () -> Void)? {
            handles.withLock { handles in
                defer { handles.finish = nil }
                return handles.finish
            }
        }
    }

    /// 프리페처를 만듭니다. 프리페처가 사라지면 끝나지 않은 요청을 모두 취소합니다.
    ///
    /// - Parameters:
    ///   - session: 이미지를 받을 세션입니다.
    ///   - destination: 미리 받은 이미지를 어디까지 준비해 둘지 정합니다.
    ///   - maxConcurrentRequestCount: 동시에 미리 받을 수 있는 이미지 수입니다. 화면에 보이는 이미지의 다운로드를 늦추지 않도록 작게 둡니다.
    public init(session: ImageSession = ImageSession.shared, destination: Destination = .memoryCache, maxConcurrentRequestCount: Int = 2) {
        self.session = session
        self.destination = destination
        queue = TaskQueue(maxConcurrentOperationCount: maxConcurrentRequestCount)
    }

    deinit {
        let tasks = state.withLock { state -> [PrefetchTask] in
            defer { state.tasks.removeAll() }
            return Array(state.tasks.values)
        }
        guard !tasks.isEmpty else { return }
        for task in tasks {
            task.imageTask?.cancel()
        }
        SessionQueue.async {
            for task in tasks {
                task.operation?.cancel()
            }
        }
    }

    /// 새 요청을 시작하지 않고 멈출지 정합니다. 이미 시작한 요청은 이어 갑니다.
    ///
    /// 스크롤하는 동안 멈추고 스크롤이 끝나면 다시 시작하면, 보이는 이미지가 네트워크를 먼저 씁니다.
    public var isPaused: Bool {
        get { queue.isSuspended }
        set { queue.isSuspended = newValue }
    }

    /// 미리 받는 요청의 우선순위입니다. 기본값은 ``ImageRequest/Priority/low``입니다. 바꾸면 끝나지 않은 요청에도 적용합니다.
    public var priority: ImageRequest.Priority {
        get { state.withLock { $0.priority } }
        set {
            let tasks = state.withLock { state -> [PrefetchTask]? in
                guard state.priority != newValue else { return nil }
                state.priority = newValue
                return Array(state.tasks.values)
            }
            guard let tasks else { return }
            SessionQueue.async {
                for task in tasks {
                    task.operation?.priority = newValue
                    task.imageTask?.priority = newValue
                }
            }
        }
    }

    /// 미리 받을 요청이 모두 끝나거나 취소됐을 때 메인 스레드에서 부릅니다.
    public var didComplete: (@MainActor @Sendable () -> Void)? {
        get { state.withLock { $0.didComplete } }
        set { state.withLock { $0.didComplete = newValue } }
    }

    /// 주소의 이미지를 미리 받기 시작합니다. 이미 받고 있거나 메모리 캐시에 있는 이미지는 건너뜁니다.
    public func startPrefetching(with urls: [URL]) {
        startPrefetching(with: urls.map { ImageRequest(url: $0) })
    }

    /// 요청한 이미지를 미리 받기 시작합니다. 이미 받고 있거나 메모리 캐시에 있는 이미지는 건너뜁니다.
    ///
    /// 요청의 우선순위는 무시하고 ``priority``를 씁니다. 필터나 썸네일 설정은 실제로 보여 줄 요청과 같게 맞춰 주세요. 다르면 다른 캐시 항목으로 저장합니다.
    public func startPrefetching(with requests: [ImageRequest]) {
        SessionQueue.async { [self] in
            _startPrefetching(with: requests)
        }
    }

    /// 주소의 이미지를 미리 받던 요청을 취소합니다.
    public func stopPrefetching(with urls: [URL]) {
        stopPrefetching(with: urls.map { ImageRequest(url: $0) })
    }

    /// 요청한 이미지를 미리 받던 요청을 취소합니다. ``startPrefetching(with:)-([ImageRequest])``에 넘긴 요청과 같은 요청을 넘겨 주세요.
    public func stopPrefetching(with requests: [ImageRequest]) {
        SessionQueue.async { [self] in
            let priority = state.withLock { $0.priority }
            for var request in requests {
                request.priority = priority
                let key = PrepareImageStageKey(request)
                guard let task = state.withLock({ $0.tasks.removeValue(forKey: key) }) else { continue }
                cancel(task)
            }
            sendCompletionIfNeeded()
        }
    }

    /// 미리 받던 요청을 모두 취소합니다. 화면을 떠날 때 불러 주세요.
    public func stopPrefetching() {
        SessionQueue.async { [self] in
            let tasks = state.withLock { state -> [PrefetchTask] in
                defer { state.tasks.removeAll() }
                return Array(state.tasks.values)
            }
            tasks.forEach(cancel)
        }
    }

    var pendingTaskCount: Int {
        state.withLock { $0.tasks.count }
    }

    private func _startPrefetching(with requests: [ImageRequest]) {
        SessionQueue.assertOnQueue()
        let priority = state.withLock { $0.priority }
        for var request in requests {
            request.priority = priority
            let key = PrepareImageStageKey(request)
            guard state.withLock({ $0.tasks[key] == nil }) else { continue }
            if destination == .memoryCache, session.cache[request] != nil {
                continue
            }
            let task = PrefetchTask(key: key, request: request)
            state.withLock { $0.tasks[key] = task }
            task.operation = queue.add(priority: priority) { [weak self, weak task] finish in
                guard let self, let task, self.state.withLock({ $0.tasks[key] === task }) else {
                    finish()
                    return
                }
                self.load(task, finish: finish)
            }
        }
        sendCompletionIfNeeded()
    }

    private func load(_ task: PrefetchTask, finish: @escaping @Sendable () -> Void) {
        SessionQueue.assertOnQueue()
        task.setFinish(finish)
        task.imageTask = session.makeStartedImageTask(with: task.request, isDataTask: destination == .diskCache) { [weak self, weak task] event, _ in
            guard case .finished = event else { return }
            finish()
            guard let self, let task else { return }
            let didRemove = self.state.withLock { state -> Bool in
                guard state.tasks[task.key] === task else { return false }
                state.tasks[task.key] = nil
                return true
            }
            guard didRemove else { return }
            self.sendCompletionIfNeeded()
        }
    }

    private func cancel(_ task: PrefetchTask) {
        SessionQueue.assertOnQueue()
        task.operation?.cancel()
        task.imageTask?.cancel()
        task.takeFinish()?()
    }

    private func sendCompletionIfNeeded() {
        let didComplete = state.withLock { state -> (@MainActor @Sendable () -> Void)? in
            state.tasks.isEmpty ? state.didComplete : nil
        }
        guard let didComplete else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                didComplete()
            }
        }
    }
}
