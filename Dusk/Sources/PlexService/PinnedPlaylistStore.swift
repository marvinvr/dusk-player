import SwiftUI

/// The playlists pinned to Home, per Plex profile, in pin order (oldest
/// first). Device-local like the other Home settings: Plex has no concept of
/// a pinned playlist. Each pin carries its server (`PlexItemID`) and the
/// title it had, so Settings › Home can list pins without asking a server.
@MainActor
@Observable
final class PinnedPlaylistStore {
    struct Pin: Codable, Equatable, Identifiable, Sendable {
        let id: PlexItemID
        var title: String
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Bumped on every write so views reading `pins(profileID:)` update.
    private var revision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func pins(profileID: String?) -> [Pin] {
        _ = revision
        guard let key = Self.storageKey(profileID),
              let data = defaults.data(forKey: key),
              let pins = try? JSONDecoder().decode([Pin].self, from: data) else { return [] }
        return pins
    }

    func isPinned(_ id: PlexItemID, profileID: String?) -> Bool {
        pins(profileID: profileID).contains { $0.id == id }
    }

    func pin(_ id: PlexItemID, title: String, profileID: String?) {
        var pins = pins(profileID: profileID)
        guard !pins.contains(where: { $0.id == id }) else { return }
        pins.append(Pin(id: id, title: title))
        save(pins, profileID: profileID)
    }

    func unpin(_ id: PlexItemID, profileID: String?) {
        var pins = pins(profileID: profileID)
        pins.removeAll { $0.id == id }
        save(pins, profileID: profileID)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int, profileID: String?) {
        var pins = pins(profileID: profileID)
        pins.move(fromOffsets: source, toOffset: destination)
        save(pins, profileID: profileID)
    }

    /// Keeps the Settings list in step with a rename seen on Home.
    func updateTitle(_ title: String, for id: PlexItemID, profileID: String?) {
        var pins = pins(profileID: profileID)
        guard let index = pins.firstIndex(where: { $0.id == id }), pins[index].title != title else { return }
        pins[index].title = title
        save(pins, profileID: profileID)
    }

    private func save(_ pins: [Pin], profileID: String?) {
        guard let key = Self.storageKey(profileID) else { return }
        if pins.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(pins) {
            defaults.set(data, forKey: key)
        }
        revision += 1
    }

    /// No profile, no pins: a Home switch never inherits another member's.
    static func storageKey(_ profileID: String?) -> String? {
        guard let profileID, !profileID.isEmpty else { return nil }
        return "PinnedHomePlaylists.v1.\(profileID)"
    }
}

extension PlexService {
    var pinnedPlaylistPins: [PinnedPlaylistStore.Pin] {
        pinnedPlaylists.pins(profileID: activeProfileID)
    }

    func isPlaylistPinned(_ id: PlexItemID) -> Bool {
        pinnedPlaylists.isPinned(id, profileID: activeProfileID)
    }

    func setPlaylistPinned(_ pinned: Bool, id: PlexItemID, title: String) {
        if pinned {
            pinnedPlaylists.pin(id, title: title, profileID: activeProfileID)
        } else {
            pinnedPlaylists.unpin(id, profileID: activeProfileID)
        }
    }
}
