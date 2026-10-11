import Foundation
import ImageLoaderTesting
@_spi(Testing) @testable import ImageLoaderUI
import Testing
import UIKit

@testable import ImageLoader

@Suite(.serialized)
@MainActor
struct AnimatedImageViewTests {
    private func loadAnimatedContainer(_ name: String, colors: [UIFixtures.RGB] = [UIFixtures.red, UIFixtures.green, UIFixtures.blue], loopCount: Int = 0) async throws
        -> ImageContent
    {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.gif(colors, loopCount: loopCount)))
        let session = makeUISession(loader: loader)
        let response = try await session.imageTask(with: UIFixtures.url(name)).response
        #expect(response.content.animatedImageSource != nil)
        return response.content
    }

    @Test func pixelsFollowFramesOfThreeColorGIF() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.gif([UIFixtures.red, UIFixtures.green, UIFixtures.blue])))
        let session = makeUISession(loader: loader)
        let view = AnimatedImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        let recorder = UIResultRecorder()

        loadImage(with: UIFixtures.url("pixels.gif"), options: makeUIOptions(session), into: view) { recorder.record($0) }
        await uiExpectEventually { recorder.count == 1 }
        let source = try #require(view.animatedImageSource)
        #expect(source.frameCount == 3)
        #expect(!view.isDisplayLinkActive)
        await uiExpectEventually { source.hasCachedFrame(at: 1) && source.hasCachedFrame(at: 2) }

        #expect(uiColorMatches(uiCenterColor(of: view), UIFixtures.red))
        #expect(view.advanceAnimation(by: source.frameDuration(at: 0)))
        #expect(uiColorMatches(uiCenterColor(of: view), UIFixtures.green))
        view.setNeedsLayout()
        view.layoutIfNeeded()
        await uiDrainMainQueue()
        #expect(uiColorMatches(uiCenterColor(of: view), UIFixtures.green))
        #expect(view.advanceAnimation(by: source.frameDuration(at: 1)))
        #expect(uiColorMatches(uiCenterColor(of: view), UIFixtures.blue))
        #expect(view.advanceAnimation(by: source.frameDuration(at: 2)))
        #expect(uiColorMatches(uiCenterColor(of: view), UIFixtures.red))
        #expect(view.completedLoopCount == 1)
        #expect(view.advancedFrameCount == 3)
        #expect(view.stallCount == 0)
    }

    enum PausedState: CaseIterable, Sendable {
        case autoPlayDisabled
        case stopped
        case zeroRate
        case finishedLoop
    }

    @Test(arguments: PausedState.allCases)
    func pausedFrameSurvivesResizeTraitAndHighlightChanges(_ state: PausedState) async throws {
        let content = try await loadAnimatedContainer("paused-\(state).gif")
        let source = try #require(content.animatedImageSource)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.isHidden = false
        let view = AnimatedImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.autoPlayAnimatedImage = state != .autoPlayDisabled
        if state == .finishedLoop {
            view.loopCountOverride = 1
        }
        window.addSubview(view)
        view.display(content)
        await uiExpectEventually { source.hasCachedFrame(at: 1) && source.hasCachedFrame(at: 2) }

        let expected: UIFixtures.RGB
        switch state {
        case .autoPlayDisabled:
            #expect(view.advanceAnimation(by: source.frameDuration(at: 0)))
            expected = UIFixtures.green
        case .stopped:
            view.stopAnimating()
            #expect(view.advanceAnimation(by: source.frameDuration(at: 0)))
            expected = UIFixtures.green
        case .zeroRate:
            #expect(view.advanceAnimation(by: source.frameDuration(at: 0)))
            view.playbackRate = 0
            expected = UIFixtures.green
        case .finishedLoop:
            #expect(view.advanceAnimation(by: source.frameDuration(at: 0)))
            #expect(view.advanceAnimation(by: source.frameDuration(at: 1)))
            view.advanceAnimation(by: source.frameDuration(at: 2))
            #expect(view.completedLoopCount == 1)
            expected = UIFixtures.blue
        }
        #expect(!view.isDisplayLinkActive)
        #expect(uiColorMatches(uiCenterColor(of: view), expected))

        view.frame = CGRect(x: 0, y: 0, width: 60, height: 60)
        view.layoutIfNeeded()
        window.layoutIfNeeded()
        await uiDrainMainQueue()
        #expect(uiColorMatches(uiCenterColor(of: view), expected), "resize")

        view.overrideUserInterfaceStyle = .dark
        view.layoutIfNeeded()
        await uiDrainMainQueue()
        #expect(uiColorMatches(uiCenterColor(of: view), expected), "trait")

        view.isHighlighted = true
        view.layoutIfNeeded()
        await uiDrainMainQueue()
        #expect(uiColorMatches(uiCenterColor(of: view), expected), "highlighted")

        view.isHighlighted = false
        view.tintColor = .systemPink
        view.layer.setNeedsDisplay()
        view.layer.displayIfNeeded()
        await uiDrainMainQueue()
        #expect(uiColorMatches(uiCenterColor(of: view), expected), "display")

        let yellow: UIFixtures.RGB = (200, 200, 30)
        view.image = UIFixtures.image(yellow)
        view.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
        view.layoutIfNeeded()
        await uiDrainMainQueue()
        #expect(uiColorMatches(uiCenterColor(of: view), yellow), "static image after playback")
        view.removeFromSuperview()
        window.isHidden = true
    }

    @Test func highlightedImageWinsWhileHighlightedAndPlaybackFrameReturnsAfter() async throws {
        let content = try await loadAnimatedContainer("highlighted.gif")
        let source = try #require(content.animatedImageSource)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.isHidden = false
        let view = AnimatedImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        let yellow: UIFixtures.RGB = (200, 200, 30)
        view.highlightedImage = UIFixtures.image(yellow)
        view.autoPlayAnimatedImage = false
        window.addSubview(view)
        view.display(content)
        await uiExpectEventually { source.hasCachedFrame(at: 1) && source.hasCachedFrame(at: 2) }

        view.isHighlighted = true
        view.layoutIfNeeded()
        await uiDrainMainQueue()
        #expect(uiColorMatches(uiCenterColor(of: view), yellow))
        #expect(view.advanceAnimation(by: source.frameDuration(at: 0)))
        view.layoutIfNeeded()
        await uiDrainMainQueue()
        #expect(uiColorMatches(uiCenterColor(of: view), yellow))

        view.isHighlighted = false
        view.layoutIfNeeded()
        await uiDrainMainQueue()
        #expect(uiColorMatches(uiCenterColor(of: view), UIFixtures.green))
        view.removeFromSuperview()
        window.isHidden = true
    }

    @Test func stallsOnCurrentFrameWhileNextFrameIsDecoding() async throws {
        let content = try await loadAnimatedContainer("stall.gif")
        let source = try #require(content.animatedImageSource)
        let gate = UIDecodeGate()
        defer { gate.open() }
        source.setWillDecodeFrameHandler { index in gate.block(index) }
        let view = AnimatedImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))

        view.display(content)
        await uiExpectEventually { !gate.blocked.isEmpty }
        #expect(!view.advanceAnimation(by: 1))
        #expect(view.stallCount == 1)
        #expect(view.currentFrameIndex == 0)
        #expect(uiColorMatches(uiCenterColor(of: view), UIFixtures.red))

        gate.open()
        source.setWillDecodeFrameHandler(nil)
        await uiExpectEventually { source.hasCachedFrame(at: 1) }
        #expect(view.advanceAnimation(by: 0))
        #expect(view.currentFrameIndex == 1)
        #expect(uiColorMatches(uiCenterColor(of: view), UIFixtures.green))
    }

    @Test func displayLinkStopsWhenRemovedFromWindowHiddenOrRateIsZero() async throws {
        let content = try await loadAnimatedContainer("link.gif")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let view = AnimatedImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))

        view.display(content)
        #expect(!view.isDisplayLinkActive)
        window.addSubview(view)
        #expect(view.isDisplayLinkActive)

        view.removeFromSuperview()
        #expect(!view.isDisplayLinkActive)
        window.addSubview(view)
        #expect(view.isDisplayLinkActive)

        view.isHidden = true
        #expect(!view.isDisplayLinkActive)
        view.isHidden = false
        #expect(view.isDisplayLinkActive)

        view.playbackRate = 0
        #expect(!view.isDisplayLinkActive)
        #expect(!view.isAnimating)
        view.playbackRate = 1
        #expect(view.isDisplayLinkActive)

        view.autoPlayAnimatedImage = false
        #expect(!view.isDisplayLinkActive)
        view.startAnimating()
        #expect(view.isDisplayLinkActive)
        view.stopAnimating()
        #expect(!view.isDisplayLinkActive)
        view.removeFromSuperview()
    }

    @Test func displayLinkAdvancesFramesWhileInWindow() async throws {
        let content = try await loadAnimatedContainer("drive.gif")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let view = AnimatedImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        window.addSubview(view)

        view.display(content)
        #expect(view.isDisplayLinkActive)
        await uiExpectEventually(timeout: 10) { view.advancedFrameCount >= 2 }
        view.removeFromSuperview()
    }

    @Test func finiteLoopStopsDisplayLinkAndReportsLoops() async throws {
        let content = try await loadAnimatedContainer("loop.gif", colors: [UIFixtures.red, UIFixtures.green], loopCount: 1)
        let source = try #require(content.animatedImageSource)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let view = AnimatedImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        let loops = UILoopRecorder()
        view.onLoopCompleted = { loops.values.append($0) }
        view.loopCountOverride = 1
        window.addSubview(view)
        view.display(content)
        await uiExpectEventually { source.hasCachedFrame(at: 1) }

        view.advanceAnimation(by: 1)
        view.advanceAnimation(by: 1)

        #expect(loops.values == [1])
        #expect(!view.isDisplayLinkActive)
        #expect(!view.isAnimating)
        view.startAnimating()
        #expect(view.isDisplayLinkActive)
        #expect(view.currentFrameIndex == 0)
        view.removeFromSuperview()
    }

    @Test func settingStaticImageEndsPlayback() async throws {
        let content = try await loadAnimatedContainer("static.gif")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let view = AnimatedImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        window.addSubview(view)
        view.display(content)
        #expect(view.isDisplayLinkActive)

        let still = UIFixtures.image(UIFixtures.blue)
        view.image = still

        #expect(view.animatedImageSource == nil)
        #expect(!view.isDisplayLinkActive)
        #expect(!view.advanceAnimation(by: 1))
        #expect(view.image === still)
        view.removeFromSuperview()
    }

    @Test func redisplayingSameSourceKeepsPlaybackPosition() async throws {
        let content = try await loadAnimatedContainer("same.gif")
        let source = try #require(content.animatedImageSource)
        let view = AnimatedImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.display(content)
        await uiExpectEventually { source.hasCachedFrame(at: 1) }
        #expect(view.advanceAnimation(by: source.frameDuration(at: 0)))

        view.display(content)

        #expect(view.currentFrameIndex == 1)
        #expect(view.advancedFrameCount == 1)
    }

    @Test func viewDeallocatesWhilePlaying() async throws {
        let content = try await loadAnimatedContainer("dealloc.gif")
        weak var weakView: AnimatedImageView?
        weak var weakWindow: UIWindow?

        autoreleasepool {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            let view = AnimatedImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
            window.addSubview(view)
            view.display(content)
            #expect(view.isDisplayLinkActive)
            weakView = view
            weakWindow = window
        }
        await uiDrainMainQueue()

        await uiExpectEventually { weakView == nil && weakWindow == nil }
    }

    @Test func displayFrameRateIsSmallestScreenDivisorCoveringPlaybackRate() {
        #expect(AnimatedImageView.displayFrameRate(frameDuration: 0.1, playbackRate: 1, maximumFramesPerSecond: 60) == 10)
        #expect(AnimatedImageView.displayFrameRate(frameDuration: 0.1, playbackRate: 2, maximumFramesPerSecond: 60) == 20)
        #expect(AnimatedImageView.displayFrameRate(frameDuration: 0.03, playbackRate: 1, maximumFramesPerSecond: 60) == 60)
        #expect(AnimatedImageView.displayFrameRate(frameDuration: 0.04, playbackRate: 1, maximumFramesPerSecond: 60) == 30)
        #expect(AnimatedImageView.displayFrameRate(frameDuration: 0.03, playbackRate: 1, maximumFramesPerSecond: 120) == 40)
        #expect(AnimatedImageView.displayFrameRate(frameDuration: 0.01, playbackRate: 4, maximumFramesPerSecond: 60) == 60)
        #expect(AnimatedImageView.displayFrameRate(frameDuration: 2, playbackRate: 1, maximumFramesPerSecond: 60) == 1)
        #expect(AnimatedImageView.displayFrameRate(frameDuration: 0.1, playbackRate: .infinity, maximumFramesPerSecond: 60) == 60)
    }

    @Test func playbackRateChangeUpdatesRunningDisplayLinkFrameRate() async throws {
        let content = try await loadAnimatedContainer("rate-range.gif")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let view = AnimatedImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        window.addSubview(view)
        view.display(content)
        let maximum = window.screen.maximumFramesPerSecond
        let expectedAtNormalRate = AnimatedImageView.displayFrameRate(frameDuration: 0.1, playbackRate: 1, maximumFramesPerSecond: maximum)
        let expectedAtDoubleRate = AnimatedImageView.displayFrameRate(frameDuration: 0.1, playbackRate: 2, maximumFramesPerSecond: maximum)

        let initial = try #require(view.displayLinkFrameRateRange)
        #expect(initial.preferred == Float(expectedAtNormalRate))
        #expect(initial.minimum == initial.preferred)

        view.playbackRate = 2
        let doubled = try #require(view.displayLinkFrameRateRange)
        #expect(doubled.preferred == Float(expectedAtDoubleRate))
        #expect(doubled.minimum == doubled.preferred)

        let custom = CAFrameRateRange(minimum: 8, maximum: 24, preferred: 24)
        view.preferredFrameRateRange = custom
        #expect(view.displayLinkFrameRateRange.map { AnimatedImageView.isSameRange($0, custom) } == true)
        view.removeFromSuperview()
    }

    @Test func staticContainerFallsBackToImage() {
        let view = AnimatedImageView()
        let image = UIFixtures.image()
        view.display(ImageContent(image: image))
        #expect(view.image === image)
        #expect(view.animatedImageSource == nil)
        #expect(!view.isDisplayLinkActive)
    }
}

@MainActor
final class UILoopRecorder {
    var values: [Int] = []
}

@Suite(.serialized, .enabled(if: !uiIsThreadSanitizerEnabled))
@MainActor
struct AnimatedImageViewTimingTests {
    private func measureFramesPerSecond(delay: Double, playbackRate: Double, frames target: Int) async throws -> Double {
        let colors = [UIFixtures.red, UIFixtures.green, UIFixtures.blue, UIFixtures.red]
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.gif(colors, delay: delay)))
        let session = makeUISession(loader: loader)
        let content = try await session.imageTask(with: UIFixtures.url("timing-\(delay)-\(playbackRate).gif")).response.content
        let source = try #require(content.animatedImageSource)
        #expect(abs(source.frameDuration(at: 0) - delay) < 0.001)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.isHidden = false
        let view = AnimatedImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.playbackRate = playbackRate
        window.addSubview(view)
        view.display(content)
        await uiExpectEventually { (1..<source.frameCount).allSatisfy { source.hasCachedFrame(at: $0) } }
        await uiExpectEventually { view.advancedFrameCount >= 1 }
        let startCount = view.advancedFrameCount
        let start = DispatchTime.now().uptimeNanoseconds
        let expectedSeconds = Double(target) * delay / playbackRate
        await uiExpectEventually(timeout: expectedSeconds * 2 + 1) { view.advancedFrameCount - startCount >= target }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let advanced = view.advancedFrameCount - startCount
        view.removeFromSuperview()
        window.isHidden = true
        let measured = Double(advanced) / elapsed
        print(
            String(
                format: "BENCH|ui.animatedPlaybackRate|delay=%.3f|rate=%.1f|frames=%d|elapsed_s=%.3f|fps=%.2f|expected_fps=%.2f|stalls=%d", delay, playbackRate, advanced, elapsed,
                measured, playbackRate / delay, view.stallCount))
        return measured
    }

    @Test func doublePlaybackRateDoublesFramesPerSecond() async throws {
        let measured = try await measureFramesPerSecond(delay: 0.1, playbackRate: 2, frames: 30)
        #expect(measured >= 20 * 0.85)
        #expect(measured <= 20 * 1.15)
    }

    @Test func shortFrameDelayPlaysAtFullSpeed() async throws {
        let measured = try await measureFramesPerSecond(delay: 0.03, playbackRate: 1, frames: 60)
        #expect(measured >= (1 / 0.03) * 0.93)
        #expect(measured <= (1 / 0.03) * 1.1)
    }
}
