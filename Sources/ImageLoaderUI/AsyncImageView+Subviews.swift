import Foundation
import UIKit

extension AsyncImageView {
    func display(_ content: ImageContent, isFromMemory: Bool) {
        if isResetNeeded {
            reset(clearsImage: false, cancels: !content.isPreview)
        }
        removeCustomImageView()
        if let custom = makeImageView?(content) {
            addSubview(custom)
            custom.layoutInSuperview(.fill)
            customImageView = custom
        } else {
            animatedImageView.display(content)
            if animatedImageView.isHidden {
                animatedImageView.isHidden = false
            }
        }
        guard !isFromMemory, let transition else {
            return
        }
        switch transition {
        case .fadeIn(let duration):
            fadeIn(duration: duration)
        case .custom(let closure):
            closure(self, content)
        }
    }

    private func fadeIn(duration: TimeInterval) {
        guard !animatedImageView.isHidden else {
            return
        }
        animatedImageView.alpha = 0
        UIView.animate(withDuration: duration, delay: 0, options: [.allowUserInteraction]) {
            self.animatedImageView.alpha = 1
        }
    }

    func removeCustomImageView() {
        guard let customImageView else {
            return
        }
        customImageView.removeFromSuperview()
        self.customImageView = nil
    }

    func setPlaceholderViewHidden(_ isHidden: Bool) {
        guard let placeholderView, placeholderView.isHidden != isHidden else {
            return
        }
        placeholderView.isHidden = isHidden
    }

    func setPlaceholderImage(_ image: UIImage?) {
        placeholderView = image.map { UIImageView(image: $0) }
    }

    func replacePlaceholderView(_ oldView: UIView?, with newView: UIView?) {
        oldView?.removeFromSuperview()
        guard let newView else {
            return
        }
        newView.isHidden = !animatedImageView.isHidden
        insertSubview(newView, at: 0)
        setNeedsUpdateConstraints()
        if let spinner = newView as? UIActivityIndicatorView {
            spinner.startAnimating()
        }
    }

    func setFailureViewHidden(_ isHidden: Bool) {
        guard let failureView, failureView.isHidden != isHidden else {
            return
        }
        failureView.isHidden = isHidden
    }

    func setFailureImage(_ image: UIImage?) {
        failureView = image.map { UIImageView(image: $0) }
    }

    func replaceFailureView(_ oldView: UIView?, with newView: UIView?) {
        oldView?.removeFromSuperview()
        guard let newView else {
            return
        }
        newView.isHidden = true
        insertSubview(newView, at: 0)
        setNeedsUpdateConstraints()
    }
}

extension UIView {
    @discardableResult
    func layoutInSuperview(_ position: AsyncImageView.SubviewPosition) -> [NSLayoutConstraint] {
        guard let superview else {
            return []
        }
        translatesAutoresizingMaskIntoConstraints = false
        let constraints =
            switch position {
            case .fill:
                [
                    topAnchor.constraint(equalTo: superview.topAnchor),
                    bottomAnchor.constraint(equalTo: superview.bottomAnchor),
                    leadingAnchor.constraint(equalTo: superview.leadingAnchor),
                    trailingAnchor.constraint(equalTo: superview.trailingAnchor),
                ]
            case .center:
                [
                    centerXAnchor.constraint(equalTo: superview.centerXAnchor),
                    centerYAnchor.constraint(equalTo: superview.centerYAnchor),
                ]
            }
        NSLayoutConstraint.activate(constraints)
        return constraints
    }
}
