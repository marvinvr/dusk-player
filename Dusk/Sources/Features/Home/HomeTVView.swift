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
    let serverName: String?
    let recentlyAddedInlineItemLimit: Int
    let heroSelectionResetRevision: Int
    let liveTVViewModel: LiveTVViewModel
    let showsLiveTV: Bool
    let playLiveTV: (PlexLiveChannel, PlexLiveProgram, PlexLiveTVLineup) -> Void
    let play: (PlexItem) -> Void

    /// The last vertical remote move the hero reported. `@FocusState` only tells
    /// us that focus *left* `.heroPrimaryAction`, not which way it went — up into
    /// the tab bar and down into the shelves both read as `nil` — so the hero
    /// hands us the direction and this disambiguates them.
    @State private var lastHeroVerticalMove: HomeHeroVerticalMove?

    private enum FocusTarget: Hashable {
        case heroPrimaryAction
    }

    /// Scroll anchors for the down/up choreography between the full-screen hero
    /// and the shelves.
    private enum HomeScrollAnchor: Hashable {
        case hero
        case shelves
    }

    private let heroScrollAnimationDuration: TimeInterval = 0.35

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

            ScrollViewReader { scrollProxy in
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
                                },
                                onVerticalMove: { move in
                                    lastHeroVerticalMove = move
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
                            .ignoresSafeArea(edges: .top)
                            .id(HomeScrollAnchor.hero)
                            #if os(tvOS)
                            .focusSection()
                            #endif
                        } else if let serverName {
                            homeHeader(serverName: serverName)
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
                            .id(HomeScrollAnchor.shelves)
                            #if os(tvOS)
                            .focusSection()
                            #endif
                    }
                    .frame(width: geometry.size.width, alignment: .leading)
                    .padding(.top, heroItems.isEmpty ? 24 : -geometry.safeAreaInsets.top)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                .onChange(of: focusedTarget) { _, newValue in
                    handleHeroFocusChange(
                        newValue,
                        hasHeroItems: !heroItems.isEmpty,
                        scrollProxy: scrollProxy
                    )
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

    /// Drives the hero ⇄ shelves scroll choreography.
    ///
    /// `focusedTarget` only distinguishes "the hero button" from "anything
    /// else", so a bare `nil` is ambiguous: it is equally the tab bar above and
    /// the first shelf below. `lastHeroVerticalMove`, reported by the hero's own
    /// move-command handler, is what tells the two apart — without it, moving up
    /// into the tab bar would scroll the shelves into view.
    private func handleHeroFocusChange(
        _ target: FocusTarget?,
        hasHeroItems: Bool,
        scrollProxy: ScrollViewProxy
    ) {
        guard hasHeroItems else { return }

        switch target {
        case .heroPrimaryAction:
            lastHeroVerticalMove = nil
            withAnimation(.easeInOut(duration: heroScrollAnimationDuration)) {
                scrollProxy.scrollTo(HomeScrollAnchor.hero, anchor: .top)
            }
        case nil:
            guard lastHeroVerticalMove == .down else { return }
            lastHeroVerticalMove = nil
            withAnimation(.easeInOut(duration: heroScrollAnimationDuration)) {
                scrollProxy.scrollTo(HomeScrollAnchor.shelves, anchor: .top)
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

    private func homeHeader(serverName: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Home")
                .font(
                    DuskFont.pageTitleRounded(
                        ios: .system(size: 44, weight: .bold, design: .rounded)
                    )
                )
                .foregroundStyle(Color.primary)

            Text(serverName)
                .font(DuskFont.pageSubtitle(ios: .title3))
                .foregroundStyle(Color.primary)
        }
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
