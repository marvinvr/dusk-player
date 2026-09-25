import Foundation
import VideoToolbox

/// Determines which playback engine to use based on the media's codec profile.
///
/// Decision logic (from SPEC.md §4.2, evaluated per stream across ALL parts —
/// parts without stream metadata fall back to the media-level summary fields):
/// - **Dolby Vision profile 5** (IPTPQc2 color, no HDR10-compatible base layer)
///   is flagged `requiresServerTranscode` regardless of container — neither
///   AVPlayer nor libvlc can tone-map it locally. Profiles 7/8 play through
///   their HDR10 base layer and follow normal engine selection.
/// - **AVPlayer** when ALL of: container is mp4/mov/m4v, video is 8-bit h264,
///   hevc, or av1 with a hardware decoder, audio is aac/ac3/eac3/alac/mp3/flac,
///   and all subtitles are either tx3g/mov_text (embedded) or external text
///   (srt/vtt).
/// - **VLCKit** for everything else: MKV/AVI/WMV containers, 10-bit H.264
///   (Hi10P), AV1 without hardware decode (libvlc has dav1d software decode),
///   DTS/TrueHD audio, PGS/ASS/SSA subtitles, or any combination outside the
///   AVPlayer set.
enum StreamResolver {
    struct Decision: Sendable {
        let engine: PlaybackEngineType
        let reason: String
        /// True when neither local engine can render this media correctly
        /// (e.g. Dolby Vision profile 5, whose IPTPQc2 color neither AVPlayer
        /// from a remux nor libvlc can tone-map). The coordinator should start
        /// such media on the server-transcode ladder rung instead of direct play.
        var requiresServerTranscode: Bool = false
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

        // Dolby Vision profile 5 check — before the container check on purpose:
        // a DV5 MKV must flag the server transcode too, since neither local
        // engine can tone-map IPTPQc2 color.
        if let dolbyVisionDecision = dolbyVisionDecision(for: media) {
            return dolbyVisionDecision
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

        // Video codec check — per stream across all parts
        if let videoDecision = videoDecision(for: media) {
            return videoDecision
        }

        // Audio codec check — per stream across all parts
        if let audioDecision = audioDecision(for: media) {
            return audioDecision
        }

        // Subtitle check — every subtitle stream in every part must be
        // AVPlayer-compatible. External text subs (srt, vtt) are fine. Embedded
        // bitmap subs (PGS, VOBSUB) and complex styled subs (ASS/SSA) require VLCKit.
        for part in media.parts {
            for stream in part.streams where stream.streamType == .subtitle {
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

    /// Live TV is already packaged by Plex as HLS, so the source file's
    /// container is irrelevant. Codec and subtitle capabilities still decide
    /// whether the native HLS path or VLCKit is the safer renderer.
    static func evaluateLiveTV(
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
        if let decision = dolbyVisionDecision(for: media) {
            return decision
        }
        if let decision = videoDecision(for: media) {
            return decision
        }
        if let decision = audioDecision(for: media) {
            return decision
        }
        for part in media.parts {
            for stream in part.streams where stream.streamType == .subtitle {
                guard let codec = stream.codec?.lowercased() else { continue }
                if !avSubtitleCodecs.contains(codec) {
                    return Decision(
                        engine: .vlcKit,
                        reason: "Live subtitle codec \(codec.uppercased()) requires VLCKit"
                    )
                }
            }
        }
        return Decision(engine: .avPlayer, reason: "Plex Live HLS is AVPlayer-compatible")
    }

    // MARK: - Dolby Atmos / Spatial Audio Remux

    /// Subtitle codecs Plex can convert to WebVTT HLS segments without touching
    /// the video. Bitmap subtitles (PGS, VobSub) would be burned in — a video
    /// re-encode — and styled ASS/SSA would lose its styling, so both keep the
    /// VLCKit direct-play path.
    private static let remuxTextSubtitleCodecs: Set<String> = [
        "srt", "subrip", "vtt", "webvtt", "mov_text", "tx3g",
    ]

    /// Whether this file should reach AVPlayer through a Plex copy-remux so
    /// Dolby audio plays as Atmos (HDMI) or spatial audio (AirPods) instead of
    /// VLCKit's plain PCM decode. Returns why not, or nil when it qualifies.
    ///
    /// Only files that would otherwise direct play on VLCKit are considered —
    /// AVPlayer-compatible files already get Atmos/spatial audio natively. The
    /// video must be something AVPlayer decodes from fMP4 HLS (8-bit H.264 or
    /// HEVC). The audio stream playback would open on must be Dolby: E-AC-3
    /// with Atmos everywhere, and on iPhone/iPad any 5.1+ AC-3/E-AC-3 (AVPlayer
    /// spatializes multichannel Dolby for AirPods; on tvOS VLCKit already
    /// outputs discrete multichannel PCM, so only Atmos is worth the remux).
    ///
    /// HDR video needs `displaySupportsHDR` (`AVPlayer.eligibleForHDRPlayback`):
    /// Plex declares the remux's only variant `VIDEO-RANGE=PQ`, AVFoundation
    /// refuses such a stream on an SDR display
    /// (`AVErrorNoCompatibleAlternatesForExternalDisplay`) and rejects it if
    /// the declaration is removed (CoreMedia -12927). VLCKit tone-maps there.
    static func spatialAudioRemuxBlocker(
        media: PlexMedia,
        decision: Decision,
        audioStream: PlexStream?,
        subtitleStream: PlexStream?,
        displaySupportsHDR: Bool,
        convertsAudio: Bool = false
    ) -> String? {
        guard decision.engine == .vlcKit, !decision.requiresServerTranscode else {
            return "not a VLCKit direct-play file"
        }
        guard media.parts.count == 1 else { return "multi-part media" }
        if let videoDecision = videoDecision(for: media) {
            return videoDecision.reason
        }
        let videoCodecs = media.parts.flatMap(\.streams)
            .filter { $0.streamType == .video }
            .compactMap { $0.codec?.lowercased() }
        guard !videoCodecs.isEmpty, videoCodecs.allSatisfy({ $0 == "h264" || $0 == "hevc" }) else {
            return "video codec is not H.264/HEVC"
        }
        let hasHDRVideo = media.parts.flatMap(\.streams).contains {
            $0.streamType == .video && ($0.isHDRVideo || $0.doviPresent == true)
        }
        if hasHDRVideo && !displaySupportsHDR {
            return "HDR video on a display without HDR playback"
        }
        // Converting (TrueHD & co.): Plex re-encodes the audio, so any
        // selected stream qualifies; only the video must be copyable.
        guard let audioStream, convertsAudio || isSpatialAudioCandidate(audioStream) else {
            return "audio track is not Dolby Atmos\(platformSpatialAudioSuffix)"
        }
        if let subtitleStream, !canRideRemux(subtitle: subtitleStream) {
            return "subtitle \(subtitleStream.codec?.uppercased() ?? "?") cannot ride the remux"
        }
        return nil
    }

    static func canRideRemux(subtitle stream: PlexStream) -> Bool {
        remuxTextSubtitleCodecs.contains(stream.codec?.lowercased() ?? "")
    }

    static func isSpatialAudioCandidate(_ stream: PlexStream) -> Bool {
        let codec = stream.codec?.lowercased()
        guard codec == "eac3" || codec == "ac3" else { return false }
        if isDolbyAtmos(stream) { return true }
        #if os(tvOS)
        return false
        #else
        return (stream.channels ?? 0) >= 6
        #endif
    }

    /// Plex reports E-AC-3 + JOC as profile "dolby digital plus + dolby atmos".
    static func isDolbyAtmos(_ stream: PlexStream) -> Bool {
        guard stream.codec?.lowercased() == "eac3" else { return false }
        let labels = [stream.profile, stream.extendedDisplayTitle, stream.displayTitle]
            .compactMap { $0?.lowercased() }
        return labels.contains { $0.contains("atmos") }
    }

    private static var platformSpatialAudioSuffix: String {
        #if os(tvOS)
        ""
        #else
        " or multichannel Dolby"
        #endif
    }

    // MARK: - Per-Stream Checks

    /// Whether this device can hardware-decode AV1 (A17 Pro / M3 and newer).
    /// Cached so the VideoToolbox query runs once per process, not per decision.
    private static let hasAV1HardwareDecode: Bool =
        VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    /// Dolby Vision profile 5 carries IPTPQc2 color with no HDR10-compatible
    /// base layer; neither AVPlayer (from a remux) nor libvlc can tone-map it,
    /// so it must start on the server-transcode ladder rung. Profiles 7/8 (and
    /// anything with a base-layer compatibility ID) render fine via their HDR10
    /// base layer, so they stay on normal engine selection.
    private static func dolbyVisionDecision(for media: PlexMedia) -> Decision? {
        for part in media.parts {
            for stream in part.streams where stream.streamType == .video {
                guard stream.doviPresent == true || stream.doviProfile != nil else { continue }
                if stream.doviProfile == 5 {
                    return Decision(
                        engine: .avPlayer,
                        reason: "Dolby Vision profile 5 requires server transcode (no local tone mapping)",
                        requiresServerTranscode: true
                    )
                }
            }
        }
        return nil
    }

    /// Check every video stream in every part; parts without stream metadata
    /// (tolerated — Plex omits streams on some endpoints) fall back to the
    /// media-level summary codec. Returns nil when AVPlayer can handle it all.
    private static func videoDecision(for media: PlexMedia) -> Decision? {
        var checkedStreamMetadata = false

        for part in media.parts {
            for stream in part.streams where stream.streamType == .video {
                checkedStreamMetadata = true
                if let decision = videoDecision(
                    codec: stream.codec ?? media.videoCodec,
                    stream: stream
                ) {
                    return decision
                }
            }
        }

        let hasStreamlessPart = media.parts.isEmpty || media.parts.contains { $0.streams.isEmpty }
        if !checkedStreamMetadata || hasStreamlessPart {
            return videoDecision(codec: media.videoCodec, stream: nil)
        }
        return nil
    }

    /// Evaluate one video stream (or the media-level summary when `stream` is
    /// nil). Returns nil when the stream is AVPlayer-compatible.
    private static func videoDecision(codec rawCodec: String?, stream: PlexStream?) -> Decision? {
        guard let codec = rawCodec?.lowercased(),
              avVideoCodecs.contains(codec) else {
            let unsupportedVideoCodec = rawCodec?.uppercased() ?? "unknown"
            return Decision(
                engine: .vlcKit,
                reason: "Video codec \(unsupportedVideoCodec) requires VLCKit"
            )
        }

        switch codec {
        case "h264":
            // AVPlayer only hardware-decodes 8-bit H.264; Hi10P anime encodes
            // would stutter or fail, while libvlc decodes them in software.
            if let stream, isTenBitH264(stream) {
                return Decision(
                    engine: .vlcKit,
                    reason: "10-bit H.264 (Hi10P) has no hardware decoder and requires VLCKit"
                )
            }
        case "av1":
            // Only A17 Pro / M3-class chips decode AV1 in hardware; AVPlayer
            // has no software fallback, but libvlc ships dav1d.
            if !hasAV1HardwareDecode {
                return Decision(
                    engine: .vlcKit,
                    reason: "AV1 has no hardware decoder on this device and requires VLCKit (dav1d)"
                )
            }
        default:
            break // hevc needs no extra per-stream checks.
        }
        return nil
    }

    /// Hi10P detection: Plex reports the codec profile as "High 10" and/or a
    /// bit depth above 8 on the video stream.
    private static func isTenBitH264(_ stream: PlexStream) -> Bool {
        if let profile = stream.profile?.lowercased(), profile.contains("high 10") {
            return true
        }
        return (stream.bitDepth ?? 8) > 8
    }

    /// Check every audio stream in every part; parts without stream metadata
    /// fall back to the media-level summary codec. Any single incompatible
    /// track routes to VLCKit so all tracks stay selectable.
    private static func audioDecision(for media: PlexMedia) -> Decision? {
        var checkedStreamMetadata = false

        for part in media.parts {
            for stream in part.streams where stream.streamType == .audio {
                checkedStreamMetadata = true
                if let decision = audioDecision(codec: stream.codec ?? media.audioCodec) {
                    return decision
                }
            }
        }

        let hasStreamlessPart = media.parts.isEmpty || media.parts.contains { $0.streams.isEmpty }
        if !checkedStreamMetadata || hasStreamlessPart {
            return audioDecision(codec: media.audioCodec)
        }
        return nil
    }

    /// Evaluate one audio codec. Returns nil when AVPlayer can play it.
    private static func audioDecision(codec rawCodec: String?) -> Decision? {
        guard let codec = rawCodec?.lowercased(),
              avAudioCodecs.contains(codec) else {
            let unsupportedAudioCodec = rawCodec?.uppercased() ?? "unknown"
            return Decision(
                engine: .vlcKit,
                reason: "Audio codec \(unsupportedAudioCodec) requires VLCKit"
            )
        }
        return nil
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
