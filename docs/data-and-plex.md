# Dusk Plex Data Layer

Agent-facing map for Dusk's Plex data layer. Plex is the only backend; views
call view models, view models call `PlexService`, and `PlexService` is the
network boundary.

## Responsibilities
- `PlexService/` owns auth, discovery, request helpers, endpoints, playback
  reporting, direct-play URLs, and image helpers.
- `Models/` owns Plex response shapes plus app-level playback models.
- `PlexService` is `@MainActor @Observable` and is injected from `DuskApp`.
- Plex is the source of truth. Do not persist metadata except for explicit
  offline/download support.
- No generic provider abstraction. Add focused Plex methods in the existing
  same-type extension files.

## Auth And Server Discovery
Files: `PlexService.swift` for shared state and persisted bootstrap;
`PlexService+Auth.swift` for PIN auth and token lifecycle;
`PlexService+Servers.swift` for resource lookup, probing, endpoint refresh, and
server-token recovery; `KeychainHelper.swift` for token storage.

Tokens and persisted state:
- `authToken`: Plex account token from `plex.tv`, saved as `PlexAuthToken`.
- `serverAuthToken`: selected server token, saved as `PlexServerAuthToken`.
- `connectedServer`: encoded `PlexServer` in UserDefaults.
- `serverBaseURL`: selected connection URI in UserDefaults.
- `clientIdentifier`: stable UUID sent on every Plex request.

Flow:
1. `generatePin(strong:)` posts to `https://plex.tv/api/v2/pins`.
2. `authURL(for:)` opens Plex's hosted auth page for the PIN.
3. `checkPin(_:)` polls until `authToken` appears.
4. `setAuthToken(_:)` stores the token and clears stale server state on account
   change.
5. `discoverServers()` fetches `/api/v2/resources` with HTTPS/relay and keeps
   resources whose `provides` contains `server`.
6. `connect(to:)` probes candidates, validates `/library/sections`, and calls
   `setServer(...)`.

Discovery behavior to preserve:
- Connections sort local non-relay, remote non-relay, relay; HTTPS wins within
  a priority. HTTP fallbacks and unreachable-address filtering are built in.
- Fresh auth has a propagation retry window; missing server tokens or 401s may
  become `.authenticationPending`.
- A server request 401 tries authorization recovery once; repeated 401 clears
  the selected server.
- Selected endpoints refresh after network errors or selected 4xx/5xx statuses.

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

Pitfalls:
- `rawServerRequest` requires `serverBaseURL` plus a usable server token.
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

Hubs and search:
- `getHubs()` -> `/hubs`.
- `getLibraryHubs(sectionId:count:)` -> `/hubs/sections/{sectionId}` with
  `includeGuids=1`.
- `getContinueWatching()` -> `/hubs/continueWatching`, flattened from hubs.
- `getHubItems(hubKey:start:size:)` follows the hub key and merges `Metadata`
  plus `Directory`.
- `search(query:)` -> `/hubs/search` with `limit=10`, no collections, wrapped
  as `[PlexSearchResult]`.

Detail and hierarchy:
- `getMediaDetails(ratingKey:)` -> `/library/metadata/{ratingKey}` with
  `includeMarkers=1`; this feeds detail screens and playback resolution.
- `getSeasons(showKey:)` and `getEpisodes(seasonKey:)` use
  `/library/metadata/{ratingKey}/children`.
- `getNextEpisode(after:)` walks current season episodes, then later seasons.
- `getMediaDetailsPayload` and `getChildrenPayload` return raw data for
  `PlexMetadataCache` and downloads. Keep their endpoint semantics stable.

Where to edit:
- Browse/library/detail endpoints: `PlexService+Library.swift`.
- Cast/person endpoints: `PlexService+People.swift`; account/history endpoints:
  `PlexService+History.swift`.
- Playback progress/watch state/direct play: `PlexService+Playback.swift`.
- New response shapes: `Dusk/Sources/Models/`, near the closest model.

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

Pitfalls:
- Transcoded image URLs can contain a token-bearing original URL as a query
  parameter. Avoid logging them.
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
- Check downloads/offline users before changing raw payload helpers.
- If Swift source files are added, removed, or renamed, run `xcodegen generate`.
- For Swift changes, run the compile-only `xcodebuild` from `AGENTS.md`; for
  docs-only changes, no build is needed.
