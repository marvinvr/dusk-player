import Foundation

/// Decides which server plays an item, and in which order to try the others.
///
/// The same title routinely exists on several connected servers. The merge
/// layers already know which copies are the same content (`ContentAlternatesIndex`),
/// so playback does not have to search: it asks here for the instances of the
/// item, keeps the ones whose server is actually usable right now, and orders
/// them by the user's Server Priority.
///
/// Plex's remote-streaming rule is not judged here: only the server knows
/// whether a request counts as remote and who holds which pass, so every
/// candidate is tried (see `RemotePlaybackRefusal`).
@MainActor
struct PlaybackSourceResolver {
    struct Resolution: Equatable {
        /// Usable instances, best first.
        let identifiers: [PlexItemID]
        /// The instance the caller asked for, with a missing server filled in.
        /// Callers compare candidates against this to tell the copy the user
        /// actually picked from its fallbacks.
        let requestedID: PlexItemID

        var isEmpty: Bool { identifiers.isEmpty }
    }

    let plexService: PlexService

    /// - Parameters:
    ///   - restrictToItemServer: explicit choices (a specific media version, a
    ///     SharePlay activity) must stay on the server the user picked them
    ///     from — another server's copy is a different file with different
    ///     versions, and a SharePlay post-check would reject it.
    ///   - prefersRequestedInstance: the requested copy carries the user's
    ///     progress (a resume offset), so it plays first no matter where its
    ///     server sits in the priority list; the others remain as fallbacks.
    func resolve(
        for id: PlexItemID,
        restrictToItemServer: Bool = false,
        prefersRequestedInstance: Bool = false
    ) -> Resolution {
        let instances = restrictToItemServer
            ? [id]
            : plexService.alternates.instances(of: id)
        let requested = normalizedRequestedID(id)

        var seenServers = Set<String>()
        var usable: [PlexItemID] = []

        for instance in orderedByPriority(normalized(instances, requestedBy: id)) {
            guard let serverID = instance.serverID,
                  plexService.serverPriority.isEnabled(serverID),
                  plexService.pool.connection(for: serverID) != nil,
                  seenServers.insert(serverID).inserted else {
                continue
            }
            // The instance the caller asked for always represents its own
            // server. Two items on one server can share a weak content key (two
            // guid-less clips called "Trailer"), and swapping the tapped one for
            // its "alternate" would play a different file.
            usable.append(serverID == requested.serverID ? requested : instance)
        }

        if prefersRequestedInstance, let index = usable.firstIndex(of: requested), index != 0 {
            usable.remove(at: index)
            usable.insert(requested, at: 0)
        }

        return Resolution(identifiers: usable, requestedID: requested)
    }

    /// An item that reached playback without a server (an unstamped offline
    /// cache, a legacy route) plays from the primary server.
    private func normalized(_ instances: [PlexItemID], requestedBy id: PlexItemID) -> [PlexItemID] {
        var normalized = instances
        if !normalized.contains(id) {
            normalized.append(id)
        }
        guard id.serverID == nil, let primaryID = plexService.pool.primary?.serverID else {
            return normalized
        }
        return normalized.map { instance in
            instance.serverID == nil
                ? PlexItemID(serverID: primaryID, ratingKey: instance.ratingKey)
                : instance
        }
    }

    /// The requested id as it appears after `normalized` has filled in a
    /// missing server.
    private func normalizedRequestedID(_ id: PlexItemID) -> PlexItemID {
        guard id.serverID == nil, let primaryID = plexService.pool.primary?.serverID else {
            return id
        }
        return PlexItemID(serverID: primaryID, ratingKey: id.ratingKey)
    }

    private func orderedByPriority(_ instances: [PlexItemID]) -> [PlexItemID] {
        instances
            .enumerated()
            .sorted { lhs, rhs in
                let leftRank = rank(of: lhs.element)
                let rightRank = rank(of: rhs.element)
                if leftRank != rightRank { return leftRank < rightRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func rank(of id: PlexItemID) -> Int {
        guard let serverID = id.serverID else { return Int.max }
        return plexService.serverPriority.rank(of: serverID)
    }
}
