import Foundation

/// Pure functions that translate between the Plex account's flat
/// `pinnedSources` list and the connected servers' `/library/sections` order.
///
/// The pinned list is **account-wide**: one flat array spanning every server the
/// account can see plus the cloud providers. Dusk is connected to several of
/// those servers at once, so the mapping is keyed on
/// (`machineIdentifier`, `directoryID`) throughout — a `directoryID` is a
/// per-server counter and keying on it alone silently aliases two servers'
/// sections onto each other.
///
/// Everything here is deliberately side-effect free so the rules stay testable
/// and readable; `LibraryOrderStore` and `PlexService+LibraryOrder` own all the
/// state and networking.
enum LibraryOrderArrangement {
    /// The order Dusk shows libraries in, across every connected server.
    ///
    /// Sections pinned by the account come first, in the account's sidebar
    /// order; everything else keeps the order `libraries` was given in (which is
    /// server priority, then each server's own `/library/sections` order).
    ///
    /// Edge cases, all intentional:
    /// - No machine identifiers, or no pinned sources at all (fresh account,
    ///   blob missing/404/unparseable, plex.tv unreachable) -> plain server
    ///   order. The blob must never be able to block the library list.
    /// - A pinned entry whose section no longer exists, or whose server is not
    ///   connected, is skipped — but it is still preserved on write.
    /// - Duplicate pins for one section: the first one wins.
    /// - `isHidden` entries are *not* pinned to the front. Dusk does not hide
    ///   libraries, so a hidden library falls through to the tail block instead
    ///   of disappearing (see `writeOrder`, which keeps it hidden on write).
    /// - Cloud provider entries (`machineIdentifier == "myPlex"`) are ignored
    ///   here; they are preserved on write.
    static func effectiveOrder(
        libraries: [PlexLibrary],
        pinnedSources: [PlexPinnedSource],
        machineIdentifiers: Set<String>
    ) -> [PlexLibrary] {
        guard !machineIdentifiers.isEmpty, !pinnedSources.isEmpty else {
            return libraries
        }

        var librariesByIdentity: [String: PlexLibrary] = [:]
        for library in libraries where librariesByIdentity[library.id] == nil {
            librariesByIdentity[library.id] = library
        }

        var placed: [PlexLibrary] = []
        var used: Set<String> = []

        for source in pinnedSources
        where machineIdentifiers.contains(source.machineIdentifier)
            && source.isPMSLibrary
            && !source.isHidden {
            guard let identity = identity(for: source),
                  let library = librariesByIdentity[identity],
                  !used.contains(identity) else { continue }
            placed.append(library)
            used.insert(identity)
        }

        return placed + libraries.filter { !used.contains($0.id) }
    }

    /// Splices the connected servers' freshly reordered entries back into the
    /// account's full pinned list.
    ///
    /// Every participating server's entries collapse into one contiguous block
    /// placed where the *first* of them used to be — the whole point being that
    /// a cross-server order is one list, not one block per server. Entries
    /// belonging to servers that did not participate (disabled, not connected,
    /// or whose sections could not be read) and to cloud providers are copied
    /// verbatim, keep their relative order, and are never dropped or mutated: a
    /// partial write would wipe the user's Plex Web sidebar.
    static func merged(
        existing: [PlexPinnedSource],
        reordered: [PlexPinnedSource],
        machineIdentifiers: Set<String>
    ) -> [PlexPinnedSource] {
        func isParticipating(_ source: PlexPinnedSource) -> Bool {
            machineIdentifiers.contains(source.machineIdentifier) && source.isPMSLibrary
        }

        let others = existing.filter { !isParticipating($0) }

        let insertionIndex: Int
        if let firstIndex = existing.firstIndex(where: isParticipating) {
            insertionIndex = existing[..<firstIndex].filter { !isParticipating($0) }.count
        } else {
            // Nothing pinned for these servers yet: append after everything else.
            insertionIndex = others.count
        }

        return Array(others[..<insertionIndex]) + reordered + Array(others[insertionIndex...])
    }

    /// User order in, write order out.
    ///
    /// Existing entries are reused verbatim (only `title` is refreshed from the
    /// section) so unmodeled Plex fields survive; sections that were never
    /// pinned get a freshly built entry, which needs that section's own server
    /// — hence `servers`, keyed by machine identifier.
    ///
    /// A section whose server is missing from `servers` is skipped rather than
    /// guessed at: writing it under the wrong machine identifier would move a
    /// different server's library in every Plex client.
    ///
    /// Hidden entries keep `isHidden` and are stable-moved to the end of the
    /// block. That makes the write idempotent with `effectiveOrder`, which
    /// already shows hidden libraries last: a library hidden in Plex Web still
    /// appears in Dusk, and dragging it into the middle of the list snaps back
    /// to the end. Documented wart — do not force-unhide, that would silently
    /// undo a choice the user made in another Plex client.
    static func writeOrder(
        userOrder: [PlexLibrary],
        existing: [PlexPinnedSource],
        servers: [String: PlexServer]
    ) -> [PlexPinnedSource] {
        var existingByIdentity: [String: PlexPinnedSource] = [:]
        for source in existing
        where servers[source.machineIdentifier] != nil && source.isPMSLibrary {
            guard let identity = identity(for: source),
                  existingByIdentity[identity] == nil else { continue }
            existingByIdentity[identity] = source
        }

        var seen: Set<String> = []
        var mapped: [PlexPinnedSource] = []
        for library in userOrder {
            guard let serverID = library.serverID, let server = servers[serverID] else { continue }
            guard seen.insert(library.id).inserted else { continue }
            if let existingSource = existingByIdentity[library.id] {
                mapped.append(existingSource.updatingTitle(library.title))
            } else {
                mapped.append(PlexPinnedSource.make(library: library, server: server))
            }
        }

        return mapped.filter { !$0.isHidden } + mapped.filter(\.isHidden)
    }

    /// The `(machineIdentifier, directoryID)` pair a pinned entry points at, in
    /// the same shape as `PlexLibrary.id`.
    private static func identity(for source: PlexPinnedSource) -> String? {
        guard let directoryID = source.directoryID else { return nil }
        return "\(source.machineIdentifier)|\(directoryID)"
    }
}
