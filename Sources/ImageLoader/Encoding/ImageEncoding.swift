import Foundation
import UIKit

/// 이미지를 디스크 캐시에 저장할 데이터로 바꾸는 인코더가 따르는 프로토콜입니다.
///
/// 필터를 적용한 이미지나 ``ImageSession/Cache/storeCachedImage(_:for:caches:)``로 넣은 이미지를 디스크 캐시에 저장할 때 씁니다.
/// 내려받은 원본 데이터는 인코딩하지 않고 그대로 저장합니다.
public protocol ImageEncoding: Sendable {
    /// 이미지를 데이터로 바꿉니다. 바꾸지 못하면 `nil`을 돌려주고, 그 이미지는 디스크 캐시에 저장하지 않습니다.
    func encode(_ image: UIImage) -> Data?
    /// 이미지와 그 정보를 데이터로 바꿉니다. 요청에 따라 형식을 바꿔야 할 때 구현합니다.
    func encode(_ content: ImageContent, context: ImageEncodingContext) -> Data?
}

extension ImageEncoding {
    /// 기본 구현은 애니메이션 이미지와 GIF면 원본 데이터를 그대로 돌려주고, 나머지는 ``encode(_:)``를 부릅니다.
    public func encode(_ content: ImageContent, context: ImageEncodingContext) -> Data? {
        if content.userInfo[.animatedImageKey] != nil || content.type == .gif, let data = content.data {
            return data
        }
        return encode(content.image)
    }
}

/// 인코딩할 때 쓰는 정보입니다.
public struct ImageEncodingContext: Sendable {
    /// 인코딩할 이미지를 요청한 요청입니다.
    public let request: ImageRequest
    /// 인코딩할 이미지입니다.
    public let image: UIImage
    /// 원본을 받을 때의 서버 응답입니다. 캐시에서 읽었으면 `nil`입니다.
    public let urlResponse: URLResponse?

    /// 인코딩 정보를 만듭니다.
    public init(request: ImageRequest, image: UIImage, urlResponse: URLResponse?) {
        self.request = request
        self.image = image
        self.urlResponse = urlResponse
    }
}
