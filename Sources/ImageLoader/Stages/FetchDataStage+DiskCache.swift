import Foundation

extension FetchDataStage {
    func storeDataInCacheIfNeeded(_ data: Data) {
        guard !isLocalResource,
            let diskCache = session.delegate.diskCache(for: request, session: session),
            shouldStoreDataInDiskCache(),
            Self.isStorableImageData(data, response: urlResponse)
        else {
            return
        }
        let key = makeDiskCacheKey(for: request.withFilters([]).withoutThumbnail())
        let session = session
        let request = request
        session.delegate.willCache(data: data, image: nil, for: request, session: session) { data in
            guard let data else { return }
            diskCache.storeData(data, for: key)
        }
    }

    private func shouldStoreDataInDiskCache() -> Bool {
        let imageTasks = imageTasks
        guard imageTasks.contains(where: { !$0.request.effectiveOptions.contains(.disableDiskCacheWrites) }) else {
            return false
        }
        switch session.configuration.diskCachePolicy {
        case .automatic:
            return imageTasks.contains { $0.request.filters.isEmpty && $0.request.thumbnail == nil }
        case .storeOriginalData, .storeAll:
            return true
        case .storeEncodedImages:
            return false
        }
    }

    static func isStorableImageData(_ data: Data, response: URLResponse?) -> Bool {
        if AssetType(data) != nil {
            return true
        }
        return response?.mimeType?.hasPrefix("image/") ?? false
    }
}
