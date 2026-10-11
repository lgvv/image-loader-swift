import Foundation
import UIKit

extension ImageSession {
    /// 요청마다 캐시, 디코더, 네트워크 요청을 바꾸고 세션에서 일어난 일을 전달받습니다.
    ///
    /// 필요한 메서드만 구현하면 됩니다. 구현하지 않은 메서드는 ``Configuration`` 값을 그대로 씁니다.
    /// ``imageTaskCreated(_:session:)``를 뺀 메서드는 메인 스레드가 아닌 곳에서 부르므로, UI를 바꾸려면 메인 스레드로 옮겨 주세요.
    public protocol Delegate: AnyObject, Sendable {
        /// 데이터를 디코딩할 디코더를 고릅니다. `nil`을 돌려주면 요청은 ``Error/decoderNotRegistered(context:)``로 끝납니다.
        ///
        /// 디스크 캐시에서 읽은 데이터에 `nil`을 돌려주면 그 항목을 지우고 네트워크에서 다시 받습니다.
        func imageDecoder(for context: ImageDecodingContext, session: ImageSession) -> (any ImageDecoding)?
        /// 필터를 적용한 이미지를 디스크 캐시에 저장할 때 쓸 인코더를 고릅니다.
        func imageEncoder(for context: ImageEncodingContext, session: ImageSession) -> any ImageEncoding
        /// 다운로드 도중에 어떤 미리보기를 만들지 정합니다. ``Configuration/isProgressiveDecodingEnabled``를 켰을 때만 부릅니다.
        ///
        /// ``PreviewPolicy/disabled``를 돌려주면 데이터가 두 배로 늘 때마다 다시 묻고, 요청 하나에 최대 6번까지 묻습니다.
        func previewPolicy(for context: ImageDecodingContext, session: ImageSession) -> ImageSession.PreviewPolicy
        /// 요청을 내려받을 객체를 고릅니다. 특정 호스트만 다른 `URLSession` 설정을 써야 할 때 씁니다.
        func dataLoader(for request: ImageRequest, session: ImageSession) -> any DataLoading
        /// 네트워크 요청을 보내기 직전에 `URLRequest`를 바꿉니다. 인증 헤더를 붙일 때 씁니다.
        ///
        /// 캐시에서 이미지를 찾으면 부르지 않습니다. 오류를 일으키면 요청은 ``Error/dataLoadingFailed(error:)``로 끝납니다.
        func willLoadData(for request: ImageRequest, urlRequest: URLRequest, session: ImageSession) async throws -> URLRequest
        /// 요청이 쓸 메모리 캐시를 고릅니다. `nil`을 돌려주면 그 요청은 메모리 캐시를 쓰지 않습니다.
        func memoryCache(for request: ImageRequest, session: ImageSession) -> (any MemoryCaching)?
        /// 요청이 쓸 디스크 캐시를 고릅니다. `nil`을 돌려주면 그 요청은 디스크 캐시를 쓰지 않습니다.
        func diskCache(for request: ImageRequest, session: ImageSession) -> (any DiskCaching)?
        /// 메모리 캐시와 디스크 캐시에서 쓸 키를 직접 정합니다.
        ///
        /// `nil`을 돌려주면 주소, 필터, 썸네일 설정으로 키를 만듭니다. 값을 돌려주면 필터와 썸네일 설정은 키에 들어가지 않으므로, 필요하면 직접 넣어 주세요.
        func cacheKey(for request: ImageRequest, session: ImageSession) -> String?
        /// 디스크 캐시에 저장하기 직전에 데이터를 바꾸거나 저장을 막습니다.
        ///
        /// `completion`에 바꾼 데이터를 넘기면 그 데이터를 저장하고, `nil`을 넘기면 저장하지 않습니다. 원본 데이터를 저장할 때는 `image`가 `nil`입니다.
        func willCache(data: Data, image: ImageContent?, for request: ImageRequest, session: ImageSession, completion: @escaping @Sendable (Data?) -> Void)
        /// 디코딩한 이미지를 미리 그려 둘지 정합니다. 기본 구현은 ``Configuration/isDecompressionEnabled``를 돌려줍니다.
        func shouldDecompress(response: ImageResponse, for request: ImageRequest, session: ImageSession) -> Bool
        /// 디코딩한 이미지를 미리 그립니다. 직접 구현하면 미리 그리는 방법을 바꿀 수 있습니다.
        func decompress(response: ImageResponse, request: ImageRequest, session: ImageSession) -> ImageResponse
        /// 작업을 만들었을 때 부릅니다. 작업을 만든 스레드에서 작업이 시작되기 전에 부릅니다.
        func imageTaskCreated(_ task: ImageTask, session: ImageSession)
        /// 작업에서 ``ImageTask/Event``가 생길 때마다 부릅니다. 모든 작업의 상태를 한곳에서 기록할 때 씁니다.
        func imageTask(_ task: ImageTask, didReceiveEvent event: ImageTask.Event, session: ImageSession)
        /// 캐시 오류나 메모리 압박 대응처럼 요청 결과에 드러나지 않는 일을 전달합니다. 로그나 통계에 남길 때 씁니다.
        func session(_ session: ImageSession, didRecord diagnostic: Diagnostic)
    }

    /// 요청 결과에 드러나지 않지만 기록해 둘 만한 일입니다. ``Delegate/session(_:didRecord:)``로 전달합니다.
    public enum Diagnostic: Sendable {
        /// 디스크 캐시를 읽거나 쓰지 못했습니다. 요청은 디스크 캐시 없이 이어갑니다.
        case diskCacheFailure(operation: DiskCacheOperation, error: Swift.Error)
        /// 디스크 캐시에서 읽은 데이터를 디코딩하지 못해 그 항목을 지웠습니다. 이미지는 네트워크에서 다시 받습니다.
        case corruptedDiskCacheEntryRemoved
        /// ``Configuration/failureCooldown``이 요청을 막았습니다.
        case failureCooldownApplied(ImageSession.FailureCooldownError)
        /// 작업 하나가 끝났습니다. ``Configuration/isMetricsCollectionEnabled``를 켰을 때만 전달합니다.
        case taskMetrics(ImageTaskMetrics)
        /// ``DataLoading``이 예상하지 못한 종류의 오류를 돌려줘서 ``Error/dataLoadingFailed(error:)``로 감쌌습니다. 값은 오류 타입 이름이고, 타입마다 한 번만 전달합니다.
        case unexpectedErrorWrapped(String)
        /// 메모리가 부족해 메모리 캐시를 모두 비웠습니다. 비운 항목 수와 바이트 수를 함께 전달합니다.
        case memoryPressurePurge(reason: MemoryPressureReason, entryCount: Int, cost: Int)
        /// 메모리 캐시를 비운 뒤 10초 동안, 비웠던 이미지 중 몇 개를 다시 불러왔는지 알려 줍니다.
        ///
        /// `redecodedCount`는 다시 디코딩한 이미지 수이고, `diskReadCount`는 그중 디스크 캐시에서 읽은 수입니다. 값이 크면 비운 이미지를 곧바로 다시 쓰고 있다는 뜻입니다.
        case memoryPressureRecovery(reason: MemoryPressureReason, redecodedCount: Int, diskReadCount: Int)
        /// 메모리 경고를 받아 메모리 캐시를 ``MemoryCacheLifecyclePolicy/pressureWarningTrimRatio``만큼 줄였습니다. 지운 항목 수와 바이트 수를 함께 전달합니다.
        case memoryPressureTrim(entryCount: Int, cost: Int)
        /// 앱이 백그라운드로 가서 메모리 캐시를 ``MemoryCacheLifecyclePolicy/backgroundTrimRatio``만큼 줄였습니다. 지운 항목 수와 바이트 수를 함께 전달합니다.
        case backgroundTrim(entryCount: Int, cost: Int)
    }

    /// 메모리 캐시를 줄이거나 비운 이유입니다.
    public enum MemoryPressureReason: Sendable, Hashable {
        /// 시스템이 메모리 압박 경고를 보냈습니다.
        case warning
        /// 시스템이 메모리 압박이 심각하다고 알렸습니다.
        case critical
        /// `UIApplication.didReceiveMemoryWarningNotification`을 받았습니다.
        case applicationMemoryWarning
    }

    /// 디스크 캐시에서 실패한 작업의 종류입니다.
    @frozen public enum DiskCacheOperation: Sendable {
        /// 파일을 읽지 못했습니다.
        case read
        /// 파일을 쓰지 못했거나, 데이터가 ``DiskCache/maximumEntrySize``를 넘어 저장하지 않았습니다.
        case write
        /// 파일을 지우지 못했습니다.
        case remove
        /// 오래된 파일을 정리하다가 지우지 못했습니다.
        case sweep
        /// 캐시 폴더를 훑어 목록을 만들지 못했습니다.
        case initialize
    }
}

extension ImageSession.Delegate {
    /// 기본 구현은 ``ImageSession/Configuration/makeImageDecoder``를 부릅니다.
    public func imageDecoder(for context: ImageDecodingContext, session: ImageSession) -> (any ImageDecoding)? {
        session.configuration.makeImageDecoder(context)
    }

    /// 기본 구현은 ``ImageSession/Configuration/makeImageEncoder``를 부릅니다.
    public func imageEncoder(for context: ImageEncodingContext, session: ImageSession) -> any ImageEncoding {
        session.configuration.makeImageEncoder(context)
    }

    /// 기본 구현은 ``ImageSession/PreviewPolicy/default(for:)``를 돌려줍니다.
    public func previewPolicy(for context: ImageDecodingContext, session: ImageSession) -> ImageSession.PreviewPolicy {
        ImageSession.PreviewPolicy.default(for: context.data)
    }

    /// 기본 구현은 ``ImageSession/Configuration/dataLoader``를 돌려줍니다.
    public func dataLoader(for request: ImageRequest, session: ImageSession) -> any DataLoading {
        session.configuration.dataLoader
    }

    /// 기본 구현은 `urlRequest`를 그대로 돌려줍니다.
    public func willLoadData(for request: ImageRequest, urlRequest: URLRequest, session: ImageSession) async throws -> URLRequest {
        urlRequest
    }

    /// 기본 구현은 ``ImageSession/Configuration/memoryCache``를 돌려줍니다.
    public func memoryCache(for request: ImageRequest, session: ImageSession) -> (any MemoryCaching)? {
        session.configuration.memoryCache
    }

    /// 기본 구현은 ``ImageSession/Configuration/diskCache``를 돌려줍니다.
    public func diskCache(for request: ImageRequest, session: ImageSession) -> (any DiskCaching)? {
        session.configuration.diskCache
    }

    /// 기본 구현은 `nil`을 돌려줘서 주소, 필터, 썸네일 설정으로 키를 만들게 합니다.
    public func cacheKey(for request: ImageRequest, session: ImageSession) -> String? {
        nil
    }

    /// 기본 구현은 `data`를 그대로 저장합니다.
    public func willCache(data: Data, image: ImageContent?, for request: ImageRequest, session: ImageSession, completion: @escaping @Sendable (Data?) -> Void) {
        completion(data)
    }

    /// 기본 구현은 ``ImageSession/Configuration/isDecompressionEnabled``를 돌려줍니다.
    public func shouldDecompress(response: ImageResponse, for request: ImageRequest, session: ImageSession) -> Bool {
        session.configuration.isDecompressionEnabled
    }

    /// 기본 구현은 비트맵 컨텍스트에 그리고, ``ImageSession/Configuration/isUsingPrepareForDisplay``를 켰으면 `UIImage.preparingForDisplay()`를 씁니다.
    public func decompress(response: ImageResponse, request: ImageRequest, session: ImageSession) -> ImageResponse {
        response.map { content in
            content.map { ImageDecompression.decompress(image: $0, isUsingPrepareForDisplay: session.configuration.isUsingPrepareForDisplay) }
        }
    }

    /// 기본 구현은 아무 일도 하지 않습니다.
    public func imageTaskCreated(_ task: ImageTask, session: ImageSession) {}

    /// 기본 구현은 아무 일도 하지 않습니다.
    public func imageTask(_ task: ImageTask, didReceiveEvent event: ImageTask.Event, session: ImageSession) {}

    /// 기본 구현은 아무 일도 하지 않습니다.
    public func session(_ session: ImageSession, didRecord diagnostic: ImageSession.Diagnostic) {}
}

final class ImageSessionDefaultDelegate: ImageSession.Delegate {}
