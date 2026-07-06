This is **Dusk**, a native Swift/SwiftUI Plex client for Apple platforms. Read `docs/product-and-scope.md` for product intent and long-lived constraints.

Mandatory for agents: read this local `AGENTS.md` before planning, editing, committing, or pushing in this repository. Treat it as the repo-local source of truth for workflow expectations, especially verification and multi-agent git hygiene.

If `AGENTS.local.md` exists, read it immediately after this file. It contains checkout-specific verification and publishing constraints.

`docs/codebase-map.md` is the quick map of the current source structure. Read it before doing discovery-heavy work.

`STYLE.md` is the visual source of truth and must be followed at all times for colors, materials, spacing, and overall UI styling.

`docs/` is the agent-facing implementation guide. Read `docs/README.md` and the relevant topic doc before deep changes, especially when touching Plex data flow, playback, downloads/offline behavior, reusable UI, or project setup.

## Essential Context

- **Hybrid playback engine**: AVPlayer for MP4/MOV with standard codecs, VLCKit for everything else (MKV, DTS, PGS subs, etc.). Both conform to `PlaybackEngine` protocol. `StreamResolver` picks which engine to use based on stream metadata.
- **Plex is the source of truth**: App is stateless beyond auth token (Keychain) and user preferences (UserDefaults). All metadata, watch state, and library data is fetched from Plex.
- **No premature abstraction**: No `MediaProvider` protocol. Plex-specific code is fine. Keep it in `PlexService` but don't abstract until a second backend exists.
- **SwiftUI, multi-platform**: iOS/iPadOS and tvOS are project targets. Share as much UI as possible, use `#if os(tvOS)` for platform differences.
- **VLCKit is vendored, fetched not committed**: No CocoaPods. Pinned stable-line `MobileVLCKit.xcframework` (iOS) and `TVVLCKit.xcframework` (tvOS) binaries — VideoLAN's official prebuilt artifacts, thinned to arm64 — are downloaded into `Frameworks/` by `ci_scripts/install_vlckit.sh` and linked dynamically for LGPL compliance. The `.xcframework` binaries are git-ignored (~140 MB); CI fetches them automatically via `ci_scripts/ci_post_clone.sh`, and you must run the script once locally after cloning. Only the license and `Frameworks/VLCKit-VERSION.txt` are tracked.
- **Direct play first**: Playback starts with direct play unless the resolver flags the media as locally unplayable (e.g. Dolby Vision profile 5) or a local download is used. When an online direct-play attempt fails, the coordinator automatically falls back to a Plex server stream (HLS with `directStream=1`, video copied without re-encoding when possible). Manual transcoding remains a per-session player Quality action and must never become an automatic startup *quality* default.

## Code Style

- SwiftUI views backed by `@Observable` ViewModels
- ViewModels call `PlexService`, views never touch the network directly
- Async/await throughout, no Combine unless wrapping VLCKit callbacks
- Minimal dependencies: VLCKit is the only third-party dependency

## Documentation Maintenance

- Keep `docs/` concise but operational. Document responsibilities, data/control flow, extension points, invariants, traps, and verification steps; do not mirror every method or produce giant files.
- Preserve the structure described in `docs/README.md`: an index, a codebase map, and focused topic docs so no single file becomes the whole architecture manual.
- Update the matching doc in the same change when modifying a meaningful flow, boundary, reusable component, setting, setup step, or verification expectation.
- Prefer linking new behavior to the existing topic file over creating a new doc. Add a new doc only when a component has a distinct owner and the existing files would become noisy.
- If a doc and source disagree, treat the source as truth, fix the stale doc, and mention that in your final summary.

## Project Setup

The Xcode project is generated via [xcodegen](https://github.com/yonaskolb/XcodeGen). `project.yml` remains the source of truth; regenerate `Dusk.xcodeproj` when project settings change.

After making code changes, run a compile-only verification build before finishing. Use `xcodebuild` for the relevant app target or scheme, but do not run tests and do not launch the app or simulator. Treat this as a quick sanity check to catch Swift compile errors like invalid bindings, missing references, or bad signatures.

For iOS app verification in this repo, prefer:

```bash
xcodebuild -project Dusk.xcodeproj -scheme Dusk -configuration Debug -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
```

The vendored iOS `MobileVLCKit.xcframework` is thinned to arm64 (device and simulator), so generic simulator builds without the arm64 override can fail at link time even when the Swift code is otherwise valid.

Important: if you add, remove, or rename any source file under `Dusk/Sources`, run `xcodegen generate` before finishing. The checked-in `Dusk.xcodeproj` can otherwise be stale, which causes new Swift files to appear as "Cannot find in scope" even though they exist on disk.

```bash
# 1. Generate the Xcode project
brew install xcodegen  # if not already installed
xcodegen generate

# 2. Open in Xcode
open Dusk.xcodeproj
```

The iOS/tvOS VLCKit binaries are **not committed** to git, so fetch them into
`Frameworks/` after cloning (this is also how you refresh the pinned version).
CI does this automatically via `ci_scripts/ci_post_clone.sh`; the script is
idempotent and a no-op once the pinned version is present:

```bash
./ci_scripts/install_vlckit.sh
```

## Important
- Read AGENTS.local.md at the beginning of every thread if it exists.
