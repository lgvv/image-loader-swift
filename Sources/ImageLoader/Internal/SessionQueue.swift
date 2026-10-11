import Foundation

enum SessionQueue {
    static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "ImageLoader.SessionQueue", qos: .userInitiated)
        queue.setSpecific(key: specificKey, value: ())
        return queue
    }()

    private static let specificKey = DispatchSpecificKey<Void>()

    static var isCurrent: Bool {
        DispatchQueue.getSpecific(key: specificKey) != nil
    }

    static func async(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    static func asyncAfter(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        queue.asyncAfter(deadline: SystemClock.dispatchDeadline(after: delay), execute: work)
    }

    static func performOrAsync(_ work: @escaping @Sendable () -> Void) {
        if isCurrent {
            work()
        } else {
            queue.async(execute: work)
        }
    }

    static func sync<T>(_ work: () throws -> T) rethrows -> T {
        if isCurrent {
            return try work()
        }
        return try queue.sync(execute: work)
    }

    static func assertOnQueue(file: StaticString = #fileID, line: UInt = #line) {
        #if DEBUG
            dispatchPrecondition(condition: .onQueue(queue))
        #endif
    }
}

enum SessionWorkers {
    static let decoding = DispatchQueue(label: "ImageLoader.Decode", qos: .userInitiated, attributes: .concurrent)
    static let processing = DispatchQueue(label: "ImageLoader.Process", qos: .userInitiated, attributes: .concurrent)
    static let decompressing = DispatchQueue(label: "ImageLoader.Decompress", qos: .userInitiated, attributes: .concurrent)
    static let encoding = DispatchQueue(label: "ImageLoader.Encode", qos: .utility)
    static let io = DispatchQueue(label: "ImageLoader.IO", qos: .userInitiated, attributes: .concurrent)
    static let release = DispatchQueue(label: "ImageLoader.Release", qos: .utility)
}
