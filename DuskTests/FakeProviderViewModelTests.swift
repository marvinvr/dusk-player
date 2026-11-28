import Foundation
import Testing
@testable import Dusk

/// The testing seam (docs/jellyfin/04-architecture.md §5.5, 05-plan.md P0-19):
/// a real view model over a real `MediaService`, its server registered as a
/// non-Plex kind and served by `FakeMediaServerProvider`. The data on screen
/// must be the fake's, and nothing may reach the network.
@Suite("Fake provider view models", .serialized)
@MainActor
struct FakeProviderViewModelTests {
    private func makeService(_ fake: FakeMediaServerProvider) -> MediaService {
        MediaService(
            urlProtocolClasses: [FakeNetworkRecorder.self],
            serverRegistry: ServerRegistry(records: [
                fake.descriptor.id: ServerRecord(kind: fake.descriptor.kind, accountID: nil, name: fake.descriptor.name),
            ]),
            additionalProviderFactories: [FakeProviderFactory(provider: fake)]
        )
    }

    private func tearDown(_ service: MediaService, serverID: String) {
        ServerPool.forget(serverID: serverID)
        service.session.invalidateAndCancel()
        service.slowQuerySession.invalidateAndCancel()
        service.probeSession.invalidateAndCancel()
        service.bootstrapSession.invalidateAndCancel()
    }

    @Test func seasonPageShowsTheFakesEpisodesAndWritesWatchedStateToIt() async throws {
        let serverID = "fake-\(UUID().uuidString)"
        let fake = FakeMediaServerProvider(serverID: serverID)
        fake.details["season-1"] = FakeMedia.details(
            serverID: serverID, itemID: "season-1", type: .season, title: "Season 1",
            index: 1, parentID: "show-1", grandparentTitle: "Fake Show",
            episodeCount: 2, watchedEpisodeCount: 1
        )
        // Out of order on purpose: the page sorts by episode number.
        fake.episodes["season-1"] = [
            FakeMedia.episode(serverID: serverID, itemID: "ep-2", title: "The Second", index: 2,
                              seasonID: "season-1", showID: "show-1", showTitle: "Fake Show"),
            FakeMedia.episode(serverID: serverID, itemID: "ep-1", title: "The First", index: 1,
                              seasonID: "season-1", showID: "show-1", showTitle: "Fake Show", playCount: 1),
        ]
        fake.details["ep-2"] = FakeMedia.details(
            serverID: serverID, itemID: "ep-2", type: .episode, title: "The Second",
            index: 2, parentIndex: 1, parentID: "season-1", grandparentID: "show-1",
            grandparentTitle: "Fake Show", duration: 1_800_000
        )
        let service = makeService(fake)
        defer { tearDown(service, serverID: serverID) }
        #expect(service.serverProvider(for: serverID) === fake)

        let model = SeasonDetailViewModel(id: MediaItemID(serverID: serverID, itemID: "season-1"), media: service)
        await model.load()

        #expect(model.error == nil)
        #expect(model.details?.title == "Season 1")
        #expect(model.showTitle == "Fake Show")
        #expect(model.episodes.map(\.itemID) == ["ep-1", "ep-2"])
        #expect(model.nextEpisodeToPlay?.itemID == "ep-2")
        #expect(model.nextEpisodeDetails?.title == "The Second")
        #expect(model.playButtonLabel == "Play · Episode 2")

        let unwatched = try #require(model.episodes.last)
        await model.toggleWatched(for: unwatched)
        #expect(model.error == nil)
        #expect(fake.watchedWrites == [
            .init(item: MediaItemID(serverID: serverID, itemID: "ep-2"), watched: true),
        ])
        #expect(fake.calls.contains("episodes(seasonID:)"))
        #expect(FakeNetworkRecorder.requests.isEmpty, "\(FakeNetworkRecorder.requests)")
    }

    @Test func playlistPageShowsTheFakesPlaylistAndEntries() async throws {
        let serverID = "fake-\(UUID().uuidString)"
        let fake = FakeMediaServerProvider(serverID: serverID)
        fake.allPlaylists = [Playlist(serverID: serverID, itemID: "playlist-1", title: "Road Trip", episodeCount: 2)]
        fake.playlistEntries["playlist-1"] = [
            PlaylistEntry(playlistItemID: 11, item: FakeMedia.item(
                serverID: serverID, itemID: "movie-1", type: .movie, title: "A Movie",
                duration: 6_000_000, playCount: 1
            )),
            PlaylistEntry(playlistItemID: 12, item: FakeMedia.item(
                serverID: serverID, itemID: "ep-9", type: .episode, title: "An Episode",
                index: 9, parentIndex: 1, grandparentTitle: "Fake Show",
                duration: 1_800_000, resumeOffsetMs: 600_000
            )),
        ]
        let service = makeService(fake)
        defer { tearDown(service, serverID: serverID) }

        let model = PlaylistDetailViewModel(id: MediaItemID(serverID: serverID, itemID: "playlist-1"), media: service)
        #expect(model.playlist == nil, "the store starts empty, so load asks the server")
        await model.load()

        #expect(model.error == nil)
        #expect(model.title == "Road Trip")
        #expect(model.canEdit)
        #expect(model.hasLoadedEntries)
        #expect(model.entries.map(\.playlistItemID) == [11, 12])
        #expect(model.entries.map(\.item.title) == ["A Movie", "An Episode"])
        #expect(model.canPlay)
        #expect(model.playButtonTitle == "Resume")
        #expect(fake.calls == ["playlist(id:)", "entries(playlistID:)"])
        #expect(FakeNetworkRecorder.requests.isEmpty, "\(FakeNetworkRecorder.requests)")
    }
}
