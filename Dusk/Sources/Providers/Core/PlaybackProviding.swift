import Foundation

/// Direct-play URLs, server streams, sidecars and pre-rolls
/// (docs/jellyfin/04-architecture.md §12). Empty until P0-09, which also
/// settles the request types below; nothing uses them yet.
protocol PlaybackProviding: Sendable {}

/// One server-stream request: which file and tracks, and what the stream is for.
struct ServerStreamRequest: Sendable {
    let item: MediaItemID
    let version: MediaVersion
    let part: MediaPart
    let intent: StreamIntent
    let audioStreamID: String?
    let subtitle: SubtitleRequest
    let startOffsetMs: Int?
    let device: DeviceVideoCapabilities
}

/// What a server stream is for. The neutral form of `TranscodeDeliveryMode`.
enum StreamIntent: Sendable {
    /// Video and audio copied (Atmos, HDR, Dolby Vision, Dolby Vision 7 input).
    case losslessRemux
    /// Video copied, audio converted (TrueHD to E-AC-3 and the like).
    case convertedAudioRemux(target: AudioTarget)
    /// Today's direct-stream fallback after a failed direct play.
    case videoCopyFallback
    /// A manual quality choice; never an automatic default.
    case quality(PlaybackQualityPreset)
    case av1Fallback
    case airPlay
    case live(LiveTuneContext)
}

/// The audio a converted-audio stream produces.
struct AudioTarget: Sendable, Hashable {
    let codec: String
    let channels: Int?
}

/// The channel a live stream plays.
struct LiveTuneContext: Sendable, Hashable {
    let channelID: String
}

/// What this playback attempt may show.
struct DeviceVideoCapabilities: Sendable, Hashable {
    let supportsHDR: Bool
    let dolbyVisionProfiles: Set<Int>
    let decodesAV1: Bool
    let maxAudioChannels: Int
}

enum SubtitleRequest: Sendable, Hashable {
    case none
    case stream(id: String, delivery: SubtitleDelivery)
}

enum SubtitleDelivery: Sendable, Hashable {
    case inManifest
    case external
    case burnIn
}

/// How a sidecar subtitle is fetched: as stored (VLCKit) or as WebVTT for
/// Dusk's own overlay.
enum SubtitleFormat: Sendable, Hashable {
    case original
    case webVTT
}

/// A started server stream.
struct ServerStream: Sendable {
    /// `.proven`: the server said what it copies. `.predicted`: the request made
    /// anything else impossible, and `confirm` checks it after the first frame.
    enum Proof: Sendable, Hashable {
        case proven
        case predicted
    }

    let url: URL
    let sessionID: String
    let playMethod: PlayMethod
    let decisions: StreamDecisions
    let proof: Proof
    let credentialPolicy: any CredentialTransportPolicy
}

enum PlayMethod: Sendable, Hashable {
    case directPlay
    case directStream
    case transcode
}

/// What the server does with each track of a stream.
struct StreamDecisions: Sendable, Hashable {
    enum Video: Sendable, Hashable {
        case copy
        case transcode
    }

    enum Audio: Sendable, Hashable {
        case copy
        case convert(codec: String, channels: Int?)
    }

    let video: Video
    let audio: Audio
    let subtitle: SubtitleDelivery?
    let container: String?
}

/// Whether a direct-play URL may be used from where the device is.
enum PlaybackAccess: Sendable, Hashable {
    case allowed
    /// The server refuses remote direct play (Plex's remote-refusal probe).
    case refusedRemotely
}

/// The tracks a stream should start with.
struct TrackSelection: Sendable, Hashable {
    let audioStreamID: String?
    let subtitleStreamID: String?
}

/// What to put back after a stream that needed the server's track choice changed.
struct TrackSelectionRestore: Sendable, Hashable {
    let item: MediaItemID
    let previous: TrackSelection
}
