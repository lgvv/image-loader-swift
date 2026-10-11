import Foundation
import os

final class SessionSignposter: Sendable {
    static let subsystem = "ImageLoader.ImageSession"
    static let category = "Image Loading"

    static let shared = SessionSignposter(
        isEnabled: { ImageSession.Configuration.isSignpostLoggingEnabled },
        makeSignposter: { OSSignposter(subsystem: subsystem, category: category) }
    )

    private let isEnabled: @Sendable () -> Bool
    private let makeSignposter: @Sendable () -> OSSignposter
    private let storage = LockIsolated<OSSignposter?>(nil)

    init(isEnabled: @escaping @Sendable () -> Bool, makeSignposter: @escaping @Sendable () -> OSSignposter) {
        self.isEnabled = isEnabled
        self.makeSignposter = makeSignposter
    }

    var hasCreatedSignposter: Bool {
        storage.withLock { $0 != nil }
    }

    private var signposter: OSSignposter {
        if let existing = storage.value {
            return existing
        }
        let created = makeSignposter()
        return storage.withLock { stored in
            if let stored {
                return stored
            }
            stored = created
            return created
        }
    }

    func interval<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        guard isEnabled() else { return try work() }
        let signposter = signposter
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try work()
    }

    func beginInterval(_ name: StaticString) -> Interval? {
        guard isEnabled() else { return nil }
        let signposter = signposter
        let id = signposter.makeSignpostID()
        return Interval(signposter: signposter, name: name, id: id, state: signposter.beginInterval(name, id: id))
    }

    struct Interval {
        let signposter: OSSignposter
        let name: StaticString
        let id: OSSignpostID
        let state: OSSignpostIntervalState

        func resumed(byteCount: Int) {
            signposter.emitEvent(name, id: id, "Resumed with \(byteCount, privacy: .public) bytes")
        }

        func end(_ outcome: Outcome) {
            switch outcome {
            case .finished(let byteCount):
                signposter.endInterval(name, state, "Finished with \(byteCount, privacy: .public) bytes")
            case .cancelled:
                signposter.endInterval(name, state, "Cancelled")
            case .failed:
                signposter.endInterval(name, state, "Failed")
            }
        }
    }

    enum Outcome: Equatable {
        case finished(byteCount: Int)
        case cancelled
        case failed
    }
}
