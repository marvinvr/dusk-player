#if os(iOS)
import SwiftUI
import UIKit

struct HomeIOSView: View {
    @Binding var path: NavigationPath

    let viewModel: HomeViewModel
    let serverName: String?
    let recentlyAddedInlineItemLimit: Int
    let heroSelectionResetRevision: Int
    let liveTVViewModel: LiveTVViewModel
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
            let heroItems = viewModel.heroItems()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !heroItems.isEmpty {
                        HomeCinematicHero(
                            items: heroItems,
                            viewModel: viewModel,
                            containerSize: geometry.size,
                            topInset: geometry.safeAreaInsets.top,
                            layout: .ios,
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
                    } else if showsHomeServerSubtitle, let serverName {
                        homeSubtitle(serverName)
                            .padding(.bottom, 12)
                    }

                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(viewModel.arrangedRows) { row in
                            switch row {
                            case .liveTV:
                                LiveTVHomeShelf(viewModel: liveTVViewModel, play: playLiveTV)
                            case .hub(let hub):
                                hubSection(hub)
                            case .suggestions(let shelves):
                                ForEach(shelves) { shelf in
                                    personalizedSection(shelf)
                                }
                            }
                        }

                        if heroItems.isEmpty, showsEmptyLayoutState {
                            emptyLayoutState
                                .frame(maxWidth: .infinity)
                                .padding(.top, 60)
                        }
                    }
                    .padding(.top, heroItems.isEmpty ? 0 : 24)
                }
                .padding(.top, heroItems.isEmpty ? (showsHomeServerSubtitle ? -10 : 16) : -geometry.safeAreaInsets.top)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: 88)
        }
        .task {
            await liveTVViewModel.loadNowPlaying(force: true)
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
                subtitle: { isVideoHub ? $0.standardPosterSubtitle : $0.year.map(String.init) },
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

    /// Distinguishes "the user turned every row off" from an empty server,
    /// which `HomeView` already covers with its own loading and error states.
    /// The Live TV row does not count: it renders nothing on its own.
    private var showsEmptyLayoutState: Bool {
        guard !viewModel.isLoading, viewModel.hasLoadedContent else { return false }

        return !viewModel.arrangedRows.contains { row in
            switch row {
            case .liveTV:
                false
            case .hub, .suggestions:
                true
            }
        }
    }

    private var emptyLayoutState: some View {
        FeatureEmptyStateView(
            systemImage: "rectangle.stack",
            title: "Nothing on Home",
            message: "Every row is turned off. Turn some back on in Settings › Home Screen."
        )
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

    private func homeSubtitle(_ serverName: String) -> some View {
        Text(serverName)
            .font(.subheadline)
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 20)
    }

    private var showsHomeServerSubtitle: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    private var showsCinematicHero: Bool {
        !viewModel.heroItems().isEmpty
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
