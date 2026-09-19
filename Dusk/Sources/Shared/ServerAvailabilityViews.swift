import SwiftUI

/// The states Home, Libraries and Search share when the problem is the servers
/// rather than the screen.
///
/// Dusk connects to every enabled server at once, so "no content" now has three
/// distinct causes the user can act on — every server is switched off, every
/// server is unreachable, or we are still probing — and one that needs no action
/// at all: some servers answered and some did not. The first three replace the
/// screen; the last is a quiet inline note, because the content that *did* load
/// is perfectly usable. None of them is ever a modal blocker.
struct ServerAvailabilityStateView: View {
    @Environment(ServerConnectionCoordinator.self) private var connections

    let availability: ServerAvailability
    @State private var showsServerPriority = false

    var body: some View {
        Group {
            switch availability {
            case .unknown, .connecting:
                // The pool stays `.unknown` when discovery itself never got far
                // enough to produce server states — no internet on a fresh
                // install, plex.tv down — so a spinner there would never end.
                if let message = startupFailureMessage {
                    unreachableState(message: message)
                } else {
                    FeatureLoadingView()
                }
            case .allDisabled:
                actionableState(
                    systemImage: "server.rack",
                    title: "Every server is turned off",
                    message: "Turn a server back on in Server Priority to see your libraries.",
                    buttonTitle: "Server Priority"
                )
            case let .unreachable(reason):
                unreachableState(message: reason ?? Self.unreachableMessage)
            case .ready:
                EmptyView()
            }
        }
        .serverPrioritySheet(isPresented: $showsServerPriority)
    }

    static let unreachableMessage = "Dusk can't reach any of your Plex servers right now."

    /// Why a still-pending pool is actually stuck: the first connect pass has
    /// finished, nothing is running, and it left us without a single server
    /// state to show.
    private var startupFailureMessage: String? {
        guard connections.hasCompletedFirstPass, !connections.isConnecting else { return nil }
        return connections.lastError ?? Self.unreachableMessage
    }

    private func unreachableState(message: String) -> some View {
        VStack(spacing: 20) {
            FeatureErrorView(message: message) {
                Task { await connections.refresh() }
            }
            serverPriorityButton("Server Priority")
        }
    }

    private func actionableState(
        systemImage: String,
        title: String,
        message: String,
        buttonTitle: String
    ) -> some View {
        VStack(spacing: 20) {
            FeatureEmptyStateView(systemImage: systemImage, title: title, message: message)
            serverPriorityButton(buttonTitle)
        }
    }

    private func serverPriorityButton(_ title: String) -> some View {
        Button(title) {
            showsServerPriority = true
        }
        .font(.headline)
        .foregroundStyle(Color.duskTextPrimary)
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(Color.duskSurface, in: Capsule())
        .duskSuppressTVOSButtonChrome()
        .duskTVOSFocusEffectShape(Capsule())
    }
}

/// A one-line note that some of the account's servers are missing.
///
/// Deliberately unobtrusive: the rest of the screen is real content from the
/// servers that did answer, and turning a transient outage into an error would
/// make a two-server account feel broken every time the laptop sleeps.
struct ServerOutageNote: View {
    @Environment(ServerConnectionCoordinator.self) private var connections
    @Environment(PlexService.self) private var plexService

    /// Explicit list, or nil to read the pool's current one. Screens that
    /// already hold an availability value pass it; the rest just drop the note
    /// in and it renders nothing while every server is fine.
    private let explicitOfflineServerNames: [String]?

    init(offlineServerNames: [String]? = nil) {
        explicitOfflineServerNames = offlineServerNames
    }

    private var offlineServerNames: [String] {
        explicitOfflineServerNames ?? plexService.pool.availability.offlineServerNames
    }

    var body: some View {
        if !offlineServerNames.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                Text(message)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Retry") {
                    Task { await connections.refresh() }
                }
                .duskSuppressTVOSButtonChrome()
            }
            .font(.footnote)
            .foregroundStyle(Color.duskTextSecondary)
        }
    }

    private var message: String {
        let names = ListFormatter.localizedString(byJoining: offlineServerNames)
        guard offlineServerNames.count > 1 else {
            return "\(names) is offline, so some of your library is missing."
        }
        return "\(names) are offline, so some of your library is missing."
    }
}

extension View {
    /// Presents Server Priority without leaving the current tab. An empty state
    /// has to be able to send the user straight to the switch that caused it.
    func serverPrioritySheet(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            NavigationStack {
                ServerPrioritySettingsView()
                    #if !os(tvOS)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isPresented.wrappedValue = false }
                        }
                    }
                    #endif
            }
        }
    }
}
