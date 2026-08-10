# Codebase Map

This is the fast orientation map for `Dusk/Sources`. It is intentionally about
ownership and flow, not a full symbol index.

## Top-Level Shape

```text
Dusk/Sources
  App/                 App entry, dependency injection, tabs, routes
  Models/              Plex response models and app-facing media structs
  PlexService/         Plex auth, server discovery, API calls, images, playback URLs
  SeerrService/        Optional Seerr auth sessions, API calls, and request state
  Playback/            PlaybackEngine protocol, AVPlayer/VLCKit engines, resolver
  Downloads/           Queue, file store, metadata cache, offline sync
  Shared/              Reusable UI, formatting, image loading, recommendation helpers
  Features/
    Account/           Sign-in and server picker
    Home/              Home hubs, continue watching, recommendations
    Libraries/         Library list, library item grids, recommendations
    LiveTV/            Channel guide, on-now Home shelf, Live TV state
    Detail/            Movie/show/season/episode/video/person detail flows
    Seerr/             Request-only external movie/show/season detail flows
    Player/            Full-screen playback UI and coordinator
    Downloads/         Downloads screen and download controls
    Search/            Search view and view model
    Settings/          Preferences and server/account settings
    Supporter/         Supporter tier: StoreKit store, sheet, prompt, app icons
```

## App Lifetime

`DuskApp` constructs the shared long-lived services and injects them into the
SwiftUI environment:

- `PlexService`
- `SeerrService`
- `PlaybackCoordinator`
- `DownloadManager`
- `OfflinePlaybackSyncManager`
- `UserPreferences`
- `SupporterStore`

`ContentView` gates the app by auth/connection state:

```text
not authenticated -> SignInView
authenticated but no server -> discovery / ServerPickerView
connected -> MainTabView
```

`MainTabView` owns independent `NavigationPath`s per tab and presents
`PlayerView` as a full-screen cover when `PlaybackCoordinator.showPlayer` is
true. App-wide routes are declared in `AppNavigationRoute`; new top-level
destinations should normally be added there. Content tabs cover library types
(Movies, TV Shows, Videos) and Live TV when the selected server exposes it,
with visibility and order supplied by `UserPreferences`;
iOS/iPadOS expose Search from Home/library toolbars, while
tvOS keeps it as a flat destination. iPadOS keeps every remaining destination
flat. On iPhone, content beyond the first three visible destinations and any
trailing Downloads/Settings destinations are absorbed by `MoreView` to stay
within five tabs.

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

Do not create feature-local copies of these patterns unless the behavior is
truly feature-specific.

## Feature Ownership

Home:

- `HomeView` chooses iOS/tvOS shell.
- `HomeViewModel` loads hubs, continue watching, and recommendation shelves.
- `HomeRecommendationEngine` owns home-specific recommendation orchestration.
- `HomeCinematicHero` is large and visual; keep reusable poster/list UI outside it.
- `LiveTVHomeShelf` renders currently airing programs without blocking ordinary
  Home content when Live TV is absent or unavailable.

Live TV:

- `LiveTVViewModel` discovers the EPG provider, loads channels, and owns the
  selected date's guide.
- `LiveTVView` renders current, past, and future schedule metadata. Only an
  airing program starts playback; arbitrary past guide entries are not recordings.
- `PlexService+LiveTV` owns provider/channel/grid/tune endpoints and
  `PlexLiveTV.swift` owns their response shapes.

Libraries:

- `LibrariesViewModel` loads available Plex libraries (movie, show, and video
  sections; `PlexLibrary.libraryType` classifies "Other Videos" sections).
- `LibraryItemsViewModel` owns paged item loading, sorting, genre filtering, and
  optional collection scoping (`LibraryCollectionItemsView`).
- `LibraryRecommendationsViewModel` and `LibraryRecommendationEngine` own
  library-scoped personalization; `.video` libraries use `LibraryVideoShelfLoader`
  (channel/collection rows + seeded Rediscover) instead of the genre engine.

Detail:

- Each media type has a view and view model.
- `MediaDetailDestinationView` routes `PlexMediaType` to the right detail screen.
- Shared detail UI belongs in `DetailSharedViews.swift` only when multiple
  detail screens use it.
- Offline-aware detail behavior lives in the view models through
  `DownloadManager` and `OfflinePlaybackSyncManager`.

Player:

- `PlaybackCoordinator` starts library and Live TV sessions and owns
  timeline/scrobble/up-next. Live sessions never scrobble.
- `PlayerView` and `PlayerViewModel` own on-screen player interaction.
- `PlayerLiveTimeline.swift` owns the Live TV play bar's wall-clock model
  (live-edge estimate, program window, behind-live offset).
- Engine-specific work stays in `Playback/`.

Downloads:

- `DownloadManager` owns queue state and public download actions.
- `DownloadTransferController` owns `URLSessionDownloadDelegate`.
- `DownloadFileStore` owns local paths and persistence.
- `OfflinePlaybackSyncManager` queues watch-state/timeline changes made offline.

Settings:

- `UserPreferences` persists settings in `UserDefaults`.
- `SettingsViewModel` owns settings actions that need services.
- iOS/tvOS layouts are separate views with shared support helpers.

Search and Seerr:

- `SearchViewModel` owns the additive Plex/Seerr merge. Plex results publish
  first and remain usable if Seerr fails.
- `SearchMediaResult` keeps external cards out of Plex playback/download paths.
- `Features/Seerr` contains request-only details and must never expose playback.
- `ShowDetailViewModel` enriches missing seasons only through exact Plex TMDB
  GUIDs. Details and traps: `docs/seerr-integration.md`.

Supporter:

- `SupporterStore` owns StoreKit 2 state; supporter status is monotonic
  (any purchase ever, cached in UserDefaults, never downgraded).
- `SupporterView` is the single pitch/thank-you/prompt sheet;
  `SupporterPromptPresenter` gates the iOS/iPadOS three-prompt ladder from
  `MainTabView`, while tvOS support remains available explicitly in Settings.
- `DuskAppIcon` + `AppIconPickerView` own the alternate icons (iOS-only).
- Details and traps: `docs/supporter.md`.

## Where New Code Goes

- New Plex endpoint: matching `PlexService+*.swift` file.
- New Seerr endpoint: `SeerrService/`, without widening `PlexService` or adding
  a generic provider protocol.
- New Plex response shape: `Models/`, with optional fields where Plex varies by
  media type.
- New playback format decision: `StreamResolver`.
- New engine behavior: concrete engine in `Playback/`, not player UI.
- New player overlay/control: `Features/Player/`.
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
- `PlayerView.swift`: platform input bridges and full-screen player composition.
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
- The app is stateless beyond Keychain auth, UserDefaults preferences, and
  download/offline files.
- Direct play is the startup playback model. Manual transcoding is only a
  per-session player quality action and must not become a persisted default
  that starts future sessions transcoded.
- iOS and tvOS can have different shells, but shared state and reusable UI should
  stay common where practical.
- Keep docs in this directory aligned with meaningful changes.
