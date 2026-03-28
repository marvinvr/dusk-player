import Foundation

/// Full metadata for a Plex item including the media/part/stream hierarchy.
/// Returned from `GET /library/metadata/{ratingKey}`. Used by StreamResolver
/// to determine which playback engine to use and to construct the direct play URL.
struct PlexMediaDetails: Decodable, Sendable, Identifiable {
    var id: String { ratingKey }

    let ratingKey: String
    let key: String
    let type: PlexMediaType
    let title: String
    let summary: String?
    let year: Int?
    let duration: Int?
    let viewOffset: Int?
    let viewCount: Int?
    let thumb: String?
    let art: String?
    let clearLogo: String?
    let contentRating: String?

    // Ratings
    let rating: Double?
    let audienceRating: Double?

    // Production
    let studio: String?
    let originallyAvailableAt: String?

    // Show/season counts
    let childCount: Int?
    let leafCount: Int?
    let viewedLeafCount: Int?

    // Episode hierarchy (when type == .episode)
    let index: Int?
    let parentIndex: Int?
    let parentRatingKey: String?
    let parentThumb: String?
    let grandparentRatingKey: String?
    let grandparentTitle: String?
    let grandparentThumb: String?

    // Metadata tags
    let genres: [PlexTag]?
    let directors: [PlexTag]?
    let writers: [PlexTag]?
    let roles: [PlexRole]?
    let markers: [PlexMarker]

    /// The media versions for this item. A single item can have multiple
    /// versions (e.g. different resolutions or codecs).
    let media: [PlexMedia]

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, type, title, summary, year
        case duration, viewOffset, viewCount, thumb, art, clearLogo, contentRating
        case rating, audienceRating, studio, originallyAvailableAt
        case childCount, leafCount, viewedLeafCount
        case index, parentIndex, parentRatingKey, parentThumb, grandparentRatingKey, grandparentTitle, grandparentThumb
        case genres = "Genre"
        case directors = "Director"
        case writers = "Writer"
        case roles = "Role"
        case markers = "Marker"
        case media = "Media"
        case images = "Image"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ratingKey = try container.decode(String.self, forKey: .ratingKey)
        key = try container.decode(String.self, forKey: .key)
        type = try container.decode(PlexMediaType.self, forKey: .type)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        viewOffset = try container.decodeIfPresent(Int.self, forKey: .viewOffset)
        viewCount = try container.decodeIfPresent(Int.self, forKey: .viewCount)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        art = try container.decodeIfPresent(String.self, forKey: .art)
        clearLogo = try container.decodePlexImageURLIfPresent(type: "clearLogo", explicitKey: .clearLogo, arrayKey: .images)
        contentRating = try container.decodeIfPresent(String.self, forKey: .contentRating)
        rating = try container.decodeIfPresent(Double.self, forKey: .rating)
        audienceRating = try container.decodeIfPresent(Double.self, forKey: .audienceRating)
        studio = try container.decodeIfPresent(String.self, forKey: .studio)
        originallyAvailableAt = try container.decodeIfPresent(String.self, forKey: .originallyAvailableAt)
        childCount = try container.decodeIfPresent(Int.self, forKey: .childCount)
        leafCount = try container.decodeIfPresent(Int.self, forKey: .leafCount)
        viewedLeafCount = try container.decodeIfPresent(Int.self, forKey: .viewedLeafCount)
        index = try container.decodeIfPresent(Int.self, forKey: .index)
        parentIndex = try container.decodeIfPresent(Int.self, forKey: .parentIndex)
        parentRatingKey = try container.decodeIfPresent(String.self, forKey: .parentRatingKey)
        parentThumb = try container.decodeIfPresent(String.self, forKey: .parentThumb)
        grandparentRatingKey = try container.decodeIfPresent(String.self, forKey: .grandparentRatingKey)
        grandparentTitle = try container.decodeIfPresent(String.self, forKey: .grandparentTitle)
        grandparentThumb = try container.decodeIfPresent(String.self, forKey: .grandparentThumb)
        genres = try container.decodeIfPresent([PlexTag].self, forKey: .genres)
        directors = try container.decodeIfPresent([PlexTag].self, forKey: .directors)
        writers = try container.decodeIfPresent([PlexTag].self, forKey: .writers)
        roles = try container.decodeIfPresent([PlexRole].self, forKey: .roles)
        markers = (try container.decodeIfPresent([PlexMarker].self, forKey: .markers) ?? [])
            .sorted { $0.startTimeOffset < $1.startTimeOffset }
        media = try container.decodeIfPresent([PlexMedia].self, forKey: .media) ?? []
    }
}

private extension KeyedDecodingContainer where Key == PlexMediaDetails.CodingKeys {
    func decodePlexImageURLIfPresent(type: String, explicitKey: Key, arrayKey: Key) throws -> String? {
        if let explicitValue = try decodeIfPresent(String.self, forKey: explicitKey) {
            return explicitValue
        }

        let images = try decodeIfPresent([PlexImageResource].self, forKey: arrayKey) ?? []
        return images.first(where: { $0.type.caseInsensitiveCompare(type) == .orderedSame })?.url
    }
}

struct PlexMarker: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let type: String
    let startTimeOffset: Int
    let endTimeOffset: Int

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

// MARK: - Media (file-level metadata)

/// A single media version of a Plex item.
/// One item can have multiple media entries (e.g. 1080p and 4K versions).
struct PlexMedia: Codable, Sendable, Identifiable {
    let id: Int

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

    let parts: [PlexMediaPart]

    enum CodingKeys: String, CodingKey {
        case id, container, videoCodec, audioCodec
        case videoResolution, videoProfile, audioProfile, audioChannels
        case width, height, bitrate, duration, optimizedForStreaming
        case parts = "Part"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
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
        parts = try container.decodeIfPresent([PlexMediaPart].self, forKey: .parts) ?? []
    }
}

// MARK: - Part (individual file within a media version)

/// A single file part. Most items have exactly one part, but multi-file
/// items (e.g. split DVDs) can have multiple.
struct PlexMediaPart: Codable, Sendable, Identifiable {
    let id: Int

    /// Relative path used to construct the direct play URL:
    /// `{serverURL}{key}?X-Plex-Token={token}`
    let key: String

    let file: String?
    let size: Int?
    let container: String?
    let duration: Int?
    let videoProfile: String?
    let audioProfile: String?

    let streams: [PlexStream]

    enum CodingKeys: String, CodingKey {
        case id, key, file, size, container, duration
        case videoProfile, audioProfile
        case streams = "Stream"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        key = try container.decode(String.self, forKey: .key)
        file = try container.decodeIfPresent(String.self, forKey: .file)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        self.container = try container.decodeIfPresent(String.self, forKey: .container)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        videoProfile = try container.decodeIfPresent(String.self, forKey: .videoProfile)
        audioProfile = try container.decodeIfPresent(String.self, forKey: .audioProfile)
        streams = try container.decodeIfPresent([PlexStream].self, forKey: .streams) ?? []
    }
}

// MARK: - Stream (individual track)

/// Stream type constants matching the Plex API.
enum PlexStreamType: Int, Codable, Sendable {
    case video = 1
    case audio = 2
    case subtitle = 3
}

/// A single audio, video, or subtitle track within a media part.
struct PlexStream: Codable, Sendable, Identifiable {
    let id: Int
    let streamType: PlexStreamType
    let codec: String?
    let displayTitle: String?
    let extendedDisplayTitle: String?
    let language: String?
    let languageCode: String?
    let languageTag: String?
    let isSelected: Bool?
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
    let colorTrc: String?
    let chromaSubsampling: String?
    let profile: String?
    let level: Int?

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
        case id, streamType, codec
        case displayTitle, extendedDisplayTitle
        case language, languageCode, languageTag
        case isSelected = "selected"
        case isDefault = "default"
        case width, height, bitrate, frameRate, bitDepth
        case colorSpace, colorRange, colorPrimaries, colorTrc
        case chromaSubsampling, profile, level
        case channels, channelLayout, samplingRate
        case isForced = "forced"
        case isHearingImpaired = "hearingImpaired"
        case key
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        streamType = try container.decode(PlexStreamType.self, forKey: .streamType)
        codec = try container.decodeIfPresent(String.self, forKey: .codec)
        displayTitle = try container.decodeIfPresent(String.self, forKey: .displayTitle)
        extendedDisplayTitle = try container.decodeIfPresent(String.self, forKey: .extendedDisplayTitle)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
        languageTag = try container.decodeIfPresent(String.self, forKey: .languageTag)

        // Plex returns Bool-ish fields as Int (0/1) or Bool depending on endpoint
        isSelected = try Self.decodeBoolish(container: container, key: .isSelected)
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
        colorTrc = try container.decodeIfPresent(String.self, forKey: .colorTrc)
        chromaSubsampling = try container.decodeIfPresent(String.self, forKey: .chromaSubsampling)
        profile = try container.decodeIfPresent(String.self, forKey: .profile)
        level = try container.decodeIfPresent(Int.self, forKey: .level)
        channels = try container.decodeIfPresent(Int.self, forKey: .channels)
        channelLayout = try container.decodeIfPresent(String.self, forKey: .channelLayout)
        samplingRate = try container.decodeIfPresent(Int.self, forKey: .samplingRate)
        key = try container.decodeIfPresent(String.self, forKey: .key)
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
