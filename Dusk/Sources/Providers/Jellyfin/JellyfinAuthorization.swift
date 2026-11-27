import Foundation

/// How Dusk introduces itself to a Jellyfin server. `client` and `device` are
/// what the server dashboard and the Quick Connect approval prompt show, so
/// they must be human-readable. One `deviceID` holds one token: signing in
/// again with the same `deviceID` revokes the previous token
/// (docs/jellyfin/03-prior-art.md §10.2), so two sessions that live at the
/// same time need two device ids.
struct JellyfinClientIdentity: Hashable, Sendable {
    var client: String
    var device: String
    var deviceID: String
    var version: String

    init(client: String = "Dusk", device: String, deviceID: String, version: String) {
        self.client = client
        self.device = device
        self.deviceID = deviceID
        self.version = version
    }
}

/// The one credential form Jellyfin 12 accepts in a header:
/// `Authorization: MediaBrowser Client="…", Device="…", DeviceId="…", Version="…", Token="…"`.
///
/// Every legacy carrier (`X-Emby-Token`, `X-Emby-Authorization`,
/// `X-MediaBrowser-Token`, `Authorization: Emby`, `Bearer`, `?api_key=`)
/// answers `401` (03 §10.1); URLs handed to a player carry `ApiKey=` instead
/// (`JellyfinClient.authenticatedURL`).
///
/// The server percent-decodes each value, and a literal `"` gives `400`, so
/// every value is percent-encoded with only RFC 3986 unreserved characters
/// left as they are. Device names come from the user and contain apostrophes,
/// umlauts and commas.
enum JellyfinAuthorization {
    static let headerName = "Authorization"
    static let scheme = "MediaBrowser"

    static func headerValue(identity: JellyfinClientIdentity, token: String?) -> String {
        var parameters = [
            ("Client", identity.client),
            ("Device", identity.device),
            ("DeviceId", identity.deviceID),
            ("Version", identity.version),
        ]
        if let token, !token.isEmpty {
            parameters.append(("Token", token))
        }
        return scheme + " " + parameters
            .map { "\($0.0)=\"\(encode($0.1))\"" }
            .joined(separator: ", ")
    }

    /// Unreserved characters only (`A–Z a–z 0–9 - . _ ~`); UTF-8 for the rest.
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()
}
