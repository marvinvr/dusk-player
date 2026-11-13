import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Full-screen photo viewer over a grid's loaded photos and clips.
///
/// iOS/iPadOS page with a swipe (or the arrow keys), pinch or double-tap to
/// zoom, and tap to show or hide the chrome. tvOS moves with left/right on the
/// remote, toggles the info with Select, and runs a slideshow on Play/Pause.
/// A clip is shown as its frame with a play button; playing it closes the
/// viewer and hands the clip back, because the player cannot present over it.
struct PhotoViewerView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(\.dismiss) private var dismiss

    let viewModel: PhotoBrowserViewModel
    let onPlayClip: (PlexPhotoItem) -> Void

    @State private var currentID: PlexItemID?
    @State private var showsChrome = true
    @State private var isSlideshowRunning: Bool
    #if os(iOS)
    @State private var zoomedID: PlexItemID?
    @FocusState private var isFocused: Bool
    #endif

    /// Seconds each photo stays up in the slideshow.
    private let slideshowInterval: Duration = .seconds(5)

    init(
        viewModel: PhotoBrowserViewModel,
        request: PhotoViewerRequest,
        onPlayClip: @escaping (PlexPhotoItem) -> Void
    ) {
        self.viewModel = viewModel
        self.onPlayClip = onPlayClip
        _currentID = State(initialValue: request.startID)
        _isSlideshowRunning = State(initialValue: request.startsSlideshow)
        #if os(tvOS)
        // The slideshow is a lean-back mode: it starts without the info.
        _showsChrome = State(initialValue: !request.startsSlideshow)
        #endif
    }

    private var currentIndex: Int? {
        viewModel.media.firstIndex { $0.id == currentID }
    }

    private var currentItem: PlexPhotoItem? {
        currentIndex.map { viewModel.media[$0] }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pages
            if showsChrome, let currentItem {
                chrome(for: currentItem)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsChrome)
        .onChange(of: currentID) { _, _ in
            pageDidChange()
        }
        .onAppear {
            pageDidChange()
        }
        .task(id: isSlideshowRunning) {
            await runSlideshow()
        }
        .onDisappear {
            setIdleTimerDisabled(false)
        }
        .duskStatusBarHidden(!showsChrome)
    }

    // MARK: - Pages

    #if os(iOS)
    private var pages: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(viewModel.media) { item in
                    page(for: item)
                        .containerRelativeFrame([.horizontal, .vertical])
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .scrollIndicators(.hidden)
        .scrollDisabled(zoomedID != nil)
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) {
            step(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            step(by: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    @ViewBuilder
    private func page(for item: PlexPhotoItem) -> some View {
        if item.isClip {
            clipPage(for: item)
                .contentShape(Rectangle())
                .onTapGesture { showsChrome.toggle() }
        } else {
            PhotoZoomPage(
                thumbnailURL: thumbnailURL(for: item),
                displayURL: displayURL(for: item),
                onSingleTap: { showsChrome.toggle() },
                onZoomChange: { isZoomed in
                    if isZoomed {
                        zoomedID = item.id
                    } else if zoomedID == item.id {
                        zoomedID = nil
                    }
                }
            )
        }
    }
    #else
    private var pages: some View {
        ZStack {
            if let currentItem {
                Group {
                    if currentItem.isClip {
                        clipPage(for: currentItem)
                    } else {
                        PhotoFitImage(
                            thumbnailURL: thumbnailURL(for: currentItem),
                            displayURL: displayURL(for: currentItem)
                        )
                    }
                }
                .id(currentItem.id)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: currentID)
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left:
                stopSlideshow()
                step(by: -1)
            case .right:
                stopSlideshow()
                step(by: 1)
            default:
                break
            }
        }
        .onPlayPauseCommand {
            if currentItem?.isClip == true {
                play(currentItem)
            } else {
                isSlideshowRunning.toggle()
            }
        }
        .onTapGesture {
            if currentItem?.isClip == true {
                play(currentItem)
            } else {
                showsChrome.toggle()
            }
        }
        .onExitCommand {
            dismiss()
        }
    }
    #endif

    private func clipPage(for item: PlexPhotoItem) -> some View {
        ZStack {
            PhotoFitImage(thumbnailURL: thumbnailURL(for: item), displayURL: nil)

            #if os(iOS)
            Button {
                play(item)
            } label: {
                Image(systemName: "play.fill")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Play video")
            #else
            Image(systemName: "play.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 112, height: 112)
                .background(.ultraThinMaterial, in: Circle())
            #endif
        }
    }

    // MARK: - Chrome

    private func chrome(for item: PlexPhotoItem) -> some View {
        ZStack(alignment: .bottom) {
            // A soft floor so white text reads on a bright photo.
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .frame(height: chromeGradientHeight)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                #if os(iOS)
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Close")

                    Spacer()

                    if let position = positionLabel {
                        Text(position)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                #endif

                Spacer()

                info(for: item)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, chromePadding)
            .padding(.vertical, chromePadding / 2)
        }
    }

    @ViewBuilder
    private func info(for item: PlexPhotoItem) -> some View {
        let details = [item.displayPlace, item.displayCamera].compactMap { $0 }

        VStack(alignment: .leading, spacing: 4) {
            Text(item.displayDate ?? item.title)
                .font(DuskFont.sectionHeader(ios: .headline))
                .foregroundStyle(.white)

            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(DuskFont.metadata(ios: .subheadline))
                    .foregroundStyle(.white.opacity(0.75))
            }

            #if os(tvOS)
            if let position = positionLabel {
                Text(position)
                    .font(DuskFont.caption(ios: .caption).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
            #endif
        }
        .lineLimit(1)
        .allowsHitTesting(false)
    }

    /// "12 of 340", against the loaded list while more is still to come.
    private var positionLabel: String? {
        guard let currentIndex, viewModel.media.count > 1 else { return nil }
        let total = viewModel.hasMore ? "\(viewModel.media.count)+" : "\(viewModel.media.count)"
        return "\(currentIndex + 1) of \(total)"
    }

    private var chromePadding: CGFloat {
        #if os(tvOS)
        80
        #else
        16
        #endif
    }

    private var chromeGradientHeight: CGFloat {
        #if os(tvOS)
        320
        #else
        180
        #endif
    }

    // MARK: - Navigation

    private func step(by offset: Int) {
        guard let currentIndex else { return }
        let target = currentIndex + offset
        guard viewModel.media.indices.contains(target) else { return }
        #if os(iOS)
        withAnimation(.snappy) {
            currentID = viewModel.media[target].id
        }
        #else
        currentID = viewModel.media[target].id
        #endif
    }

    private func pageDidChange() {
        guard let currentIndex else { return }
        // Keep a page ahead of the viewer; the grid behind it pages the same way.
        if viewModel.hasMore, currentIndex >= viewModel.media.count - 10 {
            Task { await viewModel.loadMore() }
        }
        prefetch(around: currentIndex)
    }

    /// Warms the neighbours so a swipe or slideshow step lands on a loaded image.
    private func prefetch(around index: Int) {
        let urls = [index - 1, index + 1, index + 2]
            .filter { viewModel.media.indices.contains($0) }
            .map { viewModel.media[$0] }
            .filter { !$0.isClip }
            .compactMap { displayURL(for: $0) }
        let plexService = plexService
        Task {
            for url in urls {
                _ = try? await DuskImageLoader.shared.image(for: url, using: plexService)
            }
        }
    }

    private func play(_ item: PlexPhotoItem?) {
        guard let item else { return }
        onPlayClip(item)
        dismiss()
    }

    // MARK: - Slideshow

    private func runSlideshow() async {
        setIdleTimerDisabled(isSlideshowRunning)
        guard isSlideshowRunning else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: slideshowInterval)
            guard !Task.isCancelled else { return }
            guard advanceSlideshow() else {
                isSlideshowRunning = false
                return
            }
        }
    }

    /// Moves to the next photo, skipping clips. False at the end of the library.
    private func advanceSlideshow() -> Bool {
        guard let currentIndex else { return false }
        guard let next = viewModel.media[(currentIndex + 1)...].first(where: { !$0.isClip }) else {
            return false
        }
        currentID = next.id
        return true
    }

    private func stopSlideshow() {
        isSlideshowRunning = false
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }

    // MARK: - Images

    private func thumbnailURL(for item: PlexPhotoItem) -> URL? {
        viewModel.thumbnailURL(for: item, side: PhotoGridMetrics.photoPreferredWidth)
    }

    /// Sized to the screen's long edge on both axes, so a photo in either
    /// orientation fits without another request after a rotation.
    private func displayURL(for item: PlexPhotoItem) -> URL? {
        let bounds = UIScreen.main.bounds
        let side = Int(max(bounds.width, bounds.height).rounded(.up))
        #if os(tvOS)
        return plexService.photoDisplayURL(for: item, width: side, height: Int(bounds.height.rounded(.up)))
        #else
        return plexService.photoDisplayURL(for: item, width: side, height: side)
        #endif
    }
}

/// A fitted image that shows the (usually cached) grid thumbnail until the
/// full-size image arrives.
private struct PhotoFitImage: View {
    @Environment(PlexService.self) private var plexService

    let thumbnailURL: URL?
    let displayURL: URL?

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: displayURL) {
            await PhotoImageLoading.load(
                thumbnailURL: thumbnailURL,
                displayURL: displayURL,
                plexService: plexService
            ) { image = $0 }
        }
    }
}

private enum PhotoImageLoading {
    @MainActor
    static func load(
        thumbnailURL: URL?,
        displayURL: URL?,
        plexService: PlexService,
        update: (UIImage) -> Void
    ) async {
        if let thumbnailURL,
           let thumbnail = try? await DuskImageLoader.shared.image(for: thumbnailURL, using: plexService),
           !Task.isCancelled {
            update(thumbnail)
        }
        if let displayURL,
           let full = try? await DuskImageLoader.shared.image(for: displayURL, using: plexService),
           !Task.isCancelled {
            update(full)
        }
    }
}

#if os(iOS)
/// One page of the iOS viewer: the photo in a zooming `UIScrollView`.
///
/// UIKit owns the zoom because pinch, double-tap to zoom, panning a zoomed
/// photo and the single tap that toggles the chrome all have to cooperate,
/// which `UIScrollView` and its recognizers already do natively.
private struct PhotoZoomPage: View {
    @Environment(PlexService.self) private var plexService

    let thumbnailURL: URL?
    let displayURL: URL?
    let onSingleTap: () -> Void
    let onZoomChange: (Bool) -> Void

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            PhotoZoomView(image: image, onSingleTap: onSingleTap, onZoomChange: onZoomChange)
            if image == nil {
                ProgressView()
                    .tint(.white)
            }
        }
        .task(id: displayURL) {
            await PhotoImageLoading.load(
                thumbnailURL: thumbnailURL,
                displayURL: displayURL,
                plexService: plexService
            ) { image = $0 }
        }
    }
}

private struct PhotoZoomView: UIViewRepresentable {
    let image: UIImage?
    let onSingleTap: () -> Void
    let onZoomChange: (Bool) -> Void

    func makeUIView(context: Context) -> PhotoZoomScrollView {
        let view = PhotoZoomScrollView()
        view.onSingleTap = onSingleTap
        view.onZoomChange = onZoomChange
        return view
    }

    func updateUIView(_ view: PhotoZoomScrollView, context: Context) {
        view.onSingleTap = onSingleTap
        view.onZoomChange = onZoomChange
        view.setImage(image)
    }
}

final class PhotoZoomScrollView: UIScrollView, UIScrollViewDelegate {
    var onSingleTap: (() -> Void)?
    var onZoomChange: ((Bool) -> Void)?

    private let imageView = UIImageView()
    private var wasZoomed = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear

        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ image: UIImage?) {
        guard imageView.image !== image else { return }
        // The thumbnail is swapped for the full image in place; the zoom stays.
        imageView.image = image
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == minimumZoomScale {
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let isZoomed = zoomScale > minimumZoomScale + 0.01
        guard isZoomed != wasZoomed else { return }
        wasZoomed = isZoomed
        onZoomChange?(isZoomed)
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = recognizer.location(in: imageView)
            let scale = min(maximumZoomScale, 2.5)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}
#endif
