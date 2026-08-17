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
   `play`, `playFromStart`, or `playVersion`, passing a `PlaybackPlaceholder`
   (the title/poster art paths the caller already holds). The coordinator
   also receives the initiating model's `viewOffset` as a resume fallback:
   freshly fetched item details remain authoritative when they contain a
   positive offset, but a hub/list offset is preserved when that detail
   response omits one or reports zero. `playFromStart` always overrides both
   with zero. The coordinator
   presents the player cover IMMEDIATELY on `PlayerLoadingView` (poster + title +
   spinner) via `enterLoadingState`, stamps a `currentPlaybackAttemptID`, and
   then loads in the background — pressing Play feels instant instead of blocking
   on the metadata round-trip. The loading state is cancellable (iOS close
   button, tvOS Menu → `dismissFailedPlayback`), which supersedes the in-flight
   attempt so a slow/hung load never pins the user on a spinner.
2. `startPlaybackSession` gets `PlexMediaDetails` from completed-download cache
   when playable, otherwise from `plexService.getMediaDetails(checkFiles: true)`
   so each part carries accurate `accessible`/`exists` flags.
3. The coordinator chooses a `PlexMedia` version, then its first *available*
   part (`PlexMedia.firstAvailablePart`).
4. If a matching completed download exists, playback uses the local file URL.
   Otherwise `PlexService.directPlayURL(for:)` builds `{serverBaseURL}{part.key}`
   and adds `X-Plex-Token` when available.
5. `StreamResolver.evaluate` records the intended engine, a human-readable
   reason, and `requiresServerTranscode` (media neither engine can render
   correctly, e.g. Dolby Vision profile 5). Flagged online media skips direct
   play and starts on the server-stream rung (see "Delivery Ladder").
   `PlaybackEngineFactory.makeEngine` returns an AVPlayer or VLCKit engine,
   reusing a warmed engine when available.
6. The coordinator creates `PlaybackSource`, `PlaybackAttemptContext`, and
   `PlaybackDebugInfo`, starts now-playing/timeline work, and commits the engine
   under the already-visible cover (it no longer presents the cover itself).
   Every `await` in `startPlaybackSession` is followed by a
   `currentPlaybackAttemptID` guard, so a dismissal or a newer Play supersedes a
   slow load instead of committing over it — a transcode session started for the
   superseded attempt is stopped. A pre-engine failure sets `loadError`, which
   `PlayerView` surfaces as a "Couldn't Play" alert (only while no engine is
   live) whose dismissal tears down the cover. A `.unauthorized` load error or
   in-session `PlaybackError.unauthorized` offers Sign In instead of OK/Close;
   that signs out and returns to `SignInView` instead of retrying with a dead
   token.
7. `PlayerSessionView` creates `PlayerViewModel`, configures preferences and
   markers, then calls `engine.load(source:)` once.
8. The engine validates the URL, loads media, auto-plays, and publishes
   state/time/tracks through the `PlaybackEngine` contract.
9. For online direct-play sessions the coordinator arms a one-shot failure
   watch; an engine error swaps the session onto a Plex server stream at the
   same position instead of dead-ending (see "Delivery Ladder").

## Live TV Play Flow

- `PlaybackCoordinator.playLiveTV` presents the same cancellable loading cover
  and asks `PlexService.tuneLiveTV` for a DVR session. The tuned session path
  goes through Plex's universal HLS endpoint with direct stream enabled; it is
  not validated as a library file. `StreamResolver.evaluateLiveTV` ignores the
  source-file container because Plex already packaged HLS, while retaining
  codec and force-engine rules.
- `PlaybackSource.liveTVContext` carries the lineup, channel/program, and
  session ID into the player. The header and gear menu use it for identity and
  channel switching by finalizing and re-tuning. The loading cover leads with a
  centered channel-logo tile (`PlaybackPlaceholder.Artwork.liveChannel`), not a
  poster frame: program art is frequently absent on live lineups, and the
  channel logo is the one image that is reliably there.
- AVPlayer publishes `seekableTimeRanges` as
  `PlaybackEngine.seekableTimeRange`. Gestures, iOS scrubbing, tvOS scrubbing,
  remote commands, and Go Live clamp to that range, so seeking cannot move into
  the future. Pause/rewind reach only as far back as Plex retains the tuned
  session's sliding window.
- Live playback disables 2× hold, manual Quality, scrub thumbnails, markers,
  Up Next, completion scrobbling, and offline progress. Now Playing marks the
  item live. Timeline reports use `/livetv/sessions/{sessionID}` as their key
  and still send stopped so Plex can release the consumer.

## Live TV Timeline

`PlayerLiveTimeline.swift` owns everything the live play bar shows.
`PlayerViewModel.sync()` rebuilds a `LiveTimelineSnapshot` on each 0.25 s tick,
so the whole live HUD is derived from one instant.

- **Never derive the live edge from `seekableTimeRange`.** Its upper bound is
  the newest segment the playlist advertises, which sits a play-out buffer
  *ahead* of what any player is rendering, and it only moves when a segment
  lands. Both readings of it failed in turn: taking the fraction from the whole
  range made the bar jump as the window slid, and folding the upper bound into
  the edge estimate pinned it a segment or two in front of the playhead and left
  a standing "−0:10" flickering across the LIVE threshold. Seeking still clamps
  to that range; only the edge estimate ignores it.
- `LiveEdgeClock` anchors to the **playhead** and projects it forward in real
  time — a live stream produces one second of content per second of wall clock.
  It ratchets up when the playhead overtakes the projection (startup, Go Live, a
  catch-up skip), and while playback is running it collapses any residual under
  `liveEdgeTolerance`, so buffering hiccups too small to report cannot
  accumulate into a permanent drift off LIVE. A real pause or rewind is larger
  than the tolerance and survives untouched. Feed it `engine.currentTime`, never
  `PlayerViewModel.currentTime`: that one freezes at the scrub preview while
  dragging, which the clock would read as falling behind live.
- The snapshot pairs `anchorPosition` (engine clock) with `anchorDate` (wall
  clock), which is what lets positions and broadcast times convert both ways.
  `secondsBehindLive` below `LiveTimelineSnapshot.liveEdgeTolerance` reads LIVE.
- The bar spans the **scheduled program the playhead is inside**, taken from the
  tuned channel's guide, but its left edge is clipped to the oldest instant the
  session can still reach. A tuner only starts buffering when the channel is
  tuned, so the part of the program before that is unreachable on any client and
  drawing it only gives the bar a dead zone. Clipped this way every point left
  of the playhead is seekable and the bar behaves like an ordinary one; the left
  edge slides back toward the program's start as the session buffers. With no
  guide coverage the window is the rewindable session itself, floored at
  `fallbackWindowSpan`. `timelineRange` returns the window mapped onto the engine
  clock, so the shared seek-bar, scrubbing, and tvOS cursor code keeps working in
  playback positions, and seeks stay clamped to `seekableRange`.
- The header leads with the **series** (`PlexLiveProgram.primaryDisplayTitle`),
  with the episode below it and the channel name as the subtitle. Guides put the
  episode name in `title` and the series in `grandparentTitle`, so leading with
  `displayTitle` showed an episode name that rarely says what is on.
- `PlaybackCoordinator` refreshes the tuned channel's schedule for the length of
  the session (`liveTVScheduleRefreshTask`) and republishes
  `activeLiveTVContext`; `PlayerSessionView` forwards it into the view model.
  The lineup a caller passes in is a snapshot — the home shelf carries only
  what was airing when it loaded — so without this the bar and header would
  still describe a finished program. Programs roll over from the local schedule
  on the next sync; the network fetch only runs when the held schedule stops
  covering the next hour (and pulls the next day in at the date boundary).

## Delivery Ladder and Session Hygiene

- The ladder is: direct play → server stream (HLS with `directStream=1`,
  video copied without re-encoding when the profile allows) → error surface.
  It never triggers for local downloads or sessions already on a server
  stream/transcode, and it must not change the direct-play-first startup rule:
  the server rung is entered only on resolver `requiresServerTranscode` or an
  actual direct-play failure.
- `PlexService.serverStreamURL` drives the fallback rung via
  `TranscodeDeliveryMode.directStreamFallback` (no bitrate caps, `directPlay=0`,
  `directStream=1`, `directStreamAudio=1`); manual Quality keeps
  `.manualTranscode` semantics (forced re-encode at the chosen bitrate).
- The coordinator's failure watch (`directPlayFallbackWatchTask`, ~500 ms
  cadence, one-shot per session) detects `engine.state == .error`, snapshots
  the position, and swaps engine/source through the same helper `switchQuality`
  uses. The snapshot also retains `PlaybackSource.startPosition`: a forced
  engine can fail before its clock advances or the first timeline tick, and the
  replacement must still inherit Plex's saved resume offset. Automatic recovery
  is silent: the failed direct-play engine's transient error overlay stays
  hidden while Plex prepares the replacement stream, while the loading
  presentation and player controls remain visible across the handoff.
  `PlaybackCoordinator.playerLoadingState` is the single presentation state for
  preparation, startup, delayed mid-play buffering, and automatic recovery.
  `PlayerView` owns its only spinner above the replaceable player-session
  identity, so loading phases cannot stack indicators and its native animation
  phase does not restart when the engine swaps. A failed fallback reveals the
  normal error overlay. The mid-play buffering leg
  (`PlayerViewModel.updateBufferingPresentation`, 2 s debounce) never fires
  while the session is `.paused`: `isBuffering` survives a pause on AVPlayer
  (pausing out of `waitingToPlayAtSpecifiedRate` leaves the flag set), and the
  iOS controls hide the play/pause button while the spinner is up, so a user
  who pauses a stalling stream would otherwise be left with no way to resume.
- Transcode/server-stream sessions are now closed on the server:
  `stopTranscodeSession` fires on finalize, on quality switches (only after
  the replacement decision succeeded), and when a fallback replaces a
  transcode; `pingTranscodeSession` keeps active sessions alive every ~60 s
  from the timeline timer.
- Transcode/decision URLs identify the client honestly
  (`X-Plex-Platform` iOS/tvOS, `X-Plex-Device`, `X-Plex-Platform-Version`);
  the capability constraints stay in `X-Plex-Client-Profile-Extra`.
- That profile declares E-AC-3 and AC-3 as additional HLS transcode-target
  audio codecs with a 6-channel limitation. With only the Generic profile's
  lone AAC target, Plex downmixed every 5.1/7.1 source to 2-channel AAC on the
  server-side rungs — which is what the direct-stream fallback and every
  TrueHD title (undecodable in the vendored VLCKit, so always routed through
  the server) received. AVPlayer decodes AC-3/E-AC-3 in HLS/mpegts natively on
  both platforms. `.airPlay` is deliberately excluded: that rung targets
  whatever receiver the user picked, which is not necessarily AC-3 capable.
  There is deliberately no `aac` channel limitation — capping it would fight
  Plex's decision engine rather than widening what Dusk accepts.

## AirPlay (iOS/iPadOS)

- Dusk is the AirPlay sender and remains the playback coordinator/remote. The
  receiver needs AirPlay support but never needs Dusk installed. This is native
  AVPlayer external playback, not screen mirroring and not a Dusk-to-Dusk sync
  protocol.
- `PlaybackAirPlayController` observes the system-owned long-form-video route.
  `PlayerAirPlayRoutePicker` wraps `AVRoutePickerView` and prioritizes video
  receivers. `Info-iOS.plist` declares `AVInitialRouteSharingPolicy =
  LongFormVideo`; the existing audio session, background mode, Now Playing
  metadata, and remote commands keep the phone useful while video is external.
- The route picker is rendered with clear tints and `PlayerAirPlayControl`
  draws the visible `airplayvideo` symbol on top of it. `AVRoutePickerView`
  positions its own glyph on its own metrics instead of centering it in the
  size it is given, so the system glyph sits high in Dusk's 44pt circle and
  never matches the weight of the buttons beside it. The picker stays the
  actual control — discovery, route naming, and connection UI remain Apple's —
  and it also reports the proposed size rather than its intrinsic one so it
  cannot grow the bar it sits in or take a touch target wider than the circle.
- `PlayerAirPlayRemoteBackground` is the phone's screen while video is on the
  receiver: a clamped, clipped, blurred wash of the item's backdrop, the poster
  in the half above the HUD's centered play/pause button, and a "Playing on
  <route>" pill in the half below it. Both halves are equally flexible, so the
  split stays on the transport button in any orientation; short layouts
  (iPhone landscape) drop the poster and title and keep the pill. **Any
  full-bleed artwork added here must keep the
  `.frame(maxWidth:.infinity, maxHeight:.infinity).clipped()` clamp**: a
  fill-scaled image reports its scaled size, which grows `PlayerSessionView`'s
  stack past the screen and drags the HUD's top bar and play bar off the edges
  (portrait lost the play bar entirely, landscape clipped the top bar).
  `PlayerLoadingView` and `PlayerUpNextOverlayView` clamp their washes the same
  way.
- Local output remains direct-play first. When an AirPlay route is selected for
  a direct-play or downloaded source, the coordinator snapshots position/state
  and asks `PlexService.airPlayStreamURL` for uncapped HLS. Plex may direct-stream
  compatible tracks but has an H.264/AAC target for receiver-incompatible media;
  Dusk then swaps to AVPlayer without finalizing timeline/scrobble state.
- Manual transcodes, automatic server streams, and Live TV are already HLS and
  hand off directly when they use AVPlayer. AirPlay overrides the debug-only
  Force VLCKit choice when a new library or Live TV session starts.
- AirPlay audio/subtitle pickers represent original Plex streams, not the
  rewritten HLS track list. A selection rebuilds the AirPlay stream at the same
  position; subtitles are burned by Plex so PGS/ASS and third-party receivers
  behave consistently.
- Disconnecting AirPlay keeps the prepared HLS source until the item ends. This
  avoids a second visible handoff back to direct play/VLCKit. The next item uses
  the currently selected route normally.
- Completed downloads require the matching Plex server to be connected for
  AirPlay. Dusk does not run an on-device transcoder or local HTTP server for
  offline VLC-only files.
- `PlaybackCoordinator` continues to own timeline, scrobble, markers, continuous
  playback, and Up Next. No state is synchronized from a Dusk receiver app.

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
- Selecting a subtitle stream can be carried into a server stream/transcode
  via `subtitleStreamID` + `subtitles=burn` (both delivery modes support it).

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
- `StreamResolver.evaluate` only decides engine type, reason, and the
  `requiresServerTranscode` flag. It does not build URLs, validate network
  access, or inspect local download availability.
- Evaluation is per-stream across ALL parts (media-level summary fields are
  the fallback when a part carries no stream metadata): 10-bit H.264 (Hi10P)
  routes to VLCKit, AV1 uses AVPlayer only when
  `VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)` (dav1d decodes it in
  software otherwise), and Dolby Vision profile 5 sets
  `requiresServerTranscode` regardless of container — neither engine can
  tone-map IPTPQc2 locally. DV profiles 7/8 play through their HDR10 base
  layer normally.
- Force preferences override all codec/container checks. `forceAVPlayer` can
  intentionally choose an engine that later fails on unsupported media.

## PlaybackEngine Contract
- `PlaybackEngine` is `@MainActor` and implementations are `@Observable`.
- Required lifecycle: `load(source:)`, `play`, `pause`, `stop`, `seek`,
  `setPlaybackRate`, `recoverFromStall`, and `handleReturnToForeground`.
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
  stream metadata before presenting them. VLCKit 3 identifies player tracks by
  elementary-stream indexes (unique only per track kind, with a "Disable"
  pseudo-track at -1 that the engine filters out); `VLCKitEngine` keys them as
  "audio/<index>"/"spu/<index>" and mints a stable Int model id per key. Codec,
  channel, and language metadata comes from `VLCMedia.tracksInformation`.
- Engine tracks carry `isDecodable`. The bundled VLCKit build cannot decode
  every codec a container may hold (see "Undecodable audio tracks" below).
  Automatic selection only considers decodable tracks; the pickers list all of
  them, and picking an undecodable one reroutes through
  `PlaybackCoordinator.transcodeForUndecodableAudio` (server transcode pinned
  to that stream) instead of silencing playback.
- Picture in Picture is optional, observable engine state: `isPictureInPicturePossible`,
  `isPictureInPictureActive`, `start/stopPictureInPicture()`, and
  `setPictureInPictureDelegate(_:)`. The protocol extension defaults everything
  to off, so tvOS engines get a safe no-op. AVPlayer PiP is always available;
  VLCKit PiP uses the sample-buffer output — immediately when Video
  Enhancement's raw frame tap is already running, otherwise via the on-demand
  PiP support mode (see the Picture in Picture section).
- `playerViewGeneration` is bumped when an engine replaces its rendering view
  mid-session (VLCKit entering PiP support mode); `PlayerViewModel.sync()`
  re-calls `makePlayerView()` when it changes.

## iOS/iPadOS Hold-to-Speed
- Holding the unobstructed player surface for 0.5 seconds temporarily switches
  active playback to 2x. Lifting the finger or cancelling the gesture restores
  1x; a short tap remains the normal controls gesture.
- `PlayerTapInteractionOverlay` owns the UIKit long-press recognizer so begin,
  end, movement cancellation, and competition with the existing single/double
  taps are explicit. tvOS does not install this interaction.
- `PlayerViewModel` owns the transient UI state and always restores 1x during
  cleanup or before a play/pause toggle. Concrete rate changes stay behind
  `PlaybackEngine`, with both AVPlayer and VLCKit resetting to 1x for a new or
  stopped session so the temporary rate cannot leak across playback sessions.

## AVPlayer and VLCKit Split
- `AVPlayerEngine` is for MP4/MOV/M4V-style direct play with AV-compatible
  video, audio, and text subtitles. `VLCKitEngine` is the fallback for MKV,
  DTS/TrueHD audio, bitmap/complex subtitles, and other VLC-only combinations.
- Current AV-compatible sets live in `StreamResolver`: containers
  `mp4`, `mov`, `m4v`; video `h264` (8-bit only), `hevc`, `av1` (hardware
  decoders only); audio `aac`, `ac3`, `eac3`, `alac`, `mp3`, `flac`;
  subtitles `tx3g`, `mov_text`, `srt`, `subrip`, `vtt`, `webvtt`.
- AVPlayer uses `AVPlayerLayer`, KVO, media-selection groups, and text style
  rules. Its initial exact resume seek must finish before autoplay begins; do
  not clear the pending offset or call `play()` merely because the item became
  ready. VLCKit uses `VLCMediaPlayer`, delegate callbacks, track APIs, media
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
  passthrough probing, session activation, resume-seek flush) risks a failed
  `aout_OutputNew` muting the stream until a manual pause/resume. The stable
  3.x line has not shown this failure class on device, but preselection still
  avoids provoking an ES switch during bring-up at all.
- The runtime auto-selection remains as a safety net for preselect mapping
  misses. It is deferred until steady-state playback
  (`PlaybackEngine.isReadyForAutomaticAudioSelection`; VLCKit: playing,
  start-position seek issued and settled, no revive in flight — trivially
  satisfied while the revive machinery is dormant — and ≥4 consecutive
  advancing time ticks; the counter resets on load/seek/pause). The counter and the gate
  are deliberately NOT tied to buffering state: libvlc emits buffering
  events continuously on network streams (cache-level churn), and the old
  reset-on-buffering/`!isBuffering` gate provably never opened on device —
  the safety net and the audio revive silently never ran. Advancing time is
  the real steadiness signal; a genuine refill freezes the clock and stops
  the counter on its own. Auto-selection is skipped entirely when the
  preferred track is already selected, which is the normal case with
  preselection in place. Steady-state switches use the
  same code path as manual picker changes, which are reliable. Verified in
  the C-API harness (throttled Range-HTTP + amem PCM tap + audiounit log
  tracing): ASAP switch interleaves the output restart with bring-up;
  `:audio-track` preselect yields a single bring-up with zero switches;
  post-settle switch restarts a live output with one ~30 ms flush.

### Undecodable audio tracks (TrueHD/MLP)
- The vendored frameworks are VideoLAN's STOCK stable 3.x prebuilts, which
  disable ffmpeg's mlp decoder/demuxer/parser on iOS/tvOS ("to be in
  compliance with the App Store ToS" — Dolby licensing; AC-3/E-AC-3 decode
  through Apple's licensed AudioToolbox instead), and ffmpeg's truehd decoder
  depends on the mlp parser. libvlc logs ``Codec `mlpa' (TrueHD Audio) is not
  supported`` and cannot play such tracks, so
  `VLCKitEngine.undecodableAudioFourCCs` contains the TrueHD/MLP fourccs.
  (The retired 4.x-alpha setup carried a local patch series that re-enabled
  TrueHD; it lives in git history under `ci_scripts/vlc-patches/` if ever
  needed again — a deliberate licensing/App Store decision.)
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
  direct-playing as a silent video.

### VLCKit audio output module
- `VLCKitEngine` runs its players on a single shared `VLCLibrary` with no
  custom options. On the stable 3.x line the iOS/tvOS audio output IS the
  classic pull-model AudioUnit module; the `avsamplebuffer` output that
  libvlc 4.0-dev defaulted to — and whose iOS-specific clock drift caused
  the cyclic audio dropouts chronicled in the postmortem — does not exist on
  this branch, so the old `--aout` pin and the Settings A/B toggle were
  removed with the migration.
- VLCKit keeps encoded passthrough off. `configureAudioOutputPolicy` is split by
  platform because the routes are fundamentally different, and it is idempotent
  (a signature of the resolved config gates every player/session write) and
  observes only `routeChangeNotification` — never the spatial- or
  rendering-capability notifications.
- libvlc caching (`PlaybackBufferPolicy.vlcCachingMilliseconds(for:)`) is the
  input's pts_delay, which IS the audio output's start deferral: every start
  and every seek renders video for ~the caching duration before sound joins.
  It is therefore tiered by `PlaybackSource.locality` (resolved by the
  coordinator: downloaded file 300 ms / LAN server 600 ms / remote 1500 ms)
  instead of a flat value — a flat 1500 ms opened every session with ~1.5 s
  of silent video. Playback Info shows the applied value ("VLC Caching").
  Lowering a tier trades rebuffer risk for start latency; raise the LAN tier
  before suspecting playback code if LAN sessions start rebuffering.
- Pause/resume has a separate stock-VLC latency source: stable 3.x's Apple
  AudioUnit output flushes its queued audio when pausing because it cannot
  recover the previous output delay after `AudioOutputUnitStop`; the upstream
  source notes that this otherwise loses roughly 1–2 seconds of audio after
  resume. `VLCKitEngine.play()` therefore re-seeks to the paused timestamp
  before unpausing. That rebuilds the audio and video decoder queues together,
  making resume use the same locality-sized 300/600/1500 ms cache window as
  startup and seeks instead of waiting through the discarded audio window.

### Audio revive machinery (dormant) and session ownership

> Full history, root-cause analysis, false leads, and diagnostic tooling for
> the 2026-07 silent-audio saga live in `docs/audio-silence-postmortem.md`.
> Read it before changing anything in this section.
- HISTORICAL CONTEXT: the machinery below was built against the retired
  VLCKit 4.0.0a19 (libvlc 4.0-dev) vendoring, whose rewritten iOS audio
  output could latch into rendering silence while reporting success. The
  local libvlc patch series that fixed the detectable latches (vlc-patches
  0013–0016) was retired together with that build; the patches live in git
  history. The stable 3.x line vendored now uses the field-proven audiounit
  output that has shown none of those states.
- The app-side revive is therefore DORMANT by default:
  `VLCKitEngine.isAudioReviveEnabled` reads the `vlcAudioReviveEnabled` user
  default (false unless set), which gates both the settle-revive arming and
  the interruption watchdog. It is deliberately kept compiled — it is the
  only proven cure for undetectable silent-render states, and re-arming it
  on device requires no rebuild. Do not delete it without device evidence
  that the 3.x stack never needs it.
- App-side seek/startup discipline (`VLCKitEngine`), because every libvlc
  seek flushes the decoders and the audio output, and a flush landing on an
  output mid-bring-up is what latched the remaining silent states:
  - The resume position is applied immediately after `play()`, while the
    input is still opening — the seek is queued on the input thread and
    processed before the audio output exists. The first `.playing` state
    keeps a fallback seek only when the early seek demonstrably did not land
    (observed player time far from the target). Deliberately NOT the
    `:start-time` media option: libvlc treats that as a virtual sub-clip
    (duration shrinks, later seeks become relative), which would corrupt
    Plex timeline reporting.
  - `applySeek` issues exactly one seek command (`time`). Setting `position`
    then `time` was two input seeks — double flush — per app seek; libvlc's
    input core already falls back to a position-seek internally when a
    demuxer cannot seek by time.
  - Seek verification retries are skipped while the player is buffering: a
    buffering player has accepted the seek and is refilling (far double-tap
    seeks over the network take longer than the retry delays), and
    re-seeking mid-refill just multiplied the flush storm. Retries only fire
    when playback runs on at the pre-seek position, i.e. the seek was truly
    ignored.
  - The seek target is published as `currentTime` immediately, and stale
    pre-seek time updates are rejected for `pendingSeekStaleUpdateWindow`
    (1.5 s) — extended to `pendingSeekRefillHoldWindow` (12 s) while the
    player is buffering, because a refilling player keeps reporting the old
    time until the new position decodes. Without the extension the play bar,
    the Skip Intro button, and Now Playing all snapped back to the pre-seek
    position mid-refill and forward again when it completed. The window is
    bounded so a seek that never lands cannot freeze the readout (stall
    recovery takes over at 12 s). `AVPlayerEngine.seek` publishes its target
    the same way; its periodic observer only reports once the seek resolves.
- App-side audio revive (`VLCKitEngine`, DORMANT unless `vlcAudioReviveEnabled`
  is set — everything below describes its behavior when armed): it exists for
  silent-render states where nothing observable fails — an interruption
  `began` whose `ended` never arrives (some Bluetooth handoffs never send
  it), and a started-but-dead render unit. Both are cured by exactly what a
  manual pause→play does
  (AudioOutputUnitStop → session reactivation → AudioOutputUnitStart →
  render unlatch, and a fresh render-callback timing report that re-syncs
  the master clock), so the engine automates that cure as a CLOSED-LOOP
  replica of the manual sequence. Every step waits for libvlc's own state
  confirmation instead of racing it with wall-clock timers — an open-loop
  pause → sleep → play provably lost that race on slow connections (the
  timed play was processed before the pause, which then confirmed
  afterwards and stranded the player paused). Phases: pause issued → wait
  for the `.paused` event → hold (1.2 s on initial warmup, 100 ms on seek
  revives; tunable via `vlcAudioWarmupReviveGapMs`/`vlcAudioReviveGapMs`)
  → play issued
  (plus the post-resume video-output refresh the manual path schedules) →
  wait for the `.playing` event; a stray late pause confirmation is
  re-played (bounded enforcer). The only timers are failsafes whose expiry
  action is safe and idempotent in every ordering (issue/repeat play, or
  surface reality and stop masking). Confirmed on device (2026-07-06) to
  restore audio exactly like the manual cure:
  - once per audio-output disturbance — media open, stall recovery, and
    each seek burst (every seek flushes the output) — on iOS/iPadOS only.
    Two independent triggers, first to succeed wins, and the arm survives
    until a revive actually starts (a deferred/rate-limited attempt
    retries), so the cure cannot be lost to a race:
    1. initial warmup (load/stall recovery): PRIMARY trigger is ≥4 accepted
       advancing time ticks (~1 s of confirmed rendering; ticks freeze
       during genuine refills, so the wait adapts to connection speed), and
       the pause holds 1.2 s (`vlcAudioWarmupReviveGapMs`, default 1200).
       This is the configuration confirmed on device to cure silent starts
       100% of the time. Firing earlier (first tick or the `.playing`
       event) provably cured seeks but NOT starts — the silent state forms
       during the first ~second of rendering, and a cure that runs before
       it exists cures nothing. The latency hides behind the loading mask.
    2. seek revives: the `.playing` transition after a refill (far seeks)
       or the first advancing tick (near/cached seeks that settle without a
       state transition), with a 100 ms hold (`vlcAudioReviveGapMs`) —
       confirmed sufficient for seek-induced silence.
    On initial bring-up (load and stall recovery, not seeks) the engine
    masks the whole warmup as `.loading`: the user-facing state first
    becomes `.playing` only when the revive has completed and audio is
    guaranteed, so the pause→resume is absorbed into perceived load time
    and the UI never sees a play→pause→play flap at any connection speed.
    User pause/stop/error/end always tear the machinery down (user intent
    and reality win; the mask can never stick). The revive is ordered
    before automatic track selection so an ES switch never interleaves
    with it. A real user pause→resume consumes a pending arm, since it
    already ran the same cure natively. Rate limit: 1.5 s between revives.
  - whenever an audio-session interruption `began` is not followed by an
    `ended` within 2.5 s while the engine still reports playing (nothing
    paused us, so the user expects sound). If `ended` does arrive, the
    patched libvlc revives itself and the watchdog is cancelled.
- Stale-embed guard: Xcode's framework-embed step can silently reuse an old
  cached VLCKit when the checked-in binary is replaced in-place — device
  builds have shipped outdated VLCKit while the repo contained a newer one,
  making every fix look ineffective. Two defenses:
  - Build time: `scripts/verify_embedded_vlckit.sh` (post-build phase on
    both targets) fails the build when the embedded
    MobileVLCKit/TVVLCKit binary's Mach-O UUID does not match the checked-in
    `Frameworks/` copy, with a "delete DerivedData" message.
  - Runtime: `VLCKitEngine.vendoredVLCKitAudit` reports the libvlc version
    actually loaded into the process, logs the verdict at engine init, and
    Playback Info shows it as the "VLCKit Build" row ("Stable VLCKit 3.x
    (libvlc 3.0.x)" vs "UNEXPECTED build"). When debugging audio on a
    device, check this row FIRST.
- On-device libvlc tracing: `VLCLibraryLogBridge` attaches to both shared
  `VLCLibrary` instances and forwards libvlc's internal messages into the
  unified log (subsystem = bundle id, category "libvlc") at `.notice`+ so
  they persist into Console.app captures and sysdiagnoses from TestFlight
  devices. Errors/warnings always pass; info/debug pass only for
  audio/clock/ES-selection emitters ("deferring start", "playback way too
  late", output restarts, session activation failures, interruptions). The
  `vlcVerboseLogging` user default opens the full firehose. VLCKit drops
  ALL libvlc messages when no logger is attached — never remove this bridge
  while any audio bug is open. Filter Console on category `libvlc` plus
  categories `VLCKitEngine`/`PlaybackSession` for the app-side breadcrumbs
  (seeks, revives, interruptions, audits).
- Session ownership: the app (`PlaybackNowPlayingController`) is the single
  owner of the `AVAudioSession` category/mode/policy on iOS. `beginSession`
  does not deactivate the previous session before activating the new one
  (the deactivate→activate whiplash was a proven failure generator on
  Bluetooth routes), session activation/deactivation failures log instead
  of asserting, and the interruption handler only pauses the engine when it
  was actually playing (never pokes a loading/buffering player mid-open).
  The same controller preserves playing transport intent across
  resign-active/background transitions: if iOS or an engine reports an
  unsolicited pause after Control Center or backgrounding, it reactivates the
  session and resumes. Explicit remote Pause commands, genuine audio-session
  interruptions, and headphone/route removal remain authoritative and are
  never auto-resumed by this recovery path.
  tvOS sets the `.playback`/`.moviePlayback` category at app launch
  (`DuskApp.configurePlaybackAudioSession`).
- tvOS drives true multichannel output to the connected receiver over
  HDMI/eARC at the session level, and **timing is the whole game**. libvlc 3's
  `avas_setPreferredNumberOfChannels` reads the route's
  `maximumOutputNumberOfChannels` exactly once while its audio output starts;
  if that reads 2 it pins `fmt->i_physical_channels` to stereo and folds
  5.1/7.1 down in libvlc's own channel mixer for the whole session — an
  unnormalized `L + 0.7071*(C + Ls)` fold with no headroom, which buries
  dialogue and clips loud scenes. So:
  - the multichannel opt-in is **unconditional** on tvOS. It is a capability
    declaration, not a statement about the current track. Making it
    conditional on the selected track is what regressed 5.1/7.1 during the
    VLCKit 4 → 3.7.3 migration: `selectedAudioTrackInfo()` is nil until
    `tracks-refreshed`, long after libvlc has already committed to stereo.
  - the expected layout comes from Plex metadata via
    `PlaybackSource.preferredAudioChannelCount`
    (`PlayerViewModel.preferredAudioStreamChannelCount`), because the
    `before-play` call is the only one that can still influence libvlc and the
    engine has no track list then.
  - the route ceiling is re-read *after* the opt-in. tvOS reports a
    stereo-only maximum while the session is declared stereo-only, so
    measuring first permanently justifies never asking for surround.
  - libvlc overwrites `supportsMultichannelContent` on every audio-output
    start (`avas_SetActive` passes its own spatial-audio flag, still false on
    first bring-up), so `AVPlayerEngine.load` re-asserts it on tvOS. Without
    that, one VLCKit title leaves every later AVPlayer title in stereo for the
    rest of the app's lifetime.
  - passthrough/bitstreaming is impossible on this stack regardless: libvlc 3
    returns `VLC_EGENERIC` for SPDIF/HDMI formats on Apple platforms. Dusk
    always software-decodes to PCM; the goal is only that the PCM is discrete
    multichannel rather than a fold-down.
  - Playback Info's "Output Channels" row reads
    `expected=… current=… preferred=… max=…`. `expected>2` with `current=2` is
    the signature of libvlc folding down in software.
- iOS/iPadOS does NOT drive surround at all. The output route is effectively
  stereo (built-in speaker, wired, or Bluetooth/AirPods), so the policy lets
  VLCKit downmix to the route on its own; it sets no preferred output channel
  count and does not touch multichannel session content (the AVAudioSession is
  owned by `PlaybackNowPlayingController`). Keeping this policy idempotent
  matters: every re-poke of the live player's audio settings (passthrough,
  equalizer) restarts VLCKit's audio output, which is an audible gap. Historical note: the recurring "audio cuts in and out on this
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
  20 seconds of forward buffer, while VLCKit uses 1,500 ms for network and file
  caching. Do NOT raise the VLC caching values casually: libvlc caching becomes
  the input's pts_delay, which scales every clock window in the pipeline — the
  initial dejitter, the audio output's start deferral after open/seek/flush,
  and the late/early drift thresholds. At the previous 8,000 ms those windows
  stretched to many seconds of silent-but-"healthy" audio after every start
  and seek (a manual pause→play "cured" it only because pausing shifts the
  clocks by the pause duration). VLC-iOS ships 999 ms on the same stack.
  Dusk does not configure an explicit back-buffer size.
- Both engines implement stall recovery by reloading/restarting near the
  observed position. Keep recovery behavior engine-specific.
- iOS VLCKit has extra drawable and video-output refresh behavior and hosts the
  native PiP pipeline (see Picture in Picture); tvOS uses a simpler drawable host.
- Subtitle sizing is centralized in `PlaybackSubtitleStyle`; avoid separate
  magic numbers per engine unless there is a platform reason.

## Picture in Picture
- iOS only, native. AVPlayer uses an `AVPictureInPictureController` built from
  the `AVPlayerLayer` and auto-starts PiP when the app is backgrounded during
  playback (`canStartPictureInPictureAutomaticallyFromInline`). VLCKit 3.x has
  no drawable-native PiP (that was a 4.x feature); all VLC PiP goes through
  the sample-buffer output. tvOS uses the protocol no-op defaults.
- VLCKit PiP support mode (plain sessions, button-triggered): libvlc has
  exactly one video output, so PiP needs the raw frame tap — which cannot
  coexist with the native drawable. When the user taps PiP on a session where
  the tap is not already running, `VLCKitEngine.enterPictureInPictureSupportMode`
  swaps the pipeline: it attaches the raw tap feeding a fresh
  `VLCKitEnhancedPictureInPictureOutput`, makes the sample-buffer layer the
  PRIMARY on-screen surface (`isPrimaryDisplaySurface`, full-rate intake, no
  Metal renderer involved), reloads the media in place at the live position
  (raw callbacks only bind on a fresh input — same mechanics as stall
  recovery, masked as loading), and auto-starts PiP once the controller
  reports possible (`pendingPictureInPictureStart`). The mode persists for
  the rest of the session — switching back would be another visible reload —
  and is torn down on `load`/`stop`/`configureVideoEnhancement`. Costs while
  active: vmem software rendering plus the per-frame BGRA channel swap, i.e.
  the same class of overhead as Video Enhancement; HDR content is rendered
  through the 8-bit conversion without libvlc's GL tone mapping, so it can
  look flatter in this mode.
- With Video Enhancement already on, the tap and output are already live and
  the button starts PiP directly (no reload).
- Prerequisites already in place: the audio session is
  `.playback`/`.moviePlayback`/`.longFormVideo` (`DuskApp`) and `UIBackgroundModes`
  includes `audio` (`Info-iOS.plist`). PiP will not run without both.
- Availability: `isPictureInPicturePossible` is true for VLC sessions whenever
  media is loaded (the button may trigger the support-mode swap) and for the
  enhanced path once the system controller is ready. The player's round
  top-right PiP button (`PlayerControlsIOSOverlay`) only shows when possible
  and toggles via `PlayerViewModel.togglePictureInPicture()`.
- Enhanced-mode PiP (the part that makes the above work): the Metal upscaler
  takes over the full-screen surface, so each engine keeps a *separate* native
  layer alive behind it, occluded, purely to feed PiP.
  - AVPlayer keeps its real `AVPlayerLayer` mounted behind the Metal view
    (`makePlayerView()` returns a `ZStack`); the same native
    `AVPictureInPictureController` projects from it, no other change.
  - VLCKit: `VLCKitEnhancedPictureInPictureOutput` tees the same decoded
    frames into an `AVSampleBufferDisplayLayer` and drives a sample-buffer
    `AVPictureInPictureController`. The frames are RGBA-in-BGRA (see Video
    Enhancement), so it channel-swaps each frame to true BGRA (vImage) before
    display, coalescing to the latest frame on a serial queue like the Metal
    renderer. While the floating window is closed the intake is throttled to
    every 10th frame — enough to keep PiP startable on a current picture
    without paying the full-resolution CPU swap per decoded frame. A
    `CMTimebase` synced from the engine drives the PiP scrubber. The display
    layer is mounted (occluded) behind the Metal view to keep a native
    surface on screen.
- Lifecycle (the subtle part): starting PiP drops the full-screen cover
  (`showPlayer = false`) so the floating window is unobstructed. The engine must
  outlive that dismissal — `PlaybackCoordinator.onPlayerDismissed` and
  `PlayerViewModel.cleanup` both skip teardown while `isPictureInPictureActive`,
  and `startPlaybackIfNeeded` skips the reload (`engine.state == .idle` guard) so
  returning re-presents the player over the live engine instead of restarting.
- Restore vs. close is handled in `PlaybackCoordinator+PictureInPicture`. Both
  paths own a real `AVPictureInPictureControllerDelegate`: the restore button
  re-presents the player (completion fired from `notePlayerUIDidAppear`), the
  close button finalizes the session.

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
- Direct-play and downloaded parts with embedded subtitle streams always keep
  the native engine renderer, even when enhancement is Auto or On. AVPlayer and
  VLCKit composite subtitles in their native presentation surfaces, while the
  opaque Metal view receives only raw video frames and would cover every cue.
  The decision is made before the engine loads because VLCKit 3's custom-memory
  video callback cannot be detached from a live player. Playback Info reports
  `Native renderer required for embedded subtitles` when this constraint wins.
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
- The drawable is sized from `UIScreen.nativeScale`, never `scale`. On an Apple
  TV 4K `scale` is 1.0 (UIKit lays out on a 1920x1080 point grid) while
  `nativeScale` is 2.0, so reading `scale` silently capped the upscaler's output
  at 1080p and handed tvOS an image to stretch. Apple's Metal Best Practices
  guide requires drawables be sized from `nativeScale`/`nativeBounds`.
- The scale that drives the enhancement decision is source -> *letterboxed
  viewport*, not source -> full drawable. Deciding from the drawable overstates
  it on scope content (2.39:1 in a 16:9 drawable reads as 1.35x when the real
  ratio is ~1.00). `renderToLayer` computes `displayRect` before calling
  `enhancementDecision` for this reason; keep that order.
- The Metal layer declares `colorspace` (BT.709 for SDR). A nil `colorspace`
  means "no colormatching occurs" per `CAMetalLayer`'s header: the rendered
  values reach the display's context untouched, which is wrong whenever that
  context is not the space the frames are in — notably an Apple TV pinned to a
  Dolby Vision/HDR output format, where BT.709 SDR values get consumed as HDR
  and the picture washes out. libvlc has already converted YUV to full-range
  BT.709 RGB (`matrix_bt709_tv2full`), so BT.709 is the accurate declaration.
  HDR sources stay untagged: this path is 8-bit BGRA, so claiming BT.709 for
  frames libvlc already flattened would be a second wrong answer.
- When changing this path, verify compile-only builds for iOS and tvOS, then
  manually check one AVPlayer stream, one VLCKit stream, the Off setting,
  Auto on a lower-resolution SDR stream, and player dismissal/teardown on
  device.

## Display Mode Matching (tvOS)
- `DisplayModeMatcher` asks tvOS to switch the Apple TV's output to the
  content's native frame rate and dynamic range for the duration of a session.
  It is renderer-independent and therefore applied for every engine — this is
  the only fix that reaches VLCKit's native drawable, which is what most of the
  library actually plays through.
- Why it matters: without it the box stays in the system UI's mode. 23.976 fps
  into 60 Hz needs 3:2 pulldown, so frames alternate 2 and 3 refreshes
  (41.7/83.3 ms) — the judder visible on slow pans. And when the box is pinned
  to an HDR format, SDR content is carried in an HDR container; AVPlayer's
  frames are tagged and survive it, but VLCKit renders into an untagged 8-bit
  RGBA UI-plane surface (libvlc 3.0.x `modules/video_output/ios.m` uses
  `kEAGLColorFormatRGBA8` and never tags the layer), so BT.709 is treated as
  sRGB and the picture flattens.
- `apply` runs *before* `engine = newEngine` at both session-start and
  replacement-attempt sites, so the mode switch's screen blank overlaps
  buffering rather than playback. `reset` runs in `clearPlayerState`. A
  replacement attempt re-evaluates rather than inheriting, because a quality
  switch can change the delivered dynamic range.
- Refresh rate comes from the Plex video stream's `frameRate`, passed through
  unrounded: an exact 23.976 request is what lets a 24000/1001 file play with no
  cadence correction. NTSC rates are deliberately not snapped to integers. tvOS
  picks the closest mode the TV supports, so an unsupported request degrades
  rather than fails.
- Dynamic range is carried by the `CMVideoFormatDescription`'s color tags, read
  from the stream's own `colorTrc`/`colorPrimaries`/`colorSpace` (ffmpeg
  spellings) rather than the looser `isHDRVideo` heuristic, and defaulting to
  BT.709 so an unrecognized value is never reported as HDR.
- tvOS gates the switch behind Settings → Video and Audio → Match Content. When
  the user has it off, `displayCriteriaMatchingEnabled` is false and setting a
  criteria is a no-op; the matcher leaves any previous criteria alone and
  reports the reason. `AirPlay` decisions reset instead of applying, since the
  local box is not the renderer.
- Display matching is device-only because the simulator cannot switch the host
  Mac's display mode. `AVKit.framework` must remain an explicit tvOS target
  dependency: `UIWindow.avDisplayManager` is supplied by an Objective-C category
  in AVKit, and merely importing the module does not load that category into the
  app process. The lookup also checks the selector at runtime so a missing
  category skips matching instead of crashing playback.
- Playback Info shows a `Display Mode` row (tvOS only) with either the requested
  mode (`23.976 Hz SDR`) or why nothing was requested. Use it to confirm the
  feature before diagnosing anything else about picture quality.

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
- **Auto-skip fires at most once per marker per playback session.** Skipping a
  marker — by countdown or by tapping Skip Intro — records its id in
  `PlaybackCoordinator.spentAutoSkipMarkerIDs`, and `updateAutoSkipState` never
  arms a countdown for a spent marker again. The button still appears, so the
  viewer can skip by hand as often as they like. Two failure modes this closes:
  a post-skip seek that is still buffering leaves the position inside the marker
  and used to re-arm the countdown immediately, and a deliberate rewind into the
  intro used to be yanked forward again. The record lives on the coordinator (not
  the view model) so it survives the engine swaps that rebuild the player —
  quality switch, delivery-ladder fallback, Picture in Picture restore — and is
  cleared when the next session commits or the player is torn down, so reopening
  an episode gets a fresh auto-skip. `PlayerViewModel` is seeded with it in
  `configureAutomaticTrackSelection` and reports new entries through
  `autoSkipSpentHandler`.
- Playback controls start visible for orientation, then `PlayerViewModel`
  owns one auto-hide deadline/task for the whole session. Sync arms it once
  playback has started, every user reveal resets it, and it keeps retrying
  while temporary blockers such as scrubbing or selection sheets are active.
- The HUD fades in and out on the same curve
  (`PlayerViewModel.controlsVisibilityAnimation`), applied by the `withAnimation`
  around every `showControls` mutation. **On iOS the overlay stays mounted for
  the whole session** and `PlayerSessionView.controlsOverlay` animates `opacity`
  (plus `allowsHitTesting` and `accessibilityHidden`). Do not turn this back into
  a `.transition(.opacity)` on an `if showControls` branch: a removal transition
  is re-decided on every render pass, and sync republishes `currentTime` 4x/sec —
  which `activeSkipMarker` derives from and `body` reads — so an unanimated pass
  lands mid-fade and finalizes the removal, making the HUD vanish instead of fade
  (fade-in is unaffected, which is what makes the bug look one-sided). tvOS keeps
  the conditional mount because `PlayerControlsTVOverlay` owns focus state and its
  buttons stay focusable at zero opacity; it binds the curve to the transition
  instead.
- On iPad the whole player cover — `PlayerView`'s stack, the loading art, the
  shared spinner, and the session — extends through the top status-bar safe
  area (`PlayerOverlayLayout.ignoredStatusBarSafeAreaEdges`), while the HUD
  reserves the captured status-bar inset itself
  (`PlayerOverlayLayout.capturedStatusBarTopInset`). Keep this separation when
  changing system-overlay visibility: otherwise the status-bar fade changes the
  cover's proposed height and makes the video and centered overlays jump
  independently of the HUD fade. It is not enough for the session alone to
  ignore the inset — the spinner is centered in `PlayerView`'s stack, so it
  would still hop by half the status-bar height on every HUD toggle. iPhone is
  unaffected (its top inset comes from the sensor housing and does not move
  with the status bar), which is why the symptom is iPad-only.
- `PlayerViewModel.cleanup()` pauses the engine instead of stopping it so the
  coordinator can still read final time/duration before finalization.
- iOS uses touch overlays, a gear menu for playback info, quality, and track
  selection, sheets for quality/audio/subtitle choices, and double-tap seek
  zones when enabled. The center play/pause button is replaced by the shared
  spinner for as long as that spinner is up
  (`PlaybackCoordinator.playerLoadingState.isVisible`): startup (engine
  `.idle`/`.loading`, which includes the VLCKit audio warmup, also covered
  same-frame by `PlayerViewModel.isAwaitingPlaybackStart`), mid-play
  buffering, and
  automatic direct-play recovery. So the two never stack in the center slot,
  and startup never flashes a play icon that immediately flips to pause. The
  button stays mounted at zero opacity instead of being removed, for the same
  reason the HUD does (see the fade note above) and so the HUD's layout does
  not change when buffering starts.
- The iOS/iPadOS controls expose a round zoom button at the top-right that
  toggles `PlayerViewModel.aspectFillEnabled` and calls
  `PlaybackEngine.setVideoFillEnabled(_:)`. Fill zooms the picture to cover the
  drawable (cropping the overflow) instead of letterboxing it. Each rendering
  path applies it natively: AVPlayer flips `AVPlayerLayer.videoGravity`, VLCKit
  sets a crop ratio matching the drawable's aspect ratio (re-applied on layout
  so rotation stays correct), and the Video Enhancement Metal renderer switches
  its viewport from aspect-fit to aspect-fill. tvOS does not expose the control.
- The choice is persisted **per orientation** and remembered across sessions via
  `UserPreferences.playerAspectFill(isLandscape:)` /
  `setPlayerAspectFill(_:isLandscape:)` (keys `playerAspectFillPortrait` /
  `playerAspectFillLandscape`, both default off). `PlayerSessionView` derives the
  orientation from the player's own layout size (so it also tracks iPad
  multitasking window shape) and feeds it to
  `PlayerViewModel.updateVideoOrientation(isLandscape:)`, which applies that
  orientation's saved value; `toggleAspectFill()` writes back only the current
  orientation. Portrait and landscape are fully independent — rotating swaps the
  framing to whatever that orientation was last left at.
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
- With a mouse/trackpad (Mac or iPad), the system pointer hides together with the
  controls and returns the moment the pointer moves. The non-tvOS
  `PlayerTapInteractionOverlay` owns this: a `UIPointerInteraction` returns
  `UIPointerStyle.hidden()` while `showControls` is false (re-queried via
  `UIPointerInteraction.invalidate()` on every visibility flip), and a
  `UIHoverGestureRecognizer` reveals the HUD on movement. Moving the pointer over
  the visible controls keeps them up via `onContinuousHover` →
  `noteControlsInteraction()`. Touch-only playback never triggers any of it.
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
- Marker skip buttons come from `PlexMarker.skipButtonTitle`. Only the intro
  marker still renders a skip button (`PlayerViewModel.activeSkipMarker` is
  intro-only). Credits are handled by the bottom-right Up Next poster instead of
  a Skip Credits button (see "Timeline, Scrobble, and Up Next").

## Timeline, Scrobble, and Up Next
- `PlaybackCoordinator.startTimelineReporting` sends progress every 10 seconds,
  carrying `X-Plex-Session-Identifier` (the per-session UUID) so the server can
  correlate the session. Every 6th tick pings the active transcode session.
- Timeline maps `.playing` and `.paused` to Plex; `.loading`/buffering reports
  `"buffering"` with the last known position (online sessions only — the
  offline sync manager has no buffering concept).
- `flushTimelineForScenePhase` reports on inactive/background and asks engines
  to refresh rendering when the app becomes active.
- Finalization sends a stopped timeline, updates now-playing, stops the engine,
  and ends the now-playing session.
- Live TV finalization sends stopped but never marks a program watched or
  scrobbles it; its HLS clock is a sliding window rather than item progress.
- Scrobble happens once when progress exceeds 90 percent of duration, either
  during periodic reporting or during finalization.
- Local-download playback does not call Plex directly. It records progress or
  watch state in `OfflinePlaybackSyncManager`, which syncs pending actions when
  the matching server is available.
- There are two Up Next surfaces: the small bottom-right **poster**
  (`upNextPoster`, `PlayerUpNextPosterView`) shown during the credits, and the
  full-screen **overlay** (`upNextPresentation`, `PlayerUpNextOverlayView`).
  They are mutually exclusive; the poster yields to the overlay.
- The poster and the Skip Intro button share
  `PlayerOverlayLayout.skipMarkerBottomInset(controlsVisible:)`: they rest near
  the bottom edge while the HUD is hidden and animate up above the play bar when
  the controls come up.
- Poster layout: concentric corners (the still's radius is
  `cardCornerRadius - cardPadding`) and a fixed three-row text column — eyebrow,
  title, metadata — so the card keeps one height for its whole lifetime. The
  countdown occupies the eyebrow's trailing slot (`8s`, or `Playing…` once
  starting) plus a bar spanning the card's full inner width beneath both
  columns; it is never an extra text row. The column width is clamped against
  the player's own width so the card still fits a narrow viewport.
- Overlay layout: one vertically centered content block sized from **both** axes
  (`UpNextLayoutMetrics.previewSize`). The still is the smaller of a share of the
  width and a share of the height, because the player is watched in landscape as
  often as portrait; a width-only rule pushed the details off the bottom of an
  iPhone in landscape. Narrow or portrait containers stack the still over the
  details, wide ones put them side by side, and tvOS is always side by side. The
  close button anchors to the screen's top-trailing safe area, not to the content
  block. The next episode's artwork also backs the screen as a blurred wash.
- The overlay's forward action is a labeled capsule ("Play Now" while a countdown
  is running, "Keep Watching" otherwise), not an icon over the still: white glass
  with a dark label on both platforms, because the screen is near-black whatever
  the app's appearance mode is. tvOS uses a custom `ButtonStyle` for the same
  reason `DetailHeroPrimaryTVButtonStyle` exists — the system `.glassProminent`
  focus highlight would force fill and label both to white.
- Up Next poster (replaces the old Skip Credits button): when the credits marker
  is reached, `PlayerViewModel.reachedCreditsMarker` changes and the player calls
  `presentUpNextPosterIfPossible`, which resolves the next episode and raises the
  poster. `reachedCreditsMarker` stays set from the marker start through the end
  of the episode (based on actual playback time), and clears if the user seeks
  back before the credits, which dismisses the poster. The poster's `mode` is
  computed once from preferences:
  - `timedAutoplay` (continuous play + auto-skip credits on): a pause-aware
    countdown of `continuousPlayCountdown` runs; on expiry the next episode plays
    immediately with no full-screen overlay. The countdown freezes while the user
    pauses, driven by `noteActivePlaybackState` from the player snapshot handler.
  - `autoAdvanceAtEnd` (continuous play on, auto-skip credits off): no countdown;
    the credits play out and the next episode starts at the natural end with no
    overlay.
  - `manual` (continuous play off, the passout-protection streak was hit, or the
    credits auto-advance was already spent this session): no countdown and no
    automatic advance; the natural end shows the full-screen overlay ("Are You
    Still Watching?" / "Autoplay Paused").
  - Like intro auto-skip, the credits auto-advance gets one turn per session:
    arming a `timedAutoplay` poster, or dismissing a poster by hand, records the
    credits marker in `spentAutoSkipMarkerIDs`. Seeking back before the credits
    and reaching them again therefore raises a `manual` poster instead of
    restarting a countdown the viewer already saw or waved off.
- Poster interactions: tapping it (Select on tvOS) plays the next episode now
  (`playUpNextPosterNow`); dragging it down (iOS) / swiping down (tvOS) dismisses
  the poster and cancels any pending auto-advance
  (`dismissUpNextPoster(userInitiated: true)` — the flag is what marks the
  auto-advance spent; the seek-back-out-of-credits path dismisses without it), so the
  current episode plays out to its end — the full-screen overlay only appears
  when it actually finishes (via `handlePlaybackEnded`). `startUpNextPosterPlayback`
  finalizes the still-playing session first (the poster shows over live
  playback), then starts the next episode; on failure it surfaces the full-screen
  overlay with an error.
- On natural episode end, `handlePlaybackEnded` branches on the poster: an
  auto-advancing poster continues straight into the next episode, a `manual`
  poster falls back to the full-screen overlay, and with no poster (no credits
  marker, or the user dragged the poster away) it keeps the legacy behavior of
  finalizing and showing `PlayerUpNextOverlayView`.
- Starting the next episode from the full-screen overlay keeps the cover up and
  the overlay visible as its own loading state (the Play button shows a spinner
  while `isStarting`); the old, already-finalized engine stays until the new one
  commits, and `startPlaybackSession` clears both `upNextPresentation` and
  `upNextPoster` at commit. A failed start restores the overlay with an error
  message instead of the generic "Couldn't Play" alert.
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
- Display mode matching (tvOS): `Features/Player/DisplayModeMatcher.swift`,
  applied and reset from `PlaybackCoordinator+Session.swift`.
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
