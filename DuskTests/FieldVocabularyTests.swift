import Foundation
import Testing
@testable import Dusk

/// P0-03: neutral field names over unchanged Plex keys, `DolbyVisionInfo`,
/// `ExternalIDs` and `ContentKey.native`.
@Suite("Field vocabulary")
struct FieldVocabularyTests {
    private func object(_ data: Data) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    @Test func partialDolbyVisionAndNumericKindRoundTrip() throws {
        let text = #"{"id":5,"streamType":1,"codec":"hevc","selected":true,"colorTrc":"smpte2084","DOVIProfile":8,"DOVIBLCompatID":1}"#
        let stream = try JSONDecoder().decode(MediaStream.self, from: Data(text.utf8))
        #expect(stream.kind == .video)
        #expect(stream.isServerSelected == true)
        #expect(stream.colorTransfer == "smpte2084")
        let dv = try #require(stream.dolbyVision)
        #expect(dv.present == nil)
        #expect(dv.profile == 8)
        #expect(dv.level == nil)
        #expect(dv.blCompatID == 1)
        #expect(try object(JSONEncoder().encode(stream)).isEqual(try object(Data(text.utf8))))
    }

    @Test func noDolbyVisionFieldsMeansNoInfo() throws {
        let text = #"{"id":6,"streamType":2,"codec":"eac3"}"#
        let stream = try JSONDecoder().decode(MediaStream.self, from: Data(text.utf8))
        #expect(stream.kind == .audio)
        #expect(stream.dolbyVision == nil)
        #expect(try object(JSONEncoder().encode(stream)).isEqual(try object(Data(text.utf8))))
    }

    @Test func presentOnlyIsKeptApartFromAProfile() throws {
        let stream = try JSONDecoder().decode(MediaStream.self, from: Data(#"{"id":7,"streamType":1,"DOVIPresent":1}"#.utf8))
        #expect(stream.dolbyVision?.present == true)
        #expect(stream.dolbyVision?.profile == nil)
    }

    @Test func externalIDsKeepServerOrderAndEveryValue() {
        let ids = ExternalIDs(uris: ["TMDB://abc", "imdb://tt1", "tmdb://42", "tvdb://", "tmdb://7"])
        #expect(ids.values(for: "tmdb") == ["abc", "42", "7"])
        #expect(ids.tmdb == "abc")
        #expect(ids.imdb == "tt1")
        #expect(ids.tvdb == nil)
    }

    @Test func watchlistTakesTheFirstNumericTMDBID() {
        let entry = WatchlistEntry(itemID: "1", guid: "plex://movie/x", type: .movie, title: "X",
                                   guids: [PlexGuid(id: "tmdb://abc"), PlexGuid(id: "tmdb://42")])
        #expect(entry.tmdbID == 42)
    }

    @Test func traktTakesTheFirstValueThatPassesItsFilter() throws {
        let entry = try #require(TraktHistoryMapper.entry(
            type: .movie, guid: nil,
            externalIDs: ExternalIDs(uris: ["imdb://nm1", "tmdb://x", "imdb://tt2", "tmdb://9"]),
            watchedAt: Date(timeIntervalSince1970: 0), profileID: "p"
        ))
        #expect(entry.ids == TraktIDs(imdb: "tt2", tmdb: 9))
    }

    @Test func contentKeyAppendsTheScalarGuidAfterTheArray() {
        let identity = MediaItemID(serverID: "a", itemID: "1")
        let fromArray = ContentKey.resolve(guid: "tmdb://1", externalIDs: ExternalIDs(uris: ["tmdb://2"]),
                                           type: .movie, title: "T", year: nil, identity: identity)
        #expect(fromArray == .external(provider: "tmdb", namespace: "movie", id: "2"))
        let fromScalar = ContentKey.resolve(guid: "imdb://tt3", externalIDs: ExternalIDs(),
                                            type: .movie, title: "T", year: nil, identity: identity)
        #expect(fromScalar == .external(provider: "imdb", namespace: "movie", id: "tt3"))
        let native = ContentKey.resolve(guid: "plex://movie/ABC", externalIDs: ExternalIDs(uris: ["tmdb://2"]),
                                        type: .movie, title: "T", year: nil, identity: identity)
        #expect(native == .native("plex://movie/abc"))
    }

    @Test func aliasesCarryEveryStrongKey() {
        let aliases = ContentKey.aliases(
            guid: "plex://movie/abc", externalIDs: ExternalIDs(uris: ["tmdb://2", "imdb://tt3", "local://9"]),
            type: .movie, edition: nil, isClip: false, identity: MediaItemID(serverID: "a", itemID: "1")
        )
        #expect(aliases == [
            .native("plex://movie/abc"),
            .external(provider: "tmdb", namespace: "movie", id: "2"),
            .external(provider: "imdb", namespace: "movie", id: "tt3"),
        ])
    }
}
