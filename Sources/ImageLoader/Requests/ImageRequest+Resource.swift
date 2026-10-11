import Foundation

extension ImageRequest {
    enum Resource: CustomStringConvertible, Sendable {
        case url(URL?)
        case urlRequest(URLRequest)
        case data(id: String, fetch: @Sendable () async throws -> Data)
        case image(id: String, fetch: @Sendable () async throws -> ImageContent)

        var description: String {
            switch self {
            case .url(let url): "\(url?.absoluteString ?? "nil")"
            case .urlRequest(let urlRequest): "\(urlRequest)"
            case .data(let id, _): "data(\(id))"
            case .image(let id, _): "image(\(id))"
            }
        }
    }
}
