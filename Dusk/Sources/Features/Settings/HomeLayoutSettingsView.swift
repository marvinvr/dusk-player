import SwiftUI

#if !os(tvOS)
/// Reorders and hides the rows on Home. Changes go back to Plex whenever the
/// row is one Plex can manage, so the layout follows the account instead of the
/// device; see `HomeLayoutSettingsViewModel`.
struct HomeLayoutSettingsView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(UserPreferences.self) private var preferences
    @State private var viewModel: HomeLayoutSettingsViewModel?
    @State private var confirmsReset = false

    var body: some View {
        content
            .background(Color.duskBackground.ignoresSafeArea())
            .duskNavigationTitle("Home Screen")
            .duskNavigationBarTitleDisplayModeInline()
            .task(id: layoutContext) {
                let newViewModel = HomeLayoutSettingsViewModel(
                    plexService: plexService,
                    preferences: preferences,
                    context: layoutContext
                )
                viewModel = newViewModel
                await newViewModel.load()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let viewModel {
            if viewModel.isLoading, viewModel.rows.isEmpty {
                FeatureLoadingView()
            } else if let error = viewModel.error, viewModel.rows.isEmpty {
                FeatureErrorView(message: error) {
                    Task { await viewModel.load() }
                }
            } else {
                editor(viewModel)
            }
        } else {
            FeatureLoadingView()
        }
    }

    private func editor(_ viewModel: HomeLayoutSettingsViewModel) -> some View {
        List {
            Section {
                Toggle(isOn: featuredBinding(viewModel)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Continue Watching")
                            .foregroundStyle(Color.duskTextPrimary)
                        Text("The full-width hero at the top")
                            .font(.caption)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }
                .tint(Color.duskAccent)
            } header: {
                Text("Featured")
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                ForEach(viewModel.rows) { row in
                    Toggle(isOn: visibilityBinding(viewModel, row: row)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title)
                                .foregroundStyle(Color.duskTextPrimary)

                            if let subtitle = row.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(Color.duskTextSecondary)
                            }
                        }
                    }
                    .tint(Color.duskAccent)
                }
                .onMove(perform: viewModel.move(fromOffsets:toOffset:))
            } header: {
                Text("Rows")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(footerText(viewModel))
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            if viewModel.hasSavedLayout {
                Section {
                    Button("Reset Layout", role: .destructive) {
                        confirmsReset = true
                    }
                } footer: {
                    Text("Clears this device's row order and hidden rows. Rows stored on Plex keep their server settings.")
                        .foregroundStyle(Color.duskTextSecondary)
                }
                .listRowBackground(Color.duskSurface)
            }
        }
        .contentMargins(.top, 12, for: .scrollContent)
        .duskScrollContentBackgroundHidden()
        .toolbar {
            EditButton()
        }
        .confirmationDialog(
            "Reset the Home layout?",
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button("Reset Layout", role: .destructive) {
                Task { await viewModel.resetLayout() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .refreshable {
            await viewModel.load()
        }
    }

    private func footerText(_ viewModel: HomeLayoutSettingsViewModel) -> String {
        if viewModel.isSyncing {
            return "Saving the layout to Plex…"
        }

        if let syncWarning = viewModel.syncWarning {
            return syncWarning
        }

        let editingHint = "Tap Edit, then drag to change the order."

        if viewModel.syncsToPlex {
            return "\(editingHint) Rows your Plex server manages are saved to Plex, so other Plex apps follow the same layout. Everything else is saved on this device."
        }

        return "\(editingHint) This server doesn't let Dusk store the layout, so it is saved on this device."
    }

    private func featuredBinding(_ viewModel: HomeLayoutSettingsViewModel) -> Binding<Bool> {
        Binding(
            get: { viewModel.isFeaturedVisible },
            set: { viewModel.setFeaturedVisible($0) }
        )
    }

    private func visibilityBinding(
        _ viewModel: HomeLayoutSettingsViewModel,
        row: HomeLayoutSettingsViewModel.Row
    ) -> Binding<Bool> {
        Binding(
            get: { row.isVisible },
            set: { viewModel.setVisible($0, rowID: row.id) }
        )
    }

    private var layoutContext: String {
        UserPreferences.homeLayoutContext(
            serverID: plexService.currentServerIdentifier,
            profileID: plexService.activeProfileID
        )
    }
}
#endif
