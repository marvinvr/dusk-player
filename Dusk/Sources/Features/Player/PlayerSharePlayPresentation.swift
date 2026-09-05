import GroupActivities
import SwiftUI
import UIKit

#if os(iOS)
struct SharePlayInvitation: Identifiable {
    let id = UUID()
    let controller: GroupActivitySharingController
}

private struct SharePlayInvitationView: UIViewControllerRepresentable {
    let controller: GroupActivitySharingController

    func makeUIViewController(context: Context) -> GroupActivitySharingController {
        controller
    }

    func updateUIViewController(_ controller: GroupActivitySharingController, context: Context) {}
}
#endif

/// Present from the player cover while it is open, and from the app root for
/// incoming invitations that need sign-in. The root cannot alert over a cover.
private struct PlayerSharePlayPresentation: ViewModifier {
    @Environment(PlaybackCoordinator.self) private var playback
    let isPlayer: Bool

    private var isPresentationHost: Bool {
        playback.showPlayer == isPlayer
    }

    func body(content: Content) -> some View {
        content
            .alert(
                "SharePlay",
                isPresented: Binding(
                    get: { isPresentationHost && playback.sharePlayError != nil },
                    set: { presented in
                        if !presented, isPresentationHost {
                            playback.dismissSharePlayError()
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {
                    playback.dismissSharePlayError()
                }
            } message: {
                Text(playback.sharePlayError ?? "SharePlay is unavailable.")
            }
            #if os(iOS)
            .sheet(item: Binding(
                get: { isPresentationHost ? playback.sharePlayController.invitation : nil },
                set: { invitation in
                    if isPresentationHost {
                        playback.sharePlayController.invitation = invitation
                    }
                }
            )) { invitation in
                SharePlayInvitationView(controller: invitation.controller)
                    .task {
                        _ = await invitation.controller.result
                        // UIKit also dismisses itself. Clear SwiftUI's state so
                        // either completion or cancellation permits another try.
                        if playback.sharePlayController.invitation?.id == invitation.id {
                            playback.sharePlayController.invitation = nil
                        }
                    }
            }
            #endif
    }
}

extension View {
    func playerSharePlayPresentation(isPlayer: Bool) -> some View {
        modifier(PlayerSharePlayPresentation(isPlayer: isPlayer))
    }
}
