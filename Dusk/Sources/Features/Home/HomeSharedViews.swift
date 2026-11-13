import SwiftUI

/// One long-press menu entry, so the same list renders as SwiftUI buttons
/// (`HomeItemMenuButtons`) or as a UIKit `UIMenu` (the iOS hero button).
struct HomeItemMenuAction: Identifiable {
    let title: String
    let systemImage: String
    let perform: () -> Void

    var id: String { title }
}

struct HomeItemContextMenu: View {
    @Environment(AddToPlaylistPresenter.self) private var playlistPresenter: AddToPlaylistPresenter?

    let item: PlexItem
    let detailsLabel: String
    let onMarkWatched: () -> Void
    let onMarkUnwatched: () -> Void
    let onSelectRoute: (AppNavigationRoute) -> Void
    var onRemoveFromContinueWatching: (() -> Void)?

    var body: some View {
        HomeItemMenuButtons(actions: actions(playlistPresenter: playlistPresenter))
    }

    func actions(playlistPresenter: AddToPlaylistPresenter?) -> [HomeItemMenuAction] {
        var actions: [HomeItemMenuAction] = []

        if item.canMarkWatchedFromContinueWatchingMenu {
            actions.append(HomeItemMenuAction(title: "Mark Watched", systemImage: "eye", perform: onMarkWatched))
        }

        if item.canMarkUnwatchedFromContextMenu {
            actions.append(HomeItemMenuAction(title: "Mark Unwatched", systemImage: "eye.slash", perform: onMarkUnwatched))
        }

        if let onRemoveFromContinueWatching {
            actions.append(
                HomeItemMenuAction(
                    title: "Remove from Continue Watching",
                    systemImage: "minus.circle",
                    perform: onRemoveFromContinueWatching
                )
            )
        }

        let item = item
        let onSelectRoute = onSelectRoute
        actions.append(
            HomeItemMenuAction(title: detailsLabel, systemImage: "info.circle") {
                onSelectRoute(AppNavigationRoute.destination(for: item))
            }
        )

        if let seasonRoute = item.contextMenuSeasonRoute {
            actions.append(HomeItemMenuAction(title: "Go to Season", systemImage: "rectangle.stack") {
                onSelectRoute(seasonRoute)
            })
        }

        if let showRoute = item.contextMenuShowRoute {
            actions.append(HomeItemMenuAction(title: "Go to Show", systemImage: "tv.fill") {
                onSelectRoute(showRoute)
            })
        }

        // Same rule as `AddToPlaylistMenuButton`: only inside the tab shell,
        // and only for content that can go in a playlist.
        if let playlistPresenter, let target = AddToPlaylistTarget(item: item) {
            actions.append(HomeItemMenuAction(title: "Add to Playlist…", systemImage: "text.badge.plus") {
                playlistPresenter.present(target)
            })
        }

        return actions
    }
}

struct HomeItemMenuButtons: View {
    let actions: [HomeItemMenuAction]

    var body: some View {
        ForEach(actions) { action in
            Button(action.title, systemImage: action.systemImage, action: action.perform)
        }
    }
}

struct HomeHeroActionButtonLabel: View {
    let title: String
    let systemImage: String
    var fillsWidth: Bool = false

    #if os(tvOS)
    private let minimumButtonWidth: CGFloat = 280
    #endif

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(heroButtonFont)

            Text(title)
                .font(heroButtonFont)
                .lineLimit(1)
        }
        .frame(minHeight: heroButtonMinHeight)
        #if os(tvOS)
        .frame(minWidth: minimumButtonWidth)
        .contentShape(Capsule())
        #else
        .frame(maxWidth: fillsWidth ? .infinity : nil)
        .contentShape(Capsule())
        #endif
        .foregroundStyle(labelColor)
    }

    // iOS draws the home hero button as prominent, `Color.primary`-tinted glass,
    // so its label uses the inverse color for contrast. tvOS keeps translucent
    // glass where the standard `primary` label already reads correctly.
    private var labelColor: Color {
        #if os(tvOS)
        .primary
        #else
        .duskPrimaryActionLabel
        #endif
    }

    private var heroButtonFont: Font {
        #if os(tvOS)
        DuskFont.TV.buttonLabel
        #else
        .headline.weight(.semibold)
        #endif
    }

    private var heroButtonMinHeight: CGFloat {
        #if os(tvOS)
        28
        #else
        32
        #endif
    }
}

struct HomeHeroSecondaryActionButtonLabel: View {
    let title: String

    #if os(tvOS)
    private let minimumButtonWidth: CGFloat = 280
    #endif

    var body: some View {
        Text(title)
            .font(heroButtonFont)
            #if os(tvOS)
            .frame(minWidth: minimumButtonWidth)
            .contentShape(Capsule())
            #endif
            .foregroundStyle(Color.primary)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
    }

    private var heroButtonFont: Font {
        #if os(tvOS)
        DuskFont.TV.buttonLabel
        #else
        .headline.weight(.semibold)
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        18
        #else
        20
        #endif
    }

    private var verticalPadding: CGFloat {
        #if os(tvOS)
        12
        #else
        14
        #endif
    }
}

/// The pager pills on screen when the hero has more items than
/// `maxVisible`, in the manner of `UIPageControl`: a fixed number of slots that
/// slides to keep the current item centred, with the outermost pills shrunk on
/// a side where more items lie beyond. The pager's width is therefore bounded
/// however long Continue Watching grows.
struct HomeHeroPagerWindow {
    let range: Range<Int>
    private let count: Int

    init(count: Int, currentIndex: Int, maxVisible: Int) {
        let visible = min(max(count, 0), max(maxVisible, 1))
        let start = min(max(currentIndex - visible / 2, 0), max(count, 0) - visible)
        range = start ..< start + visible
        self.count = count
    }

    func scale(for index: Int) -> CGFloat {
        let fromLeadingEdge = range.lowerBound > 0 ? index - range.lowerBound : .max
        let fromTrailingEdge = range.upperBound < count ? range.upperBound - 1 - index : .max

        switch min(fromLeadingEdge, fromTrailingEdge) {
        case 0: return 0.5
        case 1: return 0.75
        default: return 1
        }
    }
}

struct HomeHeroPagerPill: View {
    let isActive: Bool
    let progress: Double

    var body: some View {
        let pillWidth: CGFloat = isActive ? 28 : 10
        let pillHeight: CGFloat = 10
        let fillInset: CGFloat = 1
        let clampedProgress = min(max(progress, 0), 1)

        ZStack(alignment: .leading) {
            Capsule()
                .fill(isActive ? Color.primary.opacity(0.24) : Color.primary.opacity(0.28))

            if isActive {
                Capsule()
                    .fill(Color.primary)
                    .frame(
                        width: max((pillWidth - (fillInset * 2)) * clampedProgress, 0),
                        height: pillHeight - (fillInset * 2)
                    )
                    .padding(fillInset)
                    .clipShape(Capsule())
            }
        }
        .frame(width: pillWidth, height: pillHeight)
        .clipShape(Capsule())
        .overlay {
            if isActive {
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            }
        }
    }
}

extension View {
    @ViewBuilder
    func homeHeroNativeButtonStyle() -> some View {
        #if os(tvOS)
        // No tint: the tab shell clears it for its content, and an explicit
        // one (even `Color.primary`) turns the focused glass white-on-white.
        self
            .buttonStyle(.glass)
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
        #elseif os(iOS)
        // Prominent glass tinted with a translucent `primary` so the hero CTA
        // contrasts the artwork (dark in Light mode, light in Dark) while still
        // reading as liquid glass. `.regular` height keeps it a short, wide pill.
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glassProminent)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
                .tint(Color.duskPrimaryButtonTint)
        } else {
            self
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
                .tint(Color.primary)
        }
        #elseif os(macOS)
        // The iOS look; `.large` is the Mac's short, wide pill.
        self
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .tint(Color.duskPrimaryButtonTint)
        #else
        self
        #endif
    }
}

/// The small Continue Watching row Home opens with in place of the cinematic
/// hero when Settings › Home Advanced › Compact Continue Watching is on. The
/// same row the library pages use; the menu matches the hero's.
struct HomeContinueWatchingShelf: View {
    let viewModel: HomeViewModel
    let detailsLabel: (PlexItem) -> String
    let onSelectRoute: (AppNavigationRoute) -> Void
    let play: (PlexItem) -> Void

    var body: some View {
        if !viewModel.continueWatching.isEmpty {
            PlexItemActionCarouselSection(
                title: "Continue Watching",
                items: viewModel.continueWatching,
                action: play,
                posterWidth: DuskPosterMetrics.continueWatchingWidth,
                imageAspectRatio: 16.0 / 9.0,
                subtitle: { viewModel.displaySubtitle(for: $0) },
                posterURL: { item, width, height in
                    viewModel.landscapeImageURL(for: item, width: width, height: height)
                },
                progress: { viewModel.progress(for: $0) },
                isUnwatchedEpisodeImage: { $0.landscapeImageIsUnwatchedEpisodeStill }
            ) { item in
                HomeItemContextMenu(
                    item: item,
                    detailsLabel: detailsLabel(item),
                    onMarkWatched: {
                        Task { await viewModel.setWatched(true, for: item) }
                    },
                    onMarkUnwatched: {
                        Task { await viewModel.setWatched(false, for: item) }
                    },
                    onSelectRoute: onSelectRoute,
                    onRemoveFromContinueWatching: {
                        Task { await viewModel.removeFromContinueWatching(item) }
                    }
                )
            }
        }
    }
}
