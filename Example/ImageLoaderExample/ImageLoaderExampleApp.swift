import ImageLoader
import SwiftUI

@main
struct ImageLoaderExampleApp: App {
    @StateObject private var metrics: LoadMetrics

    init() {
        let metrics = LoadMetrics()
        var configuration = ImageSession.Configuration.withDiskCache(name: "ImageLoaderExample.DiskCache")
        configuration.isMetricsCollectionEnabled = true
        ImageSession.shared = ImageSession(configuration: configuration, delegate: metrics)
        _metrics = StateObject(wrappedValue: metrics)
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-UIKitGallery") {
                NavigationStack {
                    UIKitGalleryScreen(autoScroll: ProcessInfo.processInfo.arguments.contains("-AutoScroll"), mode: GalleryCellMode.fromLaunchArguments())
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle("UIKit 갤러리")
                        .navigationBarTitleDisplayMode(.inline)
                }
            } else {
                GalleryView()
                    .environmentObject(metrics)
            }
        }
    }
}
