import Foundation

extension PlexService {
    func getCurrentUser() async throws -> PlexUser {
        if let currentUser {
            return currentUser
        }

        let user: PlexUser = try await plexTVRequest(path: "/user")
        currentUser = user
        return user
    }

    func getPlaybackHistory(
        accountId: Int?,
        librarySectionId: String,
        viewedSince: Date,
        limit: Int = 400,
        pageSize: Int = 200
    ) async throws -> [PlexPlaybackHistoryEntry] {
        let epochSeconds = Int(viewedSince.timeIntervalSince1970.rounded(.down))
        let clampedLimit = max(limit, 0)
        let clampedPageSize = max(pageSize, 1)

        guard clampedLimit > 0 else { return [] }

        var entries: [PlexPlaybackHistoryEntry] = []
        var start = 0

        while entries.count < clampedLimit {
            let currentPageSize = min(clampedPageSize, clampedLimit - entries.count)
            var queryItems = [
                URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
                URLQueryItem(name: "X-Plex-Container-Size", value: String(currentPageSize)),
                URLQueryItem(name: "sort", value: "viewedAt:desc"),
                URLQueryItem(name: "librarySectionID", value: librarySectionId),
                URLQueryItem(name: "viewedAt>", value: String(epochSeconds)),
            ]

            if let accountId {
                queryItems.append(URLQueryItem(name: "accountId", value: String(accountId)))
            }

            let page: [PlexPlaybackHistoryEntry] = try await fetchMetadata(
                path: "/status/sessions/history/all",
                queryItems: queryItems
            )

            guard !page.isEmpty else { break }

            entries.append(contentsOf: page)
            start += page.count

            if page.count < currentPageSize {
                break
            }
        }

        return entries
    }
}
