import Foundation

/// One entry of `experience.sidebarSettings.pinnedSources` on plex.tv.
///
/// The array is the Plex account's single, flat, ordered list of pinned sources
/// across *every* server and cloud provider. Array position is the sidebar
/// order; `isHidden` soft-hides an entry without removing it.
///
/// `raw` is the element exactly as plex.tv sent it; the typed fields are only a
/// read view over it. Writes reuse `raw`, so fields Dusk does not model
/// (`directoryIcon`, `providerSourceTitle`, `hiddenAt`, anything a newer Plex
/// client adds) round-trip intact.
struct PlexPinnedSource: Sendable, Hashable, Identifiable {
    /// `providerIdentifier` of a real PMS library section. Cloud entries use
    /// `tv.plex.provider.discover` / `.vod` / `.epg` instead.
    static let libraryProviderIdentifier = "com.plexapp.plugins.library"

    var id: String { key }

    let key: String
    let sourceType: String
    let machineIdentifier: String
    let providerIdentifier: String
    /// The `/library/sections` key (`"3"`) for PMS libraries; `"home"`,
    /// `"watchlist"`, … for cloud providers.
    let directoryID: String?
    let title: String
    let isHidden: Bool
    let raw: DuskJSONValue

    private init(
        key: String,
        sourceType: String,
        machineIdentifier: String,
        providerIdentifier: String,
        directoryID: String?,
        title: String,
        isHidden: Bool,
        raw: DuskJSONValue
    ) {
        self.key = key
        self.sourceType = sourceType
        self.machineIdentifier = machineIdentifier
        self.providerIdentifier = providerIdentifier
        self.directoryID = directoryID
        self.title = title
        self.isHidden = isHidden
        self.raw = raw
    }

    /// Deliberately lenient: anything object-shaped becomes a `PlexPinnedSource`
    /// so it survives the next write. Returning nil here means the entry is
    /// dropped from the blob, which would destroy part of the user's Plex Web
    /// setup, so only a non-object element fails.
    init?(raw: DuskJSONValue) {
        guard let object = raw.objectValue else { return nil }

        let sourceType = object["sourceType"]?.stringOrNumberValue ?? ""
        let machineIdentifier = object["machineIdentifier"]?.stringOrNumberValue ?? ""
        let providerIdentifier = object["providerIdentifier"]?.stringOrNumberValue ?? ""
        let directoryID = object["directoryID"]?.stringOrNumberValue?.nilIfEmpty

        let key = object["key"]?.stringOrNumberValue?.nilIfEmpty ?? Self.makeKey(
            sourceType: sourceType,
            machineIdentifier: machineIdentifier,
            providerIdentifier: providerIdentifier,
            directoryID: directoryID
        )

        self.init(
            key: key,
            sourceType: sourceType,
            machineIdentifier: machineIdentifier,
            providerIdentifier: providerIdentifier,
            directoryID: directoryID,
            title: object["title"]?.stringOrNumberValue ?? "",
            isHidden: object["isHidden"]?.boolValue ?? false,
            raw: raw
        )
    }

    /// Builds the entry Plex Web would create for a library that has never been
    /// pinned. Only used when the user reorders a section that is missing from
    /// the blob (fresh account, or a library added after the last sync).
    static func make(library: Library, server: PlexServer) -> PlexPinnedSource {
        // `Library.type` is "movie" for Other Videos sections too, so the
        // resolved library type decides between "movies" and "videos".
        let sourceType = library.libraryType == .video
            ? "videos"
            : sourceType(forSectionType: library.type)
        let key = makeKey(
            sourceType: sourceType,
            machineIdentifier: server.clientIdentifier,
            providerIdentifier: libraryProviderIdentifier,
            directoryID: library.key
        )

        let raw = DuskJSONValue.object([
            "key": .string(key),
            "sourceType": .string(sourceType),
            "machineIdentifier": .string(server.clientIdentifier),
            "providerIdentifier": .string(libraryProviderIdentifier),
            "directoryID": .string(library.key),
            "title": .string(library.title),
            "serverFriendlyName": .string(server.name),
            "isCloud": .bool(false),
            "isFullOwnedServer": .bool(server.owned),
            "isHidden": .bool(false),
        ])

        return PlexPinnedSource(
            key: key,
            sourceType: sourceType,
            machineIdentifier: server.clientIdentifier,
            providerIdentifier: libraryProviderIdentifier,
            directoryID: library.key,
            title: library.title,
            isHidden: false,
            raw: raw
        )
    }

    /// `["source", sourceType, machineIdentifier, providerIdentifier, directoryID]`
    /// joined with `--`, dropping empty components — the exact format Plex Web
    /// uses as the collection's id attribute.
    static func makeKey(
        sourceType: String,
        machineIdentifier: String,
        providerIdentifier: String,
        directoryID: String?
    ) -> String {
        ["source", sourceType, machineIdentifier, providerIdentifier, directoryID ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: "--")
    }

    /// `/library/sections` type -> Plex sidebar `sourceType`.
    static func sourceType(forSectionType type: String) -> String {
        switch type {
        case "movie": "movies"
        case "show": "tv"
        case "artist": "music"
        case "photo": "photos"
        case "clip": "videos"
        default: "unknown"
        }
    }

    /// True for an entry that points at a library section of a Plex Media
    /// Server (as opposed to Discover, Watchlist, or a VOD/EPG provider).
    var isPMSLibrary: Bool { providerIdentifier == Self.libraryProviderIdentifier }

    /// Returns the same entry with a refreshed title, leaving every other raw
    /// field untouched. Used on write so a library renamed on the server does
    /// not keep its stale sidebar title.
    func updatingTitle(_ newTitle: String) -> PlexPinnedSource {
        guard title != newTitle, raw.objectValue != nil else { return self }
        var updatedRaw = raw
        updatedRaw["title"] = .string(newTitle)
        return PlexPinnedSource(
            key: key,
            sourceType: sourceType,
            machineIdentifier: machineIdentifier,
            providerIdentifier: providerIdentifier,
            directoryID: directoryID,
            title: newTitle,
            isHidden: isHidden,
            raw: updatedRaw
        )
    }

    /// Returns the same entry with `isHidden` set, leaving every other raw
    /// field untouched. Used on write when the user hides or shows a library.
    func updatingHidden(_ newIsHidden: Bool) -> PlexPinnedSource {
        guard isHidden != newIsHidden, raw.objectValue != nil else { return self }
        var updatedRaw = raw
        updatedRaw["isHidden"] = .bool(newIsHidden)
        return PlexPinnedSource(
            key: key,
            sourceType: sourceType,
            machineIdentifier: machineIdentifier,
            providerIdentifier: providerIdentifier,
            directoryID: directoryID,
            title: title,
            isHidden: newIsHidden,
            raw: updatedRaw
        )
    }
}
