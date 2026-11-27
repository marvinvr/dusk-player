import Foundation

// `MediaSourceInfo`, `MediaStream`, `MediaAttachment`.
// docs/jellyfin/02-jellyfin-api-mapping.md §9 – §10.
//
// Raw server values on purpose: codec names (`PGSSUB`, `subrip`), containers
// (`mov` for `.mp4`) and stream `Index` are normalised by the mapper, never
// handed to `StreamResolver` as they are.

/// One version of an item (`MediaSources[]` replaces Plex `Media[]` +
/// `Part[]`). `id` equals the item id for the primary version.
struct JellyfinMediaSourceDTO: Decodable, Sendable {
    let id: String
    let name: String?
    let path: String?
    let type: String?
    let `protocol`: JellyfinMediaProtocol?
    let container: String?
    /// Bytes.
    let size: Int64?
    /// Bits per second (Plex is kbit/s).
    let bitrate: Int?
    let runTimeTicks: JellyfinTicks?
    let videoType: String?
    let isRemote: Bool?
    let isInfiniteStream: Bool?
    let hasSegments: Bool?
    let etag: String?
    let mediaStreams: [JellyfinMediaStreamDTO]?
    let mediaAttachments: [JellyfinMediaAttachmentDTO]?
    /// Already resolved for the user (language prefs + remembered selection),
    /// so it is a tie-break, not the one default (02 §9).
    let defaultAudioStreamIndex: Int?
    let defaultSubtitleStreamIndex: Int?
    let requiredHTTPHeaders: [String: String]?

    // PlaybackInfo answers only.
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let supportsTranscoding: Bool?
    /// Relative, token embedded (`ApiKey=`), never log unredacted.
    let transcodingURL: String?
    let transcodingSubProtocol: String?
    let transcodingContainer: String?
    /// Not populated on 12.4; build `/Videos/{id}/stream?static=true` instead.
    let directStreamURL: String?
    let liveStreamID: String?
    let requiresOpening: Bool?
    let requiresClosing: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case path = "Path"
        case type = "Type"
        case `protocol` = "Protocol"
        case container = "Container"
        case size = "Size"
        case bitrate = "Bitrate"
        case runTimeTicks = "RunTimeTicks"
        case videoType = "VideoType"
        case isRemote = "IsRemote"
        case isInfiniteStream = "IsInfiniteStream"
        case hasSegments = "HasSegments"
        case etag = "ETag"
        case mediaStreams = "MediaStreams"
        case mediaAttachments = "MediaAttachments"
        case defaultAudioStreamIndex = "DefaultAudioStreamIndex"
        case defaultSubtitleStreamIndex = "DefaultSubtitleStreamIndex"
        case requiredHTTPHeaders = "RequiredHttpHeaders"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case transcodingURL = "TranscodingUrl"
        case transcodingSubProtocol = "TranscodingSubProtocol"
        case transcodingContainer = "TranscodingContainer"
        case directStreamURL = "DirectStreamUrl"
        case liveStreamID = "LiveStreamId"
        case requiresOpening = "RequiresOpening"
        case requiresClosing = "RequiresClosing"
    }

    var streams: [JellyfinMediaStreamDTO] { mediaStreams ?? [] }

    /// `TranscodeReasons=` inside `transcodingURL`. A hint only: the server
    /// still stream-copies with `VideoRangeTypeNotSupported` (03 §5.1 item 8).
    var transcodeReasons: [JellyfinTranscodeReason] {
        guard let transcodingURL,
              let items = URLComponents(string: transcodingURL)?.queryItems else { return [] }
        let value = items.first { $0.name.caseInsensitiveCompare("TranscodeReasons") == .orderedSame }?.value
        return JellyfinTranscodeReason.list(value)
    }
}

/// One stream of a media source.
///
/// `index` is the position inside the media source and what the server's
/// `AudioStreamIndex` / `SubtitleStreamIndex` mean. An external subtitle takes
/// index 0 and shifts every embedded stream (02 §9), so it is not the
/// container's track number and not VLCKit's track id.
struct JellyfinMediaStreamDTO: Decodable, Hashable, Sendable {
    let index: Int
    let type: JellyfinStreamType
    let codec: String?
    let codecTag: String?
    let language: String?
    let title: String?
    let displayTitle: String?
    let profile: String?
    let level: Double?
    let isDefault: Bool?
    let isForced: Bool?
    let isHearingImpaired: Bool?
    let isExternal: Bool?
    let isTextSubtitleStream: Bool?
    let supportsExternalStream: Bool?
    let path: String?

    // Video
    let width: Int?
    let height: Int?
    let bitRate: Int?
    let bitDepth: Int?
    let realFrameRate: Double?
    let averageFrameRate: Double?
    let refFrames: Int?
    let isInterlaced: Bool?
    let pixelFormat: String?
    let aspectRatio: String?
    let videoRange: JellyfinVideoRange?
    let videoRangeType: JellyfinVideoRangeType?
    let videoDoViTitle: String?
    let colorTransfer: String?
    let colorPrimaries: String?
    let colorSpace: String?
    let dvProfile: Int?
    let dvLevel: Int?
    let dvVersionMajor: Int?
    let dvVersionMinor: Int?
    let dvBlSignalCompatibilityID: Int?
    let rpuPresentFlag: Int?
    let elPresentFlag: Int?
    let blPresentFlag: Int?
    let hdr10PlusPresentFlag: Bool?

    // Audio
    let channels: Int?
    let channelLayout: String?
    let sampleRate: Int?
    let audioSpatialFormat: JellyfinAudioSpatialFormat?

    // Subtitle delivery (PlaybackInfo answers)
    let deliveryMethod: JellyfinSubtitleDeliveryMethod?
    /// Relative, may carry `ApiKey=`.
    let deliveryURL: String?
    let isExternalURL: Bool?

    enum CodingKeys: String, CodingKey {
        case index = "Index"
        case type = "Type"
        case codec = "Codec"
        case codecTag = "CodecTag"
        case language = "Language"
        case title = "Title"
        case displayTitle = "DisplayTitle"
        case profile = "Profile"
        case level = "Level"
        case isDefault = "IsDefault"
        case isForced = "IsForced"
        case isHearingImpaired = "IsHearingImpaired"
        case isExternal = "IsExternal"
        case isTextSubtitleStream = "IsTextSubtitleStream"
        case supportsExternalStream = "SupportsExternalStream"
        case path = "Path"
        case width = "Width"
        case height = "Height"
        case bitRate = "BitRate"
        case bitDepth = "BitDepth"
        case realFrameRate = "RealFrameRate"
        case averageFrameRate = "AverageFrameRate"
        case refFrames = "RefFrames"
        case isInterlaced = "IsInterlaced"
        case pixelFormat = "PixelFormat"
        case aspectRatio = "AspectRatio"
        case videoRange = "VideoRange"
        case videoRangeType = "VideoRangeType"
        case videoDoViTitle = "VideoDoViTitle"
        case colorTransfer = "ColorTransfer"
        case colorPrimaries = "ColorPrimaries"
        case colorSpace = "ColorSpace"
        case dvProfile = "DvProfile"
        case dvLevel = "DvLevel"
        case dvVersionMajor = "DvVersionMajor"
        case dvVersionMinor = "DvVersionMinor"
        case dvBlSignalCompatibilityID = "DvBlSignalCompatibilityId"
        case rpuPresentFlag = "RpuPresentFlag"
        case elPresentFlag = "ElPresentFlag"
        case blPresentFlag = "BlPresentFlag"
        case hdr10PlusPresentFlag = "Hdr10PlusPresentFlag"
        case channels = "Channels"
        case channelLayout = "ChannelLayout"
        case sampleRate = "SampleRate"
        case audioSpatialFormat = "AudioSpatialFormat"
        case deliveryMethod = "DeliveryMethod"
        case deliveryURL = "DeliveryUrl"
        case isExternalURL = "IsExternalUrl"
    }
}

/// `MediaAttachment` (fonts for ASS/SSA):
/// `GET /Videos/{id}/{mediaSourceId}/Attachments/{index}`.
struct JellyfinMediaAttachmentDTO: Decodable, Hashable, Sendable {
    let index: Int
    let codec: String?
    let fileName: String?
    let mimeType: String?
    let deliveryURL: String?

    enum CodingKeys: String, CodingKey {
        case index = "Index"
        case codec = "Codec"
        case fileName = "FileName"
        case mimeType = "MimeType"
        case deliveryURL = "DeliveryUrl"
    }
}
