import CoreGraphics
import Foundation
import UIKit

/// 불러올 이미지와 불러오는 방법을 담은 값입니다.
///
/// 주소 외에 필터, 우선순위, 캐시 옵션을 함께 담습니다. 값 타입이라 복사한 뒤 고쳐도 원래 요청은 바뀌지 않습니다.
///
/// ```swift
/// var request = ImageRequest(url: url, filters: [.resize(width: 120)])
/// request.priority = .high
/// let image = try await ImageSession.shared.image(for: request)
/// ```
public struct ImageRequest: CustomStringConvertible, Sendable, ExpressibleByStringLiteral {
    /// 작업 큐에서 기다리는 순서를 정합니다.
    ///
    /// 동시 다운로드 수(기본 6개)가 다 찼을 때 높은 우선순위부터 시작합니다. 이미 시작한 다운로드를 멈추지는 않습니다.
    /// 같은 이미지를 여러 곳에서 요청하면 그중 가장 높은 우선순위를 따릅니다.
    @frozen public enum Priority: Int, Comparable, CaseIterable, Sendable {
        /// 다른 요청이 모두 끝난 뒤에 받아도 되는 이미지에 씁니다. 화면을 벗어난 셀의 이미지가 그런 경우입니다.
        case veryLow = 0
        /// 곧 보일 것 같아 미리 받아 두는 이미지에 씁니다.
        case low
        /// 기본값입니다.
        case normal
        /// 지금 화면에 보이는 이미지에 씁니다.
        case high
        /// 화면에서 가장 먼저 보여야 하는 이미지에 씁니다. 상세 화면의 대표 이미지가 그런 경우입니다.
        case veryHigh

        public static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// 캐시를 읽고 쓰는 방식과 작업 큐 사용 여부를 정합니다.
    ///
    /// 디스크 캐시 옵션은 ``ImageSession/Configuration/diskCache``에만 적용됩니다.
    /// ``ImageSession/shared``가 쓰는 `URLCache`에는 영향을 주지 않습니다.
    public struct Options: OptionSet, Hashable, Sendable {
        /// 옵션을 비트로 담은 값입니다. 비트 배치는 버전이 바뀌어도 유지합니다.
        public let rawValue: UInt16

        /// 비트 값으로 옵션을 만듭니다.
        public init(rawValue: UInt16) {
            self.rawValue = rawValue
        }

        /// 메모리 캐시를 읽지 않습니다. 받은 결과는 메모리 캐시에 저장합니다.
        public static let disableMemoryCacheReads = Options(rawValue: 1 << 0)
        /// 받은 결과를 메모리 캐시에 저장하지 않습니다. 이미 저장된 이미지는 읽습니다.
        public static let disableMemoryCacheWrites = Options(rawValue: 1 << 1)
        /// 메모리 캐시를 읽지도 쓰지도 않습니다.
        public static let disableMemoryCache: Options = [.disableMemoryCacheReads, .disableMemoryCacheWrites]
        /// 디스크 캐시를 읽지 않습니다. 받은 결과는 디스크 캐시에 저장합니다.
        public static let disableDiskCacheReads = Options(rawValue: 1 << 2)
        /// 받은 결과를 디스크 캐시에 저장하지 않습니다. 이미 저장된 데이터는 읽습니다.
        public static let disableDiskCacheWrites = Options(rawValue: 1 << 3)
        /// 디스크 캐시를 읽지도 쓰지도 않습니다.
        public static let disableDiskCache: Options = [.disableDiskCacheReads, .disableDiskCacheWrites]
        /// 메모리 캐시와 디스크 캐시를 읽지 않고 다시 받습니다. 받은 결과는 두 캐시에 저장합니다.
        ///
        /// `URLCache`에 남은 응답은 그대로 쓸 수 있습니다. 서버에 다시 확인하려면 ``ImageRequest/revalidatesCachedData``를 켜 주세요.
        public static let reloadIgnoringCachedData: Options = [.disableMemoryCacheReads, .disableDiskCacheReads]
        /// 캐시에 있는 이미지만 쓰고 네트워크 요청은 보내지 않습니다.
        ///
        /// 메모리 캐시와 디스크 캐시에 모두 없으면 ``ImageSession/Error/dataMissingInCache``로 끝납니다.
        /// ``ImageSession/shared``는 디스크 캐시 대신 `URLCache`를 쓰기 때문에, 이 옵션을 켜면 메모리 캐시만 확인합니다.
        public static let returnCacheDataDontLoad = Options(rawValue: 1 << 4)
        /// 디코딩한 이미지를 백그라운드에서 미리 그려 두는 단계를 건너뜁니다.
        ///
        /// 결과를 화면에 바로 그리지 않고 파일로 저장하거나 다시 인코딩할 때 쓰면 메모리와 CPU를 아낍니다.
        /// 이 옵션으로 받은 이미지를 메인 스레드에서 처음 그릴 때는 디코딩 때문에 멈출 수 있습니다.
        public static let skipDecompression = Options(rawValue: 1 << 5)
        /// 동시 다운로드 수 제한(``ImageSession/Configuration/dataLoadingQueue``, 기본 6개)을 거치지 않고 바로 받습니다.
        ///
        /// 큐에 다운로드가 밀려 있어도 이 요청은 기다리지 않습니다. 여러 요청에 함께 켜면 동시 다운로드 수가 제한 없이 늘어납니다.
        public static let skipDataLoadingQueue = Options(rawValue: 1 << 6)
    }

    /// ``ImageRequest/userInfo``에 값을 넣을 때 쓰는 키입니다.
    ///
    /// 문자열 리터럴로 만들 수 있습니다. 라이브러리가 쓰는 키는 `imageloader/`로 시작하니 다른 접두어를 써 주세요.
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
    }

    /// 작업 큐에서 기다리는 순서입니다. 기본값은 ``Priority/normal``입니다.
    public var priority: Priority {
        get { ref.priority }
        set { mutate { $0.priority = newValue } }
    }

    /// 디코딩한 이미지에 앞에서부터 차례로 적용할 필터입니다.
    ///
    /// 필터 구성이 다르면 다른 캐시 항목을 씁니다. 필터의 순서도 캐시 키에 들어갑니다.
    public var filters: [any ImageFilter] {
        get { ref.filters }
        set { mutate { $0.filters = newValue } }
    }

    /// 캐시를 읽고 쓰는 방식입니다. 기본값은 빈 값이고, 모든 캐시를 읽고 씁니다.
    public var options: Options {
        get { ref.options }
        set { mutate { $0.options = newValue } }
    }

    /// 요청에 붙여 보내는 값입니다. 델리게이트나 직접 만든 필터에서 꺼내 씁니다.
    ///
    /// 캐시 키에는 들어가지 않습니다. 값만 다른 두 요청은 같은 캐시 항목을 씁니다.
    public var userInfo: [UserInfoKey: any Sendable] {
        get { ref.userInfo ?? [:] }
        set { mutate { $0.userInfo = newValue } }
    }

    /// 네트워크로 보낼 요청입니다.
    ///
    /// 주소로 만든 요청은 기본 `URLRequest`를 돌려줍니다. 클로저로 만든 요청은 네트워크를 쓰지 않으므로 `nil`입니다.
    public var urlRequest: URLRequest? {
        switch ref.resource {
        case .url(let url): url.map { URLRequest(url: $0) }
        case .urlRequest(let urlRequest): urlRequest
        case .data, .image: nil
        }
    }

    /// 이미지의 주소입니다. 클로저로 만든 요청은 `nil`입니다.
    public var url: URL? {
        switch ref.resource {
        case .url(let url): url
        case .urlRequest(let urlRequest): urlRequest.url
        case .data, .image: nil
        }
    }

    /// 캐시에서 이미지를 구분하는 값입니다.
    ///
    /// 기본값은 주소 문자열이고, 클로저로 만든 요청은 `id`입니다. 헤더는 들어가지 않습니다.
    /// 서명 토큰처럼 주소가 바뀌어도 같은 이미지라면, 바뀌지 않는 부분을 넣어 캐시를 함께 쓰게 할 수 있습니다.
    /// `nil`을 넣으면 기본값으로 돌아갑니다.
    public var imageID: String? {
        get { ref.customImageID ?? ref.originalImageID }
        set { mutate { $0.customImageID = newValue } }
    }

    /// 디코딩한 `UIImage`의 `scale` 값입니다. 기본값은 1입니다.
    ///
    /// 값이 1이면 300픽셀 이미지의 `size`가 300포인트이고, 3이면 100포인트입니다. 캐시 키에 들어갑니다.
    public var scale: Float {
        get { ref.scale }
        set { mutate { $0.scale = newValue } }
    }

    /// 원본 대신 작은 크기로 디코딩할 때의 설정입니다.
    ///
    /// 원본을 모두 디코딩한 뒤 줄이지 않고 처음부터 작게 디코딩하므로, 큰 사진을 목록에 띄울 때 메모리를 덜 씁니다.
    /// 캐시 키에 들어갑니다.
    public var thumbnail: ThumbnailOptions? {
        get { ref.thumbnail }
        set { mutate { $0.thumbnail = newValue } }
    }

    public var description: String {
        "ImageRequest(resource: \(ref.resource), priority: \(priority), filters: \(filters.map(\.identifier)), options: \(options.rawValue))"
    }

    /// 문자열 리터럴로 요청을 만듭니다. 주소로 바꿀 수 없는 문자열이면 주소가 `nil`인 요청이 됩니다.
    public init(stringLiteral value: String) {
        self.init(url: URL(string: value))
    }

    /// 주소로 요청을 만듭니다.
    ///
    /// - Parameters:
    ///   - url: 불러올 이미지의 주소입니다. `nil`이면 요청은 ``ImageSession/Error/dataLoadingFailed(error:)``로 끝납니다.
    ///   - filters: 디코딩한 이미지에 차례로 적용할 필터입니다.
    ///   - priority: 작업 큐에서 기다리는 순서입니다.
    ///   - options: 캐시를 읽고 쓰는 방식입니다.
    ///   - userInfo: 델리게이트나 필터에 넘길 값입니다. 캐시 키에는 들어가지 않습니다.
    public init(
        url: URL?,
        filters: [any ImageFilter] = [],
        priority: Priority = .normal,
        options: Options = [],
        userInfo: [UserInfoKey: any Sendable]? = nil
    ) {
        ref = Container(resource: .url(url), filters: filters, priority: priority, options: options, userInfo: userInfo)
    }

    /// `URLRequest`로 요청을 만듭니다. 헤더나 타임아웃을 정해야 할 때 씁니다.
    ///
    /// 캐시 키에는 주소만 들어갑니다. 헤더만 다른 두 요청은 같은 캐시 항목을 씁니다.
    ///
    /// - Parameters:
    ///   - urlRequest: 네트워크로 보낼 요청입니다.
    ///   - filters: 디코딩한 이미지에 차례로 적용할 필터입니다.
    ///   - priority: 작업 큐에서 기다리는 순서입니다.
    ///   - options: 캐시를 읽고 쓰는 방식입니다.
    ///   - userInfo: 델리게이트나 필터에 넘길 값입니다. 캐시 키에는 들어가지 않습니다.
    public init(
        urlRequest: URLRequest,
        filters: [any ImageFilter] = [],
        priority: Priority = .normal,
        options: Options = [],
        userInfo: [UserInfoKey: any Sendable]? = nil
    ) {
        ref = Container(resource: .urlRequest(urlRequest), filters: filters, priority: priority, options: options, userInfo: userInfo)
    }

    /// 바이트를 돌려주는 클로저로 요청을 만듭니다. 이미지가 네트워크가 아닌 곳에 있을 때 씁니다.
    ///
    /// 클로저는 캐시에 이미지가 없을 때만 부릅니다. 같은 `id`로 동시에 요청하면 한 번만 부릅니다.
    ///
    /// - Parameters:
    ///   - id: 캐시에서 이미지를 구분하는 값입니다. 다른 이미지에 같은 값을 쓰면 캐시가 섞입니다.
    ///   - data: 이미지 바이트를 돌려줍니다. 오류를 일으키면 요청은 ``ImageSession/Error/dataLoadingFailed(error:)``로 끝납니다.
    ///   - filters: 디코딩한 이미지에 차례로 적용할 필터입니다.
    ///   - priority: 작업 큐에서 기다리는 순서입니다.
    ///   - options: 캐시를 읽고 쓰는 방식입니다.
    ///   - userInfo: 델리게이트나 필터에 넘길 값입니다. 캐시 키에는 들어가지 않습니다.
    public init(
        id: String,
        data: @Sendable @escaping () async throws -> Data,
        filters: [any ImageFilter] = [],
        priority: Priority = .normal,
        options: Options = [],
        userInfo: [UserInfoKey: any Sendable]? = nil
    ) {
        ref = Container(resource: .data(id: id, fetch: data), filters: filters, priority: priority, options: options, userInfo: userInfo)
    }

    /// 이미 만든 이미지를 돌려주는 클로저로 요청을 만듭니다. 디코딩을 건너뛰고 필터와 캐시만 거칩니다.
    ///
    /// - Parameters:
    ///   - id: 캐시에서 이미지를 구분하는 값입니다. 다른 이미지에 같은 값을 쓰면 캐시가 섞입니다.
    ///   - image: 이미지를 돌려줍니다. 오류를 일으키면 요청은 ``ImageSession/Error/dataLoadingFailed(error:)``로 끝납니다.
    ///   - filters: 이미지에 차례로 적용할 필터입니다.
    ///   - priority: 작업 큐에서 기다리는 순서입니다.
    ///   - options: 캐시를 읽고 쓰는 방식입니다.
    ///   - userInfo: 델리게이트나 필터에 넘길 값입니다. 캐시 키에는 들어가지 않습니다.
    public init(
        id: String,
        image: @Sendable @escaping () async throws -> ImageContent,
        filters: [any ImageFilter] = [],
        priority: Priority = .normal,
        options: Options = [],
        userInfo: [UserInfoKey: any Sendable]? = nil
    ) {
        ref = Container(resource: .image(id: id, fetch: image), filters: filters, priority: priority, options: options, userInfo: userInfo)
    }

    private var ref: Container

    var resource: Resource {
        ref.resource
    }

    var originalImageID: String? {
        ref.originalImageID
    }

    func withFilters(_ filters: [any ImageFilter]) -> ImageRequest {
        var request = self
        request.filters = filters
        return request
    }

    func withoutThumbnail() -> ImageRequest {
        var request = self
        request.thumbnail = nil
        return request
    }

    private mutating func mutate(_ closure: (Container) -> Void) {
        if !isKnownUniquelyReferenced(&ref) {
            ref = Container(ref)
        }
        closure(ref)
    }

    private final class Container: @unchecked Sendable {
        let resource: Resource
        let originalImageID: String?
        var customImageID: String?
        var priority: Priority
        var filters: [any ImageFilter]
        var options: Options
        var userInfo: [UserInfoKey: any Sendable]?
        var scale: Float = 1
        var thumbnail: ThumbnailOptions?

        init(resource: Resource, filters: [any ImageFilter], priority: Priority, options: Options, userInfo: [UserInfoKey: any Sendable]?) {
            self.resource = resource
            switch resource {
            case .url(let url): originalImageID = url?.absoluteString
            case .urlRequest(let urlRequest): originalImageID = urlRequest.url?.absoluteString
            case .data(let id, _): originalImageID = id
            case .image(let id, _): originalImageID = id
            }
            self.filters = filters
            self.priority = priority
            self.options = options
            self.userInfo = userInfo
        }

        init(_ other: Container) {
            resource = other.resource
            originalImageID = other.originalImageID
            customImageID = other.customImageID
            priority = other.priority
            filters = other.filters
            options = other.options
            userInfo = other.userInfo
            scale = other.scale
            thumbnail = other.thumbnail
        }
    }
}

extension CGSize {
    func scaled(by scale: CGFloat) -> CGSize {
        CGSize(width: width * scale, height: height * scale)
    }
}

enum Screen {
    private static let fallback = LockIsolated<CGFloat>(2)

    static var scale: CGFloat {
        let scale = UITraitCollection.current.displayScale
        if scale > 0 {
            fallback.withLock { $0 = scale }
            return scale
        }
        return fallback.value
    }
}
