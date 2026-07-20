# Codebase Map

This is the fast orientation map for `Dusk/Sources`. It is intentionally about
ownership and flow, not a full symbol index.

## Top-Level Shape

```text
Dusk/Sources
  App/                 App entry, dependency injection, tabs, routes
  Models/              Plex response models and app-facing media structs
  PlexService/         Plex auth, server discovery, API calls, images, playback URLs
  Playback/            PlaybackEngine protocol, AVPlayer/VLCKit engines, resolver
  Downloads/           Queue, file store, metadata cache, offline sync
  Shared/              Reusable UI, formatting, image loading, recommendation helpers
  Features/
    Account/           Sign-in and server picker
    Home/              Home hubs, continue watching, recommendations
    Libraries/         Library list, library item grids, recommendations
    Detail/            Movie/show/season/episode/video/person detail flows
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
destinations should normally be added there. Tabs are per library type (Movies,
TV Shows, Videos); on iOS an overflow `MoreView` tab absorbs Search/Settings
(and Downloads if needed) to stay within five tabs, while tvOS stays flat.

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

- `PlaybackCoordinator` starts sessions and owns timeline/scrobble/up-next.
- `PlayerView` and `PlayerViewModel` own on-screen player interaction.
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
- `PlexService` is intentionally Plex-specific. Do not add generic provider
  protocols without a real second backend.
- The app is stateless beyond Keychain auth, UserDefaults preferences, and
  download/offline files.
- Direct play is the startup playback model. Manual transcoding is only a
  per-session player quality action and must not become a persisted default
  that starts future sessions transcoded.
- iOS and tvOS can have different shells, but shared state and reusable UI should
  stay common where practical.
- Keep docs in this directory aligned with meaningful changes.
