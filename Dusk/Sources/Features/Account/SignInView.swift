import SwiftUI

/// The sign-in host (docs/jellyfin/04-architecture.md §7.2): Plex's welcome
/// screen with one entry per other registered provider under its own button,
/// and the chosen flow's steps. Plex's flow ends in
/// `MediaService.completeSignIn`, Jellyfin's in `completeJellyfinSignIn`.
struct SignInView: View {
    @Environment(MediaService.self) private var media
    @State private var chosenFlow: ProviderKind? = Self.initialFlow

    /// DEBUG only: `-DuskSignInFlow jellyfin` opens that flow at launch, for
    /// simulator screenshots of its steps.
    private static var initialFlow: ProviderKind? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "DuskSignInFlow").flatMap(ProviderKind.init(rawValue:))
        #else
        nil
        #endif
    }

    var body: some View {
        Group {
            if chosenFlow == .jellyfin, let jellyfin = media.jellyfinSignInFlow {
                SignInJellyfinFlowView(flow: jellyfin) {
                    chosenFlow = nil
                }
                .transition(.opacity)
            } else if let plex = media.signInFlows.lazy.compactMap({ $0 as? PlexSignInFlow }).first {
                SignInPlexFlowView(flow: plex, otherFlows: otherEntries)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: chosenFlow)
    }

    private var otherEntries: [SignInHostEntry] {
        media.signInFlows
            .filter { $0.kind != .plex }
            .map { flow in
                SignInHostEntry(id: flow.productName, title: "Sign in with \(flow.productName)") {
                    chosenFlow = flow.kind
                }
            }
    }
}

/// Another provider's button on the welcome screen.
struct SignInHostEntry: Identifiable {
    let id: String
    let title: String
    let action: () -> Void
}
