#if os(iOS)
import SwiftUI
import UIKit

struct HomeIOSView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var path: NavigationPath

    let viewModel: HomeViewModel
    /// Enabled servers that are currently unreachable. Only used for the quiet
    /// inline note; Home never names the server a row came from, because with
    /// every server merged into one screen that would be noise.
    let offlineServerNames: [String]
    let recentlyAddedInlineItemLimit: Int
    let heroSelectionResetRevision: Int
    let liveTVViewModel: LiveTVViewModel
    let showsLiveTV: Bool
    /// Settings › Home Advanced: the small Continue Watching row replaces
    /// the cinematic hero.
    let showsCompactContinueWatching: Bool
    let playLiveTV: (PlexLiveChannel, PlexLiveProgram, PlexLiveTVLineup) -> Void
    let play: (PlexItem) -> Void

    var body: some View {
        applyNavigationChrome(to: content, showsHero: showsCinematicHero)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SearchToolbarLink()
                }
            }
    }

    private var content: some View {
        GeometryReader { geometry in
            let heroItems = cinematicHeroItems
            // The artwork runs under side insets (iPhone landscape, iPhone
            // Duo's vertical bar) like the top one; the hero keeps its title,
            // buttons, and pager inside them.
            let heroLeadingInset = geometry.safeAreaInsets.leading
            let heroTrailingInset = geometry.safeAreaInsets.trailing
            let heroWidth = geometry.size.width + heroLeadingInset + heroTrailingInset

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !heroItems.isEmpty {
                        HomeCinematicHero(
                            items: heroItems,
                            viewModel: viewModel,
                            containerSize: CGSize(width: heroWidth, height: geometry.size.height),
                            topInset: geometry.safeAreaInsets.top,
                            contentLeadingInset: heroLeadingInset,
                            contentTrailingInset: heroTrailingInset,
                            layout: heroLayout,
                            autoRotates: true,
                            supportsDragNavigation: true,
                            selectionResetRevision: heroSelectionResetRevision,
                            primaryAction: { item, callbacks in
                                AnyView(
                                    Button {
                                        callbacks.restartRotation()
                                        play(item)
                                    } label: {
                                        HomeHeroActionButtonLabel(
                                            title: viewModel.heroPrimaryActionTitle(for: item),
                                            systemImage: "play.fill",
                                            fillsWidth: true
                                        )
                                    }
                                    .homeHeroNativeButtonStyle()
                                    .frame(
                                        maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? 300 : 240,
                                        alignment: .leading
                                    )
                                    .simultaneousGesture(
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { _ in callbacks.pauseRotation() }
                                    )
                                    .contextMenu {
                                        HomeItemContextMenu(
                                            item: item,
                                            detailsLabel: heroDetailsLabel(for: item),
                                            onMarkWatched: {
                                                Task { await viewModel.setWatched(true, for: item) }
                                            },
                                            onMarkUnwatched: {
                                                Task { await viewModel.setWatched(false, for: item) }
                                            },
                                            onSelectRoute: { route in
                                                path.append(route)
                                            },
                                            onRemoveFromContinueWatching: {
                                                Task { await viewModel.removeFromContinueWatching(item) }
                                            }
                                        )
                                    }
                                    .accessibilityAddTraits(.isButton)
                                )
                            },
                            detailsAction: { item in
                                path.append(AppNavigationRoute.destination(for: item))
                            }
                        )
                        .frame(width: heroWidth)
                        .offset(x: -heroLeadingInset)
                    }

                    LazyVStack(alignment: .leading, spacing: 18) {
                        ServerOutageNote(offlineServerNames: offlineServerNames)
                            .padding(.horizontal, 20)

                        if showsCompactContinueWatching {
                            HomeContinueWatchingShelf(
                                viewModel: viewModel,
                                detailsLabel: heroDetailsLabel(for:),
                                onSelectRoute: { path.append($0) },
                                play: play
                            )
                        }

                        if showsLiveTV {
                            LiveTVHomeShelf(viewModel: liveTVViewModel, play: playLiveTV)
                        }

                        let watchlistIndex = viewModel.watchlistIndex
                        ForEach(Array(viewModel.hubs.enumerated()), id: \.element.id) { index, hub in
                            if index == watchlistIndex {
                                watchlistShelf
                            }
                            hubSection(hub)
                        }

                        if let watchlistIndex, watchlistIndex >= viewModel.hubs.count {
                            watchlistShelf
                        }

                        ForEach(viewModel.personalizedShelves) { shelf in
                            personalizedSection(shelf)
                        }
                    }
                    .padding(.top, heroItems.isEmpty ? 0 : 24)
                }
                .padding(.top, heroItems.isEmpty ? 16 : -geometry.safeAreaInsets.top)
                .padding(.bottom, 24)
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: 88)
        }
        // Also keyed on the DVR: the first call often runs before any server
        // has connected, and the shelf has to load once discovery finds it.
        .task(id: LiveTVShelfLoadKey(isShown: showsLiveTV, providerID: liveTVViewModel.provider?.id)) {
            guard showsLiveTV else { return }
            await liveTVViewModel.loadNowPlaying(force: true)
        }
    }

    private var watchlistShelf: some View {
        HomeWatchlistShelf(viewModel: viewModel) { item, watched in
            Task { await viewModel.setWatched(watched, for: item) }
        }
    }

    @ViewBuilder
    private func hubSection(_ hub: PlexHub) -> some View {
        let items = viewModel.inlineItems(
            in: hub,
            maxRecentlyAddedItems: recentlyAddedInlineItemLimit
        )

        if !items.isEmpty {
            let isVideoHub = viewModel.isVideoHub(hub)

            PlexItemPosterCarouselSection(
                title: hub.title,
                items: items,
                posterWidth: isVideoHub ? DuskPosterMetrics.videoCarouselWidth : 130,
                imageAspectRatio: isVideoHub ? 16.0 / 9.0 : 2.0 / 3.0,
                showAllRoute: viewModel.shouldShowAll(
                    for: hub,
                    maxRecentlyAddedItems: recentlyAddedInlineItemLimit
                ) ? AppNavigationRoute.hub(hub) : nil,
                subtitle: { isVideoHub ? $0.standardPosterSubtitle : $0.hubPosterSubtitle },
                posterURL: { item, width, height in
                    viewModel.posterURL(for: item, width: width, height: height)
                }
            ) { item in
                hubContextMenu(item, in: hub)
            }
        }
    }

    @ViewBuilder
    private func hubContextMenu(_ item: PlexItem, in hub: PlexHub) -> some View {
        PlexItemContextMenuContent(
            item: item,
            onMarkWatched: {
                Task { await viewModel.setWatched(true, for: item) }
            },
            onMarkUnwatched: {
                Task { await viewModel.setWatched(false, for: item) }
            }
        )

        if viewModel.canHideRow(hub) {
            Button("Hide Row", systemImage: "minus.circle") {
                Task { await viewModel.hideRow(hub) }
            }
        }
    }

    @ViewBuilder
    private func personalizedSection(_ shelf: HomePersonalizedShelf) -> some View {
        if !shelf.items.isEmpty {
            PlexItemPosterCarouselSection(
                title: shelf.title,
                items: shelf.items,
                posterWidth: 130,
                showAllRoute: viewModel.showAllRoute(for: shelf),
                subtitle: { item in
                    viewModel.subtitle(for: item)
                },
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
    }

    @ViewBuilder
    private func applyNavigationChrome<Content: View>(to content: Content, showsHero: Bool) -> some View {
        if showsHero {
            content
                .duskNavigationTitle("")
                .duskNavigationBarTitleDisplayModeInline()
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content
                .duskNavigationTitle("Home")
                .duskNavigationBarTitleDisplayModeLarge()
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    /// Regular-width iPad gets the near-full-screen hero; iPhone and compact
    /// iPad multitasking keep the shorter banner.
    private var heroLayout: HomeCinematicHeroLayout {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
            ? .iPad
            : .ios
    }

    private var cinematicHeroItems: [PlexItem] {
        showsCompactContinueWatching ? [] : viewModel.heroItems()
    }

    private var showsCinematicHero: Bool {
        !cinematicHeroItems.isEmpty
    }

    private func heroDetailsLabel(for item: PlexItem) -> String {
        switch item.type {
        case .episode:
            return "Go to Episode"
        case .season:
            return "Go to Season"
        case .show:
            return "Go to Show"
        case .movie:
            return "Go to Movie"
        default:
            return "View Details"
        }
    }
}
#endif
