import Foundation

/// Where Seerr artwork is loaded from, in the order to try it.
///
/// Seerr's `/imageproxy/tmdb/...` only answers when the admin turned on
/// Settings › General › Enable Image Caching (off by default). With it off
/// every proxy request is a 404 ("Image caching is disabled.") and Seerr's own
/// web app loads the same paths straight from TMDB's public CDN, so Dusk does
/// the same. Overseerr's proxy has no `/tmdb` segment, and a self-signed
/// certificate or a forward-auth proxy in front of Seerr can also fail the
/// image request, so the other source is always kept as a fallback.
enum SeerrImageURL {
    static let tmdbImageBase = "https://image.tmdb.org/t/p"

    /// - Parameters:
    ///   - path: Seerr's `posterPath`/`backdropPath`/`stillPath`, normally a
    ///     TMDB file path like `/abc.jpg`. An absolute http(s) URL is used as is.
    ///   - size: A TMDB size bucket such as `w342`.
    ///   - seerrBaseURL: The Seerr base URL, reverse-proxy subpath included.
    ///   - cachesImages: Seerr's public `cacheImages` setting; `nil` when unknown.
    static func candidates(
        path: String?,
        size: String,
        seerrBaseURL: URL?,
        cachesImages: Bool?
    ) -> [URL] {
        guard let raw = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return []
        }

        if let absolute = URL(string: raw),
           let scheme = absolute.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           absolute.host != nil {
            return [absolute]
        }

        let file = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !file.isEmpty,
              let encodedFile = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return []
        }

        let tmdb = URL(string: "\(tmdbImageBase)/\(size)/\(encodedFile)")
        let proxy = seerrBaseURL.flatMap {
            SeerrServerURL.endpointURL(base: $0, path: "imageproxy/tmdb/t/p/\(size)/\(file)")
        }

        let ordered: [URL?]
        switch cachesImages {
        case true?:
            ordered = [proxy, tmdb]
        case false?:
            // The proxy is a guaranteed 404.
            ordered = [tmdb]
        case nil:
            ordered = [tmdb, proxy]
        }
        return ordered.compactMap { $0 }
    }

    static func posterSize(forWidth width: Int) -> String {
        switch width {
        case ...185: "w185"
        case ...342: "w342"
        case ...500: "w500"
        default: "w780"
        }
    }

    static func backdropSize(forWidth width: Int) -> String {
        switch width {
        case ...300: "w300"
        case ...780: "w780"
        default: "w1280"
        }
    }
}
