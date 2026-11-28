import Foundation
import Testing
@testable import Dusk

/// J-07 against a real Jellyfin server, gated like `JellyfinLiveTests`
/// (`TEST_RUNNER_DUSK_JELLYFIN_LIVE_*`). Writes only to the signed-in user's
/// own state: a throw-away "J07 live" playlist that is deleted again. The
/// collection expectations are the jellyfin-demo test data (05-plan T-0).
@MainActor
@Suite("Jellyfin playlists and collections live", .serialized, .enabled(if: JellyfinLiveConfig.current != nil, "no live server configured"))
struct JellyfinUserContentLiveTests {
    @Test(.timeLimit(.minutes(3)))
    func playlistsAndCollectionsAgainstLiveServer() async throws {
        let config = try #require(JellyfinLiveConfig.current)
        let password = try String(contentsOfFile: config.passwordFile, encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        let identity = JellyfinClientIdentity(
            device: "Dusk Tests", deviceID: "dusk-tests-\(UUID().uuidString.prefix(8).lowercased())", version: "0.0-test")
        let anonymous = JellyfinClient(baseURL: config.url, identity: identity)
        let auth = try await anonymous.send(JellyfinAPI.authenticateByName(username: config.user, password: password))
        let client = anonymous.signedIn(JellyfinCredentials(accessToken: auth.accessToken, userID: auth.user.id))
        let serverID = auth.serverID ?? ""
        let catalog = JellyfinCatalog(serverID: serverID, client: { client })
        let playlists = JellyfinPlaylists(serverID: serverID, client: { client })
        var created: Playlist?
        do {
            try await collections(catalog)
            try await crud(playlists, catalog: catalog, created: &created)
        } catch {
            if let created { _ = try? await playlists.delete(playlistID: created.itemID) }
            _ = try? await client.send(JellyfinAPI.logout())
            throw error
        }
        _ = try await client.send(JellyfinAPI.logout())
    }

    private func collections(_ catalog: JellyfinCatalog) async throws {
        let libraries = try await catalog.libraries()
        let movies = try #require(libraries.first { $0.title == "Movies" })
        let shorts = try #require(libraries.first { $0.title == "Shorts" })

        let inMovies = try await catalog.collections(libraryID: movies.key, start: 0, size: 50).items
        #expect(inMovies.map(\.title) == ["Blender Open Movies", "Weekend Watch"])
        let blender = try #require(inMovies.first)
        #expect(blender.collectionCountLabel == "5 movies")
        #expect(blender.thumb != nil, "a BoxSet without artwork borrows a title's poster")
        // Weekend Watch holds a show too, so it is listed in the TV library.
        let inShorts = try await catalog.collections(libraryID: shorts.key, start: 0, size: 50).items
        #expect(inShorts.map(\.title) == ["Weekend Watch"])
        // Libraries without a collected title list none.
        let paging = try #require(libraries.first { $0.title == "Paging Test" })
        #expect(try await catalog.collections(libraryID: paging.key, start: 0, size: 50).items.isEmpty)
        #expect(try await !catalog.filterFields(libraryID: paging.key, includesCollection: true).contains { $0.parameter == "collection" })
        let field = try #require(try await catalog.filterFields(libraryID: shorts.key, includesCollection: true)
            .first { $0.parameter == "collection" })
        #expect(try await catalog.filterChoices(for: field).map(\.title) == ["Weekend Watch"])
        let weekend = try await catalog.items(libraryID: shorts.key, kind: .show, start: 0, size: 50, sort: nil,
                                              filter: LibraryFilter(choices: ["collection": inShorts[0].itemID]))
        #expect(weekend.map(\.title) == ["Weekend Projects"])

        let page = try await catalog.collectionItems(collectionID: blender.itemID, start: 0, size: 2, sort: nil)
        #expect(page.totalSize == 5)
        #expect(page.items.map(\.title) == ["Elephants Dream", "Big Buck Bunny"])
        let sorted = try await catalog.collectionItems(collectionID: blender.itemID, start: 0, size: 5, sort: .titleDescending)
        #expect(sorted.items.first?.title == "Tears of Steel")

        let bunny = try #require(page.items.last)
        let partOf = try await catalog.collections(containing: bunny.itemID, libraryID: nil, tags: [])
        #expect(partOf.map(\.title) == ["Blender Open Movies", "Weekend Watch"])
        #expect(try await catalog.collection(itemID: blender.itemID)?.title == "Blender Open Movies")
    }

    private func crud(_ playlists: JellyfinPlaylists, catalog: JellyfinCatalog, created: inout Playlist?) async throws {
        let libraries = try await catalog.libraries()
        let movies = try #require(libraries.first { $0.title == "Movies" })
        let shorts = try #require(libraries.first { $0.title == "Shorts" })
        let films = try await catalog.items(libraryID: movies.key, kind: .movie, start: 0, size: 3,
                                            sort: .titleAscending, filter: LibraryFilter())
        try #require(films.count == 3)
        let show = try #require(try await catalog.items(libraryID: shorts.key, kind: .show, start: 0, size: 1,
                                                       sort: .titleAscending, filter: LibraryFilter()).first)
        let episodes = try await catalog.allEpisodes(showID: show.itemID)

        let playlist = try await playlists.createPlaylist(title: "J07 live \(UUID().uuidString.prefix(6))", itemIDs: [films[0].itemID, films[1].itemID])
        created = playlist
        #expect(playlist.episodeCount == 2)
        #expect(try await playlists.playlists().contains { $0.id == playlist.id })

        // A repeat is skipped; a show adds its episodes.
        let added = try await playlists.add(itemIDs: [films[0].itemID, films[2].itemID, show.itemID], to: playlist.itemID)
        #expect(added == PlaylistAddResult(added: 1 + episodes.count, requested: 2 + episodes.count))
        var entries = try await playlists.entries(playlistID: playlist.itemID)
        #expect(entries.map(\.item.itemID) == [films[0], films[1], films[2]].map(\.itemID) + episodes.map(\.itemID))

        // Move the first film after the third: [1, 2, 0, …].
        try await playlists.moveEntry(try #require(entries[0].playlistItemID), after: entries[2].playlistItemID, in: playlist.itemID)
        entries = try await playlists.entries(playlistID: playlist.itemID)
        #expect(Array(entries.prefix(3).map(\.item.itemID)) == [films[1], films[2], films[0]].map(\.itemID))
        try await playlists.moveEntry(try #require(entries[2].playlistItemID), after: nil, in: playlist.itemID)
        entries = try await playlists.entries(playlistID: playlist.itemID)
        #expect(entries.first?.item.itemID == films[0].itemID)

        try await playlists.removeEntry(try #require(entries[1].playlistItemID), from: playlist.itemID)
        entries = try await playlists.entries(playlistID: playlist.itemID)
        #expect(!entries.contains { $0.item.itemID == films[1].itemID })

        try await playlists.rename(playlistID: playlist.itemID, to: playlist.title + " renamed")
        #expect(try await playlists.playlist(id: playlist.itemID)?.title == playlist.title + " renamed")

        try await playlists.delete(playlistID: playlist.itemID)
        created = nil
        #expect(try await playlists.playlist(id: playlist.itemID) == nil)
    }
}
