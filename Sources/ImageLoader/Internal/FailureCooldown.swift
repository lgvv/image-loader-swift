import Foundation

extension ImageSession {
    /// 같은 이미지에서 실패가 이어질 때 잠시 요청을 막는 정책입니다.
    ///
    /// 깨진 주소를 담은 셀이 스크롤할 때마다 다시 요청해 네트워크와 배터리를 쓰는 일을 막습니다.
    /// 실패할 때마다 막는 시간을 두 배로 늘리고(2초, 4초, 8초 순서), 한 번 성공하면 기록을 지웁니다.
    /// 막힌 요청은 네트워크에 보내지 않고 ``Error/dataLoadingFailed(error:)``로 바로 끝나며, 원인은 ``FailureCooldownError``입니다.
    public struct FailureCooldownPolicy: Sendable {
        /// 첫 실패 뒤 막는 시간입니다. 기본값은 2초입니다.
        public var baseInterval: TimeInterval
        /// 막는 시간의 상한입니다. 기본값은 300초입니다.
        public var maximumInterval: TimeInterval
        /// 기록해 둘 이미지 수입니다. 기본값은 512개이고, 넘으면 가장 오래된 기록부터 지웁니다.
        public var countLimit: Int
        /// 이 오류로 실패했을 때 막을지 정합니다. 기본값은 ``defaultShouldCooldown``입니다.
        public var shouldCooldown: @Sendable (ImageSession.Error) -> Bool

        /// 정책을 만듭니다.
        ///
        /// - Parameters:
        ///   - baseInterval: 첫 실패 뒤 막는 시간입니다.
        ///   - maximumInterval: 막는 시간의 상한입니다.
        ///   - countLimit: 기록해 둘 이미지 수입니다. 1보다 작으면 1로 봅니다.
        ///   - shouldCooldown: 이 오류로 실패했을 때 막을지 정합니다.
        public init(
            baseInterval: TimeInterval = 2,
            maximumInterval: TimeInterval = 300,
            countLimit: Int = 512,
            shouldCooldown: @escaping @Sendable (ImageSession.Error) -> Bool = FailureCooldownPolicy.defaultShouldCooldown
        ) {
            self.baseInterval = baseInterval
            self.maximumInterval = maximumInterval
            self.countLimit = max(1, countLimit)
            self.shouldCooldown = shouldCooldown
        }

        /// 다시 시도해도 같은 결과가 나올 오류만 막습니다.
        ///
        /// 404처럼 408과 429를 뺀 4xx 상태 코드, 잘못된 주소처럼 일시적이지 않은 네트워크 오류, 빈 데이터, 크기 초과, 디코딩 실패가 해당합니다.
        /// 5xx 상태 코드와 시간 초과 같은 일시적인 오류, 취소, 디코딩 한도 초과는 막지 않습니다.
        public static let defaultShouldCooldown: @Sendable (ImageSession.Error) -> Bool = { error in
            error.failureClassification.isCooldownEligible
        }
    }

    /// ``FailureCooldownPolicy``가 요청을 막았다는 오류입니다. ``Error/cooldown``으로 꺼냅니다.
    public struct FailureCooldownError: Swift.Error, CustomStringConvertible, Sendable {
        /// 요청을 다시 보낼 수 있는 시각입니다.
        public let until: Date
        /// 지금까지 이어서 실패한 횟수입니다.
        public let failureCount: Int
        /// 마지막으로 실패했을 때의 오류입니다.
        public let lastError: ImageSession.Error

        public var description: String {
            "Request is in failure cooldown after \(failureCount) failures. Last error: \(lastError.diagnosticCode)."
        }
    }
}

enum FailureCooldownKey: Hashable, Sendable {
    case data(imageID: String)
    case decoding(imageID: String, scale: Float, thumbnail: ImageRequest.ThumbnailOptions?)

    static func dataUnit(for request: ImageRequest) -> FailureCooldownKey? {
        request.originalImageID.map { .data(imageID: $0) }
    }

    static func decodingUnit(for request: ImageRequest) -> FailureCooldownKey? {
        request.originalImageID.map { .decoding(imageID: $0, scale: request.scale, thumbnail: request.thumbnail) }
    }
}

final class FailureCooldownTable: @unchecked Sendable {
    private let policy: ImageSession.FailureCooldownPolicy
    let clock: any SessionClock
    private var entries: [FailureCooldownKey: LinkedList<Entry>.Node] = [:]
    private let order = LinkedList<Entry>()

    struct Entry {
        let key: FailureCooldownKey
        let failureCount: Int
        let until: TimeInterval
        let lastError: ImageSession.Error
    }

    init(policy: ImageSession.FailureCooldownPolicy, clock: any SessionClock) {
        self.policy = policy
        self.clock = clock
    }

    var count: Int {
        entries.count
    }

    func check(_ key: FailureCooldownKey) -> ImageSession.FailureCooldownError? {
        SessionQueue.assertOnQueue()
        guard let node = entries[key] else { return nil }
        let remaining = node.value.until - clock.monotonicIncludingSleep
        guard remaining > 0 else { return nil }
        return ImageSession.FailureCooldownError(
            until: clock.now.addingTimeInterval(remaining),
            failureCount: node.value.failureCount,
            lastError: node.value.lastError
        )
    }

    func recordFailure(_ key: FailureCooldownKey, error: ImageSession.Error) {
        SessionQueue.assertOnQueue()
        guard policy.shouldCooldown(error) else { return }
        var count = 1
        if let node = entries[key] {
            count = node.value.failureCount + 1
            order.remove(node)
        }
        let interval = min(policy.maximumInterval, policy.baseInterval * pow(2, Double(min(count - 1, 30))))
        entries[key] = order.append(Entry(key: key, failureCount: count, until: clock.monotonicIncludingSleep + interval, lastError: error))
        while order.count > policy.countLimit, let oldest = order.first {
            order.remove(oldest)
            entries[oldest.value.key] = nil
        }
    }

    func recordSuccess(_ key: FailureCooldownKey) {
        SessionQueue.assertOnQueue()
        guard let node = entries.removeValue(forKey: key) else { return }
        order.remove(node)
    }

    func removeAll() {
        SessionQueue.assertOnQueue()
        entries.removeAll()
        order.removeAllElements()
    }
}
