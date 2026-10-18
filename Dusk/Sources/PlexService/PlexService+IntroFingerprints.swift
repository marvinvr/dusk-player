import Foundation

/// Captured before the write, so a late response never resolves identities in
/// the profile or primary server that replaced the initiating session.
struct IntroFingerprintResetTarget {
    let profileID: String
    let serverID: String
    let ratingKey: String
    let type: PlexMediaType?
    let seasonRatingKeys: [String]
}

extension PlexService {
    func prepareIntroFingerprintReset(ratingKey: String, serverID: String) async -> IntroFingerprintResetTarget? {
        let session = serverSessionToken
        guard let profile = session.profileID else { return nil }
        // Read without reconciliation: a failed mutation must not itself clear
        // anything. Metadata failure still permits resetting known cache scopes.
        let items: [PlexMediaDetails]? = try? await fetchMetadata(
            path: PlexMetadataCache.metadataEndpoint(ratingKey), serverID: serverID
        )
        guard session == serverSessionToken, !Task.isCancelled else { return nil }
        let details = items?.first
        var seasons: [String] = []
        if details?.type == .show {
            let children: [PlexSeason]? = try? await fetchMetadata(
                path: PlexMetadataCache.childrenEndpoint(ratingKey), serverID: serverID
            )
            guard session == serverSessionToken, !Task.isCancelled else { return nil }
            seasons = (children ?? []).map(\.ratingKey)
        }
        return IntroFingerprintResetTarget(profileID: profile, serverID: serverID,
                                           ratingKey: ratingKey, type: details?.type, seasonRatingKeys: seasons)
    }

    func applyIntroFingerprintReset(_ target: IntroFingerprintResetTarget) {
        let store = IntroFingerprintStore.shared
        switch target.type {
        case .episode:
            store.noteEpisodeWatchState(viewerProfileID: target.profileID, serverID: target.serverID,
                                        episodeRatingKey: target.ratingKey, watched: false, confirmed: true)
        case .season:
            store.removeSeason(.init(viewerProfileID: target.profileID, serverID: target.serverID,
                                     seasonRatingKey: target.ratingKey))
        case .show:
            store.removeShow(viewerProfileID: target.profileID, serverID: target.serverID,
                             showRatingKey: target.ratingKey, seasonRatingKeys: target.seasonRatingKeys)
        case nil:
            store.removeItem(viewerProfileID: target.profileID, serverID: target.serverID, ratingKey: target.ratingKey)
        default:
            break
        }
    }

    func registerIntroFingerprintHierarchy(_ details: PlexMediaDetails, profileID: String) {
        let season: String?
        let show: String?
        switch details.type {
        case .episode:
            season = details.parentRatingKey
            show = details.grandparentRatingKey
        case .season:
            season = details.ratingKey
            show = details.parentRatingKey
        default:
            return
        }
        guard let server = details.serverID, let season else { return }
        IntroFingerprintStore.shared.registerSeason(
            .init(viewerProfileID: profileID, serverID: server, seasonRatingKey: season),
            showRatingKey: show, accountProfileID: primaryProfileID
        )
    }
}
