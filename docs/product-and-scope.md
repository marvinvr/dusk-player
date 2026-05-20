# Product And Scope

This is the long-lived product context for Dusk. Keep implementation details in
the focused topic docs and keep this file to intent, constraints, and non-goals.

## Product Shape

Dusk is a native Swift/SwiftUI Plex client for Apple platforms. It is built for
people who run their own Plex servers and want a focused client for browsing and
playing their libraries without promoted content or extra service layers.

This is a personal/small-audience project. Favor straightforward, maintainable
code over enterprise abstractions, broad plugin systems, or premature provider
boundaries.

## Core Principles

- Plex is the source of truth for metadata, watch state, library contents, and
  server identity.
- Local persistence is limited to auth tokens, user preferences, explicit
  downloads/offline state, and caches that are documented in the relevant topic
  doc.
- Playback starts direct when using Plex-hosted media. Manual transcoding is a
  per-session player Quality action only; no stored quality setting may start
  video transcoding automatically.
- SwiftUI UI should be shared where practical and platform-aware where needed.
- Plex-specific service code is acceptable. Do not introduce generic provider
  abstractions until a second backend is actually being implemented.
- Dependencies should stay minimal. VLCKit is vendored manually; system
  frameworks and URLSession are preferred elsewhere.

## Platform Targets

`project.yml` is authoritative for build targets and deployment versions:

- `Dusk`: iOS/iPadOS app target, currently iOS 18.0 minimum.
- `Dusk-tvOS`: tvOS app target, currently tvOS 26.0 minimum.

macOS support should be checked against current project and App Store settings
before making implementation claims. There is no separate native macOS target in
`project.yml` today.

## Feature Scope

Current product pillars:

- Plex sign-in, server discovery, and server switching.
- Home hubs, library browsing, genre filtering, search, and detail screens.
- Hybrid playback through AVPlayer and VLCKit.
- Subtitle and audio track selection.
- Manual player Quality selection for Plex transcoding.
- Timeline reporting, scrobble/unscrobble, resume, skip intro/credits,
  continuous playback, and passout protection.
- Offline downloads and delayed watch-state sync.

Future ideas such as Jellyfin, Live TV, managed users, collections, playlists,
native macOS work, or broader provider abstractions are not current architecture
requirements. Do not shape today's code around them without an explicit task.

## Dependency And Licensing Decisions

- VLCKit is checked in as dynamic xcframeworks under `Frameworks/` and linked
  dynamically for LGPL compliance.
- XcodeGen owns the generated Xcode project; edit `project.yml`, then regenerate
  when project structure changes.
- Image loading uses the app's Plex-aware image pipeline and URL caching rather
  than a third-party image dependency.
- Networking uses async/await and URLSession. Avoid Combine unless wrapping
  callback-driven APIs such as player engines.

## Privacy And Network Boundaries

Dusk should not collect analytics, telemetry, or tracking data. Network traffic
should be limited to Plex account/server APIs, selected Plex servers, artwork and
media URLs derived from Plex, and explicitly requested external links such as
project/license pages.

Do not log raw token-bearing URLs. Playback and image URLs often include
`X-Plex-Token` because AVPlayer and VLCKit load media directly.
