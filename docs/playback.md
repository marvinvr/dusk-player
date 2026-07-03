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
  stream metadata before presenting them. VLCKit 4 identifies player tracks by a
  stable string `trackId`; the inherited int `identifier` is NOT a reliable
  selector, so `VLCKitEngine` mints a stable Int model id per `trackId` and
  matches on `trackId` for selection. Matching on the int `identifier` silently
  selected the wrong track, so switching audio/subtitle never took effect.
- Engine tracks carry `isDecodable`. The bundled VLCKit build cannot decode
  every codec a container may hold (see "Undecodable audio tracks" below).
  Automatic selection only considers decodable tracks; the pickers list all of
  them, and picking an undecodable one reroutes through
  `PlaybackCoordinator.transcodeForUndecodableAudio` (server transcode pinned
  to that stream) instead of silencing playback.
- Picture in Picture is optional, observable engine state: `isPictureInPicturePossible`,
  `isPictureInPictureActive`, `start/stopPictureInPicture()`, and
  `setPictureInPictureDelegate(_:)`. The protocol extension defaults everything
  to off, so tvOS engines get a safe no-op. Video Enhancement no longer disables
  PiP — each engine keeps a native surface alive for the floating window (see
  the Picture in Picture section). See the Picture in Picture section.

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
- Automatic audio selection keeps the user's preferred language (with no
  language preference configured it re-ranks only within the default track's
  language), then ranks tracks by Plex selected/default metadata, channel
  count, codec desirability, and non-commentary/non-descriptive titles. This
  prevents a matching-language commentary or stereo downmix from beating a
  theatrical 5.1/7.1/Atmos-style track.
- Codec desirability is platform-aware (`platformAudioCodecAdjustment`): on
  tvOS lossless bitstreams (TrueHD/MLP, DTS-HD, PCM) rank top — they decode
  to multichannel LPCM over HDMI — while iPhone/iPad demote them below lossy
  surround (E-AC-3/AC-3/DTS), because the phone outputs a stereo/binaural
  downmix either way and lossless only costs decode CPU, battery, and
  streaming bandwidth. Ranking is relative, so a lossless-only file still
  plays natively, and the pickers can always select any track manually.
- Selection only considers `selectableAudioTracks` (decodable tracks): ranking
  by desirability used to steer playback onto a TrueHD track the bundled
  VLCKit cannot decode, which is what actually broke Bluray-remux audio.
- The automatically preferred audio track is normally PRESELECTED before
  playback starts: `PlaybackCoordinator` computes it from Plex part metadata
  (`PlayerViewModel.preferredAudioStreamPosition`, the pre-start twin of the
  runtime policy sharing the same scorer), carries it in
  `PlaybackSource.preferredAudioTrackPosition`, and `VLCKitEngine` passes it
  as the `:audio-track=<position>` media option (0-based position among the
  audio ESes — verified against this libvlc build). libvlc then opens
  directly on the winning track: no post-start ES switch exists at all, the
  losing track's decoder is never created, and the audio output is brought
  up exactly once. Direct play / local downloads only — HLS transcodes
  rewrite the stream layout, so positions are not passed there.
- Why no-switch matters: switching the audio ES makes libvlc restart the
  audio output for the input format change (e.g. TrueHD 7.1 → AC-3 5.1);
  landing that restart inside the startup window (output bring-up,
  passthrough probing, session activation, resume-seek flush) can brick the
  stream on device — a failed `aout_OutputNew` sets
  `mixer_format.i_format = 0` in libvlc's `dec.c` and, in stock libvlc,
  nothing retries: video plays with no audio until a manual pause/resume
  forces another restart via the audiounit resume path. Since vlc-patch 0016
  the vendored build retries such failed restarts after 500 ms, so even this
  class self-heals — preselection still avoids provoking it at all.
- The runtime auto-selection remains as a safety net for preselect mapping
  misses. It is deferred until steady-state playback
  (`PlaybackEngine.isReadyForAutomaticAudioSelection`; VLCKit: playing, not
  buffering, start-position seek issued and settled, and ≥4 consecutive
  advancing time ticks — ~1 s at the 250 ms cadence; the counter resets on
  load/seek/pause/buffering so the gate cannot open mid-refill), and it is
  skipped entirely when the preferred track is already selected, which is
  the normal case with preselection in place. Steady-state switches use the
  same code path as manual picker changes, which are reliable. Verified in
  the C-API harness (throttled Range-HTTP + amem PCM tap + audiounit log
  tracing): ASAP switch interleaves the output restart with bring-up;
  `:audio-track` preselect yields a single bring-up with zero switches;
  post-settle switch restarts a live output with one ~30 ms flush.

### Undecodable audio tracks (TrueHD/MLP)
- The vendored frameworks are now built with the full `ci_scripts/vlc-patches/`
  series — 0013 (TrueHD/MLP), 0014 (Apple SDK build fix), 0015/0016 (audio
  silence-latch recovery, see below) —
  (`DUSK_EXTRA_VLC_PATCHES=1 ./ci_scripts/install_vlckit.sh`, VERSION
  `4.0.0a19+patched`), so TrueHD/MLP decode natively and
  `VLCKitEngine.undecodableAudioFourCCs` is empty. Everything below describes
  the stock-VLCKit situation and the safety net that stays in place for it.
- Stock VLCKit 4.0.0a19 disables ffmpeg's mlp decoder/demuxer/parser on iOS
  via its patch 0007 ("to be in compliance with the App Store ToS" — Dolby
  licensing; AC-3/E-AC-3 decode through Apple's licensed AudioToolbox
  instead), and ffmpeg's truehd decoder depends on the mlp parser. libvlc
  then logs ``Codec `mlpa' (TrueHD Audio) is not supported`` and cannot play
  such tracks.
- Failure chain this produced on Bluray remuxes (default track TrueHD, with a
  companion AC-3 track): libvlc auto-falls back to AC-3 at start; the app's
  auto-selection then re-selected the "better" TrueHD track; libvlc unselects
  the working AC-3 ES, the TrueHD decoder fails to open, and there is NO
  second fallback — audio goes silent until a pause/resume/seek/track event
  revives it, then dies again. That is the cyclic "audio cuts in and out,
  sometimes catches itself" symptom: route-independent, streamed or local,
  only on files whose preferred track is undecodable.
- Fix layers: `VLCKitEngine.undecodableAudioFourCCs` marks such tracks
  (`AudioTrack.isDecodable == false`); auto-selection skips them. The pickers
  still offer them: `PlayerViewModel.selectAudio` reroutes an undecodable pick
  through `transcodeAudioFallbackHandler` → `PlaybackCoordinator.
  transcodeForUndecodableAudio(_:)`, which restarts the session as a Plex HLS
  transcode pinned to that stream (`switchQuality(to:audioStreamID:)`), so the
  choice produces sound. A file with zero locally decodable audio tracks (a
  TrueHD-only remux) triggers the same fallback automatically instead of
  direct-playing as a silent video. To decode TrueHD natively, rebuild the
  frameworks with `DUSK_EXTRA_VLC_PATCHES=1 ./ci_scripts/install_vlckit.sh`
  (applies `ci_scripts/vlc-patches/`) and remove the corresponding fourccs
  from `undecodableAudioFourCCs` — a deliberate licensing/App Store decision,
  not a code default.

### VLCKit audio output module
- `VLCKitEngine` runs its players on a shared `VLCLibrary` with
  `--aout=audiounit_ios,any`, pinning libvlc 4's audio output to the classic
  AudioUnit module. libvlc 4's new default, `avsamplebuffer`
  (AVSampleBufferAudioRenderer, capability 100 vs 99), drives the master
  playback clock from a 1-second periodic observer of an
  AVSampleBufferRenderSynchronizer — a mechanism with documented iOS-specific
  drift that does not exist on macOS (so simulator runs cannot reproduce it),
  and mpv ships the equivalent output opt-in rather than default. When those
  timing reports lurch under device load, the aout core inserts silence or
  flushes buffers ("playback way too late/early"), audible as cyclic
  dropouts that pause/resume temporarily clears. A PCM-tap harness proved the
  demux→decode→delivery pipeline is gapless through seeks and pause/resume,
  isolating the output layer. Settings → Playback Advanced → "VLCKit
  AVSampleBuffer Audio" restores the libvlc default for on-device A/B testing
  (applies to the next playback session).
- VLCKit keeps encoded passthrough off. `configureAudioOutputPolicy` is split by
  platform because the routes are fundamentally different, and it is idempotent
  (a signature of the resolved config gates every player/session write) and
  observes only `routeChangeNotification` — never the spatial- or
  rendering-capability notifications.

### Audio silence latches (vlc-patches 0015/0016) and session ownership
- Stock libvlc's iOS AudioUnit output has three states in which it keeps
  accepting buffers and reporting success to the core while rendering pure
  silence, so no recovery machinery (decoder reload, output restart) ever
  engages — video plays on with dead audio, and a manual pause→play is the
  only cure because it happens to re-run session activation +
  `AudioOutputUnitStart` + the unlatch:
  1. Interruption latch — `AVAudioSessionInterruptionTypeBegan` silences the
     render callback (`ca_SetAliveState(false)`); iOS often omits
     `shouldResume` from the matching *ended* notification (Bluetooth
     handoffs/auto-switching), or never sends *ended* at all for
     was-suspended pseudo-interruptions, so the latch held forever.
  2. Resume fall-through — if `AVAudioSession` activation failed during
     unpause, `audiounit_ios.m` reported the stream resumed with the
     AudioUnit still stopped: the render callback never ran again.
  3. Unclamped start deferral — a pathological first-block date after a
     seek/flush deferred audible start arbitrarily far while silence rendered.
- vlc-patch 0015 fixes all three in the vendored build: was-suspended
  interruptions are ignored; interruption-ended always revives the output
  and requests a clean output restart; both resume-failure branches request
  an output restart instead of falling through; `Start()` retries session
  activation briefly (transient `!act`/busy errors are normal while a
  Bluetooth route settles); start deferrals are clamped at 2 s. vlc-patch
  0016 makes a failed output restart itself retry after 500 ms
  (`stream_CheckReady` re-enters the regular `AOUT_RESTART_OUTPUT` path)
  instead of muting the stream until the end of the input.
- Session ownership: the app (`PlaybackNowPlayingController`) is the single
  owner of the `AVAudioSession` category/mode/policy. Patched
  `avas_SetActive` no longer re-asserts `.moviePlayback` when a
  Playback-category session is already configured — previously the app
  (`.default` mode for VLCKit, the anti-spatialization choice) and VLC
  (`.moviePlayback`) flipped the mode on every output start/resume, and each
  flip forces a route re-evaluation that glitches Bluetooth routes and
  spawns exactly the spurious interruptions that trip latch 1 and 2.
  App-side, `beginSession` no longer deactivates the previous session before
  activating the new one (the deactivate→activate whiplash was another
  failure generator), session activation/deactivation failures log instead
  of asserting, and the interruption handler only pauses the engine when it
  was actually playing (never pokes a loading/buffering player mid-open).
- tvOS drives true multichannel output to the connected receiver over HDMI/eARC:
  it nudges the VLC mix mode to 5.1 or 7.1 for the selected track, clamped to the
  route's channel capacity (a route that cannot render the layout steps down to
  the largest it can, then to a stereo downmix), and opts the audio session into
  multichannel content. The surround helpers live under `#if os(tvOS)`.
- iOS/iPadOS does NOT drive surround at all. The output route is effectively
  stereo (built-in speaker, wired, or Bluetooth/AirPods), so the policy leaves the
  VLC mix mode unset and lets VLCKit downmix to the route on its own; it sets no
  preferred output channel count and does not touch multichannel session content
  (the AVAudioSession is owned by `PlaybackNowPlayingController`). Keeping this
  policy idempotent matters: every re-poke of the live player's audio settings
  (mix mode, passthrough, equalizer) restarts VLCKit's audio output, which is an
  audible gap. Historical note: the recurring "audio cuts in and out on this
  remux" bug was chased through several audio-session/mix-mode theories before
  the actual cause was found — the app steering playback onto an undecodable
  TrueHD track (see "Undecodable audio tracks" above). The idempotency and
  no-surround-on-iOS changes remain as valid hardening, but they were not the
  root cause. Playback Info still exposes the selected VLC audio track, mix
  mode, passthrough state, route, and channel counts.
- The AVAudioSession *mode* is engine-owned via `PlaybackEngine.prefersSpatializedAudioSession`
  (iOS, read by `PlaybackNowPlayingController`). AVPlayer keeps `.moviePlayback`,
  which lets iOS spatialize audio for AirPods and which AVPlayer feeds natively.
  VLCKit returns `false`: its raw audio output does not feed that spatializer
  cleanly, so on a Bluetooth route the audio kept underrunning and stuttering
  (worse with AirPods spatial audio; a pause/resume reset it until the next
  underrun). VLCKit therefore gets a plain `.default` session with no multichannel
  content and a slightly larger preferred IO buffer for slack against the jittery
  Bluetooth clock. This is separate from `configureAudioOutputPolicy` above, which
  governs the VLC player's own mix, not the session's signal processing.
- Video Enhancement is engine-owned and both engines must expose aligned status
  through `videoEnhancementStatus`; see the dedicated section below.
- Both engines perform preflight direct-play validation via
  `PlaybackError.validateDirectPlayURL`.
- Buffering defaults are centralized in `PlaybackBufferPolicy`: AVPlayer targets
  20 seconds of forward buffer, while VLCKit uses 8,000 ms for network and file
  caching. Dusk does not configure an explicit back-buffer size.
- Both engines implement stall recovery by reloading/restarting near the
  observed position. Keep recovery behavior engine-specific.
- iOS VLCKit has extra drawable and video-output refresh behavior and hosts the
  native PiP pipeline (see Picture in Picture); tvOS uses a simpler drawable host.
- Subtitle sizing is centralized in `PlaybackSubtitleStyle`; avoid separate
  magic numbers per engine unless there is a platform reason.

## Picture in Picture
- iOS only, both engines, native. AVPlayer uses an `AVPictureInPictureController`
  built from the `AVPlayerLayer`. VLCKit uses VLCKit 4.x's
  `VLCPictureInPictureDrawable`/`...WindowControlling`, which wraps a native
  `AVPictureInPictureController` behind the drawable — the Apple-sanctioned path,
  not the old non-native hack. tvOS uses the protocol no-op defaults.
- Prerequisites already in place: the audio session is
  `.playback`/`.moviePlayback`/`.longFormVideo` (`DuskApp`) and `UIBackgroundModes`
  includes `audio` (`Info-iOS.plist`). PiP will not run without both.
- Availability: `isPictureInPicturePossible` is false until the system controller
  is ready. It is **also available with Video Enhancement on** — the upscaled
  picture stays full-screen while PiP projects the non-upscaled source stream
  (all PiP needs). The player's round top-right PiP button
  (`PlayerControlsIOSOverlay`) only shows when possible and toggles via
  `PlayerViewModel.togglePictureInPicture()`.
- Enhanced-mode PiP (the part that makes the above work): the Metal upscaler
  takes over the full-screen surface, so each engine keeps a *separate* native
  layer alive behind it, occluded, purely to feed PiP.
  - AVPlayer keeps its real `AVPlayerLayer` mounted behind the Metal view
    (`makePlayerView()` returns a `ZStack`); the same native
    `AVPictureInPictureController` projects from it, no other change.
  - VLCKit cannot: libvlc has one video output, and enhancement claims it via
    raw callbacks, so the drawable-backed PiP host is detached. Instead
    `VLCKitEnhancedPictureInPictureOutput` tees the same decoded frames into an
    `AVSampleBufferDisplayLayer` and drives a sample-buffer
    `AVPictureInPictureController`. The frames are RGBA-in-BGRA (see Video
    Enhancement), so it channel-swaps each frame to true BGRA (vImage) before
    display, coalescing to the latest frame on a serial queue like the Metal
    renderer. A `CMTimebase` synced from the engine drives the PiP scrubber.
    The display layer is mounted (occluded) behind the Metal view for the same
    "keep a native surface on screen" reason.
- Lifecycle (the subtle part): starting PiP drops the full-screen cover
  (`showPlayer = false`) so the floating window is unobstructed. The engine must
  outlive that dismissal — `PlaybackCoordinator.onPlayerDismissed` and
  `PlayerViewModel.cleanup` both skip teardown while `isPictureInPictureActive`,
  and `startPlaybackIfNeeded` skips the reload (`engine.state == .idle` guard) so
  returning re-presents the player over the live engine instead of restarting.
- Restore vs. close is handled in `PlaybackCoordinator+PictureInPicture`. AVPlayer
  distinguishes them via its delegate: the restore button re-presents the player
  (completion fired from `notePlayerUIDidAppear`), the close button finalizes the
  session. VLCKit's *drawable* binding only reports start/stop, so it always
  re-presents the player on stop (non-destructive — playback is never silently
  lost). The enhanced-mode sample-buffer output owns a real
  `AVPictureInPictureControllerDelegate`, so it *does* get the proper
  restore-vs-close callbacks and behaves like AVPlayer.

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
- Engaging the playback settings menu refreshes the auto-hide deadline with a
  longer window than a normal tap (`settingsControlsAutoHideDelay`, double the
  base delay) via `PlayerViewModel.noteSettingsMenuInteraction()`, so the HUD
  does not hide while the menu is open. iOS detects the gear's opening tap with
  a `simultaneousGesture` (a native `Menu` exposes no presentation callback);
  tvOS routes its settings-menu presentation callbacks to the same refresh.
- tvOS focus moves and menu selections refresh the auto-hide deadline as a
  reveal. Do not use tvOS `Menu` appear/disappear callbacks as hard HUD holds;
  SwiftUI can emit those lifecycle events outside a real open-menu interval,
  which would otherwise leave the HUD stuck visible. The settings refresh guards
  on `showControls` and never reveals the HUD on its own for the same reason.
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
