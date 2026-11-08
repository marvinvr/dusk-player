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

    // A source that lists a programme it never published a replay of answers
    // the catch-up URL with a 404; the viewer reads why, not "URL not found".
    @Test func aRefusedReplaySaysWhyInTheServersWords() {
        let message = IPTVAsset.catchUpRefusalMessage(
            status: 404,
            body: "No published replay for this programme and channel\n"
        )
        #expect(message == "No published replay for this programme and channel.")
    }

    @Test func aRefusalWithoutASentenceFallsBackToTheStatus() {
        let fallback = "No replay is available for this program."
        #expect(IPTVAsset.catchUpRefusalMessage(status: 404, body: nil) == fallback)
        #expect(IPTVAsset.catchUpRefusalMessage(status: 404, body: "  ") == fallback)
        #expect(IPTVAsset.catchUpRefusalMessage(status: 410, body: "<html>gone</html>") == fallback)
        #expect(IPTVAsset.catchUpRefusalMessage(status: 404, body: "{\"error\":1}") == fallback)
        #expect(IPTVAsset.catchUpRefusalMessage(status: 404, body: "one\ntwo") == fallback)
        #expect(IPTVAsset.catchUpRefusalMessage(status: 404, body: String(repeating: "x", count: 201)) == fallback)
        #expect(IPTVAsset.catchUpRefusalMessage(status: 403, body: nil) == "The replay of this program was refused.")
        #expect(IPTVAsset.catchUpRefusalMessage(status: 503, body: nil)?.contains("503") == true)
    }

    @Test func aStatusThatExplainsNothingIsNotARefusal() {
        #expect(IPTVAsset.catchUpRefusalMessage(status: 200, body: "#EXTM3U") == nil)
        #expect(IPTVAsset.catchUpRefusalMessage(status: 302, body: nil) == nil)
    }

    @Test func aFailedReplayIsNotCalledAChannel() {
        #expect(IPTVAsset.failureMessage(for: nil, isCatchUp: true) == "This program couldn’t be played.")
        #expect(IPTVAsset.failureMessage(for: nil) == "This channel couldn’t be played.")
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

    // MARK: Collapsed gaps

    /// A sparse guide: one session two days back, one two days ahead.
    private func sparse(now: Date) throws -> (LiveTVGuideTimeline, PlexLiveChannelGuide) {
        let past = try program("past", from: now.addingTimeInterval(-48 * 3600), to: now.addingTimeInterval(-47 * 3600))
        let next = try program("next", from: now.addingTimeInterval(48 * 3600), to: now.addingTimeInterval(49 * 3600))
        let guide = PlexLiveChannelGuide(channel: channel, programs: [past, next])
        let lineup = PlexLiveTVLineup(
            provider: PlexLiveTVProvider(identifier: "p", providerIdentifier: "p", title: "P", dvrID: 1, gridKey: "/g"),
            guides: [guide]
        )
        let timeline = LiveTVGuideTimeline(
            window: LiveTVGuideTimeline.wholeGuideWindow(of: lineup, now: now),
            lineup: lineup, now: now, pointsPerMinute: 5, collapsedWidth: 100, collapsesTrailingGap: false
        )
        return (timeline, guide)
    }

    /// No filler entries at all: the empty days become markers either side
    /// of a to-scale stretch around now, and the row still tiles.
    @Test func emptyStretchesCollapseAroundNow() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let (timeline, guide) = try sparse(now: now)
        #expect(timeline.collapses.count == 2)
        #expect(timeline.contains(now))
        let compact: CGFloat = 100 * 2 + 5 * 60 * 3 + 1
        #expect(timeline.width < compact)

        let cells = LiveTVGuideSection.cells(for: guide, rowID: "r", timeline: timeline, now: now)
        #expect(cells.first?.program != nil)
        #expect(cells.last?.program != nil)
        let markers = cells.filter(\.isCollapsedGap)
        #expect(markers.count == 2)
        #expect(markers.allSatisfy { $0.program == nil })
        let live = try #require(cells.first { $0.isAiring(at: now) })
        #expect(live.program == nil)
        #expect(!live.isCollapsedGap)
    }

    @Test func positionsMapBothWaysAcrossACollapse() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let (timeline, _) = try sparse(now: now)
        for date in [timeline.start, now, timeline.end, now.addingTimeInterval(24 * 3600)] {
            #expect(abs(timeline.date(forX: timeline.x(for: date)).timeIntervalSince(date)) < 1)
        }
        let collapse = try #require(timeline.collapses.first)
        let markerWidth: CGFloat = timeline.x(for: collapse.end) - timeline.x(for: collapse.start)
        #expect(abs(markerWidth - 100) < 0.01)
    }

    @Test func aShortSilenceStaysToScale() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let earlier = try program("a", from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600))
        let later = try program("b", from: now.addingTimeInterval(3600 + 50 * 60), to: now.addingTimeInterval(3 * 3600))
        let lineup = PlexLiveTVLineup(
            provider: PlexLiveTVProvider(identifier: "p", providerIdentifier: "p", title: "P", dvrID: 1, gridKey: "/g"),
            guides: [PlexLiveChannelGuide(channel: channel, programs: [earlier, later])]
        )
        let timeline = LiveTVGuideTimeline(
            window: LiveTVGuideTimeline.wholeGuideWindow(of: lineup, now: now),
            lineup: lineup, now: now, pointsPerMinute: 5, collapsedWidth: 100, collapsesTrailingGap: false
        )
        #expect(timeline.collapses.isEmpty)
    }

    /// One channel without a guide must not become one long tunable cell.
    @Test func theLiveGapIsOnlyTheNowZone() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let timeline = LiveTVGuideTimeline(
            window: LiveTVGuideWindow(start: now, end: now.addingTimeInterval(12 * 3600)), pointsPerMinute: 5
        )
        let cells = LiveTVGuideSection.cells(
            for: PlexLiveChannelGuide(channel: channel, programs: []), rowID: "r", timeline: timeline, now: now
        )
        let live = try #require(cells.first { $0.isAiring(at: now) })
        #expect(live.end.timeIntervalSince(live.start) <= LiveTVGuideTimeline.nowZoneLength)
    }

    /// A step never moves more than the block's comfortable share plus margin,
    /// however long the next programme is.
    @Test func aStepScrollsOnlyAsFarAsItMust() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let start = LiveTVGuideTimeline.floorToTick(now)
        let short = try program("short", from: start, to: start.addingTimeInterval(1800))
        let long = try program("long", from: start.addingTimeInterval(1800), to: start.addingTimeInterval(6 * 3600))
        let timeline = LiveTVGuideTimeline(
            window: LiveTVGuideWindow(start: start, end: start.addingTimeInterval(8 * 3600)), pointsPerMinute: 5
        )
        let row = LiveTVGuideRow(
            id: "r", channel: channel,
            cells: LiveTVGuideSection.cells(
                for: PlexLiveChannelGuide(channel: channel, programs: [short, long]), rowID: "r", timeline: timeline, now: now
            )
        )
        var cursor = LiveTVGuideCursor(time: start)
        let viewport: CGFloat = 200
        let stepped = cursor.step(.next, in: row, timeline: timeline, viewport: viewport)
        #expect(stepped)
        let limit = viewport * (LiveTVGuideCursor.comfortableShare + LiveTVGuideCursor.marginShare)
        let longStart = try #require(long.beginsAt)
        let furthest: CGFloat = timeline.x(for: longStart) + limit - viewport + 0.01
        #expect(cursor.offset <= furthest)
        #expect(cursor.time >= longStart)
    }

    // The shape of a sports relay's guide: real sessions only, days apart, and
    // the same on every channel. Checked at every point of the week, so a now
    // inside a session, in a gap, on an edge or past the whole guide is covered.
    @Test func aSparseGuideLaysOutCleanlyAtEveryMoment() throws {
        let base = Date(timeIntervalSince1970: 1_793_000_000)
        let sessions: [(hours: Double, length: Double)] = [
            (0, 1.1), (1.2, 2), (3.2, 0.7), (97, 0.7), (116, 1.25), (120, 1.25), (139, 1.25), (142, 0.5), (143, 1.2), (144.2, 0.5), (164, 1.1), (165.2, 2), (167.2, 0.7),
        ]
        let channels = try (0..<4).map { index in
            PlexLiveChannelGuide(
                channel: PlexLiveChannel(iptvID: "c\(index)", number: nil, title: "C\(index)", logo: nil, playable: self.channel.iptv!),
                programs: try sessions.enumerated().map { number, session in
                    try program(
                        "\(index)-\(number)",
                        from: base.addingTimeInterval(session.hours * 3600),
                        to: base.addingTimeInterval((session.hours + session.length) * 3600)
                    )
                }
            )
        }
        let provider = PlexLiveTVProvider(identifier: "iptv:x", providerIdentifier: IPTVLineupBuilder.providerIdentifier, title: "x", dvrID: 0, gridKey: "", serverID: "x")
        let lineup = PlexLiveTVLineup(provider: provider, guides: channels)

        for hours in stride(from: -48.0, through: 216, by: 0.37) {
            let now = base.addingTimeInterval(hours * 3600)
            let window = LiveTVGuideTimeline.wholeGuideWindow(of: lineup, now: now)
            let timeline = LiveTVGuideTimeline(
                window: window, lineup: lineup, now: now,
                pointsPerMinute: 9, collapsedWidth: 136, collapsesTrailingGap: false
            )
            #expect(timeline.width.isFinite && timeline.width > 0)
            #expect(timeline.nowOffset(now) >= 0)
            let section = LiveTVGuideSection(id: "s", title: "s", lineup: lineup, timeline: timeline, now: now)
            for row in section.rows {
                var last = timeline.start
                for cell in row.cells {
                    #expect(cell.end > cell.start)
                    #expect(cell.start >= last)
                    #expect(timeline.x(for: cell.end) >= timeline.x(for: cell.start))
                    last = cell.end
                }
                #expect(Set(row.cells.map(\.id)).count == row.cells.count)

                var cursor = LiveTVGuideCursor(time: now)
                cursor.jumpToNow(now, timeline: timeline, viewport: 1500)
                for step in [LiveTVGuideCursor.Step.next, .previous] {
                    for _ in 0...row.cells.count where cursor.step(step, in: row, timeline: timeline, viewport: 1500) {
                        #expect(cursor.offset.isFinite && cursor.offset >= 0)
                    }
                }
            }
        }
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
