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
- **Shell.** `MacRootView` is a `NavigationSplitView`: a sidebar (Home, the
  library-type destinations, Live TV, Playlists, Downloads) under a sidebar
  search field (`.searchable(placement: .sidebar)`, Music/TV style: typing
  shows Search in the detail area, clearing returns), and one
  `NavigationStack` per destination using the shared `AppNavigationRoute`s, so
  every detail page is the shared iOS view. Back/forward is one toolbar pair
  (`MacShellBackForwardButtons`, Go › Back ⌘[ / Forward ⌘], forward history
  per destination in `MacShellRouter`); pushed screens hide the stack's own
  back button through `macShellBackButtonHidden()` (applied by
  `duskAppNavigationDestinations()`; other `navigationDestination`s add it).
  The window toolbar is transparent everywhere with the soft scroll-edge
  effect; hero pages put `macHeroUnderToolbar()` on their root `ScrollView` so
  the artwork runs under the toolbar. Settings is the standard
  `Settings { }` scene (⌘,). Menu bar commands live in `Mac/MacCommands.swift`.
- **Player.** `MacPlayerView` replaces the iOS touch HUD (`PlayerView`) on macOS.
  It is shown over the main window's content when
  `PlaybackCoordinator.showPlayer` is true (the TV app's model, no separate
  window). Engines stay the shared `AVPlayerEngine` / `VLCKitEngine` behind
  `PlaybackEngine`, with a macOS renderer (`NSView` hosting `AVPlayerLayer` /
  VLCKit's video view). Keyboard: Space play/pause, ←/→ seek, ↑/↓ volume,
  F full screen, Esc leave full screen / close player, ⌘F search.
- **VLCKit.** Dusk's own `VLCKit.xcframework` 3.7.3-dusk3 for macOS
  (`ci_scripts/build_vlckit.sh macos`: VLCKit commit `319ed2c0`, same patch
  series as iOS/tvOS, one universal `macos-arm64_x86_64` slice, macOS 26.0
  minimum), stamped `DuskVLCKitBuild`/`DuskVLCKitTrueHD`, so TrueHD decodes
  locally. On Mac only 0100 (TrueHD/MLP) and 0102 (no `pipe2`) matter; 0101 and
  0103 are tvOS-only no-ops. `ci_scripts/install_vlckit.sh` installs it into
  `Frameworks/VLCKit.xcframework` (git-ignored) from `DUSK_VLCKIT_CACHE_DIR` or
  the private `vlckit-3.7.3-dusk3` release; while that release has no
  `VLCKit-3.7.3-dusk3.tar.xz` asset it falls back to VideoLAN's stock macOS
  build (no stamp: TrueHD routes through Plex, and its weak `dispatch_once_f` /
  `dispatch_queue_attr_make_with_qos_class` imports trip
  `verify_embedded_vlckit.sh` allowlists for `macosx` only).
- **DuskDovi.** `scripts/build_dusk_dovi_xcframework.sh` adds a universal
  `macos-arm64_x86_64` slice (`aarch64-apple-darwin` + `x86_64-apple-darwin`,
  lipo'd).
- **Signing.** Ad-hoc (`CODE_SIGN_IDENTITY = -`), App Sandbox with network
  client + server (DV7 loopback proxy) and user-selected read-only files. No
  team, no upload. Hardened runtime is **off** on purpose: with no Team ID its
  library validation refuses the embedded VLCKit. Switch it on together with
  Developer ID / App Store signing.

## Build

```bash
./ci_scripts/install_vlckit.sh      # iOS, tvOS and macOS VLCKit
./ci_scripts/install_dusk_dovi.sh   # incl. the macOS slice
xcodegen generate
xcodebuild -project Dusk.xcodeproj -scheme Dusk-macOS -configuration Debug \
  -destination 'platform=macOS' build
```

## Release bundle

```bash
xcodebuild -project Dusk.xcodeproj -scheme Dusk-macOS -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath /tmp/dusk-mac-rel build
ditto /tmp/dusk-mac-rel/Build/Products/Release/Dusk.app build/macOS/Dusk.app
```

Universal (arm64 + x86_64), ~140 MB (VLCKit is most of it), ad-hoc signed.
`build/` is git-ignored.

## Where things are

| Area | Mac code |
| --- | --- |
| Scenes, window, Settings scene | `App/DuskApp.swift` (`#if os(macOS)` body), `Mac/MacWindow.swift` |
| Sidebar shell + router | `Mac/MacRootView.swift`, `Mac/MacSidebar.swift`, `Mac/MacShellRouter.swift` |
| Menu bar | `Mac/MacCommands.swift` (app/Edit/View/Go), `Mac/MacPlayerCommands.swift` (Playback) |
| Player UI | `Mac/MacPlayerView.swift`, `Mac/MacPlayerHUD.swift`, `Mac/MacPlayerSupport.swift`; mounted through `PlayerControlsOverlay`'s macOS branch |
| Engines | `Playback/AVPlayerEngine.swift` (`AVPlayerNSView`), `Playback/VLCKitRendererMacOS.swift`, `Playback/VideoEnhancementRenderer.swift` (AppKit Metal view) |
| Shared-UI helpers | `Mac/MacUIHover.swift` (poster hover), `Mac/MacUISheet.swift` (sheet sizes), `Mac/MacUIToolbarPlacement.swift`, `Features/Settings/SettingsContainer.swift` (`SettingsList`) |

Behaviour notes:

- Menu bar: app menu Switch User… / Sign Out…; Edit › Search ⌘F (focuses the
  sidebar search field); View › Refresh ⌘R; Go › Back ⌘[, Forward ⌘] and the
  sidebar destinations ⌘1–⌘9;
  Playback › Play/Pause Space, Skip ←/→, Previous/Next Episode ⌘←/⌘→,
  Volume ↑/↓, Mute M, Full Screen F, Picture in Picture, Close Player. Player
  items are disabled with no player up, so the bare keys fall through.
- Player: click = play/pause, double-click = full screen, pointer movement
  shows the HUD, the cursor hides with it, Esc leaves full screen then closes.
  Display sleep is held off through a `ProcessInfo` activity while playing.
  Volume/mute persist in `UserDefaults` (`macPlayerVolume`, `macPlayerMuted`).
  `MacPlayerView` runs `onPlayerDismissed()` itself on unmount (the iOS
  cover's `onDismiss`); the shell must not call it too.
- `MacPlayerSessionView` mirrors `PlayerSessionView`'s coordinator/view-model
  wiring line for line. Change both together.
- The shell forces `horizontalSizeClass = .regular`, so detail pages use the
  iPad layout. Home uses a `.mac` hero layout.
- Captures: `-DuskScreenshotSignedOut YES` opens the sign-in screen; it and
  screenshot mode use an in-memory store instead of the Keychain on the Mac
  (`KeychainHelper`), so a rebuilt ad-hoc build never blocks on a Keychain
  prompt. `-DuskScreenshotUserPicker YES` (screenshot mode) shows the Switch
  User sheet with sample profiles.
- Plex identity: X-Plex-Platform `macOS`, Device `Mac`, Device-Name = the Mac's
  name; X-Plex-Product stays `Dusk` (the plex.tv experience setting is keyed on
  it).

## Checklist

Foundation
- [x] `Dusk-macOS` target + scheme in `project.yml`, Info-macOS.plist, entitlements
- [x] VLCKit for macOS in `install_vlckit.sh`, verify script knows `macosx`
- [x] Own macOS VLCKit build with TrueHD (`build_vlckit.sh macos`); archive not published yet
- [x] DuskDovi macOS slice
- [x] `import UIKit` guarded, `PlatformTypes.swift`
- [x] Whole module compiles and links for macOS (Debug + Release, universal)

Shell (App/, Mac/)
- [x] `DuskApp` scene for macOS: main window (min size, restorable), `Settings` scene, commands
- [x] Sign-in (plex.tv PIN), Home profile picker, connection pass
- [x] Sidebar layout with per-destination navigation stacks
- [x] Menu commands: ⌘F search, ⌘R refresh, sidebar toggle, Playback menu
- [x] Launch splash skipped/adapted on macOS

Shared UI / features
- [x] Home, library grids, detail pages, search, playlists, watchlist, Live TV, photos, downloads compile and look Mac-native
- [x] Hover effects and right-click context menus on posters
- [x] Settings pages inside the Settings scene
- [x] Supporter (StoreKit) + App icon picker hidden on Mac

Player
- [x] AVPlayer engine on macOS (direct play, HDR/DV remux, DV7 proxy)
- [x] VLCKit engine on macOS (MKV/DTS/PGS…)
- [x] `MacPlayerView` HUD: hover-to-show, scrubber, tracks, quality, Up Next/skip chips
- [x] Keyboard shortcuts + Playback menu
- [x] Now Playing / media keys

Release
- [x] iOS + tvOS still build
- [x] Release `.app` bundle
- [x] Docs: what's done / missing / known issues (this file)

## Status

Everything above is **code-complete and compile-verified only**. Nothing has
been run yet (no GUI launches on the dev Mac), so every item still needs a
first real run.

## Known gaps / issues

- **Never launched.** Window sizing, sidebar look, toolbar hiding under the
  player, Settings window size, bare-key menu shortcuts vs. text fields, the
  hero layout and the hover effects are all unverified.
- **Playback unverified on a real file**: AVPlayer `NSView` host, the VLCKit
  `NSView` drawable, PiP on macOS (AVPlayer only; VLC PiP needs the iOS
  sample-buffer path), HDR/DV output on an EDR display, DV7 loopback proxy
  under the sandbox (`network.server` entitlement), Now Playing / media keys.
- **VLCKit archive not published.** The Dusk macOS VLCKit is installed locally
  from `.build/vlckit/out`; until `VLCKit-3.7.3-dusk3.tar.xz` is uploaded to the
  private `vlckit-3.7.3-dusk3` release, other clones get the stock build
  (TrueHD via Plex).
- **Only the selected sidebar destination is mounted.** Its navigation path
  survives a switch, its scroll position and view model don't (Home reloads
  when you come back).
- **Downloads** use a foreground `URLSession` on macOS: a download stops when
  the app quits.
- **Compiled out on macOS:** alternate app icons (no Mac API; the Supporter
  page shows them as an iPhone/iPad/Apple TV perk), in-app Safari (links open
  in the browser), AirPlay route picker, iOS touch/keyboard bridges,
  orientation, Always Play in Landscape, VLC PiP, AVAudioSession handling,
  the launch splash, the tab shells/More, Top Shelf.
- **No macOS unit-test target** yet (DuskTests is iOS/tvOS-hosted).
- **Hardened runtime off** for ad-hoc builds (see Signing).
- Ad-hoc signing changes the code identity on every build, so the login
  keychain may ask again for the Plex token item after a rebuild.
- Trackpad swipe on the Home hero doesn't page (chevrons + pager do).
- Universal Purchase, Mac App Store/TestFlight, Sparkle/notarization: not
  started (decisions for the owner).
