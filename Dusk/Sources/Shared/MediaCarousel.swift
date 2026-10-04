import SwiftUI

/// Reusable horizontal carousel with a section title.
struct MediaCarousel<Content: View>: View {
    let title: String
    let horizontalPadding: CGFloat
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        horizontalPadding: CGFloat = DuskPosterMetrics.carouselHorizontalPadding,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.horizontalPadding = horizontalPadding
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DuskPosterMetrics.carouselSectionSpacing) {
            Text(title)
                .font(DuskFont.sectionHeader(ios: .title3.bold()))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: DuskPosterMetrics.carouselItemSpacing) {
                    content()
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, DuskPosterMetrics.carouselBottomPadding)
            }
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
            .carouselLeadingFocusLock(leadingInset: horizontalPadding)
        }
    }
}

extension EnvironmentValues {
    /// tvOS: while true, only a carousel's first item can take focus.
    ///
    /// Home sets it on its first shelf while the full-screen hero is up, so the
    /// hero's down-press lands on that shelf's first card. Left to itself, the
    /// focus engine enters the shelves' focus section on whichever card it
    /// likes (it picked the third). A carousel honours it with
    /// `carouselLeadingFocusLock(leadingInset:)` on its scroll view and
    /// `carouselItemFocusLock(isLeadingItem:)` on every item.
    @Entry var carouselLeadingItemFocusLock = false
}

extension View {
    /// Applies `carouselLeadingItemFocusLock` to a carousel's horizontal scroll
    /// view. `leadingInset` is the content's leading padding.
    ///
    /// While the lock is requested and the carousel is off screen, it scrolls
    /// back to its leading edge, so a row the user had scrolled along offers
    /// its first item again by the time the lock matters. The lock only reaches
    /// the items while the first one is in view: it sits in a lazy stack, and
    /// locking focus to an item that is not materialised would dead-end the
    /// move into the carousel.
    func carouselLeadingFocusLock(leadingInset: CGFloat) -> some View {
        modifier(CarouselLeadingFocusLock(leadingInset: leadingInset))
    }

    /// Marks one carousel item for `carouselLeadingItemFocusLock`.
    func carouselItemFocusLock(isLeadingItem: Bool) -> some View {
        modifier(CarouselItemFocusLock(isLeadingItem: isLeadingItem))
    }
}

private struct CarouselLeadingFocusLock: ViewModifier {
    let leadingInset: CGFloat

    #if os(tvOS)
    @Environment(\.carouselLeadingItemFocusLock) private var isRequested
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
                returnToLeadingEdgeIfHidden()
            }
            .onChange(of: isRequested) { _, _ in
                returnToLeadingEdgeIfHidden()
            }
            .environment(\.carouselLeadingItemFocusLock, isRequested && isLeadingItemInView)
        #else
        content
        #endif
    }

    #if os(tvOS)
    /// Only while nobody can see it, so the row never visibly jumps.
    private func returnToLeadingEdgeIfHidden() {
        guard isRequested, !isOnScreen, !isLeadingItemInView else { return }
        scrollPosition.scrollTo(edge: .leading)
    }
    #endif
}

private struct CarouselItemFocusLock: ViewModifier {
    let isLeadingItem: Bool

    #if os(tvOS)
    @Environment(\.carouselLeadingItemFocusLock) private var isLocked
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        // `.disabled` takes the item out of the focus engine's reach. The
        // poster cards' chrome-suppressed style ignores `isEnabled`, so they do
        // not dim; the Live TV cards use the system `.plain` style, which may.
        // Either way a locked row is only on screen while the page scrolls
        // from the hero to the fold.
        content.disabled(isLocked && !isLeadingItem)
        #else
        content
        #endif
    }
}
