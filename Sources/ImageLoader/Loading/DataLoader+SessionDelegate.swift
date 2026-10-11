import Foundation

final class DataLoaderSessionDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct Entry: Sendable {
        let didReceiveData: @Sendable (Data, URLResponse) -> Void
        let completion: @Sendable (Swift.Error?) -> Void
    }

    private let validate: @Sendable (URLResponse) -> Swift.Error?
    private let sessionDelegate: (any URLSessionDelegate)?
    private let taskDelegate: (any URLSessionTaskDelegate)?
    private let dataDelegate: (any URLSessionDataDelegate)?
    private let entries = LockIsolated<[Int: Entry]>([:])

    init(validate: @escaping @Sendable (URLResponse) -> Swift.Error?, delegate: (any URLSessionDelegate)?) {
        self.validate = validate
        sessionDelegate = delegate
        taskDelegate = delegate as? any URLSessionTaskDelegate
        dataDelegate = delegate as? any URLSessionDataDelegate
    }

    var activeTaskCount: Int {
        entries.withLock { $0.count }
    }

    func register(
        _ task: URLSessionTask,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Swift.Error?) -> Void
    ) {
        let identifier = task.taskIdentifier
        let entry = Entry(didReceiveData: didReceiveData, completion: completion)
        entries.withLock { $0[identifier] = entry }
    }

    private func entry(for task: URLSessionTask) -> Entry? {
        let identifier = task.taskIdentifier
        return entries.withLock { $0[identifier] }
    }

    private func removeEntry(for task: URLSessionTask) -> Entry? {
        let identifier = task.taskIdentifier
        return entries.withLock { $0.removeValue(forKey: identifier) }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        dataDelegate?.urlSession?(session, dataTask: dataTask, didReceive: response, completionHandler: { _ in })
        guard let error = validate(response) else {
            completionHandler(.allow)
            return
        }
        let entry = removeEntry(for: dataTask)
        completionHandler(.cancel)
        entry?.completion(error)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        dataDelegate?.urlSession?(session, dataTask: dataTask, didReceive: data)
        guard let entry = entry(for: dataTask), let response = dataTask.response else {
            return
        }
        entry.didReceiveData(data, response)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Swift.Error?) {
        taskDelegate?.urlSession?(session, task: task, didCompleteWithError: error)
        removeEntry(for: task)?.completion(error)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let request = DataLoader.redirectRequest(request, originalRequest: task.originalRequest)
        if taskDelegate?.urlSession?(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler) != nil {
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if Self.isSessionLevel(challenge),
            sessionDelegate?.urlSession?(session, didReceive: challenge, completionHandler: completionHandler) != nil
        {
            return
        }
        if taskDelegate?.urlSession?(session, task: task, didReceive: challenge, completionHandler: completionHandler) != nil {
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        taskDelegate?.urlSession?(session, taskIsWaitingForConnectivity: task)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        taskDelegate?.urlSession?(session, task: task, didFinishCollecting: metrics)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willBeginDelayedRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLSession.DelayedRequestDisposition, URLRequest?) -> Void
    ) {
        if taskDelegate?.urlSession?(session, task: task, willBeginDelayedRequest: request, completionHandler: completionHandler) != nil {
            return
        }
        completionHandler(.continueLoading, nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
    ) {
        let filtered: @Sendable (CachedURLResponse?) -> Void = { response in
            completionHandler(response.flatMap { FetchDataStage.isStorableImageData($0.data, response: $0.response) ? $0 : nil })
        }
        if dataDelegate?.urlSession?(session, dataTask: dataTask, willCacheResponse: proposedResponse, completionHandler: filtered) != nil {
            return
        }
        filtered(proposedResponse)
    }

    @available(iOS 16.0, *)
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        taskDelegate?.urlSession?(session, didCreateTask: task)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Swift.Error?) {
        sessionDelegate?.urlSession?(session, didBecomeInvalidWithError: error)
    }

    private static func isSessionLevel(_ challenge: URLAuthenticationChallenge) -> Bool {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust,
            NSURLAuthenticationMethodClientCertificate,
            NSURLAuthenticationMethodNTLM,
            NSURLAuthenticationMethodNegotiate:
            true
        default:
            false
        }
    }
}
