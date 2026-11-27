# Demo server test data (Jellyfin T-0)

Ops package T-0 from [`docs/jellyfin/05-plan.md`](../../docs/jellyfin/05-plan.md) §7:
test data on `plex-demo` (`http://storage:10012`, PMS 1.43.5) and
`jellyfin-demo` (`http://jellyfin-demo`, Jellyfin 12.4.0). Both servers read the
same folder: `/Volumes/Bulk/Media/Demo` on the Mac (SMB), `/data` on the servers.
Plex mounts it read-write, Jellyfin read-only. No app code is involved.

Applied on 2026-11-27. Every step was checked on both servers through their
APIs; the results are in the tables below.

## Files

| File | What it does |
| --- | --- |
| `make_media.py` | Generates the test media with ffmpeg and PIL into a staging folder (`~/.cache/dusk-demo-testdata`) and copies anything missing to the share. It never deletes anything and never writes under `Real/` or `Stress/` |
| `vobsub.py` | A small VobSub (`.idx`/`.sub`) writer. ffmpeg cannot make DVD subtitles from text, so the bitmaps are rendered with PIL and wrapped in MPEG-PS by hand |
| `apply.py` | Server-side steps over the Plex and Jellyfin APIs: scans, collections, version merge, extra titles, playlists, watch state, users, Paging Test library, markers and BIF, pre-roll, plus `verify-<step>` checks (`verify-tester` prints what the App Review account sees) |
| `demo_api.py` | Minimal Plex and Jellyfin clients (standard library only) |

## Running it again

You need macOS (`sips` makes the HEIC), ffmpeg with libx264 and libx265, Python 3
with Pillow, the share mounted, and these credential files in
`~/.config/jellyfin-demo/`: `plex-token`, `admin-password`, `compare-password`
and `compare-plex-token`. The scripts read them at runtime and never print them.
Run without `-I`, which would hide the user-site Pillow.

```sh
python3 scripts/demo-testdata/make_media.py all       # versions multipart subtitles extras photos paging
python3 scripts/demo-testdata/apply.py collections media
# wait ~1 min for both scans, then
python3 scripts/demo-testdata/apply.py merge-versions extra-titles jf-titles playlists watch-state jf-users paging
python3 scripts/demo-testdata/apply.py plex-markers   # then wait for the markers
python3 scripts/demo-testdata/apply.py plex-analysis  # BIF; wait until verify shows both indexes
python3 scripts/demo-testdata/apply.py plex-analysis-restore preroll tester
python3 scripts/demo-testdata/apply.py verify-media verify-plex-analysis
```

Every step is idempotent: it looks up what exists and adds only what is
missing. Items are matched across the servers by their `/data/...` path, not by
title or id. Extras sometimes need a metadata refresh after the scan before
they show up (Plex `PUT /library/metadata/{rk}/refresh?force=1`, Jellyfin
`POST /Items/{id}/Refresh?recursive=true`).

## What was added

All generated media is synthetic: an ffmpeg `testsrc2` pattern with a PIL text
label and silent AAC audio, so it is licence-free. The only third-party file is
the OFL font Pacifico (google/fonts), embedded as the ASS attachment.

| Data | Where | plex-demo | jellyfin-demo |
| --- | --- | --- | --- |
| Collection inside one library: **Blender Open Movies** (BBB, Cosmos Laundromat, Elephants Dream, Sintel, Tears of Steel) | API | 5 items in Movies | BoxSet with 5 items, created by admin |
| Collection spanning a movie and a TV library: **Weekend Watch** (BBB, Sintel, show Weekend Projects) | API | **two** same-named collections, Movies (2) + Shorts (1), because Plex collections are per section | one BoxSet with 3 items |
| Two versions: `Movies/Dusk Two Versions (2026)/… - 1080p.mkv` (H.264) and `… - 2160p.mkv` (HEVC), 60 s | share | one item with 2 Media (`4k`, `1080`), **after an API merge** (see facts) | one item, MediaSources `2160p`, `1080p` |
| Multi-part film: `Movies/Dusk Two Parts (2026)/… - cd1.mkv`, `… - cd2.mkv`, 45 s each | share | 1 Media, 2 Parts | `PartCount 2`, 1 AdditionalPart |
| ASS: `Movies/Dusk Subtitles ASS (2026)/…mkv` with an embedded styled ASS track (eng; positioned, rotated and moving lines) and the Pacifico TTF attached; external `….de.ass` | share | `ass/eng`, `ass/deu` external | `ass/eng`, `ass/deu` external, attachment `Pacifico-Regular.ttf` |
| VobSub + forced: `Movies/Dusk Subtitles VobSub Forced (2026)/…mkv` with embedded VobSub (eng) and a forced-only SRT track (eng, forced disposition); external `….de.idx/.sub` VobSub and `….en.forced.srt` | share | `vobsub/eng`, `srt/eng/forced`, `idx/deu` ext, `srt/eng/forced` ext | `DVDSUB/eng`, `subrip/eng/forced`, `DVDSUB/de` ext, `subrip/eng/forced` ext |
| Movie extras: BBB already had Behind The Scenes, Featurette and a local trailer; added `Deleted Scenes/Alternate Ending.mp4` | share | BTS, featurette, deleted scene, local trailer and Plex's own online trailer | BTS, featurette, deleted scene, LocalTrailers 1 (plus the TMDb YouTube RemoteTrailer it already had) |
| Show extras on `Shorts/Weekend Projects`: `Featurettes/Meet the Builders.mp4`, `Trailers/Weekend Projects Trailer.mp4` | share | featurette + trailer | featurette + LocalTrailer |
| Season extra: `Season 01/Behind The Scenes/Season One Bloopers.mp4` | share | season 1 extra | season 1 SpecialFeature |
| Episode extra: `Season 01/Weekend Projects - S01E01 - Building the Treehouse-behindthescenes.mp4` | share | extra **of S01E01** | listed as a **season** extra; Jellyfin 12.4 has no episode-level extras |
| Playlists for `duskcompare`: **T-0 Short Mix** (BBB, Sintel, Tears of Steel, Office S01E01, Knives Out) and **T-0 Long Watch** (every Real TV episode: The Office, Severance, Ted Lasso = 249, above Dusk's 200 page size) | API, as duskcompare | 5 and 249, same order | 5 and 249, same order, `OpenAccess false` |
| Next Up: Severance S1E1–E3 watched by `duskcompare` | API, as duskcompare | On Deck: Severance "The You You Are" (E4) | NextUp: Severance "The You You Are" |
| Resume past 5 %: Dune: Part Two at 607 s (6.1 %) and Paddington 2 at 309 s (4.99 %) | already there before T-0, positions equal | Continue Watching | `/UserItems/Resume?mediaTypes=Video` |
| Photos: `Photos/Metadata Test/`, 6 JPEGs with EXIF `DateTimeOriginal` across Aug, Sep and Oct 2025, one JPEG with landscape pixels + EXIF Orientation 6 (it reads "UP" only when rotated correctly), one HEIC (EXIF kept by `sips`), one 8 s clip with `creation_time` | share | 8 items with matching dates, orientation 6 reported; **HEIC ignored** | 8 items with matching dates; **HEIC ignored** |
| Users (Jellyfin only): **Dusk Family** (on the login screen, password), **Dusk Guest** (on the login screen, empty password), **Dusk No Downloads** (hidden, password, `EnableContentDownloading false`). All three see only Movies, Shorts, Photos and Home Videos | API | n/a | passwords in `~/.config/jellyfin-demo/user-dusk-family-password` and `user-dusk-no-downloads-password` |
| **Paging Test** library: 520 flat 2 s stub files in `/data/Paging Test`, spread over A–Z, digits, symbols (`#`, `&`, `@`, `(`, `[`, `¡`, `'`, `…`), accented initials (`É`, `Å`, `Ø`, `Ü`, `Ç`), a lowercase title and `The`/`A`/`An` articles | share + API | section 21, personal-media agent (no online matching), no BIF/credits/loudness/voice analysis, title + year written and locked via API; shared with **duskcompare only** | library with no metadata or image fetchers and no trickplay or chapter images; visible to duskcompare, not tester |
| Intro + credits markers on The Office S1 | API | all 6 episodes have `intro` + `credits` (E01 intro 1.0–52.1 s, credits 1376.6–1405.2 s; Jellyfin has 0–54.6 s and 1372.7–1405.2 s). E04 has two credits markers | already had them |
| BIF previews on Knives Out and Paddington 2 (the films with Jellyfin trickplay) | API | both `indexes=sd`, `/library/parts/{id}/indexes/sd` → 200 (how: "Plex BIF" below) | already had trickplay |
| Credits on films | side effect of the BIF analysis | Knives Out `credits` 7519.5–7817.2 s (Jellyfin Outro 7549.3 s) | – |
| Cinema pre-roll `Prerolls/Dusk Preroll.mp4` | | `CinemaTrailersPrerollID` was already set; `POST /playQueues … extrasPrefixCount=0` puts the clip before the film | plugin **Local Intros 5.0.0.0** (official repo) installed, pointed at `/data/Prerolls`, movies only; `/Items/{film}/Intros` returns the clip, an episode returns none |

### tester (App Review account)

Its view was recorded before the first change and checked again at the end.

- Plex `tes2552`: still `allLibraries=0` with Home Videos, Movies, Photos and
  Shorts only. It sees the new test films, the photo album, the extras and
  the Blender Open Movies / Weekend Watch collections, all inside those demo
  libraries. It does not see Paging Test, Real Movies, Real TV or the
  duskcompare playlists.
- Jellyfin `tester`: still has its explicit `EnabledFolders` (the four demo
  libraries). It has no Collections view and no Paging Test. Every movie,
  episode, video and photo it can list lives under those four folders.
- **Not caused by T-0, needs an owner:** a playlist called **"Dusk Fixture
  Recorder"** was created on jellyfin-demo at 21:35 UTC while T-0 ran. It
  contains Knives Out and Paddington 2, has `OpenAccess: true`, and therefore
  gives tester a "Playlists" view that lists those two Real Movies titles. It
  probably belongs to the P0-00 fixture harness. T-0 left it alone.
- Also not from T-0: during the run, duskcompare got a Plex resume point on
  Big Buck Bunny (79 s) that Jellyfin does not have. Someone played it as
  duskcompare on plex-demo. It breaks the "same state on both" rule until it
  is cleared.

## Facts found on the way (for the J packages)

- **Plex does not group versions of unmatched films.** With a local (`local://`)
  match, `… - 1080p.mkv` and `… - 2160p.mkv` in one folder became two items.
  `PUT /library/metadata/{rk}/merge?ids={other}` joins them. Jellyfin groups
  them by the suffix and names the sources `2160p` / `1080p`.
- **Plex collections are per section**, so a collection across a movie library
  and a TV library does not exist on Plex. Dusk sees two collections there.
- **Extra titles:** Plex derives them oddly. Untagged, it turned
  `Alternate Ending.mp4` into "Ending" and gave the episode extra the parent
  episode's embedded title ("Big Buck Bunny - https://archive.org/…"). When the
  files were then replaced with title-tagged copies at the same path, Plex
  kept the old titles even after a scan and a forced refresh. Step
  `extra-titles` now writes and locks the intended titles through the API.
  Jellyfin uses the file name (`EnableEmbeddedExtrasTitles` is off), so the
  episode extra reads "Weekend Projects - S01E01 - Building the Treehouse"
  there. Every other extra title now matches on both servers.
- **Episode-level extras:** Plex attaches a `-behindthescenes` file next to
  S01E01 to that episode. Jellyfin 12.4 files it under the season.
- **Jellyfin 12.4 reports `HasPassword: true` for every user**, also in
  `/Users/Public`, even for Dusk Guest, which signs in with an empty
  password. A wrong password is still rejected. J-01 cannot use `HasPassword`
  to skip the password field; it has to try an empty password or always show
  the field.
- `/UserItems/Resume` without `mediaTypes=Video` also returns partly watched
  **Season and Series** rows (position 0) on Jellyfin 12.4.
- The Local Intros item has `RunTimeTicks: null` in `/Items/{id}/Intros`.
- **HEIC is ignored by both servers** after a scan and an item refresh, even
  though the file is a valid HEIF (`ftypheic`). Dusk will not see HEIC from
  either demo server. The file stays in the album as a negative case.
- Jellyfin converts the EXIF local time with the server time zone
  (09:15 → `07:15Z`, CEST). Plex shows the date only.
- Jellyfin's Movies library (TMDb on) names an unmatched folder movie
  "Dusk Two Versions (2026)", with the year parsed but still in the name.
  Step `jf-titles` sets and locks Plex's title. Paging Test, which has no
  fetchers, gets clean names by itself.
- Plex's personal-media agent keeps `Title (Year)` as the title and no year;
  Jellyfin parses both. Paging Test has title and year written via the API.
  The servers still sort symbol titles differently: Plex puts `@`, `&`, `#`
  and `Ø` first, Jellyfin puts `#` first.
- Jellyfin trickplay covers The Office S2/S3 (30 episodes) and Knives Out and
  Paddington 2, not S1. Markers are compared on S1, previews on the two films.
- Jellyfin picks up new folders under `/data` without a library scan
  (`POST /Library/Media/Updated` with the folder paths is enough).

### Plex BIF

plex-demo had `GenerateBIFBehavior=never` and the `GenerateMediaIndexFiles`
butler task disabled. `GenerateIndexFilesDuringAnalysis=1` plus an analysis did
nothing. `GenerateBIFBehavior=asap` plus `PUT /library/metadata/{rk}/analyze` on
the two films started BIF generation. Once both films had BIFs, both prefs were
put back (`never`, `GenerateIndexFilesDuringAnalysis` off). The butler task
stayed disabled, so no other item got previews.

## Server changes outside the media folder

- Plex: the two collections, the duskcompare playlists and watch state, the
  Paging Test section (prefs + share with duskcompare), a version merge,
  locked titles on five extras,
  locked title/year on the Paging Test items, an intro-detection butler run
  (all shows without intros; plex-demo runs this nightly anyway), analysis of
  The Office S1 and the two films, and the temporary BIF prefs described above.
- Jellyfin: two BoxSets, duskcompare playlists and watch state, three users,
  locked names on the four new films,
  the Paging Test library, and the Local Intros plugin with its configuration.
  The plugin needed **one server restart** (Jellyfin restarts in-process,
  ~10 s; no playback sessions were active).
- On the Mac: `~/.config/jellyfin-demo/user-dusk-*-password` (mode 600), and
  the staging folder `~/.cache/dusk-demo-testdata`, which can be deleted.

## Not done

Skipped as asked; these are done later from the homelab repo:

- Live TV tuner (M3U + XMLTV) on both servers, and a recording
- the second small Jellyfin server (J-13)
- the Jellyfin-backed Seerr (J-12)
- the Plex Home member with a PIN

In §7 but not in the T-0 request, so not done:

- a film stored as two **Plex editions** (`{edition-…}`). Both servers read the
  same folder, so Jellyfin would show those files as two films or two versions.
  Decide how to keep it Plex-only before adding it.
- a film with **only a remote (YouTube) trailer** on Jellyfin. It can be set
  through `POST /Items/{id}` `RemoteTrailers`. BBB already has a TMDb YouTube
  trailer next to its local one.
- a user with `EnableSubtitleManagement` and a subtitle plugin. There is no
  OpenSubtitles account for the demo; the official Open Subtitles plugin is
  available in the catalog once there is one.

## Undo

- Media: delete `Movies/Dusk *`, `Movies/Big Buck Bunny (2008)/Deleted Scenes`,
  `Shorts/Weekend Projects/{Featurettes,Trailers}`,
  `Shorts/Weekend Projects/Season 01/Behind The Scenes`, the
  `…S01E01…-behindthescenes.mp4` file, `Photos/Metadata Test` and
  `Paging Test` from the share. Then scan, and empty the Plex trash.
- Plex: delete section 21 and the collections and playlists.
- Jellyfin: delete the Paging Test library, the BoxSets, the playlists, the
  three users and the Local Intros plugin.
