import Foundation

struct PlaybackAttemptContext: Sendable {
    let attemptID: UUID
    let title: String
    let ratingKey: String
    let engine: PlaybackEngineType
    let resolverReason: String
    let mediaID: Int
    let partID: Int
    let sanitizedDirectPlayURL: String

    var attemptLabel: String {
        attemptID.uuidString
    }
}

struct PlaybackSource: Sendable {
    let url: URL
    let startPosition: TimeInterval?
    let context: PlaybackAttemptContext
}

struct PlaybackDebugInfo: Sendable {
    let title: String
    let engine: PlaybackEngineType
    let decision: PlaybackDecision
    let media: PlexMedia
    let part: PlexMediaPart
    let attemptID: UUID
    let resolverReason: String
    let sanitizedDirectPlayURL: String

    var engineLabel: String {
        switch engine {
        case .avPlayer: "AVPlayer"
        case .vlcKit: "VLCKit"
        }
    }

    var transcodeLabel: String {
        "No"
    }

    var directPlayLabel: String {
        switch decision {
        case .directPlay:
            "Yes"
        case .localDownload:
            "Local"
        }
    }

    var decisionLabel: String {
        switch decision {
        case .directPlay: "Direct Play"
        case .localDownload: "Local Download"
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
        sanitizedDirectPlayURL
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
