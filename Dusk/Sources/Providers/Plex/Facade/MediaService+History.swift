import Foundation

extension MediaService {
    func getCurrentUser() async throws -> PlexUser {
        // No plex.tv account behind another provider's session.
        guard accountSession == nil else { throw MediaServiceError.notAuthenticated }
        if let currentUser {
            return currentUser
        }

        let user: PlexUser = try await plexTVRequest(path: "/user")
        currentUser = user
        return user
    }

    /// The catalog's `playbackHistory` of one library.
    func getPlaybackHistory(
        accountId: Int?,
        librarySectionId: String,
        viewedSince: Date,
        limit: Int = 400,
        pageSize: Int = 200,
        serverID: String? = nil
    ) async throws -> [PlaybackHistoryEntry] {
        guard limit > 0 else { return [] }
        return try await catalog(on: resolveServerID(serverID)).playbackHistory(
            libraryID: librarySectionId,
            since: viewedSince,
            limit: limit,
            pageSize: pageSize,
            accountID: accountId
        )
    }
}
