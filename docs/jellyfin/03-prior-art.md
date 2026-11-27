# Jellyfin support — 03: Prior art

How existing Apple-platform Jellyfin clients and multi-backend players solve
the problems Dusk is about to have, and what Dusk should copy, adapt or avoid.
Research only: no app code was changed for this document.

Evidence levels used throughout:

- **[live]** — observed on the test server `jellyfin-demo` (Jellyfin **12.4.0**,
  `GET /System/Info/Public`) on 2026-11-27 with the `duskcompare` user. The
  probes were read-only apart from creating and logging out throw-away
  sessions and starting/stopping a few remux jobs.
- **[source]** — read in the named repository file on 2026-11-27.
- **[recalled]** — from memory or secondary sources, not re-verified. Treat as
  a lead, not a fact.

<!-- SURVEY-PENDING -->

## 2. Where Dusk stands today: is anything protocol-backed?

Short answer: **no, not on the data side.** The only protocol seam that matters
for a second backend already exists on the *playback engine* side.

Protocols declared in `Dusk/Sources` (complete list, 9):

| Protocol | File | Relevance |
| --- | --- | --- |
| `PlaybackEngine` | `Playback/PlaybackEngine.swift:98` | The one real abstraction. `AVPlayerEngine` and `VLCKitEngine` conform; `PlaybackEngineFactory` builds them. Takes a neutral `PlaybackSource`, so engines are already backend-agnostic. |
| `PlaybackPictureInPictureDelegate`, `VLCKitEnhancedPictureInPicturePlaybackDelegate`, `VLCKitRenderingHost` | `Playback/` | Engine plumbing. |
| `HLSUpstreamFetching`, `DolbyVisionSampleRewriting` | `Playback/DolbyVision7/` | Test seams of the DV7 → 8.1 proxy. Backend-agnostic by construction (they see HLS playlists and fMP4). |
| `FairPlayKeyRequest`, `IPTVResumeCloud`, `HeroScrollKind` | misc | Irrelevant. |

There is no `MediaProvider`, no protocol in front of `PlexService`, and the
models are concrete Plex-shaped `Decodable` structs. `AGENTS.md` says so on
purpose: *"No premature abstraction: No `MediaProvider` protocol … don't
abstract until a second backend exists."* That moment is now.

How deep the Plex shape goes (ripgrep over `Dusk/Sources`, excluding
`PlexService/` and `Models/`):

| Measure | Value |
| --- | --- |
| Swift files outside the service/model folders | 286 |
| …of which mention a `Plex*` type | **186** (65 %) |
| Distinct `plexService.<member>` names used by features | **141** |
| `plexService.` call sites | 1 280 in 112 files |
| `PlexItem` / `PlexItemID` / `PlexMediaDetails` references | 279 / 253 / 117 |
| `ratingKey` occurrences | 796 in 60 files |
| `plexService.pool` reached into directly | 72 times |
| Size of the service layer | `PlexService/` 46 files, 9 702 lines, 214 funcs across the `PlexService+*.swift` extensions |
| Size of the models | `Models/` 32 files, 6 376 lines |

What is already in Dusk's favour:

1. **Server-scoped identity exists.** `PlexItemID { serverID, ratingKey }`
   (`Models/PlexServerScoped.swift`) with a `"<serverID>|<ratingKey>"` storage
   form. Jellyfin item ids are 32 hex characters, so the `|` separator stays
   unambiguous. Every model is stamped with its server through
   `CodingUserInfoKey.duskServerID` by `ServerPool.decoder(for:)`.
2. **Content identity is already backend-neutral in spirit.**
   `PlexContentKey` (`Models/PlexContentKey.swift`) resolves
   `plex://` guid → external id (tmdb, imdb, tvdb) → heuristic. Jellyfin's
   `ProviderIds` (`{"Tmdb": "546554", "Imdb": "tt8946378"}` **[live]**) drop
   straight into the `.external(provider:namespace:id:)` case, which means the
   existing multi-server merge (`PlexService/MultiServer/`) could merge a Plex
   and a Jellyfin copy of the same film without new machinery.
3. **A multi-server pool exists.** `ServerPool` + `PlexServerConnection` hold
   one live session per server. That is the natural seam for "this server
   speaks Jellyfin".
4. **A precedent for a second source mapping into the shared models exists:**
   `IPTVService/IPTVLineupBuilder.swift` turns M3U/XMLTV into
   `PlexLiveTVLineup` / `PlexLiveChannel` so the Live TV UI and player are
   reused unchanged. It works, and it shows the cost: Plex names for
   non-Plex data, and special cases such as `PlexLiveChannel.iptv`.
5. **The playback ladder is expressed in neutral terms** even where the code
   is not: direct play → server remux with stream copy → explicit quality
   transcode. `StreamResolver` decides from codec/container/HDR metadata; its
   55-odd functions take `PlexMedia` / `PlexStream` only because that is where
   the metadata lives.

What is against it:

- `StreamResolver`, `PlaybackCoordinator*`, `DownloadManager`
  (296 Plex-ish references in that one file) and the offline metadata cache
  all consume Plex structs directly.
- Features call 141 different service members, many of them Plex concepts
  with no Jellyfin twin (`homeUsers`, `generatePin`, `watchlist`,
  `libraryOrder`, `setManagedHub`, `cinemaPrerolls`, `checkRemoteDirectPlayAccess`).
- Persisted state (downloads, resume memory, pins, Siri catalog, Top Shelf
  snapshot) stores Plex-shaped payloads.

<!-- SDK-DECISION-PENDING -->

## 5. DeviceProfile and playback negotiation

### 5.1 What the server actually does with a profile [live]

Everything in this subsection was measured against `jellyfin-demo` with
`POST /Items/{id}/PlaybackInfo` and hand-built profiles. The library has the
right torture files (DV 5 / 7 FEL+MEL / 8.1 / 8.4, HDR10+, AV1, TrueHD, DTS-X,
E-AC-3 JOC, PGS).

**Profile A, "VLCKit plays anything":**

```json
{ "DirectPlayProfiles": [{ "Type": "Video" }, { "Type": "Audio" }],
  "TranscodingProfiles": [], "CodecProfiles": [],
  "SubtitleProfiles": [{ "Format": "srt", "Method": "Embed" }, "… one Embed entry per format …"] }
```

A `DirectPlayProfile` with no `Container` matches every container. All 12
test files came back `SupportsDirectPlay: true`, `SupportsDirectStream: true`,
`SupportsTranscoding: false`, every subtitle stream `DeliveryMethod: "Embed"`.

**Profile B, "AVPlayer":** direct play only `mp4,m4v,mov` with
`h264,hevc,av1` + `aac,ac3,eac3,alac,flac,mp3`; one transcoding profile
`{Protocol: "hls", Container: "mp4", VideoCodec: "hevc,h264", AudioCodec: "aac,ac3,eac3", MaxAudioChannels: "8", MinSegments: 2, BreakOnNonKeyFrames: true, EnableSubtitlesInManifest: true}`;
a `CodecProfile` for hevc with an `EqualsAny VideoRangeType` condition.

| File | Result with profile B | `TranscodeReasons` |
| --- | --- | --- |
| MP4 H.264/AAC | direct play | — |
| MP4 DV 5 (`dvh1`), DV 8.1 (`dvhe`), DV 8.4 HLG | direct play | — |
| MKV HEVC DV 8.1 + E-AC-3 Atmos | HLS fMP4, **video + audio copied** | `ContainerNotSupported` |
| MKV HEVC HDR10 + E-AC-3 JOC | HLS fMP4, copied | `ContainerNotSupported` |
| MKV HEVC HDR10+ | HLS fMP4, copied | `ContainerNotSupported` |
| MKV HEVC SDR + AC-3/DTS (default track DTS) | HLS fMP4, video copied, audio transcoded | `ContainerNotSupported,AudioCodecNotSupported` |
| MKV H.264 + DTS-X | same | `ContainerNotSupported,AudioCodecNotSupported` |
| MPEG-TS H.264 + TrueHD | same | `ContainerNotSupported,AudioCodecNotSupported` |
| MKV DV 7 (`DOVIWithEL`), range list without `DOVIWithEL` | HLS fMP4, **video still copied**, DV config dropped | `ContainerNotSupported,VideoRangeTypeNotSupported` |
| MKV AV1 HDR10 | video re-encode | `ContainerNotSupported,VideoCodecNotSupported,AudioCodecNotSupported` |

Details that matter for an implementation:

1. **`TranscodingUrl` is a relative path with the token baked in**:
   `/videos/<dashed-guid>/master.m3u8?DeviceId=…&MediaSourceId=…&VideoCodec=hevc,h264&AudioCodec=eac3&AudioStreamIndex=1&…&SegmentContainer=mp4&MinSegments=2&PlaySessionId=…&ApiKey=<token>&…&hevc-rangetype=…&TranscodeReasons=ContainerNotSupported`.
   Prefix it with the server base URL. Never log it unredacted (Dusk already
   has `sanitizedPlaybackURLString`).
2. **`DirectStreamUrl` is not populated** on 12.4. For direct play the client
   builds `/Videos/{itemId}/stream?static=true&mediaSourceId={id}` itself
   (optionally `stream.{container}`). It answers `206` with
   `Accept-Ranges: bytes`.
3. **Stream indexes are ignored unless `MediaSourceId` is sent too.**
   `{"SubtitleStreamIndex": -1}` alone changed nothing; with
   `"MediaSourceId": "<id>"` added it took effect. Same for `AudioStreamIndex`.
4. **The default subtitle can silently force a burn-in.** Without an explicit
   index the server picked the default PGS track, answered
   `SubtitleStreamIndex=4&SubtitleMethod=Encode` and added
   `SubtitleCodecNotSupported`: a full video re-encode, Dolby Vision gone.
   Always send `SubtitleStreamIndex` (`-1` for none) with `MediaSourceId`.
   Text subtitles came back `DeliveryMethod: "Hls"` (WebVTT rendition in the
   manifest) and did not affect the copy.
5. **No transcoding profile + not direct-playable = three `false` flags and no
   error.** `SupportsDirectPlay/DirectStream/Transcoding` all false,
   `ErrorCode` null. The client has to treat that as "unplayable this way".
6. **Audio transcode target follows the order of the profile's `AudioCodec`
   list.** `aac,ac3,eac3` → `mp4a.40.2`; `eac3,ac3,aac` → `ac-3` for a DTS
   source. Put the surround codec first if 5.1 over HDMI matters.
7. **`MediaSource.Container` is ffprobe's name, not the extension**: an `.mp4`
   reported `"mov"`. List `mp4,m4v,mov` together.
8. **`TranscodeReasons` is not a reliable "is the video re-encoded" signal.**
   With `VideoRangeTypeNotSupported` present the server still stream-copied
   (see 5.3). The authoritative answer is the session:
   `GET /Sessions?deviceId={DeviceId}` → `TranscodingInfo`
   `{IsVideoDirect, IsAudioDirect, VideoCodec, AudioCodec, Container, TranscodeReasons, HardwareAccelerationType}`.
   This is the exact analogue of the Plex `videoDecision == "copy"` /
   `audioDecision == "copy"` check Dusk already makes in
   `PlexService+Playback.swift` before it accepts a remux.
9. **The HLS media playlist is a complete VOD playlist from the first
   request** (`#EXT-X-PLAYLIST-TYPE:VOD`, version 7, `#EXT-X-MAP` init
   segment, every segment listed; 2 571 lines for a 2 h 10 film). Segment
   durations are keyframe-aligned when copying (6.006 s, 11.512 s, …,
   `TARGETDURATION:16`). Seeking is the player's job; `StartTimeTicks` in the
   request body did not appear in the URL.
10. **Stopping matters.** `DELETE /Videos/ActiveEncodings?deviceId=…&playSessionId=…`
    answered `204` and ended the ffmpeg job. Dusk's
    `stopTranscodeSession` / `pingTranscodeSession` have direct twins.
11. `EnableTranscoding: false` and `AllowVideoStreamCopy: false` in the body
    had no visible effect on the response in these probes. Do not build the
    "remux only" guarantee on those flags; build it on the profile and on the
    `TranscodingInfo` check.

### 5.2 The master playlist trap [live]

For an **HDR** source the master playlist always carries two variants, even
when the transcoding profile lists only `hevc`:

```text
#EXT-X-STREAM-INF:BANDWIDTH=14450153,…,VIDEO-RANGE=PQ,CODECS="hvc1.2.4.L153.B0,ec-3",SUPPLEMENTAL-CODECS="dvh1.08.10/db1p",RESOLUTION=1920x1038,FRAME-RATE=23.976
#EXT-X-STREAM-INF:BANDWIDTH=14450153,…,VIDEO-RANGE=SDR,CODECS="avc1.424029,ec-3",RESOLUTION=1920x1038,FRAME-RATE=23.976
```

The second one is an H.264 SDR re-encode with tone mapping, at the same
advertised bandwidth. AVPlayer chooses variants by display capability, so on
an SDR panel (or with HDR switched off) it will take that variant and the
server starts a 4K tone-mapping transcode without anyone asking. That breaks
Dusk's rule that quality transcoding is never automatic.

Mitigation, in order of preference:

1. Load the **media playlist directly** (`main.m3u8` with the same query
   string, which is what the first variant line points at) instead of
   `master.m3u8`. Dusk then decides HDR vs SDR itself, as it does on Plex.
2. Or filter the master through the existing `AVAssetResourceLoader` path
   (`RemuxHLSLoader`), dropping every variant whose `CODECS` is not the copy.

SDR sources produced a single variant.

### 5.3 Dolby Vision, HDR10+ and Atmos through the remux [live]

fMP4 init segments were fetched and their boxes inspected:

| Source | Range types claimed in profile | Init segment | Master playlist |
| --- | --- | --- | --- |
| MKV DV 8.1 (`DOVIWithHDR10`) | includes `DOVIWithHDR10` | `hvc1` + `hvcC` + **`dvvC`** (profile 8, level 10, rpu 1, el 0, bl 1, compat id 1) | `VIDEO-RANGE=PQ`, `CODECS="hvc1…"`, `SUPPLEMENTAL-CODECS="dvh1.08.10/db1p"` |
| same file | HDR10 only, no DOVI values | `hvc1` + `hvcC`, **no `dvvC`** — served as HDR10 | still advertises `SUPPLEMENTAL-CODECS="dvh1.08.10/db1p"` (inconsistent with the init segment) |
| MKV DV 7 FEL (`DOVIWithEL`) | includes `DOVIWithEL` | **`dvh1`** + `hvcC` + **`dvcC`** (profile 7, level 6, rpu 1, el 1, bl 1, compat id 6) | plain `hvc1` PQ, no supplemental codecs |
| same file | without `DOVIWithEL` | `hvc1` + `hvcC`, no DV box — HDR10 base layer | plain `hvc1` PQ |
| MKV HDR10+ | includes `HDR10Plus` | `hvc1` | `SUPPLEMENTAL-CODECS="hvc1.2.4.L150.B0/cdm4"` |
| MKV E-AC-3 JOC | — | `ec-3` with a **15-byte `dec3`** (JOC trailer present) | `CODECS="…,ec-3"` |

In all rows `TranscodingInfo.IsVideoDirect` and `IsAudioDirect` were `true`.

Consequences for Dusk:

- **The server strips Dolby Vision for you when the profile does not claim
  it**, and still copies the video. That is the HDR10 fallback Dusk implements
  by hand on Plex. On Jellyfin it is a profile switch, not a second code path.
- **DV 8.1 is signalled the modern way** (HEVC base entry + `dvvC` +
  `SUPPLEMENTAL-CODECS`), which is what AVPlayer wants for cross-compatible
  profile 8.
- **DV 7 can be had with its `dvcC` intact** by claiming `DOVIWithEL` (and
  `DOVIWithELHDR10Plus`). That is the input `DolbyVision7HLSProxy` +
  `DuskDovi` need. Claim it only when the conversion will run; otherwise leave
  it out and take the server's HDR10 base layer. Whether the server removes
  the RPU NAL units or only the config box in the fallback case was not
  checked at bitstream level.
- **Jellyfin keeps the Atmos signalling.** The `dec3` box arrives with the
  `flag_ec3_extension_type_a` trailer, so `EAC3JOCSignaling` /
  `RemuxHLSLoader`'s `dec3` patch (needed because Plex writes a 13-byte box)
  is unnecessary here. `patchedInitSegment` returns nil when there is nothing
  to patch, so routing a Jellyfin remux through it would be harmless, but it
  should simply be skipped.
- **Do not trust the master playlist's DV claim**; it advertised
  `dvh1` for a stream whose init segment had no DV box. Decide from the
  profile that was sent.

`VideoRangeType` values seen on the server: `SDR`, `HDR10`, `HDR10Plus`,
`DOVI` (profile 5), `DOVIWithHDR10` (8.1), `DOVIWithHLG` (8.4),
`DOVIWithEL` (7), `DOVIWithELHDR10Plus` (7 + HDR10+). `MediaStream` also
carries `DvProfile`, `DvBlSignalCompatibilityId`, `CodecTag`
(`dvh1`/`dvhe`/`hvc1`/`av01`), which is everything `StreamResolver`'s
`dolbyVision*` functions read from Plex today.

### 5.4 Recommended shape for Dusk

Keep the decision where it is. `StreamResolver` already knows, per file, which
engine can direct-play it and when a remux is worth it; no surveyed client has
a better local decision than that. Use the DeviceProfile to **express** the
decision to the server rather than to ask the server to make it:

| Dusk ladder step | Request | Accept when |
| --- | --- | --- |
| 1. Direct play (AVPlayer or VLCKit) | Profile A (`[{Type: Video}]`, no transcoding profiles), explicit `MediaSourceId` | `SupportsDirectPlay` true → `/Videos/{id}/stream?static=true&mediaSourceId=…` |
| 2. Lossless remux for AVPlayer (HDR, DV, Atmos, DV 7 → 8.1) | Profile B built **for this file**: no direct-play entry, one HLS/`mp4` transcoding profile whose `VideoCodec` is exactly the source codec and whose `AudioCodec` is exactly the chosen track's codec, range-type list = what this device and this attempt can show, `SubtitleStreamIndex` explicit | `TranscodeReasons` has no video/audio codec reason, then after start `TranscodingInfo.IsVideoDirect && IsAudioDirect`; otherwise stop the encoding and fall through, as with Plex |
| 3. Server stream fallback (video copied, audio converted) | Same, with `AudioCodec: "eac3,ac3,aac"` | `IsVideoDirect` |
| 4. Manual quality | Full transcoding profile (`hevc,h264`), `MaxStreamingBitrate` from the picker | always |

Rules of thumb collected from the survey and the probes:

- Build the profile per attempt. It is a few dozen lines of JSON, not a
  capability database.
- Send a huge `MaxStreamingBitrate` (hundreds of Mbit/s) for steps 1 to 3 so
  bitrate never becomes a transcode reason; only the manual picker lowers it.
- `Container: "mp4"` in the transcoding profile is required for HEVC over HLS
  on Apple players (`ts` works for H.264 only in practice; with `ts` the server
  answered `SegmentContainer=ts` and kept offering HEVC).
- List subtitle formats per engine: VLCKit `Embed` for everything plus
  `External` for sidecars; AVPlayer `Hls` + `External` for `vtt` only, so
  bitmap subtitles never reach the server as a burn-in request unless the
  user chose that.
- Bypass the master playlist for HDR (5.2).

## 6. Playback reporting

<!-- REPORTING-PENDING -->

## 7. Sign-in: Quick Connect

The whole flow was walked on the demo server **[live]**:

| Step | Call | Observed |
| --- | --- | --- |
| Is it on? | `GET /QuickConnect/Enabled` | `200 true`, no auth needed |
| Start | `POST /QuickConnect/Initiate` with `Authorization: MediaBrowser Client=…, Device=…, DeviceId=…, Version=…` (no token) | `200` `{Authenticated: false, Secret: <64 chars>, Code: "197020", DeviceId, DeviceName, AppName, AppVersion, DateAdded}`. Without the header: `400`. `GET`: `405`. |
| Poll | `GET /QuickConnect/Connect?secret=…` | same object; `Authenticated` flips to `true`. Unknown secret: `404`. |
| Approve (another, signed-in client) | `POST /QuickConnect/Authorize?code=197020&userId=…` | `200 true`; wrong code `404` |
| Finish | `POST /Users/AuthenticateWithQuickConnect` `{"Secret": "…"}` | `200` with the same shape as `AuthenticateByName`: `{AccessToken, ServerId, SessionInfo, User}`. Before approval: `404`. |

The code is six digits and the `DeviceName` / `AppName` from the header are
what the approving user sees, so they must be human-readable.

This is structurally the same as Dusk's existing Plex link flow
(`PlexService+Auth.generatePin` / `checkPin`, the code screen in
`Features/Account/SignInView.swift`): show a short code, poll, receive a
token. The Apple TV code screen can be reused almost unchanged; only the
instruction line differs ("Open Jellyfin on another device → Quick Connect →
enter this code" instead of plex.tv/link).

<!-- QUICKCONNECT-UX-PENDING -->

## 8. Server discovery

<!-- DISCOVERY-PENDING -->

<!-- ARCHITECTURE-PENDING -->

## 10. Pitfalls checklist

### 10.1 Authentication header [live unless marked]

| Credential carrier | 12.4.0 result |
| --- | --- |
| `Authorization: MediaBrowser Client="…", Device="…", DeviceId="…", Version="…", Token="…"` | `200` |
| `Authorization: MediaBrowser Token="…"` (token only), also unquoted | `200` |
| `?ApiKey=…` (name is case-insensitive, `apikey` works) | `200` |
| `?api_key=…` | **`401`** |
| `X-Emby-Token`, `X-MediaBrowser-Token` | **`401`** |
| `X-Emby-Authorization: MediaBrowser …` | **`401`** |
| `Authorization: Emby …`, `Authorization: Bearer …` | **`401`** |
| `/emby/…` path prefix | **`404`** |

Every legacy carrier that older clients, blog posts and half of GitHub still
use is dead on this server. Use exactly one header form and, for URLs handed
to a player, the `ApiKey` query parameter.

- Header values are **percent-decoded** by the server:
  `Device="Marvin%E2%80%99s%20iPhone"` was stored as `Marvin’s iPhone`.
  Percent-encode `Client`, `Device`, `DeviceId` and `Version`. A literal `"`
  inside a value gives `400`. Device names come from the user
  (`UIDevice.current.name` is "iPhone" without the entitlement, but tvOS and
  macOS return real names with apostrophes and umlauts).
- `Client` and `Device` are what the server dashboard and the Quick Connect
  approval prompt display.
- Paths are case-insensitive (`/system/info/public` works). Query parameter
  names are too.

### 10.2 DeviceId and tokens [live]

- Logging in again with the **same `DeviceId`** returns a new token and the
  previous token immediately answers `401`.
- A Quick Connect login with a *different* `DeviceId` left the first session
  valid.

So one `DeviceId` holds one token. Anything in Dusk that could hold two
sessions at once on one device must not share a `DeviceId`:

- several Jellyfin users on one Apple TV (the Plex Home equivalent),
- the tvOS Top Shelf extension if it ever talks to the server itself (today it
  reads an App Group snapshot, which sidesteps this),
- the screenshot / mock harness and unit tests against a real server.

Derive it as `hash(installID + serverID + userID)` rather than reusing Plex's
`clientIdentifier` verbatim. `POST /Sessions/Logout` (`204`) revokes the token.

### 10.3 Units and formats [live]

- **Ticks are 100 ns.** `RunTimeTicks: 78172470000` is 7 817.2 s. Plex is
  milliseconds (`duration`, `viewOffset`), so the conversion factor between
  the two backends is 10 000, and between ticks and `TimeInterval` 10 000 000.
  Applies to `RunTimeTicks`, `UserData.PlaybackPositionTicks`,
  `Chapters[].StartPositionTicks`, `MediaSegments` `StartTicks` / `EndTicks`,
  and every reporting field.
- **Not everything is ticks**: trickplay `Interval` is **milliseconds**
  (`10000` = one thumbnail per 10 s), bitrates are bits per second.
- Use `Int64` for ticks. A 3 h film is 108 000 000 000, past `Int32`.
- **Dates carry seven fractional digits**: `"2026-06-18T11:06:59.8066228Z"`.
  On macOS 27 `JSONDecoder.dateDecodingStrategy = .iso8601` and
  `Date.ISO8601FormatStyle` parse it, plain `ISO8601DateFormatter()` does not
  (needs `.withFractionalSeconds`, and then rejects dates *without* a
  fraction). Dusk's floor is iOS 18, where this was not tested. Decode dates
  through one tolerant custom strategy and make every date optional.
- **Ids are 32 hex characters without dashes** in JSON
  (`980dffd6dfa0d8cfd69e5bd6b350e983`), but the server itself emits the dashed
  form in `TranscodingUrl` paths. Both are accepted in requests; normalise to
  the undashed form before using an id as a dictionary key.
- JSON keys are PascalCase. Absent beats `null`: an unplayed item's `UserData`
  was `{PlaybackPositionTicks, PlayCount, IsFavorite, Played, Key, ItemId}`
  with no `PlayedPercentage` or `LastPlayedDate` at all.

### 10.4 Images [live]

`GET /Items/{id}/Images/{Primary|Backdrop|Logo|Thumb|Banner}[/{index}]?tag=…&maxWidth=…&quality=…&format=…`

- **No authentication.** Image URLs carry no token, which is friendlier than
  Plex's `X-Plex-Token` photo transcoder URLs (nothing to redact, nothing to
  rotate on a profile switch).
- **With `tag`**: `Cache-Control: public, max-age=31536000, immutable`,
  `ETag: "<tag>"`, `Vary: Accept`; `If-None-Match` gives `304`.
  **Without `tag`**: only `Cache-Control: public`, so `URLCache` falls back to
  heuristic freshness and artwork goes stale or gets re-fetched.
- The tag is a cache-buster, not a validator: a wrong tag still returns the
  image. Always take it from the item (`ImageTags.{Type}`,
  `BackdropImageTags[i]`, `SeriesPrimaryImageTag`, `ParentBackdropImageTags`,
  `ParentLogoImageTag`, person `PrimaryImageTag`, chapter `ImageTag`) and put
  it in the URL, which also makes the URL a correct cache key for
  `DuskAsyncImage`.
- A missing image type is `404` (`Banner` on a film that has none), so pick
  the type from `ImageTags` instead of probing.
- `format=Webp` works (the WebP was *larger* than the JPEG for a poster in
  this probe); default is JPEG.
- `ImageBlurHashes` is keyed type → tag → hash.

### 10.5 Things that are unauthenticated, and things that are not [live]

| Endpoint | Auth |
| --- | --- |
| `/System/Info/Public`, `/QuickConnect/Enabled`, `/Users/Public`, `/Branding/Configuration` | none |
| `/Items/{id}/Images/…` | none |
| `/Videos/{id}/stream?static=true` | **none** (answered `206` with no credentials) |
| `/Videos/{id}/Trickplay/{width}/tiles.m3u8`, `/{index}.jpg` | required |
| `/MediaSegments/{id}` | required |
| `/Items/{id}/Download`, `/Items/{id}/File` | required |

Add `ApiKey` to stream URLs anyway; an unauthenticated stream endpoint is a
long-standing server issue and should be expected to close.

### 10.6 Skip markers and trickplay [live]

- `GET /MediaSegments/{itemId}` →
  `{"Items":[{"Id","ItemId","Type":"Intro","StartTicks":3291660771,"EndTicks":4094090000},{"Type":"Outro",…}],"TotalRecordCount":2,"StartIndex":0}`.
  The demo server's Intro Skipper plugin feeds this API; the plugin's own
  legacy routes (`/Episode/{id}/IntroTimestamps`, `/IntroSkipperSegments`,
  `/Timestamps`) are `404`. One code path: `MediaSegments`. Maps onto
  `PlexMarker` (`intro` / `credits`).
- Trickplay metadata sits on the item when `Fields=Trickplay` is requested:
  `Trickplay[mediaSourceId]["320"] = {Width: 320, Height: 172, TileWidth: 10, TileHeight: 10, ThumbnailCount: 782, Interval: 10000, Bandwidth: 9681}`.
  Sheets are `GET /Videos/{id}/Trickplay/320/{n}.jpg?mediaSourceId=…`
  (a 10 × 10 sheet, about 1.2 MB). Thumbnail `i` is on sheet
  `i / (TileWidth × TileHeight)` at column `i % TileWidth`, row
  `(i / TileWidth) % TileHeight`; time is `i × Interval` ms. That fills
  `PlexScrubPreviewSource`'s role (Plex BIF) with a different container, and
  Dusk's generated-preview fallback still applies when a library has
  trickplay off (only two of the 25 test movies had it).

### 10.7 Still-working legacy routes [live]

`/Users/{userId}/Views`, `/Users/{userId}/Items`, `/Users/{userId}/Items/Resume`
all answered `200`, next to their modern forms `/UserViews`, `/Items?userId=`,
`/UserItems/Resume`. Write against the modern forms only; given what happened
to the legacy auth carriers, the legacy routes should be assumed to be next.
