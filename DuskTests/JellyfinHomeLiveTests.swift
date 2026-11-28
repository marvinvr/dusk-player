import Foundation
import Testing
@testable import Dusk

/// J-04 against a real Jellyfin server, gated like `JellyfinLiveTests`
/// (`TEST_RUNNER_DUSK_JELLYFIN_LIVE_*`). Read-only: it signs in with its own
/// throw-away `DeviceId`, reads Home and the library rows, and logs out.
/// Watch state on jellyfin-demo moves while other checks run, so it asserts
/// on the rows' shape and on titles the T-0 data fixes (05-plan §7), not on
/// what is in progress right now.
@MainActor
@Suite("Jellyfin home live", .serialized, .enabled(if: JellyfinLiveConfig.current != nil, "no live server configured"))
struct JellyfinHomeLiveTests {
    @Test(.timeLimit(.minutes(3)))
    func homeAgainstLiveServer() async throws {
        let config = try #require(JellyfinLiveConfig.current)
        let password = try String(contentsOfFile: config.passwordFile, encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        let identity = JellyfinClientIdentity(
            device: "Dusk Tests", deviceID: "dusk-tests-\(UUID().uuidString.prefix(8).lowercased())", version: "0.0-test")
        let anonymous = JellyfinClient(baseURL: config.url, identity: identity)
        let auth = try await anonymous.send(JellyfinAPI.authenticateByName(username: config.user, password: password))
        let client = anonymous.signedIn(JellyfinCredentials(accessToken: auth.accessToken, userID: auth.user.id))
        let serverID = JellyfinID.normalized(auth.serverID ?? "")
        do {
            try await exercise(JellyfinHome(serverID: serverID, client: { client }),
                               catalog: JellyfinCatalog(serverID: serverID, client: { client }))
        } catch {
            _ = try? await client.send(JellyfinAPI.logout())
            throw error
        }
        _ = try await client.send(JellyfinAPI.logout())
    }

    private func exercise(_ home: JellyfinHome, catalog: JellyfinCatalog) async throws {
        let libraries = try await catalog.libraries()
        let realTV = try #require(libraries.first { $0.title == "Real TV" })
        let realMovies = try #require(libraries.first { $0.title == "Real Movies" })

        // Home: Recently Added per film/TV/video library, nothing else.
        let rows = try await home.homeRows()
        #expect(rows.allSatisfy { $0.kind == .recentlyAdded && $0.title.hasPrefix("Recently Added in ") })
        #expect(!rows.contains { $0.title.contains("Photos") || $0.title.contains("Collections") })
        let tvRow = try #require(rows.first { $0.libraryScope == .section(realTV.key) })
        #expect(tvRow.items.allSatisfy { $0.libraryID == realTV.key })
        // Latest groups episodes into their season or show.
        #expect(tvRow.items.contains { $0.type == .show || $0.type == .season })
        // The expansion and Show All read the same list as the row.
        let expanded = try await home.rowItems(rowKey: try #require(tvRow.key), start: 0, size: 3)
        #expect(expanded.map(\.id) == Array(tvRow.items.prefix(3)).map(\.id))

        // Continue Watching: in-progress titles and next episodes, newest first,
        // one per show, every one with its library.
        let continueWatching = try await home.continueWatching()
        #expect(continueWatching.allSatisfy { $0.libraryID != nil })
        let shows = continueWatching.compactMap(\.grandparentID)
        #expect(Set(shows).count == shows.count)
        let dates = continueWatching.compactMap(\.lastPlayedAt)
        #expect(dates == dates.sorted(by: >))

        // A library's Recommended rows, in Plex's order, empty ones left out.
        let tvRows = try await home.libraryRows(libraryID: realTV.key, count: 12)
        let order = ["tv.inprogress", "tv.recentlyaired", "tv.recentlyadded", "tv.toprated", "tv.recentlyviewed"]
        let identifiers = tvRows.compactMap { $0.hubIdentifier?.components(separatedBy: ".").prefix(2).joined(separator: ".") }
        #expect(identifiers == order.filter(identifiers.contains))
        #expect(identifiers.contains("tv.recentlyaired"))
        #expect(tvRows.allSatisfy { !$0.items.isEmpty })
        let top = try #require(tvRows.first { $0.title == "Top Rated TV" })
        #expect(Set(top.items.map(\.title)).isSubset(of: ["The Office", "Severance", "Ted Lasso"]))

        let promoted = try await home.promotedLibraryRows(libraryID: realMovies.key, count: 12)
        #expect(promoted.allSatisfy { $0.kind == .continueWatching || $0.kind == .recentlyAdded })

        // Hidden Rows reads the switch without changing it.
        let managed = try await home.managedRows(libraryID: realMovies.key)
        #expect(managed.count == 1)
    }
}
