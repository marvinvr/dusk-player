import Foundation

/// The Trakt API app Dusk talks to. The client ID and secret are build-time
/// values (`TRAKT_CLIENT_ID` / `TRAKT_CLIENT_SECRET` from the git-ignored
/// `Dusk/Support/Secrets.xcconfig`, surfaced as Info.plist keys). A build
/// without them hides the Trakt setting entirely. See `docs/trakt.md`.
struct TraktConfiguration: Sendable, Equatable {
    let clientID: String
    let clientSecret: String
    let apiBase: URL

    static let productionAPIBase = URL(string: "https://api.trakt.tv")!
    /// Out-of-band redirect, the one the device flow registers with.
    static let redirectURI = "urn:ietf:wg:oauth:2.0:oob"
    static let apiVersion = "2"

    var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty }

    static let current: TraktConfiguration = {
        let bundle = Bundle.main
        func value(_ key: String) -> String {
            let raw = (bundle.object(forInfoDictionaryKey: key) as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // An unset build setting can leave the literal `$(…)` behind.
            return raw.hasPrefix("$(") ? "" : raw
        }
        var base = productionAPIBase
        #if DEBUG
        if let override = ScreenshotMode.traktAPIBase { base = override }
        #endif
        return TraktConfiguration(
            clientID: value("TraktClientID"),
            clientSecret: value("TraktClientSecret"),
            apiBase: base
        )
    }()
}
