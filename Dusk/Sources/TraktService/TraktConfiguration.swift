import Foundation

/// The Trakt API app Dusk talks to. Client ID, secret and the optional
/// redirect URI are build-time values (`TRAKT_CLIENT_ID` /
/// `TRAKT_CLIENT_SECRET` / `TRAKT_REDIRECT_URI` from the git-ignored
/// `Dusk/Support/Secrets.xcconfig`, surfaced as Info.plist keys). A build
/// without ID and secret hides the Trakt setting entirely. See `docs/trakt.md`.
struct TraktConfiguration: Sendable, Equatable {
    let clientID: String
    let clientSecret: String
    let apiBase: URL
    /// Where the browser sign-in page lives (`trakt.tv`, not the API host).
    let webBase: URL
    /// `TRAKT_REDIRECT_URI`, exactly as registered on the Trakt app (e.g.
    /// `http://localhost` or `dusk://trakt/callback`); `nil` when unset or
    /// malformed. Every token refresh must send a registered redirect, so
    /// device-code links refresh with this one when it is set.
    let registeredRedirectURI: String?
    /// iOS authorization-code redirect: `registeredRedirectURI` when it is a
    /// custom scheme (`ASWebAuthenticationSession` cannot catch http(s)
    /// without associated domains). `nil` means the device-code flow.
    let appRedirectURI: String?

    static let productionAPIBase = URL(string: "https://api.trakt.tv")!
    static let productionWebBase = URL(string: "https://trakt.tv")!
    /// Out-of-band redirect, used for refreshes only when no
    /// `TRAKT_REDIRECT_URI` is set (Trakt Development apps reject it).
    static let deviceRedirectURI = "urn:ietf:wg:oauth:2.0:oob"
    static let apiVersion = "2"

    init(
        clientID: String,
        clientSecret: String,
        apiBase: URL,
        webBase: URL = productionWebBase,
        appRedirectURI: String? = nil
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.apiBase = apiBase
        self.webBase = webBase
        let registered = appRedirectURI.flatMap(Self.validatedRedirectURI)
        registeredRedirectURI = registered
        self.appRedirectURI = registered.flatMap(Self.browserRedirectURI)
    }

    var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty }

    /// `redirect_uri` for refreshing a device-code link.
    var deviceRefreshRedirectURI: String { registeredRedirectURI ?? Self.deviceRedirectURI }

    /// Any URL with a scheme and host. A value cut off at `//` by xcconfig
    /// comment parsing (`dusk:`, `http:`) has no host and is rejected.
    static func validatedRedirectURI(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              url.scheme?.isEmpty == false,
              url.host()?.isEmpty == false else {
            return nil
        }
        return value
    }

    /// The browser sign-in only works with a custom scheme; http(s) redirects
    /// (Trakt Development apps accept only localhost) keep the device flow.
    static func browserRedirectURI(_ value: String) -> String? {
        guard let scheme = URL(string: value)?.scheme?.lowercased(),
              scheme != "http", scheme != "https" else { return nil }
        return value
    }

    static let current: TraktConfiguration = {
        let bundle = Bundle.main
        func value(_ key: String) -> String {
            let raw = (bundle.object(forInfoDictionaryKey: key) as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // An unset build setting can leave the literal `$(…)` behind.
            return raw.hasPrefix("$(") ? "" : raw
        }
        var base = productionAPIBase
        var web = productionWebBase
        #if DEBUG
        // The screenshot mock answers both the API and the authorize page.
        if let override = ScreenshotMode.traktAPIBase {
            base = override
            web = override
        }
        #endif
        // Read on tvOS too (refresh redirect); tvOS never opens a browser.
        let redirect = value("TraktRedirectURI").nilIfEmpty
        return TraktConfiguration(
            clientID: value("TraktClientID"),
            clientSecret: value("TraktClientSecret"),
            apiBase: base,
            webBase: web,
            appRedirectURI: redirect
        )
    }()
}
