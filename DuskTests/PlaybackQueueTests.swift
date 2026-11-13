import Foundation
import Testing
@testable import Dusk

@Suite("Playback queue")
struct PlaybackQueueTests {
    private let playlistID = PlexItemID(serverID: "srv", ratingKey: "900")

    private func item(_ key: String, type: PlexMediaType = .movie, watched: Bool = false, offset: Int? = nil, server: String = "srv") -> PlaybackQueueItem {
        PlaybackQueueItem(
            id: PlexItemID(serverID: server, ratingKey: key),
            type: type,
            title: "Item \(key)",
            index: type == .episode ? Int(key) : nil,
            parentIndex: type == .episode ? 1 : nil,
            grandparentTitle: type == .episode ? "Show" : nil,
            duration: 60_000,
            viewOffset: offset,
            isWatched: watched
        )
    }

    // MARK: Playlist order

    @Test func playlistPlaysThroughInOrderFromTheChosenItem() throws {
        let items = ["1", "2", "3", "4", "5"].map { item($0) }
        var queue = try #require(PlaybackQueue.playlist(id: playlistID, title: "Mix", items: items, startIndex: 2))
        #expect(queue.current?.ratingKey == "3")
        #expect(queue.title == "Mix")

        var played: [String] = [queue.current!.ratingKey]
        while let next = queue.next() {
            queue.move(to: next.index)
            played.append(next.item.ratingKey)
        }
        #expect(played == ["3", "4", "5"])
    }

    /// Marvin: a playlist never skips completed items; they start over.
    /// The start position is never forced, though (review #1): a watched
    /// item only hands no stale list offset to the session, which then
    /// decides from fresh details and pending offline progress.
    @Test func watchedItemsAreNotSkippedAndNeverResumeFromAStaleListOffset() throws {
        let items = [item("1", offset: 12_000), item("2", watched: true), item("3", watched: true, offset: 30_000), item("4")]
        let queue = try #require(PlaybackQueue.playlist(id: playlistID, title: "Mix", items: items, startIndex: 0))
        let next = try #require(queue.next())
        #expect(next.item.ratingKey == "2")
        #expect(next.item.queueResumeFallbackOffset == nil)
        #expect(items[2].queueResumeFallbackOffset == nil)
        // An unwatched one hands its list offset over as the fallback.
        #expect(items[0].queueResumeFallbackOffset == 12_000)
    }

    /// Review #3: the same title twice; the chosen occurrence is where it starts.
    @Test func duplicateEntriesStartAtTheChosenOccurrence() throws {
        let items = [item("A"), item("B"), item("A"), item("C")]
        let queue = try #require(PlaybackQueue.playlist(id: playlistID, title: "Mix", items: items, startIndex: 2))
        #expect(queue.position == 2)
        #expect(queue.next()?.item.ratingKey == "C")
        // Dropped kinds before the start still count correctly.
        let mixed = [item("X", type: .track), item("A"), item("A")]
        let second = try #require(PlaybackQueue.playlist(id: playlistID, title: "Mix", items: mixed, startIndex: 2))
        #expect(second.position == 1)
        #expect(second.next() == nil)
    }

    @Test func mixedMoviesAndEpisodesFollowThePlaylistNotTheShow() throws {
        let items = [item("10", type: .episode), item("20"), item("11", type: .episode)]
        var queue = try #require(PlaybackQueue.playlist(id: playlistID, title: "Mix", items: items))
        let afterEpisode = try #require(queue.next())
        #expect(afterEpisode.item.ratingKey == "20")
        #expect(afterEpisode.item.type == .movie)
        queue.move(to: afterEpisode.index)
        #expect(queue.next()?.item.ratingKey == "11")
        #expect(queue.previous()?.item.ratingKey == "10")
    }

    @Test func endOfPlaylistHasNoNext() throws {
        let items = [item("1"), item("2")]
        let queue = try #require(PlaybackQueue.playlist(id: playlistID, title: "Mix", items: items, startIndex: 1))
        #expect(queue.next() == nil)
        #expect(queue.previous()?.item.ratingKey == "1")
    }

    @Test func unplayableKindsAreDroppedUpFront() throws {
        let items = [item("1"), item("2", type: .track), item("3", type: .clip)]
        let queue = try #require(PlaybackQueue.playlist(id: playlistID, title: "Mix", items: items, startIndex: 2))
        #expect(queue.items.map(\.ratingKey) == ["1", "3"])
        #expect(queue.current?.ratingKey == "3")
        #expect(PlaybackQueue.playlist(id: playlistID, title: "Empty", items: [item("9", type: .album)]) == nil)
    }

    // MARK: Shuffle

    @Test func shuffleIsAFixedPermutationStartingAtItsFirstItem() throws {
        let items = (1...8).map { item(String($0)) }
        var generator = SeededGenerator(seed: 7)
        var queue = try #require(PlaybackQueue.shuffledPlaylist(id: playlistID, title: "Mix", items: items, using: &generator))
        #expect(queue.isShuffled)
        #expect(queue.position == 0)
        #expect(Set(queue.items.map(\.ratingKey)) == Set(items.map(\.ratingKey)))
        #expect(queue.items.map(\.ratingKey) != items.map(\.ratingKey))

        var played = [queue.current!.ratingKey]
        while let next = queue.next() {
            queue.move(to: next.index)
            played.append(next.item.ratingKey)
        }
        #expect(played == queue.items.map(\.ratingKey))

        var sameSeed = SeededGenerator(seed: 7)
        let again = try #require(PlaybackQueue.shuffledPlaylist(id: playlistID, title: "Mix", items: items, using: &sameSeed))
        #expect(again.items.map(\.ratingKey) == queue.items.map(\.ratingKey))
    }

    // MARK: Removed / unavailable / offline

    @Test func itemsGoneFromTheServerAreSkipped() throws {
        var queue = try #require(PlaybackQueue.playlist(id: playlistID, title: "Mix", items: [item("1"), item("2"), item("3")]))
        queue.markUnavailable(PlexItemID(serverID: "srv", ratingKey: "2"))
        #expect(queue.next()?.item.ratingKey == "3")
        queue.markUnavailable(PlexItemID(serverID: "srv", ratingKey: "3"))
        #expect(queue.next() == nil)
    }

    @Test func offlineOnlyDownloadedItemsPlay() throws {
        let downloaded: Set<String> = ["1", "4"]
        let queue = try #require(PlaybackQueue.playlist(
            id: playlistID,
            title: "Mix",
            items: ["1", "2", "3", "4", "5"].map { item($0) }
        ))
        let isPlayable: (PlaybackQueueItem) -> Bool = { downloaded.contains($0.ratingKey) }
        let next = try #require(queue.next(isPlayable: isPlayable))
        #expect(next.item.ratingKey == "4")
        var moved = queue
        moved.move(to: next.index)
        #expect(moved.next(isPlayable: isPlayable) == nil)
        #expect(moved.previous(isPlayable: isPlayable)?.item.ratingKey == "1")
    }

    @Test func fresherMetadataReplacesOnlyTheSameItem() throws {
        var queue = try #require(PlaybackQueue.playlist(id: playlistID, title: "Mix", items: [item("1"), item("2")]))
        queue.replaceItem(at: 1, with: item("2", watched: true))
        #expect(queue.items[1].isWatched)
        queue.replaceItem(at: 1, with: item("99"))
        #expect(queue.items[1].ratingKey == "2")
    }

    // MARK: Lists (Videos libraries, collections)

    @Test func listContextPlaysThroughMoviesAndClipsOnly() throws {
        let plexItems = try decodeItems("""
            {"ratingKey":"1","key":"/library/metadata/1","type":"movie","subtype":"clip","title":"Clip A"},
            {"ratingKey":"2","key":"/library/metadata/2","type":"show","title":"A Show"},
            {"ratingKey":"3","key":"/library/metadata/3","type":"movie","subtype":"clip","title":"Clip B","viewCount":1},
            {"ratingKey":"4","key":"/library/metadata/4","type":"movie","subtype":"clip","title":"Clip C"}
            """)
        let list = try #require(PlaybackListContext(title: "Home Videos", plexItems: plexItems))
        #expect(list.items.map(\.ratingKey) == ["1", "3", "4"])
        let queue = try #require(list.queue(startingAt: plexItems[2].id))
        #expect(queue.current?.ratingKey == "3")
        #expect(queue.next()?.item.ratingKey == "4")
        #expect(queue.title == "Home Videos")
        #expect(AppNavigationRoute.destination(for: plexItems[0], in: list) == .videoInList(id: plexItems[0].id, list: list))
        #expect(AppNavigationRoute.destination(for: plexItems[1], in: list) == .media(type: .show, id: plexItems[1].id))
        // A single video has nothing to continue to: plain playback.
        #expect(PlaybackListContext(title: "One", plexItems: [plexItems[0]]) == nil)
    }

    @Test func playlistEntriesDecodeWithAndWithoutPlaylistItemID() throws {
        // Shape of plex-demo (PMS 1.43.5) /playlists/{id}/items: regular
        // playlists number their entries, smart ones send no playlistItemID.
        let data = Data("""
            {"MediaContainer":{"size":2,"totalSize":2,"duration":4,"leafCount":2,"smart":false,"Metadata":[
              {"playlistItemID":10,"ratingKey":"83468","key":"/library/metadata/83468","type":"movie","title":"Amber Atlas","duration":2021},
              {"ratingKey":"116969","key":"/library/metadata/116969","type":"episode","title":"Night Wild","grandparentTitle":"Amber Garden","index":1,"parentIndex":1}
            ]}}
            """.utf8)
        let entries = try JSONDecoder().decode(MetadataResponse<PlexPlaylistEntry>.self, from: data).MediaContainer.Metadata ?? []
        #expect(entries.map(\.playlistItemID) == [10, nil])
        #expect(entries[1].item.type == .episode)
        #expect(entries.map(\.id).count == Set(entries.map(\.id)).count)
    }

    @Test func playlistListDecodesSmartAndMillisecondDuration() throws {
        let data = Data("""
            {"MediaContainer":{"size":2,"Metadata":[
              {"ratingKey":"166489","key":"/playlists/166489/items","type":"playlist","title":"Marathon","summary":"","smart":true,
               "playlistType":"video","composite":"/playlists/166489/composite/1","duration":40000,"leafCount":20},
              {"ratingKey":"7","key":"/playlists/7/items","type":"playlist","title":"Songs","smart":"0","playlistType":"audio","leafCount":3}
            ]}}
            """.utf8)
        let playlists = try JSONDecoder().decode(MetadataResponse<PlexPlaylist>.self, from: data).MediaContainer.Metadata ?? []
        #expect(playlists[0].smart)
        #expect(playlists[0].summary == nil)
        #expect(playlists[0].duration == 40_000)
        #expect(playlists[0].isVideo)
        #expect(!playlists[1].smart)
        #expect(!playlists[1].isVideo)
    }

    private func decodeItems(_ rows: String) throws -> [PlexItem] {
        let data = Data(#"{"MediaContainer":{"Metadata":["# .utf8 + Data(rows.utf8) + Data("]}}".utf8))
        return try JSONDecoder().decode(MetadataResponse<PlexItem>.self, from: data).MediaContainer.Metadata ?? []
    }
}

/// How Up Next picks what follows, end to end through the coordinator. The
/// stub server counts requests: the episode hot path must not ask the server
/// again once the commit-time neighbour lookup has answered.
@Suite("Up Next resolution", .serialized)
@MainActor
struct UpNextResolutionTests {
    private let serverID = "upnext-test-server"

    @Test func episodeUsesTheCommitTimeNeighbourWithoutARequest() async throws {
        let (playback, details) = try makeEpisodeSession()
        playback.adjacentEpisodes = PlaybackAdjacentEpisodes(
            itemID: details.id,
            isResolved: true,
            next: .init(item: episodeItem("102")),
            isOnlineEpisodeLookup: true
        )
        UpNextStubProtocol.reset()

        let candidate = try #require(await playback.resolveUpNext(after: details, prefersDownloadCache: true))
        #expect(candidate.item.ratingKey == "102")
        #expect(candidate.queueIndex == nil)
        #expect(UpNextStubProtocol.requestCount == 0)
    }

    @Test func episodeWithoutAnAnswerFallsBackToTheOldLookup() async throws {
        let (playback, details) = try makeEpisodeSession()
        // The neighbour lookup is still running (or failed): ask the server,
        // exactly as before.
        playback.adjacentEpisodes = PlaybackAdjacentEpisodes(itemID: details.id)
        UpNextStubProtocol.reset()
        UpNextStubProtocol.seasonChildren = Data("""
            {"MediaContainer":{"size":2,"Metadata":[
              {"ratingKey":"101","key":"/library/metadata/101","title":"One","index":1,"parentIndex":1},
              {"ratingKey":"102","key":"/library/metadata/102","title":"Two","index":2,"parentIndex":1}
            ]}}
            """.utf8)

        let candidate = try #require(await playback.resolveUpNext(after: details, prefersDownloadCache: false))
        #expect(candidate.item.ratingKey == "102")
        #expect(UpNextStubProtocol.requestCount >= 1)
    }

    /// Review #2: an online lookup that found no next episode is not the
    /// final word — the old path still asks again and falls back to downloads.
    @Test func anEmptyNeighbourAnswerFallsBackToTheOldLookup() async throws {
        let (playback, details) = try makeEpisodeSession()
        playback.adjacentEpisodes = PlaybackAdjacentEpisodes(
            itemID: details.id,
            isResolved: true,
            next: nil,
            isOnlineEpisodeLookup: true
        )
        UpNextStubProtocol.reset()
        UpNextStubProtocol.seasonChildren = Data("""
            {"MediaContainer":{"size":2,"Metadata":[
              {"ratingKey":"101","key":"/library/metadata/101","title":"One","index":1,"parentIndex":1},
              {"ratingKey":"102","key":"/library/metadata/102","title":"Added Later","index":2,"parentIndex":1}
            ]}}
            """.utf8)

        let candidate = try #require(await playback.resolveUpNext(after: details, prefersDownloadCache: true))
        #expect(candidate.item.title == "Added Later")
        #expect(UpNextStubProtocol.requestCount >= 1)
    }

    /// Review #3: auto-advancing from one copy of an item to the next copy
    /// refreshes the Previous / Next targets.
    @Test func neighboursFollowTheQueuePositionNotJustTheItem() throws {
        let (playback, details) = try makeEpisodeSession()
        let movie = PlaybackQueueItem(id: PlexItemID(serverID: serverID, ratingKey: "500"), type: .movie, title: "Film")
        playback.playbackQueue = PlaybackQueue.playlist(
            id: PlexItemID(serverID: serverID, ratingKey: "900"),
            title: "Mix",
            items: [episodeItem("101"), episodeItem("101"), movie]
        )
        playback.refreshAdjacentEpisodesIfNeeded()
        #expect(playback.adjacentEpisodes?.next?.queueIndex == 1)

        playback.moveQueue(to: 1)
        playback.refreshAdjacentEpisodesIfNeeded()
        #expect(playback.adjacentEpisodes?.itemID == details.id)
        #expect(playback.adjacentEpisodes?.next?.item.ratingKey == "500")
        #expect(playback.adjacentEpisodes?.previous?.queueIndex == 0)
    }

    /// #76: Back stops the poster countdown but keeps the poster, which
    /// still advances when the episode really ends.
    @Test func haltingThePosterCountdownKeepsThePoster() async throws {
        let (playback, _) = try makeEpisodeSession()
        defer { playback.cancelUpNextPosterCountdown() }
        let next = episodeItem("102")
        playback.upNextPoster = UpNextPosterPresentation(
            item: next,
            mode: .timedAutoplay(countdown: 30),
            creditsMarkerID: 7,
            secondsRemaining: 30,
            countdownClock: UpNextCountdownClock(duration: 30)
        )
        playback.startUpNextPosterCountdown()
        #expect(playback.upNextPosterCountdownTask != nil)

        #expect(playback.haltUpNextPosterCountdown())

        let poster = try #require(playback.upNextPoster)
        #expect(poster.item.ratingKey == "102")
        #expect(poster.mode == .autoAdvanceAtEnd)
        #expect(poster.autoAdvancesAtEnd)
        #expect(poster.countdownClock == nil)
        #expect(poster.secondsRemaining == nil)
        #expect(playback.upNextPosterCountdownTask == nil)

        // The cancelled loop publishes nothing more.
        try await Task.sleep(for: .milliseconds(250))
        #expect(playback.upNextPoster?.countdownClock == nil)
        #expect(playback.upNextPoster?.isStarting == false)

        // Nothing left to halt: Back goes back to its usual job.
        #expect(!playback.haltUpNextPosterCountdown())
    }

    @Test func haltDoesNothingForAnUntimedPoster() throws {
        let (playback, _) = try makeEpisodeSession()
        #expect(!playback.haltUpNextPosterCountdown())

        playback.upNextPoster = UpNextPosterPresentation(item: episodeItem("102"), mode: .manual, creditsMarkerID: 7)
        #expect(!playback.haltUpNextPosterCountdown())
        #expect(playback.upNextPoster?.mode == .manual)
    }

    /// Review #4: an item found gone after the poster went up moves the
    /// poster on to the following item (or away at the end).
    @Test func aGoneItemMovesTheVisiblePosterOn() throws {
        let (playback, _) = try makeEpisodeSession()
        let b = PlaybackQueueItem(id: PlexItemID(serverID: serverID, ratingKey: "600"), type: .movie, title: "B")
        let c = PlaybackQueueItem(id: PlexItemID(serverID: serverID, ratingKey: "700"), type: .movie, title: "C")
        playback.playbackQueue = PlaybackQueue.playlist(
            id: PlexItemID(serverID: serverID, ratingKey: "900"),
            title: "Mix",
            items: [episodeItem("101"), b, c]
        )
        playback.upNextPoster = UpNextPosterPresentation(item: b, queueIndex: 1, queueTitle: "Mix", mode: .manual, creditsMarkerID: 1)

        playback.noteQueueItemUnavailable(b.id)
        #expect(playback.upNextPoster?.item.ratingKey == "700")
        #expect(playback.upNextPoster?.queueIndex == 2)
        #expect(playback.revalidatedQueueCandidate(UpNextCandidate(item: b, queueIndex: 1))?.item.ratingKey == "700")

        playback.noteQueueItemUnavailable(c.id)
        #expect(playback.upNextPoster == nil)
    }

    /// Review #5: any number of removed entries in a row is skipped by the
    /// lookahead, not just the first three.
    @Test func lookaheadSkipsAnyRunOfRemovedEntries() async throws {
        let (playback, details) = try makeEpisodeSession()
        let missing = (1...4).map { PlaybackQueueItem(id: PlexItemID(serverID: serverID, ratingKey: "m\($0)"), type: .movie, title: "Missing \($0)") }
        let b = PlaybackQueueItem(id: PlexItemID(serverID: serverID, ratingKey: "800"), type: .movie, title: "B")
        playback.playbackQueue = PlaybackQueue.playlist(
            id: PlexItemID(serverID: serverID, ratingKey: "900"),
            title: "Mix",
            items: [episodeItem("101")] + missing + [b]
        )
        var lookups: [String] = []
        playback.queueItemLookup = { item in
            lookups.append(item.ratingKey)
            guard item.ratingKey == "800" else { throw PlexServiceError.httpError(statusCode: 404) }
            let decoder = JSONDecoder()
            decoder.userInfo[.duskServerID] = item.serverID
            return try decoder.decode(PlexMediaDetails.self, from: Data("""
                {"ratingKey":"800","key":"/library/metadata/800","type":"movie","title":"B (fresh)","viewCount":1}
                """.utf8))
        }
        playback.refreshAdjacentEpisodesIfNeeded()
        await playback.queueLookaheadTask?.value

        #expect(lookups == ["m1", "m2", "m3", "m4", "800"])
        #expect(playback.adjacentEpisodes?.next?.item.ratingKey == "800")
        #expect(playback.adjacentEpisodes?.next?.item.isWatched == true)
        let candidate = try #require(await playback.resolveUpNext(after: details, prefersDownloadCache: true))
        #expect(candidate.item.ratingKey == "800")
    }

    @Test func aMovieOutsideAQueueHasNoUpNext() async throws {
        let (playback, _) = try makeEpisodeSession()
        let movie = try JSONDecoder().decode(PlexMediaDetails.self, from: Data("""
            {"ratingKey":"5","key":"/library/metadata/5","type":"movie","title":"Movie"}
            """.utf8))
        #expect(await playback.resolveUpNext(after: movie, prefersDownloadCache: true) == nil)
    }

    @Test func queueSessionsFollowTheQueueAndEndWithIt() async throws {
        let (playback, details) = try makeEpisodeSession()
        let movie = PlaybackQueueItem(id: PlexItemID(serverID: serverID, ratingKey: "500"), type: .movie, title: "Film")
        playback.playbackQueue = PlaybackQueue.playlist(
            id: PlexItemID(serverID: serverID, ratingKey: "900"),
            title: "Mix",
            items: [episodeItem("101"), movie]
        )
        // Even with the show's next episode known, the playlist wins.
        playback.adjacentEpisodes = PlaybackAdjacentEpisodes(
            itemID: details.id,
            isResolved: true,
            next: .init(item: episodeItem("102")),
            isOnlineEpisodeLookup: true
        )
        UpNextStubProtocol.reset()

        let candidate = try #require(await playback.resolveUpNext(after: details, prefersDownloadCache: true))
        #expect(candidate.item.ratingKey == "500")
        #expect(candidate.queueIndex == 1)
        #expect(UpNextStubProtocol.requestCount == 0)

        playback.moveQueue(to: 1)
        #expect(await playback.resolveUpNext(after: details, prefersDownloadCache: true) == nil)
    }

    @Test func queueSkipsItemsWhoseServerIsUnreachable() async throws {
        let (playback, details) = try makeEpisodeSession()
        let offline = PlaybackQueueItem(id: PlexItemID(serverID: "gone-server", ratingKey: "7"), type: .movie, title: "Offline")
        let online = PlaybackQueueItem(id: PlexItemID(serverID: serverID, ratingKey: "8"), type: .movie, title: "Online")
        playback.playbackQueue = PlaybackQueue.playlist(
            id: PlexItemID(serverID: serverID, ratingKey: "900"),
            title: "Mix",
            items: [episodeItem("101"), offline, online]
        )
        let candidate = try #require(await playback.resolveUpNext(after: details, prefersDownloadCache: true))
        #expect(candidate.item.ratingKey == "8")
        #expect(candidate.queueIndex == 2)
    }

    @Test func passoutProtectionCountsEveryQueueItem() throws {
        let (playback, _) = try makeEpisodeSession()
        playback.activeItemDetails = try JSONDecoder().decode(PlexMediaDetails.self, from: Data("""
            {"ratingKey":"5","key":"/library/metadata/5","type":"movie","title":"Movie"}
            """.utf8))
        playback.resetContinuousPlayEpisodeRunCountForCurrentItem()
        #expect(playback.continuousPlayEpisodeRunCount == 0)
        playback.playbackQueue = PlaybackQueue.list(
            title: "Videos",
            items: [PlaybackQueueItem(id: PlexItemID(serverID: serverID, ratingKey: "5"), type: .movie, title: "Movie")],
            startIndex: 0
        )
        playback.resetContinuousPlayEpisodeRunCountForCurrentItem()
        #expect(playback.continuousPlayEpisodeRunCount == 1)
    }

    // MARK: Helpers

    private func episodeItem(_ key: String) -> PlaybackQueueItem {
        PlaybackQueueItem(
            id: PlexItemID(serverID: serverID, ratingKey: key),
            type: .episode,
            title: "Episode \(key)",
            index: Int(key).map { $0 - 100 },
            parentIndex: 1
        )
    }

    private func makeEpisodeSession() throws -> (PlaybackCoordinator, PlexMediaDetails) {
        let service = PlexService(urlProtocolClasses: [UpNextStubProtocol.self])
        for connected in service.pool.connections.map(\.serverID) {
            service.pool.markOffline(serverID: connected, reason: "Not part of this test")
        }
        let server = try JSONDecoder().decode(PlexServer.self, from: Data("""
            {"name":"\(serverID)","clientIdentifier":"\(serverID)","provides":"server","owned":true,"presence":true,"connections":[]}
            """.utf8))
        service.pool.adopt(
            server: server,
            baseURL: URL(string: "https://upnext.invalid:32400")!,
            token: "token",
            connection: nil
        )
        let playback = PlaybackCoordinator(plexService: service)
        let json = Data("""
            {"ratingKey":"101","key":"/library/metadata/101","type":"episode","title":"One",
             "index":1,"parentIndex":1,"parentRatingKey":"100","grandparentRatingKey":"99"}
            """.utf8)
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = serverID
        let details = try decoder.decode(PlexMediaDetails.self, from: json)
        playback.activeItemDetails = details
        playback.ratingKey = details.ratingKey
        playback.activePlaybackServerID = serverID
        return (playback, details)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Counts every request and answers the season's children; anything else 404s.
private final class UpNextStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) static var seasonChildren = Data(#"{"MediaContainer":{"size":0}}"#.utf8)

    static var requestCount: Int { lock.withLock { count } }

    static func reset() {
        lock.withLock { count = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "upnext.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        let path = request.url?.path ?? ""
        let body: Data
        let status: Int
        if path == "/library/metadata/100/children" {
            body = Self.lock.withLock { Self.seasonChildren }
            status = 200
        } else {
            body = Data()
            status = 404
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Playlist store")
@MainActor
struct PlaylistStoreTests {
    private func playlist(_ key: String, server: String) -> PlexPlaylist {
        PlexPlaylist(serverID: server, ratingKey: key, title: "P\(key)")
    }

    private func revision(_ servers: [String], profile: String? = "p1") -> ServerContentRevision {
        ServerContentRevision(serverIDs: servers, priorityRevision: 0, profileID: profile)
    }

    /// Review #6: an older load's late answer cannot bring back a server the
    /// newer load dropped, nor finish the newer load.
    @Test func staleLoadsCannotCommit() {
        let store = PlaylistStore()
        let old = store.beginLoad(revision: revision(["a", "b"]))
        let new = store.beginLoad(revision: revision(["a"]))
        store.commit([playlist("1", server: "b")], serverID: "b", generation: old)
        store.commit([playlist("2", server: "a")], serverID: "a", generation: old)
        #expect(store.playlists.isEmpty)
        store.finishLoad(failure: nil, generation: old)
        #expect(store.state == .loading)

        store.commit([playlist("3", server: "a")], serverID: "a", generation: new)
        store.finishLoad(failure: nil, generation: new)
        #expect(store.playlists.map(\.ratingKey) == ["3"])
        #expect(store.state == .loaded)
    }

    @Test func editsThatOutliveASessionAreDropped() {
        let store = PlaylistStore()
        let generation = store.beginLoad(revision: revision(["a"]))
        store.commit([playlist("1", server: "a")], serverID: "a", generation: generation)
        let session = store.sessionGeneration
        store.reset()
        store.upsert(playlist("1", server: "a"), sessionGeneration: session)
        #expect(!store.hasPlaylists)

        // A profile switch is a new session too.
        _ = store.beginLoad(revision: revision(["a"], profile: "p1"))
        let p1 = store.sessionGeneration
        _ = store.beginLoad(revision: revision(["a"], profile: "p2"))
        store.upsert(playlist("9", server: "a"), sessionGeneration: p1)
        #expect(!store.hasPlaylists)
        store.upsert(playlist("9", server: "a"), sessionGeneration: store.sessionGeneration)
        #expect(store.hasPlaylists)
    }
}

@Suite("Up Next countdown clock")
struct UpNextCountdownClockTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test("Seconds round up and progress runs from 0 to 1")
    func runningClock() {
        var clock = UpNextCountdownClock(duration: 15)
        #expect(clock.secondsRemaining(at: start) == 15)
        #expect(clock.progress(at: start) == 0)

        clock.resume(at: start)
        #expect(clock.secondsRemaining(at: start.addingTimeInterval(0.1)) == 15)
        #expect(clock.secondsRemaining(at: start.addingTimeInterval(1)) == 14)
        #expect(clock.secondsRemaining(at: start.addingTimeInterval(14.9)) == 1)
        #expect(clock.secondsRemaining(at: start.addingTimeInterval(20)) == 0)
        #expect(clock.progress(at: start.addingTimeInterval(7.5)) == 0.5)
        #expect(clock.progress(at: start.addingTimeInterval(20)) == 1)
    }

    @Test("A pause holds the position and resuming continues from it")
    func pauseAndResume() {
        var clock = UpNextCountdownClock(duration: 10)
        clock.resume(at: start)
        clock.freeze(at: start.addingTimeInterval(4))
        // Freezing or resuming twice must not move or re-anchor it: the task
        // calls one of them on every poll.
        clock.freeze(at: start.addingTimeInterval(5))
        #expect(clock.elapsed(at: start.addingTimeInterval(100)) == 4)

        clock.resume(at: start.addingTimeInterval(100))
        let resumed = clock
        clock.resume(at: start.addingTimeInterval(101))
        #expect(clock == resumed)
        #expect(clock.elapsed(at: start.addingTimeInterval(102)) == 6)
    }

    @Test("A finished or empty countdown reads as over")
    func finished() {
        var clock = UpNextCountdownClock(duration: 10)
        clock.finish()
        #expect(clock.progress(at: start) == 1)
        #expect(clock.secondsRemaining(at: start) == 0)
        #expect(UpNextCountdownClock(duration: 0).progress(at: start) == 1)
    }
}
