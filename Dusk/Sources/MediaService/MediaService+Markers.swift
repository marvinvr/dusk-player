import Foundation

/// Skip markers and scrub previews, routed to the item's server's
/// `MarkerProviding` (docs/jellyfin/04-architecture.md §12.6).
extension MediaService: PlexMarkersTransport {}

extension MediaService {
    /// The marker facet of `serverID` (nil = the primary server).
    ///
    /// Every server is a Plex server until J-01. The facet is built here rather
    /// than read off the session's provider because the routed send it needs
    /// (re-authorization, 401 refresh) still lives in this facade; see
    /// `PlexMarkersTransport`.
    func markerFacet(on serverID: String?) throws -> any MarkerProviding {
        PlexMarkers(serverID: try resolveServerID(serverID), transport: self)
    }

    /// Preview frames for the scrubber of the part being played on `serverID`.
    /// nil when there are none or loading them failed; never throws, because
    /// a missing thumbnail is not an error the player shows.
    func scrubPreview(forPartID partID: String, serverID: String? = nil) async -> (any ScrubPreviewSource)? {
        guard let facet = try? markerFacet(on: serverID) else { return nil }
        return await facet.scrubPreview(forPartID: partID)
    }

    // MARK: - PlexMarkersTransport

    /// Re-authorizes the server first when it has no session, and refreshes
    /// the token once on a 401. Nothing else: no endpoint re-selection, which
    /// a missing index (404) must never trigger.
    func scrubPreviewData(path: String, accept: String, serverID: String) async throws -> Data {
        if pool.connection(for: serverID) == nil {
            try await refreshServerAuthorization(serverID: serverID)
        }

        do {
            return try await sendScrubPreviewData(path: path, accept: accept, serverID: serverID)
        } catch let error as PlexServiceError where error == .unauthorized {
            try await refreshServerAuthorization(serverID: serverID)
            return try await sendScrubPreviewData(path: path, accept: accept, serverID: serverID)
        }
    }

    private func sendScrubPreviewData(path: String, accept: String, serverID: String) async throws -> Data {
        guard let connection = pool.connection(for: serverID) else {
            switch pool.state(for: serverID) {
            case .unauthorized:
                throw isAuthenticationFresh ? PlexServiceError.authenticationPending : PlexServiceError.unauthorized
            default:
                throw PlexServiceError.noServerConnected
            }
        }

        guard let url = buildURL(base: connection.baseURL.absoluteString, path: path) else {
            throw PlexServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .returnCacheDataElseLoad
        applyHeaders(to: &request, token: connection.token)
        request.setValue(accept, forHTTPHeaderField: "Accept")

        return try await executeRequest(request)
    }
}
