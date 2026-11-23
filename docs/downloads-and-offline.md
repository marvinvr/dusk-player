# Downloads And Offline Playback

## Boundaries

Core state is in `Dusk/Sources/Downloads/`; UI is in
`Dusk/Sources/Features/Downloads/`. Detail screens consume injected
`DownloadManager` and `OfflinePlaybackSyncManager`; they should not touch files
directly. Playback stays in `PlaybackCoordinator`; offline playback swaps only
the URL/source and timeline reporting path. Plex remains the source of truth,
and `DownloadsFeature.isVisible` hides downloads on tvOS.

## DownloadManager Responsibilities

`DownloadManager` is the public facade for download behavior. It loads and
persists profile-scoped `DownloadedMediaRecord` values; queues movie, episode,
season, and show
downloads; expands seasons/shows into episode records; aggregates state;
controls transfer lifecycle; selects the download media version through
`StreamResolver`; validates free-space reserve; caches Plex metadata/artwork;
exposes local playback/artwork URLs only when files exist; and reconciles
background `URLSession` tasks after relaunch.

New user-facing download behavior usually starts as a manager method, then gets
wired into `DownloadActionButton`, `DownloadsView`, or settings.

## File Store Layout

`DownloadFileStore` owns all paths under:

```text
Application Support/Dusk/Downloads/
  downloads.json
  playback-sync.json
  Metadata/Profiles/<profile-id>/<server-id>/<endpoint-hash>.json
  Artwork/<path-hash>.jpg
  ResumeData/<global-key-hash>.resume
  Subtitles/<global-key-hash>/<stream-id>.<ext>
  Profiles/<profile-id>/Movies/<Title>/<Title>.<ext>
  Profiles/<profile-id>/TV Shows/<Show>/Season NN/S<season>E<episode> - <Episode>.<ext>
  Profiles/<profile-id>/Other/<Title>/<Title>.<ext>
```

Invariants: the root is excluded from backup; video paths in records are
relative; `absoluteURL(for:)` rejects paths outside the root; file names are
sanitized; artwork/metadata/resume names are SHA-256 hashes; delete-all removes
and recreates the root.

## Queue Lifecycle

Normal single-item flow:

```text
DownloadActionButton
  -> DownloadManager.queueDownload(id:type:)   // id = PlexItemID
  -> create DownloadedMediaRecord(.queued)
  -> processQueue()
  -> fetch/cache Plex metadata
  -> startDownload(.preparing)
  -> URLSessionDownloadTask(.downloading)
  -> completeDownload(.completed + relativeVideoPath)
```

### Explicit Offline Quality

Movies, episodes, seasons, and shows present a native quality picker. Original
is the default and keeps the direct-file path; clips also keep Original. The
Download Quality setting (Auto / 4K / 1080p / 720p) selects an existing source
version. Playback’s separate Preferred Version setting is unchanged.
An explicit 320p–1080p bitrate preset asks Plex to prepare a smaller offline
copy. This does not change playback quality or start streaming transcodes.

`DownloadedMediaRecord.downloadQuality` defaults to Original for old snapshots.
Expanded episodes retain hierarchy and preset immediately; existing records keep
their own preset, and a partial show/season retry inherits the scope's saved
choice. A failed download's explicit retry resets its server job and recovery
budget while preserving source media/part IDs and quality. Pause keeps the job.

`PlexService+Downloads` owns the Download Queue API (PMS 1.41.9+). Each record
persists a unique client identifier before creating its user/client-scoped
queue. The queue ID is saved before add; listing that dedicated queue recovers
an add whose response was lost. Every operation uses captured server credentials
and checks the owning Home profile. Media indices are resolved from fresh
metadata by saved media ID, so source reordering cannot select another version.

Conversion uses the Generic profile with a **static** HTTP MKV/H.264/AAC target,
`partIndex=-1` for a joined file, and no subtitle burn-in. Polling reports
separate preparation progress. Before native handoff, the decision must confirm
the requested container/codecs; a ready-file HEAD supplies its actual size when
available. Dusk never substitutes the original file after conversion failure.
Two server preparations run at a time; a prepared file is handed to the
background session as soon as Plex reports it available (the session queues it
behind running transfers).
An expired job/file may be regenerated twice automatically; explicit Retry
starts a new recovery budget. A prepared file can expire while paused, too.

Preparation requires the app to run. On iOS 26+ the downloads continued
task (see Background Transfers) keeps Dusk running after the user leaves;
otherwise suspension delays polling/handoff until iOS wakes Dusk or the user
opens it. Queue/client/item identity survives relaunch. Once handed off,
the existing background URLSession owns transfer. Cancellation and completion
enqueue item-only cleanup; pending cleanup persists across offline periods and
profile switches and runs only with its owner's credentials. A cancellation
during add waits for that operation to unwind, then resolves any unknown item
through its dedicated queue. Never delete a whole server queue.

Converted files are saved as `.mkv` and validated against the prepared file's
size, never the original part's size. Persisted converted media supplies offline
engine selection, while original media/part IDs retain version identity. Source
stream IDs and codec/HDR fields must not label converted tracks; VLC discovers
the downloaded file's tracks. Only the source part's external subtitle sidecars
carry over (`DownloadedMediaRecord.convertedMediaVersion`, used by both the
initial local playback lookup and subtitle refresh), and AirPlay handoff returns
to the original server media metadata.

Converted copies may omit embedded subtitles; choose Original to retain the
source's embedded tracks.

## External Subtitles

Both download modes save the source part's external **text** sidecars
(`DownloadedMediaRecord.offlineSubtitleStreams`: a `key` plus a codec
`SubtitleTextDecoder.fileExtension` knows, so srt/ass/ssa/vtt/smi/MicroDVD;
never VobSub or unknown codecs). `DownloadManager.cacheExternalSubtitles` runs
right after a download completes: each `/library/streams/{id}` is fetched,
normalized to UTF-8 with a BOM (`SubtitleTextDecoder.normalizedFileData`, the
same step the VLCKit mount uses) and written to `Subtitles/`. The record keeps
`externalSubtitlePaths` (stream id → relative path; nil = never synced, empty =
the item has none) and `hasMissingExternalSubtitles`. A failed sidecar never
fails the download. Records that are unsynced or missing one (downloads made
before this existed included) are backfilled once per launch when their server
connects or the profile activates (`backfillExternalSubtitles`). Deleting a
download removes its subtitle folder; delete-all, storage usage and legacy
re-keying need nothing extra because paths are relative and under the root.

Local playback mounts them through `PlaybackCoordinator.externalSubtitleURL(for:)`
(saved copy first, server URL otherwise). An AVPlayer download lists them as
"switches to VLC engine" rows; picking one restarts the local file on VLCKit at
the live position, offline too. A remembered show sidecar starts a download on
VLCKit only when its saved copy exists. Like online playback, automatic
language selection never switches engines by itself. Sidecars added to the
server after an item finished downloading are not picked up.

Every queue API is keyed by `PlexItemID`, and `DownloadScope` carries it too:
rating keys collide across servers, so a record is only ever matched by server +
rating key. `DownloadManager.record(for:)` is strict about this: an id without a
server resolves only when exactly one record carries that rating key, never by
picking the first match — the answer feeds `localPlaybackURL` and
`downloadedMediaVersion`, where a wrong match plays a different file. Season and
show downloads fetch hierarchy metadata on the season's
or show's own server, then call the same
single-item queue path for each episode, which inherits that server.

Records and pending sync actions written before servers were identified by
machine identifier can carry the server's base URL in `serverID`. Those match no
connection and would wait forever, so `DownloadManager` and
`OfflinePlaybackSyncManager` re-key them once
(`plexService.serverID(forLegacyConnectionURI:)`, which matches the URL against
each known server's endpoints); the record's cached metadata directory moves
with it (`DownloadFileStore.relocateMetadata`). An address that resolves to no
known server is left untouched — the record stays listed and its file stays
playable offline.

The queue only starts records whose server is currently connected; the others
stay `queued` rather than failing, and `DownloadManager` observes the pool so a
server coming back re-runs the queue on its own. Such a record must say why it
is idle: `DownloadManager.queueWaitReason(for:)` turns `pool.state(for:)` into
the queue row's status text ("Waiting for <server>", "<server> is turned off"),
so a download parked behind a disabled or unreachable server never looks like a
stuck "Queued". Single movie/episode requests should
return after writing the queued record; expensive metadata fetch, media version
selection, episode context caching, and storage validation belong in queue
processing. Aggregate controls use `DownloadScope` and `relatedRecords(for:)`;
do not add separate season/show transfer records unless the product model
changes.

Status rules: `queued`/`preparing`/`downloading` are active. `paused` and
`failed` are resumable. User-facing cancel removes a non-completed queue record
and its partial/resume data; pause is the non-destructive stop. Delete is
reserved for completed local files. Completed is playable only when the local
file exists; launch-time `reconcileCompletedFiles()` removes stale completed
records and marks invalid completed files failed.

Completion must validate the transfer before a record becomes playable. Reject
non-2xx HTTP responses, text/JSON/XML error payloads, zero-byte files, and
files smaller than Plex's selected part size when that size is known. Keep the
URLSession temporary file separate from the final video path until validation
passes, then replace the final file and mark the record `completed`. A failed
validation must leave the record `failed`, not `completed`.

## Background Transfers

`DownloadTransferController` owns `URLSessionDownloadDelegate`. iOS uses
background session id `com.dusk-player.app.downloads.background`; other
platforms use a default session. Rules (pure parts in `DownloadQueuePolicy`,
tested in `DuskTests/DownloadQueuePolicyTests.swift`):

- **Hand-off ahead.** `processQueue` hands every queued Original download to
  the session right away (up to 50, four resolving at a time), not one per
  free slot. Simultaneous Downloads is the session's
  `httpMaximumConnectionsPerHost`, read when the session is created, so a
  change applies from the next launch. The session runs the rest on its own
  while Dusk is suspended or killed by the system; nothing waits for Dusk to
  wake between files. Tasks get a `priority` from their queue position (a
  hint: preparations finish in any order). A handed-off record is
  `.downloading`; until its first byte (`isAwaitingTransfer`) rows show it as
  Queued and `activeDownloadCount` leaves it out. The storage check counts
  what other handed-off transfers still need.
- **Background wake.** `urlSessionDidFinishEvents` emits
  `.backgroundEventsFinished`; the manager calls iOS's completion handler
  only after finished files are moved and the queue has handed off what it
  can (max 20 s, bringing the Plex session up on a cold launch via
  `prepareSessionForBackgroundWork`).
- **Relaunch reconciliation before a profile exists** (background launch):
  matched tasks keep running and unmatched in-flight records keep their task
  ids, so the finished-file events iOS delivers right after launch still
  complete them. `judgeRelaunchedTransfersIfNeeded` applies the
  per-profile pause/requeue once a profile is active.
- **Early failure.** A transfer that fails before any byte (stale staged URL,
  prepared file expired, unusable resume data) is requeued once with a fresh
  request instead of failing.
- **Live session (iOS 26+).** Any background-session task created while Dusk
  is in the background is discretionary for iOS (it may wait for power and
  Wi-Fi). While the continued task keeps Dusk running in the background, new
  transfers (typically a conversion Plex just finished) use an in-process
  session instead; their identifiers are negative (`-(id + 1)`). When the task
  ends or Dusk leaves the foreground without one, `moveLiveTransfersToBackgroundSession`
  pauses them (resume data) and restarts them in the background session under
  a short `beginBackgroundTask`. Resume data from the default session works in
  the background session (sim-verified, byte-identical file). DEBUG
  `-DuskDebugLiveTransfers 1` puts foreground transfers on the live session to
  exercise that move.
Progress is throttled in the delegate and persisted less frequently by
`DownloadManager`. Pause uses `cancel(byProducingResumeData:)`; resume data is
saved under `ResumeData/` and deleted after reuse. `PlexTransportSecurity`
validates new transfers and redirects. A resumed task must expose a safe
original/current endpoint before it starts; otherwise the controller discards
that task and restarts using the freshly validated request. This prevents old
resume data from restoring a public HTTP endpoint. Task descriptions carry the
record `globalKey`; use them for relaunch reconciliation instead of task ids.

Wi-Fi Only is enforced by URLSession: every transfer request sets
`allowsExpensive/ConstrainedNetworkAccess = !downloadsWifiOnly`, so on cellular
a transfer waits inside the session (also while Dusk is suspended) and goes on
by itself on Wi-Fi. Nothing is paused. `NWPathMonitor` only feeds the "Waiting
for Wi-Fi" row text (`queueWaitReason`) and the Live Activity. Request flags are
fixed per task, so toggling the setting restarts handed-off transfers from
their resume data (`wifiOnlyPreferenceDidChange`, `restartTransfer`).

### Downloads Live Activity (iOS 26+)

`DownloadContinuedTaskController` (`DownloadContinuedTask.swift`) submits one
`BGContinuedProcessingTask` (`com.dusk-player.app.downloads.continued.<uuid>`,
wildcard in `BGTaskSchedulerPermittedIdentifiers`, registered per id just
before submit, strategy `.queue`) when the user starts, resumes or retries
downloads, or turns on / changes Keep Next N. iOS draws the Live Activity
(Lock Screen, Dynamic Island) from its title, subtitle and progress and keeps
Dusk running after the user leaves, so conversions keep polling and new
transfers are created without being demoted. No widget extension.

- One task for the whole queue; items added meanwhile join it. Wording and
  bar come from `DownloadActivitySummary` (tested in
  `DuskTests/DownloadActivitySummaryTests.swift`): "Downloading 4 episodes" /
  "Downloading Severance", subtitle = the moving item, "Preparing on <server>"
  or the wait reason; a conversion is half preparation, half transfer; items
  weigh by size; the bar never moves back.
- Ends when the batch is done ("Downloaded 4 episodes", or "2 downloads
  failed" with `success: false`), when everything left has waited 20 s (Wi-Fi
  Only on cellular, server away: the session keeps those transfers), or 15 s
  after start with nothing to do.
- Expiration (the user's ✕ on the activity, or iOS ending it; the API does not
  say which) = Pause All, resume data kept.
- Submit failures (simulator: "BGTaskScheduler is not available on this
  platform", or iOS refusing) change nothing: the background session carries
  the transfers as before.
- Never submitted for automatic work: Smart Downloads refills (background task,
  after watching, on reconnect), auto-resume, relaunch reconciliation.
- Not on iOS 18–25 or the iPad app on a Mac (`isSupported`). There the queue
  sheet keeps the screen awake while downloads are active; on iOS 26+ it does
  not, and its hint says downloads continue unless the app is swiped away.

## Metadata And Artwork Cache

`PlexMetadataCache` stores raw Plex payloads by server id and endpoint:
`/library/metadata/{ratingKey}` and
`/library/metadata/{ratingKey}/children`.

Queueing fills cache progressively: movies cache their own details; episodes
cache details plus season/show context; seasons cache details, episodes, show
details, and sibling seasons; shows cache show details, seasons, and every
season's episodes.

Artwork is separate: `DownloadManager.cacheArtwork` fetches image bytes through
`PlexService` and stores hashed jpgs. Detail view models call
`localArtworkURL(for:)` first, then fall back to Plex image URLs.

Pitfall: cached metadata is profile- and server-scoped. Use the active profile
with `serverID(for:)` or `preferredServerIDs`; do not assume a rating key is
unique across profiles or servers — with several servers connected at once, it
is routinely not. Legacy cache/video paths remain readable and are adopted only
by the originally linked profile.

Plex Home adds a second identity boundary: downloaded records, offline metadata
lookups, playback-sync actions, and their global keys include `activeProfileID`
in addition to server id and rating key. A profile must never see or mutate
another profile's records merely because both can access the same server.

## Offline Startup And Recovery

On iOS, `ServerConnectionCoordinator.showsOfflineDownloads` applies the pure
`OfflineFallback` decision: no network route or no reachable server opens the
existing Downloads destination (even if empty). Partial outages keep online
content. The offline shell uses Home, Downloads and Settings so Downloads cannot
be buried in More; it stays mounted during retries and local playback.

Plex Home bootstrap and discovery fail within a 3 s request/resource budget
without waiting for connectivity. No-route startup exposes the existing error
screen on tvOS; iOS retains its guarded Downloads fallback.

Plex Home bootstrap also has to work without plex.tv. Transport failures and
5xx responses may restore the saved automatically signed-in profile, marked
`isUsingOfflineHomeSession`; a remembered Home member requires its remembered
token. This does not complete the Home migration or persist a successful online
validation. Authentication failures, missing identity, mandatory profile/PIN
selection and disabled automatic sign-in cannot use this escape hatch. tvOS
keeps its online bootstrap and has no Downloads fallback.

Network-path recovery and foreground entry re-run connection selection. While
foregrounded with a network route, offline recovery also retries every 30 seconds
so a server returning on the same network is discovered automatically. Recovery
revalidates a cached Home session and reuses the existing stored-snapshot/LAN
selection path if plex.tv is unavailable. Successful connections restore the
normal tabs without interrupting Downloads navigation or local playback.
`DuskTests/OfflineFallbackTests.swift` covers the decision, profile guards and
bootstrap with a simulated `notConnectedToInternet` failure.

## Offline Playback Route

`PlaybackCoordinator+Session.startPlaybackSession` owns the route. It prefers
cached media details when the rating key is playable offline; otherwise it
fetches live Plex details and falls back to cache on failure. It resolves media
normally, then uses `localPlaybackURL(for:selectedMediaID:)` when present or a
Plex direct-play URL otherwise. Engine selection still goes through
`StreamResolver` and `PlaybackEngineFactory`. Only local downloads use
`OfflinePlaybackSyncManager` for the effective resume offset.

Keep engines and player views source-agnostic; offline-specific playback logic
belongs in the coordinator or presentation/debug models.

For local playback, resolve the engine from the downloaded record's stored
`mediaID` and `partID`. Do not reselect a media version from normal playback
quality preferences after choosing a local file, because that can pair the
downloaded container with the wrong engine.

## Offline Watch-State Sync

`OfflinePlaybackSyncManager` persists pending actions to `playback-sync.json`.
Action kinds are `progress` (offset, duration, Plex state, optional watched
mark), `watched` (scrobble), and `unwatched` (unscrobble).

`PlaybackCoordinator+Timeline` reports every 10 seconds. Live streams report to
Plex directly. Local downloads record progress locally and opportunistically
sync. Finalization records stopped progress; crossing 90 percent queues a
watched/scrobble effect. Detail watch/unwatch actions also queue locally when
using cached data or a local file.

Sync considers actions for `plexService.activeProfileID`, and routes each action
to **its own** server: a pending action is syncable when that server is
currently connected (`pool.connection(for:)`), and actions for servers that are
offline or disabled simply wait. It starts
on launch and active scene phase, stops its retry loop outside active phase, and
uses per-action backoff. `markSynced` preserves newer local edits when an older
sync attempt completes late.

Actions recorded before Plex Home support are adopted by the original linked
profile during the one-time migration; they must not be left as unscoped
actions. Switching users pauses the outgoing profile's queue and leaves failed
sync actions attached to that profile until it becomes active again.

## Smart Downloads (Keep Next N Unwatched)

Per show, iPhone/iPad only (`DownloadsFeature`). `SmartDownloads.swift` holds
the rule (`SmartDownloadRule`: profile + server + show key, N of 3/5/10,
quality) and the pure planner (`SmartDownloadPlanner`, tested in
`DuskTests/SmartDownloadPlannerTests.swift`). Rules persist in
`downloads.json` (`smartDownloadRules`); records the rule queued carry
`isSmartDownload`.

- **Window**: the show's `allLeaves` from its own server, specials (season 0)
  left out, starting after the furthest watched episode (Continue Watching
  semantics), first N unwatched. Watched = Plex `viewCount`, overridden by
  pending offline sync (`effectiveWatchedState`) and by the episode that just
  finished in Dusk.
- **Ownership**: any existing download in the window fills a slot. Only
  `isSmartDownload` records outside the window (watched, beyond N, gone from
  the server) are removed; manual downloads are never touched.
- **Triggers**: rule created/changed, `resumePendingWork` (foreground),
  server reconnect, profile activation (those are throttled to one per minute
  per rule), and an episode crossing the watched threshold
  (`PlaybackCoordinator+Session.finalizeCurrentPlaybackSession`). Queued
  episodes go through the normal queue: background URLSession, Wi-Fi Only,
  storage reserve, concurrency.
- **Background refill** (iOS, `SmartDownloadBackgroundRefill`): a
  `BGProcessingTask` (`…smart-downloads.refill`, external power + network, so
  iOS usually runs it overnight on the charger) and a `BGAppRefreshTask`
  (`…smart-downloads.refresh`). Registered in `DuskApp.init`, scheduled on
  scene background and after each run while any rule exists, cancelled when
  none does (Info-iOS.plist: `BGTaskSchedulerPermittedIdentifiers`, modes
  `fetch` + `processing`). `DownloadManager.runBackgroundSmartRefill`
  bootstraps the Plex Home session if iOS launched Dusk without a scene,
  activates the profile, waits for the first network path, skips the run when
  Wi-Fi Only is on and the network is expensive/constrained
  (`SmartDownloadBackgroundPolicy`), connects servers, refills every rule and
  returns once each reachable episode is handed to the background URLSession.
  Wi-Fi Only is enforced again downstream: every transfer request sets
  `allowsExpensive/ConstrainedNetworkAccess = !downloadsWifiOnly`. Refills
  never show the downloads Live Activity; turning a rule on or changing N
  does (`userInitiated`).
  The simulator cannot submit BGTask requests, so
  `_simulateLaunchForTaskWithIdentifier` finds nothing there; the DEBUG
  argument `-DuskSimulateSmartRefillAfter <seconds>` runs the same task body
  (background the app first). Real scheduling needs a device.
- **Failure handling**: unreachable server or failed/empty `allLeaves`
  changes nothing. A failed episode keeps its slot until retried (no requeue
  loop). A fully watched show keeps its rule (`remainingUnwatchedCount == 0`)
  so new episodes arrive on their own, and stays in the Downloads grid.
- **Off**: Stop Keeping clears the rule and turns its downloads into ordinary
  ones. Deleting the whole show (or Delete All) also ends the rule. Deleting
  or cancelling one smart episode inside the window brings it back on the
  next refill.
- **UI**: Download Show sheet has an Episodes section (All / Next 3/5/10
  Unwatched). A smart show's hero button uses `arrow.down.circle.dotted` and
  opens an action sheet (change N, pause/resume/retry, Stop Keeping, Delete).
  Long-press menus on the button and the Downloads poster share
  `SmartDownloadMenuContent`; the poster subtitle reads "Next 5 · 3 episodes".

## UI Hooks

`DownloadActionButton` is the inline download/delete/pause/resume/retry control.
`DownloadsView` owns the downloaded movie/show grid, queue sheet, queue awake
hint, pending sync banner, transfer-rate and ETA display, and (below iOS 26
only) the queue-sheet idle timer hold while active downloads exist. Queue rows
dismiss the sheet before appending the media destination to the Downloads tab
navigation path, so detail screens are shown in the full tab stack rather than
inside the sheet.
`MainTabView` shows the Downloads tab when records exist, and always in the
iOS offline fallback (including its native empty state).
`SettingsIOSView` owns Download Quality (source-version resolution), Wi-Fi Only, concurrency, storage reserve, usage,
manual sync, and delete-all. `MediaDetailDestinationView` passes managers into
detail view models and marks routes from Downloads with
`prefersOfflineAvailability`.

Detail view models load cached data before live Plex where useful, disable play
when cached data is unavailable offline, prefer local artwork, and use
`effectiveWatched` / `effectiveViewOffsetMs` so pending local state wins over
stale Plex metadata.

## Extension Points

New preference: `UserPreferences`, settings UI, then `DownloadManager` at queue
or start time. New queue action: public manager API plus `DownloadScope`
aggregate behavior, then `DownloadContextMenuContent`. New cached metadata type:
typed accessor in `PlexMetadataCache`; keep storage raw and endpoint-keyed. New
offline playback behavior: `PlaybackCoordinator+Session` or
`PlaybackCoordinator+Timeline`, not engine views. New path rule:
`DownloadFileStore`; verify relative paths, containment, deletion, and migration.

## Pitfalls

Do not key persisted records by rating key alone; use
`profileID:serverID:ratingKey`. Route every download action — token, URL,
connectivity guard — by the record's or item's own `serverID`, never by the
primary server. A download whose server has since been disabled stays listed and
plays offline; only new network work needs the server back. Do
not casually delete shared metadata/artwork; show/season browsing and up-next may
reuse it. Do not trust `downloadTaskIdentifier` across relaunch. Do not report
Plex timeline directly for local downloads. Keep Downloads visibility tied to
records or the offline fallback. Do not add
a generic provider abstraction unless product scope changes.

## Safe-Change Checklist

Locate the layer: storage, queue, delegate, metadata cache, playback route, sync
queue, or UI. Preserve root containment, relative paths, server-scoped keys,
completion validation, and per-server sync routing. Keep views on
managers/view models, not files or network calls. Exercise movie, episode,
season, and show scopes; check pause, resume, cancel, retry, delete, delete-all,
Wi-Fi Only, and relaunch behavior. For offline-route changes, check cached
detail loading, local artwork, local playback, downloaded-version engine
selection, and pending sync banners. For Swift source changes, run the
compile-only `xcodebuild` command from `AGENTS.md`; docs-only changes do not
need a build.

Protocol/decision fixtures and legacy-record migration coverage live in
`DuskTests/PlexDownloadQueueTests.swift`. Compile-only verification does not
establish live-server behavior: before release, verify conversion permissions,
multiple versions, expiry, profile switching, cancellation during add/poll/file
transfer, full offline MKV playback, and iOS background relaunch with a real PMS.
The downloads Live Activity only runs on a device (the simulator has no
BGTaskScheduler); test it locked for a couple of hours with a converted item
in the queue. Simulator recipe for the transfer side: scratch wrapper of the
dusk-screenshots mock that throttles media GETs, reports the real short-cut
size, and fakes `/downloadQueue`; `-DuskScreenshotDownloads movie:1001@p720`
queues a conversion; background with `simctl launch … com.apple.Preferences`,
kill with `simctl terminate` (counts as a system kill, transfers continue).
