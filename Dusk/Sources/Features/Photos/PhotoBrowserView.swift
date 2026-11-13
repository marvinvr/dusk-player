import SwiftUI

/// What the full-screen viewer opens on.
struct PhotoViewerRequest: Identifiable {
    let id = UUID()
    let startID: PlexItemID
    let startsSlideshow: Bool
}

/// A photo library root or one of its albums: sub-albums first, then the
/// photos and clips as a square grid. Photos open the full-screen viewer;
/// clips play straight away in the regular player.
struct PhotoBrowserView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var viewModel: PhotoBrowserViewModel
    @State private var viewerRequest: PhotoViewerRequest?
    /// A clip picked inside the viewer. It plays once the viewer is gone: the
    /// player is a full-screen cover of the tab shell and cannot present over
    /// another cover.
    @State private var pendingClip: PlexPhotoItem?

    init(library: PlexLibrary, album: PhotoAlbumRoute? = nil, plexService: PlexService) {
        _viewModel = State(initialValue: PhotoBrowserViewModel(
            library: library,
            album: album,
            plexService: plexService
        ))
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if viewModel.isLoading && viewModel.isEmpty && !viewModel.showsModePicker {
                FeatureLoadingView()
            } else if let error = viewModel.error, viewModel.isEmpty, !viewModel.showsModePicker {
                FeatureErrorView(message: error) {
                    Task { await viewModel.reload() }
                }
            } else {
                content
            }
        }
        .duskNavigationTitle(viewModel.navigationTitle)
        .duskNavigationBarTitleDisplayModeLarge()
        .task {
            await viewModel.loadIfNeeded()
            #if DEBUG
            openScreenshotViewerIfRequested()
            #endif
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SearchToolbarLink()
            }
        }
        #endif
        #if os(macOS)
        // No full-screen cover on the Mac: a large sheet over the window.
        .sheet(item: $viewerRequest, onDismiss: playPendingClip) { request in
            PhotoViewerView(viewModel: viewModel, request: request) { clip in
                pendingClip = clip
            }
            .macUISheetSize(minWidth: 720, idealWidth: 1200, minHeight: 480, idealHeight: 800)
        }
        #else
        .fullScreenCover(item: $viewerRequest, onDismiss: playPendingClip) { request in
            PhotoViewerView(viewModel: viewModel, request: request) { clip in
                pendingClip = clip
            }
        }
        #endif
    }

    private var content: some View {
        GeometryReader { geometry in
            let albumLayout = AdaptivePosterGridLayout.make(
                containerWidth: geometry.size.width,
                horizontalPadding: PhotoGridMetrics.horizontalPadding,
                gridSpacing: PhotoGridMetrics.albumSpacing,
                preferredPosterWidth: PhotoGridMetrics.albumPreferredWidth
            )
            let photoLayout = AdaptivePosterGridLayout.make(
                containerWidth: geometry.size.width,
                horizontalPadding: PhotoGridMetrics.horizontalPadding,
                gridSpacing: PhotoGridMetrics.photoSpacing,
                preferredPosterWidth: PhotoGridMetrics.photoPreferredWidth,
                minimumColumnCount: 4
            )

            ScrollView {
                VStack(alignment: .leading, spacing: PhotoGridMetrics.sectionSpacing) {
                    if viewModel.showsModePicker || canStartSlideshow {
                        controls
                    }

                    if viewModel.isLoading && viewModel.isEmpty {
                        FeatureLoadingView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else if let error = viewModel.error, viewModel.isEmpty {
                        FeatureErrorView(message: error) {
                            Task { await viewModel.reload() }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else if viewModel.isEmpty {
                        FeatureEmptyStateView(
                            systemImage: PlexLibraryType.photo.systemImage,
                            title: viewModel.emptyStateTitle
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }

                    if !viewModel.albums.isEmpty {
                        albumGrid(albumLayout)
                    }

                    if !viewModel.media.isEmpty {
                        photoGrid(photoLayout)
                    }

                    if viewModel.isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, DuskPosterMetrics.pageBottomPadding)
            }
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }

    private var canStartSlideshow: Bool {
        #if os(tvOS)
        viewModel.hasPhotos
        #else
        false
        #endif
    }

    private var controls: some View {
        HStack(spacing: 20) {
            if viewModel.showsModePicker {
                Picker("View", selection: modeBinding) {
                    ForEach(PhotoBrowseMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            #if os(tvOS)
            if canStartSlideshow {
                Button {
                    openViewer(at: viewModel.media.first { $0.kind == .photo }, slideshow: true)
                } label: {
                    Label("Slideshow", systemImage: "play.fill")
                        .font(DuskFont.TV.buttonLabel)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
            }
            #endif

            Spacer(minLength: 0)
        }
        .padding(.horizontal, PhotoGridMetrics.horizontalPadding)
    }

    private var modeBinding: Binding<PhotoBrowseMode> {
        Binding(
            get: { viewModel.mode },
            set: { mode in Task { await viewModel.selectMode(mode) } }
        )
    }

    private func albumGrid(_ layout: AdaptivePosterGridLayout) -> some View {
        LazyVGrid(columns: layout.columns, alignment: .leading, spacing: DuskPosterMetrics.gridRowSpacing) {
            ForEach(viewModel.albums) { album in
                PhotoAlbumCard(
                    album: album,
                    route: viewModel.route(for: album),
                    imageURL: viewModel.thumbnailURL(for: album, side: layout.posterWidth),
                    side: layout.posterWidth
                )
                .onAppear {
                    Task { await viewModel.loadMoreIfNeeded(currentItem: album) }
                }
            }
        }
        .padding(.horizontal, PhotoGridMetrics.horizontalPadding)
    }

    private func photoGrid(_ layout: AdaptivePosterGridLayout) -> some View {
        LazyVGrid(columns: layout.columns, alignment: .leading, spacing: PhotoGridMetrics.photoSpacing) {
            ForEach(viewModel.media) { item in
                PhotoTile(
                    item: item,
                    imageURL: viewModel.thumbnailURL(for: item, side: layout.posterWidth),
                    side: layout.posterWidth,
                    onOpen: { open(item) },
                    onSlideshow: { openViewer(at: item, slideshow: true) }
                )
                .onAppear {
                    Task { await viewModel.loadMoreIfNeeded(currentItem: item) }
                }
            }
        }
        .padding(.horizontal, PhotoGridMetrics.horizontalPadding)
    }

    private func open(_ item: PlexPhotoItem) {
        if item.isClip {
            play(item)
        } else {
            openViewer(at: item, slideshow: false)
        }
    }

    private func openViewer(at item: PlexPhotoItem?, slideshow: Bool) {
        guard let item else { return }
        viewerRequest = PhotoViewerRequest(startID: item.id, startsSlideshow: slideshow)
    }

    private func playPendingClip() {
        guard let clip = pendingClip else { return }
        pendingClip = nil
        play(clip)
    }

    private func play(_ clip: PlexPhotoItem) {
        Task {
            await playback.play(
                id: clip.id,
                resumeOffsetMilliseconds: nil,
                placeholder: PlaybackPlaceholder(
                    title: clip.title,
                    subtitle: clip.displayDate,
                    posterPath: clip.thumb,
                    backdropPath: clip.thumb,
                    serverID: clip.serverID
                )
            )
        }
    }

    #if DEBUG
    /// Screenshot mode: `-DuskScreenshotPhotoViewer <n>` opens the viewer on
    /// the n-th photo of the requested grid.
    private func openScreenshotViewerIfRequested() {
        guard let index = ScreenshotMode.consumePhotoViewerIndex(inAlbum: !viewModel.showsModePicker),
              viewModel.media.indices.contains(index) else { return }
        openViewer(at: viewModel.media[index], slideshow: ScreenshotMode.startsPhotoSlideshow)
    }
    #endif
}

enum PhotoGridMetrics {
    static var horizontalPadding: CGFloat {
        DuskPosterMetrics.gridHorizontalPadding
    }

    static var sectionSpacing: CGFloat {
        DuskPosterMetrics.pageSectionSpacing
    }

    static var albumSpacing: CGFloat {
        DuskPosterMetrics.gridSpacing
    }

    static var albumPreferredWidth: CGFloat {
        #if os(tvOS)
        300
        #else
        150
        #endif
    }

    /// Photos sit close together like a camera roll; tvOS keeps room for the
    /// focused tile to lift.
    static var photoSpacing: CGFloat {
        #if os(tvOS)
        36
        #else
        3
        #endif
    }

    static var photoPreferredWidth: CGFloat {
        #if os(tvOS)
        250
        #else
        88
        #endif
    }

    static var photoCornerRadius: CGFloat {
        #if os(tvOS)
        16
        #else
        6
        #endif
    }
}

private struct PhotoAlbumCard: View {
    let album: PlexPhotoItem
    let route: AppNavigationRoute
    let imageURL: URL?
    let side: CGFloat
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PosterArtwork.cornerRadius, style: .continuous)

        VStack(alignment: .leading, spacing: DuskPosterMetrics.cardSpacing) {
            NavigationLink(value: route) {
                PhotoThumbnail(url: imageURL, systemImage: "rectangle.stack")
                    .frame(width: side, height: side)
                    .clipShape(shape)
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .duskSuppressTVOSButtonChrome()
            #if os(tvOS)
            .focused($isFocused)
            .duskTVOSFocusEffectShape(shape, scales: false)
            #endif

            Text(album.title)
                .font(DuskFont.cardTitle(ios: .subheadline.weight(.semibold)))
                .foregroundStyle(Color.duskTextPrimary)
                .lineLimit(1)
        }
        .frame(width: side, alignment: .topLeading)
        #if os(tvOS)
        .duskTVOSFocusedScale(isFocused)
        .zIndex(isFocused ? 1 : 0)
        #endif
    }
}

private struct PhotoTile: View {
    let item: PlexPhotoItem
    let imageURL: URL?
    let side: CGFloat
    let onOpen: () -> Void
    let onSlideshow: () -> Void
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PhotoGridMetrics.photoCornerRadius, style: .continuous)

        Button(action: onOpen) {
            PhotoThumbnail(url: imageURL, systemImage: item.isClip ? "video" : "photo")
                .frame(width: side, height: side)
                .overlay(alignment: .bottomLeading) {
                    if item.isClip {
                        clipBadge
                    }
                }
                .clipShape(shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .duskSuppressTVOSButtonChrome()
        .accessibilityLabel(accessibilityLabel)
        #if os(tvOS)
        .focused($isFocused)
        .duskTVOSFocusEffectShape(shape, scales: false)
        .duskTVOSFocusedScale(isFocused)
        .zIndex(isFocused ? 1 : 0)
        // Play/Pause on a focused photo starts the slideshow from it.
        .onPlayPauseCommand {
            if !item.isClip { onSlideshow() }
        }
        #endif
    }

    private var clipBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "play.fill")
            if let duration = clipDuration {
                Text(duration)
                    .monospacedDigit()
            }
        }
        .font(DuskFont.badge(ios: .caption2.weight(.semibold)))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 3)
        .padding(6)
    }

    /// "0:09", the way a camera roll labels its videos.
    private var clipDuration: String? {
        guard let duration = item.duration, duration > 0 else { return nil }
        let seconds = Int((Double(duration) / 1000).rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var accessibilityLabel: String {
        let kind = item.isClip ? "Video" : "Photo"
        return [kind, item.displayDate].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A square, cropped Plex thumbnail with a quiet placeholder.
struct PhotoThumbnail: View {
    let url: URL?
    var systemImage = "photo"

    var body: some View {
        Color.duskSurface
            .overlay {
                DuskAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        Image(systemName: systemImage)
                            .font(DuskFont.glyphMedium(ios: .title3))
                            .foregroundStyle(Color.duskTextSecondary)
                    case .empty:
                        Color.clear
                    }
                }
            }
            .clipped()
    }
}
