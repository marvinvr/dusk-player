import SwiftUI

/// The sign-in host (docs/jellyfin/04-architecture.md §7.2): lists the
/// registered providers' sign-in flows and shows the chosen flow's steps. Each
/// flow ends by handing `MediaService.completeSignIn` its account.
///
/// Plex is the only flow, so the host shows it directly and there is no
/// provider picker; the picker arrives with the Jellyfin flow (J-01).
struct SignInView: View {
    @Environment(MediaService.self) private var media

    var body: some View {
        if let flow = media.signInFlows.first {
            flowSteps(flow)
        }
    }

    @ViewBuilder
    private func flowSteps(_ flow: any SignInFlow) -> some View {
        if let plex = flow as? PlexSignInFlow {
            SignInPlexFlowView(flow: plex)
        }
    }
}
