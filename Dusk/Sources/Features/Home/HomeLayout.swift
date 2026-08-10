import Foundation

/// Stable identifiers for everything Home can render as a row. They key the
/// saved layout in `UserPreferences`, so an existing value must never change
/// meaning once shipped.
enum HomeLayoutRowID {
    /// The cinematic hero, which is Continue Watching in row form.
    static let featured = "dusk.featured"
    static let liveTV = "dusk.liveTV"
    static let suggestions = "dusk.suggestions"

    static func hub(_ hubID: String) -> String {
        "plex.\(hubID)"
    }

    static func hub(_ plexHub: PlexHub) -> String {
        hub(plexHub.id)
    }
}

/// A Home row in the order the user arranged it. Personalized shelves move as
/// one block: they are generated per load, so an individual shelf has no
/// identity worth persisting.
enum HomeRow: Identifiable {
    case liveTV
    case hub(PlexHub)
    case suggestions([HomePersonalizedShelf])

    var id: String {
        switch self {
        case .liveTV:
            HomeLayoutRowID.liveTV
        case .hub(let hub):
            HomeLayoutRowID.hub(hub)
        case .suggestions:
            HomeLayoutRowID.suggestions
        }
    }
}

enum HomeLayoutArrangement {
    /// Applies a saved row order.
    ///
    /// Rows the user placed come first in their saved order. Rows Plex has
    /// added since the last edit keep their server order at the end rather than
    /// jumping into an arbitrary slot; the layout editor lists them so the next
    /// edit gives them a home.
    static func arrange<Element>(
        _ elements: [Element],
        id: (Element) -> String,
        preferredOrder: [String]
    ) -> [Element] {
        guard !preferredOrder.isEmpty else { return elements }

        var positions: [String: Int] = [:]
        for (index, identifier) in preferredOrder.enumerated() where positions[identifier] == nil {
            positions[identifier] = index
        }

        let placed = elements
            .compactMap { element in positions[id(element)].map { (position: $0, element: element) } }
            .sorted { $0.position < $1.position }
            .map(\.element)
        let unplaced = elements.filter { positions[id($0)] == nil }

        return placed + unplaced
    }
}

/// Content Home never shows regardless of layout. Shared with the layout editor
/// so both screens agree on which Plex hubs exist as rows.
enum HomeHubFilter {
    /// Plex's own continue-watching/on-deck hubs are covered by the cinematic
    /// hero, and playlists are not a Dusk destination.
    static func shouldHide(hub: PlexHub) -> Bool {
        let fields = [hub.title, hub.key, hub.hubIdentifier]
            .compactMap { $0?.lowercased() }

        return fields.contains { value in
            value.contains("continue watching") ||
            value.contains("continuewatching") ||
            value.contains("on deck") ||
            value.contains("ondeck") ||
            value.contains("playlist") ||
            value.contains("playlists")
        }
    }

    static func shouldHide(item: PlexItem) -> Bool {
        switch item.type {
        case .artist, .album, .track, .unknown:
            return true
        default:
            return item.key.lowercased().contains("/playlists/")
        }
    }
}
