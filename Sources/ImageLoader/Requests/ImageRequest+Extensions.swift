import Foundation

extension ImageRequest.UserInfoKey {
    /// ``ImageRequest/revalidatesCachedData`` 값을 담는 키입니다.
    public static let revalidatesCachedDataKey: ImageRequest.UserInfoKey = "imageloader/revalidates-cached-data"

    /// ``ImageRequest/bypassesFailureCooldown`` 값을 담는 키입니다.
    public static let bypassesFailureCooldownKey: ImageRequest.UserInfoKey = "imageloader/bypasses-failure-cooldown"
}

extension ImageRequest {
    /// 캐시를 건너뛰고 서버에 이미지가 바뀌었는지 확인할지 정합니다. 기본값은 `false`입니다.
    ///
    /// 켜면 메모리 캐시와 디스크 캐시를 읽지 않고, `URLCache`에 남은 응답도 서버에 확인한 뒤에 씁니다.
    /// 같은 주소의 이미지가 바뀌었을 수 있는 화면, 예를 들어 프로필 사진을 바꾼 직후에 씁니다.
    public var revalidatesCachedData: Bool {
        get { (userInfo[.revalidatesCachedDataKey] as? Bool) ?? false }
        set { userInfo[.revalidatesCachedDataKey] = newValue }
    }

    /// ``ImageSession/Configuration/failureCooldown``에 막힌 주소라도 요청을 보낼지 정합니다. 기본값은 `false`입니다.
    ///
    /// 사용자가 다시 시도 버튼을 눌렀을 때처럼 바로 다시 받아야 할 때 켭니다.
    public var bypassesFailureCooldown: Bool {
        get { (userInfo[.bypassesFailureCooldownKey] as? Bool) ?? false }
        set { userInfo[.bypassesFailureCooldownKey] = newValue }
    }

    var effectiveOptions: Options {
        revalidatesCachedData ? options.union(.reloadIgnoringCachedData) : options
    }
}
