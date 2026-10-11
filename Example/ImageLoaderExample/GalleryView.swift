import ImageLoader
import ImageLoaderUI
import SwiftUI

enum ThumbnailSource: String, CaseIterable, Identifiable {
    case resizedURL = "작은 URL"
    case downsampledOriginal = "원본 다운샘플"

    var id: String { rawValue }
}

struct GalleryView: View {
    @State private var photos: [Photo] = []
    @State private var nextPage = 1
    @State private var isLoadingPage = false
    @State private var loadError: String?
    @State private var columnCount = 3
    @State private var pinchBase: Int?
    @State private var thumbnailSource = ThumbnailSource.resizedURL
    @State private var selection: PhotoSelection?
    @State private var isShowingCacheSheet = false
    @State private var isShowingUIKitGallery = false
    @EnvironmentObject private var metrics: LoadMetrics

    private let columnRange = 1...8

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let spacing: CGFloat = 2
                let side = (proxy.size.width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount), spacing: spacing) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                            GalleryCell(photo: photo, side: side, source: thumbnailSource)
                                .onTapGesture { selection = PhotoSelection(index: index) }
                                .onAppear {
                                    if index >= photos.count - 12 {
                                        Task { await loadNextPage() }
                                    }
                                }
                                .accessibilityIdentifier("갤러리_사진_\(photo.id)")
                        }
                    }
                    .animation(.snappy, value: columnCount)
                    if isLoadingPage {
                        ProgressView().padding()
                    }
                    if let loadError {
                        Text(loadError).foregroundStyle(.secondary).padding()
                    }
                }
                .simultaneousGesture(gridPinch)
                .safeAreaInset(edge: .bottom) {
                    Text(metrics.summary.text)
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                        .onTapGesture { metrics.reset() }
                        .accessibilityIdentifier("갤러리_로드지표")
                }
            }
            .navigationTitle("ImageLoader 갤러리")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("썸네일", selection: $thumbnailSource) {
                        ForEach(ThumbnailSource.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("갤러리_썸네일방식")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Text("\(columnCount)열").monospacedDigit().foregroundStyle(.secondary)
                    Button("UIKit") {
                        isShowingUIKitGallery = true
                    }
                    .accessibilityIdentifier("갤러리_UIKit예제")
                    Button {
                        isShowingCacheSheet = true
                    } label: {
                        Image(systemName: "internaldrive")
                    }
                    .accessibilityIdentifier("갤러리_캐시")
                }
            }
            .navigationDestination(isPresented: $isShowingUIKitGallery) {
                UIKitGalleryScreen()
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("UIKit 갤러리")
            }
            .sheet(isPresented: $isShowingCacheSheet) {
                CacheView().presentationDetents([.medium])
            }
            .fullScreenCover(item: $selection) { selection in
                PhotoPagerView(photos: photos, startIndex: selection.index)
            }
            .task {
                if photos.isEmpty {
                    await loadNextPage()
                }
            }
        }
    }

    private var gridPinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? columnCount
                pinchBase = base
                let target = Int((Double(base) / value.magnification).rounded())
                columnCount = min(columnRange.upperBound, max(columnRange.lowerBound, target))
            }
            .onEnded { _ in
                pinchBase = nil
            }
    }

    private func loadNextPage() async {
        guard !isLoadingPage else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }
        do {
            let page = try await PhotoCatalog.load(page: nextPage)
            photos.append(contentsOf: page)
            nextPage += 1
            loadError = nil
        } catch {
            loadError = "목록을 불러오지 못했습니다: \(error.localizedDescription)"
        }
    }
}

struct PhotoSelection: Identifiable {
    let index: Int
    var id: Int { index }
}

private struct GalleryCell: View {
    let photo: Photo
    let side: CGFloat
    let source: ThumbnailSource

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        CachedAsyncImage(request: request) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else if state.error != nil {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else {
                Color(.secondarySystemBackground)
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .contentShape(Rectangle())
    }

    private var pixelSize: Int {
        let raw = Int(side * displayScale)
        let bucket = 128
        return max(bucket, (raw + bucket - 1) / bucket * bucket)
    }

    private var request: ImageRequest {
        switch source {
        case .resizedURL:
            return ImageRequest(url: photo.thumbnailURL(pixelSize: pixelSize))
        case .downsampledOriginal:
            var request = ImageRequest(url: photo.originalURL)
            request.thumbnail = ImageRequest.ThumbnailOptions(maxPixelSize: Float(pixelSize))
            return request
        }
    }
}
