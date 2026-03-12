# Dusk -- Technical Specification

**Version:** 1.0
**Last Updated:** 2026-03-12

---

## 1. Overview

A native Swift/SwiftUI video player app for Apple platforms called **Dusk** (repo: `dusk-player`) that integrates exclusively with Plex. The app prioritizes direct playback of local media libraries (particularly MKV HEVC content) using a hybrid playback engine (AVPlayer + VLCKit), with a clean, minimal UI.

This is a personal/small-audience project, not a commercial product. Architectural decisions should favor simplicity and maintainability over enterprise patterns.

### 1.1 Design Principles

- **Plex is the source of truth.** The app is stateless beyond auth credentials and user preferences. All metadata, watch state, and library data lives on the Plex server.
- **Direct play first.** No transcoding in v1. The player must handle whatever the server has, or fail gracefully with a clear message.
- **Shared UI, platform-aware.** Maximize SwiftUI code sharing across platforms. Use `#if os(tvOS)` conditionals for platform-specific behavior, not separate view hierarchies.
- **No premature abstraction.** Plex-specific code is fine. Isolate it cleanly in a service layer, but do not build provider protocols until a second backend exists to validate the abstraction.

---

## 2. Platform Targets

| Platform | Priority | Status | Notes |
|----------|----------|--------|-------|
| iOS | P0 | v1 scope | Primary target |
| iPadOS | P0 | v1 scope | Shared codebase with iOS, layout adaptations only |
| tvOS | P1 | Near-term | Second phase. Focus-based nav, PIN-on-screen auth |
| macOS | P2 | Later | Run as iPad app via Mac Catalyst. Minimal custom work |

### 2.1 Minimum OS Versions

- iOS/iPadOS 17.0 (SwiftUI maturity, SwiftData availability if needed later)
- tvOS 17.0 (when added)
- macOS 14.0 Sonoma (when added, via Catalyst)

### 2.2 Platform Sharing Strategy

Three layers of code:

1. **Core (100% shared):** Plex API client, playback engine protocol + implementations, data models, stream resolution logic.
2. **Shared UI (~80% shared):** SwiftUI views for library browsing, detail screens, search. These compile on all platforms with minor conditionals.
3. **Platform UI (~20% platform-specific):** Navigation structure (TabView on iOS vs sidebar on tvOS), playback controls overlay (touch vs remote), auth flow presentation (ASWebAuthenticationSession on iOS vs code-on-screen on tvOS), 10-foot UI spacing on tvOS.

---

## 3. Architecture

### 3.1 High-Level Module Structure

```
App
 +-- PlexService/          # Plex API client, auth, models
 +-- Playback/             # PlaybackEngine protocol, AVPlayer + VLCKit engines, StreamResolver
 +-- Features/
 |    +-- Home/            # Up Next, Recently Added
 |    +-- Libraries/       # Library browsing
 |    +-- Search/          # Cross-library search
 |    +-- Detail/          # Movie/Show/Season/Episode detail views
 |    +-- Player/          # Playback UI, controls overlay, subtitle/audio picker
 |    +-- Settings/        # User preferences
 |    +-- Account/         # Auth state, sign in/out
 +-- Shared/               # Common UI components, extensions, utilities
```

### 3.2 Data Flow

```
Plex Server  <-->  PlexService  <-->  ViewModels  <-->  SwiftUI Views
                        |
                        v
                   PlaybackEngine (AVPlayer or VLCKit)
                        |
                        v
                   Player UI Overlay
```

All network calls go through `PlexService`. ViewModels hold UI state and call `PlexService` methods. No views talk to the network directly.

### 3.3 Dependency Summary

| Dependency | Purpose | License |
|------------|---------|---------|
| VLCKit 3.x | Fallback playback engine for MKV, DTS, PGS subs, etc. | LGPL 2.1 |
| AVFoundation (system) | Primary playback engine for AVPlayer-compatible content | N/A |
| KeychainAccess (or raw Security framework) | Auth token storage | MIT (if using library) |

No other third-party dependencies in v1. Networking uses URLSession directly. UI uses SwiftUI + system frameworks only.

---

## 4. Playback Engine (Hybrid)

### 4.1 Architecture

```
StreamResolver
  Input:  Plex MediaItem (container, videoCodec, audioCodec, subtitleCodec)
  Output: PlaybackEngine instance (AVPlayerEngine or VLCKitEngine)

protocol PlaybackEngine {
    // Lifecycle
    func load(url: URL, startPosition: TimeInterval?)
    func play()
    func pause()
    func stop()
    func seek(to position: TimeInterval)

    // State (published/observable)
    var state: PlaybackState { get }        // idle, loading, playing, paused, error
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var isBuffering: Bool { get }
    var error: PlaybackError? { get }

    // Tracks
    var availableSubtitleTracks: [SubtitleTrack] { get }
    var availableAudioTracks: [AudioTrack] { get }
    func selectSubtitleTrack(_ track: SubtitleTrack?)
    func selectAudioTrack(_ track: AudioTrack)

    // Rendering
    func makePlayerView() -> AnyView  // platform-specific view embedding
}
```

### 4.2 Stream Resolution Logic

The `StreamResolver` inspects the Plex `MediaItem`'s stream metadata and picks an engine:

```
AVPlayer is selected when ALL of:
  - Container: mp4, mov, m4v
  - Video codec: h264, hevc (av1 on A15+ devices)
  - Audio codec: aac, ac3, eac3, alac, mp3, flac (iOS 17+)
  - Subtitle codec: none, tx3g/mov_text (embedded), or external SRT
  - No burn-in required for subtitle rendering

VLCKit is selected for EVERYTHING ELSE, including:
  - MKV, AVI, WMV containers
  - DTS, DTS-HD, TrueHD audio
  - PGS, ASS/SSA bitmap/complex subtitles
  - Any format combination not in the AVPlayer list above
```

A user preference in Settings can override this: "Force VLCKit for all playback." This is useful for debugging or if AVPlayer causes issues with specific content.

### 4.3 Why Hybrid

For the author's library (predominantly MKV HEVC), VLCKit will handle ~95%+ of content. AVPlayer exists for:

- Native PiP support (future scope) without AVSampleBufferDisplayLayer workarounds.
- AirPlay (future scope) with zero extra work.
- Battery efficiency on compatible content.
- Future-proofing if the library composition changes.

The added complexity is minimal: both engines conform to the same protocol. The `StreamResolver` is a pure function with no state. The player UI doesn't know or care which engine is active.

### 4.4 Playback URL Construction

Plex direct play URLs follow this pattern:

```
{server_url}/library/parts/{part_id}/file.mkv?X-Plex-Token={token}
```

The `part_id` and file info come from the Plex API's media metadata response. No transcoding session setup is needed for direct play.

### 4.5 Error Handling

If direct play fails (engine can't handle the format, network error, etc.):

1. Display a clear error: "This file couldn't be played directly. [Container] [VideoCodec] [AudioCodec]"
2. In future: offer to start a transcode session on the server. Not in v1.
3. Never silently fail or hang on a loading spinner.

---

## 5. Plex Integration

### 5.1 Authentication

Plex uses a PIN-based auth flow (not standard OAuth, but conceptually similar):

**iOS/iPadOS flow:**
1. App calls `POST https://plex.tv/api/v2/pins` with client identifier to generate a PIN (includes `id` and `code`).
2. App opens `https://app.plex.tv/auth#?clientID={clientId}&code={code}&context[device][product]=Dusk` via `ASWebAuthenticationSession` (or `SFSafariViewController`).
3. User logs into Plex in the browser and approves the app.
4. App polls `GET https://plex.tv/api/v2/pins/{pinId}` until `authToken` is populated.
5. Store `authToken` in Keychain.

**tvOS flow (future):**
1. Same PIN generation.
2. Display the `code` on screen with instructions: "Go to plex.tv/link and enter code: XXXX"
3. Poll until token is received.
4. Store in Keychain (shared Keychain group enables cross-platform if desired).

**Headers for all Plex API requests:**
```
X-Plex-Token: {authToken}
X-Plex-Client-Identifier: {persistent UUID, generated once and stored}
X-Plex-Product: Dusk
X-Plex-Version: {app version}
X-Plex-Platform: iOS / tvOS / macOS
X-Plex-Device-Name: {UIDevice.current.name}
```

### 5.2 Server Discovery

After authentication, retrieve the user's servers:

```
GET https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1
```

This returns all servers the user has access to, with connection URIs (local, remote, relay). The app should:

1. Try local connections first (faster, no bandwidth limits).
2. Fall back to remote connections.
3. Relay connections as last resort (bandwidth-limited through Plex's infrastructure).
4. Store the last-used server connection for quick reconnect.

On first login, if the user has multiple servers, show a one-time server picker. The selection is stored in UserDefaults and used for all subsequent launches (no repeated prompts). The active server can be changed later in Settings. If the user has only one server, skip the picker entirely and connect automatically.

### 5.3 Core API Endpoints

All endpoints below are relative to the selected server's base URL.

**Libraries:**
```
GET /library/sections
  -> returns list of libraries (movies, TV shows, music, etc.)

GET /library/sections/{sectionId}/all
  -> returns all items in a library (paginated via X-Plex-Container-Start, X-Plex-Container-Size)
```

**Home / Hubs:**
```
GET /hubs
  -> returns "hubs" including Continue Watching, Recently Added, etc.

GET /hubs/continueWatching
  -> dedicated endpoint for Up Next / Continue Watching items
```

**Show Structure:**
```
GET /library/metadata/{showRatingKey}/children
  -> returns seasons for a show

GET /library/metadata/{seasonRatingKey}/children
  -> returns episodes for a season
```

**Search:**
```
GET /hubs/search?query={query}&limit=10
  -> searches across all libraries, returns results grouped by type
```

**Media Details (for playback):**
```
GET /library/metadata/{ratingKey}
  -> full metadata including Media (container, codecs, streams, part IDs)
```

**Playback Tracking:**
```
GET /:/timeline?ratingKey={ratingKey}&key={key}&state={playing|paused|stopped}&time={ms}&duration={ms}&X-Plex-Token={token}
  -> report playback progress (call periodically during playback, e.g., every 10 seconds)
```

**Watch State:**
```
GET /:/scrobble?identifier=com.plexapp.plugins.library&key={ratingKey}
  -> mark as watched

GET /:/unscrobble?identifier=com.plexapp.plugins.library&key={ratingKey}
  -> mark as unwatched
```

### 5.4 PlexService Interface

```swift
class PlexService {
    // Auth
    func generatePin() async throws -> PlexPin
    func checkPin(_ pinId: Int) async throws -> String?  // returns authToken or nil
    func signOut()

    // Server
    func discoverServers() async throws -> [PlexServer]
    func connect(to server: PlexServer) async throws

    // Libraries
    func getLibraries() async throws -> [PlexLibrary]
    func getLibraryItems(sectionId: String, start: Int, size: Int) async throws -> [PlexItem]

    // Browsing
    func getSeasons(showKey: String) async throws -> [PlexSeason]
    func getEpisodes(seasonKey: String) async throws -> [PlexEpisode]

    // Home
    func getHubs() async throws -> [PlexHub]
    func getContinueWatching() async throws -> [PlexItem]

    // Search
    func search(query: String) async throws -> [PlexSearchResult]

    // Media details (for playback resolution)
    func getMediaDetails(ratingKey: String) async throws -> PlexMediaDetails

    // Playback tracking
    func reportTimeline(ratingKey: String, state: PlaybackState, timeMs: Int, durationMs: Int) async
    func scrobble(ratingKey: String) async throws
    func unscrobble(ratingKey: String) async throws
}
```

---

## 6. UI / Navigation

### 6.1 Tab Structure (iOS/iPadOS)

Three tabs at the bottom:

| Tab | Icon | Content |
|-----|------|---------|
| Home | house.fill | Up Next, Recently Added TV, Recently Added Movies |
| Libraries | rectangle.stack.fill | List of Plex libraries (content browsing within is future scope for v1, but show the library list and skeleton) |
| Search | magnifyingglass | Search bar + results grouped by type |

Top-right toolbar: **Account button** (person.circle). Taps open an account sheet/popover with:
- User avatar + name (from Plex profile)
- Server name + connection status
- Settings link
- Sign Out button

### 6.2 Home Tab

Vertically scrolling page of horizontal carousels:

1. **Up Next** (Continue Watching) -- most prominent, top of page. Shows partially watched movies and next episodes of in-progress shows. Each card shows poster/thumbnail, title, progress bar (for partially watched items).
2. **Recently Added -- Movies** -- horizontal scroll of movie posters.
3. **Recently Added -- TV Shows** -- horizontal scroll of show posters or recently added episode cards.

These map directly to Plex Hub API responses. Each card is tappable and navigates to the appropriate detail view.

### 6.3 Libraries Tab

v1: Display a list of the user's Plex libraries (e.g., "Movies," "TV Shows," "Anime"). Tapping a library opens a grid/list view of items in that library. For v1, this is a simple poster grid with sort and basic filtering. This is one of the easier screens to iterate on later.

### 6.4 Search Tab

- Persistent search bar at top.
- Results displayed grouped by type (Movies, Shows, Episodes).
- Debounced input (300ms) to avoid hammering the API.
- Empty state: recently searched or trending content (if Plex API provides it), or just a prompt.

### 6.5 Detail Views

**Movie Detail:**
- Hero backdrop image
- Poster, title, year, rating, duration, genres
- Synopsis/summary
- Play button (prominent), "Mark as Watched/Unwatched" toggle
- If partially watched: resume button with timestamp + "Play from beginning" option
- Subtitle/audio selection (or defer to player overlay)

**Show Detail:**
- Hero backdrop, poster, title, year, rating, genres
- Synopsis
- Season picker (horizontal pills or dropdown)
- Episode list for selected season, each showing: thumbnail, episode number, title, duration, air date, watched indicator, progress bar if partially watched
- Tapping an episode goes to Episode Detail or directly into playback (TBD, but Episode Detail with a play button is safer UX)

**Episode Detail:**
- Episode thumbnail (still from episode)
- Title, season/episode number, air date, duration, rating
- Synopsis
- Play button, resume if applicable
- "Mark as Watched/Unwatched"
- Navigate to next/previous episode

### 6.6 Player UI

Full-screen playback with an overlay that appears on tap (iOS) or Siri Remote menu button (tvOS):

**Controls overlay:**
- Play/pause (center)
- Seek bar with current time / remaining time
- 15s skip back / 15s skip forward buttons
- Subtitle track picker (bottom sheet or popover)
- Audio track picker (bottom sheet or popover)
- Close/dismiss button (top-left)

**Behavior:**
- Overlay auto-hides after 4 seconds of no interaction.
- Swipe gestures for seek (optional, can add later).
- On iOS: supports landscape orientation lock during playback.
- On playback end: return to detail view, mark as watched if >90% completed (Plex handles this threshold via timeline reporting).

### 6.7 Settings View

Accessible from the Account popover/sheet. Sections:

**Playback:**
- Maximum resolution (Auto / 4K / 1080p / 720p) -- controls which Plex media version to select if multiple exist.
- Default subtitle language (None / list of ISO 639 languages)
- Default audio language (list of ISO 639 languages)
- Force VLCKit (toggle, default off) -- bypasses StreamResolver, always uses VLCKit.

**Server:**
- Active server display (name, local/remote connection status).
- Change server button -- re-opens the server picker with all available servers.

**App:**
- About (version, build, licenses)
- Clear cached data (when cache is implemented)

### 6.8 tvOS Adaptations (Future, but designed for)

- Tab bar moves to the top (standard tvOS pattern).
- Account button in top-left or top-right of the top tab bar.
- All interactive elements must be focusable. SwiftUI handles this largely automatically.
- Playback controls: swipe on Siri Remote trackpad to seek. Click to play/pause. Menu to show overlay.
- Auth flow: code displayed on screen, user enters at plex.tv/link.
- Larger text, 10-foot UI spacing (minimum 48pt tap targets become focus targets).
- No search keyboard by default: support dictation and the Siri Remote keyboard, or accept text input from the Remote app on iPhone.

---

## 7. Data & State Management

### 7.1 Auth State

| Data | Storage | Scope |
|------|---------|-------|
| Plex auth token | Keychain | Persisted across launches, optionally shared via Keychain group for multi-platform |
| Client identifier (UUID) | UserDefaults | Generated once on first launch, never changes |
| Selected server ID + URL | UserDefaults | Set once on first login (or when changed in Settings). Used for automatic reconnect on launch |

### 7.2 User Preferences

All stored in UserDefaults:

| Key | Type | Default |
|-----|------|---------|
| maxResolution | String (enum) | "auto" |
| defaultSubtitleLanguage | String? (ISO 639) | nil (none) |
| defaultAudioLanguage | String (ISO 639) | "en" |
| forceVLCKit | Bool | false |

### 7.3 Transient State

Everything else is fetched from Plex on demand and held in memory (ViewModels):
- Library lists
- Item metadata
- Search results
- Hub content (Up Next, Recently Added)
- Playback progress (synced to Plex via timeline reporting)

### 7.4 Future: Metadata Cache (SwiftData)

Not in v1. When added, this would cache:
- Library item listings (poster URL, title, year, ratingKey) for instant UI on launch.
- Watch state snapshots for offline-aware progress indicators.
- Refresh strategy: serve from cache immediately, fetch in background, update UI reactively.

SwiftData chosen because: native SwiftUI integration, `@Query` for reactive views, schema migrations, multi-platform support. Only added when "spinner on every launch" becomes a UX problem.

---

## 8. Detailed Feature Breakdown (v1)

### 8.1 In Scope

| Feature | Complexity | Notes |
|---------|-----------|-------|
| Plex PIN auth (iOS) | Low | Well-documented flow, ASWebAuthenticationSession |
| Server discovery + connection | Low | Single API call, connection preference logic |
| Home: Up Next | Medium-High | Continue Watching hub + resume logic + next episode resolution |
| Home: Recently Added | Low | Direct hub API mapping |
| Libraries: list + grid browse | Medium | Paginated grid, poster loading, sort |
| Search | Medium | Debounced search, grouped results |
| Movie detail view | Low | Metadata display, play button |
| Show/Season/Episode browsing | Medium | Nested navigation, season picker |
| Hybrid playback (AVPlayer + VLCKit) | High | Core feature, protocol design, StreamResolver |
| Subtitle track selection | Medium | Engine-dependent implementation |
| Audio track selection | Medium | Engine-dependent implementation |
| Playback progress sync | Medium | Periodic timeline reporting to Plex, scrobble on completion |
| Mark as watched/unwatched | Low | Single API call per action |
| Settings | Low | UserDefaults-backed preferences |
| Sign out | Low | Clear Keychain + reset state |

### 8.2 Out of Scope (Future)

| Feature | Phase | Dependency |
|---------|-------|------------|
| tvOS support | P1 | Validate VLCKit tvOS build + focus UI |
| macOS support | P2 | Mac Catalyst, minimal work expected |
| Picture in Picture | P1-P2 | AVPlayer: native. VLCKit: needs AVSampleBufferDisplayLayer pipe. Design player view layer with this in mind |
| AirPlay | P2 | AVPlayer: native. VLCKit: needs investigation |
| Transcoding fallback | P1 | Plex transcode session API, resolution/bitrate selection UI |
| Offline / Downloads | P2 | Local storage, download manager, DRM considerations |
| Metadata cache | P1 | SwiftData integration |
| Provider abstraction | P3 | Only when adding Emby/Jellyfin |
| Multiple server switching | v1 (basic) | Server picker on first login, changeable in Settings. Seamless switching (auto-reconnect, state refresh) is future scope |
| User switching (managed users) | P2 | Plex managed user API |
| Collections / Playlists | P2 | Plex collections API |
| Music playback | Out | Not a goal for this app |

---

## 9. Technical Risks & Open Questions

### 9.1 Confirmed Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| VLCKit PiP requires AVSampleBufferDisplayLayer | Medium | Defer PiP to later phase. When implementing, pipe VLCKit decoded frames to AVSampleBufferDisplayLayer. Does not affect v1 |
| VLCKit on tvOS build viability | Medium | Research agent dispatched. If VLCKit tvOS build fails, evaluate KSPlayer (LGPL paid) or server-side transcoding |
| OpenGL ES deprecation on iOS | Low | VLCKit uses it, but Apple has kept it functional for 8+ years. Not an imminent risk. Watch for removal signals in future iOS betas |
| LGPL compliance for App Store | Low | Ship VLCKit as dynamic xcframework, include attribution, provide source code offer. Well-trodden path (Infuse, nPlayer, VLC all do this) |
| DTS/TrueHD audio on tvOS | Medium | tvOS has no bitstream passthrough. Software decode to PCM loses spatial metadata. Acceptable tradeoff for v1. Monitor tvOS 26+ for passthrough APIs |

### 9.2 Resolved Decisions

1. **App name: Dusk.** Repository: `dusk-player`. Plex client identifier: `com.dusk-player.app`. Product header: `Dusk`.
2. **Plex Pass not required.** The app relies on direct play, library browsing, and timeline reporting, none of which require Plex Pass. If a Plex Pass-only feature becomes relevant later (e.g., hardware-accelerated transcoding on the server when we add transcoding fallback), handle it gracefully: detect the 401/403 response, show a clear message explaining the feature requires Plex Pass, and continue operating without it.
3. **Image loading: AsyncImage + URLCache.** Configure a shared URLSession with a generous URLCache (200MB disk). Use AsyncImage throughout. No third-party image loading dependency (Kingfisher, Nuke, etc.). If performance becomes an issue with large grids, revisit with a lightweight prefetch layer before adding a dependency.
4. **VLCKit integration: vendor the xcframework manually.** VLCKit 3.x has no official SPM support. The community SPM wrapper (tylerjonesio/vlckit-spm) pins to v3.5.1 and may lag behind updates. CocoaPods adds project complexity. The cleanest path: download the prebuilt VLCKit xcframework from VideoLAN's release artifacts, add it to the project as a vendored binary framework, and link it as a dynamic framework for LGPL compliance. This keeps the project pure SPM for everything else and gives full control over VLCKit versioning.
