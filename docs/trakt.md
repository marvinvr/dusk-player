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
  ids), `TraktAuthorization` (iOS PKCE + `state`, callback check),
  `TraktRequestBuilder` (every request, headers and bodies), API DTOs.
  Both pure and covered by `DuskTests/TraktMappingTests.swift`.
- `TraktService/TraktStores.swift`: tokens in the Keychain
  (`TraktAccounts`, a `[plexProfileID: TraktTokens]` map) and the pending
  history queue in UserDefaults (`TraktPendingHistory`).
- `Features/Settings/TraktSettingsView.swift`: Settings › Integrations ›
  Trakt. iOS: status + Connect/Disconnect with browser sign-in. tvOS:
  the same QR + code-tile layout as the Plex sign-in. Includes the required
  Trakt non-endorsement notice on both platforms.

## Flow

1. **Sign in**, one of two flows. Either way `GET /users/settings` then
   fetches the username, and the tokens are bound to the Plex profile that
   was active when sign-in started.
   - **iOS/iPadOS: authorization code + PKCE (S256)**. A fresh random
     32-byte verifier and a separate random state live in memory for each attempt.
     `ASWebAuthenticationSession` opens `https://auth.trakt.tv/oauth/authorize`
     with `response_type=code`, `client_id`, the registered HTTPS `redirect_uri`,
     `state`, `code_challenge=base64url(SHA256(verifier))`, and
     `code_challenge_method=S256`. Safari cookies can be reused.
     The session uses `.https(host: "getdusk.app", path: "/trakt/callback")`
     to receive `https://getdusk.app/trakt/callback` directly. The iOS 18.0
     deployment target already supports this iOS 17.4 API; no scheme fallback
     is needed. The app checks HTTPS, host, exact path and state, rejects
     duplicate OAuth parameters, then exchanges the code with the original
     verifier and the same HTTPS redirect URI. Unclaimed URLs delivered to
     `DuskApp.onOpenURL` or browsing `NSUserActivity` are ignored, including
     cold launches: only the live session completion can exchange a code.
     Denial is an error; closing the sheet is a plain cancellation. Invalid
     redirect configuration fails sign-in; iOS never falls back to device codes.
   - **tvOS: device code**. `POST /oauth/device/code` sends `client_id`;
     `POST /oauth/device/token` sends `code` and `client_id` only. Show the
     returned verification URL/QR and poll at `interval` until expiry
     (400 pending, 429 slow down, 418 denied, 410 expired, 404/409 invalid).
   - All OAuth calls, including refresh and revoke, use **auth.trakt.tv**;
     `/users/settings` and `/sync/history` stay on **api.trakt.tv**.
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
- **Tokens**: refreshed when less than an hour remains, and once on a 401.
  Refresh sends `client_id`, `refresh_token`, `grant_type=refresh_token` and
  a registered HTTPS `redirect_uri`, with no secret or verifier. Browser
  grants repeat their saved HTTPS redirect; device and older custom-scheme /
  localhost grants use the configured HTTPS redirect. A legacy grant may need
  reconnecting if Trakt no longer accepts it. Refresh tokens are single-use:
  replace both tokens with every successful response. A refresh answered with
  400/401 removes the local account and Settings shows "Not connected".
- **Disconnect** removes local tokens and pending history immediately and makes
  a best-effort secret-free `/oauth/revoke` request (`token`, `client_id`).
- **Per profile**: a Plex Home user only ever writes to the Trakt account they
  linked themselves.

## Public-client configuration

Only `TRAKT_CLIENT_ID` and `TRAKT_REDIRECT_URI` are supported. No secret belongs
in source, xcconfig, Info.plist, request bodies or the shipped app.
`Keys.xcconfig` defaults the redirect to `https://getdusk.app/trakt/callback`;
`Secrets.xcconfig` optionally overrides the public settings. Without a client ID,
the Trakt row stays hidden. Both Info.plists expose only `TraktClientID` and
`TraktRedirectURI`.

```
TRAKT_CLIENT_ID = <Client ID>
TRAKT_REDIRECT_URI = https:/$()/getdusk.app/trakt/callback
```

`//` starts an xcconfig comment: use `/$()/` to preserve the slashes. Non-HTTPS,
localhost, user-info, query and fragment redirects are rejected. Remove legacy
secret entries from local configs. `scripts/testflight.sh` filters the local
config to these two settings when preparing an archive; it never copies the
whole file (which might still contain an old secret).

Register `https://getdusk.app/trakt/callback` exactly on Dusk's Production Trakt
app. Other redirect hosts, paths, ports and custom schemes are rejected.
The website lives in `~/Development/Private/dusk-player-website`:

- `/.well-known/apple-app-site-association` is served directly as
  `application/json`, without a redirect. It declares
  `WZ6VURTF6A.com.dusk-player.app` for `applinks` (`/trakt/callback*`) and
  `webcredentials`. Team ID `WZ6VURTF6A` was cross-checked against
  `ASC_TEAM_ID` in the existing `~/.config/testflight/env` signing setup.
- Only the iOS app's `Dusk.entitlements` declares `applinks:getdusk.app` and
  `webcredentials:getdusk.app`. The latter permits the HTTPS web-session
  callback; tvOS and Top Shelf keep their existing entitlements. Associated
  Domains must also be enabled on the iOS App ID and provisioning profile
  (managed separately by Tim; no signing/ASC changes here).
- nginx serves both `/trakt/callback` and `/trakt/callback/` directly,
  avoiding an HTTP directory redirect behind the TLS proxy. The page is just
  a neutral return-to-app fallback when the system does not intercept the
  link; no scheme bounce, tracking, scripts, external assets or query storage.
  Responses disable caching and nginx access logging, and set `no-referrer`.

The authorization code is exchanged only on the device.
Dusk uses `/sync/history`; it needs no `/checkin` or `/scrobble` permission.

## Current Trakt requirements and remaining release decisions

Checked 2026-11-05 against the official [PKCE guide](https://developer.trakt.tv/docs/pkce),
[authentication guide](https://developer.trakt.tv/docs/authentication-oauth),
and [OpenAPI schema](https://developer.trakt.tv/openapi.json).

| Endpoint (auth.trakt.tv) | Public-client body / parameters | Secret required? |
| --- | --- | --- |
| GET /oauth/authorize | client ID, HTTPS redirect, state, S256 challenge | No |
| POST /oauth/token (code) | client ID, redirect, code, grant type, verifier | No |
| POST /oauth/device/code | client ID | No |
| POST /oauth/device/token | client ID, device code | No |
| POST /oauth/token (refresh) | client ID, redirect, refresh token, grant type | No |
| POST /oauth/revoke | client ID, access token | No |

The schema explicitly makes `client_secret` optional/deprecated on token,
device-token and revoke requests. No endpoint used by Dusk requires it.
The guide is less explicit about device/refresh; the schema resolves that.

The redirect uses the owned HTTPS domain in accordance with Trakt's PKCE
requirements. Apple's [HTTPS callback API](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/callback/https(host:path:))
requires an associated domain; see [Supporting Associated Domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains)
and Apple's [HTTPS callback / webcredentials discussion](https://developer.apple.com/forums/thread/838975).
Apple's association CDN and device caches can lag a fresh AASA deployment;
installation or an app update triggers association verification.

The [API Use Policy](https://developer.trakt.tv/docs/api-use-policy) permits
user-authorized media-player history sync. Dusk limits access to opted-in
profiles, bounded finished-item history and connection status; disconnect
stops access. Settings includes the required non-endorsement notice. The
website privacy policy explains the optional connection, local retention,
disconnect and deleting previously sent history through Trakt. Add the same
notice to the App Store description before release: "Dusk uses Trakt but is not
endorsed or certified by Trakt". Store metadata and Production registration
are managed outside this repository.

## Verification

- Unit tests: `DuskTests/TraktMappingTests.swift` (RFC 7636 S256 vector, fresh
  verifier/state, HTTPS callback validation, rejection of custom schemes and
  mismatched origins/paths/ports, owned redirect configuration and every
  secret-free request).
- Published association: `curl -i https://getdusk.app/.well-known/apple-app-site-association`
  must return 200, `Content-Type: application/json`, no `Location` redirect,
  and the iOS app ID in both service sections. Device association verification
  also depends on Apple's CDN cache and an entitled provisioning profile.
- Screenshot mode (DEBUG): `-DuskScreenshotScreen trakt` opens Settings ›
  Trakt; `-DuskScreenshotTrakt <url>` points the API (and the iOS authorize
  page) at a mock; `-DuskScreenshotTraktSignIn 1` starts sign-in on open.
- iOS browser sign-in on a device: Connect → Trakt sheet → approve → back to
  "Connected as …"; also try closing the sheet (back to "Not connected", no
  error) and denying on Trakt ("Sign-in was denied").
- On a device with real keys: link, finish a movie and an episode (and one
  from a download while offline, then go online), check trakt.tv history;
  switch Plex Home profile and confirm the other profile is not linked.
