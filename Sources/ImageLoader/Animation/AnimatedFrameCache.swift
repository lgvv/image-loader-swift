import CoreGraphics
import Foundation
import UIKit

struct AnimatedFrameKey: Hashable, Sendable {
    let sourceID: UInt64
    let index: Int
}

struct AnimatedFrameFootprint: Hashable, Sendable {
    let frameCount: Int
    let decodedCost: Int
    let playhead: Int
}

/// 애니메이션 프레임을 보관하는 캐시입니다.
///
/// 한도를 넘으면 오래 쓰지 않은 프레임부터 지웁니다. 애니메이션 하나의 프레임이 한도보다 크면, 재생 위치에서 가장 늦게 다시 보일 프레임부터 지워
/// 재생 중인 부근의 프레임을 남깁니다. 메모리 경고를 받으면 모두 비웁니다.
public final class AnimatedFrameCache: Sendable {
    /// ``ImageDecoders/Animated``가 기본으로 쓰는 캐시입니다. 한도는 32MB입니다.
    public static let shared = AnimatedFrameCache(costLimit: 32 * 1024 * 1024)

    enum EvictionPolicy: Sendable {
        case leastRecentlyUsed
        case windowForOversizedSources
        case windowForAllSources
    }

    private struct Entry {
        let key: AnimatedFrameKey
        let frame: CGImage
        let cost: Int
    }

    private typealias Node = LinkedList<Entry>.Node

    private struct State {
        var buckets: [UInt64: [Int: Node]] = [:]
        var list = LinkedList<Entry>()
        var totalCost = 0
        var costLimit: Int

        func node(for key: AnimatedFrameKey) -> Node? {
            buckets[key.sourceID]?[key.index]
        }

        mutating func append(_ entry: Entry) {
            buckets[entry.key.sourceID, default: [:]][entry.key.index] = list.append(entry)
            totalCost += entry.cost
        }

        mutating func remove(_ node: Node) {
            let key = node.value.key
            list.remove(node)
            buckets[key.sourceID]?[key.index] = nil
            if buckets[key.sourceID]?.isEmpty == true {
                buckets[key.sourceID] = nil
            }
            totalCost -= node.value.cost
        }
    }

    private static let backwardScanLimit = 64

    private let state: LockIsolated<State>
    private let policy: EvictionPolicy
    private let notificationCenter: NotificationCenter
    private let memoryWarningObserver = LockIsolated<(any NSObjectProtocol)?>(nil)

    /// 한도를 정해 캐시를 만듭니다.
    ///
    /// - Parameter costLimit: 보관할 수 있는 최대 바이트 수입니다. 디코딩한 비트맵 크기로 셉니다.
    public convenience init(costLimit: Int) {
        self.init(costLimit: costLimit, notificationCenter: .default)
    }

    init(costLimit: Int, notificationCenter: NotificationCenter, policy: EvictionPolicy = .windowForOversizedSources) {
        state = LockIsolated(State(costLimit: max(0, costLimit)))
        self.policy = policy
        self.notificationCenter = notificationCenter
        let observer = notificationCenter.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.removeAll()
        }
        memoryWarningObserver.withLock { $0 = observer }
    }

    deinit {
        if let observer = memoryWarningObserver.value {
            notificationCenter.removeObserver(observer)
        }
    }

    /// 보관할 수 있는 최대 바이트 수입니다. 줄이면 넘친 만큼 바로 지웁니다.
    public var costLimit: Int {
        get {
            state.withLock { $0.costLimit }
        }
        set {
            let evicted = state.withLock { state -> [Entry] in
                state.costLimit = max(0, newValue)
                return Self.trim(&state, protecting: nil)
            }
            withExtendedLifetime(evicted) {}
        }
    }

    /// 지금 보관한 프레임의 바이트 수 합계입니다.
    public var totalCost: Int {
        state.withLock { $0.totalCost }
    }

    /// 지금 보관한 프레임 수입니다.
    public var count: Int {
        state.withLock { $0.list.count }
    }

    /// 모든 프레임을 지웁니다. 재생 중인 애니메이션은 다음 프레임부터 다시 디코딩합니다.
    public func removeAll() {
        let removed = state.withLock { state -> LinkedList<Entry> in
            let list = state.list
            state.buckets = [:]
            state.list = LinkedList<Entry>()
            state.totalCost = 0
            return list
        }
        withExtendedLifetime(removed) {}
    }

    func frame(for key: AnimatedFrameKey) -> CGImage? {
        state.withLock { state -> CGImage? in
            guard let node = state.node(for: key) else {
                return nil
            }
            state.list.moveToLast(node)
            return node.value.frame
        }
    }

    func contains(_ key: AnimatedFrameKey) -> Bool {
        state.withLock { $0.node(for: key) != nil }
    }

    func cachedFrameCount(of sourceID: UInt64) -> Int {
        state.withLock { $0.buckets[sourceID]?.count ?? 0 }
    }

    var leafLockNestingCount: Int {
        state.nestedAcquisitionCount + memoryWarningObserver.nestedAcquisitionCount
    }

    func insert(_ frame: CGImage, for key: AnimatedFrameKey, footprint: AnimatedFrameFootprint? = nil) {
        let entry = Entry(key: key, frame: frame, cost: Bitmap.cost(of: frame))
        let policy = policy
        let evicted = state.withLock { state -> [Entry] in
            var evicted: [Entry] = []
            if let previous = state.node(for: key) {
                state.remove(previous)
                evicted.append(previous.value)
            }
            state.append(entry)
            if let footprint, Self.usesWindow(policy, footprint: footprint, costLimit: state.costLimit) {
                evicted += Self.evictOwnFrames(&state, inserting: key, footprint: footprint)
            }
            evicted += Self.trim(&state, protecting: key)
            return evicted
        }
        withExtendedLifetime(evicted) {}
    }

    func removeFrames(of sourceID: UInt64) {
        let removed = state.withLock { state -> [Entry] in
            guard let bucket = state.buckets[sourceID] else {
                return []
            }
            var removed: [Entry] = []
            removed.reserveCapacity(bucket.count)
            for node in bucket.values {
                state.remove(node)
                removed.append(node.value)
            }
            return removed
        }
        withExtendedLifetime(removed) {}
    }

    private static func usesWindow(_ policy: EvictionPolicy, footprint: AnimatedFrameFootprint, costLimit: Int) -> Bool {
        switch policy {
        case .leastRecentlyUsed:
            false
        case .windowForOversizedSources:
            footprint.decodedCost > costLimit
        case .windowForAllSources:
            true
        }
    }

    private static func evictOwnFrames(_ state: inout State, inserting key: AnimatedFrameKey, footprint: AnimatedFrameFootprint) -> [Entry] {
        var evicted: [Entry] = []
        while state.totalCost > state.costLimit,
            let bucket = state.buckets[key.sourceID], bucket.count > 1,
            let victim = farthestUntilNextUse(in: bucket, protecting: key.index, footprint: footprint)
        {
            state.remove(victim)
            evicted.append(victim.value)
        }
        return evicted
    }

    private static func farthestUntilNextUse(in bucket: [Int: Node], protecting protectedIndex: Int, footprint: AnimatedFrameFootprint) -> Node? {
        let frameCount = footprint.frameCount
        guard frameCount > 1 else {
            return nil
        }
        let playhead = ((footprint.playhead % frameCount) + frameCount) % frameCount
        for distance in 1..<min(frameCount, backwardScanLimit + 1) {
            let candidate = ((playhead - distance) % frameCount + frameCount) % frameCount
            if candidate != protectedIndex, let node = bucket[candidate] {
                return node
            }
        }
        var best: (node: Node, distance: Int)?
        for (candidate, node) in bucket where candidate != protectedIndex {
            let distance = ((candidate - playhead) % frameCount + frameCount) % frameCount
            if best.map({ distance > $0.distance }) ?? true {
                best = (node, distance)
            }
        }
        return best?.node
    }

    private static func trim(_ state: inout State, protecting protectedKey: AnimatedFrameKey?) -> [Entry] {
        guard state.totalCost > state.costLimit else {
            return []
        }
        let target = state.costLimit - state.costLimit / 10
        var evicted: [Entry] = []
        var node = state.list.first
        while state.totalCost > target, let current = node {
            node = current.next
            guard current.value.key != protectedKey else {
                continue
            }
            state.remove(current)
            evicted.append(current.value)
        }
        return evicted
    }
}
