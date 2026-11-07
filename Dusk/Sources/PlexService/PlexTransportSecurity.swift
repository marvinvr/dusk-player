import Foundation

/// Tokens may travel over HTTP only to a destination known to be on the LAN.
/// Never trust discovery's `local` flag or a separate advertised address here:
/// the URL's actual host is the one that receives the credential.
enum PlexTransportSecurity {
    static let session = URLSession(
        configuration: .default, delegate: PlexTransportSessionDelegate(), delegateQueue: nil
    )

    static func allowsToken(in url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return url.host != nil
        case "http":
            guard let host = url.host?.lowercased() else { return false }
            return host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
                || PlexConnection.isPrivateAddress(PlexConnection.plexDirectIPAddress(in: host) ?? host)
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
            throw URLError(.appTransportSecurityRequiresSecureConnection)
        }
    }

    static func allowsRedirect(_ request: URLRequest, original: URLRequest?) -> Bool {
        // A redirect may have dropped the header/body. Keep the original
        // request's credential requirement for every hop in the chain.
        guard carriesToken(request) || original.map(carriesToken) == true else { return true }
        return request.url.map(allowsToken) == true
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
