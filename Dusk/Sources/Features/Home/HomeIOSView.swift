#if !os(tvOS)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct HomeIOSView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(AddToPlaylistPresenter.self) private var addToPlaylistPresenter: AddToPlaylistPresenter?
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
            #if !os(macOS)
            // Search is a sidebar destination (and ⌘F) on the Mac.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SearchToolbarLink()
                }
            }
            #endif
    }

    private var content: some View {
        GeometryReader { geometry in
            let heroItems = cinematicHeroItems
            // The artwork runs under side insets (iPhone landscape, iPhone
            // Duo's vertical bar) like the top one; the hero keeps its title,
            // buttons, and pager inside them.
            #if os(macOS)
            // The Mac hero fills the detail column only; its art reaches
            // under the floating sidebar through `backgroundExtensionEffect`
            // (HomeCinematicHero), not by widening the hero.
            let heroLeadingInset: CGFloat = 0
            let heroTrailingInset: CGFloat = 0
            #else
            let heroLeadingInset = geometry.safeAreaInsets.leading
            let heroTrailingInset = geometry.safeAreaInsets.trailing
            #endif
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
                            layout: heroLayout(width: heroWidth),
                            autoRotates: true,
                            supportsDragNavigation: true,
                            selectionResetRevision: heroSelectionResetRevision,
                            primaryAction: { item, callbacks in
                                AnyView(
                                    callbacks.withContextMenu(
                                        AnyView(
                                            heroPrimaryButton(for: item) {
                                                callbacks.restartRotation()
                                                play(item)
                                            }
                                        )
                                    )
                                    .frame(
                                        maxWidth: heroPrimaryButtonMaxWidth,
                                        alignment: .leading
                                    )
                                    .simultaneousGesture(
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { _ in callbacks.pauseRotation() }
                                    )
                                    .accessibilityAddTraits(.isButton)
                                )
                            },
                            detailsAction: { item in
                                path.append(AppNavigationRoute.destination(for: item))
                            },
                            contextMenuActions: { item in
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
                                .actions(playlistPresenter: addToPlaylistPresenter)
                            }
                        )
                        #if os(macOS)
                        .macContextMenu { item in
                            AnyView(
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
                            )
                        }
                        #endif
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

                        ForEach(viewModel.pinnedPlaylistRows) { row in
                            HomePinnedPlaylistShelf(row: row, viewModel: viewModel)
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
                .padding(.top, contentTopPadding(showsHero: !heroItems.isEmpty, safeAreaTop: geometry.safeAreaInsets.top))
                .padding(.bottom, 24)
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
            #if os(macOS)
            // The hero runs edge to edge under the transparent toolbar.
            .modifier(MacHomeHeroChrome(isEnabled: !heroItems.isEmpty))
            #endif
        }
        #if !os(macOS)
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: 88)
        }
        #endif
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

        #if os(macOS)
        if !items.isEmpty, items.allSatisfy({ $0.type == .episode }) {
            // Episodes as 16:9 stills, "S2 E3 · Title" over the show.
            PlexItemPosterCarouselSection(
                title: hub.title,
                items: items,
                posterWidth: DuskPosterMetrics.videoCarouselWidth,
                imageAspectRatio: 16.0 / 9.0,
                showAllRoute: viewModel.shouldShowAll(
                    for: hub,
                    maxRecentlyAddedItems: recentlyAddedInlineItemLimit
                ) ? AppNavigationRoute.hub(hub) : nil,
                subtitle: { $0.grandparentTitle?.nilIfEmpty },
                posterURL: { item, width, height in
                    viewModel.landscapeImageURL(for: item, width: width, height: height)
                },
                cardTitle: { $0.macEpisodeCardTitle },
                isUnwatchedEpisodeImage: { $0.landscapeImageIsUnwatchedEpisodeStill }
            ) { item in
                hubContextMenu(item, in: hub)
            }
        } else {
            posterHubSection(hub, items: items)
        }
        #else
        posterHubSection(hub, items: items)
        #endif
    }

    @ViewBuilder
    private func posterHubSection(_ hub: PlexHub, items: [PlexItem]) -> some View {
        if !items.isEmpty {
            let isVideoHub = viewModel.isVideoHub(hub)

            PlexItemPosterCarouselSection(
                title: hub.title,
                items: items,
                posterWidth: isVideoHub ? DuskPosterMetrics.videoCarouselWidth : DuskPosterMetrics.carouselPosterWidth,
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
            #if os(macOS)
            Divider()
            #endif
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
                posterWidth: DuskPosterMetrics.carouselPosterWidth,
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
        #if os(macOS)
        // The window title stays "Home"; over the hero the toolbar drops the
        // visible title (`macHeroUnderToolbar`).
        content
            .duskNavigationTitle("Home")
        #else
        if showsHero {
            content
                .duskNavigationTitle("")
                .duskNavigationBarTitleDisplayModeInline()
                #if !os(macOS)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbarBackground(.hidden, for: .navigationBar)
                #endif
        } else {
            content
                .duskNavigationTitle("Home")
                .duskNavigationBarTitleDisplayModeLarge()
                #if !os(macOS)
                .toolbarBackground(.visible, for: .navigationBar)
                #endif
        }
        #endif
    }

    /// iOS pulls the page up under the navigation bar so the hero starts at
    /// the top of the screen. On the Mac the scroll view itself ignores the
    /// top safe area (`macHeroUnderToolbar`), so the hero is already there.
    private func contentTopPadding(showsHero: Bool, safeAreaTop: CGFloat) -> CGFloat {
        #if os(macOS)
        showsHero ? 0 : 16
        #else
        showsHero ? -safeAreaTop : 16
        #endif
    }

    /// The hero's Play/Resume. The Mac uses the detail pages' primary
    /// button (white prominent capsule), so playback looks the same on every
    /// hero; iOS keeps Home's own style.
    @ViewBuilder
    private func heroPrimaryButton(for item: PlexItem, action: @escaping () -> Void) -> some View {
        #if os(macOS)
        Button(action: action) {
            DetailHeroPrimaryActionButtonLabel(
                title: viewModel.heroPrimaryActionTitle(for: item),
                systemImage: "play.fill"
            )
        }
        .detailHeroNativePrimaryButtonStyle()
        #else
        Button(action: action) {
            HomeHeroActionButtonLabel(
                title: viewModel.heroPrimaryActionTitle(for: item),
                systemImage: "play.fill",
                fillsWidth: heroPrimaryButtonFillsWidth
            )
        }
        .homeHeroNativeButtonStyle()
        #endif
    }

    private var heroPrimaryButtonFillsWidth: Bool {
        #if os(macOS)
        // A Mac button hugs its label.
        false
        #else
        true
        #endif
    }

    /// Regular-width iPad gets the near-full-screen hero; iPhone and compact
    /// iPad multitasking keep the shorter banner.
    private func heroLayout(width: CGFloat) -> HomeCinematicHeroLayout {
        #if os(macOS)
        return .mac(width: width)
        #else
        if UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular {
            return .iPad
        }
        var layout = HomeCinematicHeroLayout.ios
        // iPhone Duo: in landscape the cover display is shorter than the
        // banner's 520pt floor, which hid Play/Resume below the fold.
        layout.fitsContainerHeight = DuskDuoDisplay.isActive
        return layout
        #endif
    }

    private var heroPrimaryButtonMaxWidth: CGFloat {
        #if os(macOS)
        300
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? 300 : 240
        #endif
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
#if os(macOS)
/// Home's window chrome: with a hero the page runs under the transparent
/// toolbar; without one (Compact Continue Watching) it is an ordinary page.
private struct MacHomeHeroChrome: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.macHeroUnderToolbar()
        } else {
            content
        }
    }
}
#endif
#endif
