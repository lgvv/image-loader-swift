# 애니메이션 이미지

애니메이션 GIF, APNG, WebP를 메모리를 적게 쓰면서 재생하는 방법을 알아봅니다.

## Overview

``AnimatedImageView``는 프레임을 미리 모두 디코딩하지 않습니다.
첫 프레임만 들고 있다가, 재생 위치보다 3프레임 앞까지만 백그라운드에서 디코딩합니다.
64×64 크기의 200프레임 GIF를 모두 디코딩하면 약 3.1MB를 쓰지만, 재생 중에는 그 일부만 메모리에 둡니다.

디코딩한 프레임은 ``AnimatedFrameCache``에 보관하고, 여러 애니메이션이 함께 32MB 한도를 나눠 씁니다.

### UIKit

``AnimatedImageView``를 `UIImageView` 대신 쓰고 ``loadImage(with:options:into:completion:)-(URL?,_,_,_)``로 이미지를 넣습니다.
애니메이션 이미지면 재생하고, 정지 이미지면 그대로 보여 줍니다.

```swift
let imageView = AnimatedImageView()
loadImage(with: gifURL, into: imageView)
```

뷰가 화면에서 빠지거나 숨겨지면 재생을 멈추고, 다시 보이면 멈춘 프레임부터 이어서 재생합니다.
재생 속도는 ``AnimatedImageView/playbackRate``로, 반복 횟수는 ``AnimatedImageView/loopCountOverride``로 바꿉니다.

스크롤 성능이 더 중요하다면 ``AnimatedImageView/runLoopMode``를 `.default`로 바꿔 스크롤하는 동안 재생을 멈출 수 있습니다.

### SwiftUI

``CachedAsyncImage``의 `phase`에서 ``CachedAsyncImagePhase/animatedImage``를 꺼내 보여 줍니다.
정지 이미지면 `nil`이므로 ``CachedAsyncImagePhase/image``로 넘어갑니다.

```swift
CachedAsyncImage(url: url) { phase in
    if let animated = phase.animatedImage {
        animated
    } else {
        phase.image?.resizable()
    }
}
```

주소만 있으면 ``AnimatedImageRepresentable``을 바로 써도 됩니다.

```swift
AnimatedImageRepresentable(url: gifURL, contentMode: .scaleAspectFill)
```

### 필터와 함께 쓸 때

필터를 적용하면 첫 프레임만 남은 정지 이미지가 됩니다. 애니메이션 이미지를 줄여 보여 주려면 필터 대신 ``ImageRequest/thumbnail``을 씁니다.
썸네일 설정은 프레임마다 적용되어 애니메이션이 유지됩니다.

### 깨진 프레임

디코딩에 두 번 실패한 프레임은 건너뛰고 다음 프레임을 보여 줍니다.
보여 줄 수 있는 프레임이 하나만 남으면 ``AnimatedImageSource/canAnimate``가 `false`가 됩니다.
