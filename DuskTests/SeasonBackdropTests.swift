import Foundation
import Testing
@testable import Dusk

@Suite("Series hero artwork")
@MainActor
struct SeasonBackdropTests {
    @Test("Episode focus preserves the season/show art fallback", arguments: [
        ("season", "/season-art"),
        ("show", "/show-art"),
        ("poster", "/show-poster"),
        ("parent", "/parent-poster"),
        ("last", "/season-poster"),
        ("none", ""),
        ("orphan", ""),
    ])
    func backdropWhileBrowsing(scenario: String, expectedPath: String) async throws {
        let service = MediaService(urlProtocolClasses: [SeasonBackdropStub.self])
        let serverID = "backdrop-\(UUID().uuidString)"
        let baseURL = try #require(URL(string: "https://\(scenario).backdrop.test"))
        let serverData = try JSONSerialization.data(withJSONObject: [
            "name": "Artwork fixture", "clientIdentifier": serverID,
        ])
        let server = try JSONDecoder().decode(PlexServer.self, from: serverData)
        service.pool.adopt(server: server, baseURL: baseURL, token: "fixture", connection: nil)
        defer {
            service.session.invalidateAndCancel()
            service.slowQuerySession.invalidateAndCancel()
            service.probeSession.invalidateAndCancel()
            service.bootstrapSession.invalidateAndCancel()
            ServerPool.forget(serverID: serverID)
        }
        let model = SeasonDetailViewModel(
            id: MediaItemID(serverID: serverID, itemID: "season"), media: service
        )
        await model.load()
        #expect(model.error == nil)
        #expect(model.episodes.count == 2)
        let show = try await service.getMediaDetails(itemID: "show", serverID: serverID)
        let original = model.backdropURL(width: 1920, height: 540, show: show)
        if expectedPath.isEmpty {
            #expect(original == nil)
        } else {
            let components = try #require(original.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
            #expect(components.host == baseURL.host)
            let source = try #require(components.queryItems?.first { $0.name == "url" }?.value)
            #expect(URL(string: source)?.path == expectedPath)
        }
        // These have different stills/art and watch states. Fetching their
        // details must keep the same hero, even when no season/show art exists.
        for episode in model.episodes {
            await model.focusEpisode(episode)
            #expect(model.focusedEpisodeDetails?.itemID == episode.itemID)
            #expect(model.backdropURL(width: 1920, height: 540, show: show) == original)
        }
        #if !os(tvOS)
        // Separate season pages load their own show fallback.
        #expect(model.backdropURL(width: 1920, height: 540) == original)
        for (index, episode) in model.episodes.enumerated() {
            let detail = EpisodeDetailViewModel(id: episode.id, media: service)
            await detail.load()
            #expect(detail.error == nil)
            let backdrop = detail.backdropURL(width: 1920, height: 540)
            if scenario == "orphan" {
                // Both parent requests fail: inherited show posters still win
                // over season posters, and no episode still is enlarged.
                let source = backdrop.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                    .queryItems?.first { $0.name == "url" }?.value
                #expect(source.flatMap(URL.init(string:))?.path == "/inherited-show-poster")
            } else {
                #expect(backdrop == original)
            }
            // The small episode image is still the episode's own thumbnail.
            let small = try #require(model.episodeImageURL(episode, width: 320, height: 180))
            let source = URLComponents(url: small, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "url" }?.value
            #expect(source.flatMap(URL.init(string:))?.path == "/episode\(index + 1)-still")
        }
        #else
        // A season route paints before the show loads: use its inherited
        // show poster until the show's background becomes available.
        if scenario == "show" {
            let early = try #require(model.backdropURL(width: 1920, height: 540, show: nil))
            let source = URLComponents(url: early, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "url" }?.value
            #expect(source.flatMap(URL.init(string:))?.path == "/parent-poster")
        }
        #endif
    }
}

private final class SeasonBackdropStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let scenario = url.host?.components(separatedBy: ".").first ?? "none"
        func metadata(_ key: String, type: String) -> [String: Any] {
            ["ratingKey": key, "key": "/library/metadata/\(key)", "type": type, "title": key]
        }
        var season = metadata("season", type: "season")
        season["parentRatingKey"] = "show"
        season["art"] = scenario == "season" ? "/season-art" : ""
        if !["none", "orphan"].contains(scenario) { season["thumb"] = "/season-poster" }
        if ["season", "show", "poster", "parent"].contains(scenario) {
            season["parentThumb"] = "/parent-poster"
        }
        var show = metadata("show", type: "show")
        if ["season", "show"].contains(scenario) { show["art"] = "/show-art" }
        if ["season", "show", "poster"].contains(scenario) { show["thumb"] = "/show-poster" }
        if scenario == "none" {
            season["thumb"] = ""
            season["parentThumb"] = ""
            show["art"] = ""
            show["thumb"] = ""
        }
        let episodes = (1...2).map { index -> [String: Any] in
            var value = metadata("episode\(index)", type: "episode")
            value.merge([
                "index": index, "parentRatingKey": "season", "grandparentRatingKey": "show",
                "thumb": "/episode\(index)-still", "art": "/episode\(index)-art", "viewCount": index - 1,
            ]) { _, new in new }
            if scenario == "orphan" {
                value["parentRatingKey"] = "missing-season"
                value["grandparentRatingKey"] = "missing-show"
                value["parentThumb"] = "/inherited-season-poster"
                value["grandparentThumb"] = "/inherited-show-poster"
            }
            return value
        }
        let values: [[String: Any]]
        switch url.path {
        case "/library/metadata/season": values = [season]
        case "/library/metadata/show": values = [show]
        case "/library/metadata/season/children": values = episodes
        default: values = episodes.filter { url.lastPathComponent == $0["ratingKey"] as? String }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": values]])
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
