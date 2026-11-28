import Foundation

/// Turns what the user typed into the URLs worth trying
/// (docs/jellyfin/04-architecture.md §7.1).
///
/// - A typed scheme is taken as it is: `http://jellyfin-demo` is only that.
/// - A bare host tries `https://host`, `http://host:8096`, `https://host:8920`
///   (Jellyfin's default ports), then `http://host` (a proxy on port 80), in
///   that order of preference.
/// - A host with a port tries HTTPS, then HTTP, on that port.
/// - A path is kept (a reverse proxy at `/jellyfin`); trailing slashes and a
///   pasted `/web/…` page path are dropped.
enum JellyfinAddress {
    static func candidates(for input: String) -> [URL] {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return [] }

        let lowered = text.lowercased()
        let typedScheme: String?
        if lowered.hasPrefix("https://") {
            typedScheme = "https"
            text = String(text.dropFirst("https://".count))
        } else if lowered.hasPrefix("http://") {
            typedScheme = "http"
            text = String(text.dropFirst("http://".count))
        } else if lowered.contains("://") {
            return []
        } else {
            typedScheme = nil
        }

        guard let parts = URLComponents(string: "http://" + text),
              let host = parts.host?.nilIfEmpty,
              parts.user == nil, parts.password == nil else { return [] }
        let path = basePath(parts.path)

        func url(_ scheme: String, _ port: Int?) -> URL? {
            var components = URLComponents()
            components.scheme = scheme
            components.host = host
            components.port = port
            components.path = path
            return components.url
        }

        if let typedScheme {
            return [url(typedScheme, parts.port)].compactMap { $0 }
        }
        if let port = parts.port {
            return [url("https", port), url("http", port)].compactMap { $0 }
        }
        return [url("https", nil), url("http", 8096), url("https", 8920), url("http", nil)].compactMap { $0 }
    }

    /// `/jellyfin/` → `/jellyfin`; `/web/index.html` and `/jellyfin/web/#/home`
    /// → the part before `/web`.
    private static func basePath(_ path: String) -> String {
        var path = path
        if let range = path.range(of: "/web", options: .caseInsensitive),
           path[range.upperBound...].isEmpty || path[range.upperBound...].hasPrefix("/") {
            path = String(path[..<range.lowerBound])
        }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The server's `LocalAddress` as a URL, or nil when it is missing or the
    /// same endpoint as `baseURL`.
    static func localAddress(_ value: String?, distinctFrom baseURL: URL) -> URL? {
        guard let value = value?.nilIfEmpty,
              let url = URL(string: value), url.scheme != nil, url.host != nil else { return nil }
        func key(_ url: URL) -> String {
            let scheme = url.scheme?.lowercased() ?? ""
            let port = url.port ?? (scheme == "https" ? 443 : 80)
            return "\(scheme)://\(url.host?.lowercased() ?? ""):\(port)"
        }
        return key(url) == key(baseURL) ? nil : url
    }
}
