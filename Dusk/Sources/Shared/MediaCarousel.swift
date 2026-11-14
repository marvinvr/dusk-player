import SwiftUI

/// Reusable horizontal carousel with a section title.
struct MediaCarousel<Content: View>: View {
    let title: String
    let horizontalPadding: CGFloat
    /// Mac: the full list behind the row, opened from the section title
    /// ("Title ›", like the TV and Music apps). Ignored on iOS and tvOS.
    var titleRoute: AppNavigationRoute? = nil
    /// Mac: height of the cards' artwork, so the hover paging chevrons sit
    /// centred on the artwork rather than on artwork plus titles.
    var artworkHeight: CGFloat? = nil
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        horizontalPadding: CGFloat = DuskPosterMetrics.carouselHorizontalPadding,
        titleRoute: AppNavigationRoute? = nil,
        artworkHeight: CGFloat? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.horizontalPadding = horizontalPadding
        self.titleRoute = titleRoute
        self.artworkHeight = artworkHeight
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DuskPosterMetrics.carouselSectionSpacing) {
            header
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, horizontalPadding)

            #if os(macOS)
            MacShelfPagingScrollView(
                horizontalPadding: horizontalPadding,
                artworkHeight: artworkHeight
            ) {
                CarouselItemStack(alignment: .top, spacing: DuskPosterMetrics.carouselItemSpacing) {
                    content()
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, DuskPosterMetrics.carouselBottomPadding)
            }
            #else
            ScrollView(.horizontal, showsIndicators: false) {
                CarouselItemStack(alignment: .top, spacing: DuskPosterMetrics.carouselItemSpacing) {
                    content()
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, DuskPosterMetrics.carouselBottomPadding)
            }
            #if os(tvOS)
            // One section per row. Up or Down from any card — including one
            // scrolled away from the leading edge — moves to the nearest item
            // in the row above or below. Leaving the move to geometry traps
            // it on the first card (issue #24).
            .focusSection()
            .scrollClipDisabled()
            #endif
            .carouselLeadingFocusLock(leadingInset: horizontalPadding)
            #endif
        }
    }

    @ViewBuilder
    private var header: some View {
        let text = Text(title)
            .font(DuskFont.sectionHeader(ios: .title3.bold()))
            .foregroundStyle(Color.primary)
        #if os(macOS)
        if let titleRoute {
            NavigationLink(value: titleRoute) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    text
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show All")
        } else {
            text
        }
        #else
        text
        #endif
    }
}

#if os(macOS)
/// A shelf's horizontal scroll view on the Mac. While the pointer is over
/// the shelf, glass chevrons at its leading and trailing edges (centred on
/// the artwork) page it by one visible width, like the TV app's rows; each
/// only shows when there is more to scroll that way.
private struct MacShelfPagingScrollView<Content: View>: View {
    let horizontalPadding: CGFloat
    let artworkHeight: CGFloat?
    @ViewBuilder let content: () -> Content

    @State private var position = ScrollPosition(edge: .leading)
    @State private var metrics = ShelfScrollMetrics()
    /// Bumped to make the scroll view report its geometry again (see
    /// `ShelfScrollMetrics.generation`).
    @State private var measureGeneration = 0
    @State private var isHovered = false

    /// Offsets as the scroll view reports them: with a leading content
    /// inset (the safe area beside the sidebar) a row at rest sits at
    /// `-inset`, not 0, so both ends come from the geometry, never from 0.
    private struct ShelfScrollMetrics: Equatable {
        var offset: CGFloat = 0
        var minOffset: CGFloat = 0
        var maxOffset: CGFloat = 0
        var viewport: CGFloat = 0
        /// `onScrollGeometryChange` reports changes only, never the first
        /// value, so a row laid out once at its final size never had any
        /// metrics. Changing this re-runs the transform with a new value.
        var generation = 0
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content()
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: ShelfScrollMetrics.self) { [measureGeneration] geometry in
            let minOffset = -geometry.contentInsets.leading
            let maxOffset = geometry.contentSize.width + geometry.contentInsets.trailing
                - geometry.containerSize.width
            return ShelfScrollMetrics(
                offset: geometry.contentOffset.x,
                minOffset: minOffset,
                maxOffset: max(maxOffset, minOffset),
                viewport: geometry.containerSize.width,
                generation: measureGeneration
            )
        } action: { _, new in
            metrics = new
        }
        .overlay(alignment: .topLeading) {
            chevrons
        }
        .onHover { inside in
            isHovered = inside
            if inside { measureGeneration += 1 }
        }
        .task { measureGeneration += 1 }
    }

    private var canPageBack: Bool { metrics.offset > metrics.minOffset + 1 }
    private var canPageForward: Bool { metrics.offset < metrics.maxOffset - 1 }

    private var chevrons: some View {
        HStack {
            chevron("chevron.left", label: "Previous", isShown: canPageBack) { page(by: -1) }
            Spacer(minLength: 0)
            chevron("chevron.right", label: "Next", isShown: canPageForward) { page(by: 1) }
        }
        .padding(.horizontal, 6)
        .frame(height: artworkHeight)
        .frame(maxHeight: artworkHeight == nil ? .infinity : nil)
    }

    private func chevron(
        _ systemImage: String,
        label: String,
        isShown: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isVisible = isHovered && isShown
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help(label)
        .accessibilityLabel(label)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeOut(duration: 0.16), value: isVisible)
    }

    /// One visible width (less the side insets, so the card cut off at the
    /// edge comes round in full), clamped to the row.
    private func page(by direction: CGFloat) {
        let step = max(metrics.viewport - horizontalPadding * 2, 1)
        let target = min(max(metrics.offset + direction * step, metrics.minOffset), metrics.maxOffset)
        withAnimation(.smooth(duration: 0.4)) {
            position.scrollTo(x: target)
        }
    }
}
#endif

/// The items of a horizontally scrolling row.
///
/// tvOS keeps the row's first items out of the lazy stack. A lazy row that is
/// off screen stands in for its unrealised items with focusable filler items.
/// A vertical move lands on a filler and UIKit then re-resolves focus inside
/// the row wherever it likes, which was the third card (issue #50). The eager
/// items cover a screen width, so a row that has not been scrolled always
/// offers the focus engine the real card below the focused one. The rest stays
/// lazy for long rows.
struct CarouselItemStack<Content: View>: View {
    var alignment: VerticalAlignment = .center
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    #if os(tvOS)
    /// Seven posters fit on the display at the carousel's width, and an eighth
    /// is revealed by the first move right.
    private static var eagerItemCount: Int { 8 }
    #endif

    var body: some View {
        #if os(tvOS)
        Group(subviews: content()) { items in
            HStack(alignment: alignment, spacing: spacing) {
                ForEach(items.prefix(Self.eagerItemCount)) { $0 }

                if items.count > Self.eagerItemCount {
                    LazyHStack(alignment: alignment, spacing: spacing) {
                        ForEach(items.dropFirst(Self.eagerItemCount)) { $0 }
                    }
                }
            }
        }
        #else
        LazyHStack(alignment: alignment, spacing: spacing) {
            content()
        }
        #endif
    }
}

/// tvOS: what Home asks of the shelf its hero's down-press lands on.
///
/// Home does not let the focus engine's own pick stand (it picked the third
/// card, or a row further down). It scrolls the page to the fold and asks the
/// shelf's first item to take focus. See `HomeTVView.beginHeroExit`.
///
/// None of this disables anything. A row with nothing focusable left in it
/// is stood in for by a focusable filler item, and a move into that filler
/// ends wherever UIKit then decides.
enum CarouselLeadingItemRequest {
    case none
    /// Scroll back to the first item, but only while the row is off screen.
    case rewindWhenHidden
    /// Scroll back to the first item now.
    case rewind
    /// Scroll back to the first item and focus it; again on every bump of
    /// `carouselLeadingFocusGeneration` while the request stands.
    case focus
}

extension EnvironmentValues {
    /// A carousel honours it with `carouselLeadingFocusLock(leadingInset:)` on
    /// its scroll view, `carouselItemFocusLock(isLeadingItem:)` on every item,
    /// and `carouselLeadingFocusTarget()` on the focusable view of an item.
    @Entry var carouselLeadingItemRequest = CarouselLeadingItemRequest.none
    /// Bumped by whoever made a `.focus` request to have the item take focus
    /// again after it lost it. The requester decides, not the item: a request
    /// it has just withdrawn must not be answered by a stale re-assertion.
    @Entry var carouselLeadingFocusGeneration = 0
}

/// Whether any carousel item holds focus.
struct CarouselItemFocusedKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Whether the item a `.focus` request asked for now holds focus.
struct CarouselLeadingItemFocusedKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    /// Applies `carouselLeadingItemRequest` to a carousel's horizontal scroll
    /// view. `leadingInset` is the content's leading padding.
    ///
    /// The first item sits in a lazy stack, so it only exists while the row is
    /// at its leading edge. Until a row asked to `.focus` has been rewound, its
    /// items only see `.rewind`; the first one is asked for focus once it is in
    /// view.
    func carouselLeadingFocusLock(leadingInset: CGFloat) -> some View {
        modifier(CarouselLeadingFocusLock(leadingInset: leadingInset))
    }

    /// Marks one carousel item for `carouselLeadingItemRequest`: only the
    /// leading item sees the request.
    func carouselItemFocusLock(isLeadingItem: Bool) -> some View {
        modifier(CarouselItemFocusLock(isLeadingItem: isLeadingItem))
    }

    /// Put this on the focusable view of a carousel item (the button, not its
    /// container). It takes focus when a `.focus` request reaches it.
    func carouselLeadingFocusTarget() -> some View {
        modifier(CarouselLeadingFocusTarget())
    }
}

private struct CarouselLeadingFocusLock: ViewModifier {
    let leadingInset: CGFloat

    #if os(tvOS)
    @Environment(\.carouselLeadingItemRequest) private var request
    @State private var scrollPosition = ScrollPosition()
    @State private var isLeadingItemInView = true
    @State private var isOnScreen = true
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // The first item's leading edge is inside the viewport.
                geometry.contentOffset.x + geometry.contentInsets.leading <= leadingInset
            } action: { _, isInView in
                isLeadingItemInView = isInView
            }
            .onScrollVisibilityChange(threshold: 0.01) { isVisible in
                isOnScreen = isVisible
                rewindIfRequested()
            }
            .onChange(of: request) { _, _ in
                rewindIfRequested()
            }
            .environment(
                \.carouselLeadingItemRequest,
                request == .focus ? (isLeadingItemInView ? .focus : .rewind) : .none
            )
        #else
        content
        #endif
    }

    #if os(tvOS)
    private func rewindIfRequested() {
        switch request {
        case .none:
            return
        case .rewindWhenHidden:
            // Nobody can see it, so the row never visibly jumps.
            guard !isOnScreen else { return }
        case .rewind, .focus:
            break
        }

        guard !isLeadingItemInView else { return }
        scrollPosition.scrollTo(edge: .leading)
    }
    #endif
}

private struct CarouselItemFocusLock: ViewModifier {
    let isLeadingItem: Bool

    #if os(tvOS)
    @Environment(\.carouselLeadingItemRequest) private var request
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
            .environment(\.carouselLeadingItemRequest, isLeadingItem ? request : .none)
        #else
        content
        #endif
    }
}

private struct CarouselLeadingFocusTarget: ViewModifier {
    #if os(tvOS)
    @Environment(\.carouselLeadingItemRequest) private var request
    @Environment(\.carouselLeadingFocusGeneration) private var generation
    @FocusState private var isFocused: Bool
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        let wantsFocus = request == .focus

        content
            .focused($isFocused)
            // A task rather than `onChange`, so an item that only materialises
            // after the request was made still answers it.
            .task(id: wantsFocus ? generation : nil) {
                guard wantsFocus else { return }
                isFocused = true
                // An item that has only just materialised may not be in the
                // focus system yet. Withdrawing the request cancels this.
                try? await Task.sleep(for: .milliseconds(120))
                if !Task.isCancelled, !isFocused {
                    isFocused = true
                }
            }
            .preference(key: CarouselLeadingItemFocusedKey.self, value: wantsFocus && isFocused)
            .preference(key: CarouselItemFocusedKey.self, value: isFocused)
        #else
        content
        #endif
    }
}
