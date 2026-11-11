import Foundation

/// Determines which playback engine to use based on the media's codec profile.
///
/// Decision logic (from SPEC.md §4.2, evaluated per stream across ALL parts —
/// parts without stream metadata fall back to the media-level summary fields):
/// - **Dolby Vision profile 5** (IPTPQc2 color, no HDR10-compatible base layer)
///   is flagged `requiresServerTranscode` regardless of container — libvlc
///   cannot reshape it, and AVPlayer only renders it from MP4 carrying the DV
///   signaling (see `dolbyVisionRemuxBlocker`). The engine still follows the
///   container so a last-resort direct play never hands AVPlayer an MKV.
///   Profiles 7/8 follow normal engine selection; a VLCKit-only HDR file
///   (Dolby Vision 7/8, HDR10, HDR10+, HLG) can then reach AVPlayer through
///   the HDR remux (see `hdrVideoRemuxBlocker`).
/// - **AVPlayer** when ALL of: container is mp4/mov/m4v, video is 8-bit h264,
///   hevc, or av1 with a hardware decoder, audio is aac/ac3/eac3/alac/mp3/flac,
///   and all subtitles are either tx3g/mov_text (embedded) or external text
///   (srt/vtt).
/// - **VLCKit** for everything else: MKV/AVI/WMV containers, 10-bit H.264
///   (Hi10P), budgeted SDR AV1 software decode (see StreamResolver+AV1),
///   DTS/TrueHD audio, PGS/ASS/SSA subtitles, or any combination outside the
///   AVPlayer set.
enum StreamResolver {
    struct Decision: Sendable {
        let engine: PlaybackEngineType
        let reason: String
        /// The source needs server packaging or conversion before playback
        /// (e.g. hardware AV1 in MKV, unsupported AV1 decode, Dolby Vision 5).
        /// The coordinator tries an eligible video-copy remux before conversion.
        var requiresServerTranscode: Bool = false
        /// tvOS prefers VLC for enhanced SDR subtitles, including when the
        /// container already needs VLC but an optional Atmos remux could win.
        var usesEnhancedSubtitleRenderer = false
    }

    // MARK: - Local Rendering Preference

    /// Local-file/direct-play selection. Also gates the optional SDR Atmos
    /// remux so it cannot replace an eligible enhanced subtitle renderer.
    static func evaluateForDirectPlayback(
        media: PlexMedia,
        part: PlexMediaPart,
        enhancementMode: VideoEnhancementMode,
        selectedSubtitleStreamID: Int?,
        forceAVPlayer: Bool = false,
        forceVLCKit: Bool = false
    ) -> Decision {
        let decision = evaluate(media: media, forceAVPlayer: forceAVPlayer, forceVLCKit: forceVLCKit)
        #if os(tvOS)
        guard !containsAV1(media), !forceAVPlayer, !forceVLCKit,
              !decision.requiresServerTranscode,
              let selectedSubtitleStreamID,
              part.streams.contains(where: {
                  $0.streamType == .subtitle && $0.id == selectedSubtitleStreamID && $0.key == nil
              }) else { return decision }
        let request = VideoEnhancementRequest.make(mode: enhancementMode, media: media, part: part)
        guard request.isPotentiallyEnabled, request.preflightUnavailabilityReason == nil else { return decision }

        // vmem is SDR-only. Require positive SDR evidence and reject *every*
        // HDR/DV hint, even when Plex omitted bitDepth or spelled PQ as ST2084.
        let videoStreams = part.streams.filter { $0.streamType == .video }
        let sdrTransfers: Set<String> = ["bt709", "smpte170m", "smpte240m", "gamma22", "gamma28", "iec61966-2-1"]
        guard !videoStreams.isEmpty, videoStreams.allSatisfy({ stream in
            !stream.isHDRVideo && hdrTransfer(of: stream) == nil &&
                stream.doviPresent != true && stream.doviProfile == nil &&
                stream.doviBLCompatID == nil && stream.doviLevel == nil &&
                (stream.bitDepth.map { (1...8).contains($0) } == true ||
                    sdrTransfers.contains(stream.colorTrc?.lowercased() ?? ""))
        }) else { return decision }
        return Decision(
            engine: .vlcKit,
            reason: "SDR video enhancement with selected embedded subtitles uses VLCKit",
            usesEnhancedSubtitleRenderer: true
        )
        #else
        return decision
        #endif
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
    ///   - forceAVPlayer: Engine override, subject to AV1 capability safety.
    ///   - forceVLCKit: Engine override, subject to AV1 capability safety.
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
        forceVLCKit: Bool = false,
        av1Capabilities: AV1PlaybackCapabilities = .current
    ) -> Decision {
        if let decision = av1Decision(for: media, capabilities: av1Capabilities) {
            return decision
        }
        if forceAVPlayer {
            return Decision(engine: .avPlayer, reason: "User preference forced AVPlayer")
        }
        if forceVLCKit {
            return Decision(engine: .vlcKit, reason: "User preference forced VLCKit")
        }

        // Dolby Vision profile 5 — a DV5 MKV must flag the server path too,
        // since libvlc cannot reshape IPTPQc2 color. The engine stays the
        // container's: if every server rung fails, the coordinator falls back
        // to direct play, and AVPlayer cannot even open an MKV.
        let decision = localEngineDecision(for: media)
        if isDolbyVisionProfile5(media) {
            return Decision(
                engine: decision.engine,
                reason: "Dolby Vision profile 5 requires a server remux or transcode (no local reshaping)",
                requiresServerTranscode: true
            )
        }
        return decision
    }

    private static func localEngineDecision(for media: PlexMedia) -> Decision {
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
        if isDolbyVisionProfile5(media) {
            return Decision(
                engine: .avPlayer,
                reason: "Dolby Vision profile 5 requires server transcode (no local reshaping)",
                requiresServerTranscode: true
            )
        }
        // A tune answer Dusk could not read leaves codec-less fallback media.
        // That says nothing about the stream: Plex delivers Live TV through
        // the universal transcoder in what Dusk's profile asks for (H.264 +
        // AAC/AC-3/E-AC-3 in MPEG-TS HLS), which AVPlayer plays. "Unknown"
        // video used to route it to VLCKit, whose HLS demuxer started late
        // and lost its clock on every source timestamp jump.
        let hasVideoMetadata = media.videoCodec?.nilIfEmpty != nil
            || media.parts.contains { $0.streams.contains { $0.streamType == .video } }
        guard hasVideoMetadata else {
            return Decision(engine: .avPlayer, reason: "Plex Live HLS without codec details plays through AVPlayer")
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

    /// Audio codecs Plex can copy into the fMP4 remux for AVPlayer. Anything
    /// else (TrueHD, DTS, …) has to be converted by Plex on the way.
    private static let remuxCopyableAudioCodecs: Set<String> = ["eac3", "ac3", "aac"]

    static func canCopyIntoRemux(audio stream: PlexStream) -> Bool {
        remuxCopyableAudioCodecs.contains(stream.codec?.lowercased() ?? "")
    }

    /// Whether a Dolby Vision profile 5 file should reach AVPlayer through a
    /// video-copy Plex remux. Apple's decoders render DV5 natively (it is
    /// what Infuse does from the same file) as long as the fMP4 sample entry
    /// says `dvh1` and carries a `dvcC` box — `RemuxHLSLoader` makes sure of
    /// that. Returns why not, or nil when it qualifies.
    ///
    /// The display gate mirrors the Atmos remux: Plex declares the variant
    /// `VIDEO-RANGE=PQ`, which AVFoundation refuses on an SDR display.
    static func dolbyVisionRemuxBlocker(
        media: PlexMedia,
        subtitleStream: PlexStream?,
        displaySupportsHDR: Bool
    ) -> String? {
        guard isDolbyVisionProfile5(media) else { return "not Dolby Vision profile 5" }
        guard media.parts.count == 1 else { return "multi-part media" }
        let videoCodecs = media.parts.flatMap(\.streams)
            .filter { $0.streamType == .video }
            .compactMap { $0.codec?.lowercased() }
        guard !videoCodecs.isEmpty, videoCodecs.allSatisfy({ $0 == "hevc" }) else {
            return "video codec is not HEVC"
        }
        guard displaySupportsHDR else { return "Dolby Vision on a display without HDR playback" }
        if let subtitleStream, !canRideRemux(subtitle: subtitleStream) {
            return "subtitle \(subtitleStream.codec?.uppercased() ?? "?") cannot ride the remux"
        }
        return nil
    }

    // MARK: - HDR Video Remux

    /// Whether an HDR file only VLCKit could direct play should reach AVPlayer
    /// through a video-copy Plex remux. VLCKit 3 renders into an untagged
    /// 8-bit surface on iOS/tvOS, so it never shows HDR at all; AVPlayer
    /// gives real HDR10, HLG, HDR10+ (the ST 2094-40 SEI rides the copied
    /// bitstream) and — with `DolbyVisionSignaling` — Dolby Vision 8.1/8.4.
    /// Returns why not, or nil when it qualifies.
    ///
    /// Audio must be copyable (E-AC-3/AC-3/AAC): converting DTS & co. to
    /// keep the picture would trade a lossless track for a lossy one, so
    /// those files keep VLCKit. DV7 + TrueHD is the exception, see
    /// `convertedTrueHDRemuxBlocker`.
    /// The display gate is the one the Atmos remux uses: Plex declares the
    /// variant HDR, which AVFoundation refuses on an SDR display.
    static func hdrVideoRemuxBlocker(
        media: PlexMedia,
        decision: Decision,
        audioStream: PlexStream?,
        subtitleStream: PlexStream?,
        displaySupportsHDR: Bool
    ) -> String? {
        guard decision.engine == .vlcKit, !decision.requiresServerTranscode else {
            return "not a VLCKit direct-play file"
        }
        guard media.parts.count == 1 else { return "multi-part media" }
        let videoStreams = media.parts.flatMap(\.streams).filter { $0.streamType == .video }
        guard !videoStreams.isEmpty, videoStreams.allSatisfy({ $0.codec?.lowercased() == "hevc" }) else {
            return "video codec is not HEVC"
        }
        guard videoStreams.contains(where: isRemuxableHDRVideo) else { return "video is not HDR" }
        guard displaySupportsHDR else { return "HDR video on a display without HDR playback" }
        if let audioStream, !canCopyIntoRemux(audio: audioStream) {
            return "audio \(audioStream.codec?.uppercased() ?? "?") would need conversion"
        }
        if let subtitleStream, !canRideRemux(subtitle: subtitleStream) {
            return "subtitle \(subtitleStream.codec?.uppercased() ?? "?") cannot ride the remux"
        }
        return nil
    }

    /// DV7 picture takes priority over local lossless TrueHD: start with a
    /// video-copy remux, Plex converting TrueHD/MLP to E-AC-3, and the on-device
    /// DV7 → 8.1 proxy. Other TrueHD files retain local decoding. This startup
    /// choice does not depend on VLCKit's TrueHD capability or spatial audio.
    /// Returns why not, or nil when the remux should be requested up front.
    static func convertedTrueHDRemuxBlocker(
        media: PlexMedia,
        decision: Decision,
        audioStream: PlexStream,
        subtitleStream: PlexStream?,
        displaySupportsHDR: Bool,
        hdrVideoRemuxEnabled: Bool
    ) -> String? {
        guard ["truehd", "mlp"].contains(audioStream.codec?.lowercased() ?? "") else {
            return "audio is not TrueHD/MLP"
        }
        guard dolbyVision7ConversionStream(in: media) != nil else {
            return "non-DV7 TrueHD uses local decoding"
        }
        guard hdrVideoRemuxEnabled else { return "HDR remux is off" }
        return hdrVideoRemuxBlocker(
            media: media,
            decision: decision,
            audioStream: nil,
            subtitleStream: subtitleStream,
            displaySupportsHDR: displaySupportsHDR
        )
    }

    /// HDR video AVPlayer can show from an HEVC remux: a PQ or HLG transfer,
    /// or a Dolby Vision profile whose base layer is HDR (7, 8.1, 8.4, 8.6).
    /// Profile 5 has its own path; 8.2 (SDR base) is not HDR.
    static func isRemuxableHDRVideo(_ stream: PlexStream) -> Bool {
        guard stream.streamType == .video, stream.doviProfile != 5 else { return false }
        switch hdrTransfer(of: stream) {
        case .pq?, .hlg?: return true
        case nil: return false
        }
    }

    enum HDRTransfer: Sendable {
        case pq
        case hlg
    }

    /// The stream's HDR transfer, from Plex's (ffprobe-spelled) `colorTrc`,
    /// falling back to the Dolby Vision base-layer compatibility ID when
    /// the TRC is missing. nil means SDR or unknown.
    static func hdrTransfer(of stream: PlexStream) -> HDRTransfer? {
        let trc = stream.colorTrc?.lowercased() ?? ""
        if trc.contains("2084") || trc.contains("pq") { return .pq }
        if trc.contains("hlg") || trc.contains("b67") { return .hlg }
        guard trc.isEmpty, stream.doviPresent == true || stream.doviProfile != nil else { return nil }
        switch (stream.doviProfile, stream.doviBLCompatID) {
        case (8?, 4?): return .hlg
        case (7?, _), (8?, 1?), (8?, 6?): return .pq
        default: return nil
        }
    }

    /// Whether the part's video is HDR or Dolby Vision in any form Plex reports,
    /// i.e. anything a move to VLCKit would flatten (or, for DV5, break).
    static func containsHDRVideo(inPart part: PlexMediaPart) -> Bool {
        part.streams.contains {
            $0.streamType == .video && ($0.isHDRVideo || hdrTransfer(of: $0) != nil ||
                $0.doviPresent == true || $0.doviProfile != nil ||
                $0.doviBLCompatID != nil || $0.doviLevel != nil)
        }
    }

    /// Short label for a remux reason / Playback Info, e.g. `Dolby Vision 8.1`,
    /// `HDR10`, `HLG`. HDR10+ is not in Plex's metadata, so it reads HDR10.
    static func hdrVideoLabel(for media: PlexMedia) -> String {
        guard let stream = media.parts.lazy.flatMap(\.streams).first(where: isRemuxableHDRVideo) else {
            return "HDR"
        }
        if let configuration = dolbyVisionSignalingStream(in: media, includesProfile8: true)
            .flatMap(DolbyVisionConfiguration.init(stream:)) {
            return configuration.displayName
        }
        if let profile = stream.doviProfile {
            return "Dolby Vision \(profile) (HDR10 base layer)"
        }
        return hdrTransfer(of: stream) == .hlg ? "HLG" : "HDR10"
    }

    /// The video stream whose Dolby Vision signaling a remux restores for
    /// AVPlayer: profile 5, or (with `includesProfile8`) 8.1/8.4. Profile 7
    /// is never signalled — Apple has no decoder for it, and its RPU is not
    /// valid as 8.1 without per-frame conversion — so it plays its HDR10
    /// base layer. 8.2/8.6 have no Apple-supported Dolby Vision form either.
    static func dolbyVisionSignalingStream(in media: PlexMedia, includesProfile8: Bool) -> PlexStream? {
        media.parts.lazy
            .flatMap(\.streams)
            .first { stream in
                guard stream.streamType == .video, stream.codec?.lowercased() != "av1" else { return false }
                switch (stream.doviProfile, stream.doviBLCompatID) {
                case (5?, _): return true
                case (8?, 1?), (8?, 4?): return includesProfile8
                default: return false
                }
            }
    }

    /// The Dolby Vision profile 7 HEVC video stream a remux can convert to
    /// profile 8.1 on device (`DolbyVision7HLSProxy`), if any.
    static func dolbyVision7ConversionStream(in media: PlexMedia) -> PlexStream? {
        media.parts.lazy
            .flatMap(\.streams)
            .first { stream in
                stream.streamType == .video
                    && stream.codec?.lowercased() == "hevc"
                    && stream.doviProfile == 7
            }
    }

    /// The 8.1 configuration a profile 7 file is converted to and signalled as.
    static func dolbyVision7ConversionTarget(in media: PlexMedia) -> DolbyVisionConfiguration? {
        dolbyVision7ConversionStream(in: media)
            .flatMap(DolbyVisionConfiguration.init(stream:))?
            .convertedToProfile81()
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
        AV1PlaybackCapabilities.current.hardwareDecode

    /// Dolby Vision profile 5 carries IPTPQc2 color with no HDR10-compatible
    /// base layer; libvlc cannot reshape it, so it must start on a server
    /// rung. Profiles 7/8 (and anything with a base-layer compatibility ID)
    /// render fine via their HDR10 base layer, so they stay on normal engine
    /// selection.
    static func isDolbyVisionProfile5(_ media: PlexMedia) -> Bool {
        dolbyVisionProfile5Stream(in: media) != nil
    }

    static func dolbyVisionProfile5Stream(in media: PlexMedia) -> PlexStream? {
        media.parts.lazy
            .flatMap(\.streams)
            .first { $0.streamType == .video && $0.doviProfile == 5 }
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
