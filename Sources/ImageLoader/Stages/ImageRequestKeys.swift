import Foundation

final class RequestCacheKey: Hashable, @unchecked Sendable {
    let imageID: String?
    let scale: Float
    let thumbnail: ImageRequest.ThumbnailOptions?
    let filters: [AnyHashable]
    private let hash: Int

    init(_ request: ImageRequest) {
        imageID = request.imageID
        scale = request.scale
        thumbnail = request.thumbnail
        filters = request.filters.map(\.hashableIdentifier)
        var hasher = Hasher()
        hasher.combine(imageID)
        hasher.combine(scale)
        hasher.combine(thumbnail)
        hasher.combine(filters)
        hash = hasher.finalize()
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(hash)
    }

    static func == (lhs: RequestCacheKey, rhs: RequestCacheKey) -> Bool {
        lhs === rhs || (lhs.hash == rhs.hash && lhs.imageID == rhs.imageID && lhs.scale == rhs.scale && lhs.thumbnail == rhs.thumbnail && lhs.filters == rhs.filters)
    }
}

final class PrepareImageStageKey: Hashable, @unchecked Sendable {
    let loadKey: DecodeImageStageKey
    let options: ImageRequest.Options
    let filters: [AnyHashable]
    private let hash: Int

    init(_ request: ImageRequest) {
        loadKey = DecodeImageStageKey(request)
        options = request.effectiveOptions
        filters = request.filters.map(\.hashableIdentifier)
        var hasher = Hasher()
        hasher.combine(loadKey)
        hasher.combine(options)
        hasher.combine(filters)
        hash = hasher.finalize()
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(hash)
    }

    static func == (lhs: PrepareImageStageKey, rhs: PrepareImageStageKey) -> Bool {
        lhs === rhs || (lhs.hash == rhs.hash && lhs.loadKey == rhs.loadKey && lhs.options == rhs.options && lhs.filters == rhs.filters)
    }
}

struct DecodeImageStageKey: Hashable, Sendable {
    let dataLoadKey: FetchDataStageKey
    let scale: Float
    let thumbnail: ImageRequest.ThumbnailOptions?

    init(_ request: ImageRequest) {
        dataLoadKey = FetchDataStageKey(request)
        scale = request.scale
        thumbnail = request.thumbnail
    }
}

struct FetchDataStageKey: Hashable, Sendable {
    let imageID: String?
    let cachePolicy: URLRequest.CachePolicy
    let allowsCellularAccess: Bool
    let revalidates: Bool
    let bypassesFailureCooldown: Bool

    init(_ request: ImageRequest) {
        imageID = request.originalImageID
        revalidates = request.revalidatesCachedData
        bypassesFailureCooldown = request.bypassesFailureCooldown
        if case .urlRequest(let urlRequest) = request.resource {
            cachePolicy = urlRequest.cachePolicy
            allowsCellularAccess = urlRequest.allowsCellularAccess
        } else {
            cachePolicy = .useProtocolCachePolicy
            allowsCellularAccess = true
        }
    }
}
