# ``ImageLoaderUI``

UIKit 뷰와 SwiftUI 뷰에 이미지를 불러와 보여 주고, 애니메이션 이미지를 재생합니다.

## Overview

`ImageLoaderUI`는 `ImageLoader`를 함께 내보내므로 `import ImageLoaderUI` 하나로 둘 다 쓸 수 있습니다.

UIKit에서는 `UIImageView`에 ``loadImage(with:options:into:completion:)-(URL?,_,_,_)``로 이미지를 넣고,
SwiftUI에서는 ``CachedAsyncImage``를 `AsyncImage` 대신 씁니다.
두 방법 모두 메모리 캐시에 이미지가 있으면 네트워크를 기다리지 않고 바로 보여 줍니다.

## Topics

### 시작하기

- <doc:UsingUIKit>
- <doc:UsingSwiftUI>
- <doc:AnimatedImages>

### UIKit

- ``loadImage(with:options:into:completion:)-(URL?,_,_,_)``
- ``loadImage(with:options:into:progress:completion:)-(URL?,_,_,_,_)``
- ``loadImage(with:options:into:completion:)-(ImageRequest?,_,_,_)``
- ``loadImage(with:options:into:progress:completion:)-(ImageRequest?,_,_,_,_)``
- ``cancelRequest(for:)``
- ``ImageLoadingOptions``
- ``ImageLoader_ImageDisplaying``
- ``ImageDisplayingView``
- ``AsyncImageView``

### SwiftUI

- ``CachedAsyncImage``
- ``CachedAsyncImagePhase``
- ``AsyncImageModel``

### 애니메이션 이미지

- ``AnimatedImageView``
- ``AnimatedImageRepresentable``
