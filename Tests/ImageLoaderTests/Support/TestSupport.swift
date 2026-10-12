import Foundation
import ImageIO
import ImageLoaderTesting
import Testing
import UIKit

@testable import ImageLoader

enum Fixtures {
    static let url = URL(string: "https://example.com/image.png")!

    static func url(_ index: Int) -> URL {
        URL(string: "https://example.com/image-\(index).png")!
    }

    static func png(width: Int = 8, height: Int = 8, color: UIColor = .red) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.pngData()!
    }

    static let pngData = png()
}

func makeSession(
    loader: MockDataLoader,
    delegate: (any ImageSession.Delegate)? = nil,
    configure: (inout ImageSession.Configuration) -> Void = { _ in }
) -> ImageSession {
    var configuration = ImageSession.Configuration(dataLoader: loader)
    configuration.memoryCache = MemoryCache(costLimit: 64 * 1024 * 1024)
    configuration.isRateLimiterEnabled = false
    configure(&configuration)
    return ImageSession(configuration: configuration, delegate: delegate)
}

@discardableResult
func waitUntil(timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return condition()
}

func spinUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() {
            return true
        }
        usleep(200)
    }
    return condition()
}

func drainSessionQueue() {
    SessionQueue.sync {}
}

let enforcesTimingBudgets = ProcessInfo.processInfo.environment["CI"] == nil

func elapsedSeconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
}

func result(of task: ImageTask) async -> Result<ImageResponse, ImageSession.Error> {
    do {
        return .success(try await task.response)
    } catch {
        return .failure(error)
    }
}

final class Box<Value>: @unchecked Sendable {
    private let storage: LockIsolated<Value>

    init(_ value: Value) {
        storage = LockIsolated(value)
    }

    var value: Value {
        get { storage.value }
        set { storage.withLock { $0 = newValue } }
    }

    func mutate<T>(_ body: (inout Value) -> T) -> T {
        storage.withLock(body)
    }
}

final class RecordingDelegate: ImageSession.Delegate, @unchecked Sendable {
    let events = Box<[(UInt64, ImageTask.Event)]>([])
    let diagnostics = Box<[ImageSession.Diagnostic]>([])
    let createdTaskIDs = Box<[UInt64]>([])
    let headers: [String: String]
    let willLoadDataError: Swift.Error?

    init(headers: [String: String] = [:], willLoadDataError: Swift.Error? = nil) {
        self.headers = headers
        self.willLoadDataError = willLoadDataError
    }

    func imageTaskCreated(_ task: ImageTask, session: ImageSession) {
        createdTaskIDs.mutate { $0.append(task.taskId) }
    }

    func imageTask(_ task: ImageTask, didReceiveEvent event: ImageTask.Event, session: ImageSession) {
        events.mutate { $0.append((task.taskId, event)) }
    }

    func session(_ session: ImageSession, didRecord diagnostic: ImageSession.Diagnostic) {
        diagnostics.mutate { $0.append(diagnostic) }
    }

    func willLoadData(for request: ImageRequest, urlRequest: URLRequest, session: ImageSession) async throws -> URLRequest {
        if let willLoadDataError {
            throw willLoadDataError
        }
        var urlRequest = urlRequest
        for (name, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    func finishedEvents(for taskId: UInt64) -> [Result<ImageResponse, ImageSession.Error>] {
        events.value.compactMap { id, event in
            guard id == taskId, case .finished(let result) = event else { return nil }
            return result
        }
    }
}

final class CountingDecoder: ImageDecoding, @unchecked Sendable {
    let counter: Box<Int>

    init(counter: Box<Int>) {
        self.counter = counter
    }

    func decode(_ data: Data) throws -> ImageContent {
        counter.mutate { $0 += 1 }
        guard let image = UIImage(data: data) else {
            throw ImageDecodingError.unknown
        }
        return ImageContent(image: image, type: AssetType(data))
    }
}

final class InMemoryDiskCache: DiskCaching, @unchecked Sendable {
    let storage = Box<[String: Data]>([:])
    let readCount = Box(0)

    func cachedData(for key: String) -> Data? {
        readCount.mutate { $0 += 1 }
        return storage.value[key]
    }

    func containsData(for key: String) -> Bool {
        storage.value[key] != nil
    }

    func storeData(_ data: Data, for key: String) {
        storage.mutate { $0[key] = data }
    }

    func removeData(for key: String) {
        storage.mutate { $0[key] = nil }
    }

    func removeAll() {
        storage.mutate { $0.removeAll() }
    }
}

struct TintFilter: ImageFilter, Hashable {
    let name: String

    func process(_ image: UIImage) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(at: .zero)
        }
    }

    var identifier: String {
        "test/tint?\(name)"
    }
}

struct FailingFilter: ImageFilter, Hashable {
    func process(_ image: UIImage) -> UIImage? {
        nil
    }

    var identifier: String {
        "test/failing"
    }
}

extension ImageSession.Error {
    var caseName: String {
        switch self {
        case .dataMissingInCache: "dataMissingInCache"
        case .dataLoadingFailed: "dataLoadingFailed"
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
}
