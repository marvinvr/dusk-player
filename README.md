# Dusk for Plex

A native Swift/SwiftUI Plex client for Apple platforms.

> **Warning:** This project is under very active development. Expect bugs and unexpected behavior. If you run into issues, please [submit an issue](https://github.com/marvinvr/dusk-for-plex/issues).

> **Download:** For now, the app needs to be compiled manually (see setup below). A TestFlight / App Store link will be added here in the near future.

## Features

- [x] Direct Play
- [x] Plex authentication & server discovery
- [x] Library browsing
- [x] Search
- [x] Movie & TV show detail views
- [x] Subtitle & audio track selection
- [x] Continuous Playback
- [ ] App Store Release
- [ ] tvOS App
- [x] Skip Intro & Credits
- [ ] Chapter Markers
- [ ] Select which version to play
- [x] Picture in Picture
- [x] Passout Protection (Are you still watching?)
- [ ] macOS App
- [ ] Transcoding Support
- [ ] Offline playback (Downloads)
- [ ] Plex Home Integration

** Maybe? **
- [ ] Jellyfin Support

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
