import Foundation

struct PlexLiveTVProvider: Sendable, Hashable, Identifiable {
    let identifier: String
    let providerIdentifier: String
    let title: String
    let dvrID: Int
    let gridKey: String
    /// The server this DVR lives on; every Live TV call goes back to it.
    var serverID: String?

    var id: String { identifier }

    func on(serverID: String) -> PlexLiveTVProvider {
        var provider = self
        provider.serverID = serverID
        return provider
    }

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
    /// Every other identifier the lineup advertises for this channel
    /// (`identifier`, `key`). Guide airings may reference a channel by any of
    /// them, so they take part in guide matching but never in tuning.
    let alternateIdentifiers: [String]
    /// Set only for a channel from an IPTV source (`IPTVLineupBuilder`). Such
    /// a channel is never tuned through Plex: `PlaybackCoordinator.playLiveTV`
    /// hands it to AVPlayer directly.
    var iptv: IPTVPlayableChannel? = nil

    var tuneIdentifier: String {
        // `id` is Plex's DVR ChannelMapping.channelKey. `vcn` is only the
        // human-facing virtual channel number (for example "7.1") and is not
        // a valid tune target on current cloud/XMLTV lineups.
        id
    }

    var displayTitle: String {
        title.nilIfEmpty ?? callSign?.nilIfEmpty ?? "Channel \(vcn ?? id)"
    }

    var displayNumber: String? {
        vcn?.nilIfEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id, gridKey, vcn, isHD = "isHd", thumb, title, callSign, language
        case identifier, key, channelVcn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = Self.decodeString(container, key: .id)
        let decodedGridKey = Self.decodeString(container, key: .gridKey)
        id = decodedID ?? decodedGridKey ?? UUID().uuidString
        gridKey = decodedGridKey ?? decodedID ?? id
        vcn = Self.decodeString(container, key: .vcn)
            ?? Self.decodeString(container, key: .channelVcn)
        alternateIdentifiers = [
            Self.decodeString(container, key: .identifier),
            Self.decodeString(container, key: .key),
        ].compactMap { $0?.nilIfEmpty }
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
    /// The metadata guid (`plex://episode/…`) on Plex guides. A DVR recording
    /// matched by Plex carries the same one, which is how a past airing finds
    /// its recording in the library. Nil for IPTV.
    let guid: String?
    let title: String
    let summary: String?
    let thumb: String?
    let art: String?
    let grandparentTitle: String?
    let parentTitle: String?
    let type: PlexMediaType
    let duration: Int?
    private(set) var airings: [PlexLiveAiring]

    var id: String {
        "\(ratingKey)-\(primaryAiring?.channelIdentifier ?? "unknown")-\(Int(primaryAiring?.beginsAt ?? 0))"
    }

    var primaryAiring: PlexLiveAiring? {
        airings.first
    }

    /// One copy per airing. A grid item lists every airing of the program
    /// (simulcast subchannels, repeats), but the guide and player read the
    /// times and channel off `primaryAiring`, so each airing has to become
    /// its own program before it is filed under a channel.
    func splitByAiring() -> [PlexLiveProgram] {
        guard airings.count > 1 else { return [self] }
        return airings.map { airing in
            var program = self
            program.airings = [airing]
            return program
        }
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

    /// The series a live program belongs to, when it is an episode of one.
    /// Guides carry the episode name in `title` and the series in
    /// `grandparentTitle`, so the series is what a viewer needs to see first —
    /// an episode title alone rarely says what is on.
    var seriesTitle: String? {
        grandparentTitle?.nilIfEmpty
    }

    /// What to lead with: the series for an episode, the program itself
    /// otherwise.
    var primaryDisplayTitle: String {
        seriesTitle ?? displayTitle
    }

    /// The episode title, when the series is already leading.
    var episodeDisplayTitle: String? {
        guard let seriesTitle, let episodeTitle = title.nilIfEmpty else { return nil }
        return episodeTitle == seriesTitle ? nil : episodeTitle
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
        case ratingKey, key, guid, title, summary, thumb, art, grandparentTitle, parentTitle
        case type, duration
        case airings = "Media"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        guid = try? container.decodeIfPresent(String.self, forKey: .guid)
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

extension PlexLiveProgram {
    // Here rather than with the rest of the IPTV mapping
    // (`IPTVLineupBuilder`) because `airings` has a private setter.
    /// XMLTV `title` is the show and `sub-title` the episode, while Plex puts
    /// the episode in `title` and the show in `grandparentTitle`; mapped so
    /// the shared guide reads both the same way.
    init(iptv programme: IPTVProgramme, channel: PlexLiveChannel) {
        let start = Int(programme.start.timeIntervalSince1970)
        ratingKey = "iptv-\(channel.id)-\(start)"
        key = nil
        guid = nil
        if let subtitle = programme.subtitle?.nilIfEmpty, subtitle != programme.title {
            title = subtitle
            grandparentTitle = programme.title.nilIfEmpty
        } else {
            title = programme.title
            grandparentTitle = nil
        }
        summary = programme.summary
        thumb = programme.iconURL?.absoluteString
        art = nil
        parentTitle = nil
        type = .unknown
        duration = Int(programme.stop.timeIntervalSince(programme.start) * 1000)
        airings = [PlexLiveAiring(
            beginsAt: programme.start.timeIntervalSince1970,
            endsAt: programme.stop.timeIntervalSince1970,
            channel: channel
        )]
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

    init(provider: PlexLiveTVProvider, guides: [PlexLiveChannelGuide]) {
        self.provider = provider
        self.guides = guides
    }

    /// Files guide programs under the lineup's channels. Every channel gets a
    /// guide, empty when nothing matched, so it stays listed and tunable.
    init(
        provider: PlexLiveTVProvider,
        channels: [PlexLiveChannel],
        programs: [PlexLiveProgram]
    ) {
        let matcher = PlexLiveChannelMatcher(channels: channels)
        var programsByChannel: [String: [PlexLiveProgram]] = [:]
        var seenIDs: [String: Set<String>] = [:]
        for program in programs.flatMap({ $0.splitByAiring() }) {
            guard let airing = program.primaryAiring,
                  let channel = matcher.channel(for: airing),
                  seenIDs[channel.id, default: []].insert(program.id).inserted else { continue }
            programsByChannel[channel.id, default: []].append(program)
        }
        self.init(
            provider: provider,
            guides: channels.map { channel in
                PlexLiveChannelGuide(
                    channel: channel,
                    programs: (programsByChannel[channel.id] ?? []).sorted {
                        ($0.beginsAt ?? .distantPast) < ($1.beginsAt ?? .distantPast)
                    }
                )
            }
        )
    }

    var channels: [PlexLiveChannel] {
        guides.map(\.channel)
    }

    func guide(for channel: PlexLiveChannel) -> PlexLiveChannelGuide? {
        guides.first { $0.channel.id == channel.id }
    }

    func channel(for program: PlexLiveProgram) -> PlexLiveChannel? {
        guides.first { $0.programs.contains(program) }?.channel
    }

    /// Keeps only programs that overlap `window`; channels stay listed (and
    /// tunable) even when nothing of theirs is left.
    func restricted(to window: LiveTVGuideWindow) -> PlexLiveTVLineup {
        PlexLiveTVLineup(
            provider: provider,
            guides: guides.map { guide in
                PlexLiveChannelGuide(
                    channel: guide.channel,
                    programs: guide.programs.filter { window.contains($0) }
                )
            }
        )
    }
}

/// The stretch of time the guide shows. "Now" starts at the current time and
/// runs `lookahead` ahead, crossing midnight when it has to: a guide held to
/// one calendar day showed only the last hour late in the evening, and an
/// app left running overnight kept showing the day it was opened (issue #17).
/// A later day runs from its midnight to the next.
struct LiveTVGuideWindow: Hashable, Sendable {
    let start: Date
    let end: Date

    static let lookahead: TimeInterval = 12 * 60 * 60

    /// `dayOffset` 0 is "Now"; 1 and up are whole days after today, -1 and
    /// down whole days before it (catch-up).
    static func forDayOffset(
        _ dayOffset: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> LiveTVGuideWindow {
        guard dayOffset != 0 else {
            return LiveTVGuideWindow(start: now, end: now.addingTimeInterval(lookahead))
        }
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(24 * 60 * 60)
        return LiveTVGuideWindow(start: start, end: end)
    }

    /// The local calendar days Plex's `date=` grid has to be asked for to
    /// cover the window, oldest first.
    func gridDays(calendar: Calendar = .current) -> [Date] {
        var days: [Date] = []
        var day = calendar.startOfDay(for: start)
        while day < end {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    /// Whether `program` is on at any point inside the window. A program
    /// without times is kept: dropping it would hide guide data the server
    /// did send.
    func contains(_ program: PlexLiveProgram) -> Bool {
        guard let beginsAt = program.beginsAt, let endsAt = program.endsAt else { return true }
        return endsAt > start && beginsAt < end
    }
}

/// Decides which lineup channel a guide airing belongs to. Providers disagree
/// on which field ties the two together: cloud and XMLTV guides carry the
/// channel's `gridKey`, others only an identifier, a channel number or a call
/// sign (issue #17: an HDHomeRun lineup listed every channel with no programs).
/// Identifiers are tried first; the descriptive keys only count when they
/// name exactly one channel, since subchannels often share a call sign or a
/// network title.
struct PlexLiveChannelMatcher {
    private let channels: [PlexLiveChannel]
    private var byIdentifier: [String: Int] = [:]
    private var byNumber: [String: [Int]] = [:]
    private var byCallSign: [String: [Int]] = [:]
    private var byTitle: [String: [Int]] = [:]

    init(channels: [PlexLiveChannel]) {
        self.channels = channels
        for (index, channel) in channels.enumerated() {
            for identifier in [channel.gridKey, channel.id] + channel.alternateIdentifiers {
                if byIdentifier[identifier] == nil {
                    byIdentifier[identifier] = index
                }
            }
            if let number = Self.normalizedNumber(channel.vcn) {
                byNumber[number, default: []].append(index)
            }
            if let callSign = Self.normalizedName(channel.callSign) {
                byCallSign[callSign, default: []].append(index)
            }
            if let title = Self.normalizedName(channel.title) {
                byTitle[title, default: []].append(index)
            }
        }
    }

    func channel(for airing: PlexLiveAiring) -> PlexLiveChannel? {
        let identifiers = [airing.gridKey, airing.channelIdentifier, airing.channelID.map(String.init)]
            .compactMap { $0?.nilIfEmpty }
        if let index = identifiers.lazy.compactMap({ byIdentifier[$0] }).first {
            return channels[index]
        }
        let candidates = [
            Self.normalizedNumber(airing.channelVCN).flatMap { byNumber[$0] },
            Self.normalizedName(airing.channelCallSign).flatMap { byCallSign[$0] },
            Self.normalizedName(airing.channelTitle).flatMap { byTitle[$0] },
        ]
        if let match = candidates.lazy.compactMap({ $0 }).first(where: { $0.count == 1 }) {
            return channels[match[0]]
        }
        return nil
    }

    /// "3.1", "3-1" and " 03.1 " are the same ATSC subchannel.
    private static func normalizedNumber(_ value: String?) -> String? {
        guard let value = value?.nilIfEmpty else { return nil }
        let parts = value
            .split(whereSeparator: { !$0.isNumber })
            .map { String(Int($0) ?? 0) }
        return parts.isEmpty ? nil : parts.joined(separator: ".")
    }

    private static func normalizedName(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty
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

    /// The tuned channel's schedule. Refreshed during playback by
    /// `PlaybackCoordinator`, so it stays valid past the tuned program's end.
    var channelPrograms: [PlexLiveProgram] {
        lineup.guide(for: channel)?.programs ?? []
    }

    func program(at date: Date) -> PlexLiveProgram? {
        channelPrograms.first { $0.isAiring(at: date) }
    }

    /// Copy of this context carrying a fresh schedule for the tuned channel.
    /// Other channels keep their guides so the in-player channel list still
    /// shows what is on elsewhere.
    func replacingChannelPrograms(_ programs: [PlexLiveProgram]) -> PlexLivePlaybackContext {
        var guides = lineup.guides.map { guide in
            guide.channel.id == channel.id
                ? PlexLiveChannelGuide(channel: guide.channel, programs: programs)
                : guide
        }
        if !guides.contains(where: { $0.channel.id == channel.id }) {
            guides.append(PlexLiveChannelGuide(channel: channel, programs: programs))
        }
        return PlexLivePlaybackContext(
            lineup: PlexLiveTVLineup(provider: lineup.provider, guides: guides),
            channel: channel,
            program: programs.first { $0.isAiring() } ?? program,
            sessionID: sessionID
        )
    }
}

struct PlexLiveTuneResult: Sendable {
    /// The server the tuner session lives on. Live TV runs on one server at a
    /// time, and every follow-up call (stream URL, transcode ping/stop) has to
    /// go back to that same one.
    let serverID: String
    let sessionID: String
    let playbackSessionIdentifier: String
    let transcodeSessionID: String?
    let playbackURL: URL
    let media: PlexMedia
    let part: PlexMediaPart
    /// Playing the live session's own HLS (the tuner stream, copied), not a
    /// Plex transcode. See `PlexService.liveTVDirectPlayURL`.
    var isDirectPlay = false
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
        // Optional so one odd feature can't fail the whole provider list, and
        // with it Live TV discovery.
        let type: String?
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

        /// Why Plex refused the tune, for a response without a session. A
        /// tuner conflict (a one-tuner HDHomeRun/Threadfin device already on
        /// another channel; Plex keeps a closed channel's tuner for a few
        /// minutes) gets a message that says so instead of a parse error.
        var tuneFailureMessage: String? {
            let operations = MediaSubscription.flatMap(\.MediaGrabOperation)
            if operations.contains(where: \.hasConflicts)
                || operations.contains(where: { $0.error?.localizedCaseInsensitiveContains("conflict") == true }) {
                return String(
                    localized: "All tuners are in use. Stop another Live TV stream or recording, or try again in a few minutes."
                )
            }
            return operations.lazy.compactMap { $0.error?.nilIfEmpty }.first
                ?? message?.nilIfEmpty
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
        /// "inprogress" for a tuned channel, "error" when the grab was refused.
        let status: String?
        /// Why a refused grab failed, e.g. "The recording conflicts with other
        /// recordings" when every tuner of the device is in use.
        let error: String?
        /// Present when the grab was refused for a tuner conflict.
        let hasConflicts: Bool

        private enum CodingKeys: String, CodingKey {
            case Metadata, Video, status, error, Conflicts
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            Metadata = container.decodeOneOrMany(PlayableMetadata.self, forKey: .Metadata)
            Video = container.decodeOneOrMany(PlayableMetadata.self, forKey: .Video)
            status = container.lenientString(forKey: .status)
            error = container.lenientString(forKey: .error)
            hasConflicts = container.contains(.Conflicts)
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

        private enum CodingKeys: String, CodingKey {
            case id, uuid, container, videoCodec, audioCodec, videoResolution, audioChannels
            case width, height, bitrate, duration, Part
        }

        // The tune answer is not typed like library metadata: PMS 1.43 sends
        // `Media.id`, `Part.id` and `Stream.id` as strings ("222512"). One
        // strict `Int` threw away the whole Media, so the session fell back to
        // codec-less media, the resolver sent it to VLCKit as "unknown" video
        // and Plex Live TV only ever played (if at all) through libvlc's HLS.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = container.lenientInt(forKey: .id)
            uuid = container.lenientString(forKey: .uuid)
            self.container = container.lenientString(forKey: .container)
            videoCodec = container.lenientString(forKey: .videoCodec)
            audioCodec = container.lenientString(forKey: .audioCodec)
            videoResolution = container.lenientString(forKey: .videoResolution)
            audioChannels = container.lenientInt(forKey: .audioChannels)
            width = container.lenientInt(forKey: .width)
            height = container.lenientInt(forKey: .height)
            bitrate = container.lenientInt(forKey: .bitrate)
            duration = container.lenientInt(forKey: .duration)
            let parts = container.decodeOneOrMany(TunePart.self, forKey: .Part)
            Part = parts.isEmpty ? nil : parts
        }

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

        /// Whether the live session's own HLS (the tuner stream as the
        /// grabber copies it, no re-encode) plays in AVPlayer as it is:
        /// MPEG-TS with progressive 8-bit H.264 and AAC/AC-3/E-AC-3/MP3
        /// audio. Anything else (MPEG-2 broadcast video, interlaced or 10-bit
        /// H.264, MP2 audio, unknown codecs) goes through the transcoder.
        var supportsLiveDirectPlay: Bool {
            let streams = (Part ?? []).flatMap { $0.Stream ?? [] }
            let video = streams.filter { $0.streamType == PlexStreamType.video.rawValue }
            let audio = streams.filter { $0.streamType == PlexStreamType.audio.rawValue }
            guard (container ?? "mpegts").lowercased() == "mpegts",
                  (videoCodec ?? video.first?.codec)?.lowercased() == "h264",
                  !video.contains(where: { $0.scanType?.lowercased() == "interlaced" }),
                  !video.contains(where: { ($0.bitDepth ?? 8) > 8 }) else {
                return false
            }
            let audioCodecs = audio.isEmpty
                ? [audioCodec].compactMap { $0?.lowercased() }
                : audio.map { $0.codec?.lowercased() ?? "" }
            return !audioCodecs.isEmpty
                && audioCodecs.allSatisfy { ["aac", "ac3", "eac3", "mp3"].contains($0) }
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

        private enum CodingKeys: String, CodingKey {
            case id, key, container, duration, Stream
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = container.lenientInt(forKey: .id)
            key = container.lenientString(forKey: .key)
            self.container = container.lenientString(forKey: .container)
            duration = container.lenientInt(forKey: .duration)
            let streams = container.decodeOneOrMany(TuneStream.self, forKey: .Stream)
            Stream = streams.isEmpty ? nil : streams
        }

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
        let scanType: String?

        private enum CodingKeys: String, CodingKey {
            case id, index, streamType, codec, width, height, bitrate, frameRate, bitDepth
            case profile, level, channels, audioChannelLayout, samplingRate, scanType
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = container.lenientInt(forKey: .id)
            index = container.lenientInt(forKey: .index)
            streamType = container.lenientInt(forKey: .streamType)
            codec = container.lenientString(forKey: .codec)
            width = container.lenientInt(forKey: .width)
            height = container.lenientInt(forKey: .height)
            bitrate = container.lenientInt(forKey: .bitrate)
            frameRate = container.lenientDouble(forKey: .frameRate)
            bitDepth = container.lenientInt(forKey: .bitDepth)
            profile = container.lenientString(forKey: .profile)
            level = container.lenientInt(forKey: .level)
            channels = container.lenientInt(forKey: .channels)
            audioChannelLayout = container.lenientString(forKey: .audioChannelLayout)
            samplingRate = container.lenientInt(forKey: .samplingRate)
            scanType = container.lenientString(forKey: .scanType)
        }

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

    /// Numbers the tune answer may send as JSON numbers or as strings.
    func lenientInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return Int(value)
        }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return Int(trimmed) ?? Double(trimmed).flatMap { $0.isFinite ? Int($0) : nil }
        }
        return nil
    }

    func lenientDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return Double(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    func lenientString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        return nil
    }
}
