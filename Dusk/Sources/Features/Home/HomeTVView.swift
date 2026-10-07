import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if os(tvOS)
import UIKit.UIGestureRecognizerSubclass
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
    /// Reports whether the page is scrolled away from its top. See
    /// `HomeView.isScrolledOffTop`.
    @Binding var isScrolledOffTop: Bool
    let scrollToTopRevision: Int
    let playLiveTV: (PlexLiveChannel, PlexLiveProgram, PlexLiveTVLineup) -> Void
    let play: (PlexItem) -> Void

    private enum FocusTarget: Hashable {
        case heroPrimaryAction
        /// The invisible strip under the play button that the focus engine's
        /// down move lands on first. See `heroDownCatch`.
        case heroDownCatch
    }

    /// Whether the hero still covers at least half the screen. Tells
    /// `HomeTVFoldSnapping` which side of the fold a focus move starts from.
    @State private var isHeroShowing = true
    /// Whether focus has settled below the hero. Closed while the play button
    /// has focus; opened once the hero's down-press has landed on the first
    /// shelf's first item (`beginHeroExit`). Latched, not derived from the
    /// scroll offset. Tells `settleFold` which end the page belongs at, and a
    /// card taking focus while it is closed means the focus engine moved
    /// down from the hero on its own, which starts the landing.
    @State private var shelvesUnlocked = false
    @State private var heroExit = HeroExitPhase.idle
    /// The shelf the running hero exit lands on. Fixed when the exit starts:
    /// a shelf that loads in above it mid-exit must not take the landing
    /// over from under the card focus is arriving on.
    @State private var heroExitShelf: HomeTVShelfID?
    @State private var heroExitTimeout: Task<Void, Never>?
    /// See `carouselLeadingFocusGeneration`.
    @State private var heroExitFocusGeneration = 0
    /// `requestHeroPrimaryFocusIfNeeded` is moving focus back to the play
    /// button. A card that holds focus for a moment in between is not the
    /// focus engine moving down from the hero.
    @State private var isReturningToHero = false
    /// Whether a down move off the play button is deliberate: fed from UIKit
    /// with the remote's presses and touch-surface travel, asked whenever a
    /// move arrives. See `HomeTVHeroDownGate`.
    @State private var heroDownGate = HomeTVHeroDownGate()

    /// The hero's down-press. See `beginHeroExit`.
    private enum HeroExitPhase {
        case idle
        /// The page is going to the fold and the first shelf's first item is
        /// asked to take focus, and to take it back from any further move
        /// the same gesture delivers.
        case landing
    }
    /// `beginHeroExit` scrolls through this (the hero's down-press), and
    /// `settleFold` once the page is still. The move back up to the hero is
    /// the focus engine's own scroll; see `HomeTVFoldSnapping` for why
    /// nothing else may scroll alongside that one.
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
                            onMoveDown: { beginHeroExit(heroHeight: heroHeight) },
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
                                            downGate: heroDownGate,
                                            onSwipeLeft: callbacks.showPrevious,
                                            onSwipeRight: callbacks.showNext,
                                            onMoveDown: { beginHeroExit(heroHeight: heroHeight) }
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
                                    #if os(tvOS)
                                    .overlay(alignment: .bottomLeading) {
                                        // The guide must sit on the strip itself: a
                                        // conditional wrapper would swallow it and
                                        // leave the strip over the button.
                                        heroDownCatch(width: heroContainerSize.width, isEnabled: !shelvesUnlocked)
                                            .alignmentGuide(.bottom) { $0[.top] }
                                    }
                                    #endif
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

                    shelvesStack(hasHero: !heroItems.isEmpty)
                        .environment(\.carouselLeadingFocusGeneration, heroExitFocusGeneration)
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
                    startsAboveFold: focusedTarget == .heroPrimaryAction || isHeroShowing,
                    pinsToFold: heroExit != .idle,
                    downGate: heroDownGate
                )
            )
            .onScrollGeometryChange(for: Bool.self) { scrollGeometry in
                scrollGeometry.contentOffset.y + scrollGeometry.contentInsets.top < heroHeight * 0.5
            } action: { _, isShowing in
                isHeroShowing = isShowing
            }
            .onPreferenceChange(CarouselLeadingItemFocusedKey.self) { hasLanded in
                if hasLanded {
                    finishHeroExit(heroHeight: heroHeight)
                } else if heroExit == .landing, shelvesUnlocked, focusedTarget != .heroPrimaryAction {
                    // The first item had focus and lost it to a further move
                    // of the same gesture while the landing is still open.
                    // Not to the play button: that is the user going back up,
                    // and `focusedTarget` has already withdrawn the request.
                    heroExitFocusGeneration += 1
                }
            }
            // The focus engine moved focus from the play button into a shelf
            // by itself. Wherever it put it, the landing takes over. Same as
            // `onMoveDown`, which may or may not have fired already.
            .onPreferenceChange(CarouselItemFocusedKey.self) { isCardFocused in
                guard isCardFocused, !heroItems.isEmpty, !shelvesUnlocked, !isReturningToHero else { return }
                // The thumb drifted on the touch surface, and the engine took
                // that for a move past the catch strip. Play keeps focus.
                if !heroDownGate.allowsDownMove {
                    heroDownGate.noteRefusedMove()
                    Task { await requestHeroPrimaryFocusIfNeeded(hasHeroItems: true) }
                    return
                }
                beginHeroExit(heroHeight: heroHeight)
            }
            // Only a page with a hero has somewhere to return to: without one
            // there is no reliable focus target, so Back stays the system's.
            .onScrollGeometryChange(for: Bool.self) { scrollGeometry in
                !heroItems.isEmpty && HomeTVScrollMetrics(scrollGeometry).offset > 1
            } action: { _, isOffTop in
                isScrolledOffTop = isOffTop
            }
            .onChange(of: heroItems.isEmpty) { _, isEmpty in
                if isEmpty { isScrolledOffTop = false }
            }
            // Without a hero nothing locks the shelves. Keeping the latch open
            // then also covers a hero that arrives late: the shelves stay
            // reachable (one of their cards may hold focus) until the play
            // button has actually taken it.
            .onChange(of: heroItems.isEmpty, initial: true) { _, isEmpty in
                guard isEmpty else { return }
                cancelHeroExit()
                foldSettle.pendingSettle?.cancel()
                shelvesUnlocked = true
            }
            .onDisappear {
                cancelHeroExit()
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
            .onChange(of: focusedTarget) { previous, target in
                #if os(tvOS)
                if target == .heroDownCatch {
                    catchHeroDownMove(from: previous, heroHeight: heroHeight)
                    return
                }
                #endif
                if target == .heroPrimaryAction {
                    shelvesUnlocked = false
                    // Focus came back to the play button after the landing
                    // was requested: the user went back up. Withdraw the
                    // request so the card does not take focus again.
                    if heroExit == .landing {
                        cancelHeroExit()
                    }
                }
                // A move the fold snapping pinned in place scrolls nothing, so
                // no geometry change would schedule the settle check.
                scheduleFoldSettle(heroHeight: heroHeight, hasHeroItems: !heroItems.isEmpty)
            }
            .task(id: heroItemIDs) {
                await requestHeroPrimaryFocusIfNeeded(hasHeroItems: !heroItems.isEmpty)
            }
            // The Siri Remote's Back press while the page is scrolled down.
            // This only moves focus back to the hero: the focus engine's
            // reveal scroll, bent by `HomeTVFoldSnapping`, carries the page
            // up, and `settleFold` finishes at the very top if the snapping
            // stops at the fold. A `scrollTo` here would stack with it.
            .onChange(of: scrollToTopRevision) { _, _ in
                cancelHeroExit()
                Task { await requestHeroPrimaryFocusIfNeeded(hasHeroItems: !heroItems.isEmpty) }
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
    private func shelvesStack(hasHero: Bool) -> some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: DuskPosterMetrics.pageSectionSpacing) {
            shelves(hasHero: hasHero)
        }
        #else
        LazyVStack(alignment: .leading, spacing: DuskPosterMetrics.pageSectionSpacing) {
            shelves(hasHero: hasHero)
        }
        #endif
    }

    /// The shelf the hero's down-press lands on: the first one `shelves()`
    /// actually renders. Mirrors its conditions, including `LiveTVHomeShelf`'s
    /// own "nothing on right now" check: a shelf that renders nothing has no
    /// first item to focus, and the down-press would bounce back to the hero.
    private var firstShelfID: HomeTVShelfID? {
        if !offlineServerNames.isEmpty {
            return .outageNote
        }

        if showsLiveTV,
           liveTVViewModel.nowPlayingLineup?.guides.contains(where: { $0.currentProgram() != nil }) == true {
            return .liveTV
        }

        if let hub = viewModel.hubs.first(where: { hub in
            !viewModel.inlineItems(in: hub, maxRecentlyAddedItems: recentlyAddedInlineItemLimit).isEmpty
        }) {
            return .hub(hub.id)
        }

        if let shelf = viewModel.personalizedShelves.first(where: { !$0.items.isEmpty }) {
            return .personalized(shelf.id)
        }

        return nil
    }

    @ViewBuilder
    private func shelves(hasHero: Bool) -> some View {
        let landingShelf = heroExit == .idle ? firstShelfID : heroExitShelf
        let focus = { (shelf: HomeTVShelfID) -> HomeTVShelfFocus in
            guard hasHero, shelf == landingShelf else { return .reachable() }
            if heroExit == .landing { return .landing }
            return .reachable(shelvesUnlocked ? .none : .rewindWhenHidden)
        }

        ServerOutageNote(offlineServerNames: offlineServerNames)
            .padding(.horizontal, DuskPosterMetrics.carouselHorizontalPadding)
            .homeTVShelfFocus(focus(.outageNote))

        if showsLiveTV {
            LiveTVHomeShelf(viewModel: liveTVViewModel, play: playLiveTV)
                .homeTVShelfFocus(focus(.liveTV))
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
                .homeTVShelfFocus(focus(.hub(hub.id)))
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
                .homeTVShelfFocus(focus(.personalized(shelf.id)))
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

    #if os(tvOS)
    /// Height of the catch strip. It fits in the hero's bottom padding under
    /// the play button (at least 104pt in `HomeCinematicHeroLayout.tv`), so
    /// the hero's clip never cuts it (a clipped strip still worked in the
    /// simulator; this just keeps it simple).
    private let heroDownCatchHeight: CGFloat = 100

    /// The first thing the focus engine finds below the play button: an
    /// invisible focusable strip the width of the display, inside the hero's
    /// focus section. It never keeps focus. `catchHeroDownMove` either hands
    /// focus straight back to the play button (the move was a thumb drifting
    /// on the touch surface) or starts the hero exit (it was deliberate).
    ///
    /// Without it the engine's first stop is a shelf card or a filler item,
    /// rows below and off screen, and taking a drift back from there costs a
    /// scroll and a visible card flash. The strip is inside the hero, so the
    /// page does not move and the only thing that changes for a frame is the
    /// play button's focus ring.
    ///
    /// Only focusable while the latch is closed, so the move back up from the
    /// first shelf goes straight to the play button.
    private func heroDownCatch(width: CGFloat, isEnabled: Bool) -> some View {
        Color.clear
            .frame(width: width, height: heroDownCatchHeight)
            .focusable(isEnabled)
            .focused($focusedTarget, equals: .heroDownCatch)
            .focusEffectDisabled()
            .accessibilityHidden(true)
    }

    /// Focus arrived on the catch strip.
    ///
    /// Only a deliberate down move from the play button leaves the hero
    /// (`heroDownGate`). Anything else, including the engine arriving from
    /// below on its way up, goes to the play button.
    private func catchHeroDownMove(from previous: FocusTarget?, heroHeight: CGFloat) {
        guard previous == .heroPrimaryAction, !shelvesUnlocked, !isReturningToHero,
              heroDownGate.allowsDownMove else {
            if previous == .heroPrimaryAction, !shelvesUnlocked {
                heroDownGate.noteRefusedMove()
            }
            focusedTarget = .heroPrimaryAction
            return
        }

        beginHeroExit(heroHeight: heroHeight)
        if heroExit == .idle {
            // Nothing to land on (no shelf renders anything yet).
            focusedTarget = .heroPrimaryAction
        }
    }
    #endif

    /// The hero's down-press. Whatever the focus engine does with it, the
    /// landing ends on the first item of the first shelf.
    ///
    /// The focus engine is not fenced out, and must not be: a shelf with
    /// nothing focusable in it (disabled, or a lazy row not yet realised) is
    /// stood in for by a filler item that *is* focusable. The press moves
    /// focus into the filler, the play button's binding drops to nil, and
    /// UIKit then picks a target of its own, which is how three rounds of
    /// `.disabled` fences each landed somewhere else (third card, fifth row).
    /// Measured in the simulator with a replica of this screen; see
    /// `docs/ui-features.md`.
    ///
    /// So the press is left alone and overruled instead. It reaches here three
    /// ways, in any order, and the first one wins:
    /// - the catch strip under the play button taking focus
    ///   (`catchHeroDownMove`), which is where the engine's move lands;
    /// - the hero's `onMoveCommand(.down)` (which fires whether or not the
    ///   engine moved focus) and the down-click recognizer behind the play
    ///   button;
    /// - a shelf card taking focus while `shelvesUnlocked` is closed, i.e.
    ///   the engine moved down past the strip by itself.
    ///
    /// 1. Scroll the page to the fold. `HomeTVFoldSnapping` pins every
    ///    scroll the engine makes meanwhile to the fold as well.
    /// 2. Ask the first shelf's first item to take focus. It answers as soon
    ///    as it exists (the rows are lazy; the fold brings it on screen).
    /// 3. Once it holds focus, open the latch. The landing stays open 250 ms
    ///    more, and any further move of the same gesture that pulls focus
    ///    off the item in that time is answered by asking it again
    ///    (`heroExitFocusGeneration`).
    ///
    /// If the item never answers, the timeout returns focus to the hero.
    ///
    /// Only a deliberate move counts (`heroDownGate`): a thumb drifting on
    /// the touch surface, or rolling on the clickpad as it presses Play, must
    /// not carry focus to a card. If the engine already moved focus off the
    /// play button for it, focus goes straight back.
    private func beginHeroExit(heroHeight: CGFloat) {
        guard heroExit == .idle, !shelvesUnlocked, let landingShelf = firstShelfID else { return }
        if !heroDownGate.allowsDownMove {
            heroDownGate.noteRefusedMove()
            if focusedTarget != .heroPrimaryAction, !isReturningToHero {
                Task { await requestHeroPrimaryFocusIfNeeded(hasHeroItems: true) }
            }
            return
        }

        heroExitShelf = landingShelf
        heroExit = .landing
        withAnimation(.easeInOut(duration: foldSettleAnimationDuration)) {
            scrollPosition.scrollTo(y: heroHeight)
        }

        heroExitTimeout?.cancel()
        heroExitTimeout = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, heroExit != .idle else { return }
            endHeroExit(heroHeight: heroHeight)
        }
    }

    /// The first shelf's first item took focus.
    private func finishHeroExit(heroHeight: CGFloat) {
        // Once per exit: the item reporting focus again after a re-assertion
        // must not push the deadline back, or a gesture that keeps delivering
        // moves would keep the landing open for as long as it lasts.
        guard heroExit == .landing, !shelvesUnlocked else { return }

        // Open the latch now, so nothing that ends the exit early (Home
        // going away because the card was selected, say) can leave it
        // closed with focus on a card.
        shelvesUnlocked = true
        heroExitTimeout?.cancel()
        heroExitTimeout = Task { @MainActor in
            // One remote gesture can deliver more than one move. Keep the
            // request standing a moment longer so the item takes focus back
            // from the extra ones.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, heroExit == .landing else { return }
            heroExit = .idle
            scheduleFoldSettle(heroHeight: heroHeight, hasHeroItems: true)
        }
    }

    /// The exit ran out of time without the first item reporting focus.
    ///
    /// Back to the hero, whatever has focus. Focus may be on some card the
    /// focus engine picked, but the page has been pinned to the fold the
    /// whole time, so that card can be anywhere below the screen; the only
    /// place both focus and page are known to agree is the hero.
    private func endHeroExit(heroHeight: CGFloat) {
        heroExit = .idle
        if focusedTarget == .heroPrimaryAction {
            scheduleFoldSettle(heroHeight: heroHeight, hasHeroItems: true)
        } else {
            Task { await requestHeroPrimaryFocusIfNeeded(hasHeroItems: true) }
        }
    }

    /// Drops a running hero exit without touching the latch: Back, a hero
    /// focus reset, focus returning to the play button, or Home going away.
    /// The shelves stay as they are and `settleFold` puts the page right.
    private func cancelHeroExit() {
        heroExitTimeout?.cancel()
        heroExitTimeout = nil
        heroExit = .idle
    }

    private func scheduleFoldSettle(heroHeight: CGFloat, hasHeroItems: Bool) {
        foldSettle.pendingSettle?.cancel()
        guard hasHeroItems else { return }

        foldSettle.pendingSettle = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            settleFold(heroHeight: heroHeight)
        }
    }

    /// Safety net: once the page has stopped moving, make sure it rests where
    /// its focus state says it should.
    ///
    /// - Latch closed (focus is on the play button): the full hero. Resting
    ///   anywhere else would leave the focused button off screen.
    /// - Latch open (focus is below the hero): at or past the fold, never on
    ///   a sliver of hero.
    ///
    /// The move back up to the hero is the focus engine's scroll, bent by
    /// `HomeTVFoldSnapping`; where the engine puts a newly focused item is its
    /// own business, and this repairs a proposal the snapping misread. It only
    /// runs when the page is still and no hero exit is under way, so it never
    /// races another scroll. Normally it does nothing.
    private func settleFold(heroHeight: CGFloat) {
        guard heroExit == .idle else { return }

        let metrics = foldSettle.metrics
        // A short page may not scroll far enough to reach the fold at all.
        let fold = min(heroHeight, metrics.maxOffset)
        guard fold > 1 else { return }

        if !shelvesUnlocked {
            guard metrics.offset > 1 else { return }
            withAnimation(.easeInOut(duration: foldSettleAnimationDuration)) {
                scrollPosition.scrollTo(edge: .top)
            }
        } else if metrics.offset > 1, metrics.offset < fold - 1 {
            withAnimation(.easeInOut(duration: foldSettleAnimationDuration)) {
                scrollPosition.scrollTo(y: fold)
            }
        }
    }

    @MainActor
    private func requestHeroPrimaryFocusIfNeeded(hasHeroItems: Bool) async {
        guard hasHeroItems else { return }

        cancelHeroExit()
        isReturningToHero = true
        defer { isReturningToHero = false }
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
        case .episode, .season, .show:
            // Episodes and seasons open the show page too (on their own season).
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
    /// A hero exit is under way (`HomeTVView.beginHeroExit`): the page is
    /// going to the fold and nowhere else, whatever the focus engine proposes
    /// when the first card takes focus.
    var pinsToFold = false
    /// Read live, not from the last render: the move it blocks arrives
    /// mid-gesture, before any re-render.
    var downGate: HomeTVHeroDownGate?

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        // Only the vertical page scroll, never the shelves' own carousels.
        guard let foldY, foldY > 0, context.axes.contains(.vertical) else { return }
        let proposedY = target.rect.minY

        if pinsToFold {
            target.rect.origin.y = foldY
            return
        }

        if startsAboveFold, downGate?.allowsDownMove == false {
            // A move the engine made out of a drift or a press on the play
            // button. `HomeTVView` hands focus straight back, so the page
            // stays on the hero rather than dipping to the fold and back.
            target.rect.origin.y = 0
            return
        }

        if startsAboveFold {
            // The play button is the only thing on the hero that takes focus,
            // and it is fully on screen at rest. So any real scroll from up
            // here is focus leaving for the shelves: land the first shelf at
            // the top. Only small nudges (the play button, re-focused or eased
            // off the bottom edge) keep the hero pinned. The threshold stays
            // low because the first thing below the fold can be small, like
            // the outage note's Retry button.
            //
            //
            // A target past the fold is the focus engine revealing whatever
            // it picked below the first shelf on its own. That pick never
            // stands: `HomeTVView.beginHeroExit` moves focus to the first
            // shelf's first item, which sits exactly at the fold, so the page
            // goes to the fold and nowhere else. Letting the target through
            // would scroll rows down and back again.
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

/// Identifies one of Home's shelves, in `HomeTVView.shelves()` order, so the
/// hero's down-press can be limited to the first one.
private enum HomeTVShelfID: Hashable {
    case outageNote
    case liveTV
    case hub(AnyHashable)
    case personalized(AnyHashable)
}

/// What Home asks of a shelf. See `HomeTVView.beginHeroExit`.
///
/// Nothing here ever disables a shelf. A shelf with nothing focusable in it
/// (every card disabled, or a lazy row with nothing realised yet) is still a
/// focus target: SwiftUI stands a filler item in for it, the down-press moves
/// focus into the filler, and UIKit then picks a new focus target on its own,
/// which is how the press ended rows down. Every earlier attempt fenced the
/// focus engine with `.disabled` and ran straight into that.
private enum HomeTVShelfFocus: Equatable {
    /// The first shelf, while the hero has focus, is told to bring its row
    /// back to the first item while off screen, ready for the next landing.
    case reachable(CarouselLeadingItemRequest = .none)
    /// The hero's down-press is landing here: the first item is asked to take
    /// focus and to keep it until the landing is over.
    case landing

    var request: CarouselLeadingItemRequest {
        switch self {
        case .reachable(let request): request
        case .landing: .focus
        }
    }
}

private extension View {
    func homeTVShelfFocus(_ focus: HomeTVShelfFocus) -> some View {
        #if os(tvOS)
        environment(\.carouselLeadingItemRequest, focus.request)
        #else
        self
        #endif
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

/// Whether a down move off the hero's play button is deliberate.
///
/// The focus engine moves focus down from the play button for a thumb that
/// merely drifts on the Siri Remote's touch surface: how far the thumb has to
/// travel before focus leaves an item depends on the item's size, and the
/// play button is small (a card is five times taller). Nothing in UIKit lets
/// Home raise that threshold for one item, so Home measures the gesture
/// itself and decides whether the move it produced counts.
///
/// A move never counts while Select or Play/Pause is held on the play button,
/// or for `releaseGrace` after: a thumb rolling on the clickpad as it clicks
/// must not carry the press to a card. Otherwise it counts when
/// - a click on the clickpad's bottom edge is in flight or just ended (the
///   click can be over before Home gets to ask), or
/// - the touch has travelled `deliberateTravel` down since it began, or has
///   moved down faster than `deliberateVelocity` at some point; a touch that
///   ended less than `touchGrace` ago is judged by how it ended, since the
///   engine's move can reach Home a render after the finger lifted, or
/// - nothing has touched the surface lately (so the move is not a drift).
///
/// A move Home refused is retried by Home itself if the same touch then goes
/// on to qualify (`noteRefusedMove`, `onQualifiedAfterRefusal`): leaving the
/// hero must not depend on the engine attempting a second move.
///
/// Travel and velocity are in the window's points, as UIKit reports indirect
/// touches: the touch starts at the centre of the display and moves from
/// there. The two limits are set by feel, between a drift (a few points,
/// slow) and the shortest swipe that moves focus a full card row.
///
/// Nothing reads it to draw, so it is a plain reference rather than state:
/// `SwipeCaptureView` writes it from UIKit and `HomeTVView` asks it when a
/// move arrives.
private final class HomeTVHeroDownGate {
    /// Window points of downward travel that make a touch a swipe.
    static let deliberateTravel: CGFloat = 160
    /// Window points per second of downward motion that make a touch a flick,
    /// however short.
    static let deliberateVelocity: CGFloat = 1500

    /// Long enough to cover a thumb rolling off the clickpad after the click,
    /// short enough that a deliberate swipe straight after never notices.
    private let releaseGrace: CFTimeInterval = 0.3
    /// A press is never held this long: a missed release must not lock the
    /// hero in for good. A long press opens the context menu well before.
    private let maximumHold: CFTimeInterval = 2
    private var selectPressedAt: CFTimeInterval?
    private var selectReleasedAt: CFTimeInterval = -.infinity
    /// A click is over before Home asks about the move it caused: the engine
    /// moves focus on press-down, Home hears of it a render later.
    private let downPressGrace: CFTimeInterval = 0.5
    private var downPressedAt: CFTimeInterval?
    private var downReleasedAt: CFTimeInterval = -.infinity

    /// Same for a touch: the finger can lift between the engine's move and
    /// Home's question about it.
    private let touchGrace: CFTimeInterval = 0.3
    private(set) var isTouching = false
    private var touchEndedAt: CFTimeInterval = -.infinity
    /// Translation since the touch began, window points, y down.
    private var touchTravel = CGPoint.zero
    /// Points per second, y down, lightly smoothed, and its peak so far: a
    /// flick is judged by its fastest moment, not by how it ended.
    private var touchVelocityY: CGFloat = 0
    private var touchPeakVelocityY: CGFloat = 0
    /// Home refused a move during the current touch. If the touch then
    /// qualifies, `onQualifiedAfterRefusal` runs once.
    private var hasRefusedMove = false
    /// Set by `SwipeCaptureView`: Home's own hero exit.
    var onQualifiedAfterRefusal: (() -> Void)?

    var isHoldingSelect: Bool {
        let now = CACurrentMediaTime()
        if let selectPressedAt, now - selectPressedAt < maximumHold { return true }
        return now - selectReleasedAt < releaseGrace
    }

    var isDownPressActive: Bool {
        let now = CACurrentMediaTime()
        if let downPressedAt, now - downPressedAt < maximumHold { return true }
        return now - downReleasedAt < downPressGrace
    }

    var allowsDownMove: Bool {
        if isHoldingSelect { return false }
        if isDownPressActive { return true }
        if isTouching || CACurrentMediaTime() - touchEndedAt < touchGrace {
            return isTouchDeliberate
        }
        return true
    }

    private var isTouchDeliberate: Bool {
        touchTravel.y >= Self.deliberateTravel || touchPeakVelocityY >= Self.deliberateVelocity
    }

    /// Home turned a move down. Called where focus is handed back.
    func noteRefusedMove() {
        guard isTouching else { return }
        hasRefusedMove = true
    }

    func selectBegan() {
        selectPressedAt = CACurrentMediaTime()
    }

    func selectEnded() {
        guard selectPressedAt != nil else { return }
        selectPressedAt = nil
        selectReleasedAt = CACurrentMediaTime()
    }

    func downPressBegan() {
        downPressedAt = CACurrentMediaTime()
    }

    func downPressEnded() {
        guard downPressedAt != nil else { return }
        downPressedAt = nil
        downReleasedAt = CACurrentMediaTime()
    }

    func touchBegan() {
        isTouching = true
        touchTravel = .zero
        touchVelocityY = 0
        touchPeakVelocityY = 0
        hasRefusedMove = false
    }

    func touchMoved(translation: CGPoint, velocityY: CGFloat) {
        guard isTouching else { return }
        touchTravel = translation
        touchVelocityY = touchVelocityY * 0.5 + velocityY * 0.5
        touchPeakVelocityY = max(touchPeakVelocityY, touchVelocityY)
        if hasRefusedMove, !isHoldingSelect, isTouchDeliberate {
            hasRefusedMove = false
            onQualifiedAfterRefusal?()
        }
    }

    func touchEnded() {
        guard isTouching else { return }
        isTouching = false
        touchEndedAt = CACurrentMediaTime()
        hasRefusedMove = false
        // Travel and peak velocity stay for `touchGrace`; the next touch
        // resets them.
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

/// Feeds `HomeTVHeroDownGate` with the remote's presses: Select and
/// Play/Pause (the hold), and the click on the clickpad's bottom edge. Never
/// recognizes and cancels nothing, so the play button gets its press exactly
/// as before.
///
/// It sits on the window, not next to the play button: remote presses only
/// reach recognizers on the focused item's own view chain, and the SwiftUI
/// button's focus item is not a superview of this capture view (measured in
/// the simulator: a recognizer there never saw a Select or down press).
private final class HeroPressObserver: UIGestureRecognizer {
    weak var downGate: HomeTVHeroDownGate?
    /// Focus is on the play button. Presses that start anywhere else are
    /// none of the gate's business.
    var isArmed = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedPressTypes = [
            NSNumber(value: UIPress.PressType.select.rawValue),
            NSNumber(value: UIPress.PressType.playPause.rawValue),
            NSNumber(value: UIPress.PressType.downArrow.rawValue)
        ]
        allowedTouchTypes = []
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        guard isArmed else {
            state = .failed
            return
        }
        for press in presses {
            switch press.type {
            case .downArrow: downGate?.downPressBegan()
            case .select, .playPause: downGate?.selectBegan()
            default: break
            }
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        end(presses)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        end(presses)
    }

    override func reset() {
        super.reset()
        downGate?.selectEnded()
        downGate?.downPressEnded()
    }

    private func end(_ presses: Set<UIPress>) {
        for press in presses {
            switch press.type {
            case .downArrow: downGate?.downPressEnded()
            case .select, .playPause: downGate?.selectEnded()
            default: break
            }
        }
        state = .failed
    }
}

/// Feeds `HomeTVHeroDownGate` with the touch on the remote's touch surface:
/// how far it has travelled since it began and how fast it is moving. Never
/// recognizes and cancels nothing. On the window, like `HeroPressObserver`,
/// so it keeps seeing the touch whichever item the focus engine moves to
/// mid-gesture.
private final class HeroTouchObserver: UIGestureRecognizer {
    weak var downGate: HomeTVHeroDownGate?
    var isArmed = false

    private var startLocation = CGPoint.zero
    private var lastLocation = CGPoint.zero
    private var lastTimestamp: TimeInterval = 0

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        allowedPressTypes = []
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard isArmed, let touch = touches.first else {
            state = .failed
            return
        }
        startLocation = touch.location(in: nil)
        lastLocation = startLocation
        lastTimestamp = touch.timestamp
        downGate?.touchBegan()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        let location = touch.location(in: nil)
        let dt = touch.timestamp - lastTimestamp
        let velocityY = dt > 0 ? (location.y - lastLocation.y) / dt : 0
        lastLocation = location
        lastTimestamp = touch.timestamp
        downGate?.touchMoved(
            translation: CGPoint(x: location.x - startLocation.x, y: location.y - startLocation.y),
            velocityY: velocityY
        )
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        downGate?.touchEnded()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        downGate?.touchEnded()
        state = .failed
    }

    override func reset() {
        super.reset()
        downGate?.touchEnded()
    }
}

private struct TVRemoteSwipeCapture: UIViewRepresentable {
    let isEnabled: Bool
    let downGate: HomeTVHeroDownGate
    let onSwipeLeft: () -> Void
    let onSwipeRight: () -> Void
    /// A click on the bottom edge of the clickpad, or a touch qualifying as a
    /// swipe after a move of it was refused. Belt and braces next to the
    /// hero's `onMoveCommand`: any one starting the hero exit is enough.
    ///
    /// There is deliberately no down *swipe* recognizer. A raw
    /// `UISwipeGestureRecognizer` has a far lower threshold than the focus
    /// engine and recognizes alongside a click. Touch-surface moves down are
    /// the focus engine's and reach Home through the catch strip,
    /// `onMoveCommand`, or a card taking focus, each asking
    /// `HomeTVHeroDownGate` whether the touch was deliberate.
    let onMoveDown: () -> Void

    func makeUIView(context: Context) -> SwipeCaptureView {
        let view = SwipeCaptureView()
        view.backgroundColor = .clear
        view.update(
            isEnabled: isEnabled,
            downGate: downGate,
            onSwipeLeft: onSwipeLeft,
            onSwipeRight: onSwipeRight,
            onMoveDown: onMoveDown
        )
        return view
    }

    func updateUIView(_ uiView: SwipeCaptureView, context: Context) {
        uiView.update(
            isEnabled: isEnabled,
            downGate: downGate,
            onSwipeLeft: onSwipeLeft,
            onSwipeRight: onSwipeRight,
            onMoveDown: onMoveDown
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
    /// The click on the bottom edge of the remote's clickpad. Presses only:
    /// with touches allowed it would also fire for a tap on the touch surface.
    private lazy var pressDownRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handlePressDown))
        recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.downArrow.rawValue)]
        recognizer.allowedTouchTypes = []
        recognizer.delegate = self
        return recognizer
    }()
    private lazy var pressObserver: HeroPressObserver = {
        let recognizer = HeroPressObserver(target: nil, action: nil)
        recognizer.delegate = self
        return recognizer
    }()
    private lazy var touchObserver: HeroTouchObserver = {
        let recognizer = HeroTouchObserver(target: nil, action: nil)
        recognizer.delegate = self
        return recognizer
    }()
    private var windowObservers: [UIGestureRecognizer] { [pressObserver, touchObserver] }

    private var recognizers: [UIGestureRecognizer] {
        [swipeLeftRecognizer, swipeRightRecognizer, pressDownRecognizer]
    }
    private weak var observedWindow: UIWindow?

    private var isSwipeCaptureEnabled = false
    private var onSwipeLeft: () -> Void = {}
    private var onSwipeRight: () -> Void = {}
    private var onMoveDown: () -> Void = {}

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        attachRecognizersIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachRecognizersIfNeeded()
        attachWindowObserversIfNeeded()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil {
            detachWindowObservers()
        }

        super.willMove(toWindow: newWindow)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview == nil {
            detachRecognizers()
        }

        super.willMove(toSuperview: newSuperview)
    }

    func update(
        isEnabled: Bool,
        downGate: HomeTVHeroDownGate,
        onSwipeLeft: @escaping () -> Void,
        onSwipeRight: @escaping () -> Void,
        onMoveDown: @escaping () -> Void
    ) {
        isSwipeCaptureEnabled = isEnabled
        pressDownRecognizer.isEnabled = isEnabled
        pressObserver.downGate = downGate
        pressObserver.isArmed = isEnabled
        touchObserver.downGate = downGate
        touchObserver.isArmed = isEnabled
        // A move refused as a drift, then the same touch going on to qualify:
        // Home's own exit, since the engine may not try again.
        downGate.onQualifiedAfterRefusal = isEnabled ? onMoveDown : nil
        self.onSwipeLeft = onSwipeLeft
        self.onSwipeRight = onSwipeRight
        self.onMoveDown = onMoveDown
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

    @objc
    private func handlePressDown() {
        guard isSwipeCaptureEnabled else { return }
        onMoveDown()
    }

    private func attachRecognizersIfNeeded() {
        guard let targetView = superview else { return }
        guard attachedView !== targetView else { return }

        detachRecognizers()
        recognizers.forEach(targetView.addGestureRecognizer)
        attachedView = targetView
    }

    private func attachWindowObserversIfNeeded() {
        guard let window, observedWindow !== window else { return }

        detachWindowObservers()
        windowObservers.forEach(window.addGestureRecognizer)
        observedWindow = window
    }

    private func detachWindowObservers() {
        if let observedWindow {
            windowObservers.forEach(observedWindow.removeGestureRecognizer)
        }
        observedWindow = nil
        // Nothing is cleared here on purpose: while the hero pages, the
        // outgoing and incoming slides each hold a capture view on the same
        // gate, and the outgoing one must not end a gesture the incoming one
        // is still tracking. A gesture cut off for good heals by itself: the
        // next touch resets the touch record and presses time out.
    }

    private func detachRecognizers() {
        if let attachedView {
            recognizers.forEach(attachedView.removeGestureRecognizer)
        }
        attachedView = nil
    }
}
#endif
