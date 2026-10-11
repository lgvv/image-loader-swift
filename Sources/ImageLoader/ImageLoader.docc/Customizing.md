# 동작 바꾸기

인증 헤더를 붙이거나, 직접 만든 필터와 디코더를 쓰거나, 요청마다 다른 캐시를 쓰는 방법을 알아봅니다.

## Overview

세션 전체에 적용할 값은 ``ImageSession/Configuration``으로 정하고, 요청마다 달라지는 동작은 ``ImageSession/Delegate``로 정합니다.
델리게이트는 필요한 메서드만 구현하면 되고, 구현하지 않은 메서드는 설정 값을 그대로 씁니다.

### 인증 헤더 붙이기

``ImageSession/Delegate/willLoadData(for:urlRequest:session:)``은 네트워크 요청을 보내기 직전에 부릅니다.
캐시에서 이미지를 찾으면 부르지 않으므로, 토큰을 새로 받는 비용은 실제로 내려받을 때만 듭니다.

```swift
final class AuthDelegate: ImageSession.Delegate {
    let tokens: TokenStore

    init(tokens: TokenStore) {
        self.tokens = tokens
    }

    func willLoadData(for request: ImageRequest, urlRequest: URLRequest, session: ImageSession) async throws -> URLRequest {
        var urlRequest = urlRequest
        urlRequest.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        return urlRequest
    }
}

let session = ImageSession(delegate: AuthDelegate(tokens: tokens))
```

리디렉션으로 다른 호스트에 가면 ``DataLoader``가 이 헤더를 빼고 보내므로, 토큰이 다른 서버로 새지 않습니다.

### 필터 만들기

``ImageFilter``를 따르는 타입을 만들고 ``ImageFilter/identifier``를 정합니다.
식별자는 디스크 캐시 키에 들어가므로, 설정값이 다르면 다른 문자열을 돌려줘야 합니다.

```swift
struct BrightnessFilter: ImageFilter, Hashable {
    let amount: Double

    var identifier: String { "com.example/brightness?amount=\(amount)" }

    func process(_ image: UIImage) -> UIImage? {
        ImageFilters.CoreImageFilter(
            name: "CIColorControls",
            parameters: [kCIInputBrightnessKey: amount],
            identifier: identifier
        ).process(image)
    }
}
```

필터가 `Hashable`이면 메모리 캐시를 조회할 때 문자열을 만들지 않아 더 빠릅니다.
타입을 만들기 번거로우면 ``ImageFilters/Anonymous``로 클로저를 넘길 수 있습니다.

### 디코더 추가하기

시스템이 디코딩하지 못하는 형식은 ``ImageDecoding``을 구현해 ``ImageDecoderRegistry/shared``에 등록합니다.
나중에 등록한 디코더부터 물어보므로 기본 디코더보다 먼저 선택됩니다.

```swift
ImageDecoderRegistry.shared.register { context in
    context.data.starts(with: Data("<svg".utf8)) ? SVGDecoder() : nil
}
```

데이터 형식을 ``AssetType``으로 알아내야 한다면 ``AssetType/registerSignature(for:matching:)``로 시그니처를 함께 등록합니다.
디코딩 전에 ``ImageDecodingLimits/validate(_:)``를 부르면, 픽셀 수가 너무 큰 이미지 때문에 앱이 종료되는 일을 막을 수 있습니다.

### 요청마다 다른 캐시 쓰기

``ImageSession/Delegate/diskCache(for:session:)``와 ``ImageSession/Delegate/memoryCache(for:session:)``에서 요청마다 캐시를 고릅니다.
예를 들어 사용자가 올린 사진만 오래 남기고 싶다면, 그 요청에만 크기가 큰 ``DiskCache``를 돌려줍니다.
`nil`을 돌려주면 그 요청은 해당 캐시를 쓰지 않습니다.
