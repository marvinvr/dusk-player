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
    /// - same-server copies are accepted only for strong movie keys. TV keeps
    ///   its existing one-copy-per-server behavior until episode mapping exists.
    func register(_ ids: [PlexItemID], for key: PlexContentKey) {
        guard key.isStrong, !ids.isEmpty else { return }

        // A later response may bridge a Plex key and an external key. Preserve
        // every already-known copy rather than moving just the bridging item.
        let previousKeys = Set(ids.compactMap { keysByIdentifier[$0] })
        var known = identifiersByKey[key] ?? []
        for previous in previousKeys where previous != key {
            let previousIDs = identifiersByKey[previous] ?? []
            if key.isMovie, previous.isMovie, key.movieEdition == previous.movieEdition {
                for id in previousIDs where !known.contains(id) { known.append(id) }
                identifiersByKey[previous] = nil
            } else {
                // Re-matching metadata or changing an edition is not an alias
                // bridge. Move only the affected instances, leaving others put.
                let remaining = previousIDs.filter { !ids.contains($0) }
                identifiersByKey[previous] = remaining.isEmpty ? nil : remaining
            }
        }
        for id in ids where !known.contains(id) {
            guard key.isMovie || !known.contains(where: { $0.serverID == id.serverID }) else { continue }
            known.append(id)
        }
        if identifiersByKey[key] != known { identifiersByKey[key] = known }
        for id in known + ids where keysByIdentifier[id] != key { keysByIdentifier[id] = key }
    }

    /// Every known instance, with the requested copy first.
    func instances(of id: PlexItemID) -> [PlexItemID] {
        guard let key = keysByIdentifier[id], let known = identifiersByKey[key] else { return [id] }
        return [id] + known.filter { $0 != id && (key.isMovie || $0.serverID != id.serverID) }
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
