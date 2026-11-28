import Foundation
import Testing
@testable import Dusk

/// Records the synthetic G4 fixtures in `DuskTests/Fixtures/LegacyContainer/`
/// with today's encoders, by driving each store's own write path and dumping
/// the bytes it persisted.
///
/// Skipped unless `DUSK_RECORD_LEGACY_CONTAINER=1` reaches the test process
/// (`TEST_RUNNER_DUSK_RECORD_LEGACY_CONTAINER=1 xcodebuild … test-without-building`).
/// Re-recording is only legitimate on the pre-refactor baseline commit: the
/// whole point of these files is that later builds must still read them.
@Suite(
    "Legacy container recorder",
    .serialized,
    .enabled(if: LegacyFixture.isRecording, "Set TEST_RUNNER_DUSK_RECORD_LEGACY_CONTAINER=1 to re-record")
)
@MainActor
struct LegacyContainerRecorder {
    private typealias V = LegacyValues

    @Test func recordDownloadsSnapshot() throws {
        let converted = try JSONDecoder().decode(MediaVersion.self, from: Data(V.convertedMediaJSON.utf8))
        // DownloadManager stores the prepared media exactly like this.
        let convertedData = try JSONEncoder().encode(converted)

        let snapshot = DownloadStoreSnapshot(
            records: [
                DownloadedMediaRecord(
                    accountProfileID: V.ownerProfile,
                    serverID: V.serverA,
                    serverName: "Living Room",
                    itemID: "1001",
                    type: .movie,
                    title: "Arrival",
                    subtitle: "2016",
                    thumbPath: "/library/metadata/1001/thumb/1700000000",
                    artPath: "/library/metadata/1001/art/1700000000",
                    mediaID: "501",
                    partID: "601",
                    relativeVideoPath: "Profiles/4f2a9c1d7e3b5a60/Movies/Arrival (2016)/Arrival (2016).mkv",
                    externalSubtitlePaths: [
                        "7001": "Subtitles/547b0036d8c6f5d72c77415432032b11b28aafbec6a6d376d3c0de83e1d2a29e/7001.srt",
                        "7002": "Subtitles/547b0036d8c6f5d72c77415432032b11b28aafbec6a6d376d3c0de83e1d2a29e/7002.ass",
                    ],
                    status: .completed,
                    progress: 1,
                    downloadedBytes: 4_000_000_000,
                    totalBytes: 4_000_000_000,
                    errorMessage: nil,
                    addedAt: V.t0,
                    updatedAt: V.t1
                ),
                DownloadedMediaRecord(
                    accountProfileID: V.kidProfile,
                    serverID: V.serverB,
                    serverName: "Friend's Server",
                    itemID: "2011",
                    type: .episode,
                    title: "Pilot",
                    subtitle: "S1 · E1",
                    parentID: "2010",
                    parentTitle: "Season 1",
                    grandparentID: "2000",
                    grandparentTitle: "Severance",
                    thumbPath: "/library/metadata/2011/thumb/1700000001",
                    artPath: nil,
                    mediaID: "81",
                    partID: "82",
                    downloadQuality: .p720,
                    isSmartDownload: true,
                    queueClientIdentifier: "C0FFEE00-1111-4222-8333-944445555666",
                    plexDownloadQueueID: "17",
                    plexDownloadItemID: "3",
                    preparationProgress: 0.5,
                    preparationRetryCount: 2,
                    convertedMediaData: convertedData,
                    relativeVideoPath: "Profiles/plex-home-24601/TV Shows/Severance/Season 01/S01E01 - Pilot.mkv",
                    externalSubtitlePaths: [:],
                    hasMissingExternalSubtitles: true,
                    resumeDataPath: "ResumeData/0d1c3e5f.resume",
                    downloadTaskIdentifier: 42,
                    wasPausedForProfileSwitch: true,
                    status: .paused,
                    progress: 0.25,
                    downloadedBytes: 315_000_000,
                    totalBytes: 1_260_000_000,
                    errorMessage: nil,
                    addedAt: V.t0,
                    updatedAt: V.t2
                ),
                // Pre-Plex-Home record keyed on the server's base URL.
                DownloadedMediaRecord(
                    accountProfileID: nil,
                    serverID: V.legacyBaseURLServer,
                    serverName: nil,
                    itemID: "3001",
                    type: .movie,
                    isClip: true,
                    title: "Behind the Scenes",
                    status: .failed,
                    progress: 0.75,
                    downloadedBytes: 750,
                    totalBytes: nil,
                    errorMessage: "The network connection was lost.",
                    addedAt: V.t0,
                    updatedAt: V.t0
                ),
            ],
            pendingQueueRemovals: [
                DownloadQueueRemoval(
                    profileID: V.kidProfile,
                    serverID: V.serverB,
                    clientIdentifier: "C0FFEE00-1111-4222-8333-944445555666",
                    itemID: "2012",
                    queueID: "17",
                    queueItemID: nil
                ),
            ],
            smartDownloadRules: [
                SmartDownloadRule(
                    accountProfileID: V.kidProfile,
                    serverID: V.serverB,
                    showRatingKey: "2000",
                    count: 5,
                    quality: .p720,
                    showTitle: "Severance",
                    thumbPath: "/library/metadata/2000/thumb/1700000002",
                    artPath: nil,
                    remainingUnwatchedCount: 7,
                    lastRefillAt: V.t1,
                    createdAt: V.t0
                ),
            ]
        )

        try LegacyFixture.withTemporaryRoot { root in
            let store = DownloadFileStore(rootDirectory: root)
            try store.saveSnapshot(snapshot)
            try LegacyFixture.record(try Data(contentsOf: store.stateFileURL), as: "LegacyContainer-downloads.json")
        }
    }

    @Test func recordPlaybackSyncSnapshot() throws {
        let snapshot = OfflinePlaybackSyncSnapshot(actions: [
            OfflinePlaybackSyncAction(
                accountProfileID: V.ownerProfile,
                serverID: V.serverA,
                itemID: "1001",
                kind: .progress,
                viewOffsetMs: 1_234_000,
                durationMs: 6_960_000,
                shouldMarkWatched: false,
                plexState: "paused",
                needsSync: true,
                attemptCount: 0,
                lastAttemptAt: nil,
                createdAt: V.t0,
                updatedAt: V.t1
            ),
            OfflinePlaybackSyncAction(
                accountProfileID: nil,
                serverID: V.legacyBaseURLServer,
                itemID: "3001",
                kind: .watched,
                viewOffsetMs: nil,
                durationMs: nil,
                shouldMarkWatched: true,
                plexState: nil,
                needsSync: true,
                attemptCount: 3,
                lastAttemptAt: V.t2,
                createdAt: V.t0,
                updatedAt: V.t2
            ),
            OfflinePlaybackSyncAction(
                accountProfileID: V.kidProfile,
                serverID: V.serverB,
                itemID: "2011",
                kind: .unwatched,
                viewOffsetMs: 0,
                durationMs: 2_520_000,
                shouldMarkWatched: false,
                plexState: "stopped",
                needsSync: false,
                attemptCount: 1,
                lastAttemptAt: V.t1,
                createdAt: V.t1,
                updatedAt: V.t1
            ),
        ])

        try LegacyFixture.withTemporaryRoot { root in
            let fileStore = DownloadFileStore(rootDirectory: root)
            try OfflinePlaybackSyncStore(fileStore: fileStore).saveSnapshot(snapshot)
            try LegacyFixture.record(
                try Data(contentsOf: fileStore.playbackSyncStateFileURL),
                as: "LegacyContainer-playback-sync.json"
            )
        }
    }

    @Test func recordPinnedPlaylists() throws {
        try LegacyFixture.withScratchDefaults { defaults in
            let store = PinnedPlaylistStore(defaults: defaults)
            store.pin(MediaItemID(serverID: V.serverA, itemID: "5001"), title: "Friday Movie Night", profileID: V.ownerProfile)
            store.pin(MediaItemID(serverID: nil, itemID: "5002"), title: "Old Pin", profileID: V.ownerProfile)
            let data = try #require(defaults.data(forKey: "PinnedHomePlaylists.v1.4f2a9c1d7e3b5a60"))
            try LegacyFixture.record(data, as: "LegacyContainer-PinnedHomePlaylists.json")
        }
    }

    @Test func recordShowTrackPreferences() throws {
        let details = try JSONDecoder().decode(MediaDetails.self, from: Data(V.trackEpisodeJSON.utf8))
        let streams = details.media[0].parts[0].streams
        let audio = try #require(ShowTrackDescriptor(stream: streams[0]))
        let externalSDH = try #require(ShowTrackDescriptor(stream: streams[2]))

        try LegacyFixture.withScratchDefaults { defaults in
            let store = ShowTrackPreferenceStore(defaults: defaults)
            let ownerScope = try #require(ShowTrackPreferenceStore.Scope(profileID: V.ownerProfile, serverID: V.serverA, details: details))
            let kidScope = try #require(ShowTrackPreferenceStore.Scope(profileID: V.kidProfile, serverID: V.serverB, details: details))
            store.save(ShowTrackPreferences(audio: audio, subtitles: .track(externalSDH)), for: ownerScope)
            store.save(ShowTrackPreferences(audio: nil, subtitles: .off), for: kidScope)
            try LegacyFixture.record(
                try #require(defaults.data(forKey: ownerScope.storageKey)),
                as: "LegacyContainer-ShowTrackPreferences-track.json"
            )
            try LegacyFixture.record(
                try #require(defaults.data(forKey: kidScope.storageKey)),
                as: "LegacyContainer-ShowTrackPreferences-off.json"
            )
        }
    }

    @Test func recordServerPriority() throws {
        try LegacyFixture.withScratchDefaults { defaults in
            let store = ServerPriorityStore(defaults: defaults)
            store.setEnabled(true, for: V.serverA)
            store.setEnabled(false, for: V.serverB)
            try LegacyFixture.record(
                try #require(defaults.data(forKey: "PlexServerPriority")),
                as: "LegacyContainer-PlexServerPriority.json"
            )
        }
    }

    @Test func recordServerSnapshots() throws {
        let servers = try JSONDecoder().decode([PlexServer].self, from: Data(V.serverResourcesJSON.utf8))
        let data = LegacyFixture.withStandardDefault("PlexServerSnapshots", set: nil) {
            ServerPool.saveSnapshots(servers)
            return UserDefaults.standard.data(forKey: "PlexServerSnapshots")
        }
        try LegacyFixture.record(try #require(data), as: "LegacyContainer-PlexServerSnapshots.json")
    }

    @Test func recordActiveHomeUser() throws {
        let user = try JSONDecoder().decode(PlexHomeUser.self, from: Data(V.homeUserJSON.utf8))
        // `PlexService.persistActiveHomeUser` writes `encoder.encode(user)` with
        // a plain `JSONEncoder()` (`PlexService.encoder`).
        try LegacyFixture.record(try JSONEncoder().encode(user), as: "LegacyContainer-PlexActiveHomeUserData.json")
    }

    @Test func recordIPTVSources() throws {
        let secret = MemorySecret()
        try LegacyFixture.withScratchDefaults { defaults in
            let store = IPTVSourceStore(defaults: defaults, secrets: secret.storage)
            store.save([
                IPTVSource(
                    id: V.iptvSourceID,
                    name: "Freeview",
                    playlistURL: URL(string: "https://iptv.example.com/freeview.m3u")!,
                    guideURL: URL(string: "https://iptv.example.com/epg.xml.gz")!,
                    headerName: "Authorization"
                ),
                IPTVSource(
                    id: V.iptvXtreamSourceID,
                    name: "Panel",
                    playlistURL: URL(string: "http://panel.example:8080/get.php?username=alice&password=secret&type=m3u_plus&output=ts")!
                ),
            ], profileID: V.ownerProfile)
            store.setHeaderValue("Bearer abc123", for: V.iptvSourceID)
            try LegacyFixture.record(
                try #require(defaults.data(forKey: "IPTVSources.4f2a9c1d7e3b5a60")),
                as: "LegacyContainer-IPTVSources.json"
            )
            try LegacyFixture.record(try #require(secret.data), as: "LegacyContainer-IPTVSourceHeaderValues.json")
        }
    }

    @Test func recordIPTVResumePoints() throws {
        let source = "http://example.com/list.m3u"
        let channel = URL(string: "http://example.com/live/1.ts")!
        let watching = IPTVResumeKey(
            sourceIdentity: source, channelStreamURL: channel,
            start: V.iptvProgrammeStart, end: V.iptvProgrammeEnd
        )
        let finished = IPTVResumeKey(
            sourceIdentity: source, channelStreamURL: channel,
            start: V.iptvProgrammeEnd, end: V.iptvNextProgrammeEnd
        )
        try LegacyFixture.withScratchDefaults { defaults in
            let store = IPTVResumeStore(defaults: defaults, cloud: nil, now: { V.t0 })
            store.record(position: 1234.5, duration: 3600, for: watching)
            store.record(position: 600, duration: 3600, for: finished)
            store.record(position: 3590, duration: 3600, for: finished)
            try LegacyFixture.record(
                try #require(defaults.data(forKey: "iptvResumePoints")),
                as: "LegacyContainer-iptvResumePoints.json"
            )
        }
    }

    @Test func recordTraktStores() throws {
        try LegacyFixture.withScratchDefaults { defaults in
            TraktHistoryQueue(defaults: defaults).save([
                TraktHistoryEntry(
                    kind: .episode,
                    ids: TraktIDs(imdb: "tt11280740", tmdb: 95396, tvdb: 371980),
                    season: 1,
                    episode: 1,
                    watchedAt: V.t1,
                    profileID: V.ownerProfile,
                    attempts: 2,
                    id: V.traktHistoryID
                ),
            ])
            try LegacyFixture.record(
                try #require(defaults.data(forKey: "TraktPendingHistory")),
                as: "LegacyContainer-TraktPendingHistory.json"
            )
        }

        let accounts: [String: TraktTokens] = [
            V.ownerProfile: TraktTokens(
                accessToken: "trakt-access-owner", refreshToken: "trakt-refresh-owner",
                expiresAt: V.t2, username: "alice", redirectURI: nil
            ),
            V.kidProfile: TraktTokens(
                accessToken: "trakt-access-kid", refreshToken: "trakt-refresh-kid",
                expiresAt: V.t1, username: nil, redirectURI: "dusk://trakt/callback"
            ),
        ]
        let data = try LegacyFixture.preservingKeychainItem("TraktAccounts") { () throws -> Data in
            try #require(LegacyFixture.keychainIsAvailable, "Keychain unavailable to the test host")
            TraktCredentialStore.save(accounts)
            return try #require(LegacyFixture.keychainData(account: "TraktAccounts"))
        }
        try LegacyFixture.record(data, as: "LegacyContainer-TraktAccounts.json")
    }

    @Test func recordSeerrSessions() throws {
        let data = try LegacyFixture.preservingKeychainItem("SeerrSessions") { () throws -> Data in
            try #require(LegacyFixture.keychainIsAvailable, "Keychain unavailable to the test host")
            SeerrCredentialStore.save([
                SeerrStoredSession(
                    baseURL: "https://seerr.example.com",
                    profileID: V.ownerProfile,
                    serverID: V.serverA,
                    cookies: ["connect.sid": "s%3Aabc.def"]
                ),
            ])
            return try #require(LegacyFixture.keychainData(account: "SeerrSessions"))
        }
        try LegacyFixture.record(data, as: "LegacyContainer-SeerrSessions.json")
    }

    @Test func recordSiriCatalogEntries() throws {
        // `SiriTitleCatalog.Stored` is private; its real bytes come from the
        // captured container (LegacyContainer-real-siriTitleCatalog.json).
        let entries = [
            SiriCatalogEntry(
                id: MediaItemID(serverID: V.serverA, itemID: "1001"),
                kind: .movie, title: "Arrival", year: 2016, lastPlayedAt: 1_767_225_600
            ),
            SiriCatalogEntry(
                id: MediaItemID(serverID: V.serverB, itemID: "2000"),
                kind: .show, title: "Severance", year: nil, lastPlayedAt: nil
            ),
        ]
        try LegacyFixture.record(try JSONEncoder().encode(entries), as: "LegacyContainer-SiriCatalogEntries.json")
    }

    @Test func recordWatchTogetherActivity() throws {
        let activity = DuskWatchTogetherActivity(
            serverIdentifier: V.serverA, itemID: "1001", title: "Arrival", subtitle: nil
        )
        try LegacyFixture.record(try JSONEncoder().encode(activity), as: "LegacyContainer-WatchTogetherActivity.json")
    }

    #if os(tvOS)
    @Test func recordTopShelfSnapshot() throws {
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = V.serverA
        let movie = try decoder.decode(MediaItem.self, from: Data(#"""
            {"ratingKey":"1001","key":"/library/metadata/1001","type":"movie","title":"Arrival"}
            """#.utf8))
        let clip = try decoder.decode(MediaItem.self, from: Data(#"""
            {"ratingKey":"4001","key":"/library/metadata/4001","type":"movie","subtype":"clip","title":"Home Video"}
            """#.utf8))
        let snapshot = TopShelfSnapshot(sections: [
            TopShelfSnapshot.Section(title: "Continue Watching", items: [
                TopShelfSnapshot.Item(
                    id: movie.id.storageKey, title: "Arrival", imageFileName: "a3d5-1001.jpg",
                    isLandscape: false, progress: 0.25,
                    playURL: try #require(TopShelfLink.url(.play, for: movie)),
                    displayURL: try #require(TopShelfLink.url(.open, for: movie))
                ),
            ]),
            TopShelfSnapshot.Section(title: "Recently Added in Home Videos", items: [
                TopShelfSnapshot.Item(
                    id: clip.id.storageKey, title: "Home Video", imageFileName: "a3d5-4001.jpg",
                    isLandscape: true, progress: nil,
                    playURL: try #require(TopShelfLink.url(.play, for: clip)),
                    displayURL: try #require(TopShelfLink.url(.open, for: clip))
                ),
            ]),
        ])
        // `TopShelfPublisher.write` encodes with a plain `JSONEncoder()`.
        try LegacyFixture.record(try JSONEncoder().encode(snapshot), as: "LegacyContainer-TopShelfSnapshot.json")
    }
    #endif
}

/// In-memory stand-in for the Keychain behind `IPTVSourceStore`.
final class MemorySecret: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    init(_ data: Data? = nil) { stored = data }

    var data: Data? { lock.withLock { stored } }

    var storage: IPTVSourceStore.SecretStorage {
        IPTVSourceStore.SecretStorage(
            load: { [self] in lock.withLock { stored } },
            save: { [self] value in lock.withLock { stored = value } },
            delete: { [self] in lock.withLock { stored = nil } }
        )
    }
}
