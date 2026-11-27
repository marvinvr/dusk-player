import Foundation
import Testing
@testable import Dusk

@Suite("Seerr image URLs")
struct SeerrImageURLTests {
    private func strings(
        _ path: String?,
        size: String = "w342",
        base: URL? = URL(string: "http://192.168.1.10:5055"),
        caches: Bool?
    ) -> [String] {
        SeerrImageURL.candidates(path: path, size: size, seerrBaseURL: base, cachesImages: caches)
            .map(\.absoluteString)
    }

    @Test func cachingOffLoadsFromTMDBOnly() {
        // Seerr's default: the proxy answers 404 "Image caching is disabled."
        #expect(strings("/abc.jpg", caches: false) == ["https://image.tmdb.org/t/p/w342/abc.jpg"])
    }

    @Test func cachingOnPrefersTheProxyWithTMDBFallback() {
        #expect(strings("/abc.jpg", caches: true) == [
            "http://192.168.1.10:5055/imageproxy/tmdb/t/p/w342/abc.jpg",
            "https://image.tmdb.org/t/p/w342/abc.jpg",
        ])
    }

    @Test func unknownCachingTriesTMDBThenTheProxy() {
        #expect(strings("/abc.jpg", caches: nil) == [
            "https://image.tmdb.org/t/p/w342/abc.jpg",
            "http://192.168.1.10:5055/imageproxy/tmdb/t/p/w342/abc.jpg",
        ])
    }

    @Test func reverseProxySubpathIsKeptForTheImageProxy() {
        let urls = strings("/abc.jpg", base: URL(string: "https://example.com/seerr"), caches: true)
        #expect(urls.first == "https://example.com/seerr/imageproxy/tmdb/t/p/w342/abc.jpg")
    }

    @Test func pathWithoutLeadingSlashOrWithSpacesStillBuilds() {
        #expect(strings("abc.jpg", caches: false) == ["https://image.tmdb.org/t/p/w342/abc.jpg"])
        #expect(strings("  /abc.jpg \n", caches: false) == ["https://image.tmdb.org/t/p/w342/abc.jpg"])
    }

    @Test func absoluteURLIsUsedAsIs() {
        let path = "https://artworks.thetvdb.com/banners/posters/123.jpg"
        #expect(strings(path, caches: true) == [path])
        #expect(strings(path, base: nil, caches: nil) == [path])
    }

    @Test func missingPathGivesNoURL() {
        #expect(strings(nil, caches: true).isEmpty)
        #expect(strings("", caches: true).isEmpty)
        #expect(strings("   ", caches: nil).isEmpty)
        #expect(strings("/", caches: nil).isEmpty)
    }

    @Test func noSeerrBaseStillLoadsFromTMDB() {
        #expect(strings("/abc.jpg", base: nil, caches: true) == ["https://image.tmdb.org/t/p/w342/abc.jpg"])
    }

    @Test func sizeBuckets() {
        #expect(SeerrImageURL.posterSize(forWidth: 120) == "w185")
        #expect(SeerrImageURL.posterSize(forWidth: 300) == "w342")
        #expect(SeerrImageURL.posterSize(forWidth: 500) == "w500")
        #expect(SeerrImageURL.posterSize(forWidth: 640) == "w780")
        #expect(SeerrImageURL.backdropSize(forWidth: 300) == "w300")
        #expect(SeerrImageURL.backdropSize(forWidth: 2000) == "w1280")
    }

    @Test func publicSettingsDecodeCacheImages() throws {
        func decode(_ json: String) throws -> SeerrPublicSettings {
            try JSONDecoder().decode(SeerrPublicSettings.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"initialized":true,"cacheImages":true}"#).cacheImages == true)
        #expect(try decode(#"{"initialized":true,"cacheImages":false}"#).cacheImages == false)
        #expect(try decode(#"{"initialized":true}"#).cacheImages == nil)
        // A wrong type must not break sign-in.
        #expect(try decode(#"{"initialized":true,"cacheImages":"yes"}"#).cacheImages == nil)
    }
}
