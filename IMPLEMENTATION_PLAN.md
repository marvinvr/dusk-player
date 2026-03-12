# Dusk -- Implementation Plan

## Principles

- **Sequential until the foundation is solid, then fan out.** The first ~8 tasks are a single critical path. After that, most features can be built in parallel by independent agents.
- **Each task produces a compilable, testable unit.** No task should leave the project in a broken state.
- **Interfaces before implementations.** Define protocols and data models early so parallel agents have stable contracts to code against.
- **PlexService is the spine.** Almost every feature depends on it. Get it right and complete early, because every parallel agent will import it.

---

## Phase 0: Project Skeleton (Manual / Single Agent)

Do this yourself or with one agent in a single session. It's small but fiddly and everything depends on it being right.

**Task 0: Project setup**
- Create Xcode project: SwiftUI App, iOS/iPadOS targets (tvOS target created but not active)
- Folder structure matching SPEC.md module layout
- Vendor VLCKit xcframework, confirm it links and builds (dynamic framework)
- Basic App entry point with a TabView shell (Home, Libraries, Search) showing placeholder text
- CLAUDE.md and SPEC.md in repo root

Output: A project that builds and runs, shows three empty tabs, VLCKit links without errors.

---

## Phase 1: Core Contracts (Sequential, Single Agent)

These tasks define the interfaces that everything else builds against. Order matters here because each one builds on the previous. One agent, working through them in sequence.

**Task 1: Data models**
- All Plex API response models as Codable structs: PlexPin, PlexServer, PlexLibrary, PlexItem, PlexMediaDetails (including media/part/stream hierarchy), PlexHub, PlexSearchResult, PlexSeason, PlexEpisode
- Subtitle/audio track models: SubtitleTrack, AudioTrack
- PlaybackState enum, PlaybackError enum
- Keep them in a shared Models/ directory

Output: Compilable model files. No networking yet.

**Task 2: PlexService networking foundation**
- Base networking: a generic request method that handles Plex headers (X-Plex-Token, X-Plex-Client-Identifier, X-Plex-Product, etc.), JSON decoding, error handling
- Token injection from Keychain
- Server base URL management (stored URL, connection preference)
- All the PlexService method signatures from the spec as stubs (real signatures, bodies that throw "not implemented")

Output: PlexService compiles with all method signatures. Calling any method throws/returns placeholder. Every future task just fills in method bodies.

**Task 3: Auth flow**
- PlexService.generatePin() and .checkPin() implementations
- ASWebAuthenticationSession integration for the browser redirect
- Keychain read/write for auth token
- Client identifier generation + UserDefaults persistence
- A minimal sign-in screen that triggers the flow and stores the token
- Sign-out (clear Keychain + reset PlexService state)

Output: You can launch the app, sign in with your Plex account, and the token is persisted. Relaunch skips sign-in.

**Task 4: Server discovery + connection**
- PlexService.discoverServers() implementation
- Connection priority logic (local > remote > relay)
- One-time server picker UI (if multiple servers)
- Store selected server in UserDefaults
- Auto-reconnect on launch using stored server
- Wire up so the tab shell only appears after auth + server connection

Output: Full auth-to-connected flow works end to end. App launches, checks for stored token, connects to server, shows the tab shell. First-time users get sign-in then server picker.

---

## Phase 2: Playback (Sequential, Single Agent)

This is the highest-risk work. One agent, focused, working through it in order. Don't parallelize this with anything else yet because playback bugs will block everything.


**Task 5: PlaybackEngine protocol + StreamResolver**
- PlaybackEngine protocol (exact interface from SPEC.md)
- StreamResolver: takes PlexMediaDetails, returns which engine type to use
- Engine factory that instantiates the correct engine
- No actual engine implementations yet, just the contracts

Output: Protocol file, StreamResolver logic, factory. Compiles but can't play anything yet.

**Task 6: VLCKitEngine**
- Implement PlaybackEngine protocol using VLCKit
- VLCMediaPlayer setup, rendering surface (UIView wrapping for SwiftUI)
- Play, pause, stop, seek
- State observation (map VLCKit delegate callbacks to PlaybackState)
- Subtitle and audio track enumeration + selection
- Test with a hardcoded Plex direct play URL

Output: Can play an MKV file from Plex in a raw full-screen view. Controls are programmatic (no UI yet).

**Task 7: AVPlayerEngine**
- Implement PlaybackEngine protocol using AVPlayer/AVPlayerLayer
- Same interface: play, pause, stop, seek, state observation
- Subtitle and audio track enumeration via AVMediaSelectionGroup
- Test with a hardcoded MP4 URL

Output: Can play an MP4 file. Same programmatic interface as VLCKitEngine.

**Task 8: Player UI**
- Full-screen player view that takes a PlaybackEngine
- Controls overlay: play/pause, seek bar with timestamps, 15s skip forward/back, close button
- Auto-hide overlay after 4 seconds
- Subtitle track picker (bottom sheet)
- Audio track picker (bottom sheet)
- Landscape orientation support

Output: A polished player screen that works with either engine. The player UI doesn't know which engine it's using.

**Task 9: Playback wiring**
- Build the "play an item" flow: given a PlexItem ratingKey, fetch PlexMediaDetails, run StreamResolver, construct direct play URL, launch player
- Resume position: pass startPosition from Plex's viewOffset field
- Timeline reporting: periodic progress updates to Plex during playback (every 10s)
- Scrobble on completion (>90% watched)
- Handle playback errors with the error UI from the spec

Output: You can trigger playback of any item from code, it picks the right engine, plays, syncs progress to Plex. This is the "it works" milestone.

---

## -- PARALLELIZATION POINT --

After Phase 2, the foundation is solid:
- PlexService is complete with all method stubs (many already filled in from auth/server/media details)
- Both playback engines work behind a unified protocol
- Player UI is done
- Playing an item end-to-end works

From here, most features are independent SwiftUI screens that call PlexService methods and navigate to the player. Agents can work on these simultaneously without stepping on each other, as long as each agent works in its own feature directory.

---

## Phase 3: Features (Parallel, Multiple Agents)

Each task below is independent. An agent picks one, implements it, done. The only shared touchpoints are PlexService (read-only, methods just need their bodies filled in) and navigation (pushing to detail views or the player).

Group them by dependency if you want to be safe, but in practice any ordering works.

**Task A: Home tab -- Recently Added**
- Fill in PlexService.getHubs()
- Horizontal carousel UI component (reusable)
- Recently Added Movies carousel
- Recently Added TV carousel
- Poster card component with AsyncImage (reusable)
- Tap navigates to detail view (can stub as print/placeholder if detail views aren't done yet)

**Task B: Home tab -- Up Next**
- Fill in PlexService.getContinueWatching()
- Up Next carousel at top of Home (reuse carousel component from Task A if available, build it if not)
- Progress bar on partially watched items
- Tap resumes playback (or navigates to detail view)
- Next episode resolution (show the next unwatched episode, not the show poster)

**Task C: Movie detail view**
- Fill in PlexService.getMediaDetails() if not already done
- Hero backdrop, poster, metadata layout
- Play button (wired to playback flow from Task 9)
- Resume button with timestamp if partially watched
- Mark as watched / unwatched (fill in PlexService.scrobble/unscrobble)

**Task D: Show / Season / Episode browsing**
- Fill in PlexService.getSeasons() and .getEpisodes()
- Show detail: backdrop, metadata, season picker (horizontal pills), episode list
- Episode rows: thumbnail, number, title, duration, watched indicator, progress bar
- Episode detail: metadata, play button, resume, mark watched, next/previous episode navigation
- Wire play button to playback flow

**Task E: Libraries tab**
- Fill in PlexService.getLibraries() and .getLibraryItems()
- Library list view
- Grid view for items within a library (poster grid)
- Pagination (load more on scroll, using X-Plex-Container-Start/Size)
- Tap navigates to movie or show detail

**Task F: Search tab**
- Fill in PlexService.search()
- Search bar with 300ms debounce
- Results grouped by type (Movies, Shows, Episodes)
- Tap navigates to appropriate detail view
- Empty state / no results state

**Task G: Settings + Account**
- Settings view: playback prefs (max resolution, default subtitle/audio language, force VLCKit toggle)
- Server section: show active server, change server button (re-triggers server picker)
- Account popover/sheet from top-right toolbar button: avatar, name, server status, settings link, sign out
- Wire up UserDefaults bindings for all preferences
- Make StreamResolver and PlexService respect the stored preferences

---

## Phase 4: Integration + Polish (Single Agent or Pair)

After parallel features land, one agent cleans up the seams.

**Task H: Navigation wiring**
- Ensure all detail views properly push/present from Home, Libraries, Search
- Deep navigation: Home > show card > season > episode > play
- Back navigation works cleanly everywhere
- Loading states, error states, empty states on all screens

**Task I: Edge cases + polish**
- Playback interruptions (phone call, backgrounding, lock screen)
- Network error handling (server unreachable mid-browse, mid-playback)
- Token expiry handling (re-auth flow)
- Image loading performance (if large grids are slow, tune URLCache or add prefetch)

---

## Phase 5: tvOS (Sequential, Single Agent)

Only after iOS is solid.

**Task J: tvOS target activation**
- Enable tvOS target, resolve build issues
- VLCKit tvOS xcframework integration
- Auth flow: PIN code on screen, poll in background
- Tab bar adaptation (top bar)
- Focus-based navigation testing across all existing views
- Player controls for Siri Remote (swipe seek, click play/pause, menu for overlay)
- 10-foot UI spacing adjustments

---

## Summary

```
Phase 0  [manual]     Project skeleton
Phase 1  [sequential] Models > Networking > Auth > Server > Playback protocol
Phase 2  [sequential] VLCKit engine > AVPlayer engine > Player UI > Wiring
                       ---- parallelization point ----
Phase 3  [parallel]   A: Recently Added    E: Libraries
                       B: Up Next           F: Search
                       C: Movie detail      G: Settings + Account
                       D: Show browsing
                       ---- merge + polish ----
Phase 4  [sequential] Navigation wiring, edge cases, polish
Phase 5  [sequential] tvOS
```

Tasks A through G can run simultaneously. The only collision risk is if two agents both try to fill in the same PlexService method body, but in practice each feature uses different endpoints so this is unlikely. If it happens, the second agent just finds the method already implemented and moves on.
