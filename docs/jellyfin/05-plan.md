# Jellyfin support — 05: Execution plan

How to get from today's tree to the design in
[04-architecture.md](04-architecture.md) with a fleet of coding agents and one
coordinator. Plan only: no app code was changed for this document.

Two phases:

- **Phase 0** puts Plex behind the provider abstraction with **zero behaviour
  change**. It ends at a gate (§3) that compares requests, pixels and persisted
  data against a baseline recorded before the first change.
- **Phase J** adds Jellyfin on top. Nothing is hidden: each J package lands
  on `main` as it passes, and Jellyfin is visible to everyone in the build
  that ships it (2.0).

Paths are relative to `Dusk/Sources/` unless noted. Section references such as
"04 §12" point into the architecture document.

## 1. Ground rules for the fleet

| Rule | Why |
| --- | --- |
| One package = one worktree = one branch `jf/<package-id>`, cut from `main` at the moment its dependencies have merged | minimal overlap, clean review |
| **Everything merges to `main` as it passes its acceptance**, not to a long-lived integration branch | a refactor branch that touches 186 files cannot survive weeks of 1.9.x fixes on `main`. Every Phase 0 package is behaviour-neutral, so it is safe to land |
| **Nothing hidden: there is no launch flag.** J packages land on `main` like Phase 0 packages; the sign-in host shows the Jellyfin flow as soon as J-01 lands. `main` is version 2.0.0, and 1.9.x fixes ship from `release/1.9` | Jellyfin is visible to everyone once it works (Marvin, 2026-11-28); a gate would only be one more thing to remove |
| A package edits only the files it lists. A needed change in someone else's file is a request to the coordinator, not an edit | the split below is designed around file ownership |
| `Dusk.xcodeproj` is never hand-merged: after any merge that touched source files, run `xcodegen generate` and commit the result | every package adds files |
| Commit with `git commit -- <paths>`; never stage what another agent left | existing repo rule |
| Coding agents do the compile-only builds from `AGENTS.md` (iOS and tvOS always, macOS when `Mac/` or shared UI changed). **Tests, simulators and server checks are run by the coordinator's verification agent** on the merged result, on simulators only, with silent test media, never by launching Dusk on the Mac | existing repo rules; this plan is the explicit request for those runs |
| No persisted string changes, ever (04 §19). A package that needs one stops and asks | no migration is the migration plan |
| A package that changes a documented flow updates the matching file in `docs/` in the same commit | existing repo rule |
| Server writes during checks are limited to the `duskcompare` user's own watch state, playlists and favourites, and are reverted at the end of the check | the demo servers are shared |

Sizes: **S** under ~300 changed lines; **M** 300 – 1 000; **L** 1 000 – 3 000;
**XL** above that, or needs device measurement to finish. "mech." marks a
change that is large in lines but produced by a script.

Risk: **R** = hard or likely to surprise; give it the strongest agent, a
second reviewer and extra time.

## 2. Package overview and order

```text
Wave 0  (parallel)        P0-00  T-0  J-00a
Wave 1  (serial, 1 agent) P0-01 → P0-02 → P0-03 → P0-04
Wave 2  (parallel ×4)     P0-05a  P0-05b  P0-05c  P0-05d            then J-00b may start
Wave 3  (serial)          P0-06
Wave 4  (parallel ≤6)     P0-07 … P0-18
Wave 5  (serial)          P0-19   ← Phase 0 gate
Wave 6  (parallel)        J-01  J-03
Wave 7  (parallel)        J-02  J-05          (J-04 after J-02)
Wave 8  (parallel ≤6)     J-04  J-06  J-07  J-08a  J-09  J-10  J-11  J-12
Wave 9  (parallel)        J-08b  J-13
Wave 10 (serial)          J-14  ← parity gate
```

| ID | Package | Size | Risk | Depends on |
| --- | --- | --- | --- | --- |
| P0-00 | Baseline harness and golden fixtures | M | | — |
| T-0 | Demo-server test data | ops | | — |
| J-00a | Jellyfin client and DTOs | L | | — |
| P0-01 | Type rename sweep, `Models/` → `Domain/` | L mech. | | P0-00 |
| P0-02 | Identity sweep: `itemID`, string ids | L mech. | R | P0-01 |
| P0-03 | Field vocabulary, `ExternalIDs`, kinds | L mech. | | P0-02 |
| P0-04 | `ArtworkRef` sweep | M | | P0-03 |
| P0-05a–d | DTO split by model family | L total | R | P0-04 |
| J-00b | Jellyfin mappers and contract tests | L | | P0-05, J-00a |
| P0-06 | Service skeleton: `MediaService`, provider protocols, `PlexClient` | L | R | P0-05 |
| P0-07 | Catalog facet | L | | P0-06 |
| P0-08 | Images facet | S | | P0-06 |
| P0-09 | Playback stream facet | XL | R | P0-06 |
| P0-10 | User data, reporting, offline sync | M | | P0-06 |
| P0-11 | Markers and scrub previews | S | | P0-06 |
| P0-12 | Home rows | M | R | P0-06 |
| P0-13 | Playlists | S | | P0-06 |
| P0-14 | Live TV facet | M | | P0-06 |
| P0-15 | Downloads facet and storage tags | L | R | P0-06 |
| P0-16 | Accounts, sign-in host, profiles, pool | L | R | P0-06 |
| P0-17 | Account features: order, hidden, watchlist, languages | M | | P0-06 |
| P0-18 | Peripherals: Seerr, Trakt, Top Shelf, Siri, SharePlay, analytics | M | | P0-06 |
| P0-19 | Boundary check, fake provider, docs, gate | M | | P0-07 … P0-18 |
| J-01 | Sign-in, account, session, profiles | L | R | P0-19, J-00a |
| J-03 | Images | S | | P0-19, J-00b |
| J-02 | Catalog and browse | L | | J-01, J-00b |
| J-05 | Playback I: direct play, reports, markers, previews, sidecars | L | | J-01, J-00b |
| J-04 | Home rows and library hubs | M | | J-02 |
| J-06 | Playback II: server streams, HDR/DV/Atmos, quality | XL | R | J-05 |
| J-07 | Playlists, collections, watchlist | M | | J-02 |
| J-08a | Downloads: original, sidecars, offline | L | | J-05 |
| J-09 | Live TV | L | R | J-05, T-0 |
| J-10 | Photos | M | | J-02 |
| J-11 | Account preferences, subtitle search, pre-rolls | M | | J-02 |
| J-12 | Integrations | M | | J-02 |
| J-08b | Downloads: converted quality | L | R | J-06, J-08a |
| J-13 | Several accounts, mixed Plex + Jellyfin | L | R | J-04, J-07, J-11 |
| J-14 | Parity audit, mock, docs | M | | all |

## 3. The Phase 0 gate

"Zero behaviour change" is checked the same way after **every** Phase 0
package and once more, in full, in P0-19. P0-00 builds the tools and records
the baseline from the commit before P0-01.

| Check | What it compares | Tool |
| --- | --- | --- |
| G1 Unit tests | all suites green; the number of test cases is not lower than the baseline; assertions may be renamed, not weakened | `scripts/test_units.py` |
| G2 Request log | for each scripted screen, the multiset of `METHOD path?sorted-query` (tokens, session ids and timestamps stripped) equals the baseline | `scripts/parity/requests.sh` against `scripts/mock_large_plex.py`, which already logs every request |
| G3 Pixels | screenshots of the same scripted screens on iPhone, iPad and Apple TV simulators match the baseline within a small per-pixel tolerance | `scripts/parity/screens.sh` (screenshot-mode launch arguments + `simctl io screenshot`) |
| G4 Persisted data | a container captured from the baseline build (downloads, metadata cache, pins, remembered tracks, offline sync file, server priority) loads in the new build and decodes to the same values | unit test over `DuskTests/Fixtures/LegacyContainer/` |
| G5 Golden strings | profile scope id, `storageKey`, `globalKey`, metadata cache hash input, `ShowTrackPreferences` key, deep-link and Siri id forms equal captured values | unit tests |
| G6 plex-demo smoke | as `duskcompare` through a logging read-mostly proxy: restore session, Home, a movie grid with sort + filter + A–Z jump, movie detail, show → season → episode, search, direct play 20 s, one Atmos/HDR remux title 20 s, a manual quality switch, mark watched and back, download one episode and play it offline. Request log and screenshots compared with the baseline run | `scripts/parity/smoke_plex.sh` |
| G7 Boundary | no provider names outside `Providers/` and the sign-in flow (from P0-19 on) | `scripts/check_provider_boundary.sh` |

G1, G4, G5 and the compile builds run for every package. G2 and G3 run for
every package that touches a feature or service file. G6 runs after waves 1,
3 and 4 and in P0-19. A difference is a bug in the package, never an
"improvement" to keep.

Screens scripted for G2/G3 (all exist as `-DuskScreenshotScreen` routes or are
added by P0-00): home, movies, shows, library grid, collections, collection
detail, movie detail, show detail, season, episode, search with a query,
playlists, photos, settings root, server priority, downloads (empty).

## 4. Phase 0 packages

### P0-00 Baseline harness and golden fixtures — M

- **Scope.** The gate tools in §3; the legacy container fixture; golden-string
  tests; `Codable` round-trip tests for every persisted type in 01 §20 written
  against **today's** type names, so the sweeps have to keep them green.
- **Files.** new `scripts/parity/*`, new tests under `DuskTests/`,
  `DuskTests/Fixtures/`, missing screenshot routes in
  `App/ScreenshotMode.swift` (additive).
- **Parallel with** T-0, J-00a.
- **Accept.** Two consecutive baseline runs of G2/G3 on an unchanged tree
  produce no difference (the harness is deterministic); the baseline is
  committed.

### P0-01 Type rename sweep — L mech.

- **Scope.** Rename types per 04 §4.1 and move `Models/` to `Domain/`. Type
  names only; no field, no logic. Shared UI files named `PlexItem*` are
  renamed too. `Plex*` types that stay Plex (`PlexPin`, transport, client
  identity) are left alone.
- **How.** A checked-in script, `scripts/refactor/01_types.sh` (word-boundary
  replacements from a table + `git mv` + `xcodegen generate`). **The script is
  the deliverable**: when `main` moves, the sweep is re-run instead of
  hand-merged. Same for P0-02 … P0-04.
- **Files.** ~190 files, mechanically.
- **Serial.** The sweep train (P0-01 … P0-04) is one agent, one package at a
  time, merged within hours of starting. The coordinator announces the window
  so other agents rebase right after.
- **Accept.** G1 – G5; diff contains no change outside identifiers, file
  paths and the project file.

### P0-02 Identity sweep — L mech., R

- **Scope.** `MediaItemID.itemID` (Codable key stays `ratingKey`); field
  renames `ratingKey` / `parentRatingKey` / `grandparentRatingKey` /
  `librarySectionID`; version, part, stream and marker ids become `String`;
  every `Int(ratingKey)` and numeric-id assumption removed;
  `ServerRegistry` added with "no record = Plex".
- **Files.** 60 files for `ratingKey` (796 occurrences), `Playback/`,
  `Features/Player/`, `Downloads/DownloadModels.swift`.
- **Why risky.** Integer ids are compared, sorted and persisted
  (`externalSubtitlePaths`, `mediaID`, `partID`, the estimated-credits `-1`).
  Decoders must accept Int or String.
- **Accept.** G1 – G5, G6; new tests decode old Int-keyed records.

### P0-03 Field vocabulary, `ExternalIDs`, kinds — L mech.

- **Scope.** Remaining renames in 04 §4.2 (`resumeOffsetMs`, `playCount`,
  `lastPlayedAt`, `episodeCount`, `watchedEpisodeCount`, stream `kind`,
  `dolbyVision`, `isServerSelected`); `ExternalIDs` accessor replacing
  `PlexGuid.value(for:)` at its call sites (Trakt, Seerr, merge, movie
  copies); `ContentKey` with `.native` and `contentAliases` (canonicalisation
  present, inert for a single provider).
- **Accept.** G1 – G5; `TraktMappingTests`, `MovieLibraryMergeTests`,
  `TVLibraryMergeTests`, `PlexEditionTests` unchanged in meaning.

### P0-04 `ArtworkRef` sweep — M

- **Scope.** `ArtworkRef`, `ArtworkSet`, `ImageSize`; the 64 image call sites
  in 29 files pass refs instead of path + server id; fallback helpers move
  onto `ArtworkSet`; `imageServerConnection(for: URL)` removed.
- **Files.** `Domain/`, `Shared/DuskAsyncImage.swift`,
  `Shared/MediaItemPresentation.swift`, the 29 call-site files,
  `PlexService+Images.swift`.
- **Accept.** G1 – G5; G2 shows identical image URLs; `EpisodePosterArtworkTests`,
  `SeasonBackdropTests` green.

### P0-05a–d DTO split — L total, R

Four parallel packages, one per model family. Each moves `init(from:)` and
`CodingKeys` into `Providers/Plex/DTO/`, adds a mapper, and gives the domain
type a memberwise initialiser. Decode call sites in the service change from
"decode domain" to "decode DTO, map".

| ID | Family | Owns |
| --- | --- | --- |
| P0-05a | item, details, episode, season, library, hub, search, tags, people | `Domain/MediaItem.swift`, `MediaDetails`, `Episode`, `Season`, `Library`, `HomeRow`, `SearchSection`; `PlexService+Library`, `+People` decode sites |
| P0-05b | version, part, stream, marker, ratings | `Domain/MediaVersion*`, `Marker`, `Rating`; `PlexService+Playback` decision decoding |
| P0-05c | Live TV and devices | `Domain/Live*`; `PlexService+LiveTV`; `IPTVService/IPTVLineupBuilder.swift` (uses the memberwise initialisers) |
| P0-05d | playlists, collections, extras, photos, watchlist, pinned sources, managed hubs, subtitle search, history | the matching `Domain/` files and `PlexService+*` files |

- **Why risky.** The offline metadata cache and `convertedMediaData` decode
  these shapes from disk; tests build models from JSON literals. The server id
  stamp moves from `CodingUserInfoKey` to the mapper.
- **Accept.** G1 – G6. Decoding tests (`PlexMediaPartDecodingTests`,
  `PlexLiveTuneDecodingTests`, `PlexExtrasTests`, …) now target the DTOs and
  assert the mapped value. Cut from the same commit, merged in any order.

### P0-06 Service skeleton — L, R

- **Scope.**
  - `plexService` → `media`, `PlexService` → `MediaService` (scripted).
  - `Providers/Core/`: every protocol and request type from 04 §3 and §12 as
    declarations, `ProviderRegistry`, `ProviderKind`, `ServerPermissions`,
    `PlaybackTraits`, `CredentialTransportPolicy`.
  - `PlexClient` (request core, headers, sessions, decode helpers) extracted
    from `+Networking`; `PlexServerProvider` and `PlexAccountProvider` created
    as shells that own it.
  - `ServerSession` replaces `PlexServerConnection`; the pool stores the
    provider on the session.
  - **Pure file moves that unblock wave 4**: `PlexService+Playback.swift`
    split into `+Streams.swift` and `+WatchState.swift`; folder moves to
    `MediaService/` and `Providers/Plex/` per 04 §2.
- **Files.** `PlexService/*` (moved), `App/DuskApp.swift`, every file for the
  receiver rename.
- **Why risky.** Touches request routing, token refresh and self-healing for
  every call.
- **Accept.** G1 – G6; after this package each wave-4 package owns a disjoint
  set of files.

### Wave 4: facet extraction

Each package does the same three things for its area: fill in the facet
protocol, move the Plex implementation into `Providers/Plex/Plex<Facet>.swift`
behind it, and turn the facade methods into routes. P0-06 created both files
of every facet, one facet per file (table below), so no two packages share a
facet file. The DTO and mapper files from P0-05 are mapped further down; one
of them is shared. Feature files change only
where a Plex concept leaked into them (listed per package). All accept on
G1 – G5 plus G2/G3; those marked ◆ also on G6.

| ID | Area | Owns (beyond its new `Providers/` files) | Notes |
| --- | --- | --- | --- |
| P0-07 L | Catalog | `MediaService+Library`, `+Collections`, `+People`, `+Extras`, `+Photos`, `+Ratings`, search; `Features/Libraries/LibraryItemsViewModel.swift` (`plexKey` → provider mapping), `LibraryFilters*`, `LibraryLetterIndex*` | `LibrarySort` / `LibraryFilter` / `FilterCatalog` / `SortCatalog` become neutral; Plex returns today's lists. Photo timeline grouping moves to the client here (the one allowed internal change; G3 must still match) |
| P0-08 S | Images | `MediaService+Images` | provider resolves `ArtworkRef`; IPTV image provider |
| P0-09 XL R ◆ | Playback streams | `MediaService+Streams`, `+RemotePlayback`, `+PlayQueue`, `+Subtitles` (sidecar URL only; nobody else edits the file); `Features/Player/PlaybackCoordinator+Session.swift`, `+SpatialAudio`, `+ServerTracks`, `+Prerolls`, `PlaybackSourceResolver`, `PlaybackPresentationModels.swift`; `Playback/RemuxHLSLoader.swift`, `PlaybackEngineFactory`, both engines' credential validation; `Providers/Plex/PlexTransportSecurity.swift` | `TranscodeDeliveryMode` → `StreamIntent`; decisions → `StreamDecisions`; `confirm` hook wired (no-op for Plex); loader takes `PlaybackTraits`. Existing `HDRVideoRemuxTests`, `PlaybackFallbackTests`, `TrueHDAudioRoutingTests`, `AV1RoutingTests`, `HEV1RoutingTests`, `DolbyVision7*` must pass untouched in meaning. G6 additionally plays the DV 7 and TrueHD titles |
| P0-10 M ◆ | User data | `MediaService+WatchState`, `Shared/MediaService+WatchedFanOut.swift`, `Features/Player/PlaybackCoordinator+Timeline.swift`, `Downloads/OfflinePlaybackSync*` | `PlaybackReport`; 90 % rule stays in the coordinator behind the trait |
| P0-11 S | Markers, previews | `Features/Player/PlayerViewModel+Presentation.swift` (marker ids), scrub preview loading in `PlayerView.swift` | `ScrubPreviewSource` protocol; BIF implementation |
| P0-12 M R | Home rows | `MediaService+HomeRows`, `+Hubs` (hub fetching, split out of `+Library` in P0-06; `search` there still calls its `fetchHomeRows`); `Features/Home/HomeHubFilter.swift`, `HomeHubArrangement.swift`, `HomeViewModel.swift`; `MultiServer/HubMerge.swift` | string heuristics move verbatim into the Plex mapper; add fixture tests from captured `/hubs` payloads **before** moving them |
| P0-13 S | Playlists | `MediaService+Playlists`, `PlaylistStore` | library-URI building becomes Plex-private |
| P0-14 M | Live TV | `MediaService+LiveTV`, `Features/LiveTV/LiveTVViewModel.swift`, `LiveTVView.swift`; `LivePlaybackContext` in `Domain/LiveTV.swift`; the Live TV / IPTV section of `Features/Player/PlaybackCoordinator.swift`, `PlaybackCoordinator+IPTVResume.swift` | channel matcher and device sections become Plex-private; `isIPTV` routing branches removed |
| P0-15 L R ◆ | Downloads | `MediaService+Downloads`, `Downloads/DownloadManager.swift`, `DownloadModels.swift`, `PlexDownloadQueue.swift` (moves to `Providers/Plex`), `PlexMetadataCache.swift` → `MetadataSnapshotCache.swift` | `MetadataSnapshotKey` must hash to today's file names; `provider` tag added; G4 is the main check |
| P0-16 L R ◆ | Accounts | `MediaService.swift`, `+Auth`, `+Home` (profiles), `+Servers`, `ServerPool.swift`, `ServerProbe.swift`, `ServerSession.swift`, the provider files below, `App/ContentView.swift`, `App/ServerConnectionCoordinator.swift`, `Features/Account/*`, `Features/Settings/ServerPriority*`, `ConnectionDiagnosticsView.swift` | `AccountStore`, `StoredAccount` read from the existing Keychain accounts, `SessionState`, `SignInFlow` host with the Plex flow as its only entry, neutral `Profile`. The only package allowed to edit `MediaService.swift` |
| P0-17 M | Account features | `MediaService+LibraryOrder`, `+LanguageDefaults`, `+Watchlist`, `LibraryOrderStore`, `HiddenLibraryFilter`, `WatchlistStore`, the matching settings view models | `AccountPreferencesProviding`, `WatchlistProviding` |
| P0-18 M | Peripherals | `SeerrService/*` (`SeerrAuthProviding`), `TraktService/TraktHistoryMapper.swift`, `TopShelf/*`, `Siri/*`, `Features/Player/DuskWatchTogetherActivity.swift`, `Analytics/*` (wording only) | frozen identifiers per 04 §18; no analytics property yet |

Facet files (each created by P0-06 as an empty protocol and an empty Plex
value that `PlexServerProvider` / `PlexAccountProvider` return):

| Package | `Providers/Core/` | `Providers/Plex/` |
| --- | --- | --- |
| P0-07 | `CatalogProviding`, `UserRatingProviding` | `PlexCatalog`, `PlexUserRating` |
| P0-08 | `ImageProviding` | `PlexImages` |
| P0-09 | `PlaybackProviding` (with the §12 request types), `PlaybackTraits`, `CredentialTransportPolicy` | `PlexPlayback` |
| P0-10 | `UserDataProviding` (with `PlaybackReport`) | `PlexUserData` |
| P0-11 | `MarkerProviding` (with `ScrubPreviewSource`) | `PlexMarkers` |
| P0-12 | `HomeProviding` | `PlexHomeRows` |
| P0-13 | `PlaylistProviding` | `PlexPlaylists` |
| P0-14 | `LiveTVProviding` | `PlexLiveTV` |
| P0-15 | `DownloadProviding` | `PlexDownloads` |
| P0-16 | `MediaServerProvider`, `MediaAccountProvider`, `ProviderRegistry`, `ServerPermissions`, `ProfileProviding`, `SignInFlow` | `PlexServerProvider`, `PlexAccountProvider`, `PlexProviderFactory`, `PlexProfiles`, `PlexClient` |
| P0-17 | `AccountPreferencesProviding`, `WatchlistProviding` | `PlexAccountPreferences`, `PlexWatchlist` |
| P0-18 | `SeerrAuthProviding` | `PlexSeerrAuth` |
| none yet | `SubtitleSearchProviding` | `PlexSubtitleSearch` |

P0-16 also adds what P0-06 left out of the provider protocols because it needs
the account layer: `MediaServerProvider.permissions`, `MediaAccountProvider`'s
`account`, `servers()`, `probe(_:)` and `signOut()`, and `ProviderFactory`'s
`makeSignInFlow()` and `restoreAccount(from:)`.

DTOs and mappers (P0-05): each DTO file belongs to the package of its family:
`PlexItemDTO`, `PlexMediaDetailsDTO`, `PlexSeasonEpisodeDTO`, `PlexLibraryDTO`,
`PlexExtraDTO`, `PlexPhotoDTO`, `PlexRatingDTO` → P0-07; `PlexHubDTO`,
`PlexManagedHubDTO` → P0-12; `PlexMediaVersionDTO`, `PlexTranscodeDecisionDTO`
→ P0-09; `PlexMarkerDTO` → P0-11; `PlexPlaylistDTO` → P0-13; `PlexLiveTVDTO` →
P0-14; `PlexWatchlistDTO` → P0-17; `PlexSubtitleSearchDTO`,
`PlexPlaybackHistoryDTO` → none yet. Mappers: `PlexItemMapper` → P0-07,
`PlexMediaVersionMapper` and `PlexTranscodeDecisionMapper` → P0-09,
`PlexLiveTVMapper` → P0-14. `PlexItemDecodingBridge` is edited by nobody: each
package switches its own remaining direct decodes to the DTOs, and the bridge
is deleted once none is left.

Shared files P0-06 could not split without changing code:

- `Mappers/PlexUserContentMapper.swift` maps playlists (P0-13), extras and
  photos (P0-07), watchlist (P0-17), managed hubs (P0-12), subtitle search and
  history. A package edits only its own `MARK` section, or moves that section
  into a `Mappers/Plex<Area>Mapper.swift` of its own.
- `PlexItemMapper.map(_: PlexHubDTO, …)` is P0-12's hub mapping inside
  P0-07's file. P0-12 moves it into its own `Mappers/PlexHubMapper.swift`
  (together with the hub heuristics) and touches nothing else in the file.
- `Features/Player/PlaybackCoordinator.swift` holds the stored state of every
  coordinator extension (Swift extensions cannot), next to P0-14's Live TV /
  IPTV section. A package that needs new coordinator state adds only its
  stored properties there.

Owned by no wave-4 package: `MediaService+Networking` (routing and
self-healing), `+History`, `MultiServer/MediaService+MultiServer.swift` (its
hub and search streams call the facade methods P0-07 and P0-12 route, so it
should not need an edit), `+MovieCopies`, `Shared/MediaService+ServerIdentity.swift`,
`PlaybackCoordinator+AudioOffset`, `+ShowTracks`, `+UpNext`.

Overlap to watch: P0-09 and P0-10 both read the coordinator's session state
(different files; the shared type `PlaybackAttemptContext` belongs to P0-09).
P0-12 and P0-17 both touch Home's watchlist placement (P0-17 owns
`HomeWatchlist*`). P0-15 and P0-10 share `OfflinePlaybackSyncManager`
(P0-10 owns it). P0-14's "`isIPTV` routing branches removed" includes the
timeline guard in `PlaybackCoordinator+Timeline.swift`, which is P0-10's file:
P0-10 removes it when it routes reports (an IPTV session has no user-data
provider).

### P0-19 Boundary, fake provider, docs, gate — M

- **Scope.** `scripts/check_provider_boundary.sh` and fixing what it finds;
  `FakeMediaServerProvider` in the test target with two example view-model
  tests; rewrite the three overturned rules (`AGENTS.md`,
  `docs/codebase-map.md`, `docs/playback.md`) and `docs/data-and-plex.md` →
  provider layering; full §3 gate.
- **Accept.** G1 – G7 on iOS, tvOS and macOS. Tag `provider-abstraction-done`.
- **As built (2026-11-28).** Done: routing and self-healing moved verbatim into
  `PlexServerRouter`, which asks the pool through `SessionRecovering`; every
  facet route goes to `serverProvider(for:)`; one plex.tv path
  (`PlexAccountProvider.plexTVData`); Settings and Mac read `profiles` /
  `activeProfile`; `permissions` are live and replace the two ownership
  checks; neutral names by `scripts/refactor/19_boundary.sh`
  (`MediaServiceError` keeps the reported domain `Dusk.PlexServiceError`);
  `TransportSecurity` for generic credential checks; Plex-only facade glue in
  `Providers/Plex/Facade/`; G7 enforced on the 04 §5.4 pattern with the
  exceptions in `provider_boundary_allowlist.txt`; `FakeMediaServerProvider`
  and two view-model tests; the three rules rewritten. Still open, for the J
  packages that need them: the feature callers that pass Plex sort strings
  and `/filters` parameters (recommendation engines, Siri, video shelves,
  `VideoDetailViewModel`, `LibraryGenreSupport`) through the raw routes in
  `+PlexFacets`; the `+PlexFacets` routes themselves (live-stream consumers,
  image forwarders) as facet members; the row-string parsing in
  `MediaItemMerge` / `LibraryRecommendationsViewModel` /
  `HomeWatchlistPlacement`; `removeFromContinueWatching` on `HomeProviding`;
  the download quality menus; `metadataSnapshotFormat` on `ProviderFactory`;
  the probe and candidate list moving into the account provider (04 §7.1);
  `PlexItemDecodingBridge`; captured `/hubs` fixtures. The list below is the
  wave-4 input this note answers.
- **Left by wave 4** (merged together with J-00b; the package reports were the
  source). Most of these are what the boundary check will flag:
  - **Routing.** Every server facet is still built by the facade, with the
    facade as its transport. The facets are `PlexServerTransport` (catalog,
    rating, home, playlists, user data) and `PlexLiveTVTransport` (refines
    it); playback, markers and the account preferences use their own
    `PlexPlaybackRouting`, `PlexMarkersTransport` and `PlexAccountTransport`.
    A provider's own facets have no transport and refuse to send. The open
    design step is a routed send on `PlexClient` or the provider (04 §8),
    after which the facade routes through `session.provider`.
  - **The plex.tv request exists twice.** One copy is
    `MediaService+Networking.rawPlexTVRequest`, the other is
    `PlexAccountProvider.plexTVData`. The facade's copy also sends the JSON
    body and timeout that the library-order write needs.
  - **Account readers.** The Settings views (iOS, tvOS, container) and
    `MacRootView`, `MacSettingsView`, `MacCommands` and
    `MacScreenshotRouting` still read `homeUsers`, `activeHomeUser`,
    `hasPlexHome` and `PlexHomeUserAvatar`. They should switch to
    `profiles` / `activeProfile` / `ProfileAvatar`, and then the shims can
    be removed. `+HomeRows` and `+Subtitles` should read the provider's
    `permissions` instead of checking ownership themselves. A provider's
    `permissions` is a snapshot from when its session was built.
  - **Plex shapes left in neutral code:**
    - Plex sort and filter strings are still passed by the recommendation
      engines, Siri (`SiriTitleCatalog`), the video shelf loader,
      `VideoDetailViewModel` and `LibraryGenreSupport`.
    - Plex wrappers kept for old callers: `CollectionDetailViewModel` uses
      `plexValue`, and `PlexPhotoQuery` is a typealias.
    - `MediaItemMerge`, `LibraryRecommendationsViewModel` and
      `HomeWatchlistPlacement` parse the row strings instead of reading
      `HomeRow.kind` / `mergeKey`.
    - `removeFromContinueWatching` is in `+WatchState`; it belongs on
      `HomeProviding`.
    - The download quality menus (`DownloadActionButton`, `MacUIItemMenu`)
      use `DownloadQuality.allCases` instead of
      `media.downloadQualities(for:)`.
    - `ProviderFactory` has no `metadataSnapshotFormat` yet, so the code
      reaches it with an `as?` cast.
    - The Seerr token isn't on `PlexAccountProvider.seerrAuth` yet.
    - `MainTabView`'s screenshot live channel builds the lineup directly.
  - **Plex names that are still referenced:**
    - `PlexTransportSecurity` in the remux relay, the DV 7 proxy,
      `SubtitleTextDecoder`, `PlaybackError`, downloads and `SeerrService`.
    - `PlexScrubPreviewSource` / `Frame`, cast in `PlayerView` and
      `MacPlayerView`.
    - The Domain types `PlexLibraryFilter`, `PlexPerson`, `PlexManagedHub`,
      `PlexHubSource`, `PlexPlaylistAddResult` and `PlexHomeHubSetting`.
    - The `PlexMetadataCache` alias, which the tests still use.
    - The `+Images` forwarders `transcodeSourceURLString` and
      `imageRequestURLString`, and the `PlexImages` fallback.
    - Exemptions the script must allow: `PlexTitleEntity` and
      `PlexTitleEntityQuery` (frozen App Intents ids).
  - **Kept on purpose:** P0-10 kept the `isIPTV` timeline guard. Without it,
    an IPTV session's nil server id would report to the primary Plex server.
  - **Still to come:**
    - `PlexItemDecodingBridge` still has callers (`HomeRow` decoding among
      them), and its header comment is stale.
    - P0-12's `/hubs` fixtures are hand-written; real plex-demo captures
      should be added.
    - P0-09 departs from 04 §12.1, and its confirm hook only logs (see its
      report). J-05 and J-06 read this.
    - J-00b's Domain gaps (`Person.id`, rating sources, artwork slots) belong
      to the J packages.

## 5. Phase J packages

Every J package accepts on: compile builds; its own unit tests on fixtures;
**G1 – G6 still green** (Plex untouched); and its row of the side-by-side
matrix (§6) against `plex-demo` and `jellyfin-demo` as `duskcompare`.

### J-00a Jellyfin client and DTOs — L (wave 0)

- **Scope.** `JellyfinClient` (the one `Authorization: MediaBrowser` form,
  percent-encoded values, `userId` injection, result-shape validation because
  unknown parameters return `200`), tolerant date and tick decoding, errors,
  DTOs for every response in 02, a fixture recorder
  (`scripts/jellyfin/record_fixtures.sh`) and the recorded fixtures.
- **Files.** new, under `Providers/Jellyfin/` and `DuskTests/Fixtures/Jellyfin/`.
  No existing file is touched, so it runs during Phase 0.
- **Accept.** DTO decoding tests over fixtures for the 12 torture files in 03
  §5.1; auth-header tests for the cases in 03 §10.1.

### J-00b Mappers and contract tests — L

- **Scope.** DTO → domain mappers (codec alias table, per-kind stream
  positions, `isServerSelected` from default indexes, `ArtworkSet` from image
  tags, `ExternalIDs`, ratings, date rounding); the provider contract suite
  (04 §5.5) run for both providers.
- **Accept.** For `Knives Out`, `Dune: Part Two`, `The Office S01E01`: same
  stream kinds and canonical codecs, duration within 1 s, same external ids
  and numbering from both servers' fixtures; the external-subtitle index trap
  (02 §9) has a test.

### J-01 Sign-in, account, session, profiles — L, R

- **Scope.** Jellyfin `SignInFlow` (address → Quick Connect / password, tvOS
  code screen shared with Plex), address normalisation, `StoredAccount` +
  `DeviceId`, `JellyfinAccountProvider`, candidates (typed URL +
  `LocalAddress`) and probe, `ServerPermissions` from `Policy`, Switch User
  (saved accounts + `/Users/Public`), sign-out, capabilities post.
- **Files.** `Providers/Jellyfin/Account/*`, `Features/Account/SignIn*`
  (host gets its second entry), profile picker feed.
- **Why risky.** First real exercise of the account abstraction; token and
  `DeviceId` semantics (03 §10.2); tvOS focus on a new screen.
- **Accept.** Sign in by Quick Connect and by password on iOS and tvOS
  simulators; relaunch restores the session; two saved users switch without
  logging each other out; wrong address and wrong password show the existing
  error presentation; an existing Plex install upgraded to this build is
  still signed in (G4).
- **As built (2026-11-28).**
  - Sign-in host: Plex's welcome screen gains "Sign in with Jellyfin" under
    Plex's own button. Jellyfin asks for the address, then password, or a
    Quick Connect code. Apple TV opens on the code when the server has Quick
    Connect on. The tvOS code screen is shared (`SignInCodeScreen`).
  - Accounts: `JellyfinAccountProvider` keeps every saved user, each with its
    own random `DeviceId`. Records live in new keys only (`JellyfinAccounts`,
    `JellyfinActiveAccountID`, Keychain `JellyfinAccessToken.<id>`).
  - The facade reads a non-Plex primary through `AccountSession`
    (`MediaService.accountSession`). The pool connects that account's one
    server with the account's probe. A server id finds its provider through
    the accounts that hold it (`ProviderFactory.ownsServer`), so no registry
    is persisted.
  - Switch User lists the saved users plus `/Users/Public`. An unsaved user
    asks for a password. Saved users switch without a logout. Sign-out logs
    every saved user out.
  - Settings shows "Users" and drops the Plex-only rows (Automatically Sign
    In, Manage/Delete Plex Account).
  - Images are J-03's `JellyfinImages`. Every other facet is a placeholder that
    answers empty (`Providers/Jellyfin/Facets/`, one file per facet for J-02 …
    J-08a).
  - `PlexServerRouter.requirePlex` keeps not-yet-routed Plex routes off a
    Jellyfin server. `getCurrentUser` makes no plex.tv call while no Plex
    account is signed in.
  - Verified against jellyfin-demo:
    - iPhone and Apple TV: password sign-in, wrong address, wrong password
      and cold-relaunch restore.
    - Apple TV: Quick Connect sign-in, the picker listing the public users,
      and sign-out with logout.
    - Two DeviceIds of the same user held at once.
    - A logging proxy in front of the server saw only Jellyfin routes, each
      with the `MediaBrowser` header and no `X-Plex` header, through
      sign-in and a cold relaunch.
  - Not verified live: switching between two *saved* users. Only
    `duskcompare`'s password was cleared for use, so this is covered by
    unit tests only.
  - Open (the bare-host `http://host` candidate, the Connection Diagnostics
    "server address" label and the iOS tagline "Sign in to get started."
    landed with J-02):
    - Library order is read-only (`notImplemented` on save, J-11).
    - Seerr has no Jellyfin sign-in yet (J-12).

### J-03 Images — S

`JellyfinImageProvider`: locator parsing, `fit` / `fill`, tag-keyed cache
keys, person and chapter images. **Accept:** matrix rows "posters",
"episode stills", "hero art + logo" look the same on both servers.

- **As built (2026-11-28).** `Providers/Jellyfin/JellyfinImages.swift`, no
  stored state. `ImageSize` stayed without a `mode`: every call site passes a
  box, and `fill*` already gives Plex's cover-without-crop pixels (measured:
  poster, still, backdrop and logo dimensions match plex-demo at the same
  boxes). Chapters use `max*`, the only fit case. `JellyfinServerProvider`
  (J-01) returns it. Open: nothing maps or shows chapter images yet; a `jf:` ref whose server is not connected falls
  through to `PlexImages` and yields an unloadable `jf:` URL (placeholder).

### J-02 Catalog and browse — L

- **Scope.** Libraries (incl. `homevideos` classification), items with sort
  and filter mapping, `FilterCatalog` (incl. decade, director/actor,
  collection, resolution), exact letter table, details, seasons, episodes,
  people, extras, trailers, search sections, `items(matching:)`,
  `playbackHistory`.
- **Accept.** Matrix rows for library grid, sort, each offered filter, A–Z
  jump (lands on the same first title as Plex for the shared libraries),
  movie / show / season / episode / person pages, search. Unit tests assert on
  **results**, not status codes.
- **As built (2026-11-28).**
  - `Providers/Jellyfin/Facets/JellyfinCatalog.swift` plus
    `JellyfinBrowseVocabulary` (sorts, filters, A–Z as pure functions). Full
    mapping in `docs/data-and-plex.md` → Library, Search, Hubs, And Detail
    Endpoints.
  - New catalog members, each Plex's request moved over unchanged:
    `genreChoices` (the genre menu, which used to read raw `/filters`),
    `items(matching:kind:title:year:)` (watchlist's `serverItems`) and
    `playbackHistory` (`getPlaybackHistory`). The libraries list's empty
    check uses the neutral count. `getLibraryFilters` and
    `getLibraryFilterValues` are gone.
  - `homevideos` is classified by its photo and video counts. A view that
    holds both appears once, as whichever it holds more of.
  - Trailers: a local trailer is an extra and plays. A web-only one opens
    outside the app on iOS and macOS (`MediaDetails.remoteTrailerURL`) and is
    hidden on tvOS. The `canOpenURL` variant needs the YouTube app on a
    device, so it is not built.
  - The Rate button is hidden when the server has no rating facet
    (`MediaService.canRate`).
  - Verified against jellyfin-demo, on iPhone and Apple TV simulators
    (`~/dusk-qa/jellyfin/J-02/`) and in `JellyfinCatalogLiveTests`, which
    asserts on titles:
    - grid, sort, Filters sheet, collection filter (Weekend Watch → Big Buck
      Bunny, Sintel), director, genre and resolution filters;
    - A–Z on Paging Test (520), where each offset lands on its letter;
    - movie with extras and the trailer button, web trailer (Knives Out);
    - show → seasons → episodes, episode page, person page (Steve Carell);
    - search, the Videos grid.
  - A–Z against plex-demo's `/firstCharacter` offsets: Real Movies and Real
    TV land on the same first titles. On Paging Test 24 of 27 buckets start
    on the same title. `#`, L and R differ because the servers make sort
    names differently (Plex keeps `[`, `&` and a lower-case "the"). The
    Movies libraries hold differently named test files, so they cannot be
    compared.
  - Open:
    - Library Recommended tabs and Home are empty until J-04.
    - Collections chip, grid and page are J-07.
    - Hidden libraries are J-11: Jellyfin list items carry no library id,
      so search results are not filtered by them yet.

### J-05 Playback I — L

- **Scope.** Direct play URL on both engines, `PlaybackReport` mapping,
  server-side watched threshold trait, explicit watched/unwatched, markers
  from `/MediaSegments`, trickplay `ScrubPreviewSource`, sidecar subtitles,
  engine track mapping by per-kind position, Up Next / next episode, resume.
- **Accept.** Matrix rows: play MP4 (AVPlayer) and MKV (VLCKit), resume from
  Continue Watching, Skip Intro / Skip Credits on `The Office S01E01`, scrub
  previews on a trickplay title and the generated fallback on another, switch
  audio and subtitle tracks, sidecar SRT. The server dashboard shows the
  session; stopping at 95 % marks played once (`PlayCount` +1, not +2).
- **As built (2026-11-28).**
  - Direct play: `JellyfinPlayback.directPlayURL` is
    `/Videos/{id}/stream?static=true&mediaSourceId=…&ApiKey=…` on both engines,
    checked by `JellyfinCredentialPolicy` (`ApiKey` / `Token=`, Plex's rules).
    `openServerStream` still throws (J-06), so a remux-eligible file falls
    through to direct play; the Quality menu is visible and fails until J-06.
  - Details: `JellyfinItemDetails` loads `/Items/{id}` and `/MediaSegments`
    in parallel and puts the markers on `MediaDetails`. `JellyfinCatalog.details`
    calls it (one line for J-02 to keep). Recap / Preview / Commercial are
    mapped, never shown.
  - Reports: `JellyfinPlaybackSessions` opens a session once (measured: every
    `/Sessions/Playing` is a play, even with the same `PlaySessionId`), then
    `/Progress` and `/Stopped`. The coordinator now fills the report's version,
    play method and the viewer's own track picks (Plex ignores them). Automatic
    picks are not reported, because the server remembers reported tracks: the
    shared pre-start pick chose a commentary track on S01E01 (see Open).
    `setWatched` is `/UserPlayedItems`.
  - Scrub previews: trickplay sheets fetched whole and cut into a
    `ScrubPreviewFrameSet` (not lazy as 04 §12.6 says: the player controls
    read the frame set synchronously, so no player view changed). The
    "generated fallback" in Accept no longer exists (f450da82, for Plex too).
  - Sidecars: own format per track (PGS as `sup`); external VobSub has no
    servable file and is not offered.
  - Track mapping: the existing positional matcher already works (tests on
    Knives Out and the external-at-index-0 file).
  - DEBUG: `-DuskDebugPlayItem <id>` plays an item without browse screens;
    `-DuskScreenshotMute 1` now works outside screenshot mode and gives VLCKit
    `:no-audio` on iOS/tvOS.
  - Verified against jellyfin-demo (iPhone and Apple TV simulators, logging
    proxy): VLCKit direct play (AV1 MKV, ASS MKV, The Office), AVPlayer
    direct play (Big Buck Bunny) resuming at its 79 s point, start → progress
    → pause → stopped with the right ticks and indexes, the session listed in
    `/Sessions` as DirectPlay, a played-out item `Played` with `PlayCount` +1
    and no `/UserPlayedItems`, a close storing the resume point, Skip Intro and
    Skip Credits on S01E01, both trickplay sheets fetched and the iPhone
    scrubber thumbnail, audio switch reported as index 3 behind an external
    subtitle at index 0, the external `.ass` sidecar and the embedded ASS with
    its attached font. No `X-Plex` header anywhere.
    Knives Out (Atmos / Dolby Vision MKV) declines the remux without a
    request and plays directly, with no alert; its 8 trickplay sheets load in
    under a second.
  - Open:
    - Up Next and the next episode need J-02's `seasons`/`episodes` (today
      the credits show Skip Credits, no poster).
    - Explicit watched / unwatched has no screen until J-02; not exercised.
    - The Quality menu answers "This feature is not yet implemented." until
      J-06.
    - The first report (and so the session on the server) arrives at the
      first tick or state change, about 10 s in, as on Plex.
    - The tvOS scrub thumbnail needs a touch-surface pan the simulator cannot
      send.
    - Pre-rolls are J-11.
    - Shared, not Jellyfin-specific: the pre-start audio pick
      (`preferredAudioStreamPosition`) looks for "commentary" only in
      `displayTitle`, which both servers keep in `title`, and on iOS it
      penalises the lossless DTS-HD MA main track, so The Office S01E01 opens
      on a commentary track. The plex-demo copy has the same streams, so Plex
      should do the same (read from the code, not run).
    - Residue on duskcompare: `LastPlayedDate` (no API clears it) on the
      items played, and the ASS test film now remembers subtitles Off (`-1`)
      instead of no remembered choice, which plays the same. Three restored
      items came back as played about 40 min later, dated to the original
      plays in whole seconds with no client session active: something on the
      server (a watched-state sync such as a Trakt import) re-applies plays.
      Restored again at the end; it may recur.

### J-04 Home rows and library hubs — M

Rows per 04 §11, Continue Watching dismiss (incl. the Next Up store), Hide
Row / Hidden Rows via `LatestItemsExcludes`, library Recommended rows.
**Accept:** Home on both servers shows the same row kinds in the same order
for the shared data; dismiss and hide behave the same on screen; first-paint
gate unchanged.

- **As built (2026-11-28).** `JellyfinHome` + `JellyfinHomeRowSpec`; details in
  `docs/data-and-plex.md` (Jellyfin's Home rows).
  - Rows use Plex's identifiers, titles and types for the same row of a
    library (`movie.recentlyadded.<id>`, "Recently Added in Movies"), so
    `mergeKey` and the library tab's string checks need no change and J-13
    merges both servers' rows.
  - Home: one Recently Added row per film / TV / video library not in
    `LatestItemsExcludes`, all from `/Items/Latest` (row, expansion and Show
    All), so played titles stay out when the user hides them in Latest
    (`HidePlayedInLatest`, default on).
  - Continue Watching: Resume + Next Up per library, one per show, newest
    first; Next Up dated by the show's latest played episode.
  - Library tab: Continue Watching, Recently Released, Recently Added, Top
    Unwatched / Top Rated, Recently Watched, with Plex's conditions (one year,
    rating ≥ 7, unplayed / played).
  - Dismiss is `HomeProviding.dismissFromContinueWatching`. Plex's PUT moved
    verbatim into `PlexHomeRows` (pinned by a request test);
    `MediaService+WatchState.removeFromContinueWatching` is a route now.
  - Hide Row rewrites only `LatestItemsExcludes` in the raw `Configuration`,
    read fresh before each write.
  - Verified against jellyfin-demo on iPhone and Apple TV simulators
    (`~/dusk-qa/jellyfin/J-04/`): Home rows per library, hero order, the
    TV Shows tab merging Real TV and Shorts, Hide Row then Hidden Rows
    switching it back (every other `Configuration` key kept, including J-11's concurrent `OrderedViews` /
    `MyMediaExcludes` test values), dismissing a Next Up episode (stays out
    after relaunch), dismissing Paddington 2 (position cleared,
    `LastPlayedDate` kept; restored afterwards). Library rows match
    plex-demo's `/hubs/sections` for the same data (Top Unwatched = Sintel;
    Recently Watched the same three films; TV rows the same titles).
  - Open:
    - plex-demo shows duskcompare (a shared user) type-wide rows ("Recently
      Added Movies", `home.*`); Jellyfin shows one row per library, as Plex
      does for an owner. Same kind, different count of rows.
    - Plex's library tab also has genre, actor/director, Start Watching and
      Rediscover rows; Jellyfin has the five above (04 §11).
    - The Next Up dismiss store is per device, not per account.
    - Settings › Home › Hidden Rows still says "Other Plex apps hide these
      rows too." and names Plex in its errors (feature file, not this
      package's).
    - Continue Watching on Home costs `/UserViews`, one Resume per library,
      one Next Up per TV library and one dating query; not timed on a large
      server.

### J-06 Playback II: server streams — XL, R

- **Scope.** `DeviceProfile` builder per `StreamIntent`; `PlaybackInfo` with
  explicit source and stream ids; lossless remux, converted-audio remux,
  video-copy fallback, manual quality, AV1 fallback, AirPlay; variant filter
  and `STREAM-INF` pinning in `RemuxHLSLoader`; DV 5 / 8.1 / 8.4, HDR10 base
  fallback, DV 7 → 8.1 through the existing proxy; `confirm` via
  `TranscodingInfo`; ping and close; text subtitles as external WebVTT.
- **Why risky.** The part of the app with the most device-only behaviour;
  several facts are unmeasured (whether AVPlayer needs the supplemental codec
  line for 8.1, whether the HDR10 fallback strips RPU NALs, ASS attachments).
- **Accept.** For each file in 03 §5.1: the same engine and the same HDR /
  audio result as the same file on `plex-demo` (the player's quality line is
  the oracle), `confirm` reports a copy, no tone-mapping transcode is ever
  started unasked (server log). Real-device checks on an Apple TV 4K with a
  Dolby Vision display are listed for Marvin; simulator results alone do not
  close this package.

### J-07 Playlists, collections, watchlist — M

Playlist CRUD (move converted to an index), pinned playlists, collections
grid / page, "Part of" membership index, watchlist on favourites (after the
sign-off in 04 §22). **Accept:** matrix rows; a playlist created on one
server and mirrored by hand on the other renders identically.

### J-08a Downloads: original, sidecars, offline — L

Original file, text sidecars, snapshot envelope, offline browsing and
playback, offline progress replay, Smart Downloads. **Accept:** download a
film and a season on both servers; airplane-mode browsing and playback match;
progress made offline appears on the server afterwards; a Plex download made
by the pre-refactor build still plays (G4).

- **As built (2026-11-28).**
  - Original only (`JellyfinDownloads.qualities` = `[.original]`) until J-08b.
    The quality UI reads the facade, so a single choice downloads directly. A
    show's sheet keeps only Keep Next. Mac's menu becomes a plain item. A
    stored preset the server lacks is queued as Original.
  - The original is `/Items/{sourceID}/Download` with the `Authorization`
    token. The source id picks the version, checked live for both versions of
    the two-version film. `ServerPermissions.canDownload` hides only the start
    affordances. `TransportSecurity` now checks Jellyfin's credential too: one
    hook in a shared `Providers/` file.
  - Snapshot: fetching is a facet member (`metadataSnapshot`) because Jellyfin
    `.details` is item + `/MediaSegments` and `.children` needs the item's
    type. Payloads sit in the 04 §15.3 envelope under `jellyfin:/Items/{id}`
    (pinned). Plex sends the same request through its router: G6's Plex
    episode download made the same snapshot reads and file transfer as the
    baseline.
  - Offline replay: verified on the server, a sessionless Stopped/Progress
    stores the position, marks played past 90 % and never counts a play. The
    sync manager skips its own watched write for such a server, because every
    timeline tick past 90 % syncs again and each `/UserPlayedItems` counted a
    play. So a film finished offline ends Played with its `PlayCount`
    unchanged, where online play counts one.
  - Verified on jellyfin-demo (iPhone simulator, through a killable proxy):
    - A film with an external `.ass` downloaded with its sidecar. Weekend
      Projects downloaded under Keep Next 3.
    - With the proxy killed, a cold launch reached the offline shell. The show,
      season and film pages decoded from the Jellyfin snapshots. Downloads
      played on AVPlayer (episode) and VLCKit (film). The film's subtitle
      menu listed the saved external track and it could be selected. No cue
      was on screen when the screenshot was taken.
    - Back online, the queued 1:21 position reached the server.
    - After marking S01E01 watched on the server, a foreground refill removed
      it and downloaded S01E04.
  - Gaps:
    - Multi-part films download cd1 only, as they play.
    - Item-level `CanDownload` is not read.
    - No user with downloading off exists on the demo, so the hidden button
      is not checked live.
    - Apple TV has no download UI.
    - On Jellyfin, the Smart Downloads refill did not run on a cold launch;
      foregrounding did run it. Probably the server is already connected when
      `DownloadManager` starts, so it never "appears". If so, Plex behaves
      the same, but that was not checked.
    - Not tapped in the simulator: Download Season, an episode row's
      Download Episode, the Mac menu. The season's snapshot reads (the
      season, its episodes, the show's seasons) did run, during the Keep
      Next episode downloads.
    - Offline cold launch: Home still showed a spinner after 12 s. Not
      followed up; Downloads worked.

### J-08b Downloads: converted quality — L, R

Starts with a spike: segment-wise HLS download of a 2 h film at the 4 Mbit/s
preset, app suspended mid-way, resumed, concatenated file plays in both
engines. **If the spike fails, switch to the progressive transfer** (04
§15.2) inside the same package. **Accept:** every preset in the menu produces
a playable file whose size is within 15 % of bitrate × duration; interrupting
and resuming completes.

### J-09 Live TV — L, R

Lineup, guide window, on-now shelf, tune and close, channel switch, live
timeline, recordings as catch-up. **Why risky:** entirely [doc] until T-0's
tuner exists; live HLS behaviour on AVPlayer has been a source of bugs on
Plex. **Accept:** the Live TV tab, guide grid (iOS, tvOS) and Home shelf show
the test lineup; a channel plays and switches; closing the player ends the
live stream on the server.

### J-10 Photos — M

Albums incl. plain folders, album contents, timeline with the shared client
grouping, viewer, tvOS slideshow. **Accept:** matrix rows for the six shared
albums.
- **As built (2026-11-28).**
  - `JellyfinCatalog.photoPage` forwards to `JellyfinPhotos` (one line). The
    queries and their order are in `docs/data-and-plex.md` → Photo Libraries.
    No shared code changed: the grid, viewer and slideshow work unchanged on
    `PhotoItem`.
  - Order against plex-demo: the root albums, the `2026` folder (Birthday,
    Ski Weekend) and Metadata Test (EXIF days, the clip in place) match
    exactly. In Loose (no EXIF) Plex puts `photo_7` last, because it sorts by
    the file time to the second; Jellyfin lists those photos by name. On the
    timeline the date order matches Plex (items with the same date can come in
    another order), except `Clip_2025-10-05`: Jellyfin's `DateCreated` for a
    clip is the file's import time, so it sorts first instead of among the
    2025 photos. That is why the timeline uses
    `DateCreated` rather than the `PremiereDate, DateCreated` of 02 §13:
    `PremiereDate` put every undated photo after the dated ones.
  - The photo day is the device-zone day of `PremiereDate`. The server converts
    the zone-less EXIF time from its own zone to UTC, so a UTC day would show
    the day before for photos taken after midnight.
  - Verified against jellyfin-demo on iPhone and Apple TV simulators
    (`~/dusk-qa/jellyfin/J-10/`) and in `JellyfinPhotosLiveTests`: albums,
    folder, album, Orientation 6 photo upright in the viewer with date and
    camera, timeline paged to its last item, tvOS slideshow, a clip playing
    from the grid.
  - Open:
    - HEIC cannot be checked, because neither demo server imports the T-0
      HEIC.
    - The viewer image covers the screen box (`fill*`) rather than fitting
      inside it, so panoramas come back much larger than needed. The cost is
      not measured, because the test photos are at most 1600 px. A
      `photoDisplay` provider verb (01 §16) would need changes in Core, Plex
      and the fake provider, so it was not added.
    - The photo day assumes the device and the server share a time zone. A
      server running in UTC (common in containers) shifts photos taken near
      midnight by a day; jellyfin-demo cannot show it.

### J-11 Account preferences, subtitle search, pre-rolls — M

Library order and hidden libraries on `OrderedViews` / `MyMediaExcludes`
(device-local fallback), language defaults, `SubtitleSearchProviding`,
`/Intros`. **Accept:** reorder and hide in Dusk, confirm in Jellyfin Web and
the other way round; the subtitle action appears only for the user with the
permission; a pre-roll plays when the plugin returns one.

### J-12 Integrations — M

Seerr Jellyfin sign-in (after sign-off), Trakt ids, Top Shelf, Siri catalog
and playback, SharePlay ids, analytics `provider` property and privacy text
(after sign-off). **Accept:** Seerr links against a Jellyfin-backed instance
and re-authenticates silently; a finished film reaches the Trakt queue; a Top
Shelf entry and a Siri phrase open a Jellyfin title.

### J-13 Several accounts, mixed Plex + Jellyfin — L, R

"Add Server" row, linked accounts per profile scope, content-key
canonicalisation switched on, cross-provider watched fan-out and playback
alternates, library interleave, Server Priority with both kinds. **Why
risky:** first time two providers share one merge; profile switching with
linked accounts. **Accept:** with `plex-demo` and `jellyfin-demo` both
connected, the shared films appear once on Home, in search and in grids;
disabling one server plays the other copy; a Plex-only install shows no new
UI anywhere except the one "Add Server" row.

### J-14 Parity audit, mock, docs — M

Full matrix (§6) on iPhone, iPad, Apple TV and Mac; fix list worked off or
filed; a Jellyfin mode for the screenshot mock; `docs/` updated
(`data-and-plex.md` split into provider docs, `playback.md`,
`downloads-and-offline.md`, `seerr-integration.md`, `analytics.md`). There is
no launch-argument gate to remove (§1).

## 6. Side-by-side matrix

Both servers hold the same media and the same `duskcompare` state (T-0 keeps
them aligned). For each row the verification agent captures the same screen
from both and files any difference that is not on the allowed list.

| Area | Rows |
| --- | --- |
| Home | hero, Continue Watching, each Recently Added row, recommendation shelves, dismiss, hide row, pinned playlist, watchlist row |
| Browse | movie grid, show grid, each sort, each filter, A–Z jump, collections grid, collection page, Videos library |
| Detail | movie, show, season, episode, person, extras row, "Part of" row, trailer button, versions menu, ratings line |
| Search | titles, people, episodes |
| Player | direct play AVPlayer, direct play VLCKit, each remux case of 03 §5.1, quality menu, tracks panel, sidecar and ASS subtitles, skip intro/credits, scrub previews, Up Next, pre-roll |
| State | resume position, watched / unwatched on film, episode, season, show |
| Downloads | original, each preset, offline browse, offline play, sync back |
| Playlists | list, page, create, add, reorder, remove, delete |
| Photos | albums, album, timeline, viewer |
| Live TV | tab, guide, on-now shelf, play, switch |
| Settings | server list, library order, hidden libraries, hidden rows, switch user |

Allowed differences (platform facts, 04 §21): rating numbers and their icons,
cast count and order, content-rating strings, edition labels, version label
wording, filters Jellyfin lacks (HDR, Dolby Vision, audio language), the Rate
action, the lost resume point after a Continue Watching dismiss, a YouTube
trailer opening outside the app.

## 7. T-0: test data to add to the demo servers

Ops work, no repo changes; start in wave 0 because several packages wait on
it. "Both" means the same files on `plex-demo` and `jellyfin-demo`.

| Data | Where | Needed by |
| --- | --- | --- |
| Two collections (one in Movies, one spanning Movies and TV) | both; on Jellyfin created by an admin, since `duskcompare` lacks `EnableCollectionManagement` | J-02, J-07 |
| A film with **two versions** (1080p and 2160p, Jellyfin `- 1080p` / `- 2160p` suffix naming) | both | J-02, J-06, Preferred Version |
| A second film stored as two **editions** | plex-demo only (Jellyfin has none) | allowed-difference check |
| **ASS/SSA** subtitle with embedded font attachments, and an external `.ass` | both | J-05, J-06 |
| VobSub and a forced-only subtitle track | both | J-05 |
| **Extras**: behind the scenes, deleted scene, featurette, and a **local trailer** on one film; extras on a show, a season and an episode | both | J-02 |
| A film with only a remote (YouTube) trailer | jellyfin-demo | J-02 |
| A **multi-part** film (cd1 / cd2) | both | J-00b (`AdditionalParts`) |
| Intro and credits markers on `The Office` season 1 | plex-demo (run marker detection; Jellyfin already has them) | G6, J-05 |
| Video preview thumbnails (BIF) on the two films that have trickplay on Jellyfin | plex-demo | G6, J-05 |
| **Live TV**: an M3U tuner + XMLTV guide from `scripts/iptv_test_source.py` on jellyfin-demo; on plex-demo the same source behind an HDHomeRun emulator if one can be run, otherwise Live TV is compared against Dusk's IPTV source | jellyfin-demo required, plex-demo if feasible | J-09 |
| One recording of a guide entry | jellyfin-demo | J-09 catch-up |
| Cinema pre-roll: Plex pre-roll video setting; Jellyfin intros plugin with the same clip | both | J-11 |
| Playlists: one short, one long enough to page | both | J-07 |
| A show with episodes 1 – 3 watched (so Next Up is populated) and one film resumed past 5 % | both, same positions | J-04 |
| Photos with real EXIF dates across three months, one HEIC, one rotated image, one clip | both | J-10 |
| Users: a second user visible on the Jellyfin login screen with a password, one without; a user with `EnableSubtitleManagement` and a subtitle plugin if an account for it exists; a user with `EnableContentDownloading` off | jellyfin-demo | J-01, J-11, J-08a |
| A Plex Home member with a PIN | plex-demo account (if not present) | G6 profile switch |
| A second small Jellyfin server holding five of the same films | new container | J-13 |
| A Jellyfin-backed Seerr instance | new container | J-12 |
| A library large enough to page the letter index (≥ 500 titles, generated stubs are fine) | jellyfin-demo | J-02 |

## 8. Risk register

| Package | What can go wrong | Mitigation |
| --- | --- | --- |
| P0-02 | an integer id assumption survives in persisted data | Int-or-String decoders, G4 fixture, grep gate for `Int(` on ids |
| P0-05 | offline cache or converted-media blobs stop decoding | DTOs keep the exact `CodingKeys`; G4 |
| P0-06 | token refresh or self-healing regresses for every request | G6 includes a forced-dead-endpoint run; second reviewer |
| P0-09 | the delivery ladder changes order or acceptance | no logic edits allowed, only type substitution; the existing routing tests are the contract; G6 on DV 7 and TrueHD |
| P0-12 | a hub lands in the wrong place once heuristics become `kind` | fixture tests captured before the move |
| P0-15 | existing downloads disappear | hash-input golden test; G4 |
| P0-16 | existing users are signed out or lose their profile scope | Keychain accounts read in place; scope golden test |
| J-01 | `DeviceId` reuse logs a profile out | per-account ids; two-user test |
| J-06 | DV / HDR behaviour differs on real hardware | device checklist for Marvin; variant line always written by Dusk |
| J-08b | background segment downloads stall | spike first, progressive fallback decided in advance |
| J-09 | untested platform behaviour | T-0 tuner; IPTV path as the reference |
| J-13 | wrong merges across providers | canonicalisation only re-keys items without a native id; strong keys only for playback alternates |
| whole plan | `main` moves under the sweeps | sweeps are scripts and are re-run, not merged; sweep train lands within a day |

## 9. What the coordinator decides before starting

1. The five sign-offs in 04 §22 (watchlist = favourites, Seerr password in
   the Keychain, analytics property, mixed accounts, no rating logos). Only
   J-07, J-12 and J-13 wait on them.
2. The window for the sweep train (wave 1): a quiet day on `main`.
3. Who owns T-0 and when the second Jellyfin server and the Seerr instance
   exist.
4. Which Apple TV and display are used for the J-06 device checklist.
