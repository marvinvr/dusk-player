import SwiftUI

/// Root view that routes between sign-in, server selection, and the main tab shell
/// based on PlexService auth/connection state.
struct ContentView: View {
    @Environment(PlexService.self) private var plexService
    #if os(tvOS)
    @Environment(TopShelfCoordinator.self) private var topShelfCoordinator
    #endif
    @State private var discoveredServers: [PlexServer]?
    @State private var connectError: String?
    @State private var refreshedConnectionIdentifier: String?
    @State private var isRefreshingConnection = false
    @State private var showConnectionRefreshMessage = false

    var body: some View {
        Group {
            if !plexService.isAuthenticated {
                SignInView()
            } else if plexService.isConnected, isRefreshingConnection {
                connectionRefreshView
            } else if plexService.isConnected {
                MainTabView()
            } else if let servers = discoveredServers, servers.count > 1 {
                ServerPickerView(servers: servers) { server in
                    try await plexService.connect(to: server)
                } onSignOut: {
                    signOut()
                }
            } else {
                serverDiscoveryView
            }
        }
        .animation(.default, value: plexService.isAuthenticated)
        .animation(.default, value: plexService.isConnected)
        .background(Color.duskBackground.ignoresSafeArea())
        .duskSuppressTVOSButtonChrome()
        .task(id: plexService.currentServerIdentifier) {
            await refreshConnectedServerIfNeeded()
        }
        #if os(tvOS)
        .onOpenURL { topShelfCoordinator.handleOpenURL($0) }
        .onChange(of: plexService.isConnected) { _, isConnected in
            if isConnected {
                Task { await topShelfCoordinator.refresh() }
            }
        }
        .onChange(of: plexService.isAuthenticated) { _, isAuthenticated in
            if !isAuthenticated {
                topShelfCoordinator.handleSignOut()
            }
        }
        #endif
    }

    private var connectionRefreshView: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .tint(Color.duskAccent)
                if showConnectionRefreshMessage {
                    Text("Checking your server connection…")
                        .foregroundStyle(Color.duskTextSecondary)
                }
            }
        }
        .task {
            showConnectionRefreshMessage = false
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            showConnectionRefreshMessage = true
        }
    }

    @ViewBuilder
    private var serverDiscoveryView: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            VStack(spacing: 16) {
                if let error = connectError {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(Color.duskTextSecondary)
                    Text(error)
                        .foregroundStyle(Color.duskTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    VStack(spacing: 12) {
                        Button("Retry") {
                            resetDiscoveryState()
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(Color.duskAccent, in: Capsule())
                        .duskSuppressTVOSButtonChrome()
                        .duskTVOSFocusEffectShape(Capsule())

                        Button("Sign Out", role: .destructive) {
                            signOut()
                        }
                        .font(.headline)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                        .duskSuppressTVOSButtonChrome()
                        .duskTVOSFocusEffectShape(Capsule())
                    }
                } else {
                    ProgressView()
                        .tint(Color.duskAccent)
                    Text("Finding your servers…")
                        .foregroundStyle(Color.duskTextSecondary)
                }
            }
        }
        .task(id: connectError == nil) {
            guard connectError == nil else { return }
            await discoverAndConnect()
        }
    }

    private func refreshConnectedServerIfNeeded() async {
        guard plexService.isAuthenticated else {
            refreshedConnectionIdentifier = nil
            isRefreshingConnection = false
            showConnectionRefreshMessage = false
            return
        }

        guard plexService.isConnected,
              let connectionIdentifier = plexService.currentServerIdentifier,
              refreshedConnectionIdentifier != connectionIdentifier else {
            return
        }

        isRefreshingConnection = true
        showConnectionRefreshMessage = false
        connectError = nil

        do {
            try await plexService.refreshConnectedServerConnection()
            refreshedConnectionIdentifier = plexService.currentServerIdentifier ?? connectionIdentifier
        } catch {
            refreshedConnectionIdentifier = connectionIdentifier
            if !plexService.isConnected {
                connectError = error.localizedDescription
            }
        }

        isRefreshingConnection = false
        showConnectionRefreshMessage = false
    }

    private func discoverAndConnect() async {
        do {
            let servers = try await plexService.discoverServers()
            if servers.isEmpty {
                connectError = "No Plex servers found on your account."
            } else if servers.count == 1 {
                try await plexService.connect(to: servers[0])
            } else {
                discoveredServers = servers
            }
        } catch {
            connectError = error.localizedDescription
        }
    }

    private func resetDiscoveryState() {
        connectError = nil
        discoveredServers = nil
    }

    private func signOut() {
        resetDiscoveryState()
        refreshedConnectionIdentifier = nil
        isRefreshingConnection = false
        showConnectionRefreshMessage = false
        plexService.signOut()
    }
}
