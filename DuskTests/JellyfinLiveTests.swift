import Foundation
import Testing
@testable import Dusk

/// Runs the client against a real Jellyfin server. Skipped unless configured,
/// so normal unit runs never touch the network:
///
///     TEST_RUNNER_DUSK_JELLYFIN_LIVE_URL=http://jellyfin-demo \
///     TEST_RUNNER_DUSK_JELLYFIN_LIVE_USER=duskcompare \
///     TEST_RUNNER_DUSK_JELLYFIN_LIVE_PASSWORD_FILE=$HOME/.config/jellyfin-demo/compare-password \
///     xcodebuild test … -only-testing:DuskTests/JellyfinLiveTests
///
/// (`xcodebuild` strips the `TEST_RUNNER_` prefix.) Read-only apart from
/// session bookkeeping: it signs in with its own throw-away `DeviceId`, so no
/// other session is logged out, reads, asks for playback decisions, reads one
/// byte of a direct stream, and logs out again.
@Suite("Jellyfin live", .serialized, .enabled(if: JellyfinLiveConfig.current != nil, "no live server configured"))
struct JellyfinLiveTests {
    @Test(.timeLimit(.minutes(3)))
    func clientAgainstLiveServer() async throws {
        let config = try #require(JellyfinLiveConfig.current)
        let password = try String(contentsOfFile: config.passwordFile, encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        let deviceName = "Dusk Tests’ Sim \"Ü\", 50% = ok"
        let identity = JellyfinClientIdentity(
            device: deviceName, deviceID: "dusk-tests-\(UUID().uuidString.prefix(8).lowercased())", version: "0.0-test")
        let anonymous = JellyfinClient(baseURL: config.url, identity: identity)

        let info = try await anonymous.send(JellyfinAPI.publicSystemInfo())
        #expect(info.productName == "Jellyfin Server")
        _ = try await anonymous.send(JellyfinAPI.quickConnectEnabled())

        let auth = try await anonymous.send(JellyfinAPI.authenticateByName(username: config.user, password: password))
        let client = anonymous.signedIn(JellyfinCredentials(accessToken: auth.accessToken, userID: auth.user.id))
        do {
            try await exercise(client, serverID: info.id, auth: auth, deviceName: deviceName)
        } catch {
            _ = try? await client.send(JellyfinAPI.logout())
            throw error
        }
        _ = try await client.send(JellyfinAPI.logout())
        await #expect(throws: JellyfinError.unauthorized) { _ = try await client.send(JellyfinAPI.currentUser()) }
    }

    private func exercise(_ client: JellyfinClient, serverID: String,
                          auth: JellyfinAuthenticationResultDTO, deviceName: String) async throws {
        // The percent-encoded header values arrive decoded.
        #expect(auth.serverID == serverID)
        #expect(auth.sessionInfo?.deviceName == deviceName)
        #expect(auth.sessionInfo?.deviceID == client.identity.deviceID)
        #expect(auth.sessionInfo?.client == "Dusk")

        let me = try await client.send(JellyfinAPI.currentUser())
        #expect(me.policy != nil && me.configuration != nil)
        _ = try await client.send(JellyfinAPI.endpointInfo())
        _ = try await client.send(JellyfinAPI.postCapabilities())

        let views = try await client.send(JellyfinAPI.userViews())
        let movies = try #require(views.items.first { $0.name == "Movies" })
        let realMovies = try #require(views.items.first { $0.name == "Real Movies" })
        let realTV = try #require(views.items.first { $0.name == "Real TV" })

        var browse = JellyfinItemQuery()
        browse.parentID = realMovies.id
        browse.recursive = true
        browse.includeItemTypes = [.movie]
        browse.sortBy = [.sortName]
        browse.fields = [.providerIDs, .dateCreated, .overview]
        let realList = try await client.send(JellyfinAPI.items(browse))
        #expect(realList.items.count >= 3)
        #expect(realList.items.allSatisfy { $0.providerIDs != nil })

        // A misspelt parameter is ignored with 200; validation catches it.
        var typo = JellyfinAPI.items(browse)
        typo.query.append(URLQueryItem(name: "limt", value: "1"))
        var limited = browse
        limited.limit = 1
        let typoed = JellyfinRequest<JellyfinQueryResult<JellyfinItemDTO>>(
            path: typo.path, query: typo.query, isUserScoped: true,
            decode: JellyfinAPI.items(limited).decode)
        await #expect(throws: JellyfinError.self) { _ = try await client.send(typoed) }
        #expect(try await client.send(JellyfinAPI.items(limited)).items.count == 1)

        // Every torture file and the real films decode in full.
        var torture = JellyfinItemQuery()
        torture.parentID = movies.id
        torture.recursive = true
        torture.includeItemTypes = [.movie]
        let tortureList = try await client.send(JellyfinAPI.items(torture))
        #expect(tortureList.items.count >= 12)
        for summary in tortureList.items + realList.items {
            let item = try await client.send(JellyfinAPI.item(id: summary.id))
            #expect(item.mediaSources?.first?.streams.contains { $0.type == .video } == true, "\(item.name ?? item.id)")
        }

        // Playback decision + one byte of the direct stream through ApiKey.
        let knivesOut = try #require(realList.items.first { $0.name == "Knives Out" })
        var request = JellyfinPlaybackInfoRequestDTO(
            mediaSourceID: knivesOut.id, audioStreamIndex: 1, subtitleStreamIndex: -1,
            deviceProfile: JellyfinDeviceProfileDTO(
                directPlayProfiles: [JellyfinDirectPlayProfileDTO(type: "Video")],
                subtitleProfiles: [JellyfinSubtitleProfileDTO(format: "srt", method: .embed)]))
        request.enableTranscoding = false
        // Without a bitrate the server assumes a low default and refuses
        // direct play for a 1080p remux.
        request.maxStreamingBitrate = 400_000_000
        let decision = try await client.send(JellyfinAPI.playbackInfo(itemID: knivesOut.id, request))
        #expect(decision.mediaSources.first?.supportsDirectPlay == true,
                "\(decision.mediaSources.first?.transcodeReasons ?? []) \(decision.errorCode ?? "")")
        #expect(decision.playSessionID?.isEmpty == false)
        let stream = JellyfinAPI.directStreamPath(itemID: knivesOut.id, mediaSourceID: knivesOut.id)
        var range = URLRequest(url: try client.authenticatedURL(path: stream.path, query: stream.query))
        range.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession.shared.data(for: range)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect(bytes.count == 1)

        // A show: seasons, episodes, skip segments.
        var shows = JellyfinItemQuery()
        shows.parentID = realTV.id
        shows.recursive = true
        shows.includeItemTypes = [.series]
        let office = try #require(try await client.send(JellyfinAPI.items(shows)).items.first { $0.name == "The Office" })
        let seasons = try await client.send(JellyfinAPI.seasons(seriesID: office.id))
        let seasonOne = try #require(seasons.items.first { $0.indexNumber == 1 })
        let episodes = try await client.send(JellyfinAPI.episodes(
            seriesID: office.id, seasonID: seasonOne.id, fields: [.mediaSources, .chapters, .trickplay]))
        let pilot = try #require(episodes.items.first { $0.indexNumber == 1 })
        let segments = try await client.send(JellyfinAPI.mediaSegments(itemID: pilot.id, types: [.intro, .outro]))
        #expect(segments.items.contains { $0.type == .intro })
        #expect(segments.items.allSatisfy { $0.type == .intro || $0.type == .outro })

        // Home rows, search, filters, sessions.
        _ = try await client.send(JellyfinAPI.resume(limit: 10))
        _ = try await client.send(JellyfinAPI.nextUp(seriesID: office.id, limit: 1))
        let latest = try await client.send(JellyfinAPI.latest(parentID: realTV.id, limit: 5))
        #expect(latest.count <= 5)
        let hints = try await client.send(JellyfinAPI.searchHints(term: "office", limit: 5))
        #expect(!hints.searchHints.isEmpty)
        _ = try await client.send(JellyfinAPI.itemFilters(parentID: realMovies.id))
        _ = try await client.send(JellyfinAPI.genres(parentID: realMovies.id))
        let sessions = try await client.send(JellyfinAPI.sessions(deviceID: client.identity.deviceID))
        #expect(sessions.contains { $0.deviceID == client.identity.deviceID })
    }
}

struct JellyfinLiveConfig: Sendable {
    let url: URL
    let user: String
    let passwordFile: String

    static let current: JellyfinLiveConfig? = {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["DUSK_JELLYFIN_LIVE_URL"], let url = URL(string: address),
              let user = environment["DUSK_JELLYFIN_LIVE_USER"],
              let passwordFile = environment["DUSK_JELLYFIN_LIVE_PASSWORD_FILE"] else { return nil }
        return JellyfinLiveConfig(url: url, user: user, passwordFile: passwordFile)
    }()
}
