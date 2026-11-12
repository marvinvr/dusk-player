import Foundation

/// An exact version, scoped to its owning item (media IDs alone are insufficient).
struct MoviePlaybackVersion: Identifiable, Sendable {
    struct ID: Hashable {
        let item: PlexItemID
        let mediaID: Int
    }
    let details: PlexMediaDetails
    let media: PlexMedia
    var id: ID { ID(item: details.id, mediaID: media.id) }

    var label: String {
        MediaTextFormatter.movieCopyVersionLabel(media, library: details.librarySectionTitle)
    }

    static func versions(in copies: [PlexMediaDetails]) -> [MoviePlaybackVersion] {
        copies.flatMap { details in
            details.media.filter { !$0.parts.isEmpty }.map { MoviePlaybackVersion(details: details, media: $0) }
        }
    }

    static func mostAdvancedCopy(in copies: [PlexMediaDetails]) -> PlexMediaDetails? {
        copies.max { lhs, rhs in
            let watched = (lhs.viewCount ?? 0) > 0
            let otherWatched = (rhs.viewCount ?? 0) > 0
            if watched != otherWatched { return !watched }
            return Double(lhs.viewOffset ?? 0) / Double(max(lhs.duration ?? 1, 1))
                < Double(rhs.viewOffset ?? 0) / Double(max(rhs.duration ?? 1, 1))
        }
    }

    static func preferred(
        in copies: [PlexMediaDetails], maxResolution: MaxResolution, preference: PreferredMediaVersion
    ) -> MoviePlaybackVersion? {
        let versions = versions(in: copies)
        guard let media = StreamResolver.selectMediaVersion(
            from: versions.map(\.media), preferredMaxResolution: maxResolution, preferredVersion: preference
        ) else { return nil }
        // Selection is per server; media IDs on a Plex server are unique.
        return versions.first { $0.media.id == media.id }
    }
}

extension PlexService {
    /// Per-title lookup also works when detail/play was opened from a library
    /// grid that deliberately did not merge its entries. Never scan a library.
    func movieCopies(
        for details: PlexMediaDetails,
        includeOtherServers: Bool = true,
        checkFiles: Bool = false
    ) async -> [PlexMediaDetails] {
        guard !details.movieContentKeys.isEmpty, let serverID = details.serverID else { return [details] }
        let session = serverSessionToken
        let hidden = await loadedHiddenLibraryFilter()
        let guids = ([details.guid].compactMap { $0?.nilIfEmpty }
            + details.guids.filter { $0.value(for: "tmdb") != nil || $0.value(for: "imdb") != nil }.map(\.id))
        let matches = await withTaskGroup(of: [PlexItem].self) { group in
            for guid in Set(guids) {
                group.addTask { (try? await self.serverItems(guid: guid, serverID: serverID)) ?? [] }
            }
            var found: [PlexItem] = []
            for await items in group { found += items }
            return hidden.filtering(found).filter {
                !$0.movieContentKeys.isDisjoint(with: details.movieContentKeys)
            }.sorted { $0.ratingKey < $1.ratingKey }
        }
        guard !Task.isCancelled, session == serverSessionToken else { return [details] }
        let merged = PlexItemMerge.interleave([matches])
        registerAlternates(merged.alternates)
        // Teach the index about an item even if /library/all did not return it.
        if let matching = matches.first {
            let key = PlexItemMerge.contentKeys(in: [matches])[matching.id] ?? matching.contentKey
            alternates.register([details.id] + matches.map(\.id), for: key)
        } else {
            alternates.register([details.id], for: details.contentKey)
        }
        var copies = [details]
        // Cross-server copies already found by Home/search are included in the
        // detail picker. Startup ranks versions only within its chosen server.
        for id in alternates.instances(of: details.id) where id != details.id {
            if !includeOtherServers, id.serverID != serverID { continue }
            guard let server = id.serverID, pool.connection(for: server) != nil else { continue }
            if let copy = try? await getMediaDetails(ratingKey: id.ratingKey, checkFiles: checkFiles, serverID: server),
               !copy.movieContentKeys.isDisjoint(with: details.movieContentKeys),
               !hidden.hides(serverID: copy.serverID, librarySectionID: copy.librarySectionID) {
                copies.append(copy)
            }
        }
        guard !Task.isCancelled, session == serverSessionToken else { return [details] }
        return copies
    }
}
