import Foundation
import Testing
import UIKit

@testable import ImageLoader

private final class DataLoaderProbe: Sendable {
    let chunks = LockIsolated<[Data]>([])
    let events = LockIsolated<[String]>([])
    let errors = LockIsolated<[Swift.Error?]>([])

    var completionCount: Int {
        errors.withLock { $0.count }
    }

    var firstError: Swift.Error? {
        errors.withLock { $0.first ?? nil }
    }

    var receivedData: Data {
        chunks.withLock { $0.reduce(into: Data()) { $0.append($1) } }
    }

    func load(_ loader: DataLoader, _ request: URLRequest, acknowledging url: URL? = nil) -> any Cancellable {
        loader.loadData(
            with: request,
            didReceiveData: { [self] data, _ in
                let index = chunks.withLock { chunks -> Int in
                    chunks.append(data)
                    return chunks.count - 1
                }
                events.withLock { $0.append("chunk\(index)") }
                if let url {
                    MockURLProtocol.acknowledge(url)
                }
            },
            completion: { [self] error in
                events.withLock { $0.append("completion") }
                errors.withLock { $0.append(error) }
            })
    }

    func load(_ loader: DataLoader, _ url: URL, acknowledging: Bool = false) -> any Cancellable {
        load(loader, URLRequest(url: url), acknowledging: acknowledging ? url : nil)
    }
}

private final class ForwardingProbeDelegate: NSObject, URLSessionDataDelegate, Sendable {
    let redirectRequests = LockIsolated<[URLRequest]>([])
    let metricsCount = LockIsolated(0)
    let completedCount = LockIsolated(0)
    let receivedByteCount = LockIsolated(0)
    let responseStatusCodes = LockIsolated<[Int]>([])
    let createdTaskCount = LockIsolated(0)

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        redirectRequests.withLock { $0.append(request) }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        metricsCount.withLock { $0 += 1 }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Swift.Error?) {
        completedCount.withLock { $0 += 1 }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedByteCount.withLock { $0 += data.count }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        responseStatusCodes.withLock { $0.append((response as? HTTPURLResponse)?.statusCode ?? -1) }
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        createdTaskCount.withLock { $0 += 1 }
    }
}

private func drainDelegateQueue(_ loader: DataLoader) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        loader.session.delegateQueue.addOperation {
            continuation.resume()
        }
    }
}

private func statusCode(of error: Swift.Error?) -> Int? {
    guard case .statusCodeUnacceptable(let code) = error as? DataLoader.Error else {
        return nil
    }
    return code
}

private func injectedRequest(_ url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue("Bearer test-placeholder", forHTTPHeaderField: "Authorization")
    request.setValue("probe", forHTTPHeaderField: "X-Test-Probe")
    return request
}

private func makeLoaderSession(_ loader: DataLoader, configure: (inout ImageSession.Configuration) -> Void = { _ in }) -> ImageSession {
    var configuration = ImageSession.Configuration(dataLoader: loader)
    configuration.memoryCache = MemoryCache(costLimit: 16 * 1024 * 1024)
    configuration.isRateLimiterEnabled = false
    configuration.isResumableDataEnabled = false
    configure(&configuration)
    return ImageSession(configuration: configuration)
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else {
        return 0
    }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))
    return sorted[index]
}

private let isThreadSanitizerActive = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil

private func processCPUSeconds() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time)
    return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
}

@Suite("DataLoader: 기본값과 검증")
struct DataLoaderDefaultsTests {
    @Test("기본 설정은 쿠키를 끄고 전용 URLCache를 쓴다")
    func defaultConfiguration() {
        let configuration = DataLoader.defaultConfiguration
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCache === DataLoader.sharedUrlCache)
        #expect(DataLoader.sharedUrlCache.memoryCapacity == 0)
        #expect(DataLoader.sharedUrlCache.diskCapacity == 150 * 1024 * 1024)
        let loader = DataLoader()
        #expect(loader.session.configuration.httpCookieStorage == nil)
        #expect(loader.session.configuration.httpShouldSetCookies == false)
        #expect(loader.session.delegateQueue.maxConcurrentOperationCount == 1)
        #expect(loader.prefersIncrementalDelivery == false)
        #expect(loader.delegate == nil)
    }

    @Test("기본 validate는 2xx만 통과시키고 HTTP가 아닌 응답은 통과")
    func validate() {
        let url = MockURLProtocol.uniqueURL()
        func response(_ code: Int) -> URLResponse {
            HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
        }
        #expect(DataLoader.validate(response(200)) == nil)
        #expect(DataLoader.validate(response(299)) == nil)
        #expect(statusCode(of: DataLoader.validate(response(199))) == 199)
        #expect(statusCode(of: DataLoader.validate(response(304))) == 304)
        #expect(statusCode(of: DataLoader.validate(response(404))) == 404)
        let plain = URLResponse(url: url, mimeType: "image/png", expectedContentLength: 1, textEncodingName: nil)
        #expect(DataLoader.validate(plain) == nil)
        #expect(DataLoader.Error.statusCodeUnacceptable(404).description == "Response status code was unacceptable: 404")
    }

    @Test("리다이렉트 헤더 제거 판정: 호스트가 바뀌거나 https에서 내려갈 때만 제거")
    func stripRule() {
        func strips(_ original: String?, _ redirect: String?) -> Bool {
            DataLoader.shouldStripInjectedHeaders(from: original.flatMap(URL.init(string:)), to: redirect.flatMap(URL.init(string:)))
        }
        #expect(!strips("https://a.test/x", "https://a.test/y?z=1"))
        #expect(!strips("https://A.test/x", "https://a.TEST/y"))
        #expect(!strips("https://a.test/x", "https://a.test:443/y"))
        #expect(!strips("http://a.test/x", "https://a.test/x"))
        #expect(!strips("http://a.test/x", "HTTPS://a.test/x"))
        #expect(strips("https://a.test/x", "https://a.test:8443/x"))
        #expect(strips("http://a.test/x", "http://a.test:8080/x"))
        #expect(strips("https://a.test:8443/x", "https://a.test/x"))
        #expect(!strips("https://a.test:8443/x", "https://a.test:8443/y"))
        #expect(!strips("http://a.test:80/x", "https://a.test/x"))
        #expect(!strips("http://a.test/x", "http://a.test/y"))
        #expect(strips("https://a.test/x", "https://b.test/x"))
        #expect(strips("https://a.test/x", "https://sub.a.test/x"))
        #expect(strips("https://a.test/x", "https://a.test.evil.test/x"))
        #expect(strips("http://a.test/x", "https://b.test/x"))
        #expect(strips("https://a.test/x", "http://a.test/x"))
        #expect(strips("HTTPS://a.test/x", "http://a.test/x"))
        #expect(strips("https://a.test/x", "http://a.test:8443/x"))
        #expect(strips(nil, "https://a.test/x"))
        #expect(strips("https://a.test/x", nil))
        #expect(strips("https://a.test/x", "file:///x"))
    }

    @Test("리다이렉트 요청에서는 원래 요청이 가진 헤더 이름만 대소문자 무시로 지움")
    func redirectRequestRemovesOnlyOriginalHeaderNames() {
        var original = URLRequest(url: URL(string: "https://a.test/x")!)
        original.setValue("Bearer test-placeholder", forHTTPHeaderField: "authorization")
        original.setValue("probe", forHTTPHeaderField: "X-Test-Probe")
        var redirected = URLRequest(url: URL(string: "https://b.test/x")!)
        redirected.setValue("Bearer test-placeholder", forHTTPHeaderField: "Authorization")
        redirected.setValue("probe", forHTTPHeaderField: "x-test-probe")
        redirected.setValue("image/*", forHTTPHeaderField: "Accept")
        let stripped = DataLoader.redirectRequest(redirected, originalRequest: original)
        #expect(stripped.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(stripped.value(forHTTPHeaderField: "X-Test-Probe") == nil)
        #expect(stripped.value(forHTTPHeaderField: "Accept") == "image/*")
        #expect(stripped.url == redirected.url)

        var upgraded = redirected
        upgraded.url = URL(string: "HTTPS://A.test/y")
        var upgradedOriginal = original
        upgradedOriginal.url = URL(string: "http://a.test/x")
        #expect(DataLoader.redirectRequest(upgraded, originalRequest: upgradedOriginal) == upgraded)
        var otherPort = redirected
        otherPort.url = URL(string: "https://a.test:8443/y")
        #expect(DataLoader.redirectRequest(otherPort, originalRequest: original).value(forHTTPHeaderField: "Authorization") == nil)

        #expect(DataLoader.redirectRequest(redirected, originalRequest: nil) == redirected)
        #expect(DataLoader.redirectRequest(redirected, originalRequest: URLRequest(url: URL(string: "https://a.test/x")!)) == redirected)
    }

    @Test("판정은 원래 요청 기준이라 원래 호스트로 돌아오는 요청은 건드리지 않음 (상태 없음)")
    func redirectRuleIsStatelessAgainstOriginalRequest() {
        let original = injectedRequest(URL(string: "https://a.test/x")!)
        var back = injectedRequest(URL(string: "https://a.test/back")!)
        back.setValue("image/*", forHTTPHeaderField: "Accept")
        #expect(DataLoader.redirectRequest(back, originalRequest: original) == back)
        var away = back
        away.url = URL(string: "https://b.test/x")
        #expect(DataLoader.redirectRequest(away, originalRequest: original).value(forHTTPHeaderField: "Authorization") == nil)
    }
}

@Suite("DataLoader: URLProtocol 계약")
struct DataLoaderTests {
    @Test("404는 본문 전에 끊고 statusCodeUnacceptable(404)를 한 번만 전달")
    func notFoundCancelsBeforeBody() async {
        let url = MockURLProtocol.uniqueURL()
        MockURLProtocol.stub(
            url,
            steps: [
                .response(statusCode: 404, headers: ["Content-Length": "50000", "Content-Type": "image/png"]),
                .data(Data(repeating: 4, count: 1000)),
                .hold,
            ])
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let probe = DataLoaderProbe()
        _ = probe.load(loader, url)
        #expect(await waitUntil { probe.completionCount == 1 })
        #expect(await waitUntil { MockURLProtocol.record(for: url).stopCount == 1 })
        await drainDelegateQueue(loader)
        #expect(probe.completionCount == 1)
        #expect(statusCode(of: probe.firstError) == 404)
        #expect(probe.chunks.value.isEmpty)
        let record = MockURLProtocol.record(for: url)
        #expect(record.finishCount == 0)
        #expect(record.sentByteCount == 1000)
        #expect(loader.activeTaskCount == 0)
    }

    @Test("404 응답 뒤에 이미 도착한 본문도 전달하지 않음")
    func notFoundBodyIsNotDelivered() async {
        let url = MockURLProtocol.uniqueURL()
        MockURLProtocol.stub(url, statusCode: 404, body: Data(repeating: 7, count: 4096), chunkCount: 4)
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let probe = DataLoaderProbe()
        _ = probe.load(loader, url)
        #expect(await waitUntil { probe.completionCount == 1 })
        await drainDelegateQueue(loader)
        #expect(probe.completionCount == 1)
        #expect(statusCode(of: probe.firstError) == 404)
        #expect(probe.chunks.value.isEmpty)
    }

    @Test("200 분할 응답은 청크를 순서대로 전달한 뒤 완료를 한 번 부름")
    func chunksInOrderThenCompletionOnce() async {
        let url = MockURLProtocol.uniqueURL()
        let body = Data((0..<64000).map { UInt8($0 % 251) })
        MockURLProtocol.stub(url, steps: MockURLProtocol.pacedSteps(body: body, chunkCount: 8))
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let probe = DataLoaderProbe()
        _ = probe.load(loader, url, acknowledging: true)
        #expect(await waitUntil { probe.completionCount == 1 })
        await drainDelegateQueue(loader)
        #expect(probe.completionCount == 1)
        #expect(probe.firstError == nil)
        #expect(probe.chunks.value.count == 8)
        #expect(probe.receivedData == body)
        #expect(probe.events.value == (0..<8).map { "chunk\($0)" } + ["completion"])
        #expect(loader.activeTaskCount == 0)
    }

    @Test("취소하면 URLError.cancelled를 정확히 한 번 전달하고 URLSessionTask를 멈춤")
    func cancelYieldsCancelledOnce() async {
        let url = MockURLProtocol.uniqueURL()
        MockURLProtocol.stub(
            url,
            steps: [
                .response(statusCode: 200, headers: ["Content-Length": "100000"]),
                .data(Data(repeating: 1, count: 1000)),
                .hold,
            ])
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let probe = DataLoaderProbe()
        let cancellable = probe.load(loader, url)
        #expect(await waitUntil { probe.chunks.value.count == 1 })
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            cancellable.cancel()
        }
        #expect(await waitUntil { probe.completionCount == 1 })
        cancellable.cancel()
        await drainDelegateQueue(loader)
        #expect(probe.completionCount == 1)
        #expect((probe.firstError as? URLError)?.code == .cancelled)
        #expect(await waitUntil { MockURLProtocol.record(for: url).stopCount == 1 })
        #expect(MockURLProtocol.record(for: url).finishCount == 0)
        #expect(loader.activeTaskCount == 0)
    }

    @Test("응답 전에 취소해도 URLError.cancelled 한 번")
    func cancelBeforeResponse() async {
        let url = MockURLProtocol.uniqueURL()
        MockURLProtocol.stub(url, steps: [.hold])
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let probe = DataLoaderProbe()
        let cancellable = probe.load(loader, url)
        cancellable.cancel()
        #expect(await waitUntil { probe.completionCount == 1 })
        await drainDelegateQueue(loader)
        #expect(probe.completionCount == 1)
        #expect((probe.firstError as? URLError)?.code == .cancelled)
        #expect(probe.chunks.value.isEmpty)
    }

    @Test("전송 실패는 URLError 그대로 한 번 전달")
    func transportFailure() async {
        let url = MockURLProtocol.uniqueURL()
        MockURLProtocol.stub(url, steps: [.failure(.networkConnectionLost)])
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let probe = DataLoaderProbe()
        _ = probe.load(loader, url)
        #expect(await waitUntil { probe.completionCount == 1 })
        await drainDelegateQueue(loader)
        #expect(probe.completionCount == 1)
        #expect((probe.firstError as? URLError)?.code == .networkConnectionLost)
    }

    @Test("로더가 해제되면 진행 중인 작업을 취소하고 완료를 한 번 부름")
    func deinitCancelsInFlightTasks() async {
        let url = MockURLProtocol.uniqueURL()
        MockURLProtocol.stub(url, steps: [.hold])
        let probe = DataLoaderProbe()
        do {
            let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
            _ = probe.load(loader, url)
            #expect(await waitUntil { MockURLProtocol.record(for: url).startCount == 1 })
            #expect(loader.activeTaskCount == 1)
        }
        #expect(await waitUntil { probe.completionCount == 1 })
        #expect((probe.firstError as? URLError)?.code == .cancelled)
    }

    @Test("호스트가 바뀌는 리다이렉트는 원래 요청의 헤더를 모두 제거")
    func crossHostRedirectStripsHeaders() async {
        let first = MockURLProtocol.uniqueURL("one.test")
        let second = MockURLProtocol.uniqueURL("two.test")
        MockURLProtocol.stub(first, steps: [.redirect(to: second, statusCode: 302)])
        MockURLProtocol.stub(second, body: Data([1, 2, 3]))
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let probe = DataLoaderProbe()
        _ = probe.load(loader, injectedRequest(first))
        #expect(await waitUntil { probe.completionCount == 1 })
        #expect(probe.firstError == nil)
        #expect(probe.receivedData == Data([1, 2, 3]))
        #expect(MockURLProtocol.record(for: first).requests.first?.value(forHTTPHeaderField: "Authorization") != nil)
        let redirected = MockURLProtocol.record(for: second).requests
        #expect(redirected.count == 1)
        #expect(redirected.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(redirected.first?.value(forHTTPHeaderField: "X-Test-Probe") == nil)
    }

    @Test("같은 출처 리다이렉트에서 DataLoader 정책은 헤더를 지우지 않음 (실제 스택이 Authorization을 지우는 것은 루프백 테스트가 확인)")
    func sameOriginRedirectPolicyKeepsHeaders() async {
        let first = MockURLProtocol.uniqueURL("one.test")
        let second = URL(string: first.absoluteString.replacingOccurrences(of: "image.png", with: "moved.png"))!
        MockURLProtocol.stub(first, steps: [.redirect(to: second, statusCode: 301)])
        MockURLProtocol.stub(second, body: Data([4, 5]))
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let probe = DataLoaderProbe()
        _ = probe.load(loader, injectedRequest(first))
        #expect(await waitUntil { probe.completionCount == 1 })
        #expect(probe.firstError == nil)
        let redirected = MockURLProtocol.record(for: second).requests
        #expect(redirected.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-placeholder")
        #expect(redirected.first?.value(forHTTPHeaderField: "X-Test-Probe") == "probe")
    }

    @Test("https에서 http로 내려가는 리다이렉트는 같은 호스트라도 헤더를 제거")
    func downgradeRedirectStripsHeaders() async {
        let first = MockURLProtocol.uniqueURL("one.test")
        let second = URL(string: first.absoluteString.replacingOccurrences(of: "https://", with: "http://"))!
        MockURLProtocol.stub(first, steps: [.redirect(to: second, statusCode: 302)])
        MockURLProtocol.stub(second, body: Data([6]))
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let probe = DataLoaderProbe()
        _ = probe.load(loader, injectedRequest(first))
        #expect(await waitUntil { probe.completionCount == 1 })
        let redirected = MockURLProtocol.record(for: second).requests
        #expect(redirected.count == 1)
        #expect(redirected.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(redirected.first?.value(forHTTPHeaderField: "X-Test-Probe") == nil)
    }

    @Test("같은 호스트에서 http에서 https로 올라가는 리다이렉트에서 DataLoader 정책은 헤더를 지우지 않음")
    func sameHostUpgradeRedirectPolicyKeepsHeaders() async {
        let first = MockURLProtocol.uniqueURL("one.test", scheme: "http")
        let second = URL(string: first.absoluteString.replacingOccurrences(of: "http://", with: "https://"))!
        MockURLProtocol.stub(first, steps: [.redirect(to: second, statusCode: 301)])
        MockURLProtocol.stub(second, body: Data([6]))
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let probe = DataLoaderProbe()
        _ = probe.load(loader, injectedRequest(first))
        #expect(await waitUntil { probe.completionCount == 1 })
        #expect(probe.firstError == nil)
        let redirected = MockURLProtocol.record(for: second).requests
        #expect(redirected.count == 1)
        #expect(redirected.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-placeholder")
        #expect(redirected.first?.value(forHTTPHeaderField: "X-Test-Probe") == "probe")
    }

    @Test("같은 호스트에서 포트만 바뀌는 리다이렉트에서도 DataLoader 정책은 헤더를 지움")
    func portChangeRedirectPolicyStripsHeaders() async {
        let first = MockURLProtocol.uniqueURL("one.test")
        let second = URL(string: first.absoluteString.replacingOccurrences(of: "one.test", with: "one.test:8443"))!
        MockURLProtocol.stub(first, steps: [.redirect(to: second, statusCode: 302)])
        MockURLProtocol.stub(second, body: Data([6]))
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let probe = DataLoaderProbe()
        _ = probe.load(loader, injectedRequest(first))
        #expect(await waitUntil { probe.completionCount == 1 })
        #expect(probe.firstError == nil)
        let redirected = MockURLProtocol.record(for: second).requests
        #expect(redirected.count == 1)
        #expect(redirected.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(redirected.first?.value(forHTTPHeaderField: "X-Test-Probe") == nil)
    }

    @Test("https 포트 변경과 다운그레이드가 겹치면 제거")
    func downgradeWithPortChangeStripsHeaders() async {
        let first = MockURLProtocol.uniqueURL("one.test")
        let second = URL(
            string: first.absoluteString
                .replacingOccurrences(of: "https://one.test", with: "http://one.test:8080"))!
        MockURLProtocol.stub(first, steps: [.redirect(to: second, statusCode: 302)])
        MockURLProtocol.stub(second, body: Data([6]))
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let probe = DataLoaderProbe()
        _ = probe.load(loader, injectedRequest(first))
        #expect(await waitUntil { probe.completionCount == 1 })
        let redirected = MockURLProtocol.record(for: second).requests
        #expect(redirected.count == 1)
        #expect(redirected.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(redirected.first?.value(forHTTPHeaderField: "X-Test-Probe") == nil)
    }

    @Test("설정의 httpAdditionalHeaders는 요청마다 옮겨 싣고, 호스트가 바뀌는 리다이렉트에서 함께 제거")
    func configurationHeadersAreMovedIntoRequests() async {
        let first = MockURLProtocol.uniqueURL("one.test")
        let second = MockURLProtocol.uniqueURL("two.test")
        let override = MockURLProtocol.uniqueURL("one.test")
        MockURLProtocol.stub(first, steps: [.redirect(to: second, statusCode: 302)])
        MockURLProtocol.stub(second, body: Data([1]))
        MockURLProtocol.stub(override, body: Data([2]))
        let configuration = MockURLProtocol.makeConfiguration()
        configuration.httpAdditionalHeaders = ["X-Test-Config": "cfg", "Authorization": "Bearer cfg-placeholder"]
        let loader = DataLoader(configuration: configuration)
        #expect(configuration.httpAdditionalHeaders?.count == 2)
        #expect(loader.session.configuration.httpAdditionalHeaders == nil)

        let probe = DataLoaderProbe()
        _ = probe.load(loader, URLRequest(url: first))
        #expect(await waitUntil { probe.completionCount == 1 })
        #expect(probe.firstError == nil)
        let original = MockURLProtocol.record(for: first).requests.first
        #expect(original?.value(forHTTPHeaderField: "X-Test-Config") == "cfg")
        #expect(original?.value(forHTTPHeaderField: "Authorization") == "Bearer cfg-placeholder")
        let redirected = MockURLProtocol.record(for: second).requests
        #expect(redirected.count == 1)
        #expect(redirected.first?.value(forHTTPHeaderField: "X-Test-Config") == nil)
        #expect(redirected.first?.value(forHTTPHeaderField: "Authorization") == nil)

        var request = URLRequest(url: override)
        request.setValue("req", forHTTPHeaderField: "x-test-config")
        let overrideProbe = DataLoaderProbe()
        _ = overrideProbe.load(loader, request)
        #expect(await waitUntil { overrideProbe.completionCount == 1 })
        let sent = MockURLProtocol.record(for: override).requests.first
        #expect(sent?.value(forHTTPHeaderField: "X-Test-Config") == "req")
        #expect(sent?.value(forHTTPHeaderField: "Authorization") == "Bearer cfg-placeholder")
    }

    @Test("리다이렉트 체인에서 다른 호스트를 거쳐 원래 호스트로 돌아와도 지운 헤더를 되살리지 않음")
    func redirectChainDoesNotRestoreStrippedHeaders() async {
        let first = MockURLProtocol.uniqueURL("one.test")
        let second = MockURLProtocol.uniqueURL("two.test")
        let back = MockURLProtocol.uniqueURL("one.test", path: "back.png")
        MockURLProtocol.stub(first, steps: [.redirect(to: second, statusCode: 302)])
        MockURLProtocol.stub(second, steps: [.redirect(to: back, statusCode: 302)])
        MockURLProtocol.stub(back, body: Data([7, 8]))
        let delegate = ForwardingProbeDelegate()
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration(), delegate: delegate)
        let probe = DataLoaderProbe()
        _ = probe.load(loader, injectedRequest(first))
        #expect(await waitUntil { probe.completionCount == 1 })
        await drainDelegateQueue(loader)
        #expect(probe.firstError == nil)
        #expect(probe.receivedData == Data([7, 8]))
        #expect(MockURLProtocol.record(for: first).requests.first?.value(forHTTPHeaderField: "X-Test-Probe") == "probe")
        #expect(MockURLProtocol.record(for: second).requests.first?.value(forHTTPHeaderField: "X-Test-Probe") == nil)
        let returned = MockURLProtocol.record(for: back).requests
        #expect(returned.count == 1)
        #expect(returned.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(returned.first?.value(forHTTPHeaderField: "X-Test-Probe") == nil)
        let forwarded = delegate.redirectRequests.value
        #expect(forwarded.map(\.url) == [second, back])
        #expect(forwarded.allSatisfy { $0.value(forHTTPHeaderField: "X-Test-Probe") == nil })
    }

    @Test("사용자 delegate는 정책을 적용한 리다이렉트 요청과 메트릭, 데이터, 완료를 전달받음")
    func userDelegateForwarding() async {
        let first = MockURLProtocol.uniqueURL("one.test")
        let second = MockURLProtocol.uniqueURL("two.test")
        MockURLProtocol.stub(first, steps: [.redirect(to: second, statusCode: 302)])
        MockURLProtocol.stub(second, body: Data(repeating: 3, count: 300))
        let delegate = ForwardingProbeDelegate()
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration(), delegate: delegate)
        #expect(loader.delegate === delegate)
        let probe = DataLoaderProbe()
        _ = probe.load(loader, injectedRequest(first))
        #expect(await waitUntil { probe.completionCount == 1 })
        await drainDelegateQueue(loader)
        let redirects = delegate.redirectRequests.value
        #expect(redirects.count == 1)
        #expect(redirects.first?.url == second)
        #expect(redirects.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(delegate.receivedByteCount.value == 300)
        #expect(delegate.completedCount.value == 1)
        #expect(delegate.metricsCount.value == 1)
        #expect(delegate.responseStatusCodes.value == [200])
        #expect(probe.firstError == nil)
        #expect(probe.receivedData.count == 300)
        if #available(iOS 16.0, *) {
            #expect(delegate.createdTaskCount.value == 1)
        }
    }

    @Test("응답은 검증 전에 사용자 delegate로 한 번 전달하고, 진행 여부는 DataLoader가 정함")
    func responseIsForwardedBeforeValidation() async {
        let url = MockURLProtocol.uniqueURL()
        MockURLProtocol.stub(url, statusCode: 404, body: Data(repeating: 0, count: 2048))
        let delegate = ForwardingProbeDelegate()
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration(), delegate: delegate)
        let probe = DataLoaderProbe()
        _ = probe.load(loader, url)
        #expect(await waitUntil { probe.completionCount == 1 })
        #expect(await waitUntil { delegate.completedCount.value == 1 })
        await drainDelegateQueue(loader)
        #expect(delegate.responseStatusCodes.value == [404])
        #expect(statusCode(of: probe.firstError) == 404)
        #expect(probe.completionCount == 1)
        #expect(probe.chunks.value.isEmpty)
    }

    @Test("prefersIncrementalDelivery를 작업마다 적용 (기본 false)")
    func incrementalDeliveryIsAppliedPerTask() async {
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let first = MockURLProtocol.uniqueURL()
        let second = MockURLProtocol.uniqueURL()
        MockURLProtocol.stub(first, body: Data([1]))
        MockURLProtocol.stub(second, body: Data([2]))
        let firstProbe = DataLoaderProbe()
        _ = firstProbe.load(loader, first)
        #expect(await waitUntil { firstProbe.completionCount == 1 })
        loader.prefersIncrementalDelivery = true
        let secondProbe = DataLoaderProbe()
        _ = secondProbe.load(loader, second)
        #expect(await waitUntil { secondProbe.completionCount == 1 })
        #expect(MockURLProtocol.record(for: first).prefersIncrementalDelivery == [false])
        #expect(MockURLProtocol.record(for: second).prefersIncrementalDelivery == [true])
    }

    @Test("동시 100건(성공, 404, 실패, 즉시 취소)에서 완료는 작업마다 정확히 한 번")
    func completionExactlyOnceUnderConcurrency() async {
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let count = 100
        let body = Data(repeating: 5, count: 2048)
        let urls = (0..<count).map { MockURLProtocol.uniqueURL("h\($0).concurrent.test") }
        for (index, url) in urls.enumerated() {
            switch index % 4 {
            case 0:
                MockURLProtocol.stub(url, body: body, chunkCount: 2)
            case 1:
                MockURLProtocol.stub(url, statusCode: 404, body: body)
            case 2:
                MockURLProtocol.stub(url, steps: [.hold])
            default:
                MockURLProtocol.stub(url, steps: [.failure(.networkConnectionLost)])
            }
        }
        let completions = LockIsolated<[Int: [Swift.Error?]]>([:])
        let bytes = LockIsolated<[Int: Int]>([:])
        let cancellables = LockIsolated<[Int: any Cancellable]>([:])
        DispatchQueue.concurrentPerform(iterations: count) { index in
            let cancellable = loader.loadData(
                with: URLRequest(url: urls[index]),
                didReceiveData: { data, _ in
                    bytes.withLock { $0[index, default: 0] += data.count }
                },
                completion: { error in
                    completions.withLock { $0[index, default: []].append(error) }
                })
            cancellables.withLock { $0[index] = cancellable }
            if index % 4 == 2 {
                cancellable.cancel()
            }
        }
        #expect(await waitUntil(timeout: 20) { completions.withLock { $0.count } == count })
        let all = cancellables.withLock { Array($0.values) }
        DispatchQueue.concurrentPerform(iterations: all.count) { all[$0].cancel() }
        await drainDelegateQueue(loader)
        let results = completions.value
        #expect(results.values.allSatisfy { $0.count == 1 })
        for index in 0..<count {
            let error = results[index]?.first ?? nil
            switch index % 4 {
            case 0:
                #expect(error == nil)
                #expect(bytes.value[index] == body.count)
            case 1:
                #expect(statusCode(of: error) == 404)
                #expect(bytes.value[index] == nil)
            case 2:
                #expect((error as? URLError)?.code == .cancelled)
            default:
                #expect((error as? URLError)?.code == .networkConnectionLost)
            }
        }
        #expect(loader.activeTaskCount == 0)
    }
}

@Suite("DataLoader: 루프백 실제 HTTP 스택", .serialized)
struct DataLoaderLoopbackTests {
    private func makeServer() async throws -> (DataLoaderLoopbackServer, UInt16) {
        let server = try DataLoaderLoopbackServer()
        let port = try #require(await server.start())
        return (server, port)
    }

    private func load(_ loader: DataLoader, _ request: URLRequest) async -> DataLoaderProbe {
        let probe = DataLoaderProbe()
        _ = probe.load(loader, request)
        #expect(await waitUntil(timeout: 10) { probe.completionCount == 1 })
        return probe
    }

    private func controlConfiguration(storage: HTTPCookieStorage?) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        if let storage {
            configuration.httpCookieStorage = storage
        }
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.urlCache = nil
        return configuration
    }

    @Test("Set-Cookie 응답은 어떤 쿠키 저장소에도 들어가지 않고 다음 요청에 Cookie 헤더가 없음 (대조군 포함)")
    func cookiesAreNeitherStoredNorSent() async throws {
        let (server, port) = try await makeServer()
        let cookieName = "imageloader_probe_\(UUID().uuidString.prefix(8))"
        server.route("/set", .init(statusCode: 200, headers: ["Set-Cookie": "\(cookieName)=1; Path=/"], body: Data([1])))
        server.route("/echo", .init(statusCode: 200, body: Data([2])))
        server.route("/control-echo", .init(statusCode: 200, body: Data([3])))
        let base = "http://127.0.0.1:\(port)"

        let control = DataLoader(configuration: controlConfiguration(storage: nil))
        #expect(await load(control, URLRequest(url: URL(string: "\(base)/set")!)).firstError == nil)
        #expect(await load(control, URLRequest(url: URL(string: "\(base)/control-echo")!)).firstError == nil)
        let controlCookie = server.requests(path: "/control-echo").first?.headers["cookie"]
        try #require(controlCookie?.contains(cookieName) == true, "대조군에서 쿠키가 동작하지 않으면 이 테스트는 의미가 없음")

        let loader = DataLoader()
        let setProbe = await load(loader, URLRequest(url: URL(string: "\(base)/set")!))
        #expect(setProbe.firstError == nil)
        #expect(setProbe.receivedData == Data([1]))
        let echoProbe = await load(loader, URLRequest(url: URL(string: "\(base)/echo")!))
        #expect(echoProbe.firstError == nil)
        let echoed = server.requests(path: "/echo")
        #expect(echoed.count == 1)
        #expect(echoed.first?.headers["cookie"] == nil)
        let url = URL(string: "\(base)/")!
        #expect((HTTPCookieStorage.shared.cookies(for: url) ?? []).allSatisfy { $0.name != cookieName })
        #expect(loader.session.configuration.httpCookieStorage == nil)
    }

    @Test("공유 쿠키 저장소에 쿠키가 있어도 요청에 싣지 않음 (대조군 포함)")
    func sharedStorageCookiesAreNotSent() async throws {
        let (server, port) = try await makeServer()
        server.route("/control", .init(statusCode: 200, body: Data([1])))
        server.route("/default", .init(statusCode: 200, body: Data([2])))
        let cookieName = "imageloader_seed_\(UUID().uuidString.prefix(8))"
        let cookie = try #require(
            HTTPCookie(properties: [
                .domain: "127.0.0.1",
                .path: "/",
                .name: cookieName,
                .value: "placeholder",
            ]))
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        let base = "http://127.0.0.1:\(port)"

        let control = DataLoader(configuration: controlConfiguration(storage: HTTPCookieStorage.shared))
        #expect(await load(control, URLRequest(url: URL(string: "\(base)/control")!)).firstError == nil)
        let controlCookie = server.requests(path: "/control").first?.headers["cookie"]
        try #require(controlCookie?.contains(cookieName) == true, "대조군에서 공유 쿠키가 실리지 않으면 이 테스트는 의미가 없음")

        let loader = DataLoader()
        #expect(await load(loader, URLRequest(url: URL(string: "\(base)/default")!)).firstError == nil)
        let sent = server.requests(path: "/default")
        #expect(sent.count == 1)
        #expect(sent.first?.headers["cookie"] == nil)
    }

    @Test("실제 HTTP 리다이렉트: 호스트가 바뀌면 헤더 제거, 같은 출처면 Authorization 말고는 유지")
    func realRedirects() async throws {
        let (server, port) = try await makeServer()
        server.route("/cross", .init(statusCode: 302, headers: ["Location": "http://localhost:\(port)/cross-target"]))
        server.route("/cross-target", .init(statusCode: 200, body: Data([1])))
        server.route("/same", .init(statusCode: 302, headers: ["Location": "http://127.0.0.1:\(port)/same-target"]))
        server.route("/same-target", .init(statusCode: 200, body: Data([2])))
        let loader = DataLoader(
            configuration: {
                let configuration = DataLoader.defaultConfiguration
                configuration.urlCache = nil
                return configuration
            }())

        let cross = await load(loader, injectedRequest(URL(string: "http://127.0.0.1:\(port)/cross")!))
        #expect(cross.firstError == nil)
        #expect(cross.receivedData == Data([1]))
        #expect(server.requests(path: "/cross").first?.headers["x-test-probe"] == "probe")
        let crossTarget = server.requests(path: "/cross-target")
        #expect(crossTarget.count == 1)
        #expect(crossTarget.first?.headers["x-test-probe"] == nil)
        #expect(crossTarget.first?.headers["authorization"] == nil)

        let same = await load(loader, injectedRequest(URL(string: "http://127.0.0.1:\(port)/same")!))
        #expect(same.firstError == nil)
        let sameTarget = server.requests(path: "/same-target")
        #expect(sameTarget.count == 1)
        #expect(sameTarget.first?.headers["x-test-probe"] == "probe")
        #expect(sameTarget.first?.headers["authorization"] == nil)
    }

    @Test("실제 HTTP 리다이렉트: 설정의 httpAdditionalHeaders도 다른 호스트로 새지 않음")
    func realRedirectsWithConfigurationHeaders() async throws {
        let (server, port) = try await makeServer()
        server.route("/cfg-cross", .init(statusCode: 302, headers: ["Location": "http://localhost:\(port)/cfg-cross-target"]))
        server.route("/cfg-cross-target", .init(statusCode: 200, body: Data([1])))
        server.route("/cfg-same", .init(statusCode: 302, headers: ["Location": "http://127.0.0.1:\(port)/cfg-same-target"]))
        server.route("/cfg-same-target", .init(statusCode: 200, body: Data([2])))
        let loader = DataLoader(
            configuration: {
                let configuration = DataLoader.defaultConfiguration
                configuration.urlCache = nil
                configuration.httpAdditionalHeaders = ["X-Test-Config": "cfg", "Authorization": "Bearer cfg-placeholder"]
                return configuration
            }())

        let cross = await load(loader, URLRequest(url: URL(string: "http://127.0.0.1:\(port)/cfg-cross")!))
        #expect(cross.firstError == nil)
        #expect(cross.receivedData == Data([1]))
        let crossOrigin = server.requests(path: "/cfg-cross").first
        #expect(crossOrigin?.headers["x-test-config"] == "cfg")
        #expect(crossOrigin?.headers["authorization"] == "Bearer cfg-placeholder")
        let crossTarget = server.requests(path: "/cfg-cross-target")
        #expect(crossTarget.count == 1)
        #expect(crossTarget.first?.headers["x-test-config"] == nil)
        #expect(crossTarget.first?.headers["authorization"] == nil)

        let same = await load(loader, URLRequest(url: URL(string: "http://127.0.0.1:\(port)/cfg-same")!))
        #expect(same.firstError == nil)
        #expect(same.receivedData == Data([2]))
        let sameTarget = server.requests(path: "/cfg-same-target")
        #expect(sameTarget.count == 1)
        #expect(sameTarget.first?.headers["x-test-config"] == "cfg")
        #expect(sameTarget.first?.headers["authorization"] == nil)
    }

    @Test("실제 HTTP 리다이렉트 체인: 다른 호스트를 거쳐 원래 호스트로 돌아와도 지운 헤더가 되살아나지 않음")
    func realRedirectChain() async throws {
        let (server, port) = try await makeServer()
        server.route("/chain-1", .init(statusCode: 302, headers: ["Location": "http://localhost:\(port)/chain-2"]))
        server.route("/chain-2", .init(statusCode: 302, headers: ["Location": "http://127.0.0.1:\(port)/chain-3"]))
        server.route("/chain-3", .init(statusCode: 200, body: Data([3])))
        let loader = DataLoader(
            configuration: {
                let configuration = DataLoader.defaultConfiguration
                configuration.urlCache = nil
                return configuration
            }())
        let probe = await load(loader, injectedRequest(URL(string: "http://127.0.0.1:\(port)/chain-1")!))
        #expect(probe.firstError == nil)
        #expect(probe.receivedData == Data([3]))
        #expect(server.requests(path: "/chain-1").first?.headers["x-test-probe"] == "probe")
        #expect(server.requests(path: "/chain-2").count == 1)
        #expect(server.requests(path: "/chain-2").first?.headers["x-test-probe"] == nil)
        let back = server.requests(path: "/chain-3")
        #expect(back.count == 1)
        #expect(back.first?.headers["x-test-probe"] == nil)
        #expect(back.first?.headers["authorization"] == nil)
    }

    @Test("실제 HTTP 리다이렉트: 같은 호스트에서 포트만 바뀌어도 헤더 제거")
    func realPortChangeRedirectStripsHeaders() async throws {
        let (origin, originPort) = try await makeServer()
        let (target, targetPort) = try await makeServer()
        origin.route("/port", .init(statusCode: 302, headers: ["Location": "http://127.0.0.1:\(targetPort)/port-target"]))
        target.route("/port-target", .init(statusCode: 200, body: Data([4])))
        let loader = DataLoader(
            configuration: {
                let configuration = DataLoader.defaultConfiguration
                configuration.urlCache = nil
                return configuration
            }())
        let probe = await load(loader, injectedRequest(URL(string: "http://127.0.0.1:\(originPort)/port")!))
        #expect(probe.firstError == nil)
        #expect(probe.receivedData == Data([4]))
        let received = target.requests(path: "/port-target")
        #expect(received.count == 1)
        #expect(received.first?.headers["x-test-probe"] == nil)
    }

    @Test("실제 HTTP 401 Basic 챌린지: task 수준 사용자 delegate만 받고, 세션 수준만 구현하면 기본 처리")
    func realBasicChallengeRouting() async throws {
        let (server, port) = try await makeServer()
        server.route("/basic", .init(statusCode: 401, headers: ["WWW-Authenticate": "Basic realm=\"imageloader-test\""], body: Data([0])))
        func configuration() -> URLSessionConfiguration {
            let configuration = DataLoader.defaultConfiguration
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            return configuration
        }
        let url = URL(string: "http://127.0.0.1:\(port)/basic")!

        let plain = await load(DataLoader(configuration: configuration()), URLRequest(url: url))
        #expect(plain.completionCount == 1)
        #expect(statusCode(of: plain.firstError) == 401)

        let sessionRecorder = LockIsolated<[String]>([])
        let sessionOnly = await load(DataLoader(configuration: configuration(), delegate: SessionChallengeDelegate(recorder: sessionRecorder)), URLRequest(url: url))
        #expect(sessionOnly.completionCount == 1)
        #expect(statusCode(of: sessionOnly.firstError) == 401)
        #expect(sessionRecorder.value.isEmpty)

        let taskRecorder = LockIsolated<[String]>([])
        let taskLevel = await load(DataLoader(configuration: configuration(), delegate: TaskChallengeDelegate(recorder: taskRecorder)), URLRequest(url: url))
        #expect(taskLevel.completionCount == 1)
        #expect(taskRecorder.value.first == "task:\(NSURLAuthenticationMethodHTTPBasic)")
        print(
            "INFO|loopback.basicChallenge|plain=\(String(describing: plain.firstError))|taskDelegateCalls=\(taskRecorder.value.count)|taskDelegateOutcome=\(String(describing: taskLevel.firstError))"
        )
    }

    @Test("실제 HTTP 404: statusCodeUnacceptable(404), 본문 청크 0개")
    func realNotFound() async throws {
        let (server, port) = try await makeServer()
        server.route("/missing", .init(statusCode: 404, body: Data(repeating: 9, count: 256 * 1024)))
        let loader = DataLoader(
            configuration: {
                let configuration = DataLoader.defaultConfiguration
                configuration.urlCache = nil
                return configuration
            }())
        let probe = await load(loader, URLRequest(url: URL(string: "http://127.0.0.1:\(port)/missing")!))
        await drainDelegateQueue(loader)
        #expect(probe.completionCount == 1)
        #expect(statusCode(of: probe.firstError) == 404)
        #expect(probe.chunks.value.isEmpty)
    }
}

private final class DataLoaderChallengeSender: NSObject, URLAuthenticationChallengeSender, Sendable {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

private final class SessionChallengeDelegate: NSObject, URLSessionDelegate, Sendable {
    let recorder: LockIsolated<[String]>

    init(recorder: LockIsolated<[String]>) {
        self.recorder = recorder
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        recorder.withLock { $0.append("session:\(challenge.protectionSpace.authenticationMethod)") }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

private final class TaskChallengeDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let recorder: LockIsolated<[String]>

    init(recorder: LockIsolated<[String]>) {
        self.recorder = recorder
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        recorder.withLock { $0.append("task:\(challenge.protectionSpace.authenticationMethod)") }
        completionHandler(.rejectProtectionSpace, nil)
    }
}

private final class SessionAndTaskChallengeDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let recorder: LockIsolated<[String]>

    init(recorder: LockIsolated<[String]>) {
        self.recorder = recorder
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        recorder.withLock { $0.append("session:\(challenge.protectionSpace.authenticationMethod)") }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        recorder.withLock { $0.append("task:\(challenge.protectionSpace.authenticationMethod)") }
        completionHandler(.rejectProtectionSpace, nil)
    }
}

private final class AuxiliaryForwardingDelegate: NSObject, URLSessionDataDelegate, Sendable {
    let events = LockIsolated<[String]>([])

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        events.withLock { $0.append("waiting") }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willBeginDelayedRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLSession.DelayedRequestDisposition, URLRequest?) -> Void
    ) {
        events.withLock { $0.append("delayed") }
        var replaced = request
        replaced.setValue("1", forHTTPHeaderField: "X-Test-Delayed")
        completionHandler(.useNewRequest, replaced)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
    ) {
        events.withLock { $0.append("cache") }
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Swift.Error?) {
        events.withLock { $0.append("invalid") }
    }
}

private enum ChallengeRouting {
    static let sessionLevelMethods = [
        NSURLAuthenticationMethodServerTrust,
        NSURLAuthenticationMethodClientCertificate,
        NSURLAuthenticationMethodNTLM,
        NSURLAuthenticationMethodNegotiate,
    ]

    static let taskLevelMethods = [
        NSURLAuthenticationMethodHTTPBasic,
        NSURLAuthenticationMethodHTTPDigest,
        NSURLAuthenticationMethodHTMLForm,
        NSURLAuthenticationMethodDefault,
    ]

    static func challenge(_ method: String) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(host: "challenge.test", port: 443, protocol: NSURLProtectionSpaceHTTPS, realm: nil, authenticationMethod: method)
        return URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: DataLoaderChallengeSender()
        )
    }

    static func dispositions(_ loader: DataLoader, methods: [String]) throws -> [URLSession.AuthChallengeDisposition?] {
        let delegate = try #require(loader.session.delegate as? any URLSessionTaskDelegate)
        let task = loader.session.dataTask(with: MockURLProtocol.uniqueURL("challenge.test"))
        return methods.map { method in
            let result = LockIsolated<URLSession.AuthChallengeDisposition?>(nil)
            delegate.urlSession?(
                loader.session, task: task, didReceive: challenge(method),
                completionHandler: { disposition, _ in
                    result.withLock { $0 = disposition }
                })
            return result.value
        }
    }
}

@Suite("DataLoader: 인증 챌린지와 기타 delegate 전달")
struct DataLoaderDelegateRoutingTests {
    @Test("사용자 delegate가 없으면 모든 챌린지를 performDefaultHandling으로 처리")
    func noDelegateUsesDefaultHandling() throws {
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let methods = ChallengeRouting.sessionLevelMethods + ChallengeRouting.taskLevelMethods
        let dispositions = try ChallengeRouting.dispositions(loader, methods: methods)
        #expect(dispositions == Array(repeating: .performDefaultHandling, count: methods.count))
    }

    @Test("세션 수준 메서드만 구현한 delegate는 ServerTrust, ClientCertificate, NTLM, Negotiate만 받음")
    func sessionOnlyDelegateReceivesSessionLevelChallenges() throws {
        let recorder = LockIsolated<[String]>([])
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration(), delegate: SessionChallengeDelegate(recorder: recorder))
        let sessionLevel = try ChallengeRouting.dispositions(loader, methods: ChallengeRouting.sessionLevelMethods)
        #expect(sessionLevel == Array(repeating: .cancelAuthenticationChallenge, count: ChallengeRouting.sessionLevelMethods.count))
        let taskLevel = try ChallengeRouting.dispositions(loader, methods: ChallengeRouting.taskLevelMethods)
        #expect(taskLevel == Array(repeating: .performDefaultHandling, count: ChallengeRouting.taskLevelMethods.count))
        #expect(recorder.value == ChallengeRouting.sessionLevelMethods.map { "session:\($0)" })
    }

    @Test("task 수준 메서드만 구현한 delegate는 모든 챌린지를 받음")
    func taskOnlyDelegateReceivesEveryChallenge() throws {
        let recorder = LockIsolated<[String]>([])
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration(), delegate: TaskChallengeDelegate(recorder: recorder))
        let methods = ChallengeRouting.sessionLevelMethods + ChallengeRouting.taskLevelMethods
        let dispositions = try ChallengeRouting.dispositions(loader, methods: methods)
        #expect(dispositions == Array(repeating: .rejectProtectionSpace, count: methods.count))
        #expect(recorder.value == methods.map { "task:\($0)" })
    }

    @Test("둘 다 구현하면 URLSession처럼 세션 수준 챌린지는 세션 메서드, 나머지는 task 메서드로")
    func bothLevelsFollowURLSessionRouting() throws {
        let recorder = LockIsolated<[String]>([])
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration(), delegate: SessionAndTaskChallengeDelegate(recorder: recorder))
        let sessionLevel = try ChallengeRouting.dispositions(loader, methods: ChallengeRouting.sessionLevelMethods)
        #expect(sessionLevel == Array(repeating: .cancelAuthenticationChallenge, count: ChallengeRouting.sessionLevelMethods.count))
        let taskLevel = try ChallengeRouting.dispositions(loader, methods: ChallengeRouting.taskLevelMethods)
        #expect(taskLevel == Array(repeating: .rejectProtectionSpace, count: ChallengeRouting.taskLevelMethods.count))
        #expect(recorder.value == ChallengeRouting.sessionLevelMethods.map { "session:\($0)" } + ChallengeRouting.taskLevelMethods.map { "task:\($0)" })
    }

    @Test("지연 요청은 기본 continueLoading, 사용자 delegate가 있으면 그 결정을 따름")
    func delayedRequestRouting() throws {
        let request = URLRequest(url: MockURLProtocol.uniqueURL("delayed.test"))
        func decide(_ loader: DataLoader) throws -> (URLSession.DelayedRequestDisposition, URLRequest?)? {
            let delegate = try #require(loader.session.delegate as? any URLSessionTaskDelegate)
            let task = loader.session.dataTask(with: request)
            let result = LockIsolated<(URLSession.DelayedRequestDisposition, URLRequest?)?>(nil)
            delegate.urlSession?(
                loader.session, task: task, willBeginDelayedRequest: request,
                completionHandler: { disposition, replaced in
                    result.withLock { $0 = (disposition, replaced) }
                })
            return result.value
        }
        let plain = try #require(try decide(DataLoader(configuration: MockURLProtocol.makeConfiguration())))
        #expect(plain.0 == .continueLoading)
        #expect(plain.1 == nil)
        let user = AuxiliaryForwardingDelegate()
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration(), delegate: user)
        let forwarded = try #require(try decide(loader))
        withExtendedLifetime(loader) {
            #expect(forwarded.0 == .useNewRequest)
            #expect(forwarded.1?.value(forHTTPHeaderField: "X-Test-Delayed") == "1")
            #expect(user.events.value == ["delayed"])
        }
    }

    @Test("연결 대기, 캐시 저장 결정, 세션 무효화를 사용자 delegate로 전달하고 없으면 기본값")
    func auxiliaryCallbacksAreForwarded() throws {
        let url = MockURLProtocol.uniqueURL("aux.test")
        let proposed = CachedURLResponse(
            response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
            data: Fixtures.pngData
        )
        let nonImage = CachedURLResponse(
            response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!,
            data: Data("<html></html>".utf8)
        )
        func run(_ loader: DataLoader) throws -> CachedURLResponse? {
            let delegate = try #require(loader.session.delegate as? any URLSessionDataDelegate)
            let task = loader.session.dataTask(with: url)
            delegate.urlSession?(loader.session, taskIsWaitingForConnectivity: task)
            let cached = LockIsolated<CachedURLResponse??>(nil)
            delegate.urlSession?(
                loader.session, dataTask: task, willCacheResponse: proposed,
                completionHandler: { response in
                    cached.withLock { $0 = .some(response) }
                })
            delegate.urlSession?(loader.session, didBecomeInvalidWithError: nil)
            return try #require(cached.value)
        }
        let plain = try run(DataLoader(configuration: MockURLProtocol.makeConfiguration()))
        #expect(plain === proposed)
        let plainLoader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let plainDelegate = try #require(plainLoader.session.delegate as? any URLSessionDataDelegate)
        let dropped = LockIsolated<CachedURLResponse??>(nil)
        plainDelegate.urlSession?(
            plainLoader.session, dataTask: plainLoader.session.dataTask(with: url), willCacheResponse: nonImage,
            completionHandler: { response in
                dropped.withLock { $0 = .some(response) }
            })
        #expect(dropped.value == .some(nil))
        let user = AuxiliaryForwardingDelegate()
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration(), delegate: user)
        let forwarded = try run(loader)
        withExtendedLifetime(loader) {
            #expect(forwarded == nil)
            #expect(user.events.value == ["waiting", "cache", "invalid"])
        }
    }
}

@Suite("DataLoader: 파이프라인 통합")
struct DataLoaderSessionTests {
    @Test("실제 DataLoader로 PNG를 받아 디코딩")
    func loadsPNG() async throws {
        let url = MockURLProtocol.uniqueURL()
        MockURLProtocol.stub(url, headers: ["Content-Type": "image/png"], body: Fixtures.png(width: 12, height: 10), chunkCount: 3)
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let session = makeLoaderSession(loader)
        let image = try await session.image(for: url)
        #expect(image.size == CGSize(width: 12, height: 10))
        #expect(MockURLProtocol.record(for: url).startCount == 1)
        #expect(await waitUntil { loader.activeTaskCount == 0 })
    }

    @Test("Content-Length가 maximumResponseDataSize를 넘으면 dataDownloadExceededMaximumSize이고 URLSessionTask를 취소")
    func exceedsMaximumSizeByContentLength() async {
        let url = MockURLProtocol.uniqueURL()
        MockURLProtocol.stub(
            url,
            steps: [
                .response(statusCode: 200, headers: ["Content-Length": "100000"]),
                .data(Data(repeating: 1, count: 1000)),
                .hold,
            ])
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let session = makeLoaderSession(loader) { $0.maximumResponseDataSize = 10000 }
        let outcome = await result(of: session.imageTask(with: url))
        #expect(outcome.failureValue?.caseName == "dataDownloadExceededMaximumSize")
        #expect(await waitUntil { MockURLProtocol.record(for: url).stopCount == 1 })
        #expect(await waitUntil { loader.activeTaskCount == 0 })
        let record = MockURLProtocol.record(for: url)
        #expect(record.finishCount == 0)
        #expect(record.sentByteCount < 100000)
    }

    @Test("Content-Length 없이 누적 바이트가 상한을 넘어도 URLSessionTask를 취소")
    func exceedsMaximumSizeCumulatively() async {
        let url = MockURLProtocol.uniqueURL()
        MockURLProtocol.stub(
            url,
            steps: [
                .response(statusCode: 200, headers: [:]),
                .data(Data(repeating: 1, count: 6000)),
                .data(Data(repeating: 2, count: 6000)),
                .hold,
            ])
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let session = makeLoaderSession(loader) { $0.maximumResponseDataSize = 10000 }
        let outcome = await result(of: session.imageTask(with: url))
        #expect(outcome.failureValue?.caseName == "dataDownloadExceededMaximumSize")
        #expect(await waitUntil { MockURLProtocol.record(for: url).stopCount == 1 })
        #expect(await waitUntil { loader.activeTaskCount == 0 })
        #expect(MockURLProtocol.record(for: url).finishCount == 0)
    }

    @Test("404는 dataLoadingFailed이고 statusCode 404")
    func notFoundSurfacesStatusCode() async {
        let url = MockURLProtocol.uniqueURL()
        MockURLProtocol.stub(url, statusCode: 404, body: Data(repeating: 0, count: 512))
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let session = makeLoaderSession(loader)
        let error = await result(of: session.imageTask(with: url)).failureValue
        #expect(error?.caseName == "dataLoadingFailed")
        #expect(error?.statusCode == 404)
        #expect(error?.dataLoadingError is DataLoader.Error)
    }

    @Test("ImageTask를 취소하면 URLSessionTask도 취소")
    func cancellingImageTaskCancelsSessionTask() async {
        let url = MockURLProtocol.uniqueURL()
        MockURLProtocol.stub(
            url,
            steps: [
                .response(statusCode: 200, headers: ["Content-Length": "100000"]),
                .data(Data(repeating: 1, count: 1000)),
                .hold,
            ])
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let session = makeLoaderSession(loader)
        let task = session.imageTask(with: url)
        #expect(await waitUntil { MockURLProtocol.record(for: url).sentChunkCount == 1 })
        task.cancel()
        #expect(await result(of: task).failureValue?.caseName == "cancelled")
        #expect(await waitUntil { MockURLProtocol.record(for: url).stopCount == 1 })
        #expect(await waitUntil { loader.activeTaskCount == 0 })
        #expect(MockURLProtocol.record(for: url).finishCount == 0)
    }

    @Test("willLoadData가 붙인 헤더는 다른 호스트로 리다이렉트될 때 제거")
    func delegateHeadersAreStrippedOnCrossHostRedirect() async throws {
        let first = MockURLProtocol.uniqueURL("one.test")
        let second = MockURLProtocol.uniqueURL("two.test")
        MockURLProtocol.stub(first, steps: [.redirect(to: second, statusCode: 302)])
        MockURLProtocol.stub(second, body: Fixtures.png())
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        var configuration = ImageSession.Configuration(dataLoader: loader)
        configuration.memoryCache = MemoryCache(costLimit: 16 * 1024 * 1024)
        configuration.isRateLimiterEnabled = false
        let session = ImageSession(configuration: configuration, delegate: RecordingDelegate(headers: ["Authorization": "Bearer test-placeholder"]))
        _ = try await session.image(for: first)
        #expect(MockURLProtocol.record(for: first).requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-placeholder")
        #expect(MockURLProtocol.record(for: second).requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }
}

@Suite("DataLoaderBenchmarks", .serialized, .enabled(if: !isThreadSanitizerActive, "ThreadSanitizer 계측에서는 시간 기준을 판정하지 않음"))
struct DataLoaderBenchmarks {
    @Test("작은 응답 200건 순차/동시 로드 비용")
    func loadThroughput() async {
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let body = Data(repeating: 1, count: 4096)
        let count = 200
        let sequentialURLs = (0..<count).map { _ in MockURLProtocol.uniqueURL("bench.test") }
        let concurrentURLs = (0..<count).map { _ in MockURLProtocol.uniqueURL("bench.test") }
        for url in sequentialURLs + concurrentURLs {
            MockURLProtocol.stub(url, body: body)
        }
        let cpuStart = processCPUSeconds()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        for url in sequentialURLs {
            let probe = DataLoaderProbe()
            _ = probe.load(loader, url)
            #expect(await waitUntil(timeout: 10) { probe.completionCount == 1 })
        }
        let sequentialWall = elapsedSeconds(since: wallStart)
        let sequentialCPU = processCPUSeconds() - cpuStart
        let done = LockIsolated(0)
        let concurrentCPUStart = processCPUSeconds()
        let concurrentStart = DispatchTime.now().uptimeNanoseconds
        for url in concurrentURLs {
            _ = loader.loadData(
                with: URLRequest(url: url), didReceiveData: { _, _ in },
                completion: { _ in
                    done.withLock { $0 += 1 }
                })
        }
        #expect(await waitUntil(timeout: 30) { done.value == count })
        let concurrentWall = elapsedSeconds(since: concurrentStart)
        let concurrentCPU = processCPUSeconds() - concurrentCPUStart
        print(
            "BENCH|loader.sequential|count=\(count)|wall_ms_per_load=\(String(format: "%.3f", sequentialWall * 1000 / Double(count)))|cpu_ms_per_load=\(String(format: "%.3f", sequentialCPU * 1000 / Double(count)))"
        )
        print(
            "BENCH|loader.concurrent|count=\(count)|wall_ms_total=\(String(format: "%.1f", concurrentWall * 1000))|cpu_ms_per_load=\(String(format: "%.3f", concurrentCPU * 1000 / Double(count)))"
        )
    }

    @Test("진행 중 100건 cancel() 반환 시간과 취소 완료 지연")
    func cancelLatency() async {
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let count = 100
        let urls = (0..<count).map { MockURLProtocol.uniqueURL("h\($0).cancel.bench.test") }
        for url in urls {
            MockURLProtocol.stub(
                url, steps: [.response(statusCode: 200, headers: ["Content-Length": "100000", "Content-Type": "image/png"]), .data(Data(repeating: 1, count: 1000)), .hold])
        }
        let firstChunk = LockIsolated<Set<Int>>([])
        let completedAt = LockIsolated<[Int: UInt64]>([:])
        var cancellables: [any Cancellable] = []
        for (index, url) in urls.enumerated() {
            cancellables.append(
                loader.loadData(
                    with: URLRequest(url: url),
                    didReceiveData: { _, _ in
                        firstChunk.withLock { _ = $0.insert(index) }
                    },
                    completion: { _ in
                        let now = DispatchTime.now().uptimeNanoseconds
                        completedAt.withLock { $0[index] = now }
                    }))
        }
        #expect(await waitUntil(timeout: 20) { firstChunk.value.count == count })
        var returns: [Double] = []
        var cancelledAt: [UInt64] = []
        for cancellable in cancellables {
            let start = DispatchTime.now().uptimeNanoseconds
            cancellable.cancel()
            let end = DispatchTime.now().uptimeNanoseconds
            returns.append(Double(end - start) / 1_000_000)
            cancelledAt.append(start)
        }
        #expect(await waitUntil(timeout: 20) { completedAt.value.count == count })
        let completed = completedAt.value
        let latencies = (0..<count).map { Double((completed[$0] ?? cancelledAt[$0]) - cancelledAt[$0]) / 1_000_000 }
        let p95 = percentile(returns, 0.95)
        print("BENCH|loader.cancelReturn|count=\(count)|p50_ms=\(String(format: "%.4f", percentile(returns, 0.5)))|p95_ms=\(String(format: "%.4f", p95))|threshold_p95_ms=10")
        print(
            "BENCH|loader.cancelToCompletion|count=\(count)|p50_ms=\(String(format: "%.3f", percentile(latencies, 0.5)))|p95_ms=\(String(format: "%.3f", percentile(latencies, 0.95)))"
        )
        #expect(p95 < 10)
    }

    @Test("파이프라인 스크롤 취소: 100건 중 90건 취소, 실제 로더로 10건만 완료")
    func sessionScrollCancel() async {
        let loader = DataLoader(configuration: MockURLProtocol.makeConfiguration())
        let session = makeLoaderSession(loader)
        let png = Fixtures.png()
        let count = 100
        let urls = (0..<count).map { MockURLProtocol.uniqueURL("h\($0).scroll.test") }
        for url in urls {
            MockURLProtocol.stub(
                url,
                steps: [
                    .response(statusCode: 200, headers: ["Content-Length": "\(png.count)"]),
                    .awaitAcknowledgements(1),
                    .data(png),
                    .finish,
                ])
        }
        let tasks = urls.map { session.imageTask(with: $0) }
        #expect(await waitUntil(timeout: 20) { urls.filter { MockURLProtocol.record(for: $0).startCount == 1 }.count >= 6 })
        var returns: [Double] = []
        for task in tasks.prefix(90) {
            let start = DispatchTime.now().uptimeNanoseconds
            task.cancel()
            returns.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        for url in urls.suffix(10) {
            MockURLProtocol.acknowledge(url)
        }
        var succeeded = 0
        for task in tasks.suffix(10) {
            if case .success = await result(of: task) {
                succeeded += 1
            }
        }
        var cancelled = 0
        for task in tasks.prefix(90) {
            if await result(of: task).failureValue?.caseName == "cancelled" {
                cancelled += 1
            }
        }
        #expect(await waitUntil(timeout: 20) { loader.activeTaskCount == 0 })
        let started = urls.prefix(90).filter { MockURLProtocol.record(for: $0).startCount > 0 }
        let stopped = started.filter { MockURLProtocol.record(for: $0).stopCount > 0 && MockURLProtocol.record(for: $0).finishCount == 0 }
        let finished = urls.filter { MockURLProtocol.record(for: $0).finishCount > 0 }.count
        let p95 = percentile(returns, 0.95)
        print(
            "BENCH|session.scrollCancel.realLoader|cancel_p50_ms=\(String(format: "%.4f", percentile(returns, 0.5)))|cancel_p95_ms=\(String(format: "%.4f", p95))|threshold_p95_ms=10|succeeded=\(succeeded)|cancelled=\(cancelled)|started_of_cancelled=\(started.count)|session_tasks_cancelled=\(stopped.count)|finished_downloads=\(finished)"
        )
        #expect(succeeded == 10)
        #expect(cancelled == 90)
        #expect(finished == 10)
        #expect(stopped.count == started.count)
        #expect(p95 < 10)
    }
}
