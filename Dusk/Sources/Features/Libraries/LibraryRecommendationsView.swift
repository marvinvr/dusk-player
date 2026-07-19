import SwiftUI
#if os(iOS)
import UIKit
#endif

struct LibraryRecommendationsView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: LibraryRecommendationsViewModel

    private let navigationTitle: String

    private let continueWatchingCardWidth: CGFloat = DuskPosterMetrics.continueWatchingWidth
    private let continueWatchingAspectRatio: CGFloat = 16.0 / 9.0

    init(
        library: PlexLibrary,
        plexService: PlexService,
        navigationTitle: String
    ) {
        self.navigationTitle = navigationTitle
        _viewModel = State(initialValue: LibraryRecommendationsViewModel(
            library: library,
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
            ToolbarItem(placement: .topBarTrailing) {
                browseLibraryButton(labelText: "Browse Library")
            }
        }
        #endif
        .duskNavigationTitle(navigationTitle)
        .duskNavigationBarTitleDisplayModeLarge()
    }

    private var contentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                #if os(tvOS)
                HStack {
                    Spacer()
                    browseLibraryButton(labelText: "Browse")
                }
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

                            ForEach(viewModel.channelShelves) { shelf in
                                if !shelf.items.isEmpty {
                                    channelShelfSection(shelf)
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

    @ViewBuilder
    private func browseLibraryButton(labelText: String) -> some View {
        #if os(tvOS)
        ShowAllCarouselLink(
            route: AppNavigationRoute.library(viewModel.library),
            title: labelText
        )
        #else
        NavigationLink(value: AppNavigationRoute.library(viewModel.library)) {
            Label(labelText, systemImage: "square.grid.2x2")
                .font(.subheadline.weight(.semibold))
        }
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
            showAllRoute: AppNavigationRoute.libraryGenre(library: viewModel.library, genre: shelf.genre),
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
    private func channelShelfSection(_ shelf: LibraryVideoChannelShelf) -> some View {
        PlexItemPosterCarouselSection(
            title: shelf.collection.title,
            items: shelf.items,
            posterWidth: shelfPosterWidth,
            imageAspectRatio: shelfImageAspectRatio,
            horizontalPadding: DuskPosterMetrics.libraryPageHorizontalPadding,
            showAllRoute: AppNavigationRoute.libraryCollection(
                library: viewModel.library,
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
        UIDevice.current.userInterfaceIdiom == .pad ? 15 : 10
        #else
        10
        #endif
    }

    private func play(_ item: PlexItem) {
        Task {
            await playback.play(ratingKey: item.ratingKey, placeholder: PlaybackPlaceholder(item: item))
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
