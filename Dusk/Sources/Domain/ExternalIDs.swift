import Foundation

/// The external ids an item carries (tmdb, imdb, tvdb, …), in the order the
/// server listed them (docs/jellyfin/04-architecture.md §4.1).
///
/// Values are kept raw and in order, not collapsed to one per namespace:
/// callers differ in which one they want (the first, the first that parses
/// as a number, the first that looks like an imdb id), and each keeps its own
/// rule. Plex sends them as `Guid` entries (`tmdb://546554`).
struct ExternalIDs: Hashable, Sendable {
    /// Provider-prefixed ids, `<namespace>://<value>`, in server order.
    let uris: [String]

    init(uris: [String] = []) {
        self.uris = uris
    }

    /// Every value for `namespace` (`tmdb`, `imdb`, `tvdb`), in order.
    /// The namespace prefix matches case-insensitively; empty values are skipped.
    func values(for namespace: String) -> [String] {
        uris.compactMap { Self.value(of: $0, for: namespace) }
    }

    /// The first value for `namespace`.
    func first(_ namespace: String) -> String? {
        uris.lazy.compactMap { Self.value(of: $0, for: namespace) }.first
    }

    var tmdb: String? { first("tmdb") }
    var imdb: String? { first("imdb") }
    var tvdb: String? { first("tvdb") }

    /// The value of one `<namespace>://<value>` uri, or nil when it belongs to
    /// another namespace.
    static func value(of uri: String, for namespace: String) -> String? {
        let prefix = "\(namespace)://"
        guard uri.lowercased().hasPrefix(prefix) else { return nil }
        return String(uri.dropFirst(prefix.count)).nilIfEmpty
    }

    /// The same ids followed by `others`.
    func appending(_ others: [String]) -> ExternalIDs {
        ExternalIDs(uris: uris + others)
    }
}
