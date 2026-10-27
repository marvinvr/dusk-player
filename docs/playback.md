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
1. Detail/list UI asks `PlaybackCoordinator` to play a `PlexItemID` (server +
   rating key) through
   `play`, `playFromStart`, or `playVersion`, passing a `PlaybackPlaceholder`
   (the title/poster art paths the caller already holds). The coordinator
   also receives the initiating model's `viewOffset` as a resume fallback:
   freshly fetched item details remain authoritative when they contain a
   positive offset, but a hub/list offset is preserved when that detail
   response omits one or reports zero. `playFromStart` always overrides both
   with zero. Callers that know the item's runtime also pass
   `resumeOffsetDurationMilliseconds`, which decides whether that offset may
   follow the item onto another server's copy (see "Choosing The Server").
   The coordinator
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
   Otherwise `PlexService.directPlayURL(for:)` builds
   `{connection.baseURL}{part.key}` from the connection of the item's own server
   and adds that server's `X-Plex-Token` when available.
5. `StreamResolver.evaluate` records the intended engine, a human-readable
   reason, and `requiresServerTranscode` (media direct play cannot render
   correctly, e.g. Dolby Vision profile 5). Flagged online media skips direct
   play: it first tries the Dolby Vision remux (see "Dolby Vision Profile 5"),
   then the server-stream rung (see "Delivery Ladder"). The recorded engine
   still follows the container, so the last-resort direct play of a DV5 MKV
   opens on VLCKit rather than an AVPlayer that cannot read MKV at all.
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

## Choosing The Server

- An item can exist on several connected servers. `PlaybackSourceResolver`
  builds the candidate list — the item itself plus its merge `alternates`,
  filtered to currently connected servers and sorted by strict server priority.
  Plex's remote-streaming rule is not judged up front: a server that refuses the
  stream as remote gets one LAN re-race and retry, and only then the Plex Pass /
  Remote Watch Pass explanation (see `data-and-plex.md` → Remote streaming).
- **The requested instance always represents its own server.** An alternate on
  the *same* server is never substituted for it: two items can share a weak
  (heuristic) content key — two guid-less clips both called "Trailer" — and
  swapping them would play a different file, on single-server accounts too.
- **A copy that carries progress plays first.** When the caller passes a
  positive `resumeOffsetMilliseconds`, that instance becomes candidate #0
  regardless of priority (`prefersRequestedInstance`): the offset belongs to
  that copy, and re-resolving by priority is what makes a merged Continue
  Watching row resume server A's copy at server B's position and then split the
  progress across both.
- `PlaybackCoordinator.runPlaybackAttempt` walks those candidates on a **hard**
  failure: details fetch throws, no playable part, transcode decision failure, or
  a nil URL. A soft failure (an engine error mid-stream) stays inside the current
  server and uses the delivery ladder below. Every candidate but the last gets
  only `candidateFetchDeadline` (10 s) for its metadata fetch — enough for a
  sleeping NAS to answer a `checkFiles` request, far less than the full 15 s
  request timeout.
- The initiating offset travels with the walk only where it means something: the
  copy it was measured on uses it unconditionally, and another server's copy
  inherits it only when both runtimes are within
  `resumeOffsetDurationTolerance` (2 %, from `resumeOffsetDurationMilliseconds`
  passed by the caller). Otherwise the fallback server's own `viewOffset`
  decides. A positive `viewOffset` in the candidate's own details always wins.
- A completed local download is always tried first — it needs no server at all.
  If the file on disk turns out not to match the record, the same candidate is
  immediately retried online (`suppressLocalDownload`) instead of ending the
  walk on a download error.
- Explicit version selection (`playVersion`) never leaves its server, and
  neither does SharePlay: `prepareForSharePlay` calls
  `playFromStart(restrictToItemServer: true)`, because the group is watching the
  copy the activity names and the readiness post-check rejects any other server.
- `activePlaybackServerID` is authoritative for the session. Timelines and
  scrobbles go **only** to the server the session is actually playing from —
  never fanned out to the pool, which would corrupt watch state on the others.
  An explicit "Mark as Watched/Unwatched" is the deliberate exception: see
  `PlexService.setWatchedAcrossServers`.
- The Plex Pass message is shown when *every* candidate is restricted, and also
  when the walk exhausted a list that ended in restricted candidates — the
  missing entitlement is a more useful answer than the first server's error.

### Watch State Across Servers

- `PlexService.setWatchedAcrossServers(_:id:)`
  (`Shared/PlexService+WatchedFanOut.swift`) marks an item watched/unwatched on
  the requested instance **and** on every connected server holding a known
  alternate of the same content. Detail screens and item context menus use it.
- The requested instance decides the result (its error is thrown and surfaced);
  the other copies are best effort and never twice per server.
- Removing an item from Continue Watching (`HomeViewModel`) fans out the same
  way and for the same reason: the row shows one copy of a title that may be in
  progress on several servers, and dismissing only that copy makes it come back
  from another server on the next load.
- Those two are the only watch-state fan-outs. Timeline reporting and scrobbles
  during playback stay on `activePlaybackServerID`, because those describe one
  file being played, not a statement the user made about the content.

## Delivery Ladder and Session Hygiene

- The ladder is: direct play → server stream (HLS with `directStream=1`,
  video copied without re-encoding when the profile allows) → error surface.
  It never triggers for local downloads or sessions already on a server
  stream/transcode, and it must not change the direct-play-first startup rule:
  the server rung is entered only on resolver `requiresServerTranscode` or an
  actual direct-play failure. The ladder stays **within one server**; moving to
  another server is the candidate walk above, not a rung.
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
  Remux recovery uses the same loading/error suppression as direct play.
  Cleanup is scoped to the failed presentation: a DV7 retry or return to
  direct play re-arms its own watch, whose flags the outgoing attempt must
  not clear.
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
  TrueHD title (undecodable in stock VLCKit, so routed through the server
  before Dusk's own build) received. AVPlayer decodes AC-3/E-AC-3 in HLS/mpegts natively on
  both platforms. `.airPlay` is deliberately excluded: that rung targets
  whatever receiver the user picked, which is not necessarily AC-3 capable.
  There is deliberately no `aac` channel limitation — capping it would fight
  Plex's decision engine rather than widening what Dusk accepts.

## Automatic Track Languages

- Audio: `defaultAudioLanguage` scopes the pre-start pick
  (`preferredAudioStreamPosition` and friends) and the runtime
  `preferredAudioTrack()`; "" (Original) keeps the part's selected/default
  language and only re-ranks codecs inside it.
- Subtitles: `SubtitleSelectionPolicy` is the one rule for every path — the
  startup pick on Plex metadata (`PlayerViewModel.preferredSubtitleStreamID(inPart:policy:audioStream:)`,
  feeding direct-play routing, remux and AirPlay) and the runtime pick on engine
  tracks (`preferredSubtitleTrack()`, AVPlayer and VLCKit, embedded and sidecar).
  Off = forced only; Auto = full subtitles when the audio is not in the subtitle
  language (Plex's "shown with foreign audio"; the audio preference deliberately
  does not count, so Japanese audio + English subtitles shows subtitles), forced
  otherwise; Always = full subtitles. Full prefers non-forced, non-SDH in the
  subtitle language, falling back to SDH, then forced. Forced looks in the
  subtitle language, then the audio's language, then untagged forced tracks, and
  never appears when Forced Subtitles is off. Untagged/`und` audio counts as
  understood.
- The audio Auto compares against: startup uses the remembered audio, else the
  stream the audio preference opens on; at runtime subtitles can be picked before
  audio (audio waits for steady playback), so `automaticSubtitleAudioLanguage()`
  uses the pending audio pick first. A later manual audio change does not
  re-run Auto.
- A per-show remembered choice (below) is resolved first and always wins.
- `SubtitleSelectionPolicyTests` covers the modes, fallbacks, startup audio,
  legacy-setting migration and the Plex account profile decoding.

## Per-show Track Choices

- Explicit audio/subtitle picker actions and downloaded-subtitle selection save
  `ShowTrackPreferences` in UserDefaults, keyed by active Plex profile ID,
  server machine ID, and the episode's **grandparent** rating key. Seasons share
  the same record. Movies and Live TV never read or write it; no settings UI.
- `ShowTrackDescriptor` matches language (canonical ISO codes/tags) and purpose
  (forced, SDH, commentary, descriptive audio). Codec and channel count break
  ties, then source order. Stream IDs are used only within the active part,
  never persisted. Unknown language or a missing language/purpose match uses
  existing automatic selection. A miss does not erase the saved choice.
- Subtitles have three states: unspecified, explicitly Off, or a descriptor.
  Off overrides forced/default/global subtitles too. Changing audio only keeps
  the independently saved subtitle preference, and vice versa. Automatic picks,
  decoder recovery and rejected-remux fallback never rewrite either preference.
- Startup resolves the preference **before** AirPlay/remux/direct-play decisions
  and VLCKit audio preselection. Local engines receive `ExplicitTrackSelection`;
  remux/AirPlay use the resolved Plex IDs. Up Next and autoplay use the same
  startup path; UserDefaults survives relaunch. PiP re-presentation retains the
  effective selection. Profile changes invalidate in-flight startup and queued
  Plex selection writes.
- Plex's [stream-selection API](https://developer.plex.tv/pms/)
  remembers selections per user/part (`subtitleStreamID=0` means Off), not a rich
  rule for future episodes. Plex's account/show language auto-selection cannot
  express this complete descriptor, so Dusk keeps the per-show rule locally and
  best-effort syncs direct-play choices and resolved episodes through the existing
  `selectStreams` PUT. The existing remux PUT remains mandatory before HLS
  creation (including On → Off → On). All PUTs share a serialized queue in
  `PlexService`; local downloads skip server writes. Per-show preferences are
  device-local; another client can observe the per-part Plex selection, but
  there is no Dusk per-show sync across devices.
- tvOS's existing enhanced-SDR/embedded-subtitle routing receives the resolved
  subtitle ID. Remembered SDR sidecars can start on VLCKit. HDR/DV never gains a
  subtitle-induced VLC route: an unsupported remembered bitmap/ASS subtitle is
  omitted from the HDR remux for that episode, without erasing the preference.
  Remembered audio that cannot be copied is converted by Plex when needed to
  preserve HDR. The existing remux conversion retention and declined-HDR-change
  guard remain in charge of later track changes (the `a310f05` behavior).
- `ShowTrackPreferenceTests` covers semantic matches across IDs/seasons,
  forced/SDH distinctions, codec/channel ties, commentary/description, missing
  matches, Off/relaunch, profile/server/show isolation, movie exclusion and
  SDR versus HDR/DV routing. `PlaybackFallbackTests` also checks that explicit
  Off waits until engine loading has finished before marking it applied.
  Compile with `build-for-testing` to check test sources without executing tests or launching the app.

## Dolby Atmos and Spatial Audio

- Why it exists: VLCKit decodes Dolby audio to plain PCM. That drops Atmos
  objects (E-AC-3 + JOC) and never reaches AirPods spatial audio; there is no
  bitstream passthrough on this libvlc. AVPlayer renders both. MP4/MOV files
  with Dolby audio already play on AVPlayer and need nothing extra.
- Eligibility (`StreamResolver.spatialAudioRemuxBlocker`): the resolver would
  pick VLCKit for direct play (not DV5, not forced engines, setting
  `spatialAudioRemuxEnabled` on), single part, 8-bit H.264 or HEVC video, and
  the audio stream the remux decision is made for
  (`preferredRemuxAudioStream`, which skips TrueHD) is E-AC-3 Atmos — or, on iPhone/iPad only, any 5.1+
  AC-3/E-AC-3 (spatial audio; on tvOS VLCKit already outputs discrete PCM).
  The auto-selected subtitle, if any, must be text (SRT/WebVTT/mov_text):
  bitmap subtitles would be burned in (a video re-encode) and ASS would lose
  styling. HDR video additionally needs `AVPlayer.eligibleForHDRPlayback`:
  Plex declares the remux's only variant `VIDEO-RANGE=PQ`, AVFoundation
  refuses it on an SDR display (`AVErrorNoCompatibleAlternatesForExternalDisplay`,
  e.g. every simulator) and rejects it with CoreMedia -12927 if the attribute
  is removed. VLCKit keeps those files.
- Delivery (`PlexService.spatialAudioRemuxURL`, mode `.spatialAudioRemux`):
  HLS with an fMP4 target first (`container=mp4&videoCodec=hevc,h264&audioCodec=eac3,ac3,aac`;
  AAC is last so audio Plex has to convert still lands on E-AC-3)
  — HEVC in MPEG-TS HLS plays audio-only on AVPlayer — plus a WebVTT subtitle
  target. Plex takes the session subtitle from the part's server-side
  selection, so `requestSpatialAudioRemux` first mirrors the audio/subtitle
  choice with `PUT /library/parts/{id}` (what Plex clients do on a track
  change; always written because the part metadata is a startup snapshot) and
  requests `subtitles=auto` (`subtitles=none` plus an explicit selection of `0`
  for Off). Never compare the requested selection with that stale snapshot.
  The session is accepted only when the decision's streams say video `copy`,
  audio `copy`, and any active subtitle `segments-subs`. A subtitle explicitly
  marked `ignore` is also safe, even with `location=embedded`
  (`TranscodeStreamDecisions.isLosslessRemux`); anything else stops the Plex
  session and keeps plain direct play. It never lowers quality.
- Atmos signaling (`Playback/RemuxHLSLoader.swift`): Plex's fMP4 muxer writes a
  13-byte `dec3` box without `flag_ec3_extension_type_a`/complexity index, so
  AVFoundation sees plain 5.1 E-AC-3 (no `ec+3` layer in the format list).
  For Atmos streams (Plex profile "dolby digital plus + dolby atmos") the
  AVPlayer item is built through `RemuxHLSLoader`, an `AVAssetResourceLoader`
  delegate: playlists and the `EXT-X-MAP` init segment go through it, the
  init segment's `dec3` gets the trailer back (complexity 16), and media
  segments are rewritten to absolute server URLs so they never pass through
  the app. It must not be used for non-Atmos E-AC-3 — the patch asserts JOC.
  MPEG-TS remuxes do not need this (AVFoundation reads the bitstream there).
  `AVPlayerEngine` logs `AVPlayer audio format …, Dolby Atmos: yes/no` from
  the item's format list once ready.
- Session behavior: `PlaybackDecision.spatialAudio`, AVPlayer, Video
  Enhancement off, and server track selection (`usesServerTrackSelection`):
  the pickers list Plex streams. A pick rebuilds the remux around the new
  streams (`scheduleSpatialAudioTrackChange`), or — when the new combination
  cannot ride a lossless remux (TrueHD, AAC, PGS, …) — `leaveSpatialAudioRemux`
  moves to plain direct play at the live position, carrying the choice as an
  `ExplicitTrackSelection` (audio via `:audio-track` preselection, subtitle
  applied once by `PlayerViewModel`). The subtitle rendition in the HLS item is
  switched on by `PlayerViewModel` (`pendingServerSubtitleRenditionSelection`).
  HDR/DV track changes that cannot rebuild the remux retain the loaded AVPlayer
  session and restore its confirmed stream choices, with an error message.
  They never fall back to VLC. `remuxTrackSelection` records the loaded choices
  separately from an in-flight request, including across repeated On/Off picks.
- The same session type carries the undecodable-audio fallback (video copied,
  audio converted by Plex); see "Dolby TrueHD decoding" below. The setting
  gates only the Dolby remux, not that fallback.
- Failure: the direct-play failure watch is armed for remux sessions too; an
  engine error moves the session to plain direct play (VLCKit) at the same
  position instead of surfacing an error.
- AirPlay: selecting a route rebuilds a remux session as AirPlay HLS, like
  direct play, because the fMP4/HEVC remux targets this device.

## Dolby Vision Profile 5

- Why: DV5 has no HDR10/SDR base layer (IPTPQc2 color). libvlc shows it
  green/purple, and the server stream asks Plex to transcode 4K DV5 to H.264,
  which fails on most servers. Apple's decoders render DV5 natively from MP4
  (what Infuse does) when the track is labelled `dvh1` and carries `dvcC`.
- Delivery: DV5 media (`StreamResolver.isDolbyVisionProfile5`) goes through
  the same video-copy fMP4 remux as Atmos (`requestSpatialAudioRemux`, session
  type `.spatialAudio`), independent of the spatial-audio setting. Eligibility
  is `StreamResolver.dolbyVisionRemuxBlocker`: single part, HEVC, an HDR
  capable display (`AVPlayer.eligibleForHDRPlayback`, same PQ-variant reason as
  above), and a text subtitle if any (the startup pick drops a bitmap one
  rather than burn it in). Audio the fMP4 cannot carry (TrueHD, DTS) is
  converted by Plex (`convertsAudio`); E-AC-3/AC-3/AAC is copied.
- Signaling (`DolbyVisionSignaling` in `RemuxHLSLoader.swift`): Plex labels the
  copied track `hvc1`. The loader renames the sample entry `hvc1`→`dvh1`
  (`hev1`→`dvhe`), appends a `dvcC` (`dvvC` for profile > 7) built from Plex's
  `DOVIProfile`/`DOVILevel`/`DOVIBLCompatID` when the entry has none, and
  rewrites the HEVC entry of `EXT-X-STREAM-INF` `CODECS` to `dvh1.PP.LL`. The
  Atmos `dec3` patch runs only when the audio is Atmos
  (`PlaybackSource.restoresDolbyAtmos`); the DV patch only with
  `PlaybackSource.dolbyVisionRemux`.
- tvOS display matching requests a `dvh1` / PQ / BT.2020 mode for these
  sessions (DV5 streams carry no usable color tags).
- Ladder: remux declined → server stream → direct play (VLCKit). A remux that
  fails after starting goes to the server stream, not VLCKit.
- Not yet verified against a real PMS: whether Plex already writes `dvcC` or
  `dvh1` itself (the patch then changes nothing) and whether it keeps the RPU
  NAL units on copy. Picking an unsupported subtitle mid-session keeps the
  working remux and reports that the track change could not preserve HDR.
  PMS logs (2026-10) confirmed an Off rebuild returning
  copied video/audio plus `ignore/embedded` for the previous SRT. Rejecting that
  harmless subtitle decision used to drop DV5 into VLC and produce pink video.
- Verified (2026-09) against PMS 1.43.4 on tvOS/iPadOS simulators and a macOS
  AVPlayer harness: H.264 and HEVC/DV8 MKV remuxes copy both tracks, the
  patched init exposes the `ec+3` layers (7.1.4/9.1.6), WebVTT subtitles
  render, seeking works, and the fallback paths engage. Atmos output itself
  (HDMI receiver, AirPods) needs real hardware.

## HDR Video and Dolby Vision 8 (HDR Remux)

- Why: VLCKit 3 renders into an untagged 8-bit RGBA surface on iOS/tvOS (see
  "Display Mode Matching"), so an HDR MKV never shows HDR there — not HDR10,
  not the "HDR10 base" of Dolby Vision 7/8, no HDR10+ dynamic metadata, no
  HLG. Only AVPlayer/VideoToolbox output real HDR on Apple devices.
- Eligibility (`StreamResolver.hdrVideoRemuxBlocker`, setting
  `hdrVideoRemuxEnabled`, default on): the resolver would pick VLCKit for
  direct play (not DV5, not forced engines), single part, all video HEVC,
  HDR video (`isRemuxableHDRVideo`: PQ or HLG `colorTrc`, or DV 7 / 8.1 /
  8.4 / 8.6 by base-layer compatibility ID when the TRC is missing; 8.2 has
  an SDR base and is not HDR), `AVPlayer.eligibleForHDRPlayback`, a text
  subtitle if any, and audio Plex can **copy** (E-AC-3/AC-3/AAC). DTS,
  FLAC, PCM & co. keep VLCKit: converting a lossless track to keep the
  picture would lower audio quality, and the remux never lowers quality.
  DV7 + TrueHD is the picture-priority exception: request converted E-AC-3
  audio up front and keep DV7 → 8.1 on AVPlayer. Other TrueHD-only files
  use local lossless decoding on Dusk's VLCKit build. TrueHD with a copyable
  sibling remuxes the sibling (see "Dolby TrueHD decoding").
- Delivery and acceptance are the Atmos remux's
  (`requestSpatialAudioRemux`, session type `.spatialAudio`, lossless only,
  any failure → plain direct play). A file can qualify for Atmos, HDR or
  both; the session reason names what qualified, e.g. `Dolby Atmos + Dolby
  Vision 8.1 via lossless Plex remux`. A declined track change (e.g. DTS audio)
  keeps the working HDR remux and its previous tracks instead of moving to VLC.
- Formats:
  - **HDR10 / HLG**: no signaling needed; the copied HEVC carries its VUI.
  - **HDR10+**: the ST 2094-40 SEI rides the copied bitstream and AVPlayer
    forwards it (Apple TV 4K 3rd gen and later, HDR10+ TV). Plex metadata
    does not distinguish HDR10+, so these read as HDR10 everywhere in Dusk.
  - **Dolby Vision 8.1 / 8.4** (`DolbyVisionSignaling`, profile 8 path): the
    track stays `hvc1` (the base layer remains decodable everywhere) and
    gains a `dvvC` box built from Plex's `DOVIProfile`/`DOVILevel`/
    `DOVIBLCompatID`. The variant keeps its HEVC `CODECS` entry and gains
    `dvh1.08.LL/db1p` (`/db4h` for 8.4) in `SUPPLEMENTAL-CODECS` (merged:
    other supplemental codecs are kept, an existing DV entry is replaced),
    with `VIDEO-RANGE` set explicitly to `PQ` (8.1) or `HLG` (8.4) because
    Apple requires it to match the brand. Attributes are parsed by full
    name (`HLSAttributeList`), so `CODECS` never matches inside
    `SUPPLEMENTAL-CODECS`. This is Apple's backward-compatible packaging: a
    DV display gets real Dolby Vision, anything else the base layer. It
    applies to every remux session of an 8.1/8.4 file (HDR, Atmos,
    converted audio) while the HDR setting is on. Only `hvc1` is signalled:
    Apple requires it for 8.4, and a `hev1` entry (in-band parameter sets)
    cannot honestly be renamed, so a `hev1` variant and its init segment are
    left as plain HEVC. (DV5 renames `hev1` to `dvhe` and declares `dvhe.05.LL`
    to match.)
  - Level cap: tvOS 27 refuses a DV master declaring level 5.2 (`L156`)
    with -11848 although the same 4K24 stream declared 5.1 plays with DV
    engaged (AetherEngine #674; encoders often over-declare). The declared
    level is lowered to `L153` only when Plex's metadata proves the content
    fits 5.1 for the declared tier (picture size, luma sample rate, average
    bitrate ≤ 40/160 Mbit/s Main/High); otherwise, or with metadata missing,
    the source's level stays. It is not OS-gated, because a declaration the
    content satisfies is truthful everywhere. A wrong guess (peaks above the
    average) costs one decoder error, which the failure watch turns into
    VLCKit direct play — the same outcome as an uncapped refusal.
  - **Dolby Vision 7** (FEL/MEL, dual layer): converted to 8.1 on device
    while `dolbyVision7ConversionEnabled` is on — see "Dolby Vision 7
    (on-device 8.1 conversion)" below. With the setting off, or after a
    failed conversion, it rides the remux unsignalled and plays its HDR10
    base layer on AVPlayer (EL/RPU NALs are ignored).
- Turning `hdrVideoRemuxEnabled` off restores the previous behavior exactly:
  no HDR-only remux, and no profile 8 signaling on Atmos/converted-audio
  remuxes.
- Unverified without real hardware/PMS: whether Plex already writes
  `dvvC`/`SUPPLEMENTAL-CODECS` itself (the patch then leaves them alone),
  whether Plex declares `VIDEO-RANGE=HLG` for plain HLG sources, that the
  RPU is actually applied (an L2-trim test clip pulses visibly), HDR10+ on
  an HDR10+ TV, and the level cap on 4K60 and high-bitrate sources.

## Dolby Vision 7 (on-device 8.1 conversion)

- Why: profile 7 (UHD Blu-ray, base layer + MEL/FEL enhancement layer) has
  no Apple decoder, and its RPU is not valid as 8.1 without per-frame
  rewriting. Converting it the way dovi_tool mode 2 does (drop the EL, rewrite
  every RPU as 8.1) gives a single-layer stream Apple plays as real Dolby
  Vision. FEL detail is lost, as with every player that does this.
- Gate (one place: `PlaybackCoordinator.remuxDolbyVision7Conversion`): any
  `.spatialAudio` remux (HDR, Atmos or converted audio) of a file whose HEVC
  video is profile 7 (`StreamResolver.dolbyVision7ConversionStream` /
  `dolbyVision7ConversionTarget`), while `hdrVideoRemuxEnabled` and
  `dolbyVision7ConversionEnabled` are on and the conversion has not failed for
  this item (`isDolbyVision7ConversionSuppressed`, reset at the top of
  `startPlaybackSession`, never by replacement attempts). The result is
  `PlaybackSource.dolbyVision7Conversion` (8.1, compat ID 1, source level,
  `convertedFromProfile = 7`); `DisplayModeMatcher` gets it in place of
  `dolbyVisionRemux`. VLCKit taking over a remux URL never converts.
  `StreamResolver.dolbyVisionSignalingStream` still excludes profile 7.
- Picture-priority startup: when the remux audio pick is TrueHD/MLP,
  `convertedTrueHDRemuxBlocker` qualifies DV7 for AVPlayer, regardless of
  whether VLCKit can decode TrueHD. The demo clips `DV P7 MEL - Hybrid
  HDR10 TrueHD Atmos (2020)` (7.1/48 kHz) and `DV P7 MEL - Hybrid HDR10+
  TrueHD 5.1 (2020)` (5.1/96 kHz, forced SRT) have this combination. The
  request chooses audio conversion before contacting Plex: video copied,
  E-AC-3 surround, then DV7 → 8.1 on device. It never first loads TrueHD
  into AVPlayer or waits for a local decoder failure. Before loading the
  engine, acceptance requires MP4, copied H.264/HEVC, converted E-AC-3,
  and 6 or 8 output channels for a surround source. The profile allows 7.1;
  current PMS commonly encodes 5.1. Only output E-AC-3 Atmos metadata
  authorizes restoring JOC; a TrueHD Atmos input must not turn ordinary
  DD+ into falsely signalled Atmos. Existing JOC signaling is preserved.
  The HDR/display/subtitle gates still apply; turning conversion off keeps
  the HDR10 base-layer remux. DV7 with copyable AC-3/E-AC-3 stays lossless,
  and non-DV7 TrueHD-only files stay on local decoding.
- Proxy architecture: after Plex confirms the remux, `AVPlayerEngine`
  starts a `DolbyVision7HLSProxy` for the source instead of
  `RemuxHLSLoader` (`usesRemuxHLSLoader` is false with a conversion) and
  hands AVPlayer `http://127.0.0.1:<port>/<token>/master.m3u8`:
  - Proxy (`Playback/DolbyVision7/DolbyVision7HLSProxy.swift`,
    `HLSProxyHTTP.swift`): Network.framework listener bound to the loopback
    interface, local-only, random 128-bit path token (wrong token → 403),
    every relayed URL must share the master playlist's scheme/host/port
    (→ 403, never an open relay). GET/HEAD, single byte ranges (206/416),
    `Connection: close`, `Cache-Control: no-store`. Routes: `master.m3u8`
    (cached from preflight), `v/<b64url>.m3u8` video playlists,
    `p/<b64url>.m3u8` rendition (subtitle/audio) playlists, `i/<b64url>.mp4`
    init segments (converted once, cached with their `FMP4InitInfo`;
    concurrent first requests share one fetch), `s/<init id>/<b64url>.m4s`
    media segments (fetched, converted, never cached; at most two at once).
    Upstream non-2xx is forwarded, network errors are 502, and a player
    hanging up (seen as end of stream on a read kept pending after the
    request head) cancels the fetch and conversion behind it: the detached
    conversion task is cancelled with the request, `FMP4FragmentRewriter`
    stops between samples, and an abandoned request never runs the RPU
    check or reports a fatal error (a seek must not drop playback to
    HDR10). Logs never carry the token or upstream query strings.
  - Upstream (`URLSessionHLSUpstreamFetcher`, one shared delegate-based
    session): bodies are received incrementally against a per-kind limit —
    playlists 16 MiB, init segments 4 MiB, media segments 256 MiB (≥ 16 s
    at UHD Blu-ray's 128 Mbps ceiling; Plex cuts copied video at keyframes,
    so a segment is at least a GOP) — and a declared `Content-Length` over
    it fails before any byte. Redirects are followed only on the master
    playlist's origin; any other is refused (`HLSUpstreamFetchError`). For
    video (master/variant playlists, init, segments) either is fatal → the
    unconverted remux, which AVPlayer streams from the server itself; a
    rendition playlist only fails its own request (502).
  - Connections: a request head must arrive within 10 s of accept (no
    deadline after that, so a request waiting on a fetch or a segment slot
    is never cut), and at most 16 connections may wait for their head; a
    new one over the cap evicts the oldest waiting one, so a local client
    without the token cannot pile them up or lock AVPlayer out (its heads
    arrive immediately).
  - Playlists (`DolbyVision7PlaylistRewriter`): `SUPPLEMENTAL-CODECS=
    "dvh1.08.LL/db1p"`, `VIDEO-RANGE=PQ`, level cap as for DV8; I-frame
    playlists dropped; WebVTT renditions (no `EXT-X-MAP`) keep their segment
    URLs on the server. Video is strict: a variant playlist without
    `EXT-X-MAP`, a segment ahead of the first `EXT-X-MAP` of any fMP4
    playlist, or a variant/init/segment URI off the server's origin throws
    `.unsupportedPlaylist` (fatal → ladder) instead of passing through, so an
    unconverted profile 7 sample never plays behind 8.1 signaling.
  - Init (`DolbyVision7InitRewriter`): one `hvc1`/`dvh1` video track becomes
    `hvc1` + an 8.1 `dvvC`; the Atmos `dec3` patch (`EAC3JOCSignaling`) runs
    here too when `restoresDolbyAtmos`.
  - Segments (`FMP4FragmentRewriter` + `DoviBridgeSampleRewriter`): every
    video sample goes through the Rust bridge (`Native/DuskDovi`, libdovi
    `ConversionMode::To81`): NAL 63 (EL) dropped, NAL 62 (RPU) rewritten;
    `trun` sizes and data offsets are rebuilt, `sidx` dropped, audio bytes
    copied. Before anything is allocated, a fragment's runs share one
    budget: at most one sample per mdat byte and 2^20 samples in all, and
    sample bytes summing to no more than the mdat payload (runs never
    overlap), so a crafted `moof` cannot multiply memory or output.
    Zero-size samples stay legal (ISO BMFF allows them) and count against
    the sample budget.
- Preflight (`DolbyVision7HLSProxy.start()`): listener ready, master has a
  variant that takes 8.1 signaling, its media playlist passes the same strict
  video rewrite AVPlayer will get (fMP4 throughout, no byte ranges or
  encryption, everything on the server), and the init segment converts.
  Segment 0 is not prefetched.
- Fallback ladder:
  1. Preflight failure fails the load; a segment that cannot be converted, a
     video segment with samples but no RPU, or a listener that dies twice
     calls `onFatalError` (once), which sets the engine to `.error` for the
     same attempt; AVPlayer item failures (e.g. -11848) do the same.
  2. The failure watch (armed for `.spatialAudio`) runs
     `performDirectPlayServerStreamFallback`, whose first branch sets
     `isDolbyVision7ConversionSuppressed` and calls
     `retryRemuxWithoutDolbyVision7Conversion`, which queues
     `rebuildSpatialAudioSession(transitionLabel:declineReason:)` on
     `spatialAudioTransitionTask` (behind any track-change rebuild in flight;
     one that already replaced the failed engine counts as the retry): a
     fresh Plex remux (old transcode session stopped) at the live position,
     now without conversion — the HDR10 base layer through `RemuxHLSLoader`.
     When the rebuild cannot start at all (its guard fails), the branch falls
     through to the normal remux-failure rung below instead of leaving the
     error overlay up.
  3. Plex declining that, or the unconverted remux failing as well, leaves
     the remux for direct play (VLCKit) like any failed remux. The flag stops
     a loop.
- Setting: `dolbyVision7ConversionEnabled` ("Dolby Vision 7 → 8.1", default
  on, disabled while "HDR & Dolby Vision" is off). Off restores the HDR10
  base-layer remux exactly.
- AirPlay: a receiver cannot reach 127.0.0.1. Remux sessions already become
  Plex AirPlay HLS on a route change (see "AirPlay"), so the proxy is never
  handed to a receiver on purpose. tvOS has no background playback; on iOS
  the listener is re-created once (same port) if the system tears it down
  while backgrounded, then the ladder takes over.
- Unverified (no real PMS/hardware yet): that Plex copies NAL 62/63 into the
  fMP4 for single-track BL+EL MKVs (dual-track MKVs carry no EL at all —
  harmless), that Plex never writes its own `dvcC`/`dvvC`/`dvh1` for profile
  7, AVPlayer behaviour with a loopback HLS source on device, sustained CPU
  and memory on 4K FEL, and listener survival across iOS backgrounding.
- Manual hardware checklist (Apple TV 4K + a Dolby Vision TV; iPhone/iPad
  for the iOS parts). Log categories: `DolbyVision7` (proxy, init, first
  segment stats, fatal errors), `SpatialAudio` (remux request/acceptance),
  `PlaybackSession` (attempts, retry label), `AVPlayerEngine` (preflight,
  item failures), `DisplayMode`.
  - DV7 **FEL** MKV and DV7 **MEL** MKV: the TV shows its Dolby Vision badge;
    the session reason (Playback Info) names "Dolby Vision 7 → 8.1" and
    Display Mode reads "Dolby Vision 8.1 (from profile 7)"; the first-segment log shows RPUs ≈ samples
    and EL NALs dropped (FEL and MEL).
  - Audio: E-AC-3 Atmos (receiver shows Atmos), AC-3; DV7 + TrueHD-only
    starts on the converted-audio remux with real DV, on custom and stock
    VLCKit builds. Plain converted DD+ must not be labelled Atmos.
  - DV display mode switch on the TV (Match Content on).
  - Seeking: scrub forward/back, skip ±10 s, resume from a saved position.
  - WebVTT subtitles on and switching tracks (rebuilds the remux, conversion
    stays).
  - Setting off → the same file plays as HDR10 (no DV badge); "HDR & Dolby
    Vision" off disables the toggle.
  - Fallback: a file Plex delivers without RPUs (or a forced fatal error) →
    one retry log line "retrying the remux without Dolby Vision 7 conversion",
    playback continues as HDR10 at the same position.
  - iOS: AirPlay mid-session, background/foreground, Picture in Picture.

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

## SharePlay (iOS/iPadOS and tvOS)

- SharePlay is coordinated playback, not screen mirroring. Every participant
  runs Dusk and resolves the shared Plex item with their own Plex account/token;
  Group Activities carries only the hosting server identifier, rating key, and
  display metadata. Playback URLs and Plex tokens are never shared.
- `DuskWatchTogetherActivity` identifies content by server identifier + rating
  key. That same stable value is the AVFoundation playback-item identifier, so
  participants may independently use AVPlayer, VLCKit, a completed download,
  direct play, or a per-user Plex HLS stream without breaking synchronization.
- `PlaybackSharePlayController` owns the `GroupSession` listener, activation,
  join/leave lifecycle, participant state, incoming activity handling, and
  engine attachment. An invitee who has the hosting server connected resolves the
  item on that server through `pool.connection(for:)`; nothing about the
  invitee's own session changes. The preparation plays with
  `restrictToItemServer: true` so the invitee's own server priority cannot move
  the session to another copy — the readiness check compares
  `activePlaybackServerID` against the activity and would otherwise tear the
  session down as if the item were unavailable. Missing authentication is retryable
  after sign-in; an account without server access gets a clear failure.
  Session/activity listeners stay responsive while a separate cancellable
  worker resolves Plex playback. It drains the latest activity, never republishes
  an incoming item's local metadata, and cannot commit an engine after its
  session is left/replaced. Repeated attachment of an unchanged session is ignored.
- SharePlay lives in the player gear menu on iOS/iPadOS. The tvOS play bar has
  no SharePlay control; an Apple TV only joins a session started elsewhere.
  The action checks `GroupStateObserver`: an eligible
  conversation uses `activate()`, otherwise iOS/iPadOS presents Apple's
  `GroupActivitySharingController` to invite participants/start a call. tvOS
  explains how to start a call or continue from iPhone/iPad when ineligible.
  Activation errors and a result that creates no local session are surfaced.
  `PlayerSharePlayPresentation` hosts invitations/errors on `PlayerView` while
  its full-screen cover is open, and account-related errors on `ContentView`
  otherwise. Invitations are presented directly as UIKit modals from an anchor
  in the player. Never embed the self-dismissing system controller inside a
  SwiftUI `.sheet`: cancelling can dismiss the enclosing player cover too.
  System completion/interactive dismissal clears only the invitation request;
  receiving a session does not race the system by dismissing the picker again.
  Presenting errors from the covered root silently hides them.
- AVPlayer uses its native `AVPlayerPlaybackCoordinator` with an explicit item
  identifier delegate. VLCKit uses `AVDelegatingPlaybackCoordinator`; local UI
  play, pause, and seek requests go through the coordinator, while delegate
  commands apply directly to libvlc and honor the supplied host-clock start.
  This permits mixed AVPlayer/VLCKit groups.
- Engine attachment is idempotent for the same engine/item/session. Initial
  activity publication must not reattach an already connected engine: VLCKit's
  configuration resets pending coordinated transport commands.
- Engine replacements for Quality, AirPlay preparation, and automatic delivery
  fallback reconnect to the existing group without changing its activity.
  Normal library item changes and Up Next update `GroupSession.activity`, which
  makes every participant prepare the next server-scoped rating key before the
  playback coordinators match its group state.
- Dismissing playback or reaching the final item leaves the group locally.
  Leaving SharePlay does not stop local playback. Temporary iOS hold-to-2x is
  disabled while SharePlay is active because it is a local convenience rather
  than a group transport command.
- Plex Live TV is intentionally unavailable to SharePlay. Each independently
  tuned Plex session owns a different sliding DVR window, so equal engine times
  do not guarantee equal broadcast moments. A stable shared timeline would
  require a separate live-specific synchronization design.
- `Dusk.entitlements` declares `com.apple.developer.group-session`; the app ID
  and provisioning profiles used for device/archive builds must also have the
  Group Activities capability enabled in the Apple Developer portal.

## Manual Transcoding
- Playback never starts with video transcoding because of a stored quality
  preference. `maxResolution` only chooses among existing Plex media versions.
- Quality is in the player gear menu on iOS and the Quality tab of the tvOS
  settings panel. `Original` means the
  current media version direct-plays; non-original presets manually request
  Plex HLS transcoding. Transcode choices are filtered against the active
  original media version so the menu only offers presets below its resolution
  and bitrate.
- `PlaybackCoordinator.switchQuality(to:)` snapshots the current engine time,
  asks `PlexService.transcodeURL(...)` for `/video/:/transcode/universal/decision`
  and `/video/:/transcode/universal/start.m3u8`, swaps the engine/source, and
  resumes from the same position without finalizing or scrobbling the session.
- iOS trap: every player sheet (Quality, Audio, Subtitles, Get Info) turns
  off the space-bar shortcut view (`PlayerKeyboardShortcutView`), which
  resigns first responder. That resign must stay deferred and change-only:
  done synchronously inside `updateUIView` it re-enters the SwiftUI
  transaction through `_UIHostingView.canBecomeFirstResponder` and froze the
  app on iOS 27 the moment a sheet opened (issue #25, "quality fails to set").
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
  the fallback when a part carries no stream metadata). Hi10P routes to VLC;
  Dolby Vision profile 5 requires a server remux/transcode. AV1 is evaluated
  **before** container and forced-engine preferences (see below).
- Force preferences override the other codec/container checks.

### AV1 (1.8)

`StreamResolver+AV1.swift` owns the AV1 policy. `AV1PlaybackCapabilities.current`
queries `VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)` and the loaded
VLCKit binary's dav1d symbols. Never infer hardware decode from platform or
simulator model names. A17 Pro/M3-class devices support it; older A12/A15
Apple TVs generally do not, while the announced A19 Apple TV does.

| Capability / source | Delivery | Engine |
| --- | --- | --- |
| Hardware AV1, compatible MP4/MOV/M4V tracks | Original file | AVPlayer |
| Hardware AV1, MKV or incompatible native tracks | Plex fMP4 video copy; audio copied or converted to E-AC-3 | AVPlayer |
| No hardware AV1, dav1d present, recent device, SDR ≤1920×1080, ≤30 fps, ≤20 Mbps | Original file | VLCKit |
| HDR without hardware decode, older device, missing decoder, unknown dimensions, above software budget, or failed local/remux playback | Uncapped Plex HEVC/H.264 conversion | AVPlayer |

The software budget starts at iPhone13,* (A14), iPad13,* (A14/M1), and
AppleTV11,* (A12). It is conservative policy, not an on-device benchmark.
Explicit SDR transfer metadata permits 10-bit SDR; missing color metadata on
10-bit media is treated conservatively. AV1 HDR/DV never enters VLC, including
forced engines, enhanced subtitles, sidecar mounts and remux failure recovery.
Unsupported AV1 downloads report that an online conversion is needed.

Hardware MKV delivery reuses `requestSpatialAudioRemux` and `.spatialAudio`:
AV1 is added to the fMP4 target only on a hardware-capable client, independently
of the Atmos/HDR preferences. Acceptance requires MP4, AV1 **video copy**, the
expected audio copy/conversion and segmented text subtitles. HDR10/HLG OBUs
and static HDR metadata remain in the copied AV1 bitstream; no HEVC Dolby Vision
patch is applied. A declined remux falls through to video conversion, never a
known-unplayable direct file. Bitmap/styled subtitle selections may require
video conversion. Playback Info identifies AV1 and distinguishes remux from
video conversion.

`TranscodeDeliveryMode.av1Transcode` disables direct stream, advertises only
HEVC/H.264 output and imposes no app bitrate/resolution cap. Plex picks the
codec its transcoder supports (including SDR tone mapping when required).
Decision validation rejects copied AV1 and incompatible containers. Track
pickers use Plex stream IDs for both remux and AV1 server-conversion sessions;
changes rebuild the session at the current position. Failed replacements keep
the current session and release the rejected server session.

Verification: `AV1RoutingTests` injects hardware, software-only, old-device and
missing-decoder capabilities, plus HDR, frame rate, size and selected-track
request cases. `scripts/create_av1_demo_samples.sh` creates silent 1080p MKV,
MP4 and 4K HDR10 MKV fixtures (two audio languages and an SRT sidecar for SDR).
Refresh/analyze the plex-demo Movies library after generating them. Simulator
playback validates software decode/server conversion; hardware AV1 and HDR
output fidelity require a physical capable device. Plex decision/master/init
inspection can separately confirm AV1 video copy and retained PQ/HLG metadata.

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
- `applySubtitleFontSize(_:)` is called by the coordinator right after the
  engine is built and before `load(source:)`, so per-media options can carry the
  size, and again by `PlayerViewModel.selectSubtitleFontSize` when the in-player
  picker changes it. The protocol extension no-ops; both real engines implement
  it.
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
- `supportsExternalSubtitles` / `attachExternalSubtitle(_:select:)` mount a Plex
  sidecar subtitle on the media that is already playing. VLCKit adds it as a
  libvlc playback slave and reports the resulting track back with its
  `externalURL` set; AVPlayer cannot attach one to a live item and keeps the
  protocol-extension defaults (`false` / no-op). See "External (sidecar)
  subtitles".
- Engine tracks carry `isDecodable`. A stock VLCKit build cannot decode
  TrueHD/MLP, and Dusk's TrueHD decoder can fail on a stream (see "Dolby
  TrueHD decoding" below).
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
  DTS/TrueHD audio (TrueHD with Dusk's own VLCKit build only), bitmap/complex
  subtitles, and other VLC-only combinations.
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
- Language matching canonicalizes ISO 639-2 Plex/VLCKit codes onto the ISO 639-1
  values stored in Settings (`rum`/`ron` → `ro`, `eng` → `en`) via
  `PlayerViewModel.normalizedLanguageCode`. Do not compare raw stream codes to
  preference codes. Romanian audio and subtitle defaults live in `CommonLanguage`
  with the other picker languages.
- Subtitle engines retain the requested selection separately from the reported
  selection, including an explicit Off choice. Same-source stall recovery must
  restore that intent: the view model's one-shot automatic selection has already
  run and will not select again after the engine rebuilds its input/item. A new
  source or stop clears the intent.
- VLCKit reconciles subtitle selection on time ticks and track/state refreshes,
  even when track counts have not changed. Early choices wait for the resume
  seek to settle and advancing playback (or a paused player); dropped or
  overridden selections get at most five writes, at least 0.5 s apart, per
  request/input rebuild. Do not gate this on `isBuffering`, and do not assume
  the setter succeeded: VLCKit discards libvlc's selection error result.
- AVPlayer restores subtitles using the option's property-list identity in the
  replacement item's group, then reapplies after the initial resume seek.
  Asynchronous track discovery must check the current item before publishing
  results, so an old item's groups cannot replace the live selection mapping.
- Local subtitle picker checkmarks come only from the engine's reported
  selection. Plex's saved `isSelected` flag must not imply a locally active
  subtitle or override Off. AirPlay keeps its server-owned selection path.
- `mergeSubtitleMetadata` merges from two disjoint pools. Embedded engine tracks
  are matched against the part's embedded streams (`key == nil`) by the fuzzy
  scorer; a sidecar stream (`key != nil`) only ever labels the track the engine
  says it mounted from that exact URL. The invariant is unchanged: an external
  stream must never relabel an embedded engine track with metadata the engine
  cannot render.
- Codec desirability is platform-aware (`platformAudioCodecAdjustment`): on
  tvOS lossless bitstreams (TrueHD/MLP, DTS-HD, PCM) rank top — they decode
  to multichannel LPCM over HDMI — while iPhone/iPad demote them below lossy
  surround (E-AC-3/AC-3/DTS), because the phone outputs a stereo/binaural
  downmix either way and lossless only costs decode CPU, battery, and
  streaming bandwidth. Ranking is relative, so a lossless-only file still
  plays natively, and the pickers can always select any track manually.
- Selection only considers `selectableAudioTracks` (decodable tracks): ranking
  by desirability used to steer playback onto a TrueHD track a stock VLCKit
  cannot decode, which is what actually broke Bluray-remux audio.
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

### External (sidecar) subtitles
- Plex sidecars (`PlexStream.key != nil`, `/library/streams/{id}`) come either
  from the library itself or from the OpenSubtitles download the server performs
  (`PlexService+Subtitles.swift`). `PlexService.externalSubtitleURL(for:)` turns
  one into a token-bearing URL.
- VLCKit mounts them: `attachExternalSubtitle(_:select:)` queues the URL and
  `addPlaybackSlave(_:type:enforce:)` adds it. libvlc returns 0 on success, not
  a track id, so slaves are added ONE AT A TIME and the newly appeared SPU
  elementary-stream index (anything outside the set captured before the first
  slave) is attributed to the slave currently in flight. That ordering is what
  makes the URL → track mapping work; do not parallelize it.
- Slaves live on the input, not on the media, so every in-place reopen (stall
  recovery, the subtitle size restyle, the PiP support-mode swap) drops
  them. `VLCKitEngine` re-queues its attachments on reopen, re-captures the
  container's own SPU indexes, and restores an active external selection once
  the slave is back (the stale ES index is cleared first — after a reopen it may
  belong to an embedded track).
- `PlayerViewModel.attachExternalSubtitlesIfNeeded` mounts the part's sidecars
  only once the engine reports `.playing`/`.paused`. Never before `load`:
  fetching a sidecar must not sit in front of playback starting.
- AVPlayer sessions list sidecars as `requiresEngineSwitch` placeholders
  ("External · switches to VLC engine", ids from
  `externalSubtitlePlaceholderIDBase`). Selecting one calls
  `PlaybackCoordinator.switchToVLCKitForExternalSubtitle(streamID:)`, which
  reuses `activateReplacementAttempt` with the same URL/media/decision and only
  swaps the engine, resuming at the live position. Local downloads switch too;
  their sidecars mount from the saved copies (see `downloads-and-offline.md`). Automatic selection never
  picks a placeholder — swapping engines is the viewer's call. It can pick a
  mounted sidecar: the one-shot automatic choice is re-evaluated exactly once
  after an external track appears, and never after the viewer has chosen.
- After a download, `PlaybackCoordinator.refreshSubtitleStreamsAfterDownload`
  refetches `getMediaDetails`, replaces `activeItemDetails` and the
  `debugInfo.part` snapshot the player configures from, diffs the subtitle
  stream ids to find the new one, and then either bumps
  `externalSubtitleRefreshToken` (VLCKit mounts it in place), restarts on VLCKit
  (AVPlayer), or hands the id to Plex (AirPlay burns it in).
- The user-facing flow is "Download Subtitles" (`SubtitleSearchView` /
  `SubtitleSearchViewModel`, `Features/Player/`): pick a language, Plex searches
  OpenSubtitles, the chosen result is installed server-side. From the player it
  then calls `refreshSubtitleStreamsAfterDownload()` so the new sidecar reaches
  the live session; from a detail screen there is no session to refresh, so the
  detail model just re-reads the item and the next playback mounts it.
- AirPlay/server-rendered sessions need none of this: external streams are
  already listed by `syncTrackLists`'s server branch and selecting one just
  passes `subtitleStreamID` to the transcode decision, which burns it.

### Subtitle character sets, fonts, and direction
- Known text sidecars carry their Plex codec into `attachExternalSubtitle`.
  `SubtitleFileStore` downloads the original bytes asynchronously, then
  `SubtitleTextDecoder` recognizes Unicode BOMs/strict UTF-8 before using
  Foundation's whole-file legacy encoding detector without lossy conversion.
  A system Russian-language confidence check resolves the detector's observed
  KOI8-R → ISO-8859-5 ambiguity. Automatic legacy detection remains heuristic;
  short or ambiguous files can still require fixing the source encoding.
- VLC mounts a temporary UTF-8 file with a BOM and the correct format suffix.
  ASS/SSA headers, fonts, positioning, inline markup, logical RTL order, and cue
  timing are preserved. The original Plex URL remains the attachment identity
  used by track matching. Files survive media reopens and are removed when the
  session's store is released. Fetch/decode failures retain original VLC
  delivery; they never block video startup or log token-bearing errors.
- Text formats currently normalized: SRT/SubRip, ASS/SSA, WebVTT, MicroDVD,
  SubViewer, and SAMI. VobSub/PGS and unknown codecs bypass preparation entirely.
  Never classify `.sub` by extension: it can contain text **or** bitmap data.
- Do not force `subsdec-encoding=UTF-8` on the shared VLC library: that also
  affects unnormalized inputs. libvlc 3.x only auto-detects UTF-8, with a
  Windows-1252 fallback in this nonlocalized build. Container tracks declare
  their own encoding (including UTF-8 Matroska text and UTF-8/UTF-16 tx3g).
- Plex documents `/library/streams/{id}?encoding=utf-8`, but this is not a
  reliable replacement for source detection. On the demo server (2026-10-17),
  the generated Windows-1251, Windows-1256, and ISO-8859-2 samples returned
  valid UTF-8 containing wrong characters. KOI8-R, GB18030, Big5, Shift-JIS,
  Hebrew, Greek, Thai, and mixed UTF-8 converted correctly. Dusk deliberately
  fetches original sidecars instead.
- There is no Dusk text overlay. Both vendored VLC frameworks include FreeType's
  CoreText family/fallback selectors, FriBidi and HarfBuzz; libass auto-selects
  the Apple font provider and honors embedded fonts. Helvetica Neue stays the
  libvlc family for the system caption face, with automatic paragraph
  direction. AVPlayer renders tx3g/WebVTT and Plex remux captions natively; its
  text style rules set only size, leaving style, font fallback and direction
  to Apple (see "System caption style" below).
  AirPlay/burned captions are rendered by Plex. No Latin typography changes or
  bundled replacement font are needed for encoding correction.
- `scripts/generate-subtitle-fixtures.py <directory>` creates mixed-script
  SRT/ASS/WebVTT, legacy-encoded SRT/ASS/MicroDVD, and an expected-text manifest
  without contacting Plex or launching a player. `SubtitleTextDecoderTests`
  covers the legacy fixtures, Unicode BOMs, unchanged logical RTL/Latin text,
  ASS markup, and bitmap/unknown-codec passthrough. Compile checks do not verify
  actual glyph rasterization, shaping, or on-device playback.

### Dolby TrueHD decoding (TrueHD/MLP)
- Dusk ships its OWN MobileVLCKit/TVVLCKit 3.7.3 build
  (`ci_scripts/build_vlckit.sh`, see `development-workflow.md` → "VLCKit
  build"). VideoLAN's stock prebuilts disable ffmpeg's mlp
  decoder/demuxer/parser on iOS/tvOS (VLCKit patch 0003, "App Store ToS" —
  Dolby licensing), and ffmpeg's truehd decoder selects the mlp parser.
  `ci_scripts/vlc-patches/0100` drops that block, so libvlc decodes TrueHD and
  MLP losslessly to PCM, up to 8 discrete channels. For TrueHD Atmos that is
  the 7.1 bed: ffmpeg ignores the object substream, and no App Store player
  can bitstream TrueHD on Apple TV (tvOS has no MLP/MAT passthrough; Infuse
  does the same 7.1 decode).
- **Licensing — a deliberate decision by Marvin (2026-10-16):** Dolby TrueHD
  is patent-encumbered and Dusk holds no Dolby license. VideoLAN removed the
  decoder from its App Store builds for exactly this reason
  (videolan/vlc#25040); Infuse ships it under a license. Shipping the decoder
  is a known legal/App Review risk that rests with the maintainer, not a
  technical default. Reverting is one step: drop patch 0100, bump
  `DUSK_VLCKIT_BUILD`, rebuild and republish — the app then falls back to the
  Plex route below on its own (`VLCKitBuildInfo.decodesTrueHD` is false).
  The binaries are hosted only in the private repo `marvinvr/dusk-vlckit`,
  never as a public download; builds without access to it get VideoLAN's
  stock VLCKit and the Plex route (`development-workflow.md` → "VLCKit
  Bootstrap").
  Never add Atmos object rendering (TrueHD/DTS:X → APAC): it is lossy, needs a
  new audio path, and carries the object-audio patent risk Firecore declined.
- Capability gate: the build script stamps every framework slice's Info.plist
  (`DuskVLCKitBuild`, `DuskVLCKitTrueHD`). `VLCKitBuildInfo.decodesTrueHD`
  reads it from the loaded binary, so a stale stock framework in a local
  `Frameworks/` keeps the old routing instead of playing TrueHD silent.
  Playback Info's "VLCKit Build" row shows `Dusk VLCKit 3.7.3-dusk2 (…,
  TrueHD)`; "Stock VLCKit 3.x" means the frameworks are stale.
- libvlc 3.x tags TrueHD `trhd`, MLP `mlp `; `mlpa` was the 4.x alpha's
  TrueHD fourcc. `VLCKitEngine.trueHDAudioFourCCs` holds all three and only
  marks tracks undecodable on a stock build.
- Routing with the Dusk build:
  - Direct play: TrueHD is an ordinary decodable track. On tvOS it ranks top
    (lossless) and VLCKit opens straight on it via `:audio-track`; iPhone/iPad
    still prefer a lossy surround sibling (`platformAudioCodecAdjustment`).
  - Startup remux decisions (DV5, HDR video, Dolby Atmos / spatial audio) are
    made for `PlayerViewModel.preferredRemuxAudioStream`: the local pick with
    TrueHD treated as undecodable, i.e. the pre-Dusk-build policy. TrueHD
    cannot ride the lossless fMP4 remux, so letting it win there would turn a
    UHD remux with TrueHD Atmos + E-AC-3/AC-3 from HDR/Atmos on AVPlayer into
    VLCKit without HDR. These files keep exactly their old remux; only when
    no remux qualifies does direct play open on the TrueHD track.
  - TrueHD-only files (`StreamResolver.convertedTrueHDRemuxBlocker`): DV7
    takes the converted-audio remux up front to preserve Dolby Vision/HDR.
    `requestSpatialAudioRemux` makes the choice before its first server
    request, also on stock builds and track changes. Other TrueHD-only
    files retain local lossless decoding; spatial audio alone does not
    force an audio transcode.
  - In a remux session, picking a TrueHD track retains DV7 picture by
    converting audio. For non-DV7, picking TrueHD behaves like picking DTS:
    `leaveSpatialAudioRemux` moves to VLCKit direct play with that track.
  - A remux that converts its audio keeps converting when it is rebuilt
    around the same audio stream (subtitle change, the Dolby Vision 7
    retry): `PlaybackCoordinator.remuxAudioConversion` records the converted
    stream, because the codec no longer says so — TrueHD is decodable, and
    re-deriving it from decodability dropped the remux (and HDR) for VLCKit.
- Failure case (`VLCKitEngine.watchTrueHDDecoding`): the decoder is Dusk's
  addition. One that fails to open leaves the ES selected and silent; its
  only trace is libvlc's error "Codec `trhd' (…) is not supported."
  (`src/input/decoder.c`), which `VLCLibraryLogBridge` counts. A TrueHD/MLP
  track selected after such an error during the current load is reported in
  `failedAudioDecoderTrackID`, marked undecodable, and `PlayerViewModel`
  hands it to the Plex fallback below once per item. Missing audio blocks
  alone never trigger it: the decoded-audio counter cannot tell a broken
  decoder from a track that starts late or pauses, and ffmpeg's runtime
  decode errors never reach the libvlc log (VLC 3 installs no av_log
  callback). A TrueHD track whose counter stays flat for 10 s while video
  decodes is only logged as a warning — that is the device evidence to look
  for if TrueHD ever plays silent. Offline downloads have no fallback.
- Plex fallback (stock build, a failed decoder, or a viewer pick of a track
  marked undecodable): `PlayerViewModel.selectAudio` reroutes through
  `transcodeAudioFallbackHandler` → `PlaybackCoordinator.
  transcodeForUndecodableAudio(_:)`. A file with zero locally decodable audio
  tracks triggers it automatically instead of direct-playing silent. It first
  tries `playConvertedAudioRemux`: the Atmos-path fMP4 remux with
  `directStreamAudio=0`, so the video (4K/HDR) is copied and Plex converts only
  the chosen stream (`directStreamAudio=1` makes Plex silently substitute a
  copyable sibling instead). Converted-audio profiles request only fMP4/E-AC-3
  with up to 8 channels, and reject incompatible or stereo-surround decisions
  before an engine starts. PMS 1.43.4 caps conversion at 6 channels regardless
  of the advertised limit, so TrueHD 7.1 normally arrives as DD+ 5.1. Output
  JOC metadata is carried in `RemuxAudioConversion` across source rebuilds;
  no Atmos signaling is inferred from a TrueHD input. A bitmap subtitle
  cannot ride the remux and is dropped. Only when the
  remux is refused (e.g. HDR on an SDR display) does it fall back to the
  quality-preset transcode — which re-encodes the video and, on servers
  without HDR tone mapping, fails for HDR sources (Plex emits 8-bit H.264
  still tagged PQ, AVPlayer rejects it with CoreMedia -12927).
- Why the stock-build rules still matter (history): on a build without the
  decoder, Bluray remuxes (default TrueHD + companion AC-3) went silent in a
  cycle — libvlc fell back to AC-3, the app's auto-selection re-selected the
  "better" TrueHD, libvlc dropped the working ES, the TrueHD decoder failed to
  open and there was no second fallback. Hence: automatic selection only
  considers decodable tracks, the pre-start preselection applies the same rule
  from Plex metadata (`isLocallyUndecodableAudioCodec`), the metadata merge
  ANDs Plex's codec into `isDecodable`, and leaving a remux never preselects
  an undecodable position. AirPlay's `preferredAudioStreamID` opts out of the
  filter because the server decodes.
- Not yet verified on hardware: TrueHD 7.1 → 8-channel LPCM on an Apple TV +
  AVR ("Output Channels" should read `current=8`), 7.1 into a 5.1 receiver
  (patch 0101 mixes down to 5.1), TrueHD Atmos bed levels, no "decoded no
  audio for 10 s" warning on healthy files, a subtitle change in a
  converted TrueHD remux staying on the remux, and CPU on Apple TV HD.

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
  - stock libvlc overwrote `supportsMultichannelContent` on every
    audio-output start (`avas_SetActive` passed its own spatial-audio flag,
    still false on first bring-up). Dusk's build (`vlc-patches/0101`) always
    opts in on tvOS, accepts any multichannel route instead of requiring the
    exact requested count, and when the route carries fewer channels than the
    source (7.1 TrueHD/DTS-HD into a 5.1 receiver) mixes down to 5.1 in
    libvlc instead of letting the AudioUnit drop the unlabelled channels.
    `AVPlayerEngine.load` still re-asserts the flag on tvOS (harmless, and it
    keeps a stock framework working). Without it, one VLCKit title on a stock
    build left every later AVPlayer title in stereo.
  - passthrough/bitstreaming is impossible on this stack regardless: libvlc 3
    returns `VLC_EGENERIC` for SPDIF/HDMI formats on Apple platforms. Dusk
    always software-decodes to PCM; the goal is only that the PCM is discrete
    multichannel rather than a fold-down.
  - Playback Info's "Output Channels" row reads
    `expected=… current=… preferred=… max=…`. `expected>2` with `current=2` is
    the signature of libvlc folding down in software. A TrueHD/DTS-HD 7.1
    title on a 7.1 receiver should read `expected=8 current=8` (unverified
    on hardware).
- iOS/iPadOS does NOT drive surround at all. The output route is effectively
  stereo (built-in speaker, wired, or Bluetooth/AirPods), so the policy lets
  VLCKit downmix to the route on its own; it sets no preferred output channel
  count and does not touch multichannel session content (the AVAudioSession is
  owned by `PlaybackNowPlayingController`). Keeping this policy idempotent
  matters: every re-poke of the live player's audio settings (passthrough,
  equalizer) restarts VLCKit's audio output, which is an audible gap. Historical note: the recurring "audio cuts in and out on this
  remux" bug was chased through several audio-session/mix-mode theories before
  the actual cause was found — the app steering playback onto an undecodable
  TrueHD track (see "Dolby TrueHD decoding" above). The idempotency and
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
  magic numbers per engine unless there is a platform reason. It holds the
  Medium baseline (`baseAVPlayerRelativeFontSize`, 75 on iPad/Mac, 100
  elsewhere) and multiplies it by `SubtitleFontSize.scale` (0.6 / 0.8 / 1.0 /
  1.25).
- Applying a size change mid-session differs by engine. `AVPlayerItem.textStyleRules`
  is settable on a playing item, so AVPlayer just rewrites the rules. VLCKit 3.x
  has no live setter: the text renderer reads `freetype-rel-fontsize` from the
  media player object when an input attaches. Per-media options such as
  `:sub-text-scale` never reach it (the vout does not inherit from the input),
  so the size is set through VLCKit's unexported `setTextRendererFontSize:`
  (`PlaybackSubtitleStyle.vlcRelativeFontSize`, 16 = 100%, smaller = larger) and
  `VLCKitEngine` reopens the media in place at the live position through
  `recoverFromStall()`, the same mechanic as stall recovery and the PiP
  support-mode swap. It only does so when the change would be visible: with a
  subtitle selected and playing. Paused sessions defer the reopen to the next
  `play()`, and with subtitles off the new size simply rides along on the next
  media load (`loadedSubtitleStyle` tracks what the open media was built with).
- System caption style (issue #18): with Settings › Audio & Subtitles ›
  Style = System (default, `UserPreferences.subtitleStyle`) subtitles follow
  Settings › Accessibility › Subtitles & Captioning › Style, read through
  MediaAccessibility in `SystemCaptionStyle` (user domain: foreground,
  character background or else the window, edge style, text size, font).
  Style = Dusk swaps in `SystemCaptionStyle.dusk` (white on 68% black, drop
  shadow, Helvetica Neue, size 1) for both engines; it is the hook for
  future Dusk-only styling. The coordinator pushes it with
  `applySubtitleStyle(_:)` next to the size; Settings-only, so next session.
  Dusk's Subtitle Size step multiplies onto the style's text size.
  - AVPlayer: with System, `textStyleRules` carry only `RelativeFontSize`
    (Dusk step × system size, because a size rule replaces the system's).
    AVFoundation applies everything else and restyles live; the engine re-sets
    the rule on `SystemCaptionStyle.didChangeNotification`. Colours, edge,
    background and font go into the rules only for Dusk: they override the
    user's style. Two AVFoundation limits (sim-verified): attributes a system
    profile locks (Outline Text: background and edge) win over the rules, and
    the Default profile's rounded window stays behind Dusk's text; and
    embedded tx3g/mov_text in a direct-played MP4 ignores `textStyleRules`
    entirely (size included), WebVTT in Plex HLS honours them.
  - VLCKit: `VLCTextRendererStyle` translates the style into libvlc
    `freetype-*` values (colour/opacity, background, outline thickness 4 for
    Outline, shadow angle/distance for drop shadow/raised/depressed).
    VLCKit's own setters only cover font/size/colour/bold, so
    `DuskVLCTextRenderer` (ObjC) creates inheritable variables on the libvlc
    player object through libvlccore's exported `var_Create`/`var_SetChecked`.
    A style change reuses the size-change reopen. Hidden system families
    (`.AppleSystemUIFont…`) map to Helvetica Neue / Menlo (monospaced,
    Classic) / Georgia (serif). Never pass an empty `freetype-font`: libvlc's
    live style update strdup()s it and crashes.
  - Not restylable: bitmap subtitles (PGS/VobSub), libass-styled ASS/SSA, and
    Plex-burned subtitles.
  - Sim verification: the simulator Settings app does not persist a style
    pick; switch profiles from a UI-test bundle through MediaAccessibility's
    private `MACaptionAppearanceSetActiveProfileID` (IDs from
    `MACaptionAppearanceCopyProfileIDs`, e.g. `MACaptionProfile-Classic`).
- Any in-place reopen rebuilds the input, so the audio choice would otherwise
  fall back to the automatic `:audio-track` preselect. `recoverFromStall`
  captures the playing audio ES position first (`currentAudioTrackPosition`,
  only when the media actually has more than one audio ES) and preselects it on
  the reopened media. Preselect, never a post-start ES switch — see
  "Dolby TrueHD decoding" and the audio-output warnings above.

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
  - Frames are enqueued through the layer's `sampleBufferRenderer`, never the
    layer's own `enqueue`/`flush`/`status`: `AVSampleBufferDisplayLayer` is
    `@MainActor` and that half of its API is deprecated, so feeding it from the
    render queue is a concurrency error. The renderer is the same pipeline and
    the documented way to enqueue off the main thread. The layer itself stays
    main-actor — it is the PiP content source and owns the control timebase.
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
- Merely containing embedded subtitle tracks never disables enhancement, for
  direct play or downloads. The actual engine selection determines rendering:
  - On tvOS, `StreamResolver.evaluateForDirectPlayback` prefers VLCKit for
    eligible SDR video when Auto/On and an embedded subtitle is selected.
    Startup uses the resolved per-show choice or the same forced/language
    subtitle rule as the player; returning
    to Original and leaving a remux use the current explicit choice when present.
    The view model also reports its actual automatic embedded-track choice,
    covering engine-discovered lists that differ from Plex's startup metadata.
    Explicit engine overrides and the frame-rate limits still win. Require
    positive SDR evidence (8-bit video or a known SDR transfer), with no HDR,
    PQ/ST2084, HLG, wide-color, or Dolby Vision flags. Missing range metadata
    keeps the normal engine; never select VLC for enhancement at the cost of HDR.
    The optional SDR Atmos copy-remux yields to this preference, at startup or
    when rebuilding it after a track change: play the original on VLC instead.
    The selected audio track is decoded to PCM (Atmos objects are not retained).
    HDR/DV and audio-conversion recovery remuxes, server streams, and transcodes
    keep their existing paths.
  - A tvOS embedded-subtitle selection during AVPlayer direct/local playback
    uses `switchToVLCKitForEnhancedSubtitlesIfNeeded` and the existing replacement
    attempt flow. It retains the source URL, live clock (even after seeking back
    before the original resume offset), playing/paused state, Plex session and
    scrobble state, downloaded-file identity, and explicit audio/subtitle IDs.
    The selected audio position is supplied before VLC opens the source, avoiding
    a startup audio-track switch. The handoff may briefly rebuffer. Keep VLC for
    the rest of that item, including subtitle Off, to avoid repeated reloads.
    This policy does not change iOS; AVPlayer still reveals its native layer
    while captions are selected. HDR/DV never gets this renderer handoff.
  - VLCKit supports enhancement with embedded text/ASS/bitmap and mounted
    sidecar subtitles. libVLC 3's `vmem` output CPU-blends SPU subtitles into
    the pixels before `DuskVLCRawVideoOutput` forwards them to Metal (see the
    [callback API contract](https://videolan.videolan.me/vlc-3.0/group__libvlc__media__player.html)).
    Keep those pixels intact; no separate overlay or Plex burn-in is needed.
  - AVPlayer's `AVPlayerItemVideoOutput` excludes native captions. While a
    legible option is selected, `AVPlayerEngine` removes the Metal view to
    reveal the existing `AVPlayerLayer` and skips enhancement frame submission.
    Turning subtitles off restores Metal without reloading or seeking; a forced
    frame refresh handles this while paused too. The cached engine view contains
    an observing SwiftUI wrapper, so changes apply immediately. Item media
    selection notifications cover automatic/system choices as well as Dusk's
    picker; observers are removed on load, stop, recovery, and deinit.
    Playback Info reports `Native AVPlayer renderer required while subtitles
    are selected` only while that selection is active (Off/HDR/fps reasons
    retain precedence). A general AVPlayer overlay is not implemented: copying
    plain text cues would lose native positioning/styling and bitmap support.
  - `VideoEnhancementSubtitleTests` covers metadata-only tracks, the preference,
    engine-specific selection eligibility, HDR/fps reason precedence, tvOS SDR
    routing with HDR/DV/HLG/unknown-range exclusions, 10-bit H.264 (Hi10P)
    staying on VLCKit without that handoff, and handoff continuity.
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
- Dolby Vision is requested (`dvh1` codec type; PQ, or HLG for 8.4) only
  for remux sessions that restore DV signaling
  (`PlaybackCoordinator.remuxDolbyVisionConfiguration`, passed to `apply`).
  Every other path shows a DV file's base layer, so it asks for that range
  and Playback Info reads `HDR10 (Dolby Vision base layer)`.
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
  bar; tvOS shows it above the grown playhead while scrubbing (see "tvOS Play
  Bar"). The playhead and thumbnail move during the swipe, but the video
  position keeps tracking actual playback until Select commits. If BIF loading
  or parsing fails, the controls keep their existing no-preview behavior.
- Intro auto-skip honors `AutoSkipIntroMode`: off, always, or always except
  episode 1 of a season. The episode check comes from the active
  `PlexMediaDetails.index`, so missing episode numbers are treated as not the
  first episode. It waits for the player's saved settings to load before arming
  a countdown and checks the current mode again before skipping.
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
  (fade-in is unaffected, which is what makes the bug look one-sided). **tvOS now
  stays mounted too**: nothing in its transport is focusable any more, so a HUD at
  zero opacity cannot capture the remote. Staying mounted is also load-bearing —
  it is what keeps `PlayerTVHUDController.actions` / `availablePanelTabs` populated
  while the HUD is hidden, so the press right after a reveal can already reach the
  action row or the settings panel.
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
  zones when enabled. The HUD's center row holds the 72pt play/pause button,
  flanked by the optional skip and episode circles (56pt); with all five on, the
  row tightens its spacing (`ViewThatFits`) to fit an upright iPhone. The center
  play/pause button is replaced by the shared spinner for as long as that
  spinner is up (`PlaybackCoordinator.playerLoadingState.isVisible`): startup
  (engine `.idle`/`.loading`, which includes the VLCKit audio warmup, also
  covered same-frame by `PlayerViewModel.isAwaitingPlaybackStart`), mid-play
  buffering, and automatic direct-play recovery. So the two never stack in the
  center slot, and startup never flashes a play icon that immediately flips to
  pause. The button stays mounted at zero opacity instead of being removed, for
  the same reason the HUD does (see the fade note above) and so the HUD's layout
  does not change when buffering starts. There is no transient play/pause badge
  on pause/resume; the HUD itself stays up while paused.
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
- tvOS uses a bottom-anchored native-style play bar driven by one remote input
  bridge and one state machine; see "tvOS Play Bar" below.
- Engaging the iOS playback settings menu refreshes the auto-hide deadline with a
  longer window than a normal tap (`settingsControlsAutoHideDelay`, double the
  base delay) via `PlayerViewModel.noteSettingsMenuInteraction()`, so the HUD
  does not hide while the menu is open. iOS detects the gear's opening tap with
  a `simultaneousGesture` (a native `Menu` exposes no presentation callback).
- Controls auto-hide only while playing on every platform. Pausing reveals the
  full HUD (including pauses from system transport, AirPlay or SharePlay) and
  cancels its hide deadline. Resuming starts a fresh normal auto-hide window.
  There is no transient center play/pause badge on tvOS; the transport provides
  the feedback. Explicit HUD dismissal still works while paused.
- With a mouse/trackpad (Mac or iPad), the system pointer hides together with the
  controls and returns the moment the pointer moves. The non-tvOS
  `PlayerTapInteractionOverlay` owns this: a `UIPointerInteraction` returns
  `UIPointerStyle.hidden()` while `showControls` is false (re-queried via
  `UIPointerInteraction.invalidate()` on every visibility flip), and a
  `UIHoverGestureRecognizer` reveals the HUD on movement. Moving the pointer over
  the visible controls keeps them up via `onContinuousHover` →
  `noteControlsInteraction()`. Touch-only playback never triggers any of it.
- On tvOS, `PlaybackCoordinator.noteActivePlaybackState` owns the actual UIKit
  idle-timer flag: only a playing, unfinalized session under the visible player
  cover suppresses sleep. Pause, loading, stop, errors, Up Next (including
  passout protection or a failed next-episode start), finalization, and dismissal
  enable the screensaver. Every engine snapshot reconciles UIKit's actual value
  because VLCKit 3.x also writes it asynchronously; never capture and restore
  that engine-written `true` as a previous value. Finalization releases the flag
  immediately, and snapshots from replaced session views are ignored. tvOS
  AVPlayer disables its independent `preventsDisplaySleepDuringVideoPlayback`
  assertion so both engines follow this policy; actual playback resumes the
  suppression, not the HUD's optimistic play state.
- iOS keeps the cover-level idle-timer modifier: loading, playing, or buffering
  suppresses auto-lock (except AirPlay); pause, stop, error, and dismissal restore
  the prior value. The cover-level lifetime survives episode/engine swaps. This
  also covers Metal rendering instead of a native video surface.
- `PlayerControlsOverlay` chooses iOS vs tvOS controls; shared controls live in
  `PlayerControlsSharedViews.swift`.
- `PlayerPlaybackInfoView` presents `PlaybackDebugInfo` from the iOS gear menu
  and from the tvOS panel's Info tab ("More…"); tvOS uses a custom full-screen
  diagnostic panel instead of the stock
  sheet/list presentation so long technical values stay readable. Its rows are
  focusable so remote up/down navigation scrolls the panel, and the back/menu
  command dismisses it. Expose resolver, stream, engine, and enhancement
  diagnostics there first.
- `PlayerSelectionSheet` is iOS-only presentation for track choices. tvOS uses
  the tabs of `PlayerTVInfoPanel`.
- Marker skip buttons come from `PlexMarker.skipButtonTitle`. Only the intro
  marker still renders a skip button (`PlayerViewModel.activeSkipMarker` is
  intro-only). Credits are handled by the bottom-right Up Next poster instead of
  a Skip Credits button (see "Timeline, Scrobble, and Up Next").

## tvOS Play Bar
- The tvOS HUD is a native-feeling, bottom-anchored play bar rather than a
  focusable control strip. Four files own it:
  - `PlayerTVHUDController` — the state machine. One `@Observable` object holding
    `mode` (`hidden` / `transport` / `scrubbing` / `panel`), `transportFocus`,
    the scrub target, the seek accumulator, and one `handle(_: PlayerTVRemoteInput)`
    entry point. Owned by `PlayerSessionView`, not by the overlay, so it survives
    the HUD being hidden.
  - `PlayerTVRemoteInputBridge` — the player's **single** remote-input owner: a
    `UIViewController` that becomes first responder while `isCaptureEnabled`,
    handles `pressesBegan/Ended/Cancelled` plus an indirect-touch pan and tap,
    and calls `super` for everything it does not understand. Its view is also
    the player's **focus sentinel** (`canBecomeFocused` while capturing, with a
    `UIFocusSystem.requestFocusUpdate(to:)` on every capture change). Nothing
    else in the HUD is focusable, and tvOS routes presses through the focused
    item's responder chain and delivers touch-surface (indirect) touches to the
    focused view — so a HUD with zero focusable items would leave both with
    nowhere to land. Making the input owner *be* the focused item converges the
    focus route and the first-responder route on one object and cannot start a
    focus fight, because while capture is on it is the only candidate. Do not
    drop the sentinel "because the first responder is enough": it is what makes
    the swipe scrub and the touch tap reachable too.
  - `PlayerControlsTVOverlay` + `PlayerTVActionRow` / `PlayerTVTransportBar` /
    `PlayerTVScrubOverlay` — the presentation.
  - `PlayerTVInfoPanel` — the settings sheet that replaced the three-level gear
    menu (tabs: Info, Chapters, Audio, Subtitles, Quality, Channel, Speed;
    a tab is omitted when it has nothing to show).
- **Invariant: only one thing owns the remote at a time.** The transport is not
  focusable — the action row draws its own selection from
  `transportFocus`, never from `@FocusState`. `PlayerTVInfoPanel` is the sole
  exception and uses SwiftUI focus properly (`.focusSection()`, `@FocusState`,
  `.onExitCommand`); while it is up the bridge resigns capture. Capture is also
  resigned for the subtitle-search cover, the playback-info cover, the
  full-screen Up Next overlay, and a surfaced playback error
  (`PlayerSessionView.isTVRemoteCaptureEnabled`). Never add a tvOS
  `onExitCommand` / `onPlayPauseCommand` to the player: the bridge already owns
  Menu and Play/Pause and the two would double-fire.
- Back has a Menu-only tap recognizer on the bridge, allowed alongside its
  touch pan. Raw Menu press callbacks are swallowed, so one physical Back is
  delivered exactly once and cannot also dismiss the enclosing cover. Back
  rejects the remainder of an active touch pan until lift-off. Any pending
  scrub or debounced click-seek consumes Back before the mode's normal action;
  cancellation clears preview/repeat/commit state without seeking or changing
  play/pause. Scrubbing also rejects queued HUD hides, keeping the visible
  "Click to seek · Back to cancel" hint consistent with the pending target.
  `PlayerTVScrubCancellationTests` covers cancellation, playing/paused state,
  trailing pan updates, visibility races, and the debounced seek task. Physical
  Siri Remote gesture arbitration still needs an Apple TV.
- Mode transitions:
  - `hidden`: tap or Select or Up or Down → `transport`, always with the bar
    selected (as in AVKit; Down used to open the panel directly, which started
    the HUD on the panel's Info tab); Left/Right → accumulate a seek
    (see below) with a centred badge, stays hidden; horizontal swipe → `scrubbing`;
    Play/Pause → toggles and reveals `transport`;
    Menu → dismiss the player. While a Skip Intro chip or an Up Next poster is on
    screen, Select activates it and Down dismisses it (the chip has nothing to
    dismiss, so Down falls through to revealing the transport).
  - `transport`: Menu or tap → `hidden`; Up → action row, Down from the row →
    the bar, Down from the bar → `panel`; Left/Right on the bar → seek, on the
    row → move the selection; Select on the bar → play/pause, on the row → run
    the action. Auto-hide is armed here only.
    The row is Skip Back / Skip Forward (advanced playback controls), Go Live
    (live, behind the edge), Subtitles, Audio, Info, Speed (advanced playback
    controls), then Next Episode when there is one; a selected action may float a tooltip
    (`PlayerTVActionItem.tooltip`) above its button.
  - `scrubbing`: the swipe moves a preview target, Left/Right steps it; Select
    or Play/Pause commits a precise seek (resuming if the session was paused);
    Menu or Up cancels back to wherever the scrub started.
  - `panel`: Menu closes it back to `transport`.
- **Seeks never go to the engine one press at a time.** A held (or repeatedly
  clicked) Left/Right accumulates into an offset previewed on the bar and the
  badge; one `seek(precise: false)` is issued once the button is released plus a
  short debounce. The hold ramps through `PlayerTVHUDLayout.seekHoldRampMultipliers`
  applied to the user's configured skip interval
  (`UserPreferences.playerDoubleTap{Backward,Forward}Interval`) — tvOS no longer
  has a hardcoded 10 s remote interval.
- Swipe scrubbing is direction-locked in the pan handler: tvOS delivers a
  touch-surface flick as *both* a pan and an arrow press, so a vertical flick is
  dropped by the pan (it is the panel gesture) and arrow presses are ignored
  while a horizontal pan is live. Mapping is relative and velocity-scaled:
  each pan update moves the cursor by `deltaX * gain * span`, `gain`
  interpolated between `swipeSlowGain` and `swipeFastGain` by finger speed,
  with `span` the seekable width on live and the timeline width otherwise. A
  second swipe that starts before the first is committed continues from the
  cursor (`translation` restarts at zero for every new gesture). The pan's
  `ended/cancelled/failed` branch is deliberately outside the capture guard: the
  controller drops arrow presses until the pan it believes is live has ended, so
  a swipe interrupted by capture going away (an Up Next overlay, a surfaced
  error) would otherwise leave the remote dead.
- The action row and the title block fade out while scrubbing: the scrub
  thumbnail (`PlayerScrubPreviewPopup`, 240x135 on tvOS) is positioned above the
  bar row and would otherwise land on top of the title. Fading rather than
  removing keeps the bottom-anchored stack from jumping as it appears.
- **All tunables live in `PlayerTVHUDLayout`** (insets, bar/head sizes, swipe
  gains and velocities, hold delays and ramp, auto-hide delay, panel
  height). They are a simulator-tuned first pass and are expected to be adjusted
  on a real Apple TV with a real Siri Remote.
- HUD visibility is mirrored in both directions: the controller writes
  `PlayerViewModel.showControls` (which the status bar, the skip chip's inset and
  the Up Next poster all read), and `PlayerSessionView` feeds changes back through
  `syncControlsVisibility(_:)` so a reveal that came from playback code (an
  auto-skip, a marker jump) still lands in a coherent mode.
  `PlayerViewModel.suppressControlsReveal` is the tvOS-only escape hatch for the
  Skip Intro activation from `hidden`, which must not raise the HUD.
  The panel and an in-flight scrub hold the HUD up via the existing
  `beginControlsInteractionHold()` / `endControlsInteractionHold()` pair.
- Chapters are marker-backed only. Plex exposes no chapter list through the
  endpoints Dusk uses, so `PlayerViewModel.chapterMarkers` (intro + credits) drives
  both the bar's ticks and the Chapters tab, and the tab is hidden when it is empty.
- Playback speed is `PlayerViewModel.playbackRate` / `setPlaybackRate(_:)`,
  offered only with advanced playback controls on (see below). It is refused
  for Live TV, hidden while SharePlay is active, and the iOS press-and-hold 2x
  boost overrides it transiently — `endSpeedBoost()` restores the chosen rate
  rather than 1x. The rate is per session: every new engine gets a new
  `playerPresentationID` (fresh `PlayerViewModel`) and both engines reset to 1x
  in `load(source:)`.

## Advanced Playback Controls
- `playerAdvancedControlsEnabled` (Settings › Playback Advanced, "Advanced
  Playback Controls", default off, iOS and tvOS). Off, the player is unchanged
  and has no speed control anywhere. On, outside Live TV:
  - iOS: skip back / forward circles beside Play (inside the Episode Buttons)
    and a speed `Menu` beside the gear (`PlayerSpeedMenu`, gauge glyph at 1x,
    the rate as text otherwise).
  - tvOS: `PlayerTVActionItem.skipBackward` / `.skipForward` lead the action
    row and a Speed shortcut (`.panel(.speed)`) follows Info; the panel gets
    its Speed tab. A skip press feeds the same debounced seek accumulator as
    Left/Right, so a burst of presses is one seek. Left/Right, Up/Down and the
    hidden-state gestures are unchanged.
- Skip intervals are the double-tap seek intervals
  (`playerDoubleTapBackwardInterval` / `ForwardInterval`, default 15 s), the
  same values the tvOS Left/Right clicks and the Now Playing skip commands use.
- `PlayerControlsContext.speedControl` decides availability. On tvOS an
  AVPlayer session whose active audio is Dolby Atmos is
  `.unavailableWithDolbyAtmos`: Atmos goes to the receiver/TV as a bitstream
  that only plays at 1x, so the control stays but shows "Not available with
  Dolby Atmos" instead of rates, and the rate drops to 1x if a mid-session
  audio switch lands on Atmos. VLCKit always decodes to PCM (passthrough is
  forced off), and iOS renders Atmos on device, so both keep the rates. This
  is a conservative call that has not been checked on hardware.

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
  the controls come up. On tvOS both insets, the trailing gutter and the
  transition come from `PlayerTVHUDLayout` (`bottomTrailing*`): the overlays
  share the bar's trailing edge and clear the action row, like AVKit's
  contextual actions. AVKit's own `contextualActions` / content proposals are
  not an option — they need `AVPlayerViewController`, which the custom HUD
  replaced (VLCKit sessions have no `AVPlayerItem`).
- tvOS look (no coral, matching the monochrome play bar): the Skip chip is
  `PlayerTVSkipChip`, a text-only capsule that is a white platter with a dark
  label while it owns Select (HUD hidden) and dark glass while the HUD is up;
  the auto-skip countdown sweeps across it. The poster lifts (scale + dark drop
  shadow, brighter platter) instead of glowing. The full-screen overlay uses the
  system `.bordered` buttons and puts Close in the action row beside Play,
  because tvOS has no pointer to reach a top-trailing corner button.
- Poster layout: concentric corners (the still's radius is
  `cardCornerRadius - cardPadding`) and a fixed three-row text column — eyebrow,
  title, metadata — so the card keeps one height for its whole lifetime. The
  countdown occupies the eyebrow's trailing slot (`8s`, or `Playing…` once
  starting) plus a bar spanning the card's full inner width beneath both
  columns (explicitly sized — its `GeometryReader` otherwise stretches the card
  across the screen); it is never an extra text row. The column width is clamped against
  the player's own width so the card still fits a narrow viewport.
- Overlay layout: one vertically centered content block sized from **both** axes
  (`UpNextLayoutMetrics.previewSize`). The still is the smaller of a share of the
  width and a share of the height, because the player is watched in landscape as
  often as portrait; a width-only rule pushed the details off the bottom of an
  iPhone in landscape. Narrow or portrait containers stack the still over the
  details, wide ones put them side by side, and tvOS is always side by side. On
  iOS the close button anchors to the screen's top-trailing safe area, not to the
  content block (tvOS puts it beside Play). The next episode's artwork also backs the screen as a blurred wash.
- The overlay's forward action is a labeled capsule ("Play Now" while a countdown
  is running, "Keep Watching" otherwise), not an icon over the still: white glass
  with a dark label on iOS, because the screen is near-black whatever the app's
  appearance mode is. tvOS uses the system `.glass` with no tint, like the
  detail hero buttons: an explicit tint goes white-on-white on focus.
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
- No Plex credits marker: `PlayerViewModel.estimatedCreditsMarker` synthesizes
  one (`isEstimated`) spanning `duration − clamp(4 %, 45 s, 2 min)` to the end
  (~50 s on a 22 min sitcom, 2 min on an hour drama), so the poster still shows.
  It never auto-skips or auto-advances on its own and never counts as "past
  credits" for marking watched.
- Poster interactions: tapping it plays the next episode now
  (`playUpNextPosterNow`); dragging it down dismisses the poster and cancels any
  pending auto-advance. On tvOS the card is **not** focusable (that would take
  the remote away from `PlayerTVRemoteInputBridge`): it is drawn as selected
  while the HUD is hidden and `PlayerTVHUDController` routes Select and Down to
  it, which is the same treatment the Skip Intro chip gets. Dismissing cancels
  any pending auto-advance
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
- Previous / Next Episode (issue #8, for credits Plex detects late): iOS shows
  `backward.end` / `forward.end` circles beside Play, opt-in via
  `playerEpisodeButtonsEnabled` ("Episode Buttons", default off); tvOS always
  appends a Next Episode button to the trailing end of the action row
  (`PlayerTVActionItem.nextEpisode`, tooltip `Next: S2 · E8`) and has no
  Previous (the Siri Remote has no spare button and the row is kept short).
  - Neighbours are resolved once per item at session commit
    (`refreshAdjacentEpisodesIfNeeded` → `adjacentEpisodes`); a Quality switch
    or delivery fallback of the same item keeps them. Online uses
    `PlexService.getAdjacentEpisodes` (current season fetched once for both
    sides; Previous never steps from a regular season into Specials), download
    sessions and failed online lookups use
    `DownloadManager.cachedAdjacentDownloadedEpisodes` (downloaded neighbours
    only). `adjacentEpisodes` is nil for movies, clips, trailers and Live TV, so
    no buttons appear there.
  - iOS keeps both buttons mounted and dims them while the lookup runs, at the
    first / last episode, and during SharePlay (`canStepEpisodes`), so Play never
    shifts. tvOS instead omits the Next button in those cases: a disabled
    control should not be a stop on the row, and Go Live already comes and goes.
  - `playAdjacentEpisode` always plays the other episode (Previous never
    restarts the current one) through the normal `play` flow: loading cover on
    the target's artwork, its resume offset, server fallback, and a reset of
    the Pause After count. It finalizes first with `markCompleted` only when
    Plex's own credits marker has been reached (`isPastCreditsMarker`; the
    estimated marker does not count); past 90 % the normal finalize scrobble
    marks it watched anyway, and anything earlier just reports progress.
- `PlaybackNowPlayingController` is iOS-only and owns AVAudioSession,
  MPNowPlayingInfoCenter, remote commands, route/interruption handling, and art.

### Playback queue (playlists and lists)
- `PlaybackQueue` (`Features/Player/PlaybackQueue.swift`) is a fixed list of
  `PlaybackQueueItem`s plus the position of the one playing; the source is a
  Plex playlist or an on-screen list (`PlaybackListContext`: Videos library or
  folder grid/row, collection). `PlaybackCoordinator.playbackQueue` holds it
  only for those sessions: `playQueue` (or `play(…, queue:)`) sets it after
  `enterLoadingState`, every other Play drops it, the cover closing clears it.
  Ordinary playback has **no queue** and behaves as before.
- `resolveUpNext(after:prefersDownloadCache:)` is the one Up Next decision,
  used by the credits poster and by `handlePlaybackEnded`:
  - queue session → `queue.next(isPlayable:)`, synchronous, no request. The
    playlist wins over the show's next episode, and its end ends playback.
    Watched items are **not** skipped; a finished one starts over because the
    session reads fresh details (Plex clears a watched item's offset). Queue
    starts never force a position (only Play from Beginning / Shuffle do): a
    watched item just hands no stale list offset over
    (`queueResumeFallbackOffset`), so pending offline progress and a rewatch
    begun elsewhere still resume. Unplayable kinds are dropped when the queue
    is built (the start position is counted per occurrence, so a duplicate
    entry starts where it was chosen); items whose server is not connected
    (and not downloaded) and items found gone from the server are skipped.
  - episode → the next episode `refreshAdjacentEpisodesIfNeeded` already
    resolved at session commit when that online lookup succeeded and found one
    (`PlaybackAdjacentEpisodes.isOnlineEpisodeLookup`; same rules as
    `getNextEpisode`), so the credits poster no longer asks the server again.
    Otherwise — still running, offline, failed, or **no** next episode —
    exactly the old path: the download cache for a download session (poster)
    or `nextEpisode(after:)`, which re-asks the server and falls back to a
    downloaded next episode the server no longer lists.
- Up Next presentations carry the generic item plus `queueIndex`/`queueTitle`;
  the eyebrow reads "NEXT IN <PLAYLIST>" and queue episodes name their show.
  Starting the item moves the queue first (`moveQueue`), so the commit already
  sees the new position, and restores it if the start fails.
- At each queue commit the neighbours come from the queue (Previous/Next and
  the tvOS Next button step through the playlist, movies included; they are
  keyed by item **and** queue position, so `[A, A, B]` still moves on) and
  `prefetchNextQueueItem` fetches the next item's metadata in the background
  (`queueItemLookup`): fresh watch state replaces the list's copy; a 404 marks
  it unavailable and the following one is tried, for any run of removed
  entries. `noteQueueItemUnavailable` also moves a poster/screen already
  offering that item on, and every queued start revalidates its candidate
  (`revalidatedQueueCandidate`). A queued start that fails because the item is
  gone (404) offers the next item instead of an error. Downloaded items are not
  fetched.
- Passout protection counts every queue item, not just episodes. Pre-rolls
  still only run for the first item (only `beginPlayback` passes a
  `prerollFeature`). Shuffle is a permutation fixed for the session, started
  from the beginning of its first item.
- `UpNext` log category: "Up Next poster ready N ms after the credits marker".
  Measured 2026-10-22 against plex-demo (iPhone sim, 3-min episode,
  credits poster): before 9–10 ms LAN / 162–167 ms with 150 ms added latency
  (one season `/children` request at the credits); after 0 ms in both.
- Tests: `DuskTests/PlaybackQueueTests.swift` (queue rules and Up Next
  resolution with a request-counting stub).

## Cinema Pre-rolls
Dusk plays the pre-roll videos a server owner set up in Plex (Settings →
Extras → "Cinema Trailer pre-roll video") in front of a movie, the way official
Plex clients do. There is no app setting: the server decides.

- Request: `PlexService.cinemaPrerolls` creates a play queue
  (`POST /playQueues?type=video&uri=server://<machineID>/com.plexapp.plugins.library/library/metadata/<ratingKey>&extrasPrefixCount=0&repeat=0&own=1`).
  The server puts its extras in front of the movie; everything ahead of the
  movie's rating key that is a `clip` plays, in order. Comma vs. semicolon in
  the server preference (play all vs. pick one at random) is resolved by the
  server. A server with no pre-roll answers with the movie alone and playback
  carries on unchanged after that one request.
- `extrasPrefixCount` is the number of cinema *trailers* ahead of the
  pre-roll, and in Plex it is a per-client setting, not a server one (no
  server preference holds a count). Dusk sends
  0 ("pre-roll only"). Any positive count would start playing library trailers
  for most servers, because "trailers from library" is on by default — that
  is a client option Dusk deliberately does not have. Leaving the parameter
  out returns no extras at all.
- Gate (in `startPlaybackSession`, after the details fetch, only when
  `beginPlayback` passed a `prerollFeature`): a `movie` that is not a Videos
  clip (`subtype == "clip"`), starting from the beginning (Play with no
  detail/initiating offset, or Play From Start), online (no local download), no
  AirPlay route, no SharePlay. Up Next, quality switches, delivery fallbacks and
  every other replay never pass `prerollFeature`. A failed lookup is logged
  and ignored.
- Playback (`PlaybackCoordinator+Prerolls`): pre-rolls are a phase *before*
  the movie's session. Each plays by direct play from its part URL on the
  engine `StreamResolver.evaluate` picks, with `ratingKey == nil`, so no
  timeline, scrobble, resume or scene-phase report ever names a pre-roll; only
  the movie carries watch state. Now Playing (iOS) shows the pre-roll and the
  audio session stays up across the hand-off. After the last one,
  `startFeatureAfterPrerolls` drops back to the movie's loading placeholder and
  replays the original request through `runPlaybackAttempt` (server walk,
  resume rules and all).
- UI (`PlayerPrerollView`, chosen by `PlayerView` while `prerollPlayback` is
  set): the video, a Skip chip where Skip Intro sits (tvOS `PlayerTVSkipChip`,
  drawn selected) and the way out (iOS close button, tvOS Menu). Skip — iOS tap,
  tvOS Select or right — goes to the next pre-roll, or to the movie after the
  last. iOS tap on the video and tvOS Play/Pause toggle pause. A pre-roll whose
  engine errors is skipped the same way; there is no transcode fallback for
  pre-rolls. `advancePreroll(from:)` is pinned to the pre-roll's
  `playerPresentationID`, so an end-of-file callback racing a Skip or an error
  cannot skip two.
- Verification: a scratch copy of the screenshot mock (`dusk-screenshots`)
  answering `/playQueues` with clips is enough to exercise the whole flow in
  the simulator via `-DuskScreenshotScreen player` (which goes through
  `beginPlayback`); the stock mock answers it with an empty container, which
  means "no pre-roll".

## Settings and Preferences
- Playback preferences live in `UserPreferences` and persist to UserDefaults.
- Session-start defaults: `maxResolution`, `videoEnhancementMode`, forced
  engines, subtitle defaults (language, forced-only, `subtitleFontSize`), and
  default audio language.
- `subtitleFontSize` is also editable from the in-player gear menu. The player
  writes the same `UserPreferences` value and calls
  `engine.applySubtitleFontSize(_:)`; there is no per-session override.
- Active UI defaults: intro auto-skip mode, credits auto-skip, double-tap seek,
  continuous play, the iOS Episode Buttons (`playerEpisodeButtonsEnabled`,
  default off; no tvOS toggle) and advanced playback controls
  (`playerAdvancedControlsEnabled`, default off, both platforms).
- `alwaysPlayInLandscape` (default on; "Always Play in Landscape" under
  Playback Behavior, iPhone only). While that cover is up, the player's
  hosting controller reports `.landscape` and the window scene requests the
  landscape side that matches the phone's physical orientation
  (`PlayerLandscapeOrientation`), including with Portrait Orientation Lock on.
  Turning the phone flips between landscape left and right. Closing the player
  restores the interface orientation from before it opened. Off leaves rotation
  to the system. iPad and tvOS do not show the setting and do not force one.
  The preference default is `PlayerLandscapePreferenceTests`. A silent
  simulator check (no playback) is `PlayerLandscapeOrientationTests`.
- New installs default intro auto-skip to always except episode 1 of each
  season; existing stored intro-skip preferences are preserved.
- `forceAVPlayer` and `forceVLCKit` are mutually exclusive in their setters.
- `spatialAudioRemuxEnabled` (default on; "Dolby Atmos" on tvOS, "Dolby Atmos &
  Spatial Audio" on iOS, under Playback Advanced) gates the Atmos remux.
  `hdrVideoRemuxEnabled` (default on; "HDR & Dolby Vision" on both) gates
  the HDR remux and profile 8 Dolby Vision signaling. Either forced engine
  also disables both. `dolbyVision7ConversionEnabled` (default on; "Dolby
  Vision 7 → 8.1" on both, disabled while HDR is off) gates the on-device
  profile 7 conversion.
- Settings UI is split by platform; shared labels/options live in
  `SettingsSupport`.
- Adding a playback preference usually requires edits in `UserPreferences`,
  both settings views, and the consumer in `PlaybackCoordinator` or
  `PlayerViewModel`.

## Where to Edit
- Engine choice: `Playback/StreamResolver.swift`.
- Engine contract: `Playback/PlaybackEngine.swift`, both engines,
  `PlayerViewModel`.
- External subtitles: `PlexService+Subtitles.swift`, `attachExternalSubtitle` in
  `VLCKitEngine`, `attachExternalSubtitlesIfNeeded`/`mergeSubtitleMetadata` in
  `PlayerViewModel+TrackSelection`, and
  `refreshSubtitleStreamsAfterDownload`/`switchToVLCKitForExternalSubtitle` in
  `PlaybackCoordinator+Session.swift`.
- Subtitle size and style: `SubtitleFontSize` + `PlaybackSubtitleStyle` in
  `Playback/PlaybackEngine.swift`, `Playback/SystemCaptionStyle.swift`,
  `Playback/DuskVLCTextRenderer.*`, `applySubtitleFontSize` in both engines,
  `UserPreferences.subtitleFontSize`, both settings views, and
  `PlayerViewModel.selectSubtitleFontSize` with the pickers in
  `PlayerControlsSharedViews`/`PlayerView`.
- Video enhancement: `Playback/VideoEnhancement*.swift`,
  `Playback/VideoEnhancementShaders.metal`, and
  `Playback/DuskVLCRawVideoOutput.*`.
- Concrete playback: `AVPlayerEngine.swift`, `VLCKitEngine.swift`, and the
  platform `VLCKitRenderer*.swift` files.
- Plex playback calls: `PlexService+Playback.swift`; metadata shape/fetching:
  `PlexService+Library.swift` and `PlexMediaDetails.swift`.
- Dolby Atmos / spatial audio, HDR and Dolby Vision remux: eligibility in
  `StreamResolver` (`spatialAudioRemuxBlocker`, `hdrVideoRemuxBlocker`,
  `dolbyVisionRemuxBlocker`), Plex request in `PlexService+Playback.swift`,
  session logic in `PlaybackCoordinator+SpatialAudio.swift`, Atmos and Dolby
  Vision init-segment/playlist fixes in `Playback/RemuxHLSLoader.swift`
  (tests: `DuskTests/HDRVideoRemuxTests.swift`).
- Dolby Vision 7 → 8.1: gate in `remuxDolbyVision7Conversion`
  (`PlaybackCoordinator+SpatialAudio.swift`) and
  `StreamResolver.dolbyVision7ConversionTarget`, retry branch in
  `performDirectPlayServerStreamFallback`, proxy lifecycle in
  `AVPlayerEngine`, proxy/fMP4/playlist rewriting in
  `Playback/DolbyVision7/`, RPU conversion in `Native/DuskDovi` (Rust,
  libdovi) behind `DoviBridge.swift` (tests:
  `DuskTests/DolbyVision7*Tests.swift`, `DuskTests/DoviBridgeTests.swift`).
  The proxy tests that accept loopback connections skip on the iOS Simulator,
  where the simulator resets them, and run on device.
- Session orchestration: `PlaybackCoordinator+Session.swift`; timeline:
  `PlaybackCoordinator+Timeline.swift`; Up Next: `PlaybackCoordinator+UpNext.swift`.
- Cinema pre-rolls: `PlexService+PlayQueue.swift`, `PlaybackCoordinator+Prerolls.swift`,
  `PlayerPrerollView.swift`, gate in `startPlaybackSession`.
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
