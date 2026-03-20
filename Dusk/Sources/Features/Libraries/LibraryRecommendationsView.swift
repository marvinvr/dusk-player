import SwiftUI
#if os(iOS)
import UIKit
#endif

struct LibraryRecommendationsView: View {
    @Environment(PlaybackCoordinator.self) private var playback
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

            if !viewModel.hasLoadedOnce, viewModel.error == nil, viewModel.hubs.isEmpty, viewModel.continueWatching.isEmpty {
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

                if let error = viewModel.error, viewModel.hubs.isEmpty, viewModel.continueWatching.isEmpty {
                    FeatureErrorView(message: error) {
                        Task { await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
                    }
                    .padding(.top, 40)
                } else if viewModel.hubs.isEmpty, viewModel.continueWatching.isEmpty {
                    emptyView
                        .padding(.top, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: DuskPosterMetrics.pageSectionSpacing) {
                        if !viewModel.continueWatching.isEmpty {
                            continueWatchingSection
                        }

                        ForEach(viewModel.hubs) { hub in
                            let items = viewModel.inlineItems(in: hub)

                            if !items.isEmpty {
                                hubSection(hub, items: items)
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
    }

    @ViewBuilder
    private func browseLibraryButton(labelText: String) -> some View {
        NavigationLink(value: AppNavigationRoute.library(viewModel.library)) {
            #if os(tvOS)
            TVBrowseLibraryButtonLabel(title: labelText)
            #else
            Label(labelText, systemImage: "square.grid.2x2")
                .font(.subheadline.weight(.semibold))
            #endif
        }
        .buttonStyle(.plain)
        .duskSuppressTVOSButtonChrome()
        .duskTVOSFocusEffectShape(Capsule())
    }

    private var continueWatchingSection: some View {
        let imageWidth = Int(continueWatchingCardWidth.rounded(.up))
        let imageHeight = Int((continueWatchingCardWidth / continueWatchingAspectRatio).rounded(.up))

        return MediaCarousel(title: viewModel.continueWatchingTitle) {
            ForEach(viewModel.continueWatching) { item in
                PosterActionCard(
                    action: { play(item) },
                    imageURL: viewModel.landscapeImageURL(for: item, width: imageWidth, height: imageHeight),
                    title: viewModel.displayTitle(for: item),
                    subtitle: viewModel.displaySubtitle(for: item),
                    progress: viewModel.progress(for: item),
                    width: continueWatchingCardWidth,
                    imageAspectRatio: continueWatchingAspectRatio,
                    showsPlayOverlay: true
                ) {
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
        }
    }

    @ViewBuilder
    private func hubSection(_ hub: PlexHub, items: [PlexItem]) -> some View {
        let imageWidth = Int(DuskPosterMetrics.carouselPosterWidth.rounded(.up))
        let imageHeight = Int((DuskPosterMetrics.carouselPosterWidth * 1.5).rounded(.up))
        let showsShowAll = viewModel.shouldShowAll(for: hub)

        MediaCarousel(
            title: viewModel.normalizedTitle(for: hub),
            headerAccessory: {
                if showsShowAll {
                    NavigationLink(value: AppNavigationRoute.hub(hub)) {
                        Text("Show all")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.duskAccent)
                    }
                    .buttonStyle(.plain)
                    .duskSuppressTVOSButtonChrome()
                }
            }
        ) {
            ForEach(items) { item in
                PosterNavigationCard(
                    route: AppNavigationRoute.destination(for: item),
                    imageURL: viewModel.posterURL(for: item, width: imageWidth, height: imageHeight),
                    title: item.title,
                    subtitle: viewModel.subtitle(for: item),
                    width: DuskPosterMetrics.carouselPosterWidth
                ) {
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
        }
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
            await playback.play(ratingKey: item.ratingKey)
        }
    }

    private func detailsLabel(for item: PlexItem) -> String {
        switch item.type {
        case .episode:
            "Go to Episode"
        case .movie:
            "Go to Movie"
        default:
            "View Details"
        }
    }
}

#if os(tvOS)
private struct TVBrowseLibraryButtonLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.subheadline.weight(.semibold))

            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(Color.duskTextPrimary)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.duskTextSecondary.opacity(0.16), lineWidth: 1)
        )
    }
}
#endif
