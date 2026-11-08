#if os(tvOS)
import CoreImage
import CryptoKit
import Foundation
import OSLog
import TVServices

private let topShelfLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "TopShelf"
)

/// Mirrors Home's Continue Watching and Recently Added rows into the Top Shelf
/// snapshot.
///
/// Home calls `publish` every time its rows change; this writes
/// `TopShelfSnapshot` plus the artwork into the App Group container and asks
/// tvOS to reload the Top Shelf. It only uses what Home already fetched: the
/// one Plex request of its own is each tile's artwork, made off the main actor
/// and skipped when the file is already cached. Artwork is stored as plain
/// files, so the extension never needs a token. `clear` runs whenever the signed-in identity goes away (sign-out,
/// Plex Home switch): the shelf must never show the previous profile's items.
@MainActor
final class TopShelfPublisher {
    static let shared = TopShelfPublisher()

    /// One Home row, as Home shows it: in order, hidden items already gone.
    struct Row {
        let title: String
        let items: [PlexItem]
    }

    /// Per section. Every tile is a cached image, so these also bound the
    /// artwork requests and the size of the cache.
    private static let itemLimit = 10
    /// Recently Added sections after Continue Watching. Home's rows arrive in
    /// Library Order, so these are the libraries the account ranks first.
    private static let recentlyAddedRowLimit = 3

    /// What was last written, so Home's repeated publishes of the same rows
    /// (tab returns, refreshes) do not rewrite files or reload the shelf.
    private var publishedSignature: [String]?
    private var writeTask: Task<Void, Never>?

    func publish(continueWatching: [PlexItem], recentlyAdded: [Row], plexService: PlexService) {
        let sections = Self.sections(
            continueWatching: continueWatching,
            recentlyAdded: recentlyAdded,
            plexService: plexService
        )
        let signature = sections.flatMap { section in
            ["# \(section.title)"] + section.entries.map(\.signature)
        }
        // The snapshot lives in Caches, so it can be purged under a running app.
        let snapshotExists = TopShelfStore.snapshotURL.map {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        } ?? false
        guard signature != publishedSignature || !snapshotExists else { return }
        publishedSignature = signature

        writeTask?.cancel()
        // Detached: file I/O and the spoiler blur stay off the main actor.
        writeTask = Task.detached(priority: .utility) {
            await Self.write(sections, plexService: plexService)
        }
    }

    func clear() {
        writeTask?.cancel()
        writeTask = nil
        publishedSignature = nil

        guard let directory = TopShelfStore.directory,
              FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    /// Continue Watching first, then the Recently Added rows. An item shows
    /// once, in the first section that has it: tvOS tracks focus by identifier,
    /// and a new film someone already started would otherwise fill two tiles.
    private static func sections(
        continueWatching: [PlexItem],
        recentlyAdded: [Row],
        plexService: PlexService
    ) -> [Section] {
        var seen: Set<String> = []
        var sections: [Section] = []

        func appendSection(title: String, items: [PlexItem]) -> Bool {
            var entries: [Entry] = []
            for item in items where entries.count < itemLimit {
                guard !seen.contains(item.id.storageKey),
                      let entry = Entry(item: item, plexService: plexService) else { continue }
                seen.insert(item.id.storageKey)
                entries.append(entry)
            }
            guard !entries.isEmpty else { return false }
            sections.append(Section(title: title, entries: entries))
            return true
        }

        _ = appendSection(title: "Continue Watching", items: continueWatching)

        var recentlyAddedCount = 0
        for row in recentlyAdded where recentlyAddedCount < recentlyAddedRowLimit {
            if appendSection(title: row.title, items: row.items) {
                recentlyAddedCount += 1
            }
        }
        return sections
    }

    private nonisolated static func write(_ sections: [Section], plexService: PlexService) async {
        guard let imagesDirectory = TopShelfStore.imagesDirectory,
              let snapshotURL = TopShelfStore.snapshotURL else {
            topShelfLogger.error("App Group container unavailable; Top Shelf not updated")
            return
        }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        } catch {
            topShelfLogger.error("Could not create the Top Shelf directory: \(error.localizedDescription, privacy: .public)")
            return
        }

        // A tile without artwork is an empty rectangle on the Home Screen, so
        // an item whose image cannot be fetched is left out.
        var cached: Set<String> = []
        for entry in sections.flatMap(\.entries) {
            let fileURL = imagesDirectory.appending(path: entry.imageFileName, directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) {
                cached.insert(entry.imageFileName)
                continue
            }

            do {
                var data = try await artwork(for: entry, plexService: plexService)
                guard !Task.isCancelled else { return }
                if entry.blursImage {
                    guard let blurred = spoilerBlurred(data) else { continue }
                    data = blurred
                }
                try data.write(to: fileURL, options: .atomic)
                cached.insert(entry.imageFileName)
            } catch {
                guard !Task.isCancelled else { return }
                topShelfLogger.error("Top Shelf artwork failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard !Task.isCancelled else { return }

        let snapshot = TopShelfSnapshot(sections: sections.compactMap { section in
            let items = section.entries.filter { cached.contains($0.imageFileName) }.map(\.item)
            return items.isEmpty ? nil : TopShelfSnapshot.Section(title: section.title, items: items)
        })
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: snapshotURL, options: .atomic)
        } catch {
            topShelfLogger.error("Could not write the Top Shelf snapshot: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Artwork for items that left the shelf.
        let files = (try? fileManager.contentsOfDirectory(atPath: imagesDirectory.path(percentEncoded: false))) ?? []
        for file in files where !cached.contains(file) {
            try? fileManager.removeItem(at: imagesDirectory.appending(path: file, directoryHint: .notDirectory))
        }

        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    /// The tile's artwork, or the show's poster for a season whose own poster
    /// Plex lists but cannot serve (same stand-in as Home's poster cards).
    private nonisolated static func artwork(for entry: Entry, plexService: PlexService) async throws -> Data {
        do {
            return try await plexService.imageData(for: entry.imageURL)
        } catch {
            guard !Task.isCancelled, let fallbackImageURL = entry.fallbackImageURL else { throw error }
            return try await plexService.imageData(for: fallbackImageURL)
        }
    }

    /// Blur Unwatched Episodes for a tile: the shelf draws plain files, so
    /// the blur is baked into the JPEG. Same strength as the in-app blur
    /// (`spoilerBlur`, 12 % of the short side). nil drops the tile rather
    /// than show the still sharp.
    private nonisolated static func spoilerBlurred(_ data: Data) -> Data? {
        guard let image = CIImage(data: data) else { return nil }
        let radius = min(image.extent.width, image.extent.height) * 0.12
        let blurred = image
            .clampedToExtent()
            .applyingGaussianBlur(sigma: radius / 2)
            .cropped(to: image.extent)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CIContext().jpegRepresentation(of: blurred, colorSpace: colorSpace)
    }

}

private extension TopShelfPublisher {
    struct Section: Sendable {
        let title: String
        let entries: [Entry]
    }

    struct Entry: Sendable {
        let item: TopShelfSnapshot.Item
        /// Authenticated Plex URLs; only ever used by the app.
        let imageURL: URL
        let fallbackImageURL: URL?
        /// The image is an unwatched episode's own still and Blur Unwatched
        /// Episodes is on.
        let blursImage: Bool
        let signature: String

        var imageFileName: String { item.imageFileName }

        @MainActor
        init?(item: PlexItem, plexService: PlexService) {
            // The focused tile in points, poster or 16:9. `imageURL` scales for
            // the screen, and Plex never upscales.
            let (imagePath, width, height) = item.isClip
                ? (item.preferredLandscapePath, 640, 360)
                : (item.preferredPosterPath, 380, 570)
            guard let imagePath,
                  let imageURL = plexService.imageURL(
                      for: imagePath,
                      serverID: item.serverID,
                      width: width,
                      height: height
                  ),
                  let displayURL = TopShelfLink.url(.open, for: item),
                  let playURL = Self.isPlayable(item) ? TopShelfLink.url(.play, for: item) : displayURL else {
                return nil
            }

            // Plex art paths carry a timestamp, so new artwork means a new file
            // name and tvOS never shows a stale image cached under an old URL.
            // An unwatched episode's still only shows here when the show has
            // no poster; with Blur Unwatched Episodes on it is a separate,
            // blurred file, so toggling the setting never reuses the sharp one.
            let blursImage = UserPreferences.storedBlursUnwatchedEpisodes
                && item.isUnwatchedEpisode
                && imagePath == item.thumb
            let imageKey = "\(item.serverID ?? "")|\(imagePath)|\(width)x\(height)"
                + (blursImage ? "|blur" : "")
            let imageFileName = SHA256.hash(data: Data(imageKey.utf8))
                .prefix(16)
                .map { String(format: "%02x", $0) }
                .joined() + ".jpg"

            let progress = item.posterProgress.flatMap { $0 > 0 ? min($0, 1) : nil }
            self.item = TopShelfSnapshot.Item(
                id: item.id.storageKey,
                title: Self.title(for: item),
                imageFileName: imageFileName,
                isLandscape: item.isClip,
                progress: progress,
                playURL: playURL,
                displayURL: displayURL
            )
            self.imageURL = imageURL
            self.fallbackImageURL = plexService.imageURL(
                for: item.fallbackPosterPath,
                serverID: item.serverID,
                width: width,
                height: height
            )
            self.blursImage = blursImage
            self.signature = [
                self.item.id,
                self.item.title,
                imageFileName,
                progress.map { String(format: "%.3f", $0) } ?? "-",
            ].joined(separator: "|")
        }

        /// A show or season has nothing to resume, so Play opens its page too.
        private static func isPlayable(_ item: PlexItem) -> Bool {
            switch item.type {
            case .show, .season: false
            default: true
            }
        }

        /// "Show · S2 E3" for an episode, "Show · Season 2" for a season, the
        /// plain title otherwise.
        private static func title(for item: PlexItem) -> String {
            let title = item.continueWatchingDisplayTitle
            if item.type == .season, let show = item.parentTitle?.nilIfEmpty {
                return "\(show) · \(title)"
            }
            guard item.type == .episode,
                  let season = item.parentIndex,
                  let episode = item.index else {
                return title
            }
            return "\(title) · S\(season) E\(episode)"
        }
    }
}
#endif
