# Codebase Map

This is the fast orientation map for `Dusk/Sources`. It is intentionally about
ownership and flow, not a full symbol index.

## Top-Level Shape

```text
Dusk/Sources
  App/                 App entry, dependency injection, tabs, routes, server connect pass
  Analytics/           Anonymous event + error vocabulary and fire-and-forget reporting
  Models/              Plex response models and app-facing media structs
  PlexService/         Plex auth, the multi-server session pool, API calls, images, playback + subtitle URLs
    MultiServer/       Cross-server merging (continue watching, hubs, search),
                       same-server movie copies, the alternates index, and library server labelling
  SeerrService/        Optional Seerr auth sessions, API calls, and request state
  IPTVService/         IPTV sources per Plex profile: M3U/XMLTV parsers, lineup
                       mapping onto the Live TV models, loader (see docs/iptv.md)
  TraktService/        Optional Trakt link per Plex profile: sign-in, tokens,
                       finished-item history queue (see docs/trakt.md)
  Playback/            PlaybackEngine protocol, AVPlayer/VLCKit engines, resolver,
                       VLCKit build capabilities (TrueHD)
    DolbyVision7/      Dolby Vision 7 → 8.1: loopback HLS proxy, fMP4 init/fragment
                       and playlist rewriting, DoviBridge over Native/DuskDovi
  Downloads/           Queue, file store, metadata cache, offline sync
  Shared/              Reusable UI, formatting, image loading, recommendation helpers
  Features/
    Account/           Sign-in and Plex Home profile picker
    Home/              Home hubs, continue watching, recommendations
    Libraries/         Library list, library item grids, recommendations
    LiveTV/            Channel guide, on-now Home shelf, Live TV state
    Photos/            Photo library grids (albums, timeline) and the full-screen viewer
    Detail/            Movie/show/season/episode/video/person detail flows
    Seerr/             Request-only external movie/show/season detail flows
    Player/            Full-screen playback UI and coordinator
    Downloads/         Downloads screen and download controls
    Playlists/         Playlists tab, playlist page, Add to Playlist sheet
    Watchlist/         Plex Watchlist bookmark/menu actions, off-server title page
    Search/            Search view and view model
    Settings/          Preferences, server priority, and account settings
    Supporter/         Supporter tier: StoreKit store, sheet, prompt, app icons
  Siri/                App Intents: "Play <title> in Dusk", title matching, Siri title catalog
  TopShelf/            tvOS Top Shelf: App Group snapshot, publisher, deep-link router
                       (the extension itself lives in DuskTopShelf/)
```

Outside `Dusk/Sources`, `Native/DuskDovi/` is the Rust wrapper crate over
libdovi (`dolby_vision`) with its frozen C header. It is built into
`Frameworks/DuskDovi.xcframework` (not committed, like VLCKit) and only
`DoviBridge.swift` imports it.

## App Lifetime

`DuskApp` constructs the shared long-lived services and injects them into the
SwiftUI environment:

- `PlexService`
- `SeerrService`
- `PlaybackCoordinator`
- `DownloadManager`
- `OfflinePlaybackSyncManager`
- `UserPreferences`
- `AnalyticsClient`
- `SupporterStore`

`ContentView` gates the app by session state only — there is no server step:

```text
not authenticated      -> SignInView
Home bootstrap pending -> loading / retry
Home user needed       -> HomeUserPickerView
otherwise              -> MainTabView
```

Connecting happens *underneath* the shell. `ServerConnectionCoordinator`
(`App/`) runs `plexService.connectAllServers()` on first mount, on a profile
switch, on return to the foreground, and on a network-path change, and publishes
itself in the environment so any screen can offer a retry (`refresh()`). Servers
appear as they answer; a server that never does is a per-screen note, never a
blocking wall, and Downloads stays reachable throughout.

`MainTabView` owns independent `NavigationPath`s per tab and presents
`PlayerView` as a full-screen cover when `PlaybackCoordinator.showPlayer` is
true. App-wide routes are declared in `AppNavigationRoute`; new top-level
destinations should normally be added there. Content tabs cover library types
(Movies, TV Shows, Videos, Photos) and Live TV when any connected server
exposes it, with visibility and order supplied by `UserPreferences`;
iOS/iPadOS expose Search from Home/library toolbars, while
tvOS keeps it as a flat destination. iPadOS keeps every remaining destination
flat. On iPhone, content beyond the first three visible destinations and any
trailing Downloads/Settings destinations are absorbed by `MoreView` to stay
within five tabs.

On macOS `ContentView` mounts `MacRootView` (`Mac/`) instead: a
`NavigationSplitView` sidebar over the same content destinations (`MainTabItem`,
same `UserPreferences` order/visibility) with one `NavigationStack` per
destination, paths held by the app-wide `MacShellRouter` that the menu bar
(`MacCommands`) drives. The app owns `ServerConnectionCoordinator` there so the
`Settings` scene (⌘,) shares it, and `MacPlayerView` covers the window while
`showPlayer` is true. See `docs/macos.md`.

## Shared Boundaries

Use `Shared/` when code is reused by multiple features or establishes a product
primitive:

- `PosterCard`, `PlatformPosterCard`, `PlexItemPosterCollections`: poster cards,
  action cards, grids, and carousels.
- `MediaFormatting`: episode labels, durations, dates, progress, and version
  labels.
- `PlexItemPresentation`: common poster URL/subtitle/progress/title helpers.
- `FeatureStateViews`: loading, empty, and error states.
- `DuskAsyncImage`: image loading through `PlexService`.
- `RecommendationCore`: scoring and deterministic randomization helpers shared
  by home/library recommendation engines.
- `PlexService+ServerIdentity`: the stable server binding persisted state uses
  (`seerrBindingServerID`), plus known-server checks and the one-time mapping of
  pre-multi-server base-URL identifiers onto machine identifiers.
- `PlexService+WatchedFanOut`: `setWatchedAcrossServers`, the one place an
  explicit watched/unwatched action reaches every server holding the content.

Do not create feature-local copies of these patterns unless the behavior is
truly feature-specific.

## Feature Ownership

Home:

- `HomeView` chooses iOS/tvOS shell.
- `HomeViewModel` loads hubs, continue watching, and recommendation shelves.
- `HomeFirstPaintGate` decides when Home's first multi-server merge is stable
  enough to paint; `HomeContinueWatchingMemory` remembers which servers had
  Continue Watching so the gate knows whose answer to wait for.
- `HomeRecommendationEngine` owns home-specific recommendation orchestration.
- `HomeCinematicHero` is large and visual; keep reusable poster/list UI outside it.
- `LiveTVHomeShelf` renders currently airing programs without blocking ordinary
  Home content when Live TV is absent or unavailable.
- `HomeHubFilter` owns the hub/item filter that keeps playlist/music/unknown
  content and Plex's own continue-watching rows off Home.
- `HomeHubArrangement` regroups the merged hubs so a library's rows follow the
  account's library order, keyed on `PlexLibrary.id` (never the bare section key,
  which aliases across servers). Home has no user-editable row layout.
- Home merges every connected server: `HubMerge`, `ContinueWatchingMerge` and
  `PlexService.streamAcrossServers` republish the screen as each server answers.

Live TV:

- `LiveTVViewModel` discovers the EPG provider (retrying until a server has a
  DVR or all have said no; `isAvailable` is `provider != nil`), loads
  channels, and owns the selected date's guide.
- `LiveTVView` renders current, past, and future schedule metadata. Only an
  airing program starts playback; arbitrary past guide entries are not recordings.
- `PlexService+LiveTV` owns provider/channel/grid/tune endpoints and
  `PlexLiveTV.swift` owns their response shapes.

Libraries:

- `LibrariesViewModel` exposes the available Plex libraries (movie, show, video
  and photo sections; `PlexLibrary.libraryType` classifies "Other Videos" sections).
  Its `libraries` is a read-through of `PlexService.libraryOrder.orderedSections`,
  so every library list follows the order stored on the Plex account — which now
  spans every connected server; it loads through `ensureLibraryOrderLoaded(force:)`
  and never stores its own copy. Video sections stay out of it until counted
  non-empty (photo sections too). `ServerLabeling` decides when a library has to
  name its server (same type, same title).
- `LibrariesView` lands each type tab on `LibraryRecommendationsView` for all of
  that type's libraries; `LibraryTypeListView` is the list of a type's libraries
  when there is more than one.
- `LibraryItemsViewModel` owns paged item loading, sorting, genre filtering, and
  optional collection scoping (`LibraryCollectionItemsView`, a video library's
  channel filter). Plex collections of movie/TV libraries are
  `LibraryCollectionsView`/`LibraryCollectionsViewModel` (paged grid) and
  `Detail/CollectionDetailView` + model; `DetailCollectionShelves` is the "Part of"
  row on movie/show detail pages, `DetailExtrasShelf` the "Extras" row on movie/show/
  season/episode pages; `Shared/PlexItemPager` pages plain listings.
- Photo libraries live in `Features/Photos`: `PhotoBrowserViewModel` (paged
  albums/timeline queries over `PlexService+Photos`, `PlexPhotoItem`),
  `PhotoBrowserView` (grid, also the album route) and `PhotoViewerView` (full-screen
  viewer, iOS zoom, tvOS slideshow). See `docs/ui-features.md` → "Photos".
- `LibraryRecommendationsViewModel` takes one *or several* libraries of the same
  type and merges their hubs and shelves; `LibraryRecommendationEngine` owns the
  per-library personalization. `.video` libraries use `LibraryVideoShelfLoader`
  (channel/collection rows + seeded Rediscover) instead of the genre engine.

Detail:

- Each media type has a view and view model.
- `MediaDetailDestinationView` routes `PlexMediaType` to the right detail screen.
  On tvOS, show, season, and episode routes all land on `SeriesDetailView` (one
  page per show with season pills); the separate show/season/episode views are
  iOS/iPadOS-only.
- Shared detail UI belongs in `DetailSharedViews.swift` only when multiple
  detail screens use it.
- Offline-aware detail behavior lives in the view models through
  `DownloadManager` and `OfflinePlaybackSyncManager`.

Player:

- `PlaybackCoordinator` starts library and Live TV sessions and owns
  timeline/scrobble/up-next. `playbackQueue` (`PlaybackQueue`) is set only for
  playlist/list sessions; `resolveUpNext` is the single Up Next decision. Live sessions never scrobble. Its entry points take
  a `PlexItemID`, and `activePlaybackServerID` is what every follow-up call is
  routed to.
- `PlaybackSourceResolver` picks which connected server plays an item and in
  which order the others are tried.
- `PlaybackCoordinator+ServerTracks` rebuilds Plex HLS for audio/subtitle
  changes, retaining manual quality and supporting PGS burn-in; it also owns
  AV1 server-conversion fallback.
- `PlaybackSharePlayController` owns Group Activities lifecycle and attaches the
  active AVPlayer or VLCKit engine to coordinated playback; Up Next republishes
  the server-scoped Plex item through `DuskWatchTogetherActivity`.
- `PlaybackAirPlayController` observes the iOS system route; AirPlay handoffs
  stay in the coordinator and use Plex HLS plus AVPlayer, so receivers do not
  need Dusk installed.
- `PlayerView` and `PlayerViewModel` own on-screen player interaction.
- `ShowTrackPreferences` owns semantic per-show track matching and profile/server/
  show-scoped persistence; `PlaybackCoordinator+ShowTracks` records explicit
  choices and syncs per-part selections to Plex. See `docs/playback.md`.
- tvOS's HUD is its own small stack, all of it file-scope `#if os(tvOS)`:
  `PlayerTVHUDController` (the `hidden`/`transport`/`scrubbing`/`panel` state
  machine), `PlayerTVRemoteInputBridge` (the player's single remote-input
  owner — nothing else in the tvOS player is focusable except
  `PlayerTVInfoPanel`), `PlayerTVHUDLayout` (every tunable),
  `PlayerControlsTVOverlay` + `PlayerTVTransportBar` / `PlayerTVActionRow` /
  `PlayerTVScrubOverlay` (presentation), and `PlayerTVInfoPanel` (the settings
  sheet that replaced the gear menu). See `docs/playback.md` → "tvOS Play Bar".
- `PlayerLiveTimeline.swift` owns the Live TV play bar's wall-clock model
  (live-edge estimate, program window, behind-live offset).
- `SubtitleSearchViewModel`/`SubtitleSearchView` own the "Download Subtitles"
  flow (Plex-proxied OpenSubtitles search + install). Detail screens reuse both
  through their own view models; only the player refreshes the live session.
- Engine-specific work stays in `Playback/`. The Dolby Vision 7 conversion is
  decided in `PlaybackCoordinator+SpatialAudio` (`remuxDolbyVision7Conversion`)
  and run by `AVPlayerEngine` through `Playback/DolbyVision7/`; see
  `docs/playback.md` → "Dolby Vision 7 (on-device 8.1 conversion)".

Downloads:

- `DownloadManager` owns queue state and public download actions.
- `DownloadTransferController` owns `URLSessionDownloadDelegate`.
- `DownloadFileStore` owns local paths and persistence.
- `OfflinePlaybackSyncManager` queues watch-state/timeline changes made offline.

Settings:

- `UserPreferences` persists device-local settings in `UserDefaults`.
- `SettingsViewModel` owns settings actions that need services.
- iOS/tvOS layouts are separate views with shared support helpers.
- `LibraryTabSettingsView` edits the device-local navigation destinations.
- `ServerPrioritySettingsView`/`ServerPrioritySettingsViewModel` own the server
  order and the per-server on/off switch. Every edit writes straight through to
  `ServerPriorityStore` (there is nothing to save); enabling a server connects it,
  disabling it drops its session via `pool.markDisabled`. iOS uses
  `EditButton` + `onMove` + a per-row toggle; tvOS uses position menus. A
  single-server account sees a plain one-row screen with no ordering language.
  Its last section links `ConnectionDiagnosticsView` (every candidate, outcome,
  latency and the winner per server; see `docs/data-and-plex.md`).
- `LibraryOrderSettingsView`/`LibraryOrderSettingsViewModel` edit the order of
  your libraries across servers on every platform. A server name is appended to
  a row only when another library of the same type has the same title. That order is an account-level
  Plex setting, not a Dusk preference: the view model edits a working copy, then
  writes through `PlexService.reorderLibraries(_:)` after a 1s debounce. iOS uses
  `EditButton` + `onMove`; tvOS uses position menus (`docs/ui-features.md`).
- `HiddenLibrariesSettingsView` (Settings › Libraries › Hidden Libraries) is the
  one place to hide a library: a switch per library, grouped by server. It reuses
  `LibraryOrderSettingsViewModel.setHidden`, which writes `pinnedSources[].isHidden`.
- `HiddenHomeRowsSettingsView` (Settings › Home › Hidden Rows) switches Plex's
  per-library Home flag (`PlexService+HomeRows.swift`); Home's Hide Row uses the
  same write.
- `PlexService/LibraryOrderStore` is the single source of that order, and of which
  libraries are hidden, for the whole app; `PlexService+LibraryOrder.swift` owns the
  plex.tv read/write. `PlexService/HiddenLibraryFilter` (`libraryOrder.hiddenLibraryFilter`,
  or `loadedHiddenLibraryFilter()` to wait for the load) drops hidden libraries' items
  wherever libraries mix: Home merge, `search`, `getHubItems`, `getPersonMedia`,
  `HomeRecommendationEngine` (visible sections), `SiriTitleCatalog`.

Playlists:

- `PlexService.playlists` (`PlaylistStore`) is the one copy of the account's
  video playlists; `PlexService+Playlists` loads and edits them.
- `PlexService.pinnedPlaylists` (`PinnedPlaylistStore`) holds the per-profile
  playlists pinned to Home; Home renders them with `HomePinnedPlaylistShelf`.
- `PlaylistsView`, `PlaylistDetailView`/`PlaylistDetailViewModel`,
  `PlaylistActions` and `AddToPlaylist.swift` (target, presenter, menu/hero
  buttons, sheet) live in `Features/Playlists`. See `docs/ui-features.md` →
  "Playlists".
- Playback goes through `PlaybackCoordinator.playQueue` with a
  `PlaybackQueue` (`Features/Player/PlaybackQueue.swift`); lists that play
  through carry a `PlaybackListContext` in their route.

Watchlist:

- `PlexService.watchlist` (`WatchlistStore`) is the account's Plex Watchlist and its
  server matches; `PlexService+Watchlist` loads/edits it (plex.tv Discover).
- Home's row is `Home/HomeWatchlistShelf` placed by `HomeWatchlistPlacement`;
  `Features/Watchlist` has the bookmark/menu actions and the off-server page.
  See `docs/ui-features.md` → "Watchlist".

Search and Seerr:

- `SearchViewModel` owns the additive Plex/Seerr merge. Plex results publish
  first and remain usable if Seerr fails.
- `SearchMediaResult` keeps external cards out of Plex playback/download paths.
- `Features/Seerr` contains request-only details and must never expose playback.
- `ShowDetailViewModel` enriches missing seasons only through exact Plex TMDB
  GUIDs. Details and traps: `docs/seerr-integration.md`.

Siri:

- `DuskIntents.swift` declares the intents, `PlexTitleEntity` and the App
  Shortcut phrases; `SiriPlaybackService` waits for servers, resolves and
  starts playback; `SiriTitleMatching.swift` is the pure, tested matcher and
  next-episode rule; `SiriTitleCatalog` is what Siri learns. See `docs/siri.md`.

Supporter:

- `SupporterStore` owns StoreKit 2 state; supporter status is monotonic
  (any purchase ever, cached in UserDefaults, never downgraded). The one
  subscription ("Dusk Supporter", monthly/yearly) and every perk it unlocks are
  not: they follow the live entitlement read (tips keep the classic icons).
  The pure rules live in `SupporterEntitlements.swift` and are covered by `DuskTests/` (incl. StoreKitTest flows against `Dusk.storekit`).
- `SupporterView` is the single pitch/thank-you/prompt sheet;
  `SupporterPromptPresenter` gates the iOS/iPadOS supporter prompt schedule from
  `MainTabView`, while tvOS support remains available explicitly in Settings.
- `DuskAppIcon` + `AppIconPickerView` (iOS) / `SupporterIconShowcase` (tvOS)
  own the alternate icons (tvOS stacks in `AppIconsTV.xcassets`);
  Velvet/Emerald/Gilded/Sapphire are subscriber exclusives. TestFlight
  (`TestFlightInstall`) unlocks every icon and skips the lapse reset.
- Details and traps: `docs/supporter.md`.

## Where New Code Goes

- New multi-server session behavior: `PlexService/ServerPool.swift` (sessions) or
  `ServerPriorityStore.swift` (order/enabled); *when* to connect belongs in
  `App/ServerConnectionCoordinator.swift`.
- New cross-server merge: `PlexService/MultiServer/`, keyed on `PlexContentKey`.
  Take per-server lists in priority order, stay a pure function of them, and
  return a single list verbatim so single-server installs are untouched.
- New "the servers are the problem" empty state: `Shared/ServerAvailabilityViews.swift`
  (`ServerAvailabilityStateView`, `ServerOutageNote`), driven by `pool.availability`.
- New Plex endpoint: matching `PlexService+*.swift` file — e.g.
  `PlexService+Subtitles.swift` owns the server-side OpenSubtitles search,
  sidecar download, sidecar stream URL, and the `canDownloadSubtitles` gate.
- New Home row type: `HomeViewModel` plus `HomeHubFilter`/`HomeHubArrangement`.
  Home's row sequence is fixed in `HomeIOSView`/`HomeTVView`; keep the two shells
  in step instead of reintroducing a user-editable row layout.
- New account-level Plex setting: `PlexService+LibraryOrder.swift` for the
  read/write and `LibraryOrderStore` for the shared state, not `UserPreferences`.
- New Seerr endpoint: `SeerrService/`, without widening `PlexService` or adding
  a generic provider protocol.
- New Plex response shape: `Models/`, with optional fields where Plex varies by
  media type.
- New playback format decision: `StreamResolver`.
- New engine behavior: concrete engine in `Playback/`, not player UI.
- New player overlay/control: `Features/Player/`.
- New SharePlay activity/session behavior: `Features/Player/`; engine timing
  adaptation remains behind `PlaybackEngine` in `Playback/`.
- New reusable poster/list/detail primitive: `Shared/` or `DetailSharedViews.swift`
  depending on reuse scope.
- New user preference: `UserPreferences`, `SettingsSupport` if display helpers
  are needed, and both settings platform views if it is user-facing.
- New source file under `Dusk/Sources`: run `xcodegen generate`.

## Large Files Worth Knowing

Some files are large because they own a complex boundary:

- `DownloadManager.swift`: queue orchestration, local metadata, file completion,
  aggregate show/season operations.
- `HomeCinematicHero.swift`: responsive hero presentation and interaction.
- `PlayerView.swift`: full-screen player composition, the iOS touch/keyboard
  input bridges, and the tvOS session's wiring to `PlayerTVHUDController`.
- `VLCKitEngine.swift` / `AVPlayerEngine.swift`: concrete playback engine state.
- `SeasonDetailView.swift`: season hero plus episode list variants.

Prefer focused extension files or helper views when adding meaningful new
behavior to these areas. Do not split them mechanically unless the extracted
piece has a clear name and owner.

## Cross-Cutting Invariants

- Views do not call Plex directly unless they are small account/setup views;
  feature views should go through `@Observable` view models.
- `PlexService` is intentionally Plex-specific. Seerr is an optional request
  companion, not a playback provider; do not add a generic provider protocol.
- Every enabled server is connected at once and their content is merged. There is
  no "selected server": anything that reaches a server resolves that server's
  `PlexServerConnection` from `PlexService.pool` by the item's `serverID`. One
  server failing (offline, 401, disabled) must never take the others down.
- Rating keys and section keys collide across servers. Identity is `PlexItemID`
  (serverID + ratingKey); cross-server sameness is `PlexContentKey`.
- The server name is a disambiguator, never decoration. A single-server account
  must look exactly as it did before multi-server.
- The app is stateless beyond Keychain auth, UserDefaults preferences, and
  download/offline files. Settings that Plex itself models across devices
  (library order) live in the Plex account, never in a Dusk-private sync store.
- Direct play is the startup playback model. Manual transcoding is only a
  per-session player quality action and must not become a persisted default
  that starts future sessions transcoded.
- iOS and tvOS can have different shells, but shared state and reusable UI should
  stay common where practical.
- Keep docs in this directory aligned with meaningful changes.
