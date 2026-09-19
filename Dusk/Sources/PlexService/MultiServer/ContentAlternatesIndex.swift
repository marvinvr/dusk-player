import Foundation

/// Side table of "these item instances are the same content".
///
/// The merge layers (Continue Watching, hubs, search) already resolve a
/// `PlexContentKey` for every item they look at and already know which copies
/// collapsed into the row the user sees. That knowledge is exactly what
/// playback needs later to fall back to another server, so instead of hanging
/// an `alternates` array off the decoded models — which would have to survive
/// every copy, cache and re-fetch — the merges deposit it here and playback
/// looks it up by `PlexItemID`.
///
/// The index only ever grows during a session: an item seen on server B an hour
/// ago is still a valid fallback for the same content on server A today, and
/// re-verifying it costs a request playback cannot afford. It is cleared when
/// the session identity changes (sign-out, Plex Home switch), because rating
/// keys are only meaningful for the account that fetched them.
@MainActor
@Observable
final class ContentAlternatesIndex {
    private var identifiersByKey: [PlexContentKey: [PlexItemID]] = [:]
    private var keysByIdentifier: [PlexItemID: PlexContentKey] = [:]

    /// Records that these item instances are the same content.
    ///
    /// Safe to call with a single id (the common case for an unmerged row) —
    /// it just teaches the index which content key that id belongs to, so a
    /// later sighting of the same content on another server links the two.
    ///
    /// Two rules keep playback honest, because sending someone to the wrong
    /// file is far worse than not offering a fallback at all:
    /// - only **strong** keys are recorded (a Plex or external id). A title/year
    ///   guess is good enough to collapse a row on screen, not to decide which
    ///   file to play.
    /// - at most one id per server and key. Two copies on one server are two
    ///   files; the one the user tapped is the one that plays, and the index
    ///   never offers the other in its place.
    func register(_ ids: [PlexItemID], for key: PlexContentKey) {
        guard key.isStrong, !ids.isEmpty else { return }

        var known = identifiersByKey[key] ?? []
        var changed = false

        for id in ids {
            // The same copy can be seen under a better key later (a row fetched
            // with `includeGuids=1` after one without). Move it rather than
            // leaving it listed under both.
            if let previous = keysByIdentifier[id], previous != key {
                remove(id, fromKey: previous)
            }
            if keysByIdentifier[id] != key {
                keysByIdentifier[id] = key
                changed = true
            }
            guard !known.contains(id),
                  !known.contains(where: { $0.serverID == id.serverID }) else { continue }
            known.append(id)
            changed = true
        }

        guard changed else { return }
        identifiersByKey[key] = known
    }

    /// Every known instance of the same content, including `id` itself.
    ///
    /// Unordered beyond `id` coming first — callers rank the rest themselves
    /// (playback sorts by server priority). Returns `[id]` when the content was
    /// never merged. Copies on `id`'s own server are never returned: that server
    /// is already represented by the copy that was asked about.
    func instances(of id: PlexItemID) -> [PlexItemID] {
        guard let key = keysByIdentifier[id], let known = identifiersByKey[key] else {
            return [id]
        }
        return [id] + known.filter { $0 != id && $0.serverID != id.serverID }
    }

    private func remove(_ id: PlexItemID, fromKey key: PlexContentKey) {
        guard var known = identifiersByKey[key] else { return }
        known.removeAll { $0 == id }
        identifiersByKey[key] = known.isEmpty ? nil : known
    }

    /// The content key an id was registered under, if the index has seen it.
    func contentKey(for id: PlexItemID) -> PlexContentKey? {
        keysByIdentifier[id]
    }

    func reset() {
        identifiersByKey.removeAll()
        keysByIdentifier.removeAll()
    }
}
