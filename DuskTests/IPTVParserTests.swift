import Foundation
import Testing
@testable import Dusk

@Suite("M3U parser")
struct M3UParserTests {
    private let playlist = M3UParser.parse(IPTVFixtures.extendedPlaylist)

    private func entry(_ title: String) throws -> IPTVPlaylistEntry {
        try #require(playlist.entries.first { $0.title == title })
    }

    @Test func readsHeaderGuideURLsOnceEach() {
        #expect(playlist.guideURLs.map(\.absoluteString) == [
            "https://guide.example.com/a.xml",
            "https://guide.example.com/b.xml.gz",
        ])
    }

    @Test func keepsEveryPlayableEntryAndDropsJunk() {
        #expect(playlist.entries.map(\.title) == [
            "News One HD", "Sport Two", "Movies 24", "Widevine Channel", "bare-entry",
        ])
    }

    @Test func readsExtinfAttributes() throws {
        let news = try entry("News One HD")
        #expect(news.tvgID == "news.one")
        #expect(news.tvgName == "News One")
        #expect(news.logoURL?.absoluteString == "https://img.example.com/news.png")
        // The comma inside the quoted group must not end the attributes.
        #expect(news.group == "News, Weather")
        #expect(news.number == "101")
        #expect(news.streamURL.absoluteString == "https://streams.example.com/news/index.m3u8")
        #expect(news.drm == nil)
    }

    @Test func optionLinesBeforeExtinfBelongToTheNextEntry() throws {
        let sport = try entry("Sport Two")
        #expect(sport.tvgID == "sport.two")
        #expect(sport.group == "Sports")
        #expect(sport.number == "7")
        #expect(sport.userAgent == "DuskTest/1.0")
        #expect(sport.referrer == "https://portal.example.com/")
        let drm = try #require(sport.drm)
        #expect(drm.licenseType == "com.apple.fps")
        // Kodi's `|headers|body|response` suffix is not part of the URL.
        #expect(drm.licenseURL?.absoluteString == "https://license.example.com/fps?ch=2")
        #expect(drm.certificateURL?.absoluteString == "https://license.example.com/cert.der")
        #expect(drm.keySystem == .fairPlay)
    }

    @Test func pipeHeadersAndExtgrp() throws {
        let movies = try entry("Movies 24")
        #expect(movies.tvgID == nil)
        #expect(movies.group == "Movies")
        #expect(movies.streamURL.absoluteString == "https://streams.example.com/movies.m3u8")
        #expect(movies.userAgent == "PipeAgent/2")
        #expect(movies.streamHeaders == ["X-Token": "abc"])
    }

    @Test func optionsOfADroppedEntryDoNotLeak() throws {
        // "broken" and the rtmp entry are dropped; the bare URL after them
        // has no EXTINF and must not inherit either one's attributes.
        let bare = try entry("bare-entry")
        #expect(bare.tvgID == nil)
        #expect(bare.drm == nil)
    }

    @Test func nonFairPlayLicenseIsUnsupported() throws {
        let widevine = try entry("Widevine Channel")
        #expect(widevine.drm?.keySystem == .unsupported("com.widevine.alpha"))
    }

    @Test func fairPlayAliasesAndLicenseOnlyEntries() {
        for type in ["com.apple.fps", "FairPlay", "fps", "com.apple.streamingkeydelivery"] {
            #expect(IPTVDRMConfiguration(licenseType: type).keySystem == .fairPlay)
        }
        let licenseOnly = IPTVDRMConfiguration(licenseURL: URL(string: "https://l.example.com"))
        #expect(licenseOnly.keySystem == .fairPlay)
        #expect(IPTVDRMConfiguration().keySystem == nil)
    }

    @Test func toleratesMissingHeaderAndEmptyInput() {
        #expect(M3UParser.parse("").entries.isEmpty)
        let headerless = M3UParser.parse("#EXTINF:-1,Solo\nhttp://a.example.com/s.m3u8\n")
        #expect(headerless.entries.map(\.title) == ["Solo"])
        #expect(headerless.guideURLs.isEmpty)
    }

    @Test func attributeLexer() {
        let attributes = M3UParser.parseAttributes(#"-1 a="x y" B='z' c=bare d="""#)
        #expect(attributes == ["a": "x y", "b": "z", "c": "bare", "d": ""])
        let split = M3UParser.splitTitle(#"-1 group-title="a,b",Title, With Comma"#)
        #expect(split.title == "Title, With Comma")
    }
}

@Suite("XMLTV parser")
struct XMLTVParserTests {
    private let window = IPTVFixtures.guideNow.addingTimeInterval(-6 * 3600)...IPTVFixtures.guideNow.addingTimeInterval(24 * 3600)

    private func parse(channelIDs: Set<String>? = nil) throws -> IPTVGuide {
        try XMLTVParser.parse(
            data: Data(IPTVFixtures.guide.utf8),
            options: XMLTVParser.Options(window: window, channelIDs: channelIDs)
        )
    }

    @Test func readsChannels() throws {
        let guide = try parse()
        let news = try #require(guide.channels["news.one"])
        #expect(news.displayNames == ["News One", "N1"])
        #expect(news.iconURL?.absoluteString == "https://img.example.com/guide-news.png")
        #expect(guide.channels.count == 3)
    }

    @Test func readsProgrammesInsideTheWindow() throws {
        let guide = try parse()
        let news = try #require(guide.programmes["news.one"])
        // "Last Year" is outside the window, "Bad Time" has no readable start.
        #expect(news.map(\.title) == ["Midday News", "Afternoon Report"])
        // The first title wins over later languages; entities are decoded.
        #expect(news[0].summary == "Headlines & weather.")
        #expect(news[0].iconURL?.absoluteString == "https://img.example.com/midday.jpg")
        #expect(news[0].start == IPTVFixtures.guideNow)
        #expect(news[0].stop == IPTVFixtures.guideNow.addingTimeInterval(3600))
        #expect(news[1].subtitle == "Markets")
    }

    @Test func honoursOffsetsCDATAAndMissingOffset() throws {
        let guide = try parse()
        let sport = try #require(guide.programmes["Sport.Two"]?.first)
        #expect(sport.title == "Grand Prix: Qualifying")
        // 14:30 +0100 is 13:30 UTC.
        #expect(sport.start == IPTVFixtures.guideNow.addingTimeInterval(90 * 60))
        // No offset means UTC.
        #expect(guide.programmes["movies"]?.first?.start == IPTVFixtures.guideNow)
    }

    @Test func channelFilterSkipsOtherProgrammes() throws {
        let guide = try parse(channelIDs: ["news.one"])
        #expect(Set(guide.programmes.keys) == ["news.one"])
        #expect(try parse().programmes["unknown.channel"]?.count == 1)
    }

    @Test func dates() {
        #expect(XMLTVParser.date("20261106120000 +0000") == IPTVFixtures.guideNow)
        #expect(XMLTVParser.date("20261106130000 +0100") == IPTVFixtures.guideNow)
        #expect(XMLTVParser.date("20261106070000 -0500") == IPTVFixtures.guideNow)
        #expect(XMLTVParser.date("202611061200") == IPTVFixtures.guideNow)
        #expect(XMLTVParser.date("nope") == nil)
    }

    @Test func truncatedFileKeepsWhatWasRead() throws {
        let truncated = String(IPTVFixtures.guide.dropLast(400))
        let guide = try XMLTVParser.parse(
            data: Data(truncated.utf8),
            options: XMLTVParser.Options(window: window, channelIDs: nil)
        )
        #expect(guide.programmes["news.one"]?.isEmpty == false)
    }

    @Test func streamsAGzippedFile() throws {
        let gzip = try #require(Data(base64Encoded: Self.gzippedGuide))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dusk-test-\(UUID().uuidString).xml.gz")
        try gzip.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(GzipFile.isGzip(file))
        let guide = try XMLTVParser.parse(
            fileURL: file,
            options: XMLTVParser.Options(window: window, channelIDs: nil)
        )
        #expect(guide.channels["c1"]?.displayNames == ["Gz One"])
        #expect(guide.programmes["c1"]?.first?.title == "Zipped Show")
    }

    /// A one-programme guide gzipped with a file name in the header (FNAME).
    private static let gzippedGuide = "H4sICAAAAAAC/2d1aWRlLnhtbABVjjsLAjEQhP9KSCuah3DVXq60tLCzC5fFC+RFEs7HrzdikHOLZZmPmVmYHt6RFXOxMYxUHDidFNRVwbzoENARa0Y6C6rA2JKcfu6D9qhOL3IOCOxPBNZNClKOt6y9R1KqznWkkstBCD4IyduQ3WfTBmPasOOW9azeXm11qK42JTTkssQ7sK8E7NfV7vb5G8sEWAzTAAAA"
}

@Suite("IPTV lineup mapping")
struct IPTVLineupBuilderTests {
    private let source = IPTVSource(
        name: "Relay",
        playlistURL: URL(string: "https://relay.example.com/playlist.m3u")!,
        headerName: "Authorization"
    )

    private func lineup() throws -> PlexLiveTVLineup {
        let playlist = M3UParser.parse(IPTVFixtures.extendedPlaylist)
        let guide = try XMLTVParser.parse(
            data: Data(IPTVFixtures.guide.utf8),
            options: XMLTVParser.Options(
                window: IPTVFixtures.guideNow.addingTimeInterval(-3600)...IPTVFixtures.guideNow.addingTimeInterval(86400),
                channelIDs: IPTVLineupBuilder.wantedGuideChannelIDs(for: playlist)
            )
        )
        return IPTVLineupBuilder.lineup(
            source: source,
            playlist: playlist,
            guide: guide,
            sourceHeaders: ["Authorization": "Bearer secret"]
        )
    }

    private func guide(_ title: String) throws -> PlexLiveChannelGuide {
        try #require(try lineup().guides.first { $0.channel.title == title })
    }

    @Test func everyEntryIsAnIPTVChannelInPlaylistOrder() throws {
        let lineup = try lineup()
        #expect(lineup.provider.isIPTV)
        #expect(lineup.provider.title == "Relay")
        #expect(lineup.channels.map(\.title) == [
            "News One HD", "Sport Two", "Movies 24", "Widevine Channel", "bare-entry",
        ])
        #expect(lineup.channels.allSatisfy { $0.iptv?.sourceID == source.id })
        #expect(Set(lineup.channels.map(\.id)).count == lineup.channels.count)
    }

    @Test func matchesGuideByIDIgnoringCaseAndByName() throws {
        #expect(try guide("News One HD").programs.count == 2)
        // tvg-id "sport.two" vs guide id "Sport.Two".
        #expect(try guide("Sport Two").programs.first?.primaryDisplayTitle == "Grand Prix: Qualifying")
        // No tvg-id: matched by its title against the guide's display-name.
        #expect(try guide("Movies 24").programs.first?.displayTitle == "Feature Film")
        #expect(try guide("bare-entry").programs.isEmpty)
    }

    @Test func nowAndNextAndSeriesMapping() throws {
        let news = try guide("News One HD")
        let now = IPTVFixtures.guideNow.addingTimeInterval(600)
        #expect(news.currentProgram(at: now)?.displayTitle == "Midday News")
        let next = try #require(news.nextProgram(after: now))
        // XMLTV title = show, sub-title = episode, like Plex's grandparent.
        #expect(next.primaryDisplayTitle == "Afternoon Report")
        #expect(next.episodeDisplayTitle == "Markets")
        // Shared guide plumbing finds the channel back from the program.
        #expect(try lineup().channel(for: next)?.title == "News One HD")
    }

    @Test func logosPreferThePlaylistThenTheGuide() throws {
        #expect(try guide("News One HD").channel.thumb == "https://img.example.com/news.png")
        #expect(try guide("Sport Two").channel.thumb == "https://img.example.com/guide-sport.png")
    }

    @Test func playableCarriesHeadersUserAgentAndDRM() throws {
        let sport = try #require(try guide("Sport Two").channel.iptv)
        #expect(sport.headers == ["Authorization": "Bearer secret", "Referer": "https://portal.example.com/"])
        #expect(sport.userAgent == "DuskTest/1.0")
        #expect(sport.drm?.keySystem == .fairPlay)
        let movies = try #require(try guide("Movies 24").channel.iptv)
        #expect(movies.headers == ["Authorization": "Bearer secret", "X-Token": "abc"])
    }

    @Test func guideFilterNeedsEveryTvgID() {
        let withIDs = M3UParser.parse("#EXTINF:-1 tvg-id=\"a\",A\nhttp://x.example.com/a\n#EXTINF:-1 tvg-id=\"b\",B\nhttp://x.example.com/b\n")
        #expect(IPTVLineupBuilder.wantedGuideChannelIDs(for: withIDs) == ["a", "b"])
        #expect(IPTVLineupBuilder.wantedGuideChannelIDs(for: M3UParser.parse(IPTVFixtures.extendedPlaylist)) == nil)
    }

    @Test func sourceHeaderNeedsNameAndValue() {
        #expect(IPTVSourceLoader.headers(for: source, headerValue: "Bearer x") == ["Authorization": "Bearer x"])
        #expect(IPTVSourceLoader.headers(for: source, headerValue: nil).isEmpty)
        var noName = source
        noName.headerName = nil
        #expect(IPTVSourceLoader.headers(for: noName, headerValue: "x").isEmpty)
    }
}

@Suite("IPTV source store")
struct IPTVSourceStoreTests {
    @Test func sourcesArePerProfileAndSecretsAreSeparate() throws {
        let defaults = try #require(UserDefaults(suiteName: "dusk-iptv-tests-\(UUID().uuidString)"))
        let box = SecretBox()
        let store = IPTVSourceStore(
            defaults: defaults,
            secrets: .init(load: { box.data }, save: { box.data = $0 }, delete: { box.data = nil })
        )
        let source = IPTVSource(name: "A", playlistURL: URL(string: "https://a.example.com/p.m3u")!, headerName: "X-Key")
        store.save([source], profileID: "profile-1")
        store.setHeaderValue("s3cret", for: source.id)

        #expect(store.sources(profileID: "profile-1") == [source])
        #expect(store.sources(profileID: "profile-2").isEmpty)
        #expect(store.headerValue(for: source.id) == "s3cret")
        // The secret never lands in the defaults.
        let stored = try #require(defaults.data(forKey: "IPTVSources.profile-1"))
        #expect(!String(decoding: stored, as: UTF8.self).contains("s3cret"))

        store.setHeaderValue(nil, for: source.id)
        #expect(box.data == nil)
    }

    private final class SecretBox: @unchecked Sendable {
        var data: Data?
    }
}
