# Dusk for Plex

A native Swift/SwiftUI Plex client for Apple platforms.

> **Warning:** This project is under very active development. Expect bugs and unexpected behavior. If you run into issues, please [submit an issue](https://github.com/marvinvr/dusk-player/issues).

> **Download:** For now, the app needs to be compiled manually (see setup below). A TestFlight / App Store link will be added here in the near future.

## Features

- [x] Direct Play
- [x] Library browsing & Search
- [x] Subtitle & audio track selection
- [x] Continuous Playback
- [x] Picture in Picture
- [x] Skip Intro & Credits
- [x] Passout Protection (Are you still watching?)
- [x] macOS App
- [ ] Select which version to play
- [ ] tvOS App
- [ ] App Store Release
- [ ] Offline playback (Downloads)
- [ ] Plex Home Integration

### Later down the line
- [ ] Jellyfin Support
- [ ] Live TV Support
- [ ] Transcoding Support

## Setup

```bash
# 1. Generate the Xcode project if needed
brew install xcodegen  # if not already installed
xcodegen generate

# 2. Open in Xcode
open Dusk.xcodeproj
```

The repository now vendors `Frameworks/VLCKit.xcframework` directly. To refresh that binary manually, run:

```bash
./ci_scripts/install_vlckit.sh
```

## License

MIT
