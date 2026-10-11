# ``ImageLoader``

이미지를 내려받아 디코딩하고, 메모리와 디스크에 캐시합니다.

## Overview

``ImageSession``에 주소나 ``ImageRequest``를 넘기면 메모리 캐시, 디스크 캐시, 네트워크 순서로 이미지를 찾습니다.
같은 이미지를 여러 곳에서 동시에 요청하면 다운로드와 디코딩은 한 번만 합니다.

```swift
let image = try await ImageSession.shared.image(for: url)
```

화면에 그리기 전에 백그라운드에서 디코딩을 마치므로, 메인 스레드에서 이미지를 처음 그릴 때 스크롤이 끊기지 않습니다.
UIKit 뷰와 SwiftUI 뷰에 이미지를 보여 주려면 `ImageLoaderUI`를 함께 써 주세요.

## Topics

### 시작하기

- <doc:GettingStarted>
- <doc:Caching>
- <doc:ErrorHandling>
- <doc:Customizing>

### 이미지 불러오기

- ``ImageSession``
- ``ImageRequest``
- ``ImageTask``
- ``ImageResponse``
- ``ImageContent``
- ``ImageTaskMetrics``

### 캐시

- ``MemoryCache``
- ``MemoryCaching``
- ``MemoryCacheKey``
- ``MemoryCacheLifecyclePolicy``
- ``DiskCache``
- ``DiskCaching``

### 필터

- ``ImageFilter``
- ``ImageFilters``
- ``ImageFilterContext``
- ``ImageFilterOptions``
- ``ImageFilterError``

### 디코딩과 인코딩

- ``ImageDecoding``
- ``ImageDecoders``
- ``ImageDecoderRegistry``
- ``ImageDecodingContext``
- ``ImageDecodingLimits``
- ``ImageDecodingError``
- ``ImageEncoding``
- ``ImageEncoders``
- ``ImageEncodingContext``
- ``AssetType``

### 애니메이션 이미지

- ``AnimatedImageSource``
- ``AnimatedFrameCache``

### 네트워크

- ``DataLoading``
- ``DataLoader``
- ``Cancellable``

### 미리 받기와 작업 큐

- ``ImagePrefetcher``
- ``TaskQueue``

### 오류

- ``ImageSessionErrorCode``
