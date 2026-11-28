import Foundation
import Testing
@testable import Dusk

/// J-02 against a real Jellyfin server, gated like `JellyfinLiveTests`
/// (`TEST_RUNNER_DUSK_JELLYFIN_LIVE_*`). Read-only: it signs in with its own
/// throw-away `DeviceId`, browses, and logs out. Expectations are the
/// jellyfin-demo test data (docs/jellyfin/05-plan.md T-0) and assert on the
/// titles that come back.
@MainActor
@Suite("Jellyfin catalog live", .serialized, .enabled(if: JellyfinLiveConfig.current != nil, "no live server configured"))
struct JellyfinCatalogLiveTests {
    @Test(.timeLimit(.minutes(3)))
    func catalogAgainstLiveServer() async throws {
        let config = try #require(JellyfinLiveConfig.current)
        let password = try String(contentsOfFile: config.passwordFile, encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        let identity = JellyfinClientIdentity(
            device: "Dusk Tests", deviceID: "dusk-tests-\(UUID().uuidString.prefix(8).lowercased())", version: "0.0-test")
        let anonymous = JellyfinClient(baseURL: config.url, identity: identity)
        let auth = try await anonymous.send(JellyfinAPI.authenticateByName(username: config.user, password: password))
        let client = anonymous.signedIn(JellyfinCredentials(accessToken: auth.accessToken, userID: auth.user.id))
        let catalog = JellyfinCatalog(serverID: auth.serverID ?? "", client: { client })
        do {
            try await exercise(catalog)
        } catch {
            _ = try? await client.send(JellyfinAPI.logout())
            throw error
        }
        _ = try await client.send(JellyfinAPI.logout())
    }

    private func exercise(_ catalog: JellyfinCatalog) async throws {
        let libraries = try await catalog.libraries()
        let movies = try #require(libraries.first { $0.title == "Movies" })
        let realMovies = try #require(libraries.first { $0.title == "Real Movies" })
        let realTV = try #require(libraries.first { $0.title == "Real TV" })
        let paging = try #require(libraries.first { $0.title == "Paging Test" })
        #expect(libraries.first { $0.title == "Photos" }?.libraryType == .photo)
        #expect(libraries.first { $0.title == "Home Videos" }?.libraryType == .video)
        #expect(!libraries.contains { $0.title == "Collections" || $0.title == "Playlists" })

        // Grid, count, sort.
        let total = try await catalog.itemCount(libraryID: movies.key, kind: .movie, filter: LibraryFilter())
        #expect(total >= 26)
        let firstPage = try await catalog.items(
            libraryID: movies.key, kind: .movie, start: 0, size: 5, sort: .titleAscending, filter: LibraryFilter())
        #expect(firstPage.count == 5)
        #expect(firstPage.first?.title.hasPrefix("AV1") == true)
        let byYear = try await catalog.items(
            libraryID: movies.key, kind: .movie, start: 0, size: 100, sort: LibrarySortOption(.year, descending: false),
            filter: LibraryFilter())
        #expect(byYear.first?.title == "Elephants Dream")

        // A–Z: the offsets land on titles of that letter (Paging Test, 520).
        let letters = try await catalog.letterCounts(libraryID: paging.key, kind: .movie, filter: LibraryFilter())
        let index = LibraryLetterIndex(characters: letters, descending: false)
        #expect(index.totalCount == (try await catalog.itemCount(libraryID: paging.key, kind: .movie, filter: LibraryFilter())))
        for label in ["A", "M", "Z"] {
            let offset = try #require(index.entries.first { $0.label == label }?.offset)
            let landed = try await catalog.items(
                libraryID: paging.key, kind: .movie, start: offset, size: 1, sort: .titleAscending, filter: LibraryFilter())
            #expect(landed.first?.title.uppercased().hasPrefix(label) == true, "\(label) landed on \(landed.first?.title ?? "nothing")")
        }

        // Filters.
        let fields = try await catalog.filterFields(libraryID: realMovies.key, includesCollection: true)
        let directorField = try #require(fields.first { $0.parameter == "director" })
        let rian = try #require(try await catalog.filterChoices(for: directorField).first { $0.title == "Rian Johnson" })
        let byRian = try await catalog.items(
            libraryID: realMovies.key, kind: .movie, start: 0, size: 50, sort: nil,
            filter: LibraryFilter(choices: ["director": rian.value]))
        #expect(byRian.map(\.title) == ["Knives Out"])

        let movieFields = try await catalog.filterFields(libraryID: movies.key, includesCollection: true)
        let collectionField = try #require(movieFields.first { $0.parameter == "collection" })
        let weekend = try #require(try await catalog.filterChoices(for: collectionField).first { $0.title == "Weekend Watch" })
        let inWeekend = try await catalog.items(
            libraryID: movies.key, kind: .movie, start: 0, size: 50, sort: nil,
            filter: LibraryFilter(choices: ["collection": weekend.value]))
        #expect(Set(inWeekend.map(\.title)) == ["Big Buck Bunny", "Sintel"])

        let resolutionField = try #require(movieFields.first { $0.parameter == "resolution" })
        #expect(try await catalog.filterChoices(for: resolutionField).map(\.value).contains("4k"))
        let uhd = try await catalog.itemCount(libraryID: movies.key, kind: .movie, filter: LibraryFilter(choices: ["resolution": "4k"]))
        #expect(uhd > 0 && uhd < total)

        // Every other offered filter, asserted on what comes back. Watch state
        // is shared with other agents' runs, so it is checked against itself.
        func titles(_ library: Library, _ kind: LibraryKind, _ filter: LibraryFilter) async throws -> [MediaItem] {
            try await catalog.items(libraryID: library.key, kind: kind, start: 0, size: 100, sort: nil, filter: filter)
        }
        func choice(_ fields: [LibraryFilterField], _ parameter: String, _ title: String) async throws -> LibraryFilterChoice {
            let field = try #require(fields.first { $0.parameter == parameter }, "no \(parameter) field")
            return try #require(try await catalog.filterChoices(for: field).first { $0.title == title }, "no \(title)")
        }
        let unwatched = try await titles(movies, .movie, LibraryFilter(watchStatus: .unwatched))
        let watched = try await titles(movies, .movie, LibraryFilter(watchStatus: .watched))
        #expect(!unwatched.isEmpty && unwatched.allSatisfy { !$0.isWatched })
        #expect(watched.allSatisfy { $0.isWatched })
        #expect(unwatched.count + watched.count == total)
        let inProgress = try await titles(movies, .movie, LibraryFilter(watchStatus: .inProgress))
        #expect(inProgress.allSatisfy { $0.resumeOffsetMs != nil })
        let unwatchedShows = try await titles(realTV, .show, LibraryFilter(watchStatus: .unwatched))
        let watchedShows = try await titles(realTV, .show, LibraryFilter(watchStatus: .watched))
        #expect(unwatchedShows.count + watchedShows.count == 3)

        let decade = try await choice(movieFields, "decade", "2000s")
        #expect(Set(try await titles(movies, .movie, LibraryFilter(choices: ["decade": decade.value])).map(\.title))
            == ["Big Buck Bunny", "Elephants Dream"])
        let year = try await choice(movieFields, "year", "2010")
        #expect(try await titles(movies, .movie, LibraryFilter(choices: ["year": year.value])).map(\.title) == ["Sintel"])
        let rating = try await choice(fields, "contentRating", "CH-12")
        #expect(Set(try await titles(realMovies, .movie, LibraryFilter(choices: ["contentRating": rating.value])).map(\.title))
            == ["Dune: Part Two", "Knives Out"])
        let studio = try await choice(fields, "studio", "MRC")
        #expect(try await titles(realMovies, .movie, LibraryFilter(choices: ["studio": studio.value])).map(\.title) == ["Knives Out"])
        let actor = try await choice(fields, "actor", "Daniel Craig")
        #expect(try await titles(realMovies, .movie, LibraryFilter(choices: ["actor": actor.value])).map(\.title) == ["Knives Out"])
        let tvFields = try await catalog.filterFields(libraryID: realTV.key, includesCollection: true)
        #expect(!tvFields.contains { $0.parameter == "resolution" || $0.parameter == "decade" })
        let network = try await choice(tvFields, "studio", "NBC")
        #expect(try await titles(realTV, .show, LibraryFilter(choices: ["studio": network.value])).map(\.title) == ["The Office"])

        let genres = try await catalog.genreChoices(libraryID: realMovies.key)
        #expect(genres.map(\.title).contains("Mystery"))
        let mysteries = try await catalog.items(
            libraryID: realMovies.key, kind: .movie, start: 0, size: 50, sort: nil, filter: LibraryFilter(genre: "Mystery"))
        #expect(mysteries.map(\.title) == ["Knives Out"])

        // Show → seasons → episodes.
        let shows = try await catalog.items(
            libraryID: realTV.key, kind: .show, start: 0, size: 50, sort: .titleAscending, filter: LibraryFilter())
        let office = try #require(shows.first { $0.title == "The Office" })
        #expect(shows.first?.title == "The Office")
        #expect(office.episodeCount == 186)
        let seasons = try await catalog.seasons(showID: office.itemID)
        #expect(seasons.map(\.index) == Array(1...9))
        let pilotSeason = try await catalog.episodes(seasonID: seasons[0].itemID)
        #expect(pilotSeason.map(\.index) == Array(1...6).map { Optional($0) })
        #expect(pilotSeason.first?.title == "Pilot")
        #expect(try await catalog.allEpisodes(showID: office.itemID).count == 186)

        // Details, extras, trailers.
        let allMovies = try await catalog.items(
            libraryID: movies.key, kind: .movie, start: 0, size: 100, sort: nil, filter: LibraryFilter())
        let bunny = try #require(allMovies.first { $0.title == "Big Buck Bunny" })
        let extras = try await catalog.extras(itemID: bunny.itemID)
        #expect(extras.first?.kind == .trailer)
        #expect(Set(extras.compactMap(\.kind)) == [.trailer, .deletedScene, .featurette, .behindTheScenes])
        let bunnyDetails = try await catalog.details(itemID: bunny.itemID, checkFiles: false)
        #expect(bunnyDetails.remoteTrailerURL == nil)

        let knivesOut = try #require(try await catalog.items(
            libraryID: realMovies.key, kind: .movie, start: 0, size: 50, sort: nil, filter: LibraryFilter())
            .first { $0.title == "Knives Out" })
        let details = try await catalog.details(itemID: knivesOut.itemID, checkFiles: false)
        #expect(details.remoteTrailerURL?.host?.contains("youtube") == true)
        #expect(details.externalIDs.tmdb == "546554")

        // People.
        let craig = try #require(details.roles?.first { $0.tag == "Daniel Craig" })
        let craigID = try #require(craig.personID)
        #expect(try await catalog.person(id: craigID).tag == "Daniel Craig")
        #expect(try await catalog.personMedia(id: craigID).map(\.title).contains("Knives Out"))

        // Search.
        let groups = try await catalog.searchGroups(query: "office")
        #expect(groups.first { $0.type == "show" }?.items.map(\.title).contains("The Office") == true)
        #expect(groups.first { $0.type == "episode" }?.items.isEmpty == false)

        // Point lookup.
        let copies = try await catalog.items(
            matching: ExternalIDs(uris: ["tmdb://546554"]), kind: .movie, title: "Knives Out", year: 2019)
        #expect(copies.map(\.itemID) == [knivesOut.itemID])
        #expect(try await catalog.items(matching: ExternalIDs(uris: ["tmdb://1"]), kind: .movie, title: "Knives Out", year: nil).isEmpty)

        // History reads without failing; contents depend on the user's plays.
        let history = try await catalog.playbackHistory(
            libraryID: realMovies.key, since: .distantPast, limit: 10, pageSize: 5, accountID: nil)
        #expect(history.allSatisfy { $0.viewedAt != nil && $0.libraryID == realMovies.key })
    }
}
