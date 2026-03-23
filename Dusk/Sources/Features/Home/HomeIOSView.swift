#if os(iOS)
import SwiftUI
import UIKit

struct HomeIOSView: View {
    @Binding var path: NavigationPath

    let viewModel: HomeViewModel
    let serverName: String?
    let recentlyAddedInlineItemLimit: Int
    let play: (PlexItem) -> Void

    var body: some View {
        applyNavigationChrome(to: content, showsHero: showsCinematicHero)
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
                            primaryAction: { item, callbacks in
                                AnyView(
                                    Button {
                                        callbacks.restartRotation()
                                        play(item)
                                    } label: {
                                        HomeHeroActionButtonLabel(
                                            title: viewModel.heroPrimaryActionTitle(for: item),
                                            systemImage: "play.fill"
                                        )
                                    }
                                    .buttonStyle(HeroPauseAwareButtonStyle(onPress: callbacks.pauseRotation))
                                    .duskSuppressTVOSButtonChrome()
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
                        ForEach(viewModel.hubs) { hub in
                            let items = viewModel.inlineItems(
                                in: hub,
                                maxRecentlyAddedItems: recentlyAddedInlineItemLimit
                            )

                            if !items.isEmpty {
                                HomeHubCarouselSection(
                                    hub: hub,
                                    items: items,
                                    posterWidth: 130,
                                    showsShowAll: viewModel.shouldShowAll(
                                        for: hub,
                                        maxRecentlyAddedItems: recentlyAddedInlineItemLimit
                                    ),
                                    subtitle: { $0.year.map(String.init) },
                                    posterURL: { item, width, height in
                                        viewModel.posterURL(for: item, width: width, height: height)
                                    },
                                    onMarkWatched: { item in
                                        Task { await viewModel.setWatched(true, for: item) }
                                    },
                                    onMarkUnwatched: { item in
                                        Task { await viewModel.setWatched(false, for: item) }
                                    }
                                )
                            }
                        }

                        ForEach(viewModel.personalizedShelves) { shelf in
                            if !shelf.items.isEmpty {
                                HomePersonalizedCarouselSection(
                                    shelf: shelf,
                                    posterWidth: 130,
                                    showAllRoute: viewModel.showAllRoute(for: shelf),
                                    subtitle: { item in
                                        viewModel.subtitle(for: item)
                                    },
                                    posterURL: { item, width, height in
                                        viewModel.posterURL(for: item, width: width, height: height)
                                    },
                                    onMarkWatched: { item in
                                        Task { await viewModel.setWatched(true, for: item) }
                                    },
                                    onMarkUnwatched: { item in
                                        Task { await viewModel.setWatched(false, for: item) }
                                    }
                                )
                            }
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
            .foregroundStyle(Color.duskTextSecondary)
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
