import Foundation

/// 디코딩한 이미지를 보관하는 메모리 캐시가 따르는 프로토콜입니다. 기본 구현은 ``MemoryCache``입니다.
///
/// 여러 스레드에서 동시에 부르므로 스레드에 안전하게 구현해 주세요.
public protocol MemoryCaching: AnyObject, Sendable {
    /// 키의 이미지를 읽거나 씁니다. `nil`을 넣으면 지웁니다.
    subscript(key: MemoryCacheKey) -> ImageContent? { get set }
    /// 모든 이미지를 지웁니다.
    func removeAll()
}

/// 메모리 캐시에서 이미지를 구분하는 키입니다.
///
/// 요청으로 만들면 ``ImageRequest/imageID``, 필터, ``ImageRequest/scale``, 썸네일 설정을 모두 비교합니다.
public struct MemoryCacheKey: Hashable, Sendable {
    let key: Inner

    /// 문자열로 키를 만듭니다. 같은 문자열이면 요청의 다른 값과 상관없이 같은 키입니다.
    public init(key: String) {
        self.key = .custom(key)
    }

    /// 요청으로 키를 만듭니다. 세션이 이미지를 불러올 때 쓰는 키와 같습니다.
    public init(request: ImageRequest) {
        key = .default(RequestCacheKey(request))
    }

    enum Inner: Hashable, Sendable {
        case custom(String)
        case `default`(RequestCacheKey)
    }
}

/// 디코딩 전 데이터를 보관하는 디스크 캐시가 따르는 프로토콜입니다. 기본 구현은 ``DiskCache``입니다.
///
/// 세션은 메서드를 메인 스레드가 아닌 곳에서 부르고, 여러 스레드에서 동시에 부를 수 있습니다.
public protocol DiskCaching: Sendable {
    /// 키의 데이터를 읽습니다. 없으면 `nil`입니다.
    func cachedData(for key: String) -> Data?
    /// 키의 데이터가 있는지 알려 줍니다. 데이터를 읽지 않고 확인할 수 있으면 그렇게 구현해 주세요.
    func containsData(for key: String) -> Bool
    /// 키에 데이터를 저장합니다. 이미 있으면 바꿉니다.
    func storeData(_ data: Data, for key: String)
    /// 키의 데이터를 지웁니다.
    func removeData(for key: String)
    /// 모든 데이터를 지웁니다.
    func removeAll()
}
