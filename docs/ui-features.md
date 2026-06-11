# Dusk UI Feature Layer

Operational notes for agents changing SwiftUI screens, feature view models, and shared UI
in Dusk. Read this with `docs/codebase-map.md`, `STYLE.md`, and `docs/data-and-plex.md`.

## App And Navigation Shell

- `DuskApp` creates the long-lived app services and injects them into the SwiftUI
  environment: `PlexService`, `PlaybackCoordinator`, `DownloadManager`,
  `OfflinePlaybackSyncManager`, and `UserPreferences`.
- App-wide color scheme comes from `UserPreferences.appearanceMode`; app tint is
  `Color.duskAccent`, except iOS/iPadOS tab bar selection stays monochrome with
  the native `.primary` color role so the floating iPad tab bar can adapt over both
  artwork and light content backgrounds.
- `ContentView` is the authenticated root gate: unauthenticated users see
  `SignInView`, disconnected users discover/pick servers, and connected users enter
  `MainTabView`.
- Server discovery/refresh lives in `ContentView`; do not move connection logic into
  feature screens.
- `MainTabView` owns one `NavigationPath` per tab so tab stacks stay independent.
- Re-selecting the active tab pops that tab to root.
- Available tabs are data-driven: one library type can become a direct Movies/Shows
  tab, mixed setups use the Libraries hub, and Downloads appears only when visible
  and populated.
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
- Poster UI is layered: `PosterArtwork`, `PosterCardText`, `PosterCard`,
  `PosterNavigationCard`, and `PosterActionCard`.
- Use `PlexItemPosterCarouselSection` for horizontal shelves and
  `PlexItemPosterGrid` for grids. They already handle image sizing, context menus,
  progress, and route creation.
- Context menus for partially watched playable items should expose both watch-state
  endpoints: mark watched and mark unwatched. Do not collapse partial progress into
  a single toggle action.
- Use `MediaCarousel` for generic horizontal sections with optional "Show all" accessory.
- Use `AdaptivePosterGridLayout.make(...)` for responsive poster grids. Do not hand-roll
  column math in feature files.
- Use `DuskPosterMetrics` for platform-sensitive poster widths, grid spacing,
  horizontal padding, detail padding, and text fonts.
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
  background underneath is the only fill at the hero boundary.
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
- On tvOS, poster, episode, and cast artwork controls should use
  `duskSuppressTVOSButtonChrome()` plus `duskTVOSFocusEffectShape`. Avoid SwiftUI's
  `.plain`, `.borderless`, `.glass`, and `.card` button styles directly here because
  real Apple TV hardware can draw gray/white system focus plates. When a poster card
  has labels below the artwork, keep the artwork as the actual control but apply
  `duskTVOSFocusedScale` to the outer card so the full poster container grows with
  a tight neutral white glow and without gaining a button background.
- Use platform helpers in `View+Platform.swift` instead of scattering `#if os(tvOS)`:
  `duskNavigationTitle`, title display modes, list background/separator suppression,
  status-bar helpers, tvOS button chrome suppression, and tvOS focus effect shape.

## Home

- `HomeView` is the tab root. It owns `HomeViewModel`, handles loading/error state,
  refreshes on appear, scene activation, and player dismissal, then delegates layout to
  `HomeIOSView` or `HomeTVView`.
- `HomeViewModel` is the only home object that calls `PlexService`.
- Home data combines global hubs from `getHubs()`, continue watching from
  `getContinueWatching()`, and personalized shelves from `HomeRecommendationEngine`.
- Home publishes the base hub and continue-watching payload first, then expands
  Recently Added hubs and loads personalized shelves through cancellable follow-up
  tasks. Keep this two-phase behavior so expensive recommendation work does not block
  the first visible home content.
- Continue-watching items drive `HomeCinematicHero`.
- Home filters playlist/music/unknown content and hides Plex "continue watching/on deck"
  hubs so the custom continue-watching flow is not duplicated.
- Recently Added hubs are expanded through `getHubItems(...)` so shelf limits are
  intentional and "Show all" can point to `.hub`.
- `HomeCinematicHero` owns optional hero rotation, drag navigation on iOS, tvOS remote
  swipe capture, image preloading, title-logo fallback, pager state, and motion
  reduction. The home shells keep automatic rotation disabled so returning from
  playback preserves the selected hero instead of advancing in the background. Extend
  it carefully; it is stateful and timing-sensitive.
- On tvOS, `HomeCinematicHero` pixel-aligns its render size and caps image dynamic
  range to standard to avoid real-device HDR/SDR seams between the backdrop fade and
  the shelves below.
- On tvOS, the home hero is intentionally taller than iOS but should still leave
  enough of the first shelf visible to make lower home content discoverable and
  reachable through normal focus movement. Keep the title/logo block, metadata, and
  hero button sizing restrained so the hero reads cinematic instead of crowded.
- `HomeIOSView` and `HomeTVView` should stay composition shells. Keep Plex data rules in
  `HomeViewModel`, not in platform views.
- Use `HomeItemContextMenu` for hero context actions. It already exposes mark watched,
  details, season, and show routes when available.
- `HomeHubItemsView` is the full "show all" grid for hub contents. It has its own small
  view model and uses the shared poster grid.

## Libraries

- `LibrariesViewModel` loads Plex libraries once and groups by `PlexLibraryType`.
- `MainTabView` reuses a single `LibrariesViewModel` to decide tabs and feed library
  screens. Avoid each tab independently discovering libraries.
- `LibrariesHubView` is the combined Libraries tab; it lists available media types and
  navigates to library recommendations or a library picker.
- `LibrariesView` is the direct Movies/Shows tab wrapper. If exactly one matching
  library exists, it goes straight to `LibraryRecommendationsView`.
- `LibraryRecommendationsViewModel` is the library-scoped home equivalent:
  `getLibraryHubs(...)`, continue-watching hub extraction, recently-added expansion,
  and personalized shelves from `LibraryRecommendationEngine`.
- `LibraryItemsView` is the browse grid for a concrete library or genre route.
- `LibraryItemsViewModel` handles pagination, sort, genre selection, and optional local
  genre filtering.
- Use `LibraryGenreSupport` for Plex genre filter discovery, normalization, URL
  parameter extraction, and fallback matching. Do not compare genre strings ad hoc.
- `LibraryItemsViewModel` uses a `queryGeneration` guard so stale async page loads do
  not mutate current results. Preserve this pattern when adding filters.
- Infinite scroll is triggered from `PlexItemPosterGrid.onItemAppear`; keep pagination
  logic in the view model.

## Detail Screens

- Detail entry is split by domain: movie, show, season, episode, and actor detail
  views each have their own `@Observable` model.
- Detail views own screen layout; detail view models own Plex fetches, offline fallback,
  watch-state mutations, image URL selection, and computed display state.
- Shared detail UI lives in `DetailSharedViews.swift` only when reused across detail
  screens.
- Use `DetailHeroSection` for cinematic detail headers. It handles backdrop gradients,
  poster/title artwork, supertitle/subtitle/action slots, safe-area offset, and compact
  action placement.
- Use `detailHeroNativeSecondaryButtonStyle()` and `detailHeroActionSpacing` for
  secondary hero actions so native glass focus feedback stays consistent across
  movie, season, episode, and download controls without focused capsules colliding.
- On tvOS, keep focusable detail rows in separate `.focusSection()` groups. Hero
  actions, expandable summaries, season/episode grids, and cast shelves should move
  vertically to the next visible row instead of letting the focus engine skip to a
  lower but more horizontally aligned item.
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
- `SeasonDetailView` uses a tvOS-only horizontal, poster-only episode shelf. Focused
  episode cards update the hero artwork, title/subtitle area, and the episode cast row
  inside stable-height regions so rapid remote navigation does not shift the scroll
  position; selecting a tvOS episode card starts playback directly while iOS keeps the
  vertical episode list and detail-navigation behavior.
- `EpisodeDetailViewModel` handles single-episode metadata, parent show/season links,
  watch toggles, and offline availability.
- `ActorDetailViewModel` loads a person plus filmography by searching Plex for exact role
  matches. Keep this search behavior local to actor detail unless Plex gets a stronger
  people endpoint.
- Use `PlayVersionContextMenu` for alternate media versions; it filters out unplayable
  versions with no parts.
- Use `DownloadActionButton` and `DownloadContextMenuContent` from the downloads
  feature for download actions. Do not duplicate download state UI in detail screens.
- Offline-capable detail models may show cached metadata before network refresh. Preserve
  `isUsingCachedData`, offline-fallback state, `offlineStateVersion`, and
  `OfflinePlaybackSyncManager` checks when changing watched/progress behavior.
- Some show/season loading is intentionally sequential to avoid async-let runtime aborts
  during transient context-menu navigation lifetimes. Do not "optimize" it back to
  `async let` without reproducing that scenario.

## Search And Settings

- `SearchView` owns a tab `NavigationStack` and lazy-creates `SearchViewModel`.
- Search is debounced in the view model with a cancellable `Task`; views only bind the
  query and render grouped results.
- Empty, loading, error, and no-result rows are local because Search uses a `List`, but
  colors and symbols must still follow shared style tokens.
- Search result rows route through `AppNavigationRoute.destination(for:)` so people,
  movies, shows, seasons, and episodes stay consistent with the rest of the app.
- `SettingsView` selects the platform shell. Shared sheet/navigation chrome is in
  `SettingsContainer`.
- `SettingsViewModel` is for transient settings UI state: server picker, server load
  errors, image cache status, app version, and server switching.
- Persistent settings live in `UserPreferences`, not `SettingsViewModel`.
- `UserPreferences` is `@Observable`, environment-injected, and backed by `UserDefaults`.
  Add new user-facing preferences there with a key, default loading, and persistence.
- `forceAVPlayer` and `forceVLCKit` are mutually exclusive in `UserPreferences`; do not
  bypass those setters.
- `videoEnhancementMode` is a persisted playback preference with Auto, On, and
  Off settings. It affects local rendering only, must not request Plex
  transcoding, and must not alter startup quality.
- Playback Info exposes Video Enhancement state and detail rows so AVPlayer and
  VLCKit sessions can explain whether enhancement is active, waiting for a
  frame, disabled by preference, or unavailable for a stream/runtime reason.
- `SettingsSupport` owns shared settings copy, URLs, language options, and bindings.
- Player Quality lives in the in-player gear menu, not global Settings. It is a
  per-session manual action and must not create a persisted default that starts
  future sessions transcoded.
- iOS settings use `List`, `Section`, `Picker`, `Toggle`, `Link`, Safari sheet, and
  confirmation dialogs.
- tvOS settings use `ScrollView` plus `TVSettingsSection`, `TVSettingsMenuRow`,
  `TVSettingsToggleRow`, and action/link row components. Keep tvOS rows focus-friendly
  and avoid iOS list-only affordances there.

## Platform Differences

- Prefer separate platform composition files for large differences:
  `HomeIOSView`/`HomeTVView`, `SettingsIOSView`/`SettingsTVView`.
- Prefer shared modifiers/helpers for small differences.
- tvOS often needs larger poster metrics, explicit focus sections, `scrollClipDisabled`,
  explicit page backgrounds, plain/custom poster focus, glass button styles for primary
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

- `STYLE.md` is authoritative. Use `Color.duskBackground`, `duskSurface`,
  `duskTextPrimary`, `duskTextSecondary`, and `duskAccent`.
- Root feature screens should paint `Color.duskBackground.ignoresSafeArea()`.
- Elevated rows/cards use `Color.duskSurface` and subtle 1pt strokes.
- Primary playback actions use `Color.duskAccent`; do not introduce ad-hoc brand colors.
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
