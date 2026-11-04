# Trakt Watch Tracking

Optional: each Plex profile can link a Trakt account. Every movie or episode
Plex scrobbles in Dusk is then added to that account's Trakt history. Nothing
else: no history import, no ratings, no watchlist, no other services.

## Pieces

- `TraktService/TraktService.swift`: `@Observable` service in the environment
  (constructed in `DuskApp`, also handed to `PlaybackCoordinator.traktService`).
  Owns the device-code sign-in, the per-profile tokens, the retry queue and
  the `/sync/history` calls.
- `TraktService/TraktModels.swift`: `TraktHistoryMapper` (Plex guids → Trakt
  ids), `TraktRequestBuilder` (every request, headers and bodies), API DTOs.
  Both pure and covered by `DuskTests/TraktMappingTests.swift`.
- `TraktService/TraktStores.swift`: tokens in the Keychain
  (`TraktAccounts`, a `[plexProfileID: TraktTokens]` map) and the pending
  history queue in UserDefaults (`TraktPendingHistory`).
- `Features/Settings/TraktSettingsView.swift`: Settings › Integrations ›
  Trakt. iOS shows the code and opens `trakt.tv/activate` in Safari; tvOS
  swaps to the same QR + code-tile layout as the Plex sign-in.

## Flow

1. **Sign in** (device flow, OAuth redirect `urn:ietf:wg:oauth:2.0:oob`):
   `POST /oauth/device/code` → show `user_code` and a QR of
   `verification_url`, poll `POST /oauth/device/token` every `interval`
   seconds until 200 (400 pending, 429 slow down, 418 denied, 410 expired,
   404/409 invalid). Then `GET /users/settings` for the username. Tokens are
   bound to the Plex profile that was active when sign-in started.
2. **Finished item**: both scrobble sites (`reportCurrentTimeline` and
   `finalizeCurrentPlaybackSession`, the 90 % rule, `hasScrobbled` keeps it to
   once per session) call `reportFinishedToTrakt()`. Local downloads included;
   Live TV never scrobbles, so never reaches Trakt.
3. `recordFinished` maps the item, appends it to the queue and flushes in a
   detached `Task`. The flush sends one `/sync/history` per profile with
   `watched_at` = the moment it finished, so a late retry still lands at the
   right time.

`/sync/history` instead of `/scrobble/start|pause|stop`: one call per finished
item, no session state to mirror, and it can be retried hours later offline.
The trade-off is no "watching now" on Trakt.

## Matching

- Modern agents: the `Guid` array (`imdb://tt…`, `tmdb://…`, `tvdb://…`).
  Episodes carry their own episode ids, so they go in `episodes[]`.
- Legacy agents: the scalar guid. `com.plexapp.agents.imdb|themoviedb://<id>`
  → movie; `com.plexapp.agents.thetvdb|themoviedb://<show>/<season>/<episode>`
  → `shows[].seasons[].episodes[]` by number.
- Anything else (`local://`, `plex://` without `Guid`, Hama/AniDB, clips) is
  skipped and logged (`Trakt` OSLog category). Trakt's `not_found` is logged too.

## Invariants

- **Playback never depends on Trakt.** `recordFinished` is synchronous queue
  work plus a background task; no error is surfaced anywhere but the log.
- **Light retry only.** Network errors, 401 (after one refresh), 429 and 5xx
  keep an entry (`attempts += 1`, dropped after 8). Other 4xx drop it. The
  queue keeps at most 200 entries. It is flushed on record, on launch (first
  `.active`) and on every return to the foreground. Disconnecting drops the
  profile's pending entries.
- **Tokens**: Trakt access tokens are short-lived; they are refreshed when
  less than an hour remains, and once on a 401. A refresh answered with
  400/401 means the grant is gone: the profile's account is removed and
  Settings shows "Not connected".
- **Per profile**: a Plex Home user only ever writes to the Trakt account they
  linked themselves.

## Build-time keys

The Trakt client ID and secret are not in git (public repo):

- `Dusk/Support/Keys.xcconfig` (committed, both app targets' `configFiles`)
  sets `TRAKT_CLIENT_ID` / `TRAKT_CLIENT_SECRET` empty and then
  `#include? "Secrets.xcconfig"`.
- `Dusk/Support/Secrets.xcconfig` (git-ignored; template
  `Secrets.example.xcconfig`) holds the real values:

  ```
  TRAKT_CLIENT_ID = <Client ID>
  TRAKT_CLIENT_SECRET = <Client Secret>
  ```

- `Info-iOS.plist` / `Info-tvOS.plist` expose them as `TraktClientID` /
  `TraktClientSecret`; `TraktConfiguration.current` reads them.
- `scripts/testflight.sh` builds from `git archive`, so its `PREPARE` step
  copies `Dusk/Support/Secrets.xcconfig` from the clone it runs in. Without
  that file the build still succeeds and the Trakt row is simply hidden
  (a warning goes to the build log). Put the file in every clone you run
  `testflight.sh` or local builds from.
- A client secret inside an app binary is never truly secret; keeping it out
  of the public repo just stops casual reuse.

### Registering the Trakt app

At <https://trakt.tv/oauth/applications/new>:

- **Name**: Dusk
- **Description**: e.g. "Dusk, a Plex player for iPhone, iPad and Apple TV.
  Adds movies and episodes you finish to your Trakt history."
- **Redirect URI**: `urn:ietf:wg:oauth:2.0:oob`
- **JavaScript (CORS) origins**: empty
- **Permissions** (`/checkin`, `/scrobble`): leave unchecked, Dusk only uses
  `/sync/history`.

Then copy **Client ID** and **Client Secret** into `Secrets.xcconfig`.

## Verification

- Unit tests: `DuskTests/TraktMappingTests.swift`.
- Screenshot mode (DEBUG): `-DuskScreenshotScreen trakt` opens Settings ›
  Trakt; `-DuskScreenshotTrakt <url>` points the API at a mock;
  `-DuskScreenshotTraktSignIn 1` starts the device flow on open.
- On a device with real keys: link, finish a movie and an episode (and one
  from a download while offline, then go online), check trakt.tv history;
  switch Plex Home profile and confirm the other profile is not linked.
