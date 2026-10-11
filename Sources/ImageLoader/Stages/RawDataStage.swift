import Foundation
import UIKit

final class RawDataStage: Stage<ImageResponse>, @unchecked Sendable {
    override func start() {
        guard !request.effectiveOptions.contains(.disableDiskCacheReads),
            let diskCache = session.delegate.diskCache(for: request, session: session)
        else {
            loadData()
            return
        }
        let key = makeDiskCacheKey(for: request.withFilters([]).withoutThumbnail())
        perform(
            on: session.diskCacheReadingQueue, worker: SessionWorkers.io,
            work: {
                diskCache.cachedData(for: key)
            },
            completion: { [weak self] data in
                guard let self else { return }
                if let data {
                    self.send(value: self.makeResponse(data: data, urlResponse: nil, cacheType: .disk), isCompleted: true)
                } else {
                    self.loadData()
                }
            })
    }

    private func loadData() {
        guard !request.effectiveOptions.contains(.returnCacheDataDontLoad) else {
            send(error: .dataMissingInCache)
            return
        }
        let request = request.withFilters([]).withoutThumbnail()
        dependency = session.makeFetchDataStage(for: request).subscribe(self) { [weak self] value, isCompleted in
            guard let self, isCompleted else { return }
            self.send(value: self.makeResponse(data: value.0, urlResponse: value.1, cacheType: nil), isCompleted: true)
        }
    }

    private func makeResponse(data: Data, urlResponse: URLResponse?, cacheType: ImageResponse.CacheType?) -> ImageResponse {
        let content = ImageContent(image: UIImage(), type: AssetType(data), data: data)
        return ImageResponse(content: content, request: request, urlResponse: urlResponse, cacheType: cacheType)
    }
}
