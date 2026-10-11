import Foundation
import UIKit

enum MemoryPressureEvent: Sendable, Hashable {
    case warning
    case critical
    case applicationMemoryWarning

    init?(systemEvent: DispatchSource.MemoryPressureEvent) {
        if systemEvent.contains(.critical) {
            self = .critical
        } else if systemEvent.contains(.warning) {
            self = .warning
        } else {
            return nil
        }
    }
}

protocol MemoryPressureResponding: AnyObject, Sendable {
    func didReceiveMemoryPressure(_ event: MemoryPressureEvent)
    func didEnterBackground()
}

protocol MemoryPressureEventSource: AnyObject, Sendable {
    var mask: DispatchSource.MemoryPressureEvent { get }
    var isCancelled: Bool { get }
    func cancel()
}

struct MemoryPressureSourceFactory: Sendable {
    typealias Handler = @Sendable (DispatchSource.MemoryPressureEvent) -> Void

    let make: @Sendable (DispatchSource.MemoryPressureEvent, DispatchQueue, @escaping Handler) -> any MemoryPressureEventSource

    static let system = MemoryPressureSourceFactory { mask, queue, handler in
        SystemMemoryPressureSource(mask: mask, queue: queue, handler: handler)
    }
}

private final class SystemMemoryPressureSource: MemoryPressureEventSource {
    private let source: any DispatchSourceMemoryPressure

    init(mask: DispatchSource.MemoryPressureEvent, queue: DispatchQueue, handler: @escaping MemoryPressureSourceFactory.Handler) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: mask, queue: queue)
        source.setEventHandler { [weak source] in
            guard let source else {
                return
            }
            handler(source.data)
        }
        self.source = source
        source.activate()
    }

    var mask: DispatchSource.MemoryPressureEvent {
        source.mask
    }

    var isCancelled: Bool {
        source.isCancelled
    }

    func cancel() {
        source.cancel()
    }
}

final class MemoryPressureMonitor: Sendable {
    static let shared = MemoryPressureMonitor(notificationCenter: .default, systemSource: .system)

    static var systemEventMask: DispatchSource.MemoryPressureEvent {
        [.warning, .critical]
    }

    let notificationCenter: NotificationCenter
    let pressureQueue: DispatchQueue
    private let pressureSource = LockIsolated<(any MemoryPressureEventSource)?>(nil)
    private let responders = LockIsolated<[WeakResponder]>([])
    private let observations = LockIsolated<[any NSObjectProtocol]>([])

    convenience init(notificationCenter: NotificationCenter, observesSystemMemoryPressure: Bool = false) {
        self.init(notificationCenter: notificationCenter, systemSource: observesSystemMemoryPressure ? .system : nil)
    }

    init(notificationCenter: NotificationCenter, systemSource: MemoryPressureSourceFactory?) {
        self.notificationCenter = notificationCenter
        pressureQueue = DispatchQueue(label: "ImageLoader.MemoryPressure", qos: .utility)
        if let systemSource {
            let source = systemSource.make(Self.systemEventMask, pressureQueue) { [weak self] event in
                self?.deliver(systemEvent: event)
            }
            pressureSource.withLock { $0 = source }
        }
        let memoryWarning = notificationCenter.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.deliver(.applicationMemoryWarning)
        }
        let background = notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.didEnterBackground()
        }
        observations.withLock { $0 = [memoryWarning, background] }
    }

    deinit {
        pressureSource.value?.cancel()
        for observation in observations.value {
            notificationCenter.removeObserver(observation)
        }
    }

    var systemPressureSourceMask: DispatchSource.MemoryPressureEvent? {
        pressureSource.value?.mask
    }

    var isSystemPressureSourceActive: Bool {
        guard let source = pressureSource.value else {
            return false
        }
        return !source.isCancelled
    }

    func register(_ responder: any MemoryPressureResponding) {
        responders.withLock { list in
            list.removeAll { $0.responder == nil }
            list.append(WeakResponder(responder: responder))
        }
    }

    func isRegistered(_ responder: any MemoryPressureResponding) -> Bool {
        liveResponders().contains { $0 === responder }
    }

    var registeredCount: Int {
        liveResponders().count
    }

    func deliver(systemEvent: DispatchSource.MemoryPressureEvent) {
        guard let event = MemoryPressureEvent(systemEvent: systemEvent) else {
            return
        }
        deliver(event)
    }

    func deliver(_ event: MemoryPressureEvent) {
        for responder in liveResponders() {
            responder.didReceiveMemoryPressure(event)
        }
    }

    func didEnterBackground() {
        for responder in liveResponders() {
            responder.didEnterBackground()
        }
    }

    private func liveResponders() -> [any MemoryPressureResponding] {
        responders.withLock { list in list.compactMap(\.responder) }
    }
}

private struct WeakResponder {
    weak var responder: (any MemoryPressureResponding)?
}
