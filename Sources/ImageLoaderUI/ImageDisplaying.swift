import Foundation
import UIKit

/// 이미지를 보여 줄 수 있는 뷰가 따르는 프로토콜입니다. `UIImageView`는 이미 따릅니다.
///
/// 직접 만든 뷰에서 ``loadImage(with:options:into:completion:)-(URL?,_,_,_)``를 쓰려면 이 프로토콜을 따라 주세요.
@MainActor
@objc public protocol ImageLoader_ImageDisplaying {
    /// 이미지를 뷰에 넣습니다. `image`가 `nil`이면 뷰를 비웁니다. `data`는 GIF처럼 원본 데이터가 필요한 뷰를 위해 함께 넘깁니다.
    @objc func imageLoader_display(image: UIImage?, data: Data?)
}

/// ``loadImage(with:options:into:completion:)-(URL?,_,_,_)``에 넘길 수 있는 뷰입니다.
public typealias ImageDisplayingView = UIView & ImageLoader_ImageDisplaying

extension UIImageView: ImageLoader_ImageDisplaying {
    /// `image`를 `UIImageView.image`에 넣습니다.
    open func imageLoader_display(image: UIImage?, data: Data? = nil) {
        self.image = image
    }
}
