import Foundation

/// Next Up entries the user took off Continue Watching (04 §11). Jellyfin has
/// no "hide from Next Up", so Dusk remembers the dismissed episode per show
/// and leaves it out until a different episode of that show is next.
///
/// Per server and user (a Jellyfin profile), in UserDefaults
/// `JellyfinDismissedNextUp`: `{ "<serverID>|<userID>": { seriesID: episodeID } }`.
/// A new key; nothing a Plex install stored is read or written.
@MainActor
enum JellyfinNextUpDismissals {
    static let defaultsKey = "JellyfinDismissedNextUp"

    /// The dismissed episode per show for one profile.
    static func dismissed(scope: String, defaults: UserDefaults = .standard) -> [String: String] {
        load(defaults)[scope] ?? [:]
    }

    static func dismiss(episodeID: String, seriesID: String, scope: String, defaults: UserDefaults = .standard) {
        var all = load(defaults)
        all[scope, default: [:]][JellyfinID.normalized(seriesID)] = JellyfinID.normalized(episodeID)
        save(all, defaults)
    }

    /// Drops the Next Up entries the user dismissed, and forgets a dismissal
    /// once its show has moved on to another episode. `nextUp` is one page of
    /// `/Shows/NextUp`: a show missing from it keeps its entry.
    static func filter(_ nextUp: [JellyfinItemDTO], scope: String, defaults: UserDefaults = .standard) -> [JellyfinItemDTO] {
        var all = load(defaults)
        guard var dismissed = all[scope], !dismissed.isEmpty else { return nextUp }
        var kept: [JellyfinItemDTO] = []
        for item in nextUp {
            guard let seriesID = item.seriesID.map(JellyfinID.normalized),
                  let episodeID = dismissed[seriesID] else {
                kept.append(item)
                continue
            }
            if episodeID == JellyfinID.normalized(item.id) { continue }
            dismissed[seriesID] = nil
            kept.append(item)
        }
        if dismissed != all[scope] {
            all[scope] = dismissed.isEmpty ? nil : dismissed
            save(all, defaults)
        }
        return kept
    }

    static func scope(serverID: String, userID: String) -> String {
        "\(JellyfinID.normalized(serverID))|\(JellyfinID.normalized(userID))"
    }

    private static func load(_ defaults: UserDefaults) -> [String: [String: String]] {
        defaults.dictionary(forKey: defaultsKey) as? [String: [String: String]] ?? [:]
    }

    private static func save(_ all: [String: [String: String]], _ defaults: UserDefaults) {
        if all.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(all, forKey: defaultsKey)
        }
    }
}
