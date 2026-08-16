import SwiftUI

struct FeatureLoadingView: View {
    var body: some View {
        ProgressView()
            .tint(Color.duskAccent)
    }
}

struct FeatureEmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(Color.duskTextSecondary)

            Text(title)
                .foregroundStyle(Color.duskTextSecondary)

            if let message, !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color.duskTextSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

struct FeatureErrorView: View {
    @Environment(PlexService.self) private var plexService

    let message: String
    let retryTitle: String
    let retryAction: () -> Void

    init(
        message: String,
        retryTitle: String = "Retry",
        retryAction: @escaping () -> Void
    ) {
        self.message = message
        self.retryTitle = retryTitle
        self.retryAction = retryAction
    }

    private var requiresSignIn: Bool {
        AuthenticationFailure.requiresReauthentication(message: message)
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(Color.duskTextSecondary)

            Text(message)
                .foregroundStyle(Color.duskTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button(requiresSignIn ? "Sign In" : retryTitle) {
                if requiresSignIn {
                    AuthenticationFailure.beginReauthentication(plexService: plexService)
                } else {
                    retryAction()
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
            .background(Color.duskAccent, in: Capsule())
            .duskSuppressTVOSButtonChrome()
            .duskTVOSFocusEffectShape(Capsule())
        }
    }
}

/// Shared detection and recovery for a dead Plex account session.
/// View models store `localizedDescription`, so message matching is the
/// feature-layer signal; typed errors use `requiresReauthentication` directly.
enum AuthenticationFailure {
    static func requiresReauthentication(message: String) -> Bool {
        message == PlexServiceError.unauthorized.errorDescription
            || message == PlexServiceError.notAuthenticated.errorDescription
            || message == PlaybackError.unauthorized.errorDescription
    }

    @MainActor
    static func beginReauthentication(
        plexService: PlexService,
        playback: PlaybackCoordinator? = nil
    ) {
        playback?.onPlayerDismissed()
        plexService.signOut()
    }
}
