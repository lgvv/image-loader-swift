import Foundation

@testable import ImageLoader

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    enum Step: Sendable {
        case response(statusCode: Int, headers: [String: String])
        case data(Data)
        case awaitAcknowledgements(Int)
        case finish
        case failure(URLError.Code)
        case redirect(to: URL, statusCode: Int)
        case hold
    }

    struct Record: Sendable {
        var requests: [URLRequest] = []
        var startCount = 0
        var stopCount = 0
        var sentChunkCount = 0
        var sentByteCount = 0
        var finishCount = 0
        var prefersIncrementalDelivery: [Bool] = []
    }

    private struct Gate {
        var acknowledged = 0
        var waiter: (target: Int, resume: @Sendable () -> Void)?
    }

    private static let stubs = LockIsolated<[String: [Step]]>([:])
    private static let records = LockIsolated<[String: Record]>([:])
    private static let gates = LockIsolated<[String: Gate]>([:])

    private let isStopped = LockIsolated(false)
    private let loadingRunLoop = LockIsolated<CFRunLoop?>(nil)

    static func uniqueURL(_ host: String = "loader.test", scheme: String = "https", path: String = "image.png") -> URL {
        URL(string: "\(scheme)://\(host)/\(UUID().uuidString)/\(path)")!
    }

    static func stub(_ url: URL, steps: [Step]) {
        stubs.withLock { $0[url.absoluteString] = steps }
    }

    static func stub(_ url: URL, statusCode: Int = 200, headers: [String: String] = [:], body: Data, chunkCount: Int = 1) {
        var headers = headers
        headers["Content-Length"] = "\(body.count)"
        var steps: [Step] = [.response(statusCode: statusCode, headers: headers)]
        steps += split(body, into: chunkCount).map { .data($0) }
        steps.append(.finish)
        stub(url, steps: steps)
    }

    static func pacedSteps(statusCode: Int = 200, body: Data, chunkCount: Int) -> [Step] {
        var steps: [Step] = [.response(statusCode: statusCode, headers: ["Content-Length": "\(body.count)"])]
        for (index, chunk) in split(body, into: chunkCount).enumerated() {
            if index > 0 {
                steps.append(.awaitAcknowledgements(index))
            }
            steps.append(.data(chunk))
        }
        steps.append(.finish)
        return steps
    }

    static func record(for url: URL) -> Record {
        records.withLock { $0[url.absoluteString] ?? Record() }
    }

    static func acknowledge(_ url: URL) {
        let key = url.absoluteString
        let resume = gates.withLock { gates -> (@Sendable () -> Void)? in
            var gate = gates[key, default: Gate()]
            gate.acknowledged += 1
            var resume: (@Sendable () -> Void)?
            if let waiter = gate.waiter, gate.acknowledged >= waiter.target {
                resume = waiter.resume
                gate.waiter = nil
            }
            gates[key] = gate
            return resume
        }
        resume?()
    }

    static func split(_ data: Data, into count: Int) -> [Data] {
        guard count > 1, data.count >= count else {
            return [data]
        }
        let size = Int((Double(data.count) / Double(count)).rounded(.up))
        return stride(from: 0, to: data.count, by: size).map { offset in
            data.subdata(in: offset..<min(data.count, offset + size))
        }
    }

    static func makeConfiguration(base: URLSessionConfiguration = DataLoader.defaultConfiguration) -> URLSessionConfiguration {
        base.urlCache = nil
        base.protocolClasses = [MockURLProtocol.self]
        return base
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        loadingRunLoop.withLock { $0 = CFRunLoopGetCurrent() }
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let key = url.absoluteString
        let request = request
        let prefersIncrementalDelivery = task?.prefersIncrementalDelivery ?? true
        Self.records.withLock { records in
            records[key, default: Record()].startCount += 1
            records[key, default: Record()].requests.append(request)
            records[key, default: Record()].prefersIncrementalDelivery.append(prefersIncrementalDelivery)
        }
        guard let steps = Self.stubs.withLock({ $0[key] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        run(steps, from: 0, url: url)
    }

    override func stopLoading() {
        isStopped.withLock { $0 = true }
        guard let key = request.url?.absoluteString else {
            return
        }
        Self.records.withLock { $0[key, default: Record()].stopCount += 1 }
    }

    private func run(_ steps: [Step], from start: Int, url: URL) {
        let key = url.absoluteString
        var index = start
        while index < steps.count {
            guard !isStopped.value else {
                return
            }
            switch steps[index] {
            case .response(let statusCode, let headers):
                let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            case .data(let data):
                Self.records.withLock { records in
                    records[key, default: Record()].sentChunkCount += 1
                    records[key, default: Record()].sentByteCount += data.count
                }
                client?.urlProtocol(self, didLoad: data)
            case .awaitAcknowledgements(let target):
                let next = index + 1
                let proceed = Self.gates.withLock { gates -> Bool in
                    if gates[key, default: Gate()].acknowledged >= target {
                        return true
                    }
                    gates[key, default: Gate()].waiter = (
                        target,
                        { [self] in
                            self.schedule(steps, from: next, url: url)
                        }
                    )
                    return false
                }
                guard proceed else {
                    return
                }
            case .finish:
                Self.records.withLock { $0[key, default: Record()].finishCount += 1 }
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let code):
                client?.urlProtocol(self, didFailWithError: URLError(code))
                return
            case .redirect(let target, let statusCode):
                let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
                var redirected = request
                redirected.url = target
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
                return
            case .hold:
                return
            }
            index += 1
        }
    }

    private func schedule(_ steps: [Step], from index: Int, url: URL) {
        guard let runLoop = loadingRunLoop.value else {
            return
        }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            self.run(steps, from: index, url: url)
        }
        CFRunLoopWakeUp(runLoop)
    }
}
