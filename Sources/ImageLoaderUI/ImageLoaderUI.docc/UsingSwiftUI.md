# SwiftUI에서 쓰기

``CachedAsyncImage``로 이미지를 보여 주고, 필요하면 ``AsyncImageModel``로 직접 뷰를 구성하는 방법을 알아봅니다.

## Overview

### AsyncImage 대신 쓰기

``CachedAsyncImage``는 SwiftUI `AsyncImage`와 쓰는 법이 같지만, ``ImageSession``의 메모리 캐시와 디스크 캐시를 씁니다.
목록을 스크롤해 셀이 다시 나타나도 메모리 캐시에서 바로 보여 줍니다.

```swift
CachedAsyncImage(url: url) { phase in
    if let image = phase.image {
        image.resizable().scaledToFill()
    } else if phase.error != nil {
        Image(systemName: "exclamationmark.triangle")
    } else {
        ProgressView()
    }
}
.frame(width: 80, height: 80)
.clipped()
```

`content` 클로저 없이 만들면 이미지를 원래 크기로 보여 주고, 불러오는 동안에는 `secondarySystemBackground` 색을 채웁니다.

### 필터와 우선순위

수정자로 필터, 우선순위, 세션을 바꿉니다. 주소, 우선순위, 옵션, 필터 중 하나가 바뀌면 다시 불러옵니다.

```swift
CachedAsyncImage(url: url)
    .filters([.resize(width: 80), .circle()])
    .priority(.high)
```

### 화면에서 사라질 때

기본으로 뷰가 화면에서 사라지면 요청을 취소합니다.
빠르게 스크롤하는 목록에서 셀이 곧 다시 나타날 가능성이 높다면, 취소하지 않고 우선순위만 낮춥니다.

```swift
CachedAsyncImage(url: url)
    .onDisappear(.lowerPriority)
```

### 직접 구성하기

``CachedAsyncImage``로 표현하기 어려운 화면은 ``AsyncImageModel``을 `@StateObject`로 들고 직접 그립니다.

```swift
struct PhotoDetail: View {
    let url: URL
    @StateObject private var model = AsyncImageModel()

    var body: some View {
        VStack {
            model.image?.resizable().scaledToFit()
            if model.isLoading {
                ProgressView(value: model.progress.fraction)
            }
        }
        .onAppear { model.load(url) }
        .onDisappear { model.cancel() }
    }
}
```

``AsyncImageModel/progress``는 처음 읽을 때 만들어지므로, 진행률을 보여 주지 않는 화면은 데이터를 받을 때마다 뷰를 다시 그리지 않습니다.
