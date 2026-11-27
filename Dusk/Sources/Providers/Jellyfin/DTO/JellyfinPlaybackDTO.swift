import Foundation

// Playback decision, reporting and the DeviceProfile wire shape.
// docs/jellyfin/02-jellyfin-api-mapping.md §8, §10; 03-prior-art.md §5.
// Which profile to send is the DeviceProfile builder's job; these are only
// the JSON shapes.

/// `POST /Items/{id}/PlaybackInfo` body.
///
/// Always send `mediaSourceID`, `audioStreamIndex` and `subtitleStreamIndex`
/// (`-1` = off): indexes are ignored without a media source id, an open audio
/// index lets the server swap the track, an open subtitle index can burn in a
/// PGS track (03 §5.1 items 3 – 4).
struct JellyfinPlaybackInfoRequestDTO: Encodable, Sendable {
    var userID: String?
    var deviceProfile: JellyfinDeviceProfileDTO?
    var mediaSourceID: String?
    var audioStreamIndex: Int?
    var subtitleStreamIndex: Int?
    /// Bits per second.
    var maxStreamingBitrate: Int?
    var startTimeTicks: JellyfinTicks?
    var enableDirectPlay: Bool?
    var enableDirectStream: Bool?
    var enableTranscoding: Bool?
    var allowVideoStreamCopy: Bool?
    var allowAudioStreamCopy: Bool?
    var autoOpenLiveStream: Bool?
    var liveStreamID: String?

    init(
        mediaSourceID: String?,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?,
        deviceProfile: JellyfinDeviceProfileDTO?
    ) {
        self.mediaSourceID = mediaSourceID
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
        self.deviceProfile = deviceProfile
    }

    enum CodingKeys: String, CodingKey {
        case userID = "UserId"
        case deviceProfile = "DeviceProfile"
        case mediaSourceID = "MediaSourceId"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case startTimeTicks = "StartTimeTicks"
        case enableDirectPlay = "EnableDirectPlay"
        case enableDirectStream = "EnableDirectStream"
        case enableTranscoding = "EnableTranscoding"
        case allowVideoStreamCopy = "AllowVideoStreamCopy"
        case allowAudioStreamCopy = "AllowAudioStreamCopy"
        case autoOpenLiveStream = "AutoOpenLiveStream"
        case liveStreamID = "LiveStreamId"
    }
}

/// `PlaybackInfoResponse`. All three `Supports*` false with no `errorCode`
/// means "unplayable this way" (03 §5.1 item 5).
struct JellyfinPlaybackInfoResponseDTO: Decodable, Sendable {
    let mediaSources: [JellyfinMediaSourceDTO]
    let playSessionID: String?
    /// `NotAllowed`, `NoCompatibleStream`, `RateLimitExceeded`.
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionID = "PlaySessionId"
        case errorCode = "ErrorCode"
    }
}

// MARK: - DeviceProfile

struct JellyfinDeviceProfileDTO: Codable, Hashable, Sendable {
    var name: String?
    var maxStreamingBitrate: Int?
    var maxStaticBitrate: Int?
    var directPlayProfiles: [JellyfinDirectPlayProfileDTO] = []
    var transcodingProfiles: [JellyfinTranscodingProfileDTO] = []
    var codecProfiles: [JellyfinCodecProfileDTO] = []
    var containerProfiles: [JellyfinContainerProfileDTO] = []
    var subtitleProfiles: [JellyfinSubtitleProfileDTO] = []

    init(
        name: String? = nil,
        directPlayProfiles: [JellyfinDirectPlayProfileDTO] = [],
        transcodingProfiles: [JellyfinTranscodingProfileDTO] = [],
        codecProfiles: [JellyfinCodecProfileDTO] = [],
        subtitleProfiles: [JellyfinSubtitleProfileDTO] = []
    ) {
        self.name = name
        self.directPlayProfiles = directPlayProfiles
        self.transcodingProfiles = transcodingProfiles
        self.codecProfiles = codecProfiles
        self.subtitleProfiles = subtitleProfiles
    }

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case maxStaticBitrate = "MaxStaticBitrate"
        case directPlayProfiles = "DirectPlayProfiles"
        case transcodingProfiles = "TranscodingProfiles"
        case codecProfiles = "CodecProfiles"
        case containerProfiles = "ContainerProfiles"
        case subtitleProfiles = "SubtitleProfiles"
    }
}

/// No `container` matches every container (03 §5.1 profile A).
struct JellyfinDirectPlayProfileDTO: Codable, Hashable, Sendable {
    var type: String
    var container: String?
    var videoCodec: String?
    var audioCodec: String?

    init(type: String = "Video", container: String? = nil, videoCodec: String? = nil, audioCodec: String? = nil) {
        self.type = type
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
    }

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case container = "Container"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
    }
}

/// The audio transcode target follows the order of `audioCodec`
/// (03 §5.1 item 6).
struct JellyfinTranscodingProfileDTO: Codable, Hashable, Sendable {
    var type: String = "Video"
    var `protocol`: String?
    var container: String?
    var videoCodec: String?
    var audioCodec: String?
    var context: String?
    var maxAudioChannels: String?
    var minSegments: Int?
    var segmentLength: Int?
    var breakOnNonKeyFrames: Bool?
    var copyTimestamps: Bool?
    var enableSubtitlesInManifest: Bool?
    var conditions: [JellyfinProfileConditionDTO]?

    init(
        protocol: String?, container: String?, videoCodec: String?, audioCodec: String?,
        context: String? = "Streaming", maxAudioChannels: String? = nil, minSegments: Int? = nil,
        breakOnNonKeyFrames: Bool? = nil, enableSubtitlesInManifest: Bool? = nil
    ) {
        self.protocol = `protocol`
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.context = context
        self.maxAudioChannels = maxAudioChannels
        self.minSegments = minSegments
        self.breakOnNonKeyFrames = breakOnNonKeyFrames
        self.enableSubtitlesInManifest = enableSubtitlesInManifest
    }

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case `protocol` = "Protocol"
        case container = "Container"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
        case context = "Context"
        case maxAudioChannels = "MaxAudioChannels"
        case minSegments = "MinSegments"
        case segmentLength = "SegmentLength"
        case breakOnNonKeyFrames = "BreakOnNonKeyFrames"
        case copyTimestamps = "CopyTimestamps"
        case enableSubtitlesInManifest = "EnableSubtitlesInManifest"
        case conditions = "Conditions"
    }
}

struct JellyfinCodecProfileDTO: Codable, Hashable, Sendable {
    var type: String
    var codec: String?
    var container: String?
    var conditions: [JellyfinProfileConditionDTO]
    var applyConditions: [JellyfinProfileConditionDTO]?

    init(type: String = "Video", codec: String?, container: String? = nil,
         conditions: [JellyfinProfileConditionDTO], applyConditions: [JellyfinProfileConditionDTO]? = nil) {
        self.type = type
        self.codec = codec
        self.container = container
        self.conditions = conditions
        self.applyConditions = applyConditions
    }

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case codec = "Codec"
        case container = "Container"
        case conditions = "Conditions"
        case applyConditions = "ApplyConditions"
    }
}

struct JellyfinContainerProfileDTO: Codable, Hashable, Sendable {
    var type: String
    var container: String?
    var conditions: [JellyfinProfileConditionDTO]

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case container = "Container"
        case conditions = "Conditions"
    }
}

/// `{"Condition": "EqualsAny", "Property": "VideoRangeType", "Value": "SDR|HDR10", "IsRequired": false}`.
struct JellyfinProfileConditionDTO: Codable, Hashable, Sendable {
    var condition: String
    var property: String
    var value: String
    var isRequired: Bool

    init(condition: String, property: String, value: String, isRequired: Bool = false) {
        self.condition = condition
        self.property = property
        self.value = value
        self.isRequired = isRequired
    }

    enum CodingKeys: String, CodingKey {
        case condition = "Condition"
        case property = "Property"
        case value = "Value"
        case isRequired = "IsRequired"
    }
}

struct JellyfinSubtitleProfileDTO: Codable, Hashable, Sendable {
    var format: String
    var method: JellyfinSubtitleDeliveryMethod

    enum CodingKeys: String, CodingKey {
        case format = "Format"
        case method = "Method"
    }
}

// MARK: - Reporting

/// Body of `POST /Sessions/Playing`, `/Sessions/Playing/Progress` and
/// `/Sessions/Playing/Stopped` (all `204`). Only set fields are sent.
/// Do not add a client-side 90 % scrobble: the server marks played on Stopped
/// at its own threshold (02 §8).
struct JellyfinPlaybackReportDTO: Encodable, Sendable {
    var itemID: String
    var mediaSourceID: String?
    var playSessionID: String?
    var playMethod: JellyfinPlayMethod?
    var positionTicks: JellyfinTicks?
    var canSeek: Bool?
    var isPaused: Bool?
    var isMuted: Bool?
    var volumeLevel: Int?
    var audioStreamIndex: Int?
    var subtitleStreamIndex: Int?
    var liveStreamID: String?
    /// Progress only: `TimeUpdate`, `Pause`, `Unpause`, …
    var eventName: String?
    var repeatMode: String?
    var playbackOrder: String?
    /// Stopped only.
    var failed: Bool?

    init(itemID: String) {
        self.itemID = itemID
    }

    enum CodingKeys: String, CodingKey {
        case itemID = "ItemId"
        case mediaSourceID = "MediaSourceId"
        case playSessionID = "PlaySessionId"
        case playMethod = "PlayMethod"
        case positionTicks = "PositionTicks"
        case canSeek = "CanSeek"
        case isPaused = "IsPaused"
        case isMuted = "IsMuted"
        case volumeLevel = "VolumeLevel"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
        case liveStreamID = "LiveStreamId"
        case eventName = "EventName"
        case repeatMode = "RepeatMode"
        case playbackOrder = "PlaybackOrder"
        case failed = "Failed"
    }
}
