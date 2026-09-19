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

## Multi-Server Model
Dusk is connected to **every enabled server at once**. There is no "current
server" the user picks: the account's servers are discovered, connected in
parallel, and their content is merged. Server selection exists only as an
*order* (which server wins when a title is on several) and an *on/off switch*
per server, both in Settings -> Server Priority.

Files: `ServerPool.swift` (live sessions), `ServerPriorityStore.swift` (order +
enabled flags), `PlexServerConnection.swift` (one session), `ServerProbe.swift`
(the connection race), `ServerAvailability.swift` (aggregate state + UI wording).

- `PlexServerConnection` is one live session: `serverID` (machine identifier),
  `name`, `owned`, `sourceTitle`, `baseURL`, `token`, winning `connection`, plus
  `isLocal` / `isRemote` / `isRelay`. Everything that talks to a server resolves
  one of these first, so a request, an image URL, or a playback decision can
  never land on a different server than the item it belongs to.
- `ServerPool` (`plexService.pool`) holds `states: [String: ServerConnectionState]`
  (`idle`/`connecting`/`connected`/`unauthorized`/`offline(reason)`/`disabled`),
  the discovered `servers`, `connections` (connected, in priority order),
  `primary`, and `decoder(for:)`. `connectAll` probes up to four servers at a
  time and **commits each server's state the moment it resolves**, so one
  unreachable server never delays the others. A probe carries its own token, so
  two probes of the same server cannot consume each other's and report a good
  session as `.unauthorized`, and every commit re-checks two things: the pool's
  `generation` (see below) and whether the server is still enabled, because the
  user can switch it off while it is being probed.
- A **disabled server is never connected by accident**. `pool.connect(to:)`
  short-circuits to `.disabled`, and `rawServerRequest` fails fast rather than
  recovering it, so a stray request from a screen that has not reloaded yet
  cannot bring a switched-off server back.
- After a *successful* discovery, a server the pool knows about that plex.tv did
  not return is marked `.offline`: discovery sees the whole account, so a
  session restored from the last launch must not keep claiming it is connected.
- `pool.generation` is the session counter. `clear()` bumps it, and any probe
  that started earlier is discarded when it lands. Together with
  `PlexService.serverSessionToken` (profile + generation, captured before
  `discoverServers()` and re-checked after) this is what stops a connect pass
  from a previous Plex Home member re-registering that member's servers — and
  re-saving their tokens — into the session that replaced it.
- `pool.primary` is simply the highest-priority connected server. It is a
  fallback for the handful of things that are genuinely account-wide — the
  Seerr link and Live TV — and for a call site that has no item in hand. It is
  **not** "the current server": anything holding an item, library, hub or
  download record must pass that value's `serverID` instead. There are no
  single-server compatibility shims on `PlexService`.
- `ServerPriorityStore` (`plexService.serverPriority`) persists an ordered
  `[{machineIdentifier, isEnabled}]` in UserDefaults (`PlexServerPriority`). It
  is additive: `reconcile(discovered:)` appends unknown servers enabled at the
  end and never drops a server that simply did not answer this time; only
  sign-out prunes it. Every mutation bumps `revision`, which merged screens
  (Home, Libraries, Search) observe to know they must reload.
- `PlexService.serverContentRevision` is the `.task(id:)` key for merged
  screens: it changes when a server connects or drops, when the order or an
  enabled flag changes, or when the profile changes. Key a merged load on it
  rather than on a single server identifier.
- `ServerPool.availability` classifies the whole account for the UI:
  `unknown` / `connecting` / `ready(offlineServerNames:)` / `allDisabled` /
  `unreachable(reason:)`. `unknown` and `connecting` only mean "wait" while a
  pass is actually running: discovery can fail before a single server state
  exists (no internet, fresh install), so `ServerAvailabilityStateView` folds in
  the coordinator's `hasCompletedFirstPass` / `isConnecting` / `lastError` and
  shows the error with Retry instead of a spinner that never ends.
  `ServerStatusText` holds the words for one server
  ("Local", "Remote", "Relay", "Connecting…", "Offline", "Not authorized",
  "Disabled", "Your server", "Shared by X").

Tokens and persisted state:
- `primaryAccountToken`: the full Plex account token established by device-link
  sign-in. It is the durable authority for listing and switching Plex Home
  members and is stored in Keychain.
- `activeAccountToken`: the identity used for account/resource requests. With no
  multi-user Plex Home it is the primary token; after a Home switch it is the
  switched user's token. It is persisted only when automatic Home sign-in is on.
- Server state is **per server**, and together it is everything a cold launch
  needs to be usable before plex.tv answers:
  - Keychain `PlexServerAuthToken.<machineID>`: that server's token, written by
    the pool when it connects.
  - `PlexServerURL.<machineID>`: the endpoint the last successful session
    actually used.
  - `PlexLastGoodConnectionURI.<machineID>`: the connection that last won the
    probe race for that server. It can differ from the base URL above — an
    HTTPS connection whose HTTP fallback won reports the former and is reached
    over the latter — so both are kept.
  - `PlexServerSnapshots`: tokenless `PlexServer` snapshots of every server the
    account has seen, in priority order. Only `pool.connectAll` rewrites it, so
    a disabled server keeps its snapshot and costs no round-trip when it is
    turned back on.
- `PlexService.init` restores a session for every *enabled* snapshot that has a
  token and a remembered endpoint, so Home/Libraries/Search have content
  immediately; `ServerConnectionCoordinator`'s pass then verifies and refreshes
  them, and a restored endpoint that has since moved fails over on its next
  request. A restored session has no winning `PlexConnection` unless the base
  URL still matches one of the snapshot's connections, so its locality reads as
  unknown until the next probe.
- `PlexServerURL` / `PlexServerData` / `PlexLastGoodConnectionURI` and Keychain
  `PlexServerAuthToken` (the unsuffixed single-server keys) are **never
  written**. `migrateLegacySingleServerState()` reads them once on launch, moves
  their contents onto the per-server keys, and deletes them. `PlexServerID` is
  the one legacy key still kept: `ServerPriorityStore` seeds the first priority
  order from it, and only sign-out removes it.
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
7. `connectAllServers()` is the app's entry point: discover ->
   `serverPriority.reconcile(discovered:)` -> `pool.connectAll(...)`. It never
   fails because a server is unreachable; it throws only when the account itself
   cannot be used. `ContentView` mounts the tab shell first and runs this
   underneath, so nothing waits for the slowest server.
8. `reconnectServer(serverID:)` re-discovers and re-probes exactly one server.
   Use it to recover one server; it never touches the other sessions. The
   request layer goes through `recoverServer(serverID:)` instead, which
   coalesces concurrent callers onto one reconnect and applies the cooldown
   below.

Plex Home invariants:
- Home membership and switching use the primary token. Server discovery,
  current-user lookup, metadata, history, and playback use the active token.
- Select the Home identity before discovering servers; members can have
  different server/library access.
- A switch clears the whole pool (`tearDownServerSessions()`) and invalidates current-user,
  entitlement, and library-order caches. Server tokens belong to the identity
  that obtained them, so the teardown also forgets the token, base URL and
  last-good connection of **every** known server — the ones in the stored
  priority order and snapshots included, not just the ones this launch
  connected to — and cancels any in-flight per-server recovery. The priority order survives the switch;
  `reconcile` folds the new identity's server list into it, so a server the new
  member cannot see simply keeps its slot without being connected.
- Automatic sign-in remembers the switched session token in Keychain, not the
  Home PIN. With automatic sign-in off, a cold Home switch requires internet.
- `activeProfileID` is the local persistence boundary for downloads, cached
  offline metadata, and delayed watch-state actions.

Discovery behavior to preserve:
- Connections sort local non-relay, remote non-relay, relay; HTTPS wins within
  a priority. HTTP fallbacks and unreachable-address filtering are built in.
- Each server's candidates are probed **concurrently** (`ServerProbe`) and the
  highest-priority one that works is committed. The race is priority-preserving:
  a success is only committed once no higher-priority candidate can still win —
  either they have all resolved, or `connectionPreferenceGrace` (1.5 s) elapsed
  after the first success. This keeps local preferred at home without blocking on
  a hung LAN address when away. Do not regress this back to a sequential loop.
  Servers race each other too (`ServerPool.connectAll`, max four at a time), and
  the two levels are independent.
- The winning connection URI is remembered per server
  (`PlexLastGoodConnectionURI.<machineID>`) and floated to the front of *its own
  priority tier* on the next connect, never across tiers. Locality is read off
  the connection: `PlexServerConnection.isLocal` / `isRemote` / `isRelay`.
- Fresh auth has a propagation retry window; missing server tokens or 401s may
  become `.authenticationPending`.
- A 401 is **per server**: the request layer tries authorization recovery for
  that server once, then `pool.markUnauthorized(serverID:)`. It must never clear
  the pool — one revoked share cannot sign the user out of the servers that are
  working. Only sign-out and a Plex Home switch clear the pool.
- A server's endpoint is re-probed after network errors or selected 4xx/5xx
  statuses, again for that server alone.
- Recovery is **coalesced and rate-limited per server** (`recoverServer(serverID:)`):
  one reconnect at a time per server with every caller joined to it, and a
  `serverRecoveryCooldown` (30 s) after a failure during which requests to that
  server fail fast with its last reason. Otherwise a screenful of requests to an
  offline server becomes a screenful of plex.tv discoveries and probe races. An
  account-wide pass (`connectAllServers()`) and the explicit Retry in Server
  Priority clear the cooldown, because those are the user asking again.
- Account-level `.unauthorized` / `.notAuthenticated` are user-facing
  re-authentication, not retryable request failures. `FeatureErrorView`, the
  player overlay and load-error alert, and ContentView bootstrap replace Retry
  with Sign In. Sign In calls `signOut()` so `ContentView` presents `SignInView`.
  Successful re-auth runs home bootstrap and a fresh connect pass; it does not
  resume the failed screen or playback.
- `ServerConnectionCoordinator` (`App/ServerConnectionCoordinator.swift`) owns
  *when* a connect pass runs: first mount, profile switch, return to the
  foreground, and network-path change. One pass at a time; concurrent callers of
  the **same session** join the running one, while a pass belonging to a profile
  that has been left is cancelled rather than joined. A pass is skipped if the
  last one succeeded less than a minute ago and the pool still has a usable
  server. `refresh()` (user Retry, network change) never settles for the pass
  that is already running — that pass started before the reason for the retry
  existed — so it queues another one behind it. It is published in the
  environment, so any screen can offer a retry with `refresh()`.

Remote-streaming entitlement (Plex Pass): since April 2025 Plex only allows
remote playback of personal video media when the server owner (or the streaming
user) holds an active Plex Pass / Remote Watch Pass; local streaming stays free.
`PlexService+Entitlement.swift` reads the account's `subscription.active` from
`/api/v2/user` (cached in `accountSubscriptionActive`) and
`remoteStreamingRestriction(forServerID:)` returns `.ownerNeedsPlexPass` only for
an **owned** server reached **remotely** with a positively-inactive subscription.
The entitlement is account-wide but the *restriction is per server*, because
ownership and locality differ per session: one server can be restricted while
another plays fine. The playback source resolver demotes a restricted server to
last and only shows the Plex Pass message when every candidate is restricted.
Unknown/shared cases never pre-empt playback.

## Request And Decode Helpers
File: `PlexService+Networking.swift`.
- Use `plexTVRequest<T>` for `plex.tv` JSON.
- Use `rawServerRequest` for server calls. It takes an optional `serverID:`,
  resolves that server's `PlexServerConnection` from the pool (nil = the
  primary), applies **that server's** token, recovers auth, re-probes the
  endpoint, and returns `Data`.
- Use `fetchMetadata<T>` for `MediaContainer.Metadata`.
- Use `fetchDirectories<T>` for `MediaContainer.Directory`.
- Use `fetchHubs(...)` for `MediaContainer.Hub`.
- The fetch helpers decode through `pool.decoder(for: serverID)`, which stamps
  `serverID` onto every model it decodes. A hand-rolled `JSONDecoder` loses that
  stamp and produces unattributable items — always go through the pool.
- Use `decodeJSON(_:from:)` so decode failures become `PlexServiceError`.
- Use `buildURL(base:path:queryItems:)` for query parameters.
- `applyHeaders(to:token:)` centralizes Plex headers, platform/device metadata,
  and optional `X-Plex-Token`.
- Plex requests should identify Dusk consistently with the stable client
  identifier, product/version, platform, and device name headers expected by
  Plex. Keep header changes centralized in `applyHeaders`.

Pitfalls:
- `rawServerRequest` needs a connected server: either the one `serverID` names
  or the primary.
- Pass the item's `serverID` through. A call that falls back to the primary for
  an item that came from another server reads the wrong library, and with
  colliding rating keys it can silently read the *wrong item*.
- Keep primary-account, active-account, and server-token usage distinct. Home
  membership/switch calls use the primary account, `plex.tv` resources use the
  active account, and per-server APIs use that server's token.
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
- `PlexHub.librarySectionID` decodes int-or-string; `resolvedLibrarySectionID`
  falls back to the numeric suffix of `hubIdentifier`
  ("movie.recentlyadded.3" -> "3") because not every server sends the field.
  That id is what lets Home group a library's rows together.
- Build a changed hub with `PlexHub.replacingItems(_:)`, not the memberwise
  init: the init drops any field the call site forgets.
- `getLibraryHubs(sectionId:count:)` -> `/hubs/sections/{sectionId}` with
  `includeGuids=1`.
- `getContinueWatching()` -> `/hubs/continueWatching`, flattened from hubs.
- `getHubItems(hubKey:start:size:)` follows the hub key and merges `Metadata`
  plus `Directory`.
- `search(query:)` -> `/hubs/search` with `limit=10`, no collections, and GUIDs,
  wrapped as `[PlexSearchResult]`.

Account library order (`PlexService+LibraryOrder.swift`, `LibraryOrderStore`) —
the user's library order is **not** a PMS setting. It lives on plex.tv, per Plex
account, in the `experience` user setting. Order, pinning, and hiding are all the
same array: `sidebarSettings.pinnedSources`. Array position is the order.

- Read: `GET /api/v2/user?includeSubscriptions=1&includeProviders=1&includeSettings=1&includeSharedSettings=1`
  with the account token. `settings` -> the entry with `id == "experience"` ->
  `value` is a **stringified** JSON document -> decode it, then read
  `sidebarSettings.pinnedSources`.
- Write: `POST /api/v2/user/settings?sharedSettings=1`, `Content-Type: application/json`,
  body `{"value": "<stringified array of setting objects>"}` where the array holds
  one `{id:"experience", type:"json", value:"<stringified blob>", hidden:true}`.
  Double-stringified in both directions; that is Plex Web's own shape.
- A `pinnedSources` element carries `key`, `sourceType`, `machineIdentifier`,
  `providerIdentifier`, `directoryID`, `title`, `serverFriendlyName`, `isHidden`,
  and cloud/ownership flags. `key` is
  `["source", sourceType, machineIdentifier, providerIdentifier, directoryID]`
  joined with `--`. `machineIdentifier` is the PMS machine id, or the literal
  `"myPlex"` for cloud providers; `providerIdentifier` is
  `com.plexapp.plugins.library` for real PMS libraries.
- `sourceType` maps from the section type: movie->movies, show->tv, artist->music,
  photo->photos, clip->videos.
- Effective order (`LibraryOrderArrangement.effectiveOrder`): take the entries for
  **every enabled server's** machine id that are PMS libraries and not hidden, in
  array order, map (`machineIdentifier`, `directoryID`) to the section, then
  append every section the array does not mention (server priority first, then
  the server's own order). No entries at all means plain `/library/sections`
  order per server. The pairing must include the machine id: `directoryID` is a
  per-server counter, so keying on it alone aliases two servers' sections.
- Merge on write (`LibraryOrderArrangement.merged(existing:reordered:machineIdentifiers:)`):
  the participating servers' entries collapse into **one** contiguous block placed
  where the first of them was — the user's order is one cross-server list, not one
  block per server. Entries for cloud providers, disabled servers, servers that are
  not connected, and servers whose sections fetch **failed** are carried through
  verbatim. `writeOrder(userOrder:existing:servers:)` takes the participating servers
  keyed by machine identifier, because a never-pinned section's new entry has to be
  built from *its own* server; a section whose server is missing is skipped, never
  guessed at.
- HARD INVARIANT: never write entries for a server whose sections could not be
  read. A failed fetch looks exactly like "this server has no libraries", and the
  write would unpin that server's libraries in every Plex client.
  `LibraryOrderStore.machineIdentifiers` is the set that answered **with at least
  one section** and `failedServerIDs` the set that failed; the write path
  intersects them. A server that answered with *nothing* is in neither: it has no
  pins to write, and an empty answer is also what a still-scanning or half-started
  server returns, so it must not be able to delete what the account has pinned
  for it.
- `LibraryOrderStore` caches per `"<connected serverIDs in priority order>|<profileID>"`
  — priority order, not sorted, because reordering Server Priority changes the
  unpinned tail and must invalidate the cache — and commits each
  server's sections the moment they land (`applyServerSections`), so the library list
  paints from the first server rather than the slowest. `sections` is reassembled in
  server-priority order each time. Identify a section by `orderedSectionIdentities`
  (`PlexLibrary.id`, `"<serverID>|<key>"`), never by the bare section key — those
  are per-server counters that collide.

Traps:
- The write is a **full-blob replace**. Read the whole `experience` document,
  mutate only `sidebarSettings.pinnedSources` (plus `hasCompletedSetup`), and POST
  it back. A partial POST wipes the user's Plex Web home customization.
- Preserve `schemaVersion` exactly as read and never invent one — writing a newer
  value disables syncing in other clients.
- Preserve other servers' and cloud (`myPlex`) entries. Dropping them unpins those
  sources everywhere.
- A 404 or a missing `experience` setting means "never customized", not an error.
  Fall back to server order and keep browsing usable.
- Last writer wins. Re-read the blob immediately before every write; never write
  from cache.
- Decode the blob into `DuskJSONValue`, not a strict `Codable` struct: unknown keys
  must survive the round-trip.
- The setting is per **account**, not per server. One flat list spans every server
  and provider, and Plex Home members each have their own (their own token), so the
  cache identity has to include the profile.
- Both calls pass `timeoutInterval: 6` to `rawPlexTVRequest` instead of the session's
  15s default. Home and Libraries await the read before their first paint, so a
  LAN-only session (PMS reachable, internet not) would otherwise hold that paint for
  the full 15s. Keep any future plex.tv call that blocks a first paint on the same
  short timeout.

Detail and hierarchy:
- `getMediaDetails(ratingKey:)` -> `/library/metadata/{ratingKey}` with markers
  and GUIDs; this feeds detail screens, exact Seerr matching, and playback
  resolution.
- `getSeasons(showKey:)` and `getEpisodes(seasonKey:)` use
  `/library/metadata/{ratingKey}/children`.
- `getNextEpisode(after:)` walks current season episodes, then later seasons.
- `getMediaDetailsPayload` and `getChildrenPayload` return raw data for
  `PlexMetadataCache` and downloads. Keep their endpoint semantics stable.

Subtitle search and download (`PlexService+Subtitles.swift`):
- Plex Media Server proxies OpenSubtitles, so Dusk needs no OpenSubtitles
  account, API key, or rate limiting of its own.
- `searchSubtitles(ratingKey:languageCode:hearingImpaired:forced:)` ->
  `GET /library/metadata/{ratingKey}/subtitles?language=&hearingImpaired=0|1&forced=0|1`,
  decoded through `StreamResponse<PlexSubtitleSearchResult>`. `language` is the
  ISO 639-1 code Plex Web sends (`en`); servers also accept 639-2 (`eng`), and
  the value is only trimmed/lowercased, never mapped. Servers may answer
  `size: 0` with no `Stream` array, which decodes to `[]`.
- `downloadSubtitle(ratingKey:result:)` -> `PUT` on the same path with
  `key` plus the optional `codec`/`language`/`hearingImpaired`/`forced`/
  `providerTitle`/`title` params, sent only when the result carries them. The
  server fetches the file, writes it as a sidecar, and refreshes the item; the
  200 body is empty. Refetch `getMediaDetails(ratingKey:)` to see the new track.
- The PUT passes `timeoutInterval: 30` to `rawServerRequest` because the provider
  round-trip routinely exceeds the session's 15s request default. 30s is also the
  session's `timeoutIntervalForResource`, so it is the practical ceiling.
- `externalSubtitleURL(for:)` builds the item's server base URL + `stream.key` +
  `X-Plex-Token` for sidecar streams (`streamType == .subtitle` with a non-nil `key`) so the
  engine can attach them via VLCKit `addPlaybackSlave`. Server token, never the
  account token; log only through `sanitizedPlaybackURLString`.
- `canDownloadSubtitles(serverID:)` gates the affordance per server: an owned
  server and a non-restricted
  Home user. Shared-server and managed-profile users cannot write sidecars, so
  hide the entry point instead of surfacing a 403.

Where to edit:
- Browse/library/detail endpoints: `PlexService+Library.swift`.
- Cast/person endpoints: `PlexService+People.swift`; account/history endpoints:
  `PlexService+History.swift`.
- Playback progress/watch state/direct play/transcode URLs:
  `PlexService+Playback.swift`.
- Subtitle search/download endpoints: `PlexService+Subtitles.swift`.
- Account-level plex.tv settings (library order): `PlexService+LibraryOrder.swift`,
  with the shared state in `LibraryOrderStore.swift`.
- New response shapes: `Dusk/Sources/Models/`, near the closest model.

## Live TV And Guide Endpoints

Files: `PlexService+LiveTV.swift` and `PlexLiveTV.swift`.

- Live TV uses the highest-priority enabled server only (v1). Discover that
  server's EPG provider through `/media/providers`.
  The provider advertises its grid path and DVR identifier; do not hard-code
  `tv.plex.providers.epg.*` identifiers.
- Load stations from the provider's `/lineups/dvr/channels` path and currently
  airing programs from `/watchnow/all`.
- Date guide requests use the advertised grid key with repeated
  `channelGridKey` values plus `date=yyyy-MM-dd`. `getLiveTVGuide` batches
  station keys to keep URLs bounded.
- Tuning is `POST /livetv/dvrs/{dvrID}/channels/{channel-id}/tune`. The channel
  `id` from the lineup is Plex's internal DVR mapping key; never substitute the
  display-only `vcn` value. Send a distinct `X-Plex-Session-Identifier` with the
  tune request and reuse it for timeline keepalives. Plex server
  versions return playable media under direct Metadata or nested
  `MediaSubscription > MediaGrabOperation > Metadata/Video`; nodes can be
  objects or arrays, so decoding must tolerate every form.
- Feed the returned `/livetv/sessions/{sessionID}` key to Plex's universal HLS
  decision/start flow with direct stream enabled. The session key is a virtual
  resource, not a library file. Use the response `Part.key` consumer URL only
  when the decision explicitly reports direct-play-only delivery.
- Program-guide history is metadata, not a recording catalogue. A tuned HLS
  session can seek only inside Plex's sliding time-shift window; never imply
  that an arbitrary past guide item is playable.

## Playback URL Handling
File: `PlexService+Playback.swift`.
- Direct play uses `{connection.baseURL}{part.key}` — the connection of the
  server the item came from — plus `X-Plex-Token` in the URL
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
  builds relative paths from the connection of the item's server, resolved via
  `pool.connection(for:)`.
- `imageData(for:)` authenticates URLs matching a connected server's
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

## Identity Across Servers
Rating keys, section keys, and hub identifiers are **per server** counters: two
servers hand out the same `ratingKey` for different titles. Identity therefore
always carries the server.

- `Models/PlexServerScoped.swift` defines `CodingUserInfoKey.duskServerID`,
  `Decoder.duskServerID`, and `PlexItemID { serverID, ratingKey }`. Each model's
  `init(from:)` reads `decoder.duskServerID` and stamps it, so nested items are
  stamped automatically. Do not add post-decode copy helpers or wrappers.
- `PlexItem.id`, `PlexMediaDetails.id`, `PlexEpisode.id`, and `PlexSeason.id` are
  `PlexItemID`; `==`/`hash` include the server. `PlexLibrary.id` is
  `"<serverID>|<key>"`. `AppNavigationRoute` carries a `PlexItemID`.
- `serverID` is `String?`: nil means "not stamped" (a model built locally or
  decoded outside the pool), not "the primary server".
- `Models/PlexContentKey.swift` is the *cross-server* identity used for merging:
  the scalar `guid` when it starts with `plex://`, else tmdb > imdb > tvdb from
  the `guids` array namespaced by type, else `type|normalizedTitle|year`
  (seasons: show|season, episodes: show|season|episode), else `.instance(id)` —
  this one copy and nothing else. It answers "is this the same title as that one,
  on another server" — never use it as a storage key or a request parameter.
  - Namespaces are **per type**, not collapsed: a show, its season and its
    episode routinely carry the same tvdb id and must never merge. Clips
    ("Other Videos", which report `type == "movie"` with `subtype == "clip"`)
    get their own namespace via `isClip`.
  - The heuristic is only allowed for movie/show/season/episode, and only when
    it actually carries information (a title, or a show plus numbering).
    Anything else — a guid-less clip called "Trailer", a season with no show —
    resolves to `.instance` and merges with nothing.
  - `isStrong` marks the two key kinds that identify the *content* (`plex`,
    `external`). Only those may be recorded as playback alternates; a heuristic
    key may collapse a row on screen and nothing more.

## Merging Rules
`PlexService/MultiServer/` merges what the connected servers return. Fan-outs use
a `TaskGroup`, a server that fails contributes `[]`, and results are grouped by
`PlexContentKey`.

Entry points on `PlexService` (`PlexService+MultiServer.swift`):
`mergeServerIDs` (connected servers in priority order),
`fanOutAcrossServers` (all answers, priority-ordered, once they all land),
`streamAcrossServers` (each answer the moment it lands, carrying its `rank`),
`streamHomeHubs` / `streamContinueWatching` / `streamSearch`,
`mergedHubItems(for:size:)` (pages every source of a merged row and re-merges),
and `registerAlternates(_:)`.

Every merge takes its per-server lists in **priority order** and is a pure
function of them. That is what makes progressive rendering safe: a screen can
merge what it has, render, and merge again when the next server answers without
deriving a different list. A single list is always returned verbatim — a
single-server install must never see its rows reordered or deduplicated, because
a heuristic content key can legitimately collide on one server.

- `ContentAlternatesIndex` (`plexService.alternates`) is the side table the merges
  fill and playback reads: `register(_:for:)` records that these `PlexItemID`s are
  the same content, `instances(of:)` returns every known copy. It accumulates for
  the whole session and is cleared by `tearDownServerSessions()` (sign-out, Plex Home switch),
  because rating keys only mean something for the account that fetched them.
  Two registration rules exist because playing the wrong file is worse than
  offering no fallback: **only strong keys are recorded** (`PlexContentKey.isStrong`),
  and **at most one id per (key, server)** — two copies on one server are two
  files, so `instances(of:)` returns the id it was asked about plus copies on
  *other* servers only. An id seen later under a better key is moved, never left
  listed under both. `PlexItemMerge.alternates(in:)`/`combine(_:_:)` apply the
  same rules to the tables they hand out.
- Continue Watching: representative = newest `lastViewedAt`, then larger
  `viewOffset`, then lowest server rank; the row is then sorted newest-first. The
  other copies are registered as alternates (in rank order) for playback fallback.
- Hubs: keyed on `hubIdentifier` with its trailing numeric section suffix
  stripped, plus type (normalized title as fallback). Deduped by content key and
  round-robin interleaved in priority order. `PlexHub.sources` records each
  contributing (serverID, key, size, more) so "Show All" can page each source and
  re-merge. `HubMerge.Mode` decides what "the same row" means, and getting it
  wrong makes whole libraries disappear from Home:
  - `.home` (one list per server, `GET /hubs`): the stripped identifier is not
    enough, because that suffix is the *only* thing telling two movie libraries
    on one server apart. The key therefore also carries the library — its
    normalized `librarySectionTitle`, which is comparable across servers, or the
    server and section id when the title is missing (then it simply never
    merges) — and two rows from the same server never merge whatever their keys
    say.
  - `.libraryType` (one list per library, `GET /hubs/sections/{id}`): a type tab
    exists to show every library of that type as one screen, so rows of the same
    kind merge across libraries, same server or not.
  - A merged row's `id` is the merge key (`PlexHub.mergeIdentity`), never the
    representative's `hubIdentifier`: that identifier carries one server's
    section id and two merged rows can carry the same one.
- Search: fanned out to every connected server and **republished as each server
  answers**, so results stream in. Grouped by type, deduped by content key,
  interleaved by rank. It is an error only when every server failed and there is
  nothing to show. Seerr results layer on unchanged.
- Libraries are **not** merged into virtual libraries. Each server's libraries
  stay distinct, ordered by the account's `pinnedSources`, and the server name is
  shown **only** when another library of the same type has the same title
  (`ServerLabeling`). A single-server account must look exactly as it did before.
- Live TV uses the highest-priority enabled server only.

## Model Conventions
- List, hub, and search rows use `PlexItem`; full metadata uses
  `PlexMediaDetails`.
- `ratingKey` is stable only *within* one server; `PlexItemID` is the identity.
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
- `PlexPinnedSource` is a typed *read view* over one `pinnedSources` element; its
  `raw` is the element exactly as plex.tv sent it and writes mutate `raw`, so
  unmodeled fields round-trip intact.
- `DuskJSONValue` is the loss-free JSON tree used for the plex.tv blob. Ints stay
  ints, so `schemaVersion` is never rewritten as `12.0`.
- `PlexStream` decodes selected/default/forced/hearing-impaired as bool-ish
  values because Plex sends both ints and bools.
- `PlexSubtitleSearchResult` models one provider hit from the subtitle search.
  Only `key` (the provider download handle) is required; `id` falls back to `key`
  because search hits are not library streams and usually arrive as `id: 0`.
  `score` tolerates int, double, and string, and the flags reuse the same bool-ish
  handling as `PlexStream` through a file-local container helper, so `PlexStream`
  stays untouched. `displayTitle`/`detailText` are the list-UI labels.
- `PlexItem` and `PlexMediaDetails` resolve `clearLogo` from either an explicit
  field or the `Image` array.
- `PlexMediaDetails.markers` are sorted for skip-intro/credits UI.
- Person id helpers tolerate `id`, filter query, and key suffixes.
- `AudioTrack` and `SubtitleTrack` are engine-facing app models, not raw
  responses.

## Extension Points
- Prefer same-type `PlexService` extensions by concern.
- Add new Plex envelopes near `MetadataResponse`, `DirectoryResponse`,
  `StreamResponse`, or `HubResponse`.
- For offline/download-only metadata, expose raw payload helpers deliberately.
- For derived display data, check `PlexItemPresentation` and `MediaFormatting`.
- `rawServerRequest` takes an optional `timeoutInterval`. Use it for server work
  that is genuinely slower than a metadata read (subtitle downloads); leave it nil
  elsewhere rather than raising the session defaults.
- Keep Plex calls async/await; do not introduce Combine for service APIs.

## Safe-Change Checklist
- Keep network calls out of views.
- Use the existing helper matching the Plex envelope.
- Route every server call by the item's `serverID`; never let it fall back to
  the primary by accident.
- Decode through `pool.decoder(for:)` so models keep their server stamp.
- Keep failure per server: a 401 or an outage on one server must not clear the
  pool or empty the other servers' content.
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
