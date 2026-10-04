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

/// tvOS: what Home asks of the shelf its hero's down-press lands on.
///
/// Home never lets the focus engine pick that landing spot (it picked the
/// third card, or a row further down). It scrolls the page itself and then
/// asks the shelf's first item to take focus. See `HomeTVView.beginHeroExit`.
enum CarouselLeadingItemRequest {
    case none
    /// Scroll back to the first item, but only while the row is off screen.
    case rewindWhenHidden
    /// Scroll back to the first item now.
    case rewind
    /// Scroll back to the first item, focus it, and keep every other item
    /// out of the focus engine's reach.
    case focus
}

extension EnvironmentValues {
    /// A carousel honours it with `carouselLeadingFocusLock(leadingInset:)` on
    /// its scroll view, `carouselItemFocusLock(isLeadingItem:)` on every item,
    /// and `carouselLeadingFocusTarget()` on the focusable view of an item.
    @Entry var carouselLeadingItemRequest = CarouselLeadingItemRequest.none
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
    /// items only see `.rewind`: every item but the first is already out of
    /// reach, and the first one is asked for focus once it is in view.
    func carouselLeadingFocusLock(leadingInset: CGFloat) -> some View {
        modifier(CarouselLeadingFocusLock(leadingInset: leadingInset))
    }

    /// Marks one carousel item for `carouselLeadingItemRequest`.
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
            .disabled(request != .none && !isLeadingItem)
            .environment(\.carouselLeadingItemRequest, isLeadingItem ? request : .none)
        #else
        content
        #endif
    }
}

private struct CarouselLeadingFocusTarget: ViewModifier {
    #if os(tvOS)
    @Environment(\.carouselLeadingItemRequest) private var request
    @FocusState private var isFocused: Bool
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        let wantsFocus = request == .focus

        content
            .focused($isFocused)
            // A task rather than `onChange`, so an item that only materialises
            // after the request was made still answers it.
            .task(id: wantsFocus) {
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
        #else
        content
        #endif
    }
}
