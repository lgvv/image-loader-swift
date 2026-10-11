# 캐시

메모리 캐시와 디스크 캐시가 어떻게 나뉘는지, 상황에 맞게 어떤 설정을 고르면 되는지 알아봅니다.

## Overview

세션은 이미지를 메모리 캐시, 디스크 캐시, 네트워크 순서로 찾습니다.
메모리 캐시에는 디코딩을 마친 이미지를, 디스크 캐시에는 디코딩 전 데이터를 보관합니다.

| 캐시 | 보관하는 것 | 기본 크기 |
| --- | --- | --- |
| ``MemoryCache`` | 디코딩을 마친 이미지 | 기기 메모리의 15%와 768MB 중 작은 값 |
| `URLCache` | 서버 응답 | 디스크 150MB |
| ``DiskCache`` | 원본 데이터나 필터 결과 | 디스크 150MB |

### 디스크 캐시 고르기

``ImageSession/shared``는 ``ImageSession/Configuration/withURLCache`` 설정을 씁니다.
`URLCache`는 서버가 보낸 `Cache-Control` 헤더를 따르므로, 서버가 캐시 기간을 정해 두었다면 그대로 지킵니다.

서버 헤더와 상관없이 받은 이미지를 디스크에 남기려면 ``ImageSession/Configuration/withDiskCache``를 씁니다.
``DiskCache``는 헤더를 보지 않고, 크기가 한도를 넘으면 오래 읽지 않은 파일부터 지웁니다.

```swift
ImageSession.shared = ImageSession(configuration: .withDiskCache(name: "Images", sizeLimit: 200 * 1024 * 1024))
```

`URLCache`와 ``DiskCache``를 함께 쓰면 같은 데이터를 두 번 저장하므로, ``ImageSession/Configuration/withDiskCache``는 `URLCache`를 끈 상태로 만듭니다.

### 필터 결과를 디스크에 남길지 정하기

``ImageSession/Configuration/diskCachePolicy``로 디스크 캐시에 무엇을 남길지 정합니다.

| 정책 | 원본 데이터 | 필터 결과 | 고르는 기준 |
| --- | --- | --- | --- |
| ``ImageSession/DiskCachePolicy/storeOriginalData`` | 저장 | 저장 안 함 | 기본값입니다. 같은 원본을 여러 크기로 보여 줄 때 맞습니다. |
| ``ImageSession/DiskCachePolicy/storeEncodedImages`` | 저장 안 함 | 저장 | 늘 같은 크기로만 보여 줄 때 디스크를 아낍니다. |
| ``ImageSession/DiskCachePolicy/automatic`` | 필터 없는 요청만 | 저장 | 요청마다 필요한 쪽만 남깁니다. |
| ``ImageSession/DiskCachePolicy/storeAll`` | 저장 | 저장 | 디스크를 가장 많이 쓰는 대신 필터를 다시 적용하지 않습니다. |

### 캐시 키

캐시 키에는 ``ImageRequest/imageID``, 필터, ``ImageRequest/scale``, 썸네일 설정이 들어갑니다.
기본 ``ImageRequest/imageID``는 주소 문자열이고, 헤더와 ``ImageRequest/userInfo``는 들어가지 않습니다.

서명 토큰처럼 주소가 요청마다 바뀌어도 같은 이미지라면, 바뀌지 않는 부분을 ``ImageRequest/imageID``에 넣어 캐시를 함께 쓰게 합니다.

```swift
var request = ImageRequest(url: signedURL)
request.imageID = signedURL.path
```

### 캐시를 직접 다루기

``ImageSession/cache``로 요청 단위로 읽고 지웁니다. 요청을 넘기면 세션이 불러올 때와 같은 키를 씁니다.

```swift
let cache = ImageSession.shared.cache
cache.removeCachedImage(for: request)
let isCached = cache.containsCachedImage(for: request, caches: [.memory])
```

프로필 사진을 바꾼 직후처럼 같은 주소의 이미지가 바뀌었을 수 있다면 ``ImageRequest/revalidatesCachedData``를 켭니다.
메모리 캐시와 디스크 캐시를 건너뛰고, `URLCache`에 남은 응답도 서버에 확인한 뒤에 씁니다.

### 메모리가 부족할 때

``MemoryCache``는 시스템이 메모리 압박을 알리면 모두 비우고, 앱이 백그라운드로 가면 한도의 10%만 남깁니다.
비운 뒤 10초 동안 같은 이미지를 다시 불러온 수를 ``ImageSession/Diagnostic/memoryPressureRecovery(reason:redecodedCount:diskReadCount:)``로 알려 주므로,
이 값이 크면 ``MemoryCacheLifecyclePolicy/pressureWarningTrimRatio``로 모두 비우는 대신 일부만 줄이도록 바꿔 볼 수 있습니다.
