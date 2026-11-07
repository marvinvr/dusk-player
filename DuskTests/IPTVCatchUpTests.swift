import Foundation
import Testing
@testable import Dusk

@Suite("IPTV catch-up")
struct IPTVCatchUpTests {
    private let start = Date(timeIntervalSince1970: 1_793_000_000)
    private var end: Date { start.addingTimeInterval(3600) }
    private var now: Date { start.addingTimeInterval(2 * 3600) }

    private func entry(_ extinf: String, url: String = "https://tv.example/live/1.m3u8", header: String = "#EXTM3U") throws -> IPTVPlaylistEntry {
        let playlist = M3UParser.parse("\(header)\n#EXTINF:-1 \(extinf),Channel\n\(url)\n")
        return try #require(playlist.entries.first)
    }

    @Test func readsTheSharedContract() throws {
        let entry = try entry(#"tvg-id="a" catchup="default" catchup-days="7" catchup-source="https://relay.example/catchup/a.m3u8?start={utc}&end={utcend}&d={duration}""#)
        let catchUp = try #require(entry.catchUp)
        #expect(catchUp.mode == .default)
        #expect(catchUp.days == 7)
        let url = catchUp.url(streamURL: entry.streamURL, start: start, end: end, now: now)
        #expect(url?.absoluteString == "https://relay.example/catchup/a.m3u8?start=1793000000&end=1793003600&d=3600")
    }

    @Test func dollarAndFormattedPlaceholders() {
        let filled = IPTVCatchUp.fill(
            "https://x/${start}-${end}/{utc:Y-m-d H:M:S}/{Y}{m}{d}{H}{M}/{duration:60}/{lutc}/{offset:1}/{unknown}",
            start: start, end: end, now: now
        )
        // 1793000000 = 2026-10-26 07:33:20 UTC
        #expect(filled == "https://x/1793000000-1793003600/2026-10-26 07:33:20/202610260733/60/1793007200/7200/{unknown}")
    }

    @Test func appendAndShiftModes() throws {
        let append = try entry(#"catchup="append" catchup-source="?utc={utc}&lutc={lutc}""#)
        #expect(append.catchUp?.url(streamURL: append.streamURL, start: start, end: end, now: now)?.absoluteString
            == "https://tv.example/live/1.m3u8?utc=1793000000&lutc=1793007200")

        let shift = try entry(#"catchup="shift" catchup-days="3""#, url: "https://tv.example/live/1.m3u8?token=t")
        #expect(shift.catchUp?.days == 3)
        #expect(shift.catchUp?.url(streamURL: shift.streamURL, start: start, end: end, now: now)?.absoluteString
            == "https://tv.example/live/1.m3u8?token=t&utc=1793000000&lutc=1793007200")
    }

    @Test func unknownModesAndIncompleteEntriesHaveNoCatchUp() throws {
        #expect(try entry(#"catchup="flussonic" catchup-days="3""#).catchUp == nil)
        #expect(try entry(#"catchup="xc""#).catchUp == nil)
        #expect(try entry(#"catchup="default""#).catchUp == nil)
        #expect(try entry(#"catchup="append""#).catchUp == nil)
        #expect(try entry(#"tvg-id="a""#).catchUp == nil)
        #expect(try entry(#"catchup="default" catchup-days="0" catchup-source="https://x/{utc}""#).catchUp == nil)
    }

    @Test func playlistHeaderDefaultsApplyAndDaysDefault() throws {
        let entry = try entry(#"tvg-id="a""#, header: #"#EXTM3U catchup="default" catchup-source="https://x/{utc}""#)
        #expect(entry.catchUp?.mode == .default)
        #expect(entry.catchUp?.days == IPTVCatchUp.defaultDays)
    }

    @Test func availabilityNeedsAnEndedProgrammeInsideTheWindow() {
        let catchUp = IPTVCatchUp(mode: .default, days: 1, source: "https://x/{utc}")
        #expect(catchUp.isAvailable(start: start, end: end, now: now))
        // Still airing.
        #expect(!catchUp.isAvailable(start: start, end: end, now: start.addingTimeInterval(60)))
        // Older than the window.
        #expect(!catchUp.isAvailable(start: start, end: end, now: start.addingTimeInterval(2 * 86_400)))
    }

    @Test func catchUpStreamKeepsHeadersAndDRM() throws {
        let drm = IPTVDRMConfiguration(licenseType: "com.apple.fps", licenseURL: URL(string: "https://lic.example/fps"), certificateURL: nil)
        let live = IPTVPlayableChannel(
            sourceID: UUID(),
            streamURL: URL(string: "https://tv.example/live/1.m3u8")!,
            headers: ["Authorization": "Bearer t"],
            userAgent: "UA",
            drm: drm,
            catchUp: IPTVCatchUp(mode: .default, days: 7, source: "https://tv.example/catchup/1.m3u8?start={utc}&end={utcend}")
        )
        let replay = try #require(live.catchUpStream(start: start, end: end, now: now))
        #expect(replay.isCatchUp)
        #expect(replay.streamURL.absoluteString == "https://tv.example/catchup/1.m3u8?start=1793000000&end=1793003600")
        #expect(replay.headers == live.headers)
        #expect(replay.userAgent == "UA")
        #expect(replay.drm == drm)
        #expect(live.catchUpStream(start: start, end: end, now: start) == nil)
    }

    @Test func guideWindowReachesBackOverTheCatchUpDays() {
        let window = IPTVSourceLoader.guideWindow(catchUpDays: 7, now: now)
        #expect(window.lowerBound <= now.addingTimeInterval(-7 * 86_400))
        let plain = IPTVSourceLoader.guideWindow(catchUpDays: 0, now: now)
        #expect(plain.lowerBound <= now.addingTimeInterval(-24 * 3600))
        #expect(plain.lowerBound > now.addingTimeInterval(-2 * 86_400))
    }
}

@Suite("Live TV guide catch-up")
struct LiveTVGuideCatchUpTests {
    private func program(_ title: String, from begin: Date, to end: Date) throws -> PlexLiveProgram {
        try JSONDecoder().decode(PlexLiveProgram.self, from: Data("""
        { "ratingKey": "\(title)", "title": "\(title)", "guid": "plex://episode/\(title)",
          "Media": [{ "beginsAt": \(Int(begin.timeIntervalSince1970)), "endsAt": \(Int(end.timeIntervalSince1970)), "gridKey": "g1" }] }
        """.utf8))
    }

    private let channel = PlexLiveChannel(
        iptvID: "c1", number: "1", title: "One", logo: nil,
        playable: IPTVPlayableChannel(sourceID: UUID(), streamURL: URL(string: "https://x/1")!, headers: [:], userAgent: nil, drm: nil)
    )

    @Test func decodesTheGuid() throws {
        let program = try program("a", from: .now, to: .now.addingTimeInterval(60))
        #expect(program.guid == "plex://episode/a")
    }

    @Test func endedCellsAreReplayableOnlyWhenAsked() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let past = try program("past", from: now.addingTimeInterval(-7200), to: now.addingTimeInterval(-3600))
        let live = try program("live", from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600))
        let guide = PlexLiveChannelGuide(channel: channel, programs: [past, live])
        let timeline = LiveTVGuideTimeline(
            window: LiveTVGuideWindow(start: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(3 * 3600)),
            pointsPerMinute: 5
        )
        let cells = LiveTVGuideSection.cells(for: guide, rowID: "r", timeline: timeline, now: now) { _, _ in true }
        let programmes = cells.filter { $0.program != nil }
        #expect(programmes.map(\.isReplayable) == [true, false])
        #expect(programmes[0].hasEnded(at: now))
    }

    @Test func gridOpensOnNowAndCrossesDays() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let timeline = LiveTVGuideTimeline(
            window: LiveTVGuideWindow(start: now.addingTimeInterval(-6 * 3600), end: now.addingTimeInterval(6 * 3600)),
            pointsPerMinute: 5
        )
        var cursor = LiveTVGuideCursor(time: now)
        cursor.jumpToNow(now, timeline: timeline, viewport: 600)
        #expect(cursor.time == now)
        #expect(cursor.offset > 0)
        #expect(timeline.date(forX: cursor.offset) <= now.addingTimeInterval(-LiveTVGuideTimeline.nowLeadIn))

        let past = try program("past", from: timeline.start, to: timeline.start.addingTimeInterval(3600))
        let row = LiveTVGuideRow(
            id: "r", channel: channel,
            cells: LiveTVGuideSection.cells(
                for: PlexLiveChannelGuide(channel: channel, programs: [past]), rowID: "r", timeline: timeline, now: now
            )
        )
        #expect(LiveTVGuideCursor.crossingTime(.previous, in: row, timeline: timeline) < timeline.start)

        // Following a rolled timeline keeps the leading time.
        let leading = timeline.date(forX: cursor.offset)
        let rolled = LiveTVGuideTimeline(
            window: LiveTVGuideWindow(start: timeline.start.addingTimeInterval(1800), end: timeline.end.addingTimeInterval(1800)),
            pointsPerMinute: 5
        )
        cursor.follow(from: timeline, to: rolled, viewport: 600)
        #expect(abs(rolled.date(forX: cursor.offset).timeIntervalSince(leading)) < 1)
    }

    @Test func pastDaysAreWholeDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 20))!
        let window = LiveTVGuideWindow.forDayOffset(-1, now: now, calendar: calendar)
        #expect(window.start == calendar.date(from: DateComponents(year: 2026, month: 11, day: 6)))
        #expect(window.end == calendar.date(from: DateComponents(year: 2026, month: 11, day: 7)))
    }
}
