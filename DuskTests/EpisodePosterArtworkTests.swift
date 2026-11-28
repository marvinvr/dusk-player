import Foundation
import Testing
@testable import Dusk

/// Poster cards (Home rows, Continue Watching, Top Shelf) show an episode's
/// season poster, then the show's, so the art changes per season.
@Suite("Episode poster artwork")
struct EpisodePosterArtworkTests {
    private func item(_ fields: [String: Any]) throws -> MediaItem {
        var json: [String: Any] = ["ratingKey": "1", "key": "/library/metadata/1", "title": "Item"]
        json.merge(fields) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "server"
        return try decoder.decode(MediaItem.self, from: data)
    }

    @Test("An episode shows its season poster, the show poster stands by")
    func seasonPosterFirst() throws {
        let episode = try item([
            "type": "episode",
            "thumb": "/library/metadata/1/thumb/1",
            "parentThumb": "/library/metadata/20/thumb/2",
            "grandparentThumb": "/library/metadata/10/thumb/3",
        ])
        #expect(episode.preferredPosterPath == "/library/metadata/20/thumb/2")
        #expect(episode.fallbackPosterPath == "/library/metadata/10/thumb/3")
    }

    @Test("A season without its own poster lands on the show poster")
    func seasonWithoutPoster() throws {
        let inherited = try item([
            "type": "episode",
            "thumb": "/library/metadata/1/thumb/1",
            "parentThumb": "/library/metadata/10/thumb/3",
            "grandparentThumb": "/library/metadata/10/thumb/3",
        ])
        #expect(inherited.preferredPosterPath == "/library/metadata/10/thumb/3")
        #expect(inherited.fallbackPosterPath == nil)

        for parentThumb: Any in [NSNull(), ""] {
            let missing = try item([
                "type": "episode",
                "thumb": "/library/metadata/1/thumb/1",
                "parentThumb": parentThumb,
                "grandparentThumb": "/library/metadata/10/thumb/3",
            ])
            #expect(missing.preferredPosterPath == "/library/metadata/10/thumb/3")
            #expect(missing.fallbackPosterPath == nil)
        }
    }

    @Test("Without season or show art the episode still is the last resort")
    func stillLastResort() throws {
        let episode = try item(["type": "episode", "thumb": "/library/metadata/1/thumb/1"])
        #expect(episode.preferredPosterPath == "/library/metadata/1/thumb/1")
        #expect(episode.fallbackPosterPath == nil)
    }

    @Test("Seasons keep their own poster with the show's as fallback")
    func seasonsUnchanged() throws {
        let season = try item([
            "type": "season",
            "thumb": "/library/metadata/20/thumb/2",
            "parentThumb": "/library/metadata/10/thumb/3",
        ])
        #expect(season.preferredPosterPath == "/library/metadata/20/thumb/2")
        #expect(season.fallbackPosterPath == "/library/metadata/10/thumb/3")
        #expect(try item(["type": "movie", "thumb": "/m"]).fallbackPosterPath == nil)
    }
}
