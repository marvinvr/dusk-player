import Foundation
import OSLog

private let plexPlaybackLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "PlexPlayback"
)

extension PlexService {
    func reportTimeline(ratingKey: String, state: PlaybackState, timeMs: Int, durationMs: Int) async {
        try? await submitTimeline(
            ratingKey: ratingKey,
            state: state,
            timeMs: timeMs,
            durationMs: durationMs
        )
    }

    func submitTimeline(ratingKey: String, state: PlaybackState, timeMs: Int, durationMs: Int) async throws {
        let stateString: String
        switch state {
        case .playing:
            stateString = "playing"
        case .paused:
            stateString = "paused"
        default:
            stateString = "stopped"
        }

        _ = try await rawServerRequest(
            path: "/:/timeline",
            queryItems: [
                URLQueryItem(name: "ratingKey", value: ratingKey),
                URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
                URLQueryItem(name: "state", value: stateString),
                URLQueryItem(name: "time", value: String(timeMs)),
                URLQueryItem(name: "duration", value: String(durationMs)),
            ]
        )
    }

    func scrobble(ratingKey: String) async throws {
        _ = try await rawServerRequest(
            path: "/:/scrobble",
            queryItems: [
                URLQueryItem(name: "key", value: ratingKey),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            ]
        )
    }

    func unscrobble(ratingKey: String) async throws {
        _ = try await rawServerRequest(
            path: "/:/unscrobble",
            queryItems: [
                URLQueryItem(name: "key", value: ratingKey),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            ]
        )
    }

    func setWatched(_ watched: Bool, ratingKey: String) async throws {
        if watched {
            try await scrobble(ratingKey: ratingKey)
        } else {
            try await unscrobble(ratingKey: ratingKey)
        }
    }

    func directPlayURL(for part: PlexMediaPart) -> URL? {
        guard let baseURL = serverBaseURL else {
            plexPlaybackLogger.error(
                "Failed to build direct play URL for part \(part.id, privacy: .public): missing server base URL"
            )
            return nil
        }
        let urlString = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast()) + part.key
            : baseURL.absoluteString + part.key
        guard var components = URLComponents(string: urlString) else {
            plexPlaybackLogger.error(
                "Failed to build direct play URL for part \(part.id, privacy: .public): invalid URL string \(urlString, privacy: .private(mask: .hash))"
            )
            return nil
        }
        var items = components.queryItems ?? []
        if let token = preferredServerToken {
            items.append(URLQueryItem(name: "X-Plex-Token", value: token))
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else {
            plexPlaybackLogger.error(
                "Failed to finalize direct play URL for part \(part.id, privacy: .public)"
            )
            return nil
        }

        plexPlaybackLogger.debug(
            "Constructed direct play URL for part \(part.id, privacy: .public): \(Self.sanitizedPlaybackURLString(for: url), privacy: .public)"
        )
        return url
    }

    func sanitizedPlaybackURLString(for url: URL) -> String {
        Self.sanitizedPlaybackURLString(for: url)
    }
}

private extension PlexService {
    static func sanitizedPlaybackURLString(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        if let queryItems = components.queryItems, !queryItems.isEmpty {
            let sanitizedItems = queryItems.compactMap { item -> URLQueryItem? in
                guard item.name.caseInsensitiveCompare("X-Plex-Token") != .orderedSame else {
                    return URLQueryItem(name: item.name, value: "<redacted>")
                }
                return item
            }
            components.queryItems = sanitizedItems.isEmpty ? nil : sanitizedItems
        }

        return components.string ?? url.absoluteString
    }
}
