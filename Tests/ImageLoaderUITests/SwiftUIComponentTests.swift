import Combine
import Foundation
import ImageLoaderTesting
@_spi(Testing) @testable import ImageLoaderUI
import SwiftUI
import Testing
import UIKit

@testable import ImageLoader

@Suite(.serialized)
@MainActor
struct FetchImageTests {
    @Test func loadPublishesLoadingThenResult() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        let model = AsyncImageModel()
        model.session = makeUISession(loader: loader)
        let started = UIFetchRecorder()
        model.onStart = { started.tasks.append($0) }
        model.onCompletion = { started.results.append($0) }

        model.load(UIFixtures.url("fetch-load"))

        #expect(model.isLoading)
        #expect(model.result == nil)
        #expect(started.tasks.count == 1)
        await uiExpectEventually { model.result != nil }
        #expect(!model.isLoading)
        #expect(model.image != nil)
        #expect(model.imageContent != nil)
        #expect(started.results.count == 1)
        guard case .success? = model.result else {
            Issue.record("Expected success, got \(String(describing: model.result))")
            return
        }
    }

    @Test func memoryHitIsAppliedSynchronously() {
        let loader = MockDataLoader()
        let session = makeUISession(loader: loader)
        let url = UIFixtures.url("fetch-memory")
        let image = UIFixtures.image()
        session.cache[ImageRequest(url: url)] = ImageContent(image: image)
        let model = AsyncImageModel()
        model.session = session
        let started = UIFetchRecorder()
        model.onStart = { started.tasks.append($0) }

        model.load(url)

        #expect(!model.isLoading)
        #expect(model.imageContent?.image === image)
        guard case .success(let response)? = model.result else {
            Issue.record("Expected synchronous success")
            return
        }
        #expect(response.cacheType == .memory)
        #expect(started.tasks.isEmpty)
        #expect(loader.counts.started == 0)
    }

    @Test func cancelPreventsResult() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let model = AsyncImageModel()
        model.session = makeUISession(loader: loader)
        let recorder = UIFetchRecorder()
        model.onStart = { recorder.tasks.append($0) }
        model.onCompletion = { recorder.results.append($0) }

        model.load(UIFixtures.url("fetch-cancel"))
        let task = try #require(recorder.tasks.first)
        await uiExpectEventually { loader.counts.started == 1 }
        model.cancel()

        #expect(task.state == .cancelled)
        loader.isSuspended = false
        await uiExpectEventually { loader.counts.cancelled + loader.counts.completed == 1 }
        await uiDrainSessionAndMain()
        #expect(model.result == nil)
        #expect(recorder.results.isEmpty)
    }

    @Test func resetClearsState() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        let model = AsyncImageModel()
        model.session = makeUISession(loader: loader)
        model.load(UIFixtures.url("fetch-reset"))
        _ = model.progress
        await uiExpectEventually { model.result != nil }

        model.reset()

        #expect(model.result == nil)
        #expect(model.imageContent == nil)
        #expect(model.image == nil)
        #expect(!model.isLoading)
    }

    @Test func generationGuardDropsCompletionOfSupersededSessionTask() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png(UIFixtures.red)))
        let model = AsyncImageModel()
        model.session = makeUISession(loader: loader)
        let recorder = UIFetchRecorder()
        model.onStart = { recorder.tasks.append($0) }
        model.onCompletion = { recorder.results.append($0) }

        model.load(UIFixtures.url("fetch-gen-a"))
        let first = try #require(recorder.tasks.first)
        #expect(uiSpinUntil { first.state == .completed })
        uiDrainSessionQueue()
        let generation = model.loadGeneration

        model.load(UIFixtures.url("fetch-gen-b"))
        #expect(model.loadGeneration != generation)
        await uiExpectEventually { recorder.results.count == 1 }
        await uiDrainSessionAndMain()

        #expect(recorder.results.count == 1)
        guard case .success(let response)? = model.result else {
            Issue.record("Expected success")
            return
        }
        #expect(response.request.url == UIFixtures.url("fetch-gen-b"))
    }

    @Test func generationGuardDropsResultOfSupersededAsyncAction() async throws {
        let model = AsyncImageModel()
        let gate = UIAsyncGate()
        let recorder = UIFetchRecorder()
        model.onCompletion = { recorder.results.append($0) }
        let staleImage = UIFixtures.image(UIFixtures.red)
        let freshImage = UIFixtures.image(UIFixtures.blue)

        model.load {
            await gate.wait()
            return ImageResponse(content: ImageContent(image: staleImage), request: ImageRequest(url: UIFixtures.url("stale")))
        }
        let staleTask = try #require(model.actionTask)
        await uiExpectEventually { gate.isWaiting }
        model.load {
            ImageResponse(content: ImageContent(image: freshImage), request: ImageRequest(url: UIFixtures.url("fresh")))
        }
        await uiExpectEventually { model.result != nil }
        gate.open()
        await staleTask.value

        #expect(model.imageContent?.image === freshImage)
        #expect(recorder.results.count == 1)
    }

    @Test func nilRequestReportsMissingRequestWithSessionErrorAccessor() {
        let model = AsyncImageModel()
        model.load(nil as URL?)
        guard case .failure(let error)? = model.result else {
            Issue.record("Expected failure")
            return
        }
        guard case .imageRequestMissing? = error.imageSessionError else {
            Issue.record("Expected imageRequestMissing, got \(error)")
            return
        }
        #expect(model.error != nil)
        #expect(URLError(.badURL).imageSessionError == nil)
    }

    @Test func priorityUpdatesRunningTaskAndProgressIsStable() throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let model = AsyncImageModel()
        model.session = makeUISession(loader: loader)
        let recorder = UIFetchRecorder()
        model.onStart = { recorder.tasks.append($0) }

        model.load(UIFixtures.url("fetch-priority"))
        let task = try #require(recorder.tasks.first)
        model.priority = .veryLow
        #expect(task.priority == .veryLow)
        #expect(model.progress === model.progress)
        model.cancel()
    }

    @Test func processorsApplyOnlyWhenRequestHasNone() throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let model = AsyncImageModel()
        model.session = makeUISession(loader: loader)
        model.filters = [UITestFilter(name: "fetch")]
        let recorder = UIFetchRecorder()
        model.onStart = { recorder.tasks.append($0) }

        model.load(UIFixtures.url("fetch-filters-a"))
        model.load(ImageRequest(url: UIFixtures.url("fetch-filters-b"), filters: [UITestFilter(name: "own")]))

        #expect(recorder.tasks.map { $0.request.filters.map(\.identifier) } == [["ui-test/fetch"], ["ui-test/own"]])
        model.cancel()
    }

    @Test func publisherLoadPublishesValueThenCompletes() {
        let model = AsyncImageModel()
        let subject = PassthroughSubject<ImageResponse, Error>()
        let response = ImageResponse(content: ImageContent(image: UIFixtures.image()), request: ImageRequest(url: UIFixtures.url("publisher")))

        model.load(subject)
        #expect(model.isLoading)
        #expect(model.result == nil)

        subject.send(response)
        #expect(model.imageContent?.image === response.image)
        #expect(model.isLoading)
        #expect(model.result == nil)

        subject.send(completion: .finished)
        #expect(!model.isLoading)
        guard case .success(let published)? = model.result else {
            Issue.record("Expected success, got \(String(describing: model.result))")
            return
        }
        #expect(published.image === response.image)
    }

    @Test func publisherFailureIsPublishedAsResult() {
        let model = AsyncImageModel()
        let subject = PassthroughSubject<ImageResponse, Error>()

        model.load(subject)
        subject.send(completion: .failure(URLError(.badServerResponse)))

        #expect(!model.isLoading)
        #expect(model.imageContent == nil)
        guard case .failure(let error)? = model.result else {
            Issue.record("Expected failure, got \(String(describing: model.result))")
            return
        }
        #expect((error as? URLError)?.code == .badServerResponse)
    }

    @Test func publisherFromSessionLoadsImage() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        let session = makeUISession(loader: loader)
        let model = AsyncImageModel()

        model.load(session.imagePublisher(with: UIFixtures.url("publisher-session")))

        #expect(model.isLoading)
        await uiExpectEventually { model.result != nil }
        #expect(!model.isLoading)
        #expect(model.imageContent != nil)
        guard case .success? = model.result else {
            Issue.record("Expected success, got \(String(describing: model.result))")
            return
        }
    }

    @Test func generationGuardDropsPublisherEventsDeliveredAfterNextLoad() async throws {
        let model = AsyncImageModel()
        let delivery = DispatchQueue(label: "ui-test.publisher-delivery")
        let stale = PassthroughSubject<ImageResponse, Error>()
        let fresh = PassthroughSubject<ImageResponse, Error>()
        let staleResponse = ImageResponse(content: ImageContent(image: UIFixtures.image(UIFixtures.red)), request: ImageRequest(url: UIFixtures.url("stale-publisher")))
        let freshResponse = ImageResponse(content: ImageContent(image: UIFixtures.image(UIFixtures.blue)), request: ImageRequest(url: UIFixtures.url("fresh-publisher")))

        model.load(stale.receive(on: delivery))
        stale.send(staleResponse)
        stale.send(completion: .finished)
        delivery.sync {}
        model.load(fresh)
        await uiDrainMainQueue()

        #expect(model.imageContent == nil)
        #expect(model.result == nil)
        #expect(model.isLoading)

        fresh.send(freshResponse)
        fresh.send(completion: .finished)
        #expect(model.imageContent?.image === freshResponse.image)
        guard case .success(let response)? = model.result else {
            Issue.record("Expected fresh success")
            return
        }
        #expect(response.image === freshResponse.image)
    }

    @Test func progressReportsCompletedAndTotalBytes() async throws {
        let data = UIFixtures.png(width: 64, height: 64)
        let loader = MockDataLoader(defaultResponse: .data(data, chunkCount: 4))
        loader.isSuspended = true
        let model = AsyncImageModel()
        model.session = makeUISession(loader: loader)
        let observed = UIProgressRecorder()

        model.load(UIFixtures.url("fetch-progress"))
        let progress = model.progress
        #expect(progress.completed == 0)
        #expect(progress.total == 0)
        let subscription = progress.$completed.sink { observed.completed.append($0) }
        defer { subscription.cancel() }
        loader.isSuspended = false
        await uiExpectEventually { model.result != nil }

        #expect(progress.total == Int64(data.count))
        #expect(progress.completed == Int64(data.count))
        #expect(progress.fraction == 1)
        let reported = observed.completed.filter { $0 > 0 }
        #expect(reported.count >= 2)
        #expect(reported == reported.sorted())
        #expect(model.progress === progress)
    }
}

@Suite(.serialized)
@MainActor
struct AnimatedImageRepresentableTests {
    @Test func coordinatorDoesNotRestartForSameRequest() throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let session = makeUISession(loader: loader)
        let coordinator = AnimatedImageRepresentable.Coordinator()
        let view = AnimatedImageView()

        coordinator.apply(AnimatedImageRepresentable(url: UIFixtures.url("rep-a"), session: session), to: view)
        let first = try #require(ImageViewController.existingController(for: view)?.currentTask)
        coordinator.apply(AnimatedImageRepresentable(url: UIFixtures.url("rep-a"), session: session, isAnimating: false), to: view)

        #expect(coordinator.loadCount == 1)
        #expect(first.state == .running)
        #expect(ImageViewController.existingController(for: view)?.currentTask === first)
        #expect(!view.autoPlayAnimatedImage)

        coordinator.apply(AnimatedImageRepresentable(url: UIFixtures.url("rep-b"), session: session), to: view)
        #expect(coordinator.loadCount == 2)
        #expect(first.state == .cancelled)

        AnimatedImageRepresentable.dismantleUIView(view, coordinator: coordinator)
        #expect(ImageViewController.existingController(for: view)?.currentTask == nil)
    }

    @Test func coordinatorKeepsPlaybackForSameContainer() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.gif([UIFixtures.red, UIFixtures.green, UIFixtures.blue])))
        let session = makeUISession(loader: loader)
        let content = try await session.imageTask(with: UIFixtures.url("rep.gif")).response.content
        let source = try #require(content.animatedImageSource)
        let coordinator = AnimatedImageRepresentable.Coordinator()
        let view = AnimatedImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))

        coordinator.apply(AnimatedImageRepresentable(content), to: view)
        #expect(view.animatedImageSource === source)
        await uiExpectEventually { source.hasCachedFrame(at: 1) }
        #expect(view.advanceAnimation(by: source.frameDuration(at: 0)))
        coordinator.apply(AnimatedImageRepresentable(content), to: view)

        #expect(coordinator.loadCount == 1)
        #expect(view.currentFrameIndex == 1)
    }

    @Test func lazyImageStateExposesAnimatedImage() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.gif([UIFixtures.red, UIFixtures.green])))
        let model = AsyncImageModel()
        model.session = makeUISession(loader: loader)
        model.load(UIFixtures.url("state.gif"))
        await uiExpectEventually { model.result != nil }

        let state: CachedAsyncImagePhase = model
        #expect(state.animatedImage != nil)
        #expect(state.error == nil)
    }
}

@Suite(.serialized)
@MainActor
struct CachedAsyncImageTests {
    @Test func loadsWhenHostedInWindow() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        let session = makeUISession(loader: loader)
        let recorder = UIFetchRecorder()
        let view = CachedAsyncImage(url: UIFixtures.url("lazy")) { state in
            if let image = state.image {
                image
            } else {
                Color.gray
            }
        }
        .session(session)
        .onStart { recorder.tasks.append($0) }
        .onCompletion { recorder.results.append($0) }
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()

        await uiExpectEventually(timeout: 10) { recorder.results.count == 1 }
        #expect(recorder.tasks.count == 1)
        guard case .success? = recorder.results.first else {
            Issue.record("Expected success, got \(String(describing: recorder.results.first))")
            return
        }
        window.isHidden = true
        window.rootViewController = nil
    }
}

@Suite(.serialized)
@MainActor
struct CachedAsyncImageLifecycleTests {
    @MainActor
    private struct Hosted {
        let window: UIWindow
        let host: UIHostingController<UILazyHost>
        let state: UILazyHostState
        let recorder: UIFetchRecorder

        func detach() {
            window.rootViewController = nil
            window.isHidden = true
        }
    }

    private func host(_ behavior: CachedAsyncImage<Image>.DisappearBehavior?, loader: MockDataLoader) -> Hosted {
        let state = UILazyHostState(url: UIFixtures.url("lazy-a"))
        let recorder = UIFetchRecorder()
        let root = UILazyHost(state: state, session: makeUISession(loader: loader), behavior: behavior, recorder: recorder)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        return Hosted(window: window, host: host, state: state, recorder: recorder)
    }

    @Test func disappearCancelsTaskByDefault() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let hosted = host(.cancel, loader: loader)
        await uiExpectEventually(timeout: 10) { hosted.recorder.tasks.count == 1 }
        let task = try #require(hosted.recorder.tasks.first)
        #expect(task.state == .running)

        hosted.detach()
        await uiExpectEventually(timeout: 10) { task.state == .cancelled }
        loader.isSuspended = false
        await uiDrainSessionAndMain()
        #expect(hosted.recorder.results.isEmpty)
    }

    @Test func disappearLowersPriorityWhenRequested() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let hosted = host(.lowerPriority, loader: loader)
        await uiExpectEventually(timeout: 10) { hosted.recorder.tasks.count == 1 }
        let task = try #require(hosted.recorder.tasks.first)
        #expect(task.priority == .normal)

        hosted.detach()
        await uiExpectEventually(timeout: 10) { task.priority == .veryLow }
        #expect(task.state == .running)
        loader.isSuspended = false
        await uiExpectEventually { hosted.recorder.results.count == 1 }
    }

    @Test func disappearWithoutBehaviorKeepsTaskRunning() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let hosted = host(nil, loader: loader)
        await uiExpectEventually(timeout: 10) { hosted.recorder.tasks.count == 1 }
        let task = try #require(hosted.recorder.tasks.first)

        hosted.detach()
        await uiDrainMainQueue()
        await uiDrainMainQueue()
        #expect(task.state == .running)
        #expect(task.priority == .normal)
        loader.isSuspended = false
        await uiExpectEventually { hosted.recorder.results.count == 1 }
    }

    @Test func changingRequestReloadsAndSameRequestDoesNot() async throws {
        let loader = MockDataLoader(defaultResponse: .data(UIFixtures.png()))
        loader.isSuspended = true
        let hosted = host(.cancel, loader: loader)
        await uiExpectEventually(timeout: 10) { hosted.recorder.tasks.count == 1 }
        let first = try #require(hosted.recorder.tasks.first)

        hosted.state.unrelated += 1
        await uiExpectEventually(timeout: 10) { hosted.state.renderCount >= 2 }
        await uiDrainMainQueue()
        #expect(hosted.recorder.tasks.count == 1)
        #expect(first.state == .running)

        hosted.state.url = UIFixtures.url("lazy-b")
        await uiExpectEventually(timeout: 10) { hosted.recorder.tasks.count == 2 }
        #expect(first.state == .cancelled)
        let second = try #require(hosted.recorder.tasks.last)
        #expect(second.request.url == UIFixtures.url("lazy-b"))
        loader.isSuspended = false
        await uiExpectEventually { hosted.recorder.results.count == 1 }
        hosted.detach()
    }
}

@MainActor
final class UILazyHostState: ObservableObject {
    @Published var url: URL
    @Published var unrelated = 0
    var renderCount = 0

    init(url: URL) {
        self.url = url
    }
}

struct UILazyHost: View {
    @ObservedObject var state: UILazyHostState
    let session: ImageSession
    let behavior: CachedAsyncImage<Image>.DisappearBehavior?
    let recorder: UIFetchRecorder

    var body: some View {
        state.renderCount += 1
        return VStack {
            Text("\(state.unrelated)")
            CachedAsyncImage(url: state.url)
                .session(session)
                .onDisappear(behavior)
                .onStart { recorder.tasks.append($0) }
                .onCompletion { recorder.results.append($0) }
        }
    }
}

@MainActor
final class UIProgressRecorder {
    var completed: [Int64] = []
}

@MainActor
final class UIFetchRecorder {
    var tasks: [ImageTask] = []
    var results: [Result<ImageResponse, Error>] = []
}

final class UIAsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private var waiting = false

    var isWaiting: Bool {
        lock.withLock { waiting }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                waiting = true
                if opened {
                    return true
                }
                self.continuation = continuation
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func open() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}
