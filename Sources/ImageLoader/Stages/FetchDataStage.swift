import Foundation

final class FetchDataStage: Stage<(Data, URLResponse?)>, @unchecked Sendable {
    private(set) var urlResponse: URLResponse?
    private var data = Data()
    private var resumableData: ResumableData?
    private var resumedDataCount: Int64 = 0
    private var dataLoadCancellable: (any Cancellable)?
    private var asyncTask: Task<Void, Never>?
    var isLocalResource = false
    private var loadInterval: SessionSignposter.Interval?

    override func start() {
        if case .data(_, let fetch) = request.resource {
            loadAsyncData(fetch)
            return
        }
        guard let urlRequest = request.urlRequest, let url = urlRequest.url else {
            send(error: .dataLoadingFailed(error: URLError(.badURL)))
            return
        }
        if session.configuration.isLocalResourcesSupportEnabled, url.isLocalResource {
            loadLocalResource(url)
            return
        }
        if let error = session.checkFailureCooldown(FailureCooldownKey.dataUnit(for: request), bypass: request.bypassesFailureCooldown) {
            send(error: error)
            return
        }
        if let rateLimiter = session.rateLimiter {
            rateLimiter.execute { [weak self] in
                guard let self, !self.isDisposed else { return false }
                self.loadData(urlRequest: urlRequest)
                return true
            }
        } else {
            loadData(urlRequest: urlRequest)
        }
    }

    static let maximumReservedCapacity: Int64 = 16 * 1024 * 1024

    private func loadAsyncData(_ fetch: @escaping @Sendable () async throws -> Data) {
        onCancelled = { [weak self] in
            self?.asyncTask?.cancel()
        }
        let start: (@escaping @Sendable () -> Void) -> Void = { [weak self] finish in
            guard let self, !self.isDisposed else {
                finish()
                return
            }
            self.asyncTask = Task { [weak self] in
                let result: Result<Data, ImageSession.Error>
                do {
                    result = .success(try await fetch())
                } catch {
                    result = .failure(.wrapping(error, at: .dataLoading))
                }
                finish()
                SessionQueue.async { [weak self] in
                    guard let self, !self.isDisposed else { return }
                    switch result {
                    case .success(let data):
                        guard !data.isEmpty else {
                            self.send(error: .dataIsEmpty)
                            return
                        }
                        self.storeDataInCacheIfNeeded(data)
                        self.send(value: (data, nil), isCompleted: true)
                    case .failure(let error):
                        self.send(error: error)
                    }
                }
            }
        }
        if request.options.contains(.skipDataLoadingQueue) {
            start {}
        } else {
            operation = session.configuration.dataLoadingQueue.add(priority: priority, start)
        }
    }

    private func loadData(urlRequest: URLRequest) {
        if request.options.contains(.skipDataLoadingQueue) {
            performDataLoad(urlRequest: urlRequest, finish: {})
        } else {
            operation = session.configuration.dataLoadingQueue.add(priority: priority) { [weak self] finish in
                guard let self, !self.isDisposed else {
                    finish()
                    return
                }
                self.performDataLoad(urlRequest: urlRequest, finish: finish)
            }
        }
    }

    private func performDataLoad(urlRequest: URLRequest, finish: @escaping @Sendable () -> Void) {
        var urlRequest = urlRequest
        if request.revalidatesCachedData {
            urlRequest.cachePolicy = .reloadRevalidatingCacheData
        }
        if session.configuration.isResumableDataEnabled, let resumableData = ResumableDataStorage.shared.removeResumableData(for: request, sessionID: session.id) {
            resumableData.resume(request: &urlRequest)
            self.resumableData = resumableData
        }
        loadInterval = SessionSignposter.shared.beginInterval("LoadImageData")
        onCancelled = { [weak self] in
            guard let self else { return }
            self.endLoadInterval(.cancelled)
            self.asyncTask?.cancel()
            self.dataLoadCancellable?.cancel()
            self.tryToSaveResumableData()
        }
        guard !session.isDefaultDelegate else {
            startLoading(urlRequest: urlRequest, finish: finish)
            return
        }
        let session = session
        let request = request
        asyncTask = Task { [weak self] in
            let result: Result<URLRequest, ImageSession.Error>
            do {
                result = .success(try await session.delegate.willLoadData(for: request, urlRequest: urlRequest, session: session))
            } catch {
                result = .failure(.wrapping(error, at: .willLoadData))
            }
            SessionQueue.async { [weak self] in
                guard let self, !self.isDisposed else {
                    finish()
                    return
                }
                switch result {
                case .success(let urlRequest):
                    self.startLoading(urlRequest: urlRequest, finish: finish)
                case .failure(let error):
                    finish()
                    self.endLoadInterval(.failed)
                    self.send(error: error)
                }
            }
        }
    }

    private func startLoading(urlRequest: URLRequest, finish: @escaping @Sendable () -> Void) {
        let dataLoader = session.delegate.dataLoader(for: request, session: session)
        dataLoadCancellable = dataLoader.loadData(
            with: urlRequest,
            didReceiveData: { [weak self] data, response in
                SessionQueue.async { [weak self] in
                    self?.dataTask(didReceiveData: data, response: response)
                }
            },
            completion: { [weak self] error in
                SessionQueue.async { [weak self] in
                    finish()
                    self?.dataTaskDidFinish(error: error)
                }
            })
    }

    private func dataTask(didReceiveData chunk: Data, response: URLResponse) {
        guard !isDisposed else { return }
        if urlResponse == nil {
            urlResponse = response
            if let resumableData, ResumableData.isResumedResponse(response) {
                guard resumableData.isValidResumption(response) else {
                    rejectInvalidResumption()
                    return
                }
                data = resumableData.data
                resumedDataCount = Int64(resumableData.data.count)
                loadInterval?.resumed(byteCount: resumableData.data.count)
            }
            resumableData = nil
            let expected = response.expectedContentLength
            if let limit = session.configuration.maximumResponseDataSize, expected > 0, expected + resumedDataCount > Int64(limit) {
                exceedMaximumSize()
                return
            }
            if expected > 0 {
                data.reserveCapacity(Int(min(expected + resumedDataCount, Self.maximumReservedCapacity)))
            }
        }
        data.append(chunk)
        if let limit = session.configuration.maximumResponseDataSize, data.count > limit {
            exceedMaximumSize()
            return
        }
        let total = response.expectedContentLength > 0 ? response.expectedContentLength + resumedDataCount : 0
        let completed = Int64(data.count)
        send(progress: ImageTask.Progress(completed: completed, total: total))
        if total > 0, completed < total {
            send(value: (data, urlResponse), isCompleted: false)
        }
    }

    private func rejectInvalidResumption() {
        dataLoadCancellable?.cancel()
        dataLoadCancellable = nil
        resumableData = nil
        endLoadInterval(.failed)
        send(error: .dataLoadingFailed(error: URLError(.cannotParseResponse)))
    }

    private func exceedMaximumSize() {
        dataLoadCancellable?.cancel()
        dataLoadCancellable = nil
        endLoadInterval(.failed)
        session.recordFailureForCooldown(FailureCooldownKey.dataUnit(for: request), error: .dataDownloadExceededMaximumSize)
        send(error: .dataDownloadExceededMaximumSize)
    }

    private func dataTaskDidFinish(error: Swift.Error?) {
        guard !isDisposed else { return }
        dataLoadCancellable = nil
        endLoadInterval(error == nil && !data.isEmpty ? .finished(byteCount: data.count) : .failed)
        if let error {
            tryToSaveResumableData()
            let error = session.wrapBoundaryError(error, at: .dataLoading)
            session.recordFailureForCooldown(FailureCooldownKey.dataUnit(for: request), error: error)
            send(error: error)
            return
        }
        guard !data.isEmpty else {
            session.recordFailureForCooldown(FailureCooldownKey.dataUnit(for: request), error: .dataIsEmpty)
            send(error: .dataIsEmpty)
            return
        }
        session.recordSuccessForCooldown(FailureCooldownKey.dataUnit(for: request))
        storeDataInCacheIfNeeded(data)
        send(value: (data, urlResponse), isCompleted: true)
    }

    private func endLoadInterval(_ outcome: SessionSignposter.Outcome) {
        guard let interval = loadInterval else { return }
        loadInterval = nil
        interval.end(outcome)
    }

    private func tryToSaveResumableData() {
        guard session.configuration.isResumableDataEnabled,
            let urlResponse,
            let resumable = ResumableData(response: urlResponse, data: data)
        else {
            return
        }
        ResumableDataStorage.shared.storeResumableData(resumable, for: request, sessionID: session.id)
    }
}
