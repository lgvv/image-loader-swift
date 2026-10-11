# 오류 다루기

이미지를 불러오지 못했을 때 원인을 가려내고, 다시 시도할지 정하고, 로그에 남기는 방법을 알아봅니다.

## Overview

세션의 모든 메서드는 ``ImageSession/Error`` 하나로 실패합니다. 네트워크 오류나 상태 코드 같은 원인은 case 안에 담깁니다.

### 화면에 보여 줄 오류 고르기

취소는 사용자가 화면을 떠났다는 뜻이라 오류로 보여 주지 않습니다. ``ImageSession/Error/isCancelled``로 먼저 걸러 냅니다.

```swift
do {
    imageView.image = try await ImageSession.shared.image(for: url)
} catch {
    guard !error.isCancelled else { return }
    showRetryButton(isEnabled: error.isRetryable)
}
```

``ImageSession/Error/isRetryable``은 잠시 뒤 다시 요청하면 성공할 수 있는 오류에서 `true`입니다.
5xx, 408, 429 상태 코드와 시간 초과, 연결 끊김이 해당하고, 404 같은 상태 코드와 디코딩 실패는 `false`입니다.

### 원인 꺼내기

| 알고 싶은 것 | 쓰는 프로퍼티 |
| --- | --- |
| HTTP 상태 코드 | ``ImageSession/Error/statusCode`` |
| 네트워크 오류 | ``ImageSession/Error/urlError`` |
| 실패 쿨다운에 막혔는지 | ``ImageSession/Error/cooldown`` |
| 원인 오류 전체 | ``ImageSession/Error/dataLoadingError`` |

### 실패가 이어지는 주소 막기

깨진 주소를 담은 셀은 스크롤할 때마다 같은 요청을 다시 보냅니다.
``ImageSession/Configuration/failureCooldown``을 켜면 같은 이미지에서 실패가 이어질 때 2초, 4초, 8초처럼 점점 길게 요청을 막습니다.
막힌 요청은 네트워크에 보내지 않고 바로 실패하며, 한 번 성공하면 기록을 지웁니다.

```swift
var configuration = ImageSession.Configuration()
configuration.failureCooldown = .init()
```

다시 시도 버튼처럼 바로 다시 받아야 할 때는 ``ImageRequest/bypassesFailureCooldown``을 켜서 보냅니다.
5xx 상태 코드나 시간 초과 같은 일시적인 오류는 기본으로 막지 않습니다.

### 로그와 통계에 남기기

``ImageSession/Error/diagnosticCode``는 `dataLoadingFailed.http.404`처럼 짧고 버전이 바뀌어도 같은 문자열입니다.
주소와 헤더가 들어가지 않으므로 그대로 로그에 남겨도 됩니다.

`NSError`로 바꾸면 도메인은 `ImageLoader.ImageSession`이고, 코드는 ``ImageSessionErrorCode``의 1부터 10 사이 값입니다.
Crashlytics처럼 `NSError` 코드로 오류를 묶는 도구에서 case마다 묶입니다.

요청 결과에 드러나지 않는 일, 예를 들어 디스크 캐시 쓰기 실패나 메모리 압박 대응은 ``ImageSession/Delegate/session(_:didRecord:)``로 받습니다.

```swift
final class Diagnostics: ImageSession.Delegate {
    func session(_ session: ImageSession, didRecord diagnostic: ImageSession.Diagnostic) {
        if case .diskCacheFailure(let operation, let error) = diagnostic {
            logger.error("disk cache \(String(describing: operation)) failed: \(error)")
        }
    }
}
```
