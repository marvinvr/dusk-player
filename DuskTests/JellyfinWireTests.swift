import Foundation
import Testing
@testable import Dusk

/// Ticks, dates, ids and open enums (docs/jellyfin/03-prior-art.md §10.3).
@Suite("Jellyfin wire values")
struct JellyfinWireTests {
    private struct Box<T: Decodable>: Decodable {
        let value: T?
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T? {
        try JSONDecoder().decode(Box<T>.self, from: Data(#"{"value": \#(json)}"#.utf8)).value
    }

    // MARK: Dates

    @Test(arguments: [
        ("2026-06-18T11:06:59.8066228Z", 1_781_780_819.8066228),
        ("2026-11-27T20:30:03.430036Z", 1_795_811_403.430036),
        ("2019-11-27T00:00:00.0000000Z", 1_574_812_800.0),
        ("2019-11-27T00:00:00Z", 1_574_812_800.0),
        ("2019-11-27T00:00:00", 1_574_812_800.0),
        ("2019-11-27", 1_574_812_800.0),
        ("2019-11-27T01:30:00+01:30", 1_574_812_800.0),
        ("2019-11-26T19:00:00-0500", 1_574_812_800.0),
        ("2019-11-27T02:00:00.5+02", 1_574_812_800.5),
        ("1968-03-01T23:00:00.0000000Z", -57_891_600.0),
        ("0001-01-01T00:00:00.0000000Z", -62_135_596_800.0),
    ])
    func parsesServerDates(_ text: String, _ epoch: Double) throws {
        let date = try #require(JellyfinDate.parse(text))
        #expect(abs(date.timeIntervalSince1970 - epoch) < 0.000_001)
    }

    @Test(arguments: ["", "garbage", "2019-13-01", "2019-11-27T", "2019-11-27T25:00:00Z",
                      "2019-11-27T10:00:00.Z", "2019-11-27T10:00:00Zjunk", "19-11-27", "2019/11/27"])
    func rejectsMalformedDates(_ text: String) {
        #expect(JellyfinDate.parse(text) == nil)
    }

    @Test func malformedDatesNeverFailTheDocument() throws {
        #expect(try decode(JellyfinDate.self, #""not a date""#)?.date == nil)
        #expect(try decode(JellyfinDate.self, #""not a date""#)?.raw == "not a date")
        #expect(try decode(JellyfinDate.self, "12345")?.date == nil)
        #expect(try decode(JellyfinDate.self, "null") == nil)
        let ok = try decode(JellyfinDate.self, #""2026-06-18T11:06:59.8066228Z""#)
        #expect(ok?.raw == "2026-06-18T11:06:59.8066228Z")
        #expect(ok?.date != nil)
    }

    @Test func formatsLikeTheServer() throws {
        // Exactly representable, so the seventh digit is not a rounding artefact.
        let date = Date(timeIntervalSince1970: 1_781_780_819.5)
        let text = JellyfinDate.format(date)
        #expect(text == "2026-06-18T11:06:59.5000000Z")
        #expect(JellyfinDate(date).raw == text)
        #expect(JellyfinDate.format(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.0000000Z")
        #expect(JellyfinDate.format(Date(timeIntervalSince1970: -57_891_600)) == "1968-03-01T23:00:00.0000000Z")
        let round = try #require(JellyfinDate.parse(JellyfinDate.format(date)))
        #expect(abs(round.timeIntervalSince(date)) < 0.000_001)
    }

    // MARK: Ticks

    @Test func ticksConvert() {
        let ticks = JellyfinTicks(78_172_470_000)
        #expect(ticks.milliseconds == 7_817_247)
        #expect(abs(ticks.seconds - 7_817.247) < 0.000_001)
        #expect(JellyfinTicks(milliseconds: 309_469).rawValue == 3_094_690_000)
        #expect(JellyfinTicks(seconds: 54.555).rawValue == 545_550_000)
        #expect(JellyfinTicks(seconds: .nan).rawValue == 0)
        // A 3 h film is past Int32.
        #expect(JellyfinTicks(milliseconds: 3 * 3_600_000).rawValue == 108_000_000_000)
        #expect(JellyfinTicks(5_000) < JellyfinTicks(5_001))
        #expect(JellyfinTicks(4_999).milliseconds == 0)
        #expect(JellyfinTicks(5_000).milliseconds == 1, "rounded, not truncated")
    }

    @Test func ticksDecodeTolerantly() throws {
        #expect(try decode(JellyfinTicks.self, "108000000000")?.rawValue == 108_000_000_000)
        #expect(try decode(JellyfinTicks.self, "1.08e11")?.rawValue == 108_000_000_000)
        #expect(try decode(JellyfinTicks.self, #""545550000""#)?.rawValue == 545_550_000)
        #expect(try decode(JellyfinTicks.self, #""soon""#)?.rawValue == 0)
        #expect(try decode(JellyfinTicks.self, "true")?.rawValue == 0)
        #expect(try decode(JellyfinTicks.self, "null") == nil)
        let encoded = try JSONEncoder().encode(JellyfinTicks(123))
        #expect(String(decoding: encoded, as: UTF8.self) == "123")
    }

    // MARK: Ids and enums

    @Test func idsNormalise() {
        #expect(JellyfinID.normalized("980dffd6-dfa0-d8cf-d69e-5bd6b350e983") == "980dffd6dfa0d8cfd69e5bd6b350e983")
        #expect(JellyfinID.normalized("980DFFD6DFA0D8CFD69E5BD6B350E983") == "980dffd6dfa0d8cfd69e5bd6b350e983")
        #expect(JellyfinID.same("980dffd6-dfa0-d8cf-d69e-5bd6b350e983", "980dffd6dfa0d8cfd69e5bd6b350e983"))
        #expect(!JellyfinID.same("980dffd6dfa0d8cfd69e5bd6b350e983", "64affd1220e9438c4d1d3cb12aaa2d84"))
    }

    @Test func openEnumsKeepUnknownValues() throws {
        #expect(try decode(JellyfinItemKind.self, #""Movie""#) == .movie)
        let future = try #require(try decode(JellyfinVideoRangeType.self, #""DOVIWithFutureThing""#))
        #expect(future.rawValue == "DOVIWithFutureThing")
        #expect(future != .dovi)
        #expect(try decode(JellyfinStreamType.self, "7")?.rawValue == "")
        #expect(JellyfinItemKind(rawValue: "boxset").matches(.boxSet))
        #expect(!JellyfinItemKind(rawValue: "boxset").matches(.movie))
        let encoded = try JSONEncoder().encode([JellyfinMediaSegmentType.outro])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["Outro"]"#)
    }

    @Test func transcodeReasonsSplit() throws {
        #expect(JellyfinTranscodeReason.list("ContainerNotSupported, AudioCodecNotSupported")
            == [.containerNotSupported, .audioCodecNotSupported])
        #expect(JellyfinTranscodeReason.list(nil).isEmpty)
        #expect(JellyfinTranscodeReason.list("").isEmpty)

        let array = try JSONDecoder().decode(JellyfinTranscodingInfoDTO.self, from: Data(
            #"{"IsVideoDirect": true, "IsAudioDirect": false, "TranscodeReasons": ["ContainerNotSupported"]}"#.utf8))
        #expect(array.isVideoDirect == true && array.isAudioDirect == false)
        #expect(array.transcodeReasons == [.containerNotSupported])
        let string = try JSONDecoder().decode(JellyfinTranscodingInfoDTO.self, from: Data(
            #"{"TranscodeReasons": "ContainerNotSupported,VideoRangeTypeNotSupported"}"#.utf8))
        #expect(string.transcodeReasons == [.containerNotSupported, .videoRangeTypeNotSupported])
        let none = try JSONDecoder().decode(JellyfinTranscodingInfoDTO.self, from: Data("{}".utf8))
        #expect(none.transcodeReasons.isEmpty)
    }
}
