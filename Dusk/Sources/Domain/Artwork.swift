import Foundation

/// An image a server can serve, named by an opaque locator only its provider
/// reads (docs/jellyfin/04-architecture.md §10). For Plex the locator is the
/// server-relative path (`/library/metadata/1/thumb/1700000000`) or an absolute
/// URL, exactly the strings models and `downloads.json` already hold.
struct ArtworkRef: Hashable, Codable, Sendable {
    let serverID: String?
    let locator: String

    init(serverID: String?, locator: String) {
        self.serverID = serverID
        self.locator = locator
    }

    /// nil when there is no path; an empty path is kept, as callers always did.
    init?(serverID: String?, path: String?) {
        guard let path else { return nil }
        self.init(serverID: serverID, locator: path)
    }

    /// This ref, or nil when its locator is empty.
    var nonEmpty: ArtworkRef? { locator.isEmpty ? nil : self }
}

/// How large an image is wanted, in points; `nil` sides leave it to the
/// server. Providers scale to the display and pick their own parameters.
struct ImageSize: Hashable, Sendable {
    var width: Int?
    var height: Int?

    init(width: Int? = nil, height: Int? = nil) {
        self.width = width
        self.height = height
    }

    /// The image as stored, no resize.
    static let original = ImageSize()
}

/// Every artwork slot an item can carry, each a ref on the item's server.
struct ArtworkSet: Hashable, Sendable {
    var poster: ArtworkRef? = nil
    var backdrop: ArtworkRef? = nil
    var logo: ArtworkRef? = nil
    var banner: ArtworkRef? = nil
    var parentPoster: ArtworkRef? = nil
    var grandparentPoster: ArtworkRef? = nil
    var grandparentBackdrop: ArtworkRef? = nil

    /// Best available primary image for compact cards and rows. Usually
    /// portrait-style; for clips the default branch is intentionally
    /// poster-first because a clip's poster is its 16:9 frame grab. An episode
    /// shows its season's poster, so the art changes per season; a season
    /// without its own poster either has no parent poster or the show's, and
    /// both land on the show poster.
    func preferredPoster(for kind: MediaKind) -> ArtworkRef? {
        switch kind {
        case .episode:
            return parentPoster?.nonEmpty ?? grandparentPoster?.nonEmpty
                ?? poster ?? grandparentBackdrop ?? backdrop ?? banner
        case .season:
            return poster ?? parentPoster ?? backdrop ?? banner
        default:
            return poster ?? parentPoster ?? grandparentPoster ?? backdrop ?? grandparentBackdrop ?? banner
        }
    }

    /// What a poster card shows when `preferredPoster` does not load. A
    /// season's own poster can be missing on the server while Plex still sends
    /// its path, so a new season of an old show in Recently Added would be a
    /// blank card; the show's poster stands in for it. The same goes for an
    /// episode showing its season's poster.
    func fallbackPoster(for kind: MediaKind) -> ArtworkRef? {
        let showPoster: ArtworkRef?
        switch kind {
        case .season:
            showPoster = parentPoster?.nonEmpty
        case .episode:
            showPoster = grandparentPoster?.nonEmpty
        default:
            return nil
        }
        guard let showPoster, showPoster != preferredPoster(for: kind) else { return nil }
        return showPoster
    }

    /// Best available landscape-style image for feature rows.
    func preferredLandscape(for kind: MediaKind) -> ArtworkRef? {
        switch kind {
        case .episode:
            return poster ?? backdrop ?? grandparentBackdrop ?? banner ?? grandparentPoster ?? parentPoster
        case .season:
            return backdrop ?? banner ?? poster ?? parentPoster
        default:
            return banner ?? backdrop ?? poster ?? parentPoster ?? grandparentBackdrop ?? grandparentPoster
        }
    }
}
