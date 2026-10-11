# 시작하기

이미지 하나를 불러오는 방법부터 진행률을 받고 취소하는 방법까지 알아봅니다.

## Overview

`ImageLoader`는 iOS 15 이상, Swift 6에서 동작하고 다른 패키지에 의존하지 않습니다.
Xcode에서 이 저장소를 Swift 패키지로 추가하고 필요한 제품을 고릅니다.

| 제품 | 쓰는 곳 |
| --- | --- |
| `ImageLoader` | 이미지 불러오기, 캐시, 디코딩, 필터, 미리 받기 |
| `ImageLoaderUI` | UIKit 뷰와 SwiftUI 뷰, 애니메이션 이미지 재생 |
| `ImageLoaderTesting` | 테스트용 로더와 시계 |

### 이미지 불러오기

``ImageSession/shared``에 주소를 넘기면 디코딩까지 마친 이미지를 돌려줍니다.

```swift
let image = try await ImageSession.shared.image(for: url)
```

호출한 `Task`를 취소하면 요청도 취소되고 ``ImageSession/Error/cancelled``로 끝납니다.
같은 이미지를 기다리는 다른 곳이 있으면 다운로드는 이어집니다.

### 요청 꾸미기

크기를 바꾸거나 우선순위를 정하려면 ``ImageRequest``를 만듭니다.

```swift
var request = ImageRequest(url: url, filters: [.resize(width: 120)])
request.priority = .high
let image = try await ImageSession.shared.image(for: request)
```

필터를 적용한 결과는 캐시에 따로 저장하므로, 같은 요청을 다시 하면 필터를 다시 적용하지 않습니다.
큰 사진을 작게 보여 줄 때는 필터보다 ``ImageRequest/thumbnail``이 메모리를 덜 씁니다.
원본을 모두 디코딩하지 않고 처음부터 작게 디코딩하기 때문입니다.

```swift
var request = ImageRequest(url: url)
request.thumbnail = .init(size: CGSize(width: 120, height: 120))
```

### 진행률을 받고 취소하기

진행률이나 미리보기가 필요하면 ``ImageSession/imageTask(with:)-(ImageRequest)``로 작업을 받습니다.
작업은 만들자마자 시작합니다.

```swift
let task = ImageSession.shared.imageTask(with: url)

Task {
    for await progress in task.progress {
        progressView.progress = progress.fraction
    }
}

let image = try await task.image
```

셀이 화면에서 벗어나면 ``ImageTask/priority``를 낮추거나 ``ImageTask/cancel()``을 불러 주세요.
우선순위를 낮추면 이미 받은 데이터를 버리지 않고, 보이는 이미지가 먼저 다운로드를 시작합니다.

### async를 쓸 수 없는 곳

클로저로 결과를 받는 ``ImageSession/loadImage(with:completion:)-(URL,_)``도 있습니다.
결과는 메인 스레드에서 받고, 작업을 취소하면 클로저를 부르지 않습니다.

```swift
ImageSession.shared.loadImage(with: url) { result in
    imageView.image = try? result.get().image
}
```

UIKit 뷰나 SwiftUI 뷰에 바로 보여 주려면 `ImageLoaderUI`의 `loadImage(with:into:)`와 `CachedAsyncImage`를 쓰는 편이 간단합니다.
셀을 재사용할 때 이전 요청을 취소하고, 불러오는 동안 플레이스홀더를 보여 줍니다.
