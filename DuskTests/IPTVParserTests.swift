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

@Suite("Xtream playlists")
struct XtreamPlaylistTests {
    private let credentials = XtreamURL.Credentials(username: "user", password: "p@ss")

    @Test func credentialsComeFromTheGetPHPQuery() {
        let url = URL(string: "http://panel.example.com:8080/get.php?username=user&password=p%40ss&type=m3u_plus&output=ts")!
        #expect(XtreamURL.credentials(fromPlaylistURL: url) == credentials)
        #expect(XtreamURL.credentials(fromPlaylistURL: URL(string: "https://x.example.com/list.m3u")!) == nil)
    }

    @Test func moviesAndSeriesAreVOD() {
        #expect(XtreamURL.isVOD(URL(string: "http://panel.example.com/movie/user/pass/123.mkv")!))
        #expect(XtreamURL.isVOD(URL(string: "http://panel.example.com/series/user/pass/456.mp4")!))
        #expect(XtreamURL.isVOD(URL(string: "http://panel.example.com/proxy/MOVIE/user/pass/1.avi")!))
        #expect(!XtreamURL.isVOD(URL(string: "http://panel.example.com/live/user/pass/123.ts")!))
        // A generic list's path that merely contains the word.
        #expect(!XtreamURL.isVOD(URL(string: "https://cdn.example.com/movie/trailer.m3u8")!))
    }

    @Test func rawTSLiveBecomesHLS() {
        func hls(_ text: String, _ credentials: XtreamURL.Credentials? = nil) -> String? {
            XtreamURL.liveHLSURL(for: URL(string: text)!, credentials: credentials)?.absoluteString
        }
        #expect(hls("http://panel.example.com:8080/live/user/pass/123.ts") == "http://panel.example.com:8080/live/user/pass/123.m3u8")
        #expect(hls("http://panel.example.com/live/user/pass/123") == "http://panel.example.com/live/user/pass/123.m3u8")
        #expect(hls("http://panel.example.com/live/user/pass/123.ts?token=a") == "http://panel.example.com/live/user/pass/123.m3u8?token=a")
        // Older extensionless form: only when the path carries the playlist's credentials.
        #expect(hls("http://panel.example.com/user/p%40ss/123", credentials) == "http://panel.example.com/live/user/p%40ss/123.m3u8")
        #expect(hls("http://panel.example.com/user/p%40ss/123.ts", credentials) == "http://panel.example.com/live/user/p%40ss/123.m3u8")
        #expect(hls("http://panel.example.com/other/name/123", credentials) == nil)
        #expect(hls("http://panel.example.com/user/p%40ss/123") == nil)
        // Already HLS, not a numeric stream id, or not Xtream at all.
        #expect(hls("http://panel.example.com/live/user/pass/123.m3u8") == nil)
        #expect(hls("http://panel.example.com/live/user/pass/news.ts") == nil)
        #expect(hls("https://cdn.example.com/a/b/segment.ts") == nil)
    }

    @Test func m3uPlusKeepsLiveChannelsAsHLSAndSkipsVOD() {
        let text = """
        #EXTM3U
        #EXTINF:-1 tvg-id="news.us" tvg-name="US| News" group-title="US | General",US| News
        http://panel.example.com:8080/live/user/p@ss/101.ts
        #EXTINF:-1 tvg-id="" tvg-name="Film (2020)" group-title="VOD | Action",Film (2020)
        http://panel.example.com:8080/movie/user/p@ss/201.mkv
        #EXTINF:-1 tvg-id="" tvg-name="Show S01 E01" group-title="SERIES | Drama",Show S01 E01
        http://panel.example.com:8080/series/user/p@ss/301.mp4
        #EXTINF:-1 tvg-id="old.style",Old Style
        http://panel.example.com:8080/user/p@ss/102
        """
        let options = M3UParser.Options(
            playlistURL: URL(string: "http://panel.example.com:8080/get.php?username=user&password=p@ss&type=m3u_plus&output=ts")
        )
        let playlist = M3UParser.parse(text, options: options)
        #expect(playlist.entries.map(\.title) == ["US| News", "Old Style"])
        #expect(playlist.entries.map(\.streamURL.path) == ["/live/user/p@ss/101.m3u8", "/live/user/p@ss/102.m3u8"])
        #expect(playlist.skippedVODEntries == 2)
    }

    @Test func fileParseMatchesTextParseAcrossChunks() throws {
        // > 1 MB so lines cross the reader's chunk boundary; CRLF and LF mixed.
        var text = "#EXTM3U\r\n"
        for index in 0..<12_000 {
            text += "#EXTINF:-1 tvg-id=\"c\(index)\" group-title=\"Group \(index % 7)\",Channel \(index)\r\n"
            text += index.isMultiple(of: 2)
                ? "http://panel.example.com/live/u/p/\(index).ts\n"
                : "http://panel.example.com/movie/u/p/\(index).mkv\r\n"
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dusk-m3u-\(UUID().uuidString).m3u")
        try Data(text.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(text.utf8.count > 1 << 20)

        let fromFile = try M3UParser.parse(fileURL: file)
        #expect(fromFile == M3UParser.parse(text))
        #expect(fromFile.entries.count == 6_000)
        #expect(fromFile.skippedVODEntries == 6_000)
        #expect(fromFile.entries.last?.streamURL.absoluteString == "http://panel.example.com/live/u/p/11998.m3u8")
    }

    @Test func fileParseDropsAnEndlessLine() throws {
        var data = Data("#EXTM3U\n#EXTINF:-1,First\nhttp://a.example.com/1.m3u8\n".utf8)
        data.append(Data(repeating: 0x41, count: 3 << 20))
        data.append(Data("\n#EXTINF:-1,Second\nhttp://a.example.com/2.m3u8".utf8))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dusk-m3u-\(UUID().uuidString).m3u")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try M3UParser.parse(fileURL: file).entries.map(\.title) == ["First", "Second"])
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
        #expect(Set(guide.channels.keys) == ["news.one"])
        #expect(try parse().programmes["unknown.channel"]?.count == 1)
    }

    @Test func channelFilterMatchesIDsIgnoringCaseAndDisplayNames() throws {
        let guide = try XMLTVParser.parse(
            data: Data(IPTVFixtures.guide.utf8),
            options: XMLTVParser.Options(window: window, channelIDs: ["sport.two"], channelNames: ["movies 24"])
        )
        #expect(Set(guide.programmes.keys) == ["Sport.Two", "movies"])
        #expect(Set(guide.channels.keys) == ["Sport.Two", "movies"])
    }

    @Test func guideLimitKeepsTheProgrammesClosestToNow() {
        let now = IPTVFixtures.guideNow
        func programme(_ channel: String, hours: Double) -> IPTVProgramme {
            IPTVProgramme(channelID: channel, start: now.addingTimeInterval(hours * 3600),
                          stop: now.addingTimeInterval((hours + 1) * 3600), title: "\(channel) \(hours)")
        }
        let guide = IPTVGuide(channels: [:], programmes: [
            "a": (-6...5).map { programme("a", hours: Double($0)) },
            "b": (-6...5).map { programme("b", hours: Double($0)) },
            "c": [programme("c", hours: 30)],
        ])
        #expect(guide.programmeCount == 25)
        #expect(guide.limited(to: 100, around: now) == guide)

        let limited = guide.limited(to: 6, around: now)
        // On air and just ended (distance 0), then an hour out either way; ties
        // at the cut are kept, so 8 rather than 6.
        #expect(limited.programmes["a"]?.map(\.title) == ["a -2.0", "a -1.0", "a 0.0", "a 1.0"])
        #expect(limited.programmes["b"]?.count == 4)
        #expect(limited.programmes["c"] == nil)
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

    private func lineup() throws -> LiveTVLineup {
        let playlist = M3UParser.parse(IPTVFixtures.extendedPlaylist)
        // The same filter the loader uses: the case-insensitive and the
        // by-name matches below must survive it.
        let filter = IPTVLineupBuilder.guideChannelFilter(for: playlist)
        let guide = try XMLTVParser.parse(
            data: Data(IPTVFixtures.guide.utf8),
            options: XMLTVParser.Options(
                window: IPTVFixtures.guideNow.addingTimeInterval(-3600)...IPTVFixtures.guideNow.addingTimeInterval(86400),
                channelIDs: filter.ids,
                channelNames: filter.names
            )
        )
        return IPTVLineupBuilder.lineup(
            source: source,
            playlist: playlist,
            guide: guide,
            sourceHeaders: ["Authorization": "Bearer secret"]
        )
    }

    private func guide(_ title: String) throws -> LiveChannelGuide {
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

    @Test func guideFilterHasIDsAndNames() {
        let playlist = M3UParser.parse("#EXTINF:-1 tvg-id=\"a\" tvg-name=\" Alpha \",A One\nhttp://x.example.com/a\n#EXTINF:-1 tvg-id=\"\",B\nhttp://x.example.com/b\n")
        let filter = IPTVLineupBuilder.guideChannelFilter(for: playlist)
        #expect(filter.ids == ["a"])
        #expect(filter.names == ["alpha", "a one", "b"])
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
