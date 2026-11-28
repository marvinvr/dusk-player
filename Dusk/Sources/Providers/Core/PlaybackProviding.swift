import Foundation

/// Direct-play URLs, server streams, sidecars and pre-rolls for one server
/// (docs/jellyfin/04-architecture.md §12). The provider answers factual
/// questions (where is the file, give me a stream for this intent, what does
/// the server do with each track); which rung of the delivery ladder plays is
/// decided above it, by `StreamResolver` and the playback coordinator.
///
/// The verbs are main-actor isolated (they route through the service); the
/// facet value itself is not, so a provider can hand it out from anywhere.
protocol PlaybackProviding {
    /// What this server's HLS output needs from `RemuxHLSLoader` and the coordinator.
    var traits: PlaybackTraits { get }
    /// Where this server's credential may travel; the engines check every URL against it.
    var credentialPolicy: any CredentialTransportPolicy { get }

    /// The file as stored, for the engines to play directly. Nil when the
    /// server is not connected or no request can be built for it.
    @MainActor func directPlayURL(for part: MediaPart) -> URL?
    /// Whether `url` may be played from where the device is right now.
    @MainActor func checkAccess(to url: URL) async -> PlaybackAccess
    /// Starts a server stream. A stream the server declines comes back with
    /// its `outcome` saying so, not as an error; errors are transport failures.
    @MainActor func openServerStream(_ request: ServerStreamRequest) async throws -> ServerStream
    /// Post-start proof for a `.predicted` stream; nil when there is nothing
    /// to check (the stream was `.proven` when it opened).
    @MainActor func confirm(_ stream: ServerStream) async -> StreamDecisions?
    /// Tells the server a stream is still being watched. Best effort.
    @MainActor func keepAlive(streamSessionID: String) async
    /// Releases a stream's server-side resources. Best effort.
    @MainActor func close(streamSessionID: String) async
    /// Records the tracks the next stream of `partID` should start with, on
    /// servers that take the choice from a stored selection rather than from
    /// the stream request. A no-op where the request carries the tracks.
    @MainActor func prepareTrackSelection(_ selection: TrackSelection, partID: String) async throws
    /// The URL of an external (sidecar) subtitle; nil for embedded tracks.
    @MainActor func sidecarSubtitleURL(for stream: MediaStream) -> URL?
    /// The pre-roll videos the server wants played before `itemID`, in order.
    /// Empty is the normal answer.
    @MainActor func prerolls(before itemID: String) async throws -> [MediaDetails]
}

/// One server-stream request: which file and tracks, and what the stream is for.
struct ServerStreamRequest: Sendable {
    let itemID: String
    /// Position of the chosen version among the item's versions.
    let mediaIndex: Int
    let intent: StreamIntent
    /// The player session the stream belongs to.
    let playbackSessionID: String
    /// The stream's own session id, chosen by the caller so it can close a
    /// stream whose request is still in flight.
    let streamSessionID: String
    let audioStreamID: String?
    let subtitle: SubtitleRequest
}

/// What a server stream is for.
enum StreamIntent: Sendable, Hashable {
    /// Video and audio copied (Atmos, HDR, Dolby Vision, Dolby Vision 7 input).
    case losslessRemux
    /// Video copied, audio converted (TrueHD to E-AC-3 and the like).
    case convertedAudioRemux(target: AudioTarget)
    /// The automatic rung below direct play: the server copies what it can
    /// and only re-encodes what it must. No bitrate or resolution caps.
    case videoCopyFallback
    /// A manual quality choice; never an automatic default.
    case quality(PlaybackQualityPreset)
    /// Decoder-driven AV1 fallback: the video is converted, uncapped.
    case av1Fallback
    /// A receiver-compatible stream for an AirPlay route the user picked.
    case airPlay
    case live(LiveTuneContext)

    /// The remux intents, which deliver text subtitles inside the stream
    /// instead of burning them in.
    var isRemux: Bool {
        switch self {
        case .losslessRemux, .convertedAudioRemux: true
        case .videoCopyFallback, .quality, .av1Fallback, .airPlay, .live: false
        }
    }

    /// How a subtitle rides a stream of this intent.
    var subtitleDelivery: SubtitleDelivery {
        isRemux ? .inManifest : .burnIn
    }
}

/// The audio a converted-audio stream produces.
struct AudioTarget: Sendable, Hashable {
    let codec: String
    let channels: Int?

    /// E-AC-3 surround, up to 7.1: the conversion target of every remux that
    /// cannot copy its audio.
    static let surroundEAC3 = AudioTarget(codec: "eac3", channels: 8)
}

/// The channel a live stream plays.
struct LiveTuneContext: Sendable, Hashable {
    let channelID: String
}

enum SubtitleRequest: Sendable, Hashable {
    case none
    case stream(id: String, delivery: SubtitleDelivery)

    var streamID: String? {
        guard case let .stream(id, _) = self else { return nil }
        return id
    }
}

enum SubtitleDelivery: Sendable, Hashable {
    case inManifest
    case external
    case burnIn
}

/// Whether the server will deliver a requested stream.
enum ServerStreamOutcome: Sendable, Hashable {
    case transcodeAvailable
    case directPlayOnly
    case failed(String?)
}

/// A server stream, as the server answered it.
struct ServerStream: Sendable {
    /// `.proven`: the server said what it copies. `.predicted`: the request made
    /// anything else impossible, and `confirm` checks it after the first frame.
    enum Proof: Sendable, Hashable {
        case proven
        case predicted
    }

    /// The stream to play. Only meaningful when `outcome` is
    /// `.transcodeAvailable`; otherwise the server's base URL.
    let url: URL
    let sessionID: String
    let outcome: ServerStreamOutcome
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

/// What the server does with each track of a stream. The questions on it
/// (`isLosslessRemux`, …) are Dusk's acceptance rules for the ladder.
struct StreamDecisions: Sendable, Hashable {
    enum Track: Sendable, Hashable {
        /// Copied bit for bit.
        case copy
        /// Re-encoded.
        case convert
        /// Anything else the server answered.
        case other(String)
    }

    enum Subtitle: Sendable, Hashable {
        /// Delivered as text segments inside the stream.
        case textSegments
        /// Present in the source but left out of the stream.
        case ignored
        /// Anything else, burning in included.
        case other(String)
    }

    var container: String?
    var video: Track?
    var videoCodec: String?
    var audio: Track?
    var audioCodec: String?
    var audioChannels: Int? = nil
    var audioProfile: String? = nil
    /// Nil when the stream carries no subtitle decision.
    var subtitle: Subtitle? = nil

    /// Video and audio are both copied bit-for-bit, and any subtitle is
    /// delivered as its own text segments rather than burned in.
    var isLosslessRemux: Bool {
        audio == .copy && isVideoCopyRemux
    }

    /// The video is copied bit-for-bit and any subtitle is delivered as
    /// text segments or explicitly ignored; the audio may be converted.
    /// Plex can retain an ignored embedded subtitle in an Off decision.
    var isVideoCopyRemux: Bool {
        video == .copy
            && (audio == .copy || audio == .convert)
            && (subtitle == nil || subtitle == .ignored || subtitle == .textSegments)
    }

    /// Refuse incompatible audio/container decisions before AVPlayer is
    /// loaded. A multichannel source must remain surround, not stereo AAC.
    func isConvertedAudioRemux(sourceChannels: Int?) -> Bool {
        isVideoCopyRemux
            && container?.lowercased() == "mp4"
            && ["hevc", "h264", "av1"].contains(videoCodec?.lowercased() ?? "")
            && audio == .convert
            && audioCodec?.lowercased() == "eac3"
            && ((sourceChannels ?? 0) < 6 || audioChannels == 6 || audioChannels == 8)
    }

    /// Only output metadata can authorize restoring JOC after conversion.
    /// TrueHD Atmos on the input does not make a plain DD+ encode Atmos.
    var hasDolbyAtmosAudio: Bool {
        let profile = audioProfile?.lowercased() ?? ""
        return audioCodec?.lowercased() == "eac3"
            && (profile.contains("atmos") || profile.contains("joc"))
            && !profile.contains("truehd")
    }

    var logDescription: String {
        "container=\(container ?? "?") video=\(videoCodec ?? "?")/\(video.map(Self.label) ?? "?") audio=\(audioCodec ?? "?")/\(audio.map(Self.label) ?? "?") channels=\(audioChannels.map(String.init) ?? "?") profile=\(audioProfile ?? "?") subtitle=\(subtitle.map(Self.label) ?? "none")"
    }

    private static func label(_ track: Track) -> String {
        switch track {
        case .copy: "copy"
        case .convert: "transcode"
        case let .other(value): value
        }
    }

    private static func label(_ subtitle: Subtitle) -> String {
        switch subtitle {
        case .textSegments: "segments"
        case .ignored: "ignore"
        case let .other(value): value
        }
    }
}

/// Whether a direct-play URL may be used from where the device is.
enum PlaybackAccess: Sendable, Hashable {
    case allowed
    /// The server refuses remote direct play (Plex's remote-refusal probe).
    case refusedRemotely
}

/// The tracks a stream should start with. Ids are the server's stream ids;
/// `"0"` as the subtitle clears the server's stored subtitle choice.
struct TrackSelection: Sendable, Hashable {
    let audioStreamID: String?
    let subtitleStreamID: String?
}
