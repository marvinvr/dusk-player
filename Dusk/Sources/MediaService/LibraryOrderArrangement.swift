import Foundation

/// Pure functions that apply the account's library layout
/// (`AccountLibraryLayout`) to the connected servers' `/library/sections`
/// order.
///
/// The layout is **account-wide**: one flat list that can span every server the
/// account can see. Dusk is connected to several of those servers at once, so
/// the mapping is keyed on `Library.id` (`"<serverID>|<key>"`) throughout — a
/// section key is a per-server counter and keying on it alone silently aliases
/// two servers' sections onto each other.
///
/// Turning a new order back into the account's own record is the provider's
/// (`PlexPinnedSourceArrangement` for Plex).
///
/// Everything here is deliberately side-effect free so the rules stay testable
/// and readable; `LibraryOrderStore` and `MediaService+LibraryOrder` own all the
/// state and networking.
enum LibraryOrderArrangement {
    /// The order Dusk shows libraries in, across every connected server.
    ///
    /// Libraries placed by the account come first, in the account's order;
    /// everything else keeps the order `libraries` was given in (which is
    /// server priority, then each server's own `/library/sections` order).
    ///
    /// Edge cases, all intentional:
    /// - No machine identifiers, or an empty layout (fresh account, Plex blob
    ///   missing/404/unparseable, plex.tv unreachable) -> plain server order.
    ///   The layout must never be able to block the library list.
    /// - An entry whose section no longer exists, or whose server is not
    ///   connected, is skipped — but the provider preserves it on write.
    /// - Duplicate entries for one section: the first visible one wins.
    /// - Hidden entries are *not* placed at the front: a hidden library falls
    ///   through to the tail block. This is the full order, hidden libraries
    ///   included — the settings editor and Home's hub grouping need every
    ///   section. Screens that list libraries drop the ones in
    ///   `hiddenIdentities`.
    static func effectiveOrder(
        libraries: [Library],
        layout: AccountLibraryLayout,
        machineIdentifiers: Set<String>
    ) -> [Library] {
        guard !machineIdentifiers.isEmpty, !layout.entries.isEmpty else {
            return libraries
        }

        var librariesByIdentity: [String: Library] = [:]
        for library in libraries where librariesByIdentity[library.id] == nil {
            librariesByIdentity[library.id] = library
        }

        var placed: [Library] = []
        var used: Set<String> = []

        for entry in layout.entries
        where machineIdentifiers.contains(entry.serverID) && !entry.isHidden {
            let identity = entry.id
            guard let library = librariesByIdentity[identity],
                  !used.contains(identity) else { continue }
            placed.append(library)
            used.insert(identity)
        }

        return placed + libraries.filter { !used.contains($0.id) }
    }

    /// `Library.id`s of the connected servers' sections the account has
    /// hidden, whether in Dusk or in another client of the account. Duplicate
    /// entries: the first entry for a section decides.
    static func hiddenIdentities(
        layout: AccountLibraryLayout,
        machineIdentifiers: Set<String>
    ) -> Set<String> {
        var seen: Set<String> = []
        var hidden: Set<String> = []
        for entry in layout.entries where machineIdentifiers.contains(entry.serverID) {
            guard seen.insert(entry.id).inserted else { continue }
            if entry.isHidden {
                hidden.insert(entry.id)
            }
        }
        return hidden
    }
}
