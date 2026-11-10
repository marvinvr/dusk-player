import SwiftUI

struct PosterNavigationCard<ContextMenuContent: View>: View {
    let route: AppNavigationRoute
    let imageURL: URL?
    /// Loaded when `imageURL` fails; see `PlexItem.fallbackPosterPath`.
    var fallbackImageURL: URL? = nil
    let title: String
    var subtitle: String?
    var progress: Double?
    var width: CGFloat = 130
    var imageAspectRatio: CGFloat = 2.0 / 3.0
    var showsPlayOverlay = false
    var availabilityBadge: String? = nil
    var isDimmed = false
    var isWatched = false
    /// See `PosterCardText.unwatchedCount`.
    var unwatchedCount: Int? = nil
    @ViewBuilder let contextMenuContent: () -> ContextMenuContent
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        #if os(tvOS)
        let artworkShape = RoundedRectangle(
            cornerRadius: PosterArtwork.cornerRadius,
            style: .continuous
        )

        VStack(alignment: .leading, spacing: DuskPosterMetrics.cardSpacing) {
            NavigationLink(value: route) {
                PosterArtwork(
                    imageURL: imageURL,
                    fallbackImageURL: fallbackImageURL,
                    progress: progress,
                    width: width,
                    imageAspectRatio: imageAspectRatio,
                    showsPlayOverlay: showsPlayOverlay,
                    availabilityBadge: availabilityBadge,
                    isDimmed: isDimmed
                )
                .contentShape(.contextMenuPreview, artworkShape)
            }
            .duskTVOSSystemPosterButton()
            .focused($isFocused)
            .carouselLeadingFocusTarget()
            .contextMenu {
                contextMenuContent()
            }

            PosterCardText(
                title: title,
                subtitle: subtitle,
                width: width,
                isWatched: isWatched,
                unwatchedCount: unwatchedCount
            )
        }
        .frame(width: width, alignment: .topLeading)
        .zIndex(isFocused ? 1 : 0)
        #else
        NavigationLink(value: route) {
            PosterCard(
                imageURL: imageURL,
                fallbackImageURL: fallbackImageURL,
                title: title,
                subtitle: subtitle,
                progress: progress,
                width: width,
                imageAspectRatio: imageAspectRatio,
                showsPlayOverlay: showsPlayOverlay,
                availabilityBadge: availabilityBadge,
                isDimmed: isDimmed,
                isWatched: isWatched,
                unwatchedCount: unwatchedCount
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .duskSuppressTVOSButtonChrome()
        .contentShape(
            .contextMenuPreview,
            PosterArtworkPreviewShape(width: width, imageAspectRatio: imageAspectRatio)
        )
        .contextMenu {
            contextMenuContent()
        }
        #endif
    }
}

extension PosterNavigationCard where ContextMenuContent == EmptyView {
    init(
        route: AppNavigationRoute,
        imageURL: URL?,
        title: String,
        subtitle: String? = nil,
        progress: Double? = nil,
        width: CGFloat = 130,
        imageAspectRatio: CGFloat = 2.0 / 3.0,
        showsPlayOverlay: Bool = false,
        availabilityBadge: String? = nil,
        isDimmed: Bool = false,
        isWatched: Bool = false
    ) {
        self.route = route
        self.imageURL = imageURL
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
        self.width = width
        self.imageAspectRatio = imageAspectRatio
        self.showsPlayOverlay = showsPlayOverlay
        self.availabilityBadge = availabilityBadge
        self.isDimmed = isDimmed
        self.isWatched = isWatched
        self.contextMenuContent = { EmptyView() }
    }
}

struct PosterActionCard<ContextMenuContent: View>: View {
    let action: () -> Void
    let imageURL: URL?
    let title: String
    var subtitle: String?
    var progress: Double?
    var width: CGFloat = 130
    var imageAspectRatio: CGFloat = 2.0 / 3.0
    var showsPlayOverlay = false
    var availabilityBadge: String? = nil
    var isDimmed = false
    var isUnwatchedEpisodeImage = false
    var isWatched = false
    @ViewBuilder let contextMenuContent: () -> ContextMenuContent
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        #if os(tvOS)
        let artworkShape = RoundedRectangle(
            cornerRadius: PosterArtwork.cornerRadius,
            style: .continuous
        )

        VStack(alignment: .leading, spacing: DuskPosterMetrics.cardSpacing) {
            Button(action: action) {
                PosterArtwork(
                    imageURL: imageURL,
                    progress: progress,
                    width: width,
                    imageAspectRatio: imageAspectRatio,
                    showsPlayOverlay: showsPlayOverlay,
                    availabilityBadge: availabilityBadge,
                    isDimmed: isDimmed,
                    isUnwatchedEpisodeImage: isUnwatchedEpisodeImage
                )
                .contentShape(.contextMenuPreview, artworkShape)
            }
            .duskTVOSSystemPosterButton()
            .focused($isFocused)
            .carouselLeadingFocusTarget()
            .contextMenu {
                contextMenuContent()
            }

            PosterCardText(
                title: title,
                subtitle: subtitle,
                width: width,
                isWatched: isWatched
            )
        }
        .frame(width: width, alignment: .topLeading)
        .zIndex(isFocused ? 1 : 0)
        #else
        Button(action: action) {
            PosterCard(
                imageURL: imageURL,
                title: title,
                subtitle: subtitle,
                progress: progress,
                width: width,
                imageAspectRatio: imageAspectRatio,
                showsPlayOverlay: showsPlayOverlay,
                availabilityBadge: availabilityBadge,
                isDimmed: isDimmed,
                isUnwatchedEpisodeImage: isUnwatchedEpisodeImage,
                isWatched: isWatched
            )
        }
        .buttonStyle(.plain)
        .duskSuppressTVOSButtonChrome()
        .contentShape(
            .contextMenuPreview,
            PosterArtworkPreviewShape(width: width, imageAspectRatio: imageAspectRatio)
        )
        .contextMenu {
            contextMenuContent()
        }
        #endif
    }
}

extension PosterActionCard where ContextMenuContent == EmptyView {
    init(
        action: @escaping () -> Void,
        imageURL: URL?,
        title: String,
        subtitle: String? = nil,
        progress: Double? = nil,
        width: CGFloat = 130,
        imageAspectRatio: CGFloat = 2.0 / 3.0,
        showsPlayOverlay: Bool = false,
        availabilityBadge: String? = nil,
        isDimmed: Bool = false
    ) {
        self.action = action
        self.imageURL = imageURL
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
        self.width = width
        self.imageAspectRatio = imageAspectRatio
        self.showsPlayOverlay = showsPlayOverlay
        self.availabilityBadge = availabilityBadge
        self.isDimmed = isDimmed
        self.contextMenuContent = { EmptyView() }
    }
}

/// The long-press lift of an iOS poster card: just the artwork, rounded like
/// it, as tvOS does. The card's full shape also lifts the title lines below
/// it as a loose cut-out over the dimmed screen.
struct PosterArtworkPreviewShape: Shape {
    let width: CGFloat
    let imageAspectRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        let artwork = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: min(width, rect.width),
            height: min(imageAspectRatio > 0 ? width / imageAspectRatio : width * 1.5, rect.height)
        )
        return RoundedRectangle(cornerRadius: PosterArtwork.cornerRadius, style: .continuous)
            .path(in: artwork)
    }
}
