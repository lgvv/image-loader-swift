import Combine
import Foundation
import ImageLoader

final class LoadMetrics: ImageSession.Delegate, ObservableObject, @unchecked Sendable {
    struct Summary: Equatable {
        var networkCount = 0
        var networkAverage: Double = 0
        var networkP95: Double = 0
        var diskCount = 0
        var diskAverage: Double = 0
        var memoryCount = 0
        var failureCount = 0

        var text: String {
            String(
                format: "네트워크 %d건 평균 %.0fms p95 %.0fms, 디스크 %d건 평균 %.1fms, 메모리 %d, 실패 %d", networkCount, networkAverage, networkP95, diskCount, diskAverage, memoryCount,
                failureCount)
        }
    }

    @MainActor @Published private(set) var summary = Summary()

    private let lock = NSLock()
    private var network: [Double] = []
    private var disk: [Double] = []
    private var memory = 0
    private var failures = 0

    func session(_ session: ImageSession, didRecord diagnostic: ImageSession.Diagnostic) {
        guard case .taskMetrics(let metrics) = diagnostic else {
            print("DIAG|\(diagnostic)")
            return
        }
        guard !metrics.isDataTask else { return }
        let milliseconds = metrics.duration * 1000
        lock.lock()
        if metrics.errorCode != nil {
            if metrics.errorCode != "cancelled" { failures += 1 }
        } else {
            switch metrics.cacheType {
            case .none: network.append(milliseconds)
            case .disk: disk.append(milliseconds)
            case .memory: memory += 1
            }
        }
        let summary = makeSummary()
        lock.unlock()
        print("METRIC|kind=\(metrics.errorCode ?? cacheName(metrics.cacheType))|ms=\(String(format: "%.1f", milliseconds))|\(summary.text)")
        Task { @MainActor in self.summary = summary }
    }

    func reset() {
        lock.lock()
        network = []
        disk = []
        memory = 0
        failures = 0
        let summary = makeSummary()
        lock.unlock()
        Task { @MainActor in self.summary = summary }
    }

    private func cacheName(_ type: ImageResponse.CacheType?) -> String {
        switch type {
        case .none: "network"
        case .disk: "disk"
        case .memory: "memory"
        }
    }

    private func makeSummary() -> Summary {
        func average(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
        func p95(_ values: [Double]) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        }
        return Summary(
            networkCount: network.count, networkAverage: average(network), networkP95: p95(network), diskCount: disk.count, diskAverage: average(disk), memoryCount: memory,
            failureCount: failures)
    }
}
