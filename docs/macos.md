# macOS App

Native Mac version of Dusk: SwiftUI on AppKit (target `Dusk-macOS`), **not**
Catalyst and not "Designed for iPad". Branch `macos-app`. Same bundle ID as
iOS/tvOS (`com.dusk-player.app`) so Universal Purchase can be switched on later.

## Architecture

- **One module, three platforms.** `Dusk-macOS` compiles the same
  `Dusk/Sources` tree as iOS/tvOS. Mac-only code lives in `Dusk/Sources/Mac/`
  and is file-scope `#if os(macOS)` (like the tvOS HUD files), so the iOS/tvOS
  targets compile it to nothing.
- **Conditional compilation rule.** Existing code is written as
  `#if os(tvOS) … #else <iOS> #endif`. On macOS the `#else` branch compiles, so
  where the iOS branch uses UIKit or iOS-only SwiftUI API, add an explicit
  `#elseif os(macOS)` branch. iOS and tvOS behaviour must stay byte-for-byte the
  same: only add macOS branches, never rewrite the iOS/tvOS ones.
- **Platform aliases.** `Shared/PlatformTypes.swift` maps `PlatformImage` /
  `PlatformColor` to UIKit or AppKit and adds `Image(platformImage:)`. That is the
  whole alias layer; anything richer gets an explicit `#if os(macOS)` branch.
- **Shell.** `MacRootView` is a `NavigationSplitView`: a sidebar (Home, Search,
  the library-type destinations, Live TV, Playlists, Downloads) and one
  `NavigationStack` per destination using the shared `AppNavigationRoute`s, so
  every detail page is the shared iOS view. Settings is the standard
  `Settings { }` scene (⌘,). Menu bar commands live in `Mac/MacCommands.swift`.
- **Player.** `MacPlayerView` replaces the iOS touch HUD (`PlayerView`) on macOS.
  It is shown over the main window's content when
  `PlaybackCoordinator.showPlayer` is true (the TV app's model, no separate
  window). Engines stay the shared `AVPlayerEngine` / `VLCKitEngine` behind
  `PlaybackEngine`, with a macOS renderer (`NSView` hosting `AVPlayerLayer` /
  VLCKit's video view). Keyboard: Space play/pause, ←/→ seek, ↑/↓ volume,
  F full screen, Esc leave full screen / close player, ⌘F search.
- **VLCKit.** VideoLAN's official `VLCKit.xcframework` 3.7.3 for macOS (same
  VLCKit commit `319ed2c0` as the iOS/tvOS line, universal), installed by
  `ci_scripts/install_vlckit.sh` into `Frameworks/VLCKit.xcframework`
  (git-ignored). It is a stock build: no `DuskVLCKitBuild` stamp, so TrueHD
  routes through Plex exactly like the iOS stock fallback. The dusk3 patches
  that matter on Mac are only 0100 (TrueHD/MLP); 0101/0103 are tvOS audio
  fixes and 0102 (pipe2) only matters for a self-built binary.
- **DuskDovi.** `scripts/build_dusk_dovi_xcframework.sh` adds a universal
  `macos-arm64_x86_64` slice (`aarch64-apple-darwin` + `x86_64-apple-darwin`,
  lipo'd).
- **Signing.** Ad-hoc (`CODE_SIGN_IDENTITY = -`), App Sandbox with network
  client + server (DV7 loopback proxy) and user-selected read-only files,
  hardened runtime. No team, no upload.

## Build

```bash
./ci_scripts/install_vlckit.sh      # iOS, tvOS and macOS VLCKit
./ci_scripts/install_dusk_dovi.sh   # incl. the macOS slice
xcodegen generate
xcodebuild -project Dusk.xcodeproj -scheme Dusk-macOS -configuration Debug \
  -destination 'platform=macOS' build
```

## Checklist

Foundation
- [x] `Dusk-macOS` target + scheme in `project.yml`, Info-macOS.plist, entitlements
- [x] VLCKit for macOS in `install_vlckit.sh`, verify script knows `macosx`
- [x] DuskDovi macOS slice
- [x] `import UIKit` guarded, `PlatformTypes.swift`
- [ ] Whole module compiles and links for macOS

Shell (App/, Mac/)
- [ ] `DuskApp` scene for macOS: main window (min size, restorable), `Settings` scene, commands
- [ ] Sign-in (plex.tv PIN), Home profile picker, connection pass
- [ ] Sidebar layout with per-destination navigation stacks
- [ ] Menu commands: ⌘F search, ⌘R refresh, sidebar toggle, Playback menu
- [ ] Launch splash skipped/adapted on macOS

Shared UI / features
- [ ] Home, library grids, detail pages, search, playlists, watchlist, Live TV, photos, downloads compile and look Mac-native
- [ ] Hover effects and right-click context menus on posters
- [ ] Settings pages inside the Settings scene
- [ ] Supporter (StoreKit) + App icon picker hidden on Mac

Player
- [ ] AVPlayer engine on macOS (direct play, HDR/DV remux, DV7 proxy)
- [ ] VLCKit engine on macOS (MKV/DTS/PGS…)
- [ ] `MacPlayerView` HUD: hover-to-show, scrubber, tracks, quality, Up Next/skip chips
- [ ] Keyboard shortcuts + Playback menu
- [ ] Now Playing / media keys

Release
- [ ] iOS + tvOS still build
- [ ] Release `.app` bundle
- [ ] Docs: what's done / missing / known issues (this file)

## Status

Work in progress. See the checklist.
