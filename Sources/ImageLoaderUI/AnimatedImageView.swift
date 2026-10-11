import QuartzCore
import UIKit

/// 애니메이션 GIF, APNG, WebP를 재생하는 `UIImageView`입니다.
///
/// 프레임을 미리 모두 디코딩하지 않고, 재생 위치보다 3프레임 앞까지만 백그라운드에서 디코딩합니다.
/// 다음 프레임이 아직 준비되지 않았으면 건너뛰지 않고 지금 프레임에서 기다립니다.
/// 뷰가 화면에서 빠지거나 숨겨지면 재생을 멈추고, 다시 보이면 이어서 재생합니다.
///
/// ``loadImage(with:options:into:completion:)-(URL?,_,_,_)``에 넘기면 애니메이션 이미지를 알아서 재생합니다.
@MainActor
open class AnimatedImageView: UIImageView {
    /// 애니메이션 이미지를 넣자마자 재생할지 정합니다. 기본값은 `true`입니다. `false`면 ``startAnimating()``을 부를 때까지 첫 프레임에 머뭅니다.
    open var autoPlayAnimatedImage = true {
        didSet {
            guard oldValue != autoPlayAnimatedImage, playback != nil else {
                return
            }
            isPlaybackRequested = autoPlayAnimatedImage
            refreshDisplayLink()
        }
    }

    /// 재생 속도 배율입니다. 기본값은 1이고, 2면 두 배로 빠르게 재생합니다. 0이면 재생을 멈춥니다.
    open var playbackRate: Double = 1 {
        didSet {
            playback?.playbackRate = effectivePlaybackRate
            refreshDisplayLink()
            updateDisplayLinkFrameRate()
        }
    }

    /// 파일에 적힌 반복 횟수 대신 쓸 횟수입니다. 0이면 계속 반복합니다. `nil`이면 ``AnimatedImageSource/loopCount``를 따릅니다.
    open var loopCountOverride: Int? {
        didSet {
            playback?.loopCountOverride = loopCountOverride
        }
    }

    /// 재생을 멈추거나 반복을 다 마쳤을 때 첫 프레임으로 돌아갈지 정합니다. 기본값은 `false`이고, 이때는 멈춘 프레임에 머뭅니다.
    open var resetsToFirstFrameWhenStopped = false

    /// 화면 갱신 타이머를 등록할 런 루프 모드입니다.
    ///
    /// 기본값 `.common`이면 스크롤하는 동안에도 재생합니다. `.default`로 바꾸면 스크롤하는 동안 멈춰 스크롤이 덜 끊깁니다.
    open var runLoopMode: RunLoop.Mode = .common {
        didSet {
            guard oldValue != runLoopMode, displayLink != nil else {
                return
            }
            stopDisplayLink()
            refreshDisplayLink()
        }
    }

    /// 화면 갱신 빈도를 직접 정합니다.
    ///
    /// `nil`이면 가장 짧은 프레임 시간에 맞는 가장 낮은 빈도를 고릅니다. 프레임당 0.1초인 GIF는 120Hz 화면에서도 1초에 10번만 갱신해 배터리를 아낍니다.
    open var preferredFrameRateRange: CAFrameRateRange? {
        didSet {
            updateDisplayLinkFrameRate()
        }
    }

    /// 한 번 반복을 마칠 때마다 지금까지 마친 반복 횟수를 넘겨 부릅니다.
    public var onLoopCompleted: (@MainActor @Sendable (_ completedLoops: Int) -> Void)?

    /// 재생 중인 애니메이션의 프레임 소스입니다. 정지 이미지를 보여 주고 있으면 `nil`입니다.
    public private(set) var animatedImageSource: AnimatedImageSource?

    /// 지금 보여 주는 프레임의 위치입니다. 0부터 시작합니다.
    public var currentFrameIndex: Int {
        playback?.currentIndex ?? 0
    }

    private(set) var playback: AnimatedImagePlayback?
    var displayLink: CADisplayLink?
    var previousTimestamp: CFTimeInterval?
    private(set) var isPlaybackRequested = false
    private var currentFrame: CGImage?

    /// 이미지를 직접 넣으면 재생 중인 애니메이션을 멈추고 그 이미지를 보여 줍니다.
    open override var image: UIImage? {
        didSet {
            if playback != nil {
                endPlayback()
            }
        }
    }

    /// 숨기면 재생을 멈추고, 다시 보이면 멈춘 프레임부터 이어서 재생합니다.
    open override var isHidden: Bool {
        didSet {
            refreshDisplayLink()
        }
    }

    /// 강조 상태에서 `highlightedImage`가 있으면 그 이미지를, 없으면 지금 프레임을 그대로 보여 줍니다.
    open override var isHighlighted: Bool {
        didSet {
            reapplyCurrentFrame()
        }
    }

    /// 애니메이션 이미지를 재생 중이면 `true`입니다.
    open override var isAnimating: Bool {
        playback == nil ? super.isAnimating : displayLink != nil
    }

    open override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshDisplayLink()
        updateDisplayLinkFrameRate()
    }

    open override func layoutSubviews() {
        super.layoutSubviews()
        reapplyCurrentFrame()
    }

    open override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        reapplyCurrentFrame()
        setNeedsLayout()
    }

    open override func display(_ layer: CALayer) {
        guard let frame = displayedFrame else {
            super.display(layer)
            return
        }
        layer.contents = frame
    }

    /// 이미지를 보여 줍니다. 애니메이션 이미지면 첫 프레임을 보여 주고 재생을 준비하고, 정지 이미지면 그대로 보여 줍니다.
    ///
    /// 같은 애니메이션을 다시 넣으면 처음부터 다시 재생하지 않고 이어 갑니다.
    open func display(_ content: ImageContent) {
        guard let source = content.animatedImageSource, source.frameCount > 1 else {
            imageLoader_display(image: content.image, data: content.data)
            return
        }
        if source === animatedImageSource, playback != nil {
            refreshDisplayLink()
            return
        }
        stopDisplayLink()
        super.image = content.image
        applyFrame(content.image.cgImage)
        animatedImageSource = source
        playback = AnimatedImagePlayback(source: source, loopCountOverride: loopCountOverride, playbackRate: effectivePlaybackRate)
        isPlaybackRequested = autoPlayAnimatedImage
        refreshDisplayLink()
    }

    /// 애니메이션을 재생합니다. 반복을 다 마친 상태면 첫 프레임부터 다시 재생합니다.
    open override func startAnimating() {
        guard let playback else {
            super.startAnimating()
            return
        }
        isPlaybackRequested = true
        if playback.isFinished {
            rewindToFirstFrame()
        }
        refreshDisplayLink()
    }

    /// 애니메이션을 멈춥니다. ``resetsToFirstFrameWhenStopped``가 `true`면 첫 프레임으로 돌아갑니다.
    open override func stopAnimating() {
        guard playback != nil else {
            super.stopAnimating()
            return
        }
        isPlaybackRequested = false
        refreshDisplayLink()
        if resetsToFirstFrameWhenStopped {
            rewindToFirstFrame()
        }
    }

    /// 화면 갱신 타이머 없이 재생 위치를 `elapsed`초만큼 옮깁니다. 프레임이 바뀌었으면 `true`입니다. 테스트에서만 씁니다.
    @_spi(Testing)
    @discardableResult
    public func advanceAnimation(by elapsed: TimeInterval) -> Bool {
        guard var current = playback else {
            return false
        }
        let loopsBefore = current.completedLoops
        let step = current.advance(by: elapsed)
        playback = current
        if let frame = step.frame {
            applyFrame(frame)
        }
        if step.didFinish {
            stopDisplayLink()
            if resetsToFirstFrameWhenStopped {
                rewindToFirstFrame()
            }
        }
        if let completedLoops = step.completedLoops, completedLoops > loopsBefore {
            for loop in (loopsBefore + 1)...completedLoops {
                onLoopCompleted?(loop)
            }
        }
        return step.frame != nil
    }

    /// 다음 프레임이 준비되지 않아 기다린 횟수입니다. 테스트에서만 씁니다.
    @_spi(Testing)
    public var stallCount: Int {
        playback?.stallCount ?? 0
    }

    /// 지금까지 넘긴 프레임 수입니다. 테스트에서만 씁니다.
    @_spi(Testing)
    public var advancedFrameCount: Int {
        playback?.advancedFrameCount ?? 0
    }

    /// 지금까지 마친 반복 횟수입니다. 테스트에서만 씁니다.
    @_spi(Testing)
    public var completedLoopCount: Int {
        playback?.completedLoops ?? 0
    }

    /// 화면 갱신 타이머가 돌고 있으면 `true`입니다. 테스트에서만 씁니다.
    @_spi(Testing)
    public var isDisplayLinkActive: Bool {
        displayLink != nil
    }

    /// 화면 갱신 타이머에 정한 빈도입니다. 테스트에서만 씁니다.
    @_spi(Testing)
    public var displayLinkFrameRateRange: CAFrameRateRange? {
        displayLink?.preferredFrameRateRange
    }

    var effectivePlaybackRate: Double {
        playbackRate.isFinite ? max(0, playbackRate) : 0
    }

    private func endPlayback() {
        stopDisplayLink()
        playback = nil
        animatedImageSource = nil
        currentFrame = nil
        isPlaybackRequested = false
    }

    func rewindToFirstFrame() {
        guard playback != nil else {
            return
        }
        playback?.rewind()
        applyFrame(image?.cgImage)
    }

    private var displayedFrame: CGImage? {
        guard playback != nil, let currentFrame else {
            return nil
        }
        if isHighlighted, highlightedImage != nil {
            return nil
        }
        return currentFrame
    }

    private func reapplyCurrentFrame() {
        guard let frame = displayedFrame, (layer.contents as AnyObject?) !== frame else {
            return
        }
        setLayerContents(frame)
    }

    private func applyFrame(_ frame: CGImage?) {
        guard let frame else {
            return
        }
        currentFrame = frame
        guard playback == nil || displayedFrame != nil else {
            return
        }
        setLayerContents(frame)
    }

    private func setLayerContents(_ frame: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = frame
        CATransaction.commit()
    }
}
