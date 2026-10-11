import Foundation
import UIKit

extension ImageSession {
    /// 세션의 메모리 캐시와 디스크 캐시를 요청 단위로 읽고 쓰고 지웁니다. ``ImageSession/cache``로 얻습니다.
    ///
    /// 요청을 넘기면 세션이 이미지를 불러올 때와 같은 키를 씁니다. 필터나 썸네일 설정이 다르면 다른 항목으로 봅니다.
    public struct Cache: Sendable {
        let session: ImageSession

        /// 어느 캐시를 대상으로 할지 고릅니다.
        public struct Caches: OptionSet, Sendable {
            /// 캐시 종류를 비트로 담은 값입니다.
            public let rawValue: Int

            /// 비트 값으로 캐시 종류를 만듭니다.
            public init(rawValue: Int) {
                self.rawValue = rawValue
            }

            /// 메모리 캐시입니다.
            public static let memory = Caches(rawValue: 1 << 0)
            /// 디스크 캐시입니다. ``ImageSession/Configuration/diskCache``가 없으면 대상이 없습니다.
            public static let disk = Caches(rawValue: 1 << 1)
            /// 메모리 캐시와 디스크 캐시 모두입니다.
            public static let all: Caches = [.memory, .disk]
        }

        /// 주소의 이미지를 메모리 캐시에서 읽거나 씁니다. `nil`을 넣으면 지웁니다. 디스크 캐시는 건드리지 않습니다.
        public subscript(url: URL) -> ImageContent? {
            get { self[ImageRequest(url: url)] }
            nonmutating set { self[ImageRequest(url: url)] = newValue }
        }

        /// 요청의 이미지를 메모리 캐시에서 읽거나 씁니다. `nil`을 넣으면 지웁니다. 디스크 캐시는 건드리지 않습니다.
        public subscript(request: ImageRequest) -> ImageContent? {
            get { cachedImageFromMemoryCache(for: request) }
            nonmutating set {
                if let newValue {
                    storeCachedImageInMemoryCache(newValue, for: request)
                } else {
                    removeCachedImageFromMemoryCache(for: request)
                }
            }
        }

        /// 캐시에 있는 이미지를 돌려줍니다.
        ///
        /// 메모리 캐시를 먼저 보고, 없으면 디스크 캐시의 데이터를 읽어 디코딩합니다. 디스크에서 읽으면 호출한 스레드에서 디코딩하므로 메인 스레드에서는 `[.memory]`만 넘겨 주세요.
        ///
        /// - Parameters:
        ///   - request: 찾을 이미지의 요청입니다.
        ///   - caches: 찾아볼 캐시입니다.
        /// - Returns: 캐시에 없거나 디코딩하지 못하면 `nil`입니다.
        public func cachedImage(for request: ImageRequest, caches: Caches = [.all]) -> ImageContent? {
            if caches.contains(.memory), let image = cachedImageFromMemoryCache(for: request) {
                return image
            }
            if caches.contains(.disk), let data = cachedData(for: request) {
                var context = ImageDecodingContext(request: request, data: data, cacheType: .disk)
                context.decodingLimits = session.configuration.decodingLimits
                guard let decoder = session.delegate.imageDecoder(for: context, session: session),
                    let response = try? decoder.decode(context)
                else {
                    return nil
                }
                return response.content
            }
            return nil
        }

        /// 이미지를 캐시에 저장합니다.
        ///
        /// 메모리 캐시에는 바로 넣고, 디스크 캐시에는 백그라운드에서 인코딩한 뒤 넣습니다. 미리보기 이미지는 디스크 캐시에 넣지 않습니다.
        ///
        /// - Parameters:
        ///   - image: 저장할 이미지입니다.
        ///   - request: 나중에 이 이미지를 찾을 때 쓸 요청입니다.
        ///   - caches: 저장할 캐시입니다.
        public func storeCachedImage(_ image: ImageContent, for request: ImageRequest, caches: Caches = [.all]) {
            if caches.contains(.memory) {
                storeCachedImageInMemoryCache(image, for: request)
            }
            if caches.contains(.disk), !image.isPreview, !request.effectiveOptions.contains(.disableDiskCacheWrites),
                let diskCache = session.delegate.diskCache(for: request, session: session)
            {
                let session = session
                let key = makeDiskCacheKey(for: request)
                SessionQueue.async {
                    session.configuration.imageEncodingQueue.add(priority: .low) { finish in
                        SessionWorkers.encoding.async {
                            let context = ImageEncodingContext(request: request, image: image.image, urlResponse: nil)
                            let encoder = session.delegate.imageEncoder(for: context, session: session)
                            let data = encoder.encode(image, context: context)
                            finish()
                            if let data {
                                diskCache.storeData(data, for: key)
                            }
                        }
                    }
                }
            }
        }

        /// 요청의 이미지를 캐시에서 지웁니다.
        public func removeCachedImage(for request: ImageRequest, caches: Caches = [.all]) {
            if caches.contains(.memory) {
                removeCachedImageFromMemoryCache(for: request)
            }
            if caches.contains(.disk) {
                removeCachedData(for: request)
            }
        }

        /// 요청의 이미지가 캐시에 있는지 알려 줍니다. 디스크 캐시는 데이터가 있는지만 보고 디코딩하지 않습니다.
        public func containsCachedImage(for request: ImageRequest, caches: Caches = [.all]) -> Bool {
            if caches.contains(.memory), cachedImageFromMemoryCache(for: request) != nil {
                return true
            }
            if caches.contains(.disk), !request.effectiveOptions.contains(.disableDiskCacheReads),
                let diskCache = session.delegate.diskCache(for: request, session: session)
            {
                return diskCache.containsData(for: makeDiskCacheKey(for: request))
            }
            return false
        }

        /// 요청의 데이터를 디스크 캐시에서 읽습니다. 파일을 읽으므로 메인 스레드에서는 부르지 않는 것이 좋습니다.
        public func cachedData(for request: ImageRequest) -> Data? {
            guard !request.effectiveOptions.contains(.disableDiskCacheReads),
                let diskCache = session.delegate.diskCache(for: request, session: session)
            else {
                return nil
            }
            return diskCache.cachedData(for: makeDiskCacheKey(for: request))
        }

        /// 데이터를 디스크 캐시에 저장합니다. ``ImageRequest/Options/disableDiskCacheWrites``를 켠 요청이면 저장하지 않습니다.
        public func storeCachedData(_ data: Data, for request: ImageRequest) {
            guard !request.effectiveOptions.contains(.disableDiskCacheWrites),
                let diskCache = session.delegate.diskCache(for: request, session: session)
            else {
                return
            }
            diskCache.storeData(data, for: makeDiskCacheKey(for: request))
        }

        /// 요청의 데이터를 디스크 캐시에서 지웁니다.
        public func removeCachedData(for request: ImageRequest) {
            session.delegate.diskCache(for: request, session: session)?.removeData(for: makeDiskCacheKey(for: request))
        }

        /// 요청의 데이터가 디스크 캐시에 있는지 알려 줍니다.
        public func containsData(for request: ImageRequest) -> Bool {
            session.delegate.diskCache(for: request, session: session)?.containsData(for: makeDiskCacheKey(for: request)) ?? false
        }

        /// 요청을 메모리 캐시에 넣을 때 쓰는 키를 만듭니다. ``MemoryCache``를 직접 다룰 때 씁니다.
        public func makeMemoryCacheKey(for request: ImageRequest) -> MemoryCacheKey {
            if let key = session.delegate.cacheKey(for: request, session: session) {
                return MemoryCacheKey(key: key)
            }
            return MemoryCacheKey(request: request)
        }

        /// 요청을 디스크 캐시에 넣을 때 쓰는 키를 만듭니다.
        ///
        /// 필터와 썸네일이 없으면 ``ImageRequest/imageID``를 그대로 쓰고, 있으면 그 식별자를 이어 붙입니다.
        /// ``ImageSession/Delegate/cacheKey(for:session:)``가 값을 돌려주면 그 값을 씁니다.
        public func makeDiskCacheKey(for request: ImageRequest) -> String {
            if let key = session.delegate.cacheKey(for: request, session: session) {
                return key
            }
            let imageID = request.imageID ?? ""
            let thumbnail = request.thumbnail?.identifier
            let filters = request.filters.map(\.identifier)
            guard thumbnail != nil || !filters.isEmpty else { return imageID }
            return ([imageID, thumbnail ?? ""] + filters).joined(separator: Self.dataKeySeparator)
        }

        static let dataKeySeparator = "\u{1F}"

        /// 캐시를 모두 비웁니다.
        ///
        /// `.disk`를 넘기면 ``ImageSession/Configuration/diskCache``와 함께 ``DataLoader``의 `URLCache`, 이어받기용으로 보관한 데이터도 지웁니다.
        public func removeAll(caches: Caches = [.all]) {
            if caches.contains(.memory) {
                session.configuration.memoryCache?.removeAll()
            }
            if caches.contains(.disk) {
                session.configuration.diskCache?.removeAll()
                (session.configuration.dataLoader as? DataLoader)?.session.configuration.urlCache?.removeAllCachedResponses()
            }
            ResumableDataStorage.shared.removeAll(sessionID: session.id)
        }

        func cachedImageFromMemoryCache(for request: ImageRequest) -> ImageContent? {
            guard !request.effectiveOptions.contains(.disableMemoryCacheReads),
                let memoryCache = session.delegate.memoryCache(for: request, session: session)
            else {
                return nil
            }
            return memoryCache[makeMemoryCacheKey(for: request)]
        }

        func storeCachedImageInMemoryCache(_ image: ImageContent, for request: ImageRequest, isFromDisk: Bool = false) {
            guard !request.effectiveOptions.contains(.disableMemoryCacheWrites),
                !image.isPreview || session.configuration.isStoringPreviewsInMemoryCache,
                let memoryCache = session.delegate.memoryCache(for: request, session: session)
            else {
                return
            }
            let key = makeMemoryCacheKey(for: request)
            memoryCache[key] = image
            if isFromDisk {
                (memoryCache as? MemoryCache)?.noteDiskReload(forKey: key)
            }
        }

        func removeCachedImageFromMemoryCache(for request: ImageRequest) {
            session.delegate.memoryCache(for: request, session: session)?[makeMemoryCacheKey(for: request)] = nil
        }
    }
}

extension ImageSession {
    func checkFailureCooldown(_ key: FailureCooldownKey?, bypass: Bool) -> ImageSession.Error? {
        SessionQueue.assertOnQueue()
        guard let failureCooldown, !bypass, let key, let error = failureCooldown.check(key) else { return nil }
        record(.failureCooldownApplied(error))
        return .dataLoadingFailed(error: error)
    }

    func recordFailureForCooldown(_ key: FailureCooldownKey?, error: ImageSession.Error) {
        SessionQueue.assertOnQueue()
        guard let failureCooldown, let key else { return }
        failureCooldown.recordFailure(key, error: error)
    }

    func recordSuccessForCooldown(_ key: FailureCooldownKey?) {
        SessionQueue.assertOnQueue()
        guard let failureCooldown, let key else { return }
        failureCooldown.recordSuccess(key)
    }
}
