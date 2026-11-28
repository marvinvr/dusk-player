import Foundation
import OSLog

/// Facade routes that only Plex has a shape for yet: the Live TV stream
/// consumers and the playback request helpers the coordinator and tests use,
/// pre-roll filtering, the raw catalog routes whose callers still pass Plex
/// sort strings and `/filters` parameters, the raw details payload the offline
/// cache stores, and the image URL forwarders `+Photos` and the transport tests
/// use. Each moves behind a neutral facet member when a second provider needs
/// it (05-plan P0-19, left for J packages).
extension MediaService {
    /// The Plex facet itself, for the Live TV consumers only Plex has.
    private func plexPlayback(for serverID: String?) -> PlexPlayback {
        PlexPlayback(client: client, serverID: serverID, router: plexAccount.router)
    }

    /// Starts an HLS consumer for an already-tuned Live TV session.
    func liveTVStreamURL(
        sessionPath: String,
        sessionIdentifier: String,
        transcodeSessionID: String,
        serverID: String? = nil
    ) async throws -> ServerStream {
        try await plexPlayback(for: serverID).liveStream(
            sessionPath: sessionPath,
            sessionIdentifier: sessionIdentifier,
            transcodeSessionID: transcodeSessionID
        )
    }

    /// Live TV direct play of the tuned session's own HLS; nil when the server
    /// does not offer it (see `PlexPlayback.liveDirectPlayURL`).
    func liveTVDirectPlayURL(
        sessionPath: String,
        sessionIdentifier: String,
        serverID: String
    ) async -> URL? {
        await plexPlayback(for: serverID).liveDirectPlayURL(
            sessionPath: sessionPath,
            sessionIdentifier: sessionIdentifier
        )
    }

    func sanitizedPlaybackURLString(for url: URL) -> String {
        PlaybackURLRedaction.redacted(PlexPlayback.sanitizedURLString(for: url))
    }

    /// Pure request construction (`PlexPlayback.transcodeQueryItems`) with
    /// this service's client identifier, for the codec-policy tests.
    func transcodeQueryItems(
        itemID: String,
        mediaIndex: Int,
        sourcePath: String?,
        intent: StreamIntent,
        sessionIdentifier: String,
        transcodeSessionID: String,
        audioStreamID: String?,
        subtitleStreamID: String?,
        token: String?,
        av1Capabilities: AV1PlaybackCapabilities = .current
    ) -> [URLQueryItem] {
        PlexPlayback.transcodeQueryItems(
            itemID: itemID,
            mediaIndex: mediaIndex,
            sourcePath: sourcePath,
            intent: intent,
            sessionIdentifier: sessionIdentifier,
            transcodeSessionID: transcodeSessionID,
            audioStreamID: audioStreamID,
            subtitleStreamID: subtitleStreamID,
            token: token,
            clientIdentifier: clientIdentifier,
            av1Capabilities: av1Capabilities
        )
    }

    /// Everything the queue puts in front of the movie. Only clips count: a
    /// queue that somehow led with anything else is not a pre-roll queue.
    static func prerollItems(in queue: [MediaDetails], featureRatingKey: String) -> [MediaDetails] {
        PlexPlayback.prerollItems(in: queue, featureRatingKey: featureRatingKey)
    }

    static var liveTVDiscoveryTimeout: TimeInterval { PlexLiveTV.discoveryTimeout }

    /// The Plex catalog itself, for the routes whose callers still pass Plex
    /// sort strings and filter parameters.
    func plexCatalog(on serverID: String) -> PlexCatalog {
        PlexCatalog(serverID: serverID, transport: plexAccount.router)
    }

    /// A page of a library in a Plex `sort` (`titleSort`, `addedAt:desc`, …)
    /// with Plex filter parameters. For the callers that still build their
    /// own (recommendation shelves, Siri, video channels); the grid uses
    /// `libraryItems(in:…)`.
    func getLibraryItems(
        sectionId: String,
        start: Int = 0,
        size: Int = 50,
        sort: String? = nil,
        filters: [String: String] = [:],
        serverID: String? = nil
    ) async throws -> [MediaItem] {
        try await plexCatalog(on: resolveServerID(serverID))
            .rawItems(libraryID: sectionId, start: start, size: size, sort: sort, filters: filters)
    }

    /// How many titles a library has under Plex filter parameters.
    func getLibraryItemCount(
        sectionId: String,
        filters: [String: String] = [:],
        serverID: String? = nil
    ) async throws -> Int {
        try await plexCatalog(on: resolveServerID(serverID)).rawItemCount(libraryID: sectionId, filters: filters)
    }

    /// The raw details payload, for the offline metadata cache. The same
    /// request `getMediaDetails` makes.
    func getMediaDetailsPayload(
        itemID: String,
        checkFiles: Bool = false,
        serverID: String? = nil
    ) async throws -> Data {
        var queryItems = [
            URLQueryItem(name: "includeMarkers", value: "1"),
            URLQueryItem(name: "includeGuids", value: "1"),
        ]
        if checkFiles {
            queryItems.append(URLQueryItem(name: "checkFiles", value: "1"))
        }
        return try await rawServerRequest(
            path: PlexMetadataSnapshotFormat.metadataEndpoint(itemID),
            queryItems: queryItems,
            serverID: serverID
        )
    }

    /// Plex only, for `+Photos` (the viewer builds its own `/photo/:/transcode`
    /// URL) until the catalog facet takes it over.
    func transcodeSourceURLString(for path: String, serverID: String? = nil) -> String? {
        PlexImages(client: client).transcodeSourceURLString(for: path, session: pool.connection(for: serverID))
    }

    /// Plex only: the image URL string on the server's connection, optionally
    /// with the token in the query.
    func imageRequestURLString(for path: String, includeToken: Bool, serverID: String? = nil) -> String? {
        PlexImages(client: client).imageRequestURLString(
            for: path,
            includeToken: includeToken,
            session: pool.connection(for: serverID)
        )
    }

    static let restoredEndpointValidationTimeout = PlexServerRouter.restoredEndpointValidationTimeout

    /// Resolves an explicit server, or the primary one when the caller has not
    /// been routed yet.
    func resolveServerID(_ serverID: String?) throws -> String {
        if let serverID = serverID?.nilIfEmpty {
            return serverID
        }
        // Falling back to the highest-priority *known* server (rather than only
        // a connected one) keeps the failure specific: the request then reports
        // "not authorized" instead of a generic "no server" when that is why the
        // session is missing.
        guard let primaryID = pool.primary?.serverID ?? pool.priorityOrderedIdentifiers.first else {
            throw MediaServiceError.noServerConnected
        }
        return primaryID
    }

    /// Whether a plex.tv resource is a Plex Media Server. See
    /// `PlexAccountProvider.isMediaServerResource`.
    nonisolated static func isMediaServerResource(_ json: [String: Any]) -> Bool {
        PlexAccountProvider.isMediaServerResource(json)
    }
}
