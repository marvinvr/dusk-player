import Foundation
import Testing
@testable import Dusk

/// G4 (05-plan §3): bytes written by the pre-refactor build still load, decode
/// to the same values and re-encode to the same JSON.
///
/// Every fixture in `Fixtures/LegacyContainer/` was produced by today's
/// encoders (`LegacyContainerRecorder`). Each test places the bytes where an
/// existing install keeps them (a literal defaults key, a literal relative
/// path, a literal Keychain account), reads them through the real store,
/// checks every field against literals, then writes them back through the
/// store and compares the result with the fixture as parsed JSON: key order
/// does not matter, a renamed `CodingKey` does.
///
/// A sweep may rename the Swift types used here. It may not change a literal.
@Suite("Legacy container: synthetic fixtures", .serialized)
@MainActor
struct LegacyContainerTests {
    // MARK: - downloads.json

    @Test func downloadsSnapshotDecodesFromTheStateFile() throws {
        let fixture = try LegacyFixture.data("LegacyContainer-downloads.json")
        try LegacyFixture.withTemporaryRoot { root in
            try LegacyFixture.place(fixture, at: "downloads.json", under: root)
            let snapshot = DownloadFileStore(rootDirectory: root).loadSnapshot()
            try #require(snapshot.records.count == 3)

            let movie = snapshot.records[0]
            #expect(movie.accountProfileID == "4f2a9c1d7e3b5a60")
            #expect(movie.serverID == "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9")
            #expect(movie.serverName == "Living Room")
            #expect(movie.itemID == "1001")
            #expect(movie.type == .movie)
            #expect(movie.type.rawValue == "movie")
            #expect(movie.isClip == false)
            #expect(movie.title == "Arrival")
            #expect(movie.subtitle == "2016")
            #expect(movie.parentID == nil)
            #expect(movie.grandparentID == nil)
            #expect(movie.thumbPath == "/library/metadata/1001/thumb/1700000000")
            #expect(movie.artPath == "/library/metadata/1001/art/1700000000")
            #expect(movie.mediaID == "501")
            #expect(movie.partID == "601")
            #expect(movie.downloadQuality == .original)
            #expect(movie.isSmartDownload == false)
            #expect(movie.queueClientIdentifier == nil)
            #expect(movie.convertedMediaData == nil)
            #expect(movie.relativeVideoPath == "Profiles/4f2a9c1d7e3b5a60/Movies/Arrival (2016)/Arrival (2016).mkv")
            #expect(movie.externalSubtitlePaths == [
                "7001": "Subtitles/547b0036d8c6f5d72c77415432032b11b28aafbec6a6d376d3c0de83e1d2a29e/7001.srt",
                "7002": "Subtitles/547b0036d8c6f5d72c77415432032b11b28aafbec6a6d376d3c0de83e1d2a29e/7002.ass",
            ])
            #expect(movie.hasMissingExternalSubtitles == false)
            #expect(movie.resumeDataPath == nil)
            #expect(movie.downloadTaskIdentifier == nil)
            #expect(movie.wasPausedForProfileSwitch == false)
            #expect(movie.status == .completed)
            #expect(movie.status.rawValue == "completed")
            #expect(movie.progress == 1)
            #expect(movie.downloadedBytes == 4_000_000_000)
            #expect(movie.totalBytes == 4_000_000_000)
            #expect(movie.errorMessage == nil)
            #expect(movie.addedAt == Date(timeIntervalSinceReferenceDate: 800_000_000))
            #expect(movie.updatedAt == Date(timeIntervalSinceReferenceDate: 800_003_600))
            #expect(movie.globalKey == "4f2a9c1d7e3b5a60:a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9:1001")
            #expect(movie.legacyGlobalKey == "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9:1001")
            #expect(movie.id == movie.globalKey)
            #expect(movie.mediaItemID.storageKey == "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9|1001")

            let episode = snapshot.records[1]
            #expect(episode.accountProfileID == "plex-home-24601")
            #expect(episode.serverID == "b7c9e1f3a5d7b9c1e3f5a7c9e1b3d5f7a9c1e3f5")
            #expect(episode.serverName == "Friend's Server")
            #expect(episode.itemID == "2011")
            #expect(episode.type == .episode)
            #expect(episode.title == "Pilot")
            #expect(episode.subtitle == "S1 · E1")
            #expect(episode.parentID == "2010")
            #expect(episode.parentTitle == "Season 1")
            #expect(episode.grandparentID == "2000")
            #expect(episode.grandparentTitle == "Severance")
            #expect(episode.displayTitle == "Severance - Pilot")
            #expect(episode.thumbPath == "/library/metadata/2011/thumb/1700000001")
            #expect(episode.artPath == nil)
            #expect(episode.mediaID == "81")
            #expect(episode.partID == "82")
            #expect(episode.downloadQuality == .p720)
            #expect(episode.downloadQuality.rawValue == "p720")
            #expect(episode.isSmartDownload == true)
            #expect(episode.queueClientIdentifier == "C0FFEE00-1111-4222-8333-944445555666")
            #expect(episode.plexDownloadQueueID == "17")
            #expect(episode.plexDownloadItemID == "3")
            #expect(episode.preparationProgress == 0.5)
            #expect(episode.preparationRetryCount == 2)
            #expect(episode.relativeVideoPath == "Profiles/plex-home-24601/TV Shows/Severance/Season 01/S01E01 - Pilot.mkv")
            #expect(episode.externalSubtitlePaths == [:])
            #expect(episode.hasMissingExternalSubtitles == true)
            #expect(episode.resumeDataPath == "ResumeData/0d1c3e5f.resume")
            #expect(episode.downloadTaskIdentifier == 42)
            #expect(episode.wasPausedForProfileSwitch == true)
            #expect(episode.status == .paused)
            #expect(episode.progress == 0.25)
            #expect(episode.downloadedBytes == 315_000_000)
            #expect(episode.totalBytes == 1_260_000_000)
            #expect(episode.addedAt == Date(timeIntervalSinceReferenceDate: 800_000_000))
            #expect(episode.updatedAt == Date(timeIntervalSinceReferenceDate: 800_086_400))
            #expect(episode.globalKey == "plex-home-24601:b7c9e1f3a5d7b9c1e3f5a7c9e1b3d5f7a9c1e3f5:2011")

            let converted = try #require(episode.convertedMedia)
            #expect(converted.id == "91")
            #expect(converted.container == "mkv")
            #expect(converted.videoCodec == "h264")
            #expect(converted.audioCodec == "aac")
            #expect(converted.videoResolution == "720")
            #expect(converted.audioChannels == 2)
            #expect(converted.width == 1280)
            #expect(converted.height == 720)
            #expect(converted.bitrate == 4000)
            #expect(converted.duration == 2_520_000)
            try #require(converted.parts.count == 1)
            #expect(converted.parts[0].id == "92")
            #expect(converted.parts[0].key == "/library/parts/92/1700000000/file.mkv")
            #expect(converted.parts[0].file == "/transcode/92.mkv")
            #expect(converted.parts[0].size == 1_260_000_000)
            #expect(converted.parts[0].container == "mkv")
            try #require(converted.parts[0].streams.count == 1)
            #expect(converted.parts[0].streams[0].id == "93")
            #expect(converted.parts[0].streams[0].kind == .audio)
            #expect(converted.parts[0].streams[0].codec == "aac")
            #expect(converted.parts[0].streams[0].languageCode == "eng")
            #expect(converted.parts[0].streams[0].channels == 2)
            // The blob's own bytes: re-encoding the decoded media gives the same JSON.
            try LegacyFixture.expectSameJSON(try JSONEncoder().encode(converted), try #require(episode.convertedMediaData))

            let legacy = snapshot.records[2]
            #expect(legacy.accountProfileID == nil)
            #expect(legacy.serverID == "http://192.168.1.10:32400")
            #expect(legacy.serverName == nil)
            #expect(legacy.itemID == "3001")
            #expect(legacy.type == .movie)
            #expect(legacy.isClip == true)
            #expect(legacy.title == "Behind the Scenes")
            #expect(legacy.mediaID == nil)
            #expect(legacy.partID == nil)
            #expect(legacy.relativeVideoPath == nil)
            #expect(legacy.externalSubtitlePaths == nil)
            #expect(legacy.downloadQuality == .original)
            #expect(legacy.status == .failed)
            #expect(legacy.progress == 0.75)
            #expect(legacy.downloadedBytes == 750)
            #expect(legacy.totalBytes == nil)
            #expect(legacy.errorMessage == "The network connection was lost.")
            #expect(legacy.globalKey == "http://192.168.1.10:32400:3001")
            #expect(legacy.legacyGlobalKey == "http://192.168.1.10:32400:3001")

            let removals = try #require(snapshot.pendingQueueRemovals)
            try #require(removals.count == 1)
            #expect(removals[0].profileID == "plex-home-24601")
            #expect(removals[0].serverID == "b7c9e1f3a5d7b9c1e3f5a7c9e1b3d5f7a9c1e3f5")
            #expect(removals[0].clientIdentifier == "C0FFEE00-1111-4222-8333-944445555666")
            #expect(removals[0].itemID == "2012")
            #expect(removals[0].queueID == "17")
            #expect(removals[0].queueItemID == nil)

            let rules = try #require(snapshot.smartDownloadRules)
            try #require(rules.count == 1)
            #expect(rules[0].accountProfileID == "plex-home-24601")
            #expect(rules[0].serverID == "b7c9e1f3a5d7b9c1e3f5a7c9e1b3d5f7a9c1e3f5")
            #expect(rules[0].showRatingKey == "2000")
            #expect(rules[0].count == 5)
            #expect(rules[0].quality == .p720)
            #expect(rules[0].showTitle == "Severance")
            #expect(rules[0].thumbPath == "/library/metadata/2000/thumb/1700000002")
            #expect(rules[0].artPath == nil)
            #expect(rules[0].remainingUnwatchedCount == 7)
            #expect(rules[0].lastRefillAt == Date(timeIntervalSinceReferenceDate: 800_003_600))
            #expect(rules[0].createdAt == Date(timeIntervalSinceReferenceDate: 800_000_000))
            #expect(rules[0].globalKey == "plex-home-24601:b7c9e1f3a5d7b9c1e3f5a7c9e1b3d5f7a9c1e3f5:2000")
            #expect(rules[0].showID.storageKey == "b7c9e1f3a5d7b9c1e3f5a7c9e1b3d5f7a9c1e3f5|2000")
        }
    }

    @Test func downloadsSnapshotReEncodesToTheFixture() throws {
        let fixture = try LegacyFixture.data("LegacyContainer-downloads.json")
        try LegacyFixture.withTemporaryRoot { root in
            try LegacyFixture.place(fixture, at: "downloads.json", under: root)
            let store = DownloadFileStore(rootDirectory: root)
            let snapshot = store.loadSnapshot()
            try #require(snapshot.records.count == 3)
            try store.saveSnapshot(snapshot)
            try LegacyFixture.expectSameJSON(try Data(contentsOf: root.appendingPathComponent("downloads.json")), fixture)
        }
    }

    // MARK: - playback-sync.json

    @Test func offlinePlaybackSyncDecodesFromTheStateFile() throws {
        let fixture = try LegacyFixture.data("LegacyContainer-playback-sync.json")
        try LegacyFixture.withTemporaryRoot { root in
            try LegacyFixture.place(fixture, at: "playback-sync.json", under: root)
            let store = OfflinePlaybackSyncStore(fileStore: DownloadFileStore(rootDirectory: root))
            let actions = store.loadSnapshot().actions
            try #require(actions.count == 3)

            #expect(actions[0].accountProfileID == "4f2a9c1d7e3b5a60")
            #expect(actions[0].serverID == "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9")
            #expect(actions[0].itemID == "1001")
            #expect(actions[0].kind == .progress)
            #expect(actions[0].kind.rawValue == "progress")
            #expect(actions[0].viewOffsetMs == 1_234_000)
            #expect(actions[0].durationMs == 6_960_000)
            #expect(actions[0].shouldMarkWatched == false)
            #expect(actions[0].plexState == "paused")
            #expect(actions[0].needsSync == true)
            #expect(actions[0].attemptCount == 0)
            #expect(actions[0].lastAttemptAt == nil)
            #expect(actions[0].createdAt == Date(timeIntervalSinceReferenceDate: 800_000_000))
            #expect(actions[0].updatedAt == Date(timeIntervalSinceReferenceDate: 800_003_600))
            #expect(actions[0].globalKey == "4f2a9c1d7e3b5a60:a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9:1001")

            #expect(actions[1].accountProfileID == nil)
            #expect(actions[1].serverID == "http://192.168.1.10:32400")
            #expect(actions[1].itemID == "3001")
            #expect(actions[1].kind == .watched)
            #expect(actions[1].viewOffsetMs == nil)
            #expect(actions[1].durationMs == nil)
            #expect(actions[1].shouldMarkWatched == true)
            #expect(actions[1].plexState == nil)
            #expect(actions[1].attemptCount == 3)
            #expect(actions[1].lastAttemptAt == Date(timeIntervalSinceReferenceDate: 800_086_400))
            #expect(actions[1].globalKey == "http://192.168.1.10:32400:3001")

            #expect(actions[2].accountProfileID == "plex-home-24601")
            #expect(actions[2].serverID == "b7c9e1f3a5d7b9c1e3f5a7c9e1b3d5f7a9c1e3f5")
            #expect(actions[2].itemID == "2011")
            #expect(actions[2].kind == .unwatched)
            #expect(actions[2].kind.rawValue == "unwatched")
            #expect(actions[2].viewOffsetMs == 0)
            #expect(actions[2].durationMs == 2_520_000)
            #expect(actions[2].plexState == "stopped")
            #expect(actions[2].needsSync == false)
            #expect(actions[2].attemptCount == 1)
            #expect(actions[2].createdAt == Date(timeIntervalSinceReferenceDate: 800_003_600))
        }
    }

    @Test func offlinePlaybackSyncReEncodesToTheFixture() throws {
        let fixture = try LegacyFixture.data("LegacyContainer-playback-sync.json")
        try LegacyFixture.withTemporaryRoot { root in
            try LegacyFixture.place(fixture, at: "playback-sync.json", under: root)
            let store = OfflinePlaybackSyncStore(fileStore: DownloadFileStore(rootDirectory: root))
            let snapshot = store.loadSnapshot()
            try #require(snapshot.actions.count == 3)
            try store.saveSnapshot(snapshot)
            try LegacyFixture.expectSameJSON(try Data(contentsOf: root.appendingPathComponent("playback-sync.json")), fixture)
        }
    }

    // MARK: - UserDefaults payloads

    @Test func pinnedPlaylistsDecodeAndReEncode() throws {
        let fixture = try LegacyFixture.data("LegacyContainer-PinnedHomePlaylists.json")
        try LegacyFixture.withScratchDefaults { defaults in
            defaults.set(fixture, forKey: "PinnedHomePlaylists.v1.4f2a9c1d7e3b5a60")
            let store = PinnedPlaylistStore(defaults: defaults)
            let pins = store.pins(profileID: "4f2a9c1d7e3b5a60")
            try #require(pins.count == 2)
            #expect(pins[0].id == MediaItemID(serverID: "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9", itemID: "5001"))
            #expect(pins[0].title == "Friday Movie Night")
            #expect(pins[1].id.serverID == nil)
            #expect(pins[1].id.itemID == "5002")
            #expect(pins[1].title == "Old Pin")
            #expect(store.pins(profileID: "plex-home-24601").isEmpty)

            // A no-op move rewrites the decoded list through the store.
            store.move(fromOffsets: IndexSet(integer: 0), toOffset: 0, profileID: "4f2a9c1d7e3b5a60")
            try LegacyFixture.expectSameJSON(defaults.data(forKey: "PinnedHomePlaylists.v1.4f2a9c1d7e3b5a60"), fixture)
        }
    }

    @Test func showTrackPreferencesDecodeAndReEncode() throws {
        let details = try JSONDecoder().decode(MediaDetails.self, from: Data(LegacyValues.trackEpisodeJSON.utf8))
        let track = try LegacyFixture.data("LegacyContainer-ShowTrackPreferences-track.json")
        let off = try LegacyFixture.data("LegacyContainer-ShowTrackPreferences-off.json")
        try LegacyFixture.withScratchDefaults { defaults in
            defaults.set(track, forKey: "ShowTrackPreferences.v1.16:4f2a9c1d7e3b5a6040:a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e94:2000")
            defaults.set(off, forKey: "ShowTrackPreferences.v1.15:plex-home-2460140:b7c9e1f3a5d7b9c1e3f5a7c9e1b3d5f7a9c1e3f54:2000")
            let store = ShowTrackPreferenceStore(defaults: defaults)
            let ownerScope = try #require(ShowTrackPreferenceStore.Scope(
                profileID: "4f2a9c1d7e3b5a60", serverID: "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9", details: details
            ))
            let kidScope = try #require(ShowTrackPreferenceStore.Scope(
                profileID: "plex-home-24601", serverID: "b7c9e1f3a5d7b9c1e3f5a7c9e1b3d5f7a9c1e3f5", details: details
            ))

            let owner = try #require(store.preferences(for: ownerScope))
            let audio = try #require(owner.audio)
            #expect(audio.language == "ja")
            #expect(audio.forced == false)
            #expect(audio.hearingImpaired == false)
            #expect(audio.commentary == false)
            #expect(audio.descriptive == false)
            #expect(audio.codec == "truehd")
            #expect(audio.channels == 8)
            #expect(audio.external == nil)
            guard case let .track(subtitle) = owner.subtitles else {
                Issue.record("Expected a remembered subtitle track, got \(String(describing: owner.subtitles))")
                return
            }
            #expect(subtitle.language == "en")
            #expect(subtitle.forced == false)
            #expect(subtitle.hearingImpaired == true)
            #expect(subtitle.commentary == false)
            #expect(subtitle.descriptive == false)
            #expect(subtitle.codec == "srt")
            #expect(subtitle.channels == nil)
            #expect(subtitle.external == true)

            let kid = try #require(store.preferences(for: kidScope))
            #expect(kid.audio == nil)
            #expect(kid.subtitles == .off)

            store.save(owner, for: ownerScope)
            store.save(kid, for: kidScope)
            try LegacyFixture.expectSameJSON(defaults.data(forKey: ownerScope.storageKey), track)
            try LegacyFixture.expectSameJSON(defaults.data(forKey: kidScope.storageKey), off)
        }
    }

    @Test func serverPriorityDecodesAndReEncodes() throws {
        let fixture = try LegacyFixture.data("LegacyContainer-PlexServerPriority.json")
        try LegacyFixture.withScratchDefaults { defaults in
            defaults.set(fixture, forKey: "PlexServerPriority")
            let store = ServerPriorityStore(defaults: defaults)
            #expect(store.entries == [
                ServerPriorityStore.Entry(machineIdentifier: "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9", isEnabled: true),
                ServerPriorityStore.Entry(machineIdentifier: "b7c9e1f3a5d7b9c1e3f5a7c9e1b3d5f7a9c1e3f5", isEnabled: false),
            ])
            #expect(store.enabledIdentifiers == ["a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9"])

            // Toggle and toggle back: two commits through the store, ending on
            // the decoded state.
            store.setEnabled(true, for: "b7c9e1f3a5d7b9c1e3f5a7c9e1b3d5f7a9c1e3f5")
            store.setEnabled(false, for: "b7c9e1f3a5d7b9c1e3f5a7c9e1b3d5f7a9c1e3f5")
            try LegacyFixture.expectSameJSON(defaults.data(forKey: "PlexServerPriority"), fixture)
        }
    }

    @Test func legacySingleServerSelectionSeedsThePriority() throws {
        try LegacyFixture.withScratchDefaults { defaults in
            defaults.set("a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9", forKey: "PlexServerID")
            let store = ServerPriorityStore(defaults: defaults)
            #expect(store.entries == [
                ServerPriorityStore.Entry(machineIdentifier: "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9", isEnabled: true),
            ])
        }
    }

    @Test func serverSnapshotsDecodeFromTheirDefaultsKey() throws {
        let fixture = try LegacyFixture.data("LegacyContainer-PlexServerSnapshots.json")
        let servers = LegacyFixture.withStandardDefault("PlexServerSnapshots", set: fixture) {
            ServerPool.storedSnapshots()
        }
        try #require(servers.count == 2)

        #expect(servers[0].name == "Living Room")
        #expect(servers[0].clientIdentifier == "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9")
        #expect(servers[0].product == "Plex Media Server")
        #expect(servers[0].productVersion == "1.41.3.9314")
        #expect(servers[0].platform == "Linux")
        #expect(servers[0].platformVersion == "6.1")
        #expect(servers[0].provides == "server")
        #expect(servers[0].owned == true)
        #expect(servers[0].presence == true)
        #expect(servers[0].accessToken == nil)
        #expect(servers[0].sourceTitle == nil)
        try #require(servers[0].connections.count == 2)
        #expect(servers[0].connections[0] == PlexConnection(
            protocol: "https", address: "192.168.1.10", port: 32400,
            uri: "https://192-168-1-10.0123456789abcdef.plex.direct:32400",
            local: true, relay: false, iPv6: false
        ))
        #expect(servers[0].connections[1].uri == "https://203-0-113-7.0123456789abcdef.plex.direct:32400")
        #expect(servers[0].connections[1].local == false)

        #expect(servers[1].name == "Friend's Server")
        #expect(servers[1].clientIdentifier == "b7c9e1f3a5d7b9c1e3f5a7c9e1b3d5f7a9c1e3f5")
        #expect(servers[1].product == nil)
        #expect(servers[1].owned == false)
        #expect(servers[1].presence == false)
        #expect(servers[1].sourceTitle == "friend")
        try #require(servers[1].connections.count == 1)
        #expect(servers[1].connections[0] == PlexConnection(
            protocol: "https", address: "198.51.100.4", port: 443,
            uri: "https://relay.plex.direct:443", local: false, relay: true, iPv6: nil
        ))

        // `ServerPool.saveSnapshots` encodes `servers.map(\.withoutAccessToken)`.
        try LegacyFixture.expectSameJSON(try JSONEncoder().encode(servers.map(\.withoutAccessToken)), fixture)
    }

    @Test func pre_KeychainServerSnapshotStillDecodesItsToken() throws {
        // Older builds kept `accessToken` inside the snapshot; bootstrap
        // migrates it, so it must still decode.
        let legacy = Data(#"""
            [{"name":"Old","clientIdentifier":"a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9","accessToken":"legacy-token",
              "connections":[{"protocol":"http","address":"10.0.0.2","port":32400,"uri":"http://10.0.0.2:32400","local":true,"relay":false}]}]
            """#.utf8)
        let servers = LegacyFixture.withStandardDefault("PlexServerSnapshots", set: legacy) {
            ServerPool.storedSnapshots()
        }
        try #require(servers.count == 1)
        #expect(servers[0].usableAccessToken == "legacy-token")
        #expect(servers[0].owned == false)
        #expect(servers[0].presence == false)
        #expect(servers[0].connections[0].iPv6 == nil)
    }

    @Test func activeHomeUserDecodesAtLaunch() throws {
        let fixture = try LegacyFixture.data("LegacyContainer-PlexActiveHomeUserData.json")
        let user = LegacyFixture.withStandardDefault("PlexActiveHomeUserData", set: fixture) {
            let service = PlexService()
            defer {
                service.session.invalidateAndCancel()
                service.slowQuerySession.invalidateAndCancel()
                service.probeSession.invalidateAndCancel()
                service.bootstrapSession.invalidateAndCancel()
            }
            return service.activeHomeUser
        }
        let decoded = try #require(user)
        #expect(decoded.id == 24601)
        #expect(decoded.uuid == "c1d2e3f4a5b60789")
        #expect(decoded.username == "kid")
        #expect(decoded.title == "Kid")
        #expect(decoded.friendlyName == "Kiddo")
        #expect(decoded.thumb == "https://plex.tv/users/c1d2e3f4a5b60789/avatar")
        #expect(decoded.isProtected == true)
        #expect(decoded.isRestricted == true)
        #expect(decoded.isAdmin == false)
        #expect(decoded.isGuest == false)
        #expect(decoded.stableProfileID == "c1d2e3f4a5b60789")
        try LegacyFixture.expectSameJSON(try JSONEncoder().encode(decoded), fixture)
    }

    @Test func iptvSourcesAndHeaderSecretsDecodeAndReEncode() throws {
        let sourcesFixture = try LegacyFixture.data("LegacyContainer-IPTVSources.json")
        let secretsFixture = try LegacyFixture.data("LegacyContainer-IPTVSourceHeaderValues.json")
        let secret = MemorySecret(secretsFixture)
        try LegacyFixture.withScratchDefaults { defaults in
            defaults.set(sourcesFixture, forKey: "IPTVSources.4f2a9c1d7e3b5a60")
            let store = IPTVSourceStore(defaults: defaults, secrets: secret.storage)
            let sources = store.sources(profileID: "4f2a9c1d7e3b5a60")
            try #require(sources.count == 2)
            #expect(sources[0].id == UUID(uuidString: "6B1E6C0A-3F2D-4C8B-9E7A-1D2C3B4A5F60"))
            #expect(sources[0].name == "Freeview")
            #expect(sources[0].playlistURL.absoluteString == "https://iptv.example.com/freeview.m3u")
            #expect(sources[0].guideURL?.absoluteString == "https://iptv.example.com/epg.xml.gz")
            #expect(sources[0].headerName == "Authorization")
            #expect(sources[1].id == UUID(uuidString: "0F9E8D7C-6B5A-4938-A7B6-C5D4E3F2A1B0"))
            #expect(sources[1].name == "Panel")
            #expect(sources[1].playlistURL.absoluteString
                == "http://panel.example:8080/get.php?username=alice&password=secret&type=m3u_plus&output=ts")
            #expect(sources[1].guideURL == nil)
            #expect(sources[1].headerName == nil)
            #expect(store.sources(profileID: "plex-home-24601").isEmpty)

            let headerID = try #require(UUID(uuidString: "6B1E6C0A-3F2D-4C8B-9E7A-1D2C3B4A5F60"))
            #expect(store.headerValue(for: headerID) == "Bearer abc123")

            store.save(sources, profileID: "4f2a9c1d7e3b5a60")
            store.setHeaderValue("Bearer abc123", for: headerID)
            try LegacyFixture.expectSameJSON(defaults.data(forKey: "IPTVSources.4f2a9c1d7e3b5a60"), sourcesFixture)
            try LegacyFixture.expectSameJSON(secret.data, secretsFixture)
        }
    }

    @Test func iptvResumePointsDecodeAndReEncode() throws {
        let fixture = try LegacyFixture.data("LegacyContainer-iptvResumePoints.json")
        try LegacyFixture.withScratchDefaults { defaults in
            defaults.set(fixture, forKey: "iptvResumePoints")
            // One hour after the recording: nothing is old enough to prune.
            let store = IPTVResumeStore(
                defaults: defaults, cloud: nil,
                now: { Date(timeIntervalSinceReferenceDate: 800_003_600) }
            )
            #expect(store.entries.count == 2)
            let watching = try #require(store.entries["a215b090b585a805b419473b0877022a"])
            #expect(watching.position == 1234.5)
            #expect(watching.duration == 3600)
            #expect(watching.updatedAt == Date(timeIntervalSinceReferenceDate: 800_000_000))
            let finished = try #require(store.entries["b4f03502a47fcfe1209f274e1e714f14"])
            #expect(finished.position == nil)
            #expect(finished.duration == 3600)

            #expect(store.resumePosition(for: IPTVResumeKey(rawValue: "a215b090b585a805b419473b0877022a")) == 1234.5)
            #expect(store.resumePosition(for: IPTVResumeKey(rawValue: "b4f03502a47fcfe1209f274e1e714f14")) == nil)

            // `IPTVResumeStore.persist` encodes `entries` with a plain `JSONEncoder()`.
            try LegacyFixture.expectSameJSON(try JSONEncoder().encode(store.entries), fixture)
        }
    }

    @Test func traktHistoryQueueDecodesAndReEncodes() throws {
        let fixture = try LegacyFixture.data("LegacyContainer-TraktPendingHistory.json")
        try LegacyFixture.withScratchDefaults { defaults in
            defaults.set(fixture, forKey: "TraktPendingHistory")
            let queue = TraktHistoryQueue(defaults: defaults)
            let entries = queue.load()
            try #require(entries.count == 1)
            #expect(entries[0].kind == .episode)
            #expect(entries[0].kind.rawValue == "episode")
            #expect(entries[0].ids == TraktIDs(imdb: "tt11280740", tmdb: 95396, tvdb: 371980))
            #expect(entries[0].season == 1)
            #expect(entries[0].episode == 1)
            #expect(entries[0].watchedAt == Date(timeIntervalSinceReferenceDate: 800_003_600))
            #expect(entries[0].profileID == "4f2a9c1d7e3b5a60")
            #expect(entries[0].attempts == 2)
            #expect(entries[0].id == UUID(uuidString: "11111111-2222-4333-8444-555555555555"))

            queue.save(entries)
            try LegacyFixture.expectSameJSON(defaults.data(forKey: "TraktPendingHistory"), fixture)
        }
    }

    // MARK: - Keychain payloads

    @Test func traktAccountsDecodeFromTheirKeychainItem() throws {
        try #require(LegacyFixture.keychainIsAvailable, "Keychain unavailable to the test host")
        let fixture = try LegacyFixture.data("LegacyContainer-TraktAccounts.json")
        try LegacyFixture.preservingKeychainItem("TraktAccounts") {
            KeychainHelper.save(key: "TraktAccounts", data: fixture)
            let accounts = TraktCredentialStore.load()
            try #require(accounts.count == 2)
            let owner = try #require(accounts["4f2a9c1d7e3b5a60"])
            #expect(owner.accessToken == "trakt-access-owner")
            #expect(owner.refreshToken == "trakt-refresh-owner")
            #expect(owner.expiresAt == Date(timeIntervalSinceReferenceDate: 800_086_400))
            #expect(owner.username == "alice")
            #expect(owner.redirectURI == nil)
            let kid = try #require(accounts["plex-home-24601"])
            #expect(kid.accessToken == "trakt-access-kid")
            #expect(kid.refreshToken == "trakt-refresh-kid")
            #expect(kid.expiresAt == Date(timeIntervalSinceReferenceDate: 800_003_600))
            #expect(kid.username == nil)
            #expect(kid.redirectURI == "dusk://trakt/callback")

            TraktCredentialStore.save(accounts)
            try LegacyFixture.expectSameJSON(LegacyFixture.keychainData(account: "TraktAccounts"), fixture)
        }
    }

    @Test func seerrSessionsDecodeFromTheirKeychainItem() throws {
        try #require(LegacyFixture.keychainIsAvailable, "Keychain unavailable to the test host")
        let fixture = try LegacyFixture.data("LegacyContainer-SeerrSessions.json")
        try LegacyFixture.preservingKeychainItem("SeerrSessions") {
            KeychainHelper.save(key: "SeerrSessions", data: fixture)
            let sessions = SeerrCredentialStore.load()
            #expect(sessions == [
                SeerrStoredSession(
                    baseURL: "https://seerr.example.com",
                    profileID: "4f2a9c1d7e3b5a60",
                    serverID: "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9",
                    cookies: ["connect.sid": "s%3Aabc.def"]
                ),
            ])

            SeerrCredentialStore.save(sessions)
            try LegacyFixture.expectSameJSON(LegacyFixture.keychainData(account: "SeerrSessions"), fixture)
        }
    }

    // MARK: - Cross-process payloads

    @Test func siriCatalogEntriesDecodeAndReEncode() throws {
        let fixture = try LegacyFixture.data("LegacyContainer-SiriCatalogEntries.json")
        let entries = try JSONDecoder().decode([SiriCatalogEntry].self, from: fixture)
        #expect(entries == [
            SiriCatalogEntry(
                id: MediaItemID(serverID: "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9", itemID: "1001"),
                kind: .movie, title: "Arrival", year: 2016, lastPlayedAt: 1_767_225_600
            ),
            SiriCatalogEntry(
                id: MediaItemID(serverID: "b7c9e1f3a5d7b9c1e3f5a7c9e1b3d5f7a9c1e3f5", itemID: "2000"),
                kind: .show, title: "Severance", year: nil, lastPlayedAt: nil
            ),
        ])
        #expect(entries.map { PlexTitleEntity($0).id } == [
            "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9|1001",
            "b7c9e1f3a5d7b9c1e3f5a7c9e1b3d5f7a9c1e3f5|2000",
        ])
        try LegacyFixture.expectSameJSON(try JSONEncoder().encode(entries), fixture)
    }

    @Test func watchTogetherActivityDecodesAndReEncodes() throws {
        let fixture = try LegacyFixture.data("LegacyContainer-WatchTogetherActivity.json")
        let activity = try JSONDecoder().decode(DuskWatchTogetherActivity.self, from: fixture)
        #expect(activity == DuskWatchTogetherActivity(
            serverIdentifier: "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9",
            itemID: "1001",
            title: "Arrival",
            subtitle: nil
        ))
        #expect(activity.playbackItemIdentifier == "plex://a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9/metadata/1001")
        try LegacyFixture.expectSameJSON(try JSONEncoder().encode(activity), fixture)
    }

    #if os(tvOS)
    @Test func topShelfSnapshotDecodesAndReEncodes() throws {
        let fixture = try LegacyFixture.data("LegacyContainer-TopShelfSnapshot.json")
        let snapshot = try JSONDecoder().decode(TopShelfSnapshot.self, from: fixture)
        try #require(snapshot.sections.count == 2)
        #expect(snapshot.sections[0].title == "Continue Watching")
        try #require(snapshot.sections[0].items.count == 1)
        let movie = snapshot.sections[0].items[0]
        #expect(movie.id == "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9|1001")
        #expect(movie.title == "Arrival")
        #expect(movie.imageFileName == "a3d5-1001.jpg")
        #expect(movie.isLandscape == false)
        #expect(movie.progress == 0.25)
        #expect(movie.playURL.absoluteString
            == "dusk://play?server=a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9&item=1001&type=movie")
        #expect(movie.displayURL.absoluteString
            == "dusk://open?server=a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9&item=1001&type=movie")

        #expect(snapshot.sections[1].title == "Recently Added in Home Videos")
        try #require(snapshot.sections[1].items.count == 1)
        let clip = snapshot.sections[1].items[0]
        #expect(clip.id == "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9|4001")
        #expect(clip.isLandscape == true)
        #expect(clip.progress == nil)
        #expect(clip.playURL.absoluteString
            == "dusk://play?server=a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9&item=4001&type=movie&clip=1")
        #expect(clip.displayURL.absoluteString
            == "dusk://open?server=a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9&item=4001&type=movie&clip=1")

        let link = try #require(TopShelfLink(url: clip.playURL))
        #expect(link.action == .play)
        #expect(link.id == MediaItemID(serverID: "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9", itemID: "4001"))
        #expect(link.type == .movie)
        #expect(link.isClip == true)

        try LegacyFixture.expectSameJSON(try JSONEncoder().encode(snapshot), fixture)
    }
    #endif
}
