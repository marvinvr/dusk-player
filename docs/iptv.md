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
  so its options never leak. Only http(s) streams are kept.
- `IPTVService/XMLTVParser.swift` + `GzipFile.swift`: streaming `XMLParser`
  over a downloaded file (gzip files are gunzipped to a temp file first with
  the Compression framework). Keeps only programmes inside the window
  (−12 h … +8 days) and, when every entry has a `tvg-id`, only those channels.
  A truncated file keeps what was read.
- `IPTVService/IPTVLineupBuilder.swift`: maps playlist + guide onto the existing
  `PlexLiveTVLineup` / `PlexLiveChannel` / `PlexLiveProgram` types so the guide
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

- **The marker is `PlexLiveChannel.iptv`.** `PlaybackCoordinator.playLiveTV`
  routes such a channel to `playIPTV`; `PlexLivePlaybackContext.isIPTV` and
  `PlexLiveTVProvider.isIPTV` gate everything Plex-only.
- **Always AVPlayer.** `playIPTV` builds an AVPlayer engine directly; Force
  VLCKit, the resolver and the direct-play → server-stream ladder never apply.
  An IPTV channel can never reach VLCKit.
- **Nothing reaches Plex.** `reportTimelineOrQueueOfflineSync` returns for IPTV
  (a nil server ID would otherwise fall back to the primary server); no
  scrobble, Trakt, Up Next, markers, quality, offline sync, SharePlay, or debug
  info. The schedule refresh re-derives the current program from the lineup but
  never fetches a Plex grid for IPTV.
- **Images**: IPTV art paths are absolute URLs; `PlexService.imageURL` returns
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
- Guide: the XMLTV window reaches back `max(catch-up days, 1 day)`
  (`IPTVSourceLoader.guideWindow`). Channels without catch-up show their past
  from the EPG as info only.
- Sim: `iptv_test_source.py` gives channels 1–2 catch-up (`/catchup/…` logs the
  substituted times, then 302s to Apple's VOD sample) and channel 3 none.
  `-DuskScreenshotScreen iptvPlayer -DuskScreenshotIPTVCatchUpHoursAgo <h>`
  plays back the programme that was on h hours ago.

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

- Unit tests: `M3UParserTests`, `XMLTVParserTests`, `IPTVLineupBuilderTests`,
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
