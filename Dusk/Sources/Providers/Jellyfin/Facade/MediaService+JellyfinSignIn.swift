import Foundation

/// The Jellyfin sign-in on the facade, for `SignInJellyfinFlowView`.
extension MediaService {
    /// The Jellyfin sign-in flow, for its own screens.
    var jellyfinSignInFlow: JellyfinSignInFlow? {
        signInFlows.lazy.compactMap { $0 as? JellyfinSignInFlow }.first
    }

    /// The end of the Jellyfin flow: the user it signed in becomes the
    /// primary account and the active profile. Starts from an empty pool, as a
    /// new Plex sign-in does.
    func completeJellyfinSignIn(_ result: JellyfinSignInFlow.Result) {
        guard let flow = jellyfinSignInFlow else { return }
        tearDownServerSessions(forgetServers: true)
        flow.account.add(result)
    }
}
