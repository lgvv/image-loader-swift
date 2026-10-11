# ``ImageLoaderTesting``

네트워크 없이 `ImageLoader`를 쓰는 코드를 테스트합니다.

## Overview

``MockDataLoader``에 주소마다 응답을 정해 두고 세션의 `dataLoader`로 넣으면, 캐시와 디코딩, 취소 동작을 실제 네트워크 없이 확인할 수 있습니다.

```swift
@Test
func reusesCachedImage() async throws {
    let loader = MockDataLoader()
    loader.setResponse(.data(pngData), for: url)
    let session = ImageSession(configuration: .init(dataLoader: loader))

    _ = try await session.image(for: url)
    _ = try await session.image(for: url)

    #expect(loader.counts.started == 1)
}
```

``MockDataLoader/isSuspended``를 `true`로 두면 응답을 보내지 않고 붙잡아 둡니다.
요청이 끝나기 전에 취소하거나, 같은 이미지 요청을 하나로 합치는 동작을 확인할 때 씁니다.

실패 쿨다운처럼 시간이 지나야 바뀌는 동작은 `@_spi(Testing) import`로 `TestClock`을 가져와 세션의 시계로 넣고, 시간을 직접 움직여 확인합니다.

## Topics

### 응답 흉내 내기

- ``MockDataLoader``
