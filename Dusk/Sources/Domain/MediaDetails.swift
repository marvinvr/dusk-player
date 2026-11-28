import Foundation

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
    /// credits marker (see `estimatedCreditsID`). Never decoded or persisted,
    /// so it defaults to false.
    var isEstimated: Bool = false

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
struct MediaVersion: Sendable, Identifiable {
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
}

// MARK: - Part (individual file within a media version)

/// A single file part. Most items have exactly one part, but multi-file
/// items (e.g. split DVDs) can have multiple.
struct MediaPart: Sendable, Identifiable {
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
}

// MARK: - Stream (individual track)

/// Stream type constants matching the Plex API.
enum StreamKind: Int, Codable, Sendable {
    case video = 1
    case audio = 2
    case subtitle = 3
}

/// A single audio, video, or subtitle track within a media part.
struct MediaStream: Sendable, Identifiable {
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
