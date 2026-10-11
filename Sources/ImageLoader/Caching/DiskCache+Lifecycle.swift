import Foundation
import UIKit

extension DiskCache {
    func installObservers() {
        let observer = notificationCenter.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.didEnterBackground()
        }
        observers.withLock { $0.append(observer) }
    }

    private func didEnterBackground() {
        guard state.withLock({ $0.isActivated }) else { return }
        queue.async { [weak self] in
            self?.performBackgroundMaintenance()
        }
        let queue = queue
        ProcessInfo.processInfo.performExpiringActivity(withReason: "ImageLoader.DiskCache.maintenance") { expired in
            guard !expired else { return }
            queue.sync {}
        }
    }
}
