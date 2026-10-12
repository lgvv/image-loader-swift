import Foundation
import ImageLoaderTesting
@_spi(Testing) @testable import ImageLoaderUI
import Testing
import UIKit

@testable import ImageLoader

@Suite(.serialized, .enabled(if: !uiIsThreadSanitizerEnabled))
@MainActor
struct UIBenchmarks {
    @Test func memoryHitLoadImageIntoView() {
        let loader = MockDataLoader()
        let session = makeUISession(loader: loader)
        let url = UIFixtures.url("bench-memory")
        session.cache[ImageRequest(url: url)] = ImageContent(image: UIFixtures.image())
        let options = makeUIOptions(session)
        let view = UIImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        let iterations = 20_000
        let completions = UIBenchCounter()

        for _ in 0..<1_000 {
            loadImage(with: url, options: options, into: view) { _ in completions.value += 1 }
        }
        completions.value = 0

        let wallStart = DispatchTime.now().uptimeNanoseconds
        let cpuStart = uiThreadCPUTimeNanoseconds()
        for _ in 0..<iterations {
            loadImage(with: url, options: options, into: view) { _ in completions.value += 1 }
        }
        let cpuNanoseconds = uiThreadCPUTimeNanoseconds() - cpuStart
        let wallNanoseconds = DispatchTime.now().uptimeNanoseconds - wallStart

        let cpuAverage = Double(cpuNanoseconds) / Double(iterations) / 1_000
        let wallAverage = Double(wallNanoseconds) / Double(iterations) / 1_000
        print(String(format: "BENCH|ui.memoryHitLoadImage|iterations=%d|cpu_avg_us=%.2f|wall_avg_us=%.2f|threshold_us=30", iterations, cpuAverage, wallAverage))
        #expect(completions.value == iterations)
        #expect(loader.counts.started == 0)
        if uiEnforcesTimingBudgets {
            #expect(cpuAverage <= 30)
        }
    }
}

@MainActor
final class UIBenchCounter {
    var value = 0
}
