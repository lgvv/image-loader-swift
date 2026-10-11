import ImageLoader
import ImageLoaderUI
import SwiftUI
import UIKit

enum GalleryCellMode: String, CaseIterable {
    case imageView = "imageView"
    case animatedView = "animatedView"
    case asyncImageView = "asyncImageView"
    case asyncImageViewAnimated = "asyncImageViewAnimated"

    var title: String {
        switch self {
        case .imageView: "UIImageView"
        case .animatedView: "움직임"
        case .asyncImageView: "AsyncImageView"
        case .asyncImageViewAnimated: "AsyncImageView 움직임"
        }
    }

    var usesGeneratedGIF: Bool {
        self == .animatedView || self == .asyncImageViewAnimated
    }

    var usesAsyncImageView: Bool {
        self == .asyncImageView || self == .asyncImageViewAnimated
    }

    static func fromLaunchArguments() -> GalleryCellMode {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-CellMode"), index + 1 < arguments.count else {
            return .imageView
        }
        return GalleryCellMode(rawValue: arguments[index + 1]) ?? .imageView
    }
}

struct UIKitGalleryScreen: UIViewControllerRepresentable {
    var autoScroll = false
    var mode = GalleryCellMode.imageView

    func makeUIViewController(context: Context) -> UIKitGalleryViewController {
        UIKitGalleryViewController(autoScroll: autoScroll, mode: mode)
    }

    func updateUIViewController(_ controller: UIKitGalleryViewController, context: Context) {}
}

@MainActor
final class ReuseAudit {
    private(set) var configuredCount = 0
    private(set) var reusedCount = 0
    private(set) var memoryHitCount = 0
    private(set) var completedCount = 0
    private(set) var mismatchCount = 0
    private(set) var displayMismatchCount = 0
    private(set) var staleCount = 0
    private(set) var ghostCount = 0
    var onChange: (() -> Void)?

    var text: String {
        "구성 \(configuredCount), 재사용 \(reusedCount), 완료 \(completedCount), 메모리 \(memoryHitCount)\n잘못된 완료 \(mismatchCount), 표시 불일치 \(displayMismatchCount), 이전 이미지 \(staleCount), 잔상 \(ghostCount)"
    }

    var logText: String {
        text.replacingOccurrences(of: "\n", with: ", ")
    }

    func recordConfigure(isReuse: Bool, isStale: Bool, leftoverSubviews: Int) {
        configuredCount += 1
        if isReuse {
            reusedCount += 1
        }
        if isStale {
            staleCount += 1
            NSLog("%@", "REUSE|stale")
        }
        if leftoverSubviews > 0 {
            ghostCount += 1
            NSLog("%@", "REUSE|ghost|leftover=\(leftoverSubviews)")
        }
        onChange?()
    }

    func recordCompletion(requestedID: String?, currentID: String?, isDisplayed: Bool, isMemoryHit: Bool) {
        completedCount += 1
        if isMemoryHit {
            memoryHitCount += 1
        }
        if requestedID != currentID {
            mismatchCount += 1
            NSLog("%@", "REUSE|mismatch|requested=\(requestedID ?? "nil")|current=\(currentID ?? "nil")")
        }
        if !isDisplayed {
            displayMismatchCount += 1
            NSLog("%@", "REUSE|display-mismatch|id=\(requestedID ?? "nil")")
        }
        onChange?()
    }
}

struct SettledResult {
    var matched = 0
    var unloaded = 0
    var wrong = 0
    var animating = 0
}

@MainActor
protocol AuditedGalleryCell: UICollectionViewCell {
    func configure(request: ImageRequest, session: ImageSession, audit: ReuseAudit)
    func settledResult(session: ImageSession) -> SettledResult
}

class ImageViewGalleryCell: UICollectionViewCell, AuditedGalleryCell {
    static let reuseIdentifier = "ImageViewGalleryCell"
    static let animatedReuseIdentifier = "AnimatedImageViewGalleryCell"

    private let imageView: UIImageView
    private var currentRequest: ImageRequest?
    private var hasBeenConfigured = false

    private static let options: ImageLoadingOptions = {
        var options = ImageLoadingOptions()
        options.placeholder = UIImage(systemName: "photo")
        options.failureImage = UIImage(systemName: "exclamationmark.triangle")
        options.transition = .fadeIn(duration: 0.3)
        options.contentModes = .init(success: .scaleAspectFill, failure: .center, placeholder: .center)
        return options
    }()

    override init(frame: CGRect) {
        imageView = UIImageView()
        super.init(frame: frame)
        setUp()
    }

    init(frame: CGRect, imageView: UIImageView) {
        self.imageView = imageView
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func setUp() {
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemBackground
        imageView.tintColor = .tertiaryLabel
        contentView.addSubview(imageView)
        isAccessibilityElement = true
        accessibilityIdentifier = "UIKit갤러리_셀"
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelRequest(for: imageView)
    }

    func configure(request: ImageRequest, session: ImageSession, audit: ReuseAudit) {
        let isReuse = hasBeenConfigured
        hasBeenConfigured = true
        currentRequest = request
        var options = Self.options
        options.session = session
        loadImage(with: request, options: options, into: imageView) { [weak self] result in
            guard let self, case .success(let response) = result else {
                return
            }
            audit.recordCompletion(
                requestedID: response.request.imageID,
                currentID: self.currentRequest?.imageID,
                isDisplayed: self.imageView.image === response.image,
                isMemoryHit: response.cacheType == .memory
            )
        }
        audit.recordConfigure(isReuse: isReuse, isStale: isShowingOtherImage(request: request, session: session), leftoverSubviews: contentView.subviews.count - 1)
    }

    private func isShowingOtherImage(request: ImageRequest, session: ImageSession) -> Bool {
        let cached = session.cache[request]
        if let animatedView = imageView as? AnimatedImageView, let source = animatedView.animatedImageSource, source !== cached?.animatedImageSource {
            return true
        }
        guard let image = imageView.image else {
            return false
        }
        return image !== Self.options.placeholder && image !== cached?.image
    }

    func settledResult(session: ImageSession) -> SettledResult {
        var result = SettledResult()
        guard let request = currentRequest else { return result }
        guard let cached = session.cache[request], !cached.isPreview else {
            result.unloaded = 1
            return result
        }
        if imageView.image === cached.image {
            result.matched = 1
        } else {
            result.wrong = 1
        }
        if let animatedView = imageView as? AnimatedImageView, animatedView.isAnimating {
            result.animating = 1
        }
        return result
    }
}

final class AnimatedImageViewGalleryCell: ImageViewGalleryCell {
    override init(frame: CGRect) {
        super.init(frame: frame, imageView: AnimatedImageView())
    }

    required init?(coder: NSCoder) {
        nil
    }
}

final class AsyncImageViewGalleryCell: UICollectionViewCell, AuditedGalleryCell {
    static let reuseIdentifier = "AsyncImageViewGalleryCell"

    private let asyncImageView = AsyncImageView()
    private var currentRequest: ImageRequest?
    private var hasBeenConfigured = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        asyncImageView.frame = contentView.bounds
        asyncImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        asyncImageView.clipsToBounds = true
        asyncImageView.imageView.contentMode = .scaleAspectFill
        asyncImageView.placeholderImage = UIImage(systemName: "photo")
        asyncImageView.placeholderViewPosition = .center
        asyncImageView.failureImage = UIImage(systemName: "exclamationmark.triangle")
        asyncImageView.failureViewPosition = .center
        contentView.addSubview(asyncImageView)
        isAccessibilityElement = true
        accessibilityIdentifier = "UIKit갤러리_셀"
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        asyncImageView.cancel()
    }

    func configure(request: ImageRequest, session: ImageSession, audit: ReuseAudit) {
        let isReuse = hasBeenConfigured
        hasBeenConfigured = true
        currentRequest = request
        asyncImageView.session = session
        asyncImageView.onSuccess = { [weak self] response in
            guard let self else { return }
            audit.recordCompletion(
                requestedID: response.request.imageID,
                currentID: self.currentRequest?.imageID,
                isDisplayed: self.asyncImageView.imageView.image === response.image,
                isMemoryHit: response.cacheType == .memory
            )
        }
        asyncImageView.request = request
        audit.recordConfigure(isReuse: isReuse, isStale: isShowingOtherImage(request: request, session: session), leftoverSubviews: 0)
    }

    private var animatedView: AnimatedImageView? {
        asyncImageView.imageView as? AnimatedImageView
    }

    private func isShowingOtherImage(request: ImageRequest, session: ImageSession) -> Bool {
        let cached = session.cache[request]
        if let source = animatedView?.animatedImageSource, source !== cached?.animatedImageSource {
            return true
        }
        guard let image = asyncImageView.imageView.image else {
            return false
        }
        return image !== cached?.image
    }

    func settledResult(session: ImageSession) -> SettledResult {
        var result = SettledResult()
        guard let request = currentRequest else { return result }
        guard let cached = session.cache[request], !cached.isPreview else {
            result.unloaded = 1
            return result
        }
        if asyncImageView.imageView.image === cached.image {
            result.matched = 1
        } else {
            result.wrong = 1
        }
        if animatedView?.isAnimating == true {
            result.animating = 1
        }
        return result
    }
}

final class UIKitGalleryViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDataSourcePrefetching, UICollectionViewDelegateFlowLayout {
    private let autoScroll: Bool
    private var mode: GalleryCellMode
    private var audit = ReuseAudit()
    private let session = ImageSession.shared
    private var prefetcher = ImagePrefetcher()
    private let statusLabel = UILabel()
    private var collectionView: UICollectionView!
    private var photos: [Photo] = []
    private var nextPage = 1
    private var isLoadingPage = false
    private var autoScrollTimer: Timer?
    private var autoScrollStep = 0
    private let columnCount: CGFloat = 3
    private let spacing: CGFloat = 2

    init(autoScroll: Bool, mode: GalleryCellMode) {
        self.autoScroll = autoScroll
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let modeControl = UISegmentedControl(items: GalleryCellMode.allCases.map(\.title))
        modeControl.selectedSegmentIndex = GalleryCellMode.allCases.firstIndex(of: mode) ?? 0
        modeControl.addTarget(self, action: #selector(modeChanged(_:)), for: .valueChanged)
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.accessibilityIdentifier = "UIKit갤러리_셀방식"
        view.addSubview(modeControl)

        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = spacing
        layout.minimumLineSpacing = spacing
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.dataSource = self
        collectionView.prefetchDataSource = self
        collectionView.delegate = self
        collectionView.register(ImageViewGalleryCell.self, forCellWithReuseIdentifier: ImageViewGalleryCell.reuseIdentifier)
        collectionView.register(AnimatedImageViewGalleryCell.self, forCellWithReuseIdentifier: ImageViewGalleryCell.animatedReuseIdentifier)
        collectionView.register(AsyncImageViewGalleryCell.self, forCellWithReuseIdentifier: AsyncImageViewGalleryCell.reuseIdentifier)
        collectionView.accessibilityIdentifier = "UIKit갤러리_목록"
        view.addSubview(collectionView)

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.accessibilityIdentifier = "UIKit갤러리_재사용지표"
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            modeControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            modeControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            modeControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            collectionView.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 4),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        bindAudit()
        start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        autoScrollTimer?.invalidate()
        prefetcher.stopPrefetching()
    }

    @objc private func modeChanged(_ control: UISegmentedControl) {
        mode = GalleryCellMode.allCases[control.selectedSegmentIndex]
        prefetcher.stopPrefetching()
        prefetcher = ImagePrefetcher()
        audit = ReuseAudit()
        bindAudit()
        collectionView.reloadData()
        collectionView.setContentOffset(.zero, animated: false)
        start()
    }

    private func bindAudit() {
        audit.onChange = { [weak self] in
            guard let self else { return }
            self.statusLabel.text = "\(self.mode.title)\n\(self.audit.text)"
        }
        statusLabel.text = "\(mode.title)\n\(audit.text)"
    }

    private func start() {
        NSLog("%@", "REUSE|mode=\(mode.rawValue)")
        if mode.usesGeneratedGIF {
            collectionView.reloadData()
            if autoScroll, autoScrollTimer == nil {
                startAutoScroll()
            }
        } else if photos.isEmpty {
            Task { await loadNextPage() }
        } else {
            collectionView.reloadData()
            if autoScroll, autoScrollTimer == nil, photos.count >= 300 {
                startAutoScroll()
            }
        }
    }

    private func pixelSize(for side: CGFloat) -> Int {
        let raw = Int(side * traitCollection.displayScale)
        let bucket = 128
        return max(bucket, (raw + bucket - 1) / bucket * bucket)
    }

    private var cellSide: CGFloat {
        (collectionView.bounds.width - spacing * (columnCount - 1)) / columnCount
    }

    private var itemCount: Int {
        mode.usesGeneratedGIF ? GeneratedGIF.count : photos.count
    }

    private func request(at index: Int) -> ImageRequest {
        if mode.usesGeneratedGIF {
            return GeneratedGIF.request(index: index)
        }
        return ImageRequest(url: photos[index].thumbnailURL(pixelSize: pixelSize(for: cellSide)))
    }

    private func loadNextPage() async {
        guard !isLoadingPage, !mode.usesGeneratedGIF else { return }
        isLoadingPage = true
        let page = try? await PhotoCatalog.load(page: nextPage)
        isLoadingPage = false
        guard let page, !mode.usesGeneratedGIF else { return }
        let start = photos.count
        photos.append(contentsOf: page)
        nextPage += 1
        collectionView.insertItems(at: (start..<photos.count).map { IndexPath(item: $0, section: 0) })
        guard autoScroll, autoScrollTimer == nil else { return }
        if photos.count >= 300 {
            startAutoScroll()
        } else {
            await loadNextPage()
        }
    }

    private func startAutoScroll() {
        autoScrollStep = 0
        NSLog("%@", "REUSE|autoscroll-start|mode=\(mode.rawValue)|items=\(itemCount)")
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.autoScrollTick()
            }
        }
    }

    private func autoScrollTick() {
        autoScrollStep += 1
        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        let cycle = autoScrollStep % 120
        let fraction = cycle < 60 ? Double(cycle) / 60 : Double(120 - cycle) / 60
        let jitter = autoScrollStep.isMultiple(of: 3) ? -cellSide * 2 : 0
        let target = min(maxOffset, max(0, maxOffset * fraction + jitter))
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        if autoScrollStep == 600 {
            autoScrollTimer?.invalidate()
            autoScrollTimer = nil
            collectionView.setContentOffset(CGPoint(x: 0, y: maxOffset * 0.4), animated: false)
            NSLog("%@", "REUSE|autoscroll-done|mode=\(mode.rawValue)|\(audit.logText)")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self?.logSettledState()
            }
        }
    }

    private func logSettledState() {
        var total = SettledResult()
        var visible = 0
        for cell in collectionView.visibleCells {
            guard let cell = cell as? AuditedGalleryCell else { continue }
            visible += 1
            let result = cell.settledResult(session: session)
            total.matched += result.matched
            total.unloaded += result.unloaded
            total.wrong += result.wrong
            total.animating += result.animating
        }
        NSLog(
            "%@",
            "REUSE|settled|mode=\(mode.rawValue)|visible=\(visible)|matched=\(total.matched)|unloaded=\(total.unloaded)|wrong=\(total.wrong)|animating=\(total.animating)|\(audit.logText)"
        )
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        itemCount
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let identifier =
            switch mode {
            case .imageView: ImageViewGalleryCell.reuseIdentifier
            case .animatedView: ImageViewGalleryCell.animatedReuseIdentifier
            case .asyncImageView, .asyncImageViewAnimated: AsyncImageViewGalleryCell.reuseIdentifier
            }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: identifier, for: indexPath)
        if let cell = cell as? AuditedGalleryCell {
            cell.configure(request: request(at: indexPath.item), session: session, audit: audit)
        }
        if !mode.usesGeneratedGIF, indexPath.item >= photos.count - 30 {
            Task { await loadNextPage() }
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        prefetcher.startPrefetching(with: indexPaths.filter { $0.item < itemCount }.map { request(at: $0.item) })
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        prefetcher.stopPrefetching(with: indexPaths.filter { $0.item < itemCount }.map { request(at: $0.item) })
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: cellSide, height: cellSide)
    }
}
