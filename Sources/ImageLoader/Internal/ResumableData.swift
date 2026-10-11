import Foundation

struct ResumableData: Sendable {
    let data: Data
    let validator: String

    init?(response: URLResponse, data: Data) {
        guard !data.isEmpty,
            let response = response as? HTTPURLResponse,
            data.count < response.expectedContentLength,
            response.statusCode == 200 || response.statusCode == 206,
            let acceptRanges = response.value(forHTTPHeaderField: "Accept-Ranges"),
            acceptRanges.lowercased() == "bytes",
            let validator = Self.validator(of: response)
        else {
            return nil
        }
        self.data = data
        self.validator = validator
    }

    func resume(request: inout URLRequest) {
        var headers = request.allHTTPHeaderFields ?? [:]
        headers["Range"] = "bytes=\(data.count)-"
        headers["If-Range"] = validator
        request.allHTTPHeaderFields = headers
    }

    static func isResumedResponse(_ response: URLResponse) -> Bool {
        (response as? HTTPURLResponse)?.statusCode == 206
    }

    func isValidResumption(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse,
            response.statusCode == 206,
            let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
            Self.rangeStart(contentRange) == data.count
        else {
            return false
        }
        if validator.hasPrefix("\""), let etag = response.value(forHTTPHeaderField: "ETag"), etag != validator {
            return false
        }
        return true
    }

    static func validator(of response: HTTPURLResponse) -> String? {
        if let etag = response.value(forHTTPHeaderField: "ETag"), !etag.hasPrefix("W/") {
            return etag
        }
        return response.value(forHTTPHeaderField: "Last-Modified")
    }

    static func rangeStart(_ contentRange: String) -> Int? {
        let parts = contentRange.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes", let dash = parts[1].firstIndex(of: "-") else {
            return nil
        }
        return Int(parts[1][..<dash])
    }
}

final class ResumableDataStorage: @unchecked Sendable {
    static let shared = ResumableDataStorage()

    private struct Key: Hashable {
        let sessionID: UUID
        let imageID: String
        let url: String

        init?(request: ImageRequest, sessionID: UUID) {
            guard let imageID = request.imageID, let url = request.urlRequest?.url?.absoluteString else { return nil }
            self.sessionID = sessionID
            self.imageID = imageID
            self.url = url
        }
    }

    private struct State {
        var entries: [Key: LinkedList<(Key, ResumableData)>.Node] = [:]
        let order = LinkedList<(Key, ResumableData)>()
        var totalCost = 0
    }

    private let state = LockIsolated(State())
    private let costLimit = Int(min(UInt64(Int.max), ProcessInfo.processInfo.physicalMemory / 100))
    private let countLimit = 100

    func removeResumableData(for request: ImageRequest, sessionID: UUID) -> ResumableData? {
        guard let key = Key(request: request, sessionID: sessionID) else { return nil }
        return state.withLock { state -> ResumableData? in
            guard let node = state.entries.removeValue(forKey: key) else { return nil }
            state.order.remove(node)
            state.totalCost -= node.value.1.data.count
            return node.value.1
        }
    }

    func storeResumableData(_ data: ResumableData, for request: ImageRequest, sessionID: UUID) {
        guard let key = Key(request: request, sessionID: sessionID) else { return }
        state.withLock { state in
            if let node = state.entries.removeValue(forKey: key) {
                state.order.remove(node)
                state.totalCost -= node.value.1.data.count
            }
            state.entries[key] = state.order.append((key, data))
            state.totalCost += data.data.count
            while state.totalCost > costLimit || state.entries.count > countLimit, let oldest = state.order.first {
                state.order.remove(oldest)
                state.entries[oldest.value.0] = nil
                state.totalCost -= oldest.value.1.data.count
            }
        }
    }

    func removeAll(sessionID: UUID) {
        state.withLock { state in
            for (key, node) in state.entries where key.sessionID == sessionID {
                state.entries[key] = nil
                state.order.remove(node)
                state.totalCost -= node.value.1.data.count
            }
        }
    }

    func removeAll() {
        state.withLock { state in
            state.entries.removeAll()
            state.order.removeAllElements()
            state.totalCost = 0
        }
    }
}
