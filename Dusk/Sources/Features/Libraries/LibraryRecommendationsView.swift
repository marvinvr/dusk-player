import SwiftUI
#if os(iOS)
import UIKit
#endif

struct LibraryRecommendationsView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(PlexService.self) private var plexService
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: LibraryRecommendationsViewModel
    #if os(iOS)
    @State private var menuBrowseTarget: LibraryBrowseTarget?
    #endif

    private let navigationTitle: String
    /// The libraries "Browse" opens straight into: one button (tvOS) or menu
    /// entry (iOS) each, so no library is more than one step from its tab.
    private let browseTargets: [LibraryBrowseTarget]
    /// The list of this screen's libraries, for their own recommendations.
    private let libraryListDestination: LibraryTypeListDestination?
    /// iOS: pushes that list from the Browse menu, which cannot hold a
    /// `NavigationLink`. The list's owner does the push.
    private let showLibraryList: (() -> Void)?

    private let continueWatchingCardWidth: CGFloat = DuskPosterMetrics.continueWatchingWidth
    private let continueWatchingAspectRatio: CGFloat = 16.0 / 9.0

    init(
        library: PlexLibrary,
        plexService: PlexService,
        navigationTitle: String
    ) {
        self.init(
            libraries: [library],
            plexService: plexService,
            navigationTitle: navigationTitle,
            browseTargets: [],
            libraryListDestination: nil,
            showLibraryList: nil
        )
    }

    init(
        libraries: [PlexLibrary],
        plexService: PlexService,
        navigationTitle: String,
        browseTargets: [LibraryBrowseTarget],
        libraryListDestination: LibraryTypeListDestination?,
        showLibraryList: (() -> Void)?
    ) {
        self.showLibraryList = showLibraryList
        self.navigationTitle = navigationTitle
        self.browseTargets = browseTargets
        self.libraryListDestination = libraryListDestination
        _viewModel = State(initialValue: LibraryRecommendationsViewModel(
            libraries: libraries,
            plexService: plexService
        ))
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if !viewModel.hasLoadedOnce,
               viewModel.error == nil,
               !viewModel.hasAnyContent {
                FeatureLoadingView()
            } else {
                contentView
            }
        }
        .task {
            await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit)
        }
        .onChange(of: playback.showPlayer) { _, isShowing in
            if !isShowing {
                Task { await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, viewModel.hasLoadedOnce else { return }
            Task { await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                SearchToolbarLink()

                browseLibraryButton
            }
        }
        .navigationDestination(item: $menuBrowseTarget) { target in
            LibraryItemsView(library: target.library, plexService: plexService)
        }
        #endif
        .duskNavigationTitle(navigationTitle)
        .duskNavigationBarTitleDisplayModeLarge()
    }

    private var contentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                #if os(tvOS)
                // Leading and first in the page, so it is where focus lands
                // when moving down from the tab bar.
                HStack(spacing: 20) {
                    browseLibraryButtons
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DuskPosterMetrics.carouselHorizontalPadding)
                .padding(.top, DuskPosterMetrics.carouselHeaderSpacing)
                .padding(.bottom, DuskPosterMetrics.carouselHeaderSpacing)
                #endif

                if let error = viewModel.error,
                   !viewModel.hasAnyContent {
                    FeatureErrorView(message: error) {
                        Task { await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
                    }
                    .padding(.top, 40)
                } else if !viewModel.hasAnyContent {
                    emptyView
                        .padding(.top, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: DuskPosterMetrics.pageSectionSpacing) {
                        ServerOutageNote()
                            .padding(.horizontal, DuskPosterMetrics.libraryPageHorizontalPadding)

                        if !viewModel.continueWatching.isEmpty {
                            continueWatchingSection
                        }

                        ForEach(viewModel.prioritizedHubs) { hub in
                            let items = viewModel.inlineItems(in: hub)

                            if !items.isEmpty {
                                hubSection(hub, items: items)
                            }
                        }

                        if viewModel.isVideoLibrary {
                            ForEach(viewModel.secondaryHubs) { hub in
                                let items = viewModel.inlineItems(in: hub)

                                if !items.isEmpty {
                                    hubSection(hub, items: items)
                                }
                            }

                            ForEach(viewModel.channelShelves) { row in
                                if !row.shelf.items.isEmpty {
                                    channelShelfSection(row)
                                }
                            }

                            if !viewModel.rediscoverItems.isEmpty {
                                rediscoverSection
                            }
                        } else {
                            ForEach(viewModel.personalizedShelves) { shelf in
                                if !shelf.items.isEmpty {
                                    personalizedShelfSection(shelf)
                                }
                            }

                            ForEach(viewModel.secondaryHubs) { hub in
                                let items = viewModel.inlineItems(in: hub)

                                if !items.isEmpty {
                                    hubSection(hub, items: items)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 48)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: 88)
        }
        .refreshable {
            await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit)
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
        .duskTVOSPageBackground()
    }

    /// The libraries "Browse" offers. A screen opened for one library (from
    /// the library list) browses that library.
    private var resolvedBrowseTargets: [LibraryBrowseTarget] {
        browseTargets.isEmpty
            ? [LibraryBrowseTarget(library: viewModel.library, title: viewModel.library.title)]
            : browseTargets
    }

    #if os(tvOS)
    /// One button per library, straight to its grid, then "Libraries" for
    /// the per-library recommendations when there are several.
    @ViewBuilder
    private var browseLibraryButtons: some View {
        ForEach(resolvedBrowseTargets, id: \.self) { target in
            styledBrowseLink(
                NavigationLink(value: AppNavigationRoute.library(target.library)) {
                    browseLabel("All \(target.title)")
                }
            )
        }

        if let libraryListDestination, viewModel.isMultiLibrary {
            styledBrowseLink(
                NavigationLink(value: libraryListDestination) {
                    browseLabel("Libraries")
                }
            )
        }
    }
    #else
    /// One library: browse it. Several: a menu of them, each straight to its
    /// grid, plus the list for their own recommendations.
    @ViewBuilder
    private var browseLibraryButton: some View {
        let targets = resolvedBrowseTargets

        if targets.count > 1 {
            Menu {
                ForEach(targets, id: \.self) { target in
                    Button(target.title) {
                        menuBrowseTarget = target
                    }
                }

                if let showLibraryList {
                    Divider()

                    Button("Libraries", systemImage: "list.bullet", action: showLibraryList)
                }
            } label: {
                browseLabel("Browse")
            }
        } else {
            styledBrowseLink(
                NavigationLink(value: AppNavigationRoute.library(viewModel.library)) {
                    browseLabel("Browse Library")
                }
            )
        }
    }
    #endif

    @ViewBuilder
    private func browseLabel(_ labelText: String) -> some View {
        #if os(tvOS)
        Text(labelText)
            .font(DuskFont.buttonLabel(ios: .subheadline.weight(.semibold)))
        #else
        Label(labelText, systemImage: "square.grid.2x2")
            .font(.subheadline.weight(.semibold))
        #endif
    }

    @ViewBuilder
    private func styledBrowseLink(_ link: some View) -> some View {
        #if os(tvOS)
        link
            .controlSize(.small)
            .buttonBorderShape(.capsule)
            .buttonStyle(.glass)
            .tint(Color.primary)
        #else
        link
            .buttonStyle(.plain)
        #endif
    }

    private var continueWatchingSection: some View {
        PlexItemActionCarouselSection(
            title: viewModel.continueWatchingTitle,
            items: viewModel.continueWatching,
            action: { play($0) },
            posterWidth: continueWatchingCardWidth,
            imageAspectRatio: continueWatchingAspectRatio,
            horizontalPadding: DuskPosterMetrics.libraryPageHorizontalPadding,
            subtitle: { viewModel.displaySubtitle(for: $0) },
            posterURL: { item, width, height in
                viewModel.landscapeImageURL(for: item, width: width, height: height)
            },
            progress: { viewModel.progress(for: $0) }
        ) { item in
            PlexItemContextMenuContent(
                item: item,
                onMarkWatched: {
                    Task { await viewModel.setWatched(true, for: item) }
                },
                onMarkUnwatched: {
                    Task { await viewModel.setWatched(false, for: item) }
                },
                detailsRoute: AppNavigationRoute.destination(for: item),
                detailsLabel: detailsLabel(for: item)
            )
        }
    }

    @ViewBuilder
    private func personalizedShelfSection(_ shelf: LibraryPersonalizedShelf) -> some View {
        PlexItemPosterCarouselSection(
            title: shelf.title,
            items: shelf.items,
            horizontalPadding: DuskPosterMetrics.libraryPageHorizontalPadding,
            showAllRoute: shelf.showAllLibrary.map {
                AppNavigationRoute.libraryGenre(library: $0, genre: shelf.genre)
            },
            subtitle: { viewModel.subtitle(for: $0) },
            posterURL: { item, width, height in
                viewModel.posterURL(for: item, width: width, height: height)
            }
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
    }

    @ViewBuilder
    private func hubSection(_ hub: PlexHub, items: [PlexItem]) -> some View {
        let showsShowAll = viewModel.shouldShowAll(for: hub)

        PlexItemPosterCarouselSection(
            title: viewModel.normalizedTitle(for: hub),
            items: items,
            posterWidth: shelfPosterWidth,
            imageAspectRatio: shelfImageAspectRatio,
            horizontalPadding: DuskPosterMetrics.libraryPageHorizontalPadding,
            showAllRoute: showsShowAll ? AppNavigationRoute.hub(hub) : nil,
            subtitle: { viewModel.subtitle(for: $0) },
            posterURL: { item, width, height in
                viewModel.posterURL(for: item, width: width, height: height)
            }
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
    }

    @ViewBuilder
    private func channelShelfSection(_ row: LibraryChannelRow) -> some View {
        let shelf = row.shelf

        PlexItemPosterCarouselSection(
            title: shelf.collection.title,
            items: shelf.items,
            posterWidth: shelfPosterWidth,
            imageAspectRatio: shelfImageAspectRatio,
            horizontalPadding: DuskPosterMetrics.libraryPageHorizontalPadding,
            showAllRoute: AppNavigationRoute.libraryCollection(
                library: row.library,
                collection: shelf.collection
            ),
            subtitle: { viewModel.subtitle(for: $0) },
            posterURL: { item, width, height in
                viewModel.posterURL(for: item, width: width, height: height)
            }
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
    }

    private var rediscoverSection: some View {
        PlexItemPosterCarouselSection(
            title: "Rediscover",
            items: viewModel.rediscoverItems,
            posterWidth: shelfPosterWidth,
            imageAspectRatio: shelfImageAspectRatio,
            horizontalPadding: DuskPosterMetrics.libraryPageHorizontalPadding,
            subtitle: { viewModel.subtitle(for: $0) },
            posterURL: { item, width, height in
                viewModel.posterURL(for: item, width: width, height: height)
            }
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
    }

    /// Video-library shelves render 16:9 clip cards; movie/show shelves keep
    /// the standard 2:3 posters.
    private var shelfPosterWidth: CGFloat {
        viewModel.isVideoLibrary ? DuskPosterMetrics.videoCarouselWidth : DuskPosterMetrics.carouselPosterWidth
    }

    private var shelfImageAspectRatio: CGFloat {
        viewModel.isVideoLibrary ? 16.0 / 9.0 : 2.0 / 3.0
    }

    private var emptyView: some View {
        FeatureEmptyStateView(
            systemImage: viewModel.library.libraryType?.systemImage ?? "rectangle.stack",
            title: "No recommendations right now"
        )
    }

    private var recentlyAddedInlineItemLimit: Int {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? 22 : 15
        #else
        15
        #endif
    }

    private func play(_ item: PlexItem) {
        Task {
            await playback.play(
                id: item.id,
                resumeOffsetMilliseconds: item.viewOffset,
                resumeOffsetDurationMilliseconds: item.duration,
                placeholder: PlaybackPlaceholder(item: item)
            )
        }
    }

    private func detailsLabel(for item: PlexItem) -> String {
        if item.isClip {
            return "Go to Video"
        }

        switch item.type {
        case .episode:
            return "Go to Episode"
        case .movie:
            return "Go to Movie"
        default:
            return "View Details"
        }
    }
}
