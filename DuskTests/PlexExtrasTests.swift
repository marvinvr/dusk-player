import Foundation
import Testing
@testable import Dusk

@Suite("Plex extras")
struct PlexExtrasTests {
    /// Shape of `/library/metadata/{key}/extras` for local extras: clips with
    /// a numeric `extraType` and the same kind as a camelCase `subtype`.
    private let payload = """
    {
        "MediaContainer": {
            "size": 4,
            "Metadata": [
                { "ratingKey": "501", "key": "/library/metadata/501", "type": "clip",
                  "subtype": "trailer", "extraType": 1, "title": "Trailer", "duration": 134000,
                  "thumb": "/library/metadata/501/thumb/1" },
                { "ratingKey": "502", "key": "/library/metadata/502", "type": "clip",
                  "subtype": "behindTheScenes", "extraType": "5", "title": "Making Of", "duration": 1500000 },
                { "ratingKey": "503", "key": "/library/metadata/503", "type": "clip",
                  "subtype": "deletedScene", "title": "Alternate Ending" },
                { "ratingKey": "504", "key": "/library/metadata/504", "type": "movie",
                  "title": "Not an extra" }
            ]
        }
    }
    """

    private func decodeExtras() throws -> [Extra] {
        let data = Data(payload.utf8)
        let items = try JSONDecoder().decode(MetadataResponse<MediaItem>.self, from: data).MediaContainer.Metadata ?? []
        let fields = try JSONDecoder().decode(MetadataResponse<PlexExtraFieldsDTO>.self, from: data).MediaContainer.Metadata ?? []
        return PlexUserContentMapper.extras(items: items, fields: fields)
    }

    @Test func extrasKeepPlexOrderAndDropNonClips() throws {
        let extras = try decodeExtras()
        #expect(extras.map(\.item.itemID) == ["501", "502", "503"])
    }

    @Test func extraTypeDecodesFromNumberStringOrSubtype() throws {
        let extras = try decodeExtras()
        #expect(extras.map(\.kind) == [.trailer, .behindTheScenes, .deletedScene])
    }

    @Test func cardSubtitleNamesTheKindAndDuration() throws {
        let extras = try decodeExtras()
        // Titled "Trailer": the kind is not repeated.
        #expect(extras[0].cardSubtitle == "2 min")
        #expect(extras[1].cardSubtitle == "Behind the Scenes · 25 min")
        #expect(extras[2].cardSubtitle == "Deleted Scene")
    }

    @Test func unknownCodesFallBackToSubtypeOrNothing() {
        #expect(ExtraKind(extraType: 99, subtype: "featurette") == .featurette)
        #expect(ExtraKind(extraType: nil, subtype: "SHORT") == .short)
        #expect(ExtraKind(extraType: nil, subtype: "somethingNew") == nil)
        #expect(ExtraKind.other.label == "Extra")
    }
}
