import Foundation

final class RateLimiter: @unchecked Sendable {
    typealias Work = () -> Bool

    private var bucket: TokenBucket
    private let pending = LinkedList<Work>()
    private var isExecutingPendingTasks = false
    private let retryDelay: TimeInterval
    let clock: any SessionClock
    let scheduler: any SessionScheduler

    init(rate: Int = 80, burst: Int = 25, clock: any SessionClock = SystemClock(), scheduler: any SessionScheduler = SystemClock()) {
        self.clock = clock
        self.scheduler = scheduler
        bucket = TokenBucket(rate: Double(rate), burst: Double(burst), clock: clock)
        retryDelay = Double(min(100, max(15, Int(2.1 * 1000 / Double(rate))))) / 1000
    }

    func execute(_ work: @escaping Work) {
        SessionQueue.assertOnQueue()
        if !pending.isEmpty || !bucket.execute(work) {
            pending.append(work)
            setNeedsExecutePendingTasks()
        }
    }

    var pendingCount: Int {
        pending.count
    }

    private func setNeedsExecutePendingTasks() {
        guard !isExecutingPendingTasks else { return }
        isExecutingPendingTasks = true
        scheduler.schedule(after: retryDelay) { [self] in
            SessionQueue.performOrAsync { [self] in
                isExecutingPendingTasks = false
                executePendingTasks()
            }
        }
    }

    func executePendingTasks() {
        SessionQueue.assertOnQueue()
        while let node = pending.first, bucket.execute(node.value) {
            pending.remove(node)
        }
        if !pending.isEmpty {
            setNeedsExecutePendingTasks()
        }
    }

    private struct TokenBucket {
        let rate: Double
        let burst: Double
        let clock: any SessionClock
        private var tokens: Double
        private var timestamp: TimeInterval

        init(rate: Double, burst: Double, clock: any SessionClock) {
            self.rate = rate
            self.burst = burst
            self.clock = clock
            tokens = burst
            timestamp = clock.monotonicIncludingSleep
        }

        mutating func execute(_ work: () -> Bool) -> Bool {
            refill()
            guard tokens >= 1 else { return false }
            if work() {
                tokens -= 1
            }
            return true
        }

        private mutating func refill() {
            let now = clock.monotonicIncludingSleep
            tokens = min(burst, tokens + rate * max(0, now - timestamp))
            timestamp = now
        }
    }
}
