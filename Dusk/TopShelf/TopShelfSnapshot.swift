import Foundation

/// Shared constants describing the App Group container that the main app and the
/// tvOS Top Shelf extension use to exchange the "Continue Watching" snapshot.
///
/// The extension runs in its own sandboxed process and never talks to Plex. The
/// app produces a snapshot and drops it in the shared container; the extension
/// only reads and renders it. Keep this file free of app-only dependencies so it
/// compiles into both the app target and the extension target.
enum TopShelfSharedContainer {
    static let appGroupIdentifier = "group.com.dusk-player.app"
    static let snapshotFileName = "continue-watching.json"
}

/// One resumable item rendered in the tvOS Top Shelf "Continue Watching" shelf.
///
/// All values are precomputed by the app: `imageURLString` already embeds the
/// Plex token so the system can fetch it without any auth headers, and
/// `actionURLString` is a ready-to-open `dusk://` deep link.
struct TopShelfEntry: Codable, Sendable, Identifiable {
    var id: String { ratingKey }

    let ratingKey: String
    let mediaType: String
    let title: String
    let subtitle: String?
    let imageURLString: String?
    let playbackProgress: Double?
    let actionURLString: String
}

/// A point-in-time snapshot of the "Continue Watching" shelf, written by the app
/// and read by the Top Shelf extension.
struct TopShelfSnapshot: Codable, Sendable {
    let generatedAt: Date
    let serverIdentifier: String?
    let entries: [TopShelfEntry]
}

/// Reads and writes the Top Shelf snapshot in the shared App Group container.
///
/// Used by the app (writer) and the extension (reader). All operations fail
/// softly: a missing container, decode error, or write error simply yields
/// `nil`/`false` rather than throwing, because neither side can recover beyond
/// "show nothing".
enum TopShelfSnapshotStore {
    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: TopShelfSharedContainer.appGroupIdentifier)?
            .appendingPathComponent(TopShelfSharedContainer.snapshotFileName)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func load() -> TopShelfSnapshot? {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? makeDecoder().decode(TopShelfSnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: TopShelfSnapshot) -> Bool {
        guard let fileURL,
              let data = try? makeEncoder().encode(snapshot) else {
            return false
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func clear() -> Bool {
        guard let fileURL else { return false }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                return false
            }
        }
        return true
    }
}
