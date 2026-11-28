import Foundation
import Testing
@testable import Dusk

/// Header, URL, user-scope, error and shape-validation behaviour of
/// `JellyfinClient`, against a stub transport. Header cases follow
/// docs/jellyfin/03-prior-art.md §10.1.
@Suite("Jellyfin client")
struct JellyfinClientTests {
    private static let identity = JellyfinClientIdentity(
        client: "Dusk", device: "Marvin’s iPhone", deviceID: "device-1", version: "1.9.1")
    private static let credentials = JellyfinCredentials(accessToken: "0123abcd", userID: "user-1")

    private func client(_ base: String = "http://jellyfin.example:8096",
                        credentials: JellyfinCredentials? = credentials,
                        transport: JellyfinStubTransport = JellyfinStubTransport()) -> JellyfinClient {
        JellyfinClient(baseURL: URL(string: base)!, identity: Self.identity,
                       credentials: credentials, transport: transport)
    }

    // MARK: Authorization header

    @Test func headerHasTheOneAcceptedForm() {
        let value = JellyfinAuthorization.headerValue(
            identity: JellyfinClientIdentity(client: "Dusk", device: "AppleTV", deviceID: "abc123", version: "1.9.1"),
            token: "deadbeef")
        #expect(value == #"MediaBrowser Client="Dusk", Device="AppleTV", DeviceId="abc123", Version="1.9.1", Token="deadbeef""#)
    }

    @Test func headerWithoutTokenForPublicCalls() {
        let value = JellyfinAuthorization.headerValue(identity: Self.identity, token: nil)
        #expect(value.hasPrefix("MediaBrowser Client=\"Dusk\", "))
        #expect(!value.contains("Token="))
        #expect(JellyfinAuthorization.headerValue(identity: Self.identity, token: "") == value)
    }

    /// The server percent-decodes values; a literal `"` is a `400`.
    @Test func headerValuesArePercentEncoded() {
        let identity = JellyfinClientIdentity(
            client: "Dusk", device: #"Wohnzimmer "Ü", 50% = TV’s"#, deviceID: "a b/c", version: "1.9.1 (42)")
        let value = JellyfinAuthorization.headerValue(identity: identity, token: "tok")
        #expect(value.contains(#"Device="Wohnzimmer%20%22%C3%9C%22%2C%2050%25%20%3D%20TV%E2%80%99s""#))
        #expect(value.contains(#"DeviceId="a%20b%2Fc""#))
        #expect(value.contains(#"Version="1.9.1%20%2842%29""#))
        // Exactly the quotes the format itself adds.
        #expect(value.filter { $0 == "\"" }.count == 10)
        #expect(JellyfinAuthorization.encode("Marvin’s iPhone") == "Marvin%E2%80%99s%20iPhone")
        #expect(JellyfinAuthorization.encode("A-Z_a.z~09") == "A-Z_a.z~09")
    }

    @Test func requestsCarryOnlyTheAuthorizationHeader() throws {
        let request = try client().makeURLRequest(for: JellyfinAPI.currentUser())
        let headers = request.allHTTPHeaderFields ?? [:]
        #expect(headers["Authorization"]?.hasPrefix("MediaBrowser ") == true)
        #expect(headers["Authorization"]?.contains(#"Token="0123abcd""#) == true)
        for legacy in ["X-Emby-Token", "X-Emby-Authorization", "X-MediaBrowser-Token", "X-Plex-Token"] {
            #expect(headers[legacy] == nil)
        }
        #expect(!(request.url?.absoluteString.lowercased().contains("api_key") ?? true))
        #expect(!(request.url?.absoluteString.lowercased().contains("apikey") ?? true))
        #expect(request.url?.path.hasPrefix("/emby") == false)
    }

    @Test func publicCallsSendIdentityWithoutToken() throws {
        let request = try client(credentials: nil).makeURLRequest(for: JellyfinAPI.publicSystemInfo())
        let header = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(header.contains(#"DeviceId="device-1""#))
        #expect(!header.contains("Token="))
        // Even when signed in, a public call does not leak the token.
        let signedIn = try client().makeURLRequest(for: JellyfinAPI.quickConnectInitiate())
        #expect(signedIn.value(forHTTPHeaderField: "Authorization")?.contains("Token=") == false)
        #expect(signedIn.httpMethod == "POST")
    }

    @Test func authenticatedCallsNeedCredentials() {
        #expect(throws: JellyfinError.notAuthenticated) {
            try client(credentials: nil).makeURLRequest(for: JellyfinAPI.currentUser())
        }
        #expect(throws: JellyfinError.notAuthenticated) {
            try client(credentials: nil).makeURLRequest(for: JellyfinAPI.userViews())
        }
    }

    // MARK: URLs

    @Test func userIDIsInjectedOnce() throws {
        let views = try client().makeURLRequest(for: JellyfinAPI.userViews())
        #expect(views.url?.absoluteString == "http://jellyfin.example:8096/UserViews?includeHidden=true&userId=user-1")

        var request = JellyfinAPI.userViews()
        request.query = [URLQueryItem(name: "UserId", value: "other")]
        let explicit = try client().makeURLRequest(for: request)
        #expect(explicit.url?.query == "UserId=other")

        let unscoped = try client().makeURLRequest(for: JellyfinAPI.mediaSegments(itemID: "abc"))
        #expect(unscoped.url?.query == nil)
    }

    @Test func queryValuesCannotSplitParameters() throws {
        var query = JellyfinItemQuery()
        query.searchTerm = "Tom & Jerry = 100% #1 + more?"
        query.genres = ["Science Fiction", "Action & Adventure"]
        query.includeItemTypes = [.movie, .series]
        query.fields = [.overview, .providerIDs]
        let url = try #require(try client().makeURLRequest(for: JellyfinAPI.items(query)).url)
        let raw = try #require(url.query)
        #expect(raw.contains("searchTerm=Tom%20%26%20Jerry%20%3D%20100%25%20%231%20%2B%20more%3F"))
        #expect(raw.contains("genres=Science%20Fiction%7CAction%20%26%20Adventure"))
        #expect(raw.contains("includeItemTypes=Movie,Series"))
        #expect(raw.contains("fields=Overview,ProviderIds"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "searchTerm" }?.value == "Tom & Jerry = 100% #1 + more?")
        #expect(items.first { $0.name == "userId" }?.value == "user-1")
    }

    @Test func itemQueryEncodesTypedParameters() {
        var query = JellyfinItemQuery()
        query.parentID = "view"
        query.recursive = true
        query.sortBy = [.sortName, .productionYear]
        query.sortOrder = .descending
        query.startIndex = 40
        query.limit = 0
        query.isPlayed = false
        query.years = [2019, 2024]
        query.nameLessThan = "D"
        query.filters = [.isResumable]
        let pairs = query.queryItems.map { "\($0.name)=\($0.value ?? "")" }
        #expect(pairs == [
            "parentId=view", "recursive=true", "sortBy=SortName,ProductionYear", "sortOrder=Descending",
            "startIndex=40", "limit=0", "filters=IsResumable", "isPlayed=false", "years=2019,2024", "nameLessThan=D",
        ])
    }

    @Test func basePathPrefixIsKept() throws {
        let proxied = client("https://media.example.com/jellyfin/")
        let request = try proxied.makeURLRequest(for: JellyfinAPI.item(id: "abc"))
        #expect(request.url?.absoluteString == "https://media.example.com/jellyfin/Items/abc?userId=user-1")
        #expect(try proxied.resolveServerURL("/videos/x/master.m3u8?ApiKey=t&a=1").absoluteString
            == "https://media.example.com/jellyfin/videos/x/master.m3u8?ApiKey=t&a=1")
        #expect(try proxied.resolveServerURL("https://cdn.example.com/a.vtt").absoluteString == "https://cdn.example.com/a.vtt")
        #expect(throws: JellyfinError.invalidURL) {
            try JellyfinClient(baseURL: URL(string: "jellyfin-demo")!, identity: Self.identity).makeURL(path: "/x")
        }
    }

    @Test func playerURLsCarryApiKey() throws {
        let stream = JellyfinAPI.directStreamPath(itemID: "item", mediaSourceID: "source")
        let url = try client().authenticatedURL(path: stream.path, query: stream.query)
        #expect(url.absoluteString == "http://jellyfin.example:8096/Videos/item/stream?static=true&mediaSourceId=source&ApiKey=0123abcd")
        #expect(!url.absoluteString.contains("api_key"))
        let replaced = try client().authenticatedURL(path: "/x", query: [URLQueryItem(name: "apikey", value: "old")])
        #expect(replaced.query == "ApiKey=0123abcd")
        #expect(throws: JellyfinError.notAuthenticated) { try client(credentials: nil).authenticatedURL(path: "/x") }
        #expect(JellyfinRedaction.redact(url) == "http://jellyfin.example:8096/Videos/item/stream?static=true&mediaSourceId=source&ApiKey=REDACTED")
    }

    @Test func bodiesGetTheSignedInUser() throws {
        let request = JellyfinAPI.playbackInfo(itemID: "item", JellyfinPlaybackInfoRequestDTO(
            mediaSourceID: "item", audioStreamIndex: 1, subtitleStreamIndex: -1, deviceProfile: nil))
        let urlRequest = try client().makeURLRequest(for: request)
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["UserId"] as? String == "user-1")
        #expect(json["MediaSourceId"] as? String == "item")
        #expect(json["SubtitleStreamIndex"] as? Int == -1)
        #expect(json["DeviceProfile"] == nil, "unset fields are not sent")
    }

    @Test func reportBodiesUseTicks() throws {
        var report = JellyfinPlaybackReportDTO(itemID: "item")
        report.positionTicks = JellyfinTicks(milliseconds: 12_345)
        report.playMethod = .directPlay
        report.isPaused = true
        let body = try JellyfinJSON.encode(report)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["PositionTicks"] as? Int64 == 123_450_000)
        #expect(json["PlayMethod"] as? String == "DirectPlay")
        #expect(json["ItemId"] as? String == "item")
        #expect(json.count == 4)
    }

    @Test func passwordBodyUsesPwKey() throws {
        let request = JellyfinAPI.authenticateByName(username: "duskcompare", password: "p\"w")
        let urlRequest = try client(credentials: nil).makeURLRequest(for: request)
        let json = try #require(try JSONSerialization.jsonObject(with: urlRequest.httpBody ?? Data()) as? [String: String])
        #expect(json == ["Username": "duskcompare", "Pw": "p\"w"])
    }

    // MARK: Responses

    @Test func statusCodesMapToErrors() async {
        let cases: [(Int, JellyfinError)] = [
            (401, .unauthorized), (403, .forbidden), (404, .notFound), (500, .httpStatus(500)),
            (400, .badRequest(message: "Bad thing ApiKey=REDACTED")),
        ]
        for (status, expected) in cases {
            let transport = JellyfinStubTransport(status: status, body: #"{"title":"Bad thing ApiKey=abc123"}"#)
            await #expect(throws: expected) {
                _ = try await client(transport: transport).send(JellyfinAPI.currentUser())
            }
        }
    }

    @Test func transportFailuresAreSanitised() async {
        let transport = JellyfinStubTransport(error: URLError(.timedOut))
        await #expect(throws: JellyfinError.transport(code: URLError.Code.timedOut.rawValue,
                                                      description: URLError(.timedOut).localizedDescription)) {
            _ = try await client(transport: transport).send(JellyfinAPI.currentUser())
        }
        await #expect(throws: CancellationError.self) {
            _ = try await client(transport: JellyfinStubTransport(error: URLError(.cancelled))).send(JellyfinAPI.currentUser())
        }
    }

    /// An unknown parameter is ignored with `200`; the client checks the shape.
    @Test func defaultResultsForIgnoredParametersAreRejected() async throws {
        let body = try JellyfinFixtures.data("items-movies-browse")
        var query = JellyfinItemQuery()
        query.includeItemTypes = [.series]
        await #expect(throws: JellyfinError.self) {
            _ = try await client(transport: JellyfinStubTransport(status: 200, data: body)).send(JellyfinAPI.items(query))
        }
        query.includeItemTypes = [.movie]
        query.limit = 2
        await #expect(throws: JellyfinError.self) {
            _ = try await client(transport: JellyfinStubTransport(status: 200, data: body)).send(JellyfinAPI.items(query))
        }
        query.limit = nil
        query.isPlayed = true
        await #expect(throws: JellyfinError.self) {
            _ = try await client(transport: JellyfinStubTransport(status: 200, data: body)).send(JellyfinAPI.items(query))
        }
        query.isPlayed = false
        let result = try await client(transport: JellyfinStubTransport(status: 200, data: body)).send(JellyfinAPI.items(query))
        #expect(result.items.count == 3)
    }

    @Test func wrongEnvelopeAndWrongItemAreRejected() async throws {
        // A bare array where `{Items}` is expected, an HTML page with 200.
        for body in ["[]", "<html>login</html>", "{}"] {
            await #expect(throws: JellyfinError.self) {
                _ = try await client(transport: JellyfinStubTransport(status: 200, body: body)).send(JellyfinAPI.userViews())
            }
        }
        let knivesOut = try JellyfinFixtures.data("item-knives-out")
        await #expect(throws: JellyfinError.self) {
            _ = try await client(transport: JellyfinStubTransport(status: 200, data: knivesOut))
                .send(JellyfinAPI.item(id: "64affd1220e9438c4d1d3cb12aaa2d84"))
        }
        // Dashed and upper-case forms of the same id are the same item.
        let item = try await client(transport: JellyfinStubTransport(status: 200, data: knivesOut))
            .send(JellyfinAPI.item(id: "980DFFD6-DFA0-D8CF-D69E-5BD6B350E983"))
        #expect(item.name == "Knives Out")
    }

    @Test func noContentIgnoresBody() async throws {
        let result = try await client(transport: JellyfinStubTransport(status: 204, body: "")).send(JellyfinAPI.logout())
        #expect(result == JellyfinNoContent())
    }

    @Test func errorDescriptionsNeverCarryCredentials() {
        let errors: [JellyfinError] = [
            .badRequest(message: JellyfinError.serverMessage(in: Data("token=\"abc\" ApiKey=xyz".utf8))),
            .transport(code: 1, description: "x"), .unexpectedResponse("y"), .decoding("z"),
        ]
        for error in errors {
            let text = error.errorDescription ?? ""
            #expect(!text.contains("abc") && !text.contains("xyz"))
        }
        #expect(JellyfinRedaction.redact(#"Token="abc", ApiKey=xyz&api_key=q"#) == #"Token="REDACTED", ApiKey=REDACTED&api_key=REDACTED"#)
    }
}

/// Answers every request with one canned response, or fails with `error`.
struct JellyfinStubTransport: JellyfinTransport {
    var status = 200
    var data = Data("{}".utf8)
    var error: (any Error & Sendable)?

    init(status: Int = 200, body: String = "{}") {
        self.status = status
        data = Data(body.utf8)
    }

    init(status: Int, data: Data) {
        self.status = status
        self.data = data
    }

    init(error: any Error & Sendable) {
        self.error = error
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let error { throw error }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (data, response)
    }
}
