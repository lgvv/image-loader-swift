import Foundation
import UIKit

extension ImageViewController {
    func removeTransitionSnapshot() {
        guard let snapshot = transitionSnapshot else {
            return
        }
        transitionSnapshot = nil
        snapshot.layer.removeAllAnimations()
        snapshot.removeFromSuperview()
        view?.layer.removeAnimation(forKey: "opacity")
    }

    func fade(
        to content: ImageContent,
        in view: ImageDisplayingView,
        duration: TimeInterval,
        animationOptions: UIView.AnimationOptions,
        contentMode: UIView.ContentMode?
    ) {
        if let contentMode, contentMode != view.contentMode, let imageView = view as? UIImageView, let previous = imageView.image {
            crossDissolve(from: previous, to: content, in: imageView, duration: duration, animationOptions: animationOptions)
            return
        }
        UIView.transition(
            with: view,
            duration: duration,
            options: animationOptions.union(.transitionCrossDissolve),
            animations: { Self.show(content, in: view) },
            completion: nil
        )
    }

    private func crossDissolve(
        from previous: UIImage,
        to content: ImageContent,
        in imageView: UIImageView,
        duration: TimeInterval,
        animationOptions: UIView.AnimationOptions
    ) {
        removeTransitionSnapshot()
        let snapshot = UIImageView(image: previous)
        snapshot.frame = imageView.frame
        snapshot.contentMode = imageView.contentMode
        snapshot.clipsToBounds = imageView.clipsToBounds
        snapshot.tintColor = imageView.tintColor
        snapshot.tintAdjustmentMode = imageView.tintAdjustmentMode
        snapshot.preferredSymbolConfiguration = imageView.preferredSymbolConfiguration
        snapshot.isHidden = imageView.isHidden
        snapshot.layer.cornerRadius = imageView.layer.cornerRadius
        snapshot.layer.cornerCurve = imageView.layer.cornerCurve
        snapshot.layer.maskedCorners = imageView.layer.maskedCorners
        if #available(iOS 17.0, *) {
            snapshot.preferredImageDynamicRange = imageView.preferredImageDynamicRange
        }
        imageView.superview?.insertSubview(snapshot, aboveSubview: imageView)
        transitionSnapshot = snapshot
        let targetAlpha = imageView.alpha
        imageView.alpha = 0
        Self.show(content, in: imageView)
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: animationOptions,
            animations: {
                snapshot.alpha = 0
                imageView.alpha = targetAlpha
            },
            completion: { [weak self, weak snapshot] _ in
                guard let snapshot else {
                    return
                }
                snapshot.removeFromSuperview()
                if self?.transitionSnapshot === snapshot {
                    self?.transitionSnapshot = nil
                }
            }
        )
    }
}
