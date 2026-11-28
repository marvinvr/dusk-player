import Foundation
import Testing
@testable import Dusk

/// Version, part, stream and marker ids are strings in the app but numbers
/// from Plex and in everything Dusk has persisted (P0-02). These pin both
/// directions with literal JSON.
@Suite("Media id coding")
struct MediaIDCodingTests {
    private func json(_ value: some Encodable) throws -> NSDictionary {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func object(_ text: String) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
    }

    @Test func numericIDsDecodeAndStayNumbers() throws {
        let text = #"{"id":41,"Part":[{"id":17,"key":"/library/parts/17/file.mkv","Stream":[{"id":104,"streamType":3,"codec":"srt"}]}]}"#
        let media = MediaVersion(plex: try JSONDecoder().decode(PlexMediaVersionDTO.self, from: Data(text.utf8)))
        #expect(media.id == "41")
        #expect(media.parts[0].id == "17")
        #expect(media.parts[0].streams[0].id == "104")
        #expect(try json(media).isEqual(try object(text)))
    }

    @Test func stringIDsDecodeAndStayStrings() throws {
        let text = #"{"id":"a1b2","Part":[{"id":"a1b2","key":"/Videos/a1b2/stream","Stream":[{"id":"3","streamType":2,"codec":"aac"},{"id":"x","streamType":3,"codec":"srt"}]}]}"#
        let media = MediaVersion(plex: try JSONDecoder().decode(PlexMediaVersionDTO.self, from: Data(text.utf8)))
        #expect(media.id == "a1b2")
        #expect(media.parts[0].streams.map(\.id) == ["3", "x"])
        // A canonical integer is written as a number, anything else as a string.
        let expected = #"{"id":"a1b2","Part":[{"id":"a1b2","key":"/Videos/a1b2/stream","Stream":[{"id":3,"streamType":2,"codec":"aac"},{"id":"x","streamType":3,"codec":"srt"}]}]}"#
        #expect(try json(media).isEqual(try object(expected)))
    }

    @Test(arguments: ["007", "-0", "+5", " 5", "12345678901234567890"])
    func nonCanonicalIntegersStayStrings(id: String) throws {
        let marker = Marker(id: id, type: "intro", startTimeOffset: 0, endTimeOffset: 1)
        #expect(try json(marker)["id"] as? String == id)
    }

    @Test func markersDecodeEitherForm() throws {
        let number = Marker(plex: try JSONDecoder().decode(PlexMarkerDTO.self, from: Data(#"{"id":7,"type":"credits","startTimeOffset":1,"endTimeOffset":2}"#.utf8)))
        let string = Marker(plex: try JSONDecoder().decode(PlexMarkerDTO.self, from: Data(#"{"id":"7","type":"credits","startTimeOffset":1,"endTimeOffset":2}"#.utf8)))
        #expect(number.id == "7")
        #expect(string.id == "7")
        #expect(try json(number)["id"] as? Int == 7)
        #expect(string.isEstimated == false)
        // The persisted path (offline metadata cache) decodes the same shape.
        #expect(try JSONDecoder().decode(Marker.self, from: try JSONEncoder().encode(number)) == number)
        #expect(Marker.estimatedCreditsID == "-1")
        #expect(try json(Marker(id: Marker.estimatedCreditsID, type: "credits", startTimeOffset: 0, endTimeOffset: 1))["id"] as? Int == -1)
    }

    private let recordJSON = #"""
        {"serverID":"srv","ratingKey":"1001","type":"movie","isClip":false,"title":"Arrival",
         "downloadQuality":"original","isSmartDownload":false,"preparationRetryCount":0,
         "hasMissingExternalSubtitles":false,"wasPausedForProfileSwitch":false,"status":"completed",
         "progress":1,"downloadedBytes":10,"addedAt":0,"updatedAt":0%@}
        """#

    private func record(_ extra: String) throws -> (DownloadedMediaRecord, String) {
        let text = recordJSON.replacingOccurrences(of: "%@", with: extra)
        return (try JSONDecoder().decode(DownloadedMediaRecord.self, from: Data(text.utf8)), text)
    }

    @Test func intKeyedDownloadRecordsDecodeAndReEncodeAsWritten() throws {
        let (record, text) = try record(#","mediaID":501,"partID":601,"externalSubtitlePaths":{"7001":"Subtitles/x/7001.srt"}"#)
        #expect(record.mediaID == "501")
        #expect(record.partID == "601")
        #expect(record.externalSubtitlePaths == ["7001": "Subtitles/x/7001.srt"])
        #expect(try json(record).isEqual(try object(text)))
    }

    @Test func absentIDsStayAbsent() throws {
        let (record, text) = try record("")
        #expect(record.mediaID == nil)
        #expect(record.partID == nil)
        let encoded = try json(record)
        #expect(encoded["mediaID"] == nil)
        #expect(encoded["partID"] == nil)
        #expect(encoded.isEqual(try object(text)))
    }

    @Test func stringKeyedDownloadRecordsDecode() throws {
        let (record, _) = try record(#","mediaID":"m1","partID":"p1""#)
        #expect(record.mediaID == "m1")
        #expect(try json(record)["partID"] as? String == "p1")
    }

    @Test func idOrderIsNumericForNumbers() {
        #expect(["10", "9", "x", "100"].sorted(by: mediaIDPrecedes) == ["9", "10", "100", "x"])
        #expect(["9", "10"].max(by: mediaIDPrecedes) == "10")
    }

    @Test func serverWithoutRecordIsPlex() {
        var registry = ServerRegistry()
        #expect(registry.kind(for: "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9") == .plex)
        #expect(registry.kind(for: nil) == .plex)
        registry.register(ServerRecord(kind: .jellyfin, accountID: "acc", name: "Home"), for: "jf")
        #expect(registry.kind(for: "jf") == .jellyfin)
    }
}
