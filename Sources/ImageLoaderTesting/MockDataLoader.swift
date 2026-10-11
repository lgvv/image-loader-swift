import Foundation
@_spi(Testing) import ImageLoader

/// 네트워크 없이 정해 둔 응답을 돌려주는 테스트용 로더입니다.
///
/// 주소마다 응답을 정해 두고 `ImageSession.Configuration.dataLoader`에 넣으면, 세션의 캐시와 디코딩, 취소 동작을 실제 네트워크 없이 확인할 수 있습니다.
///
/// ```swift
/// let loader = MockDataLoader()
/// loader.setResponse(.data(pngData), for: url)
/// let session = ImageSession(configuration: .init(dataLoader: loader))
/// let image = try await session.image(for: url)
/// #expect(loader.counts.started == 1)
/// ```
public final class MockDataLoader: DataLoading, Sendable {
    /// 로더가 돌려줄 응답입니다.
    public enum Response: Sendable {
        /// 데이터를 돌려줍니다.
        ///
        /// 상태 코드가 200부터 299 밖이면 `DataLoader.validate`와 같은 오류로 끝납니다. `chunkCount`만큼 나눠서 보내므로 진행률과 미리보기를 확인할 수 있습니다.
        /// `Content-Length` 헤더는 데이터 크기로 채웁니다.
        case data(Data, statusCode: Int = 200, headers: [String: String] = [:], chunkCount: Int = 1)
        /// 이 코드의 `URLError`로 실패합니다.
        case failure(URLError.Code)
    }

    /// 로더가 받은 요청 수입니다.
    public struct Counts: Sendable, Equatable {
        /// 시작한 요청 수입니다. 같은 이미지 요청을 합쳤는지 확인할 때 씁니다.
        public var started = 0
        /// 성공이든 실패든 결과를 돌려준 요청 수입니다.
        public var completed = 0
        /// 응답을 보내기 전에 취소된 요청 수입니다.
        public var cancelled = 0

        /// 기대하는 값과 비교할 때 씁니다.
        public init(started: Int = 0, completed: Int = 0, cancelled: Int = 0) {
            self.started = started
            self.completed = completed
            self.cancelled = cancelled
        }
    }

    private struct State {
        var responses: [URL: Response] = [:]
        var defaultResponse: Response?
        var isSuspended = false
        var pending: [@Sendable () -> Void] = []
        var counts = Counts()
        var requests: [URLRequest] = []
        var activeByURL: [URL: Int] = [:]
        var maximumActivePerURL = 0
    }

    private let state = Protected(State())
    private let queue = DispatchQueue(label: "ImageLoaderTesting.MockDataLoader")

    /// 로더를 만듭니다.
    ///
    /// - Parameter defaultResponse: 응답을 정하지 않은 주소에 돌려줄 응답입니다. `nil`이면 그런 주소는 `URLError(.fileDoesNotExist)`로 실패합니다.
    public init(defaultResponse: Response? = nil) {
        state.withLock { $0.defaultResponse = defaultResponse }
    }

    /// 주소에 돌려줄 응답을 정합니다.
    public func setResponse(_ response: Response, for url: URL) {
        state.withLock { $0.responses[url] = response }
    }

    /// `true`면 요청을 받아 두기만 하고 응답을 보내지 않습니다. `false`로 바꾸면 받아 둔 요청에 응답을 보냅니다.
    ///
    /// 끝나지 않은 요청을 취소하거나 합치는 동작을 확인할 때 씁니다.
    public var isSuspended: Bool {
        get { state.withLock { $0.isSuspended } }
        set {
            let pending = state.withLock { state -> [@Sendable () -> Void] in
                state.isSuspended = newValue
                guard !newValue else { return [] }
                defer { state.pending.removeAll() }
                return state.pending
            }
            for work in pending {
                queue.async(execute: work)
            }
        }
    }

    /// 지금까지 받은 요청 수입니다.
    public var counts: Counts {
        state.withLock { $0.counts }
    }

    /// 같은 주소로 동시에 받고 있던 요청 수의 최댓값입니다. 1이면 같은 이미지 요청을 하나로 합친 것입니다.
    public var maximumConcurrentLoadsPerURL: Int {
        state.withLock { $0.maximumActivePerURL }
    }

    /// 받은 요청을 받은 순서대로 돌려줍니다. 헤더가 붙었는지 확인할 때 씁니다.
    public var requests: [URLRequest] {
        state.withLock { $0.requests }
    }

    private func beginLoad(_ request: URLRequest) -> Response? {
        state.withLock { state -> Response? in
            state.counts.started += 1
            state.requests.append(request)
            if let url = request.url {
                let active = state.activeByURL[url, default: 0] + 1
                state.activeByURL[url] = active
                state.maximumActivePerURL = max(state.maximumActivePerURL, active)
            }
            return request.url.flatMap { state.responses[$0] } ?? state.defaultResponse
        }
    }

    private func deliver(
        _ response: Response?,
        for request: URLRequest,
        control: Control,
        didReceiveData: @Sendable (Data, URLResponse) -> Void,
        completion: @Sendable (Swift.Error?) -> Void
    ) {
        guard !control.isCancelled else {
            finishCancelled(completion)
            return
        }
        guard let response, let url = request.url else {
            finishCompleted(URLError(.fileDoesNotExist), completion)
            return
        }
        switch response {
        case .data(let data, let statusCode, let headers, let chunkCount):
            let fields = headers.merging(["Content-Length": "\(data.count)"]) { $1 }
            guard let urlResponse = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: fields) else {
                finishCompleted(URLError(.badServerResponse), completion)
                return
            }
            if let error = DataLoader.validate(urlResponse) {
                finishCompleted(error, completion)
                return
            }
            for chunk in Self.split(data, into: max(1, chunkCount)) {
                guard !control.isCancelled else {
                    finishCancelled(completion)
                    return
                }
                didReceiveData(chunk, urlResponse)
            }
            finishCompleted(nil, completion)
        case .failure(let code):
            finishCompleted(URLError(code), completion)
        }
    }

    private func finishCompleted(_ error: Swift.Error?, _ completion: @Sendable (Swift.Error?) -> Void) {
        state.withLock { $0.counts.completed += 1 }
        completion(error)
    }

    private func finishCancelled(_ completion: @Sendable (Swift.Error?) -> Void) {
        state.withLock { $0.counts.cancelled += 1 }
        completion(URLError(.cancelled))
    }

    /// 정해 둔 응답을 백그라운드 큐에서 돌려줍니다.
    public func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Swift.Error?) -> Void
    ) -> any Cancellable {
        let control = Control()
        let activeURL = request.url
        let response = beginLoad(request)
        let endActive: @Sendable () -> Void = { [weak self, control] in
            guard let self, let activeURL, control.end() else { return }
            self.state.withLock { $0.activeByURL[activeURL, default: 1] -= 1 }
        }
        let completion: @Sendable (Swift.Error?) -> Void = { error in
            endActive()
            completion(error)
        }
        let work: @Sendable () -> Void = { [weak self, control] in
            self?.deliver(response, for: request, control: control, didReceiveData: didReceiveData, completion: completion)
        }
        let shouldRunNow = state.withLock { state -> Bool in
            guard state.isSuspended else { return true }
            state.pending.append(work)
            return false
        }
        if shouldRunNow {
            queue.async(execute: work)
        }
        return AnonymousCancellable { [weak self, control] in
            guard control.cancel() else { return }
            endActive()
            _ = self
        }
    }

    private static func split(_ data: Data, into count: Int) -> [Data] {
        guard count > 1, data.count > count else { return [data] }
        let size = Int((Double(data.count) / Double(count)).rounded(.up))
        return stride(from: 0, to: data.count, by: size).map { offset in
            data.subdata(in: offset..<min(data.count, offset + size))
        }
    }

    private final class Control: Sendable {
        private let flag = Protected(false)
        private let ended = Protected(false)

        func end() -> Bool {
            ended.testAndSet(true)
        }

        var isCancelled: Bool {
            flag.value
        }

        func cancel() -> Bool {
            flag.testAndSet(true)
        }
    }
}

private struct AnonymousCancellable: Cancellable {
    let onCancel: @Sendable () -> Void

    func cancel() {
        onCancel()
    }
}

/// 직접 시간을 움직이는 테스트용 시계입니다. `ImageSession.Configuration.clock`과 `ImageSession.Configuration.scheduler`에 넣어 씁니다.
///
/// 실패 쿨다운이나 속도 제한처럼 시간이 지나야 바뀌는 동작을, 실제로 기다리지 않고 확인할 수 있습니다.
@_spi(Testing) public final class TestClock: SessionClock, SessionScheduler, Sendable {
    private struct ScheduledWork {
        let deadline: TimeInterval
        let sequence: Int
        let work: @Sendable () -> Void
    }

    private struct State {
        var now: Date
        var monotonicIncludingSleep: TimeInterval
        var scheduled: [ScheduledWork] = []
        var nextSequence = 0
    }

    private let state: Protected<State>

    /// 시작 시각을 정해 시계를 만듭니다.
    public init(now: Date = Date(timeIntervalSinceReferenceDate: 0), monotonicIncludingSleep: TimeInterval = 0) {
        state = Protected(State(now: now, monotonicIncludingSleep: monotonicIncludingSleep))
    }

    /// 지금 시각입니다. ``advance(by:)``나 ``advanceWallClock(by:)``로만 바뀝니다.
    public var now: Date {
        state.value.now
    }

    /// 흐른 초입니다. ``advance(by:)``나 ``advanceMonotonic(by:)``로만 바뀝니다.
    public var monotonicIncludingSleep: TimeInterval {
        state.value.monotonicIncludingSleep
    }

    /// 아직 부르지 않은 예약 작업 수입니다.
    public var scheduledWorkCount: Int {
        state.withLock { $0.scheduled.count }
    }

    /// `seconds`초 뒤에 부를 작업을 예약합니다. 시간을 움직이기 전에는 부르지 않습니다.
    public func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        state.withLock {
            $0.scheduled.append(ScheduledWork(deadline: $0.monotonicIncludingSleep + max(0, seconds), sequence: $0.nextSequence, work: work))
            $0.nextSequence += 1
        }
    }

    /// 시각과 흐른 초를 함께 `interval`만큼 움직이고, 때가 된 예약 작업을 예약 시각 순서대로 부릅니다.
    public func advance(by interval: TimeInterval) {
        state.withLock {
            $0.now = $0.now.addingTimeInterval(interval)
            $0.monotonicIncludingSleep += interval
        }
        runDueWork()
    }

    /// 시각만 움직입니다. 사용자가 기기 시각을 바꾼 상황을 흉내 낼 때 씁니다. 예약 작업은 부르지 않습니다.
    public func advanceWallClock(by interval: TimeInterval) {
        state.withLock {
            $0.now = $0.now.addingTimeInterval(interval)
        }
    }

    /// 흐른 초만 움직이고, 때가 된 예약 작업을 부릅니다.
    public func advanceMonotonic(by interval: TimeInterval) {
        state.withLock {
            $0.monotonicIncludingSleep += interval
        }
        runDueWork()
    }

    private func runDueWork() {
        while let next = takeNextDueWork() {
            next()
        }
    }

    private func takeNextDueWork() -> (@Sendable () -> Void)? {
        state.withLock { state in
            let current = state.monotonicIncludingSleep
            let due = state.scheduled.indices
                .filter { state.scheduled[$0].deadline <= current }
                .min { (state.scheduled[$0].deadline, state.scheduled[$0].sequence) < (state.scheduled[$1].deadline, state.scheduled[$1].sequence) }
            guard let due else { return nil }
            return state.scheduled.remove(at: due).work
        }
    }
}

final class Protected<Value>: @unchecked Sendable {
    private var storage: Value
    private let lock = NSLock()

    init(_ value: Value) {
        storage = value
    }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }

    var value: Value {
        withLock { $0 }
    }
}

extension Protected where Value: Equatable {
    @discardableResult
    func testAndSet(_ newValue: Value) -> Bool {
        withLock { value in
            guard value != newValue else { return false }
            value = newValue
            return true
        }
    }
}
