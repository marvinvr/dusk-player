import Foundation

/// Where a Plex credential may travel.
///
/// Like Plex's own apps, Dusk talks plain HTTP to any server that only offers
/// HTTP (the owner's call after #36: a manually configured `http://` custom URL
/// must simply work). HTTPS still always wins when it works — that is decided
/// by the connection ranking (`ConnectionCandidate.rank`), not here. What this
/// type guarantees is narrower and absolute:
///
/// - a token only goes to an `http`/`https` URL with a host;
/// - a token never follows a redirect to a different host;
/// - a token never follows a redirect from HTTPS down to HTTP.
enum PlexTransportSecurity {
    static let session = URLSession(
        configuration: .default, delegate: PlexTransportSessionDelegate(), delegateQueue: nil
    )

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        origin(of: lhs).map { $0 == origin(of: rhs) } ?? false
    }

    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    static func allowsToken(in url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        switch url.scheme?.lowercased() {
        case "https", "http": return true
        default: return false
        }
    }

    static func authenticatedURL(_ url: URL?) -> URL? {
        guard let url, allowsToken(in: url) else { return nil }
        return url
    }

    static func carriesToken(_ request: URLRequest) -> Bool {
        if request.value(forHTTPHeaderField: "X-Plex-Token") != nil { return true }
        if let url = request.url,
           URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
               $0.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame
           }) == true { return true }
        // Seerr sign-in sends the Plex account token in JSON, not a Plex header.
        if let body = request.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           json["authToken"] != nil { return true }
        return false
    }

    static func validate(_ request: URLRequest) throws {
        guard carriesToken(request) else { return }
        guard let url = request.url, allowsToken(in: url) else {
            throw URLError(.badURL)
        }
    }

    /// A credential-bearing request may be redirected only on the same host and
    /// never from HTTPS to HTTP. A redirect may have dropped the header/body, so
    /// the original request's credential decides for every hop in the chain.
    static func allowsRedirect(_ request: URLRequest, original: URLRequest?) -> Bool {
        guard carriesToken(request) || original.map(carriesToken) == true else { return true }
        guard let target = request.url, allowsToken(in: target) else { return false }
        guard let source = original?.url else { return true }
        guard source.host?.lowercased() == target.host?.lowercased() else { return false }
        let downgrades = source.scheme?.lowercased() == "https" && target.scheme?.lowercased() == "http"
        return !downgrades
    }
}

final class PlexTransportSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(PlexTransportSecurity.allowsRedirect(request, original: task.originalRequest) ? request : nil)
    }
}
