import Foundation

/// Determines which playback engine to use based on the media's codec profile.
///
/// Decision logic (from SPEC.md §4.2):
/// - **AVPlayer** when ALL of: container is mp4/mov/m4v, video is h264/hevc/av1,
///   audio is aac/ac3/eac3/alac/mp3/flac, and all subtitles are either
///   tx3g/mov_text (embedded) or external text (srt/vtt).
/// - **VLCKit** for everything else: MKV/AVI/WMV containers, DTS/TrueHD audio,
///   PGS/ASS/SSA subtitles, or any combination outside the AVPlayer set.
enum StreamResolver {
    struct Decision: Sendable {
        let engine: PlaybackEngineType
        let reason: String
    }

    // MARK: - AVPlayer-Compatible Codec Sets

    private static let avContainers: Set<String> = ["mp4", "mov", "m4v"]

    private static let avVideoCodecs: Set<String> = ["h264", "hevc", "av1"]

    private static let avAudioCodecs: Set<String> = [
        "aac", "ac3", "eac3", "alac", "mp3", "flac",
    ]

    /// Subtitle codecs that AVPlayer can render natively (embedded or external text).
    private static let avSubtitleCodecs: Set<String> = [
        "tx3g", "mov_text",   // Embedded MP4 text tracks
        "srt", "subrip",      // External text
        "vtt", "webvtt",      // WebVTT
    ]

    // MARK: - Resolution

    /// Choose the most appropriate Plex media version for playback.
    /// Preference is treated as a target, not a hard failure condition.
    static func selectMediaVersion(
        from mediaVersions: [PlexMedia],
        preferredMaxResolution: MaxResolution
    ) -> PlexMedia? {
        let playableCandidates = mediaVersions.enumerated().compactMap { entry -> MediaCandidate? in
            let (index, media) = entry
            guard !media.parts.isEmpty else { return nil }
            return MediaCandidate(index: index, media: media)
        }

        // Prefer versions whose underlying file Plex still reports as present.
        // When a file is deleted and re-added (often with different naming),
        // Plex can keep the dead version (accessible/exists = false) alongside
        // the live one; direct-playing it 404s and surfaces as "not available".
        // Fall back to the full set when nothing is explicitly flagged available.
        let availableCandidates = playableCandidates.filter { $0.media.hasAvailablePart }
        let candidates = availableCandidates.isEmpty ? playableCandidates : availableCandidates

        guard !candidates.isEmpty else { return mediaVersions.first }
        guard candidates.count > 1 else { return candidates.first?.media }

        let targetHeight = preferredMaxResolution.selectionTargetMaxHeight

        let withinTarget = candidates
            .filter { candidate in
                guard let height = candidate.height else { return false }
                return height <= targetHeight
            }
            .sorted(by: sortWithinTarget)

        if let bestWithinTarget = withinTarget.first {
            return bestWithinTarget.media
        }

        let aboveTarget = candidates
            .filter { candidate in
                guard let height = candidate.height else { return false }
                return height > targetHeight
            }
            .sorted(by: sortAboveTarget)

        if let closestAboveTarget = aboveTarget.first {
            return closestAboveTarget.media
        }

        return candidates
            .sorted(by: sortUnknownHeights)
            .first?.media
    }

    /// Inspect a `PlexMedia` and decide which engine should play it.
    ///
    /// - Parameters:
    ///   - media: The media version to evaluate (container + codec info).
    ///   - forceAVPlayer: User preference override — always returns `.avPlayer` when true.
    ///   - forceVLCKit: User preference override — always returns `.vlcKit` when true.
    /// - Returns: The engine type to instantiate.
    static func resolve(
        media: PlexMedia,
        forceAVPlayer: Bool = false,
        forceVLCKit: Bool = false
    ) -> PlaybackEngineType {
        evaluate(
            media: media,
            forceAVPlayer: forceAVPlayer,
            forceVLCKit: forceVLCKit
        ).engine
    }

    static func evaluate(
        media: PlexMedia,
        forceAVPlayer: Bool = false,
        forceVLCKit: Bool = false
    ) -> Decision {
        if forceAVPlayer {
            return Decision(engine: .avPlayer, reason: "User preference forced AVPlayer")
        }
        if forceVLCKit {
            return Decision(engine: .vlcKit, reason: "User preference forced VLCKit")
        }

        // Container check
        guard let container = media.container?.lowercased(),
              avContainers.contains(container) else {
            let unsupportedContainer = media.container?.uppercased() ?? "unknown"
            return Decision(
                engine: .vlcKit,
                reason: "Container \(unsupportedContainer) is not AVPlayer-compatible"
            )
        }

        // Video codec check
        guard let videoCodec = media.videoCodec?.lowercased(),
              avVideoCodecs.contains(videoCodec) else {
            let unsupportedVideoCodec = media.videoCodec?.uppercased() ?? "unknown"
            return Decision(
                engine: .vlcKit,
                reason: "Video codec \(unsupportedVideoCodec) requires VLCKit"
            )
        }

        // Audio codec check
        guard let audioCodec = media.audioCodec?.lowercased(),
              avAudioCodecs.contains(audioCodec) else {
            let unsupportedAudioCodec = media.audioCodec?.uppercased() ?? "unknown"
            return Decision(
                engine: .vlcKit,
                reason: "Audio codec \(unsupportedAudioCodec) requires VLCKit"
            )
        }

        // Subtitle check — every subtitle stream must be AVPlayer-compatible.
        // External text subs (srt, vtt) are fine. Embedded bitmap subs (PGS, VOBSUB)
        // and complex styled subs (ASS/SSA) require VLCKit.
        if let part = media.parts.first {
            let subtitleStreams = part.streams.filter { $0.streamType == .subtitle }
            for stream in subtitleStreams {
                guard let codec = stream.codec?.lowercased() else { continue }
                if !avSubtitleCodecs.contains(codec) {
                    return Decision(
                        engine: .vlcKit,
                        reason: "Subtitle codec \(codec.uppercased()) requires VLCKit"
                    )
                }
            }
        }

        return Decision(
            engine: .avPlayer,
            reason: "Container, codecs, and subtitles are AVPlayer-compatible"
        )
    }
}

private extension StreamResolver {
    struct MediaCandidate {
        let index: Int
        let media: PlexMedia

        var height: Int? {
            Self.resolveHeight(for: media)
        }

        var bitrate: Int {
            Self.resolveBitrate(for: media)
        }

        var isOptimizedForStreaming: Bool {
            media.optimizedForStreaming == 1
        }

        private static func resolveHeight(for media: PlexMedia) -> Int? {
            if let height = media.height, height > 0 {
                return height
            }

            if let streamHeight = primaryVideoStream(in: media)?.height,
               streamHeight > 0 {
                return streamHeight
            }

            guard let resolution = media.videoResolution?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !resolution.isEmpty else {
                return nil
            }

            switch resolution {
            case "4k":
                return 2160
            case "sd":
                return 480
            default:
                let digits = resolution.compactMap(\.wholeNumberValue)
                guard !digits.isEmpty else { return nil }
                return digits.reduce(0) { ($0 * 10) + $1 }
            }
        }

        private static func resolveBitrate(for media: PlexMedia) -> Int {
            if let bitrate = media.bitrate, bitrate > 0 {
                return bitrate
            }

            if let streamBitrate = primaryVideoStream(in: media)?.bitrate,
               streamBitrate > 0 {
                return streamBitrate
            }

            return 0
        }

        private static func primaryVideoStream(in media: PlexMedia) -> PlexStream? {
            for part in media.parts {
                if let stream = part.streams.first(where: { $0.streamType == .video }) {
                    return stream
                }
            }

            return nil
        }
    }

    static func sortWithinTarget(_ lhs: MediaCandidate, _ rhs: MediaCandidate) -> Bool {
        if lhs.height != rhs.height {
            return (lhs.height ?? 0) > (rhs.height ?? 0)
        }
        if lhs.bitrate != rhs.bitrate {
            return lhs.bitrate > rhs.bitrate
        }
        if lhs.isOptimizedForStreaming != rhs.isOptimizedForStreaming {
            return lhs.isOptimizedForStreaming && !rhs.isOptimizedForStreaming
        }
        return lhs.index < rhs.index
    }

    static func sortAboveTarget(_ lhs: MediaCandidate, _ rhs: MediaCandidate) -> Bool {
        if lhs.height != rhs.height {
            return (lhs.height ?? .max) < (rhs.height ?? .max)
        }
        if lhs.bitrate != rhs.bitrate {
            return lhs.bitrate > rhs.bitrate
        }
        if lhs.isOptimizedForStreaming != rhs.isOptimizedForStreaming {
            return lhs.isOptimizedForStreaming && !rhs.isOptimizedForStreaming
        }
        return lhs.index < rhs.index
    }

    static func sortUnknownHeights(_ lhs: MediaCandidate, _ rhs: MediaCandidate) -> Bool {
        if lhs.bitrate != rhs.bitrate {
            return lhs.bitrate > rhs.bitrate
        }
        if lhs.isOptimizedForStreaming != rhs.isOptimizedForStreaming {
            return lhs.isOptimizedForStreaming && !rhs.isOptimizedForStreaming
        }
        return lhs.index < rhs.index
    }
}
