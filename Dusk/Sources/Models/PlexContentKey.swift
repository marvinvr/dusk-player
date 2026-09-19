import Foundation

/// Identity of a *piece of content*, independent of which server holds it.
///
/// `PlexItemID` answers "which copy is this"; `PlexContentKey` answers "is this
/// the same movie/show/episode as that one" so the merge layers can collapse
/// the same title appearing on several servers into one row.
///
/// Resolution goes strongest to weakest:
/// 1. the scalar `guid` when it is a modern `plex://` global metadata id,
/// 2. a namespaced external id (tmdb, then imdb, then tvdb) from `Guid`,
/// 3. a title/year heuristic — seasons use show + season number and episodes
///    show + season + episode instead, because those titles repeat far too
///    often to key on,
/// 4. nothing usable: the item is keyed by its own copy and never merges.
///
/// External ids and the heuristic are namespaced by media type on purpose: a
/// show, its season and its episode routinely carry the same tvdb id, and a
/// movie and a show routinely share a tmdb id. None of them may merge.
///
/// Only the first two are *strong*: they identify the content itself, so two
/// copies carrying the same one really are the same file elsewhere. A heuristic
/// key is good enough to collapse a row on screen, never good enough to send
/// playback to another server — see `ContentAlternatesIndex`.
enum PlexContentKey: Hashable, Sendable {
    /// Plex's own global metadata id (`plex://movie/5d776...`).
    case plex(String)
    /// `provider:namespace:id`, e.g. tmdb for a movie.
    case external(provider: String, namespace: String, id: String)
    /// Title/year (or show/season/episode) fallback.
    case heuristic(String)
    /// This one copy, and nothing else. Used when the heuristic would carry no
    /// information (no title, no numbering) or would be unsafe (clips and other
    /// personal-media videos, whose titles collide constantly).
    case instance(PlexItemID)

    /// True when the key identifies the *content*, so another copy carrying it
    /// is genuinely the same thing.
    var isStrong: Bool {
        switch self {
        case .plex, .external: true
        case .heuristic, .instance: false
        }
    }
}

extension PlexContentKey {
    /// Providers in descending order of how reliably Plex populates them.
    static let externalProviders = ["tmdb", "imdb", "tvdb"]

    /// Builds the key from the raw pieces every model can supply.
    ///
    /// - Parameters:
    ///   - guid: the scalar `guid` field; only used when it is a `plex://` id.
    ///     Legacy agent guids (`com.plexapp.agents.imdb://…`) and `local://`
    ///     are ignored because they are not comparable across servers.
    ///   - guids: the `Guid` array, which carries the external ids.
    ///   - episode: show title plus season/episode numbers when the item is an
    ///     episode or a season, so the heuristic can key on the show rather than
    ///     the title — "Season 1" is the title of every show's first season.
    ///   - isClip: personal-media item ("Other Videos"). Those report
    ///     `type == .movie`, so the flag is what keeps them out of the movie
    ///     namespace and out of heuristic merging.
    ///   - identity: the copy being keyed. It is what the key falls back to when
    ///     the heuristic would say nothing, so unrelated items can never merge.
    static func resolve(
        guid: String?,
        guids: [PlexGuid],
        type: PlexMediaType,
        title: String,
        year: Int?,
        episode: EpisodeCoordinates? = nil,
        isClip: Bool = false,
        identity: PlexItemID
    ) -> PlexContentKey {
        if let plexGUID = guid?.nilIfEmpty, plexGUID.lowercased().hasPrefix("plex://") {
            return .plex(plexGUID.lowercased())
        }

        let namespace = isClip ? "clip" : type.rawValue
        for provider in externalProviders {
            if let value = guids.lazy.compactMap({ $0.value(for: provider) }).first {
                return .external(provider: provider, namespace: namespace, id: value.lowercased())
            }
        }

        // Anything below this point is a guess, and a guess is only allowed to
        // collapse rows of the kinds whose titles are meaningful. Clips and
        // everything else keep to themselves.
        guard !isClip, mergesHeuristically(type) else { return .instance(identity) }

        if let episode {
            let showTitle = normalized(episode.showTitle)
            // Without the show or the numbering there is nothing to match on,
            // and every show's "Season 1" would collapse into one.
            guard !showTitle.isEmpty, episode.season != nil else { return .instance(identity) }
            guard type != .episode || episode.episode != nil else { return .instance(identity) }

            return .heuristic(
                "\(namespace)|\(showTitle)|s\(episode.season ?? -1)|e\(episode.episode ?? -1)"
            )
        }

        let normalizedTitle = normalized(title)
        guard !normalizedTitle.isEmpty else { return .instance(identity) }

        return .heuristic("\(namespace)|\(normalizedTitle)|\(year.map(String.init) ?? "")")
    }

    /// Season/episode numbering plus the show it belongs to. A season leaves
    /// `episode` nil.
    struct EpisodeCoordinates: Hashable, Sendable {
        let showTitle: String
        let season: Int?
        let episode: Int?
    }

    /// The kinds whose title (or show + numbering) is a safe enough match to
    /// collapse two servers' rows into one. Clips and personal-media videos are
    /// deliberately not among them: "Trailer" is not an identity.
    private static func mergesHeuristically(_ type: PlexMediaType) -> Bool {
        switch type {
        case .movie, .show, .season, .episode:
            return true
        default:
            return false
        }
    }

    private static func normalized(_ value: String) -> String {
        String(
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .filter { $0.isLetter || $0.isNumber }
        )
    }
}

extension PlexContentKey {
    init(item: PlexItem) {
        self = Self.resolve(
            guid: item.guid,
            guids: item.guids,
            type: item.type,
            title: item.title,
            year: item.year,
            episode: Self.coordinates(
                type: item.type,
                // A season's show is its parent; an episode's is its grandparent.
                showTitle: item.type == .season
                    ? item.parentTitle
                    : (item.grandparentTitle ?? item.parentTitle),
                season: item.type == .season ? item.index : item.parentIndex,
                episode: item.index
            ),
            isClip: item.isClip,
            identity: item.id
        )
    }

    init(details: PlexMediaDetails) {
        self = Self.resolve(
            guid: details.guid,
            guids: details.guids,
            type: details.type,
            title: details.title,
            year: details.year,
            // Details carry no parent title, so a season without a guid simply
            // keys on its own copy rather than guessing which show it belongs to.
            episode: Self.coordinates(
                type: details.type,
                showTitle: details.grandparentTitle,
                season: details.type == .season ? details.index : details.parentIndex,
                episode: details.index
            ),
            isClip: details.isClip,
            identity: details.id
        )
    }

    /// Show coordinates for the kinds that need them. A season keys on its show
    /// plus its own index; an episode adds the episode number.
    private static func coordinates(
        type: PlexMediaType,
        showTitle: String?,
        season: Int?,
        episode: Int?
    ) -> EpisodeCoordinates? {
        switch type {
        case .season:
            return EpisodeCoordinates(showTitle: showTitle ?? "", season: season, episode: nil)
        case .episode:
            return EpisodeCoordinates(showTitle: showTitle ?? "", season: season, episode: episode)
        default:
            return nil
        }
    }
}

extension PlexItem {
    /// Cross-server content identity. See `PlexContentKey`.
    var contentKey: PlexContentKey { PlexContentKey(item: self) }
}

extension PlexMediaDetails {
    /// Cross-server content identity. See `PlexContentKey`.
    var contentKey: PlexContentKey { PlexContentKey(details: self) }
}
