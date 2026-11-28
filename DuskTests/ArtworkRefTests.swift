import Foundation
import Testing
@testable import Dusk

/// P0-04: artwork travels as `ArtworkRef`s; for Plex the locator is the path
/// the models always held, so every image URL is unchanged.
@Suite("Artwork refs")
struct ArtworkRefTests {
    @Test func aMissingPathIsNoRefButAnEmptyOneIsKept() {
        #expect(ArtworkRef(serverID: "a", path: nil) == nil)
        let empty = ArtworkRef(serverID: "a", path: "")
        #expect(empty?.locator == "")
        #expect(empty?.nonEmpty == nil)
        #expect(ArtworkRef(serverID: "a", path: "/t")?.nonEmpty?.locator == "/t")
    }

    @Test func itemArtworkStaysOnTheItemsServer() throws {
        let json = #"{"ratingKey":"7","key":"/library/metadata/7","type":"movie","title":"M","thumb":"/library/metadata/7/thumb/1","art":"/library/metadata/7/art/1"}"#
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "srv-b"
        let item = try decoder.decode(MediaItem.self, from: Data(json.utf8))
        #expect(item.artwork.poster == ArtworkRef(serverID: "srv-b", locator: "/library/metadata/7/thumb/1"))
        #expect(item.artwork.backdrop?.locator == "/library/metadata/7/art/1")
        #expect(item.preferredPoster == item.artwork.poster)
        #expect(item.preferredLandscape == item.artwork.backdrop)
        #expect(item.fallbackPoster == nil)
    }

    @Test func seasonFallsBackToItsShowPosterOnlyWhenItDiffers() {
        let show = ArtworkRef(serverID: "a", locator: "/show")
        var set = ArtworkSet(poster: ArtworkRef(serverID: "a", locator: "/season"), parentPoster: show)
        #expect(set.preferredPoster(for: .season)?.locator == "/season")
        #expect(set.fallbackPoster(for: .season) == show)
        set.poster = nil
        #expect(set.preferredPoster(for: .season) == show)
        #expect(set.fallbackPoster(for: .season) == nil)
    }
}
