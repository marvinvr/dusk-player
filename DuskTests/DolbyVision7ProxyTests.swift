import Foundation
import Network
import Testing
@testable import Dusk

@Suite("Dolby Vision 7 proxy HTTP")
struct HLSProxyHTTPTests {
    @Test func parsesRequestLineQueryAndRange() throws {
        let head = Data("GET /token/master.m3u8?a=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nrange: bytes=0-99\r\n\r\n".utf8)
        #expect(HLSProxyRequest.headLength(in: head) == head.count)
        let request = try #require(HLSProxyRequest.parse(head))
        #expect(request.method == "GET")
        #expect(request.path == "/token/master.m3u8")
        #expect(request.query == "a=1")
        #expect(request.range == .from(0, through: 99))
        #expect(!request.isHead)
    }

    @Test func incompleteOrMalformedHeadsAreRejected() {
        #expect(HLSProxyRequest.headLength(in: Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)) == nil)
        #expect(HLSProxyRequest.parse(Data("garbage\r\n\r\n".utf8)) == nil)
        #expect(HLSProxyRequest.parse(Data("GET relative HTTP/1.1\r\n\r\n".utf8)) == nil)
        let oversized = Data(("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 20_000) + "\r\n\r\n").utf8)
        #expect(HLSProxyRequest.parse(oversized) == nil)
    }

    @Test func rangeForms() {
        #expect(HLSProxyByteRange(headerValue: "bytes=100-") == .from(100, through: nil))
        #expect(HLSProxyByteRange(headerValue: "bytes=-50") == .suffix(50))
        #expect(HLSProxyByteRange(headerValue: "bytes=0-1,5-6") == nil)
        #expect(HLSProxyByteRange(headerValue: "items=0-1") == nil)
        #expect(HLSProxyByteRange(headerValue: "bytes=9-3") == nil)

        #expect(HLSProxyByteRange.from(10, through: 500).resolved(length: 100) == 10...99)
        #expect(HLSProxyByteRange.from(100, through: nil).resolved(length: 100) == nil)
        #expect(HLSProxyByteRange.suffix(500).resolved(length: 100) == 0...99)
        #expect(HLSProxyByteRange.suffix(0).resolved(length: 100) == nil)
    }

    @Test func satisfiableRangeIsPartialContent() throws {
        let response = HLSProxyResponse(status: 200, contentType: "video/mp4", body: Data("abcdef".utf8))
        let request = try #require(HLSProxyRequest.parse(Data("GET /t/x HTTP/1.1\r\nRange: bytes=1-2\r\n\r\n".utf8)))
        let text = String(decoding: response.serialized(for: request), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 206 Partial Content\r\n"))
        #expect(text.contains("Content-Range: bytes 1-2/6\r\n"))
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(text.contains("Accept-Ranges: bytes\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\nbc"))
    }

    @Test func unsatisfiableRangeIs416() throws {
        let response = HLSProxyResponse(status: 200, contentType: "video/mp4", body: Data("abcdef".utf8))
        let request = try #require(HLSProxyRequest.parse(Data("GET /t/x HTTP/1.1\r\nRange: bytes=10-\r\n\r\n".utf8)))
        let text = String(decoding: response.serialized(for: request), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 416 "))
        #expect(text.contains("Content-Range: bytes */6\r\n"))
        #expect(text.contains("Content-Length: 0\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test func headSendsHeadersOnly() throws {
        let response = HLSProxyResponse(status: 200, contentType: "video/mp4", body: Data("abcdef".utf8))
        let request = try #require(HLSProxyRequest.parse(Data("HEAD /t/x HTTP/1.1\r\n\r\n".utf8)))
        let text = String(decoding: response.serialized(for: request), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: 6\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test func upstreamURLsRoundTripThroughBase64URL() throws {
        let url = try #require(URL(string: "http://plex.test:32400/video/:/transcode/universal/session/a+b/base/00001.m4s?x=1"))
        let encoded = DolbyVision7HLSProxy.encodedUpstream(url)
        #expect(!encoded.contains("/") && !encoded.contains("+") && !encoded.contains("="))
        #expect(DolbyVision7HLSProxy.decodedUpstream(encoded) == url)
    }
}

/// The real `URLSessionHLSUpstreamFetcher` against a stubbed server
/// (`StubUpstreamProtocol`), so redirects and body limits run through
/// URLSession's own delegate calls.
@Suite("Dolby Vision 7 upstream fetcher")
struct HLSUpstreamFetcherTests {
    private static let origin = URL(string: "http://plex.test:32400/video/:/transcode/universal/start.m3u8")!

    private let fetcher: URLSessionHLSUpstreamFetcher = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubUpstreamProtocol.self]
        return URLSessionHLSUpstreamFetcher(configuration: configuration)
    }()

    @Test func sameOriginRedirectIsFollowed() async throws {
        let (data, response) = try await fetcher.fetch(
            stubURL("/redirect", ["to": "http://PLEX.test:32400/ok"]),
            origin: Self.origin,
            maximumBytes: 1024
        )
        #expect(response.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "ok")
    }

    @Test(arguments: ["http://cdn.test:32400/ok", "http://plex.test:32401/ok", "https://plex.test:32400/ok"])
    func offOriginRedirectIsRefused(target: String) async {
        await #expect(throws: HLSUpstreamFetchError.offOriginRedirect) {
            _ = try await fetcher.fetch(stubURL("/redirect", ["to": target]), origin: Self.origin, maximumBytes: 1024)
        }
    }

    @Test func declaredLengthOverTheLimitFailsBeforeTheBody() async {
        await #expect(throws: HLSUpstreamFetchError.tooLarge(limit: 100)) {
            _ = try await fetcher.fetch(stubURL("/declared", ["length": "101"]), origin: Self.origin, maximumBytes: 100)
        }
    }

    @Test func streamedBodyOverTheLimitFails() async {
        await #expect(throws: HLSUpstreamFetchError.tooLarge(limit: 200)) {
            _ = try await fetcher.fetch(stubURL("/chunks", ["count": "5", "size": "50"]), origin: Self.origin, maximumBytes: 200)
        }
    }

    @Test func bodyAtTheLimitIsReturned() async throws {
        let (data, response) = try await fetcher.fetch(
            stubURL("/chunks", ["count": "4", "size": "50"]),
            origin: Self.origin,
            maximumBytes: 200
        )
        #expect(response.statusCode == 200)
        #expect(data == Data(repeating: 0x41, count: 200))
    }

    private func stubURL(_ path: String, _ query: [String: String]) -> URL {
        var components = URLComponents(string: "http://plex.test:32400")!
        components.path = path
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }
}

/// `/ok` → "ok"; `/redirect?to=<url>` → 302; `/declared?length=<n>` →
/// `Content-Length: n` with a short body; `/chunks?count=<n>&size=<m>` → n
/// chunks of m bytes, no length.
private final class StubUpstreamProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        func respond(headers: [String: String], chunks: [Data]) {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            chunks.forEach { client.urlProtocol(self, didLoad: $0) }
            client.urlProtocolDidFinishLoading(self)
        }

        switch url.path {
        case "/redirect":
            let target = URL(string: value("to") ?? "")!
            let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString]
            )!
            // URLSession asks its delegate, then loads the target in a new
            // instance (or the fetcher cancels the task).
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        case "/declared":
            respond(headers: ["Content-Length": value("length") ?? "0"], chunks: [Data("short".utf8)])
        case "/chunks":
            let count = Int(value("count") ?? "") ?? 0
            let size = Int(value("size") ?? "") ?? 0
            respond(headers: [:], chunks: Array(repeating: Data(repeating: 0x41, count: size), count: count))
        default:
            respond(headers: [:], chunks: [Data("ok".utf8)])
        }
    }

    override func stopLoading() {}
}

/// End-to-end through a real loopback listener and URLSession. The playlist,
/// init and fragment rewriting are the real `DolbyVision7PlaylistRewriter`,
/// `DolbyVision7InitRewriter` and `FMP4FragmentRewriter`; only the server and
/// the per-sample RPU conversion are faked.
///
/// Tests that accept connections on that listener are skipped on the
/// simulator. The listener reaches `.ready`, then the simulator resets every
/// inbound connection (`SO_NECP_LISTENUUID` fails, URLSession reports
/// NSURLError -1005) and `openConnectionCount` stays 0. Preflight tests only
/// talk to the fake upstream and still run here. Device runs keep the rest.
@Suite("Dolby Vision 7 proxy", .serialized)
struct DolbyVision7ProxyTests {
    private static let masterURL = URL(string: "http://plex.test:32400/video/:/transcode/universal/start.m3u8?X-Plex-Token=secret")!

    @Test(.requiresDeviceLoopbackListener)
    func servesConvertedPlaylistsInitAndSegments() async throws {
        let upstream = ProxyFakeUpstream()
        let proxy = try makeProxy(upstream: upstream, rpusPerSample: 1)
        let masterURL = try await proxy.start()
        defer { proxy.stop() }
        #expect(masterURL.host == "127.0.0.1")

        let master = try await get(masterURL)
        #expect(master.status == 200)
        let masterText = String(decoding: master.body, as: UTF8.self)
        #expect(masterText.contains(#"SUPPLEMENTAL-CODECS="dvh1.08"#))
        #expect(!masterText.contains("secret"))
        let variantURL = try #require(firstURI(in: masterText))
        #expect(variantURL.host == "127.0.0.1")
        #expect(variantURL.path.contains("/v/"))

        let media = try await get(variantURL)
        #expect(media.status == 200)
        let mediaText = String(decoding: media.body, as: UTF8.self)
        let initURL = try #require(mapURI(in: mediaText))
        let segmentURL = try #require(firstURI(in: mediaText))
        #expect(initURL.path.contains("/i/"))
        #expect(segmentURL.path.contains("/s/0/"))

        let initSegment = try await get(initURL)
        #expect(initSegment.status == 200)
        #expect(initSegment.body.range(of: Data("dvvC".utf8)) != nil)

        let segment = try await get(segmentURL)
        #expect(segment.status == 200)
        #expect(segment.body.range(of: ProxyFakeSampleRewriter.marker) != nil)
        #expect(segment.body.range(of: ProxyFMP4Fixture.sliceNAL) == nil)

        let partial = try await get(segmentURL, range: "bytes=0-3")
        #expect(partial.status == 206)
        #expect(partial.body.count == 4)

        // The master playlist is served from the preflight copy.
        #expect(upstream.fetchCount(ofPathSuffix: "start.m3u8") == 1)
        // Every fetch is bounded for its kind.
        #expect(upstream.byteLimits(ofPathSuffix: "start.m3u8") == [DolbyVision7HLSProxy.maximumPlaylistBytes])
        #expect(upstream.byteLimits(ofPathSuffix: "/header") == [DolbyVision7HLSProxy.maximumInitSegmentBytes])
        #expect(upstream.byteLimits(ofPathSuffix: "00000.m4s").allSatisfy { $0 == DolbyVision7HLSProxy.maximumMediaSegmentBytes })
    }

    @Test(.requiresDeviceLoopbackListener)
    func refusesWrongTokenAndForeignOrigin() async throws {
        let proxy = try makeProxy(upstream: ProxyFakeUpstream(), rpusPerSample: 1)
        let masterURL = try await proxy.start()
        defer { proxy.stop() }

        let wrongToken = try #require(URL(string: "http://127.0.0.1:\(masterURL.port ?? 0)/\(String(repeating: "0", count: 32))/master.m3u8"))
        #expect(try await get(wrongToken).status == 403)

        let token = masterURL.pathComponents[1]
        let foreign = try #require(URL(string: "http://evil.test/x.m3u8"))
        let relay = try #require(URL(string: "http://127.0.0.1:\(masterURL.port ?? 0)/\(token)/p/\(DolbyVision7HLSProxy.encodedUpstream(foreign)).m3u8"))
        #expect(try await get(relay).status == 403)
    }

    @Test(.requiresDeviceLoopbackListener)
    func segmentWithoutRPUsIsFatal() async throws {
        let recorder = ProxyFatalErrorRecorder()
        let proxy = try makeProxy(upstream: ProxyFakeUpstream(), rpusPerSample: 0)
        proxy.onFatalError = { recorder.record($0) }
        let masterURL = try await proxy.start()
        defer { proxy.stop() }

        let master = try await get(masterURL)
        let variantURL = try #require(firstURI(in: String(decoding: master.body, as: UTF8.self)))
        let media = try await get(variantURL)
        let mediaText = String(decoding: media.body, as: UTF8.self)
        let segmentURL = try #require(firstURI(in: mediaText))

        #expect(try await get(segmentURL).status == 500)
        #expect(recorder.errors == [.missingRPU])
    }

    /// Too large for the proxy to buffer: the unconverted remux, which
    /// AVPlayer streams from the server itself, takes over.
    @Test(.requiresDeviceLoopbackListener)
    func oversizedVideoSegmentIsFatal() async throws {
        let recorder = ProxyFatalErrorRecorder()
        let upstream = ProxyFakeUpstream(failures: ["00000.m4s": .tooLarge(limit: DolbyVision7HLSProxy.maximumMediaSegmentBytes)])
        let proxy = try makeProxy(upstream: upstream, rpusPerSample: 1)
        proxy.onFatalError = { recorder.record($0) }
        let masterURL = try await proxy.start()
        defer { proxy.stop() }

        #expect(try await get(firstSegmentURL(masterURL)).status == 500)
        #expect(recorder.errors.count == 1)
    }

    /// A subtitle playlist is not video: a refused redirect only fails its
    /// own request.
    @Test(.requiresDeviceLoopbackListener)
    func offOriginRedirectOfARenditionIsNotFatal() async throws {
        let recorder = ProxyFatalErrorRecorder()
        let upstream = ProxyFakeUpstream(
            masterPlaylist: ProxyFakeUpstream.masterPlaylistWithSubtitles,
            failures: ["subs.m3u8": .offOriginRedirect]
        )
        let proxy = try makeProxy(upstream: upstream, rpusPerSample: 1)
        proxy.onFatalError = { recorder.record($0) }
        let masterURL = try await proxy.start()
        defer { proxy.stop() }

        let masterText = String(decoding: try await get(masterURL).body, as: UTF8.self)
        let subtitlesLine = try #require(masterText.components(separatedBy: "\n").first { $0.hasPrefix("#EXT-X-MEDIA") })
        let subtitlesURL = try #require(
            HLSAttributeList(line: subtitlesLine)?.quotedValue(of: "URI").flatMap(URL.init(string:))
        )
        #expect(try await get(subtitlesURL).status == 502)
        #expect(recorder.errors.isEmpty)
    }

    /// A seek hangs up on a segment mid-conversion: the conversion stops,
    /// and its result (here: no RPUs, fatal if checked) is never judged.
    @Test(.requiresDeviceLoopbackListener)
    func abandonedSegmentIsCancelledAndNotFatal() async throws {
        let recorder = ProxyFatalErrorRecorder()
        let sampleRewriter = ProxyBlockingSampleRewriter()
        let proxy = try makeProxy(upstream: ProxyFakeUpstream(), sampleRewriter: sampleRewriter)
        proxy.onFatalError = { recorder.record($0) }
        let masterURL = try await proxy.start()
        defer { proxy.stop() }

        let segmentURL = try await firstSegmentURL(masterURL)
        let request = Task { try await get(segmentURL) }
        #expect(await waitUntil { sampleRewriter.didStart })
        request.cancel()
        #expect(await waitUntil { sampleRewriter.sawCancellation })
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.errors.isEmpty)
    }

    @Test(.requiresDeviceLoopbackListener)
    func connectionWithoutARequestHeadTimesOut() async throws {
        let proxy = try makeProxy(upstream: ProxyFakeUpstream(), rpusPerSample: 1, requestHeadTimeout: 0.5)
        let masterURL = try await proxy.start()
        defer { proxy.stop() }

        let clients = (0..<3).map { _ in silentConnection(to: masterURL) }
        defer { clients.forEach { $0.cancel() } }
        #expect(await waitUntil { proxy.openConnectionCount == 3 })
        #expect(await waitUntil { proxy.openConnectionCount == 0 })
    }

    @Test(.requiresDeviceLoopbackListener)
    func connectionsWithoutARequestHeadAreCappedAndTheOldestEvicted() async throws {
        let proxy = try makeProxy(upstream: ProxyFakeUpstream(), rpusPerSample: 1)
        let masterURL = try await proxy.start()
        defer { proxy.stop() }

        let cap = DolbyVision7HLSProxy.maximumPendingConnections
        let clients = (0..<(cap + 4)).map { _ in silentConnection(to: masterURL) }
        defer { clients.forEach { $0.cancel() } }
        #expect(await waitUntil { proxy.openConnectionCount >= cap })
        try await Task.sleep(for: .milliseconds(500))
        #expect(proxy.openConnectionCount == cap)

        // The player still gets through.
        #expect(try await get(masterURL).status == 200)
    }

    @Test func playlistWithoutMapFailsPreflight() async throws {
        let upstream = ProxyFakeUpstream(mediaPlaylist: ProxyFakeUpstream.tsMediaPlaylist)
        let proxy = try makeProxy(upstream: upstream, rpusPerSample: 1)
        await #expect(throws: DolbyVision7ConversionError.self) {
            _ = try await proxy.start()
        }
    }

    /// Video the proxy cannot route through itself would play unconverted
    /// behind the 8.1 signaling: the variant fails preflight instead.
    @Test(arguments: [
        ProxyFakeUpstream.offOriginSegmentPlaylist,
        ProxyFakeUpstream.offOriginInitPlaylist,
        ProxyFakeUpstream.segmentBeforeMapPlaylist,
    ])
    func unproxyableVideoFailsPreflight(mediaPlaylist: String) async throws {
        let proxy = try makeProxy(upstream: ProxyFakeUpstream(mediaPlaylist: mediaPlaylist), rpusPerSample: 1)
        do {
            _ = try await proxy.start()
            Issue.record("preflight accepted a variant it cannot convert")
        } catch DolbyVision7ConversionError.unsupportedPlaylist {
            // Expected.
        } catch {
            Issue.record("unexpected preflight error \(error)")
        }
    }

    @Test(.requiresDeviceLoopbackListener)
    func subtitleRenditionStaysOnTheServer() async throws {
        let proxy = try makeProxy(
            upstream: ProxyFakeUpstream(masterPlaylist: ProxyFakeUpstream.masterPlaylistWithSubtitles),
            rpusPerSample: 1
        )
        let masterURL = try await proxy.start()
        defer { proxy.stop() }

        let masterText = String(decoding: try await get(masterURL).body, as: UTF8.self)
        let subtitlesLine = try #require(masterText.components(separatedBy: "\n").first { $0.hasPrefix("#EXT-X-MEDIA") })
        let subtitlesURL = try #require(
            HLSAttributeList(line: subtitlesLine)?.quotedValue(of: "URI").flatMap(URL.init(string:))
        )
        #expect(subtitlesURL.path.contains("/p/"))

        let subtitles = try await get(subtitlesURL)
        #expect(subtitles.status == 200)
        #expect(firstURI(in: String(decoding: subtitles.body, as: UTF8.self))?.absoluteString
            == "http://plex.test:32400/video/:/transcode/universal/session/abc/subs/sub0.vtt")
    }

    @Test(.requiresDeviceLoopbackListener)
    func concurrentFirstInitRequestsShareOneFetch() async throws {
        let upstream = ProxyFakeUpstream(mediaPlaylist: ProxyFakeUpstream.twoMapMediaPlaylist, slowPathComponent: "header2")
        let proxy = try makeProxy(upstream: upstream, rpusPerSample: 1)
        let masterURL = try await proxy.start()
        defer { proxy.stop() }

        let masterText = String(decoding: try await get(masterURL).body, as: UTF8.self)
        let variantURL = try #require(firstURI(in: masterText))
        let mediaLines = String(decoding: try await get(variantURL).body, as: UTF8.self)
            .components(separatedBy: "\n")
        // The second map and the segment after it; neither was preflighted.
        let secondInitURL = try #require(
            mediaLines.last { $0.hasPrefix("#EXT-X-MAP") }
                .flatMap { HLSAttributeList(line: $0)?.quotedValue(of: "URI") }
                .flatMap(URL.init(string:))
        )
        let secondSegmentURL = try #require(mediaLines.last { $0.hasPrefix("http") }.flatMap(URL.init(string:)))
        #expect(secondSegmentURL.path.contains("/s/1/"))

        async let initResponse = get(secondInitURL)
        async let segmentResponse = get(secondSegmentURL)
        let (initSegment, segment) = try await (initResponse, segmentResponse)
        #expect(initSegment.status == 200)
        #expect(segment.status == 200)
        #expect(upstream.fetchCount(ofPathSuffix: "/header2") == 1)
    }

    // MARK: - Helpers

    private func makeProxy(
        upstream: ProxyFakeUpstream,
        rpusPerSample: Int = 1,
        sampleRewriter: (any DolbyVisionSampleRewriting)? = nil,
        requestHeadTimeout: TimeInterval = 10
    ) throws -> DolbyVision7HLSProxy {
        let media = try proxyDolbyVision7Media(profile: 7, compat: 6)
        return DolbyVision7HLSProxy(
            upstreamMasterURL: Self.masterURL,
            target: try #require(StreamResolver.dolbyVision7ConversionTarget(in: media)),
            restoresDolbyAtmos: false,
            sampleRewriter: sampleRewriter ?? ProxyFakeSampleRewriter(rpusPerSample: rpusPerSample),
            fetcher: upstream,
            requestHeadTimeout: requestHeadTimeout
        )
    }

    /// The first media segment of the first variant, as AVPlayer finds it.
    private func firstSegmentURL(_ masterURL: URL) async throws -> URL {
        let master = try await get(masterURL)
        let variantURL = try #require(firstURI(in: String(decoding: master.body, as: UTF8.self)))
        let media = try await get(variantURL)
        return try #require(firstURI(in: String(decoding: media.body, as: UTF8.self)))
    }

    /// A loopback TCP connection that never sends a request.
    private func silentConnection(to masterURL: URL) -> NWConnection {
        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: UInt16(masterURL.port ?? 0)) ?? .any,
            using: .tcp
        )
        connection.start(queue: .global())
        return connection
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func get(_ url: URL, range: String? = nil) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func firstURI(in playlist: String) -> URL? {
        playlist.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
            .flatMap(URL.init(string:))
    }

    private func mapURI(in playlist: String) -> URL? {
        playlist.components(separatedBy: "\n")
            .first { $0.hasPrefix("#EXT-X-MAP") }
            .flatMap { HLSAttributeList(line: $0)?.quotedValue(of: "URI") }
            .flatMap(URL.init(string:))
    }
}

@Suite("Dolby Vision 7 conversion gating")
struct DolbyVision7GatingTests {
    @Test func profile7ConvertsTo81() throws {
        let media = try proxyDolbyVision7Media(profile: 7, compat: 6)
        #expect(StreamResolver.dolbyVision7ConversionStream(in: media) != nil)
        let target = try #require(StreamResolver.dolbyVision7ConversionTarget(in: media))
        #expect(target.profile == 8)
        #expect(target.blSignalCompatibilityID == 1)
        #expect(target.level == 6)
        #expect(target.convertedFromProfile == 7)
        // The 8.1 signaling path itself stays profile 5 / 8 only.
        #expect(StreamResolver.dolbyVisionSignalingStream(in: media, includesProfile8: true) == nil)
    }

    @Test func otherProfilesAndCodecsAreNotConverted() throws {
        #expect(StreamResolver.dolbyVision7ConversionTarget(in: try proxyDolbyVision7Media(profile: 5, compat: 0)) == nil)
        #expect(StreamResolver.dolbyVision7ConversionTarget(in: try proxyDolbyVision7Media(profile: 8, compat: 1)) == nil)
        #expect(StreamResolver.dolbyVision7ConversionTarget(in: try proxyDolbyVision7Media(codec: "av1", profile: 7, compat: 6)) == nil)
    }

    @Test func conversionBypassesRemuxHLSLoader() throws {
        let target = try #require(StreamResolver.dolbyVision7ConversionTarget(in: try proxyDolbyVision7Media(profile: 7, compat: 6)))
        let context = PlaybackAttemptContext(
            attemptID: UUID(),
            title: "Test",
            ratingKey: "1",
            engine: .avPlayer,
            resolverReason: "test",
            mediaID: 10,
            partID: 20,
            sanitizedPlaybackURL: ""
        )
        let url = try #require(URL(string: "http://plex.test/start.m3u8"))
        let atmos = PlaybackSource(url: url, startPosition: nil, context: context, restoresDolbyAtmos: true)
        #expect(atmos.usesRemuxHLSLoader)
        var converted = atmos
        converted.dolbyVision7Conversion = target
        #expect(!converted.usesRemuxHLSLoader)
    }
}

// MARK: - Fixtures

/// Copies nothing of the sample: writes `marker`, so a converted segment is
/// recognisable, and reports `rpusPerSample` RPUs. Sample counts and byte
/// totals are filled in by `FMP4FragmentRewriter`.
private struct ProxyFakeSampleRewriter: DolbyVisionSampleRewriting {
    static let marker = Data([0x00, 0x00, 0x00, 0x04, 0x7C, 0x01, 0xD0, 0x5E])

    let rpusPerSample: Int

    func rewriteSample(
        _ sample: UnsafeRawBufferPointer,
        nalLengthSize: Int,
        appendingTo output: inout Data
    ) throws -> DolbyVisionSampleStats {
        output.append(Self.marker)
        var stats = DolbyVisionSampleStats()
        stats.nalCount = 2
        stats.rpuCount = rpusPerSample
        stats.sourceProfile = 7
        stats.sourceELType = .mel
        return stats
    }
}

/// Blocks in the first sample until the task converting it is cancelled
/// (or 5 s pass), then reports a sample without RPUs.
private final class ProxyBlockingSampleRewriter: DolbyVisionSampleRewriting, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var cancelled = false

    var didStart: Bool { lock.withLock { started } }
    var sawCancellation: Bool { lock.withLock { cancelled } }

    func rewriteSample(
        _ sample: UnsafeRawBufferPointer,
        nalLengthSize: Int,
        appendingTo output: inout Data
    ) throws -> DolbyVisionSampleStats {
        lock.withLock { started = true }
        let deadline = Date().addingTimeInterval(5)
        while !Task.isCancelled, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let isCancelled = Task.isCancelled
        lock.withLock { cancelled = isCancelled }
        output.append(ProxyFakeSampleRewriter.marker)
        var stats = DolbyVisionSampleStats()
        stats.nalCount = 1
        return stats
    }
}

private final class ProxyFatalErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [DolbyVision7ConversionError] = []

    var errors: [DolbyVision7ConversionError] { lock.withLock { recorded } }

    func record(_ error: DolbyVision7ConversionError) {
        lock.withLock { recorded.append(error) }
    }
}

/// A Plex remux session as the proxy sees it, keyed by the last path
/// component so URL resolution details do not matter.
private final class ProxyFakeUpstream: HLSUpstreamFetching, @unchecked Sendable {
    static let masterPlaylist = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-STREAM-INF:BANDWIDTH=60000000,CODECS="hvc1.2.4.L153.b0,ec-3",RESOLUTION=3840x2160,VIDEO-RANGE=PQ
    session/abc/base/index.m3u8

    """
    static let masterPlaylistWithSubtitles = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",URI="session/abc/subs/subs.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=60000000,CODECS="hvc1.2.4.L153.b0,ec-3",RESOLUTION=3840x2160,VIDEO-RANGE=PQ,SUBTITLES="subs"
    session/abc/base/index.m3u8

    """
    static let subtitlePlaylist = """
    #EXTM3U
    #EXT-X-TARGETDURATION:4
    #EXTINF:4.000,
    sub0.vtt
    #EXT-X-ENDLIST

    """
    static let fmp4MediaPlaylist = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-TARGETDURATION:4
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXT-X-MAP:URI="header"
    #EXTINF:4.000,
    00000.m4s
    #EXT-X-ENDLIST

    """
    static let twoMapMediaPlaylist = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-TARGETDURATION:4
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXT-X-MAP:URI="header"
    #EXTINF:4.000,
    00000.m4s
    #EXT-X-DISCONTINUITY
    #EXT-X-MAP:URI="header2"
    #EXTINF:4.000,
    00001.m4s
    #EXT-X-ENDLIST

    """
    static let offOriginSegmentPlaylist = """
    #EXTM3U
    #EXT-X-TARGETDURATION:4
    #EXT-X-MAP:URI="header"
    #EXTINF:4.000,
    http://cdn.test/00000.m4s
    #EXT-X-ENDLIST

    """
    static let offOriginInitPlaylist = """
    #EXTM3U
    #EXT-X-TARGETDURATION:4
    #EXT-X-MAP:URI="http://cdn.test/header"
    #EXTINF:4.000,
    00000.m4s
    #EXT-X-ENDLIST

    """
    static let segmentBeforeMapPlaylist = """
    #EXTM3U
    #EXT-X-TARGETDURATION:4
    #EXTINF:4.000,
    lead.m4s
    #EXT-X-MAP:URI="header"
    #EXTINF:4.000,
    00000.m4s
    #EXT-X-ENDLIST

    """
    static let tsMediaPlaylist = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:4
    #EXTINF:4.000,
    00000.ts
    #EXT-X-ENDLIST

    """

    private let lock = NSLock()
    private var fetched: [(url: URL, maximumBytes: Int)] = []
    private let masterPlaylist: String
    private let mediaPlaylist: String
    /// Answered after a delay, so requests for it overlap.
    private let slowPathComponent: String?
    /// Thrown for these last path components, as the real fetcher would.
    private let failures: [String: HLSUpstreamFetchError]

    init(
        masterPlaylist: String = ProxyFakeUpstream.masterPlaylist,
        mediaPlaylist: String = ProxyFakeUpstream.fmp4MediaPlaylist,
        slowPathComponent: String? = nil,
        failures: [String: HLSUpstreamFetchError] = [:]
    ) {
        self.masterPlaylist = masterPlaylist
        self.mediaPlaylist = mediaPlaylist
        self.slowPathComponent = slowPathComponent
        self.failures = failures
    }

    func fetchCount(ofPathSuffix suffix: String) -> Int {
        lock.withLock { fetched.filter { $0.url.path.hasSuffix(suffix) }.count }
    }

    func byteLimits(ofPathSuffix suffix: String) -> [Int] {
        lock.withLock { fetched.filter { $0.url.path.hasSuffix(suffix) }.map(\.maximumBytes) }
    }

    func fetch(_ url: URL, origin: URL, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { fetched.append((url, maximumBytes)) }
        if let failure = failures[url.lastPathComponent] {
            throw failure
        }
        if url.lastPathComponent == slowPathComponent {
            try await Task.sleep(for: .milliseconds(300))
        }
        let body: Data?
        switch url.lastPathComponent {
        case "start.m3u8": body = Data(masterPlaylist.utf8)
        case "index.m3u8": body = Data(mediaPlaylist.utf8)
        case "subs.m3u8": body = Data(Self.subtitlePlaylist.utf8)
        case "header", "header2": body = ProxyFMP4Fixture.initSegment()
        case "00000.m4s", "00001.m4s": body = ProxyFMP4Fixture.mediaSegment()
        default: body = nil
        }
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (body ?? Data(), response)
    }
}

/// Minimal fMP4 a Plex HEVC remux would produce: one `hvc1` video track
/// (track 1, 4-byte NAL lengths) and one fragment with a single sample.
private enum ProxyFMP4Fixture {
    static let sliceNAL = Data([0x02, 0x01, 0xAA, 0xBB, 0xCC, 0xDD])

    static func initSegment() -> Data {
        let tkhd = fullBox("tkhd", payload: u32(0) + u32(0) + u32(1) + [UInt8](repeating: 0, count: 68))
        let hdlr = fullBox("hdlr", payload: u32(0) + Array("vide".utf8) + [UInt8](repeating: 0, count: 13))
        // hvcC: byte 21 carries lengthSizeMinusOne = 3; no parameter-set arrays.
        var hvcC = [UInt8](repeating: 0, count: 23)
        hvcC[0] = 1
        hvcC[21] = 0x0F
        let hvc1 = box("hvc1", [UInt8](repeating: 0, count: 78) + box("hvcC", hvcC))
        let stsd = fullBox("stsd", payload: u32(1) + hvc1)
        let stbl = box("stbl", stsd)
        let minf = box("minf", stbl)
        let mdia = box("mdia", hdlr + minf)
        let trak = box("trak", tkhd + mdia)
        let trex = fullBox("trex", payload: u32(1) + u32(1) + u32(1001) + u32(0) + u32(0))
        let mvex = box("mvex", trex)
        let moov = box("moov", trak + mvex)
        let ftyp = box("ftyp", Array("iso6".utf8) + u32(0) + Array("iso6".utf8))
        return Data(ftyp + moov)
    }

    static func mediaSegment() -> Data {
        let rpu: [UInt8] = [0x7C, 0x01, 0x19, 0x08]
        let sample = u32(UInt32(sliceNAL.count)) + [UInt8](sliceNAL) + u32(UInt32(rpu.count)) + rpu
        func moof(dataOffset: UInt32) -> [UInt8] {
            let mfhd = fullBox("mfhd", payload: u32(1))
            // default-base-is-moof
            let tfhd = fullBox("tfhd", flags: 0x02_0000, payload: u32(1))
            let tfdt = fullBox("tfdt", version: 1, payload: u32(0) + u32(0))
            // data-offset-present | sample-size-present
            let trun = fullBox("trun", flags: 0x00_0201, payload: u32(1) + u32(dataOffset) + u32(UInt32(sample.count)))
            return box("moof", mfhd + box("traf", tfhd + tfdt + trun))
        }
        let moofSize = UInt32(moof(dataOffset: 0).count)
        return Data(moof(dataOffset: moofSize + 8) + box("mdat", sample))
    }

    private static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        u32(UInt32(8 + payload.count)) + Array(type.utf8) + payload
    }

    private static func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, payload: [UInt8]) -> [UInt8] {
        box(type, [version, UInt8((flags >> 16) & 0xFF), UInt8((flags >> 8) & 0xFF), UInt8(flags & 0xFF)] + payload)
    }

    private static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}

private func proxyDolbyVision7Media(codec: String = "hevc", profile: Int, compat: Int) throws -> MediaVersion {
    let json = """
    {
        "id": 10,
        "container": "mkv",
        "Part": [{
            "id": 20,
            "key": "/library/parts/20/file.mkv",
            "container": "mkv",
            "Stream": [
                { "id": 1, "streamType": 1, "codec": "\(codec)", "bitDepth": 10, "frameRate": 23.976,
                  "width": 3840, "height": 2160, "bitrate": 40000, "colorTrc": "smpte2084",
                  "DOVIPresent": true, "DOVIProfile": \(profile), "DOVILevel": 6, "DOVIBLCompatID": \(compat) },
                { "id": 2, "streamType": 2, "codec": "eac3", "channels": 6 }
            ]
        }]
    }
    """
    return try JSONDecoder().decode(MediaVersion.self, from: Data(json.utf8))
}

/// True when this test bundle is running in the iOS or tvOS Simulator.
/// Inbound `NWListener` connections there are reset before the proxy accepts
/// them (`SO_NECP_LISTENUUID` fails, URLSession reports NSURLError -1005).
private var loopbackListenerIsResetBySimulator: Bool {
    #if targetEnvironment(simulator)
    true
    #else
    false
    #endif
}

private extension Trait where Self == ConditionTrait {
    /// Skip message, same role as `XCTSkip`: the test stays enabled on device.
    static var requiresDeviceLoopbackListener: Self {
        .disabled(
            if: loopbackListenerIsResetBySimulator,
            "Skipped on the iOS Simulator: NWListener loopback connections are reset (SO_NECP_LISTENUUID failed, NSURLError -1005). This test runs on device."
        )
    }
}
