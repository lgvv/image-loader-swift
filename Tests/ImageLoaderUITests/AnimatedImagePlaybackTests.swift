import CoreGraphics
import Foundation
@_spi(Testing) @testable import ImageLoaderUI
import Testing

@testable import ImageLoader

@Suite
struct AnimatedImagePlaybackTests {
    @Test func advancesAfterEachFrameDurationAndCountsLoops() {
        let frames = UIFakeFrames(durations: [0.125, 0.25, 0.125])
        var playback = AnimatedImagePlayback(source: frames)

        #expect(playback.advance(by: 0.0625).frame == nil)
        let first = playback.advance(by: 0.0625)
        #expect(first.frame === frames.images[1])
        #expect(playback.currentIndex == 1)
        #expect(playback.advance(by: 0.125).frame == nil)
        #expect(playback.advance(by: 0.125).frame === frames.images[2])
        let wrap = playback.advance(by: 0.125)
        #expect(wrap.frame === frames.images[0])
        #expect(wrap.completedLoops == 1)
        #expect(playback.completedLoops == 1)
        #expect(playback.advancedFrameCount == 3)
        #expect(!wrap.didFinish)
    }

    @Test func finiteLoopCountStopsOnLastFrameAndOverrideWins() {
        let frames = UIFakeFrames(durations: [0.1, 0.1], loopCount: 1)
        var playback = AnimatedImagePlayback(source: frames)

        #expect(playback.advance(by: 0.1).frame === frames.images[1])
        let end = playback.advance(by: 0.1)
        #expect(end.didFinish)
        #expect(end.completedLoops == 1)
        #expect(playback.isFinished)
        #expect(playback.currentIndex == 1)
        #expect(!playback.canAdvance)
        #expect(playback.advance(by: 1) == AnimatedImagePlayback.Step())

        var endless = AnimatedImagePlayback(source: frames, loopCountOverride: 0)
        for _ in 0..<10 {
            #expect(!endless.advance(by: 0.1).didFinish)
        }
        #expect(endless.completedLoops == 5)

        var twice = AnimatedImagePlayback(source: UIFakeFrames(durations: [0.1, 0.1], loopCount: 0), loopCountOverride: 2)
        var finished = false
        for _ in 0..<4 {
            finished = twice.advance(by: 0.1).didFinish
        }
        #expect(finished)
        #expect(twice.completedLoops == 2)
    }

    @Test func stallKeepsCurrentFrameUntilNextFrameIsDecoded() {
        let frames = UIFakeFrames(durations: [0.1, 0.1, 0.1])
        frames.cached = [0]
        var playback = AnimatedImagePlayback(source: frames)
        let requestsAfterInit = frames.prefetchRequests.count

        let stalled = playback.advance(by: 0.5)
        #expect(stalled.didStall)
        #expect(stalled.frame == nil)
        #expect(playback.currentIndex == 0)
        #expect(playback.stallCount == 1)
        #expect(frames.prefetchRequests.count == requestsAfterInit + 1)
        #expect(frames.prefetchRequests.last == [1, 2])

        #expect(playback.advance(by: 0.016).didStall)
        #expect(playback.stallCount == 2)

        frames.cached = [0, 1, 2]
        let resumed = playback.advance(by: 0.016)
        #expect(resumed.frame === frames.images[1])
        #expect(playback.currentIndex == 1)
        #expect(playback.timeInCurrentFrame <= 0.1)
    }

    @Test func failedFramesAreSkippedAndAllFailedFramesFinish() {
        let frames = UIFakeFrames(durations: [0.1, 0.1, 0.1, 0.1])
        frames.failed = [1, 2]
        var playback = AnimatedImagePlayback(source: frames)
        #expect(playback.advance(by: 0.1).frame === frames.images[3])
        #expect(playback.currentIndex == 3)

        let broken = UIFakeFrames(durations: [0.1, 0.1, 0.1])
        broken.failed = [1, 2]
        var stuck = AnimatedImagePlayback(source: broken)
        let step = stuck.advance(by: 0.1)
        #expect(step.didFinish)
        #expect(stuck.isFinished)
        #expect(stuck.currentIndex == 0)
    }

    @Test func playbackRateScalesTimeAndZeroPauses() {
        let frames = UIFakeFrames(durations: [0.1, 0.1, 0.1])
        var paused = AnimatedImagePlayback(source: frames, playbackRate: 0)
        #expect(paused.advance(by: 10).frame == nil)
        #expect(paused.currentIndex == 0)

        var fast = AnimatedImagePlayback(source: frames, playbackRate: 2)
        #expect(fast.advance(by: 0.05).frame === frames.images[1])
    }

    @Test func largeElapsedTimeAdvancesAtMostPrefetchDistanceAndCarriesAtMostOneFrameDuration() {
        let frames = UIFakeFrames(durations: Array(repeating: 0.1, count: 6))
        var playback = AnimatedImagePlayback(source: frames)
        let step = playback.advance(by: 30)
        #expect(step.frame === frames.images[AnimatedImagePlayback.maxFramesPerAdvance])
        #expect(playback.advancedFrameCount == AnimatedImagePlayback.maxFramesPerAdvance)
        #expect(playback.timeInCurrentFrame <= 0.1)
        #expect(playback.advance(by: 0).frame === frames.images[AnimatedImagePlayback.maxFramesPerAdvance + 1])
        #expect(playback.advance(by: 0).frame == nil)
    }

    @Test func elapsedTimeSpanningSeveralFramesAdvancesThemInOneStepAndKeepsRemainder() {
        let frames = UIFakeFrames(durations: [0.125, 0.125, 0.125, 0.125])
        var playback = AnimatedImagePlayback(source: frames)
        let step = playback.advance(by: 0.3125)
        #expect(step.frame === frames.images[2])
        #expect(playback.currentIndex == 2)
        #expect(playback.advancedFrameCount == 2)
        #expect(playback.timeInCurrentFrame == 0.0625)
        #expect(playback.advance(by: 0.0625).frame === frames.images[3])

        var fast = AnimatedImagePlayback(source: frames, playbackRate: 2)
        for _ in 0..<10 {
            _ = fast.advance(by: 0.125)
        }
        #expect(fast.advancedFrameCount == 20)
        #expect(fast.completedLoops == 5)
    }

    @Test func catchUpReportsLatestLoopAndStopsAtStallOrFiniteEnd() {
        let pair = UIFakeFrames(durations: [0.125, 0.125])
        var wrapping = AnimatedImagePlayback(source: pair)
        let wrap = wrapping.advance(by: 0.375)
        #expect(wrapping.advancedFrameCount == 3)
        #expect(wrap.completedLoops == 1)
        #expect(wrapping.currentIndex == 1)

        let partial = UIFakeFrames(durations: [0.125, 0.125, 0.125, 0.125])
        partial.cached = [0, 1]
        var stalled = AnimatedImagePlayback(source: partial)
        let step = stalled.advance(by: 0.4375)
        #expect(step.frame === partial.images[1])
        #expect(step.didStall)
        #expect(stalled.currentIndex == 1)
        #expect(stalled.stallCount == 1)
        #expect(stalled.timeInCurrentFrame <= 0.125)

        var finite = AnimatedImagePlayback(source: UIFakeFrames(durations: [0.125, 0.125], loopCount: 1))
        let end = finite.advance(by: 0.3125)
        #expect(end.frame != nil)
        #expect(end.didFinish)
        #expect(end.completedLoops == 1)
        #expect(finite.currentIndex == 1)
        #expect(finite.advancedFrameCount == 1)
    }

    @Test func rewindReturnsToFirstFrame() {
        let frames = UIFakeFrames(durations: [0.1, 0.1], loopCount: 1)
        var playback = AnimatedImagePlayback(source: frames)
        _ = playback.advance(by: 0.1)
        _ = playback.advance(by: 0.1)
        #expect(playback.isFinished)
        playback.rewind()
        #expect(!playback.isFinished)
        #expect(playback.currentIndex == 0)
        #expect(playback.completedLoops == 0)
        #expect(playback.canAdvance)
    }

    @Test func initRequestsUpcomingFrames() {
        let frames = UIFakeFrames(durations: Array(repeating: 0.1, count: 6))
        _ = AnimatedImagePlayback(source: frames)
        #expect(frames.prefetchRequests == [[1, 2, 3]])
    }
}

final class UIFakeFrames: AnimatedFrameProviding {
    let frameCount: Int
    let loopCount: Int
    let frameDurations: [TimeInterval]
    let images: [CGImage]
    var cached: Set<Int>
    var failed: Set<Int> = []
    private(set) var prefetchRequests: [[Int]] = []

    init(durations: [TimeInterval], loopCount: Int = 0) {
        frameCount = durations.count
        self.loopCount = loopCount
        frameDurations = durations
        images = durations.indices.map { _ in UIFixtures.solid(UIFixtures.red, width: 2, height: 2) }
        cached = Set(durations.indices)
    }

    func cachedFrame(at index: Int) -> CGImage? {
        cached.contains(index) ? images[index] : nil
    }

    func prefetchFrames(_ indices: [Int]) {
        prefetchRequests.append(indices)
    }

    func isFrameFailed(at index: Int) -> Bool {
        failed.contains(index)
    }
}
