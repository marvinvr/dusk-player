import Foundation

/// Extras and search rows (02 §6, §7).
extension JellyfinItemMapper {
    // MARK: Extras

    /// `ExtraType` → the extra's card label. Theme videos and songs loop
    /// behind a page in other clients; they are not extras.
    static func extraKind(_ type: JellyfinExtraType?) -> ExtraKind? {
        guard let type else { return .other }
        let table: [(JellyfinExtraType, ExtraKind)] = [
            (.trailer, .trailer), (.behindTheScenes, .behindTheScenes), (.deletedScene, .deletedScene),
            (.interview, .interview), (.featurette, .featurette), (.scene, .sceneOrSample),
            (.sample, .sceneOrSample), (.short, .short), (.clip, .other),
        ]
        if let kind = table.first(where: { type.matches($0.0) })?.1 { return kind }
        if type.matches(.themeVideo) || type.matches("ThemeSong") { return nil }
        return .other
    }

    /// The first web trailer with an https link (`RemoteTrailers`, mostly
    /// YouTube).
    static func remoteTrailerURL(_ dto: JellyfinItemDTO) -> URL? {
        dto.remoteTrailers?.lazy
            .compactMap { $0.url.flatMap(URL.init(string:)) }
            .first { $0.scheme?.lowercased() == "https" && $0.host != nil }
    }

    // MARK: Lookups and history

    /// The item types a domain kind names; nil is films and shows.
    static func itemTypes(matching kind: MediaKind?) -> [JellyfinItemKind] {
        switch kind {
        case .movie: [.movie]
        case .show: [.series]
        case .season: [.season]
        case .episode: [.episode]
        case .clip: [.video]
        default: [.movie, .series]
        }
    }

    /// A played title as a history entry; nil until it was played.
    static func historyEntry(_ dto: JellyfinItemDTO, serverID: String, libraryID: String?) -> PlaybackHistoryEntry? {
        guard let viewedAt = epochSeconds(dto.userData?.lastPlayedDate) else { return nil }
        let item = map(dto, serverID: serverID, libraryID: libraryID)
        return PlaybackHistoryEntry(
            serverID: item.serverID,
            historyKey: nil,
            itemID: item.itemID,
            libraryID: item.libraryID,
            parentID: item.parentID,
            grandparentID: item.grandparentID,
            type: item.type,
            title: item.title,
            parentTitle: item.parentTitle,
            grandparentTitle: item.grandparentTitle,
            viewedAt: viewedAt,
            accountID: nil
        )
    }

    // MARK: Search

    /// One search group: the item types asked for and the row Plex's
    /// `/hubs/search` names for them (`SearchMerge` groups by `type`).
    struct SearchGroup: Sendable {
        let types: [JellyfinItemKind]
        let type: String
        let title: String
    }

    /// Plex sends films and videos in one hub; `SearchSection` splits the
    /// videos off.
    static let searchGroups: [SearchGroup] = [
        SearchGroup(types: [.movie, .video], type: "movie", title: "Movies"),
        SearchGroup(types: [.series], type: "show", title: "Shows"),
        SearchGroup(types: [.episode], type: "episode", title: "Episodes"),
    ]

    static func searchRow(_ group: SearchGroup, items: [MediaItem], serverID: String) -> HomeRow {
        HomeRow(
            key: nil,
            title: group.title,
            type: group.type,
            hubIdentifier: group.type,
            size: items.count,
            more: false,
            libraryID: nil,
            librarySectionTitle: nil,
            items: items,
            kind: .other,
            libraryScope: .global,
            mergeKey: group.type,
            canHide: false,
            serverID: serverID,
            sources: [HomeRowSource(serverID: serverID, key: nil, size: items.count, more: false, hubIdentifier: group.type)]
        )
    }
}
