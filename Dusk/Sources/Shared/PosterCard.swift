import SwiftUI

struct PosterArtwork: View {
    static let cornerRadius: CGFloat = 16

    let imageURL: URL?
    var fallbackImageURL: URL? = nil
    var progress: Double?
    var width: CGFloat = 130
    var imageAspectRatio: CGFloat = 2.0 / 3.0
    var cornerRadius: CGFloat = Self.cornerRadius
    var showsPlayOverlay: Bool = false
    var availabilityBadge: String? = nil
    var isDimmed: Bool = false
    /// The image is an unwatched episode's own still; see `spoilerBlur`.
    var isUnwatchedEpisodeImage: Bool = false

    @Environment(\.blursUnwatchedEpisodes) private var blursUnwatchedEpisodes

    private var artworkShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        DuskAsyncImage(url: imageURL, fallbackURL: fallbackImageURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .failure:
                placeholder
            default:
                placeholder
            }
        }
        .frame(width: width, height: imageHeight)
        .spoilerBlur(isUnwatchedEpisodeImage)
        .overlay {
            if isDimmed {
                Color.black.opacity(0.42)
            }
        }
        .overlay {
            // A blurred still carries the spoiler glyph in the same spot.
            if showsPlayOverlay, !(blursUnwatchedEpisodes && isUnwatchedEpisodeImage) {
                Image(systemName: "play.fill")
                    .font(.system(size: playOverlaySymbolSize, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .padding(playOverlayPadding)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let availabilityBadge, !availabilityBadge.isEmpty {
                Text(availabilityBadge)
                    .font(DuskFont.badge(ios: .caption2.weight(.bold)))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .padding(.horizontal, availabilityBadgeHorizontalPadding)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .padding(8)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let progress, progress > 0 {
                progressBar(progress: progress)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        .clipShape(artworkShape)
    }

    private var isHorizontalArtwork: Bool {
        imageAspectRatio > 1
    }

    /// The badge text shrinks to `DuskFont.badge` on tvOS, so the pill needs
    /// relatively more horizontal padding there to stay a pill rather than a
    /// tight box around two words.
    private var availabilityBadgeHorizontalPadding: CGFloat {
        #if os(tvOS)
        9
        #else
        7
        #endif
    }

    private var playOverlaySymbolSize: CGFloat {
        #if os(tvOS)
        isHorizontalArtwork ? 34 : 28
        #else
        25
        #endif
    }

    private var playOverlayPadding: CGFloat {
        #if os(tvOS)
        isHorizontalArtwork ? 16 : 14
        #else
        14
        #endif
    }

    private var placeholder: some View {
        artworkShape
            .fill(Color.duskSurface)
            .overlay {
                Image(systemName: isHorizontalArtwork ? "play.rectangle" : "film")
                    .font(DuskFont.glyphLarge(ios: .title2))
                    .foregroundStyle(Color.duskTextSecondary)
            }
    }

    private var imageHeight: CGFloat {
        guard imageAspectRatio > 0 else { return width * 1.5 }
        return width / imageAspectRatio
    }

    /// Resume progress in the neutral TV-app look: white on a dark track.
    private func progressBar(progress: Double) -> some View {
        let clampedProgress = max(0, min(progress, 1.0))
        let height = DuskPosterMetrics.posterProgressBarHeight

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.black.opacity(0.42))
                .frame(height: height)
            GeometryReader { geo in
                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: geo.size.width * clampedProgress, height: height, alignment: .leading)
            }
        }
        .frame(height: height)
        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
    }
}

// MARK: - Spoiler blur

extension EnvironmentValues {
    /// Settings › Appearance › Blur Unwatched Episodes, set once at the app
    /// root so shared artwork views need no `UserPreferences`.
    @Entry var blursUnwatchedEpisodes = false
}

extension PlexItem {
    /// A TV episode the user hasn't finished. In-progress counts, as in Plex's
    /// own Unwatched filter: the rest of the episode is still ahead.
    var isUnwatchedEpisode: Bool {
        type == .episode && !isWatched
    }

    /// Whether `preferredLandscapePath` is the unwatched episode's own still
    /// rather than inherited show art.
    var landscapeImageIsUnwatchedEpisodeStill: Bool {
        isUnwatchedEpisode && thumb != nil && preferredLandscapePath == thumb
    }
}

extension View {
    /// Blurs an unwatched episode's own image (the frame Plex grabbed, or the
    /// agent's still) when Blur Unwatched Episodes is on, with an `eye.slash`
    /// glyph over the middle. Apply it to the image's final frame, before any
    /// badges or progress bars, so only the artwork blurs. The radius follows
    /// the frame's short side, so a small card and a full hero end up equally
    /// unreadable.
    func spoilerBlur(_ isUnwatchedEpisodeImage: Bool, showsGlyph: Bool = true) -> some View {
        modifier(SpoilerBlurModifier(isUnwatchedEpisodeImage: isUnwatchedEpisodeImage, showsGlyph: showsGlyph))
    }
}

private struct SpoilerBlurModifier: ViewModifier {
    @Environment(\.blursUnwatchedEpisodes) private var blursUnwatchedEpisodes

    let isUnwatchedEpisodeImage: Bool
    let showsGlyph: Bool

    @State private var shortSide: CGFloat = 0

    func body(content: Content) -> some View {
        let isActive = blursUnwatchedEpisodes && isUnwatchedEpisodeImage

        // Radius 0 rather than a branch, so toggling never rebuilds the image
        // view and makes it reload.
        content
            .blur(radius: isActive ? blurRadius : 0, opaque: true)
            .overlay {
                if isActive, showsGlyph {
                    Image(systemName: "eye.slash")
                        .font(.system(size: glyphSize, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                        .accessibilityHidden(true)
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                min(proxy.size.width, proxy.size.height)
            } action: { newValue in
                shortSide = newValue
            }
    }

    private var blurRadius: CGFloat {
        min(max(shortSide * 0.12, 8), 64)
    }

    private var glyphSize: CGFloat {
        min(max(shortSide * 0.24, 16), 48)
    }
}

struct PosterCardText: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = 130
    /// Adds a small checkmark to the subtitle line (a watched episode, a fully
    /// watched season). Deliberately quiet: same colour and size as the
    /// subtitle, so a fully watched row doesn't turn into a wall of badges.
    var isWatched: Bool = false
    /// Episodes left in a partially watched season, drawn in the checkmark's
    /// slot and at its size (`UnwatchedCountBadge`). Nil shows nothing.
    var unwatchedCount: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DuskPosterMetrics.cardTextSpacing) {
            titleRow

            subtitleRow
        }
    }

    @ViewBuilder
    private var titleRow: some View {
        Text(title)
            .font(DuskPosterMetrics.titleFont)
            .foregroundStyle(Color.primary)
            .lineLimit(2)
            .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private var subtitleRow: some View {
        let subtitle = subtitle?.nilIfEmpty
        if subtitle != nil || isWatched || unwatchedCount != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let subtitle {
                    Text(subtitle)
                        .lineLimit(1)
                }

                if isWatched {
                    Image(systemName: "checkmark")
                        .imageScale(.small)
                        .fontWeight(.semibold)
                        .accessibilityLabel("Watched")
                } else if let unwatchedCount {
                    UnwatchedCountBadge(count: unwatchedCount)
                        .fontWeight(.semibold)
                }
            }
            .font(DuskPosterMetrics.subtitleFont)
            .foregroundStyle(Color.primary.opacity(0.68))
            .frame(width: width, alignment: .leading)
        } else {
            Text(" ")
                .font(DuskPosterMetrics.subtitleFont)
                .hidden()
                .frame(width: width, alignment: .leading)
        }
    }
}

/// Reusable poster card with async image, title, and optional progress bar.
struct PosterCard: View {
    let imageURL: URL?
    var fallbackImageURL: URL? = nil
    let title: String
    var subtitle: String?
    /// 0...1 progress for partially watched items. Nil hides the bar.
    var progress: Double?
    var width: CGFloat = 130
    var imageAspectRatio: CGFloat = 2.0 / 3.0
    var showsPlayOverlay: Bool = false
    var availabilityBadge: String? = nil
    var isDimmed: Bool = false
    var isUnwatchedEpisodeImage: Bool = false
    var isWatched: Bool = false
    var unwatchedCount: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterArtwork(
                imageURL: imageURL,
                fallbackImageURL: fallbackImageURL,
                progress: progress,
                width: width,
                imageAspectRatio: imageAspectRatio,
                showsPlayOverlay: showsPlayOverlay,
                availabilityBadge: availabilityBadge,
                isDimmed: isDimmed,
                isUnwatchedEpisodeImage: isUnwatchedEpisodeImage
            )

            PosterCardText(
                title: title,
                subtitle: subtitle,
                width: width,
                isWatched: isWatched,
                unwatchedCount: unwatchedCount
            )
        }
        .frame(width: width, alignment: .topLeading)
    }
}

/// The unwatched-episode count of a partially watched season: the system's
/// numbered circle symbol, so it takes the watched checkmark's font and colour
/// from the caller and sits in exactly the same slot. Callers leave out the
/// checkmark's `.imageScale(.small)`: a filled circle at that scale reads
/// smaller than the open checkmark stroke and its digit gets illegible. The
/// symbols stop at 50; longer seasons get the number in a matching capsule.
struct UnwatchedCountBadge: View {
    let count: Int

    var body: some View {
        Group {
            if (0...50).contains(count) {
                Image(systemName: "\(count).circle.fill")
            } else {
                Text(verbatim: "\(count)")
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(Color.primary.opacity(0.2)))
            }
        }
        .accessibilityLabel(count == 1 ? "1 unwatched episode" : "\(count) unwatched episodes")
    }
}

struct PlexItemContextMenuContent: View {
    let item: PlexItem
    var onMarkWatched: (() -> Void)?
    var onMarkUnwatched: (() -> Void)?
    var detailsRoute: AppNavigationRoute? = nil
    var detailsLabel: String = "View Details"
    /// Off where the item already is in a playlist (the playlist page).
    var showsAddToPlaylist = true

    var body: some View {
        if item.canMarkWatchedFromContextMenu, let onMarkWatched {
            Button(action: onMarkWatched) {
                Label("Mark Watched", systemImage: "eye")
            }
        }

        if item.canMarkUnwatchedFromContextMenu, let onMarkUnwatched {
            Button(action: onMarkUnwatched) {
                Label("Mark Unwatched", systemImage: "eye.slash")
            }
        }

        if let detailsRoute {
            NavigationLink(value: detailsRoute) {
                Label(detailsLabel, systemImage: "info.circle")
            }
        }

        if let seasonRoute = item.contextMenuSeasonRoute {
            NavigationLink(value: seasonRoute) {
                Label("Go to Season", systemImage: "rectangle.stack")
            }
        }

        if let showRoute = item.contextMenuShowRoute {
            NavigationLink(value: showRoute) {
                Label("Go to Show", systemImage: "tv.fill")
            }
        }

        if showsAddToPlaylist {
            AddToPlaylistMenuButton(target: AddToPlaylistTarget(item: item))
        }

        WatchlistMenuButton(item: item)
    }
}

extension PlexItem {
    var canMarkWatchedFromContextMenu: Bool {
        switch type {
        case .movie, .episode, .clip:
            return !isWatched
        case .show, .season:
            if let leafCount, leafCount > 0, let viewedLeafCount {
                return viewedLeafCount < leafCount
            }
            return !isWatched
        default:
            return false
        }
    }

    /// Continue Watching still lists a title the user has finished before once
    /// they start it again. `viewCount` then hides Mark Watched on poster
    /// menus, but this row is the in-progress copy, and marking it watched is
    /// the scrobble that takes it off the row.
    var canMarkWatchedFromContinueWatchingMenu: Bool {
        if canMarkWatchedFromContextMenu { return true }
        switch type {
        case .movie, .episode, .clip:
            return isPartiallyWatched
        default:
            return false
        }
    }

    var canMarkUnwatchedFromContextMenu: Bool {
        switch type {
        case .movie, .episode, .clip:
            return isWatched || isPartiallyWatched
        case .show:
            if let viewedLeafCount {
                return viewedLeafCount > 0
            }
            return isWatched || isPartiallyWatched
        case .season:
            if let viewedLeafCount, viewedLeafCount > 0 {
                return true
            }
            return isWatched || isPartiallyWatched || canMarkWatchedFromContextMenu
        default:
            return false
        }
    }

    /// A relative of this item — its season or its show — always lives on the
    /// same server, so the route inherits this item's `serverID`.
    private func relativeID(_ ratingKey: String) -> PlexItemID {
        PlexItemID(serverID: serverID, ratingKey: ratingKey)
    }

    // tvOS has one page per show that every episode/season/show route opens, so
    // the item's own details entry already lands there; separate season and show
    // entries would just open the same page again.
    var contextMenuSeasonRoute: AppNavigationRoute? {
        #if os(tvOS)
        return nil
        #else
        guard type == .episode, let parentRatingKey else { return nil }
        return .media(type: .season, id: relativeID(parentRatingKey))
        #endif
    }

    var contextMenuShowRoute: AppNavigationRoute? {
        #if os(tvOS)
        return nil
        #else
        switch type {
        case .episode:
            guard let grandparentRatingKey else { return nil }
            return .media(type: .show, id: relativeID(grandparentRatingKey))
        case .season:
            guard let parentRatingKey else { return nil }
            return .media(type: .show, id: relativeID(parentRatingKey))
        default:
            return nil
        }
        #endif
    }
}
