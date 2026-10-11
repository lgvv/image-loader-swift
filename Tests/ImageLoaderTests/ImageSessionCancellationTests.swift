import Foundation
import ImageLoaderTesting
import Testing
import UIKit

@testable import ImageLoader

@Suite("취소")
struct ImageSessionCancellationTests {
    @Test("유일한 작업을 취소하면 기다리던 호출자가 바로 .cancelled를 받고 다운로드도 취소")
    func cancellingSoleTask() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        loader.isSuspended = true
        let session = makeSession(loader: loader)
        let task = session.imageTask(with: Fixtures.url)
        #expect(await waitUntil { loader.counts.started == 1 })
        let waiter = Task { await result(of: task) }
        try? await Task.sleep(nanoseconds: 1)
        task.cancel()
        let outcome = await waiter.value
        #expect(loader.isSuspended)
        #expect(loader.counts.completed == 0)
        #expect(outcome.failureValue?.caseName == "cancelled")
        #expect(task.state == .cancelled)
        drainSessionQueue()
        drainSessionQueue()
        loader.isSuspended = false
        #expect(await waitUntil { loader.counts.cancelled == 1 })
        #expect(loader.counts.completed == 0)
        #expect(await waitUntil { session.runningTaskCount == 0 })
    }

    @Test("기다리는 Swift Task가 취소되면 작업도 취소")
    func swiftTaskCancellationPropagates() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        loader.isSuspended = true
        let session = makeSession(loader: loader)
        let imageTask = session.imageTask(with: Fixtures.url)
        let waiter = Task { await result(of: imageTask) }
        #expect(await waitUntil { loader.counts.started == 1 })
        waiter.cancel()
        #expect(await waiter.value.failureValue?.caseName == "cancelled")
        #expect(imageTask.state == .cancelled)
        drainSessionQueue()
        drainSessionQueue()
        loader.isSuspended = false
        #expect(await waitUntil { loader.counts.cancelled == 1 })
    }

    @Test("같은 이미지를 기다리는 다른 작업이 있으면 하나를 취소해도 다운로드는 계속")
    func cancellingOneOfTwo() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        loader.isSuspended = true
        let session = makeSession(loader: loader)
        let leaving = session.imageTask(with: Fixtures.url)
        let staying = session.imageTask(with: Fixtures.url)
        #expect(await waitUntil { loader.counts.started == 1 })
        leaving.cancel()
        drainSessionQueue()
        drainSessionQueue()
        loader.isSuspended = false
        #expect((try? await staying.image) != nil)
        #expect(await result(of: leaving).failureValue?.caseName == "cancelled")
        #expect(loader.counts == MockDataLoader.Counts(started: 1, completed: 1, cancelled: 0))
    }

    @Test("이미 끝난 작업의 cancel은 상태와 결과를 바꾸지 않고 취소 플래그만 세우며, 여러 번 불러도 같음")
    func cancelAfterCompletionSetsFlagWithoutStateChange() async throws {
        let delegate = RecordingDelegate()
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader, delegate: delegate)
        let task = session.imageTask(with: Fixtures.url)
        _ = try await task.image
        #expect(!task.isCancelled)
        task.cancel()
        task.cancel()
        #expect(task.state == .completed)
        #expect(task.isCancelled)
        #expect((try? await task.image) != nil)
        drainSessionQueue()
        #expect(delegate.finishedEvents(for: task.taskId).count == 1)
        #expect(delegate.finishedEvents(for: task.taskId).first?.failureValue == nil)

        loader.isSuspended = true
        let other = session.imageTask(with: Fixtures.url(1))
        other.cancel()
        other.cancel()
        #expect(other.state == .cancelled)
        #expect(other.isCancelled)
        loader.isSuspended = false
    }

    @Test("취소 delegate 이벤트는 기다리던 호출자가 깨어난 뒤에 도착")
    func cancellationDelegateOrdering() async {
        let delegate = RecordingDelegate()
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        loader.isSuspended = true
        let session = makeSession(loader: loader, delegate: delegate)
        let task = session.imageTask(with: Fixtures.url)
        #expect(await waitUntil { loader.counts.started == 1 })
        task.cancel()
        #expect(await result(of: task).failureValue?.caseName == "cancelled")
        #expect(await waitUntil { delegate.finishedEvents(for: task.taskId).count == 1 })
        #expect(delegate.finishedEvents(for: task.taskId).first?.failureValue?.caseName == "cancelled")
        loader.isSuspended = false
    }

    @Test("cancel은 response 대기자만 같은 스택에서 깨우고, 스트림의 .finished(.cancelled)는 조정 큐가 풀린 뒤에 넣음")
    func cancelResumesWaiterBeforeStreamFinishes() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        loader.isSuspended = true
        let session = makeSession(loader: loader)
        let task = session.imageTask(with: Fixtures.url)
        let stream = task.events
        let collected = Box<[String]>([])
        let consumer = Task {
            for await event in stream {
                let name: String =
                    switch event {
                    case .started: "started"
                    case .progress: "progress"
                    case .preview: "preview"
                    case .finished(let result): "finished(\(result.failureValue?.caseName ?? "success"))"
                    }
                collected.mutate { $0.append(name) }
            }
        }
        #expect(await waitUntil { loader.counts.started == 1 })
        let waiterResumed = Box(false)
        let waiter = Task {
            let outcome = await result(of: task)
            waiterResumed.value = true
            return outcome
        }
        let observation = await withCheckedContinuation { (continuation: CheckedContinuation<(state: ImageTask.State, waiterResumed: Bool, sawFinished: Bool), Never>) in
            DispatchQueue.global().async {
                let entered = DispatchSemaphore(value: 0)
                let gate = DispatchSemaphore(value: 0)
                SessionQueue.async {
                    entered.signal()
                    gate.wait()
                }
                entered.wait()
                task.cancel()
                let state = task.state
                let deadline = DispatchTime.now().uptimeNanoseconds + 200_000_000
                var sawFinished = false
                while DispatchTime.now().uptimeNanoseconds < deadline {
                    if collected.value.contains(where: { $0.hasPrefix("finished") }) {
                        sawFinished = true
                        break
                    }
                }
                let resumed = waiterResumed.value
                gate.signal()
                continuation.resume(returning: (state, resumed, sawFinished))
            }
        }
        #expect(observation.state == .cancelled)
        #expect(observation.waiterResumed)
        #expect(!observation.sawFinished)
        #expect(await waiter.value.failureValue?.caseName == "cancelled")
        await consumer.value
        #expect(collected.value.last == "finished(cancelled)")
        #expect(collected.value.filter { $0.hasPrefix("finished") }.count == 1)
        loader.isSuspended = false
    }

    @Test("끝남 이벤트보다 취소가 먼저 상태를 바꾸면 delegate는 .finished와 작업 지표를 취소 쪽에서 한 번씩만 받음")
    func finishedAfterCancelIsReportedOnce() async throws {
        let delegate = CancelOnStartedDelegate()
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader, delegate: delegate) {
            $0.isMetricsCollectionEnabled = true
        }
        _ = try await session.image(for: Fixtures.url)
        delegate.cancelsOnStarted.value = true
        let task = session.imageTask(with: Fixtures.url)
        #expect(await result(of: task).failureValue?.caseName == "cancelled")
        #expect(await waitUntil { delegate.finishedEvents(for: task.taskId).count == 1 })
        drainSessionQueue()
        drainSessionQueue()
        #expect(task.state == .cancelled)
        #expect(delegate.finishedEvents(for: task.taskId) == ["cancelled"])
        #expect(delegate.metricsCount(for: task.taskId) == 1)
        #expect(loader.counts.started == 1)
    }

    @Test("시작 전에 취소된 작업은 로더를 부르지 않음")
    func cancelBeforeStart() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let session = makeSession(loader: loader)
        let task = SessionQueue.sync { () -> ImageTask in
            let task = session.imageTask(with: Fixtures.url)
            task.cancel()
            return task
        }
        #expect(await result(of: task).failureValue?.caseName == "cancelled")
        drainSessionQueue()
        drainSessionQueue()
        #expect(loader.counts.started == 0)
    }

    @Test("스크롤 취소: 요청 100개 중 90개를 취소하면 다운로드는 10건만 끝까지 진행")
    func scrollCancellation() async {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        loader.isSuspended = true
        let session = makeSession(loader: loader) {
            $0.dataLoadingQueue = TaskQueue(maxConcurrentOperationCount: 100)
        }
        let tasks = (0..<100).map { session.imageTask(with: Fixtures.url($0)) }
        #expect(await waitUntil { loader.counts.started == 100 })
        let waiters = tasks.prefix(90).map { task in Task { await result(of: task) } }
        let start = DispatchTime.now().uptimeNanoseconds
        for task in tasks.prefix(90) {
            task.cancel()
        }
        var maxReturn = 0.0
        for waiter in waiters {
            _ = await waiter.value
            maxReturn = max(maxReturn, elapsedSeconds(since: start))
        }
        #expect(loader.isSuspended)
        #expect(loader.counts.completed == 0)
        drainSessionQueue()
        drainSessionQueue()
        loader.isSuspended = false
        for task in tasks.suffix(10) {
            #expect((try? await task.image) != nil)
        }
        #expect(await waitUntil { loader.counts.cancelled == 90 && loader.counts.completed == 10 })
        print("BENCH|core_scroll_cancel|cancelled_callers_returned_ms=\(Int(maxReturn * 1000))|completed=\(loader.counts.completed)|cancelled=\(loader.counts.cancelled)")
    }
}

private final class CancelOnStartedDelegate: ImageSession.Delegate, @unchecked Sendable {
    let cancelsOnStarted = Box(false)
    private let finished = Box<[(UInt64, String)]>([])
    private let metrics = Box<[UInt64]>([])

    func imageTask(_ task: ImageTask, didReceiveEvent event: ImageTask.Event, session: ImageSession) {
        switch event {
        case .started:
            if cancelsOnStarted.value {
                task.cancel()
            }
        case .finished(let result):
            finished.mutate { $0.append((task.taskId, result.failureValue?.caseName ?? "success")) }
        case .progress, .preview:
            break
        }
    }

    func session(_ session: ImageSession, didRecord diagnostic: ImageSession.Diagnostic) {
        guard case .taskMetrics(let value) = diagnostic else { return }
        metrics.mutate { $0.append(value.taskId) }
    }

    func finishedEvents(for taskId: UInt64) -> [String] {
        finished.value.filter { $0.0 == taskId }.map(\.1)
    }

    func metricsCount(for taskId: UInt64) -> Int {
        metrics.value.filter { $0 == taskId }.count
    }
}
