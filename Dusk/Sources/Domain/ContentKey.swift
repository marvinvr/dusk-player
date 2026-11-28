import Foundation

/// Identity of a *piece of content*, independent of which server holds it.
///
/// `MediaItemID` answers "which copy is this"; `ContentKey` answers "is this
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
/// Every key but `.instance` also carries the item's Plex edition. Plex models
/// each edition ("Director's Cut", "Extended") as its own item with the same
/// guid and external ids, so without it two editions would collapse into one
/// row and one could be played as the other's fallback. Items with no edition
/// keep their plain key, so the same edition still merges across servers.
///
/// External ids and the heuristic are namespaced by media type on purpose: a
/// show, its season and its episode routinely carry the same tvdb id, and a
/// movie and a show routinely share a tmdb id. None of them may merge.
///
/// Only the first two are *strong*: they identify the content itself, so two
/// copies carrying the same one really are the same file elsewhere. A heuristic
/// key is good enough to collapse a row on screen, never good enough to send
/// playback to another server — see `ContentAlternatesIndex`.
enum ContentKey: Hashable, Sendable {
    /// The provider's own global metadata id (Plex: `plex://movie/5d776...`).
    case native(String)
    /// `provider:namespace:id`, e.g. tmdb for a movie.
    case external(provider: String, namespace: String, id: String)
    /// Title/year (or show/season/episode) fallback.
    case heuristic(String)
    /// This one copy, and nothing else. Used when the heuristic would carry no
    /// information (no title, no numbering) or would be unsafe (clips and other
    /// personal-media videos, whose titles collide constantly).
    case instance(MediaItemID)

    /// True when the key identifies the *content*, so another copy carrying it
    /// is genuinely the same thing.
    var isStrong: Bool {
        switch self {
        case .native, .external: true
        case .heuristic, .instance: false
        }
    }
}

extension ContentKey {
    /// Providers in descending order of how reliably Plex populates them.
    static let externalProviders = ["tmdb", "imdb", "tvdb"]

    /// Builds the key from the raw pieces every model can supply.
    ///
    /// - Parameters:
    ///   - guid: the scalar `guid` field; only used when it is a `plex://` id.
    ///     Legacy agent guids (`com.plexapp.agents.imdb://…`) and `local://`
    ///     are ignored because they are not comparable across servers.
    ///   - externalIDs: the item's external ids (Plex's `Guid` array).
    ///   - episode: show title plus season/episode numbers when the item is an
    ///     episode or a season, so the heuristic can key on the show rather than
    ///     the title — "Season 1" is the title of every show's first season.
    ///   - edition: the item's `editionTitle`. Compared loosely (case, accents
    ///     and punctuation ignored) because each server's edition is typed by
    ///     its owner.
    ///   - isClip: personal-media item ("Other Videos"). Those report
    ///     `type == .movie`, so the flag is what keeps them out of the movie
    ///     namespace and out of heuristic merging.
    ///   - identity: the copy being keyed. It is what the key falls back to when
    ///     the heuristic would say nothing, so unrelated items can never merge.
    static func resolve(
        guid: String?,
        externalIDs: ExternalIDs,
        type: MediaKind,
        title: String,
        year: Int?,
        episode: EpisodeCoordinates? = nil,
        edition: String? = nil,
        isClip: Bool = false,
        identity: MediaItemID
    ) -> ContentKey {
        let editionSuffix = edition.map(normalized).flatMap(\.nilIfEmpty).map { "|edition:\($0)" } ?? ""
        if let plexGUID = guid?.nilIfEmpty, plexGUID.lowercased().hasPrefix("plex://") {
            return .native(plexGUID.lowercased() + editionSuffix)
        }

        let namespace = isClip ? "clip" : type.rawValue
        // Some agents send an external URI as the scalar guid rather than in
        // Guid[]. Provider-prefixed IDs are equally strong in either location.
        let externalGuids = externalIDs.appending([guid].compactMap { $0 })
        for provider in externalProviders {
            if let value = externalGuids.first(provider) {
                return .external(provider: provider, namespace: namespace, id: value.lowercased() + editionSuffix)
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
                "\(namespace)|\(showTitle)|s\(episode.season ?? -1)|e\(episode.episode ?? -1)" + editionSuffix
            )
        }

        let normalizedTitle = normalized(title)
        guard !normalizedTitle.isEmpty else { return .instance(identity) }

        return .heuristic("\(namespace)|\(normalizedTitle)|\(year.map(String.init) ?? "")" + editionSuffix)
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
    private static func mergesHeuristically(_ type: MediaKind) -> Bool {
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

extension ContentKey {
    init(item: MediaItem) {
        self = Self.resolve(
            guid: item.guid,
            externalIDs: item.externalIDs,
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
            edition: item.editionTitle,
            isClip: item.isClip,
            identity: item.id
        )
    }

    init(details: MediaDetails) {
        self = Self.resolve(
            guid: details.guid,
            externalIDs: details.externalIDs,
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
            edition: details.editionTitle,
            isClip: details.isClip,
            identity: details.id
        )
    }

    /// Show coordinates for the kinds that need them. A season keys on its show
    /// plus its own index; an episode adds the episode number.
    private static func coordinates(
        type: MediaKind,
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

extension MediaItem {
    /// Cross-server content identity. See `ContentKey`.
    var contentKey: ContentKey { ContentKey(item: self) }

    /// Every strong key this copy carries. See `ContentKey.aliases`.
    var contentAliases: Set<ContentKey> {
        ContentKey.aliases(guid: guid, externalIDs: externalIDs, type: type,
                           edition: editionTitle, isClip: isClip, identity: id)
    }
}

extension MediaDetails {
    /// Cross-server content identity. See `ContentKey`.
    var contentKey: ContentKey { ContentKey(details: self) }

    /// Every strong key this copy carries. See `ContentKey.aliases`.
    var contentAliases: Set<ContentKey> {
        ContentKey.aliases(guid: guid, externalIDs: externalIDs, type: type,
                           edition: editionTitle, isClip: isClip, identity: id)
    }
}

extension ContentKey {
    /// Every strong key a copy carries: its primary key when that is strong,
    /// plus one key per native or external id (docs/jellyfin/04-architecture.md
    /// §6.2). The merge layer can use these to re-key a copy whose provider has
    /// no native global id onto the key of a copy that has one. Nothing reads
    /// them yet: with Plex alone every copy already has its primary key, so
    /// merging is unchanged.
    static func aliases(
        guid: String?, externalIDs: ExternalIDs, type: MediaKind,
        edition: String?, isClip: Bool, identity: MediaItemID
    ) -> Set<ContentKey> {
        var keys = Set<ContentKey>()
        let primary = resolve(guid: guid, externalIDs: externalIDs, type: type, title: "", year: nil,
                              edition: edition, isClip: isClip, identity: identity)
        if primary.isStrong { keys.insert(primary) }
        for uri in [guid].compactMap({ $0 }) + externalIDs.uris {
            let key = resolve(guid: uri, externalIDs: ExternalIDs(uris: [uri]), type: type, title: "", year: nil,
                              edition: edition, isClip: isClip, identity: identity)
            if key.isStrong { keys.insert(key) }
        }
        return keys
    }
}

// Movie copies may use different Plex agents but still share an external ID.
// Keep editions in every alias, just as in the primary content key.
extension ContentKey {
    var isMovie: Bool {
        switch self {
        case .native(let guid): guid.hasPrefix("plex://movie/")
        case .external(_, let namespace, _): namespace == "movie"
        default: false
        }
    }

    var movieEdition: String? {
        let value: String
        switch self {
        case .native(let guid): value = guid
        case .external(_, _, let id): value = id
        default: return nil
        }
        return value.components(separatedBy: "|edition:").dropFirst().first
    }

    static func movieKeys(
        guid: String?, externalIDs: ExternalIDs, title: String, year: Int?,
        edition: String?, identity: MediaItemID
    ) -> Set<ContentKey> {
        var keys = Set<ContentKey>()
        for external in externalIDs.uris {
            let key = resolve(guid: nil, externalIDs: ExternalIDs(uris: [external]), type: .movie,
                              title: title, year: year, edition: edition, identity: identity)
            if key.isStrong { keys.insert(key) }
        }
        let primary = resolve(guid: guid, externalIDs: externalIDs, type: .movie,
                              title: title, year: year, edition: edition, identity: identity)
        if primary.isStrong { keys.insert(primary) }
        return keys
    }
}

extension MediaItem {
    var movieContentKeys: Set<ContentKey> {
        guard type == .movie, !isClip else { return [] }
        return ContentKey.movieKeys(guid: guid, externalIDs: externalIDs, title: title,
                                       year: year, edition: editionTitle, identity: id)
    }
}

extension MediaDetails {
    var movieContentKeys: Set<ContentKey> {
        guard type == .movie, !isClip else { return [] }
        return ContentKey.movieKeys(guid: guid, externalIDs: externalIDs, title: title,
                                       year: year, edition: editionTitle, identity: id)
    }
}
