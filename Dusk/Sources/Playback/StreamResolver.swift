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
        if forceAVPlayer { return .avPlayer }
        if forceVLCKit { return .vlcKit }

        // Container check
        guard let container = media.container?.lowercased(),
              avContainers.contains(container) else {
            return .vlcKit
        }

        // Video codec check
        guard let videoCodec = media.videoCodec?.lowercased(),
              avVideoCodecs.contains(videoCodec) else {
            return .vlcKit
        }

        // Audio codec check
        guard let audioCodec = media.audioCodec?.lowercased(),
              avAudioCodecs.contains(audioCodec) else {
            return .vlcKit
        }

        // Subtitle check — every subtitle stream must be AVPlayer-compatible.
        // External text subs (srt, vtt) are fine. Embedded bitmap subs (PGS, VOBSUB)
        // and complex styled subs (ASS/SSA) require VLCKit.
        if let part = media.parts.first {
            let subtitleStreams = part.streams.filter { $0.streamType == .subtitle }
            for stream in subtitleStreams {
                guard let codec = stream.codec?.lowercased() else { continue }
                if !avSubtitleCodecs.contains(codec) {
                    return .vlcKit
                }
            }
        }

        return .avPlayer
    }
}
