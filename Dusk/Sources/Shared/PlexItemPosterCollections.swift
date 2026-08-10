import SwiftUI

/// Trailing shelf affordance that opens the carousel's full list.
///
/// Every platform renders it as a dashed card sized like the shelf's artwork and
/// placed after the last item, so the destination reads as part of the content
/// instead of a cramped button next to the section title.
struct ShowAllCarouselTile: View {
    let route: AppNavigationRoute
    let width: CGFloat
    var imageAspectRatio: CGFloat = 2.0 / 3.0

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        #if os(tvOS)
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

        NavigationLink(value: route) {
            label
                .foregroundStyle(isFocused ? Color.duskBackground : Color.duskTextPrimary)
                .background {
                    shape
                        .fill(isFocused ? Color.duskTextPrimary : Color.duskSurface)

                    shape
                        .strokeBorder(
                            isFocused
                                ? Color.duskTextPrimary
                                : Color.duskTextSecondary.opacity(0.5),
                            style: StrokeStyle(lineWidth: 2, dash: [10, 8])
                        )
                }
        }
        .duskSuppressTVOSButtonChrome()
        .focused($isFocused)
        .duskTVOSFocusEffectShape(shape, scales: false)
        .frame(width: width, alignment: .topLeading)
        .duskTVOSFocusedScale(isFocused)
        .zIndex(isFocused ? 1 : 0)
        .accessibilityLabel("Show all")
        #else
        let shape = RoundedRectangle(
            cornerRadius: PosterArtwork.cornerRadius,
            style: .continuous
        )

        NavigationLink(value: route) {
            label
                .foregroundStyle(Color.primary)
                .background {
                    shape
                        .fill(Color.duskSurface)

                    shape
                        .strokeBorder(
                            Color.duskTextSecondary.opacity(0.45),
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                        )
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .topLeading)
        .accessibilityLabel("Show all")
        #endif
    }

    private var label: some View {
        VStack(spacing: labelSpacing) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: iconSize, weight: .medium))

            Text("Show all")
                .font(labelFont)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(width: width, height: width / max(imageAspectRatio, 0.01))
    }

    private var isHorizontalArtwork: Bool {
        imageAspectRatio > 1
    }

    private var labelSpacing: CGFloat {
        #if os(tvOS)
        isHorizontalArtwork ? 12 : 18
        #else
        isHorizontalArtwork ? 6 : 10
        #endif
    }

    private var iconSize: CGFloat {
        #if os(tvOS)
        min(width * 0.16, 54)
        #else
        min(width * 0.18, 34)
        #endif
    }

    private var labelFont: Font {
        #if os(tvOS)
        .headline.weight(.semibold)
        #else
        .subheadline.weight(.semibold)
        #endif
    }
}

struct PlexItemPosterCarouselSection<ContextMenuContent: View>: View {
    let title: String
    let items: [PlexItem]
    var posterWidth: CGFloat = DuskPosterMetrics.carouselPosterWidth
    var imageAspectRatio: CGFloat = 2.0 / 3.0
    var horizontalPadding: CGFloat = DuskPosterMetrics.carouselHorizontalPadding
    var showAllRoute: AppNavigationRoute? = nil
    var subtitle: (PlexItem) -> String?
    var posterURL: (PlexItem, Int, Int) -> URL?
    var progress: (PlexItem) -> Double? = { _ in nil }
    @ViewBuilder let contextMenuContent: (PlexItem) -> ContextMenuContent

    var body: some View {
        let imageWidth = Int(posterWidth.rounded(.up))
        let imageHeight = Int((posterWidth / imageAspectRatio).rounded(.up))

        MediaCarousel(
            title: title,
            horizontalPadding: horizontalPadding
        ) {
            ForEach(items) { item in
                PosterNavigationCard(
                    route: AppNavigationRoute.destination(for: item),
                    imageURL: posterURL(item, imageWidth, imageHeight),
                    title: item.title,
                    subtitle: subtitle(item),
                    progress: progress(item),
                    width: posterWidth,
                    imageAspectRatio: imageAspectRatio
                ) {
                    contextMenuContent(item)
                }
            }

            if let showAllRoute {
                ShowAllCarouselTile(
                    route: showAllRoute,
                    width: posterWidth,
                    imageAspectRatio: imageAspectRatio
                )
            }
        }
    }
}

extension PlexItemPosterCarouselSection where ContextMenuContent == EmptyView {
    init(
        title: String,
        items: [PlexItem],
        posterWidth: CGFloat = DuskPosterMetrics.carouselPosterWidth,
        imageAspectRatio: CGFloat = 2.0 / 3.0,
        horizontalPadding: CGFloat = DuskPosterMetrics.carouselHorizontalPadding,
        showAllRoute: AppNavigationRoute? = nil,
        subtitle: @escaping (PlexItem) -> String?,
        posterURL: @escaping (PlexItem, Int, Int) -> URL?,
        progress: @escaping (PlexItem) -> Double? = { _ in nil }
    ) {
        self.title = title
        self.items = items
        self.posterWidth = posterWidth
        self.imageAspectRatio = imageAspectRatio
        self.horizontalPadding = horizontalPadding
        self.showAllRoute = showAllRoute
        self.subtitle = subtitle
        self.posterURL = posterURL
        self.progress = progress
        self.contextMenuContent = { _ in EmptyView() }
    }
}

struct PlexItemActionCarouselSection<ContextMenuContent: View>: View {
    let title: String
    let items: [PlexItem]
    let action: (PlexItem) -> Void
    var posterWidth: CGFloat
    var imageAspectRatio: CGFloat
    var horizontalPadding: CGFloat = DuskPosterMetrics.carouselHorizontalPadding
    var showAllRoute: AppNavigationRoute? = nil
    var subtitle: (PlexItem) -> String?
    var posterURL: (PlexItem, Int, Int) -> URL?
    var progress: (PlexItem) -> Double? = { _ in nil }
    @ViewBuilder let contextMenuContent: (PlexItem) -> ContextMenuContent

    var body: some View {
        let imageWidth = Int(posterWidth.rounded(.up))
        let imageHeight = Int((posterWidth / imageAspectRatio).rounded(.up))

        MediaCarousel(
            title: title,
            horizontalPadding: horizontalPadding
        ) {
            ForEach(items) { item in
                PosterActionCard(
                    action: { action(item) },
                    imageURL: posterURL(item, imageWidth, imageHeight),
                    title: item.continueWatchingDisplayTitle,
                    subtitle: subtitle(item),
                    progress: progress(item),
                    width: posterWidth,
                    imageAspectRatio: imageAspectRatio,
                    showsPlayOverlay: true
                ) {
                    contextMenuContent(item)
                }
            }

            if let showAllRoute {
                ShowAllCarouselTile(
                    route: showAllRoute,
                    width: posterWidth,
                    imageAspectRatio: imageAspectRatio
                )
            }
        }
    }
}

struct PlexItemPosterGrid<ContextMenuContent: View>: View {
    let items: [PlexItem]
    let layout: AdaptivePosterGridLayout
    var rowSpacing: CGFloat = DuskPosterMetrics.detailGridRowSpacing
    var imageAspectRatio: CGFloat = 2.0 / 3.0
    var posterURL: (PlexItem, Int, Int) -> URL?
    var subtitle: (PlexItem) -> String?
    var progress: (PlexItem) -> Double? = { _ in nil }
    var onItemAppear: (PlexItem) -> Void = { _ in }
    @ViewBuilder let contextMenuContent: (PlexItem) -> ContextMenuContent

    var body: some View {
        let imageWidth = Int(layout.posterWidth.rounded(.up))
        let imageHeight = Int((layout.posterWidth / imageAspectRatio).rounded(.up))

        LazyVGrid(columns: layout.columns, alignment: .leading, spacing: rowSpacing) {
            ForEach(items) { item in
                PosterNavigationCard(
                    route: AppNavigationRoute.destination(for: item),
                    imageURL: posterURL(item, imageWidth, imageHeight),
                    title: item.title,
                    subtitle: subtitle(item),
                    progress: progress(item),
                    width: layout.posterWidth,
                    imageAspectRatio: imageAspectRatio
                ) {
                    contextMenuContent(item)
                }
                .onAppear {
                    onItemAppear(item)
                }
            }
        }
    }
}

extension PlexItemPosterGrid where ContextMenuContent == EmptyView {
    init(
        items: [PlexItem],
        layout: AdaptivePosterGridLayout,
        rowSpacing: CGFloat = DuskPosterMetrics.detailGridRowSpacing,
        imageAspectRatio: CGFloat = 2.0 / 3.0,
        posterURL: @escaping (PlexItem, Int, Int) -> URL?,
        subtitle: @escaping (PlexItem) -> String?,
        progress: @escaping (PlexItem) -> Double? = { _ in nil },
        onItemAppear: @escaping (PlexItem) -> Void = { _ in }
    ) {
        self.items = items
        self.layout = layout
        self.rowSpacing = rowSpacing
        self.imageAspectRatio = imageAspectRatio
        self.posterURL = posterURL
        self.subtitle = subtitle
        self.progress = progress
        self.onItemAppear = onItemAppear
        self.contextMenuContent = { _ in EmptyView() }
    }
}
