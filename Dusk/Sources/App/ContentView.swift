import SwiftUI

/// Root view that routes between sign-in, server selection, and the main tab shell
/// based on PlexService auth/connection state.
struct ContentView: View {
    @Environment(PlexService.self) private var plexService
    @State private var discoveredServers: [PlexServer]?
    @State private var connectError: String?
    @State private var refreshedConnectionIdentifier: String?
    @State private var isRefreshingConnection = false

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
    }

    private var connectionRefreshView: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .tint(Color.duskAccent)
                Text("Checking your server connection…")
                    .foregroundStyle(Color.duskTextSecondary)
            }
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
                        .duskSuppressTVOSButtonChrome()

                        Button("Sign Out", role: .destructive) {
                            signOut()
                        }
                        .duskSuppressTVOSButtonChrome()
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
            return
        }

        guard plexService.isConnected,
              let connectionIdentifier = plexService.currentServerIdentifier,
              refreshedConnectionIdentifier != connectionIdentifier else {
            return
        }

        isRefreshingConnection = true
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
        plexService.signOut()
    }
}
