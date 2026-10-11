import QuartzCore
import UIKit

extension AnimatedImageView {
    static func displayFrameRate(frameDuration: TimeInterval, playbackRate: Double, maximumFramesPerSecond: Int) -> Int {
        let maximum = max(1, maximumFramesPerSecond)
        guard frameDuration > 0, playbackRate > 0, playbackRate.isFinite else {
            return maximum
        }
        let required = (playbackRate / frameDuration - 0.001).rounded(.up)
        for divisor in stride(from: maximum, through: 1, by: -1) where maximum % divisor == 0 {
            let rate = maximum / divisor
            if Double(rate) >= required {
                return rate
            }
        }
        return maximum
    }

    fileprivate func displayLinkDidFire(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        let elapsed = previousTimestamp.map { timestamp - $0 } ?? 0
        previousTimestamp = timestamp
        advanceAnimation(by: elapsed)
    }

    private var shouldRunDisplayLink: Bool {
        guard let playback, isPlaybackRequested, effectivePlaybackRate > 0, playback.canAdvance else {
            return false
        }
        return window != nil && !isHidden
    }

    func refreshDisplayLink() {
        if shouldRunDisplayLink {
            startDisplayLink()
            updateDisplayLinkFrameRate()
            return
        }
        guard displayLink != nil else {
            return
        }
        stopDisplayLink()
        if resetsToFirstFrameWhenStopped, effectivePlaybackRate > 0 {
            rewindToFirstFrame()
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil, let playback else {
            return
        }
        let link = CADisplayLink(target: DisplayLinkTarget(owner: self), selector: #selector(DisplayLinkTarget.fire(_:)))
        link.preferredFrameRateRange = frameRateRange(for: playback)
        link.add(to: .main, forMode: runLoopMode)
        displayLink = link
        previousTimestamp = nil
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        previousTimestamp = nil
    }

    private func frameRateRange(for playback: AnimatedImagePlayback) -> CAFrameRateRange {
        if let preferredFrameRateRange {
            return preferredFrameRateRange
        }
        let rate = Float(
            Self.displayFrameRate(
                frameDuration: playback.shortestFrameDuration,
                playbackRate: effectivePlaybackRate,
                maximumFramesPerSecond: window?.screen.maximumFramesPerSecond ?? 60
            ))
        return CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
    }

    static func isSameRange(_ lhs: CAFrameRateRange, _ rhs: CAFrameRateRange) -> Bool {
        lhs.minimum == rhs.minimum && lhs.maximum == rhs.maximum && lhs.preferred == rhs.preferred
    }

    func updateDisplayLinkFrameRate() {
        guard let displayLink, let playback else {
            return
        }
        let range = frameRateRange(for: playback)
        if !Self.isSameRange(displayLink.preferredFrameRateRange, range) {
            displayLink.preferredFrameRateRange = range
        }
    }
}

@MainActor
private final class DisplayLinkTarget: NSObject {
    private weak var owner: AnimatedImageView?

    init(owner: AnimatedImageView) {
        self.owner = owner
    }

    @objc func fire(_ link: CADisplayLink) {
        guard let owner else {
            link.invalidate()
            return
        }
        owner.displayLinkDidFire(link)
    }
}
