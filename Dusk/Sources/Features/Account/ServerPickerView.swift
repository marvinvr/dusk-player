import SwiftUI

struct ServerPickerView: View {
    let servers: [PlexServer]
    let onSelect: (PlexServer) async throws -> Void
    @State private var connectingTo: String?
    @State private var connectionError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.duskBackground.ignoresSafeArea()

                VStack(spacing: 12) {
                    if let connectionError {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(Color.duskTextSecondary)

                            Text(connectionError)
                                .font(.callout)
                                .foregroundStyle(Color.duskTextSecondary)
                                .multilineTextAlignment(.leading)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }

                    List(servers) { server in
                        Button {
                            connectionError = nil
                            connectingTo = server.clientIdentifier

                            Task {
                                do {
                                    try await onSelect(server)
                                } catch {
                                    connectionError = "Could not connect to \(server.name): \(error.localizedDescription)"
                                    connectingTo = nil
                                }
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(server.name)
                                        .font(.headline)
                                        .foregroundStyle(Color.duskTextPrimary)

                                    Text(server.owned ? "Your server" : "Shared by \(server.sourceTitle ?? "Unknown")")
                                        .font(.caption)
                                        .foregroundStyle(Color.duskTextSecondary)
                                }

                                Spacer()

                                if connectingTo == server.clientIdentifier {
                                    ProgressView()
                                        .tint(Color.duskAccent)
                                } else {
                                    Circle()
                                        .fill(server.presence ? Color.duskAccent : Color.duskTextSecondary)
                                        .frame(width: 8, height: 8)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .disabled(connectingTo != nil)
                        .duskSuppressTVOSButtonChrome()
                        .listRowBackground(Color.duskSurface)
                    }
                    .duskScrollContentBackgroundHidden()
                    .duskNavigationTitle("Choose Server")
                }
            }
        }
    }
}
