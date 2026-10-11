import Foundation

extension ImageSession {
    /// 이미지를 불러오지 못한 이유입니다.
    ///
    /// ``code``와 ``diagnosticCode``는 버전이 바뀌어도 같은 값을 유지하므로, 로그를 묶거나 통계를 낼 때 기준으로 쓸 수 있습니다.
    public enum Error: Swift.Error, CustomStringConvertible, Sendable {
        /// ``ImageRequest/Options/returnCacheDataDontLoad``를 켰는데 캐시에 이미지가 없습니다.
        case dataMissingInCache
        /// 데이터를 받지 못했습니다.
        ///
        /// 주소가 비었을 때, 네트워크 오류, 200부터 299 밖의 상태 코드, ``Configuration/failureCooldown``이 막은 요청이 모두 여기에 들어갑니다.
        /// 원인은 `error`에 담기고, ``statusCode``, ``urlError``, ``cooldown``으로 꺼낼 수 있습니다.
        case dataLoadingFailed(error: Swift.Error)
        /// 서버나 클로저가 0바이트를 돌려줬습니다.
        case dataIsEmpty
        /// 받은 데이터를 맡을 디코더가 없습니다.
        ///
        /// ``Configuration/makeImageDecoder``나 델리게이트가 `nil`을 돌려줄 때만 생깁니다. 기본 설정에서는 일어나지 않습니다.
        case decoderNotRegistered(context: ImageDecodingContext)
        /// 디코더가 이미지를 만들지 못했습니다.
        ///
        /// 데이터가 이미지가 아니거나 손상됐을 때 생깁니다. 픽셀 수가 ``Configuration/decodingLimits``를 넘으면 `error`가 ``ImageDecodingLimits/Error``입니다.
        case decodingFailed(decoder: any ImageDecoding, context: ImageDecodingContext, error: Swift.Error)
        /// 필터가 결과 이미지를 만들지 못했습니다. 실패한 필터는 `filter`에 담깁니다.
        case processingFailed(filter: any ImageFilter, context: ImageFilterContext, error: Swift.Error)
        /// UIKit과 SwiftUI 뷰에 요청이나 주소 대신 `nil`을 넘겼습니다.
        case imageRequestMissing
        /// ``ImageSession/invalidate()``를 부른 세션에 요청했습니다.
        case sessionInvalidated
        /// 받은 데이터가 ``Configuration/maximumResponseDataSize``를 넘어 다운로드를 멈췄습니다.
        ///
        /// 서버가 `Content-Length` 헤더로 크기를 미리 알려 주면 받기 전에 멈춥니다.
        case dataDownloadExceededMaximumSize
        /// 결과가 나오기 전에 작업을 취소했습니다.
        case cancelled

        /// ``dataLoadingFailed(error:)``의 원인 오류입니다. 다른 case면 `nil`입니다.
        public var dataLoadingError: Swift.Error? {
            if case .dataLoadingFailed(let error) = self {
                return error
            }
            return nil
        }

        public var description: String {
            switch self {
            case .dataMissingInCache:
                "Failed to load data from cache and download is disabled."
            case .dataLoadingFailed:
                "Failed to load image data (\(diagnosticCode))."
            case .dataIsEmpty:
                "Data loader returned empty data."
            case .decoderNotRegistered:
                "No decoders registered for the downloaded data."
            case .decodingFailed(let decoder, _, let error):
                "Failed to decode image data using decoder \(type(of: decoder)). Underlying error: \(error)."
            case .processingFailed(let filter, _, let error):
                "Failed to process the image using filter \(filter.identifier). Underlying error: \(error)."
            case .imageRequestMissing:
                "Load image method was called with no image request or no URL."
            case .sessionInvalidated:
                "Image session is invalidated and no requests can be made."
            case .dataDownloadExceededMaximumSize:
                "The downloaded data exceeded the maximum allowed size."
            case .cancelled:
                "The image task was cancelled."
            }
        }

        enum Boundary: Sendable {
            case dataLoading
            case willLoadData
            case unexpected
        }

        static func wrapping(
            _ error: Swift.Error,
            at boundary: Boundary,
            onUnexpected: (String) -> Void = { assertionFailure($0) }
        ) -> ImageSession.Error {
            if let error = error as? ImageSession.Error {
                return error
            }
            if error is CancellationError {
                return .cancelled
            }
            switch boundary {
            case .dataLoading, .willLoadData:
                return .dataLoadingFailed(error: error)
            case .unexpected:
                onUnexpected("Unexpected error type: \(String(reflecting: type(of: error)))")
                return .dataLoadingFailed(error: error)
            }
        }

        static func isExpectedLoaderError(_ error: Swift.Error) -> Bool {
            error is URLError
                || error is DataLoader.Error
                || error is CocoaError
                || error is ImageSession.FailureCooldownError
                || error is ImageSession.Error
                || error is CancellationError
        }
    }
}

extension ImageSession.Error {
    /// ``cancelled``인지 알려 줍니다. 화면에 오류를 띄우기 전에 취소된 요청을 걸러 낼 때 씁니다.
    public var isCancelled: Bool {
        if case .cancelled = self {
            return true
        }
        return false
    }

    /// 서버가 보낸 HTTP 상태 코드입니다.
    ///
    /// 상태 코드가 200부터 299 밖이라 실패했을 때만 값이 있습니다. ``cooldown``으로 막힌 요청은 마지막으로 실패했을 때의 상태 코드를 돌려줍니다.
    public var statusCode: Int? {
        if let cooldown {
            return cooldown.lastError.statusCode
        }
        if case .statusCodeUnacceptable(let code) = dataLoadingError as? DataLoader.Error {
            return code
        }
        return nil
    }

    /// 네트워크 오류입니다. ``cooldown``으로 막힌 요청은 마지막으로 실패했을 때의 오류를 돌려줍니다.
    public var urlError: URLError? {
        if let cooldown {
            return cooldown.lastError.urlError
        }
        return dataLoadingError as? URLError
    }

    /// ``Configuration/failureCooldown``이 요청을 막았을 때의 정보입니다. 막히지 않았으면 `nil`입니다.
    public var cooldown: ImageSession.FailureCooldownError? {
        dataLoadingError as? ImageSession.FailureCooldownError
    }

    /// 잠시 뒤 다시 요청하면 성공할 수 있는지 알려 줍니다.
    ///
    /// 5xx, 408, 429 상태 코드와 시간 초과, 연결 끊김 같은 일시적인 네트워크 오류면 `true`입니다.
    /// 404 같은 상태 코드, 디코딩 실패, 취소는 `false`입니다.
    public var isRetryable: Bool {
        failureClassification.isRetryable
    }

    struct FailureClassification: Equatable, Sendable {
        let isRetryable: Bool
        let isCooldownEligible: Bool

        static let transient = FailureClassification(isRetryable: true, isCooldownEligible: false)
        static let persistent = FailureClassification(isRetryable: false, isCooldownEligible: true)
        static let unrecorded = FailureClassification(isRetryable: false, isCooldownEligible: false)
    }

    var failureClassification: FailureClassification {
        switch self {
        case .dataLoadingFailed(let underlying):
            if let cooldown = underlying as? ImageSession.FailureCooldownError {
                return FailureClassification(isRetryable: cooldown.lastError.isRetryable, isCooldownEligible: false)
            }
            if case .statusCodeUnacceptable(let code) = underlying as? DataLoader.Error {
                return Self.isTransientStatusCode(code) ? .transient : .persistent
            }
            if let urlError = underlying as? URLError {
                if urlError.code == .cancelled {
                    return .unrecorded
                }
                return Self.transientURLErrorCodes.contains(urlError.code) ? .transient : .persistent
            }
            return .persistent
        case .dataIsEmpty, .decoderNotRegistered, .dataDownloadExceededMaximumSize:
            return .persistent
        case .decodingFailed(_, _, let error):
            return error is ImageDecodingLimits.Error ? .unrecorded : .persistent
        case .dataMissingInCache, .processingFailed, .imageRequestMissing, .sessionInvalidated, .cancelled:
            return .unrecorded
        }
    }

    static func isTransientStatusCode(_ code: Int) -> Bool {
        code >= 500 || code == 408 || code == 429
    }

    static let transientURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .networkConnectionLost,
        .notConnectedToInternet,
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
        .internationalRoamingOff,
        .dataNotAllowed,
        .callIsActive,
        .secureConnectionFailed,
    ]

    /// 로그와 통계에 쓰는 짧은 오류 코드입니다.
    ///
    /// case 이름을 그대로 쓰고, ``dataLoadingFailed(error:)``는 원인을 덧붙입니다.
    /// 예를 들어 404 응답은 `dataLoadingFailed.http.404`, 시간 초과는 `dataLoadingFailed.urlError.-1001`입니다.
    /// 주소와 헤더는 넣지 않으므로 그대로 로그에 남겨도 됩니다.
    public var diagnosticCode: String {
        switch self {
        case .dataMissingInCache: "dataMissingInCache"
        case .dataLoadingFailed(let underlying): Self.dataLoadingDiagnosticCode(underlying)
        case .dataIsEmpty: "dataIsEmpty"
        case .decoderNotRegistered: "decoderNotRegistered"
        case .decodingFailed: "decodingFailed"
        case .processingFailed: "processingFailed"
        case .imageRequestMissing: "imageRequestMissing"
        case .sessionInvalidated: "sessionInvalidated"
        case .dataDownloadExceededMaximumSize: "dataDownloadExceededMaximumSize"
        case .cancelled: "cancelled"
        }
    }

    private static func dataLoadingDiagnosticCode(_ underlying: Swift.Error) -> String {
        let prefix = "dataLoadingFailed"
        if let cooldown = underlying as? ImageSession.FailureCooldownError {
            let last = cooldown.lastError.diagnosticCode
            let detail = last.hasPrefix(prefix + ".") ? String(last.dropFirst(prefix.count + 1)) : last
            return prefix + ".cooldown." + detail
        }
        if case .statusCodeUnacceptable(let code) = underlying as? DataLoader.Error {
            return prefix + ".http.\(code)"
        }
        if let urlError = underlying as? URLError {
            return prefix + ".urlError.\(urlError.code.rawValue)"
        }
        if let cocoaError = underlying as? CocoaError {
            return prefix + ".cocoa.\(cocoaError.code.rawValue)"
        }
        return prefix + ".other"
    }
}

/// ``ImageSession/Error``를 `NSError`로 바꿨을 때의 오류 코드입니다.
///
/// 값은 1부터 10까지 고정이고, case를 추가해도 기존 값은 바꾸지 않습니다. Crashlytics처럼 `NSError` 코드로 오류를 묶는 도구에서 씁니다.
@objc(ImageLoaderSessionErrorCode)
public enum ImageSessionErrorCode: Int, Sendable {
    /// ``ImageSession/Error/dataMissingInCache``입니다.
    case dataMissingInCache = 1
    /// ``ImageSession/Error/dataLoadingFailed(error:)``입니다.
    case dataLoadingFailed = 2
    /// ``ImageSession/Error/dataIsEmpty``입니다.
    case dataIsEmpty = 3
    /// ``ImageSession/Error/decoderNotRegistered(context:)``입니다.
    case decoderNotRegistered = 4
    /// ``ImageSession/Error/decodingFailed(decoder:context:error:)``입니다.
    case decodingFailed = 5
    /// ``ImageSession/Error/processingFailed(filter:context:error:)``입니다.
    case processingFailed = 6
    /// ``ImageSession/Error/imageRequestMissing``입니다.
    case imageRequestMissing = 7
    /// ``ImageSession/Error/sessionInvalidated``입니다.
    case sessionInvalidated = 8
    /// ``ImageSession/Error/dataDownloadExceededMaximumSize``입니다.
    case dataDownloadExceededMaximumSize = 9
    /// ``ImageSession/Error/cancelled``입니다.
    case cancelled = 10
}

extension ImageSession.Error: CustomNSError {
    /// `NSError`로 바꿨을 때의 도메인입니다. 값은 `ImageLoader.ImageSession`입니다.
    public static var errorDomain: String {
        "ImageLoader.ImageSession"
    }

    /// `NSError`로 바꿨을 때의 오류 코드입니다.
    public var code: ImageSessionErrorCode {
        switch self {
        case .dataMissingInCache: .dataMissingInCache
        case .dataLoadingFailed: .dataLoadingFailed
        case .dataIsEmpty: .dataIsEmpty
        case .decoderNotRegistered: .decoderNotRegistered
        case .decodingFailed: .decodingFailed
        case .processingFailed: .processingFailed
        case .imageRequestMissing: .imageRequestMissing
        case .sessionInvalidated: .sessionInvalidated
        case .dataDownloadExceededMaximumSize: .dataDownloadExceededMaximumSize
        case .cancelled: .cancelled
        }
    }

    /// ``code``의 정숫값입니다.
    public var errorCode: Int {
        code.rawValue
    }

    /// `NSError`로 바꿨을 때의 `userInfo`입니다.
    ///
    /// `NSLocalizedDescriptionKey`에 ``diagnosticCode``를 넣고, 값이 있으면 `statusCode`와 `urlErrorCode`를 함께 넣습니다.
    /// 주소와 헤더는 넣지 않습니다.
    public var errorUserInfo: [String: Any] {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: diagnosticCode]
        if let statusCode {
            userInfo["statusCode"] = statusCode
        }
        if let urlError {
            userInfo["urlErrorCode"] = urlError.code.rawValue
        }
        return userInfo
    }
}
