import Foundation

extension DiskCache {
    struct Settings {
        var sizeLimit = 150 * 1024 * 1024
        var ageLimit: TimeInterval?
        var sweepInterval: TimeInterval = 1800
        var isSweepEnabled = true
        var trimRatio = 0.7
        var flushInterval: TimeInterval = 1
        var maximumEntrySize: Int?
        var maximumStagedBytes = 32 * 1024 * 1024
    }

    struct Staging {
        enum Change {
            case add(Data)
            case remove
        }

        struct Entry {
            let id: UInt64
            let change: Change
        }

        private(set) var entries: [String: Entry] = [:]
        private(set) var removeAllId: UInt64?
        private(set) var stagedBytes = 0
        private var nextId: UInt64 = 0

        var isEmpty: Bool {
            entries.isEmpty && removeAllId == nil
        }

        mutating func add(_ data: Data, for name: String) {
            replace(name, with: .add(data))
            stagedBytes += data.count
        }

        mutating func remove(_ name: String) {
            replace(name, with: .remove)
        }

        mutating func removeAll() {
            nextId += 1
            entries.removeAll()
            stagedBytes = 0
            removeAllId = nextId
        }

        func lookup(_ name: String) -> Change? {
            if let entry = entries[name] {
                return entry.change
            }
            return removeAllId == nil ? nil : .remove
        }

        func snapshot(for name: String) -> Staging? {
            guard removeAllId == nil, let entry = entries[name] else { return nil }
            var snapshot = Staging()
            snapshot.entries[name] = entry
            return snapshot
        }

        mutating func flushed(_ snapshot: Staging) {
            if let id = snapshot.removeAllId, removeAllId == id {
                removeAllId = nil
            }
            for (name, entry) in snapshot.entries where entries[name]?.id == entry.id {
                if case .add(let data) = entry.change {
                    stagedBytes -= data.count
                }
                entries[name] = nil
            }
        }

        private mutating func replace(_ name: String, with change: Change) {
            nextId += 1
            if case .add(let previous) = entries[name]?.change {
                stagedBytes -= previous.count
            }
            entries[name] = Entry(id: nextId, change: change)
        }
    }

    struct Index {
        struct Entry {
            var size: Int
            var accessTime: TimeInterval
            let generation: UInt64
            fileprivate let slot: Int
        }

        private struct Node {
            var name: String
            var previous: Int
            var next: Int
        }

        private(set) var entries: [String: Entry] = [:]
        private(set) var totalSize = 0
        private var nodes: [Node] = []
        private var freeSlots: [Int] = []
        private var head = -1
        private var tail = -1
        private var nextGeneration: UInt64 = 0

        init() {}

        init(files: [DiskCacheFile.ScannedFile]) {
            entries.reserveCapacity(files.count)
            nodes.reserveCapacity(files.count)
            for file in files.sorted(by: { $0.modified < $1.modified }) {
                set(file.name, size: file.size, accessTime: file.modified)
            }
        }

        var leastRecentlyUsedNames: [String] {
            var names: [String] = []
            names.reserveCapacity(entries.count)
            var slot = head
            while slot >= 0 {
                names.append(nodes[slot].name)
                slot = nodes[slot].next
            }
            return names
        }

        mutating func set(_ name: String, size: Int, accessTime: TimeInterval) {
            nextGeneration += 1
            let slot: Int
            if let previous = entries[name] {
                totalSize -= previous.size
                slot = previous.slot
                moveToTail(slot)
            } else {
                slot = appendNode(name)
            }
            entries[name] = Entry(size: size, accessTime: accessTime, generation: nextGeneration, slot: slot)
            totalSize += size
        }

        @discardableResult
        mutating func remove(_ name: String) -> Entry? {
            guard let entry = entries.removeValue(forKey: name) else { return nil }
            totalSize -= entry.size
            unlink(entry.slot)
            nodes[entry.slot].name = ""
            freeSlots.append(entry.slot)
            return entry
        }

        mutating func touch(_ name: String, at time: TimeInterval) {
            guard let entry = entries[name] else { return }
            moveToTail(entry.slot)
            if time > entry.accessTime {
                entries[name]?.accessTime = time
            }
        }

        mutating func removeLeastRecentlyUsed(untilSizeAtMost target: Int, limit: Int) -> [String] {
            var victims: [String] = []
            while totalSize > target, victims.count < limit, head >= 0 {
                let name = nodes[head].name
                remove(name)
                victims.append(name)
            }
            return victims
        }

        mutating func removeEntries(accessedBefore cutoff: TimeInterval) -> [String] {
            let victims = entries.compactMap { $0.value.accessTime < cutoff ? $0.key : nil }
            for name in victims {
                remove(name)
            }
            return victims
        }

        private mutating func appendNode(_ name: String) -> Int {
            let node = Node(name: name, previous: tail, next: -1)
            let slot: Int
            if let reused = freeSlots.popLast() {
                nodes[reused] = node
                slot = reused
            } else {
                nodes.append(node)
                slot = nodes.count - 1
            }
            if tail >= 0 {
                nodes[tail].next = slot
            } else {
                head = slot
            }
            tail = slot
            return slot
        }

        private mutating func unlink(_ slot: Int) {
            let previous = nodes[slot].previous
            let next = nodes[slot].next
            if previous >= 0 {
                nodes[previous].next = next
            } else {
                head = next
            }
            if next >= 0 {
                nodes[next].previous = previous
            } else {
                tail = previous
            }
            nodes[slot].previous = -1
            nodes[slot].next = -1
        }

        private mutating func moveToTail(_ slot: Int) {
            guard slot != tail else { return }
            unlink(slot)
            nodes[slot].previous = tail
            if tail >= 0 {
                nodes[tail].next = slot
            } else {
                head = slot
            }
            tail = slot
        }
    }

    enum Lookup {
        case staged(Data)
        case missing
        case indexed(generation: UInt64)
        case unknown
    }

    enum FlushTrigger {
        case timer
        case immediate
        case manual
    }

    enum FlushSchedule {
        case none
        case immediate
        case delayed(TimeInterval)
    }

    enum WriteOutcome {
        case stored(Int)
        case removed
    }

    struct State {
        var settings = Settings()
        var staging = Staging()
        var index: Index?
        var pendingTouches: [String: TimeInterval] = [:]
        var isActivated = false
        var isFlushScheduled = false
        var isImmediateFlushScheduled = false
        var isIndexBuildScheduled = false

        func lookup(_ name: String) -> Lookup {
            switch staging.lookup(name) {
            case .add(let data):
                return .staged(data)
            case .remove:
                return .missing
            case nil:
                guard let index else { return .unknown }
                guard let entry = index.entries[name] else { return .missing }
                return .indexed(generation: entry.generation)
            }
        }

        mutating func scheduleFlush(isUrgent: Bool) -> FlushSchedule {
            if isUrgent || staging.stagedBytes > settings.maximumStagedBytes {
                guard !isImmediateFlushScheduled else { return .none }
                isImmediateFlushScheduled = true
                return .immediate
            }
            guard !isFlushScheduled else { return .none }
            isFlushScheduled = true
            return .delayed(settings.flushInterval)
        }

        func totals() -> (count: Int, size: Int) {
            let base = staging.removeAllId == nil ? index : nil
            var count = base?.entries.count ?? 0
            var size = base?.totalSize ?? 0
            for (name, entry) in staging.entries {
                let existing = base?.entries[name]
                switch entry.change {
                case .add(let data):
                    size += data.count - (existing?.size ?? 0)
                    if existing == nil {
                        count += 1
                    }
                case .remove:
                    if let existing {
                        size -= existing.size
                        count -= 1
                    }
                }
            }
            return (count, size)
        }
    }

    struct Failures {
        private(set) var items: [(operation: ImageSession.DiskCacheOperation, error: any Swift.Error)] = []

        var isEmpty: Bool {
            items.isEmpty
        }

        mutating func record(_ operation: ImageSession.DiskCacheOperation, _ error: any Swift.Error) {
            guard !items.contains(where: { $0.operation == operation }) else { return }
            items.append((operation, error))
        }
    }
}
