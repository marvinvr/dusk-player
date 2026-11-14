# macOS App

Native Mac version of Dusk: SwiftUI on AppKit (target `Dusk-macOS`), **not**
Catalyst and not "Designed for iPad". On `main` since 1.9 (merged from
`macos-app`). Same bundle ID as iOS/tvOS (`com.dusk-player.app`): one app in
App Store Connect, Universal Purchase. Never commit another bundle ID; local
test installs override it on the command line only (see Local test install).

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
- **Signing.** The project builds ad-hoc (`CODE_SIGN_IDENTITY = -`, no team)
  with App Sandbox, network client + server (DV7 loopback proxy) and
  user-selected read-only files (`Dusk/Support/Dusk-macOS.entitlements`).
  Hardened runtime is off in the project on purpose: with no Team ID its
  library validation refuses the embedded VLCKit. `scripts/testflight.sh`
  turns it on for the Mac App Store archive (`ENABLE_HARDENED_RUNTIME = YES`
  in its signing xcconfig), where Apple Distribution signs the app and VLCKit
  with the same Team ID; no hardened-runtime exception entitlements are
  needed. See Mac App Store / TestFlight below.

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

### Local test install

A side-by-side test copy that doesn't share the App Store app's container or
Keychain item (the Mac Keychain service is the bundle ID): override the ID and
name on the command line only, never in `project.yml`.

```bash
xcodebuild -project Dusk.xcodeproj -scheme Dusk-macOS -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath /tmp/dusk-mac-dev \
  PRODUCT_BUNDLE_IDENTIFIER=com.dusk-player.app.macdev build
ditto /tmp/dusk-mac-dev/Build/Products/Release/Dusk.app "/tmp/Dusk Mac Beta.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Dusk Mac Beta' "/tmp/Dusk Mac Beta.app/Contents/Info.plist"
codesign --force --sign - --entitlements Dusk/Support/Dusk-macOS.entitlements "/tmp/Dusk Mac Beta.app"
```

## Mac App Store / TestFlight

`scripts/testflight.sh` has a `macos` platform (scheme `Dusk-macOS`), part of
the default `all`; `--platform macos` runs it alone. Same flow, result lines
and exit codes as iOS/tvOS (docs/development-workflow.md → TestFlight); a
`--dry-run` ends in `pkg=<path>` instead of `ipa=`. It needs, on the build Mac:

- Mac App Store provisioning profile for `com.dusk-player.app`, platform OSX,
  App Store Connect type `MAC_APP_STORE` (currently **Dusk Mac App Store
  (Molty)**), installed as a `.provisionprofile` in
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles`. Mac App Store
  profiles carry no `beta-reports-active`; a Developer ID profile is told apart
  by its type. Sandbox keys (`com.apple.security.*`) aren't provisioned and
  aren't checked against the profile.
- **Apple Distribution** identity (signs the app and frameworks) and
  **3rd Party Mac Developer Installer** (= Mac Installer Distribution, signs
  the `.pkg`), both for the team, in `SIGNING_KEYCHAIN` (or the default search
  list). A missing profile or identity fails the platform with code 3 naming it.
- Dusk's own macOS VLCKit in the checkout's `Frameworks/VLCKit.xcframework`
  (stamp `3.7.3-dusk3`). Stock VideoLAN VLCKit fails the platform with code 8
  (no TrueHD), unless `DUSK_MACOS_ALLOW_STOCK_VLCKIT=1`. Until the archive is
  on the private release, install it from a local copy:
  `DUSK_VLCKIT_CACHE_DIR=<dir with VLCKit-3.7.3-dusk3.tar.xz> ci_scripts/install_vlckit.sh`
  (the dev Mac keeps a copy in `~/Library/Caches/dusk-vlckit`).

Checked 2026-11-14 with a dry run: archive signed Apple Distribution with the
hardened runtime, sandbox entitlements as above, `.pkg` signed by the
installer identity, and `altool --validate-app -t macos` passed. No build was
uploaded.

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
- [x] `scripts/testflight.sh` `macos` platform (Mac App Store signing, hardened runtime); dry run + App Store validation passed
- [x] Docs: what's done / missing / known issues (this file)

## Status

Code-complete. Three visual QA rounds ran the app against a mock Plex (see
Visual QA below); real-server use, real playback quality and the first
TestFlight build are still ahead.

## Known gaps / issues

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
- **Hardened runtime off** for ad-hoc builds (see Signing); on only in the
  testflight.sh archive, which has not been launched yet.
- Ad-hoc signing changes the code identity on every build, so the login
  keychain may ask again for the Plex token item after a rebuild.
- Trackpad swipe on the Home hero doesn't page (chevrons + pager do).
- Offline: with no reachable server the shell opens Downloads (as iOS since
  #77) but the sidebar keeps its library destinations.

## Visual QA (2026-11-13)

First real runs on the dev Mac, against a scratch copy of the dusk-screenshots
mock Plex (demo account, three servers, MP4 + one MKV title for VLCKit) in
DEBUG screenshot mode (`-DuskScreenshotScreen …`; the Mac shell routes it in
`Mac/MacScreenshotRouting.swift`; `-DuskScreenshotSignedOut YES` shows
sign-in; `-DuskScreenshotUserPicker YES` the profile sheet;
`-DuskMacLibraryMode library|collections`; `-DuskScreenshotScrubHover <f>`).
Screen mode/QA builds keep sign-ins in memory, never the Keychain. Driven with
a small AX/CGEvent harness and `screencapture -l`, reviewed by fresh
Mac-designer agents per round.

- Round 1 (~120 findings) and round 2 (~75) fixed and committed: Mac chrome
  (transparent toolbar + soft scroll edge, heroes under the toolbar), sidebar
  search, back/forward, toolbar library controls + Recommended/Library/
  Collections switch, filters popover, Downloads list, tabbed Settings window,
  About panel, rebuilt player HUD (traffic lights, glass bar, upward NSMenus,
  merged Audio & Subtitles, More, AirPlay, scrub hover), system accent on Mac.
- Shared bug found: AVFoundation's synthesized "forced" subtitle copies
  consumed the next Plex stream in `mergeSubtitleMetadata`, so AVPlayer
  subtitle labels were shifted (forced English shown as "French"). Fixed for
  all platforms on main (bbc3685, `forcedTwinSource`).
- Round 3 (~30 findings, no P1 visual bugs left) fixed and committed:
  light-mode hero fades (Home + detail), episode heroes use show/season art,
  balanced Information grid, Mac-only Settings copy, shelf paging metrics
  (shelves beside the sidebar rest at a -210pt inset), toolbar menu sizing,
  Live TV ruler/cell fills, VLC video view no longer makes clicks window
  drags (`mouseDownCanMoveWindow`), scrub hover marker.
- Shared Live TV guide bug: the now pill's leading alignment guide shifted the
  whole ruler right of the grid. Fixed for all platforms on main (f0e5e3e).
- Still open / unverified (final verification pass blocked: the screen was
  locked):
  - Round-3 fixes A1/A7 (toolbar menu re-measure, library title), filters
    pop-up widths, sign-in link hover, player top scrim + scrub marker: built,
    not re-captured.
  - Real-mouse click on VLC sessions' HUD menus (AX press works; the drag
    region fix is the likely cause, unproven).
  - Light detail pages: hero-to-first-section gap is ~120pt (40pt dark +
    64pt fade below the buttons).
  - Not mouse-verified: shelf/hero hover chevrons, title menu, Downloads
    context menu/Delete key, Open Live TV Settings…, AirPlay picker click.
  - Corrupt local download fails with no streaming fallback (shared code).
  - Episode page has no "other episodes" shelf.
