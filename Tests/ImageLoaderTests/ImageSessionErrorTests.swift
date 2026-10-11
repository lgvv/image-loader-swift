import Foundation
@_spi(Testing) @testable import ImageLoader
@_spi(Testing) import ImageLoaderTesting
import Testing
import UIKit

@Suite("에러 모델")
struct ImageSessionErrorTests {
    @Test("URL이 없으면 dataLoadingFailed(URLError.badURL)")
    func missingURL() async {
        let session = makeSession(loader: MockDataLoader())
        let outcome = await result(of: session.imageTask(with: ImageRequest(url: nil)))
        #expect(outcome.failureValue?.urlError?.code == .badURL)
    }

    @Test("404는 statusCode 404이고 재시도 대상이 아님")
    func notFound() async {
        let loader = MockDataLoader(defaultResponse: .data(Data(), statusCode: 404))
        let session = makeSession(loader: loader)
        let error = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(error?.caseName == "dataLoadingFailed")
        #expect(error?.statusCode == 404)
        #expect(error?.isRetryable == false)
        #expect(error?.diagnosticCode == "dataLoadingFailed.http.404")
        #expect((error as NSError?)?.code == ImageSessionErrorCode.dataLoadingFailed.rawValue)
        #expect((error as NSError?)?.domain == "ImageLoader.ImageSession")
    }

    @Test("503과 타임아웃은 재시도 대상")
    func retryable() async {
        let loader = MockDataLoader()
        loader.setResponse(.data(Data(), statusCode: 503), for: Fixtures.url(1))
        loader.setResponse(.failure(.timedOut), for: Fixtures.url(2))
        let session = makeSession(loader: loader)
        let serverError = await result(of: session.imageTask(with: Fixtures.url(1))).failureValue
        let timeout = await result(of: session.imageTask(with: Fixtures.url(2))).failureValue
        #expect(serverError?.isRetryable == true)
        #expect(timeout?.isRetryable == true)
        #expect(timeout?.statusCode == nil)
    }

    @Test("빈 데이터는 dataIsEmpty")
    func emptyData() async {
        let session = makeSession(loader: MockDataLoader(defaultResponse: .data(Data())))
        #expect(await result(of: session.imageTask(with: Fixtures.url)).failureValue?.caseName == "dataIsEmpty")
    }

    @Test("이미지가 아닌 데이터는 decodingFailed")
    func decodingFailed() async {
        let session = makeSession(loader: MockDataLoader(defaultResponse: .data(Data("not an image".utf8))))
        let error = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        guard case .decodingFailed(_, let context, _) = error else {
            Issue.record("decodingFailed가 아님: \(String(describing: error))")
            return
        }
        #expect(context.data == Data("not an image".utf8))
    }

    @Test("디코더가 없으면 decoderNotRegistered")
    func decoderNotRegistered() async {
        let session = makeSession(loader: MockDataLoader(defaultResponse: .data(Fixtures.pngData))) {
            $0.makeImageDecoder = { _ in nil }
        }
        #expect(await result(of: session.imageTask(with: Fixtures.url)).failureValue?.caseName == "decoderNotRegistered")
    }

    @Test("프로세서가 실패하면 processingFailed")
    func processingFailed() async {
        let session = makeSession(loader: MockDataLoader(defaultResponse: .data(Fixtures.pngData)))
        let error = await result(of: session.imageTask(with: ImageRequest(url: Fixtures.url, filters: [FailingFilter()]))).failureValue
        guard case .processingFailed(let processor, _, _) = error else {
            Issue.record("processingFailed가 아님: \(String(describing: error))")
            return
        }
        #expect(processor.identifier == "test/failing")
    }

    @Test("캐시에 없고 returnCacheDataDontLoad면 dataMissingInCache, 로더는 부르지 않음")
    func dataMissingInCache() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader)
        let request = ImageRequest(url: Fixtures.url, options: [.returnCacheDataDontLoad])
        #expect(await result(of: session.imageTask(with: request)).failureValue?.caseName == "dataMissingInCache")
        #expect(loader.counts.started == 0)
    }

    @Test("응답이 상한을 넘으면 dataDownloadExceededMaximumSize")
    func maximumResponseSize() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.png(width: 128, height: 128), chunkCount: 8))
        let session = makeSession(loader: loader) {
            $0.maximumResponseDataSize = 64
        }
        #expect(await result(of: session.imageTask(with: Fixtures.url)).failureValue?.caseName == "dataDownloadExceededMaximumSize")
    }

    @Test("willLoadData가 던지면 dataLoadingFailed에 그 에러를 담음")
    func willLoadDataError() async {
        struct TokenError: Error {}
        let delegate = RecordingDelegate(willLoadDataError: TokenError())
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader, delegate: delegate)
        let error = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(error?.dataLoadingError is TokenError)
        #expect(loader.counts.started == 0)
    }

    @Test("같은 URL을 기다리던 호출자 모두 같은 실패를 받고 요청은 한 번")
    func sharedFailure() async {
        let loader = MockDataLoader(defaultResponse: .data(Data(), statusCode: 404))
        loader.isSuspended = true
        let session = makeSession(loader: loader)
        let first = session.imageTask(with: Fixtures.url)
        let second = session.imageTask(with: Fixtures.url)
        #expect(await waitUntil { loader.counts.started == 1 })
        loader.isSuspended = false
        #expect(await result(of: first).failureValue?.statusCode == 404)
        #expect(await result(of: second).failureValue?.statusCode == 404)
        #expect(loader.counts.started == 1)
    }

    @Test("데이터 클로저 요청의 에러는 dataLoadingFailed로 감쌈")
    func dataClosureError() async {
        struct FetchError: Error {}
        let session = makeSession(loader: MockDataLoader())
        let request = ImageRequest(id: "closure", data: { throw FetchError() })
        let error = await result(of: session.imageTask(with: request)).failureValue
        #expect(error?.dataLoadingError is FetchError)
    }

    @Test("데이터 클로저 요청은 로더 없이 이미지를 만듦")
    func dataClosureSuccess() async throws {
        let session = makeSession(loader: MockDataLoader())
        let request = ImageRequest(id: "closure-ok", data: { Fixtures.pngData })
        #expect(try await session.image(for: request).cgImage != nil)
    }
}

@Suite("에러 경계와 코드표")
struct ImageSessionErrorBoundaryTests {
    struct CustomLoaderError: Error {}

    final class FailingLoader: DataLoading, @unchecked Sendable {
        let error: Swift.Error

        init(error: Swift.Error) {
            self.error = error
        }

        func loadData(
            with request: URLRequest,
            didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
            completion: @escaping @Sendable (Error?) -> Void
        ) -> any Cancellable {
            let error = error
            DispatchQueue.global().async { completion(error) }
            return NoopCancellable()
        }
    }

    struct NoopCancellable: Cancellable {
        func cancel() {}
    }

    private func makeBoundarySession(
        loader: any DataLoading,
        delegate: RecordingDelegate,
        cooldown: Bool = false,
        assertions: Box<[String]> = Box([])
    ) -> ImageSession {
        ImageSession(delegate: delegate) {
            $0.dataLoader = loader
            $0.memoryCache = nil
            $0.diskCache = nil
            $0.unexpectedErrorAssertion = { message in assertions.mutate { $0.append(message) } }
            if cooldown {
                $0.failureCooldown = ImageSession.FailureCooldownPolicy()
            }
        }
    }

    @Test(".unexpected에 낯선 에러 타입이 오면 DEBUG assert 훅을 부르고, dataLoadingFailed로 감싸 타입마다 진단을 한 번만 남김")
    func unexpectedBoundaryErrorIsWrappedAndReportedOnce() async {
        let delegate = RecordingDelegate()
        let assertions = Box<[String]>([])
        let session = makeBoundarySession(loader: MockDataLoader(), delegate: delegate, assertions: assertions)
        let first = session.wrapBoundaryError(CustomLoaderError(), at: .unexpected)
        let second = session.wrapBoundaryError(CustomLoaderError(), at: .unexpected)
        #expect(first.dataLoadingError is CustomLoaderError)
        #expect(second.dataLoadingError is CustomLoaderError)
        drainSessionQueue()
        let reported = delegate.diagnostics.value.compactMap { diagnostic -> String? in
            if case .unexpectedErrorWrapped(let typeName) = diagnostic { return typeName }
            return nil
        }
        #expect(reported.count == 1)
        #expect(reported.first?.hasSuffix("CustomLoaderError") == true)
        #expect(assertions.value.count == 2)
        #expect(assertions.value.allSatisfy { $0.hasSuffix("CustomLoaderError") })
        #expect(session.wrapBoundaryError(ImageSession.Error.dataIsEmpty, at: .unexpected).caseName == "dataIsEmpty")
        #expect(session.wrapBoundaryError(CancellationError(), at: .unexpected).isCancelled)
        #expect(assertions.value.count == 2)
    }

    @Test("사용자 DataLoading이 고유 에러 타입을 주면 허용된 경계라 assert 훅을 부르지 않고, 감싼 뒤 타입마다 진단만 한 번 남김")
    func customDataLoadingErrorDoesNotAssert() async {
        let delegate = RecordingDelegate()
        let assertions = Box<[String]>([])
        let session = makeBoundarySession(loader: FailingLoader(error: CustomLoaderError()), delegate: delegate, assertions: assertions)
        let first = await result(of: session.imageTask(with: Fixtures.url(1))).failureValue
        let second = await result(of: session.imageTask(with: Fixtures.url(2))).failureValue
        #expect(first?.dataLoadingError is CustomLoaderError)
        #expect(second?.dataLoadingError is CustomLoaderError)
        #expect(first?.diagnosticCode == "dataLoadingFailed.other")
        drainSessionQueue()
        let reported = delegate.diagnostics.value.compactMap { diagnostic -> String? in
            if case .unexpectedErrorWrapped(let typeName) = diagnostic { return typeName }
            return nil
        }
        #expect(reported.count == 1)
        #expect(reported.first?.hasSuffix("CustomLoaderError") == true)
        #expect(assertions.value.isEmpty)
    }

    @Test("URLError와 상태 코드 에러는 예상한 에러라 assert 훅도 진단도 부르지 않음")
    func expectedLoaderErrorsAreNotReported() async {
        let delegate = RecordingDelegate()
        let assertions = Box<[String]>([])
        let errors: [Swift.Error] = [URLError(.timedOut), DataLoader.Error.statusCodeUnacceptable(500), CocoaError(.fileReadUnknown)]
        for (index, error) in errors.enumerated() {
            let session = makeBoundarySession(loader: FailingLoader(error: error), delegate: delegate, assertions: assertions)
            _ = await result(of: session.imageTask(with: Fixtures.url(index)))
        }
        drainSessionQueue()
        #expect(!delegate.diagnostics.value.contains { if case .unexpectedErrorWrapped = $0 { return true } else { return false } })
        #expect(assertions.value.isEmpty)
    }

    @Test("willLoadData와 데이터 클로저가 던진 앱 에러는 허용된 경계라 assert 훅을 부르지 않음")
    func appHookErrorsDoNotAssert() async {
        struct HookError: Error {}
        let assertions = Box<[String]>([])
        let delegate = RecordingDelegate(willLoadDataError: HookError())
        let session = makeBoundarySession(loader: MockDataLoader(defaultResponse: .data(Fixtures.pngData)), delegate: delegate, assertions: assertions)
        let hook = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        let closure = await result(of: session.imageTask(with: ImageRequest(id: "hook-closure", data: { throw HookError() }))).failureValue
        #expect(hook?.dataLoadingError is HookError)
        #expect(closure?.dataLoadingError is HookError)
        drainSessionQueue()
        #expect(assertions.value.isEmpty)
    }

    @Test("호출자가 취소하지 않았는데 로더가 URLError.cancelled를 주면 취소가 아닌 실패이고 쿨다운에 넣지 않음")
    func systemCancelledIsFailureWithoutCooldown() async {
        let delegate = RecordingDelegate()
        let session = makeBoundarySession(loader: FailingLoader(error: URLError(.cancelled)), delegate: delegate, cooldown: true)
        let first = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(first?.isCancelled == false)
        #expect(first?.urlError?.code == .cancelled)
        let second = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(second?.cooldown == nil)
    }

    @Test("데이터 클로저가 CancellationError를 던지면 .cancelled, ImageSession.Error는 그대로 전달")
    func closureErrorNormalization() async {
        let session = makeSession(loader: MockDataLoader())
        let cancelled = await result(of: session.imageTask(with: ImageRequest(id: "c1", data: { throw CancellationError() }))).failureValue
        #expect(cancelled?.isCancelled == true)
        let passthrough = await result(of: session.imageTask(with: ImageRequest(id: "c2", data: { throw ImageSession.Error.dataIsEmpty }))).failureValue
        #expect(passthrough?.caseName == "dataIsEmpty")
    }

    @Test("NSError 브리징: domain과 1부터 시작하는 고정 코드표, userInfo에는 URL을 넣지 않음")
    func errorCodeTable() {
        #expect(ImageSession.Error.errorDomain == "ImageLoader.ImageSession")
        let expected: [(ImageSession.Error, Int)] = [
            (.dataMissingInCache, 1),
            (.dataLoadingFailed(error: URLError(.timedOut)), 2),
            (.dataIsEmpty, 3),
            (.imageRequestMissing, 7),
            (.sessionInvalidated, 8),
            (.dataDownloadExceededMaximumSize, 9),
            (.cancelled, 10),
        ]
        for (error, code) in expected {
            #expect((error as NSError).code == code)
            #expect((error as NSError).domain == ImageSession.Error.errorDomain)
        }
        let url = URL(string: "https://example.com/secret?token=abc")!
        let underlying = URLError(.notConnectedToInternet, userInfo: [NSURLErrorFailingURLErrorKey: url])
        let nsError = ImageSession.Error.dataLoadingFailed(error: underlying) as NSError
        #expect(nsError.userInfo["urlErrorCode"] as? Int == URLError.Code.notConnectedToInternet.rawValue)
        #expect(!nsError.userInfo.values.contains { "\($0)".contains("example.com") })
        #expect(ImageSession.Error.dataLoadingFailed(error: DataLoader.Error.statusCodeUnacceptable(404)).diagnosticCode == "dataLoadingFailed.http.404")
    }
}

@Suite("실패 쿨다운")
struct FailureCooldownTests {
    private func makeCooldownSession(loader: MockDataLoader, clock: TestClock, delegate: RecordingDelegate? = nil) -> ImageSession {
        makeSession(loader: loader, delegate: delegate) {
            $0.failureCooldown = ImageSession.FailureCooldownPolicy(baseInterval: 2, maximumInterval: 300, countLimit: 512)
            $0.clock = clock
            $0.memoryCache = nil
        }
    }

    @Test("실패 직후 다시 요청하면 네트워크 없이 쿨다운 에러, 시간이 지나면 다시 요청")
    func blocksThenRetries() async {
        let clock = TestClock()
        let delegate = RecordingDelegate()
        let loader = MockDataLoader(defaultResponse: .data(Data(), statusCode: 404))
        let session = makeCooldownSession(loader: loader, clock: clock, delegate: delegate)
        _ = await result(of: session.imageTask(with: Fixtures.url))
        let blocked = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(blocked?.cooldown?.failureCount == 1)
        #expect(blocked?.cooldown?.lastError.statusCode == 404)
        #expect(blocked?.statusCode == 404)
        #expect(blocked?.isRetryable == false)
        #expect(blocked?.diagnosticCode == "dataLoadingFailed.cooldown.http.404")
        #expect(loader.counts.started == 1)
        #expect(await waitUntil { delegate.diagnostics.value.contains { if case .failureCooldownApplied = $0 { return true } else { return false } } })
        clock.advance(by: 2.1)
        _ = await result(of: session.imageTask(with: Fixtures.url))
        #expect(loader.counts.started == 2)
    }

    @Test("대기 시간이 지나도 실패 횟수는 남아 백오프가 두 배씩 늘어남 (기존 결함 재발 방지)")
    func backoffGrows() async {
        let clock = TestClock()
        let loader = MockDataLoader(defaultResponse: .data(Data(), statusCode: 404))
        let session = makeCooldownSession(loader: loader, clock: clock)
        _ = await result(of: session.imageTask(with: Fixtures.url))
        clock.advance(by: 2.1)
        _ = await result(of: session.imageTask(with: Fixtures.url))
        #expect(loader.counts.started == 2)
        clock.advance(by: 2.1)
        let stillBlocked = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(stillBlocked?.cooldown?.failureCount == 2)
        #expect(loader.counts.started == 2)
        clock.advance(by: 2)
        _ = await result(of: session.imageTask(with: Fixtures.url))
        #expect(loader.counts.started == 3)
    }

    @Test("성공하면 기록이 지워짐")
    func successResets() async {
        let clock = TestClock()
        let loader = MockDataLoader(defaultResponse: .data(Data(), statusCode: 404))
        let session = makeCooldownSession(loader: loader, clock: clock)
        _ = await result(of: session.imageTask(with: Fixtures.url))
        loader.setResponse(.data(Fixtures.pngData), for: Fixtures.url)
        clock.advance(by: 2.1)
        #expect(await result(of: session.imageTask(with: Fixtures.url)).failureValue == nil)
        loader.setResponse(.data(Data(), statusCode: 404), for: Fixtures.url)
        _ = await result(of: session.imageTask(with: Fixtures.url))
        let blocked = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(blocked?.cooldown?.failureCount == 1)
    }

    @Test("일시적인 에러와 취소는 기록하지 않음")
    func transientNotRecorded() async {
        let clock = TestClock()
        let loader = MockDataLoader(defaultResponse: .failure(.timedOut))
        let session = makeCooldownSession(loader: loader, clock: clock)
        _ = await result(of: session.imageTask(with: Fixtures.url))
        _ = await result(of: session.imageTask(with: Fixtures.url))
        #expect(loader.counts.started == 2)
    }

    @Test("bypassesFailureCooldown이면 쿨다운 중에도 요청")
    func bypass() async {
        let clock = TestClock()
        let loader = MockDataLoader(defaultResponse: .data(Data(), statusCode: 404))
        let session = makeCooldownSession(loader: loader, clock: clock)
        _ = await result(of: session.imageTask(with: Fixtures.url))
        var request = ImageRequest(url: Fixtures.url)
        request.bypassesFailureCooldown = true
        _ = await result(of: session.imageTask(with: request))
        #expect(loader.counts.started == 2)
    }

    @Test("빈 본문과 상한 초과 응답도 데이터 단위로 기록")
    func emptyAndOversizedResponsesAreRecorded() async {
        let clock = TestClock()
        let loader = MockDataLoader()
        loader.setResponse(.data(Data()), for: Fixtures.url(1))
        loader.setResponse(.data(Fixtures.png(width: 128, height: 128)), for: Fixtures.url(2))
        let session = makeSession(loader: loader) {
            $0.failureCooldown = ImageSession.FailureCooldownPolicy()
            $0.clock = clock
            $0.memoryCache = nil
            $0.maximumResponseDataSize = 64
        }
        #expect(await result(of: session.imageTask(with: Fixtures.url(1))).failureValue?.caseName == "dataIsEmpty")
        #expect(await result(of: session.imageTask(with: Fixtures.url(2))).failureValue?.caseName == "dataDownloadExceededMaximumSize")
        let empty = await result(of: session.imageTask(with: Fixtures.url(1))).failureValue
        let oversized = await result(of: session.imageTask(with: Fixtures.url(2))).failureValue
        #expect(empty?.cooldown?.lastError.caseName == "dataIsEmpty")
        #expect(oversized?.cooldown?.lastError.caseName == "dataDownloadExceededMaximumSize")
        #expect(loader.counts.started == 2)
    }

    @Test("네트워크 실패는 데이터 단위라 같은 URL의 썸네일, 프로세서, scale 변형을 모두 막고 다른 URL은 막지 않음")
    func networkFailureBlocksEveryVariantOfSameData() async {
        let clock = TestClock()
        let loader = MockDataLoader(defaultResponse: .data(Data(), statusCode: 404))
        loader.setResponse(.data(Fixtures.pngData), for: Fixtures.url(9))
        let session = makeCooldownSession(loader: loader, clock: clock)
        _ = await result(of: session.imageTask(with: Fixtures.url))
        var thumbnail = ImageRequest(url: Fixtures.url)
        thumbnail.thumbnail = ImageRequest.ThumbnailOptions(maxPixelSize: 4)
        var scaled = ImageRequest(url: Fixtures.url)
        scaled.scale = 2
        let processed = ImageRequest(url: Fixtures.url, filters: [TintFilter(name: "variant")])
        for request in [thumbnail, scaled, processed] {
            let blocked = await result(of: session.imageTask(with: request)).failureValue
            #expect(blocked?.cooldown?.lastError.statusCode == 404)
        }
        #expect(loader.counts.started == 1)
        #expect(await result(of: session.imageTask(with: Fixtures.url(9))).failureValue == nil)
        #expect(loader.counts.started == 2)
    }

    @Test("디코딩 실패는 디코딩 단위라 같은 URL의 썸네일과 scale 변형은 막지 않고, 같은 변형만 막음")
    func decodingFailureBlocksOnlyItsDecodingVariant() async {
        let clock = TestClock()
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader) {
            $0.failureCooldown = ImageSession.FailureCooldownPolicy()
            $0.clock = clock
            $0.memoryCache = nil
            $0.makeImageDecoder = { context in VariantRejectingDecoder(rejects: context.request.thumbnail == nil && context.request.scale == 1) }
        }
        let failed = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(failed?.caseName == "decodingFailed")
        var thumbnail = ImageRequest(url: Fixtures.url)
        thumbnail.thumbnail = ImageRequest.ThumbnailOptions(maxPixelSize: 4)
        var scaled = ImageRequest(url: Fixtures.url)
        scaled.scale = 2
        #expect(await result(of: session.imageTask(with: thumbnail)).failureValue == nil)
        #expect(await result(of: session.imageTask(with: scaled)).failureValue == nil)
        #expect(loader.counts.started == 3)
        let blocked = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(blocked?.cooldown?.lastError.caseName == "decodingFailed")
        #expect(blocked?.diagnosticCode == "dataLoadingFailed.cooldown.decodingFailed")
        let processed = await result(of: session.imageTask(with: ImageRequest(url: Fixtures.url, filters: [TintFilter(name: "shared")]))).failureValue
        #expect(processed?.cooldown?.lastError.caseName == "decodingFailed")
        #expect(loader.counts.started == 3)
    }

    @Test("디코딩 한도 거부는 기록하지 않음을 고정. 썸네일 없는 요청이 한도로 실패해도 썸네일 요청은 성공 (키 분리는 decodingFailureBlocksOnlyItsDecodingVariant가 고정)")
    func limitRejectionWithoutThumbnailDoesNotBlockThumbnailRequest() async {
        let clock = TestClock()
        let loader = MockDataLoader(defaultResponse: .data(DecodingFixtures.png(width: 40, height: 40)))
        let session = makeSession(loader: loader) {
            $0.failureCooldown = ImageSession.FailureCooldownPolicy()
            $0.clock = clock
            $0.memoryCache = nil
            $0.decodingLimits = ImageDecodingLimits(maximumPixelCount: 100)
        }
        let rejected = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        guard case .decodingFailed(_, _, let error) = rejected else {
            Issue.record("decodingFailed가 아님: \(String(describing: rejected))")
            return
        }
        #expect(error is ImageDecodingLimits.Error)
        var thumbnail = ImageRequest(url: Fixtures.url)
        thumbnail.thumbnail = ImageRequest.ThumbnailOptions(maxPixelSize: 10)
        #expect(await result(of: session.imageTask(with: thumbnail)).failureValue == nil)
        let again = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(again?.cooldown == nil)
        #expect(again?.caseName == "decodingFailed")
        #expect(loader.counts.started == 3)
    }

    @Test("디코딩 한도 거부를 반복해도 디스크 원본으로 다시 거부되어 다운로드는 1회")
    func repeatedLimitRejectionDownloadsOnce() async {
        let clock = TestClock()
        let diskCache = InMemoryDiskCache()
        let loader = MockDataLoader(defaultResponse: .data(DecodingFixtures.png(width: 40, height: 40)))
        let session = makeSession(loader: loader) {
            $0.failureCooldown = ImageSession.FailureCooldownPolicy()
            $0.clock = clock
            $0.memoryCache = nil
            $0.diskCache = diskCache
            $0.decodingLimits = ImageDecodingLimits(maximumPixelCount: 100)
        }
        let first = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(first?.caseName == "decodingFailed")
        #expect(await waitUntil { diskCache.storage.value[Fixtures.url.absoluteString] != nil })
        for _ in 0..<2 {
            let again = await result(of: session.imageTask(with: Fixtures.url)).failureValue
            #expect(again?.caseName == "decodingFailed")
            #expect(again?.cooldown == nil)
        }
        #expect(loader.counts.started == 1)
        #expect(diskCache.storage.value[Fixtures.url.absoluteString] != nil)
    }

    @Test("네트워크 데이터의 decoderNotRegistered는 디코딩 단위에 기록되어 다시 요청하면 로드 없이 쿨다운 에러")
    func decoderNotRegisteredIsRecordedAtDecodingUnit() async {
        let clock = TestClock()
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader) {
            $0.failureCooldown = ImageSession.FailureCooldownPolicy()
            $0.clock = clock
            $0.memoryCache = nil
            $0.makeImageDecoder = { _ in nil }
        }
        let first = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(first?.caseName == "decoderNotRegistered")
        let blocked = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(blocked?.cooldown?.lastError.caseName == "decoderNotRegistered")
        #expect(blocked?.diagnosticCode == "dataLoadingFailed.cooldown.decoderNotRegistered")
        #expect(loader.counts.started == 1)
    }

    @Test("디코딩에 성공하면 디코딩 단위 기록이 지워져, 다음 실패는 실패 횟수 1부터 다시 셈")
    func decodingSuccessClearsDecodingUnitEntry() async {
        let clock = TestClock()
        let rejects = Box(true)
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader) {
            $0.failureCooldown = ImageSession.FailureCooldownPolicy(baseInterval: 2, maximumInterval: 300, countLimit: 512)
            $0.clock = clock
            $0.memoryCache = nil
            $0.makeImageDecoder = { _ in VariantRejectingDecoder(rejects: rejects.value) }
        }
        #expect(await result(of: session.imageTask(with: Fixtures.url)).failureValue?.caseName == "decodingFailed")
        clock.advance(by: 2.1)
        rejects.value = false
        #expect(await result(of: session.imageTask(with: Fixtures.url)).failureValue == nil)
        rejects.value = true
        #expect(await result(of: session.imageTask(with: Fixtures.url)).failureValue?.caseName == "decodingFailed")
        let blocked = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(blocked?.cooldown?.lastError.caseName == "decodingFailed")
        #expect(blocked?.cooldown?.failureCount == 1)
        #expect(loader.counts.started == 3)
    }

    @Test("데이터 단위 키는 원래 URL이라 우회 요청의 실패도 같은 URL의 일반 요청을 막음")
    func bypassRequestFailureBlocksNormalRequests() async {
        let clock = TestClock()
        let loader = MockDataLoader(defaultResponse: .data(Data(), statusCode: 404))
        let session = makeCooldownSession(loader: loader, clock: clock)
        var bypassing = ImageRequest(url: Fixtures.url)
        bypassing.bypassesFailureCooldown = true
        #expect(await result(of: session.imageTask(with: bypassing)).failureValue?.statusCode == 404)
        let blocked = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(blocked?.cooldown?.lastError.statusCode == 404)
        #expect(loader.counts.started == 1)
    }

    @Test("프로세서 실패는 기록하지 않아 같은 URL의 다른 프로세서를 막지 않음")
    func processingFailureDoesNotBlockOtherFilters() async {
        let clock = TestClock()
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeCooldownSession(loader: loader, clock: clock)
        let failing = await result(of: session.imageTask(with: ImageRequest(url: Fixtures.url, filters: [FailingFilter()]))).failureValue
        #expect(failing?.caseName == "processingFailed")
        #expect(await result(of: session.imageTask(with: ImageRequest(url: Fixtures.url, filters: [TintFilter(name: "ok")]))).failureValue == nil)
        let again = await result(of: session.imageTask(with: ImageRequest(url: Fixtures.url, filters: [FailingFilter()]))).failureValue
        #expect(again?.caseName == "processingFailed")
    }

    @Test("이미지가 아닌 네트워크 데이터의 디코딩 실패도 기록")
    func decodingFailureRecorded() async {
        let clock = TestClock()
        let loader = MockDataLoader(defaultResponse: .data(Data("garbage".utf8)))
        let session = makeCooldownSession(loader: loader, clock: clock)
        _ = await result(of: session.imageTask(with: Fixtures.url))
        let blocked = await result(of: session.imageTask(with: Fixtures.url)).failureValue
        #expect(blocked?.cooldown != nil)
        #expect(loader.counts.started == 1)
    }
}

private struct VariantRejectingDecoder: ImageDecoding {
    let rejects: Bool

    func decode(_ data: Data) throws -> ImageContent {
        guard !rejects, let image = UIImage(data: data) else {
            throw ImageDecodingError.unknown
        }
        return ImageContent(image: image)
    }
}

@Suite("에러 헬퍼와 재시도 판정")
struct ImageSessionErrorHelperTests {
    private static func cooldownWrapping(_ lastError: ImageSession.Error) -> ImageSession.Error {
        .dataLoadingFailed(error: ImageSession.FailureCooldownError(until: .distantFuture, failureCount: 1, lastError: lastError))
    }

    @Test(
        "쿨다운으로 감싼 에러의 isRetryable, statusCode, urlError는 lastError를 따름",
        arguments: [
            (404, false),
            (503, true),
        ])
    func cooldownWrappedRetryabilityFollowsLastError(statusCode: Int, isRetryable: Bool) {
        let lastError = ImageSession.Error.dataLoadingFailed(error: DataLoader.Error.statusCodeUnacceptable(statusCode))
        let wrapped = Self.cooldownWrapping(lastError)
        #expect(wrapped.cooldown != nil)
        #expect(wrapped.isRetryable == isRetryable)
        #expect(wrapped.isRetryable == lastError.isRetryable)
        #expect(wrapped.statusCode == statusCode)
        #expect(wrapped.urlError == nil)
        #expect(wrapped.diagnosticCode == "dataLoadingFailed.cooldown.http.\(statusCode)")
        #expect(ImageSession.FailureCooldownPolicy.defaultShouldCooldown(wrapped) == false)
        #expect((wrapped as NSError).userInfo["statusCode"] as? Int == statusCode)
    }

    @Test("쿨다운으로 감싼 URLError는 urlError로 꺼내고 일시 오류 판정도 그대로 따름")
    func cooldownWrappedURLError() {
        let timedOut = Self.cooldownWrapping(.dataLoadingFailed(error: URLError(.timedOut)))
        #expect(timedOut.urlError?.code == .timedOut)
        #expect(timedOut.statusCode == nil)
        #expect(timedOut.isRetryable)
        #expect(timedOut.diagnosticCode == "dataLoadingFailed.cooldown.urlError.\(URLError.Code.timedOut.rawValue)")
        let badURL = Self.cooldownWrapping(.dataLoadingFailed(error: URLError(.badURL)))
        #expect(badURL.urlError?.code == .badURL)
        #expect(!badURL.isRetryable)
    }

    @Test("상태 코드와 URLError가 아닌 underlying은 cocoa.<코드>와 other로 분류하고, 쿨다운으로 감싸도 같은 분류를 이어 씀")
    func nonHTTPDiagnosticCodes() {
        struct HookError: Error {}
        let cocoa = CocoaError(.fileReadNoSuchFile)
        let cocoaCode = "cocoa.\(CocoaError.Code.fileReadNoSuchFile.rawValue)"
        #expect(ImageSession.Error.dataLoadingFailed(error: cocoa).diagnosticCode == "dataLoadingFailed.\(cocoaCode)")
        #expect(ImageSession.Error.dataLoadingFailed(error: HookError()).diagnosticCode == "dataLoadingFailed.other")
        #expect(Self.cooldownWrapping(.dataLoadingFailed(error: cocoa)).diagnosticCode == "dataLoadingFailed.cooldown.\(cocoaCode)")
        #expect(Self.cooldownWrapping(.dataLoadingFailed(error: HookError())).diagnosticCode == "dataLoadingFailed.cooldown.other")
        #expect(Self.cooldownWrapping(.dataIsEmpty).diagnosticCode == "dataLoadingFailed.cooldown.dataIsEmpty")
    }

    @Test("재시도와 쿨다운 기본 판정은 한 표를 공유해 '재시도 가능한데 차단'이 없음")
    func retryableClassificationTable() {
        struct HookError: Error {}
        let decoder = ImageDecoders.Empty()
        let decodingContext = ImageDecodingContext(request: ImageRequest(url: Fixtures.url), data: Data())
        let rows: [(ImageSession.Error, Bool, Bool)] = [
            (.dataLoadingFailed(error: URLError(.timedOut)), true, false),
            (.dataLoadingFailed(error: URLError(.badURL)), false, true),
            (.dataLoadingFailed(error: URLError(.cancelled)), false, false),
            (.dataLoadingFailed(error: DataLoader.Error.statusCodeUnacceptable(500)), true, false),
            (.dataLoadingFailed(error: DataLoader.Error.statusCodeUnacceptable(408)), true, false),
            (.dataLoadingFailed(error: DataLoader.Error.statusCodeUnacceptable(429)), true, false),
            (.dataLoadingFailed(error: DataLoader.Error.statusCodeUnacceptable(404)), false, true),
            (.dataLoadingFailed(error: CocoaError(.fileReadNoSuchFile)), false, true),
            (.dataLoadingFailed(error: HookError()), false, true),
            (Self.cooldownWrapping(.dataLoadingFailed(error: DataLoader.Error.statusCodeUnacceptable(503))), true, false),
            (Self.cooldownWrapping(.dataIsEmpty), false, false),
            (.dataIsEmpty, false, true),
            (.dataDownloadExceededMaximumSize, false, true),
            (.decoderNotRegistered(context: decodingContext), false, true),
            (.decodingFailed(decoder: decoder, context: decodingContext, error: ImageDecodingError.unknown), false, true),
            (.decodingFailed(decoder: decoder, context: decodingContext, error: ImageDecodingLimits.Error.pixelCountExceeded(pixelCount: 2, limit: 1)), false, false),
            (
                .processingFailed(
                    filter: FailingFilter(),
                    context: ImageFilterContext(
                        request: ImageRequest(url: Fixtures.url), response: ImageResponse(content: ImageContent(image: UIImage()), request: ImageRequest(url: Fixtures.url)),
                        isCompleted: true), error: ImageFilterError.unknown), false, false
            ),
            (.dataMissingInCache, false, false),
            (.imageRequestMissing, false, false),
            (.sessionInvalidated, false, false),
            (.cancelled, false, false),
        ]
        for (error, isRetryable, shouldCooldown) in rows {
            #expect(error.isRetryable == isRetryable, "\(error.diagnosticCode)")
            #expect(ImageSession.FailureCooldownPolicy.defaultShouldCooldown(error) == shouldCooldown, "\(error.diagnosticCode)")
            #expect(!(error.isRetryable && ImageSession.FailureCooldownPolicy.defaultShouldCooldown(error)), "\(error.diagnosticCode)")
        }
    }

    @Test("일시 오류 URLError 집합은 10종으로 고정")
    func transientURLErrorSetIsPinned() {
        let expected: Set<URLError.Code> = [
            .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
            .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive, .secureConnectionFailed,
        ]
        #expect(ImageSession.Error.transientURLErrorCodes == expected)
        for code in expected {
            #expect(ImageSession.Error.dataLoadingFailed(error: URLError(code)).isRetryable)
        }
    }
}
