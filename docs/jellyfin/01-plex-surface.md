# Jellyfin support — 01: The Plex surface

Every way Dusk depends on Plex today, where it lives, how tightly it is coupled,
and the seam an abstraction needs at that point. Research only: no app code was
changed for this document. Paths are relative to `Dusk/Sources/` unless noted.

How to read it:

- **Coupling** is LOW (a rename or a mapper), MED (a per-backend
  implementation behind an obvious interface), or HIGH (the feature is shaped
  by a Plex protocol or a plex.tv account concept).
- **Seam** is the smallest backend-neutral interface that would let the code
  above it stay unchanged. Names are illustrative, not a design; the design is
  another document's job.
- Line numbers were read on branch `jellyfin-design` (base `fabdb24`,
  2026-11-27). Sections 1–3 and the metrics in §22 were read directly; the
  line references in §4–§21 come from three read-only sweeps of the named files
  and were spot-checked, not all re-opened.

Two existing rules this work overturns and must update when code lands:
`AGENTS.md` ("No `MediaProvider` protocol … don't abstract until a second
backend exists") and `docs/playback.md:11-12` ("Do not introduce a generic
media-provider abstraction for playback unless another backend actually
exists"). `docs/codebase-map.md` repeats it under Cross-Cutting Invariants.

## 1. API client and transport

| What | Where |
| --- | --- |
| Service object | `PlexService/PlexService.swift`: one `@MainActor @Observable final class PlexService`, built in `App/DuskApp.swift:151`, injected into the SwiftUI environment. 27 extension files, about 180 non-private functions |
| Request core | `PlexService+Networking.swift`: `plexTVRequest` (:40), `rawPlexTVRequest` (:69), `rawServerRequest(path:queryItems:serverID:)` (:129), `fetchMetadata` / `fetchDirectories` / `fetchHubs` (:330–352, unwrap `MediaContainer.Metadata` / `.Directory` / `.Hub`), `applyHeaders` (:369), `executeRequest` (:381), `decodeJSON(_:from:serverID:)` (:426) |
| Client identity | Headers on every request (:13–34): `Accept: application/json`, `X-Plex-Client-Identifier` (UUID in UserDefaults `PlexClientIdentifier`), `X-Plex-Product: Dusk`, `X-Plex-Version`, `X-Plex-Platform`, `X-Plex-Device(-Name)`, `X-Plex-Token` |
| Four URLSessions | `session` (30 s), `slowQuerySession` (120 s), `probeSession`, `bootstrapSession` (3 s), all with `PlexTransportSessionDelegate` |
| Token safety | `PlexTransportSecurity.swift`: `allowsToken(in:)`, `authenticatedURL`, `carriesToken`, `validate(_:)`, `allowsRedirect`. Looks for `X-Plex-Token` in query, header or body |
| Errors | `PlexServiceError.swift` (28 references outside the service), includes Plex Home cases (`homePINRequired`, `homePINIncorrect`, `homeUserUnavailable`) |
| Self-healing | `rawServerRequest` recovers a dead endpoint through `recoverServer(serverID:)` (`PlexService+Servers.swift:203`), 30 s cooldown, restored-endpoint validation (:233) |

Coupling: **HIGH by construction, LOW in concept.** Nothing above this layer
builds a URL except playback and images (§8, §9), but 141 distinct
`plexService.<member>` names are used by features, so the class itself is the
de-facto interface.

Seam: `rawServerRequest` is already "a request to *this server*". A backend
client per `PlexServerConnection` (base URL, credential, header policy, JSON
envelope) is the natural split. Jellyfin puts its credential in
`Authorization: MediaBrowser Client=…, Device=…, DeviceId=…, Version=…, Token=…`
and returns bare objects or `{Items, TotalRecordCount}` rather than
`MediaContainer`, so `fetchMetadata`/`fetchDirectories`/`fetchHubs` cannot be
shared; `PlexTransportSecurity` needs to become a per-backend "where does the
secret travel" policy (`api_key` / `ApiKey` query item on stream URLs).

## 2. Auth, accounts, servers, connections

### 2.1 plex.tv sign-in

- `PlexService+Auth.swift`: `generatePin(strong:)` → `POST plex.tv/api/v2/pins`
  (:42), `checkPin` → `GET /api/v2/pins/{id}` (:50), `authURL(for:)` →
  `https://app.plex.tv/auth#?clientID=…&code=…` (:60), `setAuthToken`,
  `signOut`, `retryAfterFreshAuthentication` (20 s propagation window).
- UI: `Features/Account/SignInView.swift` (595 lines): browser hand-off on
  iOS/macOS, link code + QR on tvOS, polling (`startPolling`, :500).
- Model: `Models/PlexPin.swift`.
- Stored: Keychain `PlexAuthToken` (primary account), `PlexActiveHomeUserToken`.

Coupling: **HIGH, and explicitly allowed to differ.** Jellyfin is
"server URL → `POST /Users/AuthenticateByName`" or Quick Connect
(`/QuickConnect/Initiate` + `/QuickConnect/Connect` polling, which is the same
shape as the PIN flow and suits tvOS).

Seam: a sign-in flow per backend that ends in the same thing: one or more
`(server, user, credential)` sessions handed to the pool.

### 2.2 Plex Home users (profiles)

- `PlexService+Home.swift` (despite the name, this is Home *users*, not Home
  hubs): `bootstrapHomeSession` (:14), `fetchHomeUsers` →
  `GET plex.tv/api/v2/home/users` (:217), `GET /api/v2/user` (:226),
  `switchHomeUser(_:pin:remember:)` → `POST /api/home/users/{id}/switch?pin=`
  (:135), `restoreOfflineHomeSession` (:96).
- Two tokens: `primaryAccountToken` (may enumerate and switch) and
  `activeAccountToken` (the switched member), `PlexService.swift:12-20`.
- Models: `PlexUser` (`id: Int`, `uuid`, `username`, `title`, `thumb`, `email`),
  `PlexHomeUser` (`id: Int`, `isProtected`, `isRestricted`, `isAdmin`,
  `isGuest`, `stableProfileID = uuid ?? "plex-home-\(id)"`).
- UI: `Features/Account/HomeUserPickerView.swift` (1 021 lines), the "Switch
  User" rows in Settings, `ContentView` gating
  (`isAuthenticated` → `homeBootstrapCompleted` → `needsHomeUserSelection`).
- **`activeProfileID` is the app-wide storage scope** (`PlexService.swift:38`).
  See §20 for every store keyed on it.

Coupling: **HIGH.** A Plex account spans servers and has members; a Jellyfin
user belongs to exactly one server and there is no switch-with-PIN endpoint
(switching means signing in as someone else; `GET /Users/Public` lists the
users a server chooses to show).

Seam: a neutral "profile" (`id`, display name, avatar, isProtected) plus
`availableProfiles()` / `switch(to:secret:)`, and a stable opaque
`activeProfileID`. Open question for the design doc: what the profile id is
when a Plex account and a Jellyfin user are both signed in.

### 2.3 Server discovery and connection selection

- `PlexService+Servers.swift`: `discoverServers` →
  `GET plex.tv/api/v2/resources?includeHttps=1&includeRelay=1` (:38),
  `isMediaServerResource` (:25), `connectAllServers` (:92), `reconnectServer`,
  `recoverServer`, `refreshServerAuthorization`.
- Models: `PlexServer` (`clientIdentifier` = machine identifier, `owned`,
  `accessToken`, `sourceTitle`, `connections`), `PlexConnection` (`uri`,
  `local`, `relay`, `isOnTailnet`, …) in `Models/PlexServer.swift`.
- `ServerPool.swift` (693 lines): `states`, `connections`, `primary`,
  `connectAll`, `decoder(for:)` (:143, stamps the server id on every decoded
  model), `connectionCandidates` (:499), `httpsUpgradeURI` (:541), per-server
  persistence (`PlexServerAuthToken.<id>` in Keychain, `PlexServerURL.<id>`,
  `PlexLastGoodConnectionURI.<id>`, `PlexServerSnapshots`).
- `ServerProbe.swift`: `ConnectionSelector.select` races candidates;
  `probe` (:382) calls `GET /identity` and checks `machineIdentifier`, then
  `GET /library/sections` to prove the token.
- `PlexServerConnection.swift`: `serverID`, `name`, `owned`, `sourceTitle`,
  `baseURL`, `token`, `connection`, `isLocal` / `isRemote` / `isRelay`.
- `ServerPriorityStore.swift` (UserDefaults `PlexServerPriority`,
  `[{machineIdentifier, isEnabled}]`), `ServerAvailability.swift`,
  `App/ServerConnectionCoordinator.swift`,
  `Features/Settings/ServerPrioritySettingsView.swift`,
  `ConnectionDiagnosticsView.swift`.

Coupling: **MED.** The pool, priority order, availability wording and the
connect coordinator are generic in behaviour. What is Plex is the *source* of
servers (plex.tv), the candidate list (local / remote / relay URIs), the
`/identity` probe and the meaning of `owned` / `sourceTitle`.

Seam: the pool holds `[ServerSession]` where a session knows its backend kind.
Discovery becomes "account sources": plex.tv yields N servers with candidate
URIs; a Jellyfin sign-in yields exactly one server at the URL the user typed
(`GET /System/Info/Public` → `Id`, `ServerName`, `Version`, `LocalAddress` is
the identity probe). `ConnectionDiagnostics`, relay and "Remote streaming
refused" (§8) stay Plex-only or degrade to a one-candidate view.

## 3. Domain models and how far they leak

`Models/` is 32 files, 6 376 lines. All media models are concrete `Decodable`
structs whose stored properties are the Plex JSON field names.

| Model | Plex-shaped parts |
| --- | --- |
| `PlexItemID` (`PlexServerScoped.swift:30`) | `{serverID, ratingKey}`, storage form `"<serverID>|<ratingKey>"`. Persisted in many places (§20) |
| `PlexItem` (`PlexItem.swift:6`) | `ratingKey`, `key`, `type`, `subtype`, `librarySectionID`, `thumb` / `art` / `banner` / `clearLogo` (server-relative paths), `viewCount`, `viewOffset` (ms), `lastViewedAt`, `addedAt` (epoch s), `index` / `parentIndex`, `parentRatingKey`, `grandparentRatingKey`, `grandparentTitle`, `leafCount`, `viewedLeafCount`, `guid`, `guids: [PlexGuid]`, `genres: [PlexTag]`, `roles: [PlexRole]`, `editionTitle` |
| `PlexMediaDetails` (`PlexMediaDetails.swift`) | all of the above plus `ratings: [PlexRating]`, `ratingImage`, `userRating`, `primaryExtraKey`, `collections`, `markers: [PlexMarker]`, `media: [PlexMedia]` |
| `PlexMedia` → `PlexMediaPart` → `PlexStream` | **Integer ids** (`PlexMedia.id`, `PlexMediaPart.id`, `PlexStream.id`), `part.key` (file path used for direct play), `accessible` / `exists`, `streamType` 1/2/3, `selected`, `colorTrc`, `DOVIPresent`, `DOVIProfile`, `DOVILevel`, `DOVIBLCompatID`, `codecID`, `displayTitle`, `extendedDisplayTitle` |
| `PlexMarker` | `id: Int`, `type` (`intro` / `credits`), `startTimeOffset` / `endTimeOffset` (ms) |
| `PlexMediaType` | `movie, show, person, season, episode, clip, artist, album, track, collection, unknown` |
| `PlexLibrary`, `PlexLibraryType` | section `key`, `agent`, `visibility`; type `movie, show, video, liveTV, photo, playlists` |
| `PlexHub` | `hubIdentifier`, `key`, `type`, `context`, section-id suffix parsing (:94) |
| `PlexEpisode`, `PlexSeason`, `PlexAdjacentEpisodes` | parent/grandparent rating keys |
| `PlexContentKey` (`PlexContentKey.swift:75`) | `plex://` guid → external id (tmdb, imdb, tvdb) → heuristic → instance |
| Also | `PlexPlaylist(Entry)`, `PlexLibraryCollection`, `PlexExtra`, `PlexPhotoItem`, `PlexRating`, `PlexWatchlistEntry`, `PlexPinnedSource`, `PlexManagedHub`, `PlexLive*` (§13), `PlexSubtitleSearchResult`, `PlexPlaybackHistoryEntry`, `PlexSearchResult` |

Neutral already: `AudioTrack`, `SubtitleTrack`, `PlaybackState`,
`PlaybackError` (mostly), `SeerrModels`.

Leak (ripgrep `\bPlex[A-Z]\w+` and `plexService\.` per directory, this tree):

| Directory | Files | …naming a `Plex*` type | `plexService.` uses | `ratingKey` uses |
| --- | ---: | ---: | ---: | ---: |
| `Features/Player` | 50 | 32 | 98 | 256 |
| `Features/Detail` | 23 | 22 | 67 | 199 |
| `Downloads` | 14 | 8 | 118 | 207 |
| `Features/Home` | 16 | 15 | 48 | 36 |
| `Features/Libraries` | 19 | 16 | 39 | 13 |
| `Features/Settings` | 22 | 14 | 48 | 0 |
| `Features/Playlists` | 5 | 5 | 42 | 12 |
| `App` | 10 | 9 | 74 | 28 |
| `Mac` | 18 | 8 | 31 | 12 |
| `Shared` | 20 | 14 | 6 | 11 |
| `Siri` | 4 | 4 | 22 | 4 |
| `Playback` | 31 | 9 | 0 | 4 |
| `Features/LiveTV` | 5 | 5 | 14 | 0 |
| `Features/Account` | 2 | 2 | 12 | 0 |
| `Features/Search`, `Watchlist`, `Photos`, `Downloads` | 10 | 10 | 18 | 16 |
| `SeerrService`, `TraktService`, `IPTVService`, `TopShelf`, `Analytics` | 27 | 12 | 26 | 4 |
| `Features/Supporter`, `Features/Seerr` | 10 | 1 | 0 | 0 |

Most-used types outside `PlexService/` and `Models/`: `PlexItem` 279,
`PlexItemID` 253, `PlexMediaDetails` 117, `PlexLibrary` 86, `PlexMedia` 72,
`PlexStream` 67, `PlexEpisode` 65, `PlexHub` 62, `PlexLibraryType` 62,
`PlexMediaPart` 41, `PlexMediaType` 39, `PlexLiveProgram` 39.

The "views never touch the network" rule holds only loosely: **28 view files**
call `plexService.` directly (images, `pool` state, account rows), 116
non-view-model UI files name a Plex type, and `AppNavigationRoute`
(`App/AppNavigation.swift:7-49`) carries `PlexLibrary`, `PlexHub`,
`PlexItemID`, `PlexMediaType`, `PlexPersonReference`, `PlexWatchlistEntry` and
`PlexLibraryCollection` as `Hashable` payloads. Shared UI is Plex-typed by
name: `PlexItemPosterCollections`, `PlexItemPresentation`, `PlexItemPager`,
`PlexItemContextMenuContent`.

Coupling: **HIGH by spread, LOW by meaning.** Views read a small, generic set
of fields (title, artwork path, progress, indexes, parent titles, watched
state). The Plex-ness is in the names, the integer stream/part/marker ids, the
ms and epoch-second units, and image fields being *paths* rather than
references.

Seam, in order of leverage:

1. **Identity.** `PlexItemID` already is "server + opaque item id". Jellyfin
   ids are 32 hex characters, so the `|` storage form still parses; the
   comment "rating keys are numeric" (:41) and every `Int(ratingKey)` are the
   things to hunt. `serverID` must stay globally unique across backends
   (Plex `machineIdentifier` and Jellyfin `ServerId` are both opaque hex, a
   collision is not a practical worry, but the pool needs to know the kind).
2. **Stream, part and marker ids must become strings** (or opaque values).
   Jellyfin has `MediaSourceId` (string) and `MediaStream.Index` (int, per
   source), and segments have GUID ids.
3. **External ids.** `PlexGuid.value(for:)` (`PlexItem.swift:319`) is called
   from Trakt, Seerr search dedupe, missing-season enrichment, watchlist
   matching and movie copies. One accessor `externalIDs {tmdb, imdb, tvdb}`
   covers Plex `Guid[]` and Jellyfin `ProviderIds`.
4. **Artwork as a reference**, not a path (§9).
5. Either rename the models to neutral names and give each backend a mapper
   into them, or keep the structs and add a second `init`. The IPTV precedent
   (§14) shows the second option works and what it costs.

## 4. Endpoint inventory

All server calls go through `rawServerRequest` and are scoped by `serverID`.

| Area | Endpoint (PMS unless noted) | Function, file |
| --- | --- | --- |
| Sign-in | plex.tv `POST /api/v2/pins`, `GET /api/v2/pins/{id}` | `generatePin`, `checkPin` — `+Auth` |
| Account | plex.tv `GET /api/v2/user`, `/api/v2/home/users`, `POST /api/home/users/{id}/switch` | `+Home` |
| Servers | plex.tv `GET /api/v2/resources` | `discoverServers` — `+Servers` |
| Probe | `GET /identity`, `GET /library/sections` | `ConnectionSelector.probe` — `ServerProbe` |
| Libraries | `/library/sections` | `getLibraries` — `+Library:10` |
| Items | `/library/sections/{id}/all` + `X-Plex-Container-Start/Size`, `sort`, filters | `getLibraryItems` :13, `getLibraryItemCount` :44 |
| A–Z | `/library/sections/{id}/firstCharacter` | `getLibraryFirstCharacters` :73 |
| Filters | `/library/sections/{id}/filters`, each filter's `key` | `getLibraryFilters`, `getLibraryFilterValues` |
| Children | `/library/metadata/{k}/children`, `/allLeaves` | `getSeasons`, `getEpisodes`, `getAllEpisodes` |
| Details | `/library/metadata/{rk}?includeMarkers=1&includeGuids=1&checkFiles=1` | `getMediaDetails(Payload)` |
| Hubs | `/hubs?includeGuids=1`, `/hubs/continueWatching`, hub `key` paging, `/hubs/sections/{id}`, `/hubs/promoted?contentDirectoryID=` | `getHubs` :250, `getContinueWatching` :258, `getHubItems` :270, `getLibraryHubs` :111, `getLibraryPromotedHubs` :127 |
| Hub management | `GET/PUT /hubs/sections/{id}/manage[/{identifier}]` | `+HomeRows` |
| Search | `/hubs/search?query=&limit=10&includeCollections=0&includeGuids=1` | `search` :300 |
| Collections | `/library/sections/{id}/collections`, `/library/metadata/{rk}/children?sort=`, `/library/sections/{id}/prefs` | `+Collections` |
| Playlists | `/playlists` CRUD, `/playlists/{rk}/items`, `/items/{id}/move?after=` | `+Playlists` |
| People | `/library/people/{id}`, `/library/people/{id}/media` | `+People` |
| Extras | `/library/metadata/{rk}/extras` | `+Extras` |
| Ratings | `PUT /:/rate?key=&identifier=com.plexapp.plugins.library&rating=` | `+Ratings` |
| History | `/status/sessions/history/all`, plex.tv `/user` | `+History` |
| Photos | `/library/sections/{id}/all?type=14` / `13,12` / `clusterZoomLevel=1`, `/photo/:/transcode` | `+Photos` |
| Images | `/photo/:/transcode?width&height&minSize=1&upscale=0&url=` | `+Images:37` |
| Scrub previews | `/library/parts/{id}/indexes/sd` (BIF) | `scrubPreviewSource` — `+Images:77` |
| Watch state | `/:/timeline`, `/:/scrobble`, `/:/unscrobble`, `PUT /actions/removeFromContinueWatching` | `+Playback:134-212` |
| Stream choice | `PUT /library/parts/{id}?allParts=1&audioStreamID=&subtitleStreamID=` | `enqueueStreamSelection` — `+Playback:382` |
| Decision / HLS | `/video/:/transcode/universal/decision`, `/start.m3u8`, `/ping`, `/stop` | `+Playback:471-656` |
| Subtitles | `GET/PUT /library/metadata/{rk}/subtitles`, `/library/streams/{id}` | `+Subtitles` |
| Pre-rolls | `POST /playQueues?type=video&uri=server://…&extrasPrefixCount=0` | `+PlayQueue:19` |
| Live TV | `/media/providers`, `{provider}/lineups/dvr/channels`, `/livetv/dvrs/{id}`, `{provider}/watchnow/all`, `gridKey?…`, `POST /livetv/dvrs/{dvr}/channels/{id}/tune` | `+LiveTV` |
| Downloads | `/downloadQueue` create / `add` / `items` / `decision` / `media` / delete | `+Downloads` |
| Watchlist | `discover.provider.plex.tv/library/sections/watchlist/all`, `/actions/addToWatchlist`, `/library/metadata/{rk}/availabilities`; PMS `/library/all?guid=` | `+Watchlist` |
| Library order | plex.tv `GET /api/v2/user?includeSettings=1…`, `POST /api/v2/user/settings?sharedSettings=1` | `+LibraryOrder` |
| Language defaults | plex.tv `GET /api/v2/user` (`profile`) | `+LanguageDefaults:73` |

Call sites outside the service that build Plex paths themselves:
`Downloads/PlexMetadataCache.swift:115-119`, `Downloads/DownloadManager.swift:1726,1832`,
`Downloads/PlexDownloadQueue.swift:173` (cache keys named after the PMS path).

## 5. Home, hubs, Continue Watching, On Deck, Recently Added

- `Features/Home/HomeViewModel.swift` (1 080 lines), `HomeHubFilter`,
  `HomeHubArrangement`, `HomeFirstPaintGate`, `HomeRecommendationEngine`,
  `HomeCinematicHero`; merge layer `PlexService/MultiServer/` (`HubMerge`,
  `ContinueWatchingMerge`, `PlexItemMerge`, `streamHomeHubs`,
  `streamContinueWatching`, `mergedHubItems`).
- There is no separate On Deck or Recently Added call: they are rows inside
  `/hubs`. Continue Watching is `/hubs/continueWatching`, and Plex's own
  continue rows are filtered *out* of `/hubs` by string match.
- String heuristics on Plex identifiers:
  - `HomeHubFilter.shouldHide`: title/key/identifier containing
    `continue watching`, `continuewatching`, `on deck`, `ondeck`, `playlist`,
    key containing `/playlists/`, music and unknown items.
  - `HomeHubArrangement.libraryID` (:65): prefixes `home.continue*`,
    `home.ondeck*`, `movie.`, `tv.`, `show.`, `season.`, `episode.`,
    `library.`, contains `recentlyadded`, `type == "mixed"`.
  - `PlexHub` (:94): `movie.recentlyadded.3` → section 3.
  - `HomeViewModel.isRecentlyAddedHub` (:901): *title* contains
    "recently added".
  - `HubMerge.mergeKey` (:142): `hubIdentifier` minus numeric suffix + type +
    library title.
- Dismiss from Continue Watching: `PUT /actions/removeFromContinueWatching`,
  fanned out to every alternate copy (`HomeViewModel` :663).
- Hide Row / Hidden Rows: `GET/PUT /hubs/sections/{id}/manage/{identifier}`
  with `promotedToOwnHome`, owner-only (`canManageHomeRows`, `canHideHomeRow`).
- Recommendation shelves: `getCurrentUser` (plex.tv account id) +
  `getPlaybackHistory` + `genres` + `lastViewedAt` + random-offset
  `getLibraryItems`.

Coupling: **HIGH.** The Home screen is "render whatever hubs the server
returns", and Jellyfin has no hubs: its home is a fixed set of client-side
sections (`/UserItems/Resume`, `/Shows/NextUp`, `/Items/Latest?ParentId=` per
library, plus user `HomeSection*` display preferences).

Seam: `homeRows(server) -> [Row{stableID, kind: .continueWatching | .nextUp |
.recentlyAdded(library) | .custom, libraryID?, items, more}]`,
`continueWatching()`, `dismissFromContinueWatching(id)`, and a capability flag
for "can hide rows server-side". A Jellyfin adapter that synthesises rows with
Plex-like stable identifiers keeps arrangement and merge code unchanged; the
string heuristics should move onto `Row.kind` either way.

## 6. Library browsing, filters, sort, A–Z, collections, playlists

- Views/models: `Features/Libraries/LibrariesViewModel`,
  `LibraryItemsViewModel` (741 lines), `LibraryFilters`, `LibraryFiltersSheet`,
  `LibrarySortMenu`, `LibraryLetterIndex(Bar)`, `LibraryGenreSupport`,
  `LibraryRecommendationsViewModel`, `LibraryRecommendationEngine`,
  `LibraryVideoShelfLoader`, `LibraryCollectionsView(Model)`,
  `Detail/CollectionDetailView(Model)`, `CollectionSort`,
  `Features/Playlists/*`, `PlexService/PlaylistStore`, `PinnedPlaylistStore`.
- Sort vocabulary, `LibrarySortField.plexKey`
  (`LibraryItemsViewModel.swift:48`), `:desc` appended:

  | Field | Plex key | | Field | Plex key |
  | --- | --- | --- | --- | --- |
  | title | `titleSort` | | criticRating | `rating` |
  | releaseDate | `originallyAvailableAt` | | audienceRating | `audienceRating` |
  | year | `year` | | duration | `duration` |
  | addedAt | `addedAt` | | lastViewed | `lastViewedAt` |
  | lastEpisodeAdded | `episode.addedAt` | | random | `random` |
  | userRating | `userRating` | | | |

- Filters: watch state `unwatched=1` / `unwatchedLeaves=1` (shows) /
  `inProgress=1`; offered field filters `decade`, `year`, `contentRating`,
  `resolution`, `hdr`, `dovi`, `audioLanguage`, `studio`, `network`,
  `collection`, `director`, `actor`, plus `genre`. Filter *values* are
  discovered from the server (`/filters` then each `key`).
- A–Z: `/firstCharacter` returns `{key, size}`; `LibraryLetterIndex` turns
  cumulative sizes into paging offsets (title sorts only).
- Collections: `PlexLibraryCollectionMode` from section prefs decides whether
  the grid shows collections in place of their items (`includeCollections=1`).
- Playlists: full CRUD; adding needs a
  `server://{machineID}/com.plexapp.plugins.library/library/metadata/{k1,k2}`
  URI (`libraryURI`, `+Playlists:139`); entries have `playlistItemID`.
- Library type detection: agents `tv.plex.agents.none` /
  `com.plexapp.agents.none` mark "Other Videos"; `subtype == "clip"`.

Coupling: **MED.** `LibrarySortField` and the watch-status enum are already
neutral; only `plexKey` and the filter key strings are Plex.

Seam: `items(library, sort, filters, page) -> (items, total)`,
`filterCatalog(library)`, `letterIndex(library, filters)` (Jellyfin has
`NameStartsWith` but no per-letter counts, so offsets need emulation or the
bar must filter instead of jump), `collections(library, page)`,
`collectionItems(id, sort)`, and playlist CRUD on item ids.

## 7. Search

- `Features/Search/SearchViewModel.swift`, `SearchMediaResult.swift`
  (`enum { case plex(PlexItem), case seerr(SeerrSearchMedia) }`),
  `MultiServer/SearchMerge.swift`, `streamSearch`.
- One call, `/hubs/search`, grouped by hub `type`.

Coupling: **LOW–MED.** Seam: `search(query) -> [group(kind, items)]`
(Jellyfin: `/Items?SearchTerm=&IncludeItemTypes=&Recursive=true`, one request
per kind or one mixed request grouped on the client).

## 8. Playback decision

The single most valuable part of the app, and the part where the *logic* is
most portable and the *protocol* is least.

Files: `Playback/StreamResolver.swift` (+`AV1`),
`Features/Player/PlaybackCoordinator+Session.swift` (2 435 lines),
`+SpatialAudio`, `+ServerTracks`, `PlaybackSourceResolver`,
`PlexService+Playback.swift` (1 029 lines), `+RemotePlayback`,
`Playback/RemuxHLSLoader.swift`, `Playback/DolbyVision7/*`,
`Playback/HEVCSampleEntryProbe.swift`.

Inputs are Plex models all the way down:
`PlexMediaDetails → PlexMedia → PlexMediaPart → PlexStream`.
`StreamResolver.selectMediaVersion` / `evaluate` (:103, :204) are pure
functions over them and read `container`, `videoCodec`, `audioCodec`,
`codecID`, `profile`, `bitDepth`, `colorTrc`, `DOVIPresent`, `DOVIProfile`,
`DOVILevel`, `DOVIBLCompatID`, `channels`, `frameRate`, `bitrate`.

The ladder (`startPlaybackSession`, `+Session.swift:165-852`):

| Rung | Plex mechanism | Notes |
| --- | --- | --- |
| Local download | file URL | no server call |
| Direct play | `baseURL + part.key + ?X-Plex-Token=` (`directPlayURL`, `+Playback:223`) | AVPlayer or VLCKit per `StreamResolver`. `HEVCSampleEntryProbe` reads the URL to tell `hvc1` from `hev1` |
| Remote refusal | `Range: bytes=0-0` probe, 403 = remote streaming refused (`+RemotePlayback:42`), then `reconnectOverLocalNetwork` | Plex-only concept |
| Atmos / HDR remux | `decision` + `start.m3u8` with `directStream=1`, `directStreamAudio=1`, profile-extra `add-transcode-target(container=mp4, videoCodec=hevc,h264[,av1], audioCodec=…)` (`spatialAudioRemuxURL`) | Accepted only when the decision JSON proves a copy: `Media[0].Part[0].Stream[]` `decision`, `codec`, `location`, `channels`, `profile` → `isLosslessRemux` / `isConvertedAudioRemux`. Subtitles require `location == "segments-subs"`. Before the request the app **PUTs the track selection** because Plex takes remux subtitles from the part selection |
| HDR picture-first | DV7 + TrueHD asks Plex to convert audio to E-AC-3 up front so the video is copied and DV is kept, instead of VLCKit + SDR for lossless audio | stages `.copiedAudio` → `.convertedAudio` in `requestHDRServerRemux` (`+SpatialAudio:375`); blockers `spatialAudioRemuxBlocker`, `hdrVideoRemuxBlocker`, `dolbyVisionRemuxBlocker`, `hev1RemuxBlocker`, `convertedTrueHDRemuxBlocker` |
| DV `CODECS` rewrite | `RemuxHLSLoader`: Plex labels DV video plain `hvc1` with no DV config box. DV5 → `dvh1`/`dvhe` + `dvcC`, `CODECS="dvh1.05.LL"`; 8.1/8.4 → keep `hvc1`, add `dvvC`, `SUPPLEMENTAL-CODECS="dvh1.08.LL/db1p|db4h"`, `VIDEO-RANGE=PQ|HLG`, optional level cap (`rewrittenStreamInfLine`, :299) | The only Plex-typed input is `DolbyVisionConfiguration.init?(stream: PlexStream)` (:117) |
| DV7 → 8.1 | `DolbyVision7HLSProxy` on loopback over the same remux | protocol-agnostic (HLS + fMP4) |
| Fallback | 500 ms watch → `performDirectPlayServerStreamFallback` (`+Session:1952`) → `serverStreamURL` (`directStream=1`) | also the AV1 rebuild and DV7 retry |
| Manual quality | `transcodeURL` with `maxVideoBitrate`, `videoResolution`, `videoQuality`; decision codes 1000 / 1001 / ≥2000 | never a startup default |
| AirPlay | `airPlayStreamURL` (H.264/AAC HLS, burned subtitles) on AVPlayer | |
| Live TV | tune → `liveTVDirectPlayURL` or `liveTVStreamURL` | §13 |

Shared query (`transcodeQueryItems`, :656): `hasMDE=1`,
`path=/library/metadata/{rk}`, `mediaIndex`, `partIndex`, `protocol=hls`,
`fastSeek=1`, `directPlay`, `directStream`, `directStreamAudio`, `copyts`,
`session`, `transcodeSessionId`, `X-Plex-Session-Identifier`,
`X-Plex-Client-Profile-Name=Generic`, `X-Plex-Client-Profile-Extra`
(`transcodeClientProfileExtra`, :779), `subtitles=burn|auto|none`,
`audioStreamID`, `subtitleStreamID`, `X-Plex-Incomplete-Segments=1`.
Session lifetime: `/ping` every ~60 s, `/stop` at the end.

What the engines see: `PlaybackEngine` is Plex-free, and `PlaybackSource`
(`Features/Player/PlaybackPresentationModels.swift:128`) is mostly neutral
(`url`, `startPosition`, audio track position, locality, `dolbyVisionRemux`,
`dolbyVision7Conversion`, `hdrRemuxFallback`, `retagsHEV1SampleEntry`). The
`Playback/` folder is not Plex-free: `StreamResolver` (44 Plex references),
`PlaybackEngineFactory`, `VideoEnhancementRequest.make`,
`PlaybackVideoQuality`, `PlaybackDebugInfo` take `PlexMedia` / `PlexStream`;
`PlaybackSource.liveTVContext` is a `PlexLivePlaybackContext`;
`PlaybackAttemptContext` carries `ratingKey`, `mediaID`, `partID`; both
engines call `PlexTransportSecurity.validate` and can fail with "A secure
connection is required to send the Plex token." Auth is the token in the URL
query; no headers are set on `AVURLAsset`.

Coupling: **HIGH by protocol, LOW by logic.**

Seam:

1. Neutral `MediaVersion / MediaPart / MediaStream` with the same fields the
   resolver reads. Jellyfin `MediaSourceInfo` + `MediaStream` carry direct
   equivalents (`VideoRangeType`, `DvProfile`, `DvLevel`,
   `DvBlSignalCompatibilityId`, `ColorTransfer`, `CodecTag`). The resolver
   then ports untouched.
2. `directPlayURL(part)`; Jellyfin `/Videos/{id}/stream?static=true&mediaSourceId=`.
3. `startServerSession(item, version, mode, audio, subtitle) -> {url, outcome,
   StreamDecisions}` where `StreamDecisions` says, per track, copy or convert,
   output codec/container/channels, subtitle delivery. On Jellyfin that is
   `POST /Items/{id}/PlaybackInfo` with a `DeviceProfile` and the returned
   `TranscodingUrl`; whether a remux was really a copy has to be read from
   `TranscodeReasons` or the URL parameters rather than a per-stream decision.
4. `keepAlive(session)` / `stop(session)` (Jellyfin: progress pings and
   `DELETE /Videos/ActiveEncodings`).
5. The DV `CODECS` rewriter stays, but **whether it is needed is a
   per-backend fact**: it exists because of how Plex labels DV in HLS. What
   Jellyfin emits has to be measured before reusing it.
6. `PUT`-selection-before-remux is Plex-only; Jellyfin takes
   `AudioStreamIndex` / `SubtitleStreamIndex` per request.

## 9. Images

- `PlexService+Images.swift` (370 lines): `imageURL(for:serverID:width:height:)`
  (:13), `transcodedImageURL` (:37), `directImageURL`, `imageData(for:)` (:66,
  authenticated fetch, 401 → token refresh), `imageServerConnection(for:)`
  (:101, matches a URL back to a server by host and port),
  `imageRequestURLString(includeToken:)` (:233).
- `Shared/DuskAsyncImage.swift` loads through
  `DuskImageLoader.shared.image(for:using: plexService)`.
- 64 call sites of `imageURL` / `transcodedImageURL` / `imageData` in 29 files
  outside the service, each passing a **path string** taken from a model
  (`thumb`, `art`, `parentThumb`, `grandparentArt`, `clearLogo`) and a
  `serverID`.
- Fallback choices are model logic: `PlexItem.preferredPosterPath`,
  `fallbackPosterPath`, `preferredLandscapePath` (`PlexItem.swift:247-279`),
  `Shared/PlexItemPresentation.swift`.
- No blurhash use anywhere.

Coupling: **MED**, wide but shallow.

Seam: models expose `ImageRef`s (server + opaque reference + kind) and the
service turns `ImageRef + size` into a request. For Jellyfin the reference is
`(itemId, imageType, tag)` → `/Items/{id}/Images/{Primary|Backdrop|Logo|Thumb}?tag=&fillWidth=&quality=`;
parent and series artwork come from `ParentBackdropItemId`,
`SeriesPrimaryImageTag`, `ParentLogoItemId`. Jellyfin images need no token,
and it does offer `ImageBlurHashes`.

## 10. Progress reporting and watched state

- `PlaybackCoordinator+Timeline.swift`: 10 s timer (`startTimelineReporting`,
  :5); `submitTimeline` → `/:/timeline?ratingKey&key&state&time&duration` +
  `X-Plex-Session-Identifier`; states `playing`, `paused`, `buffering`,
  `stopped`; every sixth tick pings the transcode session.
- Watched: `/:/scrobble` once past 90 % (tick or
  `finalizeCurrentPlaybackSession`, `+Session:2219`); explicit
  `setWatched` / `unscrobble`; `Shared/PlexService+WatchedFanOut.swift`
  (`setWatchedAcrossServers`) reaches every server holding the content.
- Reports go to `activePlaybackServerID` only. Live TV never scrobbles; IPTV
  sends nothing.
- Offline: `Downloads/OfflinePlaybackSyncManager.swift` stores
  `OfflinePlaybackSyncAction{serverID, ratingKey, kind, viewOffsetMs,
  durationMs, shouldMarkWatched, plexState}` in `playback-sync.json` and
  replays it as `submitTimeline` + `scrobble` / `unscrobble` (:215).
- Watch state on models: `viewCount`, `viewOffset`, `lastViewedAt`,
  `leafCount` / `viewedLeafCount`; derived `isWatched`, `isPartiallyWatched`
  (`PlexItem.swift:222-230`).

Coupling: **MED.**

Seam: `reportProgress(item, session, state, positionMs, durationMs)`,
`markWatched(item)`, `markUnwatched(item)`. Jellyfin wants a start / progress /
stopped triple (`POST /Sessions/Playing`, `/Playing/Progress`,
`/Playing/Stopped` with `PlaySessionId`, `MediaSourceId`, `PositionTicks` in
100 ns ticks) and `POST|DELETE /UserPlayedItems/{id}`. The 90 % rule is the
app's own and stays. Model mapping: `UserData.Played`, `PlayCount`,
`PlaybackPositionTicks`, `LastPlayedDate`, `UnplayedItemCount`.

## 11. Markers, chapters, scrub previews

- Markers arrive with details (`includeMarkers=1`) as `PlexMarker`; only
  `intro` and `credits` are used. A missing credits marker is synthesised
  (`estimatedCreditsID = -1`, last 4 % clamped to 45 s–2 min,
  `PlayerViewModel+Presentation.swift:154`).
- Plex chapters are not fetched; "chapter markers" on the scrub bar are intro
  and credits.
- Scrub previews: BIF only, `GET /library/parts/{id}/indexes/sd`, parsed by
  `PlexScrubPreviewFrame.parse` (`+Images:316`), loaded in
  `PlayerView.swift:1332`. There is no locally generated fallback in this
  tree. Off for downloads and Live TV.

Coupling: **MED.**

Seam: `markers(item) -> [Marker{kind, startMs, endMs}]` (Jellyfin:
`/MediaSegments/{id}` with `Intro`, `Outro`, `Recap`, `Preview`, `Commercial`,
fed by the Intro Skipper plugin on the test server) and
`scrubPreview(item, version) -> frame source` (Jellyfin trickplay is tiled
JPEG sheets, `/Videos/{id}/Trickplay/{width}/{index}.jpg` described by
`Trickplay` in the item DTO; the player needs "frame at time", not BIF).

## 12. Track selection, remembered tracks, subtitles

- `Features/Player/PlayerViewModel+TrackSelection.swift` (1 226 lines),
  `SubtitleSelectionPolicy`, `ShowTrackPreferences`,
  `PlaybackCoordinator+ShowTracks`, `+ServerTracks`, `SubtitleSearchViewModel`,
  `SubtitleDownloadApplication`, `PlexService+Subtitles`,
  `+LanguageDefaults`.
- Direct play: tracks switch in the engine. Server sessions
  (`usesServerTrackSelection`): every change PUTs `/library/parts/{id}` and
  rebuilds the HLS; automatic writes are undone at session end
  (`ServerStreamSelectionRestore`).
- Per-show memory: UserDefaults key
  `"ShowTrackPreferences.v1." + <len>:<profileID><len>:<serverID><len>:<showRatingKey>`
  (`ShowTrackPreferences.swift:129-146`); the value is a semantic
  `ShowTrackDescriptor` (language, forced, HI, commentary, codec, channels,
  external), **no stream ids**, so it is already backend-neutral. Explicit
  choices on episodes are also written to Plex.
- Server-selected tracks: `PlexStream.selected` is the tie-break after Dusk's
  own rules.
- Account language defaults: plex.tv `profile` (`autoSelectAudio`,
  `defaultAudioLanguage`, `defaultSubtitleLanguage`, `autoSelectSubtitle`
  0/1/2) → UserDefaults `plexAccountAudioLanguage`,
  `plexAccountSubtitleLanguage`, `plexAccountSubtitleMode`
  (`UserPreferences.swift:724`).
- Subtitle search: `GET /library/metadata/{rk}/subtitles?language&hearingImpaired&forced`,
  install by `PUT` to the same path; owner-only and not for restricted users
  (`canDownloadSubtitles`); then refetch details and mount the new sidecar.
- Sidecars: `externalSubtitleURL(for: PlexStream)` = `base + stream.key`
  (`/library/streams/{id}`) + token. PGS renders in VLCKit, or
  `subtitles=burn` in server sessions.

Coupling: **MED–HIGH** (the write-to-server ordering), LOW for the remembered
descriptor.

Seam: `persistTrackSelection(item, version, audio, subtitle)` as an optional
capability; `accountLanguageDefaults()` (Jellyfin `UserConfiguration`:
`AudioLanguagePreference`, `SubtitleLanguagePreference`, `SubtitleMode`,
`PlayDefaultAudioTrack`); `subtitleSearch(item, …)`, `installSubtitle(result)`,
`canInstallSubtitles(server)` (Jellyfin: `/Items/{id}/RemoteSearch/Subtitles/{lang}`,
needs a subtitle plugin and a permission); `sidecarURL(stream)`
(`/Videos/{id}/{mediaSourceId}/Subtitles/{index}/Stream.{format}`).

## 13. Live TV, DVR, guide

- `PlexService+LiveTV.swift` (463 lines), `Models/PlexLiveTV.swift`
  (1 161 lines), `PlexLiveTVDevice.swift`, `Features/LiveTV/*`
  (`LiveTVViewModel`, `LiveTVView`, `LiveTVGuideGridView` 1 515 lines,
  `LiveTVGuideGridModel`, `LiveTVHomeShelf`), `Features/Player/PlayerLiveTimeline`.
- Plex concepts: EPG provider discovered from `/media/providers`
  (`protocols` contains `livetv` and a `Feature type=grid`);
  `PlexLiveTVProvider{identifier, providerIdentifier, dvrID, gridKey,
  serverID}`; `PlexLiveChannel{id, gridKey, vcn, alternateIdentifiers,
  tuneIdentifier}`; `PlexLiveProgram` / `PlexLiveAiring{channelIdentifier,
  gridKey, beginsAt, endsAt, guid}`; `PlexLiveChannelMatcher` reconciles guide
  channels with tunable channels; devices from `/livetv/dvrs/{id}` group
  channels per tuner.
- Guide: ranged grid `gridKey?endsAt>=&beginsAt<=` and per-channel
  `gridKey?channelGridKey=&date=`. Plex has no past guide.
- Tune: `POST …/tune` → `/livetv/sessions/{uuid}` → direct play of the
  session's `index.m3u8` when the decision says `directplay`, else the
  transcode ladder with `copyts=0`, `offset=-1`.
- Catch-up: a past airing is playable only as a library recording found by
  `serverItems(guid:)`.
- Live TV is single-server (`pool.primary` style provider discovery).

Coupling: **HIGH** for the Plex calls, **LOW** for the models (see §14).

Seam: `LiveTVBackend { discover, channels, devices?, guide(window), nowPlaying,
tune(channel) -> playable, recording(for: program)? }`. Jellyfin:
`/LiveTv/Channels`, `/LiveTv/Programs?MinEndDate&MaxStartDate&ChannelIds`,
`/LiveTv/Programs/Recommended?IsAiring=true`, tuning is a normal
`PlaybackInfo` on the channel item with `AutoOpenLiveStream=true`,
`/LiveTv/Recordings`. The test server has no tuner configured, so this part
cannot be verified there.

## 14. IPTV

- `IPTVService/*` (M3U, XMLTV, catch-up, resume, FairPlay under
  `Playback/FairPlay`). No server involved; AVPlayer only.
- It maps into the Plex Live TV models (`IPTVLineupBuilder`):
  `PlexLiveTVProvider(identifier: "iptv:{uuid}", providerIdentifier:
  "tv.dusk.iptv", dvrID: 0, gridKey: "")`, `PlexLiveChannel(iptvID:)` with an
  `iptv: IPTVPlayableChannel` payload, `PlexLiveProgram(iptv:channel:)` with
  `ratingKey "iptv-{channel}-{start}"`; `isIPTV` checks keep it off Plex
  calls; images go through `plexService.imageURL` with `IPTVImages.serverID`.
- Scope: sources are stored per Plex profile, `IPTVSources.<profileID>`.

Coupling: **LOW**, but it is the working precedent: `PlexLive*` already acts
as the app's neutral Live TV model, at the price of Plex names and `isIPTV`
branches. A Jellyfin Live TV adapter would be the third producer of those
types.

Seam: none beyond the profile id; renaming `PlexLive*` is optional.

## 15. Downloads and offline

- `Downloads/DownloadManager.swift` (3 262 lines), `DownloadModels`,
  `DownloadFileStore`, `DownloadTransfer`, `PlexDownloadQueue`,
  `PlexMetadataCache`, `SmartDownloads`, `OfflinePlaybackSyncManager`,
  `PlexService+Downloads`, `Features/Downloads/*`. 118 `plexService.` uses and
  207 `ratingKey` uses in `Downloads/`, the densest non-player directory.
- Original quality: plain download of `directPlayURL(part)`.
- Converted quality (presets 12 000 / 8 000 / 4 000 / 2 000 / 1 000 / 700 kbps
  at 1080p / 720p / 480p / 320p): the PMS **download queue**:
  `POST /downloadQueue`, `…/add?keys=&mediaIndex=&videoBitrate=&videoResolution=&directPlay=0&directStream=0&protocol=http`,
  poll `…/items/{i}`, then `…/item/{i}/decision` and `…/media`, delete
  afterwards. Custom headers: per-request `X-Plex-Client-Identifier`,
  `X-Plex-Pms-Api-Version: 1.0.0`, an mkv/h264/aac profile-extra.
- **Persisted Plex shapes (migration-relevant):**
  - `downloads.json`: `DownloadedMediaRecord` with `serverID`, `ratingKey`,
    `type: PlexMediaType`, parent/grandparent rating keys, `thumbPath` /
    `artPath`, `mediaID` / `partID`, `plexDownloadQueueID`,
    `plexDownloadItemID`, `convertedMediaData` (a JSON-encoded `PlexMedia`),
    `externalSubtitlePaths: [plexStreamID: path]`,
    `globalKey = "{profileID}:{serverID}:{ratingKey}"`.
  - `Metadata/[Profiles/{p}/]{serverID}/{hash(endpoint)}.json`: **raw PMS
    responses** for `/library/metadata/{rk}` and `/children`, decoded on read
    as `PlexMediaDetails` / `PlexSeason` / `PlexEpisode`. Offline browsing runs
    entirely on these blobs.
  - `SmartDownloadRule{serverID, showRatingKey, …}`.
- Smart downloads: `SmartDownloadPlanner.plan` is a pure function of
  `parentIndex`, `index`, watched; reads `/allLeaves`.

Coupling: **HIGH.**

Seam: `originalFileURL(item, version)`, `prepareConvertedDownload(item,
quality) -> async {status, url}`, `subtitleSidecars(item)`,
`metadataSnapshot(item) -> Codable`. Jellyfin has no download queue: original
is `/Items/{id}/Download`, converted is a progressive
`/Videos/{id}/stream.mkv?VideoBitRate=&MaxWidth=…` transcode that cannot
resume. The offline cache needs a backend tag or a neutral snapshot format;
existing Plex blobs can stay as they are for existing records.

## 16. Photos, extras, people, ratings, collections on detail pages

| Feature | Files | Plex specifics | Coupling | Seam (Jellyfin lead) |
| --- | --- | --- | --- | --- |
| Photos | `Features/Photos/*`, `+Photos`, `PlexPhoto.swift` | `type=14` albums, `13,12` media, `clusterZoomLevel=1` timeline; display through `/photo/:/transcode` for rotation and HEIC | MED | `photoPage(library, mode, parent, page)`, `displayURL(item, size)` (`/Items?IncludeItemTypes=Photo,PhotoAlbum,Video`, `/Items/{id}/Images/Primary`) |
| Extras | `Detail/DetailExtrasShelf`, `+Extras`, `PlexExtra.swift` | numeric `extraType`, `primaryExtraKey` trailer | LOW | `extras(item)` (`/Items/{id}/SpecialFeatures`, `/Items/{id}/LocalTrailers`, `ExtraType`) |
| People | `Detail/ActorDetailView(Model)`, `+People` | `/library/people/{id}` ids parsed from `PlexRole.tagKey` | LOW | `person(id)`, `personMedia(id)` (`People[]`, `/Items?PersonIds=`) |
| Ratings | `Detail/DetailRatings`, `PlexRating.swift`, `+Ratings` | `ratingImage` URIs (`rottentomatoes://…`, `imdb://…`), `Rating[]`, user rating 0–10 via `/:/rate` | MED | `ratings(item) -> [source, value]` (`CommunityRating`, `CriticRating`); **Jellyfin has no numeric user rating**, only `IsFavorite` / `Likes` |
| Editions | `PlexItem.editionTitle`, content key suffix | Plex field | LOW | Jellyfin has versions (`MediaSources[].Name`), no edition metadata |
| Movie copies / versions | `MultiServer/PlexService+MovieCopies`, Preferred Version setting | `Media[]` per item, same-server duplicates | MED | `MediaSources[]` |
| Detail view models | `Features/Detail/*ViewModel.swift` | `getMediaDetails`, `getSeasons`, `getEpisodes`, `getAdjacentEpisodes`, `getNextEpisode` | MED | same verbs; Jellyfin `/Shows/{id}/Seasons`, `/Shows/{id}/Episodes`, `/Shows/NextUp?SeriesId=` |
| Trailer | `primaryExtraKey`, 1.8 browse features | Plex extras | LOW | `RemoteTrailers` / local trailers |

## 17. Plex-account features: Watchlist, library order, hidden libraries

- Watchlist: `PlexService+Watchlist.swift` (358 lines), `WatchlistStore`,
  `Features/Watchlist/*`, `Home/HomeWatchlistShelf`, `HomeWatchlistPlacement`.
  Talks to `discover.provider.plex.tv`, matches entries to server items by
  `plex://` guid, and reads Plex Web's home layout
  (`experience.homeSettings.hubs`, sent with `X-Plex-Product: Plex Web`) to
  place the row.
- Library order and Hidden Libraries: `PlexService+LibraryOrder.swift`
  (378 lines), `LibraryOrderStore`, `LibraryOrderArrangement`,
  `HiddenLibraryFilter`, settings views. Stored in the plex.tv `experience`
  setting as `sidebarSettings.pinnedSources[]` with keys
  `source|sourceType|machineIdentifier|com.plexapp.plugins.library|directoryID`
  and `isHidden`; written by a read-modify-write of the whole blob.
  `HiddenLibraryFilter` keys on `"serverID|librarySectionID"` and folds in
  the per-library PMS `visibility`.

Coupling: **HIGH.** Both are account-level and span servers, which is exactly
what a Jellyfin user is not.

Seam: an optional account-features surface: `watchlist?`, `libraryOrder?`,
`hiddenLibraries?`. Jellyfin has per-user, per-server
`UserConfiguration.OrderedViews` and `MyMediaExcludes` /
`LatestItemsExcludes` (close matches for order and hiding) and favourites
(`IsFavorite`) as the nearest thing to a watchlist. A mixed account needs one
order across both backends, which neither server can hold.

## 18. Multiple servers

- `PlexService/MultiServer/*`: `fanOutAcrossServers`, `streamAcrossServers`,
  `HubMerge`, `ContinueWatchingMerge`, `PlexItemMerge`, `SearchMerge`,
  `ContentAlternatesIndex`, `ServerLabeling`, `PlexService+MovieCopies`;
  `PlaybackSourceResolver` (which server plays, in which order others are
  tried).
- Keyed on `PlexContentKey`: `plex://` guid first, then external ids
  (`tmdb`, `imdb`, `tvdb`, namespaced by type), then `type|title|year` or
  `show|sN|eN`, then instance.
- Tie-breaks use `viewCount`, `viewOffset / duration`, `lastViewedAt`, server
  rank.

Coupling: **MED**, and the best news in this document: the merge layer is a
pure function of per-server lists, so a Jellyfin server that produces the same
neutral items merges with a Plex server for free. A Jellyfin item never has a
`plex://` guid, so Plex-and-Jellyfin copies only merge when the Plex item's
key resolves through an external id; today the `plex://` guid wins whenever it
is present (`PlexContentKey.swift:87`). A mixed setup therefore needs the key
to carry (or fall back to) the external id on the Plex side too.

Seam: none new beyond §3; `pool.connections` iteration must not assume every
session speaks Plex (72 direct `plexService.pool` uses outside the service).

## 19. Peripheral systems

| System | Files | What it takes from Plex | Coupling | Change for Jellyfin |
| --- | --- | --- | --- | --- |
| Seerr | `SeerrService/*`, `Features/Seerr/*`, `Shared/PlexService+ServerIdentity.swift` | **Signs in with the Plex token**: `POST api/v1/auth/plex` with `activeAccountToken` (`SeerrService.swift:115-137`, re-auth on 401); `SeerrPublicSettings.acceptsPlexLogin` rejects Jellyfin/Emby-backed instances (`plexLoginUnavailable`); session bound to `profileID + serverID` (`seerrBindingServerID`); TMDB dedupe and missing-season enrichment through `tmdb://` guids | HIGH | `POST /api/v1/auth/jellyfin` takes username + password, so it needs credential entry or a stored secret; accept `mediaServerType == 2`; external-ids accessor |
| Trakt | `TraktService/*` | `TraktHistoryMapper.entry(type:guid:guids:…)` reads `imdb://`, `tmdb://`, `tvdb://` and legacy `com.plexapp.agents.*` guids; tokens keyed by profile id; fired from `reportFinishedToTrakt` (`+Timeline:112`) | MED | mapper takes neutral external ids and kind |
| Top Shelf (tvOS) | `TopShelf/*`, `DuskTopShelf/ContentProvider.swift` | Snapshot item id = `PlexItemID.storageKey`; images pre-downloaded (no tokens stored); deep link `dusk://play|open?server=&item=&type=<PlexMediaType>` | MED | neutral type in the URL; image fetch through the neutral image seam |
| Siri / App Intents | `Siri/*` | `PlexTitleEntity.id` = storage key; catalog from `getLibraries` + `getLibraryItems(sort: "lastViewedAt:desc" / "addedAt:desc")`; playback via `getMediaDetails`, `getAllEpisodes` | MED | neutral browse verbs; entity ids persist in Shortcuts, keep the string form |
| SharePlay | `Features/Player/DuskWatchTogetherActivity.swift`, `PlaybackSharePlayController` | Activity carries `serverIdentifier` + `ratingKey`; identifier `plex://<server>/metadata/<ratingKey>` | MED | additive backend field; both devices must reach the same server |
| iCloud KVS | `IPTVService/IPTVResumeStore.swift:228-246` only | Key `iptvResumePoints`, not scoped by user or server; Plex-typed only through `PlexLiveChannel` / `PlexLiveProgram` in an init | LOW | nothing |
| Analytics | `Analytics/*` | "Nothing Plex-derived is ever reported" (`AnalyticsClient.swift:21`); error reasons such as `pin_request`, `remote_refused`, `transcode_failed`; `ConnectionReport.errorReport` | LOW | new reasons for Jellyfin sign-in; a backend dimension is a product decision |
| Plex Pass gating | `PlexService+RemotePlayback.swift` | No client-side gate. Only the wording for a 403 on a remote connection | LOW | Plex-only message |
| Supporter | `Features/Supporter/*` | none (StoreKit) | none | none |
| Screenshot mode | `App/ScreenshotMode.swift`, `scripts/` | Swaps `https://plex.tv` for a mock that serves Plex-shaped responses | MED (debug only) | a Jellyfin mock or the real demo server |
| Tests | `DuskTests/` | 54 of 80 files name `Plex*` types; 13 are Plex-shape tests (decoding, connection selection, download queue, guide matching) | MED | merge and policy tests should move to neutral fixtures |
| Now Playing / AirPlay | `PlaybackNowPlayingController`, `PlaybackAirPlayController` | artwork via `imageURL`; AirPlay stream is Plex HLS (§8) | LOW–MED | covered by the image and session seams |
| Pre-rolls | `PlaybackCoordinator+Prerolls`, `+PlayQueue` | `/playQueues` with `extrasPrefixCount=0` to learn the server's cinema pre-roll | MED | optional capability (Jellyfin: `/Items/{id}/Intros`, plugin-fed) |
| Up Next / queue | `PlaybackCoordinator+UpNext`, `PlaybackQueue` | client-side walk of seasons and episodes; no Plex play queues | LOW | same verbs |

## 20. Settings and persisted identifiers

Settings screens that are Plex concepts: Server Priority, Connection
Diagnostics, Library Order, Hidden Libraries, Hidden Rows (owner-only hub
management), Pinned Playlists, Audio & Subtitles defaults sourced from the
Plex account, Switch User, "Manage / Delete Plex Account" links
(`SettingsIOSView.swift:69-108,253-267`), Download Subtitles.

`UserPreferences` (`Features/Settings/UserPreferences.swift`, 1 033 lines) is
device-global and mostly neutral. Plex-flavoured keys:
`plexAccountAudioLanguage`, `plexAccountSubtitleLanguage`,
`plexAccountSubtitleMode`; `libraryTabOrder` / `hiddenLibraryTabs` store
`PlexLibraryType` raw values; per-library sort keyed by library id.

Persisted identifiers a second backend must not break:

| Store | Key or format |
| --- | --- |
| Keychain | `PlexAuthToken`, `PlexActiveHomeUserToken`, `PlexServerAuthToken.<machineID>`, `SeerrSessions`, `TraktAccounts`, `IPTVSourceHeaderValues` |
| UserDefaults, account | `PlexClientIdentifier`, `PlexPrimaryProfileID`, `PlexActiveHomeUserData`, `PlexAutomaticallySignInHomeUser`, `PlexServerPriority`, `PlexServerSnapshots`, `PlexServerURL.<id>`, `PlexLastGoodConnectionURI.<id>` |
| Per profile | `IPTVSources.<profileID>`, `PinnedHomePlaylists.v1.<profileID>` (`[{id: PlexItemID, title}]`), `ShowTrackPreferences.v1.<profile><server><show>`, `HomeContinueWatchingServerIDs[profile]`, Trakt tokens, Seerr sessions (`profileID + serverID`) |
| Downloads | `globalKey "{profileID}:{serverID}:{ratingKey}"`, metadata cache paths per profile and server |
| Offline sync | `playback-sync.json` actions by profile, server, rating key |
| Cross-process / cross-device | Top Shelf snapshot + `dusk://` URLs, Siri `PlexTitleEntity.id` and `siriTitleCatalog`, SharePlay activity |
| In memory | `LibraryOrderStore` cache key `"<serverIDs>|<profileID>"`, `HiddenLibraryFilter` `"serverID|sectionID"`, `ServerContentRevision{serverIDs, priorityRevision, profileID}` |

Coupling: **MED.** Every key is "profile id × server id × item id", and all
three are already opaque strings. The risk is not format, it is *which*
profile id applies when two backends are signed in at once.

## 21. App shell

- `App/DuskApp.swift` builds `PlexService()` and hands it to
  `PlaybackCoordinator`, `DownloadManager`, `OfflinePlaybackSyncManager`,
  `SeerrService`, `TraktService`.
- `App/ContentView.swift:28-46` gates the app on `isAuthenticated`,
  `homeBootstrapCompleted`, `needsHomeUserSelection`.
- `App/ServerConnectionCoordinator.swift` runs `connectAllServers` and
  `bootstrapHomeSession`.
- `App/MainTabView.swift`, `Mac/MacRootView.swift` apply the Plex language
  defaults and key reloads on `serverContentRevision`.

Coupling: **MED.** Seam: a neutral session state
(`signedOut | bootstrapping | needsProfile | ready`) and "connect every
account source".

## 22. Coupling heat map

| Area | Coupling | Spread (where it bites) | Seam kind |
| --- | --- | --- | --- |
| Sign-in (PIN) | HIGH | 2 files | separate flow per backend (allowed to differ) |
| Plex Home users, profile id | HIGH | account UI + every per-profile store | neutral profile + scope id |
| Server discovery, connections | MED | `PlexService/` + 2 settings screens | account source per backend |
| Request core, headers, token policy | HIGH | 1 folder | client per session |
| Domain models | HIGH spread / LOW meaning | 186 files | neutral models or mappers; string ids |
| Images | MED | 64 call sites, 29 files | `ImageRef` |
| Home hubs, Continue Watching | HIGH | Home + merge layer | synthesised rows with a `kind` |
| Hide Home rows | HIGH | 2 files | capability flag |
| Library browse, sort, filters | MED | Libraries | per-backend key mappers |
| A–Z index | MED | 2 files | emulation |
| Collections, playlists | MED | Libraries, Playlists | CRUD on ids |
| Search | LOW–MED | Search | one verb |
| Playback decision (protocol) | HIGH | `+Playback`, coordinator | session API + decisions |
| Playback decision (logic), `StreamResolver` | LOW | `Playback/` | neutral stream models |
| DV `CODECS` rewrite, DV7 proxy | LOW | `Playback/` | per-backend "is it needed" |
| Engines, `PlaybackSource` | LOW–MED | `Playback/` | auth policy, neutral live context |
| Timeline, watched | MED | coordinator, offline sync | three verbs |
| Markers, scrub previews | MED | player | two verbs; trickplay ≠ BIF |
| Track persistence | MED–HIGH | player | optional capability |
| Per-show remembered tracks | LOW | 1 file | none |
| Subtitle search | MED | player, detail | optional capability |
| Live TV (Plex calls) | HIGH | `+LiveTV` | `LiveTVBackend` |
| Live TV models, IPTV | LOW | — | already shared |
| Downloads | HIGH | `Downloads/` + on-disk formats | prepare/URL API + snapshot format |
| Photos | MED | Photos | page + display URL |
| Extras, people, editions | LOW | Detail | simple verbs |
| Ratings | MED | Detail | sources differ; no user rating |
| Watchlist | HIGH | Home, Watchlist | optional account feature |
| Library order, hidden libraries | HIGH | Settings, every merged list | optional account feature |
| Multi-server merge | MED | `MultiServer/` | content key tweak |
| Seerr | HIGH | SeerrService | auth strategy |
| Trakt | MED | 1 mapper | external ids |
| Top Shelf, Siri, SharePlay | MED | ids in URLs and entities | backend-aware ids |
| iCloud KVS, analytics, Plex Pass, Supporter | LOW / none | — | none |
| App shell | MED | `App/` | neutral session state |

The shape of the work this implies: a **wide, mechanical** change (models,
identity, images, the `plexService` environment object) and a **narrow, deep**
one (playback session protocol, Home rows, downloads, account features).

## 23. Plex-only concepts with no obvious Jellyfin equivalent

Leads on the Jellyfin side are from API knowledge, not from probes; the other
documents in this folder verify them against `jellyfin-demo`.

| Plex concept | Used for | Nearest Jellyfin thing | Gap |
| --- | --- | --- | --- |
| plex.tv account spanning servers | discovery, one sign-in for N servers | none; one user per server | each Jellyfin server is its own sign-in |
| Plex Home members + PIN switch | profile picker, restricted users | `/Users/Public`, per-user password | no token switch; "profile" = full sign-in |
| Relay and multiple advertised connections | connection race, diagnostics | one URL (`LocalAddress` hint) | diagnostics collapse to one candidate |
| Remote streaming refusal (403, Plex Pass) | wording + local reconnect | none | Plex-only |
| Hubs (`/hubs`, `hubIdentifier`, promoted) | Home, library Recommended | Resume, NextUp, Latest, Suggestions | rows must be synthesised |
| Manage Recommendations (`promotedToOwnHome`) | Hide Row / Hidden Rows | `HomeSection*` display prefs, `LatestItemsExcludes` | not per-row on the server |
| `removeFromContinueWatching` | dismiss from Continue Watching | none (reset position or mark played) | behaviour differs |
| On Deck as a server hub | merged continue row | `/Shows/NextUp` | separate call |
| `plex://` global guid | cross-server identity, watchlist match | `ProviderIds` only | merge must fall back to external ids |
| Watchlist (Discover) + availabilities | Home row, off-server title page | favourites | no off-server titles |
| `experience` setting (pinned sources, home layout) | library order, hidden libraries, watchlist placement | `OrderedViews`, `MyMediaExcludes` | per server, not per account |
| Universal transcode decision with per-stream `decision` / `location` | proving a remux is a lossless copy | `PlaybackInfo` + `TranscodeReasons` | proof is coarser |
| `X-Plex-Client-Profile-Extra` | remux targets, audio conversion | `DeviceProfile` JSON | different model, same intent |
| `PUT /library/parts` selection as remux input | subtitles in remux, show memory | per-request stream indexes; no stored selection | no server-side remembered track |
| `segments-subs` WebVTT in HLS | subtitles on AVPlayer remux | `SubtitleDeliveryMethod` (`Hls`, `External`, `Encode`) | to be measured |
| BIF index | scrub previews | trickplay tile sheets | different format |
| `/playQueues` with `extrasPrefixCount` | cinema pre-rolls | `/Items/{id}/Intros` (plugin) | optional |
| Download queue (server-side prepared conversion) | Download quality presets | progressive transcode stream | no queue, no resume |
| Subtitle search proxied by PMS, owner-only | Download Subtitles | `RemoteSearch/Subtitles` + plugin + permission | availability differs |
| Numeric user rating (`/:/rate`) | Rate, user rating sort/filter | `IsFavorite`, `Likes` | no 0–10 rating |
| Rating sources (`ratingImage`, `Rating[]`) | rating logos | `CommunityRating`, `CriticRating` | no source attribution |
| Editions (`editionTitle`) | subtitles, content key | version names | no edition field |
| `firstCharacter` counts | A–Z jump | `NameStartsWith` filter | no counts |
| Collection mode (section prefs) | collections replacing items in the grid | `GroupItemsIntoCollections` display setting | to be checked |
| `subtype == "clip"`, `agents.none` sections | Videos libraries | `CollectionType: homevideos` | different signal |
| Photo timeline clustering (`clusterZoomLevel`) | Photos timeline | date sort only | client-side grouping |
| EPG provider + `gridKey` + tune session | Live TV | `/LiveTv/*` + `PlaybackInfo` live stream | different flow; unverifiable on the test server |
| Session history (`/status/sessions/history/all`, account id) | recommendation engines | `LastPlayedDate` on items, `/Items/Suggestions` | no history endpoint for users |
| Shared-server ownership (`owned`, `sourceTitle`) | "Shared by X", owner-only actions | user policy (`IsAdministrator`) | wording differs |
| Seerr `auth/plex` token sign-in | one-tap Seerr link | `auth/jellyfin` with password | needs a credential |

Going the other way, things Jellyfin has that the Plex-shaped app has no slot
for (so parity does not need them, but the abstraction should not forbid
them): favourites, `Recap` / `Preview` / `Commercial` segments, blurhash
placeholders, Quick Connect, per-request subtitle delivery choice.
