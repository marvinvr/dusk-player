import Foundation

// Plex `Media` / `Part` / `Stream` / `Marker` / `Rating` DTOs → domain types.
//
// The domain types keep `Codable` here, as a shim onto the DTOs: what Dusk
// persisted (`downloads.json`, the converted-media blob, the offline metadata
// cache) is the Plex wire shape, so decoding from disk goes through the same
// DTO and mapper as decoding from a server, and encoding writes the same keys
// and id forms (`encodeID`) it always has. None of these types carries a
// server id.

// MARK: - Mapping

extension MediaVersion {
    init(plex dto: PlexMediaVersionDTO) {
        self.init(
            id: dto.id,
            container: dto.container,
            videoCodec: dto.videoCodec,
            audioCodec: dto.audioCodec,
            videoResolution: dto.videoResolution,
            videoProfile: dto.videoProfile,
            audioProfile: dto.audioProfile,
            audioChannels: dto.audioChannels,
            width: dto.width,
            height: dto.height,
            bitrate: dto.bitrate,
            duration: dto.duration,
            optimizedForStreaming: dto.optimizedForStreaming,
            parts: dto.parts.map(MediaPart.init(plex:))
        )
    }
}

extension MediaPart {
    init(plex dto: PlexMediaPartDTO) {
        self.init(
            id: dto.id,
            key: dto.key,
            file: dto.file,
            size: dto.size,
            container: dto.container,
            duration: dto.duration,
            videoProfile: dto.videoProfile,
            audioProfile: dto.audioProfile,
            accessible: dto.accessible,
            exists: dto.exists,
            streams: dto.streams.map(MediaStream.init(plex:))
        )
    }
}

extension MediaStream {
    init(plex dto: PlexMediaStreamDTO) {
        self.init(
            id: dto.id,
            kind: dto.kind,
            codec: dto.codec,
            displayTitle: dto.displayTitle,
            extendedDisplayTitle: dto.extendedDisplayTitle,
            language: dto.language,
            languageCode: dto.languageCode,
            languageTag: dto.languageTag,
            isSelected: dto.selected,
            isDefault: dto.isDefault,
            width: dto.width,
            height: dto.height,
            bitrate: dto.bitrate,
            frameRate: dto.frameRate,
            bitDepth: dto.bitDepth,
            colorSpace: dto.colorSpace,
            colorRange: dto.colorRange,
            colorPrimaries: dto.colorPrimaries,
            colorTransfer: dto.colorTrc,
            chromaSubsampling: dto.chromaSubsampling,
            profile: dto.profile,
            level: dto.level,
            doviPresent: dto.doviPresent,
            doviProfile: dto.doviProfile,
            doviLevel: dto.doviLevel,
            doviBLCompatID: dto.doviBLCompatID,
            channels: dto.channels,
            channelLayout: dto.channelLayout,
            samplingRate: dto.samplingRate,
            isForced: dto.forced,
            isHearingImpaired: dto.hearingImpaired,
            key: dto.key,
            codecID: dto.codecID
        )
    }
}

extension Marker {
    init(plex dto: PlexMarkerDTO) {
        self.init(
            id: dto.id,
            type: dto.type,
            startTimeOffset: dto.startTimeOffset,
            endTimeOffset: dto.endTimeOffset
        )
    }
}

extension Rating {
    init(plex dto: PlexRatingDTO) {
        self.init(image: dto.image, value: dto.value, type: dto.type)
    }
}

// MARK: - Persisted coding (Plex wire shape)

extension MediaVersion: Codable {
    init(from decoder: Decoder) throws {
        self.init(plex: try PlexMediaVersionDTO(from: decoder))
    }

    /// The id is written back as a number when it is one (`encodeID`).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlexMediaVersionDTO.CodingKeys.self)
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

extension MediaPart: Codable {
    init(from decoder: Decoder) throws {
        self.init(plex: try PlexMediaPartDTO(from: decoder))
    }

    /// The id is written back as a number when it is one (`encodeID`).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlexMediaPartDTO.CodingKeys.self)
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

extension MediaStream: Codable {
    init(from decoder: Decoder) throws {
        self.init(plex: try PlexMediaStreamDTO(from: decoder))
    }

    /// The id is written back as a number when it is one (`encodeID`).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlexMediaStreamDTO.CodingKeys.self)
        try container.encodeID(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(codec, forKey: .codec)
        try container.encodeIfPresent(displayTitle, forKey: .displayTitle)
        try container.encodeIfPresent(extendedDisplayTitle, forKey: .extendedDisplayTitle)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(languageCode, forKey: .languageCode)
        try container.encodeIfPresent(languageTag, forKey: .languageTag)
        try container.encodeIfPresent(isServerSelected, forKey: .selected)
        try container.encodeIfPresent(isDefault, forKey: .isDefault)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encodeIfPresent(bitrate, forKey: .bitrate)
        try container.encodeIfPresent(frameRate, forKey: .frameRate)
        try container.encodeIfPresent(bitDepth, forKey: .bitDepth)
        try container.encodeIfPresent(colorSpace, forKey: .colorSpace)
        try container.encodeIfPresent(colorRange, forKey: .colorRange)
        try container.encodeIfPresent(colorPrimaries, forKey: .colorPrimaries)
        try container.encodeIfPresent(colorTransfer, forKey: .colorTrc)
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
        try container.encodeIfPresent(isForced, forKey: .forced)
        try container.encodeIfPresent(isHearingImpaired, forKey: .hearingImpaired)
        try container.encodeIfPresent(key, forKey: .key)
    }
}

/// `Marker` declares `Codable` itself (its declaration line borders
/// `MediaDetails`' decoding); these are the implementations.
extension Marker {
    init(from decoder: Decoder) throws {
        self.init(plex: try PlexMarkerDTO(from: decoder))
    }

    /// `isEstimated` is never written; the id is written back as a number when
    /// it is one (`encodeID`).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlexMarkerDTO.CodingKeys.self)
        try container.encodeID(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(startTimeOffset, forKey: .startTimeOffset)
        try container.encode(endTimeOffset, forKey: .endTimeOffset)
    }
}

extension Rating: Decodable {
    init(from decoder: Decoder) throws {
        self.init(plex: try PlexRatingDTO(from: decoder))
    }
}
