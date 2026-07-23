# Dusk for Plex

A native Swift/SwiftUI Plex client for Apple platforms, with AI upscaling for lower-resolution video.

![Dusk website](screenshots/dusk_website_screenshot.png)

> **Warning:** This project is under very active development. Expect bugs and unexpected behavior. If you run into issues, please [submit an issue](https://github.com/marvinvr/dusk-player/issues).

[![Download on the App Store](https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg)](https://apps.apple.com/us/app/dusk-for-plex/id6760492635)

## Features

- [x] Direct Play
- [x] Manual Transcoding
- [x] Library browsing & Search
- [x] Subtitle & audio track selection
- [x] Continuous Playback
- [x] Picture in Picture
- [x] Skip Intro & Credits
- [x] Passout Protection (Are you still watching?)
- [x] macOS App
- [x] Select which version to play
- [x] tvOS App
- [x] App Store Release
- [x] Offline playback (Downloads)
- [x] AI Upscaling
- [x] Plex Home Integration
- [ ] SharePlay Integration
- [ ] Translation of the UI
- [x] Seerr Integration

### Later down the line
- [ ] Jellyfin Support

### Maybe?

- [ ] Apple Vision Pro App
- [ ] Live TV Support

## Setup

```bash
# 1. Generate the Xcode project if needed
brew install xcodegen  # if not already installed
xcodegen generate

# 2. Open in Xcode
open Dusk.xcodeproj
```

VLCKit is vendored but **not committed** to git: the `Frameworks/MobileVLCKit.xcframework` (iOS/iPadOS) and `Frameworks/TVVLCKit.xcframework` (tvOS) binaries are downloaded on demand. After cloning, fetch them (this also refreshes the pinned version):

```bash
./ci_scripts/install_vlckit.sh
```

CI does this automatically via `ci_scripts/ci_post_clone.sh`, so no binaries live in the repo.

## License

Dusk is released under the [MIT License](LICENSE).

Playback is powered by [VLCKit](https://code.videolan.org/videolan/VLCKit)
(MobileVLCKit/TVVLCKit), which is licensed separately under the LGPL v2.1.
