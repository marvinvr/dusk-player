# Dusk UI Feature Layer

Operational notes for agents changing SwiftUI screens, feature view models, and shared UI
in Dusk. Read this with `docs/codebase-map.md`, `STYLE.md`, and `docs/data-and-plex.md`.

## App And Navigation Shell

- `DuskApp` creates the long-lived app services and injects them into the SwiftUI
  environment: `PlexService`, `PlaybackCoordinator`, `DownloadManager`,
  `OfflinePlaybackSyncManager`, `SeerrService`, and `UserPreferences`.
- App-wide color scheme comes from `UserPreferences.appearanceMode`. There is no
  root `.tint`: the global `AccentColor` asset is the label colour, so system
  controls, navigation buttons and the tab bar selection are neutral and adapt
  over both artwork and light content backgrounds.
- `ContentView` is the account-bootstrap root gate: unauthenticated users see
  `SignInView`; signed-in Plex Home accounts are checked and, when needed, show
  `HomeUserPickerView`; an active Home identity enters `MainTabView`. **There is
  no server step in onboarding.**
- Connecting is not a gate. `ServerConnectionCoordinator` (injected into the
  environment by `ContentView`) connects every enabled server in parallel while
  the shell is already on screen; each server's content appears as it answers.
  Keep connection logic there — do not spread `connectAllServers()` calls into
  feature screens; call the coordinator's `refresh()` for a retry instead.
- A connect pass runs on first mount, on a profile switch, on return to the
  foreground, and on a network-path change. Passes are deduplicated and a fresh
  one is skipped for a minute unless the pool has nothing usable.
- Home selection precedes connecting because each Home identity can expose a
  different resource list. A successful switch reconstructs the main shell so
  navigation paths and feature view models cannot retain the previous user's data.
- Server trouble is never a modal or a full-screen blocker. All servers off is a
  distinct empty state; nothing reachable is an inline error with Retry and a way
  into Server Priority; a partial outage is an unobtrusive inline note. Downloads
  stay reachable in every case. A pool that never got as far as producing server
  states (discovery itself failed: no internet, fresh install) shows the same
  inline error once the coordinator's first pass has finished — `unknown` is only
  a spinner while a pass is actually running.
- `MainTabView` owns one `NavigationPath` per tab so tab stacks stay independent.
- Re-selecting the active tab pops that tab to root.
- Available tabs are data-driven: every present and user-visible library type
  (Movies, TV Shows, Videos) plus Live TV when discovered gets its own tab in
  the user's preferred order, and
  Downloads appears only when visible and populated. Library-tab visibility and
  order are local `UserPreferences`; missing preferences preserve the original
  all-visible Movies / TV Shows / Videos / Live TV order.
- Videos ("Other Videos" / clip sections, `PlexLibraryType.video`) only counts as
  present once a section is known to hold items: `LibrariesViewModel` counts each
  video section (`getLibraryItemCount`) and keeps empty or not-yet-counted ones out
  of `libraries`, so an empty section never shows a Videos tab. A failed count shows
  the section; a cancelled one is retried on the next load. Settings › Libraries ›
  Navigation Tabs hides any destination, Videos included.
- iOS/iPadOS use the modern native `Tab` API with SF Symbols and open Search
  from a circular trailing toolbar action on Home and immediately before Browse
  on each library root, leaving Search out of the tab bar. iPadOS keeps every
  remaining destination flat. On iPhone, Home plus the first three visible
  content destinations stay flat and overflow content, Downloads, and Settings
  move into `MoreView` so the tab bar stays at five items. tvOS remains flat
  with a Search tab and no Downloads tab.
- If a preference or availability change crosses the iPhone five-tab limit,
  keep the currently selected flat destination or `MoreView` mounted until the
  user selects another tab. Replacing the active container immediately tears
  down its `NavigationStack` mid-push; defer the new flat/folded layout and clear
  the retired path when leaving it.
- The tvOS tab shell forces monochrome symbols and a label-color tab bar tint
  (`Color.duskTVTabBarTint`: `TextPrimary` in Dark mode, black in Light mode).
  tvOS draws the selected, unfocused item's icon and title in the bar's tint, so
  a dark tint in Dark mode reads as black-on-black; the focused item's contrast
  against the focus plate is handled by the system, not by the tint.
- That tint is pinned on the real `UITabBar`, at launch through the appearance
  proxy and again from the shell on every update (`DuskTVTabBarTintPin`), and a
  zero-size sentinel subview inside the bar re-pins on every `tintColorDidChange`
  UIKit reports. SwiftUI's `.tint` on a tvOS `TabView` is not sticky: a bar that
  falls back to the inherited window tint picks up the global accent color
  after returning from a detail screen or the player. That accent
  (`AccentColor`) is the same label colour, so a fallback looks identical. The
  shell clears the bar's tint off the tab content (`.tint(nil)`): an inherited
  explicit tint makes tvOS system glass buttons go white-on-white on focus.
- tvOS Back (Siri Remote Menu) at a tab root goes to Home, and on Home
  scrolled down it returns focus to the hero; only Home at its top leaves the
  app. `MainTabView.rootBackAction` decides, `DuskTVRootBackInterceptor` (a
  Menu-only tap recognizer on the `UITabBarController`'s view) catches the
  press with focus in the content or on the tab bar. The recognizer refuses
  the press whenever the selected tab has a pushed screen, checked on the real
  `UINavigationController` because Settings rows push with
  `NavigationLink(destination:)`, outside the tab's `NavigationPath`.
  `onExitCommand` cannot do this: it never sees Back with focus on the tab bar.
- `AppNavigationRoute` is the shared route enum. Add new top-level destinations there
  only when multiple features need to navigate to them.
- Use `NavigationLink(value:)` with `AppNavigationRoute` for media/person/library flows.
- Attach `.duskAppNavigationDestinations()` inside each tab `NavigationStack`; it maps
  routes to concrete destination views with environment services.
- Detail routing enters through `MediaDetailDestinationView`, which dispatches by
  `PlexMediaType` and passes download/offline context through.
- Playback presentation is centralized in `MainTabView` through
  `PlaybackCoordinator.showPlayer` and `PlayerView`; feature screens should call
  `playback.play(...)` or `playback.playVersion(...)`, not present the player.

## Shared UI Primitives

- Prefer shared primitives before adding feature-local copies.
- Loading, empty, and retry states belong to `FeatureLoadingView`,
  `FeatureEmptyStateView`, and `FeatureErrorView`.
- `FeatureErrorView` shows Retry for ordinary failures. Messages that mean the
  Plex account session is dead (`PlexServiceError.unauthorized` /
  `.notAuthenticated`) replace Retry with Sign In, which calls `signOut()` so
  `ContentView` presents `SignInView`. Do not add a local retry button for those
  errors. Successful re-auth is a new session; it does not resume the failed
  screen or playback.
- Poster UI is layered: `PosterArtwork`, `PosterCardText`, `PosterCard`,
  `PosterNavigationCard`, and `PosterActionCard`.
- Fully watched items (e.g. fully watched seasons) pass `isWatched` to the poster
  card to add a small checkmark to the subtitle line, in the subtitle's own colour
  (never a colour — a fully watched row must not become a wall of badges);
  suppress the progress bar in that case (pass `progress: nil`) so completion
  reads as the checkmark, not a full bar. A partially watched season passes
  `unwatchedCount` instead: `UnwatchedCountBadge` draws the count as the system
  `N.circle.fill` symbol in the checkmark's slot, at its size and colour (iOS
  season cards and tvOS season pills). Partial progress still renders the bar
  (`DuskPosterMetrics.posterProgressBarHeight`), white on a dark track like the
  TV app, everywhere.
- Blur Unwatched Episodes (Settings › Appearance,
  `UserPreferences.blursUnwatchedEpisodes`, off by default, issue #15) reaches
  views as `\.blursUnwatchedEpisodes` (set in `DuskApp`). An image that is an
  unwatched (not fully watched, so in-progress counts) episode's **own still**
  goes through `spoilerBlur(_:)` (`PosterCard.swift`): a local SwiftUI blur sized
  to the frame's short side, plus a centred `eye.slash` that takes the play
  glyph's place. Pass the flag only when the chosen path really is the episode's
  `thumb`: show posters/backdrops inherited onto the episode are never spoilers.
  Wired: `PosterArtwork`/`PosterActionCard` (`isUnwatchedEpisodeImage`), CW
  shelves (`landscapeImageIsUnwatchedEpisodeStill`), iOS season rows, tvOS
  series episode cards, detail hero backdrops (`blursBackdrop`, no glyph; the
  retained tvOS backdrop keeps the blur of the image it holds), Up Next card and
  overlay, and the Top Shelf fallback (blur baked into the JPEG). The local
  blur is deliberate over Plex's transcoder: it also covers downloaded artwork
  and never depends on a server honouring a parameter. Not covered: posters
  (show poster first), the player's loading backdrop and scrub previews.
- Use `PlexItemPosterCarouselSection` for horizontal shelves and
  `PlexItemPosterGrid` for grids. They already handle image sizing, context menus,
  progress, and route creation. Watch state comes from the item Plex sent with
  the row (no extra request): `progress` defaults to `PlexItem.posterProgress`
  (`viewOffset`) and the checkmark to `PlexItem.posterIsWatched` (played
  movie/episode/clip, or a show/season with every episode watched), so every
  Home/library hub row and grid shows them, not only Continue Watching. Both take `imageAspectRatio` (default 2:3); pass
  `16.0/9.0` for clip content so the requested transcode size matches the display
  aspect — a 2:3 request would be cropped server-side.
- Clip rendering is item-driven: `PlexItem.isClip` (item `subtype == "clip"`) and
  the `Collection.isAllClips` helper decide when a row/grid renders 16:9 with
  `DuskPosterMetrics.videoCarouselWidth`/`videoGridPreferredWidth`. Clip card
  subtitles show the full localized upload date and compact duration via the
  clip-aware `standardPosterSubtitle`; uploads from the last week also prefix
  relative context (for example, `2 days ago · 17 Jul 2026 · 12 min`).
- Context menus for partially watched playable items should expose both watch-state
  endpoints: mark watched and mark unwatched. Do not collapse partial progress into
  a single toggle action.
- Use `MediaCarousel` for generic horizontal sections. It renders only the section
  title; it has no header accessory slot, so do not reintroduce buttons beside the
  title. Its horizontal padding can be overridden when a page needs its shelves to
  share the system navigation title's leading edge.
- A shelf's "Show all" destination is `ShowAllCarouselTile`, rendered by
  `PlexItemPosterCarouselSection` / `PlexItemActionCarouselSection` as the **last
  card** of the shelf on **every** platform — a dashed card sized like the shelf's
  artwork (`imageAspectRatio` aware), so the destination reads as content instead of
  a cramped header button. Pass `showAllRoute` only when the shelf is actually
  truncated; a nil route simply omits the tile.
- Use `AdaptivePosterGridLayout.make(...)` for responsive poster grids. Do not hand-roll
  column math in feature files.
- Use `DuskPosterMetrics` for platform-sensitive poster widths, grid spacing,
  horizontal padding, and detail padding. Its `titleFont` / `subtitleFont` are thin
  forwards to `DuskFont.cardTitle` / `DuskFont.cardSubtitle`, so card text is styled
  by the type scale, not by the metrics struct.
- Use `DuskFont` (`Shared/DuskTypography.swift`) for **all** type. tvOS views go
  through `DuskFont` and never use raw semantic text styles (`.headline`, `.title3`,
  `.caption`, …), which resolve 2.1–2.7× larger on tvOS than on iOS. Each token takes
  the call site's current iOS style — `DuskFont.sectionHeader(ios: .title3.bold())` —
  and returns it unchanged off tvOS, so iOS rendering never moves. tvOS-only paths use
  `DuskFont.TV.<token>`; layout structs that store point sizes use
  `DuskFont.TV.Size.<token>`; sites where iOS deliberately applies no font use
  `.duskFont(tvOnly:)`. The full token table lives in `STYLE.md` §3.1.
- Use `MediaTextFormatter` for duration, season/episode labels, counts, progress,
  media type icons, air dates, and playback version labels.
- Use `PlexItemPresentation` helpers for standard poster subtitles, continue-watching
  labels, poster progress, and image URL selection.
- Use `DuskAsyncImage` for Plex artwork. It integrates app image caching and can route
  Plex image requests through `PlexService` when needed.
- Use `DetailHeroBackdrop` with `DuskHeroBackdropOverlay` for full-bleed hero artwork,
  and always apply `duskHeroBackdropBottomFade()` to the backdrop + overlay stack.
  The overlay owns the shared top and leading scrims; the bottom fade into the page
  is platform-split: on iOS the overlay paints a `Color.duskBackground` gradient and
  cap, on tvOS the modifier instead masks the hero to fully transparent so the page
  background underneath is the only fill at the hero boundary. The modifier's style
  picks the tvOS mask curve: `.standard` (the default) for detail heroes, `.compact`
  for a shorter, lighter fade that reveals more of the backdrop, and `.fullBleed` for
  a hero that owns the whole display — it holds full strength to ~86% and only
  vignettes across the last stretch. Every case must still reach, and hold, zero
  alpha before the hero's bottom edge; that is what makes the HDR seam impossible.
  On iOS the overlay's own scrim strength is selectable via its `style`: the iPhone home
  hero keeps the default `.standard`, the regular-width iPad home hero uses `.cinematic`
  (short top band for the status bar/toolbar, nearly clear middle, darkening and the
  `duskBackground` fade held to the lower third), while the movie/show/season/episode detail heroes pass
  `.soft` to hold the darkening and bottom fade off until the lower third so more of the
  backdrop reads through behind the title block. `.standard` and `.soft` differ on iOS
  only — on tvOS both render the long-standing full-strength vertical scrim. The one
  overlay style that changes tvOS is `.cinematic` (0.10 → 0.20@55% → 0.62@82% →
  0.88), used **only** by the home hero (full-screen on tvOS, near-full-screen on iPad) so the artwork stays nearly
  unscrimmed above the title block; the shared leading ramp is unchanged. Do not
  repoint the detail heroes at it.
  Never paint `Color.duskBackground` (gradient or solid) inside a hero subtree on
  tvOS: real Apple TV HDR output resolves hero-subtree fills and the plain page
  background through different color pipelines, so two stacked fills of the same
  color still meet with a visible seam and gray mismatch on hardware even though
  every simulator renders them identically. Fading the hero to zero alpha is the
  only seam-proof topology.
  When a detail hero swaps artwork from focus changes, opt into retaining the previous
  backdrop while the next one loads instead of clearing the image.
- When the iOS Home cinematic hero is visible, keep the tab bar color scheme dark.
  The floating iPad tab bar can sit over hero artwork, so its selected label must
  resolve against the tab bar material instead of the page's light appearance.
- On tvOS, each horizontal hub row (`MediaCarousel`, and the Live TV shelf) is a
  `.focusSection()` on the scrolling row. Up or Down from any card moves to the
  nearest item in the neighbouring row. Do not send that move through the leading
  card: once the row has scrolled, geometry only finds a neighbour above the first
  item (issue #24). The same section is on the show page's episode row.
- Library and View All grids (`PlexItemPosterGrid`) are one `.focusSection()` per
  row on tvOS, not one `LazyVGrid`. A short last row keeps a focus guide in the
  empty columns, sized like the missing posters, so the section extends under them
  and Down from a column with no cell lands on the nearest poster in that row.
  iOS stays a `LazyVGrid`.
- On tvOS, library poster cells (`PosterNavigationCard` and `PosterActionCard`,
  shared by library grids, hub rows, collections, and search) use
  `duskTVOSSystemPosterButton()`: `.buttonStyle(.card)` and a rounded-rectangle border
  matching `PosterArtwork.cornerRadius`. That is the system lift, scale, parallax,
  and shadow. Keep the title outside the button. Do not apply
  `duskSuppressTVOSButtonChrome()`, `duskTVOSFocusEffectShape`, or
  `focusEffectDisabled()` to these cells — a custom button style replaces the system
  effect. **Never add `.hoverEffect(.highlight)` on top** (on the button or its
  label): the card style already is that effect. Stacked on every poster in 1.7.4
  it roughly doubled Home's main-thread work per frame (measured on a tvOS
  simulator Release build: hero paging and the move down into the shelves went
  from ~160 to ~450 ms of dropped frames per press), and it flattened the card's
  lift into a plain sheen. iOS keeps `.buttonStyle(.plain)` so the iPad pointer hover stays the system one.
- Episode and cast artwork still use `duskSuppressTVOSButtonChrome()` plus
  `duskTVOSFocusEffectShape`. Avoid SwiftUI's `.plain`, `.borderless`, `.glass`, and
  `.card` button styles on those controls because real Apple TV hardware can draw
  gray/white system focus plates behind non-poster artwork. When those cards have
  labels below the artwork, keep the artwork as the actual control and apply
  `duskTVOSFocusedScale` to the outer card so it grows with a tight neutral white glow.
- Use platform helpers in `View+Platform.swift` instead of scattering `#if os(tvOS)`:
  `duskNavigationTitle`, title display modes, list background/separator suppression,
  status-bar helpers, tvOS button chrome suppression, the system poster button, and
  tvOS focus effect shape.

## Home

- `HomeView` is the tab root. It owns `HomeViewModel`, handles loading/error state,
  refreshes on appear, scene activation, and player dismissal, then delegates layout to
  `HomeIOSView` or `HomeTVView`.
- The cinematic hero always resets to its first item after player dismissal, app
  activation, Home-tab re-entry, or a change to the hero item order. Keep the explicit
  reset revision flowing from `HomeView` through both platform shells so a Plex refresh
  cannot preserve a stale selection after Continue Watching reorders.
- `HomeViewModel` owns ordinary Plex Home calls. The separate shared
  `LiveTVViewModel` owns the optional, non-blocking Live TV Home shelf.
- `HomeView` keys its load context by the active Plex Home profile and the server
  set it is showing (`serverPriority.revision` plus the connected servers),
  and installs a fresh `HomeViewModel` whenever that context task starts. Keep the
  profile in this identity: Home users commonly share a server ID, and retaining
  the outgoing model can let its in-flight load suppress the incoming user's load.
- Home data combines global hubs from `getHubs()`, continue watching from
  `getContinueWatching()`, and personalized shelves from `HomeRecommendationEngine`.
- Settings › Home › Personalized shelves is a device-local switch, on by default.
  `HomeView` passes it into `HomeViewModel` and applies changes immediately: off
  clears generated shelves, cancels their task and skips recommendation loading
  on subsequent refreshes; on reloads them. Cancellation and a publication guard
  prevent an old request from restoring shelves after they were disabled. Plex
  hubs, Continue Watching, and library-tab recommendations are unaffected.
- `HomeHubArrangement` places library rows in Library Order even when PMS omits
  the hub's section ID: it uses the paging URL, numeric identifier suffix, or
  consistent item section IDs from the representative server. Unscoped Recently
  Added rows can also use the only matching library type on that server. Ambiguous
  rows remain global; mixed/global rows such as Continue Watching keep their place.
- tvOS Home shows the time at the top right, level with the tab bar (`HomeTVClock`,
  `TimelineView(.everyMinute)`, system 12/24 h format), fading out with the tab bar
  when the page scrolls. Settings › Home › Show Clock (`UserPreferences.showsClock`,
  on by default; tvOS only).
- `LiveTVHomeShelf` adds currently airing channels when Live TV is available and
  `UserPreferences.showsLiveTVOnHome` (Settings › Home › Show Live TV, off by
  default) is on. When off, Home neither renders the shelf nor requests the
  now-playing lineup; the Live TV navigation tab is unaffected. Its
  discovery/load failure must not replace or delay normal Home content.
- Home publishes the base hub and continue-watching payload first, then expands
  Recently Added hubs and loads personalized shelves through cancellable follow-up
  tasks. Keep this two-phase behavior so expensive recommendation work does not block
  the first visible home content.
- Continue-watching items drive `HomeCinematicHero`. Settings › Home Advanced ›
  Compact Continue Watching (`UserPreferences.compactHomeContinueWatching`, off by
  default) swaps the hero for `HomeContinueWatchingShelf`, the library pages'
  `PlexItemActionCarouselSection` row, as the first shelf. Both shells then take
  their no-hero path (iOS large "Home" title; tvOS "Home" header, no fold snapping
  or hero focus), so nothing is shown twice.
- Home filters playlist/music/unknown content and hides Plex "continue watching/on deck"
  hubs so the custom continue-watching flow is not duplicated. That rule lives in
  `HomeHubFilter` (`HomeHubFilter.swift`).
- Home's arrangement is fixed and identical on both platforms: the cinematic hero,
  the Live TV shelf (when enabled), the Plex hubs, then the personalized shelves. `HomeIOSView` and
  `HomeTVView` each render that sequence directly. There is no user-editable Home
  layout; do not reintroduce one. Which Plex rows appear is Plex's per-library
  Home flag (see Hidden Rows below), not a Dusk layout.
- Home is **merged across every connected server**. `HomeViewModel.load()` fans
  `/hubs` and `/hubs/continueWatching` out to all of them. **The first paint is gated
  by `HomeFirstPaintGate`** (`HomeFirstPaintGate.swift`): painting the first server's
  answer at once made Home jump when a later server brought Continue Watching, and so
  the cinematic hero, along with it. Once there is content, the loading view stays up for a short
  grace (`settleGrace`, 500 ms) so the other servers, including ones the pool is still
  connecting, and the library order can catch up. Only while a server that had
  hero items the last time Home settled (`HomeContinueWatchingMemory`, per profile in
  UserDefaults) is still missing *and* nothing in hand has any does it wait longer.
  Nothing is held past `patience` (3 s from when Home started waiting; the gate
  survives a load superseded by a server connecting). After the first paint, late
  servers fold in as they answer. The memory is a hint: it is rewritten on every
  settled merge, so a server that stops answering stops being waited for. No skeleton
  is shown, on purpose. **Once there is content on screen (a tab return, a
  pull-to-refresh, another server connecting) the merge is published in one go
  instead.** A merge missing the servers that have not answered yet is a *smaller*
  screen than the one already there, and swapping between the two is what made
  pull-to-refresh look like content jumping between servers. The merge (`HubMerge`, `ContinueWatchingMerge`) is a
  pure function of the per-server answers in priority order, so each publish refines the
  same list. With one server both merges return their input verbatim. Every merge
  registers its findings in `plexService.alternates` for playback fallback.
- Initial load, tab return, scene activation, player dismissal and pull-to-refresh all
  go through the **same** `load()`. It bumps `loadGeneration`, supersedes the previous
  load, and runs the work in an unstructured task the view model owns, awaiting only its
  value. That last part is load-bearing: `.refreshable` runs its action in a task SwiftUI
  cancels freely, and a load cut off half way would leave Home on the merge of whichever
  servers answered first — and skip the library-order pass, the Recently Added expansion
  and the personalized shelves. `LibraryRecommendationsViewModel.load()` is built the
  same way for the same reason.
- A server that *fails* a Home request is not a server that answered with nothing.
  `HomeServerPayload` carries `nil` for a failed request and the view model keeps that
  server's previous answer (`lastPayloads`, dropped when the server leaves the pool or
  the Plex Home profile changes), so a timeout during a refresh cannot make one server's
  rows blink out and back.
- Home reloads on `plexService.serverContentRevision` (`.task(id:)`), never on a single
  server identifier: the tab shell mounts before anything is connected.
- Home never labels a row with the server it came from — with every server merged into
  one screen that is noise. The only server wording is `ServerOutageNote`, a quiet line
  naming enabled servers that are currently offline. The old server-name subtitle
  (iPhone) and tvOS header subtitle are gone.
- Within the hubs, `HomeHubArrangement.arrange(hubs:libraryOrder:)` regroups the rows
  so each library's hubs appear in the order the account gives that library.
  `libraryOrder` is a list of **`PlexLibrary.id`** (`"<serverID>|<key>"`), and a row is
  placed by `PlexHub.representativeLibraryID` — its own server, or the highest-priority
  source of a merged row. Never key this on the bare section key: two servers' "3"
  sections would share a block. It is a pure permutation — global rows first, then one
  block per library in library order, then rows whose section is unknown. `libraryOrder`
  must be built from *every* section, including music and photo, or the blocks drift.
- Recently Added hubs are expanded through `PlexService.mergedHubItems(for:size:)`,
  which pages **each contributing server's** hub key and re-merges, so shelf limits are
  intentional and "Show all" (`.hub`) shows the whole merged row rather than the
  primary server's share of it. `PlexHub.isPageable` / `hasMoreOnAnySource` /
  `totalSourceSize` are the merged-row equivalents of `key` / `more` / `size`.
- TV Recently Added rows hold seasons and episodes, not just shows: a new episode in an
  old show arrives as that season (or episode). Poster cards (`PlexItemPosterCarouselSection`,
  `PlexItemPosterGrid`) title them by their show (`PlexItem.posterCardTitle`) with the
  numbering underneath (`hubPosterSubtitle` on Home: "Season 6", "S6 · E3"), and a
  season whose own poster fails to load falls back to the show's (`fallbackPosterPath`
  → `DuskAsyncImage(fallbackURL:)`): Plex can send a season poster path even when the
  season has none (unconfirmed against a real PMS; the show poster also covers any other failure). Home keeps one card per show in Recently Added (`oneCardPerShow`).
- `HomeCinematicHero` owns hero rotation, drag navigation on iOS, tvOS focus-driven
  paging, image preloading, title-logo fallback, pager state, and motion
  reduction. iOS enables automatic rotation (`autoRotates: true`): the hero advances
  every 7s and the pager pills animate a fill that tracks the timer. The hero pauses
  rotation while `PlaybackCoordinator.showPlayer` is true and restarts it fresh on
  return, so opening the player no longer advances the hero in the background.
  Rotation also respects Reduce Motion, scene phase, and drag interaction.
  The hero is Home's only Continue Watching surface (iOS shows every item, tvOS
  caps at 10), so the pager is a `UIPageControl`-style sliding window
  (`HomeHeroPagerWindow`): at most `pagerMaxVisibleItems` pills (iPhone 7,
  iPad 9, tvOS 10), the current one centred, the outer two shrunk on a side with
  more items beyond. On iOS it is one adjustable accessibility element. The
  pager is an `.overlay` of the hero so it can never size it: as a `ZStack`
  sibling, one pill per item once widened the hero past the screen.
  **tvOS pages natively, through focus.** On tvOS every hero item
  is a full-width page of one horizontal `ScrollView` (`HomeCinematicHero.tvPages`,
  a plain `HStack`: the page focus moves to must exist before it is on screen), and
  every page has its own play button. Left/right is an ordinary focus move to the
  neighbouring page's button. The page scroll is `.scrollDisabled`, so the engine
  does not reveal the new button itself (its reveal took ~0.9s, mostly a slow creep);
  the hero slides to the focused page with `tvPageSlide` (0.5s ease-out) instead.
  Never let both scroll: they stack. Clicks and
  touch-surface swipes are therefore handled like any row of cards, and the pager
  pills follow the scroll offset. Past either end page the engine has no move, so
  the hero's `onMoveCommand` wraps around to the other end by moving focus there
  (`onFocusItem`). The page slide that follows focus (`slideToPage`) only animates
  to a neighbouring page: to any page further away (the wrap, rotation returning to
  the start) it would sweep across every full-screen page in between. It jumps
  there unanimated instead and cross-fades the page it left (an overlay copy
  without buttons, its action row stood in for by a spacer of the measured height). That command fires for every move, also after the engine has
  moved focus, and `focusedItemKey` may or may not have caught up yet (both seen
  in the simulator); only a move on an end page that is also at rest on screen
  (`currentHeroIndex`, which follows the scroll) wraps. Rotation is on
  (`autoRotates: true`, the same 7s as iOS) and advances the same way, by moving
  focus to the next page's button, so it is always the engine's own move and
  scroll. It only runs while a play button has focus (`focusedItemKey`): focus in
  the shelves, on the tab bar, in another tab or in the player holds it, and focus
  coming back to a play button, or any left/right move, starts a fresh interval.
  Playback, scene phase, Reduce Motion and the context menu pause it as on iOS.
  This replaced a single
  slide paged by `onMoveCommand`: with nothing focusable left or right of the only
  play button, the engine had no horizontal move to make, and the arc of a sideways
  swipe on a real remote ended as a move down into the shelves, which no gesture
  threshold fixed. Rotation was off on tvOS from 2026-05 to 2026-10 because the
  old single slide tore down the focused button on every advance. On iOS discrete hero moves still use the two-slot slide
  model: mount the incoming slide at its off-screen offset before advancing
  animation progress, and queue overlapping moves behind the in-flight slide.
  Backdrops are decoded off the main thread (`byPreparingForDisplay`) during
  prefetch so the first frame of a page never stalls on a JPEG decode. Publish
  prefetched artwork as each request completes; waiting for the entire batch lets
  one slow image make other pages pop in late. Extend it carefully; it is stateful
  and timing-sensitive.
- On iPad (regular width) the home hero uses `HomeCinematicHeroLayout.iPad`: it fills
  the scroll viewport down to the bottom inset (`heroHeightFactor: 1`), so at rest only
  the first shelf's header and poster tops peek in below it — that peek is iPad's
  scroll affordance. Portrait is capped at a square (`maxHeightToWidthRatio: 1`) so a
  16:9 backdrop isn't cropped to a sliver. iPhone and compact-width iPad multitasking
  keep `.ios`. `HomeIOSView.heroLayout` makes the choice.
- On tvOS, `HomeCinematicHero` pixel-aligns its render size and caps image dynamic
  range to standard to avoid real-device HDR/SDR seams between the backdrop fade and
  the shelves below.
- **On tvOS the home hero is full-bleed: it occupies the entire display and nothing
  else is on screen at rest.** This replaces the older "leave the first shelf peeking"
  rule — discoverability now comes from an explicit scroll hint plus fold snapping,
  not from a cropped shelf.
  - `HomeCinematicHeroLayout.fillsContainerHeight` (set only by `.tv`) makes the hero
    take the container height verbatim, with no `topInset` addition — the caller has
    already sized the container to the whole display. `HomeTVView` builds that size
    from `fullDisplayWidth` / `fullDisplayHeight`, floored at
    `geometry.size + safeAreaInsets.top + .bottom`. While there is a hero, the scroll
    view itself ignores the top safe area (no top content inset, no negative content
    padding): that is what puts the artwork at screen y = 0, and it makes content y
    equal the scroll offset, which the fold snapping relies on. Keep the explicit
    frame/offset width handling and `.contentMargins(.zero…)` — do not swap either
    for `containerRelativeFrame`.
  - The `.tv` paddings are measured from the real display edges: the text block
    sits just above the pager (124pt of bottom padding; the hint is bottom-centre
    and the block's lowest element is the narrow leading play button, so only the
    pills need clearing), the pager sits at
    60pt overscan + ~18pt so its pills share a baseline with the hint, and the logo
    caps grow to 640×150 for a 1920-wide frame. The backdrop is centre-aligned
    because 16:9 artwork now lands in a 16:9 box.
  - `HomeTVScrollHint` (tvOS-only, defined in `HomeTVView.swift`) is the "More" +
    `chevron.down` affordance, attached as an `.overlay(alignment: .bottom)` on the
    hero **after** the width frame and **before** the x-offset, so it moves with the
    hero and centres on the true screen, and padded 60pt off the bottom. An offset
    only moves what is drawn: attached after it, the hint centred on the un-offset
    frame, one leading safe-area inset (80pt) right of centre (measured). It is decoration: non-focusable, `allowsHitTesting`
    off, `accessibilityHidden`, with a gentle chevron bounce that is skipped under
    Reduce Motion, faded out (0.25s) whenever focus is not on a hero play button,
    and omitted entirely when there is nothing below the hero. Keep it out of
    `HomeCinematicHero`'s pages so it does not scroll away with them.
  - **Hero focus.** `HomeTVView.FocusTarget.heroPrimaryAction(storageKey)` names a
    page's play button. `heroPrimaryKey(in:)` is the focused page while a play button
    has focus, otherwise the page on screen (`visibleHeroKey`, reported by the hero
    from its page scroll through `onVisibleItemChange`). Every other page's button
    is `.disabled` unless a play button has focus, so coming in from the shelves or
    the tab bar lands on the page on screen rather than whichever button is nearest
    a page away. That is not the fencing warned against below: the hero's focus
    section always keeps one enabled item. **Never key that button on a remembered
    page.** It used to be the page last focused, reset to the first page whenever
    Home appeared again (its `.task` reruns after a detail page). With the hero on
    any other page, the only enabled button was then a page or more to the side,
    and up from the shelves did nothing (reproduced in the simulator: down, into an
    item, back, up). A hero reset (`heroSelectionResetRevision`, new hero items)
    sends the page to the start, and a play button that had focus hands it to the
    first page's.
  - **Hero → shelves: the focus engine's move is overruled, never fenced**
    (`HomeTVView.beginHeroExit`). Measured in the tvOS simulator with a replica of
    this screen (SwiftUI hero + rows of lazy `NavigationLink` cards, driven by
    `XCUIRemote`, UIKit focus logged through `UIFocusSystem.didUpdateNotification`):
    - `onMoveCommand(.down)` on the hero fires on **every** down-press, also when
      the engine already moved focus to a card (card focus first, then the
      command). It is not a "no target" fallback.
    - A region with nothing focusable in it — every card `.disabled`, or a lazy
      row with nothing realised yet — is stood in for by a focusable
      `UIKitFocusableFillerItem`. A down-press moves focus into that filler, the
      play button's `@FocusState` drops to nil, and UIKit then re-resolves focus
      on its own. That re-resolution is the "third card" / "fifth row, first
      column" landing. Three rounds of `.disabled` fences (other shelves, then
      other cards, then everything) each fed it. **Never disable shelves or cards
      to steer the focus engine.**
    - The engine's pick is geometric (play button over card 3 → card 3), so a
      pick that does not match the layout is a filler re-resolution.
    So the press is left alone and its result replaced:
    - `beginHeroExit` starts from either the hero's `onMoveCommand(.down)`, or
      from a shelf card taking focus while
      the latch is closed (`CarouselItemFocusedKey`), whichever comes first (the
      simulator shows both orders). It pins the page to the fold (`pinsToFold`)
      and sets `carouselLeadingItemRequest = .focus`
      on `firstShelfID`'s shelf (`.landing`). That shelf's first item takes focus
      through its own `@FocusState` (`carouselLeadingFocusTarget()`), after the
      row is rewound so the lazy stack has it. It reports through
      `CarouselLeadingItemFocusedKey`, which opens the latch once; the landing
      stays open 250ms more (a one-shot deadline), and if a further move of the
      same gesture pulls focus off the item in that time, Home asks it again by
      bumping `carouselLeadingFocusGeneration` — Home, not the item, so a request
      Home has just withdrawn (focus went back up to the play button) is never
      answered by a stale re-assertion. If nothing answers within 1.5s focus
      returns to the hero: the page was pinned to the fold throughout, so whatever
      card the engine picked may be off screen. The landing shelf is fixed when
      the exit starts (`heroExitShelf`); Back, a hero focus reset, focus returning
      to the play button, and Home disappearing go through `cancelHeroExit`, and
      `requestHeroPrimaryFocusIfNeeded` suppresses the card-focus trigger while it
      runs (`isReturningToHero`).
    - **Down from the hero is the focus engine's call**, touch-surface moves
      included; there is no gesture gate. The one exception is
      `HomeTVHeroPressGuard`: while Select / Play-Pause is held on a play button,
      or for 300ms after (a thumb rolling on the clickpad as it clicks Play), a
      down move is refused, focus goes back through
      `requestHeroPrimaryFocusIfNeeded`, and `HomeTVFoldSnapping` holds the page at
      the hero meanwhile so it does not dip to the fold and back. The guard is fed
      by `HeroPressObserver`, a never-recognizing recognizer on the **window**:
      recognizers next to the play button never see remote presses (measured in
      the simulator). An earlier catch strip under the play button plus a
      touch-travel/velocity gate (35c8427, f3b2cea) were removed with the move to
      native paging: sideways swipes were the moves they misjudged.
    - `shelvesUnlocked` is **latched**: it means "focus has settled below the
      hero". It drops when focus is back on the play button and stays open while
      there is no hero. It drives `settleFold` and the engine-driven trigger
      above, nothing else.
    - A carousel that can be Home's first shelf must apply
      `carouselLeadingFocusLock(leadingInset:)` to its scroll view,
      `carouselItemFocusLock(isLeadingItem:)` to each item, and
      `carouselLeadingFocusTarget()` to each item's focusable view.
      `MediaCarousel` + the poster cards, `ShowAllCarouselTile`, `LiveTVHomeShelf`,
      and `ServerOutageNote`'s Retry button do. `firstShelfID` must mirror
      `shelves()`, including `LiveTVHomeShelf`'s "nothing on now" check.
  - **Shelves → hero is the focus engine's own scroll, bent by a
    `ScrollTargetBehavior`** (`HomeTVFoldSnapping`, Apple's fold-snapping pattern
    from the "Creating a tvOS media catalog app in SwiftUI" sample). On tvOS the
    offset the focus engine is about to scroll to when it reveals a newly focused
    item goes through `updateTarget` first. From below the fold, a target short of
    the fold either reveals the whole hero (it would show more than half of it, i.e.
    focus is going back to the low play button) or stays at the fold (the focus
    engine nudging the first shelf). From above the fold every real scroll goes
    to the fold, including a target past it: that target is the engine revealing
    its own pick, which the hero exit replaces with the first card at the fold.
    During a hero exit every target is pinned to the fold (`pinsToFold`).
  - **Never add a programmatic scroll on a focus change the engine made.** It
    stacks on top of the engine's reveal scroll instead of replacing it; that threw
    the page several rows past the first shelf. The hero exit used to start with a
    `scrollTo` of its own, on the theory that pinning both to the fold left nothing
    to stack with. Measured per frame in the simulator, it did stack: when the card
    took focus first the curve bent mid-way, and when `onMoveCommand` came first
    the page cut from the hero to the shelves in a single frame (the "jumpy" exit
    on device). The exit now scrolls nothing; the engine's reveal of whichever
    card takes focus is the one scroll, both ways.
  - `settleFold` runs 200ms after the page stops moving, never during a hero exit.
    Latch closed → the page rests on the full hero; open → at or past the fold,
    never on a sliver of hero. Normally it does nothing.
  - The shelf stack is a plain `VStack` on tvOS, not a `LazyVStack`: with the hero
    filling the screen the first shelf starts exactly at the fold, and an
    unmaterialised lazy stack turns the down-press into a dead end.
    `shelfTopPadding` is derived from the measured top safe area because it is what
    keeps the first shelf header clear of the floating tab bar at the fold.
  - Unchanged and still load-bearing: both `.focusSection()`s, the focus
    scope / `defaultFocus` / `requestHeroPrimaryFocusIfNeeded` dance.
  - `HomeViewModel.heroItems()` caps the rotation at 10 items **on tvOS only**, since
    every backdrop is now decoded at 1920×1080 and the whole set is prefetched
    eagerly. iOS keeps the unbounded list.
- On iOS the home hero play button uses `homeHeroNativeButtonStyle()` (prominent,
  `Color.primary`-tinted Liquid Glass that contrasts the artwork) with
  `HomeHeroActionButtonLabel(fillsWidth: true)`, sized as a wide, short pill
  (≈240pt iPhone / ≈300pt iPad). Keep it consistent with the detail primary button
  (`STYLE.md` §3.3); never a coloured fill.
- `HomeIOSView` and `HomeTVView` should stay composition shells. Keep Plex data rules in
  `HomeViewModel`, not in platform views.
- Use `HomeItemContextMenu` for hero context actions. It already exposes mark watched,
  details, season, and show routes when available (on tvOS `contextMenuSeasonRoute` /
  `contextMenuShowRoute` are nil, because the details route already opens the one
  show page). Its optional
  `onRemoveFromContinueWatching` adds Plex's "Remove from Continue Watching" action
  (server `PUT /actions/removeFromContinueWatching`); the hero supplies it because its
  items are always the Continue Watching hub. `HomeViewModel.removeFromContinueWatching`
  drops the item optimistically, then reloads to reconcile.
- `HomeHubItemsView` is the full "show all" grid for hub contents. It has its own small
  view model and uses the shared poster grid; all-clip hubs render it 16:9.

### Server Priority

- `Settings › Libraries › Server Priority` opens `ServerPrioritySettingsView` on
  every platform. It answers two questions and nothing else: in which order the
  servers rank, and which of them Dusk uses at all.
- Each row shows the server name, its ownership ("Your server" / "Shared by X"),
  and its live status from `pool.state(for:)` — Local, Remote, Relay, Connecting…,
  Offline, Not authorized, Disabled. The words come from `ServerStatusText` so the
  rest of the app says the same thing.
- Every edit is written immediately through `ServerPriorityStore`; there is no
  save step and nothing to lose by leaving. Enabling a server reconnects it
  straight away (the row reads "Connecting…" until it resolves); disabling calls
  `pool.markDisabled`, which drops the session so the rest of the app forgets that
  server. Both bump `serverPriority.revision`, which Home, Libraries, and Search
  observe to reload.
- "Check Again" re-runs the whole connect pass through
  `ServerConnectionCoordinator.refresh()` — use it after bringing a server online
  or accepting a new share.
- Disabling the last enabled server is allowed but never silent: the screen shows
  what it costs ("Dusk has nothing to show; downloads still play"). Do not replace
  this with a blocking alert — the user may be deliberately going offline-only.
- A single-server account sees a plain one-row screen: no reorder affordances, no
  talk of priority. Ordering language only appears once there are two servers.
- iOS/iPadOS use `EditButton` + `onMove` plus a per-row toggle; tvOS gives each
  server its own section with a position menu and a "Use This Server" toggle. The
  same tvOS rule as Library Order applies: **no focus-driven drag**.
- The visible rows are not the stored list — a server that has gone missing keeps
  its slot in `ServerPriorityStore`. Reordering therefore goes through
  `reorder(visible:)`, which re-applies the new order to the visible slots only.

### Library Order

- `LibraryOrderSettingsView` (route `.libraryOrder`) is reached from the library tabs,
  not Settings: iOS has an `arrow.up.arrow.down` toolbar button on each tab's landing
  screen and the library list; tvOS has a "Library Order" glass button in the browse
  row (recommendations) and atop the library list. It edits the order of *your*
  visible libraries across every enabled server; hidden ones are not listed and keep
  their place at the end of the account's list. The order is an account-level Plex
  setting rather than a Dusk preference: the same order drives the Plex Web sidebar
  and the other Plex apps signed in as this user.
- A row carries its server name only when another library of the same type has the
  same title. The server name disambiguates; it is never decoration.
- The screen lists **every** visible section, music included, even
  though Dusk cannot browse it. They occupy slots in the account's order, so
  omitting them would silently move them when the list is written back.
- iOS/iPadOS use native list editing (`EditButton` + `onMove`). tvOS uses a position
  menu per row (`TVSettingsMenuRow`), the same pattern as Navigation Tabs, with
  formatted ordinal labels so the list is not capped at a handful of names.
  **The previous focus-driven pick-up (the old Home layout editor) was removed and
  must not come back.** It was unusable on a real remote: directional commands only
  reach an `onMoveCommand` handler when the focus engine finds no candidate, and the
  tvOS tab bar sits above this screen, so a row moved down but not up.
- Writes are debounced 1s and coalesced, so walking a library through six slots is one
  account write, not six. `onDisappear` flushes a debounce that is still counting down.
- A failed write reverts the list to `PlexService.libraryOrder.orderedSections` and
  shows an inline message; showing the rejected order would lie about what the other
  Plex apps will do. A failed load shows `FeatureErrorView` with Retry.
- The order is read and written through `PlexService`; the view model never talks to
  plex.tv itself. Entries for disabled servers, cloud providers, and servers whose
  sections failed to load are carried through untouched — never write an order for a
  server Dusk could not read. Storage format and traps: `docs/data-and-plex.md`.

### Hidden Rows (Home)

- Home's poster context menu has **Hide Row** on a Plex row (iOS + tvOS), and
  Settings › **Home** › **Hidden Rows** (`HiddenHomeRowsSettingsView`) lists every
  row of each movie/show/video library on servers the account owns, a switch each,
  built like Hidden Libraries. This is how Plex's automatic rows (the seasonal
  "Oh, The Horror!" = `movie.curated`, collections, …) leave Home.
- Storage is Plex's own Manage Recommendations "Home" flag (`promotedToOwnHome`,
  `PlexService+HomeRows.swift`), saved on the server: `GET /hubs` drops the row for
  Dusk, Plex Web and every Plex app alike, so Home needs no filter. Nothing is
  stored in Dusk.
- Only owners can change it (shared servers and restricted profiles never see the
  action), and account-wide rows (`home.*`: the type-wide Recently Added, Continue
  Watching) are not in any library's list, so they cannot be hidden this way.
- Known gap: on tvOS, hiding the focused row sends focus back to the hero.

### Hidden Libraries

- Settings › **Libraries** (formerly "Navigation") › **Hidden Libraries**
  (`HiddenLibrariesSettingsView`) is the only place to hide a library: one switch per
  library Dusk can show, grouped under server names when there are several, in server
  priority then server order (a switch never moves). Library Order has no hide action.
- Storage is the account's `pinnedSources[].isHidden` (same debounced write as the
  order), so Plex Web and the other Plex apps hide the library too, and a hide made
  there applies in Dusk. Nothing is stored in Dusk.
- A hidden library is gone everywhere: tabs and library lists (`visibleSections`),
  Home rows and its items in global rows / Continue Watching / hero / Top Shelf
  (`HomeViewModel.mergedScreen`), personalized shelves, "Show All" and Recently Added
  paging (`getHubItems`), search and Siri search (`PlexService.search`), a person's
  titles, and the Siri title catalog (rebuilt when the hidden set changes). Matching
  is `"<serverID>|<librarySectionID>"` via `HiddenLibraryFilter`; an item without a
  section id is kept.
- Home's first paint waits (up to `HomeFirstPaintGate.patience`) for the library order,
  so a hidden library's rows never flash; a later hide/show reloads Home.
- Not filtered: downloads already on the device, and Seerr results.
- Clips never enter the cinematic hero rotation (`HomeViewModel.heroItems()` filters
  `isClip` — frame grabs read poorly full-bleed). They stay visible in hub rows, where
  an all-clip hub (`isVideoHub`) renders as a 16:9 carousel.

## tvOS Top Shelf

- The `DuskTopShelf` app extension (tvOS only, bundle id
  `com.dusk-player.app.topshelf`) shows Continue Watching in the Top Shelf when
  Dusk sits in the Home Screen's top row: sectioned content, 16:9 tiles, one
  "Continue Watching" section that is Home's merged list as-is (started items
  with progress and next episodes mixed, `ContinueWatchingMerge` order), at
  most 10 items. No separate "Up Next" section; the app never splits them.
- **The extension never talks to Plex.** `TopShelfPublisher`
  (`Dusk/Sources/TopShelf/`) is called from `HomeViewModel.publish` on every
  Continue Watching publish; it caches each tile's artwork with the app's own
  session and writes `TopShelfSnapshot` (titles, artwork file names, deep links)
  into the App Group `group.com.dusk-player.app`, then calls
  `TVTopShelfContentProvider.topShelfContentDidChange()`. The extension only
  reads that snapshot (`TopShelfSnapshot.swift` is compiled into both). No
  snapshot → the static Top Shelf image.
- `PlexService.tearDownServerSessions` clears the snapshot (sign-out, Plex Home
  switch): the shelf must never show another identity's items.
- Deep links: `dusk://play?server=…&item=…&type=…[&clip=1]` resumes,
  `dusk://open?…` opens the detail page on Home. `DuskApp` hands the URL to
  `TopShelfLinkRouter`; `MainTabView` acts on it once the item's server is
  connected (a cold launch delivers it first) and drops it after 30 s. Play
  re-reads the server's `viewOffset` instead of trusting the snapshot.
- iOS is untouched: everything is `#if os(tvOS)`, the URL scheme is only in
  `Info-tvOS.plist`, and only the tvOS app uses `Dusk-tvOS.entitlements` (App
  Group added); iOS keeps `Dusk.entitlements`.

## Libraries

- `LibrariesViewModel` groups Plex libraries by `PlexLibraryType`. Its `libraries`
  reads through `PlexService.libraryOrder.orderedSections`, which now spans **every
  connected server** in the account's cross-server order, not raw `/library/sections`
  order. Libraries are never merged into virtual ones: two servers' "Movies" sections
  hold different files and page independently, so they stay two rows.
- A library shows its server name **only** when another library of the same type has
  the same title (`ServerLabeling`, shared with the Library Order settings screen). A
  single-server account never sees one.
- `MainTabView` reuses a single `LibrariesViewModel` to decide tabs and feed library
  screens, and reloads it on `plexService.serverContentRevision` because the available
  tabs derive from the merged library list. Avoid each tab independently discovering
  libraries.
- `LibrariesView` is the direct Movies/Shows/Videos/Photos tab wrapper (Photos: see
  "Photos" below). The tab lands on `LibraryRecommendationsView` for **all**
  libraries of that type. Browse reaches every library's grid in one step: on tvOS a leading row
    of glass buttons ("All Movies", one per library, then "Libraries" when there are
    several) is the first thing under the tab bar, so focus lands there moving down;
    on iOS a toolbar link with one library, or a Browse menu (each library's grid, then
    "Libraries") with several. "Libraries" opens `LibraryTypeListView` for
    per-library recommendations. The menu pushes by appending to the tab's
    `NavigationPath`, never via `navigationDestination(item:/isPresented:)`: a
    screen pushed outside the path is dropped when anything on it appends to the
    path, so a poster tapped in the grid bounced straight back to the grid.
  The list's rows open each library's recommendations. (The old combined
  `LibrariesHubView` tab is retired; every type gets its own tab.)
- `LibraryRecommendationsViewModel` takes `libraries: [PlexLibrary]` and is the
  library-scoped home equivalent: `getLibraryHubs(...)` per library (fanned out, each
  routed to its own server), `HubMerge` across them, continue-watching hub extraction,
  recently-added expansion, and personalized shelves from `LibraryRecommendationEngine`
  merged per genre (`LibraryRecommendationLoadResult.merging`). A merged personalized
  row has no "Show All" because no single library list is behind it.
- **Large libraries (tens of thousands of titles).** On a big PMS every section query
  (`/all` with a sort or filter, counts, `/hubs/sections`) costs the server a walk of the
  whole section however small the page, and the database is the bottleneck. So the
  screen is two-phase: the hub rows (Continue Watching, Recently Added, …) paint as
  soon as `/hubs/sections` answers, and only *then* do the personalized shelves start
  (genre counts, candidate pages, history); they are animated in below when ready.
  Never fold the shelves back into the first paint — that is what kept a 60k-title
  library on a spinner for minutes. Inside the engine, taste-signal metadata and the
  genre pools load concurrently, libraries of a type tab load three at a time, and
  Recently Added is only re-fetched when the hub came back shorter than the row. The
  last rows per profile + library set are kept in memory
  (`LibraryRecommendationsSnapshot`), so a rebuilt screen paints at once and refreshes
  underneath. Reproduce with a mock PMS that synthesizes the library and charges a
  per-row scan cost per section query (see `docs/development-workflow.md`).
- A failing server never blanks the others: the sections load commits per server and
  only throws when every server failed.
- `.video` libraries never run the genre engine. Their shelves come from
  `LibraryVideoShelfLoader`: per-channel rows (first ~6 collections via
  `getLibraryCollections`, items sorted by release date) and a day-seeded
  "Rediscover" row of unwatched items. Row order: Continue Watching, prioritized
  hubs, secondary hubs, channel rows, Rediscover — all 16:9.
- `LibraryItemsView` is the browse grid for a concrete library, genre, or collection
  route; `.video` libraries use the 16:9 grid metrics.
- `LibraryItemsViewModel` handles pagination, sort, genre selection, local genre
  matching as a last resort, and optional collection scoping (`LibraryCollectionItemsView`
  delegates to it). Paging is server-side (`X-Plex-Container-Start/Size`, sort and
  filters as query parameters): a 50-item first page, then 100-item pages prefetched
  half a page before the end. Without a preselected genre the first page does not wait
  for the genre list. A genre handed in from a recommendation row is resolved to the
  server's own filter value (`LibraryGenreSupport.serverOption`, by value or title);
  only a genre the server has no filter for is matched locally, on the listing's tags,
  scanning at most 10 × 200 titles per grid page from a resumable offset — never the
  whole library, never per-item metadata requests. Sort options are per-kind via `LibrarySortOption.options(for:)`;
  video libraries default to Release Date (newest).
- Use `LibraryGenreSupport` for Plex genre filter discovery, normalization, URL
  parameter extraction, and fallback matching. Do not compare genre strings ad hoc.
- Sorts are a field plus a direction (`LibrarySortField` × `LibrarySortOption`): Title,
  Release Date (`originallyAvailableAt`), Year, Date Added, Episode Added (shows,
  `episode.addedAt`), Your/Critic/Audience Rating (`userRating`/`rating`/`audienceRating`),
  Duration (not shows), Last Watched (`lastViewedAt`), Random — all keys Plex's
  `/sorts` lists. The menu has "Sort By" and an "Order" section ("Newest First"…);
  title defaults ascending, everything else descending. Random pages are each
  reshuffled by Plex, so appends are de-duplicated by id (titles can be missed, never
  repeated).
- The grid's sort is remembered per library (`LibrarySortStore`, keyed on
  `PlexLibrary.id`, stored as `"<field>"`/`"<field>:desc"`; the old fixed names such as
  `yearDescending` still read; a field the type no longer offers falls back to its
  default).
- The grid's **Unwatched** chip (between Genre and Sort) is a one-tap filter, remembered
  per library (`LibraryUnwatchedFilterStore`, keyed on `PlexLibrary.id`) and applied to
  that library's genre and collection grids too. `LibraryUnwatchedFilter` sends
  `unwatched=1` for movie/video sections (in-progress titles stay) and
  `unwatchedLeaves=1` for shows (listed while any episode is unwatched). Active = inverted
  `TextPrimary` fill with a filled checkmark (STYLE.md selected treatment).
- **Filters** chip (after Unwatched; inverted with a count when on, plus an `xmark`
  chip that resets) opens `LibraryFiltersSheet` (iOS sheet; tvOS full-screen cover
  built from the `TVSettings*` rows, because a plain `List` there shows no focus).
  `LibraryFilterState` = watch status (All/Unwatched/In Progress/Watched; shows have no
  In Progress) + one value per field + boolean toggles, ANDed. Fields are the ones in
  `LibraryFilterField.offered` that the section's `/filters` lists (decade, year,
  content rating, resolution, HDR, Dolby Vision, audio language, studio, network,
  collection, director, actor); values come from the filter's own key path, cached per
  screen, searchable past 20. Edits apply once on Done. Unwatched stays the remembered
  one-tap chip (`watchStatus == .unwatched`); everything else lasts for the screen.
  Plex percent-encodes some value keys (`Not%20Rated`), so `LibraryFilterChoice`
  decodes them before they go back into a query. Watched = `unwatched=0` /
  `unwatchedLeaves=0`. Any filter turns off `includeCollections` folding.
- `LibraryItemsViewModel` uses a `queryGeneration` guard so stale async page loads do
  not mutate current results. Preserve this pattern when adding filters.
- **A–Z jump** (title sorts only, not Videos libraries or a locally matched genre):
  `/library/sections/{id}/firstCharacter` with the grid's own server filters gives
  per-letter counts → `LibraryLetterIndex` offsets (descending is mirrored; absent
  letters dim and land on the next one). iOS: `LibraryLetterIndexBar` is a
  `UITableView`-style index (drag-to-scrub, selection haptic, 12 pt grid gutter).
  tvOS: a strip in the trailing margin that shows while it has focus or while focus
  races through the grid (5 moves/s), and stays focusable while hidden at 0.02
  opacity (the focus engine skips fully transparent views), so Right off the last
  column reaches it, starting on the browsed letter; selecting moves focus to the
  letter's first title.
- A jump outside the loaded titles replaces the grid with a **window** (`windowStart`
  = server offset of `items[0]`) that starts one row-aligned page above the letter;
  `gridColumnCount` keeps windows and prepends whole rows, so the letter starts a row
  and the grid never reflows sideways. Appends page from `windowStart + items.count`.
  Earlier rows load 1.5 screens before the top and are inserted only when the scroll
  is not decelerating; the screen then shifts the offset by the inserted height
  (`ScrollPosition`, `PrependAnchor`). Traps: a scroll view keeps its offset when
  content grows above, so an unshifted prepend slides new rows into view and cascades
  through the whole library (seen: thousands of requests, PMS 503);
  `defaultScrollAnchor(.bottom, for: .sizeChanges)` and `ScrollViewReader` mixed with
  `.scrollPosition` both failed; a `Bool` `onScrollGeometryChange` misses the
  transition after a programmatic shift. Lazy grids land `scrollTo` by estimate, so
  the jump scrolls twice. Known limit: a hard fling into the window top can still
  skip part of a page.
- Infinite scroll is triggered from `PlexItemPosterGrid.onItemAppear`; keep pagination
  logic in the view model.
- **Plex collections** (movie/TV libraries, manual and smart): the grid shows a
  **Collections** chip (first on iPhone where the chip row scrolls, after Sort on tvOS)
  when the library has any and has not disabled them; it opens `LibraryCollectionsView`
  (`.libraryCollections(library)`), a paged poster grid with "12 movies" subtitles.
  The Recommended page adds a Collections row per library (first 20, "Show All" to that
  grid) right after the Plex hubs and before the personalized shelves; it loads after
  first paint and is part of the snapshot. A collection opens `CollectionDetailView`
  (`.media(type: .collection, id:)`): backdrop hero (the collection's art, else its
  first title's), "Collection · 12 movies · 1977–2019" (year span only once every
  title is loaded; "Smart Collection" for smart ones), summary, then a paged grid via
  `PlexItemPager`. Movie collections get Play (in-progress title, else first unwatched,
  else first) and Shuffle (random unwatched title); there is no play queue, so each
  starts one title. Show collections only browse. Movie, show (iOS) and series (tvOS)
  detail pages end with `DetailCollectionShelves`: a "Part of <collection>" row per
  tagged collection (max 3) whose "Show All" opens the collection. No settings.

### Photos

- Plex `photo` sections are `PlexLibraryType.photo` (Photos tab, hideable/reorderable
  in Navigation Tabs like the others). Like "Other Videos", a photo section stays out
  of `LibrariesViewModel.libraries` until `getLibraryItemCount` says it holds
  something, so an empty one never adds a tab. Permissions need nothing extra: the
  sections come through the same per-server, per-profile session as every library,
  so a managed user only sees the photo libraries shared with them.
- No recommendations: one photo library opens straight on `PhotoBrowserView`, several
  on `LibraryTypeListView` (rows always open the grid).
  `.library(photoLibrary)` and `.photoAlbum(PhotoAlbumRoute)` both land on
  `PhotoBrowserView`.
- `PhotoBrowserViewModel` walks a list of paged queries (`PlexPhotoQuery`): a library
  root in **Albums** mode lists its root albums and then its loose photos, an album
  its sub-albums then its photos and clips, and **Timeline** (root only, remembered per
  library) is every photo and clip, newest first. 60 rows first, then 150 per page as
  the grid (or the viewer) nears the end. Nothing walks the whole library.
- Grid: album cards (composite artwork, title) above a tight square grid of photos;
  clips carry a play glyph and duration and play straight away through
  `PlaybackCoordinator.play` (they are ordinary Plex `clip` items).
- `PhotoViewerView` is a full-screen cover over the grid's loaded `media`:
  - iOS/iPadOS: horizontal paging `ScrollView` (`scrollPosition(id:)`), each photo in a
    `UIScrollView` (`PhotoZoomScrollView`) for pinch / double-tap zoom; paging is off
    while zoomed. Tap toggles the chrome (close, "n of m", date / place / camera).
    Left/right arrow keys page, Escape closes.
  - tvOS: left/right on the remote steps with a cross-fade, Select toggles the info,
    Play/Pause toggles a 5 s slideshow (clips skipped, idle timer off while it runs).
    The grid has a glass **Slideshow** button, and Play/Pause on a focused photo starts
    the slideshow from it.
  - A clip page shows its frame with a play button. Playing it closes the viewer and
    the grid starts playback in the cover's `onDismiss`, because the player is itself
    a full-screen cover of the tab shell and cannot present over another cover.
- Images: grid tiles use the item's `thumb` through `imageURL` (square, `minSize=1`
  crop). The viewer shows that cached thumbnail first, then
  `photoDisplayURL(for:width:height:)`: the original **Part** through
  `/photo/:/transcode` fitted inside the screen's long edge (no `minSize`, so portrait
  photos are not oversized), which also applies EXIF rotation and converts HEIC. Clips
  have no transcodable original and keep their thumb. Neighbours are prefetched.
- Reproduce with `scripts/mock_large_plex.py --photos 5000` (see
  `docs/development-workflow.md`); screenshot hooks: `-DuskScreenshotScreen photos`,
  `-DuskScreenshotPhotoAlbum <ratingKey>:<title>`, `-DuskScreenshotPhotoViewer <n>`,
  `-DuskScreenshotPhotoSlideshow YES`.

## Detail Screens

- Detail entry is split by domain: movie, show, season, episode, video (clip), and
  actor detail views each have their own `@Observable` model. tvOS is the exception
  for TV content: it has no separate show/season/episode screens. `MediaDetailDestinationView`
  sends all three routes to `SeriesDetailView`, and `ShowDetailView`, `SeasonDetailView`,
  `EpisodeDetailView` (+ its model) are compiled out of tvOS (`#if !os(tvOS)`).
- Clips route to `VideoDetailView` via `.video`/`.downloadedVideo` routes
  (`AppNavigationRoute.destination(for:)` branches on `item.isClip`) — never to
  `MovieDetailView`. It is a trimmed movie page: hero metadata line is
  "channel · upload date · duration", no cast/ratings sections, plus a
  "More from {channel}" 16:9 row resolved from the item's first Collection tag.
- Detail views own screen layout; detail view models own Plex fetches, offline fallback,
  watch-state mutations, image URL selection, and computed display state.
- Shared detail UI lives in `DetailSharedViews.swift` only when reused across detail
  screens.
- Use `DetailHeroSection` for cinematic detail headers. It owns the backdrop
  gradient/scrim, title artwork, supertitle/subtitle/action slots, an optional
  `descriptionText`, and safe-area offset. There is **no poster on any platform**:
  iPhone centers one column (title, metadata, actions); iPad uses two columns
  (left: title + actions, right: marker/metadata + `descriptionText`); tvOS is a
  left-aligned column with the action row beneath. Use
  `detailHeroContentAlignment(for:)` / `detailHeroTextAlignment(for:)` to center
  hero text on iPhone, and `detailShowsSynopsisBelowHero(for:)` to drop the
  below-hero synopsis section on iPad (the hero's right column shows it there).
- Clamped synopses go through `ExpandableSummaryText` (`DetailSummaryText.swift`),
  which measures whether the text is really cut off. tvOS: the text itself is
  the control (TV-app style) and is focusable **only while truncated** (a
  disabled button, so text that fits never enters the focus chain); focus shows
  a neutral platter that overhangs the text, Select opens `SummaryFullTextView`
  as a full-screen cover over the blurred page, Menu closes it and focus returns
  to the text. iOS: Show More/Show Less or a tap on the text expands in place;
  with `allowsExpansion: false` (iPad hero, iPhone episode page) a tap opens the
  full text in a detented sheet. Pass `title` so the full-text view is headed.
- tvOS series banner: the focused episode's 2-line synopsis is an
  `ExpandableSummaryText` above the action row. Because it sits above Play,
  `SeriesDetailView` pins first focus to Play (`defaultFocus`) and routes Down
  from the synopsis to Play (`onMoveCommand`); without that the page opens on
  the synopsis and Down lands on whichever action is nearest its centre.
- Detail hero actions share one button system across all platforms (see
  `STYLE.md` §3.3). The primary uses `detailHeroNativePrimaryButtonStyle()` —
  prominent, `Color.primary`-tinted Liquid Glass for contrast (dark-on-light /
  light-on-dark) with a `Color.duskPrimaryActionLabel` label; on Show/Season it
  reads just "Play" / "Resume" (`playButtonShortLabel`), never the target episode.
  Secondary actions (download, watched, go-to-show/season) are **icon-only**
  everywhere via `DetailHeroSecondaryIconLabel` + `detailHeroNativeSecondaryButtonStyle()`
  with an `.accessibilityLabel` (capsule pills on iOS, circles on tvOS). On iOS wrap
  the action block in `detailHeroActionStackFrame(isCompactPhone:)` (iPhone ≈60%
  centered, iPad fills the hero's left column); tvOS lays the icons out to the right
  of the primary. Movie/Show/Season/Episode all expose a watched toggle; Show/Season
  toggle the whole show/season. Never fill or tint primary actions with a colour.
- On tvOS, keep focusable detail rows in separate `.focusSection()` groups. Hero
  actions, expandable summaries, season/episode grids, and cast shelves should move
  vertically to the next visible row instead of letting the focus engine skip to a
  lower but more horizontally aligned item. The episode strip's own scroll view is a
  focus section too, so Up from any episode leaves the row.
- `DetailExtrasShelf` is the 16:9 "Extras" row (local trailers, featurettes, deleted
  scenes, …; card subtitle "Trailer · 2 min"). It loads `getExtras` itself, renders
  nothing when the title has none (or the server is unreachable), and selecting a card
  plays the clip directly. Placement: movie and iOS episode pages above Cast, iOS show
  under Seasons, iOS season under Episodes; tvOS `SeriesDetailView` shows
  "<Season> Extras" and the show's "Extras" under the season summary, and "Episode
  Extras" for the focused episode above Episode Cast (400 ms load delay so zapping the
  episode row does not fetch every card).
- The hero **Trailer** action (`DetailTrailerHeroButton`, icon-only `movieclapper`
  secondary right after Play) plays the title's trailer extra: the extra Plex names as
  `primaryExtraKey`, else the first `extraType` 1. It reads the same `DetailExtrasModel`
  the page's Extras row loads (passed in via `DetailExtrasShelf(model:)`), so it costs
  no request and is absent until extras load or when there is no trailer. Movie pages
  and show pages (iOS `ShowDetailView`, tvOS `SeriesDetailView` with the show's extras).
- **Ratings** (`DetailRatings.swift`): the hero metadata carries `DetailRatingsLine` —
  the user's own stars (system yellow, half stars) then each source from Plex's
  `Rating` array (`PlexRating.sources`: IMDb 6.4, Rotten Tomatoes / RT Audience %,
  TMDB %, TVDB; falls back to `rating`/`ratingImage` + `audienceRating`/
  `audienceRatingImage`). Sources are text labels, not logos (Dusk ships no
  third-party brand marks). `DetailRateHeroButton` is an icon-only `star` menu
  (1–5 stars, Clear) that writes `PUT /:/rate` (`rating` 0–10, `-1` clears) with an
  optimistic `DetailUserRatingModel`. Movie pages (all platforms) and the iOS show page
  show both; the tvOS series page only has the Rate action (its hero box is
  episode-sized).
- Detail screens use hidden inline navigation bars over hero artwork. Keep
  `.toolbarColorScheme(.dark, for: .navigationBar)` and hidden toolbar backgrounds unless
  the screen is no longer hero-led.
- Detail screens refresh after player dismissal and scene activation to pick up watch
  progress.
- `MovieDetailViewModel` handles movie metadata, media info, resume position, watched
  state, and offline movie metadata banners.
- `ShowDetailViewModel` loads show details, seasons, next-episode metadata, season
  availability badges, and show-level offline messaging.
- `SeasonDetailViewModel` loads season details and episodes, computes the next episode,
  sorts offline-available episodes first when appropriate, and records offline watch
  mutations.
- `SeriesDetailView` (tvOS only) is the one page per show. `SeriesDetailViewModel`
  composes a `ShowDetailViewModel` (seasons, Seerr gaps, show watch state) with a
  `SeasonDetailViewModel` for the season on screen; it does not re-implement either.
  The route decides where it opens: a show opens on its first regular season with
  something unwatched (Specials only when nothing else exists), a season on itself,
  and an episode on its season with that episode in the banner and the row scrolled
  to it. For season/episode routes the season paints first and the show (pills)
  loads after it; the pills share a fixed-height slot with the plain "Episodes"
  header so the row never jumps. Season pills sit above the horizontal episode row
  (only when there are 2+ seasons); picking one loads that season and swaps it in
  only once loaded (the row dims meanwhile), so the page never blanks. A Seerr-only
  season pill opens its request page. Hero buttons and season pills are system
  `.glass` with no tint (the selected season is
  bold and full-opacity, the rest dimmed, so it never looks focused), and
  progress bars are neutral. Each episode card shows the title with a
  "Season X · Episode N" subtitle plus a quiet watched checkmark
  (`PosterCardText`); the
  hero's clear-logo title, focused-episode name/metadata/summary, backdrop, and the
  "Episode Cast" row follow the focused card inside stable-height regions, with the
  focus commit debounced so rapid remote navigation does not shift the scroll
  position. Selecting a card, or the hero Play/Resume, plays the focused episode;
  the eye button toggles the season on screen. The row is only scrolled
  programmatically when the season changes — never on focus or next-up changes —
  with one exception: when the player cover closes on a later episode than it
  opened with (`PlaybackCoordinator.advancedEpisodeOnClose`, i.e. Up Next / Next
  Episode moved on), the page follows it (`SeriesDetailViewModel.follow`): its
  season, banner, row position and, if playback began on a card, focus. This runs
  on `playerCoverDismissals` plus a 600 ms beat, because tvOS restores focus to
  the starting card after the cover's `onDismiss` and would undo an earlier move.
- `SeasonDetailView` (iOS/iPadOS) keeps the vertical episode list with per-episode
  detail navigation; after a continuous-play run it scrolls the list to the
  episode the player closed on (same `advancedEpisodeOnClose` signal).
- `EpisodeDetailViewModel` (iOS/iPadOS) handles single-episode metadata, parent
  show/season links, watch toggles, and offline availability.
- `ActorDetailViewModel` loads a person plus filmography by searching Plex for exact role
  matches. Keep this search behavior local to actor detail unless Plex gets a stronger
  people endpoint.
- Use `PlayVersionContextMenu` for alternate media versions; it filters out unplayable
  versions with no parts.
- "Download Subtitles" (Plex-proxied OpenSubtitles) is a secondary action on movie,
  episode (iOS/iPadOS only — tvOS has no episode page; the player covers it), and
  video detail. iOS/iPadOS put it in the Play button's `.contextMenu`
  next to Play Version; tvOS gets a `captions.bubble` icon button in the hero action
  row, because context menus are awkward there. It is gated on
  `<Model>.canDownloadSubtitles` — `PlexService.canDownloadSubtitles(serverID:)` (owner of
  *that item's* server,
  non-restricted Home user; anything else would 403) plus a real playable part and
  no cached/offline metadata. The detail models own the flow
  (`makeSubtitleSearchViewModel(preferredLanguageCode:)`), so the views never touch
  `PlexService`; a successful install re-reads the item so the new stream shows up in
  media info, and the next playback session mounts it. Presentation goes through
  `detailSubtitleSearchPresentation(isPresented:viewModel:)` (sheet on iOS, full-screen
  cover on tvOS).
- Use `DownloadActionButton` and `DownloadContextMenuContent` from the downloads
  feature for download actions. Do not duplicate download state UI in detail screens.
- Offline-capable detail models may show cached metadata before network refresh. Preserve
  `isUsingCachedData`, offline-fallback state, `offlineStateVersion`, and
  `OfflinePlaybackSyncManager` checks when changing watched/progress behavior.
- Some show/season loading is intentionally sequential to avoid async-let runtime aborts
  during transient context-menu navigation lifetimes. Do not "optimize" it back to
  `async let` without reproducing that scenario.

## Live TV

- `MainTabView` owns one shared `LiveTVViewModel` for availability, the tab,
  `MoreView`, and the Home shelf. Do not discover providers independently per
  surface.
- `LiveTVView` offers yesterday through seven days ahead, channel/program
  artwork, current-program progress, schedule details, and Watch actions only
  for currently airing programs. Past entries remain inspectable but are not
  presented as recordings.
- The player gear menu exposes channel switching on iOS/iPadOS and tvOS. The
  live seek bar shows LIVE or the time behind live and provides Go Live; all
  forward movement is clamped to the HLS edge.

## Watchlist

- No tab or destination: the Plex Watchlist is one Home row, "Watchlist"
  (`HomeWatchlistShelf`, both shells), in Plex's order (newest first). It renders
  only with at least one title: empty, plex.tv failing, or a profile without a
  Watchlist leave no row, spinner or error.
- Placement (`HomeWatchlistPlacement`, tested): Plex Web's customized Home layout
  wins (hidden there = hidden here, otherwise after the nearest preceding Plex row Home
  also shows). Otherwise the row goes after the last Recently Added hub of every
  library block. With no Recently Added rows it goes after the Plex hubs, before
  Dusk's personalized shelves. Always under the hero / compact Continue Watching /
  Live TV. Hubs already follow Library Order.
- A title on a connected server is its server item (normal detail page, progress,
  watched mark, card context menu). One that is not opens `.watchlistItem`
  (`WatchlistItemDetailView`): Seerr's page (Request + bookmark) when Seerr is
  connected and Plex has a TMDB id, otherwise a light page from Plex metadata with
  "Not on your Plex servers · <streaming services>" and Remove/Add in the primary slot.
- Bookmark (`WatchlistHeroButton`, `bookmark`/`bookmark.fill`, icon-only) on movie and
  show pages (iOS movie/show, tvOS movie/series) and the Seerr stand-in page; "Add
  to/Remove from Watchlist" in `PlexItemContextMenuContent` for movies/shows with a
  `plex://` guid. Optimistic with rollback; the hero shows an alert on failure.

## Playlists

- A data-driven destination like Live TV: `PlexLibraryType.playlists` joins the
  tab list (so Settings › Navigation Tabs orders and hides it) only while
  `PlexService.playlists` (`PlaylistStore`) holds a video playlist on a
  connected server. `MainTabView` loads the store per `serverContentRevision`;
  creating the first playlist from Add to Playlist brings the tab in. iPhone
  folds it into More under the five-tab rule; tvOS puts it before Search.
- `Features/Playlists`: `PlaylistsView` (square cards with Plex's `composite`
  mosaic, `N items · duration`, `· Smart`, the server name only when playlists
  span servers; context menu Play / Shuffle / Rename / Delete),
  `PlaylistDetailView` + model (detail hero with the first item's art,
  Play/Resume at the first unfinished item, Play from Beginning in the primary's
  context menu (iOS) and More, Shuffle, More › Edit/Rename/Delete), and
  `PlaylistActions` (queues, rename, delete shared by both screens).
- Rows: 16:9 still with progress, title, `Show · S1 · E4` or the year, runtime,
  quiet checkmark. Tap / Select plays the playlist **from that row**, and
  playback continues through every following item, watched ones included (a
  finished item starts over). Context menu: Play from Here, Go to Details (+ Go
  to Season/Show on iOS), Mark Watched/Unwatched, Remove from Playlist.
- iOS builds the whole page as one plain `List` (hero row full-bleed) so rows
  get native swipe-to-delete and `EditMode` drag reorder (More › Edit; a Done
  button ends it). tvOS uses a focusable row stack (TextPrimary band on focus)
  and edits only through each row's context menu; no reorder on tvOS in v1.
- Smart playlists: play, shuffle, delete. More says filters are edited in Plex
  Web. Plex rejects item edits on them (HTTP 400).
- Every edit goes to the playlist's server first; removals/reorders are applied
  optimistically and rolled back with an alert on failure.
- Add to Playlist: `AddToPlaylistPresenter` (owned by `MainTabView`, in the
  environment) presents `AddToPlaylistSheet` for an `AddToPlaylistTarget`.
  Entry points: `AddToPlaylistMenuButton` inside `PlexItemContextMenuContent`
  (every poster grid/row), `HomeItemContextMenu`, episode rows (iOS season
  page, tvOS series page), tvOS season pills, search results; and the icon-only
  `AddToPlaylistHeroButton` (`text.badge.plus`) on movie, episode, season, show
  and video pages (tvOS series page: the show). The sheet lists only regular
  playlists **on the item's own server**, most recently updated first, under
  "New Playlist…" (Plex cannot create an empty playlist, so a new one starts
  with the item). A show or season asks "Add N episodes?" first; Plex expands
  it and skips episodes already in the playlist, and the confirmation says so.
- Play-through lists: grids and rows of Videos libraries and their folders
  (`LibraryItemsView`, channel/hub rows of `LibraryRecommendationsView`) and
  collection pages pass `playThroughTitle` to `PlexItemPosterGrid` /
  `PlexItemPosterCarouselSection`. Their movies and videos then open through
  `.videoInList` / `.movieInList` routes carrying a `PlaybackListContext`, and
  the page's Play starts a list queue at that item (Up Next "Next in <list>").
  Collection Play continues through the collection; Shuffle shuffles it. TV
  episodes never take part.

## Search And Settings

- `SearchView` is a thin tab-root wrapper (`NavigationStack` + destinations) around
  `SearchRootContent`, which owns the view model, searchable field, and results; the
  split lets iPhone/iPad toolbar actions push Search without a nested stack.
  Settings and Downloads follow the same wrapper/`*RootContent` pattern.
  All-clip result groups render 16:9.
- Search is debounced in the view model with a cancellable `Task`; views only bind the
  query and render grouped results.
- Search is **fanned out to every connected server** (`PlexService.streamSearch`) and the
  merged groups are republished as each server answers (`SearchMerge`), so results stream
  in instead of waiting for the slowest server. Groups are matched on their type, items
  deduplicated by content key and round-robin interleaved in priority order, and the
  copies registered in `plexService.alternates`. It is an error **only** when every
  server failed and there is nothing to show; one unreachable server shows
  `ServerOutageNote` above the results. A server connecting or dropping re-runs the
  current query (`.task(id: serverContentRevision)`).
- `SearchMediaResult.id` carries the server (`PlexItemID.storageKey`): merged results can
  hold the same rating key twice, and duplicate `ForEach` ids drop rows.
- When Seerr is connected, search also performs an additive Seerr discovery
  request. Plex groups publish first; external movies/shows are deduplicated and
  appended with request-state badges. A Seerr failure stays silent and never
  breaks Plex search.
- Presentation is platform-adaptive so search feels native everywhere. tvOS and iPad
  (`userInterfaceIdiom == .pad`) render each result group as a
  `PlexItemPosterCarouselSection` (the same poster carousels Home uses for hubs); iPhone
  renders each group as a titled `PlexItemPosterGrid` section (matching the library grid).
  Plex `/hubs/search` returns one hub per media type, which maps cleanly onto a carousel
  row or a grid section.
- All platforms reuse the shared `FeatureStateViews` for empty/loading/error/no-result
  states through one `searchResults(_:content:)` wrapper, so state reporting stays uniform.
- Search results route through `AppNavigationRoute.destination(for:)` so people, movies,
  shows, seasons, and episodes stay consistent with the rest of the app.
- Seerr cards instead use dedicated request-only routes. Never put them through
  Plex detail routes, playback, downloads, or watch-state actions.
- `SettingsView` selects the platform shell. Shared sheet/navigation chrome is in
  `SettingsContainer`.
- The Integrations section links to `SeerrSettingsView`. Both platforms accept
  only a server URL and connect using the active Plex identity; tvOS uses native
  keyboard/Remote input rather than a browser login.
- `SettingsViewModel` is for transient settings UI state: Home-user picker
  presentation, image cache status, and app version. Server state belongs to
  `ServerPrioritySettingsViewModel`.
- Persistent settings live in `UserPreferences`, not `SettingsViewModel`.
- Settings → Navigation holds three ordering screens, deliberately different in
  scope. Navigation Tabs controls the visibility and order of Movies, TV Shows,
  Videos, and Live TV; it is device-local `UserPreferences`. Library Order controls
  the order of your individual libraries across servers; it is stored on the Plex
  account (see "Library Order"). Server Priority controls which servers Dusk uses
  at all and which one wins for a title that exists on several; it is device-local
  (see "Server Priority"). All three use native list editing on iOS/iPadOS and
  position menus on tvOS.
- For Navigation Tabs, hidden types stay in the saved order so restoring one puts it
  back where the user placed it.
- `UserPreferences` is `@Observable`, environment-injected, and backed by `UserDefaults`.
  Add new device-local user-facing preferences there with a key, default loading, and
  persistence. A setting Plex already models for the account belongs in `PlexService`
  instead, like library order.
- `forceAVPlayer` and `forceVLCKit` are mutually exclusive in `UserPreferences`; do not
  bypass those setters.
- `videoEnhancementMode` is a persisted playback preference with Auto, On, and
  Off settings. It affects local rendering only, must not request Plex
  transcoding, and must not alter startup quality. Its per-platform default
  lives in `VideoEnhancementMode.defaultForPlatform` — Auto on Apple TV, Off on
  battery-powered devices.
- `alwaysPlayInLandscape` ("Always Play in Landscape", Playback Behavior,
  iPhone only, default on) forces the player into landscape, including under
  Portrait Orientation Lock. The toggle is hidden on iPad. tvOS has no row.
  Behavior is in `playback.md`.
- Playback Defaults › Audio & Subtitles (`AudioSubtitleSettingsView`, a pushed
  page on both platforms) holds every track-language setting: Audio › Language
  (`defaultAudioLanguage`, "" = Original), Subtitles › Show Subtitles
  (`subtitleMode`: Off/Auto/Always), Language (`defaultSubtitleLanguage`, never
  "None" any more), Style and Size, and Advanced › Forced Subtitles
  (`forcedSubtitlesEnabled`). The rules live in `SubtitleSelectionPolicy`
  (`playback.md` → Automatic Track Languages). The 1.8 page replaced the old
  Subtitles/Forced Only/Subtitle Size/Audio rows;
  `UserPreferences.storedSubtitleSettings` maps the legacy keys
  (`subtitleForcedOnly` stays readable for that only).
- Values the viewer never set in Dusk follow the Plex account's language
  settings (`PlexService.fetchAccountLanguageDefaults`, `profile` of
  `/api/v2/user`, fetched in `MainTabView` per profile). They are cached under
  `plexAccount*` keys and applied through
  `UserPreferences.applyPlexAccountLanguageDefaults`, which never writes the
  viewer's own keys, so the account keeps steering until the viewer picks.
  With neither a Dusk choice nor an account audio language, audio uses the
  device language and English only as the last fallback
  (`UserPreferences.storedAudioLanguage`), the same device-language step
  subtitles already take.
- `subtitleFontSize` (Audio & Subtitles › Size, Extra Small/Small/
  Medium/Large, Medium = the previous fixed size) scales locally rendered
  subtitles on both engines. It is also editable from the in-player gear menu
  (a `PlayerSelectionSheet` on iOS/iPadOS, a nested `Menu` on tvOS); the player
  writes the same `UserPreferences` value, so it is one preference and not a
  per-session override. It is disabled for AirPlay sessions, whose subtitles are
  burned in by Plex. See `playback.md` for how each engine applies it.
- `subtitleStyle` (Audio & Subtitles › Style, System/Dusk, default System)
  picks the look of locally rendered text subtitles: the Accessibility caption
  style, or Dusk's own (`SystemCaptionStyle.dusk`). Settings only, no player
  control. See `playback.md` → System caption style.
- Playback Info exposes Video Enhancement state and detail rows so AVPlayer and
  VLCKit sessions can explain whether enhancement is active, waiting for a
  frame, disabled by preference, or unavailable for a stream/runtime reason.
- `SettingsSupport` owns shared settings copy, URLs, language options, and bindings.
  Subtitle and audio pickers share `CommonLanguage` (plus the device language and a
  Plex-account language outside the list); adding an ISO 639-1 case there
  is enough for both platforms. Playback matching then canonicalizes Plex/VLCKit
  ISO 639-2 codes (`rum`/`ron` → `ro`) in `PlayerViewModel.normalizedLanguageCode`.
- Both settings pages lead with a supporter row (thank-you state for supporters),
  followed by Plex Home when applicable. There is no "Plex Server" section and no
  server picker: servers are managed in Navigation › Server Priority. Everyday playback
  and appearance settings follow, while engine overrides, storage, About, and
  Account stay lower on the page. AI Upscaling is a normal Playback Default;
  Playback Advanced is reserved for forced engine selection. The iOS Appearance
  section has an App Icon row opening `AppIconPickerView`. The supporter tier
  itself (StoreKit products, status rules, the iOS/iPadOS prompt schedule, alternate
  icons) is documented in `supporter.md`; tvOS only exposes supporter purchases
  through Settings.
- Player Quality lives in the in-player gear menu, not global Settings. It is a
  per-session manual action and must not create a persisted default that starts
  future sessions transcoded.
- "Download Subtitles" also lives in the in-player gear menu (iOS item below
  Subtitle Size, tvOS button beside the Subtitles menu), behind
  `PlayerControlsContext.canDownloadSubtitles` — `PlexService.canDownloadSubtitles(serverID:)`
  and not Live TV. It opens `SubtitleSearchView` (sheet on iOS with
  `[.medium, .large]` detents, full-screen cover on tvOS) via
  `PlayerViewModel.showSubtitleSearch`, which must stay in both controls auto-hide
  suppression lists (`PlayerView`'s keyboard bridge and
  `PlayerViewModel.canAutoHideControls`) like the other player sheets. The flow
  defaults to `UserPreferences.defaultSubtitleLanguage`, then the device language
  when it is a `CommonLanguage`, then English, and auto-searches on appear and on
  every language / Hearing Impaired change. A successful install calls
  `PlaybackCoordinator.refreshSubtitleStreamsAfterDownload()` and then dismisses,
  so the track is mounted and selected without restarting the session by hand
  (see `playback.md`).
- iOS settings use `List`, `Section`, `Picker`, `Toggle`, `Link`, Safari sheet, and
  confirmation dialogs.
- tvOS settings use `ScrollView` plus `TVSettingsSection`, `TVSettingsMenuRow`,
  `TVSettingsToggleRow`, and action/link row components. The page leads with a
  `.title` "Settings" header (tvOS has no nav-bar title). Shared spacing lives in
  `TVSettingsMetrics` (`contentInset`, `cardVerticalPadding`, `sectionSpacing`) so
  the header, section labels, card content, and footers stay aligned. Keep tvOS
  rows focus-friendly and avoid iOS list-only affordances there. Each focusable row
  shows focus with `tvSettingsRowFocusHighlight(_:)` — a neutral background band
  driven by a per-row `@FocusState` (rows can't use the scale+glow effect because
  they sit inside a shared card). Any new tvOS settings row must carry that band, or
  it will be invisible when focused (`.duskSuppressTVOSButtonChrome()` strips the
  system focus effect, leaving no indicator on its own).
- `TVSettingsMenuRow` pushes its own option list (`TVSettingsOptionList`) through a
  plain `NavigationLink`. Do not switch it back to `Picker` with
  `.pickerStyle(.navigationLink)`: on tvOS 27 that style pushes an empty list with
  nothing focusable, so focus drops to the tab bar and Back exits the app with a
  black screen left over Settings (1.6.2 fix).
- When the signed-in account has multiple Plex Home members, both settings
  platforms show a Plex Home section with the current user, `Switch User`, and
  `Automatically Sign In`. The switch action reuses the startup picker as a
  sheet on iOS and a full-screen flow on tvOS. The toggle is device-local:
  turning it off removes the persisted active-session token but keeps the
  current in-memory session until the app ends.

## Platform Differences

- Prefer separate platform composition files for large differences:
  `HomeIOSView`/`HomeTVView`, `SettingsIOSView`/`SettingsTVView`.
- Prefer shared modifiers/helpers for small differences.
- tvOS often needs larger poster metrics, explicit focus sections (one per hub row
  and one per library-grid row, with a focus guide filling a short last row),
  `scrollClipDisabled`, explicit page backgrounds, system card focus on library posters
  (custom focus stays on episode and cast artwork), glass button styles for primary
  actions, and default focus restoration.
- For tvOS detail pages, use focus sections as vertical row boundaries when a row's first
  focusable item may be horizontally offset from the current control.
- iOS often needs navigation title display modes, searchable placement tuning, status bar
  behavior, refreshable lists, Safari sheets, and compact action stacks.
- tvOS should not rely on iOS-only `List` styling, context menu behavior, or touch drag
  gestures without a remote/focus alternative.
- When a view measures full-bleed hero artwork on tvOS, account for safe-area leading and
  trailing insets so backdrops span the visual screen.

## Design And Style Rules

- `STYLE.md` is authoritative: native vibes, not orange. Use `Color.duskBackground`,
  `duskSurface`, `duskTextPrimary`, and `duskTextSecondary`; `duskAccent` is brand
  only (Supporter page, App Icon picker).
- Root feature screens should paint `Color.duskBackground.ignoresSafeArea()`.
- Elevated rows/cards use `Color.duskSurface` and subtle 1pt strokes.
- Primary action buttons use neutral contrasting Liquid Glass (`Color.primary`-tinted
  prominent glass on iOS, untinted `.glass` on tvOS). Progress, ratings, active
  states, selection, links and loading are neutral too. Do not introduce ad-hoc colors.
- Posters use 16pt corners. Sheets/cards use the larger rounded style already present in
  settings and library rows.
- Prefer system materials for overlays and hero controls where existing UI does.
- Use SF Symbols for iconography and keep labels concise.
- Keep content-first layouts: artwork leads, text supports, chrome recedes.
- Preserve progress indicators on posters and rows where watch state exists.
- Do not duplicate formatting logic in views. Add to `MediaTextFormatter` or an existing
  presentation helper.
- Do not make views call `PlexService` directly unless the file is already a small bridge
  around image URL construction. Feature data loading belongs in `@Observable` view models.

## Safe Change Checklist

- Read the relevant view, view model, shared primitive, and route code before editing.
- Confirm whether the change belongs in a platform shell, shared primitive, view model,
  route enum, or settings preference.
- Keep edits scoped; other agents may be working in nearby files.
- Reuse `AppNavigationRoute` and `.duskAppNavigationDestinations()` for navigation.
- Reuse shared poster/grid/carousel/state/formatting helpers before adding new UI.
- Keep Plex API calls in view models or `PlexService`, not view bodies.
- Preserve refresh-on-player-dismiss behavior on screens showing watch state.
- Preserve offline fallback paths and pending sync recording on downloaded media flows.
- Check tvOS focus and iOS compact layout when touching shared view code.
- If adding/removing/renaming source files under `Dusk/Sources`, run `xcodegen generate`.
- After code changes, run the compile-only `xcodebuild` command from `AGENTS.md`.
- Documentation-only changes do not require an Xcode build.
