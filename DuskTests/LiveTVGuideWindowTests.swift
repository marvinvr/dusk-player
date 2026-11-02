import Foundation
import Testing
@testable import Dusk

/// Issue #17: the tvOS guide opened on an old day and late in the evening
/// showed only the hour left before midnight.
@Suite("Live TV guide window")
struct LiveTVGuideWindowTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func program(_ title: String, from begin: Date, to end: Date) throws -> PlexLiveProgram {
        try JSONDecoder().decode(PlexLiveProgram.self, from: Data("""
        { "ratingKey": "\(title)", "title": "\(title)",
          "Media": [{ "beginsAt": \(Int(begin.timeIntervalSince1970)), "endsAt": \(Int(end.timeIntervalSince1970)), "gridKey": "g1" }] }
        """.utf8))
    }

    @Test func nowStartsAtNowAndLooksAheadAcrossMidnight() {
        let now = date(2, 23, 10)
        let window = LiveTVGuideWindow.forDayOffset(0, now: now, calendar: calendar)

        #expect(window.start == now)
        #expect(window.end == now.addingTimeInterval(LiveTVGuideWindow.lookahead))
        #expect(window.gridDays(calendar: calendar) == [date(2, 0), date(3, 0)])
    }

    @Test func nowInTheMorningAsksForOneDay() {
        let window = LiveTVGuideWindow.forDayOffset(0, now: date(2, 8), calendar: calendar)

        #expect(window.gridDays(calendar: calendar) == [date(2, 0)])
    }

    @Test func laterDayIsMidnightToMidnight() {
        let window = LiveTVGuideWindow.forDayOffset(2, now: date(2, 23, 10), calendar: calendar)

        #expect(window.start == date(4, 0))
        #expect(window.end == date(5, 0))
        #expect(window.gridDays(calendar: calendar) == [date(4, 0)])
    }

    /// The day follows the clock, not the day the guide was first opened.
    @Test func offsetIsRelativeToTheCurrentDay() {
        let first = LiveTVGuideWindow.forDayOffset(1, now: date(2, 12), calendar: calendar)
        let later = LiveTVGuideWindow.forDayOffset(1, now: date(4, 12), calendar: calendar)

        #expect(first.start == date(3, 0))
        #expect(later.start == date(5, 0))
    }

    @Test func restrictionDropsEndedAndOutOfWindowPrograms() throws {
        let now = date(2, 20, 30)
        let window = LiveTVGuideWindow.forDayOffset(0, now: now, calendar: calendar)
        let channels = try JSONDecoder().decode([PlexLiveChannel].self, from: Data("""
        [{ "id": "c1", "gridKey": "g1" }]
        """.utf8))
        let programs = try [
            program("ended", from: date(2, 19), to: date(2, 20)),
            program("airing", from: date(2, 20), to: date(2, 21)),
            program("tonight", from: date(2, 23), to: date(3, 1)),
            program("tooLate", from: date(3, 9), to: date(3, 10)),
        ]
        let lineup = PlexLiveTVLineup(
            provider: PlexLiveTVProvider(
                identifier: "p", providerIdentifier: "p", title: "Live TV", dvrID: 1, gridKey: "/grid"
            ),
            channels: channels,
            programs: programs
        )

        let restricted = lineup.restricted(to: window)

        #expect(restricted.guides.map { $0.programs.map(\.title) } == [["airing", "tonight"]])
        #expect(restricted.guides.first?.currentProgram(at: now)?.title == "airing")
    }

    /// A program spanning midnight comes back from both days' grids; it must
    /// be listed once.
    @Test func midnightSpanningProgramFromTwoGridsIsListedOnce() throws {
        let spanning = try program("late", from: date(2, 23), to: date(3, 1))
        let channels = try JSONDecoder().decode([PlexLiveChannel].self, from: Data("""
        [{ "id": "c1", "gridKey": "g1" }]
        """.utf8))
        let lineup = PlexLiveTVLineup(
            provider: PlexLiveTVProvider(
                identifier: "p", providerIdentifier: "p", title: "Live TV", dvrID: 1, gridKey: "/grid"
            ),
            channels: channels,
            programs: [spanning, spanning]
        )

        #expect(lineup.guides.first?.programs.count == 1)
    }
}
