import Foundation
import Testing
@testable import Dusk

/// Decodes the responses recorded from jellyfin-demo (Jellyfin 12.4) and checks
/// values documented in docs/jellyfin/02-jellyfin-api-mapping.md and
/// 03-prior-art.md, not only that decoding did not throw.
@Suite("Jellyfin DTO decoding")
struct JellyfinDTODecodingTests {
    typealias Items = JellyfinQueryResult<JellyfinItemDTO>

    /// The signed-in user of the recording, for request validators.
    private func context() throws -> JellyfinRequestContext {
        let auth = try JellyfinFixtures.decode(JellyfinAuthenticationResultDTO.self, "authenticate-by-name")
        return JellyfinRequestContext(userID: auth.user.id)
    }

    // MARK: Every fixture

    /// Which DTO each recorded response decodes into. A new fixture without an
    /// entry fails the test, so nothing recorded goes unchecked.
    private func decoder(for name: String) -> ((Data) throws -> Void)? {
        func decode<T: Decodable>(_ type: T.Type) -> (Data) throws -> Void {
            { _ = try JellyfinJSON.decode(type, from: $0) }
        }
        switch name {
        case "system-info-public": return decode(JellyfinPublicSystemInfoDTO.self)
        case "system-endpoint": return decode(JellyfinEndpointInfoDTO.self)
        case "quickconnect-enabled": return decode(Bool.self)
        case "quickconnect-initiate": return decode(JellyfinQuickConnectResultDTO.self)
        case "authenticate-by-name": return decode(JellyfinAuthenticationResultDTO.self)
        case "users-me": return decode(JellyfinUserDTO.self)
        case "users-public": return decode([JellyfinUserDTO].self)
        case "items-filters": return decode(JellyfinItemFiltersDTO.self)
        case "items-counts": return decode(JellyfinItemCountsDTO.self)
        case "item-images-knives-out": return decode([JellyfinImageInfoDTO].self)
        case "search-hints": return decode(JellyfinSearchHintResultDTO.self)
        case "user-data-knives-out": return decode(JellyfinUserDataDTO.self)
        case "sessions": return decode([JellyfinSessionInfoDTO].self)
        case "playlist-create": return decode(JellyfinPlaylistCreationResultDTO.self)
        case "playlist": return decode(JellyfinPlaylistDTO.self)
        case "livetv-info": return decode(JellyfinLiveTVInfoDTO.self)
        case "livetv-guide-info": return decode(JellyfinGuideInfoDTO.self)
        case _ where name.hasPrefix("media-segments-"): return decode(JellyfinQueryResult<JellyfinMediaSegmentDTO>.self)
        case _ where name.hasPrefix("playback-info-"): return decode(JellyfinPlaybackInfoResponseDTO.self)
        case _ where name.hasPrefix("latest-"), _ where name.hasPrefix("special-features-"),
             _ where name.hasPrefix("local-trailers-"), _ where name.hasPrefix("ancestors-"):
            return decode([JellyfinItemDTO].self)
        case _ where name.hasPrefix("item-"): return decode(JellyfinItemDTO.self)
        case "user-views", "resume", "next-up", "suggestions", "genres", "playlist-items", "livetv-channels",
             _ where name.hasPrefix("items-"), _ where name.hasPrefix("next-up-"), _ where name.hasPrefix("shows-"),
             _ where name.hasPrefix("similar-"), _ where name.hasPrefix("intros-"):
            return decode(Items.self)
        default: return nil
        }
    }

    @Test func everyRecordedResponseDecodes() throws {
        let names = try JellyfinFixtures.allNames()
        #expect(names.count >= 70)
        for name in names {
            let decode = try #require(decoder(for: name), "no DTO mapped for fixture \(name)")
            #expect(throws: Never.self, "\(name)") { try decode(JellyfinFixtures.data(name)) }
        }
    }

    @Test func fixturesCarryNoCredentials() throws {
        for name in try JellyfinFixtures.allNames() {
            let text = String(decoding: try JellyfinFixtures.data(name), as: UTF8.self)
            for match in text.matches(of: /(?i)api_?key=([^&"\s]*)/) {
                #expect(match.output.1 == "REDACTED_TOKEN", "\(name) carries an ApiKey")
            }
            for match in text.matches(of: /"AccessToken"\s*:\s*"([^"]*)"/) {
                #expect(match.output.1 == "REDACTED_TOKEN", "\(name) carries an AccessToken")
            }
        }
    }

    /// The detail validator (same id, `UserData` present) holds for every
    /// kind recorded: movies, episode, season, series, person.
    @Test func everyDetailPassesTheItemValidator() throws {
        let context = try context()
        let names = try JellyfinFixtures.allNames().filter { $0.hasPrefix("item-") && $0 != "item-images-knives-out" }
        #expect(names.count >= 29)
        for name in names {
            let raw = try JellyfinFixtures.decode(JellyfinItemDTO.self, name)
            #expect(throws: Never.self, "\(name)") {
                _ = try JellyfinAPI.item(id: raw.id).decode(JellyfinFixtures.data(name), context)
            }
        }
    }

    // MARK: The 12 torture files (03 §5.1)

    struct Torture: Sendable, CustomTestStringConvertible {
        let fixture: String
        let container: String
        let videoCodec: String
        let range: JellyfinVideoRangeType
        let dvProfile: Int?
        let codecTag: String?
        let firstAudio: String?
        let spatial: JellyfinAudioSpatialFormat?
        let runTimeTicks: Int64
        var testDescription: String { fixture }
    }

    static let torture: [Torture] = [
        Torture(fixture: "item-big-buck-bunny", container: "mp4", videoCodec: "h264", range: .sdr, dvProfile: nil,
                codecTag: "avc1", firstAudio: "aac", spatial: JellyfinAudioSpatialFormat.none, runTimeTicks: 5_964_800_000),
        Torture(fixture: "item-dv-p5-jellyfin-4k-test-2024", container: "mp4", videoCodec: "hevc", range: .dovi, dvProfile: 5,
                codecTag: "dvh1", firstAudio: nil, spatial: nil, runTimeTicks: 299_500_000),
        Torture(fixture: "item-dv-p8-1-lake-dynamic-changes-2020", container: "mp4", videoCodec: "hevc", range: .doviWithHDR10,
                dvProfile: 8, codecTag: "dvhe", firstAudio: nil, spatial: nil, runTimeTicks: 1_101_100_000),
        Torture(fixture: "item-dv-p8-4-hlg-jellyfin-4k-test-2024", container: "mp4", videoCodec: "hevc", range: .doviWithHLG,
                dvProfile: 8, codecTag: "hvc1", firstAudio: nil, spatial: nil, runTimeTicks: 299_500_000),
        Torture(fixture: "item-knives-out", container: "mkv", videoCodec: "hevc", range: .doviWithHDR10, dvProfile: 8,
                codecTag: nil, firstAudio: "eac3", spatial: .dolbyAtmos, runTimeTicks: 78_172_470_000),
        Torture(fixture: "item-eac3-atmos-joc-hdr10", container: "mkv", videoCodec: "hevc", range: .hdr10, dvProfile: nil,
                codecTag: nil, firstAudio: "eac3", spatial: .dolbyAtmos, runTimeTicks: 486_310_000),
        Torture(fixture: "item-hdr10-profile-b-eac3-5-1-2020", container: "mkv", videoCodec: "hevc", range: .hdr10Plus,
                dvProfile: nil, codecTag: nil, firstAudio: "eac3", spatial: JellyfinAudioSpatialFormat.none, runTimeTicks: 500_720_000),
        Torture(fixture: "item-paddington-2", container: "mkv", videoCodec: "hevc", range: .sdr, dvProfile: nil,
                codecTag: nil, firstAudio: "ac3", spatial: JellyfinAudioSpatialFormat.none, runTimeTicks: 61_989_120_000),
        Torture(fixture: "item-dts-hd-ma-dts-x-gravity-demo-2020", container: "mkv", videoCodec: "h264", range: .sdr,
                dvProfile: nil, codecTag: nil, firstAudio: "dts", spatial: .dtsX, runTimeTicks: 868_060_000),
        Torture(fixture: "item-truehd-7-1-channel-check-2020", container: "ts", videoCodec: "h264", range: .sdr,
                dvProfile: nil, codecTag: "HDMV", firstAudio: "truehd", spatial: JellyfinAudioSpatialFormat.none, runTimeTicks: 944_960_000),
        Torture(fixture: "item-dune-part-two", container: "mkv", videoCodec: "hevc", range: .doviWithEL, dvProfile: 7,
                codecTag: nil, firstAudio: "truehd", spatial: .dolbyAtmos, runTimeTicks: 100_152_240_000),
        Torture(fixture: "item-av1-hdr10-test-2026", container: "mkv", videoCodec: "av1", range: .hdr10, dvProfile: nil,
                codecTag: nil, firstAudio: "eac3", spatial: JellyfinAudioSpatialFormat.none, runTimeTicks: 120_000_000),
    ]

    @Test(arguments: torture)
    func tortureFile(_ expected: Torture) throws {
        let item = try JellyfinFixtures.decode(JellyfinItemDTO.self, expected.fixture)
        #expect(item.type == .movie)
        #expect(item.runTimeTicks?.rawValue == expected.runTimeTicks)
        #expect(item.runTimeTicks?.milliseconds == Int((Double(expected.runTimeTicks) / 10_000).rounded()))
        #expect(item.userData != nil)
        #expect(item.id.count == 32)

        let source = try #require(item.mediaSources?.first)
        #expect(JellyfinID.same(source.id, item.id), "primary version id equals the item id")
        #expect(source.container == expected.container)
        #expect(source.protocol == .file)
        #expect((source.size ?? 0) > 0)
        #expect((source.bitrate ?? 0) > 100_000, "bits per second, not kbit/s")
        #expect(source.runTimeTicks == item.runTimeTicks)

        let video = try #require(source.streams.first { $0.type == .video })
        #expect(video.codec == expected.videoCodec)
        #expect(video.videoRangeType == expected.range)
        #expect(video.dvProfile == expected.dvProfile)
        #expect(video.codecTag == expected.codecTag)
        #expect((video.width ?? 0) > 0 && (video.height ?? 0) > 0)

        let audio = source.streams.first { $0.type == .audio }
        #expect(audio?.codec == expected.firstAudio)
        #expect(audio?.audioSpatialFormat == expected.spatial)
        if let audio {
            #expect(source.defaultAudioStreamIndex.map { index in source.streams.contains { $0.index == index } } ?? true)
            #expect((audio.channels ?? 0) > 0)
        }
        // Indexes are unique positions inside the source.
        #expect(Set(source.streams.map(\.index)).count == source.streams.count)
    }

    // MARK: Documented values

    @Test func knivesOutDetail() throws {
        let item = try JellyfinFixtures.decode(JellyfinItemDTO.self, "item-knives-out")
        #expect(item.id == "980dffd6dfa0d8cfd69e5bd6b350e983")
        #expect(item.name == "Knives Out")
        #expect(item.runTimeTicks?.rawValue == 78_172_470_000)
        #expect(item.runTimeTicks?.milliseconds == 7_817_247)
        #expect(abs((item.runTimeTicks?.seconds ?? 0) - 7_817.247) < 0.001)
        #expect(item.productionYear == 2019)
        #expect(item.premiereDate?.date == date(2019, 11, 27))
        #expect(item.officialRating == "CH-12")
        #expect(item.communityRating == 7.843)
        #expect(item.criticRating == nil)
        #expect(item.providerID("imdb") == "tt8946378")
        #expect(item.providerID("Tmdb") == "546554")
        #expect(item.providerID("TmdbCollection") == "722971")
        #expect(item.providerID("Tvdb") == nil)
        #expect(item.people?.count == 19)
        #expect(item.people?.contains { $0.type == .director } == true)
        #expect(item.people?.first?.type == .actor)
        #expect(item.chapters?.count == 16)
        #expect(item.chapters?.first?.startPositionTicks.rawValue == 0)
        #expect(item.imageTag(.primary) != nil)
        #expect(item.imageTag(.logo) != nil)
        #expect(item.imageTag(.banner) == nil)
        #expect(item.backdropImageTags?.isEmpty == false)
        #expect(item.taglines?.isEmpty == false)
        #expect(item.studios?.isEmpty == false)

        // Absent beats null: an unplayed item has no PlayedPercentage key.
        let userData = try #require(item.userData)
        #expect(userData.played == false)
        #expect(userData.playedPercentage == nil)
        #expect(userData.lastPlayedDate == nil)
        #expect(userData.playbackPositionTicks?.rawValue == 0)

        // Trickplay[mediaSourceId]["320"]; Interval is milliseconds.
        let trickplay = try #require(item.trickplay?[item.id]?["320"])
        #expect(trickplay.width == 320)
        #expect(trickplay.tileWidth == 10 && trickplay.tileHeight == 10)
        #expect(trickplay.thumbnailCount == 782)
        #expect(trickplay.interval == 10_000)

        let source = try #require(item.mediaSources?.first)
        #expect(source.defaultSubtitleStreamIndex == 4, "the user-resolved default is a PGS track")
        #expect(source.defaultAudioStreamIndex == 1)
        let subtitles = source.streams.filter { $0.type == .subtitle }
        #expect(subtitles.count == 32)
        #expect(subtitles.filter { $0.isDefault == true }.count > 1, "IsDefault is not 'the one default'")
        #expect(subtitles.first { $0.index == 4 }?.codec == "PGSSUB")
        #expect(subtitles.contains { $0.codec == "subrip" && $0.isTextSubtitleStream == true })
        let atmos = try #require(source.streams.first { $0.index == 1 })
        #expect(atmos.type == .audio && atmos.codec == "eac3" && atmos.channels == 6)
        #expect(atmos.profile?.contains("Atmos") == true)
        let video = try #require(source.streams.first { $0.type == .video })
        #expect(video.videoRange == .hdr)
        #expect(video.colorTransfer == "smpte2084")
        #expect(video.bitDepth == 10)
        #expect(video.dvBlSignalCompatibilityID == 1)
    }

    /// An external subtitle takes `Index` 0 and shifts everything (02 §9).
    @Test func externalSubtitleTakesIndexZero() throws {
        let item = try JellyfinFixtures.decode(JellyfinItemDTO.self, "item-av1-sdr-test-2026")
        let streams = try #require(item.mediaSources?.first?.streams)
        let first = try #require(streams.first { $0.index == 0 })
        #expect(first.type == .subtitle)
        #expect(first.isExternal == true)
        #expect(first.codec == "subrip")
        #expect(streams.first { $0.index == 1 }?.type == .video)
        #expect(streams.filter { $0.type == .audio }.map(\.index) == [2, 3])
        #expect(item.mediaSources?.first?.defaultSubtitleStreamIndex == 0)
    }

    @Test func duneDolbyVision7() throws {
        let item = try JellyfinFixtures.decode(JellyfinItemDTO.self, "item-dune-part-two")
        let source = try #require(item.mediaSources?.first)
        let video = try #require(source.streams.first { $0.type == .video })
        #expect(video.videoRangeType == .doviWithEL)
        #expect(video.dvProfile == 7)
        #expect(video.elPresentFlag == 1)
        let audio = source.streams.filter { $0.type == .audio }
        #expect(audio.map(\.codec) == ["truehd", "ac3", "ac3"])
        #expect(audio.first?.audioSpatialFormat == .dolbyAtmos)
        #expect(source.defaultAudioStreamIndex == 3)
    }

    @Test func officeEpisodeAndSegments() throws {
        let episode = try JellyfinFixtures.decode(JellyfinItemDTO.self, "item-the-office-s01e01")
        #expect(episode.type == .episode)
        #expect(episode.name == "Pilot")
        #expect(episode.indexNumber == 1 && episode.parentIndexNumber == 1)
        #expect(episode.seriesName == "The Office")
        #expect(episode.seriesID != nil && episode.seasonID != nil)
        #expect(episode.seriesPrimaryImageTag != nil)
        #expect(episode.runTimeTicks?.milliseconds == 1_405_162)
        #expect(episode.providerID("Tvdb") == "110413")
        // Local midnight stored as UTC: one hour before 2005-03-24 UTC.
        #expect(episode.premiereDate?.raw == "2005-03-23T23:00:00.0000000Z")
        #expect(episode.premiereDate?.date == date(2005, 3, 24).addingTimeInterval(-3600))

        let segments = try JellyfinFixtures.decode(JellyfinQueryResult<JellyfinMediaSegmentDTO>.self,
                                                   "media-segments-the-office-s01e01")
        #expect(segments.totalRecordCount == 2)
        let intro = try #require(segments.items.first { $0.type == .intro })
        #expect(intro.startTicks.milliseconds == 0)
        #expect(intro.endTicks.milliseconds == 54_555)
        let outro = try #require(segments.items.first { $0.type == .outro })
        #expect(outro.startTicks.milliseconds == 1_372_746)
        #expect(outro.endTicks == episode.runTimeTicks, "credits run to the very end")
        #expect(segments.items.allSatisfy { JellyfinID.same($0.itemID ?? "", episode.id) })
    }

    @Test func seriesSeasonsAndEpisodes() throws {
        let series = try JellyfinFixtures.decode(JellyfinItemDTO.self, "item-series-the-office")
        #expect(series.type == .series)
        #expect(series.childCount == 9)
        #expect(series.recursiveItemCount == 186)
        #expect(series.userData?.unplayedItemCount == 186)
        #expect(series.providerID("Tvdb") != nil)

        let context = try context()
        let seasons = try JellyfinAPI.seasons(seriesID: series.id)
            .decode(JellyfinFixtures.data("shows-seasons-the-office"), context)
        #expect(seasons.items.count == 9)
        #expect(seasons.items.compactMap(\.indexNumber) == Array(1...9))

        let seasonOne = try #require(seasons.items.first { $0.indexNumber == 1 })
        let episodes = try JellyfinAPI.episodes(seriesID: series.id, seasonID: seasonOne.id)
            .decode(JellyfinFixtures.data("shows-episodes-the-office-s01"), context)
        #expect(episodes.items.count == 6)
        #expect(episodes.items.compactMap(\.indexNumber) == Array(1...6))
        #expect(episodes.items.allSatisfy { $0.mediaSources?.isEmpty == false })
    }

    @Test func resumeRow() throws {
        let resume = try JellyfinAPI.resume(limit: 10).decode(JellyfinFixtures.data("resume"), context())
        let positions = Dictionary(uniqueKeysWithValues: resume.items.map {
            ($0.name ?? "", $0.userData?.playbackPositionTicks?.milliseconds ?? 0)
        })
        #expect(positions["Paddington 2"] == 309_469)
        #expect(positions["Dune: Part Two"] == 607_000)
        #expect(resume.items.allSatisfy { $0.userData?.lastPlayedDate?.date != nil })
        #expect(resume.items.allSatisfy { ($0.userData?.playedPercentage ?? 0) > 0 })
    }

    @Test func latestTVMixesContainers() throws {
        let latest = try JellyfinFixtures.decode([JellyfinItemDTO].self, "latest-tv")
        #expect(Set(latest.compactMap(\.type)) == [.episode, .season, .series])
    }

    @Test func libraryViewsAndPhotoAlbums() throws {
        let context = try context()
        let views = try JellyfinAPI.userViews().decode(JellyfinFixtures.data("user-views"), context)
        #expect(views.items.allSatisfy { $0.type == .collectionFolder })
        #expect(views.items.filter { $0.collectionType == .homeVideos }.count == 2, "Photos and Videos share homevideos")
        #expect(views.items.contains { $0.collectionType == .movies })
        #expect(views.items.contains { $0.collectionType == .tvShows })

        let albums = try JellyfinFixtures.decode(Items.self, "items-photo-albums")
        #expect(albums.items.count == 6)
        #expect(albums.items.first { $0.name == "2026" }?.type == .folder)
        #expect(albums.items.first { $0.name == "2026" }?.recursiveItemCount == 60)

        let timeline = try JellyfinFixtures.decode(Items.self, "items-photo-timeline")
        #expect(timeline.items.allSatisfy { $0.type == .photo || $0.type == .video })
        #expect(timeline.items.contains { $0.mediaType == .photo })
    }

    @Test func browseCountsAndFilters() throws {
        let context = try context()
        var query = JellyfinItemQuery()
        query.includeItemTypes = [.movie]
        query.limit = 10
        let browse = try JellyfinAPI.items(query).decode(JellyfinFixtures.data("items-movies-browse"), context)
        #expect(browse.totalRecordCount == 3)
        #expect(browse.items.map(\.name) == ["Dune: Part Two", "Knives Out", "Paddington 2"])
        #expect(browse.items.allSatisfy { $0.dateCreated?.date != nil })

        query.limit = 0
        let count = try JellyfinAPI.items(query).decode(JellyfinFixtures.data("items-count-only"), context)
        #expect(count.items.isEmpty)
        #expect(count.totalRecordCount == 3)

        let filters = try JellyfinFixtures.decode(JellyfinItemFiltersDTO.self, "items-filters")
        #expect(filters.years == [2017, 2019, 2024])
        #expect(filters.officialRatings?.contains("CH-12") == true)

        let counts = try JellyfinFixtures.decode(JellyfinItemCountsDTO.self, "items-counts")
        #expect(counts.seriesCount == 4)
        #expect((counts.movieCount ?? 0) >= 25)
    }

    @Test func searchHints() throws {
        let hints = try JellyfinAPI.searchHints(term: "office", limit: 10)
            .decode(JellyfinFixtures.data("search-hints"), context())
        #expect(hints.searchHints.contains { $0.type == .series && $0.name == "The Office" })
        #expect(hints.searchHints.contains { $0.type == .episode && $0.series == "The Office" })
    }

    @Test func signInUsersAndQuickConnect() throws {
        let auth = try JellyfinFixtures.decode(JellyfinAuthenticationResultDTO.self, "authenticate-by-name")
        #expect(auth.accessToken == "REDACTED_TOKEN")
        #expect(auth.user.name == "duskcompare")
        #expect(auth.serverID == "feedfacefeedfacefeedfacefeedface", "scrubbed by the recorder")
        #expect(auth.sessionInfo?.deviceID == "dusk-fixture-recorder")
        let policy = try #require(auth.user.policy)
        #expect(policy.isAdministrator == false)
        #expect(policy.enableSubtitleManagement == false)
        #expect(policy.enableCollectionManagement == false)
        #expect(policy.enableContentDownloading == true)
        #expect(policy.remoteClientBitrateLimit == 0)
        let configuration = try #require(auth.user.configuration)
        #expect(configuration.subtitleMode == .default)
        #expect(configuration.audioLanguagePreference == nil, "absent when unset")
        #expect(configuration.orderedViews == [])

        let me = try JellyfinAPI.currentUser().decode(JellyfinFixtures.data("users-me"),
                                                      JellyfinRequestContext(userID: auth.user.id))
        #expect(me.id == auth.user.id)

        #expect(try JellyfinFixtures.decode([JellyfinUserDTO].self, "users-public").isEmpty)
        #expect(try JellyfinFixtures.decode(Bool.self, "quickconnect-enabled"))
        let initiate = try JellyfinAPI.quickConnectInitiate()
            .decode(JellyfinFixtures.data("quickconnect-initiate"), JellyfinRequestContext(userID: nil))
        #expect(initiate.authenticated == false)
        #expect(initiate.code == "000000")
        #expect(initiate.appName == "Dusk")

        let info = try JellyfinFixtures.decode(JellyfinPublicSystemInfoDTO.self, "system-info-public")
        #expect(info.id == auth.serverID)
        #expect(info.productName == "Jellyfin Server")
        #expect(info.version == "12.4.0")
        let endpoint = try JellyfinFixtures.decode(JellyfinEndpointInfoDTO.self, "system-endpoint")
        #expect(endpoint.isInNetwork == true)
    }

    @Test func playbackDecisions() throws {
        let client = JellyfinClient(
            baseURL: URL(string: "http://jellyfin.example:8096/jf")!,
            identity: JellyfinClientIdentity(device: "Test", deviceID: "test", version: "1"),
            credentials: JellyfinCredentials(accessToken: "secret", userID: "user"))

        let remux = try JellyfinFixtures.decode(JellyfinPlaybackInfoResponseDTO.self, "playback-info-knives-out-avplayer")
        #expect(remux.playSessionID == "REDACTED_PLAY_SESSION")
        let remuxSource = try #require(remux.mediaSources.first)
        #expect(remuxSource.supportsDirectPlay == false)
        #expect(remuxSource.supportsTranscoding == true)
        #expect(remuxSource.directStreamURL == nil, "not populated on 12.4")
        #expect(remuxSource.transcodingSubProtocol == "hls")
        #expect(remuxSource.transcodeReasons == [.containerNotSupported])
        let transcodingURL = try #require(remuxSource.transcodingURL)
        #expect(transcodingURL.hasPrefix("/videos/980dffd6-dfa0-d8cf-d69e-5bd6b350e983/master.m3u8?"), "dashed id in paths")
        let resolved = try client.resolveServerURL(transcodingURL)
        #expect(resolved.absoluteString.hasPrefix("http://jellyfin.example:8096/jf/videos/980dffd6-dfa0-d8cf-d69e-5bd6b350e983/master.m3u8?"))
        #expect(resolved.query?.contains("ApiKey=REDACTED_TOKEN") == true)

        let vlc = try JellyfinFixtures.decode(JellyfinPlaybackInfoResponseDTO.self, "playback-info-knives-out-vlc")
        #expect(vlc.mediaSources.first?.supportsDirectPlay == true)
        #expect(vlc.mediaSources.first?.supportsTranscoding == false)
        #expect(vlc.mediaSources.first?.transcodingURL == nil)

        let dts = try JellyfinFixtures.decode(JellyfinPlaybackInfoResponseDTO.self, "playback-info-paddington-avplayer-dts")
        #expect(dts.mediaSources.first?.transcodeReasons.contains(.audioCodecNotSupported) == true)

        let sidecar = try JellyfinFixtures.decode(JellyfinPlaybackInfoResponseDTO.self, "playback-info-av1-sdr-vlc")
        let external = try #require(sidecar.mediaSources.first?.streams.first { $0.index == 0 })
        #expect(external.deliveryMethod == .external)
        let deliveryURL = try #require(external.deliveryURL)
        #expect(deliveryURL.hasPrefix("/Videos/393119b9-80a6-b414-852a-2a572ceb7467/393119b980a6b414852a2a572ceb7467/Subtitles/0/0/Stream.srt"))
        #expect(try client.resolveServerURL(deliveryURL).path
            == "/jf/Videos/393119b9-80a6-b414-852a-2a572ceb7467/393119b980a6b414852a2a572ceb7467/Subtitles/0/0/Stream.srt")
    }

    @Test func playlistsAndLiveTV() throws {
        let context = try context()
        let entries = try JellyfinAPI.playlistItems(id: "playlist").decode(JellyfinFixtures.data("playlist-items"), context)
        #expect(entries.items.map(\.name) == ["Knives Out", "Paddington 2"])
        #expect(entries.items.allSatisfy { $0.playlistItemID != nil })
        let playlist = try JellyfinFixtures.decode(JellyfinPlaylistDTO.self, "playlist")
        #expect(playlist.itemIDs.count == 2)
        #expect(playlist.openAccess == false)

        let info = try JellyfinFixtures.decode(JellyfinLiveTVInfoDTO.self, "livetv-info")
        #expect(info.isEnabled == true)
        let guide = try JellyfinFixtures.decode(JellyfinGuideInfoDTO.self, "livetv-guide-info")
        // Six fraction digits here, seven elsewhere.
        let start = try #require(guide.startDate?.date)
        let end = try #require(guide.endDate?.date)
        #expect(abs(end.timeIntervalSince(start) - 7 * 86_400) < 1)
    }

    @Test func personDetail() throws {
        let person = try JellyfinFixtures.decode(JellyfinItemDTO.self, "item-person")
        #expect(person.type == .person)
        #expect(person.name == "Daniel Craig")
        #expect(person.productionLocations == ["Chester, Cheshire, England, UK"])
        #expect(person.premiereDate?.date == date(1968, 3, 2).addingTimeInterval(-3600))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
