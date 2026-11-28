import Foundation
import Testing
@testable import Dusk

/// J-10 against a real Jellyfin server, gated like `JellyfinLiveTests`
/// (`TEST_RUNNER_DUSK_JELLYFIN_LIVE_*`). Read-only: it signs in with its own
/// throw-away `DeviceId`, walks the Photos library and logs out. Expectations
/// are the jellyfin-demo test data (docs/jellyfin/05-plan.md T-0), which
/// plex-demo holds in the same order.
@MainActor
@Suite("Jellyfin photos live", .serialized, .enabled(if: JellyfinLiveConfig.current != nil, "no live server configured"))
struct JellyfinPhotosLiveTests {
    @Test(.timeLimit(.minutes(2)))
    func photosAgainstLiveServer() async throws {
        let config = try #require(JellyfinLiveConfig.current)
        let password = try String(contentsOfFile: config.passwordFile, encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        let identity = JellyfinClientIdentity(
            device: "Dusk Tests", deviceID: "dusk-tests-\(UUID().uuidString.prefix(8).lowercased())", version: "0.0-test")
        let anonymous = JellyfinClient(baseURL: config.url, identity: identity)
        let auth = try await anonymous.send(JellyfinAPI.authenticateByName(username: config.user, password: password))
        let client = anonymous.signedIn(JellyfinCredentials(accessToken: auth.accessToken, userID: auth.user.id))
        let catalog = JellyfinCatalog(serverID: auth.serverID ?? "", client: { client })
        do {
            try await exercise(catalog)
        } catch {
            _ = try? await client.send(JellyfinAPI.logout())
            throw error
        }
        _ = try await client.send(JellyfinAPI.logout())
    }

    private func exercise(_ catalog: JellyfinCatalog) async throws {
        let photos = try #require(try await catalog.libraries().first { $0.title == "Photos" })
        #expect(photos.libraryType == .photo)

        // Root: the albums and the `2026` folder, no loose photos.
        let root = try await catalog.photoPage(libraryID: photos.key, query: .albums(parent: nil), start: 0, size: 60)
        #expect(root.items.map(\.title) == ["2025 Summer Trip", "2026", "City Walks", "Family", "Loose", "Metadata Test", "Nature"])
        #expect(root.items.allSatisfy { $0.isAlbum && $0.thumb != nil })
        #expect(root.totalSize == 7)
        let rootMedia = try await catalog.photoPage(libraryID: photos.key, query: .media(parent: nil), start: 0, size: 60)
        #expect(rootMedia.items.isEmpty)

        // A plain folder holds albums only.
        let folder = try #require(root.items.first { $0.title == "2026" })
        let nested = try await catalog.photoPage(libraryID: photos.key, query: .albums(parent: folder.itemID), start: 0, size: 60)
        #expect(nested.items.map(\.title) == ["Birthday", "Ski Weekend"])
        let folderMedia = try await catalog.photoPage(libraryID: photos.key, query: .media(parent: folder.itemID), start: 0, size: 60)
        #expect(folderMedia.items.isEmpty)

        // An album in Plex's order, with EXIF dates and the clip in place.
        let metadata = try #require(root.items.first { $0.title == "Metadata Test" })
        let media = try await catalog.photoPage(libraryID: photos.key, query: .media(parent: metadata.itemID), start: 0, size: 60)
        #expect(media.items.map(\.title) == [
            "EXIF_2025-08-03_01", "EXIF_2025-08-21_02", "EXIF_2025-09-07_03", "Rotated_Orientation6",
            "EXIF_2025-09-28_04", "Clip_2025-10-05", "EXIF_2025-10-11_05", "EXIF_2025-10-30_06",
        ])
        #expect(media.items.map(\.originallyAvailableAt) == [
            "2025-08-03", "2025-08-21", "2025-09-07", "2025-09-14", "2025-09-28", "2025-10-05", "2025-10-11", "2025-10-30",
        ])
        let clip = try #require(media.items.first { $0.title == "Clip_2025-10-05" })
        #expect(clip.isClip && clip.duration == 8000)

        // Paging walks the album without repeats.
        var paged: [String] = []
        for start in stride(from: 0, to: 8, by: 3) {
            paged += try await catalog.photoPage(
                libraryID: photos.key, query: .media(parent: metadata.itemID), start: start, size: 3
            ).items.map(\.title)
        }
        #expect(paged == media.items.map(\.title))

        // Timeline: every photo and clip, newest file date first.
        let timeline = try await catalog.photoPage(libraryID: photos.key, query: .timeline, start: 0, size: 150)
        #expect(timeline.totalSize == 200)
        #expect(timeline.items.count == 150)
        #expect(!timeline.items.contains { $0.isAlbum })
        #expect(timeline.items.prefix(4).map(\.title) == ["Clip_2025-10-05", "VID_0002", "VID_0001", "photo_7"])
    }
}
