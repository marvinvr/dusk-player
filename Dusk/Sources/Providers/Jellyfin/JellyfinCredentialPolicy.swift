import Foundation

/// Where a Jellyfin access token may travel (docs/jellyfin/04-architecture.md
/// §8). The token rides as `ApiKey=` on URLs handed to the engines and as the
/// `Token="…"` part of the `Authorization: MediaBrowser` header on API calls.
///
/// The rules are Plex's (`PlexTransportSecurity`): plain HTTP is allowed (a
/// typed `http://` address must work), but a token only goes to an
/// `http`/`https` URL with a host, never follows a redirect to another host
/// and never follows one from HTTPS down to HTTP.
struct JellyfinCredentialPolicy: CredentialTransportPolicy {
    static let shared = JellyfinCredentialPolicy()

    private static let urlSession = URLSession(
        configuration: .default, delegate: JellyfinTransportSessionDelegate(), delegateQueue: nil
    )

    func allowsCredential(in url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        switch url.scheme?.lowercased() {
        case "https", "http": return true
        default: return false
        }
    }

    func carriesCredential(_ request: URLRequest) -> Bool {
        if let header = request.value(forHTTPHeaderField: JellyfinAuthorization.headerName),
           header.range(of: "Token=", options: .caseInsensitive) != nil {
            return true
        }
        guard let url = request.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        return items.contains { $0.name.caseInsensitiveCompare("ApiKey") == .orderedSame }
    }

    func validate(_ request: URLRequest) throws {
        guard carriesCredential(request) else { return }
        guard let url = request.url, allowsCredential(in: url) else { throw URLError(.badURL) }
    }

    /// A redirect may have dropped the header, so the original request's
    /// credential decides for every hop.
    func allowsRedirect(_ request: URLRequest, original: URLRequest?) -> Bool {
        guard carriesCredential(request) || original.map(carriesCredential) == true else { return true }
        guard let target = request.url, allowsCredential(in: target) else { return false }
        guard let source = original?.url else { return true }
        guard source.host?.lowercased() == target.host?.lowercased() else { return false }
        return !(source.scheme?.lowercased() == "https" && target.scheme?.lowercased() == "http")
    }

    var session: URLSession { Self.urlSession }
}

private final class JellyfinTransportSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let allowed = JellyfinCredentialPolicy.shared.allowsRedirect(request, original: task.originalRequest)
        completionHandler(allowed ? request : nil)
    }
}
