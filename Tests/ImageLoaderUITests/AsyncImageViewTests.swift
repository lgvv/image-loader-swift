import Foundation
import ImageLoaderTesting
@_spi(Testing) @testable import ImageLoaderUI
import Testing
import UIKit

@testable import ImageLoader

@MainActor
final class AsyncImageViewEventRecorder {
    private(set) var events: [String] = []
    private(set) var tasks: [ImageTask] = []
    private(set) var results: [Result<ImageResponse, Error>] = []

    func attach(to view: AsyncImageView) {
        view.onStart = { [weak self] task in
            self?.tasks.append(task)
            self?.events.append("start")
        }
        view.onPreview = { [weak self] _ in
            self?.events.append("preview")
        }
        view.onProgress = { [weak self] _ in
            self?.events.append("progress")
        }
        view.onSuccess = { [weak self] _ in
            self?.events.append("success")
        }
        view.onFailure = { [weak self] _ in
            self?.events.append("failure")
        }
        view.onCompletion = { [weak self] result in
            self?.results.append(result)
            self?.events.append("completion")
        }
    }

    var lastResponse: ImageResponse? {
        guard case .success(let response)? = results.last else {
            return nil
        }
        return response
    }
}

@Suite(.serialized)
@MainActor
struct AsyncImageViewTests {
    private func makeView(_ session: ImageSession) -> (AsyncImageView, AsyncImageViewEventRecorder) {
        let view = AsyncImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.session = session
        let recorder = AsyncImageViewEventRecorder()
        recorder.attach(to: view)
        return (view, recorder)
    }

    @Test func memoryCacheHitIsDisplayedSynchronouslyWithoutTransitionOrTask() {
        let loader = MockDataLoader()
        let session = makeUISession(loader: loader)
        let url = UIFixtures.url("lazy-memory")
        let image = UIFixtures.image()
        session.cache[ImageRequest(url: url)] = ImageContent(image: image)
        let (view, recorder) = makeView(session)
        var transitions = 0
        view.transition = .custom { _, _ in transitions += 1 }

        view.url = url

        #expect(view.imageView.image === image)
        #expect(view.imageView.isHidden == false)
        #expect(view.imageView.alpha == 1)
        #expect(view.placeholderView?.isHidden == true)
        #expect(view.imageTask == nil)
        #expect(transitions == 0)
        #expect(recorder.events == ["success", "completion"])
        #expect(recorder.lastResponse?.cacheType == .memory)
        #expect(loader.counts.started == 0)
    }

    @Test func memoryCacheHitWithResetDisabledReplacesPreviousImageWithoutClearing() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        let session = makeUISession(loader: loader)
        let (view, recorder) = makeView(session)
        view.url = UIFixtures.url("lazy-reuse-a")
        await uiExpectEventually { recorder.results.count == 1 }
        let cachedURL = UIFixtures.url("lazy-reuse-b")
        let cached = UIFixtures.image(UIFixtures.blue)
        session.cache[ImageRequest(url: cachedURL)] = ImageContent(image: cached)
        view.isResetEnabled = false

        view.url = cachedURL

        #expect(view.imageView.image === cached)
        #expect(view.imageView.isHidden == false)
    }

    @Test func placeholderIsVisibleWhileLoadingThenSuccessShowsImage() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let session = makeUISession(loader: loader)
        let (view, recorder) = makeView(session)
        let placeholder = UIFixtures.image(UIFixtures.green)
        view.placeholderImage = placeholder
        var transitions = 0
        view.transition = .custom { _, _ in transitions += 1 }

        view.url = UIFixtures.url("lazy-placeholder")

        let placeholderView = try #require(view.placeholderView as? UIImageView)
        #expect(placeholderView.image === placeholder)
        #expect(placeholderView.superview === view)
        #expect(placeholderView.isHidden == false)
        #expect(view.imageView.isHidden == true)
        #expect(view.imageTask != nil)

        loader.isSuspended = false
        await uiExpectEventually { recorder.results.count == 1 }

        let response = try #require(recorder.lastResponse)
        #expect(view.imageView.image === response.image)
        #expect(view.imageView.isHidden == false)
        #expect(placeholderView.isHidden == true)
        #expect(view.failureView?.isHidden ?? true)
        #expect(view.imageTask == nil)
        #expect(transitions == 1)
    }

    @Test func failureShowsFailureImageAndHidesPlaceholder() async throws {
        let loader = MockDataLoader(defaultResponse: .failure(.notConnectedToInternet))
        let session = makeUISession(loader: loader)
        let (view, recorder) = makeView(session)
        let failureImage = UIFixtures.image(UIFixtures.blue)
        view.failureImage = failureImage
        let failureView = try #require(view.failureView as? UIImageView)
        #expect(failureView.image === failureImage)
        #expect(failureView.isHidden == true)

        view.url = UIFixtures.url("lazy-failure")
        await uiExpectEventually { recorder.results.count == 1 }

        #expect(recorder.events == ["start", "failure", "completion"])
        #expect(failureView.isHidden == false)
        #expect(view.placeholderView?.isHidden == true)
        #expect(view.imageView.isHidden == true)
        #expect(view.imageView.image == nil)
    }

    @Test func failureViewAndPlaceholderOnFailureOption() async throws {
        let loader = MockDataLoader(defaultResponse: .failure(.notConnectedToInternet))
        let session = makeUISession(loader: loader)
        let (view, recorder) = makeView(session)
        let failureView = UILabel()
        view.failureView = failureView
        view.failureViewPosition = .center

        view.url = UIFixtures.url("lazy-failure-view-a")
        await uiExpectEventually { recorder.results.count == 1 }
        #expect(failureView.superview === view)
        #expect(failureView.isHidden == false)

        view.showPlaceholderOnFailure = true
        view.url = UIFixtures.url("lazy-failure-view-b")
        #expect(failureView.isHidden == true)
        await uiExpectEventually { recorder.results.count == 2 }
        #expect(failureView.isHidden == true)
        #expect(view.placeholderView?.isHidden == false)
    }

    @Test func requestChangeCancelsPreviousTaskAndIgnoresItsLateCompletion() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png(UIFixtures.red)))
        loader.setResponse(.data(UIFixtures.png(UIFixtures.blue)), for: UIFixtures.url("lazy-change-b"))
        let session = makeUISession(loader: loader)
        let (view, recorder) = makeView(session)

        view.url = UIFixtures.url("lazy-change-a")
        let first = try #require(view.imageTask)
        #expect(uiSpinUntil { first.state == .completed })
        uiDrainSessionQueue()
        #expect(recorder.results.isEmpty)

        let generation = view.loadGeneration
        view.url = UIFixtures.url("lazy-change-b")
        let second = try #require(view.imageTask)
        #expect(second !== first)
        #expect(view.loadGeneration != generation)

        await uiExpectEventually { recorder.results.count == 1 }
        await uiDrainSessionAndMain()
        await uiDrainSessionAndMain()

        #expect(recorder.results.count == 1)
        let response = try #require(recorder.lastResponse)
        #expect(response.request.url == UIFixtures.url("lazy-change-b"))
        #expect(view.imageView.image === response.image)
        #expect(recorder.events.filter { $0 == "start" }.count == 2)
    }

    @Test func detachedTaskResultIsDroppedByGenerationGuard() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let session = makeUISession(loader: loader)
        let (view, recorder) = makeView(session)

        view.url = UIFixtures.url("lazy-detached-a")
        let first = try #require(view.imageTask)
        view.imageTask = nil
        view.url = UIFixtures.url("lazy-detached-b")
        #expect(first.state == .running)

        loader.isSuspended = false
        await uiExpectEventually { first.state == .completed && recorder.results.count == 1 }
        await uiDrainSessionAndMain()
        await uiDrainSessionAndMain()

        #expect(recorder.results.count == 1)
        #expect(recorder.lastResponse?.request.url == UIFixtures.url("lazy-detached-b"))
    }

    @Test func requestChangeCancelsRunningTask() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let session = makeUISession(loader: loader)
        let (view, recorder) = makeView(session)

        view.url = UIFixtures.url("lazy-running-a")
        let first = try #require(view.imageTask)
        view.request = ImageRequest(url: UIFixtures.url("lazy-running-b"))
        let second = try #require(view.imageTask)

        #expect(first.state == .cancelled)
        #expect(second.state == .running)
        #expect(view.url == UIFixtures.url("lazy-running-b"))
        loader.isSuspended = false
        await uiExpectEventually { recorder.results.count == 1 }
        await uiDrainSessionAndMain()
        #expect(recorder.results.count == 1)
        #expect(recorder.lastResponse?.request.url == UIFixtures.url("lazy-running-b"))
    }

    @Test func nilURLResetsViewAndReportsMissingRequest() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        let session = makeUISession(loader: loader)
        let (view, recorder) = makeView(session)
        view.url = UIFixtures.url("lazy-nil")
        await uiExpectEventually { recorder.results.count == 1 }
        #expect(view.imageView.image != nil)

        view.url = nil

        #expect(view.request == nil)
        #expect(view.imageView.image == nil)
        #expect(view.imageView.isHidden == true)
        #expect(view.imageTask == nil)
        #expect(recorder.results.count == 2)
        guard case .failure(let error)? = recorder.results.last, case .imageRequestMissing? = error.imageSessionError else {
            Issue.record("Expected imageRequestMissing, got \(String(describing: recorder.results.last))")
            return
        }
        #expect(Array(recorder.events.suffix(2)) == ["failure", "completion"])
    }

    @Test func resetCancelsTaskAndClearsImage() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let session = makeUISession(loader: loader)
        let (view, recorder) = makeView(session)

        view.url = UIFixtures.url("lazy-reset")
        let task = try #require(view.imageTask)
        view.reset()

        #expect(task.state == .cancelled)
        #expect(view.imageTask == nil)
        #expect(view.placeholderView?.isHidden == true)
        loader.isSuspended = false
        await uiDrainSessionAndMain()
        await uiDrainSessionAndMain()
        #expect(recorder.results.isEmpty)
        #expect(view.imageView.image == nil)
    }

    @Test func animatedGIFPlaysInAnimatedImageView() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.gif([UIFixtures.red, UIFixtures.green, UIFixtures.blue])))
        let session = makeUISession(loader: loader)
        let (view, recorder) = makeView(session)

        view.url = UIFixtures.url("lazy-animated.gif")
        await uiExpectEventually { recorder.results.count == 1 }

        let animatedView = try #require(view.imageView as? AnimatedImageView)
        let response = try #require(recorder.lastResponse)
        let source = try #require(animatedView.animatedImageSource)
        #expect(source === response.content.animatedImageSource)
        #expect(source.frameCount == 3)
        source.prefetchFrames([1])
        await uiExpectEventually { source.cachedFrame(at: 1) != nil }
        #expect(animatedView.advanceAnimation(by: 0.15))
        #expect(animatedView.currentFrameIndex == 1)

        view.url = nil
        #expect(animatedView.animatedImageSource == nil)
    }

    @Test func makeImageViewReplacesDefaultImageView() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        let session = makeUISession(loader: loader)
        let (view, recorder) = makeView(session)
        let custom = UIView()
        view.makeImageView = { _ in custom }

        view.url = UIFixtures.url("lazy-custom")
        await uiExpectEventually { recorder.results.count == 1 }

        #expect(custom.superview === view)
        #expect(view.imageView.isHidden == true)
        view.reset()
        #expect(custom.superview == nil)
    }

    @Test func callbacksArriveInDocumentedOrder() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png(width: 64, height: 64), chunkCount: 4))
        let session = makeUISession(loader: loader)
        let (view, recorder) = makeView(session)
        view.priority = .high

        view.url = UIFixtures.url("lazy-order")
        let task = try #require(view.imageTask)
        #expect(task.priority == .high)
        #expect(recorder.events == ["start"])
        #expect(recorder.tasks.first === task)
        await uiExpectEventually { recorder.results.count == 1 }

        let events = recorder.events
        #expect(events.first == "start")
        #expect(Array(events.suffix(2)) == ["success", "completion"])
        let middle = events.dropFirst().dropLast(2)
        #expect(!middle.isEmpty)
        #expect(middle.allSatisfy { $0 == "progress" })
        #expect(view.imageTask == nil)
    }

    @Test func processorsApplyOnlyWhenRequestHasNone() throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let session = makeUISession(loader: loader)
        let (view, _) = makeView(session)
        view.filters = [UITestFilter(name: "view")]

        view.url = UIFixtures.url("lazy-filters-a")
        #expect(try #require(view.imageTask).request.filters.map(\.identifier) == ["ui-test/view"])
        view.request = ImageRequest(url: UIFixtures.url("lazy-filters-b"), filters: [UITestFilter(name: "request")])
        #expect(try #require(view.imageTask).request.filters.map(\.identifier) == ["ui-test/request"])
        view.cancel()
    }

    @Test func deallocationCancelsTask() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let session = makeUISession(loader: loader)
        weak var weakView: AsyncImageView?
        var task: ImageTask?

        autoreleasepool {
            let view = AsyncImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
            view.session = session
            view.url = UIFixtures.url("lazy-dealloc")
            task = view.imageTask
            weakView = view
        }

        #expect(weakView == nil)
        #expect(task?.state == .cancelled)
        loader.isSuspended = false
        await uiDrainSessionAndMain()
    }

    @Test func accessibilityDefaultsMirrorUIKit() {
        let view = AsyncImageView(frame: .zero)
        let reference = UIImageView()
        #expect(view.imageView.isAccessibilityElement == reference.isAccessibilityElement)
        #expect(view.imageView.accessibilityTraits == reference.accessibilityTraits)
        #expect(view.isAccessibilityElement == UIView().isAccessibilityElement)
    }
}
