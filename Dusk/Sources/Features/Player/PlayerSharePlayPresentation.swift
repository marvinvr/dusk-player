import GroupActivities
import SwiftUI
import UIKit

#if os(iOS)
struct SharePlayInvitation: Identifiable {
    let id = UUID()
    let controller: GroupActivitySharingController
}

private struct SharePlayInvitationPresenter: UIViewControllerRepresentable {
    @Binding var invitation: SharePlayInvitation?

    func makeUIViewController(context: Context) -> SharePlayPresentationAnchor {
        SharePlayPresentationAnchor()
    }

    func updateUIViewController(_ anchor: SharePlayPresentationAnchor, context: Context) {
        anchor.onCompletion = { id in
            if invitation?.id == id {
                invitation = nil
            }
        }
        anchor.update(invitation: invitation)
    }

    static func dismantleUIViewController(_ anchor: SharePlayPresentationAnchor, coordinator: ()) {
        anchor.stopPresenting()
    }
}

/// GroupActivitySharingController dismisses itself. It must be a real modal,
/// not a child embedded in a SwiftUI sheet whose dismissal can reach the player.
private final class SharePlayPresentationAnchor: UIViewController, UIAdaptivePresentationControllerDelegate {
    var onCompletion: ((UUID) -> Void)?
    private var invitation: SharePlayInvitation?
    private var presentedInvitation: SharePlayInvitation?
    private var resultTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentInvitationIfNeeded()
    }

    func update(invitation: SharePlayInvitation?) {
        self.invitation = invitation
        if let presentedInvitation, presentedInvitation.id != invitation?.id {
            stopPresenting()
        }
        presentInvitationIfNeeded()
    }

    private func presentInvitationIfNeeded() {
        guard let invitation, presentedInvitation == nil,
              viewIfLoaded?.window != nil else { return }
        presentedInvitation = invitation
        present(invitation.controller, animated: true)
        invitation.controller.presentationController?.delegate = self
        resultTask = Task { @MainActor [weak self] in
            _ = await invitation.controller.result
            guard !Task.isCancelled else { return }
            // The system owns dismissal on success and cancellation. Only
            // clear our request; never dismiss the presenting player here.
            self?.complete(invitation.id)
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let presentedInvitation,
              presentationController.presentedViewController === presentedInvitation.controller else { return }
        complete(presentedInvitation.id)
    }

    private func complete(_ id: UUID) {
        guard presentedInvitation?.id == id else { return }
        presentedInvitation = nil
        invitation = nil
        resultTask?.cancel()
        resultTask = nil
        onCompletion?(id)
    }

    func stopPresenting() {
        guard let presentedInvitation else { return }
        let controller = presentedInvitation.controller
        complete(presentedInvitation.id)
        // Target only our still-presented modal, never its presenter. This
        // also makes removal of the player safe during an outstanding invite.
        if controller.presentingViewController != nil, !controller.isBeingDismissed {
            controller.dismiss(animated: true)
        }
    }

    deinit {
        resultTask?.cancel()
    }
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
            .background {
                if isPlayer {
                    SharePlayInvitationPresenter(invitation: Binding(
                        get: { playback.sharePlayController.invitation },
                        set: { playback.sharePlayController.invitation = $0 }
                    ))
                    .frame(width: 0, height: 0)
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
