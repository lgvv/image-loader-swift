# UIKit에서 쓰기

`UIImageView`와 컬렉션 뷰 셀에 이미지를 보여 주는 방법을 알아봅니다.

## Overview

### 이미지 뷰에 넣기

``loadImage(with:options:into:completion:)-(URL?,_,_,_)``에 주소와 뷰를 넘깁니다.

```swift
loadImage(with: url, into: imageView)
```

같은 뷰에 이전 요청이 남아 있으면 먼저 취소하고, 취소된 요청의 결과는 버립니다.
그래서 셀을 재사용할 때 이전 이미지가 늦게 도착해 새 이미지를 덮어쓰는 일이 생기지 않습니다.
`prepareForReuse()`에서 따로 취소하지 않아도 됩니다.

### 플레이스홀더와 전환 효과

``ImageLoadingOptions``로 불러오는 동안 보여 줄 이미지, 실패했을 때의 이미지, 전환 효과를 정합니다.

```swift
let options = ImageLoadingOptions(
    placeholder: UIImage(named: "placeholder"),
    transition: .fadeIn(duration: 0.25),
    failureImage: UIImage(named: "broken")
)
loadImage(with: url, options: options, into: imageView)
```

앱 전체에 같은 설정을 쓰려면 앱이 시작할 때 ``ImageLoadingOptions/shared``를 바꿉니다.
메모리 캐시에서 바로 보여 줄 때는 전환 효과를 쓰지 않습니다. 스크롤할 때마다 이미지가 깜빡이지 않게 하려는 것입니다.

### 컬렉션 뷰에서 미리 받기

`UICollectionViewDataSourcePrefetching`과 `ImagePrefetcher`를 함께 쓰면, 셀이 나타날 때 이미지가 이미 캐시에 있습니다.

```swift
let prefetcher = ImagePrefetcher()

func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
    prefetcher.startPrefetching(with: indexPaths.map { photos[$0.item].url })
}

func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
    prefetcher.stopPrefetching(with: indexPaths.map { photos[$0.item].url })
}
```

미리 받는 요청에 필터나 썸네일 설정을 넣었다면, 셀에서 보여 줄 요청과 똑같이 맞춰 주세요. 다르면 다른 캐시 항목으로 저장해서 미리 받은 효과가 없습니다.

### 플레이스홀더 뷰와 실패 뷰가 필요할 때

이미지 대신 뷰를 플레이스홀더로 쓰거나, 실패했을 때 버튼을 보여 주려면 ``AsyncImageView``를 씁니다.
``AsyncImageView/url``을 넣으면 바로 불러오기 시작합니다.

```swift
let imageView = AsyncImageView()
imageView.placeholderView = UIActivityIndicatorView(style: .medium)
imageView.failureView = retryButton
imageView.onFailure = { error in
    retryButton.isEnabled = (error as? ImageSession.Error)?.isRetryable ?? false
}
imageView.url = url
```

셀에서 쓸 때는 `prepareForReuse()`에서 ``AsyncImageView/reset()``을 불러 이전 이미지와 실패 뷰를 숨깁니다.
같은 자리에서 이미지만 바꾸는 화면이라면 ``AsyncImageView/isResetEnabled``를 `false`로 두어, 새 이미지가 올 때까지 이전 이미지를 남길 수 있습니다.

### 직접 만든 뷰에 보여 주기

`UIImageView`가 아닌 뷰에 이미지를 넣으려면 ``ImageLoader_ImageDisplaying``을 따르게 합니다.

```swift
extension MyBadgeView: ImageLoader_ImageDisplaying {
    func imageLoader_display(image: UIImage?, data: Data?) {
        iconLayer.contents = image?.cgImage
    }
}
```
