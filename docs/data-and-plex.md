# Dusk Plex Data Layer

Agent-facing map for Dusk's data layer and its Plex provider. Views call view
models, view models call `MediaService`, and `MediaService` routes each call to
the item's server's provider (see Provider Layering). Plex and Jellyfin are
wired in; Jellyfin's account and session are live (J-01) and its facets fill in
package by package (docs/jellyfin/05-plan.md). The optional Seerr request companion has a separate boundary
documented in `docs/seerr-integration.md`.

## Provider Layering
docs/jellyfin/04-architecture.md §2–§8 is the design; this is how it is built.
- `Providers/Core/`: the protocols. `MediaServerProvider` (one per server: a
  `descriptor`, live `permissions`, one facet per area) and
  `MediaAccountProvider` (one per account: profiles, preferences, watchlist,
  Seerr sign-in, discovery), `ProviderFactory` / `ProviderRegistry`,
  `ServerRegistry` (server id → kind; no record is Plex), `SessionRecovering`,
  `CredentialTransportPolicy`, `PlaybackTraits` and the request types.
- `MediaService.serverProvider(for:)` (`+Networking`) is where every facet
  route starts: the server's session's provider, else one built for the id,
  so a server without a session still heals on its first request. A nil id is
  the primary-tracking provider, whose facets resolve the highest-priority
  server per request, exactly as `serverID: nil` always has.
- Routing and self-healing are the provider's routed send
  (`Providers/Plex/PlexServerRouter.swift`, one per Plex account): it picks the
  server, re-authorizes a missing session, validates a restored endpoint,
  refreshes the token on a 401 and re-selects a failing connection, asking the
  pool for each step through `SessionRecovering` (`MediaService` implements
  it over `ServerPool` and `+Servers`' per-server recovery). Every facet of a
  `PlexServerProvider` sends through it (`PlexServerTransport` and the facet
  transports refine it). The facade's `rawServerRequest` / `executeRequest`
  forward to it for the facade's own remaining calls.
- plex.tv requests have one path, `PlexAccountProvider.plexTVData`; the
  facade's `plexTVRequest` / `rawPlexTVRequest` forward to it.
- `ProviderSetup` (`Providers/`) builds the account and the registry;
  `MediaService` holds the account as `any MediaAccountProvider`.
- `TransportSecurity` (`Providers/`) is the credential rules for code that
  handles a URL without knowing its server (downloads, artwork, Seerr, the
  relays, the pool); it forwards to the provider policy.
- `Providers/Plex/Facade/`: facade extensions that are Plex-only so far: the
  account state forwarders and persisted names (`+PlexAccount`), PIN sign-in,
  Plex Home (`+Home`), history, and the routes without a
  neutral facet member yet (`+PlexFacets`: live-stream consumers, raw catalog
  routes, image URL forwarders). Each moves behind a facet member when a
  second provider needs it.
- G7 (`scripts/parity/check_provider_boundary.sh --enforce`) fails on a
  provider type name, `ProviderKind` or `X-Plex` outside `Providers/` and the
  sign-in flow; the few frozen names it allows are listed with their reasons in
  `scripts/parity/provider_boundary_allowlist.txt`.
- Tests reach a fake provider through `FakeMediaServerProvider` (test target);
  a test factory registered after the standard ones wins for its kind
  (`ProviderRegistry.factory(for:)` takes the last).
- **Accounts.** The Plex account's Plex Home state stays on the facade
  (`+Home`, `+PlexAccount`). Every other account runs its own session through
  `MediaAccountProvider.session` (`AccountSession`): when such an account is
  the primary one (`MediaService.accountSession`, nil while Plex is signed in),
  `sessionState`, `activeProfileID`, `homeBootstrapCompleted`,
  `needsHomeUserSelection`, the profile verbs, the connect pass
  (`connectAllServers` → `accountServers()`, no discovery round trip),
  per-server recovery and sign-out read it instead. Account preferences,
  watchlist and Seerr route to `primaryAccount`.
- **Which provider a server id belongs to:** `ProviderRegistry.kind(for:registry:)`
  — a `ServerRegistry` record, else the provider whose accounts hold the id
  (`ProviderFactory.ownsServer`), else Plex. Nothing new is persisted for it:
  a Jellyfin account's record already carries its server id, so a restored
  pool session finds its provider at launch.
- **Probing:** the pool asks the server's factory for a `ConnectionProbe`
  (`connectionProbe(serverID:credential:)`); nil is the built-in Plex probe,
  unchanged. Jellyfin's is `/System/Info/Public` (identity gate on `Id`) then
  `/Users/Me` (token check).
- A Plex request never reaches another provider's server:
  `PlexServerRouter.requirePlex` fails the not-yet-routed raw routes instead.
- **Jellyfin accounts** (`Providers/Jellyfin/Account/`): one record per user
  (`JellyfinAccountRecord`, id = storage scope `jellyfin-<serverID>-<userID>`)
  in UserDefaults `JellyfinAccounts` + `JellyfinActiveAccountID`, the token in
  Keychain `JellyfinAccessToken.<id>`. Each record has its own random
  `DeviceId`, created when its sign-in starts (one token per DeviceId,
  03 §10.2). The pool's per-server token copy (`PlexServerAuthToken.<id>`) is
  disposable; Switch User tears the pool down and never logs a user out.
  Candidates are the typed URL and the server's `LocalAddress`; a bare host
  tries `https://host`, `http://host:8096`, `https://host:8920`, `http://host`
  in parallel and takes the first in that order that answers (an earlier one
  that times out holds the answer for up to 8 s), a typed scheme only itself. `Policy` maps to `ServerPermissions`
  (`JellyfinPolicySnapshot`) and is refreshed from `/Users/Me` on every
  connect pass; a revoked token (401) forgets that user.

## Responsibilities
- `MediaService/` is the facade: routes to each server's provider facets,
  the session pool and its recovery, merging, and the shared stores. The
  provider side (requests, routing, DTOs, mappers) is `Providers/`.
- `Domain/` owns the app's models plus app-level playback models. Plex response
  shapes are DTOs in `Providers/Plex/DTO/`, turned into domain values by
  `Providers/Plex/Mappers/`.
- `MediaService` is `@MainActor @Observable` and is injected from `DuskApp`.
- Plex is the source of truth. Do not persist metadata except for explicit
  offline/download support.
- A new server call is a facet member (`Providers/Core/`), its Plex request
  (`Providers/Plex/`) and a facade route. Seerr is not a media provider.

## Multi-Server Model
Dusk is connected to **every enabled server at once**. There is no "current
server" the user picks: the account's servers are discovered, connected in
parallel, and their content is merged. Server selection exists only as an
*order* (which server wins when a title is on several) and an *on/off switch*
per server, both in Settings -> Server Priority.

Files: `ServerPool.swift` (live sessions), `ServerPriorityStore.swift` (order +
enabled flags), `ServerSession.swift` (one session), `ServerProbe.swift`
(connection candidates, ranking and selection), `ServerAvailability.swift` (aggregate state + UI wording).

- `ServerSession` is one live session: `serverID` (machine identifier),
  `name`, `owned`, `sourceTitle`, `baseURL`, `token`, winning `connection`, plus
  `isLocal` / `isRemote` / `isRelay`. Everything that talks to a server resolves
  one of these first, so a request, an image URL, or a playback decision can
  never land on a different server than the item it belongs to.
- The pool also stores the server's `provider` on each session it records,
  built by the provider's factory from `MediaService.providers`
  (`ProviderRegistry`, `Providers/Core/`); the facade routes through it
  (Provider Layering). The provider is not part of the session's
  `==`/`hash`.
- `ServerPool` (`media.pool`) holds `states: [String: ServerConnectionState]`
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
- A **cancelled request never triggers endpoint recovery**. URLSession reports
  cancellation as an ordinary transport failure, which `shouldRefreshServerEndpoint`
  would otherwise read as a dead endpoint, so `rawServerRequest` checks for
  cancellation before recovering. Without that, a superseded or cancelled screen
  load re-probes every server it still had in flight, and a probe that then fails
  marks the server `.offline` — which drops its content out of every merged
  screen and bumps `serverContentRevision`, reloading them all again.
- After a *successful* discovery, a server the pool knows about that plex.tv did
  not return is marked `.offline`: discovery sees the whole account, so a
  session restored from the last launch must not keep claiming it is connected.
- `pool.generation` is the session counter. `clear()` bumps it, and any probe
  that started earlier is discarded when it lands. Together with
  `MediaService.serverSessionToken` (profile + generation, captured before
  `discoverServers()` and re-checked after) this is what stops a connect pass
  from a previous Plex Home member re-registering that member's servers — and
  re-saving their tokens — into the session that replaced it.
- `pool.primary` is simply the highest-priority connected server. It is a
  fallback for the handful of things that are genuinely account-wide — the
  Seerr link and Live TV — and for a call site that has no item in hand. It is
  **not** "the current server": anything holding an item, library, hub or
  download record must pass that value's `serverID` instead. There are no
  single-server compatibility shims on `MediaService`.
- `ServerPriorityStore` (`media.serverPriority`) persists an ordered
  `[{machineIdentifier, isEnabled}]` in UserDefaults (`PlexServerPriority`). It
  is additive: `reconcile(discovered:)` appends unknown servers enabled at the
  end and never drops a server that simply did not answer this time; only
  sign-out prunes it. Every mutation bumps `revision`, which merged screens
  (Home, Libraries, Search) observe to know they must reload.
- `MediaService.serverContentRevision` is the `.task(id:)` key for merged
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

Accounts (docs/jellyfin/04-architecture.md §7): `PlexAccountProvider` owns the
Plex account's credentials and Home state (`PlexAccountState`), the plex.tv
request core with the fresh-sign-in retry, and discovery; `PlexProfiles` the
Home member calls; `PlexSignInFlow` the PIN calls. `MediaService` forwards its
account properties (`primaryAccountToken`, `homeUsers`, `automaticHomeSignIn`, …)
to that state and keeps the orchestration (teardown on account change, Home
bootstrap and switch, persistence) in `+Auth` / `+Home`. `AccountStore` lists
the signed-in accounts as `StoredAccount`s read in place from the Keychain
token (nothing new is stored); `sessionState`
(`signedOut | bootstrapping | needsProfile | ready`) is what `ContentView`
routes on, and the picker shows neutral `Profile`s (`id` = `stableProfileID`).
Every plex.tv request goes through `PlexAccountProvider.plexTVData`
(`MediaService.rawPlexTVRequest` forwards to it).

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
  - `PlexServerSnapshots`: tokenless `AccountServer` snapshots of every server the
    account has seen, in priority order. Only `pool.connectAll` rewrites it, so
    a disabled server keeps its snapshot and costs no round-trip when it is
    turned back on.
- `MediaService.init` restores a session for every *enabled* snapshot that has a
  token and a remembered endpoint the token may travel to right now
  (`ServerPool.restorableBaseURL`), so Home/Libraries/Search have content
  immediately; `ServerConnectionCoordinator`'s pass then verifies and refreshes
  them, and a restored endpoint that has since moved fails over on its next
  request. A restored session has no winning `ServerEndpoint` unless the base
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
2. `authURL(for:)` builds Plex's hosted auth page URL for the PIN.
   `SignInPlexFlowView` (inside the `SignInView` host) opens it in an in-app `SFSafariViewController` on iPhone/iPad, but for an iOS
   app on macOS (`isiOSAppOnMac`/`isMacCatalystApp`, where that sheet dismisses
   itself immediately) it opens the external browser instead. Polling is started
   before the browser opens and is independent of the browser's lifecycle:
   closing/dismissing the browser must **not** cancel sign-in — the `plex.tv/link`
   code stays on screen as the fallback and only the explicit Cancel button (or a
   real ~120 s poll-window timeout) ends it. Cancellation exits polling silently;
   the "Sign-in timed out" message is reserved for the full window elapsing.
   On Apple TV there is no browser: the code screen shows the short PIN next to
   a CoreImage QR code for `https://plex.tv/link?token=<code>`. The link page's
   script (`PlexLinkClaim`) reads `token` (not `code`) into its code field, and
   the `plex.tv` → `www.plex.tv` 301 keeps the query. New Code reruns
   `signIn()`; Cancel goes back to the start screen.
3. `checkPin(_:)` polls until `authToken` appears.
4. `completeSignIn(_:credential:)` → `setAuthToken(_:)` stores the primary token
   and clears stale account/server state on account change.
5. Account bootstrap and resource discovery use a dedicated ephemeral session
   with no connectivity waiting and a 3 s request/resource budget. The network
   monitor also rejects new bootstrap requests without a route. Account-wide
   connection passes use this short session for candidate probes, including
   parallel stored-snapshot fallback (disabled snapshots are preserved).
   Diagnostics and individual endpoint recovery retain their longer budgets.
   Account bootstrap fetches Plex Home users from `/api/v2/home/users`. Zero or
   one usable member keeps the legacy flow; multiple members require a user
   selection unless a remembered active Home session is valid. Fast user
   switching uses the separate legacy `/api/home/users/<id>/switch` route.
   Protected members send a transient PIN; Dusk never stores it. On iOS, a
   transport/5xx bootstrap failure can resume only the saved automatically
   signed-in identity for Downloads, without marking it online-validated. See
   [Offline startup and recovery](downloads-and-offline.md#offline-startup-and-recovery).
6. `discoverServers()` fetches `/api/v2/resources` as the active identity with
   HTTPS/relay and keeps
   resources whose `provides` contains `server` **or** whose `product` is
   "Plex Media Server" (`MediaService.isMediaServerResource`): plex.tv listed
   the owner's main server as `provides: "controller"` on 2026-11-10 and Dusk
   silently dropped it — the real cause behind "can't reach my server" that
   the #36 transport fixes were guessing at.
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
- A switch clears the whole pool (`tearDownServerSessions()`) and invalidates current-user
  and library-order caches. Server tokens belong to the identity
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

Connection selection (`ServerProbe.swift`: `ConnectionCandidate`,
`ConnectionSelector`; rebuilt 2026-11-10 after the owner's phone could not
reach his server on build 76):
- **Candidates** (`ServerPool.connectionCandidates(for:lastKnownGood:)`): every
  plex.tv resources connection (relay included), the HTTPS form of a public
  `http://` connection (`httpsUpgradeURI`, port 80 → 443; never for LAN /
  tailnet / single-label names), the raw-IP `http://` form of every non-relay
  HTTPS plex.direct connection (`httpFallbackURI`, for routers whose DNS
  refuses plex.direct), and the endpoint used last when plex.tv no longer lists
  it. `::`/`fe80:` are dropped; Docker-bridge 172.17–31 addresses are kept.
  Duplicates (`https://h` vs `https://h:443`) collapse.
- **Probe** (concurrent, per-candidate timeout LAN 5 s / tailnet 8 s / remote
  10 s / relay 12 s, on `MediaService.probeSession`, which never waits for
  connectivity): `GET /identity` must return the expected `machineIdentifier`
  (JSON or XML) — a different server, captive portal or recycled address never
  wins — then `GET /library/sections` must accept the token. A candidate that
  only answers by redirecting (http → https proxy) fails; its target is its
  own candidate. Latency = the `/identity` round trip.
- **Rank** (`ConnectionCandidate.rank`, lower wins, latency breaks ties):
  direct before relay → HTTPS before HTTP (never trade a working HTTPS for
  HTTP, owner's rule) → LAN, then tailnet / private name, then remote → a
  Docker-bridge LAN address after other LAN ones. Locality comes from the
  candidate URL's host as well as plex.tv's `local` flag. Tailscale is **not**
  local for `ServerSession.isLocal` (Plex treats it as remote).
- **Commit**: as soon as no still-running candidate has a strictly better rank,
  or `ConnectionSelector.defaultGrace` (1.5 s) after the first success. A hung
  LAN / Docker address therefore costs at most the grace window, never a
  timeout. Servers race each other too (`ServerPool.connectAll`, max four at a
  time). Do not regress to a sequential loop.
- **Persistence / fast path**: the winner's base URL is stored per server
  (`PlexServerURL.<id>`, plus `PlexLastGoodConnectionURI.<id>`). Cold launch
  adopts it before any probe (`restorePersistedSessions`), the launch pass
  re-selects right behind it, and the stored URL is always a candidate.
- **Failover**: any request failing with a connection-type error (refused,
  DNS, TLS, timeout — all `networkError` — `invalidURL`, or 404/408/421/502/
  503/504) re-selects that server (`recoverServer`, coalesced, 30 s cooldown
  after a failed recovery) and retries once on the new endpoint; if another
  request already moved the server it just retries there. Recovery falls back
  to the stored server snapshot when plex.tv is unreachable, and so does a
  whole pass (`connectAllServers`), so a LAN-only network still connects.
- **Network change** (`ServerConnectionCoordinator`, `NWPathMonitor`): any
  change of interfaces/types (`utun` = VPN, Wi-Fi ↔ cellular), gateways or
  `isExpensive` forces a full re-selection.
- **Diagnostics**: every selection stores a `ConnectionReport`
  (`ServerPool.reports`, in memory, never a token) and logs it under the
  `ServerEndpoint` category. Settings › Server Priority › Connection
  Diagnostics lists each candidate, its outcome, latency and the winner, can
  probe everything to completion (`ServerPool.diagnoseAll`), re-select, and
  copy the report (iOS). Ask testers for that report before guessing. A
  candidate's source label comes from its provider's factory
  (`ProviderFactory.listedConnectionSource`): "plex.tv" for Plex, "server
  address" for Jellyfin's typed address and `LocalAddress`.
- `LiveConnectionProbeTests` is an opt-in real-network check
  (`TEST_RUNNER_DUSK_LIVE_TOKEN_FILE=<file>`, `TEST_RUNNER_DUSK_LIVE_AWAY=1`
  drops LAN/tailnet connections); skipped otherwise.
- **Task group children must not contain a `do`/`catch`, and should return from
  one place.** With Swift 6.4 at `-O`, a child returning a value from both
  branches of a `do`/`catch` can lose its result: `for await` ends with children
  still running, the group is destroyed, and the next child to finish aborts in
  `AsyncTask::completeFuture` -> `__cxa_pure_virtual`, with no app frame in the
  crash log (swiftlang/swift#93208). Debug builds are unaffected, so simulator
  runs do not reproduce it. Use `Result.capturing` or `try?` and return a named
  struct. `TaskGroupChildShapeTests` fails on a `catch` in an `addTask` closure.
- Locality is read off the connection: `ServerSession.isLocal` /
  `isRemote` / `isRelay`.
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

Remote streaming (Plex Pass / Remote Watch Pass): since 2025 Plex only streams
personal video outside the server's network when the owner has Plex Pass or the
viewer has Plex Pass or a Remote Watch Pass; local playback stays free. **Dusk
never gates this itself** (`MediaService+RemotePlayback.swift`). It used to, from
the account's `subscription.active` and the connection's `local` flag, and that
blocked people at home (a public/plex.direct address that is really NAT
loopback, an unflagged LAN address) and people who had the pass (Remote Watch
Pass is not in `subscription`; the owner's pass covers shared users). Only the
server knows who is entitled and whether a request is local, so playback always
runs and Plex decides:
- `isRemotePlaybackRefusal(_:serverID:)`: an HTTP 403 on a *playback* request
  (after the metadata fetch) over a connection that is not `isLocal`. Any other
  failure is reported as itself.
- Direct play on a non-LAN session first asks for one byte of the file
  (`checkRemoteDirectPlayAccess`): AVPlayer handed a 403 URL never errors, it
  just spins, so without this a refusal is an endless spinner.
- On a refusal, `reconnectOverLocalNetwork(serverID:)` re-races that server's
  connections (only if it advertises a LAN one) and the attempt is retried once
  when the session now runs over the LAN — at session start and in the
  direct-play → server-stream fallback. Otherwise the player shows
  `RemotePlaybackRefusal.message`.
- Plex does not document the refusal's exact shape; 403 is the assumption.
  Revisit with a real refusal log if users still see generic errors away from
  home.

## Request And Decode Helpers
Files: `Providers/Plex/PlexServerRouter.swift` (routing and self-healing),
`Providers/Plex/PlexClient.swift` (the four `URLSession`s, `X-Plex-*` headers,
sending one attempt and mapping its status, URL and decode helpers) and the
facade's entry points in `MediaService+Networking.swift`, which forward to them.
- Use `plexTVRequest<T>` for `plex.tv` JSON.
- Use `rawServerRequest` for server calls. It takes an optional `serverID:`,
  resolves that server's `ServerSession` from the pool (nil = the
  primary), applies **that server's** token, recovers auth, re-probes the
  endpoint, and returns `Data`.
- Use `fetchMetadata<T>` for `MediaContainer.Metadata`.
- Use `fetchDirectories<T>` for `MediaContainer.Directory`.
- `MediaContainer.Hub` rows come from the home facet (`PlexHomeRows`, reached
  through `MediaService.home(on:)` in `MediaService+Hubs.swift`); search's
  `/hubs/search` groups come from the catalog facet (`PlexCatalog`).
- The fetch helpers decode through `pool.decoder(for: serverID)`. A DTO carries
  no server id: pass the resolved server id to its mapper, which stamps it. Items
  still decoded as domain types (the transitional `PlexItemDecodingBridge`) get
  it from that decoder. A hand-rolled `JSONDecoder` loses that stamp and
  produces unattributable items — always go through the pool.
- Use `decodeJSON(_:from:)` so decode failures become `MediaServiceError`.
- Use `buildURL(base:path:queryItems:)` for query parameters.
- `PlexTransportSecurity` is the credential transport boundary (code outside
  `Providers/` reaches it through `TransportSecurity`). Plain HTTP is
  a normal transport like in Plex's own apps (owner's decision 2026-11-10,
  replacing #36's HTTPS-only rule and 93b2243's identity-gated last resort):
  a token goes to any `http`/`https` URL with a host; HTTPS wins through the
  ranking, not through refusal. What stays absolute: a token never follows a
  redirect to a different host, and never follows an HTTPS → HTTP redirect
  (`allowsRedirect`, applied by every Plex session delegate, downloads
  included). Request executors, probes and direct image/subtitle/download/media
  fetches validate header/query/Seerr-JSON credentials before sending; add the
  same validation to any new fetch path that bypasses `executeRequest`.
  `PlexTransportSecurityTests` + `ConnectionSelectionTests` cover it without
  opening sockets.
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
- Be intentional about cache policy; `MediaService` uses `AppImageCache.shared`.

## Library, Search, Hubs, And Detail Endpoints
Files: the facade routes in `MediaService+Library.swift`, `+Collections`,
`+People`, `+Extras`, `+Photos`, `+Ratings`; the Plex requests in
`Providers/Plex/PlexCatalog.swift` (`CatalogProviding`, docs/jellyfin/04 §9) and
`PlexUserRating.swift` (`UserRatingProviding`), reached through the server's
provider (`catalog(on:)`, `userRating(on:)`). The raw routes whose callers still
pass Plex sort strings and filter parameters (`getLibraryItems`,
`getLibraryItemCount`) are in
`Providers/Plex/Facade/MediaService+PlexFacets.swift`. Hidden
libraries, merging, alternates and the next/previous episode walk stay in the
facade.

Sorts and filters are neutral (`LibrarySortOption`, `LibraryFilter`,
`LibraryFilterField`/`LibraryFilterChoice` in `Domain/LibraryBrowse.swift` and
`Providers/Core/CatalogProviding.swift`). `PlexCatalog` maps them:
`sortValue` (`titleSort`, `addedAt:desc`, …; `LibrarySortOption.plexValue` for
callers that send their own request), `queryFilters` (collection, genre, the
watch-state parameter by library kind, picked values, toggles as `=1`,
`includeCollections=1` for folding), the `offeredFilters` list, and the fixed
sort lists (`sortFields(for:)`). The grid (`LibraryItemsViewModel`) uses the
neutral routes (`libraryItems(in:…)`, `libraryLetterCounts`,
`librarySortFields`, `libraryFilterFields`, `libraryFilterChoices`), the genre
menu `libraryGenreChoices` (catalog `genreChoices`: Plex reads the section's
`genre` `/filters` row, then its values, as before) and the libraries list's
empty-library check `libraryItemCount(in:)`; the recommendation shelves, Siri
and video channels still pass Plex strings through `getLibraryItems` /
`getLibraryItemCount`, which forward unchanged to `PlexCatalog.raw…` (Plex
servers only). The watchlist's server lookup (`serverItems(guid:)`) is the
catalog's `items(matching:…)` (Plex: `/library/all?guid=`) and
`getPlaybackHistory` its `playbackHistory` (Plex:
`/status/sessions/history/all`); both send the requests they always did.

Jellyfin's catalog (`Providers/Jellyfin/Facets/JellyfinCatalog.swift`, J-02):
- One base `/Items` query per listing (`JellyfinBrowseVocabulary.baseQuery`:
  `parentId` = library, `recursive`, item types by library kind) serves the
  page, the count (`limit=0`) and the A–Z table, so the letter offsets match
  the grid. Sorts map onto `SortName`, `PremiereDate`, `ProductionYear`,
  `DateCreated`, `DateLastContentAdded`, `CriticRating`, `CommunityRating`,
  `Runtime`, `DatePlayed`, `Random`, with a `SortName` tiebreak; there is no
  "Your Rating" sort.
- Filters: genre (`/Genres` names), watch state (`isPlayed`, `IsResumable`),
  decade (expanded to `years`), year and content rating (`/Items/Filters`),
  resolution (`is4K` / `isHD`, only values with titles), studio (`/Studios`,
  shows too), director / actor (`/Persons`, `personIds` + `personTypes`) and
  collection (a BoxSet's member ids matched inside the library with `ids=`,
  because BoxSets are server-wide). No HDR, Dolby Vision or audio-language
  filter exists. A field's `.values(source:)` handle carries library id and
  kind (`ChoiceSource`), since `filterChoices(for:)` gets only the field.
- A–Z: 26 `nameLessThan` counts in parallel (`#` = before "A", "Z" keeps the
  rest), cached in memory per server, user and query until the total changes.
- A `homevideos` view is a photo library when it holds more photos than
  videos (two `limit=0` counts, cached for the launch); otherwise a Videos
  library.
- Details are `/Items/{id}`; a title without a local trailer carries its first
  https `RemoteTrailers` link as `MediaDetails.remoteTrailerURL`, which the
  hero's Trailer button opens outside the app on iOS and macOS (hidden on
  tvOS). Extras are `/LocalTrailers` then `/SpecialFeatures` (theme videos
  dropped). Episodes of a season are `/Items?parentId={season}` in
  `ParentIndexNumber, IndexNumber` order, `isMissing=false`.
- Cast members carry their person id in `Person.filter` (`personIds=<id>`),
  which `Person.personID` reads like Plex's `actor=<id>`.
- Search: one request per group (films + videos as "Movies", "Shows",
  "Episodes", `limit=10`), the same `type`s Plex's hubs use. No people group:
  Plex's actor hub never showed either.
- `items(matching:)` searches by title (and year, kind) and keeps the items
  whose `ProviderIds` match; `playbackHistory` is `DatePlayed`-sorted items
  until one predates `since` (one entry per title, not per play).
- No Rate button: `MediaService.canRate` is false while a server's provider has
  no `rating` facet.

Jellyfin's Home rows (`Providers/Jellyfin/Facets/JellyfinHome.swift`, J-04).
Jellyfin has no hub API, so each row is a fixed query (`JellyfinHomeRowSpec`):
- Rows carry the identifier, title and type Plex gives the same row of a
  library (`movie.recentlyadded.<viewID>`, "Recently Added in Movies",
  `movie`; TV `tv.recentlyadded` / `mixed`, videos `video.recent` / `clip`),
  so `mergeKey`, the library tab's string checks and a mixed account's merge
  treat both servers alike. `HomeRow.key` is `jellyfin-row/<row>/<kind>/<viewID>`,
  which `rowItems` pages.
- Home (`homeRows`): one Recently Added row per film, TV and video library
  (from `/UserViews`, so libraries the user hid in `MyMediaExcludes` are gone)
  that is not in `LatestItemsExcludes`. The row, its expansion and Show All
  all read `/Items/Latest` (episodes grouped into season or show, the user's
  "hide played" setting applied); Latest cannot page, so Show All asks for up
  to 500.
- Continue Watching: `/UserItems/Resume` and (TV libraries) `/Shows/NextUp`
  per library, so each title carries its library. One entry per show, newest
  first. A Next Up episode is dated by the user's latest played episode of
  its show (one `DatePlayed` query of 100 played episodes); undated ones go
  last in the server's order.
- Library Recommended tab (`libraryRows`): Continue Watching, Recently
  Released (films: the last year; TV: episodes by air date), Recently Added,
  Top Unwatched Movies / Top Rated TV (unplayed, `CommunityRating` ≥ 7),
  Recently Watched (played, by `DatePlayed`); videos get Continue Watching,
  Recently Added, Recently Watched. Empty rows are left out.
  `promotedLibraryRows` is the first and the third.
- Dismiss (`HomeProviding.dismissFromContinueWatching`; Plex keeps
  `PUT /actions/removeFromContinueWatching` in `PlexHomeRows`): clears the
  resume point (`PlaybackPositionTicks: 0`; Jellyfin cannot hide and keep it)
  and, for an episode, records it in UserDefaults `JellyfinDismissedNextUp`
  (`{ "<serverID>|<userID>": { seriesID: episodeID } }`, device-local) so Next
  Up leaves it out until a different episode of that show is next.
- Hide Row / Hidden Rows: only Recently Added has a switch (`canHide`); it
  writes the library id into `LatestItemsExcludes`, which other Jellyfin apps
  honour. The write re-reads `/Users/Me` and changes only that key in the raw
  `Configuration` (`JellyfinJSONValue`), because `POST /Users/Configuration`
  resets every field it leaves out and the typed DTO does not carry them all.
  Allowed when the user's policy has `EnableUserPreferenceAccess`.

Jellyfin's collections (`Providers/Jellyfin/Facets/JellyfinCatalog+Collections.swift`, J-07):
- BoxSets are server-wide, but `/Items?parentId={library}&recursive=true&includeItemTypes=BoxSet`
  lists the ones with a title in that library (a BoxSet of films and a show is
  in both), paged by the server. The library's collections, the grid's
  "has collections" probe and the filter's choices read it.
- **`/Items` ignores `parentId` when `ids=` is given** (measured on 12.4: every
  library "contains" every id). So the collection filter narrows a BoxSet's
  titles to the library by each title's `/Items/{id}/Ancestors` (the
  `CollectionFolder` id is the view id), only for the picked BoxSet.
- The page is `/Items?parentId={boxSet}` in the server's display order
  (year), or the picked sort.
- A BoxSet's titles are read once per 10 minutes (six requests at a time):
  count and noun ("5 movies"), and the poster a BoxSet without artwork
  (Jellyfin draws none) borrows from its first title.
- Items name no BoxSet, so "Part of" (`collections(containing:)`) reads the
  membership index: every BoxSet with its titles, built on first use, kept in
  memory per server and user for 10 minutes. Nothing is persisted.
- Read-only like Plex; no channels; `collectionMode` is always `.showItems`.

Library:
- `getLibraries()` -> `/library/sections`, decoded as `[Library]`.
- `getLibraryItems(sectionId:start:size:sort:filters:)` /
  `libraryItems(in:start:size:sort:filter:)` ->
  `/library/sections/{sectionId}/all` with Plex pagination; filter parameters
  are sent in key order.
- `getLibraryItemCount(sectionId:filters:)` reads `totalSize`/`size` from a
  one-item page.
- `libraryGenreChoices(sectionId:)` (the genre menu) and `libraryFilterFields` /
  `libraryFilterChoices` (the sheet) read the section's `/filters` rows and a
  row's values.
- `getLibraryCollections(sectionId:)` -> `/library/sections/{sectionId}/collection`
  filter values, decoded as `[MediaCollection]` (key + title). Fetch a
  collection's items with `getLibraryItems(filters: ["collection": key])`.
  This filter view is what video libraries use for their channel rows.

Plex collections (`MediaService+Collections.swift`, movie and TV libraries):
- A collection is a metadata item of `type: "collection"` (`MediaKind.collection`);
  `subtype` says what it holds, `smart` ("1"/"0") whether a saved filter fills it,
  `index` is the tag id. Before `.collection` existed these decoded as `.unknown`
  and were dropped everywhere, which is why "collections" never showed up.
- `getCollections(sectionId:start:size:)` -> `/library/sections/{id}/collections`,
  `getCollectionItems(itemID:start:size:sort:)` -> `/library/metadata/{rk}/children`
  (the server resolves a smart collection's filter here, in the collection's sort,
  or `sort=` from the picked `LibrarySortOption`),
  `getCollection(ratingKey:)` -> `/library/metadata/{rk}`. The two listings return
  `MediaItemPage` (items + `totalSize`) and page with `X-Plex-Container-Start/Size`.
- An item's `Collection` tags carry `id` (= the collection's `index`) and `tag`
  (title), never a rating key: `PlexCatalog.collections(containing:)` (the "Part
  of" rows, `MediaService.collections(containing:)`) resolves them against the
  section's collection listing (id first, title as fallback). Smart collections
  never tag their titles, so they have no "Part of" row.
- `collectionMode(sectionId:)` reads the section's `collectionMode` pref from
  `/library/sections/{id}/prefs` (0 Disabled, 1 Hide items which are in collections,
  2 Show both), cached per server+section for the launch; an unreadable pref (shared
  users) counts as 2. Disabled hides every collection entry point. Hide-items sends
  `includeCollections=1` on the unfiltered library grid so Plex folds a collection's
  titles into the collection, as Plex Web does; a genre/Unwatched-filtered grid lists
  the titles themselves. Per-collection display modes are not read.
- Search still sends `includeCollections=0`.

First characters (`libraryLetterCounts`, `[LibraryLetterCount]`): `/library/sections/{id}/firstCharacter`
answers `Directory` rows `{key: "A", size: 2029}` in ascending title-sort order (only
letters that have titles; "#" for digits/symbols) and honours the same filters as
`/all` (type, unwatched, genre, collection). Cheap (<1 s on 60k titles); cumulative
sizes are exact offsets into `/all?sort=titleSort` (verified on plex-demo Stress Movies).

Extras (`MediaService+Extras.swift`, `Domain/Extra.swift`):
- `getExtras(ratingKey:)` -> `/library/metadata/{rk}/extras` for a movie, show,
  season, or episode. Rows are `type: "clip"` items with a numeric `extraType`
  (1 trailer, 2 deleted scene, 3 interview, 4 music video, 5 behind the scenes,
  6 scene/sample, 7 live music video, 8 lyric video, 9 concert, 10 featurette,
  11 short, 12 other) and the same kind as a camelCase `subtype`; `ExtraKind`
  takes the number (int or string) and falls back to the subtype. The payload is
  decoded twice (`MediaItem` + `PlexExtraFieldsDTO`) and paired by rating key in
  `PlexUserContentMapper.extras(items:fields:)`, so
  `MediaItem` carries no extra-only fields; non-clip rows are dropped.
- Each extra has its own rating key and plays like any clip (`PlaybackCoordinator.play`),
  so pre-rolls (movies only), Up Next and adjacent-episode controls never apply. Its
  content key is instance-only (guid-less clips never merge across servers), so an
  extra always plays from the server whose page listed it.
- Not confirmed against a real PMS: whether `/extras` pages or also lists Plex's
  online (non-local) trailers; whatever the server returns is shown.

Hubs and search:
- `getHubs()` -> `/hubs`.
- `HomeRow.libraryID` decodes int-or-string; `resolvedLibrarySectionID`
  falls back to the paging key, then the numeric suffix of `hubIdentifier`
  ("movie.recentlyadded.3" -> "3") because not every server sends the field.
  That id is what lets Home group a library's rows together.
- Every Plex string rule about a row runs once, in `PlexHubMapper`, and lands
  on the row as `kind` (continue watching / next up / playlists / recently
  added / other), `libraryScope` (section, unresolved library row, global),
  `mergeKey` and `canHide`. `HomeHubFilter`, `HomeHubArrangement`, `HubMerge`
  and `HomeViewModel.isRecentlyAddedHub` read those fields, never
  `hubIdentifier`/titles. The rules read only fields a merge keeps from its
  representative, so a merged row classifies as its representative did.
  Pinned by `PlexHubFixtureTests` (`DuskTests/Fixtures/Plex/plex-hubs-*.json`).
  `MediaItemMerge`, `LibraryRecommendationsViewModel` and
  `HomeWatchlistPlacement` still read the strings themselves.
- Build a changed hub with `HomeRow.replacingItems(_:)`, not the memberwise
  init: the init drops any field the call site forgets.
- `getLibraryHubs(sectionId:count:)` -> `/hubs/sections/{sectionId}` with
  `includeGuids=1`.
- `getContinueWatching()` -> `/hubs/continueWatching`, flattened from hubs.
- `getHubItems(hubKey:start:size:)` follows the hub key and merges `Metadata`
  plus `Directory`.
- `search(query:)` -> `/hubs/search` with `limit=10`, no collections, and GUIDs,
  wrapped as `[SearchSection]`.

Account library order (`MediaService+LibraryOrder.swift`, `LibraryOrderStore`) —
the user's library order is **not** a PMS setting. It lives on plex.tv, per Plex
account, in the `experience` user setting. Order, pinning, and hiding are all the
same array: `sidebarSettings.pinnedSources`. Array position is the order.

The facade routes to the account's `AccountPreferencesProviding`
(`Providers/Plex/PlexAccountPreferences.swift`, through `PlexAccountTransport`):
one read (`libraryLayout()`) or one read-then-write (`saveLibraryLayout`). The
store holds only the neutral `AccountLibraryLayout` (server, library key, hidden,
in account order); `LibraryOrderArrangement` applies it to the sections. The raw
blob and `PlexPinnedSource` entries stay inside the provider, which re-reads them
for every write (`PlexPinnedSourceArrangement` builds the new list). The facade
picks the servers whose pins may be rewritten; the provider may only drop more.

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
- Effective order (`LibraryOrderArrangement.effectiveOrder`, over the
  `AccountLibraryLayout` that `PlexExperienceSettings.layout` makes of the PMS-library
  entries): take the entries for **every enabled server's** machine id that are not
  hidden, in array order, map (`machineIdentifier`, `directoryID`) to the section, then
  append every section the array does not mention (server priority first, then
  the server's own order). No entries at all means plain `/library/sections`
  order per server. The pairing must include the machine id: `directoryID` is a
  per-server counter, so keying on it alone aliases two servers' sections.
- Merge on write (`PlexPinnedSourceArrangement.merged(existing:reordered:machineIdentifiers:)`,
  in `Providers/Plex/PlexPinnedSource.swift`):
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
  intersects them (the facade does this and hands the provider the set, which may
  only narrow it to servers still in the pool). A server that answered with *nothing* is in neither: it has no
  pins to write, and an empty answer is also what a still-scanning or half-started
  server returns, so it must not be able to delete what the account has pinned
  for it.
- `LibraryOrderStore` caches per `"<connected serverIDs in priority order>|<profileID>"`
  — priority order, not sorted, because reordering Server Priority changes the
  unpinned tail and must invalidate the cache — and commits each
  server's sections the moment they land (`applyServerSections`), so the library list
  paints from the first server rather than the slowest. `sections` is reassembled in
  server-priority order each time. Identify a section by `orderedSectionIdentities`
  (`Library.id`, `"<serverID>|<key>"`), never by the bare section key — those
  are per-server counters that collide.

Jellyfin (`Providers/Jellyfin/Account/JellyfinAccountPreferences.swift`): the
order is the user's `Configuration.OrderedViews`, hidden is `MyMediaExcludes`
(view ids, the lists Jellyfin Web's Home settings edit), per user on its one
server.
- `/UserViews` is read with `includeHidden=true`: without it an excluded view
  disappears from Dusk entirely and could never be shown again.
- Write: re-read `/Users/Me`, send the whole `Configuration` back as raw JSON
  with only the two arrays changed (`POST /Users/Configuration` replaces the
  object, so a typed DTO would reset keys Dusk has no field for). Dusk's
  libraries take the slots Dusk's libraries hold in the server's effective
  order (`/UserViews`); Collections, Playlists and other views Dusk does not
  show keep theirs, and their exclusions stay.
- Without `Policy.EnableUserPreferenceAccess` (or on a `403`) the lists are
  kept on the device (UserDefaults `JellyfinLibraryViews.<accountID>`), seeded
  from the server's.
- Jellyfin's search ignores `MyMediaExcludes` and its items name no library
  (`ParentId` is the folder on disk), so `JellyfinHiddenLibraries` asks each
  search again per hidden view (`parentId`, same order and limit) and drops
  those hits before `HiddenLibraryFilter` sees the rows.
- Language defaults: `AudioLanguagePreference`, `SubtitleLanguagePreference`
  (ISO 639-2, mapped to 639-1 by `JellyfinLanguageCodes`) and `SubtitleMode`
  (`Smart` → Auto, `Always`, `None`/`OnlyForced` → Off, `Default` says
  nothing). `PlayDefaultAudioTrack` is ignored: it is on for every new user.

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
- `getMediaDetailsPayload` returns the raw details payload. Downloads make the
  same details and children reads through `PlexMetadataSnapshotFormat.fetchRequest` for
  `MetadataSnapshotCache`; keep the two in step.

Subtitle search and download (`MediaService+Subtitles.swift` routes to the
item's server's `SubtitleSearchProviding`; Plex requests in
`Providers/Plex/PlexSubtitleSearch.swift`, Jellyfin's in
`Providers/Jellyfin/Facets/JellyfinSubtitleSearch.swift`):
- Plex Media Server proxies OpenSubtitles, so Dusk needs no OpenSubtitles
  account, API key, or rate limiting of its own.
- `search(itemID:languageCode:hearingImpaired:forced:)` ->
  `GET /library/metadata/{ratingKey}/subtitles?language=&hearingImpaired=0|1&forced=0|1`,
  decoded through `StreamResponse<SubtitleSearchResult>`. `language` is the
  ISO 639-1 code Plex Web sends (`en`); servers also accept 639-2 (`eng`), and
  the value is only trimmed/lowercased, never mapped. Servers may answer
  `size: 0` with no `Stream` array, which decodes to `[]`.
- `install(_:itemID:)` -> `PUT` on the same path with
  `key` plus the optional `codec`/`language`/`hearingImpaired`/`forced`/
  `providerTitle`/`title` params, sent only when the result carries them. The
  server fetches the file, writes it as a sidecar, and refreshes the item; the
  200 body is empty. Refetch `getMediaDetails(ratingKey:)` to see the new track.
  `PlexSubtitleSearchRequestTests` pins both requests.
- The PUT passes `timeoutInterval: 30` to `rawServerRequest` because the provider
  round-trip routinely exceeds the session's 15s request default. 30s is also the
  session's `timeoutIntervalForResource`, so it is the practical ceiling.
- Jellyfin: `GET /Items/{id}/RemoteSearch/Subtitles/{lang}` with the ISO 639-2/B
  code (`ger`, `fre`: `JellyfinLanguageCodes.threeLetter`), filtered on the
  client for hearing impaired / forced (the server has no such filter); install
  is `POST /Items/{id}/RemoteSearch/Subtitles/{resultId}` (30 s). Needs
  `Policy.EnableSubtitleManagement` (or admin), else `403`, and a subtitle
  plugin, else every search is `[]`.
- `externalSubtitleURL(for:)` builds the item's server base URL + `stream.key` +
  `X-Plex-Token` for sidecar streams (`kind == .subtitle` with a non-nil `key`) so the
  engine can attach them via VLCKit `addPlaybackSlave`. Server token, never the
  account token; log only through `sanitizedPlaybackURLString`.
- `canDownloadSubtitles(serverID:)` gates the affordance per server: the server
  has a `subtitleSearch` facet and `permissions.canInstallSubtitles` (Plex: an
  owned server and a non-restricted Home user; Jellyfin: subtitle management).
  Everyone else never sees the entry point instead of a 403.

Where to edit:
- Browse/library/detail endpoints: `Providers/Plex/PlexCatalog.swift`, routed from
  `MediaService+Library.swift` (and `+Collections`, `+People`, `+Extras`, `+Photos`).
- Cast/person endpoints: `MediaService+People.swift`; account/history endpoints:
  `MediaService+History.swift`.
- Direct play/transcode/remux URLs and stream selection: routes in
  `MediaService+Streams.swift`, Plex requests in
  `Providers/Plex/PlexPlayback.swift`; playback progress and watch state:
  `MediaService+WatchState.swift` routes them to the server's
  `UserDataProviding`, whose Plex requests (`/:/timeline`, `/:/scrobble`,
  `/:/unscrobble`) live in `Providers/Plex/PlexUserData.swift`.
- Home, Continue Watching and library hub rows: `MediaService+Hubs.swift`
  (routes) and `Providers/Plex/PlexHomeRows.swift` (the Plex requests), rows
  mapped by `Providers/Plex/Mappers/PlexHubMapper.swift`.
- Subtitle search/download endpoints: `Providers/Plex/PlexSubtitleSearch.swift`
  (Jellyfin: `JellyfinSubtitleSearch.swift`), routed from `MediaService+Subtitles.swift`.
- Account-level plex.tv settings (library order, language defaults):
  `MediaService+LibraryOrder.swift` / `+LanguageDefaults.swift` route to
  `Providers/Plex/PlexAccountPreferences.swift`, with the shared state in
  `LibraryOrderStore.swift`.
- New response shapes: a DTO in `Dusk/Sources/Providers/Plex/DTO/` plus its
  mapping in `Providers/Plex/Mappers/`; the domain type gets a memberwise
  initialiser, not `Decodable`.

## Live TV And Guide Endpoints

Files: `MediaService+LiveTV.swift` (discovery across servers, and routes),
`Providers/Core/LiveTVProviding.swift` (the facet), `Providers/Plex/PlexLiveTV.swift`
(every Plex Live TV request and the tune), `Providers/Plex/PlexLiveChannelMatcher.swift`
(filing airings under channels), `Domain/LiveTV.swift` and `Domain/LiveTVDevice.swift`
(the `Live*` models, memberwise only), `Providers/Plex/DTO/PlexLiveTVDTO.swift`
(every Live TV response shape and its lenient decoding) and
`Providers/Plex/Mappers/PlexLiveTVMapper.swift` (DTO → `Live*`, including the
id/time fallbacks, tune media and the server id on `LiveTVProvider`).

- Routing: each `MediaService` Live TV method resolves the facet of the
  source's server (`liveTV(for:)`: the source's `serverID`, else
  `liveTVServerID`) and calls it. A source whose server the pool does not know
  (an IPTV source, `IPTVImages.serverID`) gets no facet: nothing is sent, the
  call throws `noServerConnected` (`liveTVLineup` files nothing). This replaces
  the `isIPTV` guards that kept IPTV away from Plex calls.

- Live TV uses one server only (v1): the highest-priority connected server
  whose `/media/providers` lists an EPG provider. Every connected server is
  asked, the provider carries that `serverID`, and all channel/grid/tune calls
  go back to it. Discovery only latches once a DVR is found; "none" is
  re-checked whenever the connected servers change.
- Discovery (`discoverLiveTVProvider` → `LiveTVDiscovery`) is `.found`,
  `.none` (every server answered without a DVR; 401/403/404 and an unreadable
  list count as answers) or `.inconclusive` (a server timed out, 5xx'd or
  dropped and no other has a DVR). `LiveTVViewModel.discover()` retries an
  inconclusive pass with backoff (2s doubling to 60s) on its own shell task,
  never behind the library load. 1.7.2 (4) hid Live TV for the session after
  one slow or failed `/media/providers`, because a4ef6ea stopped re-sending
  timed-out requests and nothing else asked again.
- A pass decides once a DVR is found and every higher-priority server has
  answered, or after a 2s grace, so an unreachable server can't hold the tab
  back. `/media/providers` runs on `slowQuerySession` (its own connections,
  120s budget) so it never queues behind Home's slow reads.
  The provider advertises its grid path and DVR identifier; do not hard-code
  `tv.plex.providers.epg.*` identifiers.
- Load stations from the provider's `/lineups/dvr/channels` path and currently
  airing programs from `/watchnow/all`.
- The guide grid takes a time range with no `channelGridKey`
  (`grid?endsAt>=<start>&beginsAt<=<end>`, sent as the strict, percent-encoded
  `endsAt%3E=` / `beginsAt%3C=`) and then answers for every channel at once,
  like Plex Web (`getLiveTVGuideAirings`, checked on PMS 1.43.5 XMLTV). The
  older form, ONE `channelGridKey` plus `date=yyyy-MM-dd` per channel
  (`getLiveTVGuide(dates:)`), answers only for the last of repeated
  `channelGridKey` values and nothing for comma lists; it stays as the fallback
  when a server ignores the range (nothing at all for today and tomorrow), and
  for the player's schedule. Plex drops airings that already ended (only the
  one still on is kept), so there is no Plex past beyond recordings.
- `LiveTVViewModel` loads the Plex guide continuously, like an IPTV source:
  one ranged request per local day, today + tomorrow first (refreshed every
  15 min), then the following days 3 at a time (every 3 h) until a day comes
  back with nothing at all, 21 days, or 20 000 airings. The section draws its
  whole guide on one axis (`timelineWindow(of:)`); the day menu only scrolls.
  Past days in the menu exist only while an IPTV source has catch-up.
- Catch-up on Plex: Plex has none. A past airing (`LiveProgram.guid`,
  `plex://…`) is playable only when `/library/all?guid=` on the DVR's server
  finds a library copy (`liveTVRecording`, normally the DVR recording);
  `LiveTVViewModel.findRecordings` looks up ended airings, 40 per pass,
  caching hits and misses per guid. Unverified against a real DVR: that EPG
  airings carry the same guid as their matched recording. `LiveTVViewModel.load()` refetches when the
  guide is 15 minutes old, the day changed or the selection changed, else just
  trims ended programs; the view calls it on appearance and scene activation
  and `keepFresh()` re-checks every minute while it is on screen. Issue #17:
  a date captured at launch kept an Apple TV on an old day, and the
  calendar-day window showed only the last hour of the evening.
- Grid items list every airing in `Media`; the facet's
  `lineup(source:channels:programs:)` (Plex: `LiveTVLineup(provider:channels:programs:)`,
  `MediaService.liveTVLineup` for features) splits them into one program per airing and files each through
  `PlexLiveChannelMatcher`: identifiers first (`gridKey`, `channelIdentifier`,
  `channelID` against the channel's `gridKey`/`id`/`identifier`/`key`), then
  channel number, call sign and title only when they name exactly one channel.
  Which key a provider uses is not uniform (issue #17: HDHomeRun lineup with
  an empty guide; its real response shape is still unconfirmed).
- A channel is always tunable, with or without guide data: tune with a nil
  program. On tvOS every row leads with a focusable channel card (Watch Live)
  in line with the program cards: a Watch button in the row header was never
  reached by focus, and a row with nothing focusable stops focus moving down.
  Guide cards use the system `.card` style (no stacked `.hoverEffect`) plus a
  lighter neutral platter on focus for artwork-less tiles.
- The program sheet's Watch Live parks the request and plays it from the
  sheet's `onDismiss` (the `PhotoBrowserView` pattern): presenting the player
  while the sheet was still dismissing never started it on tvOS. The sheet
  opens with Watch Live focused on tvOS.
- Tuning is `POST /livetv/dvrs/{dvrID}/channels/{channel-id}/tune`. The channel
  `id` from the lineup is Plex's internal DVR mapping key; never substitute the
  display-only `vcn` value. Send a distinct `X-Plex-Session-Identifier` with the
  tune request and reuse it for timeline keepalives. Plex server
  versions return playable media under direct Metadata or nested
  `MediaSubscription > MediaGrabOperation > Metadata/Video`; nodes can be
  objects or arrays, so decoding must tolerate every form. Numbers are not
  typed either: PMS 1.43 (Threadfin/HDHomeRun tuner) sends `Media.id`,
  `Part.id` and `Stream.id` as strings, so `TuneMedia`/`TunePart`/`TuneStream`
  read every number leniently. A strict `Int` used to drop the whole Media and
  play the session as codec-less media through VLCKit.
- A refused tune has no session key: the grab operation carries
  `status: "error"`, an `error` text and, for a busy tuner, `Conflicts`
  ("The recording conflicts with other recordings"). `tuneFailureMessage`
  turns that into "All tuners are in use…". One-tuner devices are common
  (Threadfin defaults to 1). Plex keeps a channel's tuner session for ~3–4
  minutes after the last consumer stops, and a re-tune of the SAME channel
  reuses it (it is shared between viewers), so Dusk stops only its own
  consumer transcode and never the `/livetv/sessions` static transcode.
- Direct play first (`liveTVDirectPlayURL`): when the tuned stream plays in
  AVPlayer as is (`TuneMedia.supportsLiveDirectPlay`: MPEG-TS, progressive
  8-bit H.264, AAC/AC-3/E-AC-3/MP3), Dusk sends a `directPlay=1` decision for
  the session with `session` = the tune's `X-Plex-Session-Identifier` and
  plays the answered `Part.key`,
  `/livetv/sessions/{uuid}/{sessionIdentifier}/index.m3u8`: the grabber's
  copy of the tuner stream in 1 s TS segments, no second transcoder. That
  playlist 404s ("Failed to find consumer") until such a decision registered
  the consumer. Strip the `X-Plex-Incomplete-Segments=1` Plex puts on the key.
  `transcodeSessionID` is nil (nothing to ping/stop). An engine error on it
  re-tunes once through the transcoder (`startLiveDirectPlayFallbackWatch`).
- Why not the transcoder (PMS 1.43.5, 2026-11-12): Live TV media has no
  bitrate, which Plex counts as 2147483647 kbps. On a connection Plex calls
  WAN (everything through the plex.mvr.bz reverse proxy, Tailscale) that
  "exceeds" `WanTotalMaxUploadRate`, and Plex rewrites the request to a
  1280x720 quality-99 VAAPI re-encode with direct stream disabled, whatever
  `directStream`/bitrate/resolution the client sends (log: "Reducing playback
  quality … disable video DS"). Direct play has no such cap. Cold Threadfin
  tune in the simulator: playing after 11.9 s transcoded vs 5.8 s direct.
- Otherwise feed the `/livetv/sessions/{sessionID}` key to Plex's universal
  HLS decision/start flow with direct stream enabled (MPEG-2/interlaced
  broadcast video, MP2 audio). The session key is a virtual resource, not a
  library file.
- Program-guide history is metadata, not a recording catalogue. A tuned HLS
  session can seek only inside Plex's sliding time-shift window; never imply
  that an arbitrary past guide item is playable.

## Playback URL Handling
Files: `Providers/Plex/PlexPlayback.swift` (requests), routed by
`MediaService+Streams.swift`.
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
  engines do not use `MediaService` request headers.
- Never log raw playback URLs; use `sanitizedPlaybackURLString(for:)`.

## Watchlist (plex.tv Discover; Jellyfin favourites)
File: `MediaService+Watchlist.swift` (load, server matching, optimistic edits),
routed to the account's `WatchlistProviding` = `Providers/Plex/PlexWatchlist.swift`
(the Discover and plex.tv calls) or `Providers/Jellyfin/Account/JellyfinWatchlist.swift`;
the bookmark and menu item ask the account for a title's entry
(`MediaService.watchlistEntry(for:)`); models `Domain/Watchlist.swift` (`WatchlistEntry`,
`WatchlistAvailability`, `HomeLayoutHub`), shared state
`MediaService/WatchlistStore.swift` (`media.watchlist`).
- Account-level, on `https://discover.provider.plex.tv` (`PlexWatchlist.discoverBase`,
  the mock's `/discover` prefix in screenshot mode), with the active profile's token.
  Verified on a real account 2026-10-25: `GET /library/sections/watchlist/all?sort=watchlistedAt:desc`
  (paged, `totalSize`), `PUT /actions/addToWatchlist|removeFromWatchlist?ratingKey=`
  (idempotent, 200 + empty container), `GET /library/metadata/{rk}` (has the `Guid`
  array: tmdb/imdb/tvdb), `GET /library/metadata/{rk}/availabilities` (`Availability[]`
  with `title`, `offerType` subscription/buy/…).
- The discover `ratingKey` is the hex id that ends a modern item's `plex://movie|show/…`
  guid, so adding a server item needs no lookup. Legacy-agent / `local://` items have
  none and get no bookmark (`WatchlistEntry.discoverRatingKey`).
- Matching to servers: `GET /library/all?guid=plex://…` per title per connected
  server, 4 at a time, skipping hidden libraries; the highest-priority server wins.
  Misses are cached 30 min per server, hits are re-read every load (progress). No
  tmdb/title fallback for legacy-agent libraries yet.
- Loads beside Home (never gating its first paint), reused for 2 min unless forced
  (pull-to-refresh, an add without a known server item). A running load is only
  joined for the same server set: one started before a server connected cannot match.
- **Jellyfin** (decided 2026-11-28, 04 §21 row 2): the Watchlist is the active
  user's favourite films and shows (`/Items?isFavorite=true&includeItemTypes=Movie,Series`,
  newest in the library first: Jellyfin keeps no favourite date), and the
  bookmark is `POST`/`DELETE /UserFavoriteItems/{id}`. Each entry carries its
  server item (`WatchlistEntry.serverItem`), so nothing is matched; its key is
  `jellyfin://<server>/<item>`. No availabilities, no Home layout (default
  placement). Favourites carry no library id, so a hidden library does not hide
  its favourites from the row.
- Failure is quiet: `.unavailable` = no Home row, no bookmark. Discover calls never
  trigger the fresh-auth retry (a 401 there is "no Watchlist for this profile").
- **plex.tv keeps the `experience` setting per `X-Plex-Product`.** Dusk's own copy
  (product "Dusk") holds only the sidebar; Plex Web's holds `homeSettings.hubs`
  (`hubIdentifier`, `server.machineIdentifier`, `isHidden`, `hasCustomizations`). The
  Watchlist reads Plex Web's copy for Home placement; Plex's watchlist row is
  `home.watchlist`.
- **Current Plex Web (4.163) no longer renders Home from `homeSettings.hubs`**: it only
  migrates it (`hasCustomizations` → `autoHomeHubsEnabled=false`). Hiding a Home row is
  per server: `GET /hubs/sections/{id}/manage` lists the library's rows by kind
  (`movie.curated`, `custom.collection.<section>.<id>`), and
  `PUT …/manage/{identifier}?promotedToRecommended=&promotedToOwnHome=&promotedToSharedHome=`
  (all three, 1/0, as Plex Web sends them) sets them. `GET /hubs` rows usually lack
  `librarySectionID`, and their identifier is kind + section + variant
  (`movie.curated.2.1`), so the trailing number is NOT the section
  (`ManagedHub.matches`). Owner-only. See `MediaService+HomeRows.swift`
(permission, routes) and `PlexHomeRows.managedRow(for:source:libraryIDs:)`.

## Playlists
File: `MediaService+Playlists.swift` (routes, store loading), Plex requests in
`Providers/Plex/PlexPlaylists.swift` behind `PlaylistProviding`
(`MediaService.playlistFacet(on:)`), models `Domain/Playlist.swift`
(`Playlist`, `PlaylistEntry`, `PlaylistAddResult`), shared state
`MediaService/PlaylistStore.swift` (`media.playlists`).
- A playlist belongs to one server and to the signed-in (Home) user. Every call
  routes to the playlist's server; an item can only be added to a playlist on
  its own server (`server://{machineID}/com.plexapp.plugins.library/library/metadata/{rk,rk}`,
  built privately in `PlexPlaylists`).
- `GET /playlists?playlistType=video` per connected server (`streamPlaylists`,
  merged A–Z by the store); `GET /playlists/{id}/items` is paged (200 per page).
- Create `POST /playlists?type=video&title=&smart=0&uri=` (never empty); add
  `PUT /playlists/{id}/items?uri=`; remove `DELETE /playlists/{id}/items/{playlistItemID}`;
  move `PUT …/items/{playlistItemID}/move?after={playlistItemID}` (no `after` =
  top); rename `PUT /playlists/{id}?title=`; delete `DELETE /playlists/{id}`.
- Verified on a real PMS (plex-demo, 1.43.5, 2026-10-22): rename via PUT title
  (and summary) works and answers an empty 200; adding a show or season `uri`
  adds all its episodes and Plex skips ones already present (`leafCountAdded` <
  `leafCountRequested`); smart playlists answer item edits with 400 and list
  items without `playlistItemID`; the list's `duration` is milliseconds but the
  `/items` container's `duration` is **seconds**.
- `PlaylistStore` drops stale answers: every load has a generation that its
  commits must match, and edits/refreshes carry the session generation (bumped
  by sign-out and profile switches) they started in.
- `HomeHubFilter` still keeps Plex's own playlist hub off Home.
- `PlaylistEntry.playlistItemID` is the server's entry handle as a string (Plex's
  number as text, so its requests are unchanged); `id` adds `#n` to repeats that
  share a handle.

Jellyfin playlists (`Providers/Jellyfin/Facets/JellyfinPlaylists.swift`, J-07),
measured on jellyfin-demo 12.4 as a non-admin user:
- List `/Items?includeItemTypes=Playlist&recursive=true` (`ChildCount`,
  `RunTimeTicks`, the server-drawn `Primary` mosaic), entries
  `/Playlists/{id}/Items` paged by 200.
- An entry's `PlaylistItemId` is its item id: repeats share it and
  `DELETE /Playlists/{id}/Items?entryIds=` removes all of them (the detail page
  re-reads then). Jellyfin appends repeats and expands a show or season itself;
  Dusk expands shows and seasons to episodes (`/Items?ids=` for the kinds), drops
  what `GET /Playlists/{id}` `ItemIds` already holds and posts the rest, so adds
  count and skip like Plex's.
- Move is `POST …/Items/{entry}/Move/{index}` with the final index: "after X" is
  X's position in the current order without the moved entry, plus one.
- Rename `POST /Playlists/{id}` `{Name}`; delete `DELETE /Items/{id}` works for
  the owner without `EnableContentDeletion`. No smart playlists.

## Photo Libraries
File: `MediaService+Photos.swift`, model `Domain/PhotoItem.swift`.
- Photo sections are decoded as `PhotoItem`, never `MediaItem` (which keeps
  `type: "photo"` as `.unknown`, and that is what keeps photos off Home, Search and the
  detail routes). In JSON an album and a photo are both `type: "photo"` under
  `Metadata`; only an album's `key` ends in `/children`. Clips are `type: "clip"`,
  `subtype: "photo"`, with normal video `Media`/`Part`.
- Everything is queried through `/library/sections/{id}/all` with Plex search types
  (clip 12, photo 13, album 14): albums `type=14&parent=<album>` (no parent = root),
  an album's photos `type=13,12&parent=<album>`, root loose photos `type=13,12`, the
  timeline `type=13,12&clusterZoomLevel=1` (without it the type filter only reaches the
  root). Not `/children`: it mixes sub-albums into the photos, so a sorted, paged walk
  would bury the albums on the last page. Paging is the usual
  `X-Plex-Container-Start/Size` + `totalSize`.
- `originallyAvailableAt` is a camera-local day; `PhotoItem.displayDate` parses it
  in the device's time zone. Place names (`Place` tags) only exist when the server
  saves location names (and are admin-only by default); there is no lat/lon.
- Sources: python-plexapi `photo.py`/`library.py`, the LukeHagar plex-api-spec, and
  JSON fixtures from another Swift client measured on PMS 1.43. Not yet checked
  against a real PMS from Dusk.
- Jellyfin (`Providers/Jellyfin/Facets/JellyfinPhotos.swift`, mapper
  `JellyfinItemMapper+Photos.swift`): one `/Items` page per query. Albums are
  `PhotoAlbum` and plain `Folder` children of the album or library, by
  `SortName`; an album's media is its `Photo` and `Video` children by
  `PremiereDate, SortName` (Plex's order for EXIF-dated photos; undated ones go by name, where Plex uses the file time); the timeline is the
  library's `Photo` and `Video` items, recursive, by `DateCreated, SortName`
  descending. Albums and media send `recursive=false` explicitly: with a library
  as parent, `includeItemTypes` alone walks the whole tree.
  - The timeline sorts by `DateCreated` because the server sets it from the EXIF
    date when a photo has one and from the file otherwise, the date Plex orders
    by. `PremiereDate` is absent without EXIF, so it would put every undated
    photo last. A clip's `DateCreated` is its file date, so a clip with an older
    recording date sits by its file date.
  - The server reads the zone-less EXIF time in its own zone and stores it as
    UTC (EXIF 09:15 in Zurich is `07:15Z`). `originallyAvailableAt` is that
    instant's day in the device's zone, usually the server's.
  - No `partKey`: `photoDisplayURL` falls back to the Primary image, which the
    server already rotates by EXIF orientation. It is fetched with `fill*`, so
    the image covers the screen box instead of fitting inside it, larger than
    Plex's for photos whose shape differs from the screen.
  - No place names (Jellyfin has only latitude and longitude) and no album
    composite.

## Image URL And Data Handling
Files: `MediaService+Images.swift` (routing, fetching), `Providers/Plex/PlexImages.swift`
(Plex URLs), `Providers/Jellyfin/JellyfinImages.swift` (Jellyfin URLs),
`IPTVService/IPTVImageProvider.swift`; the facet is
`Providers/Core/ImageProviding.swift`.
- Call `media.imageURL(for: ArtworkRef, size: ImageSize)` from view models/UI
  helpers. An `ArtworkRef` is the server id plus an opaque locator (for Plex the
  server-relative path); `MediaItem.artwork` is an `ArtworkSet`, and the poster/
  landscape fallback order lives on it (`preferredPoster(for:)`, …). A ref keeps
  the call site's server, never a guessed one.
- Routing: the facade resolves `pool.connection(for: ref.serverID)` and asks that
  session's provider (`session.provider.images`), passing the session in, since
  providers hold no endpoint or token. No session (server not connected) or no
  provider (a session built outside the pool) falls back to `PlexImages`, so
  absolute-URL artwork still resolves. The `IPTVImages.serverID` sentinel goes to
  `IPTVImageProvider` before any pool lookup.
- Plex: with dimensions, URLs go through `/photo/:/transcode` using display-scaled
  pixel dimensions (`ImageDisplayScale`), `minSize=1`, and `upscale=0`.
- Jellyfin: the locator is `jf:<itemID>:<type>:<index>:<tag>`
  (`JellyfinArtworkLocator`, item id = the image's owner, so an episode's show
  poster names the series). URLs are `/Items/{id}/Images/{type}[/{index}]?tag=`
  plus `fillWidth`/`fillHeight` (display-scaled) and `quality=90`. `fill*`
  covers the box without cropping or upscaling, so the same `ImageSize` gives
  the same pixels as Plex's `minSize=1&upscale=0`; chapter images ignore `fill*`
  and use `maxWidth`/`maxHeight`. The tag makes the URL an immutable cache key.
  No token in the URL or the request (images are unauthenticated), no `format`
  (logos stay PNG). A `jf:` ref whose server is not connected falls through to
  `PlexImages` and gives an unloadable URL, i.e. the placeholder.
- The transcode `url` is the server-relative path (`transcodeSourceURLString`),
  as Plex Web sends it. With the server's own absolute URL the server fetches
  itself, which 404s over a LAN address and left every poster blank at home.
- Without dimensions, `PlexImages.directImageURL` builds the server-relative URL
  without embedding a token.
- `imageRequestURLString(for:includeToken:)` accepts absolute URLs as-is and
  builds relative paths from the connection of the item's server, resolved via
  `pool.connection(for:)`.
- `imageData(for:)` authenticates URLs matching a connected server's
  scheme/host/defaulted port (`imageServerConnection`): the provider builds the
  request (`authenticatedRequest`, Plex headers + token), the facade does the
  cache, the send with its fresh-sign-in retry, and one token refresh on a 401
  (then `markUnauthorized`). Other URLs are fetched as plain binary requests.
- `DuskAsyncImage` uses `DuskImageLoader`, delegating to
  `media.imageData(for:)`.
- `AppImageCache.shared` is the shared URL cache and can be cleared in settings.
- Image cache entries have a max TTL of 3 days. Older URL cache responses are
  discarded on read and reloaded on demand.
- Player scrub previews use Plex's BIF index endpoint
  `/library/parts/{partID}/indexes/sd`, behind the marker facet:
  `media.scrubPreview(forPartID:serverID:)` (`MediaService+Markers.swift`)
  routes to `PlexMarkers` (`MarkerProviding`), which requests and parses the
  BIF file opportunistically for online playback only; failures return no
  preview source and should not affect normal image or playback behavior. The
  read has its own healing (re-authorize a missing session, one token refresh
  on 401) and never goes through `rawServerRequest`, so a missing index (404)
  cannot start connection recovery. The iOS, tvOS and Mac players all load
  previews this way.

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

- `Domain/MediaItemID.swift` defines `CodingUserInfoKey.duskServerID`,
  `Decoder.duskServerID`, and `MediaItemID { serverID, itemID }` (Codable key
  `ratingKey`). Item-family values (items, details, seasons, episodes,
  libraries, hub rows) are decoded as Plex DTOs (`Providers/Plex/DTO/`) and
  built by `Providers/Plex/Mappers/PlexItemMapper.swift` (hub rows by
  `PlexHubMapper.swift`), which takes the fetched server's id and stamps it
  on everything it builds, nested items included. Their remaining direct
  `Decodable` conformances (`Providers/Plex/PlexItemDecodingBridge.swift`) are
  transitional forwarders that map with `decoder.duskServerID`; nothing else
  reads it. Live TV, playlists, photos and history are stamped by their mappers
  (`Providers/Plex/Mappers/`). Do not add post-decode copy helpers or wrappers.
- `MediaItem.id`, `MediaDetails.id`, `Episode.id`, and `Season.id` are
  `MediaItemID`; `==`/`hash` include the server. `Library.id` is
  `"<serverID>|<key>"`. `AppNavigationRoute` carries a `MediaItemID`.
- `serverID` is `String?`: nil means "not stamped" (a model built locally or
  decoded outside the pool), not "the primary server".
- Swift field names are neutral (`itemID`, `parentID`, `grandparentID`,
  `libraryID`); every `CodingKeys` case keeps the Plex/persisted key
  (`ratingKey`, …). Version, part, stream and marker ids are `String`:
  decoded from a number or a string, written back as a number when they are
  one (`Domain/MediaIDCoding.swift`), so `downloads.json` and the
  converted-media blob are unchanged. Order ids with `mediaIDPrecedes`, never
  `<` on the strings.
- More neutral names over unchanged Plex keys: `resumeOffsetMs` (`viewOffset`),
  `playCount` (`viewCount`), `lastPlayedAt` (`lastViewedAt`), `episodeCount` /
  `watchedEpisodeCount` (`leafCount` / `viewedLeafCount`), `MediaStream.kind`
  (`streamType`, `StreamKind` keeps Plex's 1/2/3), `isServerSelected`
  (`selected`), `colorTransfer` (`colorTrc`). The four DOVI fields are
  `dolbyVision: DolbyVisionInfo?`, each still optional on its own.
- External ids are read through `ExternalIDs` (`item.externalIDs`): every
  `<namespace>://<value>` in server order; each caller keeps its own rule
  (first, first numeric, first that looks like an imdb id).
- `Providers/Core/ServerRegistry.swift`: which provider a `serverID` belongs
  to; a server with no record is Plex. Lookup only, nothing stored yet.
- `Domain/ContentKey.swift` is the *cross-server* identity used for merging:
  the scalar `guid` when it starts with `plex://` (`.native`), else tmdb > imdb >
  tvdb from the external ids namespaced by type, else `type|normalizedTitle|year`
  (seasons: show|season, episodes: show|season|episode), else `.instance(id)` —
  this one copy and nothing else. It answers "is this the same title as that one,
  on another server" — never use it as a storage key or a request parameter.
  `contentAliases` lists every strong key a copy carries (native plus each
  external id); nothing reads it yet, it is for providers without a native id.
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
  - **Editions** (`editionTitle`, "Director's Cut") are separate Plex items
    with the same guid and external ids, so every non-instance key appends
    the loosely normalized edition. Two editions never merge and are never each
    other's playback fallback; the same edition still merges across servers.
    TV editions live on the show only, so a show's episodes and seasons carry
    no edition and still key on the shared ids. The UI shows the edition after
    the year in poster subtitles and in the detail hero tagline, never as a
    badge.

## Merging Rules
`MediaService/MultiServer/` merges what the connected servers return. Fan-outs use
a `TaskGroup`, a server that fails contributes `[]`, and results are grouped by
`ContentKey`.

Entry points on `MediaService` (`MediaService+MultiServer.swift`):
`mergeServerIDs` (connected servers in priority order),
`fanOutAcrossServers` (all answers, priority-ordered, once they all land),
`streamAcrossServers` (each answer the moment it lands, carrying its `rank`),
`streamHomeHubs` / `streamContinueWatching` / `streamSearch`,
`mergedHubItems(for:size:)` (pages every source of a merged row and re-merges),
and `registerAlternates(_:)`.

Every merge takes its per-server lists in **priority order** and is a pure
function of them. That is what makes progressive rendering safe: a screen can
merge what it has, render, and merge again when the next server answers without
deriving a different list. Strong movie identities also merge across libraries
on one server, even when only one server answers. Movie keys include Plex and
external-ID aliases (TMDB/IMDb), with edition boundaries preserved. Strong TV
identities (show/season/episode GUID or external id) merge across libraries on
one server too — the same show in "Kids TV" and "TV" is one Home entry, and the
same-server copy that wins is the most recently watched, then furthest along
(`isMoreRecentlyWatched`); across servers the priority server's TV copy keeps
the slot. Weak same-server matches stay separate; title/year alone cannot merge
two libraries' items. Individual library grids and playlist membership/order
remain per source; search, Home, merged hubs, recommendations and person titles
use the merged entries. Movie representatives carry watched state first, then
the greatest progress fraction (offset/duration); equal progress keeps source
order. This also governs movie Continue Watching representatives.

- `ContentAlternatesIndex` (`media.alternates`) is the side table the merges
  fill and playback reads: `register(_:for:)` records that these `MediaItemID`s are
  the same content, `instances(of:)` returns every known copy. It accumulates for
  the whole session and is cleared by `tearDownServerSessions()` (sign-out, Plex Home switch),
  because rating keys only mean something for the account that fetched them.
  Only strong keys are recorded, and every server-scoped rating key is kept,
  including multiple libraries on the same server (so dismissing from Continue
  Watching and watched fan-out reach the hidden library copy too). A later registration bridging two keys joins their known copies.
  `MediaItemMerge.alternates(in:)`/`combine(_:_:)` retain the same identities.
- `MediaService.movieCopies(for:)` discovers movies with per-title
  `/library/all?guid=…&includeGuids=1` lookups, filtered against strong aliases,
  edition and hidden-library rules, then loads each copy's details. It also
  works from an unmerged library grid. The detail version picker keeps each
  version's owning item ID, media ID and library name. Startup compares media
  within its selected server; existing server priority stays authoritative.
  Explicit watched/unwatched actions discover same-server movie copies before
  using `setWatchedAcrossServers` to reach every known copy. Timelines still
  belong only to the played copy. `MovieLibraryMergeTests` covers the pure merge,
  aliases, progress, alternate registration and version choices;
  `TVLibraryMergeTests` covers same-server TV copies.
- Continue Watching (TV): representative = newest `lastViewedAt`, then larger
  `viewOffset`, then lowest server rank; the row is then sorted newest-first. The
  other copies are registered as alternates (in rank order) for playback fallback.
- Hubs: keyed on `HomeRow.mergeKey` — for Plex `hubIdentifier` with its
  trailing numeric section suffix stripped, plus type (normalized title as
  fallback), computed by `PlexHubMapper`. Deduped by content key and
  round-robin interleaved in priority order, except merged Recently Added Movies:
  `MediaItemMerge.hubItems` sorts those by `addedAt` descending before deduplication
  (newest addition determines placement; movie progress determines the displayed
  copy; ties keep source priority/order; missing dates come last).
  This applies to full and promoted hub rows, repeated-title folding before its
  cap, inline expansion, and Show All. Single-source rows and TV grouping retain
  Plex's order; update/release dates never replace `addedAt`. `HomeRow.sources` records each
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
  - After the `.home` merge, `HubMerge.collapsingRepeatedTitles` folds Home rows
    that share a normalized title into the first copy (items merged as above, capped
    at the longest copy, every copy kept as a source for "Show All"). Some Plex
    rows are generated per library under a title that does not name the library
    — the seasonal "Oh, the Horror!" row exists once per movie library — so an
    account with eleven movie libraries otherwise got eleven identical rows.
  - A merged row's `id` is the merge key (`HomeRow.mergeIdentity`), never the
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
- Live TV uses the highest-priority connected server that has a DVR.

## Model Conventions
- List, hub, and search rows use `MediaItem`; full metadata uses
  `MediaDetails`.
- `ratingKey` is stable only *within* one server; `MediaItemID` is the identity.
- Plex capitalized arrays map directly: `Media`, `Part`, `Stream`, `Genre`,
  `Role`, `Marker`, `Image`, etc.
- Most fields are optional because Plex varies by endpoint, media type, agent,
  library, and ownership.
- `MediaKind` decodes unknown raw values to `.unknown`.
- "Other Videos" (personal media / YouTube) sections report `type="movie"`; the
  section-level discriminator is `Library.libraryType == .video`, classified
  from section `subtype == "clip"`, the none-agents
  (`tv.plex.agents.none`/`com.plexapp.agents.none`), or a "Plex Video Files"
  scanner prefix. Items from those sections are `type="movie"` with item
  `subtype == "clip"` — `MediaItem.isClip`/`MediaDetails.isClip` is the
  per-item marker that drives 16:9 rendering and video-detail routing anywhere
  clips surface (hubs, search, continue watching, downloads).
- `HomeRow` decodes items lossily because search can return suggestion records
  that are not media-shaped.
- `PlexPinnedSource` is a typed *read view* over one `pinnedSources` element; its
  `raw` is the element exactly as plex.tv sent it and writes mutate `raw`, so
  unmodeled fields round-trip intact.
- `DuskJSONValue` is the loss-free JSON tree used for the plex.tv blob. Ints stay
  ints, so `schemaVersion` is never rewritten as `12.0`.
- `Media` / `Part` / `Stream` / `Marker` / `Rating` decode as DTOs in
  `Providers/Plex/DTO/` (`PlexMediaVersionDTO.swift`, `PlexMarkerDTO.swift`,
  `PlexRatingDTO.swift`) and map onto the domain types in
  `Providers/Plex/Mappers/PlexMediaVersionMapper.swift`. That file also holds
  the domain types' `Codable`, because `downloads.json`, `convertedMediaData`
  and the offline metadata cache store the Plex wire shape: never rename a key.
  The stream DTO reads selected/default/forced/hearing-impaired as bool-ish
  values because Plex sends both ints and bools. The transcode decision
  response is `PlexTranscodeDecisionDTO` + `PlexTranscodeDecisionMapper`.
- `SubtitleSearchResult` models one provider hit from the subtitle search.
  Only `key` (the provider download handle) is required; `id` falls back to `key`
  because search hits are not library streams and usually arrive as `id: 0`.
  `score` tolerates int, double, and string, and the flags reuse the same bool-ish
  handling as `MediaStream` through a file-local container helper, so `MediaStream`
  stays untouched. `displayTitle`/`detailText` are the list-UI labels.
- `MediaItem` and `MediaDetails` resolve `clearLogo` from either an explicit
  field or the `Image` array.
- `MediaDetails.markers` are sorted for skip-intro/credits UI.
- Person id helpers tolerate `id`, filter query, and key suffixes.
- `AudioTrack` and `SubtitleTrack` are engine-facing app models, not raw
  responses.

## Extension Points
- Prefer same-type `MediaService` extensions by concern.
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
- Decode through `pool.decoder(for:)` and map with the request's server id so
  models keep their server stamp.
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
