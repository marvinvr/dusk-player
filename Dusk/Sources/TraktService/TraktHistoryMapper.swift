import Foundation

/// A finished item's ids → `TraktHistoryEntry`. Pure, so it is unit tested.
///
/// `externalIDs` are the provider-neutral ids (`imdb://`, `tmdb://`, `tvdb://`),
/// which every provider fills. `guid` is the item's own server identifier and
/// only matters for Plex's legacy agents (`com.plexapp.agents.*`), whose ids
/// live in that scalar and are parsed below. Moving that parsing into the Plex
/// mapper needs a neutral shape for "show id + season + episode" (04 §16).
enum TraktHistoryMapper {
    static func entry(
        type: MediaKind,
        guid: String?,
        externalIDs: ExternalIDs,
        watchedAt: Date,
        profileID: String
    ) -> TraktHistoryEntry? {
        guard type == .movie || type == .episode else { return nil }

        // Modern agents: the `Guid` array (imdb://, tmdb://, tvdb://).
        var ids = TraktIDs()
        for uri in externalIDs.uris {
            if ids.imdb == nil, let value = ExternalIDs.value(of: uri, for: "imdb"), value.hasPrefix("tt") { ids.imdb = value }
            if ids.tmdb == nil, let value = ExternalIDs.value(of: uri, for: "tmdb").flatMap(Int.init) { ids.tmdb = value }
            if ids.tvdb == nil, let value = ExternalIDs.value(of: uri, for: "tvdb").flatMap(Int.init) { ids.tvdb = value }
        }
        if !ids.isEmpty {
            return TraktHistoryEntry(
                kind: type == .movie ? .movie : .episode,
                ids: ids,
                watchedAt: watchedAt,
                profileID: profileID
            )
        }

        // Legacy agents: everything lives in the scalar guid.
        guard let legacy = LegacyGuid(guid) else { return nil }
        switch type {
        case .movie:
            guard legacy.numbers.isEmpty, let ids = legacy.ids else { return nil }
            return TraktHistoryEntry(kind: .movie, ids: ids, watchedAt: watchedAt, profileID: profileID)
        default:
            // thetvdb://<show>/<season>/<episode>, themoviedb://<show>/<season>/<episode>
            guard legacy.numbers.count == 2, let ids = legacy.ids else { return nil }
            return TraktHistoryEntry(
                kind: .showEpisode,
                ids: ids,
                season: legacy.numbers[0],
                episode: legacy.numbers[1],
                watchedAt: watchedAt,
                profileID: profileID
            )
        }
    }

    /// `com.plexapp.agents.<agent>://<id>[/<season>/<episode>][?lang=xx]`.
    private struct LegacyGuid {
        let agent: String
        let id: String
        let numbers: [Int]

        init?(_ guid: String?) {
            guard let guid, let schemeEnd = guid.range(of: "://") else { return nil }
            let scheme = guid[..<schemeEnd.lowerBound].lowercased()
            guard scheme.hasPrefix("com.plexapp.agents.") else { return nil }
            agent = String(scheme.dropFirst("com.plexapp.agents.".count))
            let rest = guid[schemeEnd.upperBound...].split(separator: "?").first.map(String.init) ?? ""
            let parts = rest.split(separator: "/").map(String.init)
            guard let first = parts.first, !first.isEmpty else { return nil }
            id = first
            let numbers = parts.dropFirst().compactMap(Int.init)
            guard numbers.count == parts.count - 1 else { return nil }
            self.numbers = numbers
        }

        var ids: TraktIDs? {
            switch agent {
            case "imdb":
                return id.hasPrefix("tt") ? TraktIDs(imdb: id) : nil
            case "themoviedb":
                return Int(id).map { TraktIDs(tmdb: $0) }
            case "thetvdb":
                return Int(id).map { TraktIDs(tvdb: $0) }
            default:
                return nil
            }
        }
    }
}
