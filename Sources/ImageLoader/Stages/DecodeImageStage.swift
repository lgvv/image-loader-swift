import Foundation

final class DecodeImageStage: Stage<ImageResponse>, @unchecked Sendable {
    private var decoder: (any ImageDecoding)?
    private var decoderPreviewPolicy: ImageSession.PreviewPolicy?
    private var previewPolicyEvaluationCount = 0
    private var previewPolicyDataCount = 0
    private var lastPreviewTime: TimeInterval?
    private var imageLoadTask: Task<Void, Never>?

    static let maximumPreviewPolicyEvaluationCount = 6

    override func start() {
        if case .image(_, let fetch) = request.resource {
            loadAsyncImage(fetch)
            return
        }
        if let error = session.checkFailureCooldown(FailureCooldownKey.decodingUnit(for: request), bypass: request.bypassesFailureCooldown) {
            send(error: error)
            return
        }
        dependency = session.makeFetchDataStage(for: request).subscribe(self) { [weak self] value, isCompleted in
            self?.didReceiveData(value.0, urlResponse: value.1, isCompleted: isCompleted)
        }
    }

    private func loadAsyncImage(_ fetch: @escaping @Sendable () async throws -> ImageContent) {
        let request = request
        onCancelled = { [weak self] in
            self?.imageLoadTask?.cancel()
        }
        imageLoadTask = Task { [weak self] in
            let result: Result<ImageContent, ImageSession.Error>
            do {
                result = .success(try await fetch())
            } catch {
                result = .failure(.wrapping(error, at: .dataLoading))
            }
            SessionQueue.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                switch result {
                case .success(let content):
                    self.send(value: ImageResponse(content: content, request: request), isCompleted: true)
                case .failure(let error):
                    self.send(error: error)
                }
            }
        }
    }

    private func didReceiveData(_ data: Data, urlResponse: URLResponse?, isCompleted: Bool) {
        guard isCompleted else {
            didReceivePartialData(data, urlResponse: urlResponse)
            return
        }
        cancelCurrentOperation()
        var context = ImageDecodingContext(request: request, data: data, isCompleted: true, urlResponse: urlResponse)
        context.decodingLimits = session.configuration.decodingLimits
        let decoder = finalDecoder(for: context)
        self.decoder = decoder
        let isNetworkData = urlResponse != nil
        guard let decoder else {
            let error = ImageSession.Error.decoderNotRegistered(context: context)
            recordDecodingOutcome(failure: error, isNetworkData: isNetworkData)
            send(error: error)
            return
        }
        decode(context, decoder: decoder) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                self.recordDecodingOutcome(failure: nil, isNetworkData: isNetworkData)
                self.send(value: response, isCompleted: true)
            case .failure(let error):
                self.recordDecodingOutcome(failure: error, isNetworkData: isNetworkData)
                self.send(error: error)
            }
        }
    }

    private func finalDecoder(for context: ImageDecodingContext) -> (any ImageDecoding)? {
        let candidate = session.delegate.imageDecoder(for: context, session: session)
        guard let existing = decoder else {
            return candidate
        }
        guard let candidate else {
            return existing
        }
        return type(of: candidate) == type(of: existing) ? existing : candidate
    }

    private func didReceivePartialData(_ data: Data, urlResponse: URLResponse?) {
        let configuration = session.configuration
        guard configuration.isProgressiveDecodingEnabled, !isDisposed, operation == nil else { return }
        let interval = configuration.progressiveDecodingInterval
        if interval > 0, let lastPreviewTime, configuration.clock.monotonicIncludingSleep - lastPreviewTime < interval {
            return
        }
        var context = ImageDecodingContext(request: request, data: data, isCompleted: false, urlResponse: urlResponse)
        context.decodingLimits = configuration.decodingLimits
        context.previewPolicy = resolvePreviewPolicy(for: context)
        guard let decoder = partialDecoder(for: context) else { return }
        let partialContext = context
        perform(
            on: configuration.imageDecodingQueue, worker: SessionWorkers.decoding,
            work: {
                try? decoder.decode(partialContext)
            },
            completion: { [weak self] response in
                guard let self, let response else { return }
                self.lastPreviewTime = self.session.configuration.clock.monotonicIncludingSleep
                self.send(value: response, isCompleted: false)
            })
    }

    private func resolvePreviewPolicy(for context: ImageDecodingContext) -> ImageSession.PreviewPolicy {
        if let policy = decoderPreviewPolicy {
            guard policy == .disabled,
                previewPolicyEvaluationCount < Self.maximumPreviewPolicyEvaluationCount,
                context.data.count >= previewPolicyDataCount * 2
            else {
                return policy
            }
        }
        previewPolicyEvaluationCount += 1
        previewPolicyDataCount = context.data.count
        return session.delegate.previewPolicy(for: context, session: session)
    }

    private func partialDecoder(for context: ImageDecodingContext) -> (any ImageDecoding)? {
        if let decoder, context.previewPolicy == decoderPreviewPolicy {
            return decoder
        }
        guard let newDecoder = session.delegate.imageDecoder(for: context, session: session) else {
            return nil
        }
        decoder = newDecoder
        decoderPreviewPolicy = context.previewPolicy
        return newDecoder
    }

    private func recordDecodingOutcome(failure error: ImageSession.Error?, isNetworkData: Bool) {
        guard isNetworkData else { return }
        let key = FailureCooldownKey.decodingUnit(for: request)
        if let error {
            session.recordFailureForCooldown(key, error: error)
        } else {
            session.recordSuccessForCooldown(key)
        }
    }
}
