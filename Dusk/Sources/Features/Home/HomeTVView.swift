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
        /// A hero page's play button, by its item's `storageKey`. Every page
        /// has its own (`HomeCinematicHero.tvPages`).
        case heroPrimaryAction(String)
    }

    /// The hero page on screen, as the hero's own page scroll reports it.
    /// See `heroPrimaryKey(in:)`.
    @State private var visibleHeroKey: String?

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
    /// Whether Select is held on a play button. Fed from UIKit, asked
    /// whenever a down move arrives. See `HomeTVHeroPressGuard`.
    @State private var heroPressGuard = HomeTVHeroPressGuard()

    /// The hero's down-press. See `beginHeroExit`.
    private enum HeroExitPhase {
        case idle
        /// The page is going to the fold and the first shelf's first item is
        /// asked to take focus, and to take it back from any further move
        /// the same gesture delivers.
        case landing
    }
    /// Only `settleFold` scrolls through this, once the page is still. Both
    /// moves between the hero and the shelves are the focus engine's own
    /// scroll; see `HomeTVFoldSnapping` for why nothing else may scroll
    /// alongside one.
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

    private var isHeroPrimaryFocused: Bool {
        if case .heroPrimaryAction = focusedTarget { return true }
        return false
    }

    /// The page whose play button has focus, `nil` while focus is elsewhere.
    private var focusedHeroKey: String? {
        if case .heroPrimaryAction(let key) = focusedTarget { return key }
        return nil
    }

    /// The play button Home hands focus to, and the only one that takes it
    /// from outside the hero: the focused page's while a play button has
    /// focus, otherwise the page on screen.
    ///
    /// Always the page on screen, never one remembered: up from the shelves
    /// can only reach a play button the engine sees above it, and the other
    /// pages' are a page or more to the side. It used to be the page last
    /// focused, reset to the first page whenever Home appeared again. After
    /// a detail page that left the only reachable button off screen while
    /// the hero still showed another page, and up from the shelves did
    /// nothing at all.
    private func heroPrimaryKey(in heroItems: [PlexItem]) -> String? {
        if let focusedHeroKey { return focusedHeroKey }
        if let visibleHeroKey, heroItems.contains(where: { $0.id.storageKey == visibleHeroKey }) {
            return visibleHeroKey
        }
        return heroItems.first?.id.storageKey
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
            let currentHeroKey = heroPrimaryKey(in: heroItems)
            let heroHasFocus = isHeroPrimaryFocused
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
                            // Rotation pages by moving focus to the next page's
                            // play button, and only while a play button has
                            // focus (`focusedItemKey`), so it never pages the
                            // hero out from under focus or behind another tab.
                            autoRotates: true,
                            supportsDragNavigation: false,
                            selectionResetRevision: heroSelectionResetRevision,
                            onMoveDown: { beginHeroExit(heroHeight: heroHeight) },
                            focusedItemKey: focusedHeroKey,
                            onFocusItem: { item in
                                focusedTarget = .heroPrimaryAction(item.id.storageKey)
                            },
                            onVisibleItemChange: { key in
                                visibleHeroKey = key
                            },
                            primaryAction: { item, callbacks in
                                let key = item.id.storageKey
                                return AnyView(
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
                                    .focused($focusedTarget, equals: .heroPrimaryAction(key))
                                    .prefersDefaultFocus(key == currentHeroKey, in: homeFocusScope)
                                    // The other pages' buttons are only reachable
                                    // from a play button (left/right). Coming in
                                    // from the shelves or the tab bar, the engine
                                    // would otherwise pick whichever button is
                                    // nearest, a page away off screen.
                                    .disabled(!heroHasFocus && key != currentHeroKey)
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
                        // Before the offset, so the hint moves with the hero
                        // and centres on the display. An offset only moves
                        // what is drawn: an overlay after it centres on the
                        // un-offset frame, a leading safe-area inset to the
                        // right of the display's centre.
                        .overlay(alignment: .bottom) {
                            scrollHint(isEnabled: hasContentBelowHero)
                        }
                        .offset(x: -leadingContentInset)
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
                    startsAboveFold: heroHasFocus || isHeroShowing,
                    pinsToFold: heroExit != .idle,
                    pressGuard: heroPressGuard
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
                } else if heroExit == .landing, shelvesUnlocked, !isHeroPrimaryFocused {
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
            .background {
                HeroPressObserverAttachment(isArmed: heroHasFocus, pressGuard: heroPressGuard)
            }
            #endif
            .contentMargins(.zero, for: .scrollContent)
            .contentMargins(.zero, for: .scrollIndicators)
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
            .duskTVOSPageBackground()
            .defaultFocus($focusedTarget, .heroPrimaryAction(currentHeroKey ?? ""))
            .onChange(of: focusedTarget) { _, target in
                if case .heroPrimaryAction = target {
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
                // New items start the hero over on its first page by itself
                // (`visibleHeroKey` follows).
                await requestHeroPrimaryFocusIfNeeded(hasHeroItems: !heroItems.isEmpty)
            }
            // The hero is back on its first page (Home reselected, the app
            // reactivated, playback over). A play button that had focus hands
            // it to the first page's, or focus would sit pages away off screen.
            .onChange(of: heroSelectionResetRevision) { _, _ in
                if isHeroPrimaryFocused, let first = heroItems.first {
                    focusedTarget = .heroPrimaryAction(first.id.storageKey)
                }
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
                    subtitle: { isVideoHub ? $0.standardPosterSubtitle : $0.hubPosterSubtitle },
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
            HomeTVScrollHint(isVisible: isHeroPrimaryFocused)
                .padding(.bottom, 60)
        }
        #else
        EmptyView()
        #endif
    }

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
    /// So the press is left alone and overruled instead. It reaches here two
    /// ways, in either order, and the first one wins:
    /// - the hero's `onMoveCommand(.down)`, which fires whether or not the
    ///   engine moved focus;
    /// - a shelf card taking focus while `shelvesUnlocked` is closed, i.e.
    ///   the engine moved down from the play button.
    ///
    /// 1. Pin the page to the fold: `HomeTVFoldSnapping` sends every scroll
    ///    the focus engine makes meanwhile there.
    /// 2. Ask the first shelf's first item to take focus. Usually it already
    ///    has it (the engine's pick is geometric, and the play button sits
    ///    over the first card). Otherwise taking it is a focus change of its
    ///    own, which the engine scrolls to, pinned to the fold as well.
    /// 3. Once it holds focus, open the latch. The landing stays open 250 ms
    ///    more, and any further move of the same gesture that pulls focus
    ///    off the item in that time is answered by asking it again
    ///    (`heroExitFocusGeneration`).
    ///
    /// If the item never answers, the timeout returns focus to the hero.
    ///
    /// Nothing here scrolls. The page's one scroll is the focus engine's,
    /// for whichever focus change comes first. A `scrollTo` used to start the
    /// exit as well: it stacked on the engine's scroll that was already under
    /// way, which bent the move or, when `onMoveCommand` came first, cut from
    /// the hero to the shelves in a single frame (measured in the simulator).
    ///
    /// Not while Select is held on the play button (`heroPressGuard`): a
    /// thumb rolling on the clickpad as it presses Play must not carry focus
    /// to a card. If the engine already moved focus off the play button for
    /// it, focus goes straight back.
    ///
    /// Everything else is the focus engine's call, touch-surface moves
    /// included. Left/right on the hero are ordinary focus moves between its
    /// pages' play buttons, so a sideways swipe never reaches here.
    private func beginHeroExit(heroHeight: CGFloat) {
        guard heroExit == .idle, !shelvesUnlocked, let landingShelf = firstShelfID else { return }
        if heroPressGuard.isHolding {
            if !isHeroPrimaryFocused, !isReturningToHero {
                Task { await requestHeroPrimaryFocusIfNeeded(hasHeroItems: true) }
            }
            return
        }

        heroExitShelf = landingShelf
        heroExit = .landing

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
        if isHeroPrimaryFocused {
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
        focusedTarget = heroPrimaryKey(in: viewModel.heroItems()).map(FocusTarget.heroPrimaryAction)
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
/// the hero several rows past the first shelf, and later made the hero exit
/// jump to the shelves in one frame.
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
    /// mid-press, before any re-render.
    var pressGuard: HomeTVHeroPressGuard?

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        // Only the vertical page scroll, never the shelves' own carousels.
        guard let foldY, foldY > 0, context.axes.contains(.vertical) else { return }
        let proposedY = target.rect.minY

        if pinsToFold {
            target.rect.origin.y = foldY
            return
        }

        if startsAboveFold, pressGuard?.isHolding == true {
            // A move the engine made out of a press on the play button.
            // `HomeTVView` hands focus straight back, so the page stays on the
            // hero rather than dipping to the fold and back.
            target.rect.origin.y = 0
            return
        }

        if startsAboveFold {
            // The page's play button is the only thing on the hero that takes
            // focus, and it is fully on screen at rest. So any real scroll from up
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

/// Whether Select or Play/Pause is held on a hero play button, or was let go
/// less than `releaseGrace` ago.
///
/// A thumb rolling on the clickpad as it clicks Play is enough for the focus
/// engine to move focus down off the small button, and the press then lands
/// on a card. No down move leaves the hero meanwhile
/// (`HomeTVView.beginHeroExit`).
///
/// Nothing reads it to draw, so it is a plain reference rather than state:
/// `HeroPressObserver` writes it from UIKit and `HomeTVView` asks it when a
/// move arrives.
private final class HomeTVHeroPressGuard {
    /// Long enough to cover a thumb rolling off the clickpad after the click,
    /// short enough that a deliberate move straight after never notices.
    private let releaseGrace: CFTimeInterval = 0.3
    /// A press is never held this long: a missed release must not lock the
    /// hero in for good. A long press opens the context menu well before.
    private let maximumHold: CFTimeInterval = 2
    private var pressedAt: CFTimeInterval?
    private var releasedAt: CFTimeInterval = -.infinity

    var isHolding: Bool {
        let now = CACurrentMediaTime()
        if let pressedAt, now - pressedAt < maximumHold { return true }
        return now - releasedAt < releaseGrace
    }

    func pressBegan() {
        pressedAt = CACurrentMediaTime()
    }

    func pressEnded() {
        guard pressedAt != nil else { return }
        pressedAt = nil
        releasedAt = CACurrentMediaTime()
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
/// themselves). It stays **outside** `HomeCinematicHero`'s pages, so it does
/// not scroll away with them.
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

/// Feeds `HomeTVHeroPressGuard` with the remote's Select and Play/Pause
/// presses. Never recognizes and cancels nothing, so the play button gets its
/// press exactly as before.
///
/// It sits on the window: remote presses only reach recognizers on the
/// focused item's own view chain, and a SwiftUI button's focus item has no
/// view of its own (measured in the simulator: a recognizer next to the play
/// button never saw a press).
private final class HeroPressObserver: UIGestureRecognizer {
    weak var pressGuard: HomeTVHeroPressGuard?
    /// A play button has focus. Presses anywhere else are none of the
    /// guard's business.
    var isArmed = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedPressTypes = [
            NSNumber(value: UIPress.PressType.select.rawValue),
            NSNumber(value: UIPress.PressType.playPause.rawValue)
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
        pressGuard?.pressBegan()
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        pressGuard?.pressEnded()
        state = .failed
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        pressGuard?.pressEnded()
        state = .failed
    }

    override func reset() {
        super.reset()
        pressGuard?.pressEnded()
    }
}

/// Keeps a `HeroPressObserver` on the window while Home is on screen.
private struct HeroPressObserverAttachment: UIViewRepresentable {
    let isArmed: Bool
    let pressGuard: HomeTVHeroPressGuard

    func makeUIView(context: Context) -> PressObserverHostView {
        let view = PressObserverHostView()
        view.isUserInteractionEnabled = false
        view.update(isArmed: isArmed, pressGuard: pressGuard)
        return view
    }

    func updateUIView(_ uiView: PressObserverHostView, context: Context) {
        uiView.update(isArmed: isArmed, pressGuard: pressGuard)
    }
}

private final class PressObserverHostView: UIView, UIGestureRecognizerDelegate {
    private lazy var observer: HeroPressObserver = {
        let recognizer = HeroPressObserver(target: nil, action: nil)
        recognizer.delegate = self
        return recognizer
    }()
    private weak var observedWindow: UIWindow?

    func update(isArmed: Bool, pressGuard: HomeTVHeroPressGuard) {
        observer.pressGuard = pressGuard
        observer.isArmed = isArmed
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window, observedWindow !== window else { return }
        observedWindow?.removeGestureRecognizer(observer)
        window.addGestureRecognizer(observer)
        observedWindow = window
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil {
            observedWindow?.removeGestureRecognizer(observer)
            observedWindow = nil
        }
        super.willMove(toWindow: newWindow)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
#endif
