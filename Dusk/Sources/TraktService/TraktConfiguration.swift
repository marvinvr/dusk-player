import Foundation

/// Public-client Trakt configuration. Only the client ID and HTTPS redirect
/// are build-time values; a client secret must never enter an app build.
struct TraktConfiguration: Sendable, Equatable {
    let clientID: String
    let apiBase: URL
    /// All OAuth endpoints (including device auth) live on auth.trakt.tv.
    let authBase: URL
    let appRedirectURI: String?

    static let productionAPIBase = URL(string: "https://api.trakt.tv")!
    static let productionAuthBase = URL(string: "https://auth.trakt.tv")!
    static let defaultRedirectURI = "https://getdusk.app/trakt/callback"
    /// The HTTPS callback page forwards its query to this system-web-session callback.
    static let callbackURL = URL(string: "dusk://trakt/callback")!
    static let apiVersion = "2"

    init(
        clientID: String,
        apiBase: URL,
        authBase: URL = productionAuthBase,
        appRedirectURI: String? = nil
    ) {
        self.clientID = clientID
        self.apiBase = apiBase
        self.authBase = authBase
        self.appRedirectURI = Self.validatedRedirectURI(appRedirectURI ?? Self.defaultRedirectURI)
    }

    var isConfigured: Bool { !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Device grants have no initial redirect, but refresh requires a registered one.
    var deviceRefreshRedirectURI: String { appRedirectURI ?? Self.defaultRedirectURI }

    /// Reject custom schemes, localhost, and values truncated by xcconfig's `//` comments.
    static func validatedRedirectURI(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: value),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              host != "localhost", !host.hasSuffix(".localhost"),
              host != "127.0.0.1", host != "[::1]", host != "::1",
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return value
    }

    static let current: TraktConfiguration = {
        let bundle = Bundle.main
        func value(_ key: String) -> String {
            let raw = (bundle.object(forInfoDictionaryKey: key) as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.hasPrefix("$(") ? "" : raw
        }
        var base = productionAPIBase
        var auth = productionAuthBase
        #if DEBUG
        // The screenshot mock answers both the API and the authorize page.
        if let override = ScreenshotMode.traktAPIBase {
            base = override
            auth = override
        }
        #endif
        return TraktConfiguration(
            clientID: value("TraktClientID"),
            apiBase: base,
            authBase: auth,
            appRedirectURI: value("TraktRedirectURI").nilIfEmpty
        )
    }()
}
