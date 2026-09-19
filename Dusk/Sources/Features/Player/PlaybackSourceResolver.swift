import Foundation

/// Decides which server plays an item, and in which order to try the others.
///
/// The same title routinely exists on several connected servers. The merge
/// layers already know which copies are the same content (`ContentAlternatesIndex`),
/// so playback does not have to search: it asks here for the instances of the
/// item, keeps the ones whose server is actually usable right now, and orders
/// them by the user's Server Priority.
///
/// A server that would trip Plex's remote-streaming restriction is demoted to
/// the back rather than dropped — it is still playable on the server's own LAN,
/// and it is the only copy some accounts have. The Plex Pass message is
/// therefore only the answer when *every* candidate is restricted.
@MainActor
struct PlaybackSourceResolver {
    struct Candidate: Equatable, Sendable {
        let id: PlexItemID
        /// Playing this one needs a Plex Pass the account does not have.
        let isRemoteStreamingRestricted: Bool

        var serverID: String? { id.serverID }
    }

    struct Resolution: Equatable {
        /// Usable instances, best first, restricted servers last.
        let candidates: [Candidate]
        /// The instance the caller asked for, with a missing server filled in.
        /// Callers compare candidates against this to tell the copy the user
        /// actually picked from its fallbacks.
        let requestedID: PlexItemID
        /// The Plex Pass message the restricted candidates would fail with, if
        /// any candidate is restricted at all.
        let restrictionMessage: String?

        var isEmpty: Bool { candidates.isEmpty }
        var identifiers: [PlexItemID] { candidates.map(\.id) }

        /// Every usable copy needs an entitlement the account does not have, so
        /// playing any of them would fail with the same Plex Pass error.
        var isFullyRestricted: Bool {
            !candidates.isEmpty && candidates.allSatisfy(\.isRemoteStreamingRestricted)
        }

        /// The walk ends on the restricted block (restricted candidates always
        /// sort last), so this also answers "were all remaining ones restricted".
        var hasRestrictedCandidate: Bool {
            candidates.contains(where: \.isRemoteStreamingRestricted)
        }
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
    ) async -> Resolution {
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

        var allowed: [Candidate] = []
        var restricted: [Candidate] = []
        var restrictionMessage: String?

        for instance in usable {
            if let restriction = await plexService.remoteStreamingRestriction(
                forServerID: instance.serverID
            ) {
                restrictionMessage = restriction.message
                restricted.append(Candidate(id: instance, isRemoteStreamingRestricted: true))
            } else {
                allowed.append(Candidate(id: instance, isRemoteStreamingRestricted: false))
            }
        }

        return Resolution(
            candidates: allowed + restricted,
            requestedID: requested,
            restrictionMessage: restrictionMessage
        )
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
