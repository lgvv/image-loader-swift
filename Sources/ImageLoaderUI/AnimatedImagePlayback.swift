import CoreGraphics
import Foundation

protocol AnimatedFrameProviding: AnyObject {
    var frameCount: Int { get }
    var loopCount: Int { get }
    var frameDurations: [TimeInterval] { get }
    func cachedFrame(at index: Int) -> CGImage?
    func prefetchFrames(_ indices: [Int])
    func isFrameFailed(at index: Int) -> Bool
}

extension AnimatedImageSource: AnimatedFrameProviding {}

struct AnimatedImagePlayback {
    static let prefetchDistance = 3
    static let maxFramesPerAdvance = prefetchDistance

    struct Step: Equatable {
        var frame: CGImage?
        var completedLoops: Int?
        var didFinish = false
        var didStall = false
    }

    let source: any AnimatedFrameProviding
    var loopCountOverride: Int?
    var playbackRate: Double

    private(set) var currentIndex = 0
    private(set) var completedLoops = 0
    private(set) var isFinished = false
    private(set) var stallCount = 0
    private(set) var advancedFrameCount = 0
    private(set) var timeInCurrentFrame: TimeInterval = 0

    init(source: any AnimatedFrameProviding, loopCountOverride: Int? = nil, playbackRate: Double = 1) {
        self.source = source
        self.loopCountOverride = loopCountOverride
        self.playbackRate = playbackRate
        requestFrames(after: 0)
    }

    var loopLimit: Int? {
        let count = loopCountOverride ?? source.loopCount
        return count > 0 ? count : nil
    }

    var canAdvance: Bool {
        source.frameCount > 1 && !isFinished
    }

    var shortestFrameDuration: TimeInterval {
        source.frameDurations.filter { $0 > 0 }.min() ?? 0.1
    }

    mutating func rewind() {
        currentIndex = 0
        completedLoops = 0
        isFinished = false
        timeInCurrentFrame = 0
        requestFrames(after: 0)
    }

    mutating func advance(by elapsed: TimeInterval) -> Step {
        guard canAdvance, playbackRate > 0, elapsed.isFinite else {
            return Step()
        }
        timeInCurrentFrame += max(0, elapsed) * playbackRate
        var result = Step()
        for _ in 0..<Self.maxFramesPerAdvance {
            let step = advanceOneFrame()
            if let frame = step.frame {
                result.frame = frame
            }
            if let completedLoops = step.completedLoops {
                result.completedLoops = completedLoops
            }
            result.didFinish = result.didFinish || step.didFinish
            result.didStall = result.didStall || step.didStall
            guard step.frame != nil else {
                break
            }
        }
        if !isFinished {
            timeInCurrentFrame = min(timeInCurrentFrame, duration(at: currentIndex))
        }
        return result
    }

    private mutating func advanceOneFrame() -> Step {
        let currentDuration = duration(at: currentIndex)
        guard timeInCurrentFrame >= currentDuration else {
            return Step()
        }
        guard let nextIndex = nextPlayableIndex() else {
            isFinished = true
            return Step(didFinish: true)
        }
        let wrapsAround = nextIndex <= currentIndex
        if wrapsAround, let loopLimit, completedLoops + 1 >= loopLimit {
            completedLoops += 1
            isFinished = true
            return Step(completedLoops: completedLoops, didFinish: true)
        }
        guard let frame = source.cachedFrame(at: nextIndex) else {
            stallCount += 1
            timeInCurrentFrame = currentDuration
            requestFrames(after: currentIndex)
            return Step(didStall: true)
        }
        timeInCurrentFrame -= currentDuration
        currentIndex = nextIndex
        advancedFrameCount += 1
        var step = Step(frame: frame)
        if wrapsAround {
            completedLoops += 1
            step.completedLoops = completedLoops
        }
        requestFrames(after: nextIndex)
        return step
    }

    private func duration(at index: Int) -> TimeInterval {
        let durations = source.frameDurations
        guard durations.indices.contains(index) else {
            return 0.1
        }
        return durations[index]
    }

    private func nextPlayableIndex() -> Int? {
        let frameCount = source.frameCount
        var candidate = currentIndex
        for _ in 1..<frameCount {
            candidate = (candidate + 1) % frameCount
            if candidate == 0 || !source.isFrameFailed(at: candidate) {
                return candidate == currentIndex ? nil : candidate
            }
        }
        return currentIndex == 0 ? nil : 0
    }

    private func requestFrames(after index: Int) {
        let frameCount = source.frameCount
        guard frameCount > 1 else {
            return
        }
        let distance = min(Self.prefetchDistance, frameCount - 1)
        source.prefetchFrames((1...distance).map { (index + $0) % frameCount })
    }
}
