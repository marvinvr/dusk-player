# IPTV Sources

Generic IPTV next to Plex Live TV: a user adds standard M3U playlists (with an
optional XMLTV guide) and their channels appear in the Live TV guide after the
Plex channels. Nothing in Dusk is specific to any provider; any extended M3U +
XMLTV works.

## Where Things Live

- `IPTVService/IPTVModels.swift`: `IPTVSource` (stored config),
  `IPTVPlaylistEntry`, `IPTVDRMConfiguration`, `IPTVProgramme`, `IPTVGuide`,
  `IPTVPlayableChannel`, `IPTVImages.serverID`.
- `IPTVService/M3UParser.swift`: extended M3U. `#EXTM3U url-tvg/x-tvg-url`,
  `#EXTINF` attributes (`tvg-id`, `tvg-name`, `tvg-logo`, `group-title`,
  `tvg-chno`/`channel-number`/`tvg-num`), `#EXTGRP`,
  `#KODIPROP:inputstream.adaptive.license_type/license_key/server_certificate`
  (Kodi's `url|…` suffix dropped), `#EXTVLCOPT:http-user-agent/http-referrer`,
  Kodi `url|Header=value&…`. Option lines before or after `#EXTINF` belong to
  the entry closed by the next URL line; a junk URL line drops the pending entry
  so its options never leak. Only http(s) streams are kept. Fed line by line
  (`M3UParser.Reader`); the loader parses the downloaded file in 1 MB chunks
  (`parse(fileURL:)`), a line over 1 MB is dropped. Xtream rules: see below.
- `IPTVService/XMLTVParser.swift` + `GzipFile.swift`: streaming `XMLParser`
  over a downloaded file (gzip files are gunzipped to a temp file first with
  the Compression framework). Keeps only programmes inside the window
  (−12 h … +8 days) and, when every entry has a `tvg-id`, only those channels.
  A truncated file keeps what was read.
- `IPTVService/IPTVLineupBuilder.swift`: maps playlist + guide onto the existing
  `LiveTVLineup` / `LiveChannel` / `LiveProgram` types so the guide
  rows, Watch Live card, now/next, program sheet and live player HUD are reused
  as-is. Guide match: `tvg-id` exact, then case-insensitive, then a unique
  display-name match on `tvg-name`/title. XMLTV `title`/`sub-title` map to
  Plex's `grandparentTitle`/`title`. Logo: M3U `tvg-logo`, else XMLTV icon.
- `IPTVService/IPTVService.swift`: `@Observable` per-profile state (sources,
  loaded lineups, errors), add/edit/delete/move, parallel loading (30 min
  refresh). `IPTVSourceLoader` is the network half.
- `IPTVService/IPTVSourceStore.swift`: sources in UserDefaults under
  `IPTVSources.<profileID>`; header values in the Keychain
  (`IPTVSourceHeaderValues`, keyed by source id). URLs are not treated as
  secrets — a token in a playlist URL query lives in UserDefaults.
- `Features/Settings/IPTVSourcesSettingsView.swift`: Settings › Live TV ›
  IPTV Sources (list, Add IPTV Source, editor with name, M3U URL, XMLTV URL,
  header name + value). tvOS uses `TVSettingsURLFieldRow` (generalized alert
  title/message/secure).
- `Playback/FairPlay/`: `IPTVAsset` (AVURLAsset with headers/user agent),
  `FairPlayLicenseClient` (+ `FairPlayCertificateCache`),
  `FairPlayContentKeyController` / `FairPlayKeyExchange`.

## Invariants

- **The marker is `LiveChannel.iptv`.** `PlaybackCoordinator.playLiveTV`
  routes such a channel to `playIPTV`. An IPTV source is never routed to a
  server: its `LiveTVProvider.serverID` is `IPTVImages.serverID`, which no
  server has, so `MediaService.liveTV(for:)` returns no facet and no server
  request is made for it (guide refresh, filing). `LivePlaybackContext.isIPTV`
  still drives the player's Retry and keeps timeline reports off.
- **Always AVPlayer.** `playIPTV` builds an AVPlayer engine directly; Force
  VLCKit, the resolver and the direct-play → server-stream ladder never apply.
  An IPTV channel can never reach VLCKit. AVPlayer cannot play a raw MPEG-TS
  stream over HTTP ("The server is not correctly configured."), so Xtream
  `output=ts` live URLs are rewritten to the panel's HLS URL at parse time (see
  Xtream Codes). Any other raw-TS source still fails with that message.
- **Nothing reaches Plex.** `reportTimelineOrQueueOfflineSync` returns for IPTV
  (a nil server ID would otherwise fall back to the primary server); no
  scrobble, Trakt, Up Next, markers, quality, offline sync, SharePlay, or debug
  info. The schedule refresh re-derives the current program from the lineup but
  never fetches a Plex grid for IPTV.
- **Images**: IPTV art paths are absolute URLs; `MediaService.imageURL` returns
  them untouched for `serverID == IPTVImages.serverID` (never through a Plex
  photo transcoder). The IPTV provider, placeholder and Now Playing all carry
  that sentinel.
- **Tab**: `LiveTVViewModel.isAvailable` is `provider != nil || hasIPTVSources`,
  so IPTV alone shows the Live TV tab. With no DVR the Plex guide load is
  skipped (discovery keeps running on its own task; the guide task is keyed on
  the provider id so a late DVR reloads it).
- **Headers**: the source header (+ entry referrer / pipe headers) go on the
  playlist and guide requests, the asset (`AVURLAssetHTTPHeaderFieldsKey`,
  undocumented but long-standing), and both FairPlay requests.

## Xtream Codes and Large Playlists

Xtream panels (`get.php?username=…&password=…&type=m3u_plus&output=ts`) are
the usual backend behind "big" IPTV subscriptions. Their `m3u_plus` list holds
the live channels **and** the whole VOD catalogue: tens of thousands of
entries, tens of megabytes, generated on request (first byte after 30–60 s).

- **Loading** (`IPTVSourceLoader.fetchPlaylist`): `URLSession.download` to a
  file, chunked parse on a detached task. `requestTimeout` (180 s) is the idle
  timeout, first byte included; it was 30 s, which every slow panel hit
  ("The request timed out."). Same timeout for the guide.
- **VOD skipped** (`XtreamURL.isVOD`): `…/movie|series/<user>/<pass>/<id>.<ext>`
  entries are dropped and counted (`IPTVPlaylist.skippedVODEntries`). A list
  with only those says so instead of "no channels". Groups are not used: VOD
  group names are free text.
- **Live as HLS** (`XtreamURL.liveHLSURL`): `…/live/<user>/<pass>/<id>.ts` (or
  no extension) → `…/live/<user>/<pass>/<id>.m3u8`, which Xtream serves for
  every live channel (usually via a 302). The older `…/<user>/<pass>/<id>` form
  is rewritten only when user/password match the playlist URL's query. Numeric
  ids only; `.m3u8` URLs and everything else stay as written. A panel with HLS
  output disabled for the account fails at play time with AVPlayer's error (no
  VLCKit fallback).
- **Guide filter** (`IPTVLineupBuilder.guideChannelFilter`): XMLTV channels are
  kept by `tvg-id` (exact or ignoring case) or by a display name equal to an
  entry's `tvg-name`/title; programmes only for kept channels. Name matches need
  the `<channel>` before its programmes (the XMLTV order). Before, one entry
  without `tvg-id` (every Xtream VOD row) turned the filter off and the whole
  provider guide was kept.
- **Guide budget** (`IPTVGuide.limited`, `maxGuideProgrammes` = 100k): after
  parsing, only the programmes closest to now are kept (on air first, then
  outward both ways). Each kept programme costs about 1 KB in the lineup and
  the guide grid.

Measured in the tvOS 27.2 simulator (Debug, synthetic panel below: 12k live +
30k movies + 18k episodes, 39.8 MB): first byte after 45 s used to time out at
30 s; now it loads in 49.4 s (≈4.4 s after the first byte), footprint 128 MB.
With a 190 MB XMLTV (6k channels, 5 days hourly): 670–780 MB before, 300–315 MB
after. iOS: the eager guide rows (see `ui-features.md` › Live TV) crashed at
1.35 GB right after the list loaded; now 110–131 MB.

## FairPlay

Standard Apple flow only; Dusk never handles keys.

1. An `AVContentKeySession(.fairPlayStreaming)` is attached to **every** IPTV
   asset on device, so `EXT-X-KEY KEYFORMAT="com.apple.streamingkeydelivery"`
   reaches it even when the M3U names no license type. Unencrypted streams
   never trigger it.
2. On a key request: content id = the `skd://` URI minus the scheme;
   certificate from `server_certificate` (memory + Caches cache by URL, dropped
   if the SPC fails); SPC via `makeStreamingContentKeyRequestData`; POST raw to
   `license_key` with `Content-Type: application/octet-stream` and the source
   headers; raw CKC back through `AVContentKeyResponse`.
3. Failures (`FairPlayError`) fail the key request and the engine immediately
   with a readable message in the normal player error UI.
4. `license_type` other than FairPlay (`com.apple.fps`, `fairplay`, …) — e.g.
   Widevine — is refused before playback with a clear error.

**Simulator trap:** creating a FairPlay `AVContentKeySession` on the simulator
throws an Objective-C exception (app crash). `FairPlayContentKeyController
.isSupported` is false there: no session is created, and a channel that says
FairPlay fails with "plays only on a real device".

**Unverified on device:** real FairPlay playback, AirPlay of FairPlay channels,
key renewal. `FairPlayKeyExchangeTests` covers the flow against a mocked
license server with a fake key request.

## Catch-up (past programmes)

`IPTVCatchUp.swift`: the standard M3U attributes, on the `#EXTINF` or as
defaults on `#EXTM3U` — `catchup` (or `catchup-type`), `catchup-days` (or
`timeshift` / `tvg-rec`; default 7, capped at 14), `catchup-source`.

- Modes: `default` (source is the whole URL), `append` (source appended to the
  stream URL), `shift`/`timeshift` (`?utc={utc}&lutc={lutc}` appended). Others
  (`flussonic`, `xc`, `vod`, …) and incomplete entries mean no catch-up.
- Placeholders: `{utc}`/`${start}`, `{utcend}`/`${end}`, `{lutc}`/`${now}`/
  `${timestamp}`, `{duration}` (seconds, `{duration:60}` divides), `{offset:N}`,
  `{Y}{m}{d}{H}{M}{S}` and `{utc:Y-m-d H:M:S}` / `{utcend:…}` (UTC). Unknown
  `{…}` stays as written.
- A programme is replayable when it has ended and started within
  `catchup-days`. `IPTVPlayableChannel.catchUpStream` keeps the channel's
  headers, user agent and DRM (KODIPROP lines apply), sets `isCatchUp`.
- Playback: `PlaybackCoordinator.playIPTVCatchUp` → `playIPTV` with no live
  context, so it is the normal on-demand player (seek bar, header from
  `PlaybackSource.iptvCatchUp`); `isPlayingIPTVCatchUp` keeps it away from
  Plex timeline/scrobble. The engine never retunes a catch-up stream: its end
  ends playback, its failures fail.
- A guide can list a programme whose replay was never published, so a refused
  catch-up is a normal outcome. When a catch-up item fails, the engine repeats the
  request once (`IPTVAsset.catchUpRefusal`) and shows the server's one-line
  `text/plain` answer, or a sentence for the status. It only runs after a failure,
  so a working replay costs no extra request.
- Guide: the XMLTV window reaches back `max(catch-up days, 1 day)`
  (`IPTVSourceLoader.guideWindow`). Channels without catch-up show their past
  from the EPG as info only.
- The whole loaded guide is on one axis per source, with empty stretches
  collapsed to markers (see `ui-features.md` › Live TV), so a source does not have
  to pad its XMLTV with "no programme" entries, and should not.
- Sim: `iptv_test_source.py` gives channels 1–2 catch-up (`/catchup/…` logs the
  substituted times, then 302s to Apple's VOD sample) and channel 3 none.
  `-DuskScreenshotScreen iptvPlayer -DuskScreenshotIPTVCatchUpHoursAgo <h>`
  plays back the programme that was on h hours ago.

### Resume points

Plex keeps no state for IPTV, so `IPTVService/IPTVResumeStore.swift` remembers
how far a catch-up programme was watched.

- Key (`IPTVResumeKey`): SHA-256 (first 128 bits, hex) of the source identity
  + the channel's live stream URL + programme start/end. The source identity
  (`IPTVResumeKey.sourceIdentity`) is the playlist URL with scheme/host
  lowercased, default port, trailing slash and fragment dropped and the query
  sorted; Xtream (`get.php?username=…`) is server + base path + username.
  Never the source UUID: sources don't sync, every device mints its own, so a
  UUID key never matched across devices. Never the catch-up URL, which can
  carry "now"-relative placeholders. Live channels get no key.
- Storage: one JSON dictionary in UserDefaults (`iptvResumePoints`). Entries
  expire after 14 days, the newest 200 are kept, pruned on launch and every
  write. A position under 30 s is ignored (never saved, never clears a
  point); the last 5% (at most 2 min) counts as finished and leaves a
  position-less tombstone (so a merged copy can't revive the old point).
  Only finite streams (duration > 0) count. Losing it is fine; no migrations.
- Saves (`PlaybackCoordinator+IPTVResume.swift`): pause, scene inactive /
  background, session end (`finalizeCurrentPlaybackSession`, so playing to the
  end clears it) and every ~20 s on the timeline tick. Never while the engine
  is loading (it can report 0).
- iCloud: mirrored to `NSUbiquitousKeyValueStore` (one key, same
  dictionary, ~15 KB at the cap) through `IPTVResumeCloud`: merged per entry,
  newest `updatedAt` wins (tombstones included), at app launch and every
  foreground (`refreshFromCloud`: `synchronize()` + merge, from `DuskApp`),
  on every write, at every prompt read and on
  `didChangeExternallyNotification`. Entitlement
  `com.apple.developer.ubiquity-kvstore-identifier` on the iOS/tvOS app
  entitlements and `Dusk-macOS-AppStore.entitlements` (testflight.sh swaps it
  in for the Mac archive; ad-hoc Mac builds can't carry it). Never on Top
  Shelf (its App ID has no iCloud). Without the entitlement or an iCloud
  account the store is local-only, so the code needs no switch.
- Prompt: the guide's `replay` asks with a `confirmationDialog` (programme
  title; "Resume from 12:34" / "Play from Start" / Cancel) when a point
  exists, else plays straight away. Resume passes the point as
  `PlaybackSource.startPosition`.
- Sim: play a catch-up programme for over 30 s, leave the player, select it
  again. The stored dictionary is in the app container's
  `Library/Preferences/com.dusk-player.app.plist`.

## Retune (slate → live, drops)

IPTV channels never end. In `AVPlayerEngine`, for an IPTV source:
`AVPlayerItemDidPlayToEndTime` (an `EXT-X-ENDLIST`, e.g. a source ending its
off-air slate when the live session starts) and item/key failures that
`IPTVRetunePolicy.isRetryable` accepts (URL errors, CoreMedia HLS/HTTP codes,
"HTTP …" descriptions, FairPlay license/certificate with no answer or 5xx)
re-request the same channel URL with a fresh item and a fresh key session,
staying in the player on a spinner. Backoff 2 → 4 → 8 → 16 → 30 s; 10 s of
steady playback resets it; after >2 min of failing the normal error shows,
with Retry (`PlaybackCoordinator.retryActiveIPTVChannel`, a full re-tune) and
Close. A refused license (4xx), unsupported DRM or undecodable stream fails at
once. Verified in the sim with a 6 s silent ENDLIST slate (re-requests at
+2/+4/+8 s); policy covered by `IPTVRetunePolicyTests`.

## Verification

- Unit tests: `M3UParserTests`, `XtreamPlaylistTests`, `XMLTVParserTests`, `IPTVLineupBuilderTests`,
  `IPTVSourceStoreTests`, `FairPlayKeyExchangeTests` (fixtures in
  `DuskTests/IPTVFixtures.swift`).
- Simulator: `python3 scripts/iptv_test_source.py 47880` (Apple's public
  unencrypted HLS samples, guide around now, header
  `Authorization: Bearer dusk-test-token`) with `scripts/mock_large_plex.py`
  (≥120 shows), then launch a Debug build:

  ```bash
  xcrun simctl launch <sim> com.dusk-player.app -DuskScreenshotMode YES \
    -DuskScreenshotPlexTV http://127.0.0.1:47870 -DuskScreenshotMute 1 \
    -DuskScreenshotIPTVPlaylist http://127.0.0.1:47880/playlist.m3u \
    -DuskScreenshotIPTVName "Test IPTV" \
    -DuskScreenshotIPTVHeaderValue "Bearer dusk-test-token" \
    -DuskScreenshotScreen iptvPlayer -DuskScreenshotIPTVChannel 1 -DuskScreenshotKeepHUD YES
  ```

  Screens: `iptvSources`, `liveTV`, `iptvPlayer`. `-DuskScreenshotMute 1`
  mutes AVPlayer (the bipbop samples beep). The seeded source is stored in the
  profile like a real one. Apple's samples are VOD, so the live bar's playhead
  sits at the start of the programme window; real live streams behave normally.
- Xtream / large lists: `python3 scripts/iptv_xtream_test_source.py --delay 45`
  (synthetic panel on 47890, needs ffmpeg; `--epg-channels 3000` adds a big
  `url-tvg` guide). Seed `-DuskScreenshotIPTVPlaylist
  "http://127.0.0.1:47890/get.php?username=dusk&password=test&type=m3u_plus&output=ts"`;
  `.ts` channels are a real live MPEG-TS, `.m3u8` the same channel as live HLS
  (silent test pattern). The loader logs `IPTV source loaded: N channels, M
  movie/series entries skipped, playlist … s` (category `IPTV`).
  `-DuskScreenshotGuideRow 6000` scrolls the iOS guide to that row (then +100)
  to check the windowed rows.
