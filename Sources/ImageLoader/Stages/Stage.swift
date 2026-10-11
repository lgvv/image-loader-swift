import Foundation

class Stage<Value: Sendable>: SharedTask<Value>, @unchecked Sendable {
    let session: ImageSession
    let request: ImageRequest

    private var operationGeneration = 0

    init(_ session: ImageSession, _ request: ImageRequest) {
        self.session = session
        self.request = request
    }

    var hasDirectSubscribers: Bool {
        hasSubscriber(of: ImageTask.self)
    }

    var imageTasks: [ImageTask] {
        subscribers.flatMap { subscriber -> [ImageTask] in
            if let task = subscriber as? ImageTask {
                return [task]
            }
            if let node = subscriber as? ImageTaskSubscribers {
                return node.imageTasks
            }
            return []
        }
    }

    func perform<T: Sendable>(
        on queue: TaskQueue,
        worker: DispatchQueue,
        work: @escaping @Sendable () -> T,
        completion: @escaping @Sendable (T) -> Void
    ) {
        SessionQueue.assertOnQueue()
        operationGeneration += 1
        let generation = operationGeneration
        operation = queue.add(priority: priority) { [weak self] finish in
            guard let self, !self.isDisposed else {
                finish()
                return
            }
            worker.async { [weak self] in
                let result = autoreleasepool { work() }
                finish()
                SessionQueue.async { [weak self] in
                    guard let self, generation == self.operationGeneration else { return }
                    self.operation = nil
                    guard !self.isDisposed else { return }
                    completion(result)
                }
            }
        }
    }

    func decode(
        _ context: ImageDecodingContext,
        decoder: any ImageDecoding,
        completion: @escaping @Sendable (Result<ImageResponse, ImageSession.Error>) -> Void
    ) {
        let work: @Sendable () -> Result<ImageResponse, ImageSession.Error> = {
            SessionSignposter.shared.interval(context.isCompleted ? "DecodeImageData" : "DecodeProgressiveImageData") {
                do {
                    return .success(try decoder.decode(context))
                } catch {
                    return .failure(.decodingFailed(decoder: decoder, context: context, error: error))
                }
            }
        }
        guard decoder.isAsynchronous else {
            completion(work())
            return
        }
        perform(on: session.configuration.imageDecodingQueue, worker: SessionWorkers.decoding, work: work, completion: completion)
    }

    func cancelCurrentOperation() {
        operationGeneration += 1
        operation?.cancel()
        operation = nil
    }

    func makeDiskCacheKey(for request: ImageRequest) -> String {
        session.cache.makeDiskCacheKey(for: request)
    }
}

protocol ImageTaskSubscribers {
    var imageTasks: [ImageTask] { get }
}

extension Stage: ImageTaskSubscribers {}
