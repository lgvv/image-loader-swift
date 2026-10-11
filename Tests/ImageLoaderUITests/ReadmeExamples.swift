import ImageLoaderUI
import SwiftUI
import UIKit

enum ReadmeExamples {
    @MainActor
    static func quickStart(imageURL: URL, imageURLs: [URL], imageView: UIImageView) async throws {
        let image = try await ImageSession.shared.image(for: imageURL)

        var request = ImageRequest(url: imageURL)
        request.thumbnail = .init(size: CGSize(width: 200, height: 200), contentMode: .aspectFill)
        let thumbnail = try await ImageSession.shared.image(for: request)

        let prefetcher = ImagePrefetcher()
        prefetcher.startPrefetching(with: imageURLs)

        loadImage(with: imageURL, into: imageView)

        _ = (image, thumbnail)
    }

    struct QuickStartView: View {
        let imageURL: URL

        var body: some View {
            CachedAsyncImage(url: imageURL) { phase in
                phase.image?.resizable()
            }
        }
    }
}
