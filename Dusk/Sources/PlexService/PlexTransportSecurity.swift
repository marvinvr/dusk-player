import Foundation
import os

/// Tokens may travel over HTTP only to a destination that is not on the public
/// internet: the LAN (private, loopback, link-local, `.local`), a Tailscale
/// tailnet (100.64.0.0/10, fd7a:115c:a1e0::/48, `*.ts.net` — WireGuard-encrypted)
/// or a single-label name resolved through MagicDNS/search domains ("storage").
/// Never trust discovery's `local` flag or a separate advertised address here:
/// the URL's actual host is the one that receives the credential.
enum PlexTransportSecurity {
    static let session = URLSession(
        configuration: .default, delegate: PlexTransportSessionDelegate(), delegateQueue: nil
    )

    /// Public plain-HTTP origins whose `/identity` answered as the expected
    /// Plex server this launch (the owner's last-resort rule, #36 follow-up).
    /// In memory only: every launch re-verifies before a token goes there.
    private static let trustedPublicHTTPOrigins = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    static func trustPublicHTTP(_ url: URL) {
        guard let origin = origin(of: url), url.scheme?.lowercased() == "http" else { return }
        trustedPublicHTTPOrigins.withLock { _ = $0.insert(origin) }
    }

    static func distrustPublicHTTP(_ url: URL) {
        guard let origin = origin(of: url) else { return }
        trustedPublicHTTPOrigins.withLock { _ = $0.remove(origin) }
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        origin(of: lhs).map { $0 == origin(of: rhs) } ?? false
    }

    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    static func allowsToken(in url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return url.host != nil
        case "http":
            guard let host = url.host?.lowercased() else { return false }
            if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
                || PlexConnection.isTailnetHostName(host) || PlexConnection.isSingleLabelHostName(host) {
                return true
            }
            let address = PlexConnection.plexDirectIPAddress(in: host) ?? host
            if PlexConnection.isPrivateAddress(address) || PlexConnection.isTailnetAddress(address) { return true }
            guard let origin = origin(of: url) else { return false }
            return trustedPublicHTTPOrigins.withLock { $0.contains(origin) }
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
