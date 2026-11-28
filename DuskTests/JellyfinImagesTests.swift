import Foundation
import Testing
@testable import Dusk

/// `JellyfinImages` (docs/jellyfin/05-plan.md J-03) over locators the mapper
/// builds from the jellyfin-demo fixtures. `fill*` and `max*` were measured on
/// jellyfin-demo 12.4: `fill*` covers the box without cropping or upscaling,
/// like Plex's `minSize=1&upscale=0`; chapter images ignore it.
@MainActor
@Suite("Jellyfin images")
struct JellyfinImagesTests {
    static let serverID = "feedfacefeedfacefeedfacefeedface"
    let images = JellyfinImages()

    private func session(_ base: String = "http://jellyfin.example:8096") -> ServerSession {
        ServerSession(serverID: Self.serverID, name: "Jellyfin", owned: true, sourceTitle: nil,
                      baseURL: URL(string: base)!, token: "secret-token", connection: nil)
    }

    private func item(_ name: String) throws -> JellyfinItemDTO {
        try JellyfinFixtures.decode(JellyfinItemDTO.self, name)
    }

    private func url(_ locator: String?, _ size: ImageSize = .original, base: String = "http://jellyfin.example:8096") throws -> String {
        let locator = try #require(locator)
        let url = images.url(for: ArtworkRef(serverID: Self.serverID, locator: locator), size: size, session: session(base))
        return try #require(url).absoluteString
    }

    /// `points` as the provider sends them (display-scaled).
    private func px(_ points: Int) -> Int { ImageDisplayScale.pixels(points)! }

    @Test("posters, stills and hero art go to the image owner's item, sized with fill")
    func slots() throws {
        let movie = JellyfinItemMapper.map(try item("item-knives-out"), serverID: Self.serverID)
        let base = "http://jellyfin.example:8096/Items/980dffd6dfa0d8cfd69e5bd6b350e983/Images"
        #expect(try url(movie.thumb, ImageSize(width: 120, height: 180))
            == "\(base)/Primary?tag=0365dc4be0aee9bc30ce697faff421fb&fillWidth=\(px(120))&fillHeight=\(px(180))&quality=90")
        #expect(try url(movie.art, ImageSize(width: 1280, height: 720))
            == "\(base)/Backdrop/0?tag=1676f5a4dec19f33258e88482c88208d&fillWidth=\(px(1280))&fillHeight=\(px(720))&quality=90")
        let logo = try url(movie.clearLogo, ImageSize(width: 400, height: 120))
        #expect(logo.hasPrefix("\(base)/Logo?tag=3441313fb0eccf339d51d98e1c117ff9&fillWidth="))
        #expect(!logo.contains("format="))

        let episode = JellyfinItemMapper.map(try item("item-the-office-s01e01"), serverID: Self.serverID)
        #expect(try url(episode.thumb, ImageSize(width: 640, height: 360))
            == "http://jellyfin.example:8096/Items/bf695ca96f49ed398033495d141110b4/Images/Primary"
            + "?tag=2951db227fc18090be8ff9fc256faec9&fillWidth=\(px(640))&fillHeight=\(px(360))&quality=90")
        // The show poster on an episode belongs to the series.
        #expect(try url(episode.grandparentThumb).hasPrefix(
            "http://jellyfin.example:8096/Items/4eb7e22c1653ab565cf44daa4176ca56/Images/Primary?tag=e0ce18f7308a1a86a0463d6acf99bd55"))
        #expect(try url(episode.grandparentArt)
            == "http://jellyfin.example:8096/Items/4eb7e22c1653ab565cf44daa4176ca56/Images/Backdrop/0?tag=8635884fe0a24bdb4edee384b5c54ca7")
    }

    @Test("person and chapter images")
    func personAndChapter() throws {
        let dto = try item("item-knives-out")
        let details = JellyfinItemMapper.mapDetails(dto, serverID: Self.serverID)
        let lead = try #require(details.roles?.first)
        #expect(try url(lead.thumb, ImageSize(width: 100, height: 100))
            == "http://jellyfin.example:8096/Items/7756ef19211166d2d5290b3eb1d354b9/Images/Primary"
            + "?tag=68aff68f4e78d3e88f83a1f1f5a8c425&fillWidth=\(px(100))&fillHeight=\(px(100))&quality=90")

        let chapter = try #require(dto.chapters?[1])
        let locator = JellyfinArtworkLocator.path(itemID: dto.id, type: .chapter, index: 1, tag: chapter.imageTag)
        // Chapters are bounded with max*: the server ignores fill* for them.
        #expect(try url(locator, ImageSize(width: 320, height: 180))
            == "http://jellyfin.example:8096/Items/980dffd6dfa0d8cfd69e5bd6b350e983/Images/Chapter/1"
            + "?tag=66961158b22cc104b7a7b32a03b18a47&maxWidth=\(px(320))&maxHeight=\(px(180))&quality=90")
    }

    @Test("sizes: original, one side, and non-positive sides")
    func sizes() throws {
        let locator = "jf:980dffd6dfa0d8cfd69e5bd6b350e983:Primary:0:abc"
        let base = "http://jellyfin.example:8096/Items/980dffd6dfa0d8cfd69e5bd6b350e983/Images/Primary"
        #expect(try url(locator) == "\(base)?tag=abc")
        #expect(try url(locator, ImageSize(width: 0, height: -1)) == "\(base)?tag=abc")
        #expect(try url(locator, ImageSize(width: 200)) == "\(base)?tag=abc&fillWidth=\(px(200))&quality=90")
        #expect(try url(locator, ImageSize(height: 300)) == "\(base)?tag=abc&fillHeight=\(px(300))&quality=90")
    }

    @Test("indexed types keep their index; a tagless locator still resolves")
    func pathForms() throws {
        let base = "http://jellyfin.example:8096/Items/980dffd6dfa0d8cfd69e5bd6b350e983/Images"
        #expect(try url("jf:980dffd6dfa0d8cfd69e5bd6b350e983:Backdrop:2:t") == "\(base)/Backdrop/2?tag=t")
        #expect(try url("jf:980dffd6dfa0d8cfd69e5bd6b350e983:Banner:0:t") == "\(base)/Banner?tag=t")
        #expect(try url("jf:980dffd6dfa0d8cfd69e5bd6b350e983:Primary:0:") == "\(base)/Primary")
    }

    @Test("a reverse-proxy path prefix is kept")
    func pathPrefix() throws {
        let locator = "jf:980dffd6dfa0d8cfd69e5bd6b350e983:Primary:0:abc"
        let expected = "https://media.example/jellyfin/Items/980dffd6dfa0d8cfd69e5bd6b350e983/Images/Primary?tag=abc"
        #expect(try url(locator, base: "https://media.example/jellyfin") == expected)
        #expect(try url(locator, base: "https://media.example/jellyfin/") == expected)
    }

    @Test("no URL without a Jellyfin locator or a session; never a token")
    func refusals() throws {
        let plexPath = ArtworkRef(serverID: Self.serverID, locator: "/library/metadata/1/thumb/2")
        #expect(images.url(for: plexPath, size: .original, session: session()) == nil)
        let ref = ArtworkRef(serverID: Self.serverID, locator: "jf:980dffd6dfa0d8cfd69e5bd6b350e983:Primary:0:abc")
        #expect(images.url(for: ref, size: .original, session: nil) == nil)

        let built = try #require(images.url(for: ref, size: ImageSize(width: 100, height: 150), session: session()))
        #expect(!built.absoluteString.contains("secret-token"))
        let request = images.authenticatedRequest(for: built, session: session())
        #expect(request.url == built)
        #expect(request.httpMethod == "GET")
        #expect(request.cachePolicy == .returnCacheDataElseLoad)
        #expect(request.allHTTPHeaderFields?.isEmpty ?? true)
    }

    @Test("new artwork is a new URL: the tag is the cache key")
    func tagKeyedCacheKey() throws {
        let old = try url("jf:980dffd6dfa0d8cfd69e5bd6b350e983:Primary:0:aaaa", ImageSize(width: 100, height: 150))
        let new = try url("jf:980dffd6dfa0d8cfd69e5bd6b350e983:Primary:0:bbbb", ImageSize(width: 100, height: 150))
        #expect(old != new)
    }
}
