import Foundation
import UIKit

/// 디코딩한 이미지와 그 이미지에 딸린 정보입니다.
///
/// 메모리 캐시에는 이 값이 그대로 들어갑니다. 애니메이션 이미지라면 ``animatedImageSource``로 프레임을 꺼낼 수 있습니다.
public struct ImageContent: Sendable {
    /// 화면에 그릴 이미지입니다. 애니메이션 이미지라면 첫 프레임입니다.
    public var image: UIImage
    /// 원본 데이터의 형식입니다. 데이터 앞부분으로 알아내지 못했으면 `nil`입니다.
    public var type: AssetType?
    /// 다운로드 도중에 만든 미리보기면 `true`입니다. 미리보기는 디스크 캐시에 저장하지 않습니다.
    public var isPreview: Bool
    /// 원본 데이터입니다. GIF와 애니메이션 이미지, 데이터만 받은 요청에서만 들어 있고, 나머지는 메모리를 아끼려고 `nil`입니다.
    public var data: Data?
    /// 디코더나 필터가 남긴 값입니다. 애니메이션 프레임 소스와 프로그레시브 JPEG의 스캔 번호가 여기에 들어갑니다.
    public var userInfo: [UserInfoKey: any Sendable]

    /// 이미지와 정보를 담아 만듭니다.
    ///
    /// - Parameters:
    ///   - image: 화면에 그릴 이미지입니다.
    ///   - type: 원본 데이터의 형식입니다.
    ///   - isPreview: 다운로드 도중에 만든 미리보기인지 나타냅니다.
    ///   - data: 원본 데이터입니다. 메모리 캐시에 함께 들어가므로 꼭 필요할 때만 넣어 주세요.
    ///   - userInfo: 디코더나 필터가 남길 값입니다.
    public init(
        image: UIImage,
        type: AssetType? = nil,
        isPreview: Bool = false,
        data: Data? = nil,
        userInfo: [UserInfoKey: any Sendable] = [:]
    ) {
        self.image = image
        self.type = type
        self.isPreview = isPreview
        self.data = data
        self.userInfo = userInfo
    }

    func map(_ transform: (UIImage) throws -> UIImage) rethrows -> ImageContent {
        var copy = self
        copy.image = try transform(image)
        return copy
    }

    /// ``ImageContent/userInfo``에 값을 넣을 때 쓰는 키입니다. 라이브러리가 쓰는 키는 `imageloader/`로 시작합니다.
    public struct UserInfoKey: Hashable, ExpressibleByStringLiteral, Sendable {
        /// 키 문자열입니다.
        public let rawValue: String

        /// 문자열로 키를 만듭니다.
        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        /// 문자열 리터럴로 키를 만듭니다.
        public init(stringLiteral value: String) {
            rawValue = value
        }

        /// 프로그레시브 JPEG 미리보기가 몇 번째 스캔까지 디코딩한 것인지 담는 키입니다. 값은 `Int`입니다.
        public static let scanNumberKey: UserInfoKey = "imageloader/scan-number"
    }
}

/// 요청 결과로 받은 이미지와 서버 응답, 이미지를 찾은 캐시입니다.
public struct ImageResponse: Sendable {
    /// 받은 이미지와 그 정보입니다.
    public var content: ImageContent
    /// 이 결과를 만든 요청입니다.
    public var request: ImageRequest
    /// 서버 응답입니다. 캐시에서 찾았거나 네트워크를 쓰지 않은 요청이면 `nil`입니다.
    public var urlResponse: URLResponse?
    /// 이미지를 찾은 캐시입니다. 네트워크에서 받았으면 `nil`입니다.
    public var cacheType: CacheType?

    /// ``ImageContent/image``와 같습니다.
    public var image: UIImage {
        content.image
    }

    /// ``ImageContent/isPreview``와 같습니다.
    public var isPreview: Bool {
        content.isPreview
    }

    /// 결과를 직접 만듭니다. 테스트나 직접 만든 로더에서 씁니다.
    public init(content: ImageContent, request: ImageRequest, urlResponse: URLResponse? = nil, cacheType: CacheType? = nil) {
        self.content = content
        self.request = request
        self.urlResponse = urlResponse
        self.cacheType = cacheType
    }

    /// 이미지를 찾은 캐시의 종류입니다.
    @frozen public enum CacheType: Sendable {
        /// 메모리 캐시에서 디코딩된 이미지를 바로 찾았습니다.
        case memory
        /// 디스크 캐시의 데이터를 읽어 디코딩했습니다.
        case disk
    }

    func map(_ transform: (ImageContent) throws -> ImageContent) rethrows -> ImageResponse {
        var copy = self
        copy.content = try transform(content)
        return copy
    }
}
