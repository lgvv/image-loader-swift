import Foundation
import UIKit

/// 메모리 압박과 앱 상태 변화에 ``MemoryCache``가 어떻게 대응할지 정합니다.
public struct MemoryCacheLifecyclePolicy: Hashable, Sendable {
    /// 메모리 압박이 오면 캐시를 모두 비울지 정합니다. 기본값은 `true`입니다.
    ///
    /// 켜 두면 시스템이 심각한 압박을 알릴 때 항상 비웁니다. 경고 단계에서는 ``pressureWarningTrimRatio``가 `nil`일 때만 비웁니다.
    public var purgesOnMemoryPressure: Bool
    /// 메모리 압박 경고를 받았을 때 캐시를 모두 비우지 않고 줄일 비율입니다. 기본값은 `nil`입니다.
    ///
    /// 0.5를 넣으면 비용과 개수를 한도의 절반까지 줄입니다. 30초 안에 경고가 다시 오면 한 번만 줄입니다.
    public var pressureWarningTrimRatio: Double?
    /// `UIApplication.didReceiveMemoryWarningNotification`을 받았을 때도 캐시를 비울지 정합니다. 기본값은 `false`입니다.
    public var observesApplicationMemoryWarning: Bool
    /// 앱이 백그라운드로 갈 때 캐시를 줄일 비율입니다. 기본값은 0.1이고, 한도의 10%만 남깁니다. `nil`이면 줄이지 않습니다.
    public var backgroundTrimRatio: Double?

    /// 대응 방식을 정해 정책을 만듭니다. 각 값의 뜻은 같은 이름의 프로퍼티를 확인해 주세요.
    public init(
        purgesOnMemoryPressure: Bool = true,
        pressureWarningTrimRatio: Double? = nil,
        observesApplicationMemoryWarning: Bool = false,
        backgroundTrimRatio: Double? = 0.1
    ) {
        self.purgesOnMemoryPressure = purgesOnMemoryPressure
        self.pressureWarningTrimRatio = pressureWarningTrimRatio
        self.observesApplicationMemoryWarning = observesApplicationMemoryWarning
        self.backgroundTrimRatio = backgroundTrimRatio
    }
}

/// 디코딩한 이미지를 메모리에 보관하는 캐시입니다.
///
/// 한도를 넘으면 오래 쓰지 않은 이미지부터 지웁니다. 최근에 읽은 이미지는 한 번 더 남겨 두므로, 한 번 훑고 지나간 이미지가 자주 쓰는 이미지를 밀어내지 않습니다.
/// 메모리 압박이 오면 ``lifecyclePolicy``에 따라 줄이거나 비웁니다.
public final class MemoryCache: MemoryCaching {
    /// 세션이 기본으로 쓰는 캐시입니다. 한도는 ``defaultCostLimit()``입니다.
    public static let shared = MemoryCache()

    private let state: LockIsolated<MemoryCacheStorage>
    private let disposalQueue: DispatchQueue
    private let diagnosticHandlers = LockIsolated<[@Sendable (ImageSession.Diagnostic) -> Void]>([])

    /// 한도를 정해 캐시를 만듭니다.
    ///
    /// - Parameters:
    ///   - costLimit: 보관할 수 있는 최대 바이트 수입니다. 디코딩한 비트맵 크기로 셉니다.
    ///   - countLimit: 보관할 수 있는 최대 이미지 수입니다. 기본값은 제한 없음입니다.
    public init(costLimit: Int = MemoryCache.defaultCostLimit(), countLimit: Int = Int.max) {
        state = LockIsolated(MemoryCacheStorage(costLimit: costLimit, countLimit: countLimit, clock: Self.expirationClock))
        disposalQueue = Self.releaseQueue
        MemoryPressureMonitor.shared.register(self)
    }

    init(
        costLimit: Int = MemoryCache.defaultCostLimit(),
        countLimit: Int = Int.max,
        clock: any SessionClock,
        monitor: MemoryPressureMonitor = .shared,
        releaseQueue: DispatchQueue = MemoryCache.releaseQueue
    ) {
        state = LockIsolated(MemoryCacheStorage(costLimit: costLimit, countLimit: countLimit, clock: clock))
        disposalQueue = releaseQueue
        monitor.register(self)
    }

    deinit {
        mutate { $0.removeAll(disposal: &$1) }
    }

    static let weakCacheDataSweepThreshold = 4 * 1024 * 1024

    static let weakSweepBatchSize = 256

    static let evictionBatchSize = 256

    static let pressureWarningTrimInterval: TimeInterval = 30

    static let recoveryWindow: TimeInterval = 10

    static func maximumAdmissionVisits(evictionsNeeded: Int) -> Int {
        max(16, evictionsNeeded.multipliedReportingOverflow(by: 2).overflow ? Int.max : evictionsNeeded * 2)
    }

    static let releaseQueue = DispatchQueue(label: "ImageLoader.MemoryCache.release", qos: .utility)

    static let expirationClock: any SessionClock = SystemClock()

    /// 기기 메모리의 15%와 768MB 중 작은 값을 돌려줍니다. 메모리가 4GB인 기기는 약 614MB입니다.
    public static func defaultCostLimit() -> Int {
        let calculated = Double(ProcessInfo.processInfo.physicalMemory) * 0.15
        return min(MemoryCacheStorage.integer(calculated), 805_306_368)
    }

    /// 보관할 수 있는 최대 바이트 수입니다. 줄이면 넘친 만큼 바로 지웁니다.
    public var costLimit: Int {
        get { state.withLock { $0.costLimit } }
        set {
            state.withLock { $0.costLimit = newValue }
            trimIncrementally(.limits)
        }
    }

    /// 보관할 수 있는 최대 이미지 수입니다. 줄이면 넘친 만큼 바로 지웁니다.
    public var countLimit: Int {
        get { state.withLock { $0.countLimit } }
        set {
            state.withLock { $0.countLimit = newValue }
            trimIncrementally(.limits)
        }
    }

    /// 이미지 하나가 ``costLimit``에서 차지할 수 있는 최대 비율입니다. 기본값은 0.1입니다.
    ///
    /// 이보다 큰 이미지는 캐시에 넣지 않습니다. 큰 이미지 하나가 작은 이미지 여러 개를 밀어내지 않게 합니다.
    public var entryCostLimit: Double {
        get { state.withLock { $0.entryCostLimit } }
        set {
            state.withLock { $0.entryCostLimit = newValue }
            trimIncrementally(.limits)
        }
    }

    /// 이미지를 넣은 뒤 보관할 최대 초입니다. 지나면 읽을 때 지웁니다. 기본값은 `nil`이고, 시간으로는 지우지 않습니다.
    public var ttl: TimeInterval? {
        get { state.withLock { $0.ttl } }
        set { state.withLock { $0.ttl = newValue } }
    }

    /// 한도 때문에 지운 이미지를 다른 곳에서 아직 쓰고 있으면 다시 꺼내 쓸지 정합니다. 기본값은 `false`입니다.
    ///
    /// 켜면 지운 이미지를 약한 참조로 기억합니다. 뷰가 아직 그 이미지를 들고 있으면 다시 디코딩하지 않고 캐시로 되돌립니다.
    public var isWeakCacheEnabled: Bool {
        get { state.withLock { $0.isWeakCacheEnabled } }
        set { mutate { $0.setWeakCacheEnabled(newValue, disposal: &$1) } }
    }

    /// 메모리 압박과 앱 상태 변화에 대응하는 방식입니다.
    public var lifecyclePolicy: MemoryCacheLifecyclePolicy {
        get { state.withLock { $0.lifecyclePolicy } }
        set { state.withLock { $0.lifecyclePolicy = newValue } }
    }

    /// 지금 보관한 이미지의 바이트 수 합계입니다.
    public var totalCost: Int {
        state.withLock { $0.totalCost }
    }

    /// 지금 보관한 이미지 수입니다.
    public var totalCount: Int {
        state.withLock { $0.count }
    }

    /// 키의 이미지를 읽거나 씁니다. `nil`을 넣으면 지웁니다.
    ///
    /// 넣은 이미지가 ``entryCostLimit``를 넘으면 저장하지 않습니다. 넣은 뒤 한도를 넘으면 백그라운드에서 오래 쓰지 않은 이미지부터 지웁니다.
    public subscript(key: MemoryCacheKey) -> ImageContent? {
        get {
            mutate { $0.value(forKey: key, disposal: &$1) }
        }
        set {
            guard let newValue else {
                mutate { $0.removeValue(forKey: key, disposal: &$1) }
                return
            }
            let cost = Self.cost(for: newValue)
            let needsTrim = mutate { storage, disposal in
                storage.insert(newValue, cost: cost, forKey: key, disposal: &disposal)
            }
            if needsTrim {
                disposalQueue.async { [weak self] in
                    guard let self else { return }
                    self.trimIncrementally(.limits)
                    self.state.withLock { $0.didFinishOverflowTrim() }
                }
            }
        }
    }

    func noteDiskReload(forKey key: MemoryCacheKey) {
        state.withLock { $0.noteDiskReload(forKey: key) }
    }

    func finishRecoveryIfDue() {
        guard let window = state.withLock({ $0.takeRecoveryIfDue() }) else { return }
        report(window.diagnostic)
    }

    /// 모든 이미지를 지웁니다.
    public func removeAll() {
        mutate { $0.removeAll(disposal: &$1) }
    }

    /// 바이트 수 합계가 `limit` 이하가 될 때까지 오래 쓰지 않은 이미지부터 지웁니다. ``costLimit``는 바꾸지 않습니다.
    public func trim(toCost limit: Int) {
        trimIncrementally(.fixed(cost: limit, count: Int.max))
    }

    /// 이미지 수가 `limit` 이하가 될 때까지 오래 쓰지 않은 이미지부터 지웁니다. ``countLimit``는 바꾸지 않습니다.
    public func trim(toCount limit: Int) {
        trimIncrementally(.fixed(cost: Int.max, count: limit))
    }

    static func cost(for content: ImageContent) -> Int {
        let dataCost = content.data?.count ?? 0
        guard let cgImage = content.image.cgImage else {
            return 1 + dataCost
        }
        return Bitmap.cost(of: cgImage) + dataCost
    }

    var weakCacheCount: Int {
        state.withLock { $0.weakOnlyCount }
    }

    var weakCacheDataBytes: Int {
        state.withLock { $0.weakOnlyDataBytes }
    }

    var workStatistics: WorkStatistics {
        state.withLock { $0.workStatistics }
    }

    func consistencyReport() -> ConsistencyReport {
        state.withLock { $0.consistencyReport() }
    }

    struct WorkStatistics: Equatable {
        var operations = 0
        var largestSweepBatch = 0
        var sweepVisits = 0
        var largestEvictionBatch = 0
    }

    struct ConsistencyReport: Equatable {
        var recordedCost: Int
        var summedCost: Int
        var count: Int
        var linkedCount: Int
        var isLinkedConsistently: Bool
        var unmirroredEntryCount: Int
        var recordedRemnantDataBytes: Int
        var summedRemnantDataBytes: Int
        var recordedWeakOnlyCount: Int
        var summedWeakOnlyCount: Int
        var recordedWeakOnlyDataBytes: Int
        var summedWeakOnlyDataBytes: Int
    }

    private func mutate<T>(_ body: (inout MemoryCacheStorage, inout MemoryCacheDisposal) -> T) -> T {
        var disposal = MemoryCacheDisposal()
        let result = state.withLock { body(&$0, &disposal) }
        disposal.release()
        return result
    }

    @discardableResult
    private func trimIncrementally(_ target: MemoryCacheTrimTarget) -> (entryCount: Int, cost: Int) {
        let before = state.withLock { ($0.count, $0.totalCost) }
        while mutate({ $0.trimStep(toward: target, disposal: &$1) }) {}
        let after = state.withLock { ($0.count, $0.totalCost) }
        return (max(0, before.0 - after.0), max(0, before.1 - after.1))
    }

    private func trimInBackground(_ target: MemoryCacheTrimTarget, report: @escaping @Sendable (Int, Int) -> ImageSession.Diagnostic) {
        disposalQueue.async { [weak self] in
            guard let self else { return }
            let removed = self.trimIncrementally(target)
            if removed.entryCount > 0 {
                self.report(report(removed.entryCount, removed.cost))
            }
        }
    }

    func installDiagnosticHandlerIfNeeded(_ handler: @escaping @Sendable (ImageSession.Diagnostic) -> Void) {
        diagnosticHandlers.withLock { $0.append(handler) }
    }

    func waitForLifecycleWork() {
        disposalQueue.sync {}
    }

    private func report(_ diagnostic: ImageSession.Diagnostic) {
        for handler in diagnosticHandlers.value {
            handler(diagnostic)
        }
    }

    private func finishPurge(sweeping keys: [MemoryCacheKey]) {
        state.withLock { $0.didReleasePurgedEntries() }
        var start = keys.startIndex
        while start < keys.endIndex {
            let end = min(start + Self.weakSweepBatchSize, keys.endIndex)
            mutate { $0.sweepPurgedRemnants(forKeys: keys[start..<end], disposal: &$1) }
            start = end
        }
        state.withLock { $0.resetRemnantSweepThresholds() }
    }
}

extension MemoryCache: MemoryPressureResponding {
    func didReceiveMemoryPressure(_ event: MemoryPressureEvent) {
        switch state.withLock({ $0.respond(to: event) }) {
        case .ignored:
            return
        case .trim(let cost, let count):
            trimInBackground(.fixed(cost: cost, count: count)) { .memoryPressureTrim(entryCount: $0, cost: $1) }
        case .purged(let detached, let entryCount, let cost, let sweepsRemnants, let reason):
            report(.memoryPressurePurge(reason: reason.diagnosticReason, entryCount: entryCount, cost: cost))
            disposalQueue.async { [weak self] in
                let keys = autoreleasepool { detached.release() }
                guard let self else { return }
                self.finishPurge(sweeping: sweepsRemnants ? keys : [])
                let pending = Set(keys)
                if let previous = self.state.withLock({ $0.beginRecovery(reason: reason, pending: pending) }) {
                    self.report(previous.diagnostic)
                }
                self.disposalQueue.asyncAfter(deadline: SystemClock.dispatchDeadline(after: Self.recoveryWindow)) { [weak self] in
                    self?.finishRecoveryIfDue()
                }
            }
        }
    }

    func didEnterBackground() {
        guard let target = state.withLock({ $0.backgroundTrimTarget() }) else {
            return
        }
        trimInBackground(target) { .backgroundTrim(entryCount: $0, cost: $1) }
    }
}
