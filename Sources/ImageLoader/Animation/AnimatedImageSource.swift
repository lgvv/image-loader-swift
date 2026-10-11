import CoreGraphics
import Foundation
import ImageIO
import UIKit

extension ImageContent.UserInfoKey {
    /// ``ImageContent/userInfo``에 ``AnimatedImageSource``를 담는 키입니다.
    public static let animatedImageKey: ImageContent.UserInfoKey = "imageloader/animated-image-source"
}

extension ImageContent {
    /// 애니메이션 이미지의 프레임 소스입니다. 정지 이미지거나 필터를 적용했으면 `nil`입니다.
    public var animatedImageSource: AnimatedImageSource? {
        userInfo[.animatedImageKey] as? AnimatedImageSource
    }
}

/// 애니메이션 이미지의 프레임을 필요한 만큼 디코딩해 꺼내는 소스입니다.
///
/// 첫 프레임은 항상 들고 있고, 나머지 프레임은 요청할 때 디코딩해 ``AnimatedFrameCache``에 넣습니다.
/// 200프레임짜리 GIF도 재생 중인 부근의 프레임만 메모리에 둡니다.
/// 디코딩에 두 번 실패한 프레임은 다시 디코딩하지 않고 건너뜁니다.
public final class AnimatedImageSource: Sendable {
    /// 프레임 수입니다. 항상 2 이상입니다.
    public let frameCount: Int
    /// 반복 횟수입니다. 0이면 계속 반복합니다.
    ///
    /// 파일에 값이 없으면 GIF는 1, APNG와 WebP는 0으로 봅니다.
    public let loopCount: Int
    /// 프레임마다 보여 줄 초입니다.
    ///
    /// 파일에 적힌 값이 0.01초 이하이거나 없으면 0.1초로 바꿉니다.
    public let frameDurations: [TimeInterval]
    /// 원본 데이터의 바이트 수입니다.
    public let dataByteCount: Int
    /// 프레임을 `UIImage`로 만들 때 쓰는 배율입니다. ``ImageRequest/scale``과 같습니다.
    public let scale: CGFloat
    let firstFrame: CGImage

    nonisolated(unsafe) private let imageSource: CGImageSource
    private let decodeLock = AnimatedFrameDecodeLock()
    private let frameDecision: ImageRequest.ThumbnailOptions.Decision
    private let thumbnail: ImageRequest.ThumbnailOptions?
    private let frameCache: AnimatedFrameCache
    let sourceID: UInt64
    private let decodedCost: Int
    private let decodeQueue: DispatchQueue
    private let state = LockIsolated(State())
    private let willDecodeFrame = LockIsolated<(@Sendable (Int) -> Void)?>(nil)
    private let simulatedDecodeFailures = LockIsolated<Set<Int>>([])

    private struct State {
        var pending: Set<Int> = []
        var inFlight: [Int: FrameDecodeWaiter] = [:]
        var failureCounts: [Int: Int] = [:]
        var failedFrames: Set<Int> = []
        var decodeCount = 1
        var sharedDecodeWaitCount = 0
        var playhead = 0
    }

    private enum Claim {
        case failed
        case wait(FrameDecodeWaiter)
        case decode(FrameDecodeWaiter)
    }

    static let maximumDecodeAttempts = 2

    convenience init?(data: Data, scale: CGFloat, thumbnail: ImageRequest.ThumbnailOptions?, frameCache: AnimatedFrameCache = .shared) {
        guard let probe = AnimatedImageProbe(data: data) else {
            return nil
        }
        let decision = thumbnail?.decision(for: ImageHeader.properties(of: probe.imageSource, at: 0)) ?? .original
        self.init(probe: probe, scale: scale, thumbnail: thumbnail, decision: decision, frameCache: frameCache)
    }

    init?(
        probe: AnimatedImageProbe,
        scale: CGFloat,
        thumbnail: ImageRequest.ThumbnailOptions?,
        decision: ImageRequest.ThumbnailOptions.Decision,
        frameCache: AnimatedFrameCache
    ) {
        let imageSource = probe.imageSource
        let frameCount = CGImageSourceGetCount(imageSource)
        guard frameCount > 1,
            let firstFrame = Self.makeFrame(source: imageSource, index: 0, decision: decision, thumbnail: thumbnail)
        else {
            return nil
        }
        self.imageSource = imageSource
        self.frameCount = frameCount
        self.firstFrame = firstFrame
        self.thumbnail = thumbnail
        self.frameCache = frameCache
        self.scale = scale
        dataByteCount = probe.data.count
        frameDecision = decision
        let product = Bitmap.cost(of: firstFrame).multipliedReportingOverflow(by: frameCount)
        decodedCost = product.overflow ? Int.max : product.partialValue
        (loopCount, frameDurations) = AnimatedImageMetadata.timing(source: imageSource, frameCount: frameCount, type: probe.type)
        sourceID = Self.makeSourceID()
        decodeQueue = Self.nextDecodeQueue()
    }

    deinit {
        let frameCache = frameCache
        let sourceID = sourceID
        SessionWorkers.release.async {
            frameCache.removeFrames(of: sourceID)
        }
    }

    /// 한 번 재생하는 데 걸리는 초입니다. ``frameDurations``의 합입니다.
    public var totalDuration: TimeInterval {
        frameDurations.reduce(0, +)
    }

    var memoryCost: Int {
        Bitmap.cost(of: firstFrame) + dataByteCount
    }

    /// 프레임을 보여 줄 초입니다. `index`가 범위를 벗어나면 ``frameCount``로 나눈 나머지 위치의 값을 돌려줍니다.
    public func frameDuration(at index: Int) -> TimeInterval {
        frameDurations[normalized(index)]
    }

    /// 이미 디코딩해 둔 프레임을 돌려줍니다. 디코딩하지 않으므로 메인 스레드에서 불러도 됩니다.
    ///
    /// 캐시에 없으면 `nil`입니다. 첫 프레임은 항상 돌려줍니다.
    public func cachedFrame(at index: Int) -> CGImage? {
        let index = normalized(index)
        state.withLock { $0.playhead = index }
        guard index != 0 else {
            return firstFrame
        }
        return frameCache.frame(for: key(for: index))
    }

    func decodeFrame(at index: Int) -> CGImage? {
        let index = normalized(index)
        guard index != 0 else {
            return firstFrame
        }
        let key = key(for: index)
        if let frame = frameCache.frame(for: key) {
            return frame
        }
        switch claim(index, sharesInFlightDecode: true) {
        case .failed:
            return nil
        case .wait(let waiter):
            return waiter.wait()
        case .decode(let waiter):
            let frame = decodeClaimedFrame(at: index, key: key)
            waiter.finish(frame)
            return frame
        }
    }

    /// 프레임을 돌려줍니다. 캐시에 없으면 백그라운드에서 디코딩한 뒤 돌려줍니다.
    ///
    /// 같은 프레임을 여러 곳에서 동시에 요청하면 한 번만 디코딩합니다. 디코딩에 실패한 프레임이면 `nil`입니다.
    public func frame(at index: Int) async -> CGImage? {
        if let frame = cachedFrame(at: index) {
            return frame
        }
        let index = normalized(index)
        return await withCheckedContinuation { continuation in
            requestFrame(at: index) { frame in
                continuation.resume(returning: frame)
            }
        }
    }

    /// 곧 보여 줄 프레임을 백그라운드에서 미리 디코딩합니다. 이미 캐시에 있거나 디코딩 중인 프레임은 건너뜁니다.
    public func prefetchFrames(_ indices: [Int]) {
        let candidates =
            indices
            .map { normalized($0) }
            .filter { $0 != 0 && !frameCache.contains(key(for: $0)) }
        guard !candidates.isEmpty else {
            return
        }
        let targets = state.withLock { state -> [Int] in
            candidates.filter { index in
                !state.failedFrames.contains(index) && state.inFlight[index] == nil && state.pending.insert(index).inserted
            }
        }
        guard !targets.isEmpty else {
            return
        }
        decodeQueue.async { [weak self] in
            for index in targets {
                guard let self else {
                    return
                }
                self.decodeUnlessInFlight(at: index)
                self.state.withLock { _ = $0.pending.remove(index) }
            }
        }
    }

    /// 디코딩에 두 번 실패해 건너뛰는 프레임이면 `true`입니다.
    public func isFrameFailed(at index: Int) -> Bool {
        let index = normalized(index)
        return state.withLock { $0.failedFrames.contains(index) }
    }

    /// 건너뛰는 프레임 수입니다.
    public var failedFrameCount: Int {
        state.withLock { $0.failedFrames.count }
    }

    /// 보여 줄 수 있는 프레임이 두 개 이상이면 `true`입니다. `false`면 재생을 멈추고 첫 프레임만 보여 주세요.
    public var canAnimate: Bool {
        frameCount - failedFrameCount > 1
    }

    /// 지금까지 프레임을 디코딩한 횟수입니다. 첫 프레임도 1회로 셉니다. 테스트에서만 씁니다.
    @_spi(Testing) public var decodeCount: Int {
        state.withLock { $0.decodeCount }
    }

    var inFlightFrameCount: Int {
        state.withLock { $0.inFlight.count }
    }

    var sharedDecodeWaitCount: Int {
        state.withLock { $0.sharedDecodeWaitCount }
    }

    var leafLockNestingCount: Int {
        state.nestedAcquisitionCount + willDecodeFrame.nestedAcquisitionCount + simulatedDecodeFailures.nestedAcquisitionCount
    }

    func hasCachedFrame(at index: Int) -> Bool {
        let index = normalized(index)
        return index == 0 || frameCache.contains(key(for: index))
    }

    func setWillDecodeFrameHandler(_ handler: (@Sendable (Int) -> Void)?) {
        willDecodeFrame.withLock { $0 = handler }
    }

    func simulateDecodeFailures(at indices: Set<Int>) {
        simulatedDecodeFailures.withLock { $0 = indices }
    }

    private func requestFrame(at index: Int, completion: @escaping @Sendable (CGImage?) -> Void) {
        switch claim(index, sharesInFlightDecode: true) {
        case .failed:
            completion(nil)
        case .wait(let waiter):
            waiter.observe(completion)
        case .decode(let waiter):
            waiter.observe(completion)
            let key = key(for: index)
            decodeQueue.async { [self] in
                waiter.finish(decodeClaimedFrame(at: index, key: key))
            }
        }
    }

    private func decodeUnlessInFlight(at index: Int) {
        let key = key(for: index)
        guard !frameCache.contains(key), case .decode(let waiter) = claim(index, sharesInFlightDecode: false) else {
            return
        }
        waiter.finish(decodeClaimedFrame(at: index, key: key))
    }

    private func claim(_ index: Int, sharesInFlightDecode: Bool) -> Claim {
        state.withLock { state -> Claim in
            if state.failedFrames.contains(index) {
                return .failed
            }
            if let waiter = state.inFlight[index] {
                if sharesInFlightDecode {
                    state.sharedDecodeWaitCount += 1
                }
                return .wait(waiter)
            }
            let waiter = FrameDecodeWaiter()
            state.inFlight[index] = waiter
            return .decode(waiter)
        }
    }

    private func decodeClaimedFrame(at index: Int, key: AnimatedFrameKey) -> CGImage? {
        if let frame = frameCache.frame(for: key) {
            state.withLock { _ = $0.inFlight.removeValue(forKey: index) }
            return frame
        }
        willDecodeFrame.value?(index)
        let frame = simulatedDecodeFailures.value.contains(index) ? nil : decodeLock.withLock {
            Self.makeFrame(source: imageSource, index: index, decision: frameDecision, thumbnail: thumbnail)
        }
        let playhead = state.withLock { $0.playhead }
        if let frame {
            let footprint = AnimatedFrameFootprint(frameCount: frameCount, decodedCost: decodedCost, playhead: playhead)
            frameCache.insert(frame, for: key, footprint: footprint)
        }
        state.withLock { state in
            state.inFlight[index] = nil
            state.decodeCount += 1
            guard frame == nil else {
                return
            }
            let attempts = state.failureCounts[index, default: 0] + 1
            state.failureCounts[index] = attempts
            if attempts >= Self.maximumDecodeAttempts {
                state.failedFrames.insert(index)
            }
        }
        return frame
    }

    private func normalized(_ index: Int) -> Int {
        let remainder = index % frameCount
        return remainder >= 0 ? remainder : remainder + frameCount
    }

    private func key(for index: Int) -> AnimatedFrameKey {
        AnimatedFrameKey(sourceID: sourceID, index: index)
    }
}

private final class FrameDecodeWaiter: Sendable {
    private enum Phase {
        case decoding([@Sendable (CGImage?) -> Void])
        case finished(CGImage?)
    }

    private let phase = LockIsolated(Phase.decoding([]))

    func observe(_ observer: @escaping @Sendable (CGImage?) -> Void) {
        let result = phase.withLock { phase -> CGImage?? in
            switch phase {
            case .decoding(let observers):
                phase = .decoding(observers + [observer])
                return nil
            case .finished(let frame):
                return .some(frame)
            }
        }
        if let result {
            observer(result)
        }
    }

    func finish(_ frame: CGImage?) {
        let observers = phase.withLock { phase -> [@Sendable (CGImage?) -> Void] in
            guard case .decoding(let observers) = phase else {
                return []
            }
            phase = .finished(frame)
            return observers
        }
        for observer in observers {
            observer(frame)
        }
    }

    func wait() -> CGImage? {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockIsolated<CGImage?>(nil)
        observe { frame in
            result.withLock { $0 = frame }
            semaphore.signal()
        }
        semaphore.wait()
        return result.value
    }
}
