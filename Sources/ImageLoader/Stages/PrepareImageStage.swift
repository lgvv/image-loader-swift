import Foundation

final class PrepareImageStage: Stage<ImageResponse>, @unchecked Sendable {
    override func start() {
        if let content = session.cache.cachedImageFromMemoryCache(for: request) {
            let response = ImageResponse(content: content, request: request, cacheType: .memory)
            send(value: response, isCompleted: !content.isPreview)
            guard content.isPreview else { return }
        }
        loadFromDiskCacheOrFetch()
    }

    private func loadFromDiskCacheOrFetch() {
        guard !request.effectiveOptions.contains(.disableDiskCacheReads),
            let diskCache = session.delegate.diskCache(for: request, session: session)
        else {
            fetchImage()
            return
        }
        let key = makeDiskCacheKey(for: request)
        let originalKey = request.thumbnail != nil && request.filters.isEmpty ? makeDiskCacheKey(for: request.withoutThumbnail()) : nil
        perform(
            on: session.diskCacheReadingQueue, worker: SessionWorkers.io,
            work: {
                if let data = diskCache.cachedData(for: key) {
                    return (data, key) as (Data, String)?
                }
                if let originalKey, let data = diskCache.cachedData(for: originalKey) {
                    return (data, originalKey)
                }
                return nil
            },
            completion: { [weak self] cached in
                guard let self else { return }
                if let (data, key) = cached {
                    self.decodeCachedData(data, key: key, diskCache: diskCache)
                } else {
                    self.fetchImage()
                }
            })
    }

    private func decodeCachedData(_ data: Data, key: String, diskCache: any DiskCaching) {
        var context = ImageDecodingContext(request: request, data: data, cacheType: .disk)
        context.decodingLimits = session.configuration.decodingLimits
        guard let decoder = session.delegate.imageDecoder(for: context, session: session) else {
            removeCorruptedEntry(key: key, diskCache: diskCache)
            fetchImage()
            return
        }
        decode(context, decoder: decoder) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                self.didReceiveDecodedImage(response, isCompleted: true, isFromDisk: true)
            case .failure(let error):
                if error.isDecodingLimitRejection {
                    self.send(error: error)
                    return
                }
                self.removeCorruptedEntry(key: key, diskCache: diskCache)
                self.fetchImage()
            }
        }
    }

    private func removeCorruptedEntry(key: String, diskCache: any DiskCaching) {
        diskCache.removeData(for: key)
        session.record(.corruptedDiskCacheEntryRemoved)
    }

    private func fetchImage() {
        guard !request.effectiveOptions.contains(.returnCacheDataDontLoad) else {
            send(error: .dataMissingInCache)
            return
        }
        if let filter = request.filters.last {
            let request = request.withFilters(Array(request.filters.dropLast()))
            dependency = session.makePrepareImageStage(for: request).subscribe(self) { [weak self] response, isCompleted in
                self?.process(response, isCompleted: isCompleted, filter: filter)
            }
        } else {
            dependency = session.makeDecodeImageStage(for: request).subscribe(self) { [weak self] response, isCompleted in
                self?.didReceiveDecodedImage(response, isCompleted: isCompleted, isFromDisk: false)
            }
        }
    }

    private func process(_ response: ImageResponse, isCompleted: Bool, filter: any ImageFilter) {
        guard !isDisposed else { return }
        if isCompleted {
            cancelCurrentOperation()
        } else if operation != nil {
            return
        }
        let request = request
        let context = ImageFilterContext(request: request, response: response, isCompleted: isCompleted)
        perform(
            on: session.configuration.imageFilteringQueue, worker: SessionWorkers.processing,
            work: {
                SessionSignposter.shared.interval(isCompleted ? "ProcessImage" : "ProcessProgressiveImage") {
                    do {
                        var content = try filter.process(response.content, context: context)
                        if content.userInfo[.animatedImageKey] != nil {
                            content.userInfo[.animatedImageKey] = nil
                            content.data = nil
                        }
                        var processed = response
                        processed.content = content
                        processed.request = request
                        return .success(processed)
                    } catch {
                        return .failure(.processingFailed(filter: filter, context: context, error: error)) as Result<ImageResponse, ImageSession.Error>
                    }
                }
            },
            completion: { [weak self] (result: Result<ImageResponse, ImageSession.Error>) in
                guard let self else { return }
                switch result {
                case .success(let response):
                    self.didReceiveProcessedImage(response, isCompleted: isCompleted)
                case .failure(let error):
                    if isCompleted {
                        self.send(error: error)
                    }
                }
            })
    }

    private func didReceiveDecodedImage(_ response: ImageResponse, isCompleted: Bool, isFromDisk: Bool) {
        var response = response
        response.request = request
        if isFromDisk {
            response.cacheType = .disk
        }
        decompressIfNeeded(response, isCompleted: isCompleted)
    }

    private func didReceiveProcessedImage(_ response: ImageResponse, isCompleted: Bool) {
        decompressIfNeeded(response, isCompleted: isCompleted)
    }

    private func decompressIfNeeded(_ response: ImageResponse, isCompleted: Bool) {
        guard isDecompressionNeeded(for: response) else {
            didFinish(response, isCompleted: isCompleted)
            return
        }
        if isCompleted {
            cancelCurrentOperation()
        } else if operation != nil {
            return
        }
        let session = session
        let request = request
        perform(
            on: session.configuration.imageDecompressingQueue, worker: SessionWorkers.decompressing,
            work: {
                SessionSignposter.shared.interval(isCompleted ? "DecompressImage" : "DecompressProgressiveImage") {
                    session.delegate.decompress(response: response, request: request, session: session)
                }
            },
            completion: { [weak self] response in
                self?.didFinish(response, isCompleted: isCompleted)
            })
    }

    private func isDecompressionNeeded(for response: ImageResponse) -> Bool {
        ImageDecompression.isDecompressionNeeded(for: response)
            && !request.options.contains(.skipDecompression)
            && hasDirectSubscribers
            && session.delegate.shouldDecompress(response: response, for: request, session: session)
    }

    private func didFinish(_ response: ImageResponse, isCompleted: Bool) {
        guard !isDisposed else { return }
        storeImageInCaches(response)
        send(value: response, isCompleted: isCompleted)
    }

    private func storeImageInCaches(_ response: ImageResponse) {
        guard hasDirectSubscribers else { return }
        session.cache.storeCachedImageInMemoryCache(response.content, for: request, isFromDisk: response.cacheType == .disk)
        if shouldStoreResponseInDiskCache(response) {
            storeImageInDiskCache(response)
        }
    }

    private func shouldStoreResponseInDiskCache(_ response: ImageResponse) -> Bool {
        guard !response.content.isPreview,
            response.cacheType == nil,
            !request.effectiveOptions.contains(.disableDiskCacheWrites),
            !imageTasks.allSatisfy({ $0.request.effectiveOptions.contains(.disableDiskCacheWrites) })
        else {
            return false
        }
        let isProcessed = !request.filters.isEmpty || request.thumbnail != nil
        switch session.configuration.diskCachePolicy {
        case .automatic: return isProcessed
        case .storeOriginalData: return false
        case .storeEncodedImages: return true
        case .storeAll: return isProcessed
        }
    }

    private func storeImageInDiskCache(_ response: ImageResponse) {
        guard let diskCache = session.delegate.diskCache(for: request, session: session) else { return }
        let session = session
        let request = request
        let key = makeDiskCacheKey(for: request)
        session.configuration.imageEncodingQueue.add(priority: .low) { finish in
            SessionWorkers.encoding.async {
                let context = ImageEncodingContext(request: request, image: response.image, urlResponse: response.urlResponse)
                let encoder = session.delegate.imageEncoder(for: context, session: session)
                let data = autoreleasepool {
                    SessionSignposter.shared.interval("EncodeImage") {
                        encoder.encode(response.content, context: context)
                    }
                }
                finish()
                guard let data else { return }
                session.delegate.willCache(data: data, image: response.content, for: request, session: session) { data in
                    guard let data else { return }
                    diskCache.storeData(data, for: key)
                }
            }
        }
    }
}

extension ImageSession.Error {
    var isDecodingLimitRejection: Bool {
        guard case .decodingFailed(_, _, let error) = self else { return false }
        return error is ImageDecodingLimits.Error
    }
}
