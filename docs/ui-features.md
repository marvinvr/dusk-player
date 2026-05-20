# Dusk UI Feature Layer

Operational notes for agents changing SwiftUI screens, feature view models, and shared UI
in Dusk. Read this with `ARCHITECTURE.md`, `STYLE.md`, and `docs/data-and-plex.md`.

## App And Navigation Shell

- `DuskApp` creates the long-lived app services and injects them into the SwiftUI
  environment: `PlexService`, `PlaybackCoordinator`, `DownloadManager`,
  `OfflinePlaybackSyncManager`, and `UserPreferences`.
- App-wide color scheme comes from `UserPreferences.appearanceMode`; app tint is
  always `Color.duskAccent`.
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
- Continue-watching items drive `HomeCinematicHero`.
- Home filters playlist/music/unknown content and hides Plex "continue watching/on deck"
  hubs so the custom continue-watching flow is not duplicated.
- Recently Added hubs are expanded through `getHubItems(...)` so shelf limits are
  intentional and "Show all" can point to `.hub`.
- `HomeCinematicHero` owns hero rotation, drag navigation on iOS, tvOS remote swipe
  capture, image preloading, title-logo fallback, pager state, and motion reduction.
  Extend it carefully; it is stateful and timing-sensitive.
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
  plain button suppression or glass button styles, and default focus restoration.
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
