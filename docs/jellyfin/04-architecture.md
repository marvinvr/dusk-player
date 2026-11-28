# Jellyfin support — 04: Target architecture

The design Dusk moves to so that Plex is one media-server provider and Jellyfin
another. Design only: no app code was changed for this document. Inputs are
[01-plex-surface.md](01-plex-surface.md) (what exists),
[02-jellyfin-api-mapping.md](02-jellyfin-api-mapping.md) (what Jellyfin offers)
and [03-prior-art.md](03-prior-art.md) (measured playback and auth behaviour).
The execution order is in [05-plan.md](05-plan.md).

Goal, in one line: **the same app on either server, and the sign-in screen is
the only place a user can tell which one they have.** No extra settings, no
extra buttons, no "Jellyfin mode".

Every section ends in a decision. Where a decision rests on something that was
not measured, it says so and names the package in 05 that measures it.
Decisions that are product calls rather than engineering calls are collected in
§22 for sign-off.

## 1. Principles

1. **One vocabulary above the provider line.** Features, view models, the
   playback coordinator, downloads and the merge layer use neutral types and
   neutral verbs. The words `Plex` and `Jellyfin` appear only under
   `Providers/` and in the sign-in flow. This is enforced by a script (§5.4),
   not by review.
2. **Capabilities, never kinds.** Nothing outside `Providers/` asks "is this
   Plex?". It asks whether a facet exists (`server.liveTV != nil`), whether a
   row can be hidden (`row.canHide`), which filters a library offers. A
   provider that cannot do something says so through the same surface the other
   one uses to say it can.
3. **The decision engine is Dusk's.** `StreamResolver` and the delivery ladder
   decide what plays where. A provider answers factual questions (what streams
   exist, give me a URL for this intent, was it really a copy) and never makes
   the quality decision.
4. **Persisted strings never change.** Every UserDefaults key, Keychain
   account, file name and Codable key that exists today keeps its exact string.
   Swift names change, stored names do not. Existing Plex users migrate nothing
   (§19).
5. **Phase 0 changes no behaviour.** The refactor that puts Plex behind the
   abstraction must produce the same requests and the same pixels as today
   (05, Phase 0 gate). Jellyfin work starts on top of that, not alongside
   changes to Plex behaviour.
6. **A single-server Plex install looks exactly as it does today.** Same rule
   multi-server already follows.

This overturns three written rules, which Phase 0 updates in the same change
that makes them false: `AGENTS.md` ("No `MediaProvider` protocol"),
`docs/playback.md:11-12`, and `docs/codebase-map.md` → Cross-Cutting
Invariants.

## 2. Layering

```text
Features/  App/  Siri/  TopShelf/  Downloads/  Playback/     neutral types only
        │
        ▼
MediaService            @MainActor @Observable facade (today's PlexService role)
  ├─ AccountStore       signed-in accounts, active profile scope
  ├─ ServerPool         one ServerSession per connected server, any provider
  ├─ MultiServer/       fan-out, merge, alternates (pure functions, unchanged)
  └─ shared stores      playlists, pinned playlists, library order, watchlist
        │  routes by serverID
        ▼
MediaServerProvider     one instance per server      ┐
MediaAccountProvider    one instance per account     ├─ protocols (Providers/Core)
ProviderRegistry        ProviderKind → ProviderFactory┘
        │
        ├─ Providers/Plex/       PlexAccountProvider, PlexServerProvider, DTOs, mappers
        └─ Providers/Jellyfin/   JellyfinAccountProvider, JellyfinServerProvider, DTOs, mappers
```

Source layout after Phase 0:

```text
Dusk/Sources
  Domain/               neutral models (was Models/, minus Plex response shapes)
  MediaService/         facade, AccountStore, ServerPool, probe, priority, MultiServer/, stores
  Providers/
    Core/               protocols, ProviderRegistry, capability types, request/intent types
    Plex/               client, transport security, DTO/, mappers, facet implementations
    Jellyfin/           client, DTO/, mappers, DeviceProfile builder, facet implementations
```

**Decision: `MediaService` stays a wide facade.** It is not a god object by
accident: server routing, self-healing reconnects, hidden-library filtering and
cross-server merging all need one place that knows every session, and 1 280
call sites already talk to exactly that. Its public methods keep today's
shapes (renamed where a name is Plex vocabulary) and each one is a short route:
resolve the session for the id's `serverID`, call the provider facet, apply the
cross-server step if there is one. Providers stay narrow and per-server. The
facade's extension files are grouped by facet so each has one owner.

## 3. Provider protocols

**Decision: facet protocols composed into two provider protocols, not one
protocol and not a bag of free capability protocols.** One flat protocol would
be 180 methods and force Jellyfin to stub things it cannot do. Free-floating
capability protocols with `as?` casts scatter the "can it?" question. Facets
give each area an owner and make optionality explicit in the type.

```swift
enum ProviderKind: String, Codable, Sendable { case plex, jellyfin }

protocol MediaServerProvider: AnyObject, Sendable {
    var descriptor: ServerDescriptor { get }      // id, name, kind, version, owner label
    var permissions: ServerPermissions { get }    // what this user may do on this server

    // Required: both platforms can do these.
    var catalog: any CatalogProviding { get }     // libraries, browse, details, children, people, extras, search, collections, photos
    var home: any HomeProviding { get }           // rows, continue watching, dismiss, hide
    var playback: any PlaybackProviding { get }   // direct URL, server stream sessions, sidecars, pre-rolls
    var userData: any UserDataProviding { get }   // progress reports, watched, favourites
    var markers: any MarkerProviding { get }      // skip markers, scrub previews
    var images: any ImageProviding { get }        // ArtworkRef → request
    var playlists: any PlaylistProviding { get }  // CRUD
    var downloads: any DownloadProviding { get }  // original + converted + sidecars + snapshot

    // Optional: nil means the platform or this server does not have it.
    var liveTV: (any LiveTVProviding)? { get }
    var subtitleSearch: (any SubtitleSearchProviding)? { get }
    var rating: (any UserRatingProviding)? { get }        // numeric user rating (Plex only)
}

protocol MediaAccountProvider: AnyObject, Sendable {
    var account: AccountDescriptor { get }        // id, kind, display name
    func servers() async throws -> [ServerCandidateSet]     // discovery + connection candidates
    func probe(_ candidate: ConnectionCandidate) async -> ProbeResult
    var profiles: any ProfileProviding { get }    // list, switch, current
    var preferences: any AccountPreferencesProviding { get } // library order, hidden libraries, language defaults
    var watchlist: (any WatchlistProviding)? { get }
    var seerrAuth: any SeerrAuthProviding { get } // how this account signs in to Seerr (§16)
    func signOut() async
}

protocol ProviderFactory: Sendable {
    var kind: ProviderKind { get }
    func makeSignInFlow() -> any SignInFlow
    func restoreAccount(from record: StoredAccount) -> any MediaAccountProvider
    func makeServerProvider(_ session: ServerSessionSeed) -> any MediaServerProvider
}
```

Rules for the surface:

- Facet methods take and return **domain types only** (§4). A DTO never
  crosses a facet.
- A facet method that exists must work. "Works on some servers" is expressed in
  data (`ServerPermissions`, `FilterCatalog`, `HomeRow.canHide`), not by
  throwing "unsupported".
- `ServerPermissions` is the neutral form of `PlexServer.owned` and Jellyfin's
  `User.Policy`: `canManageHomeRows`, `canInstallSubtitles`, `canDownload`,
  `canPlay`, `canEditPlaylists`, `ownerLabel` ("Shared by X" or nil).
- `ProviderRegistry` is a static table of the two factories. "Swapped at
  runtime" means the pool holds sessions of either kind at the same time; there
  is no global "current provider".

## 4. Domain model

**Decision: neutral domain structs with per-provider DTOs and mappers. The
existing `Plex*` structs become the domain types by rename, then lose their
Plex decoding.** `PlexItem` does not grow a second initialiser (the IPTV
precedent): that keeps Plex field names and units as the app's vocabulary
forever and makes every Jellyfin quirk a special case inside a "Plex" type.

It happens in two mechanical steps so each is verifiable on its own (05,
P0-01 … P0-05): rename the types and fields in place, then move
`init(from: Decoder)` into `Providers/Plex/DTO` behind a mapper. After the
second step a domain type has a memberwise initialiser and no `CodingKeys`
from any server.

### 4.1 Types

| Today | Domain type | Notes |
| --- | --- | --- |
| `PlexItemID` | `MediaItemID { serverID, itemID }` | §6. Codable keys stay `serverID` / `ratingKey` |
| `PlexItem` | `MediaItem` | list/hub/search item |
| `PlexMediaDetails` | `MediaDetails` | item + versions, people, ratings, collections, trailer |
| `PlexMedia` → `PlexMediaPart` → `PlexStream` | `MediaVersion` → `MediaPart` → `MediaStream` | two levels kept; a Jellyfin `MediaSource` maps to one version with one part |
| `PlexMarker` | `Marker { id: String, kind, startMs, endMs, isFinal }` | kinds: `intro, credits, recap, preview, commercial` |
| `PlexMediaType` | `MediaKind` | same raw values (`movie, show, season, episode, clip, …`): they are in deep links and persisted records |
| `PlexLibrary`, `PlexLibraryType` | `Library`, `LibraryKind` | same raw values (stored in `libraryTabOrder`) |
| `PlexHub` | `HomeRow` | §11 |
| `PlexEpisode`, `PlexSeason`, `PlexAdjacentEpisodes` | `Episode`, `Season`, `AdjacentEpisodes` | |
| `PlexContentKey` | `ContentKey` | §6 |
| `PlexGuid` + `guid` | `ExternalIDs { tmdb, imdb, tvdb }` + `nativeGUID: String?` | one accessor for Trakt, Seerr, merge |
| `PlexRole`, `PlexTag` | `Person`, `Tag` | person image is an `ArtworkRef` |
| `PlexRating` + `ratingImage` | `Rating { source, value, scale }` | §9 |
| `PlexPlaylist(Entry)`, `PlexLibraryCollection`, `PlexExtra`, `PlexPhotoItem`, `PlexSearchResult` | `Playlist(Entry)`, `MediaCollection`, `Extra`, `PhotoItem`, `SearchSection` | |
| `PlexLive*` (also fed by IPTV) | `Live*` | third producer is Jellyfin Live TV |
| `PlexUser`, `PlexHomeUser` | `Profile { id, name, avatar, isProtected, isRestricted }` | §7 |
| `PlexServer`, `PlexConnection`, `PlexServerConnection` | `ServerDescriptor`, `ConnectionCandidate`, `ServerSession` | §7 |
| `PlexPin` | stays Plex, inside the Plex sign-in flow | |
| `PlexWatchlistEntry`, `PlexPinnedSource`, `PlexManagedHub` | `WatchlistEntry`, provider-internal, provider-internal | |
| `PlexServiceError` | `MediaServiceError` | Plex Home cases become `profileSecretRequired / Incorrect / Unavailable` |
| `PlexSubtitleSearchResult`, `PlexPlaybackHistoryEntry` | `SubtitleSearchResult`, `PlaybackHistoryEntry` | |

### 4.2 Field vocabulary

| Plex name | Domain name | |
| --- | --- | --- |
| `ratingKey`, `parentRatingKey`, `grandparentRatingKey` | `itemID`, `parentID`, `grandparentID` | strings |
| `librarySectionID` | `libraryID` | |
| `viewOffset`, `viewCount`, `lastViewedAt` | `resumeOffsetMs`, `playCount`, `lastPlayedAt` | |
| `leafCount`, `viewedLeafCount` | `episodeCount`, `watchedEpisodeCount` | |
| `thumb`, `art`, `banner`, `clearLogo`, `parentThumb`, `grandparentThumb`, `grandparentArt` | `artwork: ArtworkSet` | §10 |
| `summary`, `originallyAvailableAt`, `addedAt`, `index`, `parentIndex`, `title`, `parentTitle`, `grandparentTitle`, `editionTitle`, `contentRating`, `duration` | unchanged | generic enough; renaming buys nothing |
| `PlexMedia.id`, `PlexMediaPart.id`, `PlexStream.id` (Int) | `String` | Jellyfin: `MediaSourceId`, same again, `"\(Index)"` |
| `streamType` 1/2/3 | `MediaStream.kind: .video/.audio/.subtitle` | |
| `DOVIPresent`, `DOVIProfile`, `DOVILevel`, `DOVIBLCompatID`, `colorTrc` | `dolbyVision: DolbyVisionInfo?`, `colorTransfer` | resolver reads only these |
| `selected` | `isServerSelected` | Jellyfin: `Index == Default{Audio,Subtitle}StreamIndex` |
| `part.key`, `stream.key` | removed from the domain | URLs come from `PlaybackProviding` |
| `accessible`, `exists` | `isAvailable: Bool?` | nil = provider does not say |

**Decision on units: the domain keeps milliseconds (`Int`) for durations and
offsets and epoch seconds (`Int`) for timestamps.** They are a convention, not
a Plex-ism, 796 call sites already assume them, and changing them is where a
"pure refactor" stops being pure. The Jellyfin mapper converts ticks
(÷ 10 000, `Int64` on the wire) and ISO dates once, at the edge, through one
tolerant date strategy (03 §10.3). Premiere dates are rounded to the nearest
day (02 §6).

**Decision on codec names: the domain uses one canonical lower-case codec
vocabulary** (the one `StreamResolver` already matches: `hevc`, `h264`, `av1`,
`eac3`, `truehd`, `dts`, `pgs`, `srt`, `ass`, `vobsub`, …). Each mapper owns an
alias table into it (`PGSSUB` → `pgs`, `subrip` → `srt`, container `mov` for
`.mp4`). `StreamResolver` never sees a raw server string.

**Decision on stream order: `MediaPart.streams` is ordered as the container
orders them within each kind, and that position, not the id, is what engines
use.** Jellyfin's `Index` shifts when an external subtitle exists (02 §9); the
mapper keeps `Index` as the stream id for server calls and computes the
per-kind position separately.

### 4.3 What stays provider-private

Hub identifiers, `gridKey`, `playlistItemID` semantics, pinned-source keys,
decision codes, DeviceProfile JSON, Plex profile-extra strings, the
`MediaContainer` envelope, Jellyfin `Fields=` lists. If a view model needs one
of these, the facet is missing a verb.

## 5. Keeping features provider-agnostic

### 5.1 Injection

`MediaService` replaces `PlexService` in the SwiftUI environment (54
`@Environment(PlexService.self)` sites) and in the initialisers of
`PlaybackCoordinator`, `DownloadManager`, `OfflinePlaybackSyncManager`,
`SeerrService`, `TraktService`. Nothing else is injected: a view model never
holds a provider, it calls the facade with ids.

### 5.2 Routing

Every domain value that came from a server carries its `serverID` (as today,
stamped by the mapper instead of by `CodingUserInfoKey`). The facade resolves
`pool.session(for: serverID)` and calls that session's provider. An id whose
server is not connected fails exactly as it does today
(`MediaServiceError.serverUnavailable`), and the alternates index still offers
another copy.

### 5.3 Capability-driven UI

| UI element | Shown when |
| --- | --- |
| Live TV tab | any session has `liveTV != nil` and it discovered a lineup (today's rule) |
| Rate, "My Rating" sort | the item's server has `rating != nil` |
| Download Subtitles | `subtitleSearch != nil && permissions.canInstallSubtitles` |
| Hide Row | `row.canHide` |
| Filter and sort menus | built from `FilterCatalog` / `SortCatalog` returned for that library |
| Watchlist row and bookmark | the item's account has `watchlist != nil` |
| Download quality menu | `downloads.qualities(for:)` (both providers return the full preset list, §15) |
| "Shared by X" | `permissions.ownerLabel != nil` |
| Switch User | `profiles.canSwitch` |
| Manage / Delete account links | `account.managementLinks` non-empty (Plex only) |

A view checks a value; it never compares a `ProviderKind`.

### 5.4 Enforcement

`scripts/check_provider_boundary.sh` fails the build check when a file outside
`Providers/` and `Features/Account/SignIn*` contains `\bPlex[A-Z]\w+`,
`\bJellyfin[A-Z]\w+`, `ProviderKind` or `X-Plex`. User-facing copy that names
Plex goes through the provider (`descriptor.productName`), so the app can say
"your Plex server" or "your Jellyfin server" from one string with one
placeholder. It runs in the Phase 0 gate and in every later package's
acceptance.

### 5.5 Testing seams

- `FakeMediaServerProvider` (test target): in-memory facets, so view models,
  the coordinator and the merge layer are tested without a network or a server
  shape.
- **Provider contract tests**: one suite, run once per provider against JSON
  fixtures captured from `plex-demo` and `jellyfin-demo` for the same titles
  (`Knives Out`, `The Office S01E01`, `Dune: Part Two`). It asserts the mapped
  domain values agree where the servers agree (duration within 1 s, same
  stream kinds and codecs, same external ids, same season/episode numbers).
  This is the regression net for "identical experience".

## 6. Identity and merge keys

### 6.1 Item and server ids

**Decision: ids stay raw and opaque; nothing is prefixed.**

- `MediaItemID { serverID: String?, itemID: String }`, storage form
  `"<serverID>|<itemID>"`, Codable keys `serverID` / `ratingKey` (pinned
  playlists and download records were written with those names).
- `serverID` is the Plex `machineIdentifier` or the Jellyfin `ServerId`. Both
  are long hex strings; a collision is not a practical concern, and prefixing
  one side would rewrite every persisted Plex key.
- Jellyfin ids are normalised to 32 lower-case hex characters without dashes
  before they become an `itemID` (the server emits both forms, 03 §10.3).
- Which provider a `serverID` belongs to is recorded once in
  `ServerRegistry` (persisted `[serverID: ServerRecord{kind, accountID, name}]`).
  **A `serverID` with no record is Plex**: that is every id persisted before
  this work.
- Everything that parsed `Int(ratingKey)` or relied on "rating keys are
  numeric" (`PlexServerScoped.swift:41`) is removed in P0-02. Stream, part and
  marker ids become strings in the same package.

### 6.2 Content key

`ContentKey` keeps its four strengths: provider-native global id (`.native`,
today's `.plex`), `.external(provider:namespace:id:)`, `.heuristic`,
`.instance`. Namespaces are `MediaKind` raw values, so a Jellyfin `Series`
with `Tmdb` 2316 and a Plex show with `tmdb://2316` produce the same external
key.

The gap (01 §18): a Plex item with a `plex://` guid keys as `.native`, a
Jellyfin copy keys as `.external`, and they never meet.

**Decision: canonicalisation at merge time, not a change of Plex's primary
key.** Each item exposes `contentKey` (primary, computed exactly as today) and
`contentAliases` (every strong key it carries: native id plus each external
id). Before grouping, the merge layer builds an alias → primary index from the
items whose provider has a native global id, and re-keys only items whose
provider has none:

```text
Plex item      primary .native(plex://X)        aliases [.native(X), tmdb:546554, imdb:tt8946378]
Jellyfin item  primary .external(tmdb:546554)   → re-keyed to .native(plex://X) for this merge
```

- A Plex-only install never re-keys anything: behaviour is byte-identical,
  which is what lets this land in Phase 0 as dead code and switch on with the
  first mixed pool.
- Two Jellyfin servers merge through their shared external key, no index
  needed.
- Editions: the Plex edition suffix stays part of the Plex key; a Jellyfin
  copy has no edition and merges only with the edition-less Plex item.
- Episodes use their own provider ids when the Jellyfin server has them and
  fall back to the `show|sN|eN` heuristic otherwise. A heuristic match merges
  rows but is never an alternate for playback, exactly as today. How often
  Jellyfin episodes lack ids is measured in J-13.

Point lookups ("is tmdb 546554 on this server", used by Seerr availability,
movie copies and watchlist matching) are a facet verb,
`catalog.items(matching: ExternalIDs, kind:)`. Plex answers with
`/library/all?guid=`; Jellyfin searches by title and year and filters on
`ProviderIds`, because `anyProviderIdEquals` is ignored on 12.4 (02 §6).

## 7. Accounts, sessions, profiles

### 7.1 Model

```text
StoredAccount   { id, kind, displayName, credentialRef, deviceID? }     Keychain + UserDefaults
MediaAccountProvider                                                    one per StoredAccount
ServerSession   { descriptor, baseURL, credential, candidate, isVerified, provider }
ProfileScope    { id: String }                                          the app-wide storage scope
```

- A Plex account yields N servers; a Jellyfin account yields exactly one.
- `ServerPool` holds `ServerSession`s of any kind. Priority, enable/disable,
  availability wording, restored-endpoint validation and the connection race
  are generic and stay in the pool. What a provider contributes is the
  candidate list and the probe.
- **Connection candidates for Jellyfin: the URL the user typed plus the
  server's `LocalAddress` from `/System/Info/Public`, raced by the existing
  `ConnectionSelector`, identity-gated on `Id`.** No second URL field (02's
  proposal): that is a setting, and the server already tells us its LAN
  address. Connection Diagnostics shows the same two-row table it shows for a
  Plex server with two candidates.
- **No LAN discovery (UDP 7359).** Broadcast needs the multicast networking
  entitlement on iOS and a local-network prompt, for a convenience Plex users
  never needed. The URL field accepts a bare host and tries `https://host`,
  `http://host:8096`, `https://host:8920` in that order.

### 7.2 Sign-in

`SignInFlow` is the one provider-specific UI surface. `SignInView` becomes a
host: a provider picker (two rows: Plex, Jellyfin) and the chosen flow's
steps. Every flow ends in the same value, a `StoredAccount` handed to
`AccountStore`.

| | Plex | Jellyfin |
| --- | --- | --- |
| Steps | browser hand-off (iOS/macOS), link code + QR (tvOS) | server address → Quick Connect code (default when enabled, the only option shown first on tvOS) or username + password |
| Polling | `checkPin` | `/QuickConnect/Connect?secret=` |
| Result | account token | `{AccessToken, ServerId, User}` |
| After sign-in | — | `POST /Sessions/Capabilities/Full` once |

The tvOS code screen is shared between the two; only the instruction line
comes from the flow.

**Jellyfin `DeviceId`: a random UUID per `StoredAccount`, generated when the
sign-in attempt starts and stored with the account.** One `DeviceId` holds one
token (03 §10.2), so two users on one Apple TV must not share it; a random id
per account is the simplest thing that guarantees that and needs no user id
before the login call. Header values are percent-encoded; the only credential
carriers are the `Authorization: MediaBrowser …` header and `ApiKey=` on URLs
handed to a player.

### 7.3 Profiles and the storage scope

`activeProfileID` scopes downloads, IPTV sources, Trakt, Seerr, pinned
playlists and remembered tracks. It must not change for anyone who has data.

**Decision: the profile scope belongs to the primary account; other accounts
are linked under it.**

- The **primary account** is the one the user signed in with on the sign-in
  screen. Its active profile defines `ProfileScope.id`.
  - Plex primary: exactly today's value (`PlexHomeUser.stableProfileID`,
    user uuid, or `PlexPrimaryProfileID`). Unchanged for existing users.
  - Jellyfin primary: `"jellyfin-<serverID>-<userID>"`.
- **Linked accounts** are added later from Settings › Servers ("Add Server",
  one row at the end of the list, opens the same sign-in host). They are
  stored per profile scope, like IPTV sources are, so switching profile also
  switches which extra servers are present.
- **Switch User** is the same picker for both providers, fed by
  `ProfileProviding`:
  - Plex: Home members, PIN prompt when `isProtected`.
  - Jellyfin: the accounts already saved for the primary server, plus
    `/Users/Public` names when the server lists any. Choosing a user that is
    not saved yet asks for the password in the slot where Plex asks for a PIN
    (or offers Quick Connect). Each saved user keeps its own token and
    `DeviceId`; switching never logs the other out.

`ContentView` gates on a neutral `SessionState`
(`signedOut | bootstrapping | needsProfile | ready`) instead of
`isAuthenticated` / `homeBootstrapCompleted` / `needsHomeUserSelection`.

## 8. Request core and transport security

Each provider owns its HTTP client; nothing above builds a URL.

| | `PlexClient` | `JellyfinClient` |
| --- | --- | --- |
| Identity | `X-Plex-*` headers | `Authorization: MediaBrowser Client, Device, DeviceId, Version, Token` |
| Envelope | `MediaContainer` | bare object, `{Items, TotalRecordCount}`, or bare array |
| User scope | implied by token | `userId=` on every query |
| Errors | status codes | status codes **and** result assertions: unknown parameters are ignored with `200` (02 §0), so the client validates the shape it asked for |

`PlexTransportSecurity` generalises to `CredentialTransportPolicy` (one per
provider): which query items and headers are secrets (`X-Plex-Token`;
`ApiKey`), whether a URL may carry one over plain HTTP, redirect rules, and
log redaction. The engines call the policy attached to the `PlaybackSource`
instead of naming Plex, and the "secure connection is required to send the
Plex token" message takes the product name from the descriptor.

The four `URLSession`s (default, slow query, probe, bootstrap) move to a
shared `ProviderTransport` both clients use, so timeouts and the delegate
stay identical.

Self-healing stays in the pool: a client reports a transport failure through
`SessionRecovering`, the pool re-runs the account provider's candidates with
the existing 30 s cooldown.

## 9. Catalog

One facet, `CatalogProviding`. The verbs are today's `PlexService+Library`,
`+Collections`, `+People`, `+Extras`, `+Photos` and search, with neutral
arguments.

| Verb | Plex | Jellyfin | Decision |
| --- | --- | --- | --- |
| `libraries()` | `/library/sections` | `/UserViews` | a `homevideos` view is classified once by two `limit=0` counts (photos vs videos) and cached; a mixed folder appears as both |
| `items(library, sort, filters, page)` | `/all` | `/Items?parentId&recursive` | `LibrarySort` and `LibraryFilter` are neutral values; each provider maps them |
| `sortCatalog(library)`, `filterCatalog(library)` | fixed list / `/filters` | fixed list / `/Items/Filters`, `/Genres`, `/Studios`, `/Persons` | menus render what the catalog returns (§21 for which entries exist) |
| `letterIndex(library, filters)` | `/firstCharacter` | 26 parallel `nameLessThan={letter}&limit=0` counts | **exact parity**: the differences of consecutive counts are the per-letter sizes, so the provider returns the same `[{letter, size}]` table Plex does and `LibraryLetterIndex` is untouched. Cached per library and filter set, invalidated by the library's item count |
| `details(id)` | `/library/metadata/{id}` | `/Items/{id}?userId` | versions, people, ratings, collections, trailer in one value |
| `seasons`, `episodes`, `allEpisodes`, `adjacentEpisodes` | children / allLeaves | `/Shows/{id}/Seasons`, `/Episodes` | adjacency stays client-side over the episode list, same code for both |
| `collections(library, page)`, `collectionItems(id, sort)`, `collections(containing: item)` | section collections, `Collection` tags | BoxSets | BoxSets are server-wide: the provider filters them to the library by children. "Part of" needs a back-reference Jellyfin lacks: the provider keeps a lazily built, disk-cached BoxSet membership index per server (one list request, ids-only children requests in the background) |
| `person(id)`, `personMedia(id)` | `/library/people` | `/Items/{personId}`, `/Items?personIds=` | |
| `extras(item)`, `trailer(item)` | `/extras`, `primaryExtraKey` | `/SpecialFeatures`, `/LocalTrailers`, `RemoteTrailers` | `Trailer` is `.playable(MediaItemID)` or `.external(URL)`; §21 row 7 |
| `search(query)` | `/hubs/search` | one `/Items?searchTerm` request per kind in parallel, plus `/Persons` | both return `[SearchSection(kind, items)]`; `SearchMerge` unchanged |
| `photoPage(library, mode, parent, page)`, `photoDisplay(item, size)` | `type=14 / 13,12`, clustering | `PhotoAlbum`/`Folder`/`Photo` | the timeline is one flat newest-first list on both, no grouping (see below); `DateCreated` is the fallback date |
| `items(matching: ExternalIDs, kind)` | `/library/all?guid=` | search + `ProviderIds` check | §6.2 |
| `playbackHistory(limit)` | `/status/sessions/history/all` | `/Items?sortBy=DatePlayed&isPlayed=true` | feeds the recommendation engines unchanged |

**Phase 0 state (P0-07).** `CatalogProviding` / `UserRatingProviding` are
filled in and `PlexCatalog` / `PlexUserRating` carry today's requests unchanged.
Deviations from the table: search is `searchGroups(query) -> [HomeRow]` (the
server's per-kind groups) so the facade's hidden-library filter keeps working on
rows before they become `SearchSection`s; the letter table is
`[LibraryLetterCount]`; channel collections are `channelCollections(libraryID)`.
**Decision (2026-11-28): the photo timeline needs no client grouping.** Plex's `clusterZoomLevel=1` only widens the
type filter beyond loose root photos, and the grid has always shown one flat
newest-first list, so there is no server grouping to replace (a Jellyfin
`photoPage(.timeline)` returns the same flat list). `trailer`,
`items(matching:)` and `playbackHistory` are not declared yet. Callers outside
the catalog's files that still pass Plex sort strings or filter parameters go
through `PlexCatalog.raw…` routes (listed in `docs/data-and-plex.md`).

**Ratings.** `Rating { source: .critic | .audience | .community | .user, style, value, scale }`
where `style` carries the presentation Plex's `ratingImage` implies
(`.rottenTomatoesCritic`, `.rottenTomatoesAudience`, `.imdb`, `.tmdb`,
`.neutral`). The Plex mapper derives `style` from the `ratingImage` URI as
`DetailRatings` does today. **The Jellyfin mapper emits `CommunityRating` as
`.community / .neutral` (a plain star, 0–10) and `CriticRating` as
`.critic / .neutral` (percentage with a neutral critic glyph).** Jellyfin does
not say where either number came from, and guessing a logo would put a
trademark on an unverified source.

**Content rating** is whatever the server stores (`CH-12`); the plain
age-rating display already handles arbitrary strings.

**Versions.** `MediaVersion.label` is `editionTitle`-independent: Plex builds
it as today; Jellyfin uses `MediaSource.Name` with the item title and year
stripped ("1080p", "Extended"). Preferred Version picks by resolution from the
video stream for both.

## 10. Images

**Decision: models carry `ArtworkRef`, an opaque locator only its provider
can read.**

```swift
struct ArtworkRef: Hashable, Codable, Sendable {
    let serverID: String?
    let locator: String        // Plex: the server-relative path. Jellyfin: "jf:<itemID>:<type>:<index>:<tag>"
}

struct ArtworkSet: Sendable {
    var poster, backdrop, logo, banner, landscape: ArtworkRef?
    var parentPoster, grandparentPoster, grandparentBackdrop, grandparentLogo: ArtworkRef?
}

protocol ImageProviding {     // as built in P0-08
    func url(for ref: ArtworkRef, size: ImageSize, session: ServerSession?) -> URL?
    func authenticatedRequest(for url: URL, session: ServerSession) -> URLRequest
}
```

- Providers hold no endpoint or token, so the facade passes the session it
  resolved for `ref.serverID` (nil when not connected: absolute-URL artwork
  still resolves). Fetching, the image cache, the 401 refresh and matching a
  URL back to its server stay in `MediaService+Images`. A ref-based
  `data(for:size:)` for offline artwork lands with its callers (downloads,
  Top Shelf), which still fetch by URL.

- For Plex the locator **is** today's path string, so persisted `thumbPath` /
  `artPath` values in `downloads.json` and the Top Shelf snapshot are valid
  locators with no rewrite.
- The Jellyfin locator carries the image tag, which makes the URL a correct,
  immutable cache key (03 §10.4). Parent and series artwork resolve from
  `SeriesPrimaryImageTag`, `ParentBackdropItemId`, `ParentLogoItemId` in the
  mapper, so `ArtworkSet` is filled the same way for both.
- `ImageSize { width, height, mode: .fit | .fill }` maps to Plex
  `width/height/minSize/upscale` and Jellyfin `maxWidth` or
  `fillWidth/fillHeight`.
- The fallback choices (`preferredPosterPath`, `fallbackPosterPath`,
  `preferredLandscapePath`) become methods on `ArtworkSet` and stay shared.
  Jellyfin's `Thumb` image has the title baked in, so the Jellyfin mapper puts
  the backdrop, not `Thumb`, in `landscape`.
- `imageServerConnection(for: URL)` (matching a URL back to a server by host)
  disappears once every fetch goes by ref: the ref already names its server.
  It stays while `DuskAsyncImage`, downloads and Top Shelf fetch by URL.
- **No BlurHash.** Plex has no equivalent the app uses today, so adding
  placeholders for one provider would be a visible difference.
- IPTV images keep using `ArtworkRef(serverID: IPTVImages.serverID, …)`
  through a tiny third `ImageProviding`.

## 11. Home rows

**Decision: Home renders `[HomeRow]`; every provider produces rows with a
typed `kind`, and the string heuristics move into the Plex mapper.**

```swift
struct HomeRow: Identifiable, Sendable {
    let id: String                  // stable per server
    let kind: Kind                  // .continueWatching, .nextUp, .recentlyAdded, .recentlyReleased,
                                    // .recentlyPlayed, .topRated, .genre(String), .custom
    let mergeKey: String            // same row on another server
    let library: LibraryRef?
    let title: String
    let items: [MediaItem]
    let more: RowContinuation?      // "Show All", provider-opaque
    let canHide: Bool
}
```

- `HomeHubFilter`, `HomeHubArrangement`, `HubMerge.mergeKey`,
  `isRecentlyAddedHub` stop parsing `hubIdentifier` / titles and read `kind`,
  `library` and `mergeKey`. The Plex mapper assigns those from the same
  strings the heuristics read today (P0-12 moves the logic verbatim and pins
  it with the existing `HomeHubArrangementTests` plus captured `/hubs`
  fixtures).
- Jellyfin composes rows in the provider:

| Row | Source | Notes |
| --- | --- | --- |
| Continue Watching | `/UserItems/Resume` ∪ `/Shows/NextUp`, ordered by last played, one entry per show | this is what Plex's `home.continue` already is, so `ContinueWatchingMerge` treats both alike |
| Recently Added in {library} | `/Items/Latest?parentId=` per view not in `LatestItemsExcludes` | returns Season/Series containers; Dusk already folds those |
| Recently Released in {library} | `/Items?sortBy=PremiereDate` | library Recommended and Home |
| Recently Watched, Top Rated | `/Items?sortBy=DatePlayed`, `sortBy=CommunityRating` | library Recommended tab, to match the rows Plex's `/hubs/sections/{id}` gives |
| Show All | `/Items?sortBy=DateCreated&sortOrder=Descending` paging | `/Items/Latest` cannot page |

- Dusk's own recommendation shelves (`HomeRecommendationEngine`,
  `LibraryRecommendationEngine`) run unchanged on `playbackHistory`, genres and
  `lastPlayedAt`.
- **Dismiss from Continue Watching** is one verb,
  `home.dismissFromContinueWatching(id)`. Plex: `removeFromContinueWatching`.
  Jellyfin has no "hide but keep position": a resumable item gets its position
  cleared (`PlaybackPositionTicks: 0`), a Next Up entry is remembered in a
  small per-profile store **inside the Jellyfin provider** until a different
  episode of that show becomes next. The UI is the same action with the same
  result on screen; the resume point is lost on Jellyfin, which is the
  platform's limit.
- **Hide Row**: `home.setHidden(row, true)` and `home.hiddenRows()`. Plex
  writes `promotedToOwnHome` (owner only). Jellyfin writes
  `LatestItemsExcludes` for Recently Added rows (any user with preference
  access); other Jellyfin rows have `canHide == false`.
- `HomeFirstPaintGate` and `HomeContinueWatchingMemory` are keyed by
  `serverID` and need no change.

## 12. Playback

### 12.1 The split

```text
shared (Dusk)                                  provider
──────────────────────────────────────────    ──────────────────────────────────────────
StreamResolver, MediaVersion choice            MediaDetails with versions/streams (§4)
delivery ladder (PlaybackCoordinator+Session)  directPlayURL(version, part)
intent: copy / convert audio / quality / …     openServerStream(request) → ServerStream
accept-or-fall-through on StreamDecisions      confirm(stream) → StreamDecisions
engines, RemuxHLSLoader, DV7 proxy             traits: what the HLS output needs
90 % rule, Up Next, queue, Trakt               report(event), setWatched
track choice policy                            prepareTrackSelection, sidecarURL
```

```swift
protocol PlaybackProviding {
    var traits: PlaybackTraits { get }
    func directPlayURL(for part: MediaPart, of item: MediaItemID) -> URL?
    func checkAccess(to url: URL) async -> PlaybackAccess          // Plex: remote-refusal probe. Jellyfin: .allowed
    func openServerStream(_ request: ServerStreamRequest) async throws -> ServerStream
    func confirm(_ stream: ServerStream) async -> StreamDecisions?  // post-start proof, nil = already proven
    func keepAlive(_ stream: ServerStream) async
    func close(_ stream: ServerStream) async
    func prepareTrackSelection(_ selection: TrackSelection, for item: MediaItemID) async -> TrackSelectionRestore?
    func sidecarSubtitle(for stream: MediaStream, of item: MediaItemID, format: SubtitleFormat) -> URL?
    func prerolls(before item: MediaItemID) async -> [MediaItem]
}

struct ServerStreamRequest {
    let item: MediaItemID; let version: MediaVersion; let part: MediaPart
    let intent: StreamIntent
    let audioStreamID: String?
    let subtitle: SubtitleRequest          // .none | .stream(id, delivery: .inManifest | .external | .burnIn)
    let startOffsetMs: Int?
    let device: DeviceVideoCapabilities    // HDR modes, DV profiles this attempt may show, AV1, channels
}

enum StreamIntent {
    case losslessRemux                     // video + audio copied (Atmos / HDR / DV / DV7 input)
    case convertedAudioRemux(target: AudioTarget)   // video copied, audio converted (TrueHD → E-AC-3 etc.)
    case videoCopyFallback                 // today's directStreamFallback
    case quality(PlaybackQualityPreset)    // manual only
    case av1Fallback
    case airPlay
    case live(LiveTuneContext)
}

struct ServerStream {
    let url: URL; let sessionID: String; let playMethod: PlayMethod
    let decisions: StreamDecisions          // video: .copy/.transcode, audio: .copy/.convert(codec, channels), subtitle delivery, container
    let proof: Proof                        // .proven | .predicted
    let credentialPolicy: CredentialTransportPolicy
}
```

`TranscodeDeliveryMode` becomes `StreamIntent`; `isLosslessRemux` /
`isConvertedAudioRemux` become questions on `StreamDecisions`; the blockers
(`spatialAudioRemuxBlocker`, `hdrVideoRemuxBlocker`, …) stay in the
coordinator because they are Dusk's rules over neutral stream metadata.

### 12.2 How each provider implements a server stream

| | Plex | Jellyfin |
| --- | --- | --- |
| Mechanism | `decision` + `start.m3u8`, profile-extra string | `POST /Items/{id}/PlaybackInfo` with a `DeviceProfile` built **for this request** (03 §5.4) |
| Lossless remux | `directStream=1`, `directStreamAudio=1`, copy targets | no direct-play entry; one HLS/`mp4` transcoding profile whose video codec is exactly the source's and whose audio codec is exactly the chosen track's; range types = `request.device` |
| Converted audio | `directStreamAudio=0` targets | audio codec list `eac3,ac3,aac` (first wins) |
| Quality | `maxVideoBitrate`, `videoResolution` | `MaxStreamingBitrate` + a size condition |
| Track choice | PUT the part selection first, restore after (`prepareTrackSelection`) | `MediaSourceId` + `AudioStreamIndex` + `SubtitleStreamIndex` in every request, `-1` for off; `prepareTrackSelection` returns nil |
| Proof of copy | per-stream `decision` in the response → `.proven` | profile makes a re-encode impossible by construction → `.predicted`; `confirm` reads `GET /Sessions?deviceId=` → `TranscodingInfo.IsVideoDirect / IsAudioDirect` |
| Keep alive / close | `/ping`, `/stop` | `/Sessions/Playing/Ping`, `DELETE /Videos/ActiveEncodings` |

**Decision: always send `MediaSourceId` and both stream indexes to Jellyfin.**
Leaving them open lets the server swap the audio track or burn in a default
PGS track (02 §10), both of which break "the decision engine is Dusk's".

**Decision: the coordinator calls `confirm` once, when the engine reports the
first frame, for any stream whose proof is `.predicted`; a mismatch closes the
stream and falls through the ladder on the existing fallback path.** For Plex
`confirm` returns nil and costs nothing.

### 12.3 HLS output: one loader, provider traits

```swift
struct PlaybackTraits {
    let remuxNeedsAtmosSignalingPatch: Bool      // Plex true (13-byte dec3), Jellyfin false
    let remuxNeedsDolbyVisionBoxes: Bool         // Plex true (no dvcC/dvvC), Jellyfin false
    let remuxNeedsVariantFilter: Bool            // Jellyfin true (master playlist trap), Plex false
    let serverAppliesWatchedThreshold: Bool      // Jellyfin true
    let persistsTrackChoiceFromReports: Bool     // Jellyfin true
}
```

**Decision: every HDR/DV remux, from either provider, loads through
`RemuxHLSLoader`, and the `#EXT-X-STREAM-INF` line is always written from
Dusk's own decision.** The loader already rewrites that line from a
`DolbyVisionConfiguration`; for Jellyfin it additionally keeps only the first
(copy) variant and drops the tone-mapped H.264 one, which removes the
master-playlist trap (03 §5.2) and the unreliable DV claim (03 §5.3) in one
place. The init-segment patches run only when the traits ask for them.
Loading `main.m3u8` directly (03's first option) is rejected because it throws
away `SUPPLEMENTAL-CODECS` and `VIDEO-RANGE`, and whether AVPlayer engages
Dolby Vision 8.1 from the `dvvC` box alone was not measured.

Dolby Vision per provider, same ladder:

| Case | Plex | Jellyfin |
| --- | --- | --- |
| DV 5, 8.1, 8.4 | remux + loader adds boxes and `CODECS` | claim the DV range types; server writes the boxes; loader only pins the variant line |
| HDR10 base fallback | second remux attempt without DV signalling | same request without DV range types (server strips DV, still copies) |
| DV 7 → 8.1 | remux → `DolbyVision7HLSProxy` | claim `DOVIWithEL` only when the conversion will run → same proxy (needs `dvcC`, which Jellyfin keeps) |
| Atmos | loader patches `dec3` | nothing to do |

`DolbyVisionConfiguration.init?(stream:)` takes a `MediaStream`.

### 12.4 Subtitles

One policy for both providers, chosen by the coordinator from
`SubtitleRequest`:

- VLCKit direct play: embedded tracks need nothing; sidecars come from
  `sidecarSubtitle(for:of:format:)` and are added as today.
- AVPlayer, text track: `.external` WebVTT rendered by Dusk's overlay
  (instant switching, no new server session). Plex continues to use its
  in-manifest `segments-subs` path where it is used today; the request type
  carries both so neither is a special case.
- AVPlayer, bitmap track: the file goes to VLCKit, which is what
  `StreamResolver` already decides. Burn-in only happens for a manual quality
  transcode or AirPlay.
- ASS/SSA with fonts on Jellyfin: VLCKit direct play reads attachments from
  the container, so nothing extra is needed (to be confirmed on the test file
  added in T-0).

### 12.5 Reporting and watched state

```swift
@MainActor protocol UserDataProviding {
    func report(_ event: PlaybackReport) async throws       // started / progress / paused / buffering / stopped; throws for offline replay
    func setWatched(_ watched: Bool, item: MediaItemID, at date: Date?) async throws
    // Planned, not declared yet (see below):
    // func setResumeOffset(_ ms: Int, item: MediaItemID, at date: Date?) async throws
    // func setFavourite(_ on: Bool, item: MediaItemID) async throws
}
```

`setResumeOffset` and `setFavourite` are added by the Jellyfin packages that
first use them (P0-10 declared only what a Plex flow calls).

`PlaybackReport` carries item, session id (nil for an offline replay), the Plex
Live TV session path, version id, state, position, duration, play method and
the chosen stream ids. Plex maps it to
`/:/timeline`; Jellyfin maps `started → /Sessions/Playing`, progress →
`/Playing/Progress`, `stopped → /Playing/Stopped`, in ticks.

**Decision: the 90 % rule stays Dusk's trigger for Up Next, Trakt and the
optimistic UI on both providers; the explicit watched write is skipped when
`traits.serverAppliesWatchedThreshold` is set.** Jellyfin marks the item played
from the Stopped report and a second call double-counts `PlayCount` (02 §8).
Resume points below the server's minimum are dropped by Jellyfin; Dusk accepts
the server's answer on both platforms rather than faking state.

`setWatchedAcrossServers` keeps fanning out by `ContentKey` (§6.2), now across
providers.

### 12.6 Markers and scrub previews

`MarkerProviding.markers(for: MediaDetails)` returns `[Marker]`. Plex reads
them from the details payload it already fetched (`includeMarkers=1`), so the
call is synchronous and makes no request; Jellyfin calls `/MediaSegments/{id}`
in parallel with the playback request, so J-05 either puts the segments on
`MediaDetails.markers` when it loads details or makes this call async. The
player still builds its view model from `MediaDetails.markers` in
`PlayerSessionView.init`, where no service is reachable. `Intro → .intro`,
`Outro → .credits` (`isFinal` when it ends at the runtime); `Recap`, `Preview`
and `Commercial` are mapped into the domain and **not shown**, because Plex
has no equivalent and a button that exists on one server only is a visible
difference. The synthesised credits estimate keeps its sentinel id
(`Marker.estimatedCreditsID`, today `"-1"`; any value no server uses works).
The three P0-11 changes to this section (`scrubPreview(forPartID:)`, the
`"-1"` sentinel, no generated-preview fallback in the tree) were confirmed on
2026-11-28.

`MarkerProviding.scrubPreview(forPartID:)` returns a `ScrubPreviewSource` with
one method, `frame(at:) async -> CGImage?`. It is keyed on the playing part,
not the version: a multi-part item plays one part at a time. Plex's
implementation (`PlexMarkers`) fetches and parses the part's BIF file; its
frame set is `PlexScrubPreviewSource`, which the player controls still read
synchronously (moving them to the protocol is a view change after Phase 0).
Jellyfin's fetches trickplay sheets lazily and crops the tile (03 §10.6). A
generated-preview fallback for servers with none is not in the tree.

### 12.7 Pre-rolls, AirPlay, SharePlay

- `prerolls(before:)`: Plex `playQueues` with `extrasPrefixCount=0`;
  Jellyfin `/Items/{id}/Intros`. Empty is the normal answer.
- AirPlay is `StreamIntent.airPlay` (H.264/AAC HLS, burned subtitles) on both.
- SharePlay: `DuskWatchTogetherActivity` keeps its `serverIdentifier` /
  `ratingKey` Codable keys (an older build must still decode it); the activity
  identifier becomes `dusk://<serverID>/<itemID>` for Jellyfin items and stays
  `plex://…` for Plex items.

## 13. Track selection and language defaults

- `ShowTrackPreferences` is already semantic (no stream ids) and is untouched.
- "Explicit choices on episodes are also written to the server" is
  `prepareTrackSelection` for Plex and the playback report for Jellyfin
  (`RememberAudioSelections` / `RememberSubtitleSelections` do the rest).
- The server's own pick (`isServerSelected`) stays the tie-break **after**
  Dusk's Off/Auto/Always rules for both providers.
- Account language defaults come from
  `AccountPreferencesProviding.languageDefaults()`: plex.tv `profile` or
  Jellyfin `User.Configuration`. With several accounts linked, the primary
  account's values apply. The UserDefaults keys keep their strings
  (`plexAccountAudioLanguage`, …); the Swift properties are renamed.
- Subtitle search is the optional `SubtitleSearchProviding` facet
  (`search(item, language, hearingImpaired, forced)`, `install(result)`),
  followed by the same refetch-and-mount step on both.

## 14. Live TV

`LiveTVProviding` on the server provider; IPTV stays a separate producer of
the same `Live*` models.

As built in P0-14 (one value per server, `@MainActor` methods; `LiveTVProvider`
is the neutral name of a server's Live TV source, the DVR):

```swift
protocol LiveTVProviding {
    func source() async throws -> LiveTVProvider?             // nil: no DVR on this server
    func channels(of: LiveTVProvider) async throws -> [LiveChannel]
    func devices(of: LiveTVProvider) async throws -> [LiveTVDevice]   // empty: one guide section
    func onNow(source:, channels:) async throws -> LiveTVLineup
    func airings(source:, window: LiveTVGuideWindow) async throws -> [LiveProgram]
    func guide(source:, channels:, days: [Date]) async throws -> LiveTVLineup  // per-channel fallback
    func lineup(source:, channels:, programs:) -> LiveTVLineup        // files airings under channels
    func recording(for: LiveProgram, source:) async throws -> MediaItem?
    func tune(_: LiveChannel, source:, allowsDirectPlay: Bool) async throws -> LiveTuneResult
}
```

- Discovery across servers (`discoverLiveTVProvider`, `LiveTVDiscovery`) and
  the guide's refresh policy stay Dusk's (facade, `LiveTVViewModel`). The
  view model still decides when to fall back to `guide(days:)`: a Plex quirk
  (a grid that ignores the time range) a Jellyfin facet can answer with
  `airings` per day.
- No `closeTune`: Dusk closes nothing for a live session today (the stream's
  close is the playback facet's). Jellyfin's `/LiveStreams/Close` adds it.
- Plex keeps its provider discovery, `gridKey`, channel matcher and tune
  session inside `Providers/Plex`. `PlexLiveChannelMatcher` is Plex-private
  (`Providers/Plex/PlexLiveChannelMatcher.swift`; features file airings through
  `MediaService.liveTVLineup`). The device sections are neutral
  (`LiveTVDevice`, `LiveTVLineup.groupedByDevice`); only fetching and mapping
  `/livetv/dvrs/{id}` is Plex's, and the lineup simply has one section when a
  provider reports no devices.
- Still Plex-shaped, left for J-09: `LiveTVProvider`'s `dvrID`, `gridKey`,
  `channelsKey` and `watchNowKey`, and `LiveChannel.gridKey`/`tuneIdentifier`
  (IPTV and tests build these memberwise).
- Jellyfin: `/LiveTv/Channels`, `POST /LiveTv/Programs`,
  `/LiveTv/Programs/Recommended?IsAiring=true`, tune = `PlaybackInfo` with
  `AutoOpenLiveStream`, close = `/LiveStreams/Close`, recordings by
  `ChannelId` + start.
- `PlaybackSource.liveTVContext` is the neutral `LivePlaybackContext`; its
  `sessionPath` (the key progress reports carry) comes from the tune
  (`LiveTuneResult.reportKey`, Plex `/livetv/sessions/{id}`), nil for IPTV.
- The `isIPTV` branches that kept IPTV away from Plex calls are gone: an IPTV
  source's `serverID` is no server the pool knows, so `MediaService.liveTV(for:)`
  returns no facet. Left: `channel.iptv` (it carries the IPTV stream) and the
  timeline guard in `PlaybackCoordinator+Timeline`, which P0-10 kept on
  purpose: an IPTV session has no server id, and without the guard its
  reports would route to the primary Plex server.

**Decision: Live TV ships for Jellyfin** (02 proposed leaving it out). It is
unverified only because the demo server has no tuner; T-0 adds an M3U tuner
fed by `scripts/iptv_test_source.py`, which makes it testable.

## 15. Downloads and offline

### 15.1 Facet

```swift
protocol DownloadProviding {
    func qualities(for item: MediaItemID) -> [DownloadQuality]
    func originalFile(for part: MediaPart, of item: MediaItemID) -> DownloadRequest          // url + headers
    func prepareConverted(item: MediaItemID, version: MediaVersion, quality: DownloadQuality) async throws -> ConvertedDownload
    func sidecars(for item: MediaItemID, version: MediaVersion) -> [SidecarDownload]
    func snapshot(_ key: MetadataSnapshotKey) async throws -> Data                           // raw provider payload
    func decodeSnapshot<T>(_ data: Data, as: T.Type) throws -> T                            // provider decodes its own
}
```

`ConvertedDownload` is either `.file(DownloadRequest)` (Plex: the download
queue has prepared a file) or `.segments(HLSSegmentPlan)`.

**As built in Phase 0 (P0-15).** The source differs from the sketch above
where behaviour neutrality required it:

- Converted downloads are a resumable job rather than one `prepareConverted`
  call: `createConversionQueue`, `addConversionJob`, `conversionJob(s)`,
  `preparedConversion` and `removeConversionJob`. Today's flow persists the
  client identifier, the queue id and the job id between steps, and it gates
  hand-off on the transfer cap, so the state machine stays in
  `DownloadManager`.
- Each step is sent through a `DownloadConversionTransport`, implemented by
  the facade. It checks the owning profile and the server state around every
  await.
- `ConvertedDownload` is a struct (request, media, expected bytes). The
  `.segments` case arrives with J-08b.
- Snapshots have no session, so `snapshot`/`decodeSnapshot` became a
  sessionless `MetadataSnapshotFormat` (`storageName`, `fetchRequest`, typed
  decodes), reached by `ProviderKind` through the factory. The facade does
  the fetch.
- `MetadataSnapshotKey` has `.details` and `.children` only; nothing reads
  `allLeaves`. The envelope and `decodeSnapshot` of `convertedMediaData` come
  with J-08a. Until then, Plex payloads are stored bare.

### 15.2 Converted quality on Jellyfin

**Decision: converted downloads ship for Jellyfin, as a segment-wise download
of the HLS fMP4 transcode, concatenated into one MP4.** 02 proposed
Original-only because the progressive transcode stream cannot resume. The HLS
playlist Jellyfin returns is complete from the first request (03 §5.1.9), so
the plan is known up front: init segment plus N media segments. Each segment
is an ordinary resumable transfer, progress is segments done over N, and
`init + segments` concatenated byte-wise is a valid fragmented MP4 that both
engines play. Same presets, same menu, same badge as Plex.

This is unmeasured and is the riskiest decision in this document: background
`URLSession` behaviour with hundreds of small tasks, and the server restarting
ffmpeg when a later segment is requested after an idle gap. J-08b starts with
a spike that must show a 2 h film completing across an app suspension. **If
the spike fails, the fallback is the progressive `stream.mp4` transfer that
restarts from zero when interrupted**; the presets still ship either way.

### 15.3 Storage format and migration

**Decision: the offline cache keeps storing raw provider payloads, and the
record says which provider wrote it.** A neutral snapshot format was
considered and rejected: it creates a second persisted schema to version, and
it would require converting every existing Plex blob or reading two formats
forever anyway.

| Stored thing | Today | After |
| --- | --- | --- |
| `downloads.json` → `DownloadedMediaRecord` | Plex-named fields | same Codable keys; new optional `provider` (absent = `plex`); `type` raw values unchanged; `thumbPath` / `artPath` hold `ArtworkRef` locators; `mediaID` / `partID` decode from Int or String |
| `convertedMediaData` | JSON `PlexMedia` | provider payload, decoded by `decodeSnapshot` of the record's provider |
| `externalSubtitlePaths: [streamID: path]` | Int keys | String keys; the decoder accepts both |
| `plexDownloadQueueID`, `plexDownloadItemID` | fields | same keys, read only by the Plex provider |
| `globalKey` | `"{profileID}:{serverID}:{ratingKey}"` | unchanged string |
| `Metadata/[Profiles/{p}/]{serverID}/{hash}.json` | raw PMS response, hash of the PMS path | `MetadataSnapshotKey` (`.details(id)`, `.children(id)`, `.allLeaves(id)`); **its Plex string form is exactly today's endpoint path**, so existing files are found under the same hash. Jellyfin payloads are written in an envelope `{"provider":"jellyfin","schema":1,"payload":…}`; a bare payload is Plex |
| `SmartDownloadRule` | `serverID`, `showRatingKey` | same keys |
| `playback-sync.json` → `OfflinePlaybackSyncAction` | `plexState` etc. | same keys; replay calls `userData.report` / `setWatched(at:)` (Plex replays progress as a timeline report; `setResumeOffset` joins if Jellyfin needs it) |

Offline browsing asks `DownloadManager` for the record's provider kind (from
the record, not from a live session) and decodes through that provider's
static decoder, so it works signed out and offline.

Jellyfin specifics: original = `/Items/{id}/Download`, gated by
`permissions.canDownload`; sidecars are `…/Subtitles/{index}/0/Stream.srt`
for every text track.

## 16. Seerr and Trakt

**Seerr.** `SeerrService` stops reading `activeAccountToken` and asks the
binding account's `SeerrAuthProviding` (built since P0-18; the facade's
`MediaService.seerrAuth` until the account layer holds the credential). The
facet describes the sign-in and `SeerrService` sends it, because every Seerr
request needs that service's cookies, XSRF token and certificate pins:
`accepts(SeerrPublicSettings)` (checked before anything is sent) and
`login() -> SeerrLogin?` (path + JSON body, nil without a credential), re-sent
as is on a 401:

- Plex account: `POST api/v1/auth/plex` with the token, as today. Requires a
  Plex-backed Seerr.
- Jellyfin account: `POST api/v1/auth/jellyfin` with username and password.
  Requires a Jellyfin-backed Seerr (`mediaServerType` 2). The Seerr connect
  sheet shows a password field **only when the strategy says it needs a
  secret**; the username is prefilled.
- **Decision: the password entered there is kept in the Keychain entry of
  that Seerr session (this device only) and used for silent re-authentication
  on a 401**, which is what the Plex path does with its token. Without it a
  Jellyfin user would be asked again whenever the Seerr cookie expires. It is
  a stored password, so it is on the sign-off list (§22).
- A mismatch (Plex account, Jellyfin-backed Seerr, or the reverse) reports
  the existing `plexLoginUnavailable` state, renamed
  `mediaServerLoginUnavailable`.
- The session binding stays `profileID + serverID` (`seerrBindingServerID`);
  the Keychain account `SeerrSessions` is unchanged. TMDB dedupe and
  missing-season enrichment read `ExternalIDs`.

**Trakt.** `TraktHistoryMapper` takes `ExternalIDs` and `MediaKind`; legacy
`com.plexapp.agents.*` parsing moves into the Plex mapper that fills
`ExternalIDs`. Tokens stay keyed by profile scope. Not done in Phase 0 (P0-18
only moved the mapper into its own file): a legacy episode guid is a show id
plus season and episode numbers, which `ExternalIDs` cannot hold, so the move
needs a neutral shape for it, the Plex item mapper (P0-07) and the caller in
`PlaybackCoordinator+Timeline` (P0-10). Until then the mapper still takes the
scalar `guid`.

## 17. Account-level features

| Feature | Plex | Jellyfin | Mixed accounts |
| --- | --- | --- | --- |
| Library order | plex.tv `experience` blob | `OrderedViews` via `POST /Users/Configuration`; device-local when `EnableUserPreferenceAccess` is false | each account stores the relative order of its own libraries; the interleaving across accounts is a per-profile device-local list, used **only** when more than one account is linked |
| Hidden libraries | `pinnedSources[].isHidden` + section `visibility` | `MyMediaExcludes` | per account |
| Hidden Home rows | `promotedToOwnHome` | `LatestItemsExcludes` | per server (§11) |
| Language defaults | plex.tv `profile` | `User.Configuration` | primary account |
| Watchlist | Discover | favourites (§21 row 2) | each account's own |
| Server Priority | device-local | same store | one list, all servers; `PlexServerPriority` key and its `machineIdentifier` field names unchanged |

`LibraryOrderStore`, `HiddenLibraryFilter` and `WatchlistStore` stay the app's
single sources and aggregate over accounts. A single-account install never
writes the device-local interleave, so the rule "settings the server models
live on the server" still holds wherever a server can hold them.

## 18. Top Shelf, Siri, deep links, iCloud, analytics

- **Top Shelf.** Snapshot item id stays `MediaItemID.storageKey`; the deep
  link stays `dusk://play|open?server=&item=&type=` with `MediaKind` raw
  values (identical strings). Images are still pre-downloaded through
  `ImageProviding.data`, so no credential is ever in the App Group.
- **Siri.** **The App Intents type identifier of `PlexTitleEntity` and the
  entity id string form are frozen**, because shortcuts users built reference
  them. App Intents derives that identifier from the Swift type name, so the
  type keeps its `Plex` name (P0-18): the boundary check (§5.4) exempts
  `PlexTitleEntity` and `PlexTitleEntityQuery`. The catalog uses
  `catalog.items(sort: .lastPlayed / .addedAt)`.
- **iCloud KVS.** Only IPTV resume points, not scoped by server. No change.
- **Analytics.** The rule becomes "nothing server-derived, ever". One new
  closed-vocabulary property, `provider = plex | jellyfin | both`, is added to
  the daily app-open event and to error reports, because "does playback fail
  more on one backend" is exactly the class of question analytics exists for.
  The error-report server version allowlist takes the Jellyfin version the
  same way it takes the PMS one. New error reasons: `jf_signin`,
  `jf_quick_connect`, `playback_info`. The privacy policy text names Plex and
  needs the matching edit (§22).

## 19. Migration of persisted data

**Decision: there is no migration step.** Nothing an existing Plex user has on
disk is rewritten, moved or re-keyed. This is achieved by three rules, each
pinned by tests written before the code changes (05, P0-00):

1. **Frozen strings.** Every key in 01 §20 keeps its literal value. A
   `PersistedNames.swift` file holds them as constants with a comment that
   they are wire format.
2. **Additive Codable.** New fields are optional with a default that means
   "what this was before" (`provider` absent = Plex, envelope absent = Plex,
   `ServerRecord` absent = Plex). Renamed Swift properties keep their old
   `CodingKeys`. Ids decode from Int or String.
3. **Same derived values.** `ProfileScope.id` for a Plex primary account,
   `MediaItemID.storageKey`, `globalKey`, the metadata cache hash input and
   `ShowTrackPreferences` keys are computed by code that is moved, not
   rewritten, and each has a golden test comparing against values captured
   from today's build.

| Store | Risk if broken | Guard |
| --- | --- | --- |
| Keychain `PlexAuthToken`, `PlexActiveHomeUserToken`, `PlexServerAuthToken.<id>` | signed out on update | Plex `StoredAccount` is read from these exact accounts; no copy into a new format |
| `downloads.json`, metadata cache, artwork | downloads vanish or cannot browse offline | fixture directory captured from a real install, decoded in a unit test |
| `playback-sync.json` | lost offline progress | fixture test |
| `PinnedHomePlaylists.v1.<profile>`, `ShowTrackPreferences.v1.…`, `IPTVSources.<profile>`, `HomeContinueWatchingServerIDs` | pins and remembered tracks gone | golden key tests |
| Trakt tokens, `SeerrSessions` | re-link needed | scope id golden test |
| Siri entity ids, Top Shelf URLs, SharePlay activity | broken shortcuts / old builds cannot join | string-form tests; frozen type identifiers |
| `PlexServerPriority`, `PlexServerSnapshots`, `PlexServerURL.<id>`, `PlexLastGoodConnectionURI.<id>` | slow first launch, lost order | decoded as-is by the pool |

New Jellyfin data uses new Keychain accounts (`MediaAccounts`, one entry per
`StoredAccount`) and the same shared stores.

## 20. What Jellyfin does better, and what Dusk does with it

Used, because it costs nothing and is invisible: token-free immutable image
URLs, explicit `VideoRangeType`, server-side DV stripping by profile, correct
Atmos `dec3`, subtitle format conversion, cascade watched on a series,
sidecar download of embedded text tracks.

Not used, because it would make the two experiences differ: BlurHash
placeholders, `Recap` / `Preview` / `Commercial` skips, chapter lists with
thumbnails, like/dislike, Similar items. Each is a candidate for a later
feature **for both providers at once** (chapters exist on Plex too).

## 21. The v1 cuts in 02, challenged

02 §17 lists 24 gaps with a proposed behaviour. Against the parity goal, a cut
survives only when the platform cannot do it.

| # | 02 proposal | Verdict | Decision and closest equivalent |
| --- | --- | --- | --- |
| 1 | Client-composed Home rows; Hide Row via `LatestItemsExcludes` | keep, extend | also compose the library Recommended rows (Recently Released, Recently Watched, Top Rated) so that tab is not emptier than on Plex (§11) |
| 2 | Hide Watchlist; do not alias to favourites | **overturned** | the bookmark toggles `IsFavorite`, the Home row lists favourites, both labelled Watchlist. Favourites is the only per-user "keep this for me" list the platform has. Off-server titles cannot exist; with Seerr linked, search already covers "not on the server yet". Product call, §22 |
| 3 | Fixed alphabet without counts | **overturned** | exact letter table from 26 count requests (§9); the bar shows only letters that exist, as on Plex |
| 4 | Filters and sorts from a capability list | keep the mechanism, **shrink the cut** | kept: genre, year, **decade** (expanded to years on the client), content rating, studio/network, **director and actor** (`personIds`), **collection** (BoxSet), **resolution** (4K / HD), unwatched, in progress. Truly absent: HDR, Dolby Vision, audio language (no server filter, and filtering pages on the client is not correct), "My Rating" sort |
| 5 | Hide Rate | keep | no numeric user rating exists. Like/dislike is not a rating and is not aliased |
| 6 | Neutral rating presentation | keep | star for community, neutral glyph for critic (§9) |
| 7 | Local trailer in app; remote opens externally; hidden on tvOS | keep, **tvOS tightened** | tvOS shows Trailer when the YouTube app can open the link (`canOpenURL`), otherwise hides it. In-app playback of a YouTube URL is not possible on any platform |
| 8 | No editions | keep | version labels from `MediaSource.Name` are the closest thing and feed the existing version picker |
| 9 | Client-side content key; title search for point lookups | keep | §6.2 |
| 10 | Read-only collections; "Part of" optional | **overturned for "Part of"** | Dusk does not edit Plex collections either, so read-only is parity. "Part of" ships, backed by the cached membership index (§9) |
| 11 | URL entry, optional second URL, LAN discovery, saved accounts | **changed** | no second URL field and no discovery; `LocalAddress` is raced automatically (§7.1). Saved accounts back Switch User |
| 12 | Order / hidden in user configuration | keep | §17 |
| 13 | Classify `homevideos` by counts | keep | §9 |
| 14 | Client photo grouping, `DateCreated` fallback | keep | grouping moves to the client for both providers |
| 15 | Trust the server's played threshold | keep | §12.5 |
| 16 | No stream-selection write | keep | reports carry the choice |
| 17 | Always send explicit ids | keep | §12.2 |
| 18 | Subtitle search capability-gated | keep | same shape as Plex's owner-only gate |
| 19 | Original-only downloads | **overturned** | converted presets via segmented HLS download (§15.2), progressive fallback |
| 20 | Pre-rolls via `/Intros` | keep | |
| 21 | No Live TV in v1 | **overturned** | ships; test tuner added (§14) |
| 22 | Separate Seerr credential path | keep, decided | `auth/jellyfin` with a Keychain-stored password (§16) |
| 23 | Normalise indexes and codec names in the mapper | keep | §4.2 |
| 24 | Missing test data | keep | list in 05 → T-0 |

Not in 02's list but also absent on Jellyfin, all platform limits: Plex relay
and remote-streaming refusal (nothing to show), "Shared by X" (no ownership
label; `ownerLabel` is nil), Plex Home PIN (password instead), multi-source
rating logos, server-side "hide but keep position" for Continue Watching,
off-server watchlist titles.

## 22. Decisions that need Marvin's sign-off

Engineering decisions above stand unless contradicted. These five are product
or policy calls:

1. **Watchlist = Jellyfin favourites** (§21 row 2). Alternative: hide the
   Watchlist for Jellyfin, which is safer for meaning and worse for parity.
2. **Seerr: store the Jellyfin password in the Keychain** for silent
   re-authentication (§16). Alternative: never store it and ask again when the
   Seerr session expires.
3. **Analytics gains a `provider` property** and the privacy policy wording
   changes from "Plex" to "your media server" (§18).
4. **Mixed Plex + Jellyfin in one profile is supported** (§7.3) rather than
   one provider at a time. It is what makes two Jellyfin servers work at all,
   and it is the last package (J-13), so it can be deferred without redesign.
5. **Rating logos stay off for Jellyfin** (§9); this also keeps the open
   RT/IMDb licensing question from growing.
