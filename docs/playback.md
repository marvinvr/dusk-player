# Playback System
Operational notes for changing Dusk playback without crossing layer boundaries.

## Boundaries
- `PlexService/` owns Plex endpoints, direct-play/transcode URL construction,
  timeline, scrobble, and watch-state calls.
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
   when playable, otherwise from `plexService.getMediaDetails(checkFiles: true)`
   so each part carries accurate `accessible`/`exists` flags.
3. The coordinator chooses a `PlexMedia` version, then its first *available*
   part (`PlexMedia.firstAvailablePart`).
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

## Manual Transcoding
- Playback never starts with video transcoding because of a stored quality
  preference. `maxResolution` only chooses among existing Plex media versions.
- The player gear menu exposes Quality on iOS and tvOS. `Original` means the
  current media version direct-plays; non-original presets manually request
  Plex HLS transcoding. Transcode choices are filtered against the active
  original media version so the menu only offers presets below its resolution
  and bitrate.
- `PlaybackCoordinator.switchQuality(to:)` snapshots the current engine time,
  asks `PlexService.transcodeURL(...)` for `/video/:/transcode/universal/decision`
  and `/video/:/transcode/universal/start.m3u8`, swaps the engine/source, and
  resumes from the same position without finalizing or scrobbling the session.
- Transcoded playback uses AVPlayer by default because the server emits HLS.
  `forceVLCKit` still forces VLCKit for debugging. Dusk currently advertises
  H.264/AAC for manual Plex HLS transcodes; direct-play HEVC remains supported,
  but HEVC HLS transcoding is not advertised until the app can request a proven
  Apple-compatible package.
- Video Enhancement is disabled for manual HLS transcodes so AVPlayer's native
  renderer remains the rendering path while the server owns the video pipeline.
- Completed downloads do not expose quality switching because offline playback
  must stay local and cannot ask Plex to transcode.
- Transcode failures keep the existing stream running and show an in-player
  message; they must not silently change to another quality.

## StreamResolver and Media Version Choice
- `StreamResolver.selectMediaVersion` filters out media versions with no
  parts, then prefers versions Plex still reports as present (`hasAvailablePart`,
  backed by per-part `accessible`/`exists`). This avoids picking a stale version
  Plex keeps after a file is deleted and re-added, which would 404 on direct play
  and surface as "not available". It falls back to all candidates when nothing is
  explicitly flagged available. With multiple candidates it targets
  `preferences.maxResolution`.
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
- `configureVideoEnhancement(_:)` is called before `makePlayerView()` for each
  session. Engines expose `videoEnhancementStatus` so the UI can report whether
  Metal enhancement is active, idle, disabled, or unavailable.
- `load(source:)` should reset per-attempt state, validate playback URLs, honor
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
- Automatic audio selection keeps the user's preferred language, then ranks
  tracks by Plex selected/default metadata, channel count, codec desirability,
  and non-commentary/non-descriptive titles. This prevents a matching-language
  commentary or stereo downmix from beating a theatrical 5.1/7.1/Atmos-style
  track.
- VLCKit keeps encoded passthrough off, but automatically nudges the output mix
  mode to 5.1 or 7.1 for matching selected audio tracks when the OS route can
  accept it. The mix mode is clamped to the active route's channel capacity:
  requesting 7.1 on a stereo route (iPhone speaker / stereo headphones) makes
  VLCKit stall audio a few seconds into playback while video continues, most
  visibly on TrueHD/Atmos tracks that default to 7.1, so a route that cannot
  render the surround layout steps down to the largest layout it can, then to a
  stereo downmix. Playback Info exposes the selected VLC audio track, mix mode,
  passthrough state, route, and channel counts for debugging route differences.
- On iOS, automatic audio selection also steers off codecs VLCKit cannot decode
  reliably onto a compatible companion track. VLCKit's software TrueHD/MLP path
  (the lossless bed under Atmos on BluRay remuxes) starves the audio output
  under load, so playback cuts in and out while video keeps going; clamping the
  mix mode does not fix it because the fault is the decode, not the route. Such
  remuxes almost always ship a lossy AC3/E-AC3 companion that VLCKit renders
  cleanly, and since passthrough stays off the surround mix is downmixed locally
  anyway, so the companion is sonically equivalent on a phone.
  `PlayerViewModel+TrackSelection` penalizes TrueHD/MLP in `audioSelectionScore`
  and `enforceReliableAudioTrackIfNeeded` switches to the best companion on every
  engine sync (so a late-arriving track is still honored). It never overrides an
  explicit user choice and leaves the track in place when it is the only one.
  tvOS is excluded; it has not shown the issue and is often wired to receivers
  that want the surround track.
- Video Enhancement is engine-owned and both engines must expose aligned status
  through `videoEnhancementStatus`; see the dedicated section below.
- Both engines perform preflight direct-play validation via
  `PlaybackError.validateDirectPlayURL`.
- Buffering defaults are centralized in `PlaybackBufferPolicy`: AVPlayer targets
  20 seconds of forward buffer, while VLCKit uses 8,000 ms for network and file
  caching. Dusk does not configure an explicit back-buffer size.
- Both engines implement stall recovery by reloading/restarting near the
  observed position. Keep recovery behavior engine-specific.
- iOS VLCKit has extra PiP/drawable and video-output refresh behavior; tvOS
  uses a simpler drawable host.
- Subtitle sizing is centralized in `PlaybackSubtitleStyle`; avoid separate
  magic numbers per engine unless there is a platform reason.

## Video Enhancement
- Video Enhancement is a local rendering preference, not a Plex playback-mode
  decision. `videoEnhancementMode` persists in `UserPreferences`; the
  coordinator creates a `VideoEnhancementRequest` from the selected Plex media
  part before `makePlayerView()` and before engine `load(source:)`.
- The feature must never request Plex transcoding, alter startup quality, or
  replace the direct-play-first rule. Manual Quality remains the only user path
  into Plex transcoding.
- Modes are `automatic`, `enabled`, and `disabled`. `automatic` skips HDR,
  skips streams above 50 fps, and skips sources that already match the output
  closely. `enabled` still hard-disables streams above 70 fps so high-frame-rate
  playback does not overload the renderer. `disabled` leaves the native engine
  view path in place.
- AVPlayer attaches an `AVPlayerItemVideoOutput` and, from a display link,
  pulls the time-current pixel buffer (`itemTime(forHostTime:)` +
  `hasNewPixelBuffer`) into `VideoEnhancementRenderer.submit`. This path paces
  itself by time, so it drops to the current frame under load. VLCKit installs
  raw libvlc callbacks through `DuskVLCRawVideoOutput`, retains `CVPixelBuffer`
  frames, and pushes them through the Objective-C frame-consumer bridge into
  `VideoEnhancementRenderer.enqueue`. Keep both paths aligned when changing
  frame ownership, channel layout, or teardown.
- The push path (`enqueue`) must coalesce to the most recent frame and keep a
  single in-flight main-actor render. libvlc emits one display callback per
  decoded frame against its audio clock; rendering every one in order on a GPU
  that cannot sustain the source frame rate (notably 4K upscales on Apple TV)
  builds an unbounded backlog that plays the video back in slow motion and drifts
  it out of sync with audio. Dropping intermediate frames keeps the picture
  aligned with the audio clock instead. Do not reintroduce a per-frame task hop.
- `VideoEnhancementRenderer` owns the Metal view, texture cache, coalescing
  frame inbox, and shader pass. The shader currently uses separable Lanczos
  sampling for upscaling and adaptive sharpening. Runtime failures such as
  texture-cache or command-buffer creation should turn into an `.unavailable`
  status instead of crashing.
- All GPU work runs on a dedicated serial `renderQueue`, never the main thread,
  so the player's periodic main-thread work (time sync, SwiftUI diffing, HUD)
  cannot stall frames and a blocking `nextDrawable()` paces rendering without
  freezing the UI. Both producers funnel through `enqueue`; only `makeView`,
  `clear`, and the layout-driven `renderCurrentFrame` are called on the main
  actor. Render-queue-owned state is `nonisolated(unsafe)` and touched only on
  that queue; `status` is published back through a lock. Output size is taken
  from the drawable's texture, not the layer, to avoid a cross-thread read.
- Adaptive quality keeps playback smooth on GPU-bound hardware (4K Apple TV).
  Dropped frames on the push path are the load signal: a burst of drops steps
  the shader down (Lanczos -> bilinear -> bilinear without sharpening) so every
  frame is still drawn, and several fully clean windows step it back up. Probing
  backs off when an upgrade immediately fails, so heavy content settles instead
  of oscillating. The active tier shows up in the `Enhancement` reason
  (`Adaptive: bilinear ...`). Tunables live next to `performanceLevel`; dropping
  frames is the floor only when even bilinear cannot keep up.
- Playback Info is the user-visible diagnostic surface. It should show
  `Enhancement` as a state (`Off`, `Idle`, `Active`, `Unavailable`) and
  `Enhancement Detail` with the input/output size plus the technical reason
  (`Metal Lanczos + adaptive sharpening`, `Auto skips HDR`, texture failure,
  and similar). Keep these rows useful for both AVPlayer and VLCKit debugging.
- When changing this path, verify compile-only builds for iOS and tvOS, then
  manually check one AVPlayer stream, one VLCKit stream, the Off setting,
  Auto on a lower-resolution SDR stream, and player dismissal/teardown on
  device.

## PlayerViewModel and Overlays
- `PlayerView` is the full-screen shell. It reads coordinator state and creates
  a per-session `PlayerSessionView` keyed by `playerPresentationID`.
- `PlayerViewModel` is UI state only: syncs from engine every 0.25s, drives
  controls visibility, scrubbing, seek feedback, buffering presentation,
  auto-skip markers, stall recovery, and track selection.
- `PlayerSessionView` loads Plex scrub-preview BIF data for online playback
  parts when available. iOS shows a thumbnail popup while dragging the seek
  bar; tvOS keeps a separate preview cursor while swiping the focused seek
  point. The thumb and thumbnail move during the swipe, but the filled progress
  bar, time readout, and video position keep tracking actual playback until
  select commits the preview position and resumes playback. Holding left/right
  on the focused seek point repeats preview jumps after a short delay. If BIF
  loading or parsing fails, the controls keep their existing no-preview behavior.
- Intro auto-skip honors `AutoSkipIntroMode`: off, always, or always except
  episode 1 of a season. The episode check comes from the active
  `PlexMediaDetails.index`, so missing episode numbers are treated as not the
  first episode.
- Playback controls start visible for orientation, then `PlayerViewModel`
  owns one auto-hide deadline/task for the whole session. Sync arms it once
  playback has started, every user reveal resets it, and it keeps retrying
  while temporary blockers such as scrubbing or selection sheets are active.
- `PlayerViewModel.cleanup()` pauses the engine instead of stopping it so the
  coordinator can still read final time/duration before finalization.
- iOS uses touch overlays, a gear menu for playback info, quality, and track
  selection, sheets for quality/audio/subtitle choices, and double-tap seek
  zones when enabled.
- The iOS/iPadOS controls expose a round zoom button at the top-right that
  toggles `PlayerViewModel.aspectFillEnabled` and calls
  `PlaybackEngine.setVideoFillEnabled(_:)`. Fill zooms the picture to cover the
  drawable (cropping the overflow) instead of letterboxing it; it is
  session-scoped and starts off. Each rendering path applies it natively:
  AVPlayer flips `AVPlayerLayer.videoGravity`, VLCKit sets a crop ratio matching
  the drawable's aspect ratio (re-applied on layout so rotation stays correct),
  and the Video Enhancement Metal renderer switches its viewport from aspect-fit
  to aspect-fill. tvOS does not expose the control.
- tvOS uses focus-aware overlays, a gear menu for playback info and track
  selection, quality menus, remote seek handling, touch-surface tap reveal/hide,
  and explicit move-command routing.
- tvOS focus moves, settings-menu presentation callbacks, and menu selections
  refresh the same auto-hide deadline as a reveal. Do not use tvOS `Menu`
  appear/disappear callbacks as hard HUD holds; SwiftUI can emit those lifecycle
  events outside a real open-menu interval, which would otherwise leave the HUD
  stuck visible.
- The tvOS full-screen interaction layer is focusable only while controls are
  hidden. When controls reappear, focus is restored to the seek point so remote
  input does not get stranded on the background reveal layer.
- The first seek-point select immediately after a hidden-to-visible reveal is
  ignored; this prevents the same remote press that revealed the HUD from also
  activating the focused play bar and pausing playback.
- Controls auto-hide again only while playback is playing; paused playback may
  keep controls visible until the user hides them manually.
- The player disables the system idle timer while a session is actively loading,
  playing, or buffering, then restores the previous value on pause, stop, error,
  or dismissal. This is required because Video Enhancement can render through a
  Metal view instead of the native AVPlayer/VLCKit video surface.
- `PlayerControlsOverlay` chooses iOS vs tvOS controls; shared controls live in
  `PlayerControlsSharedViews.swift`.
- `PlayerPlaybackInfoView` presents `PlaybackDebugInfo` from the player gear
  menu; tvOS uses a custom full-screen diagnostic panel instead of the stock
  sheet/list presentation so long technical values stay readable. Its rows are
  focusable so remote up/down navigation scrolls the panel, and the back/menu
  command dismisses it. Expose resolver, stream, engine, and enhancement
  diagnostics there first.
- `PlayerSelectionSheet` is iOS-only presentation for track choices. tvOS uses
  menus under the shared gear menu.
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
- Session-start defaults: `maxResolution`, `videoEnhancementMode`, forced
  engines, subtitle defaults, and default audio language.
- Active UI defaults: intro auto-skip mode, credits auto-skip, double-tap seek,
  and continuous play.
- New installs default intro auto-skip to always except episode 1 of each
  season; existing stored intro-skip preferences are preserved.
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
- Video enhancement: `Playback/VideoEnhancement*.swift`,
  `Playback/VideoEnhancementShaders.metal`, and
  `Playback/DuskVLCRawVideoOutput.*`.
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
