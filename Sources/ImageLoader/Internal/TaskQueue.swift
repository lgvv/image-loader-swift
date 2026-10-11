import Foundation

/// 동시에 돌릴 작업 수를 제한하고, 기다리는 작업은 우선순위가 높은 것부터 시작하는 큐입니다.
///
/// ``ImageSession/Configuration``의 다운로드, 디코딩, 필터 큐가 이 타입입니다. 우선순위가 같으면 먼저 넣은 작업부터 시작합니다.
public final class TaskQueue: @unchecked Sendable {
    private let settings: LockIsolated<Settings>
    private var buckets: [LinkedList<Operation>]
    private var runningCount = 0
    private var pendingCount = 0

    var onEvent: (@Sendable (Event) -> Void)?

    enum Event: Sendable {
        case enqueued
        case started
        case finished
        case cancelled
        case priorityChanged
    }

    private struct Settings {
        var isSuspended = false
        var maxConcurrentOperationCount: Int
    }

    /// 큐를 만듭니다.
    ///
    /// - Parameter maxConcurrentOperationCount: 동시에 돌릴 수 있는 작업 수입니다. 1보다 작으면 1로 봅니다. 기본값은 CPU 코어 수입니다.
    public init(maxConcurrentOperationCount: Int = ProcessInfo.processInfo.processorCount) {
        settings = LockIsolated(Settings(maxConcurrentOperationCount: max(1, maxConcurrentOperationCount)))
        buckets = ImageRequest.Priority.allCases.map { _ in LinkedList<Operation>() }
    }

    /// `true`면 새 작업을 시작하지 않습니다. 이미 시작한 작업은 이어 갑니다.
    public var isSuspended: Bool {
        get { settings.withLock { $0.isSuspended } }
        set {
            let resumed = settings.withLock { settings -> Bool in
                let wasSuspended = settings.isSuspended
                settings.isSuspended = newValue
                return wasSuspended && !newValue
            }
            if resumed {
                SessionQueue.async { [self] in drain() }
            }
        }
    }

    /// 동시에 돌릴 수 있는 작업 수입니다. 늘리면 기다리던 작업을 바로 시작합니다.
    public var maxConcurrentOperationCount: Int {
        get { settings.withLock { $0.maxConcurrentOperationCount } }
        set {
            let increased = settings.withLock { settings -> Bool in
                let old = settings.maxConcurrentOperationCount
                settings.maxConcurrentOperationCount = max(1, newValue)
                return settings.maxConcurrentOperationCount > old
            }
            if increased {
                SessionQueue.async { [self] in drain() }
            }
        }
    }

    var operationCount: (pending: Int, running: Int) {
        SessionQueue.assertOnQueue()
        return (pendingCount, runningCount)
    }

    @discardableResult
    func add(priority: ImageRequest.Priority = .normal, _ work: @escaping (_ finish: @escaping @Sendable () -> Void) -> Void) -> Operation {
        SessionQueue.assertOnQueue()
        let operation = Operation(queue: self, priority: priority, work: work)
        operation.node = buckets[priority.rawValue].append(operation)
        pendingCount += 1
        onEvent?(.enqueued)
        drain()
        return operation
    }

    private func drain() {
        SessionQueue.assertOnQueue()
        let (isSuspended, limit) = settings.withLock { ($0.isSuspended, $0.maxConcurrentOperationCount) }
        guard !isSuspended else { return }
        while runningCount < limit, pendingCount > 0, let operation = dequeueHighestPriority() {
            execute(operation)
        }
    }

    private func dequeueHighestPriority() -> Operation? {
        for bucket in buckets.reversed() {
            if let node = bucket.first {
                bucket.remove(node)
                pendingCount -= 1
                node.value.node = nil
                return node.value
            }
        }
        return nil
    }

    private func execute(_ operation: Operation) {
        guard let work = operation.work else { return }
        operation.work = nil
        operation.isRunning = true
        runningCount += 1
        onEvent?(.started)
        let didFinish = LockIsolated(false)
        work { [weak self] in
            guard didFinish.testAndSet(true) else { return }
            SessionQueue.async { [weak self] in
                self?.operationFinished(operation)
            }
        }
    }

    private func operationFinished(_ operation: Operation) {
        operation.isRunning = false
        runningCount -= 1
        onEvent?(.finished)
        drain()
    }

    fileprivate func operationCancelled(_ operation: Operation) {
        SessionQueue.assertOnQueue()
        guard let node = operation.node else { return }
        buckets[operation.priority.rawValue].remove(node)
        operation.node = nil
        pendingCount -= 1
        onEvent?(.cancelled)
    }

    fileprivate func operationPriorityChanged(_ operation: Operation, from oldPriority: ImageRequest.Priority) {
        SessionQueue.assertOnQueue()
        guard let node = operation.node else { return }
        buckets[oldPriority.rawValue].remove(node)
        if operation.priority < oldPriority {
            operation.node = buckets[operation.priority.rawValue].prepend(operation)
        } else {
            operation.node = buckets[operation.priority.rawValue].append(operation)
        }
        onEvent?(.priorityChanged)
    }

    final class Operation: @unchecked Sendable {
        fileprivate weak var queue: TaskQueue?
        fileprivate var node: LinkedList<Operation>.Node?
        fileprivate var work: ((_ finish: @escaping @Sendable () -> Void) -> Void)?
        fileprivate(set) var isRunning = false
        private(set) var isCancelled = false

        var onCancelled: (() -> Void)?

        var priority: ImageRequest.Priority {
            didSet {
                guard oldValue != priority else { return }
                queue?.operationPriorityChanged(self, from: oldValue)
            }
        }

        fileprivate init(queue: TaskQueue, priority: ImageRequest.Priority, work: @escaping (_ finish: @escaping @Sendable () -> Void) -> Void) {
            self.queue = queue
            self.priority = priority
            self.work = work
        }

        func cancel() {
            SessionQueue.assertOnQueue()
            guard !isCancelled else { return }
            isCancelled = true
            work = nil
            queue?.operationCancelled(self)
            let onCancelled = onCancelled
            self.onCancelled = nil
            onCancelled?()
        }
    }
}
