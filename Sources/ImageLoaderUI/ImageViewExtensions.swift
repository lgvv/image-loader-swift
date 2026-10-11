import Foundation
import UIKit

/// 주소의 이미지를 불러와 뷰에 보여 줍니다.
///
/// 같은 뷰에 이전 요청이 남아 있으면 먼저 취소합니다. 취소된 요청의 `completion`은 불리지 않으므로, 셀을 재사용할 때 이전 이미지가 늦게 덮어쓰지 않습니다.
///
/// 메모리 캐시에 이미지가 있으면 함수가 돌아오기 전에 이미지를 보여 주고 `completion`을 부릅니다. 이때 전환 효과는 쓰지 않습니다.
/// 캐시에 없으면 ``ImageLoadingOptions/placeholder``를 먼저 보여 줍니다. 실패했을 때 ``ImageLoadingOptions/failureImage``를 지정해 두었으면 그 이미지로 바꿉니다.
///
/// - Parameters:
///   - url: 불러올 이미지의 주소입니다. `nil`이면 네트워크 요청 없이 ``ImageSession/Error/imageRequestMissing``으로 끝납니다.
///   - options: 플레이스홀더, 실패 이미지, 전환 효과, 사용할 세션을 정합니다. `nil`이면 ``ImageLoadingOptions/shared``를 씁니다.
///   - view: 이미지를 보여 줄 뷰입니다. `UIImageView`와 ``AnimatedImageView``를 넣을 수 있습니다.
///   - completion: 이미지를 보여 주거나 실패했을 때 메인 스레드에서 한 번 부릅니다.
/// - Returns: 시작한 작업입니다. 메모리 캐시에서 바로 보여 줬거나 요청이 `nil`이면 `nil`을 돌려줍니다.
@MainActor
@discardableResult
public func loadImage(
    with url: URL?,
    options: ImageLoadingOptions? = nil,
    into view: ImageDisplayingView,
    completion: @escaping @MainActor @Sendable (_ result: Result<ImageResponse, ImageSession.Error>) -> Void
) -> ImageTask? {
    ImageViewController.controller(for: view).load(url.map { ImageRequest(url: $0) }, options: options ?? .shared, progress: nil, completion: completion)
}

/// 주소의 이미지를 불러와 뷰에 보여 줍니다.
///
/// 같은 뷰에 이전 요청이 남아 있으면 먼저 취소합니다. 취소된 요청의 `completion`은 불리지 않으므로, 셀을 재사용할 때 이전 이미지가 늦게 덮어쓰지 않습니다.
///
/// 메모리 캐시에 이미지가 있으면 함수가 돌아오기 전에 이미지를 보여 주고 `completion`을 부릅니다. 이때 전환 효과는 쓰지 않습니다.
/// 캐시에 없으면 ``ImageLoadingOptions/placeholder``를 먼저 보여 줍니다. 실패했을 때 ``ImageLoadingOptions/failureImage``를 지정해 두었으면 그 이미지로 바꿉니다.
///
/// - Parameters:
///   - url: 불러올 이미지의 주소입니다. `nil`이면 네트워크 요청 없이 ``ImageSession/Error/imageRequestMissing``으로 끝납니다.
///   - options: 플레이스홀더, 실패 이미지, 전환 효과, 사용할 세션을 정합니다. `nil`이면 ``ImageLoadingOptions/shared``를 씁니다.
///   - view: 이미지를 보여 줄 뷰입니다. `UIImageView`와 ``AnimatedImageView``를 넣을 수 있습니다.
///   - progress: 데이터를 받을 때마다 메인 스레드에서 부릅니다. 미리보기를 만들었으면 첫 번째 값으로 넘기고, 받은 바이트 수와 전체 바이트 수를 함께 넘깁니다.
///   - completion: 이미지를 보여 주거나 실패했을 때 메인 스레드에서 한 번 부릅니다. `nil`이면 결과를 받지 않습니다.
/// - Returns: 시작한 작업입니다. 메모리 캐시에서 바로 보여 줬거나 요청이 `nil`이면 `nil`을 돌려줍니다.
@MainActor
@discardableResult
public func loadImage(
    with url: URL?,
    options: ImageLoadingOptions? = nil,
    into view: ImageDisplayingView,
    progress: (@MainActor @Sendable (_ response: ImageResponse?, _ completed: Int64, _ total: Int64) -> Void)? = nil,
    completion: (@MainActor @Sendable (_ result: Result<ImageResponse, ImageSession.Error>) -> Void)? = nil
) -> ImageTask? {
    ImageViewController.controller(for: view).load(url.map { ImageRequest(url: $0) }, options: options ?? .shared, progress: progress, completion: completion)
}

/// 요청한 이미지를 불러와 뷰에 보여 줍니다.
///
/// 같은 뷰에 이전 요청이 남아 있으면 먼저 취소합니다. 취소된 요청의 `completion`은 불리지 않으므로, 셀을 재사용할 때 이전 이미지가 늦게 덮어쓰지 않습니다.
///
/// 메모리 캐시에 이미지가 있으면 함수가 돌아오기 전에 이미지를 보여 주고 `completion`을 부릅니다. 이때 전환 효과는 쓰지 않습니다.
/// 캐시에 없으면 ``ImageLoadingOptions/placeholder``를 먼저 보여 줍니다. 실패했을 때 ``ImageLoadingOptions/failureImage``를 지정해 두었으면 그 이미지로 바꿉니다.
///
/// - Parameters:
///   - request: 주소와 필터, 캐시 옵션을 담습니다. `nil`이면 네트워크 요청 없이 ``ImageSession/Error/imageRequestMissing``으로 끝납니다.
///   - options: 플레이스홀더, 실패 이미지, 전환 효과, 사용할 세션을 정합니다. `nil`이면 ``ImageLoadingOptions/shared``를 씁니다.
///   - view: 이미지를 보여 줄 뷰입니다. `UIImageView`와 ``AnimatedImageView``를 넣을 수 있습니다.
///   - completion: 이미지를 보여 주거나 실패했을 때 메인 스레드에서 한 번 부릅니다.
/// - Returns: 시작한 작업입니다. 메모리 캐시에서 바로 보여 줬거나 요청이 `nil`이면 `nil`을 돌려줍니다.
@MainActor
@discardableResult
public func loadImage(
    with request: ImageRequest?,
    options: ImageLoadingOptions? = nil,
    into view: ImageDisplayingView,
    completion: @escaping @MainActor @Sendable (_ result: Result<ImageResponse, ImageSession.Error>) -> Void
) -> ImageTask? {
    ImageViewController.controller(for: view).load(request, options: options ?? .shared, progress: nil, completion: completion)
}

/// 요청한 이미지를 불러와 뷰에 보여 줍니다.
///
/// 같은 뷰에 이전 요청이 남아 있으면 먼저 취소합니다. 취소된 요청의 `completion`은 불리지 않으므로, 셀을 재사용할 때 이전 이미지가 늦게 덮어쓰지 않습니다.
///
/// 메모리 캐시에 이미지가 있으면 함수가 돌아오기 전에 이미지를 보여 주고 `completion`을 부릅니다. 이때 전환 효과는 쓰지 않습니다.
/// 캐시에 없으면 ``ImageLoadingOptions/placeholder``를 먼저 보여 줍니다. 실패했을 때 ``ImageLoadingOptions/failureImage``를 지정해 두었으면 그 이미지로 바꿉니다.
///
/// - Parameters:
///   - request: 주소와 필터, 캐시 옵션을 담습니다. `nil`이면 네트워크 요청 없이 ``ImageSession/Error/imageRequestMissing``으로 끝납니다.
///   - options: 플레이스홀더, 실패 이미지, 전환 효과, 사용할 세션을 정합니다. `nil`이면 ``ImageLoadingOptions/shared``를 씁니다.
///   - view: 이미지를 보여 줄 뷰입니다. `UIImageView`와 ``AnimatedImageView``를 넣을 수 있습니다.
///   - progress: 데이터를 받을 때마다 메인 스레드에서 부릅니다. 미리보기를 만들었으면 첫 번째 값으로 넘기고, 받은 바이트 수와 전체 바이트 수를 함께 넘깁니다.
///   - completion: 이미지를 보여 주거나 실패했을 때 메인 스레드에서 한 번 부릅니다. `nil`이면 결과를 받지 않습니다.
/// - Returns: 시작한 작업입니다. 메모리 캐시에서 바로 보여 줬거나 요청이 `nil`이면 `nil`을 돌려줍니다.
@MainActor
@discardableResult
public func loadImage(
    with request: ImageRequest?,
    options: ImageLoadingOptions? = nil,
    into view: ImageDisplayingView,
    progress: (@MainActor @Sendable (_ response: ImageResponse?, _ completed: Int64, _ total: Int64) -> Void)? = nil,
    completion: (@MainActor @Sendable (_ result: Result<ImageResponse, ImageSession.Error>) -> Void)? = nil
) -> ImageTask? {
    ImageViewController.controller(for: view).load(request, options: options ?? .shared, progress: progress, completion: completion)
}

/// 뷰가 기다리고 있는 요청을 취소합니다.
///
/// 취소한 요청의 `completion`은 불리지 않습니다. 뷰에 보이던 이미지는 그대로 둡니다.
///
/// - Parameter view: 이미지를 불러오던 뷰입니다. 기다리는 요청이 없으면 아무 일도 하지 않습니다.
@MainActor
public func cancelRequest(for view: ImageDisplayingView) {
    ImageViewController.existingController(for: view)?.cancelOutstandingTask()
}
