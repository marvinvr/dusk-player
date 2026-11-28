import Foundation

/// One server's contribution to a hub row. A merged row keeps one of these per
/// server so "Show All" can page each source and re-merge the results.
struct PlexHubSource: Sendable, Hashable, Codable {
    let serverID: String
    /// The hub's own `key`, which is what pages the row on that server.
    let key: String?
    let size: Int?
    let more: Bool?
    /// That server's own `hubIdentifier`: a merged row keeps only its
    /// representative's, and hiding the row needs every server's.
    var hubIdentifier: String? = nil
}

/// A row on Home or a library's Recommended tab (e.g. "Continue Watching",
/// "Recently Added Movies"), and a search section.
///
/// What the row *is* — `kind`, `libraryScope`, `mergeKey`, `canHide` — is set
/// by the provider's mapper (`PlexHubMapper` reads Plex's identifiers and
/// titles), so Home, the merge and the arrangement read those and never parse
/// a server's strings themselves (docs/jellyfin/04-architecture.md §11).
struct HomeRow: Sendable, Identifiable, Hashable {
    var id: String {
        // A merged row is identified by what made it one row. Its
        // representative's `hubIdentifier` carries *that* server's section id,
        // which another merged row's representative can carry too.
        if let mergeIdentity { return mergeIdentity }
        let base = hubIdentifier ?? title
        guard let serverID else { return base }
        return "\(serverID)|\(base)"
    }

    /// Stamped by the provider's mapper (`PlexHubMapper`). nil once a row has
    /// been merged across servers — read `sources` in that case.
    let serverID: String?

    /// The merge key this row was assembled under, set by `HubMerge`. nil on a
    /// freshly decoded row, which is identified by its own server and hub id.
    let mergeIdentity: String?

    /// Every server this row draws from, in priority order. A freshly decoded
    /// hub has exactly one entry: itself.
    let sources: [PlexHubSource]

    let key: String?
    let title: String
    let type: String?
    let hubIdentifier: String?
    let size: Int?
    let more: Bool?
    /// Section this row belongs to. Present on `GET /hubs` rows that come from a
    /// library; absent on global rows such as Continue Watching.
    let libraryID: String?
    let librarySectionTitle: String?
    let items: [MediaItem]

    /// What the row is. Set by the mapper; kept through merges, which keep the
    /// representative's.
    let kind: Kind
    /// Which library the row belongs to, as far as its server said.
    let libraryScope: LibraryScope
    /// The row's identity across servers, before Home adds the library
    /// (`HubMerge.mergeKey(for:mode:)`).
    let mergeKey: String
    /// Whether this kind of row has a Home switch at all. Whether the user may
    /// flip it is the server's permission (`MediaService.canHideHomeRow`).
    let canHide: Bool

    /// `libraryID` and `librarySectionTitle` are required parameters on
    /// purpose: every call site has to decide what it means by them. So are
    /// the mapper's classification fields. Prefer `replacingItems(_:)` over
    /// calling this directly.
    init(
        key: String?,
        title: String,
        type: String?,
        hubIdentifier: String?,
        size: Int?,
        more: Bool?,
        libraryID: String?,
        librarySectionTitle: String?,
        items: [MediaItem],
        kind: Kind,
        libraryScope: LibraryScope,
        mergeKey: String,
        canHide: Bool,
        serverID: String? = nil,
        sources: [PlexHubSource] = [],
        mergeIdentity: String? = nil
    ) {
        self.serverID = serverID
        self.mergeIdentity = mergeIdentity
        self.sources = sources
        self.key = key
        self.title = title
        self.type = type
        self.hubIdentifier = hubIdentifier
        self.size = size
        self.more = more
        self.libraryID = libraryID
        self.librarySectionTitle = librarySectionTitle
        self.items = items
        self.kind = kind
        self.libraryScope = libraryScope
        self.mergeKey = mergeKey
        self.canHide = canHide
    }

    /// The `/library/sections` key this row belongs to, or nil for a global
    /// row (Continue Watching) or a library row whose server named no section.
    var resolvedLibrarySectionID: String? {
        if case .section(let sectionID) = libraryScope { return sectionID }
        return nil
    }

    /// Same hub with a different item list; every other field is preserved.
    /// Use this instead of the memberwise init so new fields never get dropped.
    func replacingItems(_ items: [MediaItem]) -> HomeRow {
        HomeRow(
            key: key,
            title: title,
            type: type,
            hubIdentifier: hubIdentifier,
            size: size,
            more: more,
            libraryID: libraryID,
            librarySectionTitle: librarySectionTitle,
            items: items,
            kind: kind,
            libraryScope: libraryScope,
            mergeKey: mergeKey,
            canHide: canHide,
            serverID: serverID,
            sources: sources,
            mergeIdentity: mergeIdentity
        )
    }

    /// Same hub carrying a merged item list and the sources it was merged from.
    /// `serverID` is dropped because the row no longer belongs to one server.
    ///
    /// `key`, `size` and `more` keep the representative server's values and are
    /// meaningless on a merged row: they describe one source, not the merge.
    /// Ask `sources` instead — `isPageable`, `hasMoreOnAnySource`,
    /// `totalSourceSize` (`MultiServer/HubMerge.swift`).
    /// - Parameter identity: the merge key, which becomes the row's `id`.
    func merged(items: [MediaItem], sources: [PlexHubSource], identity: String? = nil) -> HomeRow {
        HomeRow(
            key: key,
            title: title,
            type: type,
            hubIdentifier: hubIdentifier,
            size: size,
            more: more,
            libraryID: libraryID,
            librarySectionTitle: librarySectionTitle,
            items: items,
            kind: kind,
            libraryScope: libraryScope,
            mergeKey: mergeKey,
            canHide: canHide,
            serverID: sources.count == 1 ? sources[0].serverID : nil,
            sources: sources,
            mergeIdentity: identity
        )
    }
}

extension HomeRow {
    /// What a row is (docs/jellyfin/04-architecture.md §11).
    enum Kind: Sendable, Hashable {
        /// The server's Continue Watching row. Home shows it as the hero.
        case continueWatching
        /// The next episodes of shows in progress (Plex's On Deck), also the hero's.
        case nextUp
        /// Playlists, which are not a Home destination.
        case playlists
        /// Recently Added, of one library or of every library of a type.
        case recentlyAdded
        case other
    }

    /// Which library a row belongs to.
    enum LibraryScope: Sendable, Hashable {
        /// A `/library/sections` key on the row's server.
        case section(String)
        /// A library row whose server named no section: Home places it by its
        /// items' library. `recentlyAddedKind` is set on a type-wide Recently
        /// Added row, which the only library of that kind on its server may
        /// claim when the items do not say.
        case unresolved(recentlyAddedKind: LibraryKind?)
        /// Not a library's row (Continue Watching, playlists, account rows).
        case global
    }

    /// A title as rows compare them: case and diacritics folded, letters and
    /// digits only ("Oh, the Horror!" → "ohthehorror").
    static func normalizedTitle(_ value: String) -> String {
        String(
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .filter { $0.isLetter || $0.isNumber }
        )
    }
}
