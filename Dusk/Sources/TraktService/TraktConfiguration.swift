import Foundation

/// The Trakt API app Dusk talks to. Client ID, secret and the optional iOS
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
    /// iOS authorization-code redirect (e.g. `dusk://trakt/callback`), exactly
    /// as registered on the Trakt app. `nil` (unset, or not a custom-scheme
    /// URL) means iOS uses the device-code flow like tvOS.
    let appRedirectURI: String?

    static let productionAPIBase = URL(string: "https://api.trakt.tv")!
    static let productionWebBase = URL(string: "https://trakt.tv")!
    /// Out-of-band redirect of the device flow. The Trakt app lists it next to
    /// `appRedirectURI`, one per line.
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
        self.appRedirectURI = appRedirectURI.flatMap(Self.validatedRedirectURI)
    }

    var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty }

    /// `ASWebAuthenticationSession` can only catch a custom scheme without
    /// associated domains, so http(s) redirects (Trakt's localhost-only
    /// development apps) are not usable and fall back to the device flow.
    /// A value cut off at `//` by xcconfig comment parsing (`dusk:`) has no
    /// host and is rejected too.
    static func validatedRedirectURI(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme != "http", scheme != "https",
              url.host()?.isEmpty == false else {
            return nil
        }
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
        #if os(tvOS)
        let redirect: String? = nil // tvOS has no browser: always the device flow
        #else
        let redirect = value("TraktRedirectURI").nilIfEmpty
        #endif
        return TraktConfiguration(
            clientID: value("TraktClientID"),
            clientSecret: value("TraktClientSecret"),
            apiBase: base,
            webBase: web,
            appRedirectURI: redirect
        )
    }()
}
