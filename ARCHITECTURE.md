# Dusk Architecture

This file is the quick map of the current codebase after the refactor. It is intentionally shorter than `SPEC.md`.

## Read This With

- `SPEC.md`: product and playback requirements
- `STYLE.md`: visual system and UI tokens
- `AGENTS.md`: repo-specific working rules

## Core Principles

- Plex is the only backend. Do not introduce provider abstractions unless a second backend actually exists.
- Views do not talk to the network. `@Observable` view models call `PlexService`.
- Shared behavior should live in `Shared/` or in focused support files, not in giant feature files.
- Platform differences are allowed at the screen-shell level. Shared product feel should come from shared state, copy, tokens, and reusable primitives.
- `project.yml` is the source of truth for the Xcode project. Regenerate `Dusk.xcodeproj` with `xcodegen generate` after adding files.

## High-Level Shape

```text
Dusk/Sources
  App/                 App entry, theme, navigation shell
  Models/              Plex response models and app-facing media types
  PlexService/         Plex auth, discovery, library, playback, images, networking
  Playback/            PlaybackEngine protocol, AVPlayer/VLCKit engines, resolver
  Features/
    Home/              Home screen and full hub browsing
    Libraries/         Library browsing
    Search/            Search UI and results
    Detail/            Movie / Show / Season / Episode / Actor detail flows
    Player/            Full-screen player, overlays, up next, coordinator
    Settings/          Preferences and server/account management
  Shared/              Reusable UI/state/formatting helpers
```

## Data Flow

```text
SwiftUI View
  -> ViewModel (@Observable)
  -> PlexService
  -> Plex API

Playback button
  -> PlaybackCoordinator
  -> PlexService.getMediaDetails(...)
  -> StreamResolver / PlaybackEngineFactory
  -> PlayerView + PlayerViewModel
```

## Important Boundaries

### `PlexService/`

`PlexService` stays Plex-specific, but it is split by concern:

- `PlexService.swift`: shared state, init, persisted server/token setup
- `PlexService+Auth.swift`
- `PlexService+Servers.swift`
- `PlexService+Library.swift`
- `PlexService+People.swift`
- `PlexService+Playback.swift`
- `PlexService+Images.swift`
- `PlexService+Networking.swift`

If you need a new Plex API call, add it to the matching concern file instead of growing one large service file again.

### `Features/Detail/`

The detail feature is split by media/domain instead of one mega screen:

- `MovieDetailView(.Model)`
- `ShowDetailView(.Model)`
- `SeasonDetailView(.Model)`
- `EpisodeDetailView(.Model)`
- `ActorDetailView(.Model)`
- `DetailSharedViews.swift`
- `MediaDetailDestinationView.swift`

Add shared detail UI to `DetailSharedViews.swift` only when it is reused by multiple detail screens.

### `Features/Player/`

The player has a few explicit layers:

- `PlaybackCoordinator*`: session orchestration, timeline reporting, up next
- `PlayerView`: full-screen shell and presentation wiring
- `PlayerViewModel*`: controls state, scrubbing, track selection, sync from engine
- `PlayerControlsOverlay`, `PlayerUpNextOverlayView`, `PlayerDebugOverlayView`, `PlayerSelectionSheet`: overlay/presentation pieces

Keep engine-agnostic player UI in `Features/Player/`. Keep AVPlayer/VLCKit specifics in `Playback/`.

### `Features/Settings/`

Settings now uses separate platform shells with shared building blocks:

- `SettingsIOSView`
- `SettingsTVView`
- `SettingsContainer`: shared navigation/sheet chrome
- `SettingsViewModel`: shared state/actions
- `SettingsSupport`: shared labels, language metadata, bindings
- `TVSettingsComponents`: tvOS-specific reusable rows/sections

When iOS and tvOS need different layouts, prefer separate view composition over heavy `#if` branching in one file.

### `Shared/`

Put broadly reused helpers here, especially when multiple features need the same thing:

- `FeatureStateViews.swift`: loading / empty / error states
- `AdaptivePosterGrid.swift`: common poster-grid sizing
- `MediaFormatting.swift`: episode labels, durations, counts, progress
- `CircularProgressView.swift`
- `PosterCard.swift`
- `View+Platform.swift`

Do not duplicate formatting helpers or load/error UI inside feature files if a shared primitive already exists.

## Preferred Extension Pattern

For types that grow naturally large, split by concern using same-type extensions in separate files. Current examples:

- `PlaybackCoordinator.swift` + `PlaybackCoordinator+Session.swift` + `PlaybackCoordinator+Timeline.swift` + `PlaybackCoordinator+UpNext.swift`
- `PlayerViewModel.swift` + `PlayerViewModel+PlaybackControls.swift` + `PlayerViewModel+TrackSelection.swift` + `PlayerViewModel+Presentation.swift`

Use this when the type is still one concept but the file is becoming a wall of unrelated behavior.

## Where New Code Should Go

- New Plex endpoints: matching `PlexService+*.swift`
- New shared browse/detail UI primitives: `Shared/`
- New detail screens or shared detail pieces: `Features/Detail/`
- New player overlays or sheets: `Features/Player/`
- New settings copy/state: `SettingsSupport.swift` or `SettingsViewModel.swift`
- New settings layout differences: `SettingsIOSView.swift` or `SettingsTVView.swift`

## Avoid Re-Introducing

- Giant multi-screen files
- Generic backend abstractions for Plex-only code
- View-level networking
- Repeated duration / episode / progress formatting logic
- Repeated loading / empty / error state implementations
