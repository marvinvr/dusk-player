import Foundation

/// Builds and parses the `dusk://` deep links used by the tvOS Top Shelf so a
/// resumable item can be launched straight from the Apple TV Home screen.
///
/// Format: `dusk://play?ratingKey=<key>&type=<plexMediaType>`. Only `ratingKey`
/// is required to resume playback; `type` is carried for context/forward use.
enum TopShelfDeepLink {
    static let scheme = "dusk"
    static let playHost = "play"

    private enum QueryKey {
        static let ratingKey = "ratingKey"
        static let mediaType = "type"
    }

    /// A parsed "resume this item" request.
    struct PlayRequest: Equatable, Sendable {
        let ratingKey: String
        let mediaType: String?
    }

    /// Builds `dusk://play?ratingKey=...&type=...` for the given item.
    static func playURL(ratingKey: String, mediaType: String) -> URL? {
        let trimmedKey = ratingKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = playHost
        components.queryItems = [
            URLQueryItem(name: QueryKey.ratingKey, value: trimmedKey),
            URLQueryItem(name: QueryKey.mediaType, value: mediaType),
        ]
        return components.url
    }

    /// Parses a `dusk://play` URL into a `PlayRequest`, or returns `nil` if the
    /// URL is not a recognized play deep link.
    static func playRequest(from url: URL) -> PlayRequest? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        // Accept both `dusk://play?...` (host == play) and the degenerate
        // `dusk:play?...` (host nil, path == play) just in case.
        let normalizedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let isPlay = components.host?.lowercased() == playHost ||
            (components.host == nil && normalizedPath == playHost)
        guard isPlay else { return nil }

        guard let ratingKey = components.queryItems?
            .first(where: { $0.name == QueryKey.ratingKey })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !ratingKey.isEmpty else {
            return nil
        }

        let mediaType = components.queryItems?
            .first(where: { $0.name == QueryKey.mediaType })?
            .value
            .flatMap { $0.isEmpty ? nil : $0 }

        return PlayRequest(ratingKey: ratingKey, mediaType: mediaType)
    }
}
