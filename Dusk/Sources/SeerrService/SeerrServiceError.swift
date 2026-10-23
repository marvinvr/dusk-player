import Darwin
import Foundation

enum SeerrServiceError: LocalizedError, Equatable {
    case invalidServerURL
    case serverMismatch
    case notConfigured
    case notConnected
    case plexLoginUnavailable
    case unauthorized
    case authenticationRequired(String)
    case permissionDenied(String)
    case requestConflict(String)
    case noSeasonsAvailable(String)
    case serverError(String)
    case invalidResponse
    case missingSession
    case unreachable
    case wrongPort
    case notASeerrServer
    case redirectedToLogin
    case localNetworkDenied
    case tlsHandshakeFailed
    case tlsUntrusted(host: String, port: Int, fingerprint: String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "Enter a valid Seerr server URL."
        case .serverMismatch:
            "This Seerr connection belongs to a different Plex server."
        case .notConfigured:
            "Set up Seerr in Settings before using request results."
        case .notConnected:
            "Connect this Plex user to Seerr in Settings."
        case .plexLoginUnavailable:
            "This Seerr server is not configured to accept Plex sign-in."
        case .unauthorized:
            "Seerr refused this Plex account."
        case .authenticationRequired(let message),
             .permissionDenied(let message),
             .requestConflict(let message),
             .noSeasonsAvailable(let message),
             .serverError(let message):
            message
        case .invalidResponse:
            "Seerr returned an invalid response."
        case .missingSession:
            "Seerr accepted the sign-in but didn't return a session."
        case .unreachable:
            "Can't reach that Seerr server. Check the address and that Seerr is running."
        case .wrongPort:
            "Nothing is listening on that port. Include the port Seerr is using, for example http://192.168.1.10:5055."
        case .notASeerrServer:
            "That address responded, but it doesn't look like a Seerr server."
        case .redirectedToLogin:
            "That address redirected to a login page instead of the Seerr API. Check the URL and any reverse-proxy base path."
        case .localNetworkDenied:
            "Dusk doesn't have permission to reach devices on your local network. Enable Local Network for Dusk in Settings."
        case .tlsHandshakeFailed:
            "Couldn't complete a TLS handshake. Use http:// for a Seerr server that isn't configured with HTTPS, and include its port."
        case .tlsUntrusted(let host, _, let fingerprint):
            fingerprint.isEmpty
                ? "The certificate for \(host) isn't trusted."
                : "The certificate for \(host) isn't trusted (\(SeerrServerURL.shortFingerprint(fingerprint))). Trust this certificate to connect."
        }
    }

    var haltsCandidateSearch: Bool {
        switch self {
        case .localNetworkDenied, .plexLoginUnavailable:
            return true
        default:
            return false
        }
    }

    /// Connectivity failures that a denied Local Network permission can look like.
    var isReachabilityFailure: Bool {
        switch self {
        case .unreachable, .wrongPort:
            return true
        default:
            return false
        }
    }

    static func prefer(_ new: SeerrServiceError, over old: SeerrServiceError?) -> SeerrServiceError {
        guard let old else { return new }
        return new.connectRank >= old.connectRank ? new : old
    }

    static func classifyTransport(_ error: Error) -> SeerrServiceError {
        if let seerr = error as? SeerrServiceError {
            return seerr
        }
        guard let urlError = underlyingURLError(in: error) else {
            return .unreachable
        }
        switch urlError.code {
        case .timedOut:
            return .unreachable
        case .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .networkConnectionLost,
             .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return .unreachable
        case .cannotConnectToHost:
            let posix = posixCode(in: urlError)
            if posix == ETIMEDOUT || posix == EHOSTUNREACH || posix == ENETUNREACH {
                return .unreachable
            }
            return .wrongPort
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return .tlsUntrusted(host: urlError.failingURL?.host ?? "that server", port: urlError.failingURL?.port ?? 0, fingerprint: "")
        case .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired:
            return .tlsHandshakeFailed
        case .cancelled:
            return .unreachable
        default:
            if posixCode(in: urlError) == ECONNREFUSED {
                return .wrongPort
            }
            return .unreachable
        }
    }

    static func mapLogin(_ error: SeerrServiceError) -> SeerrServiceError {
        switch error {
        case .permissionDenied, .authenticationRequired:
            return .unauthorized
        case .serverError(let message):
            let lowered = message.lowercased()
            if lowered.contains("login is disabled") {
                return .plexLoginUnavailable
            }
            if lowered.contains("unable to authenticate")
                || lowered.contains("access denied")
                || lowered.contains("authentication token")
                || lowered.contains("authtoken") {
                return .unauthorized
            }
            return error
        default:
            return error
        }
    }

    private var connectRank: Int {
        switch self {
        case .localNetworkDenied: 100
        case .plexLoginUnavailable: 90
        case .tlsUntrusted: 80
        case .tlsHandshakeFailed: 75
        case .unauthorized: 70
        case .redirectedToLogin: 65
        case .notASeerrServer: 60
        case .missingSession: 55
        case .wrongPort: 40
        case .unreachable: 30
        case .invalidServerURL: 10
        default: 20
        }
    }

    private static func underlyingURLError(in error: Error) -> URLError? {
        if let urlError = error as? URLError {
            return urlError
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return URLError(URLError.Code(rawValue: nsError.code), userInfo: nsError.userInfo)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return underlyingURLError(in: underlying)
        }
        return nil
    }

    private static func posixCode(in error: Error) -> Int32? {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(nsError.code)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return posixCode(in: underlying)
        }
        return nil
    }
}
