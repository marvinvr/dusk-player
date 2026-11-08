#if os(tvOS)
import Foundation

/// What the tvOS Top Shelf shows, as handed from the app to the Top Shelf
/// extension through the shared App Group container.
///
/// This file is compiled into both the app and the `DuskTopShelf` extension.
/// The extension never talks to Plex: it has no token and no network access to
/// a server, only this snapshot and the artwork files the app cached next to
/// it. Titles, artwork file names and the deep links are all decided by the
/// app (see `TopShelfPublisher`).
struct TopShelfSnapshot: Codable, Sendable {
    struct Section: Codable, Sendable {
        var title: String
        var items: [Item]
    }

    struct Item: Codable, Sendable {
        /// Stable per item (`PlexItemID.storageKey`), so tvOS can keep focus
        /// on the same tile across updates.
        var id: String
        var title: String
        /// A file in `TopShelfStore.imagesDirectory`.
        var imageFileName: String
        /// A clip's 16:9 frame grab; everything else is a 2:3 poster.
        var isLandscape: Bool
        /// 0...1, nil for an item that has not been started.
        var progress: Double?
        var playURL: URL
        var displayURL: URL
    }

    var sections: [Section]
}

/// Where the snapshot and its artwork live in the App Group container.
enum TopShelfStore {
    static let appGroupIdentifier = "group.com.dusk-player.app"

    /// nil when the binary is not entitled to the App Group (e.g. a build
    /// signed with a profile that predates the capability).
    ///
    /// Must stay under `Library/Caches`: on an Apple TV that is the only
    /// writable place in the App Group container too (tvOS creates just
    /// `Library/Caches` and `Library/Preferences`, and any other path fails
    /// with a permission error). The simulator does not enforce this. The
    /// system may purge it; the app rewrites it on the next Home load.
    static var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appending(path: "Library/Caches/TopShelf", directoryHint: .isDirectory)
    }

    static var snapshotURL: URL? {
        directory?.appending(path: "snapshot.json", directoryHint: .notDirectory)
    }

    static var imagesDirectory: URL? {
        directory?.appending(path: "Images", directoryHint: .isDirectory)
    }

    static func loadSnapshot() -> TopShelfSnapshot? {
        guard let snapshotURL, let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode(TopShelfSnapshot.self, from: data)
    }
}
#endif
