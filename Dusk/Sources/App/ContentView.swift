import SwiftUI

/// Root view that routes between sign-in, server selection, and the main tab shell
/// based on PlexService auth/connection state.
struct ContentView: View {
    @Environment(PlexService.self) private var plexService
    @State private var discoveredServers: [PlexServer]?
    @State private var connectError: String?

    var body: some View {
        Group {
            if !plexService.isAuthenticated {
                SignInView()
            } else if plexService.isConnected {
                MainTabView()
            } else if let servers = discoveredServers, servers.count > 1 {
                ServerPickerView(servers: servers) { server in
                    Task { await connectTo(server) }
                }
            } else {
                serverDiscoveryView
            }
        }
        .animation(.default, value: plexService.isAuthenticated)
        .animation(.default, value: plexService.isConnected)
        .background(Color.duskBackground.ignoresSafeArea())
        .duskSuppressTVOSButtonChrome()
    }

    @ViewBuilder
    private var serverDiscoveryView: some View {
        VStack(spacing: 16) {
            if let error = connectError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(Color.duskTextSecondary)
                Text(error)
                    .foregroundStyle(Color.duskTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("Retry") {
                    connectError = nil
                    discoveredServers = nil
                }
                .duskSuppressTVOSButtonChrome()
            } else {
                ProgressView()
                    .tint(Color.duskAccent)
                Text("Finding your servers…")
                    .foregroundStyle(Color.duskTextSecondary)
            }
        }
        .task(id: connectError == nil) {
            guard connectError == nil else { return }
            await discoverAndConnect()
        }
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

    private func connectTo(_ server: PlexServer) async {
        connectError = nil
        do {
            try await plexService.connect(to: server)
            // Connection succeeded — isConnected becomes true and ContentView switches to MainTabView
        } catch {
            connectError = "Could not connect to \(server.name): \(error.localizedDescription)"
        }
    }
}
