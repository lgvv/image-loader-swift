import Foundation

/// `URLSession`으로 이미지 데이터를 내려받는 기본 로더입니다.
///
/// 상태 코드가 200부터 299 사이가 아니면 실패로 봅니다. 쿠키는 보내지도 저장하지도 않습니다.
/// 리디렉션으로 다른 호스트나 포트로 가거나 HTTPS에서 HTTP로 바뀌면, 요청에 직접 넣은 헤더와 `httpAdditionalHeaders`를 빼고 보냅니다.
/// `Authorization` 같은 인증 헤더가 다른 서버로 새지 않게 하려는 것입니다.
public final class DataLoader: DataLoading, Sendable {
    /// 데이터를 내려받는 `URLSession`입니다.
    public let session: URLSession

    /// `URLSession` 이벤트를 넘겨받는 객체입니다. 인증 요청, 리디렉션, 전송 지표 같은 이벤트를 여기로 넘깁니다.
    public let delegate: (any URLSessionDelegate)?

    /// 데이터를 작은 조각으로 자주 받을지 정합니다. 기본값은 `false`입니다.
    ///
    /// 프로그레시브 미리보기를 쓸 때 켜면 미리보기가 더 자주 갱신됩니다. 새로 시작하는 다운로드부터 적용됩니다.
    public var prefersIncrementalDelivery: Bool {
        get { incrementalDelivery.value }
        set { incrementalDelivery.withLock { $0 = newValue } }
    }

    private let sessionDelegate: DataLoaderSessionDelegate
    private let incrementalDelivery = LockIsolated(false)
    private let additionalHeaders: [(name: String, value: String)]

    /// ``DataLoader``가 만드는 오류입니다.
    public enum Error: Swift.Error, CustomStringConvertible, Sendable {
        /// 상태 코드가 받아들일 수 없는 값입니다. 값은 서버가 보낸 상태 코드입니다.
        case statusCodeUnacceptable(Int)

        public var description: String {
            switch self {
            case .statusCodeUnacceptable(let code):
                "Response status code was unacceptable: \(code)"
            }
        }
    }

    /// 로더를 만듭니다.
    ///
    /// - Parameters:
    ///   - configuration: `URLSession` 설정입니다. 기본값은 ``defaultConfiguration``입니다.
    ///   - validate: 응답을 받아들일지 정합니다. 오류를 돌려주면 다운로드를 멈추고 그 오류로 끝납니다. 기본값은 ``validate``입니다.
    ///   - delegate: `URLSession` 이벤트를 넘겨받을 객체입니다.
    public init(
        configuration: URLSessionConfiguration = DataLoader.defaultConfiguration,
        validate: @escaping @Sendable (URLResponse) -> Swift.Error? = DataLoader.validate,
        delegate: (any URLSessionDelegate)? = nil
    ) {
        let sessionDelegate = DataLoaderSessionDelegate(validate: validate, delegate: delegate)
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated
        delegateQueue.name = "ImageLoader.DataLoader"
        let (configuration, additionalHeaders) = Self.movingAdditionalHeaders(out: configuration)
        self.additionalHeaders = additionalHeaders
        session = URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: delegateQueue)
        session.sessionDescription = "ImageLoader URLSession"
        self.sessionDelegate = sessionDelegate
        self.delegate = delegate
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// 기본 `URLSession` 설정입니다. ``sharedUrlCache``를 쓰고 쿠키를 끕니다.
    public static var defaultConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = DataLoader.sharedUrlCache
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        return configuration
    }

    /// 기본 설정이 함께 쓰는 `URLCache`입니다. 메모리는 쓰지 않고 디스크에 150MB까지 저장합니다.
    ///
    /// 이미지가 아닌 응답은 저장하지 않습니다.
    public static let sharedUrlCache: URLCache = {
        let directory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ImageLoader.URLCache", isDirectory: true)
        return URLCache(memoryCapacity: 0, diskCapacity: 150 * 1024 * 1024, directory: directory)
    }()

    /// 기본 응답 검사입니다. HTTP 응답의 상태 코드가 200부터 299 밖이면 ``Error/statusCodeUnacceptable(_:)``을 돌려줍니다.
    public static let validate: @Sendable (URLResponse) -> Swift.Error? = { response in
        guard let response = response as? HTTPURLResponse else {
            return nil
        }
        guard (200..<300).contains(response.statusCode) else {
            return DataLoader.Error.statusCodeUnacceptable(response.statusCode)
        }
        return nil
    }

    /// 요청을 보내고 받은 데이터를 조각마다 넘깁니다.
    public func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Swift.Error?) -> Void
    ) -> any Cancellable {
        let task = session.dataTask(with: applyingAdditionalHeaders(to: request))
        task.prefersIncrementalDelivery = incrementalDelivery.value
        sessionDelegate.register(task, didReceiveData: didReceiveData, completion: completion)
        task.resume()
        return AnonymousCancellable { [weak task] in
            task?.cancel()
        }
    }

    var activeTaskCount: Int {
        sessionDelegate.activeTaskCount
    }

    private func applyingAdditionalHeaders(to request: URLRequest) -> URLRequest {
        guard !additionalHeaders.isEmpty else {
            return request
        }
        var request = request
        for header in additionalHeaders where request.value(forHTTPHeaderField: header.name) == nil {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        return request
    }

    private static func movingAdditionalHeaders(
        out configuration: URLSessionConfiguration
    ) -> (URLSessionConfiguration, [(name: String, value: String)]) {
        guard let headers = configuration.httpAdditionalHeaders, !headers.isEmpty,
            let copy = configuration.copy() as? URLSessionConfiguration
        else {
            return (configuration, [])
        }
        var moved: [(name: String, value: String)] = []
        var remaining: [AnyHashable: Any] = [:]
        for (key, value) in headers {
            if let name = key.base as? String, let value = value as? String {
                moved.append((name, value))
            } else {
                remaining[key] = value
            }
        }
        copy.httpAdditionalHeaders = remaining.isEmpty ? nil : remaining
        return (copy, moved.sorted { $0.name.lowercased() < $1.name.lowercased() })
    }
}
