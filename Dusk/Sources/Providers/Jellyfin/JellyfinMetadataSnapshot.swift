import Foundation

/// Jellyfin's offline metadata snapshot (docs/jellyfin/04-architecture.md
/// §15.3): the raw server answers the online screens decode, wrapped in an
/// envelope `{"provider":"jellyfin","schema":1,"payload":…}`. A bare payload
/// is always Plex's.
///
/// - `.details(id)`: `payload` is `GET /Items/{id}`, plus `segments`, the
///   item's `/MediaSegments`, so skip buttons work offline.
/// - `.children(id)`: `payload` is the request the catalog makes for that
///   kind: a series' `/Shows/{id}/Seasons`, a season's episodes from `/Items`.
///
/// **Wire format.** `storageName(for:)` names the cache file (SHA-256 of it)
/// and the envelope is read back by later builds: neither may change once
/// shipped. A new layout bumps `schema` and keeps reading the old one.
struct JellyfinMetadataSnapshotFormat: MetadataSnapshotFormat {
    static let provider = "jellyfin"
    static let schema = 1

    var kind: ProviderKind { .jellyfin }

    func storageName(for key: MetadataSnapshotKey) -> String {
        switch key {
        case .details(let itemID): "jellyfin:/Items/\(JellyfinID.normalized(itemID))"
        case .children(let itemID): "jellyfin:/Items/\(JellyfinID.normalized(itemID))/children"
        }
    }

    func details(from data: Data, serverID: String) throws -> [MediaDetails] {
        let envelope = try Self.decode(JellyfinItemDTO.self, from: data)
        let markers = JellyfinMediaMapper.markers(envelope.segments?.items ?? [])
        return [JellyfinItemMapper.mapDetails(envelope.payload, serverID: serverID, markers: markers)]
    }

    func seasons(from data: Data, serverID: String) throws -> [Season] {
        try Self.decode(JellyfinAPI.Items.self, from: data).payload.items
            .filter { $0.type?.matches(.season) == true }
            .map { JellyfinItemMapper.mapSeason($0, serverID: serverID) }
    }

    func episodes(from data: Data, serverID: String) throws -> [Episode] {
        try Self.decode(JellyfinAPI.Items.self, from: data).payload.items
            .filter { $0.type?.matches(.episode) == true }
            .map { JellyfinItemMapper.mapEpisode($0, serverID: serverID) }
    }

    // MARK: Envelope

    /// Wraps raw JSON answers without re-encoding them, so the stored payload
    /// is byte for byte what the server sent. Both must already be valid JSON
    /// (they were decoded once by their request).
    static func envelope(payload: Data, segments: Data? = nil) -> Data {
        var data = Data(#"{"provider":"\#(provider)","schema":\#(schema),"payload":"#.utf8)
        data.append(payload)
        if let segments {
            data.append(Data(#","segments":"#.utf8))
            data.append(segments)
        }
        data.append(Data("}".utf8))
        return data
    }

    private struct Envelope<Payload: Decodable>: Decodable {
        let provider: String
        let schema: Int
        let payload: Payload
        let segments: JellyfinQueryResult<JellyfinMediaSegmentDTO>?
    }

    private static func decode<Payload: Decodable>(_ type: Payload.Type, from data: Data) throws -> Envelope<Payload> {
        let envelope = try JellyfinJSON.decode(Envelope<Payload>.self, from: data)
        guard envelope.provider == provider, envelope.schema <= schema else {
            throw JellyfinError.unexpectedResponse("snapshot of \(envelope.provider) schema \(envelope.schema)")
        }
        return envelope
    }
}

extension JellyfinProviderFactory: MetadataSnapshotFormatProviding {
    var metadataSnapshotFormat: any MetadataSnapshotFormat { JellyfinMetadataSnapshotFormat() }
}

// MARK: - Fetching

extension JellyfinMetadataSnapshotFormat {
    /// The enveloped payload for `key`, from the same requests the online
    /// screens make (`JellyfinCatalog.details`, `.seasons`, `.episodes`).
    static func fetch(_ key: MetadataSnapshotKey, client: JellyfinClient) async throws -> Data {
        switch key {
        case .details(let itemID):
            async let segments = try? client.send(JellyfinAPI.mediaSegments(itemID: itemID).raw())
            let item = try await client.send(JellyfinAPI.item(id: itemID).raw())
            return envelope(payload: item, segments: await segments)
        case .children(let itemID):
            return envelope(payload: try await client.send(childrenRequest(of: itemID, client: client)))
        }
    }

    /// A series' children are its seasons, a season's its episodes; the key
    /// does not say which, so the item's type is read first.
    private static func childrenRequest(of itemID: String, client: JellyfinClient) async throws -> JellyfinRequest<Data> {
        var lookup = JellyfinItemQuery()
        lookup.ids = [itemID]
        lookup.enableUserData = false
        lookup.enableImages = false
        guard let type = try await client.send(JellyfinAPI.items(lookup)).items.first?.type else {
            throw JellyfinError.unexpectedResponse("no item \(itemID)")
        }
        if type.matches(.series) {
            return JellyfinAPI.seasons(seriesID: itemID, fields: [.childCount, .recursiveItemCount, .dateCreated]).raw()
        }
        // `JellyfinCatalog.episodes(seasonID:)`'s query.
        var query = JellyfinItemQuery()
        query.parentID = itemID
        query.includeItemTypes = [.episode]
        query.isMissing = false
        query.sortBy = [.parentIndexNumber, .indexNumber, .sortName]
        query.fields = [.overview, .dateCreated, .providerIDs]
        return JellyfinAPI.items(query).raw()
    }
}

extension JellyfinRequest {
    /// The same call answering its raw body, once `self`'s own decode and
    /// checks have passed.
    func raw() -> JellyfinRequest<Data> {
        let decode = self.decode
        let rawAuthentication: JellyfinRequest<Data>.Authentication = switch self.authentication {
        case .none: .none
        case .token: .token
        }
        return JellyfinRequest<Data>(
            method: method, path: path, query: query, authentication: rawAuthentication,
            isUserScoped: isUserScoped, timeout: timeout, body: body
        ) { data, context in
            _ = try decode(data, context)
            return data
        }
    }
}
