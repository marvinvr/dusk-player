# Phase 0 parity gate

Tools for the "zero behaviour change" gate in
[`docs/jellyfin/05-plan.md` §3](../../docs/jellyfin/05-plan.md). The baseline
was recorded on the tree before P0-01. A difference means the package has a
bug. Never re-record to make one go away. Re-recording is only legitimate on
app sources identical to the baseline, for example after an Xcode or
simulator runtime update. `baseline/recorded.json` names them by tree hash
(`app_trees` for `Dusk/`, `DuskTopShelf/`, `project.yml`). The tree was main
at `55a2ef6`. Check out such a tree, record, then return.

| Check | Command | Baseline |
| --- | --- | --- |
| G1 unit tests | `scripts/parity/units.py check` (runs `scripts/test_units.py`, ~20 min) | `baseline/units.json` |
| G2 request log + G3 pixels | `scripts/parity/screens.sh check` (≈ `gate.py screens check`) | `baseline/<platform>/<screen>.{requests.txt,png}` |
| G4 persisted data | unit tests `LegacyContainerTests`, `RealLegacyContainerTests` (part of G1) | `DuskTests/Fixtures/LegacyContainer/` |
| G5 golden strings | unit tests `PersistedGoldenStringTests`, `PersistedPreferenceGoldenTests` (part of G1) | literals in the tests |
| G6 plex-demo smoke | `scripts/parity/smoke_plex.sh check` | `~/.cache/dusk-parity/smoke-baseline` (machine-local) |
| G7 boundary | `scripts/parity/check_provider_boundary.sh [--enforce]` | `provider_boundary_allowlist.txt` |

Exit status is 0 only when nothing differs. Everything a run produces goes to
`build/parity/runs/<time>/`, which is git-ignored. That includes logs,
screenshots, normalised request lists, and `diff/` with expected, actual and
diff images plus `.requests.diff`.

## How G2/G3 work (`gate.py`)

- **Builds.** It builds the Debug app with
  `-derivedDataPath build/parity/dd-<sdk>`.
- **Simulators.** For each platform it creates a disposable simulator with the
  exact device type and runtime from `baseline/manifest.json`, and deletes it
  afterwards. The platforms are iPhone 18 Pro and iPad Pro 13" on iOS 27.0,
  and Apple TV 4K 1080p on tvOS 27.0. The tvOS 27.2 simulator renders pushed
  pages black.
- **Fixed environment.**
  - dark appearance
  - status bar at 9:41
  - `-AppleLanguages (en) -AppleLocale en_US`
  - tvOS clock off (`-showsClock <false/>`)
- **Each screen in isolation.**
  1. A fresh `parity_mock.py` starts on a free port with its own request log.
  2. The app is reinstalled, so its container is empty.
  3. The app launches in `-DuskScreenshotMode` on the screen's route.
  4. The driver waits until no request has arrived for `quiet_seconds`, and
     at least `min_seconds`.
  5. After `settle_seconds` it takes a screenshot and terminates the app.
- **G2.** Each screen's requests are compared as a sorted multiset of
  `[role] METHOD path?sorted-query`. The baseline merges three fresh runs.
  Dusk fetches a few requests a racy number of times (45 of 7 653 baseline
  lines). Those keep the recorded range (`1-2`) and only get a note outside
  it. So do the manifest's `count_free` patterns: session restore,
  connection probes, image loads and Home recommendation genre probes. Their
  repeat count races even when three runs happened to agree. For those, presence stays strict. Every other count
  must match exactly. Image requests (`/photo/:/transcode`) are compared by
  identity, the `url=` path. A new identity fails, and so does an identity
  whose sizes share nothing with the baseline. A missing identity (an
  off-screen prefetch) or an extra transient size is only a note. G3 checks
  what is actually on screen. Background prefetches that run
  or not depending on timing are listed in the manifest's `optional` rules,
  each with a `why`. Before comparing, the driver:
  - strips tokens and client, session and device fields (`STRIPPED_QUERY`);
  - rewrites unix times within about two years of the request as day offsets
    (`<now-30d>`);
  - folds UUIDs to `<uuid>`.
- **G3.** Screenshots are stored and compared at 1/scale with a box filter,
  which is point resolution on iPhone and iPad. A difference is a pixel past
  `fuzz_percent` (4 %). A screen fails when the share of such pixels exceeds
  `max_differing_share` (0.02 %: 70 px on iPhone, 284 px on iPad, 104 px on
  Apple TV). Across the 3 baseline runs the worst noise was 1, 28 and 8 px.
  The capture waits for two frames 1.5 s apart to agree, so a running
  transition is never stored. `masks` black out the app version on Settings,
  which `main` bumps independently. `record` refuses near-uniform frames,
  such as black pushes or blank launches.
- **`check`.** It refuses to compare when Xcode differs from `recorded.json`.

`parity_mock.py` wraps `scripts/mock_large_plex.py` without changing it:

- **Clock.** The mock's clock is its start time, so data ages relative to the
  app's own clock are the same every day.
- **Request log.** Every request is logged in full, images included.
- **Empty routes.** `/hubs/search` and `/playlists*` get fixed answers.
- **Photo library.** It is served only to the `photos` screen (per-screen
  `mock` override). Dusk shows a Photos tab only after a racy emptiness
  probe returns, so on every other screen the library would make the tab
  bar nondeterministic.
- **Images.** Every image is a solid colour derived from its identity (rating
  key plus thumb/art/composite), whatever size is requested. A screen that
  picks a different image changes colour.

`gate.py screens repeat` runs everything twice and compares the runs. That is
the determinism check for the harness itself; run it after changing the
harness.

A screen with `expect` (a request its destination always sends) is
captured again, up to three times, when that request is missing; the log
says `RETRY`. That covers the photos screen: in about one launch in nine,
Dusk never sends the photo-library emptiness probe, so the route never fires
and the app stays on Home. This is a pre-existing app race. On a real install
it would show up as a missing Photos tab until the next refresh.

`downloads` runs on iPhone only. With no downloads, iPad has no Downloads
tab and tvOS has none, so the route would land on Home.

After a manifest change that only touches `optional`, `masks` or
`tolerance`, `gate.py screens record --reuse --out <earlier record dir>`
re-merges the existing runs without capturing again. Only do this on the
baseline commit.

Useful options:

- `--platforms iphone,tv`
- `--screens home,search`
- `--compare-to <run dir>`, to compare against another run's full-resolution
  output

## G6 (`smoke_plex.sh`)

G6 uses the same driver. `smoke_proxy.py` stands in for plex.tv and
plex-demo:

- **Sign-in.** It signs in as the comparison user with
  `~/.config/jellyfin-demo/compare-plex-login` and `compare-password`. The
  token stays in memory, and logs show `<token>`.
- **Fake token.** It swaps the token in for the screenshot-mode fake token.
- **Routing.** It routes the one server through itself.
- **Writes.** Writes other than timeline, scrobble, play queues and transcode
  get a 403 and are logged as `[BLOCKED]`.

The screens are listed in `smoke_manifest.json`. Player and download screens
run for a fixed time, and only their requests are compared, with positions,
segment numbers and periodic requests folded. The baseline holds real titles
and server ids, so it stays in `~/.cache/dusk-parity`. Plex-demo is live and
shared, so after T-0 changes its data or the comparison user's state,
re-record the G6 baseline on the baseline commit first.

The baseline was recorded on iPhone from two runs on 2026-11-27. Record
Apple TV with `PLATFORMS=tv smoke_plex.sh record` if you need it.

On the simulator, `play-remux` (title 10, E-AC-3 JOC HDR10) direct-plays: the
simulator's display is SDR (`AVPlayer.eligibleForHDRPlayback` is false), so the
ladder's HDR gates stop before any `/transcode/universal` request. It stays
that way so its baseline keeps meaning what it meant.

The remux path is covered by `play-dv7-atmos` (item 17) and `play-dv7-truehd`
(item 18), the two Dolby Vision 7 MEL titles with TrueHD audio. They pass
`-DuskScreenshotHDRDisplay 1` (DEBUG screenshot mode only), which makes the
ladder treat the display as HDR. Their logs show the part stream selection
(`PUT /library/parts/<id>`, answered by the proxy itself and never sent to
plex-demo), the `/video/:/transcode/universal/decision`, `start.m3u8`,
segments and `stop`. Their baseline is separate, recorded on 2026-11-28 from
three runs on the tree just before P0-19 plus the same seam, in
`~/.cache/dusk-parity/smoke-baseline-remux`:

```bash
scripts/parity/smoke_plex.sh check --screens play-dv7-atmos,play-dv7-truehd \
  --baseline ~/.cache/dusk-parity/smoke-baseline-remux
```

Their two request logs are also copied into the main G6 baseline, so a plain
`smoke_plex.sh check` includes them (`recorded.json` there still describes
the other screens). What the simulator still cannot show is what a device does after the
decision (HDR output, the Dolby Vision 7 → 8.1 proxy's loopback connection).

Not covered by G6 yet: the steps of the 05 §3 G6 list that need UI input
(sort, filter and A–Z in the grid, manual quality switch, mark watched and
back, offline playback). Screenshot-mode routes cannot reach them. They need
an XCUITest driver.
