import Foundation
import Testing
@testable import Dusk

@Suite("Movies in multiple libraries")
@MainActor
struct MovieLibraryMergeTests {
    private func fields(
        _ key: String, section: Int = 1, guid: String? = "plex://movie/shared",
        guids: [String] = [], edition: String? = nil, offset: Int = 0,
        watched: Int = 0, duration: Int = 100_000, type: String = "movie"
    ) -> [String: Any] {
        var value: [String: Any] = [
            "ratingKey": key, "key": "/library/metadata/\(key)", "type": type,
            "title": "Same Title", "year": 2020, "librarySectionID": section,
            "librarySectionTitle": section == 1 ? "Movies 1080p" : "Movies 4K",
            "duration": duration, "viewOffset": offset, "viewCount": watched,
            "Guid": guids.map { ["id": $0] },
        ]
        if let guid { value["guid"] = guid }
        if let edition { value["editionTitle"] = edition }
        return value
    }

    private func item(_ fields: [String: Any], server: String = "a") throws -> PlexItem {
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = server
        return try decoder.decode(PlexItem.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func details(_ key: String, section: Int, mediaID: Int, height: Int, size: Int, hdr: Bool = false) throws -> PlexMediaDetails {
        var value = fields(key, section: section)
        value["Media"] = [[
            "id": mediaID, "videoResolution": height == 2160 ? "4k" : "1080",
            "height": height, "width": height == 2160 ? 3840 : 1920,
            "Part": [["id": mediaID, "key": "/file/\(mediaID)", "size": size,
                      "Stream": [["id": mediaID, "streamType": 1,
                                  "colorTrc": hdr ? "smpte2084" : "bt709"]]]],
        ]]
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "a"
        return try decoder.decode(PlexMediaDetails.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @Test func singleServerSearchMergesLibrariesAndRetainsEveryCopy() throws {
        let hd = try item(fields("hd"))
        let uhd = try item(fields("uhd", section: 2, offset: 40_000))
        let group = PlexSearchResult(title: "Movies", type: "movie", items: [hd, uhd])
        let merged = SearchMerge.merge([[group]])
        #expect(merged.groups.count == 1)
        #expect(merged.groups[0].items.map(\.id) == [uhd.id])
        #expect(merged.alternates[hd.contentKey] == [hd.id, uhd.id])
        // The source library listing itself remains unchanged.
        #expect(group.items.map(\.id) == [hd.id, uhd.id])
    }

    @Test func aliasesBridgeModernAndLegacyAgentsTransitively() throws {
        let first = try item(fields("1", guids: ["tmdb://11"]))
        let bridge = try item(fields("2", section: 2, guid: "plex://movie/other", guids: ["tmdb://11", "imdb://tt12"]))
        let legacy = try item(fields("3", section: 3, guid: nil, guids: ["imdb://tt12"]))
        let merged = PlexItemMerge.interleave([[first, bridge, legacy]])
        #expect(merged.items.count == 1)
        #expect(merged.alternates.values.first == [first.id, bridge.id, legacy.id])
        var seen = RecommendationSeenTitles()
        let insertedFirst = seen.insert(first)
        let insertedBridge = seen.insert(bridge)
        let insertedLegacy = seen.insert(legacy)
        #expect(insertedFirst)
        #expect(!insertedBridge)
        #expect(!insertedLegacy)
    }

    @Test func scalarExternalGuidsMatchGuidArrays() throws {
        for guid in ["tmdb://11", "imdb://tt12"] {
            let scalar = try item(fields("scalar", guid: guid))
            let array = try item(fields("array", section: 2, guid: nil, guids: [guid]))
            let merged = PlexItemMerge.interleave([[scalar, array]])
            #expect(scalar.contentKey.isStrong)
            #expect(merged.items.count == 1)
            #expect(merged.alternates.values.first == [scalar.id, array.id])
        }
    }

    @Test func weakIdentityAndEditionsNeverMergeWithinOneServer() throws {
        let weak = try item(fields("1", guid: nil))
        let otherWeak = try item(fields("2", section: 2, guid: nil))
        #expect(PlexItemMerge.interleave([[weak, otherWeak]]).items.count == 2)
        #expect(PlexItemMerge.alternates(in: [[weak, otherWeak]]).isEmpty)
        #expect(ContinueWatchingMerge.merge([[weak, otherWeak], []]).items.count == 2)
        let theatrical = try item(fields("3", guids: ["tmdb://11"]))
        let extended = try item(fields("4", section: 2, guids: ["tmdb://11"], edition: "Extended"))
        #expect(PlexItemMerge.interleave([[theatrical, extended]]).items.count == 2)
    }

    @Test func movieAndShowWithSameExternalIDStaySeparate() throws {
        let movie = try item(fields("1", guid: nil, guids: ["tmdb://11"]))
        let show = try item(fields("2", guid: nil, guids: ["tmdb://11"], type: "show"))
        #expect(PlexItemMerge.interleave([[movie, show]]).items.count == 2)
        let otherShow = try item(fields("3", section: 2, guid: nil, guids: ["tmdb://11"], type: "show"))
        #expect(PlexItemMerge.interleave([[show, otherShow]]).items.count == 2)
    }

    @Test func progressUsesFurthestFractionThenWatchedState() throws {
        let long = try item(fields("long", offset: 60_000, duration: 200_000))
        let advanced = try item(fields("advanced", section: 2, offset: 40_000))
        #expect(PlexItemMerge.interleave([[long, advanced]]).items.first?.id == advanced.id)
        #expect(ContinueWatchingMerge.merge([[long, advanced]]).items.first?.id == advanced.id)
        let watched = try item(fields("watched", section: 3, watched: 1))
        #expect(PlexItemMerge.interleave([[long, advanced, watched]]).items.first?.id == watched.id)
    }

    @Test func homeAndLibraryTypeHubsCollapseCopiesWithoutLosingSources() throws {
        func hub(_ items: [[String: Any]], section: Int) throws -> PlexHub {
            let value: [String: Any] = ["title": "Recently Added Movies", "type": "movie",
                "hubIdentifier": "movie.recentlyadded.\(section)", "librarySectionID": section,
                "key": "/library/sections/\(section)/all", "Metadata": items]
            let decoder = JSONDecoder()
            decoder.userInfo[.duskServerID] = "a"
            return try decoder.decode(PlexHub.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let a = try hub([fields("1"), fields("2", section: 2)], section: 1)
        #expect(HubMerge.merge([[a]]).hubs[0].items.count == 1)
        let b = try hub([fields("2", section: 2)], section: 2)
        let type = HubMerge.merge([[a], [b]], mode: .libraryType)
        #expect(type.hubs.count == 1)
        #expect(type.hubs[0].items.count == 1)
        #expect(type.hubs[0].sources.count == 2)
    }

    @Test func alternateIndexKeepsSameServerCopiesAndBridgesLaterKeys() throws {
        let a = try item(fields("1"))
        let b = try item(fields("2", section: 2))
        let remote = try item(fields("3"), server: "b")
        let index = ContentAlternatesIndex()
        index.register([a.id, b.id], for: a.contentKey)
        let external = PlexContentKey.external(provider: "imdb", namespace: "movie", id: "tt12")
        index.register([remote.id], for: external)
        index.register([b.id, remote.id], for: external)
        #expect(Set(index.instances(of: a.id)) == Set([a.id, b.id, remote.id]))
        #expect(index.instances(of: b.id).first == b.id)
        #expect(index.contentKey(for: a.id) == external)
        index.reset()
        #expect(index.instances(of: a.id) == [a.id])
    }

    @Test func playbackAndWatchedActionsKeepEverySameServerCopy() async throws {
        // Every request is intercepted; this never contacts or writes to Plex.
        let stub = SelectionStub.Scope()
        let serverID = "movie-copies-\(UUID().uuidString)"
        let host = stub.host("movie-copies", .ok(serverID))
        let service = PlexService(urlProtocolClasses: [SelectionStub.self])
        let server = try JSONDecoder().decode(PlexServer.self, from: JSONSerialization.data(withJSONObject: [
            "name": "Copies", "clientIdentifier": serverID, "connections": [],
        ]))
        service.pool.adopt(server: server, baseURL: URL(string: "https://\(host)")!, token: "test-token", connection: nil)
        defer {
            ServerPool.forget(serverID: serverID)
            service.session.invalidateAndCancel()
            service.slowQuerySession.invalidateAndCancel()
            service.probeSession.invalidateAndCancel()
        }
        let hd = try item(fields("hd"), server: serverID)
        let uhd = try item(fields("uhd", section: 2), server: serverID)
        service.registerAlternates(PlexItemMerge.alternates(in: [[hd, uhd]]))
        let resolver = PlaybackSourceResolver(plexService: service)
        #expect(resolver.resolve(for: hd.id).identifiers == [hd.id, uhd.id])
        #expect(resolver.resolve(for: uhd.id, restrictToItemServer: true).identifiers == [uhd.id])
        for watched in [true, false] {
            try await service.setWatchedAcrossServers(watched, id: hd.id)
            let path = watched ? "/:/scrobble" : "/:/unscrobble"
            let keys = SelectionStub.requests(host: host).filter { $0.url.path == path }.compactMap {
                URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "key" }?.value
            }
            #expect(keys == ["hd", "uhd"])
        }
    }

    @Test func changingEditionMovesOnlyThatCopy() throws {
        let a = try item(fields("1"))
        let b = try item(fields("2", section: 2))
        let extended = try item(fields("1", edition: "Extended"))
        let index = ContentAlternatesIndex()
        index.register([a.id, b.id], for: a.contentKey)
        index.register([a.id], for: extended.contentKey)
        #expect(index.instances(of: a.id) == [a.id])
        #expect(index.instances(of: b.id) == [b.id])
    }

    @Test func allVersionPreferencesChooseAcrossLibraryItems() throws {
        let hd = try details("hd", section: 1, mediaID: 10, height: 1080, size: 10_000_000_000)
        let uhd = try details("uhd", section: 2, mediaID: 20, height: 2160, size: 60_000_000_000, hdr: true)
        let copies = [hd, uhd]
        for preference in [PreferredMediaVersion.automatic, .fullHD, .smallestFile] {
            #expect(MoviePlaybackVersion.preferred(in: copies, maxResolution: .tenEightyP, preference: preference)?.details.id == hd.id)
        }
        #expect(MoviePlaybackVersion.preferred(in: copies, maxResolution: .tenEightyP, preference: .highestQuality)?.details.id == uhd.id)
        let versions = MoviePlaybackVersion.versions(in: copies)
        #expect(versions.count == 2)
        #expect(versions[0].label.contains("1080p"))
        #expect(versions[0].label.contains("Movies 1080p"))
        #expect(versions[1].label.contains("4K"))
        #expect(versions[1].label.contains("HDR10"))
        #expect(versions[1].label.contains("60 GB"))
        #expect(versions[1].label.contains("Movies 4K"))
        #expect(versions[0].id != versions[1].id)
        #expect(MoviePlaybackVersion.mostAdvancedCopy(in: copies)?.id == hd.id)
    }
}
