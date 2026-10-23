import SwiftUI
#if os(tvOS)
import UIKit
#endif

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
        .carouselLeadingFocusTarget()
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
        isHorizontalArtwork ? 10 : 14
        #else
        isHorizontalArtwork ? 6 : 10
        #endif
    }

    private var iconSize: CGFloat {
        #if os(tvOS)
        min(width * 0.16, 44)
        #else
        min(width * 0.18, 34)
        #endif
    }

    private var labelFont: Font {
        #if os(tvOS)
        DuskFont.TV.buttonLabel
        #else
        .subheadline.weight(.semibold)
        #endif
    }
}

struct PlexItemPosterCarouselSection<ContextMenuContent: View>: View {
    @Environment(PlexService.self) private var plexService

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
                    fallbackImageURL: item.fallbackPosterImageURL(
                        plexService: plexService,
                        width: imageWidth,
                        height: imageHeight
                    ),
                    title: item.posterCardTitle,
                    subtitle: subtitle(item),
                    progress: progress(item),
                    width: posterWidth,
                    imageAspectRatio: imageAspectRatio
                ) {
                    contextMenuContent(item)
                }
                .carouselItemFocusLock(isLeadingItem: item.id == items.first?.id)
            }

            if let showAllRoute {
                ShowAllCarouselTile(
                    route: showAllRoute,
                    width: posterWidth,
                    imageAspectRatio: imageAspectRatio
                )
                .carouselItemFocusLock(isLeadingItem: items.isEmpty)
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
                .carouselItemFocusLock(isLeadingItem: item.id == items.first?.id)
            }

            if let showAllRoute {
                ShowAllCarouselTile(
                    route: showAllRoute,
                    width: posterWidth,
                    imageAspectRatio: imageAspectRatio
                )
                .carouselItemFocusLock(isLeadingItem: items.isEmpty)
            }
        }
    }
}

struct PlexItemPosterGrid<ContextMenuContent: View>: View {
    @Environment(PlexService.self) private var plexService

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

        #if os(tvOS)
        // One focus section per row, matching a native tvOS grid. Down from a
        // column the next row does not fill enters that section and lands on
        // its nearest poster. The empty columns are a focus guide so the
        // section actually extends under them (issue #24).
        LazyVStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(tvRows) { row in
                tvRow(row, imageWidth: imageWidth, imageHeight: imageHeight)
            }
        }
        #else
        LazyVGrid(columns: layout.columns, alignment: .leading, spacing: rowSpacing) {
            ForEach(items) { item in
                card(for: item, imageWidth: imageWidth, imageHeight: imageHeight)
            }
        }
        #endif
    }

    #if os(tvOS)
    private var columnCount: Int {
        max(layout.columns.count, 1)
    }

    private var columnSpacing: CGFloat {
        layout.columns.first?.spacing ?? DuskPosterMetrics.gridSpacing
    }

    private var tvRows: [TVPosterRow] {
        let count = columnCount
        var rows: [TVPosterRow] = []
        var index = items.startIndex
        while index < items.endIndex {
            let end = items.index(index, offsetBy: count, limitedBy: items.endIndex) ?? items.endIndex
            let slice = Array(items[index..<end])
            if let first = slice.first {
                rows.append(TVPosterRow(id: first.id, items: slice))
            }
            index = end
        }
        return rows
    }

    private func tvRow(_ row: TVPosterRow, imageWidth: Int, imageHeight: Int) -> some View {
        let missing = columnCount - row.items.count
        let artworkHeight = layout.posterWidth / max(imageAspectRatio, 0.01)
        let guideWidth = CGFloat(missing) * layout.posterWidth
            + CGFloat(max(missing - 1, 0)) * columnSpacing

        return HStack(alignment: .top, spacing: columnSpacing) {
            ForEach(row.items) { item in
                card(for: item, imageWidth: imageWidth, imageHeight: imageHeight)
            }

            if missing > 0 {
                TVGridRowFocusGuide()
                    .frame(width: guideWidth, height: artworkHeight)
                    .accessibilityHidden(true)
            }
        }
        .focusSection()
    }
    #endif

    private func card(for item: PlexItem, imageWidth: Int, imageHeight: Int) -> some View {
        PosterNavigationCard(
            route: AppNavigationRoute.destination(for: item),
            imageURL: posterURL(item, imageWidth, imageHeight),
            fallbackImageURL: item.fallbackPosterImageURL(
                plexService: plexService,
                width: imageWidth,
                height: imageHeight
            ),
            title: item.posterCardTitle,
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

#if os(tvOS)
/// One row of a poster grid. Identified by its first item so paging does not
/// rebuild the rows above it.
private struct TVPosterRow: Identifiable {
    let id: PlexItemID
    let items: [PlexItem]
}

/// Occupies the columns a short row does not fill. A move into that space
/// continues to the row's last poster instead of stopping.
private struct TVGridRowFocusGuide: UIViewRepresentable {
    func makeUIView(context: Context) -> TVGridFocusGuideHost {
        TVGridFocusGuideHost()
    }

    func updateUIView(_ uiView: TVGridFocusGuideHost, context: Context) {
        uiView.scheduleRetarget()
    }
}

private final class TVGridFocusGuideHost: UIView {
    private let guide = UIFocusGuide()
    private var retargetScheduled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        addLayoutGuide(guide)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: trailingAnchor),
            guide.topAnchor.constraint(equalTo: topAnchor),
            guide.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        guide.isEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleRetarget()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Stop once a poster is attached. `updateUIView` retargets if the
        // row is reused; assigning the guide from every layout pass loops.
        if !guide.isEnabled {
            scheduleRetarget()
        }
    }

    func scheduleRetarget() {
        guard !retargetScheduled else { return }
        retargetScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.retargetScheduled = false
            self.retarget()
        }
    }

    private func retarget() {
        guard window != nil, bounds.width > 1, bounds.height > 1 else { return }
        var ancestor: UIView? = superview
        for _ in 0..<8 {
            guard let container = ancestor else { break }
            let mine = convert(bounds, to: container)
            let candidates = focusableDescendants(of: container).filter { view in
                let frame = view.convert(view.bounds, to: container)
                let overlapsVertically = frame.maxY > mine.minY + 4 && frame.minY < mine.maxY - 4
                return overlapsVertically && frame.midX < mine.minX && frame.width > 40 && frame.height > 40
            }
            if let target = candidates.max(by: { lhs, rhs in
                lhs.convert(lhs.bounds, to: container).maxX < rhs.convert(rhs.bounds, to: container).maxX
            }) {
                if guide.preferredFocusEnvironments.first as? UIView !== target {
                    guide.preferredFocusEnvironments = [target]
                }
                guide.isEnabled = true
                return
            }
            ancestor = container.superview
        }
    }

    private func focusableDescendants(of root: UIView) -> [UIView] {
        var found: [UIView] = []
        var stack = root.subviews
        while let view = stack.popLast() {
            if view === self || view.isDescendant(of: self) { continue }
            // Ancestors of the guide are the row itself, not a poster.
            if view.canBecomeFocused, !isDescendant(of: view) {
                found.append(view)
            }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }
}
#endif

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
