# Legacy container fixtures (G4)

Bytes an existing Dusk install has on disk, in UserDefaults or in the Keychain,
produced by the **pre-refactor baseline build** (commit `55a2ef6`, branch
`jf-p0-00`, 2026-11-27). The Jellyfin/provider refactor (05-plan, Phase 0) must
keep reading all of them unchanged. Tests:

- `DuskTests/LegacyContainerTests.swift`: synthetic fixtures, decode field by
  field + re-encode through the store and compare as parsed JSON.
- `DuskTests/RealLegacyContainerTests.swift`: the captured install below.
- `DuskTests/PersistedGoldenStringTests.swift` (G5) also reads one metadata file.
- `DuskTests/LegacyContainerRecorder.swift` wrote the synthetic files.
- Shared helpers and input values: `DuskTests/LegacyContainerSupport.swift`.

Tests load these files through `#filePath`, not the test bundle. Every name is
globally unique because xcodegen also copies them into the test bundles as flat
resources.

**Never edit or re-record these files after the refactor has started.** A
failing G4 test means the new code broke an old install; fix the code. Only
re-record on the baseline commit (for example to add a fixture), and say so in
the commit.

## Synthetic fixtures (recorded by `LegacyContainerRecorder`)

Each file is the exact bytes the named store wrote for the values in
`LegacyContainerRecorder` / `LegacyValues`.

| File | Where an install keeps it | Written by |
| --- | --- | --- |
| `LegacyContainer-downloads.json` | `Application Support/Dusk/Downloads/downloads.json` | `DownloadFileStore.saveSnapshot`: three `DownloadedMediaRecord`s (owner movie with Int-keyed `externalSubtitlePaths`, Home-member converted episode with a `convertedMediaData` `PlexMedia` blob, a pre-Plex-Home record whose `serverID` is a base URL), one `DownloadQueueRemoval`, one `SmartDownloadRule` |
| `LegacyContainer-playback-sync.json` | `…/Downloads/playback-sync.json` | `OfflinePlaybackSyncStore.saveSnapshot`: progress, watched (legacy, no profile), unwatched |
| `LegacyContainer-PinnedHomePlaylists.json` | defaults `PinnedHomePlaylists.v1.<profileID>` | `PinnedPlaylistStore.pin`: one pin with a server, one without |
| `LegacyContainer-ShowTrackPreferences-track.json` | defaults `ShowTrackPreferences.v1.<len:profile><len:server><len:show>` | `ShowTrackPreferenceStore.save`: audio + `.track` subtitle |
| `LegacyContainer-ShowTrackPreferences-off.json` | same | subtitles `.off`, no audio |
| `LegacyContainer-PlexServerPriority.json` | defaults `PlexServerPriority` | `ServerPriorityStore.setEnabled` |
| `LegacyContainer-PlexServerSnapshots.json` | defaults `PlexServerSnapshots` | `ServerPool.saveSnapshots` (token stripped) |
| `LegacyContainer-PlexActiveHomeUserData.json` | defaults `PlexActiveHomeUserData` | `JSONEncoder().encode(PlexHomeUser)`, as `PlexService.persistActiveHomeUser` does (the method is private) |
| `LegacyContainer-IPTVSources.json` | defaults `IPTVSources.<profileID>` | `IPTVSourceStore.save` |
| `LegacyContainer-IPTVSourceHeaderValues.json` | Keychain `IPTVSourceHeaderValues` | `IPTVSourceStore.setHeaderValue` (in-memory secret seam) |
| `LegacyContainer-iptvResumePoints.json` | defaults (and iCloud KVS) `iptvResumePoints` | `IPTVResumeStore.record`: one resume point, one tombstone |
| `LegacyContainer-TraktAccounts.json` | Keychain `TraktAccounts` | `TraktCredentialStore.save` (read back from the simulator Keychain) |
| `LegacyContainer-TraktPendingHistory.json` | defaults `TraktPendingHistory` | `TraktHistoryQueue.save` |
| `LegacyContainer-SeerrSessions.json` | Keychain `SeerrSessions` | `SeerrCredentialStore.save` (read back from the simulator Keychain) |
| `LegacyContainer-SiriCatalogEntries.json` | entries of defaults `siriTitleCatalog` | `JSONEncoder().encode([SiriCatalogEntry])` (the `Stored` envelope is private; see the real capture) |
| `LegacyContainer-WatchTogetherActivity.json` | SharePlay activity payload | `JSONEncoder().encode(DuskWatchTogetherActivity)` |
| `LegacyContainer-TopShelfSnapshot.json` | App Group `Library/Caches/TopShelf/snapshot.json` (tvOS) | `JSONEncoder().encode(TopShelfSnapshot)` with `TopShelfLink.url` deep links; recorded on tvOS |

`convertedMediaData` inside `LegacyContainer-downloads.json` is base64 of an
unsorted `JSONEncoder` output, so its bytes change on every re-record; the
tests compare it as parsed JSON. Everything else re-records identically.

## Captured install (`LegacyContainer-real-*`)

A real container from the Debug app of the baseline commit, on a disposable
iPhone 18 Pro / iOS 27.0 simulator, in screenshot mode against the mock server:

```bash
python3 scripts/mock_large_plex.py --movies 200 --shows 100 --rtt 0 --scan-us 0 --item-us 0 --port 47720
xcrun simctl install <sim> build/…/Debug-iphonesimulator/Dusk.app
xcrun simctl launch <sim> com.dusk-player.app -DuskScreenshotMode YES \
  -DuskScreenshotPlexTV http://127.0.0.1:47720 -DuskScreenshotScreen downloads \
  -DuskScreenshotSeedDownloads movie:1004,season:750001 -DuskScreenshotMute 1
# ~25 s later: xcrun simctl terminate <sim> com.dusk-player.app, then copy from
# $(xcrun simctl get_app_container <sim> com.dusk-player.app data)
```

(`--shows 40` makes the mock crash: it samples 80 watched shows.)

| File | Source in the container |
| --- | --- |
| `LegacyContainer-real-downloads.json` | `Library/Application Support/Dusk/Downloads/downloads.json` (movie 1004 + the 4 episodes of season 750001) |
| `LegacyContainer-real-metadata-<first 12 hex of the hash>.json` | the 9 raw PMS payloads under `…/Downloads/Metadata/Profiles/bigplexuser/bigplexserver…001/` |
| `LegacyContainer-real-manifest.json` | each metadata file's original relative path, the artwork file names (`…/Artwork/`, bytes not kept), the placeholder video paths (not kept: sparse, multi-GB), and the string/bool Plex defaults keys with their values (`PlexClientIdentifier` left out) |
| `LegacyContainer-real-PlexServerSnapshots.json`, `-PlexServerPriority.json`, `-PlexActiveHomeUserData.json`, `-siriTitleCatalog.json` | the `Data` values of those keys in `Library/Preferences/com.dusk-player.app.plist` |

## Re-recording (baseline commit only)

```bash
xcodegen generate
xcodebuild -project Dusk.xcodeproj -scheme Dusk -configuration Debug \
  -destination 'platform=iOS Simulator,id=<disposable sim>' -derivedDataPath build/g4-dd-ios \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build-for-testing
TEST_RUNNER_DUSK_RECORD_LEGACY_CONTAINER=1 xcodebuild … -parallel-testing-enabled NO \
  -only-testing:DuskTests/LegacyContainerRecorder test-without-building
# Top Shelf: same with -scheme Dusk-tvOS, a tvOS simulator and
# -only-testing:DuskTests-tvOS/LegacyContainerRecorder/recordTopShelfSnapshot()
```

The recorder writes straight into this directory (the simulator can reach the
host file system). The real capture is redone by hand with the commands above,
on a fresh simulator, before any test run on it (hosted tests write into the
same app container).

## Ids stored as Int today

`mediaID`, `partID`, the `externalSubtitlePaths` keys and `PlexHomeUser.id`
are written as JSON numbers by the baseline build. The decode tests are the
contract: they must keep passing for every later build. The re-encode checks
also pin today's *write* format. If P0-02 needs these ids to encode as
strings, that is a persisted-format change (05 §1: "a package that needs one
stops and asks"), so it needs the coordinator's sign-off. Only then may the
re-encode expectation for those fields change, never the decode tests or the
fixture bytes.
