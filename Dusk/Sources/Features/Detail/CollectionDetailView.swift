import SwiftUI

/// A Plex collection: the backdrop-led detail hero (title, "Collection · 12
/// movies", summary) over a sort chip and a paged grid of its titles. Movie collections get
/// Play (the title in progress, else the next unwatched one) and Shuffle; a
/// show collection only browses. Smart collections look the same: the server
/// resolves their filter when the titles are listed.
struct CollectionDetailView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: CollectionDetailViewModel
    @FocusState private var focusedItemID: PlexItemID?

    private let horizontalPadding: CGFloat = DuskPosterMetrics.detailHorizontalPadding

    init(id: PlexItemID, plexService: PlexService) {
        _viewModel = State(initialValue: CollectionDetailViewModel(id: id, plexService: plexService))
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if viewModel.collection == nil, viewModel.error == nil {
                FeatureLoadingView()
            } else if let error = viewModel.error, viewModel.collection == nil {
                FeatureErrorView(message: error) {
                    Task { await viewModel.load() }
                }
            } else {
                contentView
            }
        }
        .duskNavigationBarTitleDisplayModeInline()
        #if !os(macOS)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        #if os(macOS)
        // A standard toolbar menu on the Mac, like the library grids' sort.
        .toolbar {
            if viewModel.collection != nil, viewModel.showsSortMenu {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        sortMenuPickers
                    } label: {
                        Label(viewModel.sortTitle, systemImage: "arrow.up.arrow.down")
                            .labelStyle(.titleOnly)
                            .fixedSize()
                    }
                    .help("Sort: \(viewModel.sortTitle)")
                    .id("sort|\(viewModel.sortTitle)")
                }
            }
        }
        #endif
        .task {
            await viewModel.load()
        }
        .onChange(of: playback.showPlayer) { _, isShowing in
            if !isShowing {
                Task { await viewModel.refresh() }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await viewModel.refresh() }
        }
    }

    // MARK: - Content

    private var contentView: some View {
        GeometryReader { geometry in
            // The backdrop runs under side insets (iPhone landscape, iPhone
            // Duo's vertical bar); the hero content stays inside them.
            let heroBackgroundWidth = geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing
            let heroBackgroundLeadingInset = geometry.safeAreaInsets.leading
            let layout = AdaptivePosterGridLayout.make(
                containerWidth: geometry.size.width,
                horizontalPadding: horizontalPadding,
                gridSpacing: DuskPosterMetrics.gridSpacing,
                preferredPosterWidth: viewModel.showsLandscapeItems
                    ? DuskPosterMetrics.videoGridPreferredWidth
                    : DuskPosterMetrics.gridPreferredWidth,
                minimumColumnCount: 2
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heroSection(
                        topInset: geometry.safeAreaInsets.top,
                        containerWidth: heroBackgroundWidth,
                        containerHeight: geometry.size.height,
                        backgroundLeadingInset: heroBackgroundLeadingInset
                    )
                    #if os(tvOS)
                    .focusSection()
                    #endif

                    if detailShowsSynopsisBelowHero(for: sizeClass), let summary = viewModel.summary {
                        ExpandableSummaryText(text: summary, collapsedLineLimit: 4)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, 32)
                    }

                    if showsInlineSortMenu, viewModel.showsSortMenu {
                        sortRow
                            .padding(.top, sortRowTopPadding)
                    }

                    itemsSection(layout)
                        .padding(.top, showsInlineSortMenu && viewModel.showsSortMenu ? 20 : 40)
                        .padding(.bottom, 56)
                }
                .padding(.top, -geometry.safeAreaInsets.top)
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
            .duskTVOSPageBackground()
        }
    }

    // MARK: - Hero

    private func heroSection(
        topInset: CGFloat,
        containerWidth: CGFloat,
        containerHeight: CGFloat,
        backgroundLeadingInset: CGFloat
    ) -> some View {
        // Shorter than a movie's hero: the titles below are the content.
        let heroBase = min(max(containerHeight * 0.6, 440), 640)
        let heroHeight = heroBase + topInset

        return DetailHeroSection(
            backdropURL: viewModel.backdropURL(
                width: Int(containerWidth.rounded(.up)),
                height: Int(heroHeight.rounded(.up))
            ),
            title: viewModel.title,
            descriptionText: viewModel.summary,
            topInset: topInset,
            containerWidth: containerWidth,
            backgroundLeadingInset: backgroundLeadingInset,
            heroBaseHeight: heroBase,
            leadsWithTextTitle: true
        ) {
            if let metadata = viewModel.metadataLine {
                Text(metadata)
                    .font(DuskFont.metadata(ios: .subheadline.weight(.medium)))
                    .foregroundStyle(Color.primary.opacity(0.78))
                    .multilineTextAlignment(detailHeroTextAlignment(for: sizeClass))
            }
        } actions: {
            if viewModel.isPlayable {
                actionButtons
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        #if os(tvOS)
        HStack(spacing: detailHeroActionSpacing) {
            playButton
            shuffleButton
        }
        #else
        VStack(alignment: usesFullWidthDetailActionButtons(for: sizeClass) ? .center : .leading, spacing: detailHeroActionSpacing) {
            playButton

            HStack(spacing: detailHeroActionSpacing) {
                shuffleButton
            }
        }
        .detailHeroActionStackFrame(isCompactPhone: usesFullWidthDetailActionButtons(for: sizeClass))
        #endif
    }

    private var playButton: some View {
        Button {
            if let item = viewModel.nextUp {
                play(item)
            }
        } label: {
            DetailHeroPrimaryActionButtonLabel(
                title: viewModel.playButtonTitle,
                systemImage: "play.fill",
                fillsWidth: fillsActionWidth
            )
        }
        .detailHeroNativePrimaryButtonStyle()
    }

    private var shuffleButton: some View {
        Button {
            if let queue = viewModel.shuffledQueue() {
                Task { await playback.playQueue(queue, fromStart: true) }
            }
        } label: {
            DetailHeroSecondaryIconLabel(systemImage: "shuffle", title: "Shuffle")
        }
        .detailHeroNativeSecondaryButtonStyle()
        .accessibilityLabel("Shuffle")
    }

    private var fillsActionWidth: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    // MARK: - Sort

    /// The Mac sorts from the window toolbar instead.
    private var showsInlineSortMenu: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }

    private var sortRowTopPadding: CGFloat {
        #if os(tvOS)
        // Room for the focus lift above the chip.
        22
        #else
        32
        #endif
    }

    /// The library grid's sort chip, leading with the collection's own order.
    private var sortRow: some View {
        let isSorted = viewModel.selectedSort != nil
        return HStack {
            Menu {
                LibrarySortMenuSections(
                    fields: viewModel.availableSortFields,
                    selected: viewModel.selectedSort,
                    defaultTitle: CollectionSort.defaultTitle
                ) { sort in
                    Task { await viewModel.selectSort(sort) }
                }
            } label: {
                BrowseChipMenuLabel(
                    value: viewModel.sortTitle,
                    systemImage: "arrow.up.arrow.down.circle",
                    isActive: isSorted,
                    accessibilityTitle: "Sort"
                )
            }
            .browseChipButtonStyle(isOn: isSorted)

            // The titles on screen stay until the new order lands.
            if viewModel.pager.isLoading, !viewModel.items.isEmpty {
                ProgressView()
                    .padding(.leading, 6)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, horizontalPadding)
        #if os(tvOS)
        .padding(.vertical, 18)
        // Up from any poster in the first row reaches the chip, and the
        // focused chip's lift draws over the grid, not under it.
        .focusSection()
        .zIndex(1)
        #endif
    }

    #if os(macOS)
    private var sortMenuPickers: some View {
        LibrarySortMenuPickers(
            fields: viewModel.availableSortFields,
            selected: viewModel.selectedSort,
            defaultTitle: CollectionSort.defaultTitle
        ) { sort in
            Task { await viewModel.selectSort(sort) }
        }
    }
    #endif

    // MARK: - Items

    @ViewBuilder
    private func itemsSection(_ layout: AdaptivePosterGridLayout) -> some View {
        if viewModel.items.isEmpty {
            if viewModel.pager.hasLoadedOnce, !viewModel.isSortingOnDevice {
                FeatureEmptyStateView(
                    systemImage: "square.stack",
                    title: "This collection is empty"
                )
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                PlexItemPosterGrid(
                    items: viewModel.items,
                    layout: layout,
                    rowSpacing: DuskPosterMetrics.gridRowSpacing,
                    imageAspectRatio: viewModel.showsLandscapeItems ? 16.0 / 9.0 : 2.0 / 3.0,
                    posterURL: { item, width, height in
                        viewModel.posterURL(for: item, width: width, height: height)
                    },
                    subtitle: { viewModel.subtitle(for: $0) },
                    progress: { $0.posterProgress },
                    onItemAppear: { item in
                        Task { await viewModel.loadMoreIfNeeded(currentItem: item) }
                    },
                    playThroughTitle: viewModel.title,
                    focusedItemID: $focusedItemID
                ) { item in
                    PlexItemContextMenuContent(
                        item: item,
                        onMarkWatched: {
                            Task { await viewModel.setWatched(true, for: item) }
                        },
                        onMarkUnwatched: {
                            Task { await viewModel.setWatched(false, for: item) }
                        }
                    )
                }
                .padding(.horizontal, horizontalPadding)

                if viewModel.pager.isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                }
            }
            #if os(tvOS)
            .focusSection()
            // Down from the sort chip lands on the first title. Left to the
            // engine it picked the second poster, though the chip sits over
            // the first.
            .defaultFocus($focusedItemID, viewModel.items.first?.id, priority: .userInitiated)
            #endif
        }
    }

    /// Plays `item` and then the rest of the collection, in its order.
    private func play(_ item: PlexItem) {
        Task {
            await playback.play(
                id: item.id,
                resumeOffsetMilliseconds: item.viewOffset,
                resumeOffsetDurationMilliseconds: item.duration,
                placeholder: PlaybackPlaceholder(item: item),
                queue: viewModel.playThrough?.queue(startingAt: item.id)
            )
        }
    }
}
