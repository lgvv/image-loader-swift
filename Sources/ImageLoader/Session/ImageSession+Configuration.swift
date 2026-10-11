import Foundation

extension ImageSession {
    /// 세션의 캐시, 디코더, 동시 작업 수를 정합니다.
    ///
    /// 세션을 만든 뒤에는 바꿀 수 없습니다. 값을 바꾼 설정으로 세션을 새로 만들어 주세요.
    ///
    /// ```swift
    /// var configuration = ImageSession.Configuration.withDiskCache
    /// configuration.isProgressiveDecodingEnabled = true
    /// ImageSession.shared = ImageSession(configuration: configuration)
    /// ```
    public struct Configuration: Sendable {
        /// 데이터를 내려받는 객체입니다. 기본값은 `URLCache`를 쓰는 ``DataLoader``입니다.
        public var dataLoader: any DataLoading

        /// 디코딩 전 데이터를 보관하는 디스크 캐시입니다. 기본값은 `nil`이고, 이때는 ``dataLoader``의 `URLCache`가 디스크 캐시 역할을 합니다.
        public var diskCache: (any DiskCaching)?

        /// 디코딩한 이미지를 보관하는 메모리 캐시입니다. 기본값은 ``MemoryCache/shared``이고, `nil`을 넣으면 메모리 캐시를 쓰지 않습니다.
        public var memoryCache: (any MemoryCaching)? {
            get { isCustomMemoryCacheProvided ? customMemoryCache : MemoryCache.shared }
            set {
                customMemoryCache = newValue
                isCustomMemoryCacheProvided = true
            }
        }

        private var customMemoryCache: (any MemoryCaching)?
        private var isCustomMemoryCacheProvided = false

        /// 데이터마다 쓸 디코더를 고릅니다.
        ///
        /// 기본값은 ``ImageDecoderRegistry/shared``에 등록된 디코더 중 데이터를 맡을 수 있는 것을 고릅니다.
        /// `nil`을 돌려주면 요청은 ``ImageSession/Error/decoderNotRegistered(context:)``로 끝납니다.
        public var makeImageDecoder: @Sendable (ImageDecodingContext) -> (any ImageDecoding)? = {
            ImageDecoderRegistry.shared.decoder(for: $0)
        }

        /// 필터를 적용한 이미지를 디스크 캐시에 저장할 때 쓸 인코더를 고릅니다. 기본값은 ``ImageEncoders/Default``입니다.
        public var makeImageEncoder: @Sendable (ImageEncodingContext) -> any ImageEncoding = { _ in
            ImageEncoders.Default()
        }

        /// 디코딩할 수 있는 최대 픽셀 수입니다.
        ///
        /// 넘는 이미지는 디코딩하지 않고 ``ImageSession/Error/decodingFailed(decoder:context:error:)``로 끝납니다. 큰 이미지 하나로 메모리가 부족해 앱이 종료되는 일을 막습니다.
        public var decodingLimits: ImageDecodingLimits = .default

        /// 디코딩한 이미지를 백그라운드에서 미리 그려 둘지 정합니다. 기본값은 `true`입니다.
        ///
        /// 끄면 메인 스레드에서 이미지를 처음 그릴 때 디코딩이 일어나 스크롤이 끊길 수 있습니다.
        public var isDecompressionEnabled = true

        /// 미리 그릴 때 `UIImage.preparingForDisplay()`를 쓸지 정합니다. 기본값은 `false`이고, 이때는 비트맵 컨텍스트에 직접 그립니다.
        public var isUsingPrepareForDisplay = false

        /// ``diskCache``에 무엇을 남길지 정합니다. 기본값은 ``DiskCachePolicy/storeOriginalData``입니다.
        public var diskCachePolicy = DiskCachePolicy.storeOriginalData

        /// 같은 이미지를 동시에 요청하면 다운로드와 디코딩을 한 번만 할지 정합니다. 기본값은 `true`입니다.
        public var isTaskCoalescingEnabled = true

        /// 새 다운로드를 시작하는 속도를 제한할지 정합니다. 기본값은 `true`입니다.
        ///
        /// 1초에 80개까지 시작하고, 한 번에 몰려도 25개까지만 바로 시작합니다.
        /// 빠르게 스크롤해서 다운로드를 시작하자마자 취소하는 일이 반복될 때 네트워크 연결이 쌓이지 않게 합니다.
        public var isRateLimiterEnabled = true

        /// 다운로드 도중에 미리보기를 만들지 정합니다. 기본값은 `false`입니다.
        ///
        /// 켜면 프로그레시브 JPEG은 받은 만큼 흐린 이미지를, GIF는 첫 프레임을 먼저 보여 줍니다.
        /// 어떤 미리보기를 만들지는 ``Delegate/previewPolicy(for:session:)``에서 정합니다.
        public var isProgressiveDecodingEnabled = false

        /// 미리보기를 만드는 최소 간격입니다. 기본값은 0.5초이고, 0이면 데이터를 받을 때마다 만듭니다.
        public var progressiveDecodingInterval: TimeInterval = 0.5

        /// 미리보기를 메모리 캐시에 넣을지 정합니다. 기본값은 `true`입니다.
        ///
        /// 켜 두면 다운로드가 끝나기 전에 같은 이미지를 요청한 다른 뷰도 미리보기를 바로 보여 줄 수 있습니다.
        public var isStoringPreviewsInMemoryCache = true

        /// 중간에 끊긴 다운로드를 이어받을지 정합니다. 기본값은 `true`입니다.
        ///
        /// 서버가 `Accept-Ranges: bytes`와 `ETag`나 `Last-Modified` 헤더를 보냈을 때만 이어받습니다.
        public var isResumableDataEnabled = true

        /// `file://`과 `data:` 주소를 네트워크를 거치지 않고 바로 읽을지 정합니다. 기본값은 `true`입니다.
        public var isLocalResourcesSupportEnabled = true

        /// 이미지 하나로 받을 수 있는 최대 바이트 수입니다.
        ///
        /// 기본값은 200MB와 기기 메모리의 10분의 1 중 작은 값입니다. 넘으면 다운로드를 멈추고 ``ImageSession/Error/dataDownloadExceededMaximumSize``로 끝납니다.
        /// `nil`이면 제한하지 않습니다.
        public var maximumResponseDataSize: Int? = Configuration.defaultMaximumResponseDataSize

        /// 동시에 내려받을 수 있는 이미지 수를 정합니다. 기본값은 6개입니다.
        public var dataLoadingQueue = TaskQueue(maxConcurrentOperationCount: 6)
        /// 동시에 디코딩할 수 있는 이미지 수를 정합니다. 기본값은 1개입니다.
        public var imageDecodingQueue = TaskQueue(maxConcurrentOperationCount: 1)
        /// 디스크 캐시에 넣으려고 동시에 인코딩할 수 있는 이미지 수를 정합니다. 기본값은 1개입니다.
        public var imageEncodingQueue = TaskQueue(maxConcurrentOperationCount: 1)
        /// 동시에 필터를 적용할 수 있는 이미지 수를 정합니다. 기본값은 2개입니다.
        public var imageFilteringQueue = TaskQueue(maxConcurrentOperationCount: 2)
        /// 동시에 미리 그릴 수 있는 이미지 수를 정합니다. 기본값은 2개입니다.
        public var imageDecompressingQueue = TaskQueue(maxConcurrentOperationCount: 2)

        /// 같은 주소에서 실패가 이어지면 잠시 요청을 막는 정책입니다. 기본값은 `nil`이고, 이때는 막지 않습니다.
        public var failureCooldown: FailureCooldownPolicy?

        /// 작업이 끝날 때마다 ``ImageTaskMetrics``를 ``Delegate/session(_:didRecord:)``로 보낼지 정합니다. 기본값은 `false`입니다.
        public var isMetricsCollectionEnabled = false

        /// 세션이 시각을 읽는 시계입니다. 테스트에서 시간을 직접 움직일 때만 바꿉니다.
        @_spi(Testing) public var clock: any SessionClock = SystemClock()

        /// 세션이 작업을 미뤄 부르는 스케줄러입니다. 테스트에서 시간을 직접 움직일 때만 바꿉니다.
        @_spi(Testing) public var scheduler: any SessionScheduler = SystemClock()

        var unexpectedErrorAssertion: @Sendable (String) -> Void = { message in
            assertionFailure(message)
        }

        /// Instruments에서 다운로드, 디코딩, 필터 구간을 볼 수 있도록 signpost를 남길지 정합니다. 기본값은 `false`입니다.
        ///
        /// 모든 세션에 함께 적용됩니다.
        public static var isSignpostLoggingEnabled: Bool {
            get { signpostLoggingFlag.value }
            set { signpostLoggingFlag.withLock { $0 = newValue } }
        }

        private static let signpostLoggingFlag = LockIsolated(false)

        /// 기본 설정을 만듭니다.
        ///
        /// - Parameter dataLoader: 데이터를 내려받는 객체입니다. 기본값은 `URLCache`를 쓰는 ``DataLoader``입니다.
        public init(dataLoader: any DataLoading = DataLoader()) {
            self.dataLoader = dataLoader
        }

        /// `URLCache`(디스크 150MB)를 디스크 캐시로 쓰는 설정입니다. ``ImageSession/shared``가 이 설정을 씁니다.
        ///
        /// `URLCache`는 서버의 `Cache-Control` 헤더를 따르므로, 헤더가 저장을 막으면 디스크에 남지 않습니다.
        public static var withURLCache: Configuration {
            Configuration()
        }

        /// `URLCache` 대신 ``DiskCache``를 쓰는 설정입니다.
        ///
        /// 서버 헤더와 상관없이 받은 데이터를 150MB까지 디스크에 남깁니다. 이름이 `ImageLoader.DataCache`인 캐시를 씁니다.
        public static var withDiskCache: Configuration {
            withDiskCache()
        }

        /// 이름과 크기를 정한 ``DiskCache``를 쓰는 설정입니다.
        ///
        /// 캐시 폴더를 만들지 못하면 디스크 캐시 없이 동작합니다.
        ///
        /// - Parameters:
        ///   - name: 캐시 폴더 이름입니다. 같은 이름을 쓰는 설정끼리는 같은 캐시를 함께 씁니다.
        ///   - sizeLimit: 디스크 캐시의 최대 바이트 수입니다. `nil`이면 150MB입니다.
        public static func withDiskCache(name: String = "ImageLoader.DataCache", sizeLimit: Int? = nil) -> Configuration {
            let configuration = DataLoader.defaultConfiguration
            configuration.urlCache = nil
            var sessionConfiguration = Configuration(dataLoader: DataLoader(configuration: configuration))
            sessionConfiguration.diskCache = try? DiskCache.shared(name: name, sizeLimit: sizeLimit)
            return sessionConfiguration
        }

        static var defaultMaximumResponseDataSize: Int {
            let physicalMemory = ProcessInfo.processInfo.physicalMemory
            return Int(min(UInt64(200 * 1024 * 1024), physicalMemory / 10))
        }
    }

    /// ``Configuration/diskCache``에 무엇을 남길지 정합니다.
    @frozen public enum DiskCachePolicy: Sendable {
        /// 필터나 썸네일 없이 요청한 이미지는 원본 바이트를, 필터를 적용한 이미지는 결과를 인코딩해 저장합니다.
        case automatic
        /// 내려받은 원본 바이트만 저장합니다. 필터는 캐시에서 읽을 때마다 다시 적용합니다. 기본값입니다.
        case storeOriginalData
        /// 필터를 적용한 최종 이미지를 인코딩해 저장하고, 원본 바이트는 남기지 않습니다.
        case storeEncodedImages
        /// 원본 바이트와 필터 결과를 둘 다 저장합니다. 디스크를 가장 많이 쓰는 대신 필터를 다시 적용하지 않습니다.
        case storeAll
    }

    /// 다운로드 도중에 어떤 미리보기를 만들지 정합니다. ``Configuration/isProgressiveDecodingEnabled``를 켰을 때만 씁니다.
    ///
    /// GIF는 이 값과 상관없이 첫 프레임을 한 번 미리보기로 만듭니다.
    @frozen public enum PreviewPolicy: Sendable, Equatable {
        /// 받은 데이터만큼 디코딩해 점점 선명해지는 미리보기를 만듭니다. 프로그레시브 JPEG에 맞습니다.
        case incremental
        /// 파일에 들어 있는 작은 썸네일을 한 번 미리보기로 보여 줍니다. 썸네일이 없으면 미리보기를 만들지 않습니다.
        case thumbnail
        /// 미리보기를 만들지 않습니다.
        case disabled

        /// 데이터 형식에 맞는 기본 정책을 돌려줍니다. 프로그레시브 JPEG과 GIF는 ``incremental``, 나머지는 ``disabled``입니다.
        public static func `default`(for data: Data) -> PreviewPolicy {
            switch AssetType(data) {
            case .gif:
                return .incremental
            case .jpeg:
                return JPEGScanner.isProgressive(data) ? .incremental : .disabled
            default:
                return .disabled
            }
        }
    }
}

enum JPEGScanner {
    static func isProgressive(_ data: Data) -> Bool {
        var index = data.startIndex + 2
        while index + 4 < data.endIndex {
            guard data[index] == 0xFF else { return false }
            let marker = data[index + 1]
            if marker == 0xC2 {
                return true
            }
            if marker == 0xC0 || marker == 0xC1 || marker == 0xDA {
                return false
            }
            let length = Int(data[index + 2]) << 8 | Int(data[index + 3])
            index += 2 + length
        }
        return false
    }
}
