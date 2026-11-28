import Foundation

/// Plex hub rows → `HomeRow`, and Manage Recommendations entries →
/// `PlexManagedHub`.
///
/// This is where Plex's row strings are read. Home, `HubMerge` and
/// `HomeHubArrangement` used to parse `hubIdentifier`, `key` and titles
/// themselves; the same rules now run here once, at mapping time, and set the
/// row's `kind`, `libraryScope`, `mergeKey` and `canHide`
/// (docs/jellyfin/04-architecture.md §11). They read only fields a merge keeps
/// from its representative, so a merged row classifies exactly as its
/// representative did. Pinned by `PlexHubFixtureTests`.
enum PlexHubMapper {
    /// A freshly fetched row belongs to exactly one server, so it carries one
    /// `sources` entry for it; an unstamped row has none.
    static func map(_ dto: PlexHubDTO, serverID: String?) -> HomeRow {
        let serverID = serverID?.nilIfEmpty
        let sources: [PlexHubSource]
        if let serverID {
            sources = [PlexHubSource(
                serverID: serverID,
                key: dto.key,
                size: dto.size,
                more: dto.more,
                hubIdentifier: dto.hubIdentifier
            )]
        } else {
            sources = []
        }
        let kind = kind(of: dto)
        return HomeRow(
            key: dto.key,
            title: dto.title,
            type: dto.type,
            hubIdentifier: dto.hubIdentifier,
            size: dto.size,
            more: dto.more,
            libraryID: dto.librarySectionID,
            librarySectionTitle: dto.librarySectionTitle,
            items: dto.items.map { PlexItemMapper.map($0, serverID: serverID) },
            kind: kind,
            libraryScope: libraryScope(of: dto, kind: kind),
            mergeKey: mergeKey(of: dto),
            canHide: canHide(dto),
            serverID: serverID,
            sources: sources,
            mergeIdentity: nil
        )
    }

    // MARK: - Row rules

    /// Plex's own continue-watching and on-deck rows (covered by Home's
    /// hero) and playlist rows, by any of title, key or identifier; otherwise
    /// Recently Added by title.
    static func kind(of dto: PlexHubDTO) -> HomeRow.Kind {
        let fields = [dto.title, dto.key, dto.hubIdentifier]
            .compactMap { $0?.lowercased() }

        if fields.contains(where: { $0.contains("continue watching") || $0.contains("continuewatching") }) {
            return .continueWatching
        }
        if fields.contains(where: { $0.contains("on deck") || $0.contains("ondeck") }) {
            return .nextUp
        }
        if fields.contains(where: { $0.contains("playlist") || $0.contains("playlists") }) {
            return .playlists
        }
        if dto.title.lowercased().contains("recently added") {
            return .recentlyAdded
        }
        return .other
    }

    /// The section a row names, else whether it is a library row at all.
    ///
    /// A row without a section is a library row when it is a Recently Added
    /// row by identifier or key, names its library, or carries a per-library
    /// identifier prefix. Hidden kinds, `mixed` rows and the account's
    /// continue/on-deck rows never are. Older PMS also has type-wide Recently
    /// Added rows without section metadata; their row type says which kind of
    /// library may claim them.
    static func libraryScope(of dto: PlexHubDTO, kind: HomeRow.Kind) -> HomeRow.LibraryScope {
        if let sectionID = sectionID(of: dto) { return .section(sectionID) }

        let identifier = dto.hubIdentifier?.lowercased() ?? ""
        let isHidden = kind == .continueWatching || kind == .nextUp || kind == .playlists
        guard !isHidden, dto.type != "mixed",
              !identifier.hasPrefix("home.continue"),
              !identifier.hasPrefix("home.ondeck") else { return .global }

        let fields = [dto.hubIdentifier, dto.key].compactMap { $0?.lowercased() }
        let isRecentlyAdded = fields.contains { $0.contains("recentlyadded") }
        let isLibraryRow = isRecentlyAdded || dto.librarySectionTitle?.nilIfEmpty != nil ||
            ["movie.", "tv.", "show.", "season.", "episode.", "library."].contains { identifier.hasPrefix($0) }
        guard isLibraryRow else { return .global }

        guard isRecentlyAdded else { return .unresolved(recentlyAddedKind: nil) }
        let libraryKind: LibraryKind?
        switch dto.type {
        case "movie": libraryKind = .movie
        case "show", "season", "episode": libraryKind = .show
        case "clip": libraryKind = .video
        default: libraryKind = nil
        }
        return .unresolved(recentlyAddedKind: libraryKind)
    }

    /// The `/library/sections` key a row belongs to.
    ///
    /// Falls back to a section in the paging URL or the numeric suffix Plex
    /// appends to per-library hub identifiers (`movie.recentlyadded.3` ->
    /// `"3"`), which older servers send even when `librarySectionID` is
    /// missing from the payload. Global rows (`home.continue`, `home.ondeck`)
    /// have neither and resolve to nil.
    static func sectionID(of dto: PlexHubDTO) -> String? {
        if let libraryID = dto.librarySectionID?.nilIfEmpty {
            return libraryID
        }
        // Some PMS versions only identify the section in the paging URL.
        if let key = dto.key, let url = URLComponents(string: key) {
            let path = url.path.split(separator: "/")
            if let sections = path.firstIndex(of: "sections"),
               path.indices.contains(sections + 1) {
                return String(path[sections + 1])
            }
            if let sectionID = url.queryItems?.first(where: {
                $0.name == "librarySectionID" || $0.name == "sectionID"
            })?.value?.nilIfEmpty {
                return sectionID
            }
        }
        guard let hubIdentifier = dto.hubIdentifier,
              let suffix = hubIdentifier.split(separator: ".").last,
              !suffix.isEmpty,
              suffix.allSatisfy(\.isNumber) else { return nil }
        return String(suffix)
    }

    /// The hub identifier without its per-server section suffix plus the
    /// row's type. Plex names a per-library hub `"<type>.<name>.<sectionID>"`
    /// and the section id is a per-server counter, so the suffix has to go
    /// before two servers' rows can be compared. Rows with no identifier (some
    /// servers omit it on `/hubs/sections`) fall back to the title.
    static func mergeKey(of dto: PlexHubDTO) -> String {
        let type = dto.type ?? "-"

        if let hubIdentifier = dto.hubIdentifier?.nilIfEmpty {
            var components = hubIdentifier.split(separator: ".").map(String.init)
            if let last = components.last, !last.isEmpty, last.allSatisfy(\.isNumber) {
                components.removeLast()
            }
            let stripped = components.joined(separator: ".").nilIfEmpty ?? hubIdentifier
            return "id:\(stripped.lowercased())|\(type)"
        }
        return "title:\(HomeRow.normalizedTitle(dto.title))|\(type)"
    }

    /// Account-wide rows (`home.*`: Continue Watching, the type-wide Recently
    /// Added) are not in any library's Manage Recommendations list.
    static func canHide(_ dto: PlexHubDTO) -> Bool {
        guard let identifier = dto.hubIdentifier else { return false }
        return !identifier.hasPrefix("home.")
    }

    // MARK: - Managed Home rows

    static func managedHub(_ dto: PlexManagedHubDTO) -> PlexManagedHub {
        PlexManagedHub(
            identifier: dto.identifier,
            title: dto.title,
            promotedToRecommended: dto.promotedToRecommended,
            promotedToOwnHome: dto.promotedToOwnHome,
            promotedToSharedHome: dto.promotedToSharedHome
        )
    }
}

extension PlexItemMapper {
    /// Kept for the callers that map a hub through `PlexItemMapper`:
    /// `PlexItemDecodingBridge` (`HomeRow: Decodable`), search, tests.
    static func map(_ dto: PlexHubDTO, serverID: String?) -> HomeRow {
        PlexHubMapper.map(dto, serverID: serverID)
    }
}
