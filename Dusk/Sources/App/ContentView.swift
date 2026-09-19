import SwiftUI

/// Root view that routes between sign-in, the Plex Home profile picker, and the
/// main tab shell.
///
/// There is no server step: once the session is ready the shell mounts and
/// `ServerConnectionCoordinator` connects every enabled server underneath it.
/// The user never waits for the slowest server, and a server that never answers
/// is a per-screen note rather than a wall.
struct ContentView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.scenePhase) private var scenePhase
    @State private var connections = ServerConnectionCoordinator()
    @State private var homeBootstrapError: String?
    @State private var isBootstrappingHome = false

    var body: some View {
        Group {
            if !plexService.isAuthenticated {
                SignInView()
            } else if !plexService.homeBootstrapCompleted {
                homeBootstrapView
            } else if plexService.needsHomeUserSelection {
                HomeUserPickerView(
                    users: plexService.homeUsers,
                    rememberSelection: plexService.automaticHomeSignIn,
                    onSignOut: {
                        signOut()
                    }
                )
            } else {
                MainTabView()
                    .id(plexService.activeProfileID)
            }
        }
        .environment(connections)
        .animation(.default, value: plexService.isAuthenticated)
        .animation(.default, value: plexService.homeBootstrapCompleted)
        .animation(.default, value: plexService.needsHomeUserSelection)
        .background(Color.duskBackground.ignoresSafeArea())
        .duskSuppressTVOSButtonChrome()
        .task(id: plexService.isAuthenticated) {
            await bootstrapHomeIfNeeded()
        }
        .task(id: serverConnectionTaskID) {
            connections.start(plexService: plexService)
            await connections.connectIfNeeded(session: plexService.activeProfileID)
        }
        .task(id: sharePlayReadinessTaskID) {
            await playback.retryPendingSharePlayActivityIfPossible()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            connections.applicationDidBecomeActive()
        }
        .playerSharePlayPresentation(isPlayer: false)
    }

    /// Re-runs the connect pass whenever the session identity changes: sign-in,
    /// the end of Home bootstrap, and every profile switch.
    private var serverConnectionTaskID: ServerConnectionTaskID {
        ServerConnectionTaskID(
            isAuthenticated: plexService.isAuthenticated,
            homeBootstrapCompleted: plexService.homeBootstrapCompleted,
            needsHomeUserSelection: plexService.needsHomeUserSelection,
            profileID: plexService.activeProfileID
        )
    }

    /// A pending SharePlay activity may be for an item on any server, so the
    /// retry is keyed on the whole pool rather than on one server: the item's
    /// server may well be the last one to answer.
    private var sharePlayReadinessTaskID: SharePlayReadinessTaskID {
        SharePlayReadinessTaskID(
            isAuthenticated: plexService.isAuthenticated,
            homeBootstrapCompleted: plexService.homeBootstrapCompleted,
            needsHomeUserSelection: plexService.needsHomeUserSelection,
            servers: plexService.serverContentRevision
        )
    }

    private var homeBootstrapView: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            VStack(spacing: 18) {
                if let homeBootstrapError {
                    Image(systemName: "person.2.slash")
                        .font(DuskFont.glyphLarge(ios: .largeTitle))
                        .foregroundStyle(Color.duskTextSecondary)

                    Text("Couldn’t load Plex")
                        .font(DuskFont.sectionHeader(ios: .headline))
                        .foregroundStyle(Color.duskTextPrimary)

                    Text(homeBootstrapError)
                        .duskFont(tvOnly: DuskFont.TV.body)
                        .foregroundStyle(Color.duskTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .frame(maxWidth: 680)

                    VStack(spacing: 12) {
                        if AuthenticationFailure.requiresReauthentication(message: homeBootstrapError) {
                            Button("Sign In") {
                                signOut()
                            }
                            .font(DuskFont.buttonLabel(ios: .headline))
                            .foregroundStyle(Color.duskPrimaryActionLabel)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(Color.primary.opacity(0.88), in: Capsule())
                            .duskSuppressTVOSButtonChrome()
                            .duskTVOSFocusEffectShape(Capsule())
                        } else {
                            Button("Retry") {
                                Task { await bootstrapHomeIfNeeded(force: true) }
                            }
                            .font(DuskFont.buttonLabel(ios: .headline))
                            .foregroundStyle(Color.duskPrimaryActionLabel)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(Color.primary.opacity(0.88), in: Capsule())
                            .disabled(isBootstrappingHome)
                            .duskSuppressTVOSButtonChrome()
                            .duskTVOSFocusEffectShape(Capsule())

                            Button("Sign Out", role: .destructive) {
                                signOut()
                            }
                            .font(DuskFont.buttonLabel(ios: .headline))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule())
                            .duskSuppressTVOSButtonChrome()
                            .duskTVOSFocusEffectShape(Capsule())
                        }
                    }
                } else {
                    ProgressView()
                        .tint(Color.duskAccent)

                    Text("Loading…")
                        .duskFont(tvOnly: DuskFont.TV.body)
                        .foregroundStyle(Color.duskTextSecondary)
                }
            }
        }
    }

    private func bootstrapHomeIfNeeded(force: Bool = false) async {
        guard plexService.isAuthenticated else {
            homeBootstrapError = nil
            isBootstrappingHome = false
            return
        }

        guard force || !plexService.homeBootstrapCompleted else { return }
        guard !isBootstrappingHome else { return }

        isBootstrappingHome = true
        homeBootstrapError = nil

        do {
            try await plexService.bootstrapHomeSession()
        } catch {
            homeBootstrapError = error.localizedDescription
        }

        isBootstrappingHome = false
    }

    private func signOut() {
        homeBootstrapError = nil
        isBootstrappingHome = false
        // Sign-out clears the pool and the stored priority order in the
        // service; the coordinator only has to forget that it ever ran.
        plexService.signOut()
    }
}

private struct ServerConnectionTaskID: Hashable {
    let isAuthenticated: Bool
    let homeBootstrapCompleted: Bool
    let needsHomeUserSelection: Bool
    let profileID: String?
}

private struct SharePlayReadinessTaskID: Hashable {
    let isAuthenticated: Bool
    let homeBootstrapCompleted: Bool
    let needsHomeUserSelection: Bool
    let servers: ServerContentRevision
}
