import Foundation

struct PlaybackAttemptContext: Sendable {
    let attemptID: UUID
    let title: String
    let ratingKey: String
    let engine: PlaybackEngineType
    let resolverReason: String
    let mediaID: Int
    let partID: Int
    let sanitizedPlaybackURL: String

    var attemptLabel: String {
        attemptID.uuidString
    }
}

/// The little we know about an item at the instant the user presses Play,
/// used to fill the loading screen before `getMediaDetails` returns. Carries
/// relative Plex art paths rather than resolved URLs so the loading view can
/// size them itself via `PlexService.imageURL(for:width:height:)`.
struct PlaybackPlaceholder: Sendable {
    let title: String
    let subtitle: String?
    let posterPath: String?
    let backdropPath: String?
}

extension PlaybackPlaceholder {
    init(item: PlexItem) {
        self.init(
            title: item.continueWatchingDisplayTitle,
            subtitle: item.standardPosterSubtitle,
            posterPath: item.preferredPosterPath,
            backdropPath: item.preferredLandscapePath
        )
    }

    init(episode: PlexEpisode) {
        self.init(
            title: episode.grandparentTitle ?? episode.title,
            subtitle: MediaTextFormatter.seasonEpisodeLabel(
                season: episode.parentIndex,
                episode: episode.index
            ) ?? episode.title,
            posterPath: episode.grandparentThumb ?? episode.thumb ?? episode.art,
            backdropPath: episode.thumb ?? episode.art ?? episode.grandparentThumb
        )
    }

    init(details: PlexMediaDetails) {
        switch details.type {
        case .episode:
            self.init(
                title: details.grandparentTitle ?? details.title,
                subtitle: MediaTextFormatter.seasonEpisodeLabel(
                    season: details.parentIndex,
                    episode: details.index
                ) ?? details.title,
                posterPath: details.grandparentThumb ?? details.parentThumb ?? details.thumb ?? details.art,
                backdropPath: details.art ?? details.thumb ?? details.grandparentThumb
            )
        default:
            self.init(
                title: details.title,
                subtitle: details.year.map(String.init),
                posterPath: details.thumb ?? details.art,
                backdropPath: details.art ?? details.thumb
            )
        }
    }
}

struct PlaybackSource: Sendable {
    let url: URL
    let startPosition: TimeInterval?
    let context: PlaybackAttemptContext
    /// Position of the automatically preferred audio stream among the part's
    /// audio streams (libvlc `:audio-track` semantics), computed from Plex
    /// metadata BEFORE playback starts. VLCKit passes it as a media option so
    /// the audio output opens directly on the winning track. Switching tracks
    /// after start restarts libvlc's audio output for the format change, and
    /// a restart landing in the startup window can leave playback silent
    /// until a manual pause/resume — pre-selecting removes the switch
    /// entirely. `nil` leaves the container/libvlc default untouched.
    var preferredAudioTrackPosition: Int? = nil
}

struct PlaybackDebugInfo: Sendable {
    let title: String
    let engine: PlaybackEngineType
    let decision: PlaybackDecision
    let media: PlexMedia
    let part: PlexMediaPart
    let attemptID: UUID
    let resolverReason: String
    let sanitizedPlaybackURL: String

    var engineLabel: String {
        switch engine {
        case .avPlayer: "AVPlayer"
        case .vlcKit: "VLCKit"
        }
    }

    var transcodeLabel: String {
        switch decision {
        case .directPlay, .localDownload:
            "No"
        case let .transcode(preset):
            preset.displayName
        case .serverStream:
            "Direct Stream (HLS)"
        }
    }

    var directPlayLabel: String {
        switch decision {
        case .directPlay:
            "Yes"
        case .localDownload:
            "Local"
        case .transcode, .serverStream:
            "No"
        }
    }

    var decisionLabel: String {
        switch decision {
        case .directPlay: "Direct Play"
        case .localDownload: "Local Download"
        case let .transcode(preset): "Transcode \(preset.displayName)"
        case .serverStream: "Server Stream (HLS)"
        }
    }

    var qualityPreset: PlaybackQualityPreset {
        switch decision {
        case .directPlay, .localDownload:
            .original
        case let .transcode(preset):
            preset
        case .serverStream:
            // The server copies the original video track when it can, so the
            // effective quality is the original's; no preset cap applies.
            .original
        }
    }

    var availableQualityPresets: [PlaybackQualityPreset] {
        PlaybackQualityPreset.displayOrder(forOriginalMedia: media)
    }

    var canSelectPlaybackQuality: Bool {
        switch decision {
        case .localDownload:
            false
        case .directPlay, .transcode, .serverStream:
            true
        }
    }

    var canLoadScrubPreviews: Bool {
        switch decision {
        case .localDownload:
            false
        case .directPlay, .transcode, .serverStream:
            true
        }
    }

    var containerLabel: String {
        (part.container ?? media.container ?? "Unknown").uppercased()
    }

    var resolutionLabel: String {
        if let width = media.width, let height = media.height {
            return "\(width)x\(height)"
        }
        if let height = media.height {
            return "\(height)p"
        }
        if let resolution = media.videoResolution {
            return resolution.uppercased()
        }
        return "Unknown"
    }

    var bitrateLabel: String {
        if let bitrate = media.bitrate {
            return Self.formatBitrateKbps(bitrate)
        }
        if let bitrate = selectedVideoStream?.bitrate {
            return Self.formatBitrateKbps(bitrate)
        }
        return "Unknown"
    }

    var videoLabel: String {
        let codec = media.videoCodec?.uppercased() ?? selectedVideoStream?.codec?.uppercased() ?? "Unknown"
        if let profile = media.videoProfile?.uppercased() {
            return "\(codec) (\(profile))"
        }
        return codec
    }

    var audioLabel: String {
        let codec = media.audioCodec?.uppercased() ?? selectedAudioStream?.codec?.uppercased() ?? "Unknown"
        let channels = media.audioChannels ?? selectedAudioStream?.channels
        if let channels {
            return "\(codec) \(channels)ch"
        }
        return codec
    }

    var fileSizeLabel: String {
        guard let size = part.size else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var subtitleLabel: String {
        guard let subtitle = selectedSubtitleStream else { return "None" }
        return subtitle.extendedDisplayTitle ?? subtitle.displayTitle ?? subtitle.codec?.uppercased() ?? "Selected"
    }

    var attemptLabel: String {
        attemptID.uuidString
    }

    var resolverLabel: String {
        resolverReason
    }

    var urlLabel: String {
        sanitizedPlaybackURL
    }

    private var selectedVideoStream: PlexStream? {
        part.streams.first { $0.streamType == .video }
    }

    private var selectedAudioStream: PlexStream? {
        part.streams.first { $0.streamType == .audio && ($0.isSelected ?? false) }
            ?? part.streams.first { $0.streamType == .audio }
    }

    private var selectedSubtitleStream: PlexStream? {
        part.streams.first { $0.streamType == .subtitle && ($0.isSelected ?? false) }
    }

    private static func formatBitrateKbps(_ value: Int) -> String {
        if value >= 1_000 {
            return String(format: "%.1f Mbps", Double(value) / 1_000.0)
        }
        return "\(value) kbps"
    }
}

enum PlaybackDecision: Sendable {
    case directPlay
    case localDownload
    case transcode(PlaybackQualityPreset)
    /// Delivery-ladder rung below direct play: the server packages the item as
    /// HLS with direct-stream enabled (video/audio copied when possible, only
    /// re-encoded when it must be). No quality preset applies — the video
    /// quality stays the original's.
    case serverStream
}

enum PlaybackQualityPreset: String, CaseIterable, Identifiable, Sendable {
    case original
    case p1080_20Mbps
    case p1080_12Mbps
    case p1080_10Mbps
    case p1080_8Mbps
    case p720_4Mbps
    case p720_3Mbps
    case p720_2Mbps
    case p480_1_5Mbps
    case p320_720Kbps
    case p240_320Kbps

    var id: String { rawValue }

    var isOriginal: Bool {
        self == .original
    }

    var displayName: String {
        switch self {
        case .original: "Original"
        case .p1080_20Mbps: "1080p • 20 Mbps"
        case .p1080_12Mbps: "1080p • 12 Mbps"
        case .p1080_10Mbps: "1080p • 10 Mbps"
        case .p1080_8Mbps: "1080p • 8 Mbps"
        case .p720_4Mbps: "720p • 4 Mbps"
        case .p720_3Mbps: "720p • 3 Mbps"
        case .p720_2Mbps: "720p • 2 Mbps"
        case .p480_1_5Mbps: "480p • 1.5 Mbps"
        case .p320_720Kbps: "320p • 720 kbps"
        case .p240_320Kbps: "240p • 320 kbps"
        }
    }

    var detailTitle: String? {
        switch self {
        case .original:
            "Direct Play"
        default:
            "Transcoded"
        }
    }

    var videoHeight: Int? {
        switch self {
        case .original: nil
        case .p1080_20Mbps, .p1080_12Mbps, .p1080_10Mbps, .p1080_8Mbps:
            1080
        case .p720_4Mbps, .p720_3Mbps, .p720_2Mbps:
            720
        case .p480_1_5Mbps:
            480
        case .p320_720Kbps:
            320
        case .p240_320Kbps:
            240
        }
    }

    var videoBitrateKbps: Int? {
        switch self {
        case .original: nil
        case .p1080_20Mbps: 20_000
        case .p1080_12Mbps: 12_000
        case .p1080_10Mbps: 10_000
        case .p1080_8Mbps: 8_000
        case .p720_4Mbps: 4_000
        case .p720_3Mbps: 3_000
        case .p720_2Mbps: 2_000
        case .p480_1_5Mbps: 1_500
        case .p320_720Kbps: 720
        case .p240_320Kbps: 320
        }
    }

    var videoResolution: String? {
        switch self {
        case .original: nil
        case .p1080_20Mbps, .p1080_12Mbps, .p1080_10Mbps, .p1080_8Mbps:
            "1920x1080"
        case .p720_4Mbps, .p720_3Mbps, .p720_2Mbps:
            "1280x720"
        case .p480_1_5Mbps:
            "720x480"
        case .p320_720Kbps:
            "576x320"
        case .p240_320Kbps:
            "420x240"
        }
    }

    var videoQuality: Int? {
        switch self {
        case .original: nil
        case .p1080_20Mbps: 100
        case .p1080_12Mbps: 90
        case .p1080_10Mbps: 75
        case .p1080_8Mbps: 60
        case .p720_4Mbps: 100
        case .p720_3Mbps: 75
        case .p720_2Mbps: 60
        case .p480_1_5Mbps: 60
        case .p320_720Kbps: 40
        case .p240_320Kbps: 30
        }
    }

    static let displayOrder: [PlaybackQualityPreset] = [
        .original,
        .p1080_20Mbps,
        .p1080_12Mbps,
        .p1080_10Mbps,
        .p1080_8Mbps,
        .p720_4Mbps,
        .p720_3Mbps,
        .p720_2Mbps,
        .p480_1_5Mbps,
        .p320_720Kbps,
        .p240_320Kbps,
    ]

    static func displayOrder(forOriginalMedia media: PlexMedia) -> [PlaybackQualityPreset] {
        let videoStreams = media.parts.flatMap { $0.streams }.filter { $0.streamType == .video }
        let originalHeight = media.height
            ?? videoStreams.compactMap(\.height).first
            ?? height(fromVideoResolution: media.videoResolution)
        let originalBitrate = media.bitrate ?? videoStreams.compactMap(\.bitrate).first

        return displayOrder.filter { preset in
            preset.isOriginal || preset.isBelowOriginal(height: originalHeight, bitrate: originalBitrate)
        }
    }

    private func isBelowOriginal(height originalHeight: Int?, bitrate originalBitrate: Int?) -> Bool {
        guard let presetHeight = videoHeight else { return true }

        if let originalHeight {
            if presetHeight < originalHeight {
                return true
            }

            if presetHeight > originalHeight {
                return false
            }

            guard let presetBitrate = videoBitrateKbps,
                  let originalBitrate else {
                return false
            }

            return presetBitrate < originalBitrate
        }

        guard let presetBitrate = videoBitrateKbps,
              let originalBitrate else {
            return true
        }

        return presetBitrate < originalBitrate
    }

    private static func height(fromVideoResolution videoResolution: String?) -> Int? {
        guard let videoResolution else { return nil }

        let normalized = videoResolution.lowercased()
        if normalized.contains("4k") || normalized.contains("uhd") {
            return 2160
        }

        if normalized.contains("1080") { return 1080 }
        if normalized.contains("720") { return 720 }
        if normalized.contains("576") { return 576 }
        if normalized.contains("480") || normalized.contains("sd") { return 480 }
        if normalized.contains("320") { return 320 }
        if normalized.contains("240") { return 240 }

        return nil
    }
}

struct UpNextPresentation: Sendable {
    enum Source: Sendable {
        case playbackEnded
        case creditsSkipped
    }

    let episode: PlexEpisode
    let source: Source
    var shouldAutoplay: Bool
    let countdownDuration: Int
    var countdownStartedAt: Date?
    var secondsRemaining: Int?
    var autoplayProgress: Double?
    let autoplayBlockedByPassoutProtection: Bool
    let passoutProtectionEpisodeLimit: Int?
    var isStarting = false
    var errorMessage: String?
}
