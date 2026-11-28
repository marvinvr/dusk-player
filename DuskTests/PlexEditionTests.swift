import Foundation
import Testing
@testable import Dusk

/// Plex editions ("Director's Cut", "Extended") are separate items that share
/// the guid and external ids of the title they belong to.
@Suite("Plex editions")
struct PlexEditionTests {
    private static let guid = "plex://movie/5d7768244de0ee001fcc7fed"

    private func movie(
        server: String,
        ratingKey: String,
        edition: String? = nil,
        guid: String? = PlexEditionTests.guid,
        year: Int = 1982
    ) throws -> MediaItem {
        var fields: [String: Any] = [
            "ratingKey": ratingKey,
            "key": "/library/metadata/\(ratingKey)",
            "type": "movie",
            "title": "Blade Runner",
            "year": year,
            "Guid": [["id": "tmdb://78"], ["id": "imdb://tt0083658"]],
        ]
        if let guid { fields["guid"] = guid }
        if let edition { fields["editionTitle"] = edition }
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = server
        return try decoder.decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    // MARK: Decoding and display

    @Test func decodesEditionTitleOnItemsAndDetails() throws {
        let item = try movie(server: "a", ratingKey: "1", edition: "Director's Cut")
        #expect(item.editionTitle == "Director's Cut")

        let json = """
        { "ratingKey": "1", "key": "/library/metadata/1", "type": "movie",
          "title": "Blade Runner", "year": 1982, "editionTitle": "Final Cut" }
        """
        let details = try JSONDecoder().decode(MediaDetails.self, from: Data(json.utf8))
        #expect(details.editionTitle == "Final Cut")
    }

    @Test func blankEditionTitleReadsAsNoEdition() throws {
        #expect(try movie(server: "a", ratingKey: "1", edition: "  ").editionTitle == nil)
        #expect(try movie(server: "a", ratingKey: "1").editionTitle == nil)
    }

    @Test func subtitleCarriesTheEditionAfterTheYear() throws {
        let edition = try movie(server: "a", ratingKey: "1", edition: "Director's Cut")
        #expect(edition.standardPosterSubtitle == "1982 · Director's Cut")
        #expect(edition.hubPosterSubtitle == "1982 · Director's Cut")
        #expect(edition.continueWatchingDisplaySubtitle == "1982 · Director's Cut")

        let plain = try movie(server: "a", ratingKey: "2")
        #expect(plain.standardPosterSubtitle == "1982")
    }

    @Test func joinedWithEditionSkipsMissingParts() {
        #expect(MediaTextFormatter.joinedWithEdition("1982", edition: nil) == "1982")
        #expect(MediaTextFormatter.joinedWithEdition(nil, edition: "Extended") == "Extended")
        #expect(MediaTextFormatter.joinedWithEdition(nil, edition: nil) == nil)
    }

    // MARK: Content identity

    @Test func editionsOfOneTitleHaveDifferentContentKeys() throws {
        let theatrical = try movie(server: "a", ratingKey: "1")
        let directors = try movie(server: "a", ratingKey: "2", edition: "Director's Cut")
        let final = try movie(server: "a", ratingKey: "3", edition: "Final Cut")

        #expect(theatrical.contentKey != directors.contentKey)
        #expect(directors.contentKey != final.contentKey)
        #expect(directors.contentKey.isStrong)
    }

    @Test func sameEditionOnTwoServersStillMatches() throws {
        let onA = try movie(server: "a", ratingKey: "1", edition: "Director's Cut")
        // Typed by another owner: case and punctuation differ.
        let onB = try movie(server: "b", ratingKey: "9", edition: "directors cut")
        #expect(onA.contentKey == onB.contentKey)

        #expect(try movie(server: "a", ratingKey: "1").contentKey
            == movie(server: "b", ratingKey: "9").contentKey)
    }

    @Test func editionSeparatesExternalAndHeuristicKeysToo() throws {
        let external = try movie(server: "a", ratingKey: "1", edition: "Extended", guid: nil)
        let externalPlain = try movie(server: "a", ratingKey: "2", guid: nil)
        #expect(external.contentKey != externalPlain.contentKey)
        #expect(external.contentKey.isStrong)
    }

    // MARK: Multi-server merge

    @Test func mergeKeepsBothEditionsFromOneServer() throws {
        let serverA = [
            try movie(server: "a", ratingKey: "1"),
            try movie(server: "a", ratingKey: "2", edition: "Director's Cut"),
        ]
        let serverB = [try movie(server: "b", ratingKey: "9")]

        let merged = MediaItemMerge.interleave([serverA, serverB])

        #expect(merged.items.map(\.id) == [serverA[0].id, serverA[1].id])
    }

    @Test func anotherEditionIsNeverAPlaybackFallback() throws {
        let directorsOnA = try movie(server: "a", ratingKey: "2", edition: "Director's Cut")
        let theatricalOnB = try movie(server: "b", ratingKey: "9")
        let directorsOnB = try movie(server: "b", ratingKey: "10", edition: "Director's Cut")

        let alternates = MediaItemMerge.alternates(in: [[directorsOnA], [theatricalOnB, directorsOnB]])

        #expect(alternates[directorsOnA.contentKey] == [directorsOnA.id, directorsOnB.id])
        #expect(alternates[theatricalOnB.contentKey] == [theatricalOnB.id])
    }
}
