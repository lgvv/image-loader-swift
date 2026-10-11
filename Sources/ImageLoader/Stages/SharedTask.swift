import Foundation

class SharedTask<Value: Sendable>: SharedTaskSubscriptionDelegate, @unchecked Sendable {
    enum Event {
        case value(Value, isCompleted: Bool)
        case progress(ImageTask.Progress)
        case error(ImageSession.Error)
    }

    private var inlineSubscription: Subscription?
    private var subscriptions: [Int: Subscription]?
    private var nextSubscriptionKey = 0

    private(set) var isDisposed = false
    private var isStarted = false

    var onDisposed: (() -> Void)?
    var onCancelled: (() -> Void)?

    var priority: ImageRequest.Priority = .normal {
        didSet {
            guard oldValue != priority else { return }
            operation?.priority = priority
            dependency?.setPriority(priority)
        }
    }

    var dependency: TaskSubscription? {
        didSet {
            dependency?.setPriority(priority)
        }
    }

    var operation: TaskQueue.Operation? {
        didSet {
            guard priority != .normal else { return }
            operation?.priority = priority
        }
    }

    func start() {}

    var publisher: Publisher {
        Publisher(task: self)
    }

    var subscribers: [AnyObject] {
        var result: [AnyObject] = []
        if let subscriber = inlineSubscription?.subscriber {
            result.append(subscriber)
        }
        if let subscriptions {
            for key in subscriptions.keys.sorted() {
                if let subscriber = subscriptions[key]?.subscriber {
                    result.append(subscriber)
                }
            }
        }
        return result
    }

    var subscriberCount: Int {
        (inlineSubscription == nil ? 0 : 1) + (subscriptions?.count ?? 0)
    }

    func hasSubscriber<T>(of type: T.Type) -> Bool {
        subscribers.contains { $0 is T }
    }

    func send(value: Value, isCompleted: Bool = false) {
        send(event: .value(value, isCompleted: isCompleted))
    }

    func send(error: ImageSession.Error) {
        send(event: .error(error))
    }

    func send(progress: ImageTask.Progress) {
        send(event: .progress(progress))
    }

    private func send(event: Event) {
        SessionQueue.assertOnQueue()
        guard !isDisposed else { return }
        switch event {
        case .value(_, isCompleted: true), .error:
            terminate(reason: .finished)
        case .value, .progress:
            break
        }
        let inline = inlineSubscription
        let others = subscriptions.map { subscriptions in subscriptions.keys.sorted().compactMap { subscriptions[$0] } }
        inline?.closure(event)
        for subscriber in others ?? [] {
            subscriber.closure(event)
        }
    }

    fileprivate func subscribe(priority: ImageRequest.Priority, subscriber: AnyObject, _ closure: @escaping (Event) -> Void) -> TaskSubscription? {
        SessionQueue.assertOnQueue()
        guard !isDisposed else { return nil }
        let key = nextSubscriptionKey
        nextSubscriptionKey += 1
        let subscription = Subscription(closure: closure, subscriber: subscriber, priority: priority)
        if key == 0 {
            inlineSubscription = subscription
        } else {
            if subscriptions == nil {
                subscriptions = [:]
            }
            subscriptions?[key] = subscription
        }
        updatePriority(suggested: priority)
        if !isStarted {
            isStarted = true
            start()
        }
        guard !isDisposed else { return nil }
        return TaskSubscription(task: self, key: key)
    }

    fileprivate func unsubscribe(key: Int) {
        SessionQueue.assertOnQueue()
        if key == 0, inlineSubscription != nil {
            inlineSubscription = nil
        } else {
            subscriptions?[key] = nil
        }
        guard !isDisposed else { return }
        if inlineSubscription == nil, subscriptions?.isEmpty ?? true {
            terminate(reason: .cancelled)
        } else {
            updatePriority(suggested: nil)
        }
    }

    fileprivate func setPriority(_ priority: ImageRequest.Priority, for key: Int) {
        SessionQueue.assertOnQueue()
        guard !isDisposed else { return }
        if key == 0, let inline = inlineSubscription {
            inline.priority = priority
        } else if let subscription = subscriptions?[key] {
            subscription.priority = priority
        } else {
            return
        }
        updatePriority(suggested: priority)
    }

    private func updatePriority(suggested: ImageRequest.Priority?) {
        if let suggested, suggested >= priority {
            priority = suggested
            return
        }
        var newPriority: ImageRequest.Priority?
        if let inline = inlineSubscription {
            newPriority = inline.priority
        }
        for subscription in (subscriptions ?? [:]).values {
            newPriority = max(newPriority ?? subscription.priority, subscription.priority)
        }
        priority = newPriority ?? .normal
    }

    private enum TerminationReason {
        case finished
        case cancelled
    }

    private func terminate(reason: TerminationReason) {
        guard !isDisposed else { return }
        isDisposed = true
        if reason == .cancelled {
            operation?.cancel()
            dependency?.unsubscribe()
            onCancelled?()
        }
        onDisposed?()
    }

    private final class Subscription {
        let closure: (Event) -> Void
        weak var subscriber: AnyObject?
        var priority: ImageRequest.Priority

        init(closure: @escaping (Event) -> Void, subscriber: AnyObject, priority: ImageRequest.Priority) {
            self.closure = closure
            self.subscriber = subscriber
            self.priority = priority
        }
    }

    struct Publisher {
        fileprivate let task: SharedTask<Value>

        func subscribe(priority: ImageRequest.Priority = .normal, subscriber: AnyObject, _ closure: @escaping (Event) -> Void) -> TaskSubscription? {
            task.subscribe(priority: priority, subscriber: subscriber, closure)
        }

        func subscribe<NewValue>(_ task: SharedTask<NewValue>, onValue: @escaping (Value, Bool) -> Void) -> TaskSubscription? {
            subscribe(priority: task.priority, subscriber: task) { [weak task] event in
                guard let task else { return }
                switch event {
                case .value(let value, let isCompleted):
                    onValue(value, isCompleted)
                case .progress(let progress):
                    task.send(progress: progress)
                case .error(let error):
                    task.operation?.cancel()
                    task.send(error: error)
                }
            }
        }
    }
}

protocol SharedTaskSubscriptionDelegate: AnyObject, Sendable {
    func unsubscribeFromDelegate(key: Int)
    func setPriorityFromDelegate(_ priority: ImageRequest.Priority, key: Int)
}

extension SharedTask {
    func unsubscribeFromDelegate(key: Int) {
        unsubscribe(key: key)
    }

    func setPriorityFromDelegate(_ priority: ImageRequest.Priority, key: Int) {
        setPriority(priority, for: key)
    }
}

struct TaskSubscription: Sendable {
    private let task: any SharedTaskSubscriptionDelegate
    private let key: Int

    fileprivate init(task: any SharedTaskSubscriptionDelegate, key: Int) {
        self.task = task
        self.key = key
    }

    func unsubscribe() {
        task.unsubscribeFromDelegate(key: key)
    }

    func setPriority(_ priority: ImageRequest.Priority) {
        task.setPriorityFromDelegate(priority, key: key)
    }
}

final class InFlightTasks<Key: Hashable, Value: Sendable>: @unchecked Sendable {
    private let isCoalescingEnabled: Bool
    private var map: [Key: SharedTask<Value>] = [:]

    init(_ isCoalescingEnabled: Bool) {
        self.isCoalescingEnabled = isCoalescingEnabled
    }

    var count: Int {
        map.count
    }

    func publisher(for key: @autoclosure () -> Key, _ make: () -> SharedTask<Value>) -> SharedTask<Value>.Publisher {
        SessionQueue.assertOnQueue()
        guard isCoalescingEnabled else {
            return make().publisher
        }
        let key = key()
        if let task = map[key] {
            return task.publisher
        }
        let task = make()
        map[key] = task
        task.onDisposed = { [weak self, weak task] in
            guard let self, let task, self.map[key] === task else { return }
            self.map[key] = nil
        }
        return task.publisher
    }
}
