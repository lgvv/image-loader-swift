import Foundation
import ImageLoaderTesting
@_spi(Testing) @testable import ImageLoaderUI
import Testing
import UIKit

@testable import ImageLoader

@Suite(.serialized)
@MainActor
struct ImageViewContractTests {
    @Test func c1MemoryCacheHitIsDisplayedSynchronouslyWithoutTask() {
        let loader = MockDataLoader()
        let session = makeUISession(loader: loader)
        let url = UIFixtures.url("c1")
        let image = UIFixtures.image()
        session.cache[ImageRequest(url: url)] = ImageContent(image: image)
        let view = UIImageView()
        let recorder = UIResultRecorder()

        let task = loadImage(with: url, options: makeUIOptions(session), into: view) { recorder.record($0) }

        #expect(task == nil)
        #expect(recorder.count == 1)
        #expect(recorder.lastResponse?.cacheType == .memory)
        #expect(view.image === image)
        #expect(loader.counts.started == 0)
        #expect(ImageViewController.existingController(for: view)?.currentTask == nil)
    }

    @Test func c2NilRequestPreparesForReuseShowsFailureImageAndReportsMissingRequest() {
        let session = makeUISession(loader: MockDataLoader())
        let failureImage = UIFixtures.image(UIFixtures.blue)
        let view = UIImageView(image: UIFixtures.image())
        let recorder = UIResultRecorder()

        let task = loadImage(with: nil as URL?, options: makeUIOptions(session) { $0.failureImage = failureImage }, into: view) { recorder.record($0) }

        #expect(task == nil)
        #expect(recorder.count == 1)
        guard case .failure(.imageRequestMissing)? = recorder.results.first else {
            Issue.record("Expected imageRequestMissing, got \(String(describing: recorder.results.first))")
            return
        }
        #expect(view.image === failureImage)

        let plainView = UIImageView(image: UIFixtures.image())
        loadImage(with: nil as ImageRequest?, options: makeUIOptions(session), into: plainView) { recorder.record($0) }
        #expect(plainView.image == nil)
        #expect(recorder.count == 2)
    }

    @Test func c3NewLoadCancelsPreviousTaskOfSameView() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let session = makeUISession(loader: loader)
        let view = UIImageView()
        let options = makeUIOptions(session)

        let first = try #require(loadImage(with: UIFixtures.url("c3-a"), options: options, into: view))
        let second = try #require(loadImage(with: UIFixtures.url("c3-b"), options: options, into: view))

        #expect(first.state == .cancelled)
        #expect(second.state == .running)
        #expect(ImageViewController.existingController(for: view)?.currentTask === second)
        loader.isSuspended = false
        await uiWaitUntil { second.state == .completed }
    }

    @Test func c4CompletionAndProgressAreNeverCalledAfterCancellation() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png(), chunkCount: 4))
        loader.isSuspended = true
        let session = makeUISession(loader: loader)
        let view = UIImageView()
        let recorder = UIResultRecorder()

        let started = loadImage(
            with: UIFixtures.url("c4"),
            options: makeUIOptions(session),
            into: view,
            progress: { recorder.recordProgress($0, $1, $2) },
            completion: { recorder.record($0) }
        )
        let task = try #require(started)
        await uiExpectEventually { loader.counts.started == 1 }
        cancelRequest(for: view)
        #expect(task.state == .cancelled)
        loader.isSuspended = false
        await uiExpectEventually { loader.counts.cancelled + loader.counts.completed == 1 }
        await uiDrainSessionAndMain()
        await uiDrainSessionAndMain()

        #expect(recorder.count == 0)
        #expect(recorder.progressEvents.isEmpty)
        #expect(view.image == nil)
    }

    @Test func c5GenerationGuardDropsCallbackOfTaskThatFinishedBeforeNextLoad() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png(UIFixtures.red)))
        loader.setResponse(.data(UIFixtures.png(UIFixtures.blue)), for: UIFixtures.url("c5-b"))
        let session = makeUISession(loader: loader)
        let view = UIImageView()
        let options = makeUIOptions(session)
        let stale = UIResultRecorder()
        let fresh = UIResultRecorder()

        let started = loadImage(with: UIFixtures.url("c5-a"), options: options, into: view) { stale.record($0) }
        let first = try #require(started)
        #expect(uiSpinUntil { first.state == .completed })
        uiDrainSessionQueue()
        #expect(stale.count == 0)

        let generationBefore = try #require(ImageViewController.existingController(for: view)).generation
        loadImage(with: UIFixtures.url("c5-b"), options: options, into: view) { fresh.record($0) }
        #expect(ImageViewController.existingController(for: view)?.generation == generationBefore &+ 1)
        #expect(first.state == .completed)

        await uiExpectEventually { fresh.count == 1 }
        await uiDrainSessionAndMain()
        #expect(stale.count == 0)
        let response = try #require(fresh.lastResponse)
        #expect(view.image === response.image)
    }

    @Test func c6ViewDeallocationCancelsItsTask() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let session = makeUISession(loader: loader)
        let recorder = UIResultRecorder()
        weak var weakView: UIImageView?
        var task: ImageTask?

        autoreleasepool {
            let view = UIImageView()
            weakView = view
            task = loadImage(with: UIFixtures.url("c6"), options: makeUIOptions(session), into: view) { recorder.record($0) }
        }

        #expect(weakView == nil)
        #expect(task?.state == .cancelled)
        loader.isSuspended = false
        await uiDrainSessionAndMain()
        #expect(recorder.count == 0)
    }

    @Test func c7ControllerDeinitOnBackgroundThreadCancelsTask() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let session = makeUISession(loader: loader)
        let handoff = UIControllerHandoff()
        weak var weakController: ImageViewController?
        var task: ImageTask?

        autoreleasepool {
            let view = UIImageView()
            task = loadImage(with: UIFixtures.url("c7"), options: makeUIOptions(session), into: view)
            let controller = ImageViewController.existingController(for: view)
            weakController = controller
            handoff.controller = controller
        }
        #expect(weakController != nil)

        let releasedOffMain = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue(label: "ImageLoaderUITests.ImageViewExtensionsTests", qos: .userInitiated).async {
                handoff.controller = nil
                continuation.resume(returning: !Thread.isMainThread)
            }
        }

        #expect(releasedOffMain)
        #expect(weakController == nil)
        #expect(task?.state == .cancelled)
        loader.isSuspended = false
        await uiDrainSessionAndMain()
    }

    @Test func c8OptionProcessorsApplyOnlyWhenRequestHasNone() throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let session = makeUISession(loader: loader)
        let options = makeUIOptions(session) { $0.filters = [UITestFilter(name: "options")] }

        let plain = try #require(loadImage(with: ImageRequest(url: UIFixtures.url("c8-a")), options: options, into: UIImageView()))
        let own = try #require(
            loadImage(
                with: ImageRequest(url: UIFixtures.url("c8-b"), filters: [UITestFilter(name: "request")]),
                options: options,
                into: UIImageView()
            ))

        #expect(plain.request.filters.map(\.identifier) == ["ui-test/options"])
        #expect(own.request.filters.map(\.identifier) == ["ui-test/request"])
        plain.cancel()
        own.cancel()
    }

    @Test func c9TransitionRunsOnlyForNonMemoryResultsUnlessAlwaysTransition() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        let session = makeUISession(loader: loader)
        let cachedURL = UIFixtures.url("c9-cached")
        session.cache[ImageRequest(url: cachedURL)] = ImageContent(image: UIFixtures.image())
        let transitions = UITransitionRecorder()
        let transition = ImageLoadingOptions.Transition.custom { view, image in
            MainActor.assumeIsolated {
                transitions.count += 1
                view.imageLoader_display(image: image, data: nil)
            }
        }
        let options = makeUIOptions(session) { $0.transition = transition }
        let view = UIImageView()

        loadImage(with: cachedURL, options: options, into: view)
        #expect(transitions.count == 0)
        #expect(view.image != nil)

        let recorder = UIResultRecorder()
        loadImage(with: UIFixtures.url("c9-network"), options: options, into: view) { recorder.record($0) }
        await uiExpectEventually { recorder.count == 1 }
        #expect(transitions.count == 1)

        var always = options
        always.alwaysTransition = true
        loadImage(with: cachedURL, options: always, into: view)
        #expect(transitions.count == 2)
    }

    @Test func c10AnimatedImageViewStartsPlaybackAndSharesFramesThroughMemoryCache() async throws {
        let url = UIFixtures.url("c10.gif")
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.gif([UIFixtures.red, UIFixtures.green, UIFixtures.blue])))
        let session = makeUISession(loader: loader)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let first = AnimatedImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        window.addSubview(first)
        let recorder = UIResultRecorder()

        loadImage(with: url, options: makeUIOptions(session), into: first) { recorder.record($0) }
        await uiExpectEventually { recorder.count == 1 }

        let cached = try #require(session.cache[ImageRequest(url: url)]?.animatedImageSource)
        #expect(first.animatedImageSource === cached)
        #expect(first.isDisplayLinkActive)
        #expect(first.isAnimating)

        let second = AnimatedImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        window.addSubview(second)
        let task = loadImage(with: url, options: makeUIOptions(session), into: second) { recorder.record($0) }
        #expect(task == nil)
        #expect(recorder.count == 2)
        #expect(second.animatedImageSource === cached)
        #expect(second.isDisplayLinkActive)
        #expect(loader.counts.started == 1)
        first.removeFromSuperview()
        second.removeFromSuperview()
    }

    @Test func dv29CustomDisplayingViewReceivesImageAndData() async throws {
        let url = UIFixtures.url("dv29.gif")
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.gif([UIFixtures.red, UIFixtures.green])))
        let session = makeUISession(loader: loader)
        let view = UIRecordingDisplayView()
        let recorder = UIResultRecorder()

        loadImage(with: url, options: makeUIOptions(session), into: view) { recorder.record($0) }
        await uiExpectEventually { recorder.count == 1 }

        let last = try #require(view.displayed.last)
        #expect(last.image != nil)
        #expect(last.data != nil)
        #expect(NSStringFromSelector(#selector(ImageLoader_ImageDisplaying.imageLoader_display(image:data:))) == "imageLoader_displayWithImage:data:")
    }

    @Test func placeholderIsShownWhileLoadingAndReplacedByResult() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let session = makeUISession(loader: loader)
        let placeholder = UIFixtures.image(UIFixtures.green)
        let view = UIImageView()
        let recorder = UIResultRecorder()

        loadImage(with: UIFixtures.url("placeholder"), options: makeUIOptions(session) { $0.placeholder = placeholder }, into: view) { recorder.record($0) }
        #expect(view.image === placeholder)
        loader.isSuspended = false
        await uiExpectEventually { recorder.count == 1 }
        #expect(view.image === recorder.lastResponse?.image)
    }

    @Test func failureImageIsShownOnFailure() async throws {
        let loader = MockDataLoader(defaultResponse: .failure(.notConnectedToInternet))
        let session = makeUISession(loader: loader)
        let failureImage = UIFixtures.image(UIFixtures.blue)
        let view = UIImageView()
        let recorder = UIResultRecorder()

        loadImage(with: UIFixtures.url("failure"), options: makeUIOptions(session) { $0.failureImage = failureImage }, into: view) { recorder.record($0) }
        await uiExpectEventually { recorder.count == 1 }
        guard case .failure(.dataLoadingFailed)? = recorder.results.first else {
            Issue.record("Expected dataLoadingFailed, got \(String(describing: recorder.results.first))")
            return
        }
        #expect(view.image === failureImage)
    }

    @Test func contentModesAndTintColorsFollowOutcome() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let session = makeUISession(loader: loader)
        let options = makeUIOptions(session) {
            $0.placeholder = UIFixtures.image(UIFixtures.green)
            $0.contentModes = .init(success: .scaleAspectFill, failure: .center, placeholder: .scaleToFill)
            $0.tintColors = .init(success: nil, failure: nil, placeholder: .systemPink)
        }
        let view = UIImageView()
        let recorder = UIResultRecorder()

        loadImage(with: UIFixtures.url("modes"), options: options, into: view) { recorder.record($0) }
        #expect(view.contentMode == .scaleToFill)
        #expect(view.tintColor == .systemPink)
        #expect(view.image?.renderingMode == .alwaysTemplate)

        loader.isSuspended = false
        await uiExpectEventually { recorder.count == 1 }
        #expect(view.contentMode == .scaleAspectFill)
        #expect(view.image === recorder.lastResponse?.image)
    }

    @Test func fadeInTransitionDisplaysResultAndCleansUpCrossDissolveSnapshot() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let session = makeUISession(loader: loader)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let content = UIView(frame: window.bounds)
        window.addSubview(content)
        let view = UIImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        content.addSubview(view)
        let options = makeUIOptions(session) {
            $0.placeholder = UIFixtures.image(UIFixtures.green)
            $0.transition = .fadeIn(duration: 0.01)
            $0.contentModes = .init(success: .scaleAspectFill, failure: .center, placeholder: .center)
        }
        let recorder = UIResultRecorder()

        loadImage(with: UIFixtures.url("fade"), options: options, into: view) { recorder.record($0) }
        #expect(view.contentMode == .center)
        loader.isSuspended = false
        await uiExpectEventually { recorder.count == 1 }

        #expect(view.image === recorder.lastResponse?.image)
        #expect(view.contentMode == .scaleAspectFill)
        await uiExpectEventually { content.subviews.count == 1 && view.alpha == 1 }
        window.isHidden = true
    }

    @Test func rapidLoadsOnSameViewDeliverOnlyTheLastRequest() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let session = makeUISession(loader: loader)
        let view = UIImageView()
        let options = makeUIOptions(session)
        let recorders = (0..<200).map { _ in UIResultRecorder() }
        var tasks: [ImageTask] = []

        for index in 0..<200 {
            let recorder = recorders[index]
            if let task = loadImage(with: UIFixtures.url("rapid-\(index)"), options: options, into: view, completion: { recorder.record($0) }) {
                tasks.append(task)
            }
        }
        #expect(tasks.count == 200)
        #expect(tasks.dropLast().allSatisfy { $0.state == .cancelled })

        loader.isSuspended = false
        let last = recorders[199]
        await uiExpectEventually(timeout: 10) { last.count == 1 }
        await uiDrainSessionAndMain()
        await uiDrainSessionAndMain()

        #expect(recorders.dropLast().allSatisfy { $0.count == 0 })
        #expect(last.count == 1)
        let response = try #require(last.lastResponse)
        #expect(response.request.url == UIFixtures.url("rapid-199"))
        #expect(view.image === response.image)
    }

    @Test(arguments: [false, true])
    func memoryCachedPreviewIsShownWhileFinalImageLoads(_ isPrepareForReuseEnabled: Bool) async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png(UIFixtures.blue)))
        loader.isSuspended = true
        let session = makeUISession(loader: loader)
        let url = UIFixtures.url("preview-in-memory-\(isPrepareForReuseEnabled)")
        let preview = UIFixtures.image(UIFixtures.red)
        session.cache[ImageRequest(url: url)] = ImageContent(image: preview, isPreview: true)
        let view = UIImageView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
        let recorder = UIResultRecorder()
        let options = makeUIOptions(session) { $0.isPrepareForReuseEnabled = isPrepareForReuseEnabled }

        let started = loadImage(with: url, options: options, into: view) { recorder.record($0) }

        let task = try #require(started)
        #expect(view.image === preview)
        #expect(recorder.count == 0)
        loader.isSuspended = false
        await uiExpectEventually { recorder.count == 1 }
        let response = try #require(recorder.lastResponse)
        #expect(!response.content.isPreview)
        #expect(view.image === response.image)
        #expect(task.state == .completed)
    }

    @Test func cancelRequestWithoutPriorLoadDoesNothing() {
        let view = UIImageView()
        cancelRequest(for: view)
        #expect(ImageViewController.existingController(for: view) == nil)
    }

    private struct CrossDissolveScene {
        let window: UIWindow
        let content: UIView
        let view: UIImageView
        let loader: MockDataLoader
        let session: ImageSession
    }

    private func makeCrossDissolveScene() -> CrossDissolveScene {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let content = UIView(frame: window.bounds)
        window.addSubview(content)
        window.isHidden = false
        let view = UIImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        content.addSubview(view)
        return CrossDissolveScene(window: window, content: content, view: view, loader: loader, session: makeUISession(loader: loader))
    }

    private func startCrossDissolve(in scene: CrossDissolveScene, options: ImageLoadingOptions, previous: UIImage) async -> UIImageView? {
        scene.session.cache.storeCachedImage(ImageContent(image: previous), for: ImageRequest(url: UIFixtures.url("dissolve-previous")), caches: .memory)
        loadImage(with: UIFixtures.url("dissolve-previous"), options: options, into: scene.view)
        scene.view.contentMode = .center
        let recorder = UIResultRecorder()
        loadImage(with: UIFixtures.url("dissolve-network"), options: options, into: scene.view) { recorder.record($0) }
        scene.loader.isSuspended = false
        await uiExpectEventually { recorder.count == 1 }
        return scene.content.subviews.first { $0 !== scene.view } as? UIImageView
    }

    @Test func reuseDuringCrossDissolveRemovesPreviousSnapshot() async throws {
        let scene = makeCrossDissolveScene()
        let options = makeUIOptions(scene.session) {
            $0.isPrepareForReuseEnabled = false
            $0.transition = .fadeIn(duration: 5)
            $0.contentModes = .init(success: .scaleAspectFill, failure: .center, placeholder: .center)
        }
        let previous = UIFixtures.image(UIFixtures.green)
        let snapshot = try #require(await startCrossDissolve(in: scene, options: options, previous: previous))
        #expect(snapshot.image === previous)

        let reused = UIFixtures.image(UIFixtures.green)
        scene.session.cache.storeCachedImage(ImageContent(image: reused), for: ImageRequest(url: UIFixtures.url("dissolve-reused")), caches: .memory)
        loadImage(with: UIFixtures.url("dissolve-reused"), options: options, into: scene.view)

        #expect(snapshot.superview == nil)
        #expect(scene.content.subviews.count == 1)
        #expect(scene.view.image === reused)
        #expect(scene.view.alpha == 1)
        #expect(scene.view.layer.animation(forKey: "opacity") == nil)
        scene.window.isHidden = true
    }

    @Test func cancelRequestDuringCrossDissolveRemovesSnapshot() async throws {
        let scene = makeCrossDissolveScene()
        let options = makeUIOptions(scene.session) {
            $0.placeholder = UIFixtures.image(UIFixtures.green)
            $0.transition = .fadeIn(duration: 5)
            $0.contentModes = .init(success: .scaleAspectFill, failure: .center, placeholder: .center)
        }
        let snapshot = try #require(await startCrossDissolve(in: scene, options: options, previous: UIFixtures.image(UIFixtures.green)))
        cancelRequest(for: scene.view)
        #expect(snapshot.superview == nil)
        #expect(scene.content.subviews.count == 1)
        scene.window.isHidden = true
    }

    @Test func memoryCachedPreviewIsShownInsteadOfPlaceholderUntilFinalImage() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let session = makeUISession(loader: loader)
        let view = UIImageView()
        let placeholder = UIFixtures.image(UIFixtures.green)
        let preview = UIFixtures.image(UIFixtures.green)
        let options = makeUIOptions(session) { $0.placeholder = placeholder }
        let request = ImageRequest(url: UIFixtures.url("cached-preview"))
        session.cache.storeCachedImage(ImageContent(image: preview, isPreview: true), for: request, caches: .memory)
        let recorder = UIResultRecorder()

        let task = loadImage(with: request, options: options, into: view) { recorder.record($0) }
        #expect(task != nil)
        #expect(view.image === preview)
        #expect(recorder.count == 0)

        loader.isSuspended = false
        await uiExpectEventually { recorder.count == 1 }
        #expect(recorder.lastResponse?.cacheType == nil)
        #expect(view.image === recorder.lastResponse?.image)
    }

    @Test func memoryCachedPreviewIsSkippedWhenProgressiveRenderingIsDisabled() {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let session = makeUISession(loader: loader)
        let view = UIImageView()
        let placeholder = UIFixtures.image(UIFixtures.green)
        let options = makeUIOptions(session) {
            $0.placeholder = placeholder
            $0.isProgressiveRenderingEnabled = false
        }
        let request = ImageRequest(url: UIFixtures.url("cached-preview-off"))
        session.cache.storeCachedImage(ImageContent(image: UIFixtures.image(UIFixtures.green), isPreview: true), for: request, caches: .memory)
        loadImage(with: request, options: options, into: view)
        #expect(view.image === placeholder)
        cancelRequest(for: view)
    }
}

final class UIControllerHandoff: @unchecked Sendable {
    var controller: ImageViewController?
}

@MainActor
final class UITransitionRecorder {
    var count = 0
}

final class UIRecordingDisplayView: UIView, ImageLoader_ImageDisplaying {
    private(set) var displayed: [(image: UIImage?, data: Data?)] = []

    func imageLoader_display(image: UIImage?, data: Data?) {
        displayed.append((image, data))
    }
}
