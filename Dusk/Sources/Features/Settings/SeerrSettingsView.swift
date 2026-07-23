import SwiftUI

struct SeerrSettingsView: View {
    @Environment(SeerrService.self) private var seerrService
    @State private var viewModel = SeerrSettingsViewModel()

    var body: some View {
        Group {
            #if os(tvOS)
            tvContent
            #else
            iosContent
            #endif
        }
        .background(Color.duskBackground.ignoresSafeArea())
        .duskNavigationTitle("Seerr")
        .task {
            viewModel.load(from: seerrService)
        }
        .confirmationDialog(
            "Connect to Seerr?",
            isPresented: $viewModel.showsConnectionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Connect") {
                Task { await viewModel.connect(using: seerrService) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(viewModel.confirmationMessage)
        }
    }

    #if !os(tvOS)
    private var iosContent: some View {
        List {
            Section {
                TextField("Server URL", text: $viewModel.serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(seerrService.isConnected || viewModel.isWorking)

                connectionRow
            } header: {
                Text("Server")
            } footer: {
                Text("Enter the address you use for Seerr.")
            }
            .listRowBackground(Color.duskSurface)

            if let errorMessage = viewModel.errorMessage ?? seerrService.lastConnectionError {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.duskTextSecondary)
                }
                .listRowBackground(Color.duskSurface)
            }

            Section {
                if seerrService.isConnected {
                    Button("Disconnect", role: .destructive) {
                        Task { await viewModel.disconnect(using: seerrService) }
                    }
                    .disabled(viewModel.isWorking)
                } else {
                    Button {
                        Task { await viewModel.prepareConnection(using: seerrService) }
                    } label: {
                        HStack {
                            Text("Connect with Plex")
                            Spacer()
                            if viewModel.isWorking {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(viewModel.isWorking || viewModel.serverURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .listRowBackground(Color.duskSurface)
        }
        .scrollContentBackground(.hidden)
    }
    #endif

    #if os(tvOS)
    private var tvContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                TVSettingsSection(
                    title: "Server",
                    footer: "Enter the address you use for Seerr."
                ) {
                    TVSettingsURLFieldRow(
                        prompt: "Server URL",
                        text: $viewModel.serverURL,
                        isDisabled: seerrService.isConnected || viewModel.isWorking
                    )

                    tvRowDivider
                    connectionRow
                }

                if let errorMessage = viewModel.errorMessage ?? seerrService.lastConnectionError {
                    TVSettingsSection(title: "Connection") {
                        Text(errorMessage)
                            .foregroundStyle(Color.duskTextSecondary)
                            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                    }
                }

                TVSettingsSection(
                    title: "Account",
                    footer: "This connection is kept separate for each Plex Home user and Plex server."
                ) {
                    if seerrService.isConnected {
                        TVSettingsActionRow(
                            title: "Disconnect",
                            tint: .red,
                            role: .destructive,
                            isLoading: viewModel.isWorking
                        ) {
                            Task { await viewModel.disconnect(using: seerrService) }
                        }
                    } else {
                        TVSettingsActionRow(
                            title: "Connect with Plex",
                            tint: Color.duskAccent,
                            isLoading: viewModel.isWorking
                        ) {
                            Task { await viewModel.prepareConnection(using: seerrService) }
                        }
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.top, 48)
            .padding(.bottom, 88)
        }
    }
    #endif

    private var connectionRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Status")
                    .foregroundStyle(Color.duskTextPrimary)
                Text(seerrService.connectionSubtitle)
                    .font(.caption)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            Spacer()
            Circle()
                .fill(seerrService.isConnected ? Color.duskAccent : Color.duskTextSecondary.opacity(0.5))
                .frame(width: 9, height: 9)
        }
        .frame(minHeight: 52)
    }

    private var tvRowDivider: some View {
        Rectangle()
            .fill(Color.duskTextSecondary.opacity(0.16))
            .frame(height: 1)
    }
}
