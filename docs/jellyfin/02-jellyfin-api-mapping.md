# Jellyfin support — 02: API mapping (Plex call → Jellyfin call)

Research only; no app code was changed. Every row marked **[live]** was run on
2026-11-27 against `jellyfin-demo` (Jellyfin Server 12.4.0, Intro Skipper,
trickplay on the Real libraries) as the non-admin user `duskcompare`, and the
same items were read from `plex-demo` (PMS 1.43.5) as the same user for the
shape comparison. **[doc]** means "from the API definition / general knowledge,
not exercised", usually because the demo server has no data for it.

Auth header forms, DeviceId rules, ticks, image caching, the PlaybackInfo
profile matrix, the master-playlist trap, DV/Atmos through the remux and Quick
Connect are already measured in [03-prior-art.md](03-prior-art.md) §5, §7, §10.
This file does not repeat them; it references them and adds what was missing.

Plex side references: all Plex calls live in
`Dusk/Sources/PlexService/PlexService+*.swift` (`PS+X` below), models in
`Dusk/Sources/Models/`.

## 0. Things that hold everywhere

| Topic | Plex (Dusk today) | Jellyfin 12.4 [live] |
| --- | --- | --- |
| Base | plex.tv account + N servers, per-server token | One server URL, one token per (server, user, DeviceId). No cloud account. |
| Identity header | `X-Plex-*` headers (`PS+Networking.applyHeaders`) | `Authorization: MediaBrowser Client="Dusk", Device="…", DeviceId="…", Version="…", Token="…"` (only this form works, 03 §10.1) |
| Item id | `ratingKey` (integer string, per server) | `Id`, 32 hex chars (GUID). Fits `PlexItemID(serverID, ratingKey)` as an opaque string. |
| Paging | `X-Plex-Container-Start/Size`, `totalSize` | `startIndex`, `limit`, response `TotalRecordCount`, `StartIndex`. `limit=0` returns only the count. `enableTotalRecordCount=false` skips the count (cheaper). |
| Envelope | `MediaContainer.{Metadata,Directory,Hub}` | `{Items, TotalRecordCount, StartIndex}`; a few endpoints return a bare array (`/Items/Latest`, `/Items/{id}/SpecialFeatures`, `/Items/{id}/Ancestors`, `/Sessions`). |
| Time | ms (`duration`, `viewOffset`), epoch seconds (`addedAt`) | 100 ns ticks (`RunTimeTicks`, `PlaybackPositionTicks`), ISO dates with 7 fraction digits |
| Item payload size | everything by default | List responses are slim. Ask with `fields=` (`Overview,Genres,People,MediaSources,Chapters,Trickplay,ProviderIds,ChildCount,RecursiveItemCount,DateCreated,Path,…`). `GET /Items/{id}?userId=` returns the full object. |
| User scope | token implies the user | Pass `userId=` on every query, otherwise `UserData` is missing. |
| Unknown params | mostly `400` | **Silently ignored** (`sortBy=Bogus` → `200`, default order). A typo never fails; tests must assert on results, not status. |

Type mapping: `movie` → `Movie`, `show` → `Series`, `season` → `Season`,
`episode` → `Episode`, `clip` (Videos library) → `Video`, `collection` →
`BoxSet`, `playlist` → `Playlist`, photo album → `PhotoAlbum` / `Folder`,
`photo` → `Photo`, person tag → `Person`, genre tag → `Genre`.

## 1. Sign-in, servers, users

| Dusk feature (Plex call) | Jellyfin | Verified |
| --- | --- | --- |
| Server reachable + identity (`ServerProbe`: `/identity`) | `GET /System/Info/Public` → `{Id, ServerName, Version, ProductName:"Jellyfin Server", LocalAddress, StartupWizardCompleted}`, no auth | live |
| Token still valid (`/library/sections` 401 check) | `GET /Users/Me` → `200` / `401` | live |
| PIN link (`PS+Auth.generatePin/checkPin`) | Quick Connect: `/QuickConnect/Enabled`, `/Initiate`, `/Connect?secret=`, `/Users/AuthenticateWithQuickConnect` (03 §7) | live (03) |
| — (no password form in Dusk) | `POST /Users/AuthenticateByName` `{"Username","Pw"}` → `{AccessToken, ServerId, User{Id, Name, Policy, Configuration}, SessionInfo}` | live |
| Sign out | `POST /Sessions/Logout` → `204` | live (03) |
| Server list (`plex.tv /api/v2/resources`) | none. User types a URL; optional LAN discovery (UDP 7359 "who is JellyfinServer?") | doc |
| Home users (`/api/v2/home/users`, switch) | `GET /Users/Public` → users not hidden on the login screen, no auth. **Returned `[]` here** (all users hidden); common on real servers too. Each user is a separate login with its own token and DeviceId. | live |
| User avatar | `GET /UserImage?userId=` (404 when unset) | live |
| Admin / owner check (`PlexServer.owned`) | `User.Policy.IsAdministrator`, plus per-feature flags: `EnableCollectionManagement`, `EnableSubtitleManagement`, `EnableContentDownloading`, `EnableLiveTvAccess`, `EnableMediaPlayback`, `EnablePlaybackRemuxing`, `EnableVideoPlaybackTranscoding` | live |
| Account language defaults (`PS+LanguageDefaults`, plex.tv profile) | `User.Configuration`: `AudioLanguagePreference` (absent when unset), `SubtitleLanguagePreference`, `SubtitleMode` (`Default/Always/OnlyForced/None/Smart`), `PlayDefaultAudioTrack`, `RememberAudioSelections`, `RememberSubtitleSelections` | live (read) |
| Remote-vs-local (`PlexConnection.local`) | `GET /System/Endpoint` → `{IsLocal, IsInNetwork}` | live |

Gaps and proposal:

- **No multi-connection ranking** (`ConnectionSelector`): a Jellyfin server has
  one user-supplied URL. Let the user add an optional second URL (LAN + remote)
  and run both through the existing probe; identity gate = `Id` from
  `/System/Info/Public`.
- **No Plex Home.** Profile switcher becomes "saved accounts on this server".
  Offer `/Users/Public` names as shortcuts when non-empty, otherwise a username
  field. Keep one DeviceId per (install, server, user) (03 §10.2).
- **Sign-in UI** (the allowed difference): server URL → Quick Connect code
  (default on tvOS) or username/password. `QuickConnect/Enabled` false → hide
  the code option.

## 2. Libraries

| Dusk feature (Plex call) | Jellyfin | Verified |
| --- | --- | --- |
| `getLibraries` (`/library/sections`) | `GET /UserViews?userId=` → `Items[]` with `Id, Name, CollectionType, Type:"CollectionFolder", ImageTags` | live |
| Library type | `CollectionType`: `movies`, `tvshows`, `homevideos`, `playlists` (appears once a playlist exists), `boxsets` (once a collection exists), `livetv`, `music`, `books`, absent = mixed | live (first four) |
| Videos vs Photos library | **Both are `homevideos`.** Plex has `movie` (agent none) vs `photo`. | live |
| Library order + hidden (plex.tv `experience` blob) | `User.Configuration.OrderedViews[]`, `MyMediaExcludes[]`, `LatestItemsExcludes[]`, written with `POST /Users/Configuration?userId=` (needs `Policy.EnableUserPreferenceAccess`) | read live, write doc |
| Item count (`getLibraryItemCount`) | `GET /Items?parentId=&recursive=true&includeItemTypes=Movie&limit=0` → `TotalRecordCount`; whole server: `GET /Items/Counts` | live |

Gap: **Photos and Home Videos are indistinguishable by type.** Proposal:
classify a `homevideos` view once on first load with two `limit=0` counts
(`includeItemTypes=Photo` vs `Video`, recursive) and cache the answer; mostly
photos → Dusk's Photos experience, otherwise Videos library. A mixed folder
shows both (the photo timeline already mixes clips).

## 3. Library browse

One endpoint: `GET /Items?userId=&parentId={viewId}&recursive=true&includeItemTypes=Movie|Series|…`.

| Dusk (Plex) | Jellyfin parameter | Verified |
| --- | --- | --- |
| `sort=titleSort` | `sortBy=SortName` | live |
| `originallyAvailableAt` / `year` | `PremiereDate` / `ProductionYear` | live |
| `addedAt`, `episode.addedAt` | `DateCreated`; `DateLastContentAdded` for series | live |
| `rating`, `audienceRating` | `CommunityRating`, `CriticRating` (see §6 for which is which) | live |
| `userRating` | no equivalent (no star rating, §8) | gap |
| `duration` | `Runtime` | live |
| `lastViewedAt` | `DatePlayed`; `PlayCount` also exists | live |
| `random` | `Random` | live |
| `:desc` | `sortOrder=Descending`; several keys comma-separated | live |
| `unwatched=1` / `unwatchedLeaves=1` | `isPlayed=false` or `filters=IsUnplayed` (works for Series too) | live |
| in progress | `filters=IsResumable` | live |
| `genre=` | `genres=Comedy` (names, pipe-separated) or `genreIds=` | live |
| `collection=` | `parentId={boxSetId}` (§5) | doc |
| `year`, `contentRating`, `studio`, tags | `years=2024`, `officialRatings=`, `studios=` / `studioIds=`, `tags=` | live |
| actor/director | `person=Daniel Craig` or `personIds=` (+ `personTypes=Actor,Director`) | live |
| `resolution`, `hdr`, `dovi` | `is4K=true`, `isHD=true`; **no HDR / DV / Atmos / codec filters** | live / gap |
| subtitles present | `hasSubtitles=true` | live |
| favourites | `isFavorite=true` | live |
| Filter values (`/filters`, `/genre`) | `GET /Items/Filters?userId=&parentId=` → `{Genres[], Tags[], OfficialRatings[], Years[]}`; `GET /Genres?parentId=` (items with `Id` and images); `/Studios`, `/Persons` | live |
| A–Z index (`/firstCharacter` → letters with counts) | **No index endpoint.** Building blocks: `nameStartsWith=D`, `nameLessThan=B`, `nameStartsWithOrGreater=T` (all on sort name) | live |
| Collections inside the grid (`includeCollections=1`, `collectionMode`) | `collapseBoxSetItems=true` | doc |
| Per-item watch badge | `UserData.Played`, `UserData.PlayedPercentage`, series/season `UserData.UnplayedItemCount` | live |

Plex filter list on the same library for reference: `genre, year, decade,
contentRating, collection, director, actor, writer, producer, country, studio,
resolution, hdr, dovi, hdr10plus, atmos, unwatched, inProgress, videoCodec,
audioCodec, subtitleCodec, audioLayout, audioLanguage, subtitleLanguage,
editionTitle`. Plex sorts: `titleSort, originallyAvailableAt, rating,
audienceRating, duration, addedAt, lastViewedAt, mediaHeight, random`.

Gaps and proposal:

- **A–Z bar.** Show the fixed alphabet (`#`, A–Z) without counts. A letter tap
  resolves to an offset with one `nameLessThan={letter}&limit=0` count
  (`TotalRecordCount` = index of the first item at that letter), which feeds
  the existing window pager unchanged. `#` = offset 0. Letters with no titles
  land on the next one, which is acceptable; greying them out would cost 26
  count requests per library (do it lazily, cached, only if wanted).
- **Filters Dusk offers** come from a backend capability list, not a hard-coded
  set: the provider returns the filter fields it supports. Jellyfin: genre,
  year, content rating, studio, tag, unwatched, in progress, favourite, 4K/HD,
  has subtitles. Missing ones are simply not listed.
- **Sort "My Rating"** is hidden for Jellyfin.

## 4. Home rows and hubs

Jellyfin has **no hub API**. Home is composed client-side from fixed queries.

| Dusk row (Plex call) | Jellyfin | Verified |
| --- | --- | --- |
| Continue Watching (`/hubs/continueWatching`) | `GET /UserItems/Resume?userId=&mediaTypes=Video&limit=` → partially played movies/episodes, newest first, with `UserData.PlaybackPositionTicks`, `PlayedPercentage`, `LastPlayedDate` | live: `Paddington 2` 309.469 s, `Dune: Part Two` 607.0 s; Plex shows the same two (`viewOffset` 309469 / 607332 ms) |
| On Deck (next episode) | `GET /Shows/NextUp?userId=&limit=&enableResumable=false&enableRewatching=false&nextUpDateCutoff=`; per show `&seriesId=` | live: empty server-wide until an episode of a show is played; `seriesId=` returned S1E1 |
| Recently Added per library (`/hubs/promoted`, `/hubs/sections/{id}`) | `GET /Items/Latest?userId=&parentId={viewId}&limit=&groupItems=true` → **bare array**; episodes are grouped up to `Season` / `Series` items | live: TV returned `Episode`, `Season`, `Series` mixed |
| Other promoted hubs (recently released, by genre, by actor, recently viewed) | none. Build from `/Items` (`sortBy=PremiereDate`, `genres=`, `sortBy=DatePlayed`) if wanted | — |
| "Show All" (`hub.key`) | the same query with paging (`/Items/Latest` has no paging → use `/Items?sortBy=DateCreated&sortOrder=Descending`) | live |
| Remove from Continue Watching (`/actions/removeFromContinueWatching`) | `POST /UserItems/{id}/UserData?userId=` `{"PlaybackPositionTicks":0}` (clears the resume point; there is no "hide but keep position") | live |
| Hide Home rows (`/hubs/sections/{id}/manage`, owner) | no server concept. `LatestItemsExcludes` hides a library's Latest row for the user. | read live |
| Recommendations (`/status/sessions/history/all`) | `GET /Items?sortBy=DatePlayed&sortOrder=Descending&isPlayed=true` for history; `GET /Items/Suggestions?userId=`, `GET /Movies/Recommendations?userId=&categoryLimit=&itemLimit=` | live (`Suggestions` returned items; `Recommendations` `[]` on this small server) |
| Watchlist (discover.provider.plex.tv) | none. Closest: favourites (`isFavorite=true`, `POST/DELETE /UserFavoriteItems/{id}`), which only covers items already on the server | live |
| Pinned playlists (device-local) | unchanged, key by `(serverID, Id)` | — |

Proposal:

- The Home view model consumes an abstract `[HomeRow]` from the provider. The
  Jellyfin provider emits: Continue Watching (Resume **merged with** NextUp by
  `LastPlayedDate`, which is what Plex's `home.continue` already is), then one
  "Recently Added in {library}" per view not in `LatestItemsExcludes`.
  `ContinueWatchingMerge` / `HubMerge` work on the abstract rows, so mixed
  Plex + Jellyfin homes come for free.
- Hide Row / Hidden Rows for Jellyfin: write `LatestItemsExcludes` when the row
  is a Latest row; hide the action for other rows.
- Watchlist row and bookmark button: hidden for Jellyfin in v1. Do **not**
  silently map it to favourites (different meaning: "want to watch, may not be
  on the server" vs "like"). Favourites could later be an explicit feature for
  both backends.
- Latest returns Season/Series containers: the poster row must accept them
  (Dusk already folds Recently Added seasons, see
  `dusk-home-repeated-rows-and-season-cards`).

## 5. Collections and playlists

| Dusk (Plex) | Jellyfin | Verified |
| --- | --- | --- |
| Collections list (`/library/sections/{id}/collections`) | `GET /Items?userId=&includeItemTypes=BoxSet&recursive=true` (server-wide; a `boxsets` view appears in `/UserViews`) | query live (0 results; user may not create: `POST /Collections` → `403` without `EnableCollectionManagement`) |
| Collection items (`/library/metadata/{rk}/children`) | `GET /Items?userId=&parentId={boxSetId}` | doc |
| "Part of" row on a detail page (`Collection` tags) | no back-reference on the item. `ProviderIds.TmdbCollection` exists; membership needs a BoxSet query | live (field) |
| Playlists list (`/playlists?playlistType=video`) | `GET /Items?userId=&includeItemTypes=Playlist&recursive=true` → `Name, ChildCount, MediaType:"Video", RunTimeTicks` | live |
| Playlist items (`/playlists/{rk}/items`, `playlistItemID`) | `GET /Playlists/{id}/Items?userId=` → items with `PlaylistItemId` | live |
| Create (`POST /playlists?uri=…`) | `POST /Playlists` `{"Name","Ids":[…],"UserId","MediaType":"Video","IsPublic":false}` → `{Id}` | live |
| Add (`PUT …/items?uri=`) | `POST /Playlists/{id}/Items?ids=a,b&userId=` → `204` (no added-count in the response) | live |
| Remove (`DELETE …/items/{playlistItemID}`) | `DELETE /Playlists/{id}/Items?entryIds={PlaylistItemId}` → `204` | live |
| Move (`…/move?after=`) | `POST /Playlists/{id}/Items/{PlaylistItemId}/Move/{newIndex}` (absolute index, not "after") | live |
| Rename (`PUT /playlists/{rk}?title=`) | `POST /Playlists/{id}` `{"Name": "…"}` → `204` | live |
| Delete | `DELETE /Items/{id}` → `204` (owner of the playlist) | live |
| Playlist meta | `GET /Playlists/{id}` → `{OpenAccess, Shares[], ItemIds[]}` | live |

Differences: collections are **server-wide**, not per library (filter the
BoxSet children by library when showing the grid chip; for a mixed BoxSet show
it in every library it has children in). Smart collections/playlists do not
exist. `PlexPlaylistAddResult.leafCountAdded` (duplicate detection) has no
equivalent: diff `ItemIds` before/after or just report success. "Move after X"
must be converted to an index.

## 6. Detail pages

`GET /Items/{id}?userId=` [live]. Same film, both servers (`Knives Out`):

| Dusk field (`PlexMediaDetails`) | Plex value | Jellyfin field → value |
| --- | --- | --- |
| `ratingKey` | `166519` | `Id` `980dffd6dfa0d8cfd69e5bd6b350e983` |
| `title`, `summary`, `tagline` | same | `Name`, `Overview`, `Taglines[0]` |
| `duration` | `7817247` ms | `RunTimeTicks` `78172470000` |
| `year`, `originallyAvailableAt` | `2019`, `"2019-11-27"` | `ProductionYear`, `PremiereDate` `"2019-11-27T00:00:00.0000000Z"` (episodes and people came back `…T23:00:00Z` of the previous day: local midnight stored as UTC, so a naive UTC date is one day early; round to the nearest day) |
| `contentRating` | `PG-13` | `OfficialRating` **`CH-12`** (depends on the server's metadata country) |
| `rating` + `ratingImage` | `9.7`, `rottentomatoes://image.rating.ripe` | `CriticRating` `null` here (only filled by some providers, 0–100 scale) |
| `audienceRating` + image | `9.2`, `rottentomatoes://…upright` | `CommunityRating` `7.843` (TMDB, 0–10). **No source field.** |
| `Rating[]` (multi-source) | present | none |
| `userRating` | settable 0–10 | none (§8) |
| `studio` | `MRC` | `Studios[] {Name, Id}` |
| `Genre[]` | tags | `Genres[]` + `GenreItems[] {Name, Id}` |
| `Role[]` (32) `{tag, role, thumb (absolute plex.tv URL), id}` | | `People[]` (19) `{Name, Id, Role, Type: Actor/Director/Writer/Producer, PrimaryImageTag}`; image `/Items/{personId}/Images/Primary?tag=` |
| `Director[]`, `Writer[]` | separate arrays | same `People[]`, split on `Type` |
| `guid`, `Guid[]` | `plex://movie/…`, `imdb://tt8946378`, `tmdb://546554`, `tvdb://35214` | `ProviderIds {Imdb:"tt8946378", Tmdb:"546554", TmdbCollection:"722971"}` (series also `Tvdb`). No Plex guid. |
| `primaryExtraKey` (trailer) | `/library/metadata/166539` (a playable clip) | `RemoteTrailers[] {Url (YouTube), Name}`; local files via `LocalTrailerCount` + `GET /Items/{id}/LocalTrailers` |
| `thumb`, `art`, `clearLogo` | paths | `ImageTags {Primary, Logo, Thumb}`, `BackdropImageTags[]` (§12) |
| `editionTitle` | supported | none (versions are named by filename suffix, §9) |
| `Media[]` / `Part[]` / `Stream[]` | | `MediaSources[]` / — / `MediaStreams[]` (§9) |
| `Marker[]` | absent on plex-demo for these files | `GET /MediaSegments/{id}` (§11) |
| `Chapter[]` (16, `startTimeOffset`/`endTimeOffset` ms, thumb) | | `Chapters[]` (16) `{StartPositionTicks, Name, ImageTag}`; no end time (next start / runtime) |
| `viewOffset`, `viewCount`, `lastViewedAt` | | `UserData {PlaybackPositionTicks, PlayCount, Played, LastPlayedDate, IsFavorite, PlayedPercentage}`; keys absent when zero/never |
| `Collection[]` | tags | none (§5) |
| `Country[]` | | `ProductionLocations[]` |

Other detail calls:

| Dusk (Plex) | Jellyfin | Verified |
| --- | --- | --- |
| Seasons (`/library/metadata/{show}/children`) | `GET /Shows/{seriesId}/Seasons?userId=` → `IndexNumber`, `UserData.UnplayedItemCount`, `SeriesPrimaryImageTag`, `ParentBackdropImageTags` | live |
| Episodes of a season | `GET /Shows/{seriesId}/Episodes?userId=&seasonId=&fields=Overview,MediaSources,…` | live |
| All episodes (`/allLeaves`) | same without `seasonId` (or `/Items?parentId={seriesId}&recursive=true&includeItemTypes=Episode`) | live |
| Episode ancestry (`parentRatingKey`, `grandparentRatingKey`, `grandparentThumb`) | `SeasonId`, `SeriesId`, `SeriesName`, `SeasonName`, `ParentIndexNumber`, `IndexNumber`, `SeriesPrimaryImageTag`, `ParentBackdropItemId`/`ParentBackdropImageTags`, `ParentLogoItemId`/`ParentLogoImageTag` | live |
| Leaf counts (`leafCount`, `viewedLeafCount`, `childCount`) | `fields=ChildCount,RecursiveItemCount` → `ChildCount` (seasons), `RecursiveItemCount` (episodes), `UserData.UnplayedItemCount`; watched = `RecursiveItemCount − UnplayedItemCount` | live: The Office 9 / 186 / 186 on both |
| Next / adjacent episode (client-side from leaves) | same client logic, or `/Shows/NextUp?seriesId=`, or `/Shows/{id}/Episodes?adjacentTo={episodeId}` | NextUp live, adjacentTo doc |
| Extras row (`/library/metadata/{rk}/extras`, `extraType`) | `GET /Items/{id}/SpecialFeatures?userId=` → items with `ExtraType` (`BehindTheScenes, DeletedScene, Interview, Featurette, Clip, …`); count in `SpecialFeatureCount`; trailers separately | endpoint live (0 on demo) |
| Related | `GET /Items/{id}/Similar?userId=&limit=` (Dusk has no Plex "related" call, so no parity need) | live (empty on a 3-film library) |
| Person page (`/library/people/{id}`, `/media`) | `GET /Items/{personId}?userId=` → `Overview`, `PremiereDate` (birth), `ProductionLocations` (birthplace); credits `GET /Items?personIds={id}&recursive=true&includeItemTypes=Movie,Series` | live |
| Editions on one title | none; separate `Movie` items if the admin split them | — |
| Movie copies across servers (`/library/all?guid=`) | **`anyProviderIdEquals` is ignored on 12.4** (returned all 25 films for `tmdb.546554`). Only `hasTmdbId/hasImdbId/hasTvdbId` booleans work. | live |
| Seerr / Trakt ids (`Guid[]`) | `ProviderIds` (request with `fields=ProviderIds` in lists) | live |

Gaps and proposal:

- **Ratings.** Jellyfin gives two bare numbers and no source. The provider
  returns ratings as `[(source, value, scale)]`; Jellyfin maps
  `CommunityRating` → `.community` (generic star, 0–10, **no TMDB logo**: the
  source is an assumption) and `CriticRating` → `.critic` (Rotten Tomatoes
  style percentage icon is also an assumption; use a neutral critic glyph).
  The Rate button and "My Rating" sort are hidden.
- **Trailer.** Prefer a local trailer (plays in Dusk like the Plex clip). With
  only `RemoteTrailers` (YouTube), Dusk cannot play it in the player; open the
  URL externally on iOS/macOS and hide the button on tvOS.
- **Content rating strings** are whatever the server stores (`CH-12`). Dusk's
  plain age-rating display works; a logo lookup by exact string will not.
- **Editions** (`editionTitle` in subtitles/hero, content key): feature is
  absent; `editionTitle` is nil, nothing to render.
- **Cross-server matching** (`PlexContentKey`, movie copies, Watchlist, Seerr
  availability): no guid lookup endpoint. For multi-server unification build
  the content key from `ProviderIds` (tmdb → imdb → tvdb) already present on
  listed items (request `fields=ProviderIds`) and match client-side; a
  point lookup "is tmdb 546554 on this server" needs a search by title + year
  then a `ProviderIds` check. Plex-only matching by `plex://` guid cannot span
  backends; the tmdb/imdb form must become the canonical cross-backend key.
- **Cast count/order differs** (19 vs 32); cosmetic.

## 7. Search

| Dusk (Plex) | Jellyfin | Verified |
| --- | --- | --- |
| `/hubs/search?query=&limit=10` → hubs by type | `GET /Items?userId=&searchTerm=&recursive=true&includeItemTypes=Movie,Series,Episode,BoxSet,Playlist&limit=` (one flat list, each item has `Type`); people: `GET /Persons?searchTerm=`; lightweight: `GET /Search/Hints?searchTerm=` → `SearchHints[] {Id, Name, Type, ProductionYear, PrimaryImageTag, …}` | live |

Differences [live]: `searchTerm=office` returned episodes before the series
(no relevance ranking, no per-type grouping). Matching is on names only:
`blanc` (a role name) found nothing on Jellyfin (and nothing on plex-demo
either). Proposal: issue one request per type group in parallel
(`Movie`, `Series`, `Episode`, `Person`, `BoxSet,Playlist`) with a small
`limit`, and feed them to `SearchMerge` as the same typed sections Plex gives.

## 8. Watched state, progress, ratings

| Dusk (Plex) | Jellyfin | Verified |
| --- | --- | --- |
| Scrobble (`/:/scrobble`) | `POST /UserPlayedItems/{id}?userId=` → returns the new `UserData` | live |
| Unscrobble | `DELETE /UserPlayedItems/{id}?userId=` | live |
| Show / season watched | same call on the `Series` / `Season` id; cascades to every episode | live (6 of 6 flipped and restored on `Weekend Projects`) |
| Set position / clear resume | `POST /UserItems/{id}/UserData?userId=` `{"PlaybackPositionTicks":…, "Played":…, "PlayCount":…, "LastPlayedDate":…}` | live |
| Read | `GET /UserItems/{id}/UserData?userId=` | live |
| User rating (`/:/rate`, 0–10) | only like/dislike: `POST /UserItems/{id}/Rating?likes=true` (`UserData.Likes`, `Rating: 10`), `DELETE` to clear | live |
| Favourite | `POST` / `DELETE /UserFavoriteItems/{id}?userId=` | live |
| Watched fan-out across servers (`PlexService+WatchedFanOut`) | per server; match by `ProviderIds` (§6) | — |

Playback reporting (all `204`, JSON body) [live]:

| Plex `/:/timeline` | Jellyfin |
| --- | --- |
| first report `state=playing` | `POST /Sessions/Playing` `{ItemId, MediaSourceId, PlaySessionId, PlayMethod: "DirectPlay"/"DirectStream"/"Transcode", PositionTicks, CanSeek, AudioStreamIndex, SubtitleStreamIndex, IsPaused, IsMuted, VolumeLevel, RepeatMode, PlaybackOrder}` |
| every 10 s `playing` / `paused` / `buffering` | `POST /Sessions/Playing/Progress` same body + `EventName` (`TimeUpdate`, `Pause`, `Unpause`, …); pause is `IsPaused: true` |
| `state=stopped` | `POST /Sessions/Playing/Stopped` `{ItemId, MediaSourceId, PlaySessionId, PositionTicks}` |
| transcode ping every ~60 s (`/video/:/transcode/universal/ping`) | `POST /Sessions/Playing/Ping?playSessionId=` |
| stop transcode | `DELETE /Videos/ActiveEncodings?deviceId=&playSessionId=` (03 §5.1) |
| session identifier | `PlaySessionId` from the PlaybackInfo response |

Observed semantics that differ from Plex:

- `GET /Sessions?deviceId=` shows `NowPlayingItem` and `PlayState` right after
  the Progress call, so "now playing" dashboards work.
- **The server decides what a position means.** On a 654 s video, progress and
  stop at 12 s / 15 s stored `PlaybackPositionTicks: 0` (below the server's
  minimum resume percentage, default 5 %). Stopping at 95 % set
  `Played: true`, reset the position to 0 and incremented `PlayCount`.
  Each `Sessions/Playing` start also bumped `PlayCount` and `LastPlayedDate`.
- Therefore **do not send Dusk's own 90 % auto-scrobble for Jellyfin**: the
  Stopped report already marks it played (server threshold, default 90 %), and
  an extra `POST /UserPlayedItems` double-counts `PlayCount`. Keep the local
  90 % rule only as the trigger for `TraktService.recordFinished` and for
  optimistic UI.
- Resume below 5 % is discarded server-side (Plex's threshold differs).
  Accept the server's rule; do not fake it with `UserData` writes.
- Offline replay (`OfflinePlaybackSyncManager`): a queued position becomes
  `POST /UserItems/{id}/UserData` with `PlaybackPositionTicks` +
  `LastPlayedDate`; a queued watched/unwatched becomes the `UserPlayedItems`
  call (`datePlayed=` query parameter carries the real time). No session needed.
- Call `POST /Sessions/Capabilities/Full` once after sign-in
  (`{"PlayableMediaTypes":["Video"],"SupportsMediaControl":false,"SupportsPersistentIdentifier":true}` → `204`).

## 9. Media, versions, streams

`MediaSources[]` replaces `Media[]` + `Part[]` (one level instead of two).

| `PlexMedia` / `PlexMediaPart` | Jellyfin `MediaSource` [live] |
| --- | --- |
| `Media.id`, `Part.id` | `Id` (equals the item id for the primary version) |
| `Part.key` (direct-play path) | none; build `/Videos/{itemId}/stream?static=true&mediaSourceId={Id}&ApiKey=` |
| `Part.file`, `size`, `container` | `Path`, `Size` (bytes), `Container` (ffprobe name; `mov` for `.mp4`) |
| `Media.bitrate` (kbit/s: `8133`) | `Bitrate` (bit/s: `8132996`) |
| `videoResolution`, `width`, `height` | from the video `MediaStream` (`Width`, `Height`) |
| version label / `editionTitle` | `Name` (`"Knives Out (2019) - 1080p"`, the filename) |
| `Part.accessible/exists` (`checkFiles=1`) | none; `LocationType`, `IsRemote` |
| multi-part (`Part[1…]`) | `GET /Videos/{id}/AdditionalParts` (separate items) |
| default tracks | `DefaultAudioStreamIndex`, `DefaultSubtitleStreamIndex` |

`PlexStream` → `MediaStream` (same file, stream by stream):

| Plex | Jellyfin |
| --- | --- |
| `id` (global, `284222`), used for `audioStreamID` | **`Index`** (position inside the MediaSource), used for `AudioStreamIndex` |
| `streamType` 1/2/3 | `Type` `Video`/`Audio`/`Subtitle` (also `EmbeddedImage`, `Data`) |
| `codec` `hevc`, `eac3`, `pgs`, `srt` | `Codec` `hevc`, `eac3`, **`PGSSUB`**, **`subrip`** (also `ass`, `mov_text`, `dvdsub` [doc]); compare case-insensitively through one alias table |
| `languageCode` `eng` | `Language` `eng` |
| `displayTitle` `English (EAC3 5.1 + Atmos)` | `DisplayTitle` `Surround - English - Dolby Digital Plus + Dolby Atmos - 5.1 - Default` (different wording; Dusk should keep building its own label) |
| `title` | `Title` |
| `default`, `forced`, `hearingImpaired` | `IsDefault`, `IsForced`, `IsHearingImpaired` |
| `selected` (server-side per-user choice) | none on the stream; `DefaultAudioStreamIndex` / `DefaultSubtitleStreamIndex` on the MediaSource are already user-resolved (language prefs + remembered selection) |
| `channels`, `audioChannelLayout` `5.1(side)` | `Channels`, `ChannelLayout` `5.1` |
| audio `profile` `dolby digital plus + dolby atmos` | `Profile` `Dolby Digital Plus + Dolby Atmos`; plus `AudioSpatialFormat` `DolbyAtmos` / `DTSX` / `None` |
| `DOVIPresent`, `DOVIProfile`, `DOVIBLCompatID`, `colorTrc`, `bitDepth` | `VideoRangeType` (`SDR, HDR10, HDR10Plus, HLG, DOVI, DOVIWithHDR10, DOVIWithHLG, DOVIWithEL, DOVIWithELHDR10Plus`), `VideoRange`, `DvProfile`, `DvBlSignalCompatibilityId`, `ColorTransfer` `smpte2084`, `ColorPrimaries`, `ColorSpace`, `BitDepth`, `CodecTag` (`dvh1/dvhe/hvc1/av01`, absent for MKV) |
| `frameRate`, `level`, `refFrames` | `RealFrameRate`, `AverageFrameRate`, `Level`, `RefFrames`, `IsInterlaced`, `PixelFormat` |
| external subtitle `key` | `IsExternal: true`, `Path`; delivery in §10 |
| text vs bitmap | `IsTextSubtitleStream` |

Traps [live]:

- **An external subtitle takes `Index` 0 and shifts everything.** `AV1 SDR
  Test` with a sidecar `.en.srt`: `0 = Subtitle (external)`, `1 = Video`,
  `2, 3 = Audio`. Never assume video is index 0 or that indexes equal the
  container's track numbers; VLCKit's own track ids must be mapped by order
  within type, not by `Index`.
- All 29 embedded SRT tracks on `Knives Out` report `IsDefault: true` (the
  file flags them). Do not treat `IsDefault` as "the one default"; use
  `DefaultSubtitleStreamIndex`.
- `DefaultSubtitleStreamIndex` was `4` (a PGS track) for a user with
  `SubtitleMode: Default`. Dusk's own Off/Auto/Always rules must win, exactly
  like `dusk-server-selected-tracks`: server default only as a tie-break.
- Multi-version items (`MediaSources.count > 1`, `MediaSourceCount`) exist in
  the API but none on the demo server. Preferred Version picks by resolution
  from the video stream; label from `Name`. **[doc]**

Track selection persistence (`PUT /library/parts/{id}?audioStreamID=`): no
write call exists. Jellyfin remembers the `AudioStreamIndex` /
`SubtitleStreamIndex` reported in the playback session when
`RememberAudioSelections` / `RememberSubtitleSelections` are on. Dusk's
"restore the remux auto-write at session end" dance is unnecessary: report the
user's real choice in `Sessions/Playing*`, nothing else.

## 10. Playback decision

`POST /Items/{id}/PlaybackInfo` with `{UserId, DeviceProfile, MediaSourceId,
AudioStreamIndex, SubtitleStreamIndex, MaxStreamingBitrate, StartTimeTicks,
EnableDirectPlay, EnableDirectStream, EnableTranscoding, AllowVideoStreamCopy,
AllowAudioStreamCopy, AutoOpenLiveStream}` → `{MediaSources[], PlaySessionId,
ErrorCode?}`. This replaces `/video/:/transcode/universal/decision` +
`start.m3u8` + the client-profile-extra string. `GET /Items/{id}/PlaybackInfo`
(no profile) answers `DirectPlay/DirectStream/Transcoding: true` for
everything and is useless for decisions.

Profile used here (a realistic Apple TV 4K / iPhone AVPlayer profile):
direct play `mp4,m4v,mov` × `h264,hevc,av1` × `aac,ac3,eac3,alac,flac,mp3`;
one transcoding profile `hls` / `mp4` / `hevc,h264` / `eac3,ac3,aac` /
`MaxAudioChannels 8`; hevc `VideoRangeType EqualsAny
SDR|HDR10|HDR10Plus|HLG|DOVI|DOVIWithHDR10|DOVIWithHLG|DOVIWithSDR`; subtitle
profiles `vtt/Hls` + `vtt/External`; `MaxStreamingBitrate 400 Mbit/s`.
VLCKit profile = 03 §5.1 profile A plus `External` for `srt, ass, ssa, vtt, sub`.

| File | Request | Result [live] |
| --- | --- | --- |
| MP4 AV1/AAC, MOV H.264/MP3, MP4 DV 5, MP4 DV 8.4 | AVPlayer | `SupportsDirectPlay: true` |
| `Knives Out` MKV DV 8.1 + E-AC-3 Atmos, **no explicit subtitle** | AVPlayer | HLS, `SubtitleStreamIndex=4&SubtitleMethod=Encode`, reasons `ContainerNotSupported,SubtitleCodecNotSupported` → **burn-in re-encode** |
| same, `MediaSourceId` + `SubtitleStreamIndex: -1` | AVPlayer | HLS `mp4`, `VideoCodec=hevc,h264`, `AudioCodec=eac3`, `AudioStreamIndex=1`, reason `ContainerNotSupported` (copy) |
| same, `SubtitleStreamIndex: 13` (SRT) | AVPlayer | `SubtitleMethod=Hls`, stream `DeliveryMethod: "Hls"`; still a copy |
| same, SRT, profile with only `vtt/External` | AVPlayer | `DeliveryMethod: "External"`, `DeliveryUrl: /Videos/{dashed id}/{msid}/Subtitles/13/0/Stream.vtt?ApiKey=…`; copy |
| same, PGS index 4, profile adds `pgssub/External` | AVPlayer | `DeliveryMethod: "External"`, `…/Subtitles/4/0/Stream.pgssub`; **no burn-in**, copy |
| same, `AudioStreamIndex: 2` (AC-3 commentary) | AVPlayer | `AudioCodec=ac3&AudioStreamIndex=2`, copy |
| same, `MaxStreamingBitrate: 4 Mbit/s` | AVPlayer | `VideoBitrate=3360000`, `AudioBitrate=640000`, reason `ContainerBitrateExceedsLimit` (real transcode; this is the manual quality picker) |
| same, no direct-play entry, transcoding profile exactly `hevc` / `eac3` | AVPlayer remux | reason `DirectPlayError`, `VideoCodec=hevc`, `AudioCodec=eac3` |
| `Dune: Part Two` MKV DV 7 + TrueHD Atmos + 2× AC-3, no audio index | AVPlayer | **server switched the audio track**: `DefaultAudioStreamIndex: 3`, `AudioCodec=ac3&AudioStreamIndex=3` (picked a compatible track instead of converting TrueHD); reasons `ContainerNotSupported,VideoRangeTypeNotSupported` |
| same + `DOVIWithEL` in the range list | AVPlayer | reason `ContainerNotSupported` only (DV 7 `dvcC` kept, 03 §5.3) |
| `Paddington 2`, `AudioStreamIndex: 2` (DTS) | AVPlayer | `AudioCodec=eac3,ac3,aac`, reason `AudioCodecNotSupported` (video copied, audio converted, first codec in list wins) |
| TS H.264 + TrueHD 7.1; MKV H.264 + DTS-X | AVPlayer | same: audio converted to E-AC-3, video copy |
| MKV AV1 SDR + external SRT | AVPlayer | `VideoCodecNotSupported` (re-encode), `SubtitleMethod=Hls` |
| any file | VLCKit | `SupportsDirectPlay: true`, `SupportsTranscoding: false`; embedded subs `Embed`; the sidecar SRT `External` with `DeliveryUrl …/Subtitles/0/0/Stream.srt` |

Mapping onto Dusk's ladder (`StreamResolver`, `PlaybackCoordinator+Session`,
`TranscodeDeliveryMode`):

| Dusk mode | Plex | Jellyfin |
| --- | --- | --- |
| Direct play | `{base}{Part.key}?X-Plex-Token=` | `{base}/Videos/{id}/stream?static=true&mediaSourceId=&ApiKey=` (`206`, ranges; `stream.mkv` suffix also works) |
| Remote refusal probe (`Range: bytes=0-0` → 403) | Plex remote streaming gate | not needed; `Policy.EnableMediaPlayback` / `EnableRemoteAccess`, `RemoteClientBitrateLimit` (`0` = none) |
| `spatialAudioRemux`, HDR/DV remux, DV 7 → 8.1 | decision + `directStream=1` profile extra | per-file remux profile (03 §5.4), verify `TranscodingInfo.IsVideoDirect/IsAudioDirect` |
| `directStreamFallback` (audio converted) | `directStreamAudio=0` | `AudioCodec: "eac3,ac3,aac"` in the profile |
| `manualTranscode` (quality presets) | `maxVideoBitrate`, `videoResolution` | `MaxStreamingBitrate` (+ `MaxWidth`/`MaxHeight` via a `CodecProfile` condition) |
| `av1Transcode` | forced | falls out of the profile (`VideoCodecNotSupported`) |
| `airPlay` | mpegts h264/aac | a conservative profile (`h264` + `aac`, `ts` or `mp4`) |
| Decision codes `1000/1001/2000+` | `generalDecisionCode` … | `SupportsDirectPlay/DirectStream/Transcoding` + `TranscodeReasons`; all three false = unplayable this way; `ErrorCode` (`NotAllowed`, `NoCompatibleStream`, `RateLimitExceeded`) |
| Engine choice | client (`StreamResolver`) | unchanged; feed it `MediaStream` through the common model |

Rules to encode (in addition to 03 §5.1 – 5.4):

1. **Always send `MediaSourceId`, `AudioStreamIndex` and `SubtitleStreamIndex`
   (`-1` = off).** Leaving audio open lets the server swap the track
   (Dune case); leaving subtitles open can burn in a PGS track.
2. TrueHD / DTS for AVPlayer: there is no lossless path, same as Plex. Dusk's
   existing answer (VLCKit direct play, or own TrueHD VLCKit build) stays; the
   Jellyfin audio-convert remux is only the explicit fallback.
3. Subtitles per engine:
   - VLCKit: embedded → nothing to do. Sidecar → `DeliveryUrl` (prefix base
     URL), added as a VLC slave exactly like `externalSubtitleURL` today.
   - AVPlayer, text: either `Hls` (WebVTT rendition in the manifest, appears
     as a legible option) or `External` `.vtt` rendered by Dusk's overlay.
     Switching a text subtitle with `Hls` means a new PlaybackInfo + new URL;
     `External` does not. Prefer `External` + Dusk's renderer for instant
     switching, `Hls` only if native rendering is required.
   - AVPlayer, bitmap (PGS/VobSub): claim `pgssub/External` only if Dusk can
     render `.sup` itself (it cannot today) → otherwise this file goes to
     VLCKit, which is what `StreamResolver` already does for PGS. Never let
     the server burn in unless the user asked for a quality transcode.
4. Subtitle conversion is free on the server: any text track is available as
   `Stream.vtt`, `Stream.srt`, `Stream.ass` (SRT→ASS returned a valid
   `[Script Info]` file); PGS as `Stream.sup` / `Stream.pgssub` (58 MB for a
   film); PGS → `.vtt` is `400`. **Subtitle URLs need no auth** (`200` without
   a token), so they work in offline download and with VLC without headers.
5. ASS/SSA: no sample on the demo server. Expected `Codec: "ass"`, `Embed` for
   VLCKit; attachments (fonts) in `MediaSource.MediaAttachments`,
   `GET /Videos/{id}/{msid}/Attachments/{index}`. **[doc]**

Subtitle search/download (`PS+Subtitles`): `GET /Items/{id}/RemoteSearch/Subtitles/{lang}`
and `POST /Items/{id}/RemoteSearch/Subtitles/{subtitleId}` exist but answered
**`403`** for this user (`Policy.EnableSubtitleManagement: false`, the default
for non-admins) and need a provider plugin (OpenSubtitles). Proposal: show
"Search subtitles" only when `EnableSubtitleManagement` is true; after a
download, refetch PlaybackInfo (new stream appears as external).

Cinema pre-rolls (`POST /playQueues … extrasPrefixCount`): `GET /Items/{id}/Intros?userId=`
→ `{Items: []}` here (needs an intros plugin). Call it, play what comes back
through `PlaybackCoordinator+Prerolls`, empty = nothing. No play-queue object
exists on Jellyfin; Dusk's playlist queue is already client-side.

## 11. Skip markers, chapters, scrub previews

| Dusk (Plex) | Jellyfin | Verified |
| --- | --- | --- |
| `Marker[]` via `includeMarkers=1` (`type: intro/credits`, ms) | `GET /MediaSegments/{itemId}[?includeSegmentTypes=Intro&includeSegmentTypes=Outro]` → `Items[] {Id, ItemId, Type, StartTicks, EndTicks}` | live |
| types | `Intro` → intro, `Outro` → credits, also `Recap`, `Preview`, `Commercial` | live: 47 Intro / 56 Outro / 9 Recap over 60 episodes |
| The Office S01E01 | Plex: no markers on plex-demo | Jellyfin: `Intro 0 – 54.555 s`, `Outro 1372.746 – 1405.162 s` (runtime 1405.162 s on both) |
| film credits | none on plex-demo | `Knives Out`: `Outro 7549.292 – 7817.247 s` (to the very end) |
| Chapters list | `Chapter[]` (Dusk does not use it; Chapters tab = markers) | `Chapters[] {StartPositionTicks, Name, ImageTag}`, thumbnails `/Items/{id}/Images/Chapter/{index}` | live |
| BIF (`/library/parts/{id}/indexes/sd`) | `404` on plex-demo | Trickplay: `fields=Trickplay` → `Trickplay[msid]["320"] {Width, Height, TileWidth:10, TileHeight:10, ThumbnailCount:782, Interval:10000 ms}`; sheets `GET /Videos/{id}/Trickplay/320/{n}.jpg?mediaSourceId=&ApiKey=` | live: sheets 0–7 `200` (1.2 MB / 0.68 MB), 8 `404`; `401` without token; `?ApiKey=` works |
| | | `GET /Videos/{id}/Trickplay/320/tiles.m3u8` is an `#EXT-X-IMAGES-ONLY` playlist (`#EXT-X-TILES:RESOLUTION=320x…`); not needed, the JSON has everything |

Notes:

- Segments are a **separate request** per item (not in the item payload).
  Fetch it in parallel with PlaybackInfo; failure/empty = no skip buttons.
  `MediaSource.HasSegments: true` is a hint only.
- An `Outro` that ends at the runtime is the Plex `credits` marker with
  `final=true`: drives Up Next / Skip Credits the same way.
- `Recap` has no Dusk UI; ignore in v1 (or fold a Recap that touches the Intro
  into one skip). `Commercial` could matter for Live TV recordings later.
- Trickplay coverage on the demo: 30 episodes + 2 films of 290 videos; the
  generated-preview fallback (`dusk-generated-scrub-previews`) stays as is.
  A 10×10 sheet at 320 px is ~1 MB: fetch lazily per sheet, cache per item.
- Real chapters (names + thumbnails) are available on 203 of 290 videos;
  the Chapters tab could show them for both backends, but parity today is
  markers only.

## 12. Images

Plex: `/photo/:/transcode?width=&height=&minSize=1&upscale=0&url={path}` + token.
Jellyfin: `GET /Items/{id}/Images/{Type}[/{index}]?tag=&maxWidth=|fillWidth=&fillHeight=&quality=90`,
no token (03 §10.4). All **[live]**.

| Dusk slot | Plex field | Jellyfin |
| --- | --- | --- |
| poster | `thumb` | `ImageTags.Primary` → `/Items/{id}/Images/Primary` (2000×3000 source) |
| episode still | `thumb` | episode `ImageTags.Primary` (16:9) |
| show poster on an episode | `grandparentThumb` | `SeriesId` + `SeriesPrimaryImageTag` |
| season poster | `parentThumb` | `SeasonId` (season `ImageTags.Primary`); on an episode `ParentPrimaryImageItemId` + `ParentPrimaryImageTag`; fall back to the series poster |
| background art | `art` | `BackdropImageTags[0]` → `/Images/Backdrop/0`; children: `ParentBackdropItemId` + `ParentBackdropImageTags` |
| title logo | `clearLogo` / `Image[type=clearLogo]` | `ImageTags.Logo` (PNG); children: `ParentLogoItemId` + `ParentLogoImageTag` |
| landscape card | `Image[type=coverArt]`/art | `ImageTags.Thumb` (landscape **with title baked in**) or Backdrop |
| person | `Role.thumb` (absolute URL) | `/Items/{personId}/Images/Primary?tag={PrimaryImageTag}` |
| chapter | `Chapter.thumb` | `/Items/{id}/Images/Chapter/{i}` |
| placeholder colours | `UltraBlurColors` | `ImageBlurHashes[type][tag]` (BlurHash string; needs a decoder, or ignore) |

`fillWidth`/`fillHeight` scale to *cover* the box without cropping and never
upscale (300×300 on a 2:3 poster gives 300×450), the same as Plex's
`minSize=1&upscale=0`; chapter images ignore them and come back at full size.
`maxWidth`/`maxHeight` fit inside the box (they work for chapters too). `GET /Items/{id}/Images` lists every image
with `Width/Height/Size`. The image layer needs an abstract
`ArtworkRef(kind, itemID, tag)` → URL builder per backend instead of the
server-relative path strings `PS+Images.imageURL` takes today; offline artwork
(`imageData`) needs no token for Jellyfin.

## 13. Photos

| Dusk (Plex, `PS+Photos`) | Jellyfin | Verified |
| --- | --- | --- |
| Albums (`type=14`) | `GET /Items?userId=&parentId={viewId}` → `PhotoAlbum` and plain `Folder` (a directory that only contains sub-albums: `2026` → 2 children / 60 recursive); `fields=ChildCount,RecursiveItemCount`; album cover in `ImageTags.Primary` | live (same six albums as Plex) |
| Photos in an album (`type=13,12&parent=`) | `GET /Items?parentId={albumId}&sortBy=PremiereDate,SortName&fields=Width,Height,DateCreated` → `Photo` (`MediaType: Photo`) and `Video` | live |
| Timeline (`clusterZoomLevel=1`, date desc) | `GET /Items?parentId={viewId}&recursive=true&includeItemTypes=Photo,Video&sortBy=PremiereDate,DateCreated&sortOrder=Descending` (192 items) | live |
| Display image (`/photo/:/transcode … quality=90`) | `/Items/{id}/Images/Primary?maxWidth=&quality=90` (313 KB at 2000 px) ; original: `GET /Items/{id}/Download` (auth) | live |
| EXIF | `Width, Height, ImageOrientation, CameraMake, CameraModel, ExposureTime, FocalLength, Aperture, IsoSpeedRating, Latitude, Longitude` (null for the synthetic test photos) | fields live |

Gaps: no server-side date clustering (group client-side by day/month from the
date); the test photos have **no `PremiereDate`** (no EXIF date) so the
timeline must fall back to `DateCreated` (import time), which Plex also shows
differently (`originallyAvailableAt`). `Folder` must be treated as an album.

## 14. Downloads / offline

| Dusk (Plex) | Jellyfin | Verified |
| --- | --- | --- |
| Original quality (`Part.key`) | `GET /Items/{id}/Download` (auth; `206` with ranges, `Content-Disposition` filename) — gated by `Policy.EnableContentDownloading`, item `CanDownload` | live |
| Converted quality (PMS Download Queue API) | no queue. `GET /Videos/{id}/stream.mp4?static=false&mediaSourceId=&videoCodec=h264&audioCodec=aac&videoBitRate=&maxWidth=&ApiKey=` is a progressive transcode: no `Content-Length`, **not resumable**, no progress | doc |
| Offline metadata snapshot | store the `GET /Items/{id}` JSON (+ seasons/episodes), as today with Plex payloads, but through the backend-neutral model | — |
| Sidecar subtitles saved with a download (#14) | `…/Subtitles/{index}/0/Stream.srt` for every text track (embedded ones too, a bonus over Plex) | live |
| Offline progress replay | §8 | live |

Proposal: v1 offers **Original** only for Jellyfin; the quality presets are
hidden (capability flag) rather than emulated with a non-resumable stream.
A later option is downloading the HLS remux/transcode with
`AVAssetDownloadURLSession`, which is resumable.

## 15. Live TV

`GET /LiveTv/Info` → `{Services[], IsEnabled: true}`; `Channels`, `Programs`,
`Programs/Recommended`, `Recordings`, `Timers` all `200` with empty lists;
`GET /LiveTv/GuideInfo` → `{StartDate, EndDate}` (a 7-day window). **The demo
server has no tuner, so everything below the endpoint level is [doc].**

| Dusk (Plex, `PS+LiveTV`) | Jellyfin |
| --- | --- |
| provider discovery (`/media/providers`) | `/LiveTv/Info`, `Policy.EnableLiveTvAccess`, a `livetv` view in `/UserViews` |
| channels | `GET /LiveTv/Channels?userId=&addCurrentProgram=true&enableFavoriteSorting=true` → `Number`, `ChannelNumber`, `CurrentProgram`, logo `ImageTags.Primary` |
| guide grid (`gridKey?beginsAt<=&endsAt>=`) | `POST /LiveTv/Programs` `{ChannelIds[], MinEndDate, MaxStartDate, UserId, Fields}` → programs with `ChannelId, StartDate, EndDate, IsMovie/IsSeries/IsNews/IsSports, EpisodeTitle` |
| per-device sections (`/livetv/dvrs/{id}`) | `Services[].Tuners[]`; channels carry no device grouping → one section |
| tune (`POST …/tune`) | `POST /Items/{channelId}/PlaybackInfo` with `AutoOpenLiveStream: true` → `MediaSources[0]` with `LiveStreamId`, `TranscodingUrl` or direct `Path`; close with `POST /LiveStreams/Close` `{LiveStreamId}` |
| past airing → recording (`/library/all?guid=`) | `GET /LiveTv/Recordings?userId=` (match by `ChannelId` + `StartDate`) |

Proposal: ship Jellyfin v1 **without Live TV** unless a tuner-backed test
server exists (add an M3U tuner to jellyfin-demo; Dusk's IPTV source already
covers M3U directly). The Live TV tab is driven by a capability flag.

## 16. Integrations that depend on Plex ids

| Integration | Today | Jellyfin |
| --- | --- | --- |
| Trakt (`TraktHistoryMapper`, `Guid[]`) | tmdb/imdb/tvdb from `Guid[]` | `ProviderIds.{Tmdb, Imdb, Tvdb}`; episodes: series `ProviderIds` + `ParentIndexNumber`/`IndexNumber` |
| Seerr (`POST api/v1/auth/plex`) | Plex account token | Seerr has Jellyfin auth (`POST api/v1/auth/jellyfin` `{username, password}`): needs the password again, or a Seerr local login. Availability matching via `ProviderIds`. Not verified here. |
| Top Shelf / Siri deep links | `server={serverID}&item={ratingKey}` | same shape, `item={Id}`; the snapshot must not embed tokens (image URLs need none) |
| Siri catalog (`lastViewedAt:desc`, `addedAt:desc`) | | `sortBy=DatePlayed` / `DateCreated` |
| Watchlist | discover.provider.plex.tv | none (§4) |

## 17. Gap list (everything in one place)

| # | Gap on Jellyfin | Proposed behaviour |
| --- | --- | --- |
| 1 | No hub API / promoted hubs / hide-row management | Client-composed rows: Continue Watching (Resume + NextUp), Recently Added per library; Hide Row via `LatestItemsExcludes` |
| 2 | No Watchlist | Hide row + bookmark; do not alias to favourites |
| 3 | No A–Z index with counts | Fixed alphabet, `nameLessThan` count → offset |
| 4 | No HDR/DV/Atmos/codec/language/edition filters, no user-rating sort | Filters and sorts come from a per-backend capability list |
| 5 | No star rating, only like | Hide Rate; keep Plex behaviour unchanged |
| 6 | Ratings have no source or logos | Neutral community/critic presentation |
| 7 | Trailers are mostly YouTube links | Local trailer plays in-app; remote opens externally, hidden on tvOS |
| 8 | No editions; versions named by filename | `editionTitle` nil; version label from `MediaSource.Name` |
| 9 | No guid lookup (`anyProviderIdEquals` ignored) | Client-side content key from `ProviderIds`; title search + id check for point lookups |
| 10 | Collections server-wide, no "part of" back-reference, need admin right to edit | Read-only collections; "Part of" via BoxSet children lookup (cache) or omit |
| 11 | No server list / connection ranking / Plex Home | URL entry (+ optional second URL, LAN discovery), saved accounts per server |
| 12 | Library order/hidden live in user configuration | Map onto `OrderedViews` / `MyMediaExcludes`; fall back to device-local if `EnableUserPreferenceAccess` is false |
| 13 | Photos and Videos libraries share `homevideos` | Classify by content counts |
| 14 | No server-side photo clustering, missing photo dates | Client grouping, `DateCreated` fallback |
| 15 | Resume < 5 % dropped, played at server threshold, `PlayCount` bump on start | Trust the server; no client auto-scrobble call |
| 16 | No per-part stream selection write | Report indexes in the session; server remembers |
| 17 | Server may burn in a default PGS or swap audio | Always send explicit `MediaSourceId` + both indexes |
| 18 | Subtitle search needs `EnableSubtitleManagement` + plugin | Capability-gated |
| 19 | No download queue / resumable converted downloads | Original-only in v1 |
| 20 | Pre-rolls need a plugin (`/Intros`) | Call it; empty = none |
| 21 | Live TV unverifiable (no tuner) | Capability off in v1 |
| 22 | Seerr sign-in uses the Plex token | Separate Seerr credential path for Jellyfin users |
| 23 | Stream `Index` shifts with external subs; `IsDefault` unreliable; codec names differ (`PGSSUB`, `subrip`) | Normalise in the Jellyfin → common-model mapper; never leak raw values to `StreamResolver` |
| 24 | Extras, multi-version, ASS, collections content, Similar, Live TV | Endpoints confirmed, **no test data on jellyfin-demo**: add an extras folder, a second version, an ASS file, a collection and an M3U tuner before implementation |

Things Jellyfin does **better**, worth using: token-free cacheable images,
explicit `VideoRangeType`, server-side DV stripping by profile, Atmos-correct
`dec3` (03 §5.3), subtitle format conversion, real chapters with thumbnails,
`Recap` segments, cascade watched on a series in one call.
