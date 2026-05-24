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
persists `DownloadedMediaRecord` values; queues movie, episode, season, and show
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
  Metadata/<server-id>/<endpoint-hash>.json
  Artwork/<path-hash>.jpg
  ResumeData/<global-key-hash>.resume
  Movies/<Title>/<Title>.<ext>
  TV Shows/<Show>/Season NN/S<season>E<episode> - <Episode>.<ext>
  Other/<Title>/<Title>.<ext>
```

Invariants: the root is excluded from backup; video paths in records are
relative; `absoluteURL(for:)` rejects paths outside the root; file names are
sanitized; artwork/metadata/resume names are SHA-256 hashes; delete-all removes
and recreates the root.

## Queue Lifecycle

Normal single-item flow:

```text
DownloadActionButton
  -> DownloadManager.queueDownload(ratingKey:type:)
  -> create DownloadedMediaRecord(.queued)
  -> processQueue()
  -> fetch/cache Plex metadata
  -> startDownload(.preparing)
  -> URLSessionDownloadTask(.downloading)
  -> completeDownload(.completed + relativeVideoPath)
```

Season and show downloads fetch hierarchy metadata, then call the same
single-item queue path for each episode. Single movie/episode requests should
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
background session id `com.dusk-player.app.downloads.background`; `DuskAppDelegate`
stores completion handlers in `DownloadBackgroundSessionRegistry`, and
`urlSessionDidFinishEvents` calls them. Other platforms use a default session.
Progress is throttled in the delegate and persisted less frequently by
`DownloadManager`. Pause uses `cancel(byProducingResumeData:)`; resume data is
saved under `ResumeData/` and deleted after reuse. Task descriptions carry the
record `globalKey`; use them for relaunch reconciliation instead of task ids.

Network constraints are split between URLSession configuration and
`DownloadManager`'s `NWPathMonitor`. When Wi-Fi Only is enabled and the network
is expensive or constrained, the manager pauses the queue and later resumes only
if that pause was network-driven.

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

Pitfall: cached metadata is server-scoped. Use `serverID(for:)`,
`currentServerIdentifier`, or `preferredServerIDs`; do not assume a rating key is
unique across servers.

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

Sync only considers actions for `plexService.currentServerIdentifier`. It starts
on launch and active scene phase, stops its retry loop outside active phase, and
uses per-action backoff. `markSynced` preserves newer local edits when an older
sync attempt completes late.

## UI Hooks

`DownloadActionButton` is the inline download/delete/pause/resume/retry control.
`DownloadsView` owns the downloaded movie/show grid, queue sheet, queue awake
hint, pending sync banner, ETA display, and the queue-sheet-only idle timer hold
while active downloads exist. Queue rows dismiss the sheet before appending the
media destination to the Downloads tab navigation path, so detail screens are
shown in the full tab stack rather than inside the sheet.
`MainTabView` shows the Downloads tab only when visible and records exist.
`SettingsIOSView` owns quality, Wi-Fi Only, concurrency, storage reserve, usage,
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

Do not key persisted records by rating key alone; use `serverID:ratingKey`. Do
not casually delete shared metadata/artwork; show/season browsing and up-next may
reuse it. Do not trust `downloadTaskIdentifier` across relaunch. Do not report
Plex timeline directly for local downloads. Do not make Downloads always visible
or add a generic provider abstraction unless product scope changes.

## Safe-Change Checklist

Locate the layer: storage, queue, delegate, metadata cache, playback route, sync
queue, or UI. Preserve root containment, relative paths, server-scoped keys,
completion validation, and current-server sync filtering. Keep views on
managers/view models, not files or network calls. Exercise movie, episode,
season, and show scopes; check pause, resume, cancel, retry, delete, delete-all,
Wi-Fi Only, and relaunch behavior. For offline-route changes, check cached
detail loading, local artwork, local playback, downloaded-version engine
selection, and pending sync banners. For Swift source changes, run the
compile-only `xcodebuild` command from `AGENTS.md`; docs-only changes do not
need a build.
