import Foundation
import Testing
@testable import Dusk

/// `JellyfinItemMapper` / `JellyfinMediaMapper` over the responses recorded
/// from jellyfin-demo (docs/jellyfin/05-plan.md J-00b). The cross-provider
/// comparison is `ProviderContractTests`.
@Suite("Jellyfin mappers")
struct JellyfinMapperTests {
    static let serverID = "feedfacefeedfacefeedfacefeedface"

    private func item(_ name: String) throws -> JellyfinItemDTO {
        try JellyfinFixtures.decode(JellyfinItemDTO.self, name)
    }

    private func details(_ name: String) throws -> MediaDetails {
        JellyfinItemMapper.mapDetails(try item(name), serverID: Self.serverID)
    }

    private func part(_ name: String) throws -> MediaPart {
        let details = try details(name)
        return try #require(details.media.first?.parts.first)
    }

    // MARK: External-subtitle index trap (02 §9)

    /// `AV1 SDR Test` has a sidecar `.en.srt`: Jellyfin gives it `Index` 0, so
    /// the video is 1 and the audio 2 and 3. Ids keep the server's index;
    /// positions are per kind among embedded streams, and the sidecar sorts
    /// last with a key so engines attach it by URL.
    @Test("external subtitle at Index 0 does not shift engine positions", arguments: [
        "item-av1-sdr-test-2026", "playback-info-av1-sdr-vlc",
    ])
    func externalSubtitleIndexTrap(fixture: String) throws {
        let part: MediaPart
        if fixture.hasPrefix("playback-info") {
            let response = try JellyfinFixtures.decode(JellyfinPlaybackInfoResponseDTO.self, fixture)
            let source = try #require(response.mediaSources.first)
            part = try #require(JellyfinMediaMapper.map(source, itemID: source.id).parts.first)
        } else {
            part = try self.part(fixture)
        }

        #expect(part.streams.map(\.id) == ["1", "2", "3", "0"])
        #expect(part.streams.map(\.kind) == [.video, .audio, .audio, .subtitle])

        let subtitle = try #require(part.streams.last)
        #expect(subtitle.codec == "srt")
        let key = try #require(subtitle.key)
        #expect(key.hasSuffix("/Subtitles/0/0/Stream.srt"))
        #expect(!key.localizedCaseInsensitiveContains("apikey"))

        #expect(JellyfinStreamPositions.position(ofIndex: 1, kind: .video, in: part) == 0)
        #expect(JellyfinStreamPositions.position(ofIndex: 2, kind: .audio, in: part) == 0)
        #expect(JellyfinStreamPositions.position(ofIndex: 3, kind: .audio, in: part) == 1)
        #expect(JellyfinStreamPositions.index(atPosition: 0, kind: .audio, in: part) == 2)
        #expect(JellyfinStreamPositions.position(ofIndex: 0, kind: .subtitle, in: part) == nil)
        #expect(JellyfinStreamPositions.index(atPosition: 0, kind: .subtitle, in: part) == nil)

        // DefaultAudioStreamIndex 2, DefaultSubtitleStreamIndex 0.
        #expect(part.streams.filter { $0.isServerSelected == true }.map(\.id) == ["2", "0"])
        // The engine's audio track id stays the server's index.
        #expect(AudioTrack(stream: part.streams[1]).id == 2)
    }

    @Test("embedded streams keep container order within each kind")
    func embeddedOrder() throws {
        let part = try part("item-knives-out")
        let subtitles = part.streams.filter { $0.kind == .subtitle }
        #expect(subtitles.map(\.id) == subtitles.map(\.id).sorted { Int($0)! < Int($1)! })
        #expect(subtitles.allSatisfy { $0.key == nil })
        #expect(JellyfinStreamPositions.position(ofIndex: 4, kind: .subtitle, in: part) == 0)
        #expect(JellyfinStreamPositions.position(ofIndex: 7, kind: .subtitle, in: part) == 3)
    }

    // MARK: Server-selected tracks

    @Test("isServerSelected follows the source's default indexes")
    func serverSelected() throws {
        let knivesOut = try part("item-knives-out")
        #expect(knivesOut.streams.filter { $0.isServerSelected == true }.map(\.id) == ["1", "4"])
        // Every SRT carries the file's default flag; that stays a flag.
        #expect(knivesOut.streams.filter { $0.kind == .subtitle && $0.isDefault == true }.count > 1)

        // `-1` means no subtitle.
        let response = try JellyfinFixtures.decode(JellyfinPlaybackInfoResponseDTO.self, "playback-info-knives-out-vlc")
        let source = try #require(response.mediaSources.first)
        let streams = try #require(JellyfinMediaMapper.map(source, itemID: source.id).parts.first?.streams)
        #expect(streams.filter { $0.isServerSelected == true }.map(\.id) == ["1"])
        #expect(streams.filter { $0.kind == .video }.allSatisfy { $0.isServerSelected == nil })
    }

    // MARK: Codec alias table

    @Test("codec names map into the domain vocabulary")
    func codecAliases() {
        let cases: [(String?, String?)] = [
            ("PGSSUB", "pgs"), ("subrip", "srt"), ("SRT", "srt"), ("dvdsub", "vobsub"), ("webvtt", "vtt"),
            ("ass", "ass"), ("mov_text", "mov_text"), ("dca", "dts"), ("DTS", "dts"), ("hevc", "hevc"),
            ("h265", "hevc"), ("H264", "h264"), ("truehd", "truehd"), ("eac3", "eac3"), ("", nil), (nil, nil),
        ]
        for (raw, expected) in cases {
            #expect(JellyfinCodecAliases.codec(raw) == expected, "\(raw ?? "nil")")
        }
    }

    @Test("containers map to Plex's names")
    func containerAliases() {
        #expect(JellyfinCodecAliases.container("mov,mp4,m4a,3gp,3g2,mj2", path: "/a/b.mp4") == "mp4")
        #expect(JellyfinCodecAliases.container("mov", path: "/a/b.mp4") == "mp4")
        #expect(JellyfinCodecAliases.container("mov", path: "/a/b.mov") == "mov")
        #expect(JellyfinCodecAliases.container("mp4", path: "/a/b.mp4") == "mp4")
        #expect(JellyfinCodecAliases.container("matroska,webm", path: "/a/b.mkv") == "mkv")
        #expect(JellyfinCodecAliases.container("mkv", path: nil) == "mkv")
        #expect(JellyfinCodecAliases.container("ts", path: "/a/b.m2ts") == "mpegts")
        #expect(JellyfinCodecAliases.container("avi", path: "/a/b.avi") == "avi")
        #expect(JellyfinCodecAliases.container(nil, path: "/a/b.mkv") == nil)
    }

    /// Every recorded item with media maps to canonical names only.
    @Test("no raw server codec name reaches the domain")
    func everyFixtureCanonical() throws {
        let raw: Set<String> = ["pgssub", "subrip", "dvdsub", "webvtt", "dca", "h265"]
        let names = try JellyfinFixtures.allNames().filter { $0.hasPrefix("item-") }
        var mapped = 0
        for name in names {
            guard let dto = try? item(name), let sources = dto.mediaSources, !sources.isEmpty else { continue }
            for version in JellyfinMediaMapper.map(sources, itemID: dto.id) {
                mapped += 1
                let codecs = version.parts.flatMap(\.streams).compactMap(\.codec)
                #expect(codecs.allSatisfy { !raw.contains($0) && $0 == $0.lowercased() }, "\(name): \(codecs)")
                #expect(["mkv", "mp4", "mov", "mpegts"].contains(version.container ?? ""), "\(name)")
                #expect(version.parts.count == 1)
                let ids = version.parts.flatMap(\.streams).map(\.id)
                #expect(Set(ids).count == ids.count, "\(name): duplicate stream ids")
            }
        }
        #expect(mapped >= 25)
    }

    // MARK: Torture files (03 §5.1)

    struct VideoExpectation: Sendable, CustomTestStringConvertible {
        let fixture: String
        let profile: Int?
        let blCompatID: Int?
        let transfer: StreamResolver.HDRTransfer?
        var testDescription: String { fixture }
    }

    @Test("Dolby Vision and HDR signalling", arguments: [
        VideoExpectation(fixture: "item-dv-p5-jellyfin-4k-test-2024", profile: 5, blCompatID: 0, transfer: nil),
        VideoExpectation(fixture: "item-dv-p7-fel-all-layers-test-2020", profile: 7, blCompatID: 6, transfer: .pq),
        VideoExpectation(fixture: "item-dv-p8-1-jellyfin-4k-test-2024", profile: 8, blCompatID: 1, transfer: .pq),
        VideoExpectation(fixture: "item-dv-p8-4-hlg-jellyfin-4k-test-2024", profile: 8, blCompatID: 4, transfer: .hlg),
        VideoExpectation(fixture: "item-hdr10-jellyfin-4k-hevc-60m-2024", profile: nil, blCompatID: nil, transfer: .pq),
        VideoExpectation(fixture: "item-big-buck-bunny", profile: nil, blCompatID: nil, transfer: nil),
    ])
    func dolbyVision(_ expectation: VideoExpectation) throws {
        let video = try #require(try part(expectation.fixture).streams.first { $0.kind == .video })
        if let profile = expectation.profile {
            let dolbyVision = try #require(video.dolbyVision)
            #expect(dolbyVision.present == true)
            #expect(dolbyVision.profile == profile)
            #expect(dolbyVision.blCompatID == expectation.blCompatID)
        } else {
            #expect(video.dolbyVision == nil)
        }
        #expect(StreamResolver.hdrTransfer(of: video) == expectation.transfer)
    }

    @Test("sample entry, Atmos, DTS:X and TrueHD")
    func audioAndSampleEntry() throws {
        let p5 = try part("item-dv-p5-jellyfin-4k-test-2024")
        #expect(p5.streams.first?.codecID == "dvh1")

        let atmos = try #require(try part("item-eac3-atmos-joc-hdr10").streams.first { $0.kind == .audio })
        #expect(StreamResolver.isDolbyAtmos(atmos))
        #expect(atmos.displayTitle?.contains("+ Atmos") == true)

        let dtsX = try #require(try part("item-dts-hd-ma-dts-x-gravity-demo-2020").streams.first { $0.kind == .audio })
        #expect(dtsX.codec == "dts")
        #expect(dtsX.displayTitle?.contains("DTS:X") == true)

        let trueHD = try details("item-truehd-7-1-channel-check-2020")
        #expect(trueHD.media.first?.container == "mpegts")
        #expect(trueHD.media.first?.audioCodec == "truehd")
    }

    @Test("units: kbit/s, ms, Plex resolution names")
    func units() throws {
        let version = try #require(try details("item-knives-out").media.first)
        #expect(version.bitrate == 8133)
        #expect(version.duration == 7_817_247)
        #expect(version.videoResolution == "1080")
        #expect(version.width == 1920)
        let video = try #require(version.parts.first?.streams.first)
        #expect(video.level == 153)
        #expect(video.profile == "main 10")
        #expect(video.chromaSubsampling == "4:2:0")
        #expect(video.bitrate == 6905)
        #expect(try details("item-dune-part-two").media.first?.videoResolution == "4k")
    }

    @Test("Plex-shaped track labels")
    func labels() throws {
        let streams = try part("item-the-office-s01e01").streams
        let audio = streams.filter { $0.kind == .audio }
        #expect(audio[0].displayTitle == "English (DTS-HD MA Stereo)")
        #expect(audio[0].extendedDisplayTitle == "Stereo (English DTS-HD MA)")
        #expect(audio[0].language == "English")
        #expect(audio[0].languageCode == "eng")
        #expect(audio[0].languageTag == "en")
        #expect(audio[2].displayTitle == "English (AC3 Stereo)")
        let subtitle = try #require(streams.first { $0.kind == .subtitle })
        #expect(subtitle.displayTitle == "English")
        #expect(subtitle.extendedDisplayTitle == "English (PGS)")
    }

    // MARK: Item fields

    @Test("dates round to the nearest day and become epoch seconds")
    func dates() throws {
        #expect(try details("item-knives-out").originallyAvailableAt == "2019-11-27")
        // `2024-02-26T23:00:00Z` and `2005-03-23T23:00:00Z`: local midnight stored as UTC.
        #expect(try details("item-dune-part-two").originallyAvailableAt == "2024-02-27")
        #expect(try details("item-the-office-s01e01").originallyAvailableAt == "2005-03-24")
        // DateCreated 2020-12-20T08:56:16Z
        #expect(JellyfinItemMapper.map(try item("item-the-office-s01e01"), serverID: nil).addedAt == 1_608_454_576)
    }

    @Test("watched state comes from Played, not PlayCount")
    func watchState() throws {
        let dune = JellyfinItemMapper.map(try item("item-dune-part-two"), serverID: nil)
        #expect(dune.playCount == nil)
        #expect(dune.resumeOffsetMs == 607_000)
        #expect(dune.isPartiallyWatched && !dune.isWatched)
        #expect(dune.lastPlayedAt != nil)

        let watched = JellyfinItemMapper.map(try item("item-dv-p7-mel-awaken-girl-color-accuracy-2020"), serverID: nil)
        #expect(watched.isWatched)
        #expect(watched.resumeOffsetMs == nil)

        // Every playback start bumps PlayCount, finished or not (02 §8).
        let started = try JellyfinJSON.decode(JellyfinItemDTO.self, from: Data(#"""
            {"Id": "AB", "Type": "Movie", "UserData": {"PlayCount": 3, "Played": false, "PlaybackPositionTicks": 0}}
            """#.utf8))
        #expect(JellyfinItemMapper.watchState(started) == .init())
    }

    @Test("show and season counts")
    func counts() throws {
        let show = JellyfinItemMapper.map(try item("item-series-the-office"), serverID: nil)
        #expect(show.type == .show)
        #expect(show.episodeCount == 186)
        #expect(show.watchedEpisodeCount == 0)
        #expect(show.childCount == 9)

        let season = JellyfinItemMapper.mapSeason(try item("item-season-the-office-s01"), serverID: Self.serverID)
        #expect(season.index == 1)
        #expect(season.episodeCount == 6)
        #expect(season.watchedEpisodeCount == 0)
        #expect(season.parentID == "4eb7e22c1653ab565cf44daa4176ca56")
    }

    @Test("ids are normalised and stamped with the server")
    func ids() throws {
        let episode = JellyfinItemMapper.mapEpisode(try item("item-the-office-s01e01"),
                                                    serverID: "FEEDFACE-FEED-FACE-FEED-FACEFEEDFACE")
        #expect(episode.serverID == Self.serverID)
        #expect(episode.itemID == "bf695ca96f49ed398033495d141110b4")
        #expect(episode.parentID == "89b6f2f7378f55721704fcbc3b7b776f")
        #expect(episode.grandparentID == "4eb7e22c1653ab565cf44daa4176ca56")
        #expect(episode.grandparentTitle == "The Office")
        #expect(episode.index == 1 && episode.parentIndex == 1)
        #expect(episode.duration == 1_405_162)
        #expect(JellyfinItemMapper.itemPath("980DFFD6-DFA0-D8CF-D69E-5BD6B350E983") == "/Items/980dffd6dfa0d8cfd69e5bd6b350e983")
    }

    @Test("external ids: tmdb, imdb, tvdb only")
    func externalIDs() throws {
        let knivesOut = try details("item-knives-out")
        #expect(knivesOut.guids.map(\.id) == ["tmdb://546554", "imdb://tt8946378"])
        #expect(knivesOut.guid == nil)
        #expect(knivesOut.contentKey == .external(provider: "tmdb", namespace: "movie", id: "546554"))

        let episode = try details("item-the-office-s01e01")
        #expect(episode.externalIDs.tvdb == "110413")
        #expect(!episode.guids.contains { $0.id.hasPrefix("tvrage") })
    }

    @Test("ratings on the domain scale, no invented source")
    func ratings() throws {
        let knivesOut = try details("item-knives-out")
        #expect(knivesOut.audienceRating == 7.843)
        #expect(knivesOut.rating == nil)
        #expect(knivesOut.ratings == [Rating(image: nil, value: 7.843, type: "audience")])
        #expect(knivesOut.contentRating == "CH-12")
    }

    @Test("artwork locators name the item that owns the image")
    func artwork() throws {
        let episode = JellyfinItemMapper.map(try item("item-the-office-s01e01"), serverID: Self.serverID)
        #expect(episode.thumb == "jf:bf695ca96f49ed398033495d141110b4:Primary:0:2951db227fc18090be8ff9fc256faec9")
        #expect(episode.parentThumb == "jf:89b6f2f7378f55721704fcbc3b7b776f:Primary:0:22f82df02f46e618909e146f5de1907a")
        #expect(episode.grandparentThumb == "jf:4eb7e22c1653ab565cf44daa4176ca56:Primary:0:e0ce18f7308a1a86a0463d6acf99bd55")
        #expect(episode.grandparentArt == "jf:4eb7e22c1653ab565cf44daa4176ca56:Backdrop:0:8635884fe0a24bdb4edee384b5c54ca7")
        #expect(episode.art == episode.grandparentArt)
        #expect(episode.clearLogo == "jf:4eb7e22c1653ab565cf44daa4176ca56:Logo:0:cc076bcbb16ed56a9ffe2b09f2f7eb5b")
        #expect(episode.preferredPoster?.serverID == Self.serverID)
        #expect(episode.preferredPoster?.locator == episode.parentThumb)

        let movie = JellyfinItemMapper.map(try item("item-knives-out"), serverID: Self.serverID)
        #expect(movie.thumb == "jf:980dffd6dfa0d8cfd69e5bd6b350e983:Primary:0:0365dc4be0aee9bc30ce697faff421fb")
        #expect(movie.art == "jf:980dffd6dfa0d8cfd69e5bd6b350e983:Backdrop:0:1676f5a4dec19f33258e88482c88208d")
        // `Thumb` has the title baked in and is never a slot.
        let thumbTag = "1c19a28452e05a1aa8346335467d8935"
        #expect(![movie.thumb, movie.art, movie.banner, movie.clearLogo].contains { $0?.contains(thumbTag) == true })

        let season = JellyfinItemMapper.mapSeason(try item("item-season-the-office-s01"), serverID: nil)
        #expect(season.parentThumb == "jf:4eb7e22c1653ab565cf44daa4176ca56:Primary:0:e0ce18f7308a1a86a0463d6acf99bd55")
    }

    @Test("locator round trip")
    func locator() throws {
        let locator = JellyfinArtworkLocator(itemID: "980DFFD6-DFA0-D8CF-D69E-5BD6B350E983", type: .backdrop,
                                             index: 2, tag: "abc")
        #expect(locator.locator == "jf:980dffd6dfa0d8cfd69e5bd6b350e983:Backdrop:2:abc")
        #expect(JellyfinArtworkLocator(locator: locator.locator) == locator)
        #expect(JellyfinArtworkLocator(locator: "/library/metadata/1/thumb/2") == nil)
        #expect(JellyfinArtworkLocator(locator: "jf:x:Primary:-1:a") == nil)
        #expect(JellyfinArtworkLocator.path(itemID: "a", type: .primary, tag: nil) == nil)
        #expect(JellyfinArtworkLocator.path(itemID: nil, type: .primary, tag: "t") == nil)
    }

    @Test("cast and crew")
    func people() throws {
        let knivesOut = try details("item-knives-out")
        let lead = try #require(knivesOut.roles?.first)
        #expect(lead.tag == "Daniel Craig")
        #expect(lead.role == "Benoit Blanc")
        #expect(lead.tagKey == "7756ef19211166d2d5290b3eb1d354b9")
        #expect(lead.thumb == "jf:7756ef19211166d2d5290b3eb1d354b9:Primary:0:68aff68f4e78d3e88f83a1f1f5a8c425")
        #expect(knivesOut.directors?.map(\.tag).contains("Rian Johnson") == true)

        let person = JellyfinItemMapper.mapPerson(try item("item-person"))
        #expect(person.personID?.count == 32)
    }

    @Test("skip markers from MediaSegments")
    func markers() throws {
        func markers(_ fixture: String) throws -> [Marker] {
            JellyfinMediaMapper.markers(
                try JellyfinFixtures.decode(JellyfinQueryResult<JellyfinMediaSegmentDTO>.self, fixture).items
            )
        }
        let office = try markers("media-segments-the-office-s01e01")
        #expect(office.map(\.type) == ["intro", "credits"])
        #expect(office[0].isIntro && office[1].isCredits)
        #expect(office[0].startTimeOffset == 0)
        #expect(office[0].endTimeOffset == 54_555)
        #expect(office[1].endTimeOffset == 1_405_162)

        let knivesOut = try markers("media-segments-knives-out")
        #expect(knivesOut.map(\.type) == ["credits"])
        #expect(knivesOut.first?.startTimeOffset == 7_549_292)
        #expect(knivesOut.first?.endTimeOffset == 7_817_247)
    }

    @Test("user views become library tabs")
    func libraries() throws {
        let views = try JellyfinFixtures.decode(JellyfinQueryResult<JellyfinItemDTO>.self, "user-views").items
        let libraries = views.compactMap { JellyfinItemMapper.mapLibrary($0, serverID: Self.serverID) }
        let byTitle = Dictionary(uniqueKeysWithValues: libraries.map { ($0.title, $0) })
        #expect(byTitle["Real Movies"]?.libraryType == .movie)
        #expect(byTitle["Real TV"]?.libraryType == .show)
        #expect(byTitle["Home Videos"]?.libraryType == .video)
        #expect(byTitle["Real Movies"]?.id == "\(Self.serverID)|cbcdd01d873770bc0709c2b8e441f372")
        #expect(byTitle["Shorts"]?.thumb == nil)
    }

    @Test("item kinds")
    func kinds() throws {
        #expect(try details("item-knives-out").type == .movie)
        #expect(try details("item-series-the-office").type == .show)
        #expect(try details("item-season-the-office-s01").type == .season)
        #expect(try details("item-the-office-s01e01").type == .episode)
        #expect(try details("item-person").type == .person)
        let boxSets = try JellyfinFixtures.decode(JellyfinQueryResult<JellyfinItemDTO>.self, "items-boxsets").items
        #expect(boxSets.allSatisfy { JellyfinItemMapper.mediaKind($0) == .collection })
        let videos = try JellyfinFixtures.decode(JellyfinQueryResult<JellyfinItemDTO>.self, "items-home-videos").items
        #expect(videos.filter { $0.type?.matches(.video) == true }
            .allSatisfy { JellyfinItemMapper.map($0, serverID: nil).isClip })
    }
}
