import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct HomeCinematicHeroLayout {
    var heroHeightFactor: CGFloat = 0.72
    var heroHeightRange: ClosedRange<CGFloat> = 520 ... 760
    /// When true the hero ignores `heroHeightFactor` / `heroHeightRange` and
    /// simply takes the container height it is handed, unmodified (no
    /// `topInset` addition — the caller already sized the container to the whole
    /// display). tvOS uses this for the full-bleed cinematic home hero.
    var fillsContainerHeight: Bool = false
    /// Caps the factor-derived height (before `topInset`) at this multiple of
    /// the container width, so a tall portrait iPad doesn't crop a 16:9
    /// backdrop down to a sliver. Ignored with `fillsContainerHeight`.
    var maxHeightToWidthRatio: CGFloat? = nil
    /// Caps the hero (`topInset` included) at the container height, so the
    /// title, actions and pager all land on the first screen. iPhone Duo's
    /// 466pt-tall cover display in landscape is shorter than the 520pt floor.
    /// Ignored with `fillsContainerHeight`.
    var fitsContainerHeight: Bool = false
    var maxContentWidth: CGFloat = 620
    var contentHorizontalPadding: CGFloat = 20
    var contentTopPadding: CGFloat = 64
    var contentBottomPaddingWithPager: CGFloat = 52
    var contentBottomPaddingWithoutPager: CGFloat = 28
    var actionsTopPadding: CGFloat = 0
    var actionsBottomPadding: CGFloat = 0
    var pagerHorizontalPadding: CGFloat = 20
    var pagerBottomPadding: CGFloat = 28
    /// Most pager pills shown at once. Past it the pager becomes a sliding
    /// window, see `HomeHeroPagerWindow`.
    var pagerMaxVisibleItems: Int = 7
    var titleFontSize: CGFloat = 42
    var titleLogoMaxWidth: CGFloat = 420
    var titleLogoMaxHeight: CGFloat = 108
    var backdropImageAlignment: Alignment = .center
    /// tvOS-only bottom mask of the backdrop + overlay stack. iOS ignores it.
    var backdropBottomFadeStyle: DuskHeroBottomFadeStyle = .compact
    /// Scrim strength of `DuskHeroBackdropOverlay`.
    var backdropOverlayStyle: DuskHeroOverlayStyle = .standard
    /// Gap between the title (logo or text) and the lines under it. Movies have
    /// no episode title, so their block breathes a little wider.
    var titleBlockSpacingMovie: CGFloat = 18
    var titleBlockSpacingOther: CGFloat = 14
    var episodeTitleFont: Font = .title3.weight(.semibold)
    var metadataFont: Font = .subheadline.weight(.medium)
    var summaryFont: Font = .body
    var summaryLineLimit: Int = 3
    var summaryLineSpacing: CGFloat = 4

    static let ios = HomeCinematicHeroLayout(summaryLineLimit: 2)
    /// iPad (regular width): a near-full-screen take on the tvOS hero. It fills
    /// the scroll viewport down to the bottom inset, so only the first shelf's
    /// header and the top of its posters peek in under it — enough of a hint
    /// that the page scrolls, since iPad has no tvOS-style "More" affordance.
    /// Portrait is held to a square (`maxHeightToWidthRatio`) to keep the
    /// backdrop's crop sane, and `.cinematic` keeps the artwork nearly clear
    /// above the title block.
    static let iPad = HomeCinematicHeroLayout(
        heroHeightFactor: 1,
        heroHeightRange: 560 ... 1200,
        maxHeightToWidthRatio: 1,
        maxContentWidth: 680,
        contentHorizontalPadding: 32,
        contentTopPadding: 64,
        contentBottomPaddingWithPager: 64,
        contentBottomPaddingWithoutPager: 36,
        actionsTopPadding: 6,
        pagerHorizontalPadding: 32,
        pagerBottomPadding: 32,
        pagerMaxVisibleItems: 9,
        titleFontSize: 54,
        titleLogoMaxWidth: 520,
        titleLogoMaxHeight: 136,
        backdropOverlayStyle: .cinematic,
        titleBlockSpacingMovie: 16,
        titleBlockSpacingOther: 12,
        episodeTitleFont: .title2.weight(.semibold),
        metadataFont: .callout.weight(.medium),
        summaryLineLimit: 3
    )
    #if os(macOS)
    /// Mac window: the iPad hero, but never much taller than the backdrop's
    /// own 16:9 (`maxHeightToWidthRatio`), so a wide window doesn't crop the
    /// artwork to a strip, and a little short of the viewport so the first
    /// shelf shows under it.
    ///
    /// The height is worked out in `HomeCinematicHero.macHeroHeight` (at most
    /// `MacUILayout.heroMaxHeightFraction` of the window, toolbar included),
    /// and the page fades into the window background only in the last
    /// `macBottomFadeHeight` points, below the pager.
    static let mac: HomeCinematicHeroLayout = {
        var layout = iPad
        layout.heroHeightRange = 360 ... 1000
        layout.maxContentWidth = MacUILayout.readableTextWidth
        layout.contentHorizontalPadding = MacUILayout.contentInset
        layout.pagerHorizontalPadding = MacUILayout.contentInset
        layout.contentTopPadding = 16
        layout.pagerBottomPadding = macBottomFadeHeight + 6
        layout.contentBottomPaddingWithPager = macBottomFadeHeight + 6 + 10 + 18
        layout.contentBottomPaddingWithoutPager = macBottomFadeHeight + 14
        layout.actionsTopPadding = 2
        layout.titleFontSize = 40
        layout.titleLogoMaxWidth = 360
        layout.titleLogoMaxHeight = 110
        layout.titleBlockSpacingMovie = 12
        layout.titleBlockSpacingOther = 10
        layout.episodeTitleFont = .title2.weight(.semibold)
        layout.metadataFont = .callout.weight(.medium)
        layout.summaryFont = .body
        layout.summaryLineSpacing = 2
        return layout
    }()

    /// `mac`, with the title block grown on a wide window (a 2000pt window
    /// left a 360pt logo and 13pt text looking lost on an 800pt hero): the
    /// logo, text width and summary/metadata sizes step up with the width,
    /// up to a cap.
    static func mac(width: CGFloat) -> HomeCinematicHeroLayout {
        var layout = mac
        let scale = min(max((width - 1100) / 700, 0), 1)
        layout.titleLogoMaxWidth = (360 + 160 * scale).rounded()
        layout.titleLogoMaxHeight = (110 + 40 * scale).rounded()
        layout.titleFontSize = (40 + 12 * scale).rounded()
        layout.maxContentWidth = (MacUILayout.readableTextWidth + 120 * scale).rounded()
        if scale >= 0.5 {
            layout.summaryFont = .title3
            layout.metadataFont = .body.weight(.medium)
            layout.episodeTitleFont = .title.weight(.semibold)
        }
        return layout
    }

    /// The hero's bottom strip whose art eases out onto the page background,
    /// below the text, button and pager, so the dark hero meets a light or
    /// dark page without a band.
    static let macBottomFadeHeight: CGFloat = 48
    #endif

    /// Apple TV: the hero owns the **entire** screen. Heights come from the
    /// container (`fillsContainerHeight`), and the paddings below are measured
    /// from the real display edges, not from a banner box:
    ///
    /// - `contentBottomPaddingWithPager` sits the text/button block just above
    ///   the pager pills. The "More" hint `HomeTVView` overlays is bottom
    ///   *centre*, and the lowest thing in this leading-aligned block is the
    ///   narrow play button, so the block only has to clear the pills.
    /// - `pagerBottomPadding` = 60pt overscan inset + ~18pt so the pills share a
    ///   baseline with that hint.
    static let tv = HomeCinematicHeroLayout(
        heroHeightFactor: 1,
        heroHeightRange: 560 ... 2160,
        fillsContainerHeight: true,
        maxContentWidth: 920,
        contentHorizontalPadding: 56,
        contentTopPadding: 64,
        contentBottomPaddingWithPager: 124,
        contentBottomPaddingWithoutPager: 96,
        actionsTopPadding: 10,
        actionsBottomPadding: 8,
        pagerHorizontalPadding: 56,
        pagerBottomPadding: 78,
        pagerMaxVisibleItems: 10,
        titleFontSize: DuskFont.TV.Size.heroTitle,
        titleLogoMaxWidth: 640,
        titleLogoMaxHeight: 150,
        backdropImageAlignment: .center,
        backdropBottomFadeStyle: .fullBleed,
        backdropOverlayStyle: .cinematic,
        titleBlockSpacingMovie: 14,
        titleBlockSpacingOther: 10,
        episodeTitleFont: DuskFont.TV.heroSubtitle,
        metadataFont: DuskFont.TV.metadata,
        summaryFont: DuskFont.TV.body,
        summaryLineLimit: 3,
        summaryLineSpacing: 3
    )
}

struct HomeCinematicHeroCallbacks {
    let pauseRotation: () -> Void
    let restartRotation: () -> Void
    let showPrevious: () -> Void
    let showNext: () -> Void
    /// iOS: gives a hero button the page's long-press menu through a UIKit
    /// interaction that never touches the button itself. SwiftUI's
    /// `.contextMenu` on a glass button lifts the artwork it refracts as a
    /// ghosted box, and on its label it re-lays the label out mid-press.
    var withContextMenu: (AnyView) -> AnyView = { $0 }
}

struct HomeCinematicHero: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback

    let items: [PlexItem]
    let viewModel: HomeViewModel
    let containerSize: CGSize
    let topInset: CGFloat
    var contentLeadingInset: CGFloat = 0
    var contentTrailingInset: CGFloat = 0
    var layout: HomeCinematicHeroLayout = .ios
    var autoRotates = true
    var supportsDragNavigation = false
    let selectionResetRevision: Int
    /// tvOS: the hero's `onMoveCommand(.down)`. It fires for every down move
    /// from the play button, whether or not the focus engine moved focus for
    /// it; `HomeTVView` decides what the move amounts to.
    var onMoveDown: (() -> Void)? = nil
    /// tvOS: the `storageKey` of the page whose play button has focus, `nil`
    /// while focus is anywhere else. Rotation only runs while it is set.
    var focusedItemKey: String? = nil
    /// tvOS: moves focus to that page's play button. Rotation and the
    /// wrap-around at either end page through it, so a page change is always
    /// the focus engine's own move and scroll.
    var onFocusItem: ((PlexItem) -> Void)? = nil
    /// tvOS: the `storageKey` of the page on screen, whenever it changes.
    /// It follows the page scroll, so it is the page actually showing even
    /// when focus is elsewhere and the hero has been reset or refilled.
    var onVisibleItemChange: ((String?) -> Void)? = nil
    let primaryAction: (PlexItem, HomeCinematicHeroCallbacks) -> AnyView
    var secondaryAction: ((PlexItem, HomeCinematicHeroCallbacks) -> AnyView)? = nil
    var detailsAction: ((PlexItem) -> Void)? = nil
    /// iOS: long-press menu items for a page, on its artwork and (through
    /// `HomeCinematicHeroCallbacks.withContextMenu`) its button, always with
    /// `heroContextMenuPreview` as the lifted card.
    var contextMenuActions: ((PlexItem) -> [HomeItemMenuAction])? = nil

    @State private var currentHeroIndex = Self.initialHeroIndex
    @State private var heroRotationRevision = 0
    @State private var isHeroRotationPaused = false
    @State private var heroRotationStartedAt = Date()
    @State private var pausedHeroRotationProgress: Double?
    @State private var transitioningHeroIndex: Int?
    @State private var heroSlideProgress: CGFloat = 1
    @State private var heroSlideRevision = 0
    @State private var heroTransitionDirection: HeroTransitionDirection = .forward
    @State private var pendingHeroTransition: PendingHeroTransition?
    @State private var heroDragOffset: CGFloat = 0
    @State private var heroDragTargetIndex: Int?
    @State private var heroDragRevision = 0
    @State private var isHeroDragging = false
    #if os(tvOS)
    /// The horizontal page scroll of the tvOS hero. See `tvPages`.
    @State private var tvPagePosition = ScrollPosition()
    /// The page `tvPages` is on or sliding to.
    @State private var tvRestingPage = 0
    /// The page a jump left (`slideToPage`), drawn over the hero while it
    /// fades out.
    @State private var jumpFadeItem: PlexItem?
    @State private var jumpFadeOpacity: Double = 0
    /// Height of a page's action row, so the fading page's text sits exactly
    /// where it did. It has no buttons of its own: they would be a second
    /// focus target bound to the same page.
    @State private var heroActionsHeight: CGFloat = 0
    #endif
    #if os(macOS)
    /// The pointer is over the hero; shows `macPageChevrons`.
    @State private var isPointerOverHero = false
    /// The Mac's right-click menu for a page (`macContextMenu(_:)`).
    var macContextMenuContent: ((PlexItem) -> AnyView)? = nil
    #endif
    @State private var preloadedHeroBackdropImages: [String: PlatformImage] = [:]
    @State private var preloadedHeroTitleImages: [String: PlatformImage] = [:]
    @State private var failedHeroTitleImageKeys: Set<String> = []

    private let heroRotationInterval: UInt64 = 7_000_000_000

    /// Duration of a user-driven hero move (remote press, pager tap, chevron).
    /// tvOS is shorter: every Siri Remote click waits on this slide, so the
    /// iOS-paced 0.5s read as lag there.
    #if os(tvOS)
    private let heroPressTransitionDuration: TimeInterval = 0.32
    /// The tvOS page slide (`tvPages`). The focus engine's own reveal scroll
    /// took ~0.9s, most of it a slow creep onto the page. Eased out, but not
    /// as front-loaded as `heroSlideAnimation`: across the whole display that
    /// curve's first frames read as a jump.
    private let tvPageSlide = Animation.timingCurve(0.25, 0.75, 0.25, 1, duration: 0.5)
    #else
    private let heroPressTransitionDuration: TimeInterval = 0.5
    #endif

    var body: some View {
        let resolvedIndex = resolvedHeroIndex
        let heroWidth = pixelAlignedLength(containerSize.width)
        #if os(macOS)
        let rawHeroHeight = macHeroHeight
        #else
        let rawHeroHeight: CGFloat = layout.fillsContainerHeight
            // Full-bleed: the caller already sized `containerSize` to the whole
            // display, top safe area included, so adding `topInset` again would
            // push the hero past the bottom of the screen.
            ? containerSize.height
            : min(
                max(containerSize.height * layout.heroHeightFactor, layout.heroHeightRange.lowerBound),
                layout.heroHeightRange.upperBound,
                layout.maxHeightToWidthRatio.map { containerSize.width * $0 } ?? .infinity,
                layout.fitsContainerHeight ? containerSize.height : .infinity
            ) + topInset
        #endif
        let heroHeight = pixelAlignedLength(rawHeroHeight)
        let backdropWidth = Int(heroWidth.rounded(.up))
        let backdropHeight = Int(heroHeight.rounded(.up))
        let safeContentWidth = max(heroWidth - contentLeadingInset - contentTrailingInset, 0)
        let contentWidth = min(
            max(safeContentWidth - (layout.contentHorizontalPadding * 2), 0),
            layout.maxContentWidth
        )
        let titleLogoWidth = Int(min(contentWidth, layout.titleLogoMaxWidth).rounded(.up))
        let titleLogoHeight = Int(layout.titleLogoMaxHeight.rounded(.up))

        let baseHero = ZStack(alignment: .bottomLeading) {
            heroSlides(
                resolvedIndex: resolvedIndex,
                heroWidth: heroWidth,
                heroHeight: heroHeight,
                backdropWidth: backdropWidth,
                backdropHeight: backdropHeight,
                contentWidth: contentWidth
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        #if os(macOS)
        .coordinateSpace(.named(Self.macCoordinateSpace))
        #endif
        // An overlay, not a ZStack sibling: the pager must never size the
        // hero. As a sibling, a pager wider than the screen (one pill per
        // Continue Watching item) widened the whole ZStack and pushed the
        // centred title block and Play button off the right edge.
        .overlay(alignment: heroContentBlockAlignment) {
            if items.count > 1 {
                heroPager(currentIndex: resolvedIndex)
                    #if os(macOS)
                    .environment(\.colorScheme, .dark)
                    #endif
                    .padding(.leading, contentLeadingInset + layout.pagerHorizontalPadding)
                    .padding(.trailing, contentTrailingInset + layout.pagerHorizontalPadding)
                    .padding(.bottom, layout.pagerBottomPadding)
            }
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        #if os(macOS)
        // The sidebar floats over the window: the current page's art
        // continues under it, mirrored and blurred by the system, like the TV
        // app. A separate, unclipped layer, because the sliding pages are
        // clipped to the hero.
        .background(alignment: .top) {
            macSidebarExtension(
                resolvedIndex: resolvedIndex,
                heroHeight: heroHeight,
                backdropWidth: backdropWidth,
                backdropHeight: backdropHeight
            )
        }
        #endif
        .contentShape(Rectangle())
        .onChange(of: heroItemIDs) { _, ids in
            guard !ids.isEmpty else {
                resetHeroSelection(restartRotation: false)
                return
            }

            resetHeroSelection()
        }
        .onChange(of: selectionResetRevision) { _, _ in
            resetHeroSelection()
        }
        .onChange(of: playback.showPlayer) { _, isShowing in
            // The player presents as a full-screen cover, which does not change
            // scenePhase, so the rotation timer would otherwise keep advancing the
            // hero behind it. Pause while playing and restart fresh on return so we
            // come back to the hero the user launched from.
            if isShowing {
                pauseHeroRotation()
            } else {
                restartHeroRotation()
            }
        }
        .task(id: heroRotationSeed) {
            await rotateHeroIfNeeded()
        }
        .task(id: heroBackdropPrefetchSeed(width: backdropWidth, height: backdropHeight)) {
            await preloadHeroBackdropImages(width: backdropWidth, height: backdropHeight)
        }
        .task(id: heroTitlePrefetchSeed(width: titleLogoWidth, height: titleLogoHeight)) {
            await preloadHeroTitleImages(width: titleLogoWidth, height: titleLogoHeight)
        }

        #if os(tvOS)
        return baseHero
            .duskTVOSStandardImageDynamicRange()
            .onMoveCommand(perform: handleHeroMoveCommand)
            // Focus arriving on a play button (Home on screen, back from the
            // shelves or the tab bar, a page change) starts a fresh interval;
            // focus going anywhere else holds the rotation where it is.
            .onChange(of: focusedItemKey) { _, key in
                if key == nil {
                    pauseHeroRotation()
                } else {
                    restartHeroRotation()
                }
            }
            .onChange(of: visibleItemKey, initial: true) { _, key in
                onVisibleItemChange?(key)
            }
        #else
        if supportsDragNavigation {
            return AnyView(
                baseHero
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 20)
                            .onChanged { value in
                                handleHeroDragChanged(value)
                            }
                            .onEnded { value in
                                handleHeroDragEnded(value, heroWidth: heroWidth)
                            }
                    )
                    #if os(iOS)
                    .gesture(heroIndirectScrollGesture(HeroTrackpadScroll.self, heroWidth: heroWidth))
                    .gesture(heroIndirectScrollGesture(HeroWheelScroll.self, heroWidth: heroWidth))
                    #endif
                    #if os(macOS)
                    .overlay { macPageChevrons }
                    .onHover { isPointerOverHero = $0 }
                    #endif
            )
        } else {
            return AnyView(baseHero)
        }
        #endif
    }

    @ViewBuilder
    private func heroSlides(
        resolvedIndex: Int,
        heroWidth: CGFloat,
        heroHeight: CGFloat,
        backdropWidth: Int,
        backdropHeight: Int,
        contentWidth: CGFloat
    ) -> some View {
        #if os(tvOS)
        tvPages(
            heroWidth: heroWidth,
            heroHeight: heroHeight,
            backdropWidth: backdropWidth,
            backdropHeight: backdropHeight,
            contentWidth: contentWidth
        )
        #else
        ZStack(alignment: .bottomLeading) {
            if let backgroundHeroIndex,
               items.indices.contains(backgroundHeroIndex) {
                heroSlide(
                    item: items[backgroundHeroIndex],
                    heroHeight: heroHeight,
                    backdropWidth: backdropWidth,
                    backdropHeight: backdropHeight,
                    contentWidth: contentWidth,
                    reservesPagerSpace: items.count > 1
                )
                .offset(x: backgroundHeroOffset(width: heroWidth))
                .id("background-\(items[backgroundHeroIndex].id.storageKey)")
                .zIndex(0)
            }

            if items.indices.contains(resolvedIndex) {
                heroSlide(
                    item: items[resolvedIndex],
                    heroHeight: heroHeight,
                    backdropWidth: backdropWidth,
                    backdropHeight: backdropHeight,
                    contentWidth: contentWidth,
                    reservesPagerSpace: items.count > 1
                )
                .offset(x: foregroundHeroOffset(width: heroWidth))
                .id("foreground-\(items[resolvedIndex].id.storageKey)")
                .zIndex(1)
            }
        }
        #endif
    }

    #if os(tvOS)
    /// tvOS: every hero item is a full-width page of one horizontal scroll
    /// view, and each page carries its own play button.
    ///
    /// Paging is therefore an ordinary focus move: left/right from one play
    /// button goes to its neighbour a page away. Clicks and touch-surface
    /// swipes are the engine's own, exactly as in any row of cards. The page
    /// scroll itself is the hero's: scrolling is disabled, so the engine does
    /// not reveal the newly focused button with its own slow scroll (~0.9s),
    /// and the hero slides to the focused page instead (`tvPageSlide`). The hero used to be a single slide with the only focusable item
    /// on screen, paged by `onMoveCommand`; with nothing to the left or right
    /// the engine had no horizontal move to make, and the arc of a sideways
    /// swipe ended as a move down into the shelves.
    ///
    /// Not lazy: a page the engine is to move to must exist before it is on
    /// screen, and the hero holds at most `heroItemLimit` items.
    private func tvPages(
        heroWidth: CGFloat,
        heroHeight: CGFloat,
        backdropWidth: Int,
        backdropHeight: Int,
        contentWidth: CGFloat
    ) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(items, id: \.id) { item in
                    heroSlide(
                        item: item,
                        heroHeight: heroHeight,
                        backdropWidth: backdropWidth,
                        backdropHeight: backdropHeight,
                        contentWidth: contentWidth,
                        reservesPagerSpace: items.count > 1
                    )
                    .frame(width: heroWidth, height: heroHeight)
                }
            }
        }
        .overlay {
            if let jumpFadeItem {
                heroSlide(
                    item: jumpFadeItem,
                    heroHeight: heroHeight,
                    backdropWidth: backdropWidth,
                    backdropHeight: backdropHeight,
                    contentWidth: contentWidth,
                    reservesPagerSpace: items.count > 1,
                    showsActions: false
                )
                .frame(width: heroWidth, height: heroHeight)
                .opacity(jumpFadeOpacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.zero, for: .scrollContent)
        .scrollPosition($tvPagePosition)
        .scrollDisabled(true)
        .onChange(of: focusedItemKey) { _, key in
            guard let key,
                  let index = heroItemIDs.firstIndex(of: key),
                  index != tvRestingPage else { return }
            slideToPage(index, from: tvRestingPage, heroWidth: heroWidth)
        }
        // A `scrollTo` issued while the previous slide is still running is
        // sometimes dropped (measured with quick left/right presses): the
        // hero settled a page or two short of the focused play button, which
        // then sat off screen, and nothing moved it again until the next
        // press. Once the scroll is at rest, finish the move it missed.
        .onScrollPhaseChange { _, phase in
            guard phase == .idle,
                  currentHeroIndex != tvRestingPage,
                  items.indices.contains(tvRestingPage) else { return }
            slideToPage(tvRestingPage, from: currentHeroIndex, heroWidth: heroWidth)
        }
        .onScrollGeometryChange(for: Int.self) { geometry in
            guard heroWidth > 0 else { return 0 }
            return Int(((geometry.contentOffset.x + geometry.contentInsets.leading) / heroWidth).rounded())
        } action: { _, page in
            currentHeroIndex = min(max(page, 0), max(items.count - 1, 0))
        }
    }

    /// The page slide that follows focus, with the hero's own curve.
    ///
    /// Only to a neighbouring page. Any page further away (the wrap past
    /// either end, rotation going back to the start) would slide across every
    /// full-screen page in between, which is what made the wrap stutter. That
    /// move jumps there unanimated instead, and the page left behind fades out
    /// on top.
    private func slideToPage(_ index: Int, from: Int, heroWidth: CGFloat) {
        tvRestingPage = index
        let x = CGFloat(index) * heroWidth

        guard abs(index - from) > 1, items.indices.contains(from) else {
            withAnimation(tvPageSlide) {
                tvPagePosition.scrollTo(x: x)
            }
            return
        }

        jumpFadeItem = items[from]
        jumpFadeOpacity = 1
        var jump = Transaction()
        jump.disablesAnimations = true
        withTransaction(jump) {
            tvPagePosition.scrollTo(x: x)
        }
        withAnimation(.easeOut(duration: accessibilityReduceMotion ? 0.2 : 0.35)) {
            jumpFadeOpacity = 0
        } completion: {
            if jumpFadeOpacity == 0 { jumpFadeItem = nil }
        }
    }
    #endif

    private func actionCallbacks(for item: PlexItem) -> HomeCinematicHeroCallbacks {
        var callbacks = HomeCinematicHeroCallbacks(
            pauseRotation: pauseHeroRotation,
            restartRotation: restartHeroRotation,
            showPrevious: showPreviousHero,
            showNext: showNextHero
        )
        #if os(iOS)
        if let contextMenuActions {
            let previewSize = heroContextMenuPreviewSize
            callbacks.withContextMenu = { button in
                AnyView(
                    button
                        .background(
                            HeroButtonContextMenuInteraction(
                                actions: { contextMenuActions(item) },
                                previewSize: previewSize,
                                preview: { AnyView(heroContextMenuPreview(for: item)) }
                            )
                        )
                        .accessibilityActions {
                            HomeItemMenuButtons(actions: contextMenuActions(item))
                        }
                )
            }
        }
        #elseif os(macOS)
        // A Mac menu has no lift preview, so SwiftUI's own menu is fine here.
        if let macContextMenuContent {
            callbacks.withContextMenu = { button in
                AnyView(button.contextMenu { macContextMenuContent(item).duskMenuItemIcons() })
            }
        } else if let contextMenuActions {
            callbacks.withContextMenu = { button in
                AnyView(
                    button.contextMenu {
                        HomeItemMenuButtons(actions: contextMenuActions(item))
                            .labelStyle(.titleAndIcon)
                    }
                )
            }
        }
        #endif
        return callbacks
    }

    private static var initialHeroIndex: Int {
        #if DEBUG
        ScreenshotMode.heroIndex ?? 0
        #else
        0
        #endif
    }

    private var resolvedHeroIndex: Int {
        guard !items.isEmpty else { return 0 }
        return min(currentHeroIndex, items.count - 1)
    }

    private var heroItemIDs: [String] {
        items.map(\.id.storageKey)
    }

    private var visibleItemKey: String? {
        items.isEmpty ? nil : items[resolvedHeroIndex].id.storageKey
    }

    private func pixelAlignedLength(_ length: CGFloat) -> CGFloat {
        let scale = displayScale
        guard scale > 0, length.isFinite else { return length }
        return (length * scale).rounded(.up) / scale
    }

    private var heroRotationDuration: TimeInterval {
        Double(heroRotationInterval) / 1_000_000_000
    }

    private var heroRotationSeed: String {
        [
            heroItemIDs.joined(separator: "|"),
            String(heroRotationRevision),
            String(accessibilityReduceMotion),
            String(scenePhase == .active),
            String(isHeroRotationPaused),
            String(autoRotates),
            String(isHeroDragging),
            String(isRotationSuspended),
        ].joined(separator: "::")
    }

    /// tvOS: rotation pages by moving focus between the pages' play buttons,
    /// so it only runs while one of them has focus. That also holds it while
    /// Home is behind another tab or the player, and keeps it from paging a
    /// hero the user is not looking at.
    private var isRotationSuspended: Bool {
        #if os(tvOS)
        focusedItemKey == nil
        #else
        false
        #endif
    }

    private var backgroundHeroIndex: Int? {
        if isHeroDragActive {
            return heroDragTargetIndex
        }

        return transitioningHeroIndex
    }

    private var isHeroDragActive: Bool {
        isHeroDragging || heroDragTargetIndex != nil || heroDragOffset != 0
    }

    private var isHeroDragSettling: Bool {
        heroDragTargetIndex != nil && !isHeroDragging
    }

    private func heroSlide(
        item: PlexItem,
        heroHeight: CGFloat,
        backdropWidth: Int,
        backdropHeight: Int,
        contentWidth: CGFloat,
        reservesPagerSpace: Bool,
        showsActions: Bool = true
    ) -> some View {
        let metadata = viewModel.heroMetadata(for: item)

        return ZStack(alignment: .bottomLeading) {
            ZStack {
                heroBackdrop(
                    for: item,
                    width: backdropWidth,
                    height: backdropHeight,
                    heroHeight: heroHeight
                )

                #if os(macOS)
                MacHomeHeroScrim()
                #else
                DuskHeroBackdropOverlay(style: layout.backdropOverlayStyle)
                #endif
            }
            #if os(macOS)
            // The art itself fades out at the bottom, onto the page
            // background behind it, in either appearance (a dark scrim fading
            // to a light page read as a grey band).
            .mask { MacHomeHeroFadeMask(fadeHeight: HomeCinematicHeroLayout.macBottomFadeHeight) }
            #endif
            .duskHeroBackdropBottomFade(layout.backdropBottomFadeStyle)

            #if os(iOS)
            if let detailsAction {
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture {
                        restartHeroRotation()
                        detailsAction(item)
                    }
                    .heroContextMenu(contextMenuActions.map { actions in { actions(item) } }) {
                        heroContextMenuPreview(for: item)
                    }
                    .accessibilityHidden(true)
            }
            #elseif os(macOS)
            if let detailsAction {
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture {
                        restartHeroRotation()
                        detailsAction(item)
                    }
                    .contextMenu {
                        Group {
                            if let macContextMenuContent {
                                macContextMenuContent(item)
                            } else if let contextMenuActions {
                                HomeItemMenuButtons(actions: contextMenuActions(item))
                            }
                        }
                        .duskMenuItemIcons()
                    }
                    .accessibilityHidden(true)
            }
            #endif

            VStack(alignment: heroContentHorizontalAlignment, spacing: 16) {
                VStack(alignment: heroContentHorizontalAlignment, spacing: heroTitleBlockSpacing(for: item)) {
                    heroTitle(for: item, contentWidth: contentWidth, heroHeight: heroHeight)

                    if let episodeTitle = viewModel.heroEpisodeTitle(for: item) {
                        Text(episodeTitle)
                            .font(layout.episodeTitleFont)
                            .foregroundStyle(Color.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(heroTextAlignment)
                            .frame(maxWidth: contentWidth, alignment: heroContentFrameAlignment)
                    }

                    if !metadata.isEmpty {
                        Text(metadata.joined(separator: " · "))
                            .font(layout.metadataFont)
                            .foregroundStyle(Color.primary.opacity(0.78))
                            .lineLimit(2)
                            .multilineTextAlignment(heroTextAlignment)
                            .frame(maxWidth: contentWidth, alignment: heroContentFrameAlignment)
                    }
                }

                if showsHeroSummary, let summary = viewModel.heroSummary(for: item) {
                    Text(summary)
                        .font(layout.summaryFont)
                        .foregroundStyle(Color.primary.opacity(0.76))
                        .lineLimit(summaryLineLimit(heroHeight: heroHeight))
                        .lineSpacing(layout.summaryLineSpacing)
                        .multilineTextAlignment(heroTextAlignment)
                        .frame(maxWidth: contentWidth, alignment: heroContentFrameAlignment)
                }

                Group {
                    #if os(tvOS)
                    if showsActions {
                        heroActions(for: item)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                heroActionsHeight = height
                            }
                    } else {
                        Color.clear.frame(height: heroActionsHeight)
                    }
                    #else
                    heroActions(for: item)
                    #endif
                }
                .padding(.top, layout.actionsTopPadding)
                .padding(.bottom, layout.actionsBottomPadding)
            }
            #if os(macOS)
            // The hero is a dark context in both appearances: white text on
            // the scrim, the dark-glass button.
            .environment(\.colorScheme, .dark)
            #endif
            .padding(.leading, contentLeadingInset + layout.contentHorizontalPadding)
            .padding(.trailing, contentTrailingInset + layout.contentHorizontalPadding)
            .padding(.bottom, reservesPagerSpace ? layout.contentBottomPaddingWithPager : layout.contentBottomPaddingWithoutPager)
            .padding(.top, topInset + layout.contentTopPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: heroContentBlockAlignment)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    #if os(macOS)
    /// Previous/next chevrons that appear while the pointer is over the hero,
    /// like the Mac TV app's carousels. Only with more than one page.
    @ViewBuilder
    private var macPageChevrons: some View {
        if items.count > 1 {
            HomeHeroMacPageChevrons(
                isVisible: isPointerOverHero,
                inset: MacUILayout.contentInset,
                bottomPadding: layout.pagerBottomPadding - 9,
                onPrevious: showPreviousHero,
                onNext: showNextHero
            )
        }
    }

    /// The current page's backdrop (with its scrim and bottom fade) behind
    /// the hero, extended under the sidebar by the system.
    @ViewBuilder
    private func macSidebarExtension(
        resolvedIndex: Int,
        heroHeight: CGFloat,
        backdropWidth: Int,
        backdropHeight: Int
    ) -> some View {
        if items.indices.contains(resolvedIndex) {
            let item = items[resolvedIndex]
            ZStack {
                heroBackdrop(
                    for: item,
                    width: backdropWidth,
                    height: backdropHeight,
                    heroHeight: heroHeight
                )
                MacHomeHeroScrim(includesLeadingShade: false)
            }
            .mask { MacHomeHeroFadeMask(fadeHeight: HomeCinematicHeroLayout.macBottomFadeHeight) }
            .frame(height: heroHeight)
            .id(item.id.storageKey)
            .transition(.opacity)
            .animation(.easeInOut(duration: heroPressTransitionDuration), value: item.id.storageKey)
            .backgroundExtensionEffect()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
    #endif

    private func summaryLineLimit(heroHeight: CGFloat) -> Int {
        #if os(macOS)
        heroHeight < 480 ? 2 : 3
        #else
        layout.summaryLineLimit
        #endif
    }

    #if os(macOS)
    static let macCoordinateSpace = "DuskMacHomeHero"

    /// At most `MacUILayout.heroMaxHeightFraction` of the window (the hero
    /// runs under the toolbar, so that is the container plus `topInset`) and
    /// never taller than half its width, so the first shelf always shows.
    private var macHeroHeight: CGFloat {
        let windowHeight = containerSize.height + topInset
        let height = min(
            windowHeight * MacUILayout.heroMaxHeightFraction,
            containerSize.width * 0.5,
            layout.heroHeightRange.upperBound
        )
        return max(height, layout.heroHeightRange.lowerBound)
    }

    /// The Mac's right-click menu for each page, on the artwork and the button.
    func macContextMenu(_ content: @escaping (PlexItem) -> AnyView) -> Self {
        var copy = self
        copy.macContextMenuContent = content
        return copy
    }
    #endif

    private func heroTitleBlockSpacing(for item: PlexItem) -> CGFloat {
        item.type == .movie ? layout.titleBlockSpacingMovie : layout.titleBlockSpacingOther
    }

    private var showsHeroSummary: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom != .phone
        #else
        true
        #endif
    }

    // iPhone centers the entire hero block — title logo, text, action button, and
    // pager — while iPad and tvOS keep the leading-aligned cinematic layout.
    private var centersHeroContent: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var heroContentHorizontalAlignment: HorizontalAlignment {
        centersHeroContent ? .center : .leading
    }

    private var heroContentFrameAlignment: Alignment {
        centersHeroContent ? .center : .leading
    }

    private var heroContentBlockAlignment: Alignment {
        centersHeroContent ? .bottom : .bottomLeading
    }

    private var heroTextAlignment: TextAlignment {
        centersHeroContent ? .center : .leading
    }

    @ViewBuilder
    private func heroTitle(for item: PlexItem, contentWidth: CGFloat, heroHeight: CGFloat) -> some View {
        let logoWidth = min(contentWidth, layout.titleLogoMaxWidth)
        #if os(macOS)
        // A short window gets a smaller logo, so the text block still fits.
        let logoHeight = min(layout.titleLogoMaxHeight, (heroHeight * 0.2).rounded())
        #else
        let logoHeight = layout.titleLogoMaxHeight
        #endif
        if item.clearLogo != nil {
            heroTitleArtwork(for: item, width: logoWidth, height: logoHeight)
        } else {
            heroTitleFallback(for: item)
        }
    }

    @ViewBuilder
    private func heroTitleArtwork(for item: PlexItem, width: CGFloat, height: CGFloat) -> some View {
        if let image = preloadedHeroTitleImages[item.id.storageKey] {
            Image(platformImage: image)
                .resizable()
                .scaledToFit()
                .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
                .frame(width: width, height: height, alignment: heroContentBlockAlignment)
        } else if failedHeroTitleImageKeys.contains(item.id.storageKey) {
            heroTitleFallback(for: item)
        } else {
            Color.clear
                .frame(width: width, height: height, alignment: heroContentBlockAlignment)
        }
    }

    private func heroTitleFallback(for item: PlexItem) -> some View {
        // When a show/movie has no title-logo artwork, the title renders as text.
        // Force it white (rather than `Color.primary`) so it always reads against
        // the dark hero backdrop, even in Light mode. Only this fallback title is
        // affected — episode title, metadata, and summary keep `Color.primary`.
        Text(viewModel.displayTitle(for: item))
            .font(.system(size: layout.titleFontSize, weight: .heavy, design: .rounded))
            .foregroundStyle(Color.white)
            .lineLimit(3)
            .minimumScaleFactor(0.7)
            .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
            .multilineTextAlignment(heroTextAlignment)
            .frame(maxWidth: .infinity, alignment: heroContentFrameAlignment)
    }

    @ViewBuilder
    private func heroActions(for item: PlexItem) -> some View {
        let callbacks = actionCallbacks(for: item)
        let primary = primaryAction(item, callbacks)
        let secondary = secondaryAction?(item, callbacks)

        if let secondary {
            HStack(spacing: 16) {
                primary
                secondary
            }
        } else {
            primary
        }
    }

    #if os(iOS)
    /// The lifted card for the long-press menu: the page's backdrop with its
    /// title logo and episode line, like a Continue Watching tile. UIKit
    /// rounds and shadows it and morphs it out of the pressed button.
    private var heroContextMenuPreviewSize: CGSize {
        let width: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 480 : 340
        return CGSize(width: width, height: (width * 9 / 16).rounded())
    }

    private func heroContextMenuPreview(for item: PlexItem) -> some View {
        let width = heroContextMenuPreviewSize.width
        let height = heroContextMenuPreviewSize.height
        let key = item.id.storageKey
        let subtitle = viewModel.heroEpisodeTitle(for: item)
        let metadata = viewModel.heroMetadata(for: item).joined(separator: " · ")

        return ZStack(alignment: .bottomLeading) {
            Color.duskSurface

            if let backdrop = preloadedHeroBackdropImages[key] {
                Image(uiImage: backdrop)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height, alignment: heroBackdropImageAlignment)
                    .clipped()
            }

            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.35), .black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 6) {
                if let logo = preloadedHeroTitleImages[key] {
                    Image(uiImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: width * 0.5, maxHeight: height * 0.3, alignment: .bottomLeading)
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                } else {
                    Text(viewModel.displayTitle(for: item))
                        .font(.title3.weight(.heavy))
                        .lineLimit(2)
                }

                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }

                if !metadata.isEmpty {
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(16)
        }
        .frame(width: width, height: height)
        .environment(\.colorScheme, .dark)
    }
    #endif

    @ViewBuilder
    private func heroPager(currentIndex: Int) -> some View {
        #if os(macOS)
        // Dots carry no rotation progress, so no 20 Hz timeline.
        macPagerDots(currentIndex: currentIndex)
            // The dots' hit padding, so the first dot lines up with the text.
            .padding(.horizontal, -4)
        #else
        if autoRotates {
            TimelineView(.periodic(from: .now, by: 0.05)) { timeline in
                pagerContent(currentIndex: currentIndex, date: timeline.date)
            }
        } else {
            pagerContent(currentIndex: currentIndex, date: nil)
        }
        #endif
    }

    #if os(macOS)
    /// Plain page dots, every page shown and clickable, the current one
    /// white (macOS page controls, not iOS's shrinking pill window).
    private func macPagerDots(currentIndex: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { index in
                Button {
                    selectHero(at: index)
                } label: {
                    Circle()
                        .fill(Color.white.opacity(index == currentIndex ? 0.95 : 0.4))
                        .frame(width: 7, height: 7)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(MacHeroPagerPillHover(title: viewModel.displayTitle(for: items[index])))
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .animation(.easeOut(duration: 0.2), value: currentIndex)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Continue Watching"))
        .accessibilityValue(
            Text("\(viewModel.displayTitle(for: items[currentIndex])), \(currentIndex + 1) of \(items.count)")
        )
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                selectHero(at: (currentIndex + 1) % items.count)
            case .decrement:
                selectHero(at: (currentIndex - 1 + items.count) % items.count)
            @unknown default:
                break
            }
        }
    }
    #endif

    @ViewBuilder
    private func pagerContent(currentIndex: Int, date: Date?) -> some View {
        let window = HomeHeroPagerWindow(
            count: items.count,
            currentIndex: currentIndex,
            maxVisible: layout.pagerMaxVisibleItems
        )

        let pills = HStack(spacing: 8) {
            ForEach(Array(window.range), id: \.self) { index in
                #if os(tvOS)
                HomeHeroPagerPill(
                    isActive: index == currentIndex,
                    progress: pagerProgress(for: index, currentIndex: currentIndex, date: date)
                )
                .scaleEffect(window.scale(for: index))
                .accessibilityHidden(true)
                #else
                Button {
                    selectHero(at: index)
                } label: {
                    HomeHeroPagerPill(
                        isActive: index == currentIndex,
                        progress: pagerProgress(for: index, currentIndex: currentIndex, date: date)
                    )
                    .scaleEffect(window.scale(for: index))
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .modifier(MacHeroPagerPillHover(title: viewModel.displayTitle(for: items[index])))
                #endif
                .transition(.scale.combined(with: .opacity))
                #endif
            }
        }
        .animation(.snappy(duration: 0.3), value: window.range)

        #if os(tvOS)
        pills
        #else
        // One adjustable element, like UIPageControl, instead of a button per
        // item that the window may be hiding.
        pills
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Continue Watching"))
            .accessibilityValue(
                Text("\(viewModel.displayTitle(for: items[currentIndex])), \(currentIndex + 1) of \(items.count)")
            )
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    selectHero(at: (currentIndex + 1) % items.count)
                case .decrement:
                    selectHero(at: (currentIndex - 1 + items.count) % items.count)
                @unknown default:
                    break
                }
            }
        #endif
    }

    private func pagerProgress(for index: Int, currentIndex: Int, date: Date?) -> Double {
        guard index == currentIndex else { return 0 }
        guard autoRotates, let date else { return 1 }
        return heroRotationProgress(at: date)
    }

    private func rotateHeroIfNeeded() async {
        #if DEBUG
        // Screenshot mode holds the first slide so captures are deterministic.
        if ScreenshotMode.isActive { return }
        #endif
        guard autoRotates,
              heroItemIDs.count > 1,
              !accessibilityReduceMotion,
              scenePhase == .active,
              !isHeroRotationPaused,
              !isRotationSuspended else {
            return
        }

        do {
            try await Task.sleep(nanoseconds: remainingHeroRotationNanoseconds(at: Date()))
        } catch {
            return
        }

        guard !Task.isCancelled else { return }

        await MainActor.run {
            guard autoRotates,
                  heroItemIDs.count > 1,
                  !isHeroRotationPaused,
                  !isRotationSuspended else { return }

            #if os(tvOS)
            let index = focusedItemKey.flatMap { heroItemIDs.firstIndex(of: $0) } ?? currentHeroIndex
            onFocusItem?(items[(index + 1) % items.count])
            #else
            moveHero(
                to: (currentHeroIndex + 1) % heroItemIDs.count,
                direction: .forward,
                duration: 0.42
            )
            #endif
            restartHeroRotation()
        }
    }

    private func selectHero(at index: Int) {
        guard index != currentHeroIndex else {
            restartHeroRotation()
            return
        }

        restartHeroRotation()
        moveHero(
            to: index,
            direction: resolvedHeroTransitionDirection(
                from: currentHeroIndex,
                to: index,
                itemCount: heroItemIDs.count
            ),
            duration: heroPressTransitionDuration
        )
    }

    private func restartHeroRotation() {
        guard autoRotates else { return }
        // Suspended, a fresh interval waits at the start until focus is back.
        isHeroRotationPaused = isRotationSuspended
        pausedHeroRotationProgress = isRotationSuspended ? 0 : nil
        heroRotationStartedAt = Date()
        heroRotationRevision += 1
    }

    private func pauseHeroRotation() {
        guard autoRotates, !isHeroRotationPaused else { return }
        isHeroRotationPaused = true
        pausedHeroRotationProgress = heroRotationProgress(at: Date())
        heroRotationRevision += 1
    }

    #if !os(tvOS)
    private func handleHeroDragChanged(_ value: DragGesture.Value) {
        handleHeroHorizontalNavigationChanged(
            horizontalOffset: value.translation.width,
            verticalOffset: value.translation.height
        )
    }

    private func handleHeroDragEnded(_ value: DragGesture.Value, heroWidth: CGFloat) {
        handleHeroHorizontalNavigationEnded(
            horizontalOffset: value.translation.width,
            verticalOffset: value.translation.height,
            predictedHorizontalOffset: value.predictedEndTranslation.width,
            heroWidth: heroWidth
        )
    }

    private func handleHeroHorizontalNavigationChanged(
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat = 0
    ) {
        guard supportsDragNavigation,
              heroItemIDs.count > 1,
              transitioningHeroIndex == nil,
              !isHeroDragSettling else {
            return
        }

        guard abs(horizontalOffset) > abs(verticalOffset),
              abs(horizontalOffset) > 8 else {
            return
        }

        if !isHeroDragging {
            pauseHeroRotation()
            isHeroDragging = true
        }

        heroDragTargetIndex = adjacentHeroIndex(forDragOffset: horizontalOffset)
        heroDragOffset = resolvedHeroDragOffset(for: horizontalOffset)
    }

    private func handleHeroIndirectScrollChanged(horizontalOffset: CGFloat) {
        handleHeroHorizontalNavigationChanged(horizontalOffset: horizontalOffset)
    }

    #if os(iOS)
    /// Trackpad or scroll-wheel paging; see `HeroIndirectScrollGesture`.
    private func heroIndirectScrollGesture<Kind: HeroScrollKind>(
        _ kind: Kind.Type,
        heroWidth: CGFloat
    ) -> HeroIndirectScrollGesture<Kind> {
        HeroIndirectScrollGesture<Kind>(
            isEnabled: supportsDragNavigation && heroItemIDs.count > 1,
            onChanged: { horizontalOffset in
                handleHeroIndirectScrollChanged(horizontalOffset: horizontalOffset)
            },
            onEnded: { horizontalOffset, predictedHorizontalOffset in
                handleHeroIndirectScrollEnded(
                    horizontalOffset: horizontalOffset,
                    predictedHorizontalOffset: predictedHorizontalOffset,
                    heroWidth: heroWidth,
                    isDiscrete: Kind.scrollTypes == .discrete
                )
            }
        )
    }
    #endif

    private func handleHeroIndirectScrollEnded(
        horizontalOffset: CGFloat,
        predictedHorizontalOffset: CGFloat,
        heroWidth: CGFloat,
        isDiscrete: Bool = false
    ) {
        // Any horizontal wheel burst turns the page, even a single notch that
        // moved less than the drag's 8 pt start. A trackpad swipe has to
        // travel (or fling) a bit further.
        if isDiscrete, !isHeroDragActive {
            guard transitioningHeroIndex == nil,
                  !isHeroDragSettling,
                  abs(horizontalOffset) >= 1,
                  let targetIndex = adjacentHeroIndex(forDragOffset: horizontalOffset) else {
                return
            }
            selectHero(at: targetIndex)
            return
        }

        let commitThreshold = isDiscrete ? 1 : max(min(heroWidth * 0.08, 96), 32)

        handleHeroHorizontalNavigationEnded(
            horizontalOffset: horizontalOffset,
            predictedHorizontalOffset: predictedHorizontalOffset,
            heroWidth: heroWidth,
            commitThreshold: commitThreshold
        )
    }

    private func handleHeroHorizontalNavigationEnded(
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat = 0,
        predictedHorizontalOffset: CGFloat,
        heroWidth: CGFloat,
        commitThreshold: CGFloat? = nil
    ) {
        guard supportsDragNavigation, isHeroDragActive else { return }

        let horizontalDrag = abs(horizontalOffset) > abs(verticalOffset)
        let projectedOffset = resolvedHeroDragOffset(for: predictedHorizontalOffset)
        let commitThreshold = commitThreshold ?? max(heroWidth * 0.18, 56)
        let targetIndex = heroDragTargetIndex

        if horizontalDrag,
           let targetIndex,
           abs(projectedOffset) >= commitThreshold {
            completeHeroDragTransition(to: targetIndex, heroWidth: heroWidth)
        } else {
            cancelHeroDragTransition()
        }
    }
    #endif

    #if os(tvOS)
    private func handleHeroMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .down:
            onMoveDown?()
        case .left, .right:
            // Moving to the neighbouring page's play button is the focus
            // engine's (`tvPages`). Past either end page it has nothing to
            // move to, so the move wraps around to the other end here.
            //
            // It fires for every move, also after the engine has moved focus
            // for it, and `focusedItemKey` may or may not have caught up with
            // that move yet (both measured). The page on screen has not: the
            // scroll to a new page has only just started. So only a move on
            // an end page that is also at rest on screen wraps.
            restartHeroRotation()
            guard items.count > 1,
                  let focusedItemKey,
                  let focusedIndex = heroItemIDs.firstIndex(of: focusedItemKey) else { return }
            let lastIndex = items.count - 1
            if direction == .right, focusedIndex == lastIndex, currentHeroIndex == lastIndex {
                onFocusItem?(items[0])
            } else if direction == .left, focusedIndex == 0, currentHeroIndex == 0 {
                onFocusItem?(items[lastIndex])
            }
        case .up:
            // The focus engine's: the tab bar.
            break
        @unknown default:
            break
        }
    }
    #endif

    private func showPreviousHero() {
        guard heroItemIDs.count > 1 else { return }

        let heroCount = heroItemIDs.count
        restartHeroRotation()
        moveHero(
            to: (currentHeroIndex - 1 + heroCount) % heroCount,
            direction: .backward,
            duration: heroPressTransitionDuration
        )
    }

    private func showNextHero() {
        guard heroItemIDs.count > 1 else { return }

        let heroCount = heroItemIDs.count
        restartHeroRotation()
        moveHero(
            to: (currentHeroIndex + 1) % heroCount,
            direction: .forward,
            duration: heroPressTransitionDuration
        )
    }

    private func heroRotationProgress(at date: Date) -> Double {
        if let pausedHeroRotationProgress {
            return max(0, min(pausedHeroRotationProgress, 1))
        }

        let elapsed = date.timeIntervalSince(heroRotationStartedAt)
        guard heroRotationDuration > 0 else { return 0 }
        return max(0, min(elapsed / heroRotationDuration, 1))
    }

    private func remainingHeroRotationNanoseconds(at date: Date) -> UInt64 {
        let progress = heroRotationProgress(at: date)
        let remaining = max(0, 1 - progress) * heroRotationDuration
        return UInt64((remaining * 1_000_000_000).rounded())
    }

    private func resetHeroSlideState() {
        heroSlideRevision += 1
        pendingHeroTransition = nil
        transitioningHeroIndex = nil
        heroSlideProgress = 1
    }

    private func resetHeroDragState() {
        heroDragRevision += 1
        heroDragOffset = 0
        heroDragTargetIndex = nil
        isHeroDragging = false
    }

    private func resetHeroSelection(restartRotation: Bool = true) {
        resetHeroSlideState()
        resetHeroDragState()
        currentHeroIndex = Self.initialHeroIndex
        #if os(tvOS)
        tvRestingPage = 0
        tvPagePosition.scrollTo(edge: .leading)
        #endif

        if restartRotation {
            restartHeroRotation()
        }
    }

    private func heroBackdropPrefetchSeed(width: Int, height: Int) -> String {
        [
            items.map(\.id.storageKey).joined(separator: "|"),
            "\(width)x\(height)"
        ].joined(separator: "::")
    }

    private func heroTitlePrefetchSeed(width: Int, height: Int) -> String {
        [
            items.map { "\($0.id.storageKey):\($0.clearLogo ?? "")" }.joined(separator: "|"),
            "\(width)x\(height)"
        ].joined(separator: "::")
    }

    private func preloadHeroBackdropImages(width: Int, height: Int) async {
        let backdropRequests = items.compactMap { item -> (String, URL)? in
            guard let url = viewModel.heroBackgroundURL(for: item, width: width, height: height) else {
                return nil
            }

            return (item.id.storageKey, url)
        }

        let validKeys = Set(items.map(\.id.storageKey))
        await MainActor.run {
            preloadedHeroBackdropImages = preloadedHeroBackdropImages.filter { validKeys.contains($0.key) }
        }

        guard !backdropRequests.isEmpty else { return }

        await withTaskGroup(of: HeroImageLoad.self) { group in
            for (ratingKey, url) in backdropRequests {
                group.addTask {
                    var image = try? await DuskImageLoader.shared.image(for: url, using: plexService)
                    #if os(tvOS)
                    // Decode the full-screen backdrop here, off the main
                    // thread. Left lazy, it decodes on the first frame of
                    // the slide that reveals it and stalls the animation
                    // right as the press lands.
                    if let loaded = image {
                        image = await loaded.byPreparingForDisplay() ?? loaded
                    }
                    #endif
                    return HeroImageLoad(ratingKey: ratingKey, image: image)
                }
            }

            for await load in group {
                guard let image = load.image else { continue }
                let ratingKey = load.ratingKey

                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    guard validKeys.contains(ratingKey) else { return }
                    preloadedHeroBackdropImages[ratingKey] = image
                }
            }
        }
    }

    private func preloadHeroTitleImages(width: Int, height: Int) async {
        let titleRequests = items.compactMap { item -> (String, URL)? in
            guard let url = viewModel.heroTitleLogoURL(for: item, width: width, height: height) else {
                return nil
            }

            return (item.id.storageKey, url)
        }

        let validKeys = Set(items.map(\.id.storageKey))
        let requestedKeys = Set(titleRequests.map(\.0))

        await MainActor.run {
            preloadedHeroTitleImages = preloadedHeroTitleImages.filter { validKeys.contains($0.key) }
            failedHeroTitleImageKeys = failedHeroTitleImageKeys
                .filter { validKeys.contains($0) && requestedKeys.contains($0) }
        }

        guard !titleRequests.isEmpty else { return }

        await withTaskGroup(of: HeroImageLoad.self) { group in
            for (ratingKey, url) in titleRequests {
                group.addTask {
                    let image = try? await DuskImageLoader.shared.image(for: url, using: plexService)
                    return HeroImageLoad(ratingKey: ratingKey, image: image)
                }
            }

            for await load in group {
                let ratingKey = load.ratingKey
                let image = load.image
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    guard validKeys.contains(ratingKey) else { return }

                    if let image {
                        preloadedHeroTitleImages[ratingKey] = image
                        failedHeroTitleImageKeys.remove(ratingKey)
                    } else {
                        failedHeroTitleImageKeys.insert(ratingKey)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func heroBackdrop(
        for item: PlexItem,
        width: Int,
        height: Int,
        heroHeight: CGFloat
    ) -> some View {
        let imageAlignment = heroBackdropImageAlignment

        if let image = preloadedHeroBackdropImages[item.id.storageKey] {
            GeometryReader { geometry in
                ZStack {
                    Color.duskSurface

                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: imageAlignment)
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height,
                            alignment: imageAlignment
                        )
                        .clipped()
                }
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: imageAlignment
                )
                .clipped()
            }
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)
        } else {
            DetailHeroBackdrop(
                imageURL: viewModel.heroBackgroundURL(
                    for: item,
                    width: width,
                    height: height
                ),
                height: heroHeight,
                imageAlignment: imageAlignment
            )
        }
    }

    private var heroBackdropImageAlignment: Alignment {
        layout.backdropImageAlignment
    }

    private func moveHero(to index: Int, direction: HeroTransitionDirection, duration: TimeInterval) {
        guard items.indices.contains(index), index != currentHeroIndex else { return }

        if transitioningHeroIndex != nil {
            #if os(tvOS)
            // A remote press never waits for the slide in flight: land it where
            // it is headed and start the new one now. Queueing made quick
            // presses sit behind the whole previous slide (and dropped every
            // press past the first queued one). With the front-loaded curve the
            // in-flight slide is nearly settled by the time a second press can
            // land, so finishing it in place is a small, fast jump.
            resetHeroSlideState()
            #else
            pendingHeroTransition = PendingHeroTransition(
                index: index,
                direction: direction,
                duration: duration
            )
            return
            #endif
        }

        resetHeroDragState()

        let previousIndex = currentHeroIndex
        let slideRevision = heroSlideRevision + 1

        heroSlideRevision = slideRevision
        heroTransitionDirection = direction
        transitioningHeroIndex = previousIndex
        currentHeroIndex = index
        heroSlideProgress = 0

        Task { @MainActor in
            // Give SwiftUI a transaction to mount the incoming slide at its
            // off-screen offset before animating it. Without this boundary tvOS
            // can coalesce progress 0 and 1, making the artwork appear to pop in
            // from behind the outgoing slide.
            await Task.yield()
            guard heroSlideRevision == slideRevision else { return }

            withAnimation(heroSlideAnimation(duration: duration)) {
                heroSlideProgress = 1
            }

            try? await Task.sleep(
                nanoseconds: UInt64((duration * 1_000_000_000).rounded())
            )

            guard heroSlideRevision == slideRevision else { return }
            let pendingTransition = pendingHeroTransition
            pendingHeroTransition = nil
            transitioningHeroIndex = nil
            heroSlideProgress = 1

            if let pendingTransition {
                moveHero(
                    to: pendingTransition.index,
                    direction: pendingTransition.direction,
                    duration: pendingTransition.duration
                )
            }
        }
    }

    private func heroSlideAnimation(duration: TimeInterval) -> Animation {
        #if os(tvOS)
        // Front-loaded ease-out: the slide is already moving fast on the first
        // frame after the press and spends its time settling. `easeInOut`
        // barely moves for its first ~100ms, which made clicks feel ignored.
        .timingCurve(0.16, 0.84, 0.3, 1, duration: duration)
        #else
        .easeInOut(duration: duration)
        #endif
    }

    private func heroSlideOffset(for role: HeroSlideRole, width: CGFloat) -> CGFloat {
        guard transitioningHeroIndex != nil else { return 0 }

        switch (heroTransitionDirection, role) {
        case (.forward, .outgoing):
            return -width * heroSlideProgress
        case (.forward, .incoming):
            return width * (1 - heroSlideProgress)
        case (.backward, .outgoing):
            return width * heroSlideProgress
        case (.backward, .incoming):
            return -width * (1 - heroSlideProgress)
        }
    }

    private func foregroundHeroOffset(width: CGFloat) -> CGFloat {
        if isHeroDragActive {
            return heroDragOffset
        }

        return heroSlideOffset(for: .incoming, width: width)
    }

    private func backgroundHeroOffset(width: CGFloat) -> CGFloat {
        if isHeroDragActive {
            guard let heroDragTargetIndex,
                  items.indices.contains(heroDragTargetIndex) else {
                return 0
            }

            if heroDragOffset < 0 {
                return width + heroDragOffset
            } else {
                return -width + heroDragOffset
            }
        }

        return heroSlideOffset(for: .outgoing, width: width)
    }

    private func adjacentHeroIndex(forDragOffset offset: CGFloat) -> Int? {
        guard heroItemIDs.count > 1 else { return nil }

        let heroCount = heroItemIDs.count

        if offset < 0 {
            return (currentHeroIndex + 1) % heroCount
        }

        if offset > 0 {
            return (currentHeroIndex - 1 + heroCount) % heroCount
        }

        return nil
    }

    private func resolvedHeroDragOffset(for rawOffset: CGFloat) -> CGFloat {
        guard rawOffset != 0 else { return 0 }

        guard adjacentHeroIndex(forDragOffset: rawOffset) != nil else {
            return rawOffset * 0.18
        }

        return rawOffset
    }

    private func completeHeroDragTransition(to index: Int, heroWidth: CGFloat) {
        guard heroWidth > 0 else {
            currentHeroIndex = index
            resetHeroDragState()
            restartHeroRotation()
            return
        }

        let dragRevision = heroDragRevision + 1
        let finalOffset = heroDragOffset < 0 ? -heroWidth : heroWidth
        let settleDuration = 0.24

        heroDragRevision = dragRevision
        isHeroDragging = false

        withAnimation(.easeOut(duration: settleDuration)) {
            heroDragOffset = finalOffset
        }

        Task {
            try? await Task.sleep(nanoseconds: UInt64((settleDuration * 1_000_000_000).rounded()))

            await MainActor.run {
                guard heroDragRevision == dragRevision else { return }
                currentHeroIndex = index
                resetHeroDragState()
                restartHeroRotation()
            }
        }
    }

    private func cancelHeroDragTransition() {
        let dragRevision = heroDragRevision + 1
        let settleDuration = 0.24

        heroDragRevision = dragRevision
        isHeroDragging = false

        withAnimation(.easeOut(duration: settleDuration)) {
            heroDragOffset = 0
        }

        Task {
            try? await Task.sleep(nanoseconds: UInt64((settleDuration * 1_000_000_000).rounded()))

            await MainActor.run {
                guard heroDragRevision == dragRevision else { return }
                resetHeroDragState()
                restartHeroRotation()
            }
        }
    }

    private func resolvedHeroTransitionDirection(
        from currentIndex: Int,
        to nextIndex: Int,
        itemCount: Int
    ) -> HeroTransitionDirection {
        guard itemCount > 1, currentIndex != nextIndex else { return .forward }

        let forwardDistance = nextIndex >= currentIndex
            ? nextIndex - currentIndex
            : itemCount - currentIndex + nextIndex
        let backwardDistance = currentIndex >= nextIndex
            ? currentIndex - nextIndex
            : currentIndex + itemCount - nextIndex

        return forwardDistance <= backwardDistance ? .forward : .backward
    }
}

/// One image's answer in the hero preload task groups; nil means it failed. A
/// named type built in one place on purpose: see `Result.capturing`.
private struct HeroImageLoad: Sendable {
    let ratingKey: String
    let image: PlatformImage?
}

private enum HeroTransitionDirection {
    case forward
    case backward
}

private struct PendingHeroTransition {
    let index: Int
    let direction: HeroTransitionDirection
    let duration: TimeInterval
}

private enum HeroSlideRole {
    case outgoing
    case incoming
}

#if os(iOS)
private protocol HeroScrollKind {
    static var scrollTypes: UIScrollTypeMask { get }
}

/// Trackpad and Magic Mouse swipes.
private enum HeroTrackpadScroll: HeroScrollKind {
    static var scrollTypes: UIScrollTypeMask { .continuous }
}

/// Scroll-wheel notches.
private enum HeroWheelScroll: HeroScrollKind {
    static var scrollTypes: UIScrollTypeMask { .discrete }
}

/// Pages the hero from a two-finger trackpad swipe or a horizontal scroll
/// wheel: on iPad with a trackpad or mouse, and in Dusk on the Mac.
///
/// The recognizer takes scroll events only (no touch types), so finger swipes
/// stay with the hero's `DragGesture`. As a SwiftUI gesture it sits on the
/// hero itself and takes part in SwiftUI's hit testing; a recognizer on a
/// `.background` platform view never got the scroll, because the hero content
/// in front of it was the hit view.
///
/// One swipe moves one page. UIKit ends a trackpad pan when the fingers lift
/// and does not hand the momentum that follows to the recognizer. A short
/// pause after each gesture keeps a trailing burst from turning a second page.
/// The translation follows the system's natural-scrolling setting.
///
/// The trackpad and the wheel each get their own recognizer (`Kind`), because
/// they need different commit distances and UIKit does not say which kind of
/// scroll a pan came from.
private struct HeroIndirectScrollGesture<Kind: HeroScrollKind>: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.allowedScrollTypesMask = Kind.scrollTypes
        recognizer.allowedTouchTypes = []
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        if recognizer.isEnabled != isEnabled {
            recognizer.isEnabled = isEnabled
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view)

        switch recognizer.state {
        case .began, .changed:
            onChanged(translation.x)
        case .ended:
            let velocity = recognizer.velocity(in: recognizer.view)
            context.coordinator.gestureDidEnd()
            onEnded(translation.x, translation.x + velocity.x * Coordinator.projectedVelocityDuration)
        case .cancelled, .failed:
            context.coordinator.gestureDidEnd()
            onEnded(translation.x, translation.x)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        static var projectedVelocityDuration: CGFloat { 0.18 }
        /// How long after a swipe a new scroll is taken as its tail.
        private static var restartDelay: TimeInterval { 0.35 }
        private var lastEndedAt: Date?

        func gestureDidEnd() {
            lastEndedAt = Date()
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }

            if let lastEndedAt, Date().timeIntervalSince(lastEndedAt) < Self.restartDelay {
                return false
            }

            // Mostly vertical scrolling belongs to the Home scroll view.
            var direction = pan.translation(in: pan.view)
            if direction == .zero {
                direction = pan.velocity(in: pan.view)
            }
            return abs(direction.x) > abs(direction.y)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif

#if os(iOS)
private extension View {
    /// Attaches the hero's long-press menu, when it has one, with its own
    /// preview card.
    @ViewBuilder
    func heroContextMenu<Preview: View>(
        _ actions: (() -> [HomeItemMenuAction])?,
        @ViewBuilder preview: () -> Preview
    ) -> some View {
        if let actions {
            contextMenu {
                HomeItemMenuButtons(actions: actions())
            } preview: {
                preview()
            }
        } else {
            self
        }
    }
}
#endif

#if os(iOS)
/// The long-press menu of a hero button, as a `UIContextMenuInteraction` on
/// the view hosting the button rather than SwiftUI's `.contextMenu`.
///
/// SwiftUI's menu makes UIKit snapshot its source for the press highlight and
/// the lift. On the glass button that snapshot is the hero the glass refracts
/// (a ghosted box); on the button's label it is drawn where the label sits
/// unpressed while the glass is in its pressed state, so the title and icon
/// jump mid-press. Here the highlight and dismissal previews are a clear
/// capsule over the button: UIKit never moves, hides or redraws the button,
/// whose glass keeps its own press feedback until the card grows out of it.
private struct HeroButtonContextMenuInteraction: UIViewRepresentable {
    let actions: () -> [HomeItemMenuAction]
    let previewSize: CGSize
    let preview: () -> AnyView

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        context.coordinator.anchor = view
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.previewSize = previewSize
        context.coordinator.preview = preview
        context.coordinator.installIfPossible()
    }

    static func dismantleUIView(_ uiView: AnchorView, coordinator: Coordinator) {
        coordinator.uninstall()
        uiView.coordinator = nil
    }

    final class AnchorView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.installIfPossible()
        }
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        weak var anchor: UIView?
        var actions: () -> [HomeItemMenuAction] = { [] }
        var previewSize: CGSize = .zero
        var preview: () -> AnyView = { AnyView(EmptyView()) }

        private weak var hostView: UIView?
        private var interaction: UIContextMenuInteraction?

        /// The interaction sits on the scroll view hosting the hero, where
        /// SwiftUI's own context menus live: SwiftUI content is no UIView, so
        /// a touch on the button hit-tests to that scroll view, never to the
        /// anchor (or its platform host) behind the button.
        func installIfPossible() {
            guard let anchor, let window = anchor.window else { return }
            var host: UIView = window
            var ancestor = anchor.superview
            while let view = ancestor {
                if view is UIScrollView {
                    host = view
                    break
                }
                ancestor = view.superview
            }
            guard hostView !== host else { return }
            uninstall()
            let interaction = UIContextMenuInteraction(delegate: self)
            host.addInteraction(interaction)
            hostView = host
            self.interaction = interaction
        }

        func uninstall() {
            if let interaction {
                hostView?.removeInteraction(interaction)
            }
            hostView = nil
            interaction = nil
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard let anchor, anchor.window != nil, let hostView = interaction.view else { return nil }
            let point = hostView.convert(location, to: anchor)
            guard capsulePath(in: anchor.bounds).contains(point) else { return nil }

            let actions = actions()
            guard !actions.isEmpty else { return nil }
            let previewSize = previewSize
            let preview = preview

            return UIContextMenuConfiguration(
                identifier: nil,
                previewProvider: {
                    let controller = UIHostingController(rootView: preview())
                    controller.view.backgroundColor = .clear
                    controller.preferredContentSize = previewSize
                    return controller
                },
                actionProvider: { _ in
                    UIMenu(children: actions.map { action in
                        UIAction(title: action.title, image: UIImage(systemName: action.systemImage)) { _ in
                            action.perform()
                        }
                    })
                }
            )
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configuration: UIContextMenuConfiguration,
            highlightPreviewForItemWithIdentifier identifier: any NSCopying
        ) -> UITargetedPreview? {
            clearPreview()
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configuration: UIContextMenuConfiguration,
            dismissalPreviewForItemWithIdentifier identifier: any NSCopying
        ) -> UITargetedPreview? {
            clearPreview()
        }

        /// The button's own shape, transparent and unshadowed: the card grows
        /// out of and shrinks back into the button with nothing drawn over it.
        private func clearPreview() -> UITargetedPreview? {
            guard let anchor, anchor.window != nil else { return nil }
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = capsulePath(in: anchor.bounds)
            parameters.shadowPath = UIBezierPath()
            return UITargetedPreview(view: anchor, parameters: parameters)
        }

        private func capsulePath(in rect: CGRect) -> UIBezierPath {
            UIBezierPath(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2)
        }
    }
}
#endif

#if os(macOS)
/// The hero's hover chevrons on the Mac: a pair of neutral glass circles at
/// the hero's bottom trailing corner, level with the page dots, only while
/// the pointer is over it. Not at the side edges: the title block starts at
/// the same inset as the left one would (it sat on the logo), and higher up
/// they covered faces in the art.
private struct HomeHeroMacPageChevrons: View {
    let isVisible: Bool
    let inset: CGFloat
    /// Lines the buttons' centres up with the page dots.
    let bottomPadding: CGFloat
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            chevron("chevron.left", label: "Previous", action: onPrevious)
            chevron("chevron.right", label: "Next", action: onNext)
        }
        .padding(.trailing, inset)
        .padding(.bottom, bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .environment(\.colorScheme, .dark)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeOut(duration: 0.18), value: isVisible)
    }

    private func chevron(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The Mac hero's scrim. Black, whatever the appearance, so the hero stays a
/// dark context: a light top for the toolbar, the leading side and the bottom
/// darkened under the text. The bottom fade onto the page is a mask
/// (`MacHomeHeroFadeMask`), not a colour.
private struct MacHomeHeroScrim: View {
    /// The leading shade behind the text; left out of the copy that extends
    /// under the sidebar, which would otherwise show as a dark smudge there.
    var includesLeadingShade = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.28), location: 0),
                    .init(color: .black.opacity(0.0), location: 0.2),
                    .init(color: .black.opacity(0.08), location: 0.42),
                    .init(color: .black.opacity(0.5), location: 0.72),
                    .init(color: .black.opacity(0.72), location: 0.9),
                    // Under the pager and the fade: on the light page the
                    // shade eases off, so the art dissolves into the page
                    // instead of a dark band turning grey.
                    .init(color: .black.opacity(colorScheme == .dark ? 0.78 : 0.3), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            if includesLeadingShade {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.62), location: 0),
                        .init(color: .black.opacity(0.36), location: 0.36),
                        .init(color: .black.opacity(0.08), location: 0.66),
                        .init(color: .black.opacity(0), location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
        .allowsHitTesting(false)
    }
}

/// Opaque down to the last `fadeHeight` points, which ease out to clear, so
/// the hero dissolves into whatever page background is behind it.
private struct MacHomeHeroFadeMask: View {
    let fadeHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.82), location: 0.25),
                    .init(color: .black.opacity(0.5), location: 0.5),
                    .init(color: .black.opacity(0.2), location: 0.75),
                    .init(color: .black.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: fadeHeight)
        }
    }
}

/// A pager pill under the pointer brightens and grows a little and names
/// its page in a tooltip.
private struct MacHeroPagerPillHover: ViewModifier {
    let title: String
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .scaleEffect(isHovered ? 1.2 : 1)
            .brightness(isHovered ? 0.15 : 0)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
            .help(title)
    }
}
#endif
