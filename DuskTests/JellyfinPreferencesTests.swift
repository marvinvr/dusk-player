import Foundation
import Testing
@testable import Dusk

/// J-11: library order and hidden libraries on `OrderedViews` /
/// `MyMediaExcludes`, language defaults, subtitle search, pre-rolls, hidden
/// libraries in search and the sign-in address race.
@MainActor
@Suite("Jellyfin account preferences, subtitle search, pre-rolls")
struct JellyfinPreferencesTests {
    nonisolated static let serverID = "99d23e4060434e129f9ae072bf97d30d"
    nonisolated static let userID = "7b20244faaf946818eac31a8f0f72c7b"
    nonisolated static let movies = "f137a2dd21bbc1b99aa5c0f6bf02a805"
    nonisolated static let shows = "a8ee6ba847f2671fe06a474d749352b9"
    nonisolated static let shorts = "d9afecc3a6abc4b6233bdd3a92bc2a7d"
    nonisolated static let playlists = "07ccd1a1904596a9f460271dd5d0b0da"
    nonisolated static let collections = "9d7ad6afe9afa2dab1a2f6e00ad28fa6"

    // MARK: - Fixtures

    /// A signed-in account whose server is `host`, served by `handler`.
    private func account(
        host: String,
        policy: JellyfinPolicySnapshot = .serverDefaults,
        handler: @escaping JellyfinStubURLProtocol.Handler
    ) -> (JellyfinAccountProvider, JellyfinAccountRecord) {
        JellyfinStubURLProtocol.register(host: host, handler: handler)
        let account = JellyfinAccountProvider(sessions: JellyfinSessions(urlProtocolClasses: [JellyfinStubURLProtocol.self]))
        let record = JellyfinAccountRecord(
            serverID: Self.serverID,
            serverName: "Demo",
            serverVersion: "10.11.0",
            userID: Self.userID,
            userName: "duskcompare",
            baseURL: URL(string: "http://\(host)")!,
            localAddress: nil,
            deviceID: "device-\(host)",
            policy: policy,
            hasPrimaryImage: false
        )
        account.state.records = [record]
        account.state.tokens = [record.id: "t"]
        account.state.activeAccountID = record.id
        return (account, record)
    }

    private static func host(_ name: String) -> String {
        "\(name)-\(UUID().uuidString.prefix(8).lowercased()).test"
    }

    nonisolated private static func user(configuration: String) -> String {
        #"{"Id":"\#(userID)","Name":"duskcompare","Configuration":\#(configuration)}"#
    }

    /// The live default configuration plus a custom order.
    nonisolated private static let configuration = """
    {"PlayDefaultAudioTrack":true,"SubtitleLanguagePreference":"","DisplayMissingEpisodes":false,\
    "GroupedFolders":[],"SubtitleMode":"Default","DisplayCollectionsView":false,"EnableLocalPassword":false,\
    "OrderedViews":["\(playlists)","\(movies)","\(shows)"],"LatestItemsExcludes":["\(movies)"],\
    "MyMediaExcludes":["\(shorts)","\(playlists)"],"HidePlayedInLatest":true,"RememberAudioSelections":true,\
    "RememberSubtitleSelections":true,"EnableNextEpisodeAutoPlay":true,"CastReceiverId":"F007D354"}
    """

    private func library(_ key: String, _ title: String) -> Library {
        JellyfinItemMapper.mapLibrary(
            try! JellyfinJSON.decode(
                JellyfinItemDTO.self,
                from: Data(#"{"Id":"\#(key)","Name":"\#(title)","Type":"CollectionFolder","CollectionType":"movies"}"#.utf8)
            ),
            serverID: Self.serverID,
            homeVideosHoldPhotos: false
        )!
    }

    // MARK: - Library layout

    @Test func layoutReadsOrderedViewsAndExcludesAsLibraryIDs() async throws {
        let host = Self.host("layout")
        let (account, _) = account(host: host) { request in
            request.url?.path == "/Users/Me" ? (200, Self.user(configuration: Self.configuration)) : nil
        }
        defer { JellyfinStubURLProtocol.unregister(host: host) }

        let layout = try await account.preferences.libraryLayout()
        #expect(layout.entries.map(\.libraryID) == [Self.playlists, Self.movies, Self.shows, Self.shorts])
        #expect(layout.entries.map(\.isHidden) == [true, false, false, true])
        // Entry ids are `Library.id`s, so the arrangement can match them.
        let movies = library(Self.movies, "Movies")
        #expect(layout.entries[1].id == movies.id)
        #expect(LibraryOrderArrangement.hiddenIdentities(
            layout: layout, machineIdentifiers: [movies.serverID!]
        ) == ["\(Self.serverID)|\(Self.playlists)", "\(Self.serverID)|\(Self.shorts)"])
    }

    @Test func emptyConfigurationIsNeverCustomized() async throws {
        let host = Self.host("fresh")
        let (account, _) = account(host: host) { _ in
            (200, Self.user(configuration: #"{"OrderedViews":[],"MyMediaExcludes":[]}"#))
        }
        defer { JellyfinStubURLProtocol.unregister(host: host) }
        #expect(try await account.preferences.libraryLayout() == .neverCustomized)
    }

    @Test func saveRereadsAndSendsTheWholeConfigurationBack() async throws {
        let host = Self.host("save")
        let posted = BodyBox()
        let (account, _) = account(host: host) { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/Users/Me"): return (200, Self.user(configuration: Self.configuration))
            case ("GET", "/UserViews"):
                // The effective order: the account's, then the rest by name.
                let ids = [Self.collections, Self.movies, Self.playlists, Self.shows, Self.shorts]
                let items = ids.map { #"{"Id":"\#($0)","Name":"v","Type":"CollectionFolder","UserData":{}}"# }
                return (200, #"{"Items":[\#(items.joined(separator: ","))],"TotalRecordCount":5}"#)
            case ("POST", "/Users/Configuration"):
                guard request.url?.query?.contains("userId=\(Self.userID)") == true else { return (400, "") }
                posted.set(request.bodyData)
                return (204, "")
            default: return nil
            }
        }
        defer { JellyfinStubURLProtocol.unregister(host: host) }

        let shows = library(Self.shows, "Real TV")
        let movies = library(Self.movies, "Movies")
        let shorts = library(Self.shorts, "Shorts")
        var reads: [AccountLibraryLayout] = []
        let written = try await account.preferences.saveLibraryLayout(
            [shows, shorts, movies],
            hidden: [movies.id],
            serverIDs: [Self.serverID],
            didRead: { reads.append($0) }
        )

        #expect(reads.count == 1)
        let body = try #require(posted.value.flatMap { try? JSONDecoder().decode(DuskJSONValue.self, from: $0) })
        // Dusk's libraries in the new order in their slots; Collections and
        // Playlists stay where the server shows them.
        #expect(body["OrderedViews"]?.arrayValue?.compactMap(\.stringValue) == [Self.collections, Self.shows, Self.playlists, Self.shorts, Self.movies])
        // Shorts shown again, Movies hidden, Playlists' exclusion untouched.
        #expect(body["MyMediaExcludes"]?.arrayValue?.compactMap(\.stringValue) == [Self.playlists, Self.movies])
        // Everything else round-trips, keys Dusk has no type for included.
        #expect(body["CastReceiverId"]?.stringValue == "F007D354")
        #expect(body["EnableLocalPassword"]?.boolValue == false)
        #expect(body["LatestItemsExcludes"]?.arrayValue?.compactMap(\.stringValue) == [Self.movies])
        #expect(body["SubtitleMode"]?.stringValue == "Default")
        #expect(body.objectValue?.count == (try JSONDecoder().decode(DuskJSONValue.self, from: Data(Self.configuration.utf8))).objectValue?.count)

        #expect(written.entries.filter(\.isHidden).map(\.libraryID) == [Self.playlists, Self.movies])
        #expect(await JellyfinAccountPreferences(account: account).hiddenViewIDs(serverID: Self.serverID) == [Self.playlists, Self.movies])
    }

    @Test func saveWithoutHiddenKeepsTheExclusions() async throws {
        let host = Self.host("keep")
        let posted = BodyBox()
        let (account, _) = account(host: host) { request in
            if request.httpMethod == "POST" { posted.set(request.bodyData); return (204, "") }
            return (200, Self.user(configuration: Self.configuration))
        }
        defer { JellyfinStubURLProtocol.unregister(host: host) }

        _ = try await account.preferences.saveLibraryLayout(
            [library(Self.movies, "Movies"), library(Self.shows, "Real TV")],
            hidden: nil, serverIDs: [Self.serverID], didRead: { _ in }
        )
        let body = try #require(posted.value.flatMap { try? JSONDecoder().decode(DuskJSONValue.self, from: $0) })
        #expect(body["MyMediaExcludes"]?.arrayValue?.compactMap(\.stringValue) == [Self.shorts, Self.playlists])
        #expect(body["OrderedViews"]?.arrayValue?.compactMap(\.stringValue) == [Self.playlists, Self.movies, Self.shows])
    }

    @Test func aServerThatDidNotAnswerIsNeverWritten() async throws {
        let host = Self.host("unanswered")
        let (account, _) = account(host: host) { _ in (200, Self.user(configuration: Self.configuration)) }
        defer { JellyfinStubURLProtocol.unregister(host: host) }
        await #expect(throws: MediaServiceError.self) {
            _ = try await account.preferences.saveLibraryLayout([], hidden: nil, serverIDs: ["other"], didRead: { _ in })
        }
    }

    @Test func withoutPreferenceAccessTheLayoutStaysOnThisDevice() async throws {
        let host = Self.host("local")
        let posts = BodyBox()
        var policy = JellyfinPolicySnapshot.serverDefaults
        policy.enableUserPreferenceAccess = false
        let (account, record) = account(host: host, policy: policy) { request in
            if request.httpMethod == "POST" { posts.set(Data()); return (403, "") }
            return (200, Self.user(configuration: Self.configuration))
        }
        defer {
            JellyfinStubURLProtocol.unregister(host: host)
            JellyfinLibraryViewsStore.remove(accountID: record.id)
        }

        // Before any write: the server's own lists.
        #expect(try await account.preferences.libraryLayout().entries.count == 4)

        let movies = library(Self.movies, "Movies")
        _ = try await account.preferences.saveLibraryLayout(
            [movies, library(Self.shows, "Real TV")],
            hidden: [movies.id], serverIDs: [Self.serverID], didRead: { _ in }
        )
        #expect(posts.value == nil)
        let stored = try #require(JellyfinLibraryViewsStore.load(accountID: record.id))
        #expect(stored.ordered == [Self.playlists, Self.movies, Self.shows])
        #expect(stored.excluded == [Self.shorts, Self.playlists, Self.movies])

        // Later reads come from the device.
        account.state.libraryViews = [:]
        let layout = try await account.preferences.libraryLayout()
        #expect(layout.entries.first { $0.libraryID == Self.movies }?.isHidden == true)
        #expect(layout.entries.first { $0.libraryID == Self.shows }?.isHidden == false)
    }

    @Test func aRefusedWriteFallsBackToThisDevice() async throws {
        let host = Self.host("refused")
        let (account, record) = account(host: host) { request in
            request.httpMethod == "POST" ? (403, "") : (200, Self.user(configuration: Self.configuration))
        }
        defer {
            JellyfinStubURLProtocol.unregister(host: host)
            JellyfinLibraryViewsStore.remove(accountID: record.id)
        }
        let written = try await account.preferences.saveLibraryLayout(
            [library(Self.shows, "Real TV")], hidden: [], serverIDs: [Self.serverID], didRead: { _ in }
        )
        #expect(Array(written.entries.map(\.libraryID).prefix(3)) == [Self.playlists, Self.movies, Self.shows])
        #expect(JellyfinLibraryViewsStore.load(accountID: record.id).map { Array($0.ordered.prefix(3)) } == [Self.playlists, Self.movies, Self.shows])
    }

    @Test func rearrangedKeepsOtherViewsAndNormalisesIDs() {
        let views = JellyfinLibraryViews(ordered: ["A", "b", "c"], excluded: ["C", "d"])
        #expect(views.ordered == ["a", "b", "c"])
        #expect(views.excluded == ["c", "d"])
        let moved = views.rearranged(order: ["c", "B"], hidden: ["b"])
        #expect(moved.ordered == ["a", "c", "b"])
        #expect(moved.excluded == ["d", "b"])
        // A never-ordered account: the server's order places every view.
        let fresh = JellyfinLibraryViews(ordered: [], excluded: [])
            .rearranged(order: ["tv", "movies"], hidden: nil, serverOrder: ["collections", "movies", "playlists", "tv"])
        #expect(fresh.ordered == ["collections", "tv", "playlists", "movies"])
        // A library the server did not list goes last.
        #expect(fresh.rearranged(order: ["tv", "movies", "new"], hidden: nil).ordered.last == "new")
    }

    // MARK: - Language defaults

    private func config(_ json: String) throws -> JellyfinUserConfigurationDTO {
        try JellyfinJSON.decode(JellyfinUserConfigurationDTO.self, from: Data(json.utf8))
    }

    @Test func untouchedConfigurationSaysNothing() throws {
        let defaults = JellyfinAccountPreferences.languageDefaults(from: try config(Self.configuration))
        #expect(defaults == AccountLanguageDefaults(audioLanguage: nil, subtitleLanguage: nil, subtitleMode: nil))
    }

    @Test func languagesAndSubtitleModesMapToDusk() throws {
        let defaults = JellyfinAccountPreferences.languageDefaults(from: try config(
            #"{"AudioLanguagePreference":"ger","SubtitleLanguagePreference":"fre","SubtitleMode":"Smart","PlayDefaultAudioTrack":false}"#
        ))
        #expect(defaults == AccountLanguageDefaults(audioLanguage: "de", subtitleLanguage: "fr", subtitleMode: .auto))
        let modes: [String: SubtitleMode?] = [
            "None": .off, "OnlyForced": .off, "Smart": .auto, "Always": .always, "Default": nil, "always": .always,
        ]
        for (mode, expected) in modes {
            #expect(JellyfinAccountPreferences.languageDefaults(from: try config(#"{"SubtitleMode":"\#(mode)"}"#)).subtitleMode == expected)
        }
    }

    @Test func threeLetterCodesBecomeDusksTwoLetterOnes() {
        let cases = ["eng": "en", "ger": "de", "deu": "de", "fre": "fr", "chi": "zh", "dut": "nl", "cze": "cs",
                     "jpn": "ja", "nor": "no", "en": "en", "DE": "de"]
        for (code, expected) in cases {
            #expect(JellyfinLanguageCodes.twoLetter(code) == expected, "\(code)")
        }
        #expect(JellyfinLanguageCodes.twoLetter("") == nil)
        #expect(JellyfinLanguageCodes.twoLetter(nil) == nil)
        let back = ["en": "eng", "de": "ger", "fr": "fre", "zh": "chi", "nl": "dut", "cs": "cze", "no": "nor",
                    "ja": "jpn", "deu": "ger", "eng": "eng"]
        for (code, expected) in back {
            #expect(JellyfinLanguageCodes.threeLetter(code) == expected, "\(code)")
        }
    }

    // MARK: - Subtitle search

    private func server(_ account: JellyfinAccountProvider) -> JellyfinServerProvider {
        JellyfinServerProvider(
            account: account,
            seed: ServerSessionSeed(serverID: Self.serverID, name: "Demo", version: nil, owned: true, sourceTitle: nil)
        )
    }

    @Test func subtitleSearchAsksInThreeLetterCodesAndKeepsTheServersOrder() async throws {
        let host = Self.host("subs")
        let paths = PathBox()
        let (account, _) = account(host: host) { request in
            paths.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            if request.httpMethod == "POST" { return (204, "") }
            return (200, """
            [{"Id":"os-2","ThreeLetterISOLanguageName":"ger","ProviderName":"Open Subtitles","Name":"Film.2020.srt","Format":"srt","HearingImpaired":false,"Forced":false},
             {"Id":"os-1","ThreeLetterISOLanguageName":"ger","ProviderName":"Open Subtitles","Name":"Film.2020.SDH.srt","Format":"srt","HearingImpaired":true}]
            """)
        }
        defer { JellyfinStubURLProtocol.unregister(host: host) }
        let facet = try #require(server(account).subtitleSearch)

        let results = try await facet.search(itemID: "abc", languageCode: "de", hearingImpaired: false, forced: false)
        #expect(results.map(\.id) == ["os-2", "os-1"])
        #expect(results[0].key == "os-2")
        #expect(results[0].providerTitle == "Open Subtitles")
        #expect(results[0].format == "srt")
        #expect(results[1].isHearingImpaired == true)
        let hearingImpaired = try await facet.search(itemID: "abc", languageCode: "de", hearingImpaired: true, forced: false)
        #expect(hearingImpaired.map(\.id) == ["os-1"])

        try await facet.install(results[0], itemID: "abc")
        #expect(paths.values == [
            "GET /Items/abc/RemoteSearch/Subtitles/ger",
            "GET /Items/abc/RemoteSearch/Subtitles/ger",
            "POST /Items/abc/RemoteSearch/Subtitles/os-2",
        ])
    }

    @Test func subtitlePermissionFollowsThePolicy() {
        var policy = JellyfinPolicySnapshot.serverDefaults
        #expect(!policy.permissions.canInstallSubtitles)
        policy.enableSubtitleManagement = true
        #expect(policy.permissions.canInstallSubtitles)
    }

    // MARK: - Pre-rolls

    @Test func prerollsAreTheIntrosReadAsFullItems() async throws {
        let host = Self.host("intros")
        let intro = "3d8205dff1a24802bbd7d18982d37ab0"
        let (account, _) = account(host: host) { request in
            switch request.url?.path {
            case "/Items/film/Intros":
                return (200, #"{"Items":[{"Id":"\#(intro)","Name":"Dusk Preroll","Type":"Video","MediaSources":[{"Id":"\#(intro)","Container":"mp4","MediaStreams":[]}]}],"TotalRecordCount":1}"#)
            case "/Items/\(intro)":
                return (200, """
                {"Id":"\(intro)","Name":"Dusk Preroll","Type":"Video","RunTimeTicks":81199999,"UserData":{"Played":false},
                 "MediaSources":[{"Id":"\(intro)","Container":"mp4","Path":"/data/Prerolls/Dusk Preroll.mp4",
                   "MediaStreams":[{"Type":"Video","Codec":"h264","Index":0,"Width":1920,"Height":1080},
                                   {"Type":"Audio","Codec":"aac","Index":1,"Channels":2}]}]}
                """)
            case "/Items/plain/Intros":
                return (200, #"{"Items":[],"TotalRecordCount":0}"#)
            default: return (404, "")
            }
        }
        defer { JellyfinStubURLProtocol.unregister(host: host) }
        let playback = server(account).playback

        let prerolls = try await playback.prerolls(before: "film")
        #expect(prerolls.map(\.itemID) == [intro])
        let part = try #require(prerolls.first?.media.first?.parts.first)
        #expect(part.streams.contains { $0.kind == .video && $0.codec == "h264" })
        #expect(playback.directPlayURL(for: part)?.path == "/Videos/\(intro)/stream")
        #expect(try await playback.prerolls(before: "plain").isEmpty)
    }

    // MARK: - Hidden libraries in search

    @Test func searchDropsHitsFromHiddenViews() async throws {
        let host = Self.host("search")
        let (account, _) = account(host: host) { request in
            let query = request.url?.query ?? ""
            switch request.url?.path {
            case "/Users/Me":
                return (200, Self.user(configuration: #"{"OrderedViews":[],"MyMediaExcludes":["\#(Self.shorts)"]}"#))
            case "/Items" where query.contains("parentId=\(Self.shorts)"):
                return (200, query.contains("Series")
                    ? #"{"Items":[{"Id":"hidden-show","Name":"Weekend Projects","Type":"Series"}],"TotalRecordCount":1}"#
                    : #"{"Items":[],"TotalRecordCount":0}"#)
            case "/Items" where query.contains("Series"):
                return (200, #"{"Items":[{"Id":"hidden-show","Name":"Weekend Projects","Type":"Series","UserData":{}},{"Id":"office","Name":"The Office","Type":"Series","UserData":{}}],"TotalRecordCount":2}"#)
            case "/Items":
                return (200, #"{"Items":[],"TotalRecordCount":0}"#)
            default: return (404, "")
            }
        }
        defer { JellyfinStubURLProtocol.unregister(host: host) }

        let rows = try await server(account).catalog.searchGroups(query: "e")
        #expect(rows.count == 1)
        #expect(rows.first?.items.map(\.itemID) == ["office"])
    }

    // MARK: - Address race

    nonisolated private static let info = try! JellyfinJSON.decode(
        JellyfinPublicSystemInfoDTO.self,
        from: Data(#"{"Id":"\#(serverID)","ProductName":"Jellyfin Server","ServerName":"Demo"}"#.utf8)
    )

    @Test func aBareHostDoesNotWaitForAHangingHTTPS() async {
        let candidates = JellyfinAddress.candidates(for: "jellyfin-demo")
        let clock = ContinuousClock()
        let started = clock.now
        let outcomes = await JellyfinSignInFlow.race(candidates, grace: .milliseconds(200)) { url in
            if url.scheme == "http", url.port == nil { return .init(info: Self.info) }
            try? await Task.sleep(for: .seconds(30))
            return .init(failure: "timed out")
        }
        #expect(clock.now - started < .seconds(5))
        #expect(outcomes.firstIndex { $0?.info != nil } == candidates.firstIndex { $0.absoluteString == "http://jellyfin-demo" })
    }

    @Test func httpsWinsWhenItAnswersWithinTheGrace() async {
        let candidates = JellyfinAddress.candidates(for: "jellyfin.example.com")
        let outcomes = await JellyfinSignInFlow.race(candidates, grace: .seconds(2)) { url in
            switch (url.scheme, url.port) {
            case ("http", nil): return .init(info: Self.info)
            case ("https", nil):
                try? await Task.sleep(for: .milliseconds(150))
                return .init(info: Self.info)
            default:
                try? await Task.sleep(for: .seconds(30))
                return .init(failure: "timed out")
            }
        }
        #expect(outcomes.firstIndex { $0?.info != nil } == 0)
        #expect(candidates[0].absoluteString == "https://jellyfin.example.com")
    }

    @Test func theMostPreferredAnswerIsTakenWithoutTheGrace() async {
        let candidates = JellyfinAddress.candidates(for: "jellyfin.example.com")
        let clock = ContinuousClock()
        let started = clock.now
        let outcomes = await JellyfinSignInFlow.race(candidates, grace: .seconds(20)) { url in
            if url.scheme == "https", url.port == nil { return .init(info: Self.info) }
            try? await Task.sleep(for: .seconds(30))
            return .init(failure: "timed out")
        }
        #expect(clock.now - started < .seconds(5))
        #expect(outcomes[0]?.info != nil)
    }

    @Test func everyCandidateFailingEndsTheRace() async {
        let candidates = JellyfinAddress.candidates(for: "nothing.test")
        let outcomes = await JellyfinSignInFlow.race(candidates, grace: .seconds(20)) { _ in .init(failure: "refused") }
        #expect(outcomes.allSatisfy { $0?.failure == "refused" })
    }
}

/// Pins the Plex subtitle requests as they were before the facet moved
/// behind `SubtitleSearchProviding` (J-11).
@MainActor
@Suite("Plex subtitle search requests")
struct PlexSubtitleSearchRequestTests {
    @MainActor
    final class RecordingTransport: PlexServerTransport {
        struct Call: Equatable {
            let method: String
            let path: String
            let query: [URLQueryItem]?
            let timeout: TimeInterval?
            let serverID: String?
        }

        var calls: [Call] = []
        var response = Data(#"{"MediaContainer":{"size":1,"Stream":[{"id":0,"key":"/sub/1","codec":"srt","languageCode":"eng","providerTitle":"OpenSubtitles","title":"Film.srt","hearingImpaired":false}]}}"#.utf8)

        func rawServerRequest(
            method: String,
            path: String,
            queryItems: [URLQueryItem]?,
            timeoutInterval: TimeInterval?,
            serverID: String?
        ) async throws -> Data {
            calls.append(Call(method: method, path: path, query: queryItems, timeout: timeoutInterval, serverID: serverID))
            return response
        }

        func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data, serverID: String?) throws -> T {
            try JSONDecoder().decode(type, from: data)
        }
    }

    @Test func searchAndInstallSendTodaysRequests() async throws {
        let transport = RecordingTransport()
        let facet = PlexSubtitleSearch(serverID: "machine", transport: transport)

        let results = try await facet.search(itemID: "42", languageCode: " EN ", hearingImpaired: true, forced: false)
        #expect(results.map(\.key) == ["/sub/1"])
        try await facet.install(results[0], itemID: "42")

        #expect(transport.calls == [
            .init(method: "GET", path: "/library/metadata/42/subtitles", query: [
                URLQueryItem(name: "language", value: "en"),
                URLQueryItem(name: "hearingImpaired", value: "1"),
                URLQueryItem(name: "forced", value: "0"),
            ], timeout: nil, serverID: "machine"),
            .init(method: "PUT", path: "/library/metadata/42/subtitles", query: [
                URLQueryItem(name: "key", value: "/sub/1"),
                URLQueryItem(name: "codec", value: "srt"),
                URLQueryItem(name: "language", value: "eng"),
                URLQueryItem(name: "hearingImpaired", value: "0"),
                URLQueryItem(name: "providerTitle", value: "OpenSubtitles"),
                URLQueryItem(name: "title", value: "Film.srt"),
            ], timeout: 30, serverID: "machine"),
        ])
    }

    @Test func aProviderWithoutRoutingThrows() async {
        await #expect(throws: MediaServiceError.self) {
            _ = try await PlexSubtitleSearch(serverID: nil, transport: nil)
                .search(itemID: "1", languageCode: "en", hearingImpaired: false, forced: false)
        }
    }
}

// MARK: - Helpers

private final class BodyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    var value: Data? { lock.withLock { stored } }
    func set(_ data: Data?) { lock.withLock { stored = data ?? Data() } }
}

private final class PathBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ value: String) { lock.withLock { stored.append(value) } }
}

private extension URLRequest {
    /// URLProtocol sees a body as a stream.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
