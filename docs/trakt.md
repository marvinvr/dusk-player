# Trakt Watch Tracking

Optional: each Plex profile can link a Trakt account. Every movie or episode
Plex scrobbles in Dusk is then added to that account's Trakt history. Nothing
else: no history import, no ratings, no watchlist, no other services.

## Pieces

- `TraktService/TraktService.swift`: `@Observable` service in the environment
  (constructed in `DuskApp`, also handed to `PlaybackCoordinator.traktService`).
  Owns the sign-in (browser or device code, see Flow), the per-profile
  tokens, the retry queue and the `/sync/history` calls.
- `TraktService/TraktModels.swift`: `TraktHistoryMapper` (Plex guids → Trakt
  ids), `TraktAuthorization` (iOS authorize URL + `state`, callback check),
  `TraktRequestBuilder` (every request, headers and bodies), API DTOs.
  Both pure and covered by `DuskTests/TraktMappingTests.swift`.
- `TraktService/TraktStores.swift`: tokens in the Keychain
  (`TraktAccounts`, a `[plexProfileID: TraktTokens]` map) and the pending
  history queue in UserDefaults (`TraktPendingHistory`).
- `Features/Settings/TraktSettingsView.swift`: Settings › Integrations ›
  Trakt. iOS with browser sign-in: status + Connect/Disconnect only. iOS
  without it: shows the code and opens `trakt.tv/activate` in Safari. tvOS
  swaps to the same QR + code-tile layout as the Plex sign-in.

## Flow

1. **Sign in**, one of two flows. Either way `GET /users/settings` then
   fetches the username, and the tokens are bound to the Plex profile that
   was active when sign-in started.
   - **Browser (iOS/iPadOS, only when `TRAKT_REDIRECT_URI` is a custom
     scheme such as `dusk://trakt/callback`)**:
     OAuth authorization code. Connect opens
     `trakt.tv/oauth/authorize?response_type=code&client_id&redirect_uri&state`
     in `ASWebAuthenticationSession` (`prefersEphemeralWebBrowserSession =
     false`, so an existing trakt.tv login in Safari is reused). The session
     catches the redirect's custom scheme itself, so iOS does not register
     it in `CFBundleURLTypes`. tvOS registers `dusk://` for Top Shelf links,
     which is no clash because the callback check also matches host and path.
     The callback must carry the same random `state` (32 bytes, base64url)
     or it is rejected; `error=access_denied` → "denied". Then
     `POST /oauth/token` (`grant_type=authorization_code`, the same
     `redirect_uri`). Closing the sheet is a plain cancel, with no error.
   - **Device code (tvOS always; iOS when `TRAKT_REDIRECT_URI` is empty,
     malformed or http(s) such as `http://localhost`)**. The device calls
     send no redirect; only its refreshes do (see Tokens):
     `POST /oauth/device/code` → show `user_code` and a QR of
     `verification_url`, poll `POST /oauth/device/token` every `interval`
     seconds until 200 (400 pending, 429 slow down, 418 denied, 410 expired,
     404/409 invalid).
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
  less than an hour remains, and once on a 401. Trakt rejects a refresh
  whose `redirect_uri` is not registered on the app. A browser grant
  repeats its own redirect (`TraktTokens.redirectURI`). A device-code link
  (`redirectURI == nil`, including links saved before the field existed)
  sends `TRAKT_REDIRECT_URI` when it is set, whatever its scheme
  (`TraktConfiguration.deviceRefreshRedirectURI`), and otherwise
  `urn:ietf:wg:oauth:2.0:oob`. A refresh answered with
  400/401 means the grant is gone: the profile's account is removed and
  Settings shows "Not connected".
- **Per profile**: a Plex Home user only ever writes to the Trakt account they
  linked themselves.

## Build-time keys

The Trakt client ID, secret and redirect URI are not in git (public repo):

- `Dusk/Support/Keys.xcconfig` (committed, both app targets' `configFiles`)
  sets `TRAKT_CLIENT_ID` / `TRAKT_CLIENT_SECRET` / `TRAKT_REDIRECT_URI`
  empty and then `#include? "Secrets.xcconfig"`.
- `Dusk/Support/Secrets.xcconfig` (git-ignored; template
  `Secrets.example.xcconfig`) holds the real values:

  ```
  TRAKT_CLIENT_ID = <Client ID>
  TRAKT_CLIENT_SECRET = <Client Secret>
  TRAKT_REDIRECT_URI = http:/$()/localhost
  ```

- **`TRAKT_REDIRECT_URI`** is the redirect registered on the Trakt app,
  character for character:
  - `http://localhost` (today: Trakt Development apps accept only
    localhost redirects): iOS and tvOS sign in with the device code, and
    refreshes send `http://localhost`.
  - A custom scheme, e.g. `dusk://trakt/callback` (needs a Production app,
    a request to Trakt support): iOS/iPadOS also switch to the in-app
    browser sign-in. `ASWebAuthenticationSession` cannot catch http(s)
    redirects without associated domains, which is why localhost does not.
  - Empty: device code everywhere, refreshes send
    `urn:ietf:wg:oauth:2.0:oob`, which must then be registered (Development
    apps refuse it).
- **xcconfig trap**: `//` starts a comment, so a literal `http://localhost`
  is read as `http:`. Write the `//` as `/$()/` (an empty expansion).
  `TraktConfiguration` treats a value without a host as unset. Check the
  built `Info.plist` (`TraktRedirectURI`) when in doubt.
- `Info-iOS.plist` / `Info-tvOS.plist` expose them as `TraktClientID` /
  `TraktClientSecret` / `TraktRedirectURI`; `TraktConfiguration.current`
  reads them (tvOS uses the redirect for refreshes only).
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
- **Redirect URI** (Trakt checks the `redirect_uri` of every authorize,
  token and refresh call against this list; one per line), and the same
  value in `TRAKT_REDIRECT_URI`:
  - Development app (all new apps; only localhost accepted, the oob URI
    is refused too): `http://localhost`.
  - Production app (via Trakt support), for the iOS browser sign-in:
    `dusk://trakt/callback`, with `TRAKT_REDIRECT_URI =
    dusk:/$()/trakt/callback`. Keep `http://localhost` (or the oob URI)
    listed as well while older builds are in use.
- **JavaScript (CORS) origins**: empty
- **Permissions** (`/checkin`, `/scrobble`): leave unchecked, Dusk only uses
  `/sync/history`.

Then copy **Client ID** and **Client Secret** into `Secrets.xcconfig`.

## Verification

- Unit tests: `DuskTests/TraktMappingTests.swift`.
- Screenshot mode (DEBUG): `-DuskScreenshotScreen trakt` opens Settings ›
  Trakt; `-DuskScreenshotTrakt <url>` points the API (and the iOS authorize
  page) at a mock; `-DuskScreenshotTraktSignIn 1` starts sign-in on open.
- iOS browser sign-in on a device: Connect → Trakt sheet → approve → back to
  "Connected as …"; also try closing the sheet (back to "Not connected", no
  error) and denying on Trakt ("Sign-in was denied").
- On a device with real keys: link, finish a movie and an episode (and one
  from a download while offline, then go online), check trakt.tv history;
  switch Plex Home profile and confirm the other profile is not linked.
