This is **Dusk**, a native Swift/SwiftUI Plex client for Apple platforms. See `SPEC.md` for the full technical spec.

`ARCHITECTURE.md` is the quick map of the current code structure after the refactor. Read it before doing discovery-heavy work.

`STYLE.md` is the visual source of truth and must be followed at all times for colors, materials, spacing, and overall UI styling.

## Essential Context

- **Hybrid playback engine**: AVPlayer for MP4/MOV with standard codecs, VLCKit for everything else (MKV, DTS, PGS subs, etc.). Both conform to `PlaybackEngine` protocol. `StreamResolver` picks which engine to use based on stream metadata.
- **Plex is the source of truth**: App is stateless beyond auth token (Keychain) and user preferences (UserDefaults). All metadata, watch state, and library data is fetched from Plex.
- **No premature abstraction**: No `MediaProvider` protocol. Plex-specific code is fine. Keep it in `PlexService` but don't abstract until a second backend exists.
- **SwiftUI, multi-platform**: iOS/iPadOS now, tvOS soon. Share as much UI as possible, use `#if os(tvOS)` for platform differences. macOS later via Catalyst.
- **VLCKit is vendored**: No CocoaPods. A pinned `VLCKit.xcframework` is checked into `Frameworks/` and linked dynamically for LGPL compliance.
- **Direct play only (v1)**: No transcoding. Fail with a clear error if the file can't be played.

## Code Style

- SwiftUI views backed by `@Observable` ViewModels
- ViewModels call `PlexService`, views never touch the network directly
- Async/await throughout, no Combine unless wrapping VLCKit callbacks
- Minimal dependencies: VLCKit is the only third-party dependency

## Project Setup

The Xcode project is generated via [xcodegen](https://github.com/yonaskolb/XcodeGen). `project.yml` remains the source of truth; regenerate `Dusk.xcodeproj` when project settings change.

```bash
# 1. Generate the Xcode project
brew install xcodegen  # if not already installed
xcodegen generate

# 2. Open in Xcode
open Dusk.xcodeproj
```

To refresh the vendored VLCKit binary manually, run:

```bash
./ci_scripts/install_vlckit.sh
```

## Reference Points
- ../plezy - another third party open source plex client where you can AND SHOULD take reference on how plex is integrated. They do a similar thing as this but a lot worse.
- ../Swiftfin (jellyfin/Swiftfin) is the single most valuable reference. It's a SwiftUI Jellyfin client for iOS and tvOS that does exactly the hybrid VLCKit + AVPlayer approach, with stream resolution logic, subtitle/audio track selection, and tvOS focus navigation. Architecturally it's the closest thing to what you're building, just for Jellyfin instead of Plex.
- ../PlexKit (lostinthoughs/PlexKit) - a Swift library wrapping the Plex API. Even if you don't use it as a dependency, it's useful reference for how the Plex API responses are structured as Codable models. Saves the agent from guessing at JSON shapes.
- ../VLCKit - VLCKit's own repo (videolan/VLCKit) has example projects in the Examples/ directory showing how to set up the player view and handle delegates. Worth having around for Task 6 specifically.
