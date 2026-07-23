# Dusk Plex Data Layer

Agent-facing map for Dusk's Plex data layer. Plex is the only media/playback
backend; views call view models, view models call `PlexService`, and
`PlexService` is the Plex network boundary. The optional Seerr request companion
has a separate boundary documented in `docs/seerr-integration.md`.

## Responsibilities
- `PlexService/` owns auth, discovery, request helpers, endpoints, playback
  reporting, direct-play/transcode URLs, and image helpers.
- `Models/` owns Plex response shapes plus app-level playback models.
- `PlexService` is `@MainActor @Observable` and is injected from `DuskApp`.
- Plex is the source of truth. Do not persist metadata except for explicit
  offline/download support.
- No generic provider abstraction. Seerr is not a media provider. Add focused
  Plex methods in the existing same-type extension files.

## Auth And Server Discovery
Files: `PlexService.swift` for shared state and persisted bootstrap;
`PlexService+Auth.swift` for PIN auth and token lifecycle;
`PlexService+Servers.swift` for resource lookup, probing, endpoint refresh, and
server-token recovery; `KeychainHelper.swift` for token storage.

Tokens and persisted state:
- `primaryAccountToken`: the full Plex account token established by device-link
  sign-in. It is the durable authority for listing and switching Plex Home
  members and is stored in Keychain.
- `activeAccountToken`: the identity used for account/resource requests. With no
  multi-user Plex Home it is the primary token; after a Home switch it is the
  switched user's token. It is persisted only when automatic Home sign-in is on.
- `serverAuthToken`: selected-server token discovered for the active identity,
  saved in Keychain and cleared whenever that identity changes.
- `connectedServer`: tokenless encoded server metadata in UserDefaults. Never
  restore an access token from this payload.
- `serverBaseURL`: selected connection URI in UserDefaults.
- `clientIdentifier`: stable UUID sent on every Plex request.

Flow:
1. `generatePin(strong:)` posts to `https://plex.tv/api/v2/pins`.
2. `authURL(for:)` builds Plex's hosted auth page URL for the PIN. `SignInView`
   opens it in an in-app `SFSafariViewController` on iPhone/iPad, but for an iOS
   app on macOS (`isiOSAppOnMac`/`isMacCatalystApp`, where that sheet dismisses
   itself immediately) it opens the external browser instead. Polling is started
   before the browser opens and is independent of the browser's lifecycle:
   closing/dismissing the browser must **not** cancel sign-in — the `plex.tv/link`
   code stays on screen as the fallback and only the explicit Cancel button (or a
   real ~120 s poll-window timeout) ends it. Cancellation exits polling silently;
   the "Sign-in timed out" message is reserved for the full window elapsing.
3. `checkPin(_:)` polls until `authToken` appears.
4. `setAuthToken(_:)` stores the primary token and clears stale account/server
   state on account change.
5. Account bootstrap fetches Plex Home users from `/api/v2/home/users`. Zero or
   one usable member keeps the legacy flow; multiple members require a user
   selection unless a remembered active Home session is valid. Fast user
   switching uses the separate legacy `/api/home/users/<id>/switch` route.
   Protected members send a transient PIN; Dusk never stores it.
6. `discoverServers()` fetches `/api/v2/resources` as the active identity with
   HTTPS/relay and keeps
   resources whose `provides` contains `server`.
7. `connect(to:)` probes candidates, validates `/library/sections`, and calls
   `setServer(...)`.

Plex Home invariants:
- Home membership and switching use the primary token. Server discovery,
  current-user lookup, metadata, history, and playback use the active token.
- Select the Home identity before discovering servers; members can have
  different server/library access.
- A switch invalidates current-user, entitlement, and server authorization
  caches. Reconnect to the previous server identifier only if it appears in the
  new identity's resources.
- Automatic sign-in remembers the switched session token in Keychain, not the
  Home PIN. With automatic sign-in off, a cold Home switch requires internet.
- `activeProfileID` is the local persistence boundary for downloads, cached
  offline metadata, and delayed watch-state actions.

Discovery behavior to preserve:
- Connections sort local non-relay, remote non-relay, relay; HTTPS wins within
  a priority. HTTP fallbacks and unreachable-address filtering are built in.
- `connect(to:)` probes all candidates **concurrently** (`probeConnections`) and
  commits the highest-priority one that works. The race is priority-preserving:
  a success is only committed once no higher-priority candidate can still win —
  either they have all resolved, or `connectionPreferenceGrace` (1.5 s) elapsed
  after the first success. This keeps local preferred at home without blocking on
  a hung LAN address when away. Do not regress this back to a sequential loop.
- The winning connection URI is remembered (`PlexLastGoodConnectionURI`) and
  floated to the front of *its own priority tier* on the next connect, never
  across tiers. `resolvedActiveConnection` / `isConnectedRemotely` expose whether
  the live session is local or remote/relay.
- Fresh auth has a propagation retry window; missing server tokens or 401s may
  become `.authenticationPending`.
- A server request 401 tries authorization recovery once; repeated 401 clears
  the selected server.
- Selected endpoints refresh after network errors or selected 4xx/5xx statuses.

Remote-streaming entitlement (Plex Pass): since April 2025 Plex only allows
remote playback of personal video media when the server owner (or the streaming
user) holds an active Plex Pass / Remote Watch Pass; local streaming stays free.
`PlexService+Entitlement.swift` reads the account's `subscription.active` from
`/api/v2/user` (cached in `accountSubscriptionActive`) and
`remoteStreamingRestriction()` returns `.ownerNeedsPlexPass` only for an **owned**
server reached **remotely** with a positively-inactive subscription. The player's
online-playback path checks it and shows a clean message instead of failing
slowly. Unknown/shared cases never pre-empt playback.

## Request And Decode Helpers
File: `PlexService+Networking.swift`.
- Use `plexTVRequest<T>` for `plex.tv` JSON.
- Use `rawServerRequest` for selected-server calls. It applies the server token,
  recovers auth, refreshes endpoints, and returns `Data`.
- Use `fetchMetadata<T>` for `MediaContainer.Metadata`.
- Use `fetchDirectories<T>` for `MediaContainer.Directory`.
- Use `fetchHubs(...)` for `MediaContainer.Hub`.
- Use `decodeJSON(_:from:)` so decode failures become `PlexServiceError`.
- Use `buildURL(base:path:queryItems:)` for query parameters.
- `applyHeaders(to:token:)` centralizes Plex headers, platform/device metadata,
  and optional `X-Plex-Token`.
- Plex requests should identify Dusk consistently with the stable client
  identifier, product/version, platform, and device name headers expected by
  Plex. Keep header changes centralized in `applyHeaders`.

Pitfalls:
- `rawServerRequest` requires `serverBaseURL` plus a usable server token.
- Keep primary-account, active-account, and server-token usage distinct. Home
  membership/switch calls use the primary account, `plex.tv` resources use the
  active account, and selected-server APIs use the server token.
- Plex is inconsistent: optional fields, int-or-bool flags, unknown media types,
  and multiple person id shapes are normal.
- Do not log token-bearing URLs. Use sanitized playback URL logging where it
  exists.
- Be intentional about cache policy; `PlexService` uses `AppImageCache.shared`.

## Library, Search, Hubs, And Detail Endpoints
File: `PlexService+Library.swift`.

Library:
- `getLibraries()` -> `/library/sections`, decoded as `[PlexLibrary]`.
- `getLibraryItems(sectionId:start:size:sort:filters:)` ->
  `/library/sections/{sectionId}/all` with Plex pagination.
- `getLibraryItemCount(sectionId:filters:)` reads `totalSize`/`size` from a
  one-item page.
- `getLibraryFilters(sectionId:)` and `getLibraryFilterValues(path:)` decode
  filter directories.
- `getLibraryCollections(sectionId:)` -> `/library/sections/{sectionId}/collection`
  filter values, decoded as `[PlexLibraryCollection]` (key + title). Fetch a
  collection's items with `getLibraryItems(filters: ["collection": key])`.

Hubs and search:
- `getHubs()` -> `/hubs`.
- `getLibraryHubs(sectionId:count:)` -> `/hubs/sections/{sectionId}` with
  `includeGuids=1`.
- `getContinueWatching()` -> `/hubs/continueWatching`, flattened from hubs.
- `getHubItems(hubKey:start:size:)` follows the hub key and merges `Metadata`
  plus `Directory`.
- `search(query:)` -> `/hubs/search` with `limit=10`, no collections, and GUIDs,
  wrapped as `[PlexSearchResult]`.

Detail and hierarchy:
- `getMediaDetails(ratingKey:)` -> `/library/metadata/{ratingKey}` with markers
  and GUIDs; this feeds detail screens, exact Seerr matching, and playback
  resolution.
- `getSeasons(showKey:)` and `getEpisodes(seasonKey:)` use
  `/library/metadata/{ratingKey}/children`.
- `getNextEpisode(after:)` walks current season episodes, then later seasons.
- `getMediaDetailsPayload` and `getChildrenPayload` return raw data for
  `PlexMetadataCache` and downloads. Keep their endpoint semantics stable.

Where to edit:
- Browse/library/detail endpoints: `PlexService+Library.swift`.
- Cast/person endpoints: `PlexService+People.swift`; account/history endpoints:
  `PlexService+History.swift`.
- Playback progress/watch state/direct play/transcode URLs:
  `PlexService+Playback.swift`.
- New response shapes: `Dusk/Sources/Models/`, near the closest model.

## Playback URL Handling
File: `PlexService+Playback.swift`.
- Direct play uses `{serverBaseURL}{part.key}` plus `X-Plex-Token` in the URL
  query because AVPlayer/VLCKit load the URL directly.
- Manual video transcoding uses Plex's universal transcoder flow:
  `/video/:/transcode/universal/decision` first, then
  `/video/:/transcode/universal/start.m3u8` when the decision allows it.
- Non-original quality presets force `directPlay=0`, `directStream=0`,
  `protocol=hls`, a Generic client profile, and an H.264/AAC HLS transcode
  target. Do not add HEVC to the current mpegts HLS target without validating
  the resulting package on iOS and tvOS AVPlayer.
- Decision code `1001` means transcode available, `1000` means direct-play only,
  and codes `>= 2000` are treated as failures.
- Transcode start URLs also carry `X-Plex-Token` in the query because playback
  engines do not use `PlexService` request headers.
- Never log raw playback URLs; use `sanitizedPlaybackURLString(for:)`.

## Image URL And Data Handling
File: `PlexService+Images.swift`.
- Call `plexService.imageURL(for:width:height:)` from view models/UI helpers.
- With dimensions, URLs go through `/photo/:/transcode` using display-scaled
  pixel dimensions, `minSize=1`, and `upscale=0`.
- Without dimensions, `directImageURL(for:)` builds the server-relative URL
  without embedding a token.
- `imageRequestURLString(for:includeToken:)` accepts absolute URLs as-is and
  builds relative paths from `serverBaseURL`.
- `imageData(for:)` authenticates URLs matching the selected server
  scheme/host/defaulted port; other URLs are fetched as plain binary requests.
- `DuskAsyncImage` uses `DuskImageLoader`, delegating to
  `plexService.imageData(for:)`.
- `AppImageCache.shared` is the shared URL cache and can be cleared in settings.
- Image cache entries have a max TTL of 3 days. Older URL cache responses are
  discarded on read and reloaded on demand.
- Player scrub previews use Plex's BIF index endpoint
  `/library/parts/{partID}/indexes/sd`. The service downloads and parses the
  BIF file opportunistically for online playback only; failures return no
  preview source and should not affect normal image or playback behavior.

Pitfalls:
- Transcoded image and playback URLs can contain token-bearing query
  parameters. Avoid logging them raw.
- Cache keys include the full URL, including requested dimensions.
- Keep width and height optional; callers rely on poster/art/banner/logo
  fallbacks.

## Model Conventions
- List, hub, and search rows use `PlexItem`; full metadata uses
  `PlexMediaDetails`.
- `ratingKey` is the stable identity for most media models.
- Plex capitalized arrays map directly: `Media`, `Part`, `Stream`, `Genre`,
  `Role`, `Marker`, `Image`, etc.
- Most fields are optional because Plex varies by endpoint, media type, agent,
  library, and ownership.
- `PlexMediaType` decodes unknown raw values to `.unknown`.
- "Other Videos" (personal media / YouTube) sections report `type="movie"`; the
  section-level discriminator is `PlexLibrary.libraryType == .video`, classified
  from section `subtype == "clip"`, the none-agents
  (`tv.plex.agents.none`/`com.plexapp.agents.none`), or a "Plex Video Files"
  scanner prefix. Items from those sections are `type="movie"` with item
  `subtype == "clip"` — `PlexItem.isClip`/`PlexMediaDetails.isClip` is the
  per-item marker that drives 16:9 rendering and video-detail routing anywhere
  clips surface (hubs, search, continue watching, downloads).
- `PlexHub` decodes items lossily because search can return suggestion records
  that are not media-shaped.
- `PlexStream` decodes selected/default/forced/hearing-impaired as bool-ish
  values because Plex sends both ints and bools.
- `PlexItem` and `PlexMediaDetails` resolve `clearLogo` from either an explicit
  field or the `Image` array.
- `PlexMediaDetails.markers` are sorted for skip-intro/credits UI.
- Person id helpers tolerate `id`, filter query, and key suffixes.
- `AudioTrack` and `SubtitleTrack` are engine-facing app models, not raw
  responses.

## Extension Points
- Prefer same-type `PlexService` extensions by concern.
- Add new Plex envelopes near `MetadataResponse`, `DirectoryResponse`, or
  `HubResponse`.
- For offline/download-only metadata, expose raw payload helpers deliberately.
- For derived display data, check `PlexItemPresentation` and `MediaFormatting`.
- Keep Plex calls async/await; do not introduce Combine for service APIs.

## Safe-Change Checklist
- Keep network calls out of views.
- Use the existing helper matching the Plex envelope.
- Preserve account-token vs server-token separation.
- Preserve first-login auth propagation retries.
- Keep decoding tolerant and optional.
- Avoid logging tokens or token-bearing playback/image URLs.
- Hardware transcoding, HDR tone mapping, or other Plex Pass-gated server
  features may fail with authorization/server errors. Surface a clear failure
  and keep direct playback and browsing usable.
- Check downloads/offline users before changing raw payload helpers.
- If Swift source files are added, removed, or renamed, run `xcodegen generate`.
- For Swift changes, run the compile-only `xcodebuild` from `AGENTS.md`; for
  docs-only changes, no build is needed.
