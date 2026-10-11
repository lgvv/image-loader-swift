import Foundation

/// 세션이 시각을 읽을 때 쓰는 시계입니다. 테스트에서 시간을 직접 움직일 때만 씁니다.
@_spi(Testing) public protocol SessionClock: Sendable {
    /// 현재 시각입니다.
    var now: Date { get }
    /// 기기가 잠든 시간까지 포함해 흐르는 초입니다. 시스템 시각을 바꿔도 거꾸로 가지 않습니다.
    var monotonicIncludingSleep: TimeInterval { get }
}

/// 세션이 작업을 미뤄 부를 때 쓰는 스케줄러입니다. 테스트에서 시간을 직접 움직일 때만 씁니다.
@_spi(Testing) public protocol SessionScheduler: Sendable {
    /// `seconds`초 뒤에 `work`를 부릅니다.
    func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void)
}

struct SystemClock: SessionClock, SessionScheduler {
    static let monotonicClockID = CLOCK_MONOTONIC

    let clockID: clockid_t

    init() {
        clockID = Self.monotonicClockID
    }

    init(clockID: clockid_t) {
        self.clockID = clockID
    }

    var now: Date {
        Date()
    }

    var monotonicIncludingSleep: TimeInterval {
        TimeInterval(clock_gettime_nsec_np(clockID)) / 1_000_000_000
    }

    func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        SessionQueue.asyncAfter(seconds, work)
    }

    static func dispatchDeadline(after delay: TimeInterval) -> DispatchTime {
        DispatchTime.now() + delay
    }

    static func dispatchDeadline(after delay: DispatchTimeInterval) -> DispatchTime {
        DispatchTime.now() + delay
    }
}
