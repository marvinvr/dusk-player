import Foundation

/// An exact version, scoped to its owning item (media IDs alone are insufficient).
struct MoviePlaybackVersion: Identifiable, Sendable {
    struct ID: Hashable {
        let item: MediaItemID
        let mediaID: String
    }
    let details: MediaDetails
    let media: MediaVersion
    var id: ID { ID(item: details.id, mediaID: media.id) }

    var label: String { MediaTextFormatter.playbackVersionTitle(media) }

    var detail: String? {
        MediaTextFormatter.playbackVersionDetail(media, library: details.librarySectionTitle)
    }

    static func versions(in copies: [MediaDetails]) -> [MoviePlaybackVersion] {
        copies.flatMap { details in
            details.media.filter { !$0.parts.isEmpty }.map { MoviePlaybackVersion(details: details, media: $0) }
        }
    }

    static func mostAdvancedCopy(in copies: [MediaDetails]) -> MediaDetails? {
        copies.max { lhs, rhs in
            let watched = (lhs.playCount ?? 0) > 0
            let otherWatched = (rhs.playCount ?? 0) > 0
            if watched != otherWatched { return !watched }
            return Double(lhs.resumeOffsetMs ?? 0) / Double(max(lhs.duration ?? 1, 1))
                < Double(rhs.resumeOffsetMs ?? 0) / Double(max(rhs.duration ?? 1, 1))
        }
    }

    static func preferred(
        in copies: [MediaDetails], maxResolution: MaxResolution, preference: PreferredMediaVersion
    ) -> MoviePlaybackVersion? {
        let versions = versions(in: copies)
        guard let media = StreamResolver.selectMediaVersion(
            from: versions.map(\.media), preferredMaxResolution: maxResolution, preferredVersion: preference
        ) else { return nil }
        // Selection is per server; media IDs on a Plex server are unique.
        return versions.first { $0.media.id == media.id }
    }
}

extension MediaService {
    /// Per-title lookup also works when detail/play was opened from a library
    /// grid that deliberately did not merge its entries. Never scan a library.
    func movieCopies(
        for details: MediaDetails,
        includeOtherServers: Bool = true,
        checkFiles: Bool = false
    ) async -> [MediaDetails] {
        guard !details.movieContentKeys.isEmpty, let serverID = details.serverID else { return [details] }
        let session = serverSessionToken
        let hidden = await loadedHiddenLibraryFilter()
        let guids = ([details.guid].compactMap { $0?.nilIfEmpty }
            + details.externalIDs.uris.filter { ExternalIDs.value(of: $0, for: "tmdb") != nil || ExternalIDs.value(of: $0, for: "imdb") != nil })
        let matches = await withTaskGroup(of: [MediaItem].self) { group in
            for guid in Set(guids) {
                group.addTask { (try? await self.serverItems(guid: guid, serverID: serverID)) ?? [] }
            }
            var found: [MediaItem] = []
            for await items in group { found += items }
            return hidden.filtering(found).filter {
                !$0.movieContentKeys.isDisjoint(with: details.movieContentKeys)
            }.sorted { $0.itemID < $1.itemID }
        }
        guard !Task.isCancelled, session == serverSessionToken else { return [details] }
        let merged = MediaItemMerge.interleave([matches])
        registerAlternates(merged.alternates)
        // Teach the index about an item even if /library/all did not return it.
        if let matching = matches.first {
            let key = MediaItemMerge.contentKeys(in: [matches])[matching.id] ?? matching.contentKey
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
            if let copy = try? await getMediaDetails(itemID: id.itemID, checkFiles: checkFiles, serverID: server),
               !copy.movieContentKeys.isDisjoint(with: details.movieContentKeys),
               !hidden.hides(serverID: copy.serverID, libraryID: copy.libraryID) {
                copies.append(copy)
            }
        }
        guard !Task.isCancelled, session == serverSessionToken else { return [details] }
        return copies
    }
}
