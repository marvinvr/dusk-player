import Foundation
import OSLog

private let plexMediaLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "PlexMedia"
)

/// Full metadata for a Plex item including the media/part/stream hierarchy.
/// Returned from `GET /library/metadata/{itemID}`. Used by StreamResolver
/// to determine which playback engine to use and to construct the direct play URL.
struct MediaDetails: Sendable, Identifiable {
    /// Server-scoped identity; see `MediaItemID`.
    var id: MediaItemID { MediaItemID(serverID: serverID, itemID: itemID) }

    /// Machine identifier of the server this payload came from, stamped by the
    /// provider's mapper (`PlexItemMapper`).
    let serverID: String?

    let itemID: String
    let key: String
    let type: MediaKind
    /// Plex marks video clips with `subtype == "clip"` even when `type` is `movie`.
    let subtype: String?
    /// The library section the item belongs to, as a string key usable with the
    /// `/library/sections/{id}/...` endpoints. Plex serializes it as a number.
    let libraryID: String?
    let librarySectionTitle: String?
    let title: String
    /// Plex edition name; see `MediaItem.editionTitle`.
    let editionTitle: String?
    let summary: String?
    let year: Int?
    let duration: Int?
    let resumeOffsetMs: Int?
    let playCount: Int?
    let thumb: String?
    let art: String?
    let clearLogo: String?
    let contentRating: String?
    /// The extra Plex features for the title (`/library/metadata/{key}`), its
    /// main trailer when it has one.
    let primaryExtraKey: String?

    // Ratings
    let rating: Double?
    let audienceRating: Double?
    /// Where `rating` / `audienceRating` come from (`rottentomatoes://image.rating.ripe`).
    let ratingImage: String?
    let audienceRatingImage: String?
    /// The signed-in user's own rating, 0–10 (Plex stores half stars).
    let userRating: Double?
    /// Every source the agent found (IMDb, Rotten Tomatoes, TMDB, …); newer
    /// servers only. See `Rating.sources(for:)`.
    let ratings: [Rating]

    // Production
    let studio: String?
    let originallyAvailableAt: String?

    // Show/season counts
    let childCount: Int?
    let episodeCount: Int?
    let watchedEpisodeCount: Int?

    // Episode hierarchy (when type == .episode)
    let index: Int?
    let parentIndex: Int?
    let parentID: String?
    let parentThumb: String?
    let grandparentID: String?
    let grandparentTitle: String?
    let grandparentThumb: String?

    // Metadata tags
    let genres: [Tag]?
    let directors: [Tag]?
    let writers: [Tag]?
    let roles: [Person]?
    /// Collections the item belongs to. Video clip libraries carry one per
    /// channel, which drives the "More from this channel" row.
    let collections: [Tag]?
    /// Plex's scalar guid (`plex://…` on modern servers). See `ContentKey`.
    let guid: String?
    let guids: [PlexGuid]
    let markers: [Marker]

    /// The media versions for this item. A single item can have multiple
    /// versions (e.g. different resolutions or codecs).
    var media: [MediaVersion]
}

extension MediaDetails {
    /// Whether the item is a video clip (e.g. from an "Other Videos" library).
    /// Mirrors `MediaItem.isClip`.
    var isClip: Bool {
        subtype == "clip" || type == .clip
    }

    /// A copy whose video streams in `partID` of `mediaID` carry
    /// `sampleEntry` as their `codecID`, so every later engine decision for
    /// the session sees what the file probe found.
    func stampingVideoSampleEntry(_ sampleEntry: String, mediaID: String, partID: String) -> MediaDetails {
        var copy = self
        for mediaIndex in copy.media.indices where copy.media[mediaIndex].id == mediaID {
            for partIndex in copy.media[mediaIndex].parts.indices
            where copy.media[mediaIndex].parts[partIndex].id == partID {
                for streamIndex in copy.media[mediaIndex].parts[partIndex].streams.indices
                where copy.media[mediaIndex].parts[partIndex].streams[streamIndex].kind == .video {
                    copy.media[mediaIndex].parts[partIndex].streams[streamIndex].codecID = sampleEntry
                }
            }
        }
        return copy
    }
}

struct Marker: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let type: String
    let startTimeOffset: Int
    let endTimeOffset: Int
    /// True for a synthesized fallback marker used when Plex ships no real
    /// credits marker (see `estimatedCreditsID`). Never decoded from Plex, so it
    /// is excluded from `CodingKeys` and defaults to false.
    var isEstimated: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id, type, startTimeOffset, endTimeOffset
    }

    /// Sentinel id for the synthesized "estimated credits" marker. Negative so it
    /// can never collide with a real Plex marker id.
    static let estimatedCreditsID = "-1"

    var isIntro: Bool {
        type.caseInsensitiveCompare("intro") == .orderedSame
    }

    var isCredits: Bool {
        type.caseInsensitiveCompare("credits") == .orderedSame
    }

    var skipButtonTitle: String? {
        if isIntro {
            return "Skip Intro"
        }
        if isCredits {
            return "Skip Credits"
        }
        return nil
    }

    func contains(positionMs: Int) -> Bool {
        positionMs >= startTimeOffset && positionMs < endTimeOffset
    }
}

struct PlexScrubPreviewFrame: Sendable {
    let timestampMs: Int64
    let imageData: Data
}

struct PlexScrubPreviewSource: Sendable {
    let frames: [PlexScrubPreviewFrame]

    var isAvailable: Bool {
        !frames.isEmpty
    }

    func frame(at position: TimeInterval) -> PlexScrubPreviewFrame? {
        guard !frames.isEmpty else { return nil }

        let positionMs = Int64(max(0, position) * 1000)
        var lowerBound = 0
        var upperBound = frames.count - 1

        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound + 1) / 2
            if frames[midpoint].timestampMs <= positionMs {
                lowerBound = midpoint
            } else {
                upperBound = midpoint - 1
            }
        }

        return frames[lowerBound]
    }
}

// MARK: - Media (file-level metadata)

/// A single media version of a Plex item.
/// One item can have multiple media entries (e.g. 1080p and 4K versions).
struct MediaVersion: Codable, Sendable, Identifiable {
    let id: String

    let container: String?
    let videoCodec: String?
    let audioCodec: String?
    let videoResolution: String?
    let videoProfile: String?
    let audioProfile: String?
    let audioChannels: Int?
    let width: Int?
    let height: Int?
    let bitrate: Int?
    let duration: Int?
    let optimizedForStreaming: Int?

    var parts: [MediaPart]

    /// Whether this version has at least one part Plex still reports as present.
    var hasAvailablePart: Bool {
        parts.contains { $0.isAvailable }
    }

    /// The first part Plex still reports as present, falling back to the first
    /// part when nothing is explicitly flagged.
    var firstAvailablePart: MediaPart? {
        parts.first { $0.isAvailable } ?? parts.first
    }

    enum CodingKeys: String, CodingKey {
        case id, container, videoCodec, audioCodec
        case videoResolution, videoProfile, audioProfile, audioChannels
        case width, height, bitrate, duration, optimizedForStreaming
        case parts = "Part"
    }

    init(
        id: String,
        container: String?,
        videoCodec: String?,
        audioCodec: String?,
        videoResolution: String?,
        videoProfile: String?,
        audioProfile: String?,
        audioChannels: Int?,
        width: Int?,
        height: Int?,
        bitrate: Int?,
        duration: Int?,
        optimizedForStreaming: Int?,
        parts: [MediaPart]
    ) {
        self.id = id
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.videoResolution = videoResolution
        self.videoProfile = videoProfile
        self.audioProfile = audioProfile
        self.audioChannels = audioChannels
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.duration = duration
        self.optimizedForStreaming = optimizedForStreaming
        self.parts = parts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeID(forKey: .id)
        self.container = try container.decodeIfPresent(String.self, forKey: .container)
        videoCodec = try container.decodeIfPresent(String.self, forKey: .videoCodec)
        audioCodec = try container.decodeIfPresent(String.self, forKey: .audioCodec)
        videoResolution = try container.decodeIfPresent(String.self, forKey: .videoResolution)
        videoProfile = try container.decodeIfPresent(String.self, forKey: .videoProfile)
        audioProfile = try container.decodeIfPresent(String.self, forKey: .audioProfile)
        audioChannels = try container.decodeIfPresent(Int.self, forKey: .audioChannels)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        optimizedForStreaming = try container.decodeIfPresent(Int.self, forKey: .optimizedForStreaming)
        parts = try container.decodeIfPresent([MediaPart].self, forKey: .parts) ?? []
    }
}

// MARK: - Part (individual file within a media version)

/// A single file part. Most items have exactly one part, but multi-file
/// items (e.g. split DVDs) can have multiple.
struct MediaPart: Codable, Sendable, Identifiable {
    let id: String

    /// Relative path used to construct the direct play URL:
    /// `{serverURL}{key}?X-Plex-Token={token}`
    let key: String

    let file: String?
    let size: Int?
    let container: String?
    let duration: Int?
    let videoProfile: String?
    let audioProfile: String?

    /// Plex's file-presence flags. Only populated reliably when the metadata
    /// request asks Plex to stat the files (`checkFiles=1`). When a file is
    /// deleted and re-added, Plex can keep the old version around with these set
    /// to `false` until its trash is emptied.
    let accessible: Bool?
    let exists: Bool?

    var streams: [MediaStream]

    /// Treat a part as unavailable only when Plex explicitly flags it missing;
    /// absent flags mean "assume available" so we never hide good versions.
    var isAvailable: Bool {
        accessible != false && exists != false
    }

    enum CodingKeys: String, CodingKey {
        case id, key, file, size, container, duration
        case videoProfile, audioProfile, accessible, exists
        case streams = "Stream"
    }

    init(
        id: String,
        key: String,
        file: String?,
        size: Int?,
        container: String?,
        duration: Int?,
        videoProfile: String?,
        audioProfile: String?,
        accessible: Bool?,
        exists: Bool?,
        streams: [MediaStream]
    ) {
        self.id = id
        self.key = key
        self.file = file
        self.size = size
        self.container = container
        self.duration = duration
        self.videoProfile = videoProfile
        self.audioProfile = audioProfile
        self.accessible = accessible
        self.exists = exists
        self.streams = streams
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeID(forKey: .id)
        key = try container.decode(String.self, forKey: .key)
        file = try container.decodeIfPresent(String.self, forKey: .file)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        self.container = try container.decodeIfPresent(String.self, forKey: .container)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        videoProfile = try container.decodeIfPresent(String.self, forKey: .videoProfile)
        audioProfile = try container.decodeIfPresent(String.self, forKey: .audioProfile)
        accessible = Self.decodeFlexibleBool(container, forKey: .accessible)
        exists = Self.decodeFlexibleBool(container, forKey: .exists)
        streams = try Self.decodeStreams(container)
    }

    /// Decodes each `Stream` entry on its own and drops the ones that fail, so
    /// one odd track can't take the whole item down. Plex has been seen omitting
    /// `id` on a stream in the metadata JSON (likely embedded EIA-608 captions),
    /// and newer servers may add stream types we don't model. A dropped stream
    /// just isn't offered from Plex metadata; a made-up id could otherwise be
    /// sent back to Plex as a stream selection.
    private static func decodeStreams(
        _ container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [MediaStream] {
        guard let entries = try container.decodeIfPresent([LenientStream].self, forKey: .streams) else {
            return []
        }
        return entries.enumerated().compactMap { index, entry in
            if let stream = entry.stream { return stream }
            plexMediaLogger.error(
                "Dropping undecodable stream \(index, privacy: .public) (streamType \(entry.kind.map(String.init) ?? "?", privacy: .public), codec \(entry.codec ?? "?", privacy: .public)): \(entry.failure ?? "unknown error", privacy: .public)"
            )
            return nil
        }
    }

    /// Plex serializes these flags inconsistently across versions (bool, `1`/`0`,
    /// or `"1"`/`"0"`), so decode defensively and treat anything unexpected as
    /// "unknown" rather than failing the whole part.
    private static func decodeFlexibleBool(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
            return intValue != 0
        }
        if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
            switch stringValue.trimmingCharacters(in: .whitespaces).lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        }
        return nil
    }
}

/// One `Stream` entry that never fails to decode: holds the stream when it is
/// valid, otherwise whatever is readable for logging.
private struct LenientStream: Decodable {
    let stream: MediaStream?
    let kind: Int?
    let codec: String?
    let failure: String?

    private enum ProbeKeys: String, CodingKey {
        case kind = "streamType", codec
    }

    init(from decoder: Decoder) throws {
        do {
            stream = try MediaStream(from: decoder)
            kind = nil
            codec = nil
            failure = nil
        } catch {
            let probe = try? decoder.container(keyedBy: ProbeKeys.self)
            stream = nil
            kind = try? probe?.decodeIfPresent(Int.self, forKey: .kind)
            codec = try? probe?.decodeIfPresent(String.self, forKey: .codec)
            failure = String(describing: error)
        }
    }
}

// MARK: - Stream (individual track)

/// Stream type constants matching the Plex API.
enum StreamKind: Int, Codable, Sendable {
    case video = 1
    case audio = 2
    case subtitle = 3
}

/// A single audio, video, or subtitle track within a media part.
struct MediaStream: Codable, Sendable, Identifiable {
    let id: String
    let kind: StreamKind
    let codec: String?
    let displayTitle: String?
    let extendedDisplayTitle: String?
    let language: String?
    let languageCode: String?
    let languageTag: String?
    let isServerSelected: Bool?
    let isDefault: Bool?

    // Video stream fields
    let width: Int?
    let height: Int?
    let bitrate: Int?
    let frameRate: Double?
    let bitDepth: Int?
    let colorSpace: String?
    let colorRange: String?
    let colorPrimaries: String?
    let colorTransfer: String?
    let chromaSubsampling: String?
    let profile: String?
    let level: Int?
    /// The container's sample-entry tag (`hvc1`, `hev1`, `avc1`, …) when
    /// known: from Plex's `codecID`, or stamped by the coordinator after
    /// probing the file (`HEVCSampleEntryProbe`). AVPlayer shows no picture
    /// for `hev1` HEVC, see `StreamResolver.containsHEV1Video`.
    var codecID: String?

    // Dolby Vision (video streams). Plex only sends these when the stream
    // carries a DV layer; profile 5 has no HDR10-compatible base layer, which
    // StreamResolver routes through the Dolby Vision remux.
    let dolbyVision: DolbyVisionInfo?

    // Audio stream fields
    let channels: Int?
    let channelLayout: String?
    let samplingRate: Int?

    // Subtitle stream fields
    let isForced: Bool?
    let isHearingImpaired: Bool?
    /// Non-nil for external (sidecar) subtitle files.
    let key: String?

    enum CodingKeys: String, CodingKey {
        case id, kind = "streamType", codec
        case displayTitle, extendedDisplayTitle
        case language, languageCode, languageTag
        case isServerSelected = "selected"
        case isDefault = "default"
        case width, height, bitrate, frameRate, bitDepth
        case colorSpace, colorRange, colorPrimaries, colorTransfer = "colorTrc"
        case chromaSubsampling, profile, level, codecID
        case doviPresent = "DOVIPresent"
        case doviProfile = "DOVIProfile"
        case doviLevel = "DOVILevel"
        case doviBLCompatID = "DOVIBLCompatID"
        case channels, samplingRate
        case channelLayout = "audioChannelLayout"
        case isForced = "forced"
        case isHearingImpaired = "hearingImpaired"
        case key
    }

    init(
        id: String,
        kind: StreamKind,
        codec: String?,
        displayTitle: String?,
        extendedDisplayTitle: String?,
        language: String?,
        languageCode: String?,
        languageTag: String?,
        isSelected: Bool?,
        isDefault: Bool?,
        width: Int?,
        height: Int?,
        bitrate: Int?,
        frameRate: Double?,
        bitDepth: Int?,
        colorSpace: String?,
        colorRange: String?,
        colorPrimaries: String?,
        colorTransfer: String?,
        chromaSubsampling: String?,
        profile: String?,
        level: Int?,
        doviPresent: Bool?,
        doviProfile: Int?,
        doviLevel: Int?,
        doviBLCompatID: Int?,
        channels: Int?,
        channelLayout: String?,
        samplingRate: Int?,
        isForced: Bool?,
        isHearingImpaired: Bool?,
        key: String?,
        codecID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.codec = codec
        self.displayTitle = displayTitle
        self.extendedDisplayTitle = extendedDisplayTitle
        self.language = language
        self.languageCode = languageCode
        self.languageTag = languageTag
        self.isServerSelected = isSelected
        self.isDefault = isDefault
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.frameRate = frameRate
        self.bitDepth = bitDepth
        self.colorSpace = colorSpace
        self.colorRange = colorRange
        self.colorPrimaries = colorPrimaries
        self.colorTransfer = colorTransfer
        self.chromaSubsampling = chromaSubsampling
        self.profile = profile
        self.level = level
        self.dolbyVision = DolbyVisionInfo(
            present: doviPresent, profile: doviProfile, level: doviLevel, blCompatID: doviBLCompatID
        )
        self.channels = channels
        self.channelLayout = channelLayout
        self.samplingRate = samplingRate
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.key = key
        self.codecID = codecID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeID(forKey: .id)
        kind = try container.decode(StreamKind.self, forKey: .kind)
        codec = try container.decodeIfPresent(String.self, forKey: .codec)
        displayTitle = try container.decodeIfPresent(String.self, forKey: .displayTitle)
        extendedDisplayTitle = try container.decodeIfPresent(String.self, forKey: .extendedDisplayTitle)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
        languageTag = try container.decodeIfPresent(String.self, forKey: .languageTag)

        // Plex returns Bool-ish fields as Int (0/1) or Bool depending on endpoint
        isServerSelected = try Self.decodeBoolish(container: container, key: .isServerSelected)
        isDefault = try Self.decodeBoolish(container: container, key: .isDefault)
        isForced = try Self.decodeBoolish(container: container, key: .isForced)
        isHearingImpaired = try Self.decodeBoolish(container: container, key: .isHearingImpaired)

        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate)
        frameRate = try container.decodeIfPresent(Double.self, forKey: .frameRate)
        bitDepth = try container.decodeIfPresent(Int.self, forKey: .bitDepth)
        colorSpace = try container.decodeIfPresent(String.self, forKey: .colorSpace)
        colorRange = try container.decodeIfPresent(String.self, forKey: .colorRange)
        colorPrimaries = try container.decodeIfPresent(String.self, forKey: .colorPrimaries)
        colorTransfer = try container.decodeIfPresent(String.self, forKey: .colorTransfer)
        chromaSubsampling = try container.decodeIfPresent(String.self, forKey: .chromaSubsampling)
        profile = try container.decodeIfPresent(String.self, forKey: .profile)
        level = try container.decodeIfPresent(Int.self, forKey: .level)
        codecID = try? container.decodeIfPresent(String.self, forKey: .codecID)
        dolbyVision = DolbyVisionInfo(
            present: try Self.decodeBoolish(container: container, key: .doviPresent),
            profile: try container.decodeIfPresent(Int.self, forKey: .doviProfile),
            level: try container.decodeIfPresent(Int.self, forKey: .doviLevel),
            blCompatID: try container.decodeIfPresent(Int.self, forKey: .doviBLCompatID)
        )
        channels = try container.decodeIfPresent(Int.self, forKey: .channels)
        // Older offline snapshots used Dusk's property name as the JSON key.
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        channelLayout = try container.decodeIfPresent(String.self, forKey: .channelLayout)
            ?? legacy.decodeIfPresent(String.self, forKey: .channelLayout)
        samplingRate = try container.decodeIfPresent(Int.self, forKey: .samplingRate)
        key = try container.decodeIfPresent(String.self, forKey: .key)
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case channelLayout
    }

    /// Plex sometimes sends Bool fields as Int (0/1) and sometimes as actual Bool.
    private static func decodeBoolish(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Bool? {
        if let boolVal = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return boolVal
        }
        if let intVal = try? container.decodeIfPresent(Int.self, forKey: key) {
            return intVal != 0
        }
        return nil
    }
}

extension Marker {
    /// Matches the synthesized decoding, except that the id may be a number
    /// (Plex) or a string.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeID(forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        startTimeOffset = try container.decode(Int.self, forKey: .startTimeOffset)
        endTimeOffset = try container.decode(Int.self, forKey: .endTimeOffset)
    }

    /// Matches the synthesized encoding; the id is written back as a number
    /// when it is one (`encodeID`).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeID(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(startTimeOffset, forKey: .startTimeOffset)
        try container.encode(endTimeOffset, forKey: .endTimeOffset)
    }
}

extension MediaVersion {
    /// Matches the synthesized encoding; the id is written back as a number
    /// when it is one (`encodeID`).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeID(id, forKey: .id)
        try container.encodeIfPresent(self.container, forKey: .container)
        try container.encodeIfPresent(videoCodec, forKey: .videoCodec)
        try container.encodeIfPresent(audioCodec, forKey: .audioCodec)
        try container.encodeIfPresent(videoResolution, forKey: .videoResolution)
        try container.encodeIfPresent(videoProfile, forKey: .videoProfile)
        try container.encodeIfPresent(audioProfile, forKey: .audioProfile)
        try container.encodeIfPresent(audioChannels, forKey: .audioChannels)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encodeIfPresent(bitrate, forKey: .bitrate)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(optimizedForStreaming, forKey: .optimizedForStreaming)
        try container.encode(parts, forKey: .parts)
    }
}

extension MediaPart {
    /// Matches the synthesized encoding; the id is written back as a number
    /// when it is one (`encodeID`).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeID(id, forKey: .id)
        try container.encode(key, forKey: .key)
        try container.encodeIfPresent(file, forKey: .file)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(self.container, forKey: .container)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(videoProfile, forKey: .videoProfile)
        try container.encodeIfPresent(audioProfile, forKey: .audioProfile)
        try container.encodeIfPresent(accessible, forKey: .accessible)
        try container.encodeIfPresent(exists, forKey: .exists)
        try container.encode(streams, forKey: .streams)
    }
}

extension MediaStream {
    /// Matches the synthesized encoding; the id is written back as a number
    /// when it is one (`encodeID`).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeID(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(codec, forKey: .codec)
        try container.encodeIfPresent(displayTitle, forKey: .displayTitle)
        try container.encodeIfPresent(extendedDisplayTitle, forKey: .extendedDisplayTitle)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(languageCode, forKey: .languageCode)
        try container.encodeIfPresent(languageTag, forKey: .languageTag)
        try container.encodeIfPresent(isServerSelected, forKey: .isServerSelected)
        try container.encodeIfPresent(isDefault, forKey: .isDefault)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encodeIfPresent(bitrate, forKey: .bitrate)
        try container.encodeIfPresent(frameRate, forKey: .frameRate)
        try container.encodeIfPresent(bitDepth, forKey: .bitDepth)
        try container.encodeIfPresent(colorSpace, forKey: .colorSpace)
        try container.encodeIfPresent(colorRange, forKey: .colorRange)
        try container.encodeIfPresent(colorPrimaries, forKey: .colorPrimaries)
        try container.encodeIfPresent(colorTransfer, forKey: .colorTransfer)
        try container.encodeIfPresent(chromaSubsampling, forKey: .chromaSubsampling)
        try container.encodeIfPresent(profile, forKey: .profile)
        try container.encodeIfPresent(level, forKey: .level)
        try container.encodeIfPresent(codecID, forKey: .codecID)
        try container.encodeIfPresent(dolbyVision?.present, forKey: .doviPresent)
        try container.encodeIfPresent(dolbyVision?.profile, forKey: .doviProfile)
        try container.encodeIfPresent(dolbyVision?.level, forKey: .doviLevel)
        try container.encodeIfPresent(dolbyVision?.blCompatID, forKey: .doviBLCompatID)
        try container.encodeIfPresent(channels, forKey: .channels)
        try container.encodeIfPresent(samplingRate, forKey: .samplingRate)
        try container.encodeIfPresent(channelLayout, forKey: .channelLayout)
        try container.encodeIfPresent(isForced, forKey: .isForced)
        try container.encodeIfPresent(isHearingImpaired, forKey: .isHearingImpaired)
        try container.encodeIfPresent(key, forKey: .key)
    }
}

/// Dolby Vision signalling of a video stream. Plex sends the four fields
/// independently (`DOVIPresent`, `DOVIProfile`, `DOVILevel`,
/// `DOVIBLCompatID`), so each stays optional on its own: `present == true` is
/// not the same as "some field is known". The stream's `dolbyVision` is nil
/// only when none of them is.
struct DolbyVisionInfo: Sendable, Hashable {
    let present: Bool?
    let profile: Int?
    let level: Int?
    let blCompatID: Int?

    init?(present: Bool?, profile: Int?, level: Int?, blCompatID: Int?) {
        guard present != nil || profile != nil || level != nil || blCompatID != nil else { return nil }
        self.present = present
        self.profile = profile
        self.level = level
        self.blCompatID = blCompatID
    }
}
