import ImageLoader
import ImageLoaderUI
import SwiftUI

struct PhotoPagerView: View {
    let photos: [Photo]
    @State private var index: Int
    @State private var isZoomed = false
    @Environment(\.dismiss) private var dismiss

    init(photos: [Photo], startIndex: Int) {
        self.photos = photos
        _index = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { offset, photo in
                    ZoomablePhotoView(photo: photo, isZoomed: offset == index ? $isZoomed : .constant(false))
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .scrollDisabled(isZoomed)
            .ignoresSafeArea()
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(.title3.weight(.semibold)).padding(12)
                }
                .accessibilityIdentifier("상세_닫기")
                Spacer()
                if photos.indices.contains(index) {
                    let photo = photos[index]
                    Text("\(photo.author)  \(photo.width)×\(photo.height)")
                        .font(.footnote)
                        .padding(.trailing, 12)
                }
            }
            .foregroundStyle(.white)
            .background(.black.opacity(0.35))
        }
        .onChange(of: index) {
            isZoomed = false
        }
    }
}

struct ZoomablePhotoView: View {
    let photo: Photo
    @Binding var isZoomed: Bool

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private let maximumScale: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            CachedAsyncImage(request: request(for: proxy.size)) { state in
                if let image = state.image {
                    image.resizable().scaledToFit()
                } else if state.error != nil {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("불러오지 못했습니다")
                    }
                    .foregroundStyle(.white)
                } else {
                    ProgressView(value: Double(state.progress.fraction))
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
            }
            .priority(.high)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .scaleEffect(scale)
            .offset(offset)
            .contentShape(Rectangle())
            .gesture(magnify(in: proxy.size).simultaneously(with: pan(in: proxy.size)))
            .onTapGesture(count: 2) {
                withAnimation(.snappy) {
                    if scale > 1 {
                        reset()
                    } else {
                        scale = 3
                        committedScale = 3
                        isZoomed = true
                    }
                }
            }
        }
        .accessibilityIdentifier("상세_사진_\(photo.id)")
    }

    private func request(for size: CGSize) -> ImageRequest {
        var request = ImageRequest(url: photo.originalURL)
        let longest = max(size.width, size.height) * maximumScale / 2
        request.thumbnail = ImageRequest.ThumbnailOptions(maxPixelSize: Float(max(longest, 1024) * 3))
        return request
    }

    private func magnify(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(maximumScale, max(0.8, committedScale * value.magnification))
            }
            .onEnded { _ in
                withAnimation(.snappy) {
                    if scale <= 1 {
                        reset()
                    } else {
                        committedScale = scale
                        offset = clamped(offset, in: size)
                        committedOffset = offset
                        isZoomed = true
                    }
                }
            }
    }

    private func pan(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: isZoomed ? 0 : 10_000)
            .onChanged { value in
                offset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                withAnimation(.snappy) {
                    offset = clamped(offset, in: size)
                    committedOffset = offset
                }
            }
    }

    private func clamped(_ value: CGSize, in size: CGSize) -> CGSize {
        let limitX = size.width * (scale - 1) / 2
        let limitY = size.height * (scale - 1) / 2
        return CGSize(
            width: min(limitX, max(-limitX, value.width)),
            height: min(limitY, max(-limitY, value.height))
        )
    }

    private func reset() {
        scale = 1
        committedScale = 1
        offset = .zero
        committedOffset = .zero
        isZoomed = false
    }
}
