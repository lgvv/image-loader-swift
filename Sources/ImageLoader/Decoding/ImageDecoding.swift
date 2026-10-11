import Foundation
import UIKit

/// 데이터를 이미지로 바꾸는 디코더가 따르는 프로토콜입니다.
///
/// 기본으로 쓰는 디코더는 ``ImageDecoders/Default``와 ``ImageDecoders/Animated``입니다. 다른 형식을 지원하려면 이 프로토콜을 구현해
/// ``ImageDecoderRegistry/register(_:)``로 등록해 주세요.
public protocol ImageDecoding: Sendable {
    /// 디코딩을 디코딩 큐에서 할지 정합니다.
    ///
    /// `false`를 돌려주면 세션의 내부 큐에서 바로 디코딩하므로, 그동안 다른 요청이 기다립니다.
    /// 데이터를 그대로 담기만 하는 것처럼 디코딩이 거의 걸리지 않을 때만 `false`를 돌려주세요.
    var isAsynchronous: Bool { get }

    /// 다운로드를 마친 데이터를 디코딩합니다. 오류를 일으키면 요청은 ``ImageSession/Error/decodingFailed(decoder:context:error:)``로 끝납니다.
    func decode(_ data: Data) throws -> ImageContent

    /// 다운로드 도중의 데이터로 미리보기를 만듭니다. 만들 수 없으면 `nil`을 돌려줍니다.
    ///
    /// ``ImageSession/Configuration/isProgressiveDecodingEnabled``를 켰을 때만 부릅니다. 돌려준 값의 ``ImageContent/isPreview``는 `true`여야 합니다.
    func decodePartiallyDownloadedData(_ data: Data) -> ImageContent?
}

extension ImageDecoding {
    /// 기본 구현은 `true`를 돌려줍니다.
    public var isAsynchronous: Bool {
        true
    }

    /// 기본 구현은 `nil`을 돌려줘서 미리보기를 만들지 않습니다.
    public func decodePartiallyDownloadedData(_ data: Data) -> ImageContent? {
        nil
    }

    func decode(_ context: ImageDecodingContext) throws -> ImageResponse {
        let content = try autoreleasepool { () throws -> ImageContent in
            if context.isCompleted {
                return try decode(context.data)
            }
            guard let preview = decodePartiallyDownloadedData(context.data) else {
                throw ImageDecodingError.unknown
            }
            return preview
        }
        if context.request.thumbnail == nil, !content.isPreview, content.userInfo[.animatedImageKey] == nil {
            ImageDecompression.setDecompressionNeeded(true, for: content.image)
        }
        return ImageResponse(content: content, request: context.request, urlResponse: context.urlResponse, cacheType: context.cacheType)
    }
}

/// 디코더가 이유를 밝히지 않고 실패했을 때의 오류입니다.
public enum ImageDecodingError: Error, CustomStringConvertible, Sendable {
    /// 데이터가 이미지가 아니거나, 지원하지 않는 형식이거나, 손상됐습니다.
    case unknown

    public var description: String {
        "Unknown"
    }
}

/// 디코더를 고르고 디코딩할 때 쓰는 정보입니다.
public struct ImageDecodingContext: Sendable {
    /// 디코딩할 이미지를 요청한 요청입니다. ``ImageRequest/scale``과 ``ImageRequest/thumbnail``을 여기서 읽습니다.
    public var request: ImageRequest
    /// 디코딩할 데이터입니다. ``isCompleted``가 `false`면 지금까지 받은 일부입니다.
    public var data: Data
    /// 다운로드를 마친 데이터면 `true`입니다.
    public var isCompleted: Bool
    /// 데이터와 함께 받은 서버 응답입니다. 캐시에서 읽었으면 `nil`입니다.
    public var urlResponse: URLResponse?
    /// 데이터를 읽은 캐시입니다. 네트워크에서 받았으면 `nil`입니다.
    public var cacheType: ImageResponse.CacheType?
    /// 다운로드 도중에 만들 미리보기의 종류입니다.
    public var previewPolicy: ImageSession.PreviewPolicy = .incremental
    /// 디코딩할 수 있는 최대 픽셀 수입니다. 세션이 ``ImageSession/Configuration/decodingLimits``로 채웁니다.
    public var decodingLimits: ImageDecodingLimits = .default

    /// 디코딩 정보를 만듭니다. 테스트나 디코더를 직접 부를 때 씁니다.
    public init(request: ImageRequest, data: Data, isCompleted: Bool = true, urlResponse: URLResponse? = nil, cacheType: ImageResponse.CacheType? = nil) {
        self.request = request
        self.data = data
        self.isCompleted = isCompleted
        self.urlResponse = urlResponse
        self.cacheType = cacheType
    }
}

/// 데이터에 맞는 디코더를 고르는 목록입니다.
///
/// 나중에 등록한 것부터 차례로 물어보고, 처음으로 디코더를 돌려준 것을 씁니다. 기본으로 ``ImageDecoders/Default``와 ``ImageDecoders/Animated``가 들어 있습니다.
///
/// ```swift
/// // SVGDecoder는 직접 구현한 디코더입니다.
/// ImageDecoderRegistry.shared.register { context in
///     context.data.starts(with: Data("<svg".utf8)) ? SVGDecoder() : nil
/// }
/// ```
public final class ImageDecoderRegistry: Sendable {
    /// ``ImageSession/Configuration/makeImageDecoder``가 기본으로 쓰는 목록입니다.
    public static let shared = ImageDecoderRegistry()

    private struct Registration: Sendable {
        let id: Int
        let match: @Sendable (ImageDecodingContext) -> (any ImageDecoding)?
    }

    private struct State {
        var registrations: [Registration] = []
        var nextID = 0
    }

    private let state = LockIsolated(State())

    /// 등록을 되돌릴 때 쓰는 값입니다. ``ImageDecoderRegistry/register(_:)``가 돌려줍니다.
    public struct RegistrationToken: Hashable, Sendable {
        fileprivate let id: Int
    }

    /// 기본 디코더 두 개를 등록한 목록을 만듭니다.
    public init() {
        register { ImageDecoders.Default(context: $0) }
        register { ImageDecoders.Animated(context: $0) }
    }

    /// 디코더를 고르는 클로저를 등록합니다. 먼저 등록한 것보다 먼저 물어봅니다.
    ///
    /// - Parameter match: 데이터를 맡을 수 있으면 디코더를, 아니면 `nil`을 돌려줍니다. 요청마다 부르므로 데이터 앞부분만 보고 빠르게 판단해 주세요.
    /// - Returns: ``unregister(_:)``에 넘길 값입니다.
    @discardableResult
    public func register(_ match: @escaping @Sendable (ImageDecodingContext) -> (any ImageDecoding)?) -> RegistrationToken {
        state.withLock { state in
            let id = state.nextID
            state.nextID += 1
            state.registrations.append(Registration(id: id, match: match))
            return RegistrationToken(id: id)
        }
    }

    /// 등록한 클로저를 뺍니다.
    public func unregister(_ token: RegistrationToken) {
        state.withLock { state in
            state.registrations.removeAll { $0.id == token.id }
        }
    }

    /// 기본 디코더를 포함해 등록한 클로저를 모두 뺍니다. 이후 요청은 직접 등록하기 전까지 ``ImageSession/Error/decoderNotRegistered(context:)``로 끝납니다.
    public func clear() {
        state.withLock { $0.registrations.removeAll() }
    }

    /// 데이터를 맡을 디코더를 돌려줍니다. 맡을 디코더가 없으면 `nil`입니다.
    public func decoder(for context: ImageDecodingContext) -> (any ImageDecoding)? {
        let registrations = state.withLock { $0.registrations }
        for registration in registrations.reversed() {
            if let decoder = registration.match(context) {
                return decoder
            }
        }
        return nil
    }
}
