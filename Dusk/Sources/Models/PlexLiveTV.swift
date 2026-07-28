import Foundation

struct PlexLiveTVProvider: Sendable, Hashable, Identifiable {
    let identifier: String
    let providerIdentifier: String
    let title: String
    let dvrID: Int
    let gridKey: String

    var id: String { identifier }

    var channelsKey: String {
        "\(identifier.hasPrefix("/") ? "" : "/")\(identifier)/lineups/dvr/channels"
    }

    var watchNowKey: String {
        "\(identifier.hasPrefix("/") ? "" : "/")\(identifier)/watchnow/all"
    }
}

struct PlexLiveChannel: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let gridKey: String
    let vcn: String?
    let isHD: Bool
    let thumb: String?
    let title: String
    let callSign: String?
    let language: String?

    var tuneIdentifier: String {
        vcn?.nilIfEmpty ?? id
    }

    var displayTitle: String {
        title.nilIfEmpty ?? callSign?.nilIfEmpty ?? "Channel \(vcn ?? id)"
    }

    var displayNumber: String? {
        vcn?.nilIfEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id, gridKey, vcn, isHD = "isHd", thumb, title, callSign, language
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = Self.decodeString(container, key: .id) ?? UUID().uuidString
        gridKey = Self.decodeString(container, key: .gridKey) ?? id
        vcn = Self.decodeString(container, key: .vcn)
        isHD = Self.decodeBool(container, key: .isHD) ?? false
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        callSign = try container.decodeIfPresent(String.self, forKey: .callSign)
        language = try container.decodeIfPresent(String.self, forKey: .language)
    }

    private static func decodeString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    private static func decodeBool(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return ["1", "true", "yes"].contains(value.lowercased())
        }
        return nil
    }
}

struct PlexLiveProgram: Decodable, Sendable, Hashable, Identifiable {
    let ratingKey: String
    let key: String?
    let title: String
    let summary: String?
    let thumb: String?
    let art: String?
    let grandparentTitle: String?
    let parentTitle: String?
    let type: PlexMediaType
    let duration: Int?
    let airings: [PlexLiveAiring]

    var id: String {
        "\(ratingKey)-\(primaryAiring?.channelIdentifier ?? "unknown")-\(Int(primaryAiring?.beginsAt ?? 0))"
    }

    var primaryAiring: PlexLiveAiring? {
        airings.first
    }

    var channelIdentifier: String? {
        primaryAiring?.channelIdentifier
    }

    var channelGridKey: String? {
        primaryAiring?.gridKey
    }

    var beginsAt: Date? {
        primaryAiring.map { Date(timeIntervalSince1970: $0.beginsAt) }
    }

    var endsAt: Date? {
        primaryAiring.map { Date(timeIntervalSince1970: $0.endsAt) }
    }

    var preferredLandscapePath: String? {
        art?.nilIfEmpty ?? thumb?.nilIfEmpty
    }

    var displayTitle: String {
        title.nilIfEmpty ?? grandparentTitle?.nilIfEmpty ?? "Unknown Program"
    }

    var displaySubtitle: String? {
        if let grandparentTitle = grandparentTitle?.nilIfEmpty,
           grandparentTitle != displayTitle {
            return grandparentTitle
        }
        return parentTitle?.nilIfEmpty
    }

    func isAiring(at date: Date = .now) -> Bool {
        guard let beginsAt, let endsAt else { return false }
        return beginsAt <= date && date < endsAt
    }

    func progress(at date: Date = .now) -> Double? {
        guard let beginsAt, let endsAt, endsAt > beginsAt else { return nil }
        let elapsed = date.timeIntervalSince(beginsAt)
        let total = endsAt.timeIntervalSince(beginsAt)
        return min(max(elapsed / total, 0), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case ratingKey, key, title, summary, thumb, art, grandparentTitle, parentTitle
        case type, duration
        case airings = "Media"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        ratingKey = Self.decodeString(container, key: .ratingKey)
            ?? key
            ?? UUID().uuidString
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        art = try container.decodeIfPresent(String.self, forKey: .art)
        grandparentTitle = try container.decodeIfPresent(String.self, forKey: .grandparentTitle)
        parentTitle = try container.decodeIfPresent(String.self, forKey: .parentTitle)
        type = try container.decodeIfPresent(PlexMediaType.self, forKey: .type) ?? .unknown
        duration = Self.decodeInt(container, key: .duration)
        airings = try container.decodeIfPresent([PlexLiveAiring].self, forKey: .airings) ?? []
    }

    private static func decodeString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    private static func decodeInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
}

struct PlexLiveAiring: Decodable, Sendable, Hashable {
    let id: Int?
    let beginsAt: TimeInterval
    let endsAt: TimeInterval
    let channelID: Int?
    let channelIdentifier: String?
    let channelThumb: String?
    let channelTitle: String?
    let channelVCN: String?
    let channelCallSign: String?
    let gridKey: String?
    let videoResolution: String?

    private enum CodingKeys: String, CodingKey {
        case id, beginsAt, endsAt, channelID, channelIdentifier, channelThumb
        case channelTitle, channelVCN = "channelVcn", channelCallSign, gridKey
        case videoResolution
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = Self.decodeInt(container, key: .id)
        beginsAt = Self.decodeTime(container, key: .beginsAt) ?? 0
        endsAt = Self.decodeTime(container, key: .endsAt) ?? beginsAt
        channelID = Self.decodeInt(container, key: .channelID)
        channelIdentifier = Self.decodeString(container, key: .channelIdentifier)
        channelThumb = try container.decodeIfPresent(String.self, forKey: .channelThumb)
        channelTitle = try container.decodeIfPresent(String.self, forKey: .channelTitle)
        channelVCN = Self.decodeString(container, key: .channelVCN)
        channelCallSign = try container.decodeIfPresent(String.self, forKey: .channelCallSign)
        gridKey = Self.decodeString(container, key: .gridKey)
        videoResolution = try container.decodeIfPresent(String.self, forKey: .videoResolution)
    }

    private static func decodeTime(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> TimeInterval? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return TimeInterval(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return TimeInterval(value)
        }
        return nil
    }

    private static func decodeInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    private static func decodeString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        return nil
    }
}

struct PlexLiveChannelGuide: Sendable, Hashable, Identifiable {
    let channel: PlexLiveChannel
    let programs: [PlexLiveProgram]

    var id: String { channel.id }

    func currentProgram(at date: Date = .now) -> PlexLiveProgram? {
        programs.first { $0.isAiring(at: date) }
    }

    func nextProgram(after date: Date = .now) -> PlexLiveProgram? {
        programs
            .filter { ($0.beginsAt ?? .distantPast) > date }
            .min { ($0.beginsAt ?? .distantFuture) < ($1.beginsAt ?? .distantFuture) }
    }
}

struct PlexLiveTVLineup: Sendable, Hashable {
    let provider: PlexLiveTVProvider
    let guides: [PlexLiveChannelGuide]

    var channels: [PlexLiveChannel] {
        guides.map(\.channel)
    }

    func guide(for channel: PlexLiveChannel) -> PlexLiveChannelGuide? {
        guides.first { $0.channel.id == channel.id }
    }
}

struct PlexLivePlaybackContext: Sendable, Hashable {
    let lineup: PlexLiveTVLineup
    let channel: PlexLiveChannel
    let program: PlexLiveProgram?
    let sessionID: String

    var sessionPath: String {
        "/livetv/sessions/\(sessionID)"
    }
}

struct PlexLiveTuneResult: Sendable {
    let sessionID: String
    let playbackURL: URL
    let media: PlexMedia
    let part: PlexMediaPart
}

// MARK: - Plex response envelopes

struct PlexMediaProvidersResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let MediaProvider: [Provider]?
    }

    struct Provider: Decodable {
        let id: Int?
        let parentID: Int?
        let identifier: String?
        let providerIdentifier: String?
        let title: String?
        let protocols: String?
        let Feature: [Feature]?

        private enum CodingKeys: String, CodingKey {
            case id, parentID, identifier, providerIdentifier, title, protocols, Feature
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = Self.decodeInt(container, key: .id)
            parentID = Self.decodeInt(container, key: .parentID)
            identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
            providerIdentifier = try container.decodeIfPresent(String.self, forKey: .providerIdentifier)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            protocols = try container.decodeIfPresent(String.self, forKey: .protocols)
            Feature = try container.decodeIfPresent(
                [PlexMediaProvidersResponse.Feature].self,
                forKey: .Feature
            )
        }

        var liveTVProvider: PlexLiveTVProvider? {
            guard protocols?.lowercased().contains("livetv") == true,
                  let identifier,
                  let gridKey = Feature?.first(where: { $0.type == "grid" })?.key,
                  let dvrID = parentID ?? Self.trailingIdentifier(in: identifier) ?? id else {
                return nil
            }

            return PlexLiveTVProvider(
                identifier: identifier,
                providerIdentifier: providerIdentifier ?? identifier.components(separatedBy: ":").first ?? identifier,
                title: title ?? "Live TV",
                dvrID: dvrID,
                gridKey: gridKey
            )
        }

        private static func trailingIdentifier(in identifier: String) -> Int? {
            identifier.split(separator: ":").last.flatMap { Int($0) }
        }

        private static func decodeInt(
            _ container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) -> Int? {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return Int(value)
            }
            return nil
        }
    }

    struct Feature: Decodable {
        let type: String
        let key: String?
    }
}

struct PlexLiveChannelsResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let Channel: [PlexLiveChannel]?
    }
}

struct PlexLiveTuneResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let Metadata: [PlayableMetadata]
        let MediaSubscription: [MediaSubscription]
        let Video: [PlayableMetadata]
        let message: String?

        private enum CodingKeys: String, CodingKey {
            case Metadata, MediaSubscription, Video, message
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            Metadata = container.decodeOneOrMany(PlayableMetadata.self, forKey: .Metadata)
            MediaSubscription = container.decodeOneOrMany(
                PlexLiveTuneResponse.MediaSubscription.self,
                forKey: .MediaSubscription
            )
            Video = container.decodeOneOrMany(PlayableMetadata.self, forKey: .Video)
            message = try container.decodeIfPresent(String.self, forKey: .message)
        }

        var tunedSession: TunedSession? {
            for subscription in MediaSubscription {
                for operation in subscription.MediaGrabOperation {
                    if let session = operation.Metadata.lazy.compactMap(\.tunedSession).first {
                        return session
                    }
                    if let session = operation.Video.lazy.compactMap(\.tunedSession).first {
                        return session
                    }
                }
            }

            return Metadata.lazy.compactMap(\.tunedSession).first
                ?? Video.lazy.compactMap(\.tunedSession).first
        }
    }

    struct PlayableMetadata: Decodable {
        let key: String?
        let Media: [TuneMedia]

        private enum CodingKeys: String, CodingKey {
            case key, Media
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decodeIfPresent(String.self, forKey: .key)
            Media = container.decodeOneOrMany(TuneMedia.self, forKey: .Media)
        }

        var tunedSession: TunedSession? {
            let media = Media.first
            guard let sessionPath = Self.liveSessionPath(from: key)
                    ?? media?.sessionPath else {
                return nil
            }
            return TunedSession(
                sessionPath: sessionPath,
                playbackPath: media?.playbackPath,
                media: media
            )
        }

        static func liveSessionPath(from value: String?) -> String? {
            guard let value,
                  let range = value.range(of: "/livetv/sessions/") else {
                return nil
            }
            let livePath = value[range.lowerBound...]
            let components = livePath
                .split(separator: "?", maxSplits: 1)
                .first?
                .split(separator: "/", omittingEmptySubsequences: true)
            guard let components, components.count >= 3 else { return nil }
            return "/" + components.prefix(3).joined(separator: "/")
        }
    }

    struct MediaSubscription: Decodable {
        let MediaGrabOperation: [MediaGrabOperation]

        private enum CodingKeys: String, CodingKey {
            case MediaGrabOperation
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            MediaGrabOperation = container.decodeOneOrMany(
                PlexLiveTuneResponse.MediaGrabOperation.self,
                forKey: .MediaGrabOperation
            )
        }
    }

    struct MediaGrabOperation: Decodable {
        let Metadata: [PlayableMetadata]
        let Video: [PlayableMetadata]

        private enum CodingKeys: String, CodingKey {
            case Metadata, Video
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            Metadata = container.decodeOneOrMany(PlayableMetadata.self, forKey: .Metadata)
            Video = container.decodeOneOrMany(PlayableMetadata.self, forKey: .Video)
        }
    }

    struct TunedSession {
        let sessionPath: String
        let playbackPath: String?
        let media: TuneMedia?

        var sessionID: String? {
            sessionPath
                .split(separator: "/", omittingEmptySubsequences: true)
                .last
                .map(String.init)?
                .nilIfEmpty
        }
    }

    struct TuneMedia: Decodable {
        let id: Int?
        let uuid: String?
        let container: String?
        let videoCodec: String?
        let audioCodec: String?
        let videoResolution: String?
        let audioChannels: Int?
        let width: Int?
        let height: Int?
        let bitrate: Int?
        let duration: Int?
        let Part: [TunePart]?

        var sessionPath: String? {
            if let uuid = uuid?.nilIfEmpty {
                return "/livetv/sessions/\(uuid)"
            }
            return Part?.lazy
                .compactMap(\.key)
                .compactMap(PlayableMetadata.liveSessionPath)
                .first
        }

        var playbackPath: String? {
            Part?.lazy
                .compactMap(\.key)
                .first { $0.contains("/livetv/sessions/") }
        }

        func makeMedia(sessionPath: String) -> PlexMedia {
            let convertedParts = (Part ?? []).enumerated().map { index, part in
                part.makePart(id: index, sessionPath: sessionPath)
            }
            let fallbackPart = PlexMediaPart(
                id: 0,
                key: sessionPath,
                file: nil,
                size: nil,
                container: container ?? "mpegts",
                duration: duration,
                videoProfile: nil,
                audioProfile: nil,
                accessible: true,
                exists: true,
                streams: []
            )

            return PlexMedia(
                id: id ?? 0,
                container: container ?? "hls",
                videoCodec: videoCodec,
                audioCodec: audioCodec,
                videoResolution: videoResolution,
                videoProfile: nil,
                audioProfile: nil,
                audioChannels: audioChannels,
                width: width,
                height: height,
                bitrate: bitrate,
                duration: duration,
                optimizedForStreaming: nil,
                parts: convertedParts.isEmpty ? [fallbackPart] : convertedParts
            )
        }
    }

    struct TunePart: Decodable {
        let id: Int?
        let key: String?
        let container: String?
        let duration: Int?
        let Stream: [TuneStream]?

        func makePart(id fallbackID: Int, sessionPath: String) -> PlexMediaPart {
            PlexMediaPart(
                id: id ?? fallbackID,
                key: key ?? sessionPath,
                file: nil,
                size: nil,
                container: container ?? "mpegts",
                duration: duration,
                videoProfile: nil,
                audioProfile: nil,
                accessible: true,
                exists: true,
                streams: (Stream ?? []).enumerated().compactMap { index, stream in
                    stream.makeStream(id: index)
                }
            )
        }
    }

    struct TuneStream: Decodable {
        let id: Int?
        let index: Int?
        let streamType: Int?
        let codec: String?
        let width: Int?
        let height: Int?
        let bitrate: Int?
        let frameRate: Double?
        let bitDepth: Int?
        let profile: String?
        let level: Int?
        let channels: Int?
        let audioChannelLayout: String?
        let samplingRate: Int?

        func makeStream(id fallbackID: Int) -> PlexStream? {
            guard let streamType, let type = PlexStreamType(rawValue: streamType) else {
                return nil
            }

            return PlexStream(
                id: id ?? index ?? fallbackID,
                streamType: type,
                codec: codec,
                displayTitle: nil,
                extendedDisplayTitle: nil,
                language: nil,
                languageCode: nil,
                languageTag: nil,
                isSelected: nil,
                isDefault: nil,
                width: width,
                height: height,
                bitrate: bitrate,
                frameRate: frameRate,
                bitDepth: bitDepth,
                colorSpace: nil,
                colorRange: nil,
                colorPrimaries: nil,
                colorTrc: nil,
                chromaSubsampling: nil,
                profile: profile,
                level: level,
                doviPresent: nil,
                doviProfile: nil,
                doviLevel: nil,
                doviBLCompatID: nil,
                channels: channels,
                channelLayout: audioChannelLayout,
                samplingRate: samplingRate,
                isForced: nil,
                isHearingImpaired: nil,
                key: nil
            )
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeOneOrMany<T: Decodable>(
        _ type: T.Type,
        forKey key: Key
    ) -> [T] {
        if let values = try? decode([T].self, forKey: key) {
            return values
        }
        if let value = try? decode(T.self, forKey: key) {
            return [value]
        }
        return []
    }
}
