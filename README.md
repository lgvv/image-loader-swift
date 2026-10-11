# ImageLoader

> 학습 목적으로 만든 프로젝트입니다. 실전 이미지 라이브러리들이 푸는 문제를 직접 구현하며 이미지 로딩의 핵심 구조를 이해하는 데 목적이 있습니다. 프로덕션 사용은 권장하지 않습니다.

Swift 6 기반 iOS 이미지 로딩 라이브러리입니다.

---

## 구성

패키지는 세 개의 모듈로 나뉘어 있습니다.

- `ImageLoader`: `ImageSession`을 중심으로 이미지 불러오기, 메모리와 디스크 캐시, 디코딩, 필터, 미리 받기를 제공합니다.
- `ImageLoaderUI`: UIKit용 `loadImage(with:into:)`와 `AsyncImageView`, SwiftUI용 `CachedAsyncImage`, 애니메이션 이미지 재생을 제공합니다. `ImageLoader`를 함께 내보내므로 `import ImageLoaderUI` 하나로 둘 다 씁니다.
- `ImageLoaderTesting`: 네트워크 없이 응답을 흉내 내는 `MockDataLoader`를 제공합니다.

이미지 요청은 메모리 캐시, 디스크 캐시, 네트워크 순서로 탐색합니다. 메모리 캐시는 디코딩을 마친 이미지를 보관하기 때문에, 같은 주소라도 필터나 썸네일 설정이 다르면 별도 항목으로 관리합니다. 디스크 캐시는 기본으로 `URLCache`를 쓰고, 서버 헤더와 상관없이 남기고 싶다면 `DiskCache`로 바꿀 수 있습니다.

같은 이미지에 요청이 동시에 몰려도 다운로드와 디코딩은 한 번만 하고 결과를 나눠 줍니다. 셀 열 개가 동시에 같은 이미지를 요청해도 마찬가지이고, 그중 하나가 취소해도 나머지가 기다리고 있으면 다운로드는 이어집니다. 실패 쿨다운을 켜면 같은 이미지에서 실패가 이어질 때 막는 시간을 두 배씩 늘려가며 (기본 2초에서 최대 300초까지) 불필요한 재시도를 줄입니다.

요청마다 캐시나 디코더를 바꾸거나 인증 헤더를 붙이는 일은 `ImageSession.Delegate`로 하고, 테스트에서는 `MockDataLoader`를 세션의 `dataLoader`로 넣어 네트워크 없이 검증할 수 있습니다.

---

## 구현 노트

목록 화면에서 이미지를 보여 줄 때 실제로 생기는 문제를 하나씩 정하고, 문제마다 해결 방법과 그 효과를 테스트와 벤치마크로 확인했습니다.
수치는 모두 이 저장소의 벤치마크 테스트에서 나온 값이고, 측정 환경은 맨 아래에 적었습니다. 항목을 누르면 원인과 해결 과정이 펼쳐집니다.

<details>
<summary><b>스크롤할 때 같은 이미지를 여러 번 받는 문제</b>: 요청 2,000건에 실제 다운로드 50건</summary>

셀은 재사용되고 같은 이미지가 여러 셀에 동시에 보이기 때문에, 요청을 그대로 네트워크로 보내면 같은 파일을 여러 번 받습니다.
그래서 다운로드, 디코딩, 필터 단계를 각각 키로 묶어, 아직 끝나지 않은 같은 단계가 있으면 새로 시작하지 않고 결과를 나눠 받게 했습니다.
요청한 곳이 모두 취소했을 때만 다운로드를 멈추므로, 한 셀이 화면에서 사라져도 다른 셀의 다운로드는 끊기지 않습니다.

| 시나리오 | 결과 |
| --- | --- |
| 이미지 50장에 무작위로 요청 2,000건 | 실제 다운로드 50건, 같은 주소의 동시 다운로드 최대 1건 |
| 요청 100건 중 90건을 바로 취소 | 취소한 호출이 12ms 안에 돌아오고, 다운로드는 남은 10건만 끝까지 진행 |

</details>

<details>
<summary><b>작은 파일 하나로 앱이 종료되는 문제</b>: 1.5GB로 풀릴 48KB PNG를 디코딩 전에 차단</summary>

PNG는 압축률이 높아서, 48KB짜리 파일이 디코딩하면 20000×20000 픽셀, 약 1.5GB 비트맵이 될 수 있습니다.
디코딩을 시작하면 그 메모리를 한 번에 잡기 때문에 앱이 바로 종료됩니다.
그래서 디코딩하기 전에 파일 헤더만 읽어 픽셀 수를 확인하고, 한도를 넘으면 디코딩하지 않고 오류로 끝내게 했습니다.
한도는 기기 메모리에 맞춰 정해서, 메모리가 큰 기기에서는 큰 사진도 디코딩할 수 있게 했습니다.

| 측정 | 결과 |
| --- | --- |
| 20000×20000 PNG(48KB) 20회 | 20회 모두 디코딩 전에 거부, 메모리 증가 0MB |
| 헤더에서 크기 읽기 | 직접 만든 스캐너 1.5~6.4µs, ImageIO 27~97µs |

헤더 스캐너를 직접 만든 이유는 모든 이미지가 이 검사를 거치기 때문입니다. ImageIO로 읽으면 이미지마다 수십 µs가 더 들어서, 형식마다 크기 필드 위치만 읽는 스캐너를 만들었습니다.

</details>

<details>
<summary><b>큰 사진을 목록에 띄울 때 메모리가 부족한 문제</b>: 비트맵 46MB를 11MB로</summary>

4000×3000 사진을 그대로 디코딩하면 한 장에 약 46MB를 씁니다.
목록 셀처럼 작게 보여 줄 때는 원본을 모두 디코딩한 뒤 줄이지 않고, ImageIO에 처음부터 작은 크기로 디코딩하게 하는 썸네일 옵션을 두었습니다.

| 4000×3000 JPEG | CPU 시간 | 비트맵 크기 |
| --- | --- | --- |
| 원본 디코딩 | 36ms | 약 46MB |
| 2000×1500으로 줄여 디코딩 | 21ms | 약 11MB |

</details>

<details>
<summary><b>애니메이션 GIF가 메모리를 많이 쓰는 문제</b>: 122MB짜리 GIF를 32MB 안에서 재생, 디코딩 횟수는 LRU의 6분의 1</summary>

400×400 크기의 200프레임 GIF를 모두 디코딩하면 약 122MB입니다.
그래서 첫 프레임만 들고 있다가 재생 위치보다 3프레임 앞까지만 디코딩하고, 디코딩한 프레임은 모든 애니메이션이 함께 쓰는 32MB 캐시에 넣었습니다.

캐시가 넘칠 때 무엇을 지울지가 핵심이었습니다. 일반적인 LRU(가장 오래 안 쓴 것부터 지우기)는 반복 재생에 맞지 않습니다.
방금 보여 준 프레임이 가장 최근에 쓴 것이라 남고, 곧 보여 줄 다음 프레임이 먼저 지워지기 때문입니다.
그래서 애니메이션 하나가 한도보다 크면, 재생 위치에서 가장 늦게 다시 보일 프레임부터 지우게 했습니다.

| 측정 | 결과 |
| --- | --- |
| 200프레임 GIF 두 바퀴 재생 | 캐시 최대 31.7MB(한도 32MB), 빠진 프레임 0개 |
| 큰 GIF 1개와 작은 GIF 29개 동시 재생, LRU | 디코딩 5,738회, CPU 1,386ms |
| 같은 조건, 재생 위치 기준으로 지우기 | 디코딩 941회, CPU 686ms |

</details>

<details>
<summary><b>디스크 캐시 정리가 읽기를 막는 문제</b>: 지울 파일 고르기 13.2ms를 0.33ms로</summary>

디스크 캐시가 한도를 넘으면 오래 읽지 않은 파일을 골라 지웁니다.
항목 전체를 마지막 접근 시각으로 정렬해 고르면, 정렬하는 동안 캐시 목록에 락이 걸려 다른 스레드의 읽기가 기다립니다.
그래서 접근 순서대로 이어진 목록을 들고 있다가 가장 오래된 것부터 꺼내, 정렬 없이 고르게 했습니다.

| 항목 10,000개에서 1,001개 고르기 | 걸린 시간 |
| --- | --- |
| 정렬해서 고르기 | 13.2ms |
| 접근 순서 목록에서 꺼내기 | 0.33ms(락을 잡은 시간 0.08ms) |

쓰기도 바로 파일로 쓰지 않고 메모리에 모았다가 1초 뒤에 한꺼번에 씁니다. 같은 키를 짧은 시간에 여러 번 쓰면 마지막 값만 파일로 남습니다.

</details>

<details>
<summary><b>깨진 주소를 계속 다시 요청하는 문제</b>: 실패가 이어지면 2초부터 최대 300초까지 요청 차단</summary>

404가 나는 이미지를 담은 셀은 스크롤할 때마다 같은 요청을 보냅니다.
실패 쿨다운을 켜면 같은 이미지에서 실패가 이어질 때 2초, 4초, 8초처럼 점점 길게 요청을 막습니다.
5xx와 시간 초과처럼 다시 시도하면 성공할 수 있는 오류는 막지 않고, 404처럼 결과가 바뀌지 않을 오류만 막습니다.

</details>

<details>
<summary><b>직접 붙인 헤더가 다른 서버로 새는 문제</b>: 호스트가 바뀌는 리디렉션에서 헤더 제거</summary>

`URLSession`은 리디렉션할 때 `Authorization`은 지우지만, API 키처럼 직접 붙인 다른 헤더와 `httpAdditionalHeaders`는 새 요청에 그대로 옮겨 담습니다.
이미지 서버가 다른 호스트로 리디렉션하면 그 헤더가 다른 서버로 갈 수 있습니다.
그래서 리디렉션으로 호스트나 포트가 바뀌거나 HTTPS에서 HTTP로 내려가면, 원래 요청에 있던 헤더를 빼고 보내게 했습니다. 로컬 HTTP 서버로 실제 리디렉션을 일으켜 확인합니다.
쿠키는 아예 보내지도 저장하지도 않고, `URLCache`에는 이미지 응답만 남깁니다.

</details>

<details>
<summary><b>오류를 통계로 묶기 어려운 문제</b>: 주소가 없는 고정 오류 코드</summary>

실패를 Crashlytics 같은 도구로 모으면, 오류 메시지에 주소가 들어가 같은 원인이 수천 개로 흩어집니다.
그래서 모든 오류를 하나의 타입으로 모으고, `dataLoadingFailed.http.404`처럼 주소가 들어가지 않는 고정 코드와, 버전이 바뀌어도 변하지 않는 `NSError` 코드(1부터 10)를 붙였습니다.

</details>

<details>
<summary><b>테스트 전략</b>: 단위 436개, UI 87개, 벤치마크 포함</summary>

- 테스트는 단위 436개, UI 87개입니다. 모두 Swift Testing으로 썼습니다.
- 네트워크는 `MockDataLoader`로 흉내 내되, 리디렉션과 이어받기처럼 `URLSession` 동작에 기대는 부분은 로컬 HTTP 서버를 띄워 실제 네트워크 스택으로 확인합니다.
- 쿨다운과 속도 제한처럼 시간이 지나야 바뀌는 동작은 직접 시간을 움직이는 시계(`TestClock`)를 넣어, 실제로 기다리지 않고 확인합니다.
- 락을 잘못된 순서로 잡으면 DEBUG 빌드에서 바로 멈추도록 검사 코드를 넣어, 교착 상태를 테스트 단계에서 잡습니다.
- 벤치마크도 테스트로 두었고, 그중 일부는 기준 시간을 넘으면 테스트가 실패합니다. ThreadSanitizer를 켠 빌드에서는 시간을 재지 않습니다.

</details>

---

## 문제 해결 기록

<details>
<summary><b>iOS 27에서 멈춘 애니메이션이 첫 프레임으로 돌아가는 문제</b>: 트레잇 변경 뒤 UIImageView가 화면을 덮어씀</summary>

애니메이션을 멈춘 상태에서 다크 모드로 바꾸면, 멈춰 있던 프레임 대신 첫 프레임이 보였습니다.
출력으로 순서를 확인해 보니, `traitCollectionDidChange`에서 프레임을 다시 칠한 직후 `UIImageView`가 새 트레잇에 맞춰 `image`를 다시 그리며 화면을 덮어썼습니다.
트레잇이 바뀌면 레이아웃을 무효화해, 다음 레이아웃 단계에서 현재 프레임을 다시 칠하도록 고쳤습니다.

</details>

<details>
<summary><b>iOS 27에서 손상 프레임 테스트가 실패한 문제</b>: 최신 ImageIO가 손상 프레임을 다르게 처리함</summary>

GIF 프레임의 크기 필드를 깨뜨려 "디코딩에 실패하는 프레임"을 만드는 테스트가 iOS 27에서 실패했습니다.
확인해 보니 최신 ImageIO는 그런 프레임을 만나면 뒤 프레임을 모두 잘라 내고, 개수에 들어간 프레임은 데이터를 깨뜨려도 복구해서 돌려줬습니다.
GIF 압축 데이터, 프레임 위치, 빈 데이터, APNG 체크섬을 깨뜨려 봐도 결과는 같았습니다.
파일을 깨뜨리는 방식은 OS 버전에 따라 결과가 달라지므로, 디코딩 실패를 직접 주입하는 테스트용 훅을 두고 테스트를 그 훅으로 바꿨습니다.

</details>

---

## 요구사항

- Swift 6.0+
- iOS 15.0+
- Xcode 16.0+

---

## 설치

`Package.swift`에 패키지를 추가합니다.

```swift
.package(url: "https://github.com/lgvv/simple-image-cache.git", branch: "main")
```

그런 다음 타겟에도 추가합니다. UI 없이 쓴다면 `ImageLoader`만 추가해도 됩니다.

```swift
.product(name: "ImageLoaderUI", package: "simple-image-cache")
```

---

## 빠른 시작

이미지를 불러옵니다.

```swift
import ImageLoader

let image = try await ImageSession.shared.image(for: imageURL)

// 썸네일로 디코딩
var request = ImageRequest(url: imageURL)
request.thumbnail = .init(size: CGSize(width: 200, height: 200), contentMode: .aspectFill)
let thumbnail = try await ImageSession.shared.image(for: request)

// 사전 로드
let prefetcher = ImagePrefetcher()
prefetcher.startPrefetching(with: imageURLs)
```

썸네일 크기는 포인트로 넘기면 화면 배율을 곱해 픽셀로 바꾸므로, `UIScreen.main.scale`을 직접 곱하지 않아도 됩니다.

UIKit 이미지 뷰에 보여 줍니다. 셀을 재사용해도 이전 요청은 알아서 취소합니다.

```swift
import ImageLoaderUI

loadImage(with: imageURL, into: imageView)
```

SwiftUI에서는 `AsyncImage` 대신 씁니다.

```swift
import ImageLoaderUI

CachedAsyncImage(url: imageURL) { phase in
    phase.image?.resizable()
}
```

---

## 예제 앱

`Example/ImageLoaderExample.xcodeproj`를 열어 `ImageLoaderExample` 스킴을 빌드하고 띄웁니다. 프로젝트 파일은 `Example/project.yml`로 만들었으니, 구성을 바꿨다면 `Example` 폴더에서 `xcodegen generate`로 다시 만듭니다.

| 화면 | 보여 주는 것 |
| --- | --- |
| 갤러리 | SwiftUI 격자에 사진 목록을 보여 줍니다. 열 수를 바꾸고, 작은 이미지 주소와 원본 다운샘플을 바꿔 가며 비교합니다. 화면 아래에 네트워크, 디스크, 메모리에서 불러온 건수와 평균 시간이 나옵니다. |
| UIKit 갤러리 | 컬렉션 뷰에서 `UIImageView`, `AnimatedImageView`, `AsyncImageView` 셀과 미리 받기를 비교합니다. |
| 사진 넘겨 보기 | 원본 크기 사진을 확대하고 넘겨 봅니다. |
| 캐시 | 메모리 캐시와 디스크 캐시의 항목 수와 크기를 보고, 캐시를 비웁니다. |

---

## 문서

각 영역의 상세 내용은 DocC 문서를 참고합니다. Xcode에서 Product > Build Documentation으로 열 수 있습니다.

| 문서 | 설명 |
|---|---|
| [시작하기](Sources/ImageLoader/ImageLoader.docc/GettingStarted.md) | 이미지 불러오기, 요청 꾸미기, 진행률과 취소 |
| [캐시](Sources/ImageLoader/ImageLoader.docc/Caching.md) | 메모리 캐시, `URLCache`, `DiskCache`의 차이와 고르는 기준 |
| [오류 다루기](Sources/ImageLoader/ImageLoader.docc/ErrorHandling.md) | 오류 원인 꺼내기, 재시도 판단, 실패 쿨다운, 진단 로그 |
| [동작 바꾸기](Sources/ImageLoader/ImageLoader.docc/Customizing.md) | 인증 헤더, 직접 만든 필터와 디코더, 요청별 캐시 |
| [UIKit에서 쓰기](Sources/ImageLoaderUI/ImageLoaderUI.docc/UsingUIKit.md) | 이미지 뷰, 셀 재사용, 미리 받기, `AsyncImageView` |
| [SwiftUI에서 쓰기](Sources/ImageLoaderUI/ImageLoaderUI.docc/UsingSwiftUI.md) | `CachedAsyncImage`, `AsyncImageModel` |
| [애니메이션 이미지](Sources/ImageLoaderUI/ImageLoaderUI.docc/AnimatedImages.md) | GIF, APNG, WebP 재생 |

---

## 테스트

패키지가 UIKit에 의존하고 iOS만 지원하기 때문에 macOS(`swift test`)는 지원하지 않습니다. iOS 시뮬레이터에서 돌립니다. 시뮬레이터 이름은 설치된 기기에 맞게 바꿔 주세요.

```bash
xcodebuild test \
  -scheme ImageLoader-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  CODE_SIGNING_ALLOWED=NO
```

특정 타겟만 돌리려면 `-only-testing` 옵션을 씁니다. 테스트 타겟은 `ImageLoaderTests`와 `ImageLoaderUITests`입니다.

```bash
xcodebuild test \
  -scheme ImageLoader-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:ImageLoaderTests \
  CODE_SIGNING_ALLOWED=NO
```

벤치마크 결과는 테스트 로그에 `BENCH|`로 시작하는 줄로 남습니다. 위 표의 수치는 Xcode 27, iPhone 17 시뮬레이터(iOS 27.0), Apple Silicon Mac(메모리 18GB)에서 잰 값입니다. 시뮬레이터 수치라 실제 기기와는 다를 수 있습니다.
