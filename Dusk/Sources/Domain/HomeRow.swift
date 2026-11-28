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

/// A "hub" on the Plex home screen (e.g. "Continue Watching", "Recently Added Movies").
/// Returned from `GET /hubs`, `GET /hubs/sections/{sectionId}`, and `GET /hubs/search`.
struct HomeRow: Decodable, Sendable, Identifiable, Hashable {
    var id: String {
        // A merged row is identified by what made it one row. Its
        // representative's `hubIdentifier` carries *that* server's section id,
        // which another merged row's representative can carry too.
        if let mergeIdentity { return mergeIdentity }
        let base = hubIdentifier ?? title
        guard let serverID else { return base }
        return "\(serverID)|\(base)"
    }

    /// Stamped by `ServerPool.decoder(for:)`. nil once a row has been merged
    /// across servers — read `sources` in that case.
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

    enum CodingKeys: String, CodingKey {
        case key, title, type, hubIdentifier, size, more
        case libraryID = "librarySectionID", librarySectionTitle
        case metadata = "Metadata"
        case directories = "Directory"
    }

    /// `libraryID` and `librarySectionTitle` are required parameters on
    /// purpose: every call site has to decide what it means by them. Prefer
    /// `replacingItems(_:)` over calling this directly.
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
    }

    /// The `/library/sections` key this hub belongs to.
    ///
    /// Falls back to a section in the paging URL or the numeric suffix Plex appends to per-library hub
    /// identifiers (`movie.recentlyadded.3` -> `"3"`), which older servers send
    /// even when `libraryID` is missing from the payload. Global rows
    /// (`home.continue`, `home.ondeck`) have neither and resolve to nil.
    var resolvedLibrarySectionID: String? {
        if let libraryID = libraryID?.nilIfEmpty {
            return libraryID
        }
        // Some PMS versions only identify the section in the paging URL.
        if let key, let url = URLComponents(string: key) {
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
        guard let hubIdentifier,
              let suffix = hubIdentifier.split(separator: ".").last,
              !suffix.isEmpty,
              suffix.allSatisfy(\.isNumber) else { return nil }
        return String(suffix)
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
            serverID: sources.count == 1 ? sources[0].serverID : nil,
            sources: sources,
            mergeIdentity: identity
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let serverID = decoder.duskServerID
        self.serverID = serverID
        mergeIdentity = nil
        key = try container.decodeIfPresent(String.self, forKey: .key)
        title = try container.decode(String.self, forKey: .title)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        hubIdentifier = try container.decodeIfPresent(String.self, forKey: .hubIdentifier)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        more = try container.decodeIfPresent(Bool.self, forKey: .more) ??
            (try container.decodeIfPresent(Int.self, forKey: .more).map { $0 != 0 })
        // Plex serializes libraryID as a number; tolerate strings too.
        if let numericSectionID = try? container.decodeIfPresent(Int.self, forKey: .libraryID) {
            libraryID = String(numericSectionID)
        } else {
            libraryID = (try? container.decodeIfPresent(String.self, forKey: .libraryID)) ?? nil
        }
        librarySectionTitle = try container.decodeIfPresent(String.self, forKey: .librarySectionTitle)

        let metadataItems = try container.decodeLossyPlexItemsIfPresent(forKey: .metadata)
        let directoryItems = try container.decodeLossyPlexItemsIfPresent(forKey: .directories)
        items = metadataItems + directoryItems

        if let serverID {
            sources = [PlexHubSource(serverID: serverID, key: key, size: size, more: more, hubIdentifier: hubIdentifier)]
        } else {
            sources = []
        }
    }
}

private extension KeyedDecodingContainer where Key == HomeRow.CodingKeys {
    func decodeLossyPlexItemsIfPresent(forKey key: Key) throws -> [MediaItem] {
        guard contains(key), try !decodeNil(forKey: key) else { return [] }
        return try decode(LossyPlexItemArray.self, forKey: key).items
    }
}

private struct LossyPlexItemArray: Decodable {
    let items: [MediaItem]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var items: [MediaItem] = []

        while !container.isAtEnd {
            do {
                items.append(try container.decode(MediaItem.self))
            } catch {
                // Plex short-search responses can include suggestion directories that do not
                // conform to the media item shape the UI expects.
                _ = try container.decode(IgnoredJSONValue.self)
            }
        }

        self.items = items
    }
}

private struct IgnoredJSONValue: Decodable {
    init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            while !container.isAtEnd {
                _ = try container.decode(IgnoredJSONValue.self)
            }
            return
        }

        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            for key in container.allKeys {
                _ = try container.decode(IgnoredJSONValue.self, forKey: key)
            }
            return
        }

        let container = try decoder.singleValueContainer()

        if container.decodeNil() { return }
        if (try? container.decode(Bool.self)) != nil { return }
        if (try? container.decode(Int.self)) != nil { return }
        if (try? container.decode(Double.self)) != nil { return }
        if (try? container.decode(String.self)) != nil { return }

        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
