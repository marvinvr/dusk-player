import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct HomeTVView: View {
    @FocusState private var focusedTarget: FocusTarget?
    #if os(tvOS)
    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var homeFocusScope
    #endif

    @Binding var path: NavigationPath

    let viewModel: HomeViewModel
    /// Enabled servers that are currently unreachable. Only used for the quiet
    /// inline note; Home never names the server a row came from, because with
    /// every server merged into one screen that would be noise.
    let offlineServerNames: [String]
    let recentlyAddedInlineItemLimit: Int
    let heroSelectionResetRevision: Int
    let liveTVViewModel: LiveTVViewModel
    let showsLiveTV: Bool
    let playLiveTV: (PlexLiveChannel, PlexLiveProgram, PlexLiveTVLineup) -> Void
    let play: (PlexItem) -> Void

    private enum FocusTarget: Hashable {
        case heroPrimaryAction
    }

    /// Whether the hero still covers at least half the screen. Tells
    /// `HomeTVFoldSnapping` which side of the fold a focus move starts from.
    @State private var isHeroShowing = true
    /// Only `settleFold` scrolls through this, and only once the page is still.
    /// The hero ⇄ shelves move itself is the focus engine's own scroll; see
    /// `HomeTVFoldSnapping` for why nothing else may scroll alongside it.
    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    @State private var foldSettle = HomeTVFoldSettle()

    private let foldSettleAnimationDuration: TimeInterval = 0.35

    /// Gap above the first shelf header.
    ///
    /// On tvOS this is no longer cosmetic: pressing down scrolls this stack's
    /// top to the top of the scroll viewport, which sits under the floating tab
    /// bar, so the padding is the only thing keeping the first shelf header
    /// clear of it. Derive it from the measured top safe area rather than a
    /// literal, because the tab bar's height is not ours to hard-code.
    private func shelfTopPadding(safeAreaTop: CGFloat) -> CGFloat {
        #if os(tvOS)
        return max(safeAreaTop, 60) + 24
        #else
        return 60
        #endif
    }

    /// Whether the "More" hint is telling the truth.
    private var hasContentBelowHero: Bool {
        showsLiveTV
            || !viewModel.hubs.isEmpty
            || viewModel.personalizedShelves.contains { !$0.items.isEmpty }
    }

    var body: some View {
        GeometryReader { geometry in
            let heroItems = viewModel.heroItems()
            let heroItemIDs = heroItems.map(\.id)
            let globalFrame = geometry.frame(in: .global)
            let screenWidth = max(fullDisplayWidth(fallback: geometry.size.width), geometry.size.width)
            let leadingContentInset = max(globalFrame.minX, 0)
            let trailingContentInset = max(screenWidth - globalFrame.maxX, 0)
            // The hero owns the entire display on tvOS. `geometry.size` is the
            // safe-area-inset content box, so add the insets back (and floor the
            // result at the real screen height) to get the full-bleed height.
            let heroContainerSize = CGSize(
                width: screenWidth,
                height: max(
                    fullDisplayHeight(fallback: geometry.size.height),
                    geometry.size.height
                        + geometry.safeAreaInsets.top
                        + geometry.safeAreaInsets.bottom
                )
            )
            // Content y of the first shelf's top edge, a.k.a. the fold: the
            // hero is exactly this tall and the stack below adds no spacing.
            let heroHeight = heroContainerSize.height

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !heroItems.isEmpty {
                        HomeCinematicHero(
                            items: heroItems,
                            viewModel: viewModel,
                            containerSize: heroContainerSize,
                            topInset: geometry.safeAreaInsets.top,
                            contentLeadingInset: leadingContentInset,
                            contentTrailingInset: trailingContentInset,
                            layout: .tv,
                            // Keep tvOS hero rotation OFF. The focusable play button
                            // lives inside the per-item hero slide (keyed by ratingKey),
                            // so an unattended rotation tears down the view that owns the
                            // `.heroPrimaryAction` focus binding. While another tab is on
                            // screen the Home tab stays alive and keeps rotating, leaving
                            // the binding detached — so returning to Home and pressing down
                            // from the tab bar drops focus into nothing (cursor vanishes,
                            // nothing is selectable). iOS has no focus engine and keeps it on.
                            autoRotates: false,
                            supportsDragNavigation: false,
                            selectionResetRevision: heroSelectionResetRevision,
                            primaryAction: { item, callbacks in
                                AnyView(
                                    Button {
                                        callbacks.restartRotation()
                                        play(item)
                                    } label: {
                                        HomeHeroActionButtonLabel(
                                            title: viewModel.heroPrimaryActionTitle(for: item),
                                            systemImage: "play.fill"
                                        )
                                    }
                                    #if os(tvOS)
                                    .homeHeroNativeButtonStyle()
                                    .focused($focusedTarget, equals: .heroPrimaryAction)
                                    .prefersDefaultFocus(true, in: homeFocusScope)
                                    .background(
                                        TVRemoteSwipeCapture(
                                            isEnabled: focusedTarget == .heroPrimaryAction,
                                            onSwipeLeft: callbacks.showPrevious,
                                            onSwipeRight: callbacks.showNext
                                        )
                                    )
                                    #endif
                                    .contextMenu {
                                        HomeItemContextMenu(
                                            item: item,
                                            detailsLabel: heroDetailsLabel(for: item),
                                            onMarkWatched: {
                                                Task { await viewModel.setWatched(true, for: item) }
                                            },
                                            onMarkUnwatched: {
                                                Task { await viewModel.setWatched(false, for: item) }
                                            },
                                            onSelectRoute: { route in
                                                path.append(route)
                                            },
                                            onRemoveFromContinueWatching: {
                                                Task { await viewModel.removeFromContinueWatching(item) }
                                            }
                                        )
                                        .onAppear {
                                            callbacks.pauseRotation()
                                        }
                                        .onDisappear {
                                            callbacks.restartRotation()
                                        }
                                    }
                                    .accessibilityAddTraits(.isButton)
                                )
                            }
                        )
                        .frame(width: heroContainerSize.width)
                        .offset(x: -leadingContentInset)
                        // Applied *after* the width frame and the offset so
                        // the hint centres on the real display rather than on
                        // the safe-area-inset content box.
                        .overlay(alignment: .bottom) {
                            scrollHint(isEnabled: hasContentBelowHero)
                        }
                        #if os(tvOS)
                        .focusSection()
                        #endif
                    } else {
                        homeHeader()
                            .padding(.horizontal, DuskPosterMetrics.carouselHorizontalPadding)
                            .padding(.top, DuskPosterMetrics.pageSectionSpacing)
                    }

                    shelvesStack()
                        .padding(
                            .top,
                            heroItems.isEmpty
                                ? 56
                                : shelfTopPadding(safeAreaTop: geometry.safeAreaInsets.top)
                        )
                        .padding(.bottom, DuskPosterMetrics.pageBottomPadding)
                        #if os(tvOS)
                        .focusSection()
                        #endif
                }
                .frame(width: geometry.size.width, alignment: .leading)
                .padding(.top, heroItems.isEmpty ? 24 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // With a hero, the scroll content starts at the very top of the
            // display with no top content inset. That is what puts the artwork
            // at screen y = 0, and it makes content y = scroll offset, so the
            // fold snapping below can place the first shelf exactly at
            // `heroHeight`. Without a hero, the "Home" header keeps the inset.
            .ignoresSafeArea(edges: heroItems.isEmpty ? [] : .top)
            .scrollPosition($scrollPosition)
            .scrollTargetBehavior(
                HomeTVFoldSnapping(
                    foldY: heroItems.isEmpty ? nil : heroHeight,
                    startsAboveFold: focusedTarget == .heroPrimaryAction || isHeroShowing
                )
            )
            .onScrollGeometryChange(for: Bool.self) { scrollGeometry in
                scrollGeometry.contentOffset.y + scrollGeometry.contentInsets.top < heroHeight * 0.5
            } action: { _, isShowing in
                isHeroShowing = isShowing
            }
            .onScrollGeometryChange(for: HomeTVScrollMetrics.self) { scrollGeometry in
                HomeTVScrollMetrics(scrollGeometry)
            } action: { _, metrics in
                // Called every frame while the page moves, so this stays out
                // of `@State`: the settle check only runs once it stops.
                foldSettle.metrics = metrics
                scheduleFoldSettle(heroHeight: heroHeight, hasHeroItems: !heroItems.isEmpty)
            }
            #if os(tvOS)
            .focusScope(homeFocusScope)
            #endif
            .contentMargins(.zero, for: .scrollContent)
            .contentMargins(.zero, for: .scrollIndicators)
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
            .duskTVOSPageBackground()
            .defaultFocus($focusedTarget, .heroPrimaryAction)
            .onChange(of: focusedTarget) { _, _ in
                // A move the fold snapping pinned in place scrolls nothing, so
                // no geometry change would schedule the settle check.
                scheduleFoldSettle(heroHeight: heroHeight, hasHeroItems: !heroItems.isEmpty)
            }
            .task(id: heroItemIDs) {
                await requestHeroPrimaryFocusIfNeeded(hasHeroItems: !heroItems.isEmpty)
            }
            .task(id: showsLiveTV) {
                guard showsLiveTV else { return }
                await liveTVViewModel.loadNowPlaying(force: true)
            }
        }
    }

    /// The shelves below the hero.
    ///
    /// **tvOS uses a plain `VStack`, not a `LazyVStack`, on purpose.** With the
    /// full-bleed hero the first shelf starts exactly at the fold, so a lazy
    /// stack can still have nothing materialised when the user presses down —
    /// the focus engine then finds no target and the down-press is a dead end.
    /// A plain stack costs one extra layout pass and makes the move reliable.
    @ViewBuilder
    private func shelvesStack() -> some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: DuskPosterMetrics.pageSectionSpacing) {
            shelves()
        }
        #else
        LazyVStack(alignment: .leading, spacing: DuskPosterMetrics.pageSectionSpacing) {
            shelves()
        }
        #endif
    }

    @ViewBuilder
    private func shelves() -> some View {
        ServerOutageNote(offlineServerNames: offlineServerNames)
            .padding(.horizontal, DuskPosterMetrics.carouselHorizontalPadding)

        if showsLiveTV {
            LiveTVHomeShelf(viewModel: liveTVViewModel, play: playLiveTV)
        }

        ForEach(viewModel.hubs) { hub in
            let items = viewModel.inlineItems(
                in: hub,
                maxRecentlyAddedItems: recentlyAddedInlineItemLimit
            )

            if !items.isEmpty {
                let isVideoHub = viewModel.isVideoHub(hub)

                PlexItemPosterCarouselSection(
                    title: hub.title,
                    items: items,
                    posterWidth: isVideoHub
                        ? DuskPosterMetrics.videoCarouselWidth
                        : DuskPosterMetrics.carouselPosterWidth,
                    imageAspectRatio: isVideoHub ? 16.0 / 9.0 : 2.0 / 3.0,
                    showAllRoute: viewModel.shouldShowAll(
                        for: hub,
                        maxRecentlyAddedItems: recentlyAddedInlineItemLimit
                    ) ? AppNavigationRoute.hub(hub) : nil,
                    subtitle: { isVideoHub ? $0.standardPosterSubtitle : $0.year.map(String.init) },
                    posterURL: { item, width, height in
                        viewModel.posterURL(for: item, width: width, height: height)
                    }
                ) { item in
                    PlexItemContextMenuContent(
                        item: item,
                        onMarkWatched: {
                            Task { await viewModel.setWatched(true, for: item) }
                        },
                        onMarkUnwatched: {
                            Task { await viewModel.setWatched(false, for: item) }
                        }
                    )
                }
            }
        }

        ForEach(viewModel.personalizedShelves) { shelf in
            if !shelf.items.isEmpty {
                PlexItemPosterCarouselSection(
                    title: shelf.title,
                    items: shelf.items,
                    posterWidth: DuskPosterMetrics.carouselPosterWidth,
                    showAllRoute: viewModel.showAllRoute(for: shelf),
                    subtitle: { item in
                        viewModel.subtitle(for: item)
                    },
                    posterURL: { item, width, height in
                        viewModel.posterURL(for: item, width: width, height: height)
                    }
                ) { item in
                    PlexItemContextMenuContent(
                        item: item,
                        onMarkWatched: {
                            Task { await viewModel.setWatched(true, for: item) }
                        },
                        onMarkUnwatched: {
                            Task { await viewModel.setWatched(false, for: item) }
                        }
                    )
                }
            }
        }
    }

    /// The bottom-centre "More ⌄" affordance. tvOS only; the hero is not
    /// full-bleed anywhere else, so there is nothing to hint at.
    @ViewBuilder
    private func scrollHint(isEnabled: Bool) -> some View {
        #if os(tvOS)
        if isEnabled {
            HomeTVScrollHint(isVisible: focusedTarget == .heroPrimaryAction)
                .padding(.bottom, 60)
        }
        #else
        EmptyView()
        #endif
    }

    private func scheduleFoldSettle(heroHeight: CGFloat, hasHeroItems: Bool) {
        guard hasHeroItems else { return }

        foldSettle.pendingSettle?.cancel()
        foldSettle.pendingSettle = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            settleFold(heroHeight: heroHeight)
        }
    }

    /// Safety net behind `HomeTVFoldSnapping`: once the page has stopped
    /// moving, make sure it rests on one of its two stops, the full hero or
    /// the first shelf at the fold.
    ///
    /// The snapping reads the focus engine's proposed offset, and where the
    /// focus engine puts a newly focused item is its own business. If it ever
    /// proposes something the snapping misreads, this is what repairs it: the
    /// focused play button with the hero scrolled away, or a sliver of hero
    /// left above the first shelf. It only runs when the page is still, so it
    /// can never become a second scroll racing the focus engine's, which is
    /// what caused the old multi-row overshoot. With well-behaved proposals it
    /// never scrolls at all.
    private func settleFold(heroHeight: CGFloat) {
        let metrics = foldSettle.metrics
        // A short page may not scroll far enough to reach the fold at all.
        let fold = min(heroHeight, metrics.maxOffset)
        guard fold > 1 else { return }

        if focusedTarget == .heroPrimaryAction {
            guard metrics.offset > 1 else { return }
            withAnimation(.easeInOut(duration: foldSettleAnimationDuration)) {
                scrollPosition.scrollTo(edge: .top)
            }
        } else if metrics.offset > 1, metrics.offset < fold - 1 {
            // Focus is off the hero (nothing on the hero but the play button
            // takes focus) while part of the hero is still on screen. The tab
            // bar never lands here: focus reaches it either from the hero at
            // rest or from a shelf with the page at or past the fold.
            withAnimation(.easeInOut(duration: foldSettleAnimationDuration)) {
                scrollPosition.scrollTo(y: fold)
            }
        }
    }

    @MainActor
    private func requestHeroPrimaryFocusIfNeeded(hasHeroItems: Bool) async {
        guard hasHeroItems else { return }

        // Reset the home focus scope after the hero enters the hierarchy so both
        // initial launch and re-entry from the tab bar prefer the hero action.
        focusedTarget = nil
        await Task.yield()
        #if os(tvOS)
        resetFocus(in: homeFocusScope)
        #endif
        focusedTarget = .heroPrimaryAction
    }

    private func fullDisplayWidth(fallback: CGFloat) -> CGFloat {
        #if canImport(UIKit)
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) {
            return windowScene.screen.bounds.width
        }

        return fallback
        #else
        fallback
        #endif
    }

    /// Sibling of `fullDisplayWidth`. The hero is full-bleed vertically too, so
    /// it needs the display height, not the safe-area-inset content height.
    private func fullDisplayHeight(fallback: CGFloat) -> CGFloat {
        #if canImport(UIKit)
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) {
            return windowScene.screen.bounds.height
        }

        return fallback
        #else
        fallback
        #endif
    }

    /// The server name used to sit under this title. With every server merged
    /// into one Home there is no single server to name, and naming the primary
    /// would be a lie about where the rows came from.
    private func homeHeader() -> some View {
        Text("Home")
            .font(
                DuskFont.pageTitleRounded(
                    ios: .system(size: 44, weight: .bold, design: .rounded)
                )
            )
            .foregroundStyle(Color.primary)
    }

    private func heroDetailsLabel(for item: PlexItem) -> String {
        switch item.type {
        case .episode:
            return "Episode Details"
        case .season:
            return "Season Details"
        case .show:
            return "Show Details"
        case .movie:
            return "Movie Details"
        default:
            return "View Details"
        }
    }
}

/// Snaps the focus engine's own scroll between Home's two stops on tvOS: the
/// full-screen hero, and the first shelf at the top of the display.
///
/// When focus moves to an item that is off screen, the focus engine scrolls
/// the page to reveal it, and SwiftUI runs that scroll's proposed end offset
/// through `updateTarget` first. Rewriting the target there is how Home shapes
/// the hero ⇄ shelves move. This is the fold-snapping pattern from Apple's
/// "Creating a tvOS media catalog app in SwiftUI" sample, retuned for a hero
/// that fills the whole display.
///
/// Never pair it with a programmatic `scrollTo` on the same focus change: the
/// two scrolls stack. That stacking is what used to throw a down-press from
/// the hero several rows past the first shelf.
///
/// Offsets are plain content y values. That only holds because the scroll view
/// has no top content inset while there is a hero (`HomeTVView` ignores the
/// top safe area).
private struct HomeTVFoldSnapping: ScrollTargetBehavior {
    /// Content y of the first shelf's top edge, i.e. the hero height. `nil`
    /// when there is no hero, which leaves every target alone.
    var foldY: CGFloat?
    /// Which side of the fold the scroll starts from. It comes from the last
    /// render, so it describes the page as it was *before* the focus move that
    /// triggered the scroll.
    var startsAboveFold: Bool

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        // Only the vertical page scroll, never the shelves' own carousels.
        guard let foldY, foldY > 0, context.axes.contains(.vertical) else { return }
        let proposedY = target.rect.minY

        if startsAboveFold {
            // The play button is the only thing on the hero that takes focus,
            // and it is fully on screen at rest. So any real scroll from up
            // here is focus leaving for the shelves: land the first shelf at
            // the top. Only small nudges (the play button, re-focused or eased
            // off the bottom edge) keep the hero pinned. The threshold stays
            // low because the first thing below the fold can be small, like
            // the outage note's Retry button.
            target.rect.origin.y = proposedY < foldY * 0.15 ? 0 : foldY
        } else if proposedY < foldY {
            // Below the fold, stopping anywhere short of it would leave a
            // sliver of hero on screen. A target that shows more than half of
            // the hero means focus is going back up to the play button, which
            // sits low in the hero, so reveal all of it. Anything less is the
            // focus engine nudging the first shelf, which stays at the fold.
            target.rect.origin.y = proposedY < foldY * 0.5 ? 0 : foldY
        }
        // Targets past the fold are ordinary shelf-to-shelf scrolling.
    }
}

/// The parts of the scroll geometry `settleFold` needs, measured from the
/// resting offset.
private struct HomeTVScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var maxOffset: CGFloat = 0

    init() {}

    init(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.y + geometry.contentInsets.top
        maxOffset = max(
            geometry.contentSize.height
                + geometry.contentInsets.top
                + geometry.contentInsets.bottom
                - geometry.containerSize.height,
            0
        )
    }
}

/// The latest scroll metrics plus the pending `settleFold` check.
///
/// A class on purpose: scroll geometry updates it on every frame of a scroll,
/// and going through `@State` would re-render Home once per frame.
@MainActor
private final class HomeTVFoldSettle {
    var metrics = HomeTVScrollMetrics()
    var pendingSettle: Task<Void, Never>?
}

#if os(tvOS)
/// "More ⌄" at the bottom centre of the full-bleed home hero.
///
/// It is decoration only: never focusable, never hit-testable, and hidden from
/// accessibility (VoiceOver users navigate by focus, and the shelves announce
/// themselves). It must stay **outside** `HomeCinematicHero`'s per-item slide —
/// mounting it there would tear it down on every hero change and disturb the
/// `.heroPrimaryAction` focus binding.
private struct HomeTVScrollHint: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let isVisible: Bool

    @State private var isBouncing = false

    var body: some View {
        VStack(spacing: 4) {
            Text("More")
                .font(DuskFont.TV.badge)

            Image(systemName: "chevron.down")
                .font(DuskFont.TV.glyphSmall.weight(.semibold))
                .offset(y: isBouncing ? 6 : 0)
        }
        .foregroundStyle(Color.primary.opacity(0.72))
        // Bright artwork can reach all the way to the bottom of a full-bleed
        // hero, so the hint carries its own shadow instead of relying on the
        // backdrop scrim.
        .shadow(color: .black.opacity(0.65), radius: 8, y: 2)
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: isVisible)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !accessibilityReduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                isBouncing = true
            }
        }
        .onChange(of: accessibilityReduceMotion) { _, isReduced in
            guard isReduced else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                isBouncing = false
            }
        }
    }
}

private struct TVRemoteSwipeCapture: UIViewRepresentable {
    let isEnabled: Bool
    let onSwipeLeft: () -> Void
    let onSwipeRight: () -> Void

    func makeUIView(context: Context) -> SwipeCaptureView {
        let view = SwipeCaptureView()
        view.backgroundColor = .clear
        view.update(
            isEnabled: isEnabled,
            onSwipeLeft: onSwipeLeft,
            onSwipeRight: onSwipeRight
        )
        return view
    }

    func updateUIView(_ uiView: SwipeCaptureView, context: Context) {
        uiView.update(
            isEnabled: isEnabled,
            onSwipeLeft: onSwipeLeft,
            onSwipeRight: onSwipeRight
        )
    }
}

private final class SwipeCaptureView: UIView, UIGestureRecognizerDelegate {
    private weak var attachedView: UIView?
    private lazy var swipeLeftRecognizer: UISwipeGestureRecognizer = {
        let recognizer = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        recognizer.direction = .left
        recognizer.delegate = self
        return recognizer
    }()
    private lazy var swipeRightRecognizer: UISwipeGestureRecognizer = {
        let recognizer = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        recognizer.direction = .right
        recognizer.delegate = self
        return recognizer
    }()

    private var isSwipeCaptureEnabled = false
    private var onSwipeLeft: () -> Void = {}
    private var onSwipeRight: () -> Void = {}

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        attachRecognizersIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachRecognizersIfNeeded()
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview == nil {
            detachRecognizers()
        }

        super.willMove(toSuperview: newSuperview)
    }

    func update(
        isEnabled: Bool,
        onSwipeLeft: @escaping () -> Void,
        onSwipeRight: @escaping () -> Void
    ) {
        isSwipeCaptureEnabled = isEnabled
        self.onSwipeLeft = onSwipeLeft
        self.onSwipeRight = onSwipeRight
        attachRecognizersIfNeeded()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc
    private func handleSwipe(_ recognizer: UISwipeGestureRecognizer) {
        guard isSwipeCaptureEnabled else { return }

        switch recognizer.direction {
        case .left:
            onSwipeLeft()
        case .right:
            onSwipeRight()
        default:
            break
        }
    }

    private func attachRecognizersIfNeeded() {
        guard let targetView = superview else { return }
        guard attachedView !== targetView else { return }

        detachRecognizers()
        targetView.addGestureRecognizer(swipeLeftRecognizer)
        targetView.addGestureRecognizer(swipeRightRecognizer)
        attachedView = targetView
    }

    private func detachRecognizers() {
        attachedView?.removeGestureRecognizer(swipeLeftRecognizer)
        attachedView?.removeGestureRecognizer(swipeRightRecognizer)
        attachedView = nil
    }
}
#endif
