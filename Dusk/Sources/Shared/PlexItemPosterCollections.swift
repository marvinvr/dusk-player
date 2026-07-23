import SwiftUI

struct ShowAllCarouselLink: View {
    let route: AppNavigationRoute
    var title = "Show all"

    var body: some View {
        NavigationLink(value: route) {
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .controlSize(.small)
        .buttonBorderShape(.capsule)
        .showAllCarouselButtonStyle()
    }
}

#if os(tvOS)
private struct ShowAllCarouselTile: View {
    let route: AppNavigationRoute
    let width: CGFloat
    let imageAspectRatio: CGFloat

    @FocusState private var isFocused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        let height = width / imageAspectRatio

        NavigationLink(value: route) {
            VStack(spacing: imageAspectRatio > 1 ? 12 : 18) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: min(width * 0.16, 54), weight: .medium))

                Text("Show all")
                    .font(.headline.weight(.semibold))
            }
            .foregroundStyle(isFocused ? Color.duskBackground : Color.duskTextPrimary)
            .frame(width: width, height: height)
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
    }
}
#endif

private extension View {
    @ViewBuilder
    func showAllCarouselButtonStyle() -> some View {
        #if os(tvOS)
        self
            .buttonStyle(.glass)
            .tint(Color.primary)
        #else
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .tint(Color.primary)
        } else {
            self
                .buttonStyle(.bordered)
                .tint(Color.primary)
        }
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
            horizontalPadding: horizontalPadding,
            headerAccessory: {
                #if !os(tvOS)
                if let showAllRoute {
                    ShowAllCarouselLink(route: showAllRoute)
                }
                #endif
            }
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

            #if os(tvOS)
            if let showAllRoute {
                ShowAllCarouselTile(
                    route: showAllRoute,
                    width: posterWidth,
                    imageAspectRatio: imageAspectRatio
                )
            }
            #endif
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
            horizontalPadding: horizontalPadding,
            headerAccessory: {
                #if !os(tvOS)
                if let showAllRoute {
                    ShowAllCarouselLink(route: showAllRoute)
                }
                #endif
            }
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

            #if os(tvOS)
            if let showAllRoute {
                ShowAllCarouselTile(
                    route: showAllRoute,
                    width: posterWidth,
                    imageAspectRatio: imageAspectRatio
                )
            }
            #endif
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
