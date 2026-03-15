import SwiftUI

struct PosterArtwork: View {
    let imageURL: URL?
    var progress: Double?
    var width: CGFloat = 130
    var imageAspectRatio: CGFloat = 2.0 / 3.0
    var showsPlayOverlay: Bool = false

    private let playOverlaySymbolSize: CGFloat = 25
    private let playOverlayPadding: CGFloat = 14

    var body: some View {
        ZStack {
            DuskAsyncImage(url: imageURL) { phase in
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
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if showsPlayOverlay {
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

            if let progress, progress > 0 {
                GeometryReader { geo in
                    VStack {
                        Spacer()
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.white.opacity(0.3))
                                .frame(height: 3)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.duskAccent)
                                .frame(width: geo.size.width * min(progress, 1.0), height: 3)
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }
                .frame(width: width, height: imageHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.duskSurface)
            .frame(width: width, height: imageHeight)
            .overlay {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(Color.duskTextSecondary)
            }
    }

    private var imageHeight: CGFloat {
        guard imageAspectRatio > 0 else { return width * 1.5 }
        return width / imageAspectRatio
    }
}

struct PosterCardText: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = 130

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.duskTextPrimary)
                .lineLimit(2)
                .frame(width: width, alignment: .leading)

            subtitleRow
        }
    }

    @ViewBuilder
    private var subtitleRow: some View {
        if let subtitle, !subtitle.isEmpty {
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(Color.duskTextSecondary)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        } else {
            Text(" ")
                .font(.caption2)
                .hidden()
                .frame(width: width, alignment: .leading)
        }
    }
}

/// Reusable poster card with async image, title, and optional progress bar.
struct PosterCard: View {
    let imageURL: URL?
    let title: String
    var subtitle: String?
    /// 0...1 progress for partially watched items. Nil hides the bar.
    var progress: Double?
    var width: CGFloat = 130
    var imageAspectRatio: CGFloat = 2.0 / 3.0
    var showsPlayOverlay: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterArtwork(
                imageURL: imageURL,
                progress: progress,
                width: width,
                imageAspectRatio: imageAspectRatio,
                showsPlayOverlay: showsPlayOverlay
            )

            PosterCardText(
                title: title,
                subtitle: subtitle,
                width: width
            )
        }
        .frame(width: width, alignment: .topLeading)
    }
}

struct PlexItemContextMenuContent: View {
    let item: PlexItem
    var onMarkWatched: (() -> Void)?
    var onMarkUnwatched: (() -> Void)?
    var detailsRoute: AppNavigationRoute? = nil
    var detailsLabel: String = "View Details"

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
                Label("Go to Show", systemImage: "tv")
            }
        }
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

    var canMarkUnwatchedFromContextMenu: Bool {
        switch type {
        case .movie, .episode, .clip:
            return isWatched || isPartiallyWatched
        case .show, .season:
            if let viewedLeafCount {
                return viewedLeafCount > 0
            }
            return isWatched || isPartiallyWatched
        default:
            return false
        }
    }

    var contextMenuSeasonRoute: AppNavigationRoute? {
        guard type == .episode, let parentRatingKey else { return nil }
        return .media(type: .season, ratingKey: parentRatingKey)
    }

    var contextMenuShowRoute: AppNavigationRoute? {
        switch type {
        case .episode:
            guard let grandparentRatingKey else { return nil }
            return .media(type: .show, ratingKey: grandparentRatingKey)
        case .season:
            guard let parentRatingKey else { return nil }
            return .media(type: .show, ratingKey: parentRatingKey)
        default:
            return nil
        }
    }
}
