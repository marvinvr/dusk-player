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
    /// The page a jump left (`focusPage(at:)`), drawn over the hero while
    /// it fades out.
    @State private var jumpFadeItem: PlexItem?
    @State private var jumpFadeOpacity: Double = 0
    /// Height of a page's action row, so the fading page's text sits exactly
    /// where it did. It has no buttons of its own: they would be a second
    /// focus target bound to the same page.
    @State private var heroActionsHeight: CGFloat = 0
    #endif
    #if canImport(UIKit)
    @State private var preloadedHeroBackdropImages: [String: UIImage] = [:]
    @State private var preloadedHeroTitleImages: [String: UIImage] = [:]
    @State private var failedHeroTitleImageKeys: Set<String> = []
    #endif

    private let heroRotationInterval: UInt64 = 7_000_000_000

    /// Duration of a user-driven hero move (remote press, pager tap, chevron).
    /// tvOS is shorter: every Siri Remote click waits on this slide, so the
    /// iOS-paced 0.5s read as lag there.
    #if os(tvOS)
    private let heroPressTransitionDuration: TimeInterval = 0.32
    #else
    private let heroPressTransitionDuration: TimeInterval = 0.5
    #endif

    var body: some View {
        let resolvedIndex = resolvedHeroIndex
        let heroWidth = pixelAlignedLength(containerSize.width)
        let rawHeroHeight: CGFloat = layout.fillsContainerHeight
            // Full-bleed: the caller already sized `containerSize` to the whole
            // display, top safe area included, so adding `topInset` again would
            // push the hero past the bottom of the screen.
            ? containerSize.height
            : min(
                max(containerSize.height * layout.heroHeightFactor, layout.heroHeightRange.lowerBound),
                layout.heroHeightRange.upperBound,
                layout.maxHeightToWidthRatio.map { containerSize.width * $0 } ?? .infinity
            ) + topInset
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
        // An overlay, not a ZStack sibling: the pager must never size the
        // hero. As a sibling, a pager wider than the screen (one pill per
        // Continue Watching item) widened the whole ZStack and pushed the
        // centred title block and Play button off the right edge.
        .overlay(alignment: heroContentBlockAlignment) {
            if items.count > 1 {
                heroPager(currentIndex: resolvedIndex)
                    .padding(.leading, contentLeadingInset + layout.pagerHorizontalPadding)
                    .padding(.trailing, contentTrailingInset + layout.pagerHorizontalPadding)
                    .padding(.bottom, layout.pagerBottomPadding)
            }
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
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
                    .background(
                        HeroIndirectScrollNavigation(
                            isEnabled: supportsDragNavigation && heroItemIDs.count > 1,
                            onChanged: { horizontalOffset in
                                handleHeroIndirectScrollChanged(
                                    horizontalOffset: horizontalOffset
                                )
                            },
                            onEnded: { horizontalOffset, predictedHorizontalOffset in
                                handleHeroIndirectScrollEnded(
                                    horizontalOffset: horizontalOffset,
                                    predictedHorizontalOffset: predictedHorizontalOffset,
                                    heroWidth: heroWidth
                                )
                            }
                        )
                    )
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
    /// button goes to its neighbour a page away, and the focus engine scrolls
    /// it into view (snapped to whole pages by `HomeHeroTVPaging`). Clicks and
    /// touch-surface swipes are the engine's own, exactly as in any row of
    /// cards. The hero used to be a single slide with the only focusable item
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
        .scrollTargetBehavior(
            HomeHeroTVPaging(
                pageWidth: heroWidth,
                actionLeadingInset: contentLeadingInset + layout.contentHorizontalPadding
            )
        )
        .onScrollGeometryChange(for: Int.self) { geometry in
            guard heroWidth > 0 else { return 0 }
            return Int(((geometry.contentOffset.x + geometry.contentInsets.leading) / heroWidth).rounded())
        } action: { _, page in
            currentHeroIndex = min(max(page, 0), max(items.count - 1, 0))
        }
    }
    #endif

    private var actionCallbacks: HomeCinematicHeroCallbacks {
        HomeCinematicHeroCallbacks(
            pauseRotation: pauseHeroRotation,
            restartRotation: restartHeroRotation,
            showPrevious: showPreviousHero,
            showNext: showNextHero
        )
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

                DuskHeroBackdropOverlay(style: layout.backdropOverlayStyle)
            }
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
                    .accessibilityHidden(true)
            }
            #endif

            VStack(alignment: heroContentHorizontalAlignment, spacing: 16) {
                VStack(alignment: heroContentHorizontalAlignment, spacing: heroTitleBlockSpacing(for: item)) {
                    heroTitle(for: item, contentWidth: contentWidth)

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
                        .lineLimit(layout.summaryLineLimit)
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
            .padding(.leading, contentLeadingInset + layout.contentHorizontalPadding)
            .padding(.trailing, contentTrailingInset + layout.contentHorizontalPadding)
            .padding(.bottom, reservesPagerSpace ? layout.contentBottomPaddingWithPager : layout.contentBottomPaddingWithoutPager)
            .padding(.top, topInset + layout.contentTopPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: heroContentBlockAlignment)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
    private func heroTitle(for item: PlexItem, contentWidth: CGFloat) -> some View {
        let logoWidth = min(contentWidth, layout.titleLogoMaxWidth)
        let logoHeight = layout.titleLogoMaxHeight
        if item.clearLogo != nil {
            heroTitleArtwork(for: item, width: logoWidth, height: logoHeight)
        } else {
            heroTitleFallback(for: item)
        }
    }

    @ViewBuilder
    private func heroTitleArtwork(for item: PlexItem, width: CGFloat, height: CGFloat) -> some View {
        #if canImport(UIKit)
        if let image = preloadedHeroTitleImages[item.id.storageKey] {
            Image(uiImage: image)
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
        #else
        heroTitleFallback(for: item)
        #endif
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
        let primary = primaryAction(item, actionCallbacks)
        let secondary = secondaryAction?(item, actionCallbacks)

        if let secondary {
            HStack(spacing: 16) {
                primary
                secondary
            }
        } else {
            primary
        }
    }

    @ViewBuilder
    private func heroPager(currentIndex: Int) -> some View {
        if autoRotates {
            TimelineView(.periodic(from: .now, by: 0.05)) { timeline in
                pagerContent(currentIndex: currentIndex, date: timeline.date)
            }
        } else {
            pagerContent(currentIndex: currentIndex, date: nil)
        }
    }

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
            focusPage(at: (index + 1) % items.count)
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

    private func handleHeroIndirectScrollEnded(
        horizontalOffset: CGFloat,
        predictedHorizontalOffset: CGFloat,
        heroWidth: CGFloat
    ) {
        let commitThreshold = max(min(heroWidth * 0.08, 96), 32)

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
                focusPage(at: 0)
            } else if direction == .left, focusedIndex == 0, currentHeroIndex == 0 {
                focusPage(at: lastIndex)
            }
        case .up:
            // The focus engine's: the tab bar.
            break
        @unknown default:
            break
        }
    }

    /// Moves focus to a page's play button: rotation, and the wrap-around
    /// past either end.
    ///
    /// A neighbouring page is the focus engine's ordinary reveal-scroll. Any
    /// page further away (the wrap, rotation going back to the start) would
    /// make that scroll sweep across every full-screen page in between,
    /// which is what made the wrap stutter. So the page scroll jumps there
    /// first, unanimated, and the page left behind fades out on top. The
    /// target button is then already on screen when it takes focus, so the
    /// engine has nothing to scroll. Focus moves on the next turn of the run
    /// loop, after the jump has been laid out.
    private func focusPage(at index: Int) {
        guard items.indices.contains(index) else { return }
        let target = items[index]
        guard abs(index - currentHeroIndex) > 1, items.indices.contains(currentHeroIndex) else {
            onFocusItem?(target)
            return
        }

        jumpFadeItem = items[currentHeroIndex]
        jumpFadeOpacity = 1
        var jump = Transaction()
        jump.disablesAnimations = true
        withTransaction(jump) {
            tvPagePosition.scrollTo(x: CGFloat(index) * pixelAlignedLength(containerSize.width))
        }
        withAnimation(.easeOut(duration: accessibilityReduceMotion ? 0.2 : 0.35)) {
            jumpFadeOpacity = 0
        } completion: {
            if jumpFadeOpacity == 0 { jumpFadeItem = nil }
        }
        DispatchQueue.main.async {
            onFocusItem?(target)
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
        #if canImport(UIKit)
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

        await withTaskGroup(of: (String, UIImage?).self) { group in
            for (ratingKey, url) in backdropRequests {
                group.addTask {
                    do {
                        let image = try await DuskImageLoader.shared.image(for: url, using: plexService)
                        #if os(tvOS)
                        // Decode the full-screen backdrop here, off the main
                        // thread. Left lazy, it decodes on the first frame of
                        // the slide that reveals it and stalls the animation
                        // right as the press lands.
                        return (ratingKey, await image.byPreparingForDisplay() ?? image)
                        #else
                        return (ratingKey, image)
                        #endif
                    } catch {
                        return (ratingKey, nil)
                    }
                }
            }

            for await (ratingKey, image) in group {
                guard let image else { continue }

                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    guard validKeys.contains(ratingKey) else { return }
                    preloadedHeroBackdropImages[ratingKey] = image
                }
            }
        }
        #endif
    }

    private func preloadHeroTitleImages(width: Int, height: Int) async {
        #if canImport(UIKit)
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

        await withTaskGroup(of: (String, UIImage?, Bool).self) { group in
            for (ratingKey, url) in titleRequests {
                group.addTask {
                    do {
                        let image = try await DuskImageLoader.shared.image(for: url, using: plexService)
                        return (ratingKey, image, false)
                    } catch {
                        return (ratingKey, nil, true)
                    }
                }
            }

            for await (ratingKey, image, didFail) in group {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    guard validKeys.contains(ratingKey) else { return }

                    if let image {
                        preloadedHeroTitleImages[ratingKey] = image
                        failedHeroTitleImageKeys.remove(ratingKey)
                    } else if didFail {
                        failedHeroTitleImageKeys.insert(ratingKey)
                    }
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private func heroBackdrop(
        for item: PlexItem,
        width: Int,
        height: Int,
        heroHeight: CGFloat
    ) -> some View {
        let imageAlignment = heroBackdropImageAlignment

        #if canImport(UIKit)
        if let image = preloadedHeroBackdropImages[item.id.storageKey] {
            GeometryReader { geometry in
                ZStack {
                    Color.duskSurface

                    Image(uiImage: image)
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
        #else
        DetailHeroBackdrop(
            imageURL: viewModel.heroBackgroundURL(
                for: item,
                width: width,
                height: height
            ),
            height: heroHeight,
            imageAlignment: imageAlignment
        )
        #endif
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
private struct HeroIndirectScrollNavigation: UIViewRepresentable {
    var isEnabled: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isEnabled: isEnabled,
            onChanged: onChanged,
            onEnded: onEnded
        )
    }

    func makeUIView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: CaptureView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        uiView.coordinator = context.coordinator
        context.coordinator.installIfPossible(from: uiView)
    }

    static func dismantleUIView(_ uiView: CaptureView, coordinator: Coordinator) {
        coordinator.uninstall()
        uiView.coordinator = nil
    }

    final class CaptureView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            coordinator?.installIfPossible(from: self)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled: Bool
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void

        private weak var hostView: UIView?
        private var panGesture: UIPanGestureRecognizer?
        private let projectedVelocityDuration: CGFloat = 0.18

        init(
            isEnabled: Bool,
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat, CGFloat) -> Void
        ) {
            self.isEnabled = isEnabled
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func installIfPossible(from view: UIView) {
            guard let superview = view.superview else { return }
            install(on: superview)
        }

        func uninstall() {
            if let panGesture {
                hostView?.removeGestureRecognizer(panGesture)
            }

            hostView = nil
            panGesture = nil
        }

        private func install(on view: UIView) {
            guard hostView !== view else { return }

            uninstall()

            let panGesture = UIPanGestureRecognizer(
                target: self,
                action: #selector(handlePanGesture(_:))
            )
            panGesture.allowedScrollTypesMask = .all
            panGesture.cancelsTouchesInView = false
            panGesture.delaysTouchesBegan = false
            panGesture.delaysTouchesEnded = false
            panGesture.requiresExclusiveTouchType = false
            panGesture.delegate = self

            view.addGestureRecognizer(panGesture)
            hostView = view
            self.panGesture = panGesture
        }

        @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
            guard isEnabled, let hostView else { return }

            let translation = gesture.translation(in: hostView)
            let velocity = gesture.velocity(in: hostView)
            let predictedHorizontalOffset = translation.x + (velocity.x * projectedVelocityDuration)

            switch gesture.state {
            case .began, .changed:
                onChanged(translation.x)
            case .ended:
                onEnded(translation.x, predictedHorizontalOffset)
            case .cancelled, .failed:
                onEnded(translation.x, translation.x)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            isEnabled
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

#if os(tvOS)
/// Snaps the tvOS hero's page scroll (`HomeCinematicHero.tvPages`) to whole
/// pages.
///
/// The scroll that matters is the focus engine's: moving focus to the next
/// page's play button proposes the smallest scroll that reveals that button,
/// which on its own would leave the page half on screen. The proposed visible
/// rect always contains the newly focused button and, being one page wide,
/// never contains another page's button whole, so the page is the first one
/// whose button starts at or after the rect's leading edge.
private struct HomeHeroTVPaging: ScrollTargetBehavior {
    var pageWidth: CGFloat
    /// Leading edge of a page's play button, measured from the page's own.
    var actionLeadingInset: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard pageWidth > 0, context.axes.contains(.horizontal) else { return }
        let pageCount = max(Int((context.contentSize.width / pageWidth).rounded()), 1)
        let page = Int(((target.rect.minX - actionLeadingInset) / pageWidth).rounded(.up))
        target.rect.origin.x = CGFloat(min(max(page, 0), pageCount - 1)) * pageWidth
    }
}
#endif
