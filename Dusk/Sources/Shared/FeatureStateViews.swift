import SwiftUI

struct FeatureLoadingView: View {
    var body: some View {
        ProgressView()
            .macStatePageToolbar()
    }
}

struct FeatureEmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String?

    var body: some View {
        #if os(macOS)
        ContentUnavailableView {
            MacFeatureStateLabel(title: title, systemImage: systemImage)
        } description: {
            if let message, !message.isEmpty {
                Text(message)
            }
        }
        .macStatePageToolbar()
        #else
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(DuskFont.glyphLarge(ios: .largeTitle))
                .foregroundStyle(Color.duskTextSecondary)

            Text(title)
                .duskFont(tvOnly: DuskFont.TV.rowTitle)
                .foregroundStyle(Color.duskTextSecondary)

            if let message, !message.isEmpty {
                Text(message)
                    .font(DuskFont.caption(ios: .subheadline))
                    .foregroundStyle(Color.duskTextSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        #endif
    }
}

struct FeatureErrorView: View {
    @Environment(PlexService.self) private var plexService

    let message: String
    let retryTitle: String
    /// Mac only: the headline above the message ("Couldn't Load Channels").
    /// iOS and tvOS show the message alone.
    let title: String?
    /// Mac only: a second button next to Try Again, such as "Open Live TV
    /// Settings…". iOS and tvOS ignore it.
    let secondaryAction: FeatureStateAction?
    let retryAction: () -> Void

    init(
        message: String,
        retryTitle: String = "Retry",
        title: String? = nil,
        secondaryAction: FeatureStateAction? = nil,
        retryAction: @escaping () -> Void
    ) {
        self.message = message
        self.retryTitle = retryTitle
        self.title = title
        self.secondaryAction = secondaryAction
        self.retryAction = retryAction
    }

    private var requiresSignIn: Bool {
        AuthenticationFailure.requiresReauthentication(message: message)
    }

    var body: some View {
        #if os(macOS)
        ContentUnavailableView {
            MacFeatureStateLabel(
                title: requiresSignIn ? "Signed Out of Plex" : (title ?? "Couldn’t Load"),
                systemImage: requiresSignIn ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle"
            )
        } description: {
            Text(message)
        } actions: {
            HStack(spacing: 10) {
                if !requiresSignIn, let secondaryAction {
                    Button(secondaryAction.title, action: secondaryAction.action)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                FeaturePrimaryButton(title: requiresSignIn ? "Sign In" : macRetryTitle) {
                    if requiresSignIn {
                        AuthenticationFailure.beginReauthentication(plexService: plexService)
                    } else {
                        retryAction()
                    }
                }
            }
        }
        .macStatePageToolbar()
        #else
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(DuskFont.glyphLarge(ios: .largeTitle))
                .foregroundStyle(Color.duskTextSecondary)

            Text(message)
                .duskFont(tvOnly: DuskFont.TV.rowTitle)
                .foregroundStyle(Color.duskTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            FeaturePrimaryButton(title: requiresSignIn ? "Sign In" : retryTitle) {
                if requiresSignIn {
                    AuthenticationFailure.beginReauthentication(plexService: plexService)
                } else {
                    retryAction()
                }
            }
        }
        #endif
    }

    #if os(macOS)
    /// The Mac says "Try Again", like the system's own error states.
    private var macRetryTitle: String {
        retryTitle == "Retry" ? "Try Again" : retryTitle
    }
    #endif
}

/// A secondary button of a Mac error state (`FeatureErrorView`).
struct FeatureStateAction {
    let title: String
    let action: () -> Void
}

extension View {
    /// Mac main window: a loading/empty/error state replaces a page's scroll
    /// view, and without a scroll view macOS 26 draws the (automatic) window
    /// toolbar background as an opaque band. A state keeps the toolbar
    /// transparent instead; a page's scroll view gets the soft scroll edge
    /// back as soon as the state goes away. No-op elsewhere (Settings
    /// window, sheets, iOS, tvOS).
    @ViewBuilder
    func macStatePageToolbar() -> some View {
        #if os(macOS)
        modifier(MacStatePageToolbar())
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct MacStatePageToolbar: ViewModifier {
    @Environment(\.macShellManagesBackNavigation) private var isMainWindow

    func body(content: Content) -> some View {
        if isMainWindow {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

/// The headline of a Mac empty/error state: `ContentUnavailableView` draws
/// its label in a secondary style on the Mac, which reads as disabled; the
/// title stays primary, the glyph and description secondary.
private struct MacFeatureStateLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
    }
}
#endif

/// The single action of an error or empty state, such as Retry or Sign In.
/// Same neutral glass as the detail pages' Play button.
struct FeaturePrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        #if os(macOS)
        // A plain bordered push button, as in the system's empty states.
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.large)
        #else
        Button(action: action) {
            Text(title)
                .font(DuskFont.buttonLabel(ios: .headline))
                .padding(.horizontal, 12)
                #if !os(tvOS)
                .foregroundStyle(Color.duskPrimaryActionLabel)
                #endif
        }
        .detailHeroNativePrimaryButtonStyle()
        #endif
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
