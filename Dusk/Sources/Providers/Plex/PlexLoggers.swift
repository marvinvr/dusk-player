import Foundation
import OSLog

// The Plex request, account and connection log channels. The categories are
// what Console filters on; they keep their names.

let plexAuthLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "PlexAuth"
)

let plexConnectionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "PlexConnection"
)

/// The facade's subtitle search and download (`MediaService+Subtitles`).
let subtitleSearchLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "PlexSubtitles"
)

extension ConnectionSelector {
    /// The header a probe carries the server credential in.
    static let credentialHeader = "X-Plex-Token"
}
