# Playback System
Operational notes for changing Dusk playback without crossing layer boundaries.

## Boundaries
- `PlexService/` owns Plex endpoints, direct-play URL construction, timeline,
  scrobble, and watch-state calls.
- `Playback/` owns engine selection and concrete AVPlayer/VLCKit engines.
- `Features/Player/` owns session orchestration and UI. It should depend on
  `PlaybackEngine`, not on AVPlayer or VLCKit types.
- `Features/Settings/` owns persisted playback preferences in `UserPreferences`.
- Plex remains the source of truth. Do not introduce a generic media-provider
  abstraction for playback unless another backend actually exists.

## End-to-End Play Flow
1. Detail/list UI asks `PlaybackCoordinator` to play a `ratingKey` through
   `play`, `playFromStart`, or `playVersion`.
2. `startPlaybackSession` gets `PlexMediaDetails` from completed-download cache
   when playable, otherwise from `plexService.getMediaDetails`.
3. The coordinator chooses a `PlexMedia` version, then its first part.
4. If a matching completed download exists, playback uses the local file URL.
   Otherwise `PlexService.directPlayURL(for:)` builds `{serverBaseURL}{part.key}`
   and adds `X-Plex-Token` when available.
5. `StreamResolver.evaluate` records the intended engine and human-readable
   reason. `PlaybackEngineFactory.makeEngine` returns an AVPlayer or VLCKit
   engine, reusing a warmed engine when available.
6. The coordinator creates `PlaybackSource`, `PlaybackAttemptContext`, and
   `PlaybackDebugInfo`, starts now-playing/timeline work, then presents the UI.
7. `PlayerSessionView` creates `PlayerViewModel`, configures preferences and
   markers, then calls `engine.load(source:)` once.
8. The engine validates the URL, loads media, auto-plays, and publishes
   state/time/tracks through the `PlaybackEngine` contract.

## StreamResolver and Media Version Choice
- `StreamResolver.selectMediaVersion` filters out media versions with no
  parts. With multiple candidates it targets `preferences.maxResolution`.
- `MaxResolution.auto` targets 1080p on iOS/iPadOS and 4K on tvOS.
- The preferred resolution is a target, not a hard failure: choose the highest
  height at/below target, then closest above target, then unknown-height
  candidates by bitrate.
- Tie-breakers are higher bitrate, `optimizedForStreaming`, then Plex order.
- `playVersion(ratingKey:mediaID:)` bypasses automatic version choice but still
  requires that media version to have at least one part.
- `StreamResolver.evaluate` only decides engine type and reason. It does not
  build URLs, validate network access, or inspect local download availability.
- Force preferences override all codec/container checks. `forceAVPlayer` can
  intentionally choose an engine that later fails on unsupported media.

## PlaybackEngine Contract
- `PlaybackEngine` is `@MainActor` and implementations are `@Observable`.
- Required lifecycle: `load(source:)`, `play`, `pause`, `stop`, `seek`,
  `recoverFromStall`, and `handleReturnToForeground`.
- Required state: `state`, `currentTime`, `duration`, `isBuffering`, `error`,
  audio/subtitle track arrays, and selected track IDs.
- `onPlaybackEnded` is owned by the coordinator. Engines call it once for a
  natural end; the coordinator clears it before teardown.
- `makePlayerView()` returns the rendering view. Player UI must not reach into
  engine internals.
- `load(source:)` should reset per-attempt state, validate direct play, honor
  `source.startPosition`, and begin playback when ready.
- `stop()` should release observers/media and leave a reusable stopped state.
- Track IDs are engine-local. `PlayerViewModel` maps engine tracks to Plex
  stream metadata before presenting them.

## AVPlayer and VLCKit Split
- `AVPlayerEngine` is for MP4/MOV/M4V-style direct play with AV-compatible
  video, audio, and text subtitles. `VLCKitEngine` is the fallback for MKV,
  DTS/TrueHD audio, bitmap/complex subtitles, and other VLC-only combinations.
- Current AV-compatible sets live in `StreamResolver`: containers
  `mp4`, `mov`, `m4v`; video `h264`, `hevc`, `av1`; audio `aac`, `ac3`,
  `eac3`, `alac`, `mp3`, `flac`; subtitles `tx3g`, `mov_text`, `srt`,
  `subrip`, `vtt`, `webvtt`.
- AVPlayer uses `AVPlayerLayer`, KVO, media-selection groups, and text style
  rules. VLCKit uses `VLCMediaPlayer`, delegate callbacks, track APIs, media
  options, and renderer hosts split by platform.
- Both engines perform preflight direct-play validation via
  `PlaybackError.validateDirectPlayURL`.
- Both engines implement stall recovery by reloading/restarting near the
  observed position. Keep recovery behavior engine-specific.
- iOS VLCKit has extra PiP/drawable and video-output refresh behavior; tvOS
  uses a simpler drawable host.
- Subtitle sizing is centralized in `PlaybackSubtitleStyle`; avoid separate
  magic numbers per engine unless there is a platform reason.

## PlayerViewModel and Overlays
- `PlayerView` is the full-screen shell. It reads coordinator state and creates
  a per-session `PlayerSessionView` keyed by `playerPresentationID`.
- `PlayerViewModel` is UI state only: syncs from engine every 0.25s, drives
  controls visibility, scrubbing, seek feedback, buffering presentation,
  auto-skip markers, stall recovery, and track selection.
- `PlayerViewModel.cleanup()` pauses the engine instead of stopping it so the
  coordinator can still read final time/duration before finalization.
- iOS uses touch overlays, sheets for audio/subtitle selection, and double-tap
  seek zones when enabled.
- tvOS uses focus-aware overlays, menus, remote seek handling, and explicit
  move-command routing.
- `PlayerControlsOverlay` chooses iOS vs tvOS controls; shared controls live in
  `PlayerControlsSharedViews.swift`.
- `PlayerDebugOverlayView` is gated by `playerDebugOverlayEnabled` and reads
  `PlaybackDebugInfo`; expose resolver/stream diagnostics there first.
- `PlayerSelectionSheet` is iOS-only presentation for track choices. tvOS uses
  menus in `PlayerControlsTVOverlay`.
- Marker skip buttons come from `PlexMarker.skipButtonTitle`; only intro and
  credits markers are actionable.

## Timeline, Scrobble, and Up Next
- `PlaybackCoordinator.startTimelineReporting` sends progress every 10 seconds.
- Timeline maps `.playing` and `.paused` to Plex; other states are ignored
  unless explicitly overridden.
- `flushTimelineForScenePhase` reports on inactive/background and asks engines
  to refresh rendering when the app becomes active.
- Finalization sends a stopped timeline, updates now-playing, stops the engine,
  and ends the now-playing session.
- Scrobble happens once when progress exceeds 90 percent of duration, either
  during periodic reporting or during finalization.
- Local-download playback does not call Plex directly. It records progress or
  watch state in `OfflinePlaybackSyncManager`, which syncs pending actions when
  the matching server is available.
- On natural episode end, the coordinator finalizes the current item as
  completed, resolves the next episode, and shows `PlayerUpNextOverlayView`.
- Credits auto-skip can resolve directly to Up Next. If no next episode can be
  presented, it falls back to seeking past the credits marker.
- Continuous play uses `continuousPlayEnabled`, `continuousPlayCountdown`, and
  optional passout protection. The episode run count includes the current item.
- `PlaybackNowPlayingController` is iOS-only and owns AVAudioSession,
  MPNowPlayingInfoCenter, remote commands, route/interruption handling, and art.

## Settings and Preferences
- Playback preferences live in `UserPreferences` and persist to UserDefaults.
- Session-start defaults: `maxResolution`, forced engines, subtitle defaults,
  and default audio language.
- Active UI defaults: auto-skip, double-tap seek, continuous play, and debug
  overlay.
- `forceAVPlayer` and `forceVLCKit` are mutually exclusive in their setters.
- Settings UI is split by platform; shared labels/options live in
  `SettingsSupport`.
- Adding a playback preference usually requires edits in `UserPreferences`,
  both settings views, and the consumer in `PlaybackCoordinator` or
  `PlayerViewModel`.

## Where to Edit
- Engine choice: `Playback/StreamResolver.swift`.
- Engine contract: `Playback/PlaybackEngine.swift`, both engines,
  `PlayerViewModel`.
- Concrete playback: `AVPlayerEngine.swift`, `VLCKitEngine.swift`, and the
  platform `VLCKitRenderer*.swift` files.
- Plex playback calls: `PlexService+Playback.swift`; metadata shape/fetching:
  `PlexService+Library.swift` and `PlexMediaDetails.swift`.
- Session orchestration: `PlaybackCoordinator+Session.swift`; timeline:
  `PlaybackCoordinator+Timeline.swift`; Up Next: `PlaybackCoordinator+UpNext.swift`.
- Player UI: `Features/Player/`; keep platform differences in platform overlays.
- Preferences: `UserPreferences.swift`, `SettingsSupport.swift`,
  `SettingsIOSView.swift`, and `SettingsTVView.swift`.

## Pitfalls
- Do not log raw playback URLs with tokens. Use sanitized URL strings.
- Do not stop the engine from `PlayerViewModel.cleanup()` before the
  coordinator snapshots the final timeline.
- Do not assume `details.media.first` is chosen; the coordinator may select
  another version or a specific `mediaID`.
- Do not assume media parts have streams; tolerate empty stream arrays.
- Do not treat forced engine preferences as proof of playability.
- Do not duplicate track metadata logic in views; merge Plex stream metadata in
  `PlayerViewModel+TrackSelection`.
- Do not make views call Plex APIs directly.
- Source-file changes under `Dusk/Sources` require `xcodegen generate`; this
  doc-only file does not.

## Safe-Change Checklist
- Identify whether the change belongs to Plex service, resolver, engine,
  coordinator, view model, overlay, settings, or downloads/offline sync.
- Preserve `PlaybackEngine` unless the contract must change; then update both
  engines and call sites together.
- Keep AVPlayer/VLCKit user-visible state aligned, but keep renderer and
  recovery details engine-specific.
- Verify timeline finalization still reports stopped state and still scrobbles
  only once after 90 percent progress.
- Check local-download behavior when touching resume, timeline, scrobble, or Up Next.
- Check both iOS and tvOS presentation paths for control or settings changes.
- For code changes, run the repo's compile-only `xcodebuild` command from
  `AGENTS.md`. Do not run tests or launch the app unless explicitly asked.
