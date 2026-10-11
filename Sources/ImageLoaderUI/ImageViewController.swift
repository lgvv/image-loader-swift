import Foundation
import ObjectiveC
import UIKit

@MainActor
final class ImageViewController {
    typealias ProgressHandler = @MainActor @Sendable (_ response: ImageResponse?, _ completed: Int64, _ total: Int64) -> Void
    typealias CompletionHandler = @MainActor @Sendable (_ result: Result<ImageResponse, ImageSession.Error>) -> Void

    private(set) weak var view: ImageDisplayingView?
    private var task: ImageTask?
    private var options = ImageLoadingOptions()
    weak var transitionSnapshot: UIView?
    private(set) var generation: UInt64 = 0

    private enum MemoryCacheHit {
        case none
        case preview
        case final
    }

    private static let associatedObjectKey = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))

    private init(view: ImageDisplayingView) {
        self.view = view
    }

    deinit {
        task?.cancel()
    }

    static func controller(for view: ImageDisplayingView) -> ImageViewController {
        if let existing = existingController(for: view) {
            return existing
        }
        let controller = ImageViewController(view: view)
        objc_setAssociatedObject(view, associatedObjectKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return controller
    }

    static func existingController(for view: ImageDisplayingView) -> ImageViewController? {
        objc_getAssociatedObject(view, associatedObjectKey) as? ImageViewController
    }

    var currentTask: ImageTask? {
        task
    }

    func load(
        _ request: ImageRequest?,
        options: ImageLoadingOptions,
        progress: ProgressHandler?,
        completion: CompletionHandler?
    ) -> ImageTask? {
        cancelOutstandingTask()
        guard let view else {
            return nil
        }
        self.options = options
        if options.isPrepareForReuseEnabled {
            view.layer.removeAllAnimations()
        }
        guard var request else {
            failWithMissingRequest(in: view, options: options, completion: completion)
            return nil
        }
        if request.filters.isEmpty, !options.filters.isEmpty {
            request.filters = options.filters
        }
        let session = options.session ?? ImageSession.shared
        switch presentMemoryCacheHit(for: request, session: session, options: options, completion: completion) {
        case .final:
            return nil
        case .preview:
            break
        case .none:
            presentPlaceholder(in: view, options: options)
        }
        let task = startLoading(request, session: session, rendersPreviews: options.isProgressiveRenderingEnabled, progress: progress, completion: completion)
        self.task = task
        return task
    }

    private func failWithMissingRequest(in view: ImageDisplayingView, options: ImageLoadingOptions, completion: CompletionHandler?) {
        if options.isPrepareForReuseEnabled {
            view.imageLoader_display(image: nil, data: nil)
        }
        let result = Result<ImageResponse, ImageSession.Error>.failure(.imageRequestMissing)
        finish(with: result, isFromMemory: true)
        completion?(result)
    }

    private func presentMemoryCacheHit(
        for request: ImageRequest,
        session: ImageSession,
        options: ImageLoadingOptions,
        completion: CompletionHandler?
    ) -> MemoryCacheHit {
        guard let cached = session.cache[request] else {
            return .none
        }
        if cached.isPreview {
            guard options.isProgressiveRenderingEnabled else {
                return .none
            }
            present(cached, as: .success, isFromMemory: true)
            return .preview
        }
        present(cached, as: .success, isFromMemory: true)
        completion?(.success(ImageResponse(content: cached, request: request, cacheType: .memory)))
        return .final
    }

    private func presentPlaceholder(in view: ImageDisplayingView, options: ImageLoadingOptions) {
        if let placeholder = options.placeholder {
            present(ImageContent(image: placeholder), as: .placeholder, isFromMemory: true)
        } else if options.isPrepareForReuseEnabled {
            view.imageLoader_display(image: nil, data: nil)
        }
    }

    private func startLoading(
        _ request: ImageRequest,
        session: ImageSession,
        rendersPreviews: Bool,
        progress: ProgressHandler?,
        completion: CompletionHandler?
    ) -> ImageTask {
        let started = generation
        return session.loadImage(
            with: request,
            progress: { [weak self] response, completed, total in
                guard let self, self.generation == started else {
                    return
                }
                if let response, rendersPreviews {
                    self.present(response.content, as: .success, isFromMemory: false)
                }
                progress?(response, completed, total)
            },
            completion: { [weak self] result in
                guard let self, self.generation == started else {
                    return
                }
                self.finish(with: result, isFromMemory: false)
                completion?(result)
            }
        )
    }

    func cancelOutstandingTask() {
        generation &+= 1
        let outstanding = task
        task = nil
        outstanding?.cancel()
        removeTransitionSnapshot()
    }

    private func finish(with result: Result<ImageResponse, ImageSession.Error>, isFromMemory: Bool) {
        task = nil
        switch result {
        case .success(let response):
            present(response.content, as: .success, isFromMemory: isFromMemory)
        case .failure:
            guard let failureImage = options.failureImage else {
                return
            }
            present(ImageContent(image: failureImage), as: .failure, isFromMemory: isFromMemory)
        }
    }

    private func present(_ content: ImageContent, as outcome: ImageLoadingOptions.Outcome, isFromMemory: Bool) {
        guard let view else {
            return
        }
        let presentation = options.presentation(for: outcome)
        var content = content
        if let tintColor = presentation.tintColor {
            content.image = content.image.withRenderingMode(.alwaysTemplate)
            content.userInfo[.animatedImageKey] = nil
            view.tintColor = tintColor
        }
        let transition = isFromMemory && !options.alwaysTransition ? nil : presentation.transition
        switch transition?.kind {
        case .none:
            Self.show(content, in: view)
        case .custom(let closure):
            closure(view, content.image)
        case .fadeIn(let duration, let animationOptions):
            fade(to: content, in: view, duration: duration, animationOptions: animationOptions, contentMode: presentation.contentMode)
        }
        if let contentMode = presentation.contentMode {
            view.contentMode = contentMode
        }
    }

    static func show(_ content: ImageContent, in view: ImageDisplayingView) {
        if let animatedView = view as? AnimatedImageView {
            animatedView.display(content)
        } else {
            view.imageLoader_display(image: content.image, data: content.data)
        }
    }
}
