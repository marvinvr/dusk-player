import Foundation

struct LiveTVProvider: Sendable, Hashable, Identifiable {
    let identifier: String
    let providerIdentifier: String
    let title: String
    let dvrID: Int
    let gridKey: String
    /// The server this DVR lives on; every Live TV call goes back to it.
    var serverID: String?

    var id: String { identifier }

    func on(serverID: String) -> LiveTVProvider {
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

struct LiveChannel: Sendable, Hashable, Identifiable {
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

    init(
        id: String,
        gridKey: String,
        vcn: String?,
        isHD: Bool,
        thumb: String?,
        title: String,
        callSign: String?,
        language: String?,
        alternateIdentifiers: [String] = [],
        iptv: IPTVPlayableChannel? = nil
    ) {
        self.id = id
        self.gridKey = gridKey
        self.vcn = vcn
        self.isHD = isHD
        self.thumb = thumb
        self.title = title
        self.callSign = callSign
        self.language = language
        self.alternateIdentifiers = alternateIdentifiers
        self.iptv = iptv
    }
}

struct LiveProgram: Sendable, Hashable, Identifiable {
    let itemID: String
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
    let type: MediaKind
    let duration: Int?
    private(set) var airings: [LiveAiring]

    var id: String {
        "\(itemID)-\(primaryAiring?.channelIdentifier ?? "unknown")-\(Int(primaryAiring?.beginsAt ?? 0))"
    }

    var primaryAiring: LiveAiring? {
        airings.first
    }

    /// One copy per airing. A grid item lists every airing of the program
    /// (simulcast subchannels, repeats), but the guide and player read the
    /// times and channel off `primaryAiring`, so each airing has to become
    /// its own program before it is filed under a channel.
    func splitByAiring() -> [LiveProgram] {
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

    init(
        itemID: String,
        key: String?,
        guid: String?,
        title: String,
        summary: String?,
        thumb: String?,
        art: String?,
        grandparentTitle: String?,
        parentTitle: String?,
        type: MediaKind,
        duration: Int?,
        airings: [LiveAiring]
    ) {
        self.itemID = itemID
        self.key = key
        self.guid = guid
        self.title = title
        self.summary = summary
        self.thumb = thumb
        self.art = art
        self.grandparentTitle = grandparentTitle
        self.parentTitle = parentTitle
        self.type = type
        self.duration = duration
        self.airings = airings
    }
}

struct LiveAiring: Sendable, Hashable {
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

    init(
        id: Int?,
        beginsAt: TimeInterval,
        endsAt: TimeInterval,
        channelID: Int?,
        channelIdentifier: String?,
        channelThumb: String?,
        channelTitle: String?,
        channelVCN: String?,
        channelCallSign: String?,
        gridKey: String?,
        videoResolution: String?
    ) {
        self.id = id
        self.beginsAt = beginsAt
        self.endsAt = endsAt
        self.channelID = channelID
        self.channelIdentifier = channelIdentifier
        self.channelThumb = channelThumb
        self.channelTitle = channelTitle
        self.channelVCN = channelVCN
        self.channelCallSign = channelCallSign
        self.gridKey = gridKey
        self.videoResolution = videoResolution
    }
}

struct LiveChannelGuide: Sendable, Hashable, Identifiable {
    let channel: LiveChannel
    let programs: [LiveProgram]

    var id: String { channel.id }

    func currentProgram(at date: Date = .now) -> LiveProgram? {
        programs.first { $0.isAiring(at: date) }
    }

    func nextProgram(after date: Date = .now) -> LiveProgram? {
        programs
            .filter { ($0.beginsAt ?? .distantPast) > date }
            .min { ($0.beginsAt ?? .distantFuture) < ($1.beginsAt ?? .distantFuture) }
    }
}

struct LiveTVLineup: Sendable, Hashable {
    let provider: LiveTVProvider
    let guides: [LiveChannelGuide]

    init(provider: LiveTVProvider, guides: [LiveChannelGuide]) {
        self.provider = provider
        self.guides = guides
    }

    var channels: [LiveChannel] {
        guides.map(\.channel)
    }

    func guide(for channel: LiveChannel) -> LiveChannelGuide? {
        guides.first { $0.channel.id == channel.id }
    }

    func channel(for program: LiveProgram) -> LiveChannel? {
        guides.first { $0.programs.contains(program) }?.channel
    }

    /// Keeps only programs that overlap `window`; channels stay listed (and
    /// tunable) even when nothing of theirs is left.
    func restricted(to window: LiveTVGuideWindow) -> LiveTVLineup {
        LiveTVLineup(
            provider: provider,
            guides: guides.map { guide in
                LiveChannelGuide(
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
    func contains(_ program: LiveProgram) -> Bool {
        guard let beginsAt = program.beginsAt, let endsAt = program.endsAt else { return true }
        return endsAt > start && beginsAt < end
    }
}

struct LivePlaybackContext: Sendable, Hashable {
    let lineup: LiveTVLineup
    let channel: LiveChannel
    let program: LiveProgram?
    let sessionID: String
    /// The key progress reports of this live session carry, as the server's
    /// tune gave it (`LiveTuneResult.reportKey`); nil for an IPTV channel,
    /// which reports nowhere.
    let sessionPath: String?

    /// The tuned channel's schedule. Refreshed during playback by
    /// `PlaybackCoordinator`, so it stays valid past the tuned program's end.
    var channelPrograms: [LiveProgram] {
        lineup.guide(for: channel)?.programs ?? []
    }

    func program(at date: Date) -> LiveProgram? {
        channelPrograms.first { $0.isAiring(at: date) }
    }

    /// Copy of this context carrying a fresh schedule for the tuned channel.
    /// Other channels keep their guides so the in-player channel list still
    /// shows what is on elsewhere.
    func replacingChannelPrograms(_ programs: [LiveProgram]) -> LivePlaybackContext {
        var guides = lineup.guides.map { guide in
            guide.channel.id == channel.id
                ? LiveChannelGuide(channel: guide.channel, programs: programs)
                : guide
        }
        if !guides.contains(where: { $0.channel.id == channel.id }) {
            guides.append(LiveChannelGuide(channel: channel, programs: programs))
        }
        return LivePlaybackContext(
            lineup: LiveTVLineup(provider: lineup.provider, guides: guides),
            channel: channel,
            program: programs.first { $0.isAiring() } ?? program,
            sessionID: sessionID,
            sessionPath: sessionPath
        )
    }
}

/// A tuned channel, ready to play (`LiveTVProviding.tune`).
struct LiveTuneResult: Sendable {
    /// The server the tuner session lives on. Live TV runs on one server at a
    /// time, and every follow-up call (stream URL, transcode ping/stop) has to
    /// go back to that same one.
    let serverID: String
    let sessionID: String
    /// What the session's progress reports name it by
    /// (`LivePlaybackContext.sessionPath`).
    let reportKey: String
    let playbackSessionIdentifier: String
    let transcodeSessionID: String?
    let playbackURL: URL
    let media: MediaVersion
    let part: MediaPart
    /// Playing the live session's own HLS (the tuner stream, copied), not a
    /// server transcode.
    var isDirectPlay = false
}
