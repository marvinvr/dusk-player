import Foundation
import Testing
@testable import Dusk

/// G5 (05-plan §3): identifiers that are already on users' devices, in other
/// processes or on other devices. Every expected value is a literal captured
/// from the pre-refactor build (SHA-256 values were computed independently on
/// the host with `printf %s '<input>' | shasum -a 256`), never something the
/// code under test computed. A refactor that changes one of these strings
/// orphans downloads, remembered tracks, pins, sign-ins or shortcuts.
///
/// Where a key is private, the store is driven against a scratch
/// `UserDefaults` suite (or the Keychain, restored afterwards) and the literal
/// key is looked up in what it wrote.
@Suite("Persisted golden strings", .serialized)
@MainActor
struct PersistedGoldenStringTests {
    private let owner = "4f2a9c1d7e3b5a60"
    private let serverA = "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9"

    // MARK: - Item identity

    @Test func itemStorageKeyForms() {
        #expect(MediaItemID(serverID: "srv-a", itemID: "1001").storageKey == "srv-a|1001")
        #expect(MediaItemID(serverID: nil, itemID: "1001").storageKey == "1001")
        #expect(MediaItemID(serverID: "", itemID: "1001").storageKey == "1001")
        #expect(MediaItemID(serverID: "srv-a", itemID: "1001").description == "srv-a|1001")
    }

    @Test func itemStorageKeyParsing() {
        #expect(MediaItemID(storageKey: "srv-a|1001") == MediaItemID(serverID: "srv-a", itemID: "1001"))
        // Legacy form without a server: the whole string is the rating key.
        let legacy = MediaItemID(storageKey: "1001")
        #expect(legacy?.serverID == nil)
        #expect(legacy?.itemID == "1001")
        #expect(MediaItemID(storageKey: "") == nil)
        #expect(MediaItemID(storageKey: "srv-a|") == nil)
        let emptyServer = MediaItemID(storageKey: "|123")
        #expect(emptyServer?.serverID == nil)
        #expect(emptyServer?.itemID == "123")
        // Only the first "|" separates.
        let nested = MediaItemID(storageKey: "a|b|c")
        #expect(nested?.serverID == "a")
        #expect(nested?.itemID == "b|c")
    }

    @Test func itemIDJSONForm() throws {
        let full = try JSONEncoder().encode(MediaItemID(serverID: "srv-a", itemID: "1001"))
        try LegacyFixture.expectSameJSON(full, Data(#"{"serverID":"srv-a","ratingKey":"1001"}"#.utf8))
        let unscoped = try JSONEncoder().encode(MediaItemID(serverID: nil, itemID: "1001"))
        try LegacyFixture.expectSameJSON(unscoped, Data(#"{"ratingKey":"1001"}"#.utf8))
    }

    // MARK: - Download keys

    @Test func downloadGlobalKeyForms() {
        #expect(DownloadedMediaRecord.globalKey(accountProfileID: "4f2a9c1d7e3b5a60", serverID: "srv-a", itemID: "1001")
            == "4f2a9c1d7e3b5a60:srv-a:1001")
        #expect(DownloadedMediaRecord.globalKey(accountProfileID: nil, serverID: "srv-a", itemID: "1001") == "srv-a:1001")
        #expect(DownloadedMediaRecord.globalKey(accountProfileID: "", serverID: "srv-a", itemID: "1001") == "srv-a:1001")
        #expect(DownloadedMediaRecord.globalKey(serverID: "srv-a", itemID: "1001") == "srv-a:1001")
        let summary = DownloadedShowSummary(
            serverID: "srv-a", itemID: "2000", title: "Show", thumbPath: nil, artPath: nil,
            downloadedEpisodeCount: 1, totalEpisodeCount: nil
        )
        #expect(summary.id == "srv-a:2000")
    }

    @Test func downloadFileLayout() throws {
        try LegacyFixture.withTemporaryRoot { root in
            let store = DownloadFileStore(rootDirectory: root)
            #expect(store.stateFileURL.lastPathComponent == "downloads.json")
            #expect(store.playbackSyncStateFileURL.lastPathComponent == "playback-sync.json")
            #expect(store.relativePath(for: store.metadataDirectory) == "Metadata")
            #expect(store.relativePath(for: store.artworkDirectory) == "Artwork")
            #expect(store.relativePath(for: store.resumeDataDirectory) == "ResumeData")
            #expect(store.relativePath(for: store.subtitlesDirectory) == "Subtitles")
        }
        let defaultRoot = DownloadFileStore().rootDirectory.path
        #expect(defaultRoot.hasSuffix("/Library/Application Support/Dusk/Downloads"))
    }

    /// The metadata cache file name is SHA-256 of the PMS endpoint, under
    /// `Metadata/Profiles/<profile>/<server>/` (or `Metadata/<server>/` for a
    /// pre-Plex-Home install).
    @Test func metadataCacheFileNames() throws {
        #expect(PlexMetadataCache.metadataEndpoint("1001") == "/library/metadata/1001")
        #expect(PlexMetadataCache.childrenEndpoint("2010") == "/library/metadata/2010/children")
        #expect(DownloadFileStore.hash("/library/metadata/1001")
            == "763c91a41ab63b9ef1c896ef1ba98e74bfa00f41e8b707861698dbddb117df34")
        #expect(DownloadFileStore.hash("/library/metadata/2010/children")
            == "b484084a00b1917dc534fbcdfc156b65b7a3256f71dd8c3e9bd61db291688b24")

        try LegacyFixture.withTemporaryRoot { root in
            let store = DownloadFileStore(rootDirectory: root)
            let profiled = store.metadataURL(accountProfileID: owner, serverID: serverA, endpoint: "/library/metadata/1001")
            #expect(store.relativePath(for: profiled)
                == "Metadata/Profiles/4f2a9c1d7e3b5a60/a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9/763c91a41ab63b9ef1c896ef1ba98e74bfa00f41e8b707861698dbddb117df34.json")
            let legacy = store.metadataURL(accountProfileID: nil, serverID: serverA, endpoint: "/library/metadata/2010/children")
            #expect(store.relativePath(for: legacy)
                == "Metadata/a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9/b484084a00b1917dc534fbcdfc156b65b7a3256f71dd8c3e9bd61db291688b24.json")
            // A legacy server id that was a base URL becomes one safe component.
            let baseURLServer = store.metadataURL(
                accountProfileID: "plex-home-24601", serverID: "http://192.168.1.10:32400", endpoint: "/library/metadata/1001"
            )
            #expect(store.relativePath(for: baseURLServer)
                == "Metadata/Profiles/plex-home-24601/http_192.168.1.10_32400/763c91a41ab63b9ef1c896ef1ba98e74bfa00f41e8b707861698dbddb117df34.json")
        }
    }

    @Test func metadataCacheReadsAPayloadAtItsLiteralPath() throws {
        let payload = try LegacyFixture.data("LegacyContainer-real-metadata-a3d2fd1255dd.json")
        try LegacyFixture.withTemporaryRoot { root in
            try LegacyFixture.place(
                payload,
                at: "Metadata/Profiles/4f2a9c1d7e3b5a60/a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9/a3d2fd1255dd164fe3a146fd6cabed9c4f5c911cf83d7a41d5f4b157240d2011.json",
                under: root
            )
            let cache = PlexMetadataCache(fileStore: DownloadFileStore(rootDirectory: root))
            let details = try #require(cache.mediaDetails(accountProfileID: owner, serverID: serverA, itemID: "1004"))
            #expect(details.title == "Winter Stone")
            #expect(details.serverID == serverA)
        }
    }

    @Test func legacyMetadataIsAdoptedIntoTheProfile() throws {
        let payload = try LegacyFixture.data("LegacyContainer-real-metadata-a3d2fd1255dd.json")
        try LegacyFixture.withTemporaryRoot { root in
            try LegacyFixture.place(
                payload,
                at: "Metadata/a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9/a3d2fd1255dd164fe3a146fd6cabed9c4f5c911cf83d7a41d5f4b157240d2011.json",
                under: root
            )
            let store = DownloadFileStore(rootDirectory: root)
            store.adoptLegacyMetadata(accountProfileID: owner, serverIDs: [serverA])
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(
                "Metadata/Profiles/4f2a9c1d7e3b5a60/a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9/a3d2fd1255dd164fe3a146fd6cabed9c4f5c911cf83d7a41d5f4b157240d2011.json"
            ).path))
            let cache = PlexMetadataCache(fileStore: store)
            #expect(cache.mediaDetails(accountProfileID: owner, serverID: serverA, itemID: "1004")?.title == "Winter Stone")
        }
    }

    @Test func artworkSubtitleAndResumeFileNames() throws {
        try LegacyFixture.withTemporaryRoot { root in
            let store = DownloadFileStore(rootDirectory: root)
            let artwork = try #require(store.artworkURL(for: "/library/metadata/1001/thumb/1700000000"))
            #expect(store.relativePath(for: artwork)
                == "Artwork/f87537f5d635c1b7c55cd86fc3d8f8e97549c7b0ff70df4786db219e71d5c117.jpg")
            #expect(store.artworkURL(for: nil) == nil)
            #expect(store.artworkURL(for: "") == nil)

            let globalKey = "4f2a9c1d7e3b5a60:a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9:1001"
            let subtitle = try store.saveSubtitle(Data("1\n".utf8), globalKey: globalKey, streamID: "7001", fileExtension: "srt")
            #expect(subtitle == "Subtitles/547b0036d8c6f5d72c77415432032b11b28aafbec6a6d376d3c0de83e1d2a29e/7001.srt")
            let resume = try store.saveResumeData(Data("resume".utf8), globalKey: globalKey)
            #expect(resume == "ResumeData/547b0036d8c6f5d72c77415432032b11b28aafbec6a6d376d3c0de83e1d2a29e.resume")
            let legacyResume = try store.saveResumeData(
                Data("resume".utf8), globalKey: "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9:1001"
            )
            #expect(legacyResume == "ResumeData/5302b6c696103e6fa88b109e616dad86867a1add4b82fcd503a287b861a7d21a.resume")
        }
    }

    @Test func videoFilePaths() throws {
        let movie = try JSONDecoder().decode(MediaDetails.self, from: Data(#"""
            {"ratingKey":"1001","key":"/library/metadata/1001","type":"movie","title":"Arrival: Director's Cut?","year":2016,
             "Media":[{"id":501,"container":"mkv","Part":[{"id":601,"key":"/library/parts/601/file.mkv","file":"/data/Arrival.MKV"}]}]}
            """#.utf8))
        let episode = try JSONDecoder().decode(MediaDetails.self, from: Data(#"""
            {"ratingKey":"2011","key":"/library/metadata/2011","type":"episode","title":"Pilot","parentIndex":1,"index":2,
             "grandparentTitle":"Severance",
             "Media":[{"id":81,"container":"mp4","Part":[{"id":82,"key":"/library/parts/82/file.mp4"}]}]}
            """#.utf8))
        try LegacyFixture.withTemporaryRoot { root in
            let store = DownloadFileStore(rootDirectory: root)
            let movieURL = try store.targetVideoURL(accountProfileID: owner, for: movie, part: movie.media[0].parts[0])
            #expect(store.relativePath(for: movieURL)
                == "Profiles/4f2a9c1d7e3b5a60/Movies/Arrival Director's Cut (2016)/Arrival Director's Cut (2016).mkv")
            let episodeURL = try store.targetVideoURL(accountProfileID: "plex-home-24601", for: episode, part: episode.media[0].parts[0])
            #expect(store.relativePath(for: episodeURL)
                == "Profiles/plex-home-24601/TV Shows/Severance/Season 01/S01E02 - Pilot.mp4")
        }
    }

    // MARK: - Per-profile preference keys

    @Test func showTrackPreferencesKey() throws {
        let details = try JSONDecoder().decode(MediaDetails.self, from: Data(LegacyValues.trackEpisodeJSON.utf8))
        let scope = try #require(ShowTrackPreferenceStore.Scope(profileID: owner, serverID: serverA, details: details))
        #expect(scope.storageKey
            == "ShowTrackPreferences.v1.16:4f2a9c1d7e3b5a6040:a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e94:2000")
        // Length-prefixed, so "ab"+"c" and "a"+"bc" cannot collide; UTF-8 bytes.
        let unicode = try #require(ShowTrackPreferenceStore.Scope(profileID: "é", serverID: "s|1", details: details))
        #expect(unicode.storageKey == "ShowTrackPreferences.v1.2:é3:s|14:2000")

        try LegacyFixture.withScratchDefaults { defaults in
            ShowTrackPreferenceStore(defaults: defaults).save(ShowTrackPreferences(audio: nil, subtitles: .off), for: scope)
            #expect(defaults.dictionaryRepresentation().keys.contains(
                "ShowTrackPreferences.v1.16:4f2a9c1d7e3b5a6040:a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e94:2000"
            ))
        }
    }

    @Test func pinnedPlaylistsKey() throws {
        #expect(PinnedPlaylistStore.storageKey("4f2a9c1d7e3b5a60") == "PinnedHomePlaylists.v1.4f2a9c1d7e3b5a60")
        #expect(PinnedPlaylistStore.storageKey(nil) == nil)
        #expect(PinnedPlaylistStore.storageKey("") == nil)
        try LegacyFixture.withScratchDefaults { defaults in
            PinnedPlaylistStore(defaults: defaults)
                .pin(MediaItemID(serverID: serverA, itemID: "5001"), title: "Pins", profileID: "plex-home-24601")
            #expect(defaults.dictionaryRepresentation().keys.contains("PinnedHomePlaylists.v1.plex-home-24601"))
        }
    }

    @Test func iptvSourcesKey() throws {
        try LegacyFixture.withScratchDefaults { defaults in
            IPTVSourceStore(defaults: defaults, secrets: MemorySecret().storage).save(
                [IPTVSource(name: "TV", playlistURL: URL(string: "https://iptv.example.com/a.m3u")!)],
                profileID: "plex-home-24601"
            )
            #expect(defaults.dictionaryRepresentation().keys.contains("IPTVSources.plex-home-24601"))
        }
        #expect(IPTVSource.defaultHeaderName == "Authorization")
    }

    @Test func iptvResumeKeys() throws {
        #expect(IPTVResumeStore.storageKey == "iptvResumePoints")
        #expect(UbiquitousIPTVResumeCloud.key == "iptvResumePoints")
        // SHA-256 of "<source>\n<channel URL>\n<start unix>\n<end unix>", first 16 bytes.
        let key = IPTVResumeKey(
            sourceIdentity: "http://example.com/list.m3u",
            channelStreamURL: URL(string: "http://example.com/live/1.ts")!,
            start: Date(timeIntervalSince1970: 1_767_225_600),
            end: Date(timeIntervalSince1970: 1_767_229_200)
        )
        #expect(key.rawValue == "a215b090b585a805b419473b0877022a")

        #expect(IPTVResumeKey.sourceIdentity(playlistURL: URL(string: "HTTP://Example.COM:80/lists/tv.m3u/?b=2&a=1#top")!)
            == "http://example.com/lists/tv.m3u?a=1&b=2")
        #expect(IPTVResumeKey.sourceIdentity(playlistURL: URL(string: "https://iptv.example.com:443/a.m3u")!)
            == "https://iptv.example.com/a.m3u")
        #expect(IPTVResumeKey.sourceIdentity(playlistURL: URL(string:
            "http://Panel.Example:8080/get.php?username=alice&password=secret&type=m3u_plus&output=ts")!)
            == "xtream:http://panel.example:8080|alice")

        try LegacyFixture.withScratchDefaults { defaults in
            IPTVResumeStore(defaults: defaults, cloud: nil, now: { LegacyValues.t0 })
                .record(position: 120, duration: 3600, for: key)
            #expect(defaults.dictionaryRepresentation().keys.contains("iptvResumePoints"))
        }
    }

    @Test func homeContinueWatchingServerIDsKey() throws {
        let profile = "golden-\(UUID().uuidString)"
        LegacyFixture.withStandardDefault("HomeContinueWatchingServerIDs", set: nil) {
            HomeContinueWatchingMemory.remember(["srv-b", "srv-a"], profileID: profile)
            HomeContinueWatchingMemory.remember(["srv-c"], profileID: nil)
            let stored = UserDefaults.standard.dictionary(forKey: "HomeContinueWatchingServerIDs") as? [String: [String]]
            #expect(stored == [profile: ["srv-a", "srv-b"], "-": ["srv-c"]])
            #expect(HomeContinueWatchingMemory.serverIDs(profileID: profile) == ["srv-a", "srv-b"])
        }
    }

    // MARK: - Account and server keys

    @Test func accountDefaultsAndKeychainNames() {
        #expect(MediaService.keychainTokenKey == "PlexAuthToken")
        #expect(MediaService.keychainActiveHomeTokenKey == "PlexActiveHomeUserToken")
        #expect(MediaService.keychainServerTokenKey == "PlexServerAuthToken")
        #expect(MediaService.defaultsClientIDKey == "PlexClientIdentifier")
        #expect(MediaService.defaultsPrimaryProfileIDKey == "PlexPrimaryProfileID")
        #expect(MediaService.defaultsActiveHomeUserDataKey == "PlexActiveHomeUserData")
        #expect(MediaService.defaultsAutomaticHomeSignInKey == "PlexAutomaticallySignInHomeUser")
        #expect(MediaService.defaultsHomeMigrationCompletedKey == "PlexHomeMigrationCompleted")
        #expect(MediaService.defaultsServerIDKey == "PlexServerID")
        #expect(MediaService.defaultsServerURLKey == "PlexServerURL")
        #expect(MediaService.defaultsServerDataKey == "PlexServerData")
        #expect(MediaService.defaultsLastGoodConnectionURIKey == "PlexLastGoodConnectionURI")
    }

    @Test func serverKeys() throws {
        #expect(ServerPriorityStore.defaultsKey == "PlexServerPriority")
        #expect(ServerPriorityStore.legacyServerIDKey == "PlexServerID")
        #expect(ServerPool.defaultsSnapshotsKey == "PlexServerSnapshots")
        #expect(ServerPool.baseURLKey(serverID: "abc123") == "PlexServerURL.abc123")
        #expect(ServerPool.lastGoodConnectionKey(serverID: "abc123") == "PlexLastGoodConnectionURI.abc123")
        #expect(ServerPool.tokenKey(serverID: "abc123") == "PlexServerAuthToken.abc123")
        try LegacyFixture.withScratchDefaults { defaults in
            ServerPriorityStore(defaults: defaults).setEnabled(false, for: "abc123")
            #expect(defaults.dictionaryRepresentation().keys.contains("PlexServerPriority"))
        }
    }

    @Test func keychainServiceAndAccounts() throws {
        try #require(LegacyFixture.keychainIsAvailable, "Keychain unavailable to the test host")

        let probe = "DuskGoldenProbe.\(UUID().uuidString)"
        KeychainHelper.save(key: probe, data: Data("x".utf8))
        #expect(LegacyFixture.keychainData(account: probe) == Data("x".utf8))
        KeychainHelper.delete(key: probe)

        LegacyFixture.preservingKeychainItem("SeerrSessions") {
            SeerrCredentialStore.save([SeerrStoredSession(baseURL: "https://s.example", profileID: "p", serverID: "s", cookies: [:])])
            #expect(LegacyFixture.keychainData(account: "SeerrSessions") != nil)
        }
        LegacyFixture.preservingKeychainItem("TraktAccounts") {
            TraktCredentialStore.save(["p": TraktTokens(
                accessToken: "a", refreshToken: "r", expiresAt: LegacyValues.t0, username: nil, redirectURI: nil
            )])
            #expect(LegacyFixture.keychainData(account: "TraktAccounts") != nil)
        }
        LegacyFixture.preservingKeychainItem("IPTVSourceHeaderValues") {
            let id = UUID()
            IPTVSourceStore(defaults: .standard, secrets: .keychain).setHeaderValue("Bearer x", for: id)
            let data = LegacyFixture.keychainData(account: "IPTVSourceHeaderValues")
            #expect(data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } == [id.uuidString: "Bearer x"])
        }
    }

    // MARK: - Profile scope ids

    @Test func homeUserProfileIDs() throws {
        let withUUID = try JSONDecoder().decode(PlexHomeUser.self, from: Data(#"{"id":24601,"uuid":"c1d2e3f4a5b60789"}"#.utf8))
        #expect(withUUID.stableProfileID == "c1d2e3f4a5b60789")
        let withoutUUID = try JSONDecoder().decode(PlexHomeUser.self, from: Data(#"{"id":24601}"#.utf8))
        #expect(withoutUUID.stableProfileID == "plex-home-24601")
        let emptyUUID = try JSONDecoder().decode(PlexHomeUser.self, from: Data(#"{"id":"24601","uuid":""}"#.utf8))
        #expect(emptyUUID.stableProfileID == "plex-home-24601")
    }

    @Test func activeProfileIDPrecedence() throws {
        let service = MediaService()
        defer { invalidate(service) }
        service.primaryAccountToken = "owner-token"
        service.activeAccountToken = "owner-token"
        service.activeHomeUser = nil
        service.currentUser = nil
        service.homeUsers = []
        service.primaryProfileID = "plex-account-1111"
        #expect(service.activeProfileID == "plex-account-1111")

        service.currentUser = try JSONDecoder().decode(PlexUser.self, from: Data(#"{"id":1111,"uuid":"4f2a9c1d7e3b5a60"}"#.utf8))
        #expect(service.activeProfileID == "4f2a9c1d7e3b5a60")

        service.activeHomeUser = try JSONDecoder().decode(PlexHomeUser.self, from: Data(#"{"id":24601}"#.utf8))
        #expect(service.activeProfileID == "plex-home-24601")

        // A switched-to member's token without a known member: no profile.
        service.activeHomeUser = nil
        service.currentUser = nil
        service.activeAccountToken = "member-token"
        #expect(service.activeProfileID == nil)
    }

    /// The primary account's profile id as `bootstrapHomeSession` derives it
    /// (the private `updatePrimaryProfileIdentity`), driven through stubbed
    /// plex.tv responses.
    @Test(arguments: [
        PrimaryProfileCase(
            account: #"{"id":1111,"uuid":"4f2a9c1d7e3b5a60","username":"owner"}"#,
            homeUsers: #"[{"id":1111,"uuid":"4f2a9c1d7e3b5a60","username":"owner","admin":true}]"#,
            primaryProfileID: "4f2a9c1d7e3b5a60",
            activeProfileID: "4f2a9c1d7e3b5a60"
        ),
        PrimaryProfileCase(
            account: #"{"id":1111}"#,
            homeUsers: "[]",
            primaryProfileID: "plex-account-1111",
            activeProfileID: "plex-account-1111"
        ),
        PrimaryProfileCase(
            account: #"{"id":1111,"username":"owner"}"#,
            homeUsers: #"[{"id":24601,"username":"owner","admin":true}]"#,
            primaryProfileID: "plex-home-24601",
            activeProfileID: "plex-home-24601"
        ),
        PrimaryProfileCase(
            account: #"{"id":1111,"uuid":"4f2a9c1d7e3b5a60"}"#,
            homeUsers: "[]",
            primaryProfileID: "4f2a9c1d7e3b5a60",
            activeProfileID: "4f2a9c1d7e3b5a60"
        ),
    ])
    func primaryAccountProfileID(_ example: PrimaryProfileCase) async throws {
        let keys = [
            MediaService.defaultsPrimaryProfileIDKey,
            MediaService.defaultsActiveHomeUserDataKey,
            MediaService.defaultsHomeMigrationCompletedKey,
        ]
        let rememberedHomeToken = KeychainHelper.load(key: "PlexActiveHomeUserToken")
        defer {
            if let rememberedHomeToken {
                KeychainHelper.save(key: "PlexActiveHomeUserToken", data: rememberedHomeToken)
            }
        }
        try await LegacyFixture.preservingStandardDefaults(keys) {
            ProfileBootstrapStub.responses = [
                "/api/v2/user": Data(example.account.utf8),
                "/api/v2/home/users": Data(example.homeUsers.utf8),
            ]
            let service = MediaService(urlProtocolClasses: [ProfileBootstrapStub.self])
            defer { invalidate(service) }
            service.primaryAccountToken = "golden-owner-token"
            service.activeAccountToken = "golden-owner-token"
            service.activeHomeUser = nil
            service.currentUser = nil
            service.primaryProfileID = nil

            try await service.bootstrapHomeSession()
            #expect(service.primaryProfileID == example.primaryProfileID)
            #expect(UserDefaults.standard.string(forKey: "PlexPrimaryProfileID") == example.primaryProfileID)
            #expect(service.activeProfileID == example.activeProfileID)
        }
    }

    private func invalidate(_ service: MediaService) {
        service.session.invalidateAndCancel()
        service.slowQuerySession.invalidateAndCancel()
        service.probeSession.invalidateAndCancel()
        service.bootstrapSession.invalidateAndCancel()
    }

    // MARK: - Cross-process and cross-device identifiers

    @Test func siriEntityIDForm() {
        let entry = SiriCatalogEntry(
            id: MediaItemID(serverID: "srv-a", itemID: "1001"), kind: .movie, title: "Arrival", year: 2016, lastPlayedAt: nil
        )
        let entity = PlexTitleEntity(entry)
        #expect(entity.id == "srv-a|1001")
        #expect(entity.candidate?.id == MediaItemID(serverID: "srv-a", itemID: "1001"))
        #expect(SiriTitleKind.movie.rawValue == "movie")
        #expect(SiriTitleKind.show.rawValue == "show")
        // An id saved by a build without servers still resolves to an item.
        #expect(PlexTitleEntity(id: "1001", kind: .movie, title: "Arrival", year: nil).candidate?.id
            == MediaItemID(serverID: nil, itemID: "1001"))
    }

    @Test func sharePlayIdentifiers() throws {
        #expect(DuskWatchTogetherActivity.activityIdentifier == "com.dusk-player.app.watch-together")
        let activity = DuskWatchTogetherActivity(serverIdentifier: "srv-a", itemID: "1001", title: "Arrival", subtitle: "2016")
        #expect(activity.playbackItemIdentifier == "plex://srv-a/metadata/1001")
        try LegacyFixture.expectSameJSON(
            try JSONEncoder().encode(activity),
            Data(#"{"serverIdentifier":"srv-a","ratingKey":"1001","title":"Arrival","subtitle":"2016"}"#.utf8)
        )
    }

    #if os(tvOS)
    @Test func topShelfDeepLinks() throws {
        #expect(TopShelfLink.scheme == "dusk")
        #expect(TopShelfStore.appGroupIdentifier == "group.com.dusk-player.app")

        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "srv-a"
        let movie = try decoder.decode(MediaItem.self, from: Data(#"""
            {"ratingKey":"1001","key":"/library/metadata/1001","type":"movie","title":"Arrival"}
            """#.utf8))
        let episode = try decoder.decode(MediaItem.self, from: Data(#"""
            {"ratingKey":"2011","key":"/library/metadata/2011","type":"episode","title":"Pilot"}
            """#.utf8))
        let clip = try decoder.decode(MediaItem.self, from: Data(#"""
            {"ratingKey":"4001","key":"/library/metadata/4001","type":"movie","subtype":"clip","title":"Home Video"}
            """#.utf8))
        #expect(TopShelfLink.url(.play, for: movie)?.absoluteString == "dusk://play?server=srv-a&item=1001&type=movie")
        #expect(TopShelfLink.url(.open, for: episode)?.absoluteString == "dusk://open?server=srv-a&item=2011&type=episode")
        #expect(TopShelfLink.url(.open, for: clip)?.absoluteString == "dusk://open?server=srv-a&item=4001&type=movie&clip=1")

        let unscoped = try JSONDecoder().decode(MediaItem.self, from: Data(#"""
            {"ratingKey":"1001","key":"/library/metadata/1001","type":"movie","title":"Arrival"}
            """#.utf8))
        #expect(TopShelfLink.url(.play, for: unscoped) == nil)

        // Links already handed to tvOS by an older build.
        let parsed = try #require(TopShelfLink(url: URL(string: "dusk://play?server=srv-a&item=2011&type=episode")!))
        #expect(parsed.action == .play)
        #expect(parsed.id == MediaItemID(serverID: "srv-a", itemID: "2011"))
        #expect(parsed.type == .episode)
        #expect(parsed.isClip == false)
        #expect(TopShelfLink(url: URL(string: "dusk://open?item=2011&type=episode")!) == nil)
        #expect(TopShelfLink(url: URL(string: "dusk://resume?server=srv-a&item=2011&type=episode")!) == nil)
    }
    #endif
}

struct PrimaryProfileCase: Sendable, CustomTestStringConvertible {
    let account: String
    let homeUsers: String
    let primaryProfileID: String
    let activeProfileID: String

    var testDescription: String { primaryProfileID }
}

/// Serves `/api/v2/user` and `/api/v2/home/users` for
/// `PersistedGoldenStringTests.primaryAccountProfileID` (a serialized suite).
private final class ProfileBootstrapStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = Self.responses[url.path]
        let response = HTTPURLResponse(
            url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
