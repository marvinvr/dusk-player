import SwiftUI

/// Reorders and hides the rows on Home. The complete Dusk layout syncs through
/// iCloud; managed library rows also go back to Plex where its API permits it.
///
/// This view owns the view model and its loading states for both platforms; the
/// editors themselves differ because the input models do (drag-to-reorder on
/// iOS/iPadOS, a remote pick-up in `HomeLayoutSettingsTVView`).
struct HomeLayoutSettingsView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(UserPreferences.self) private var preferences
    @State private var viewModel: HomeLayoutSettingsViewModel?
    #if !os(tvOS)
    @State private var confirmsReset = false
    #endif

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

    @ViewBuilder
    private func editor(_ viewModel: HomeLayoutSettingsViewModel) -> some View {
        #if os(tvOS)
        HomeLayoutSettingsTVView(viewModel: viewModel)
        #else
        iosEditor(viewModel)
        #endif
    }

    #if !os(tvOS)
    private func iosEditor(_ viewModel: HomeLayoutSettingsViewModel) -> some View {
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
                    Text(HomeLayoutSettingsCopy.resetFooter)
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
            return HomeLayoutSettingsCopy.syncingFooter
        }

        if let syncWarning = viewModel.syncWarning {
            return syncWarning
        }

        let editingHint = "Tap Edit, then drag to change the order."
        return "\(editingHint) \(HomeLayoutSettingsCopy.syncFooter(syncsToPlex: viewModel.syncsToPlex))"
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
    #endif

    private var layoutContext: String {
        UserPreferences.homeLayoutContext(
            serverID: plexService.currentServerIdentifier,
            profileID: plexService.activeProfileID
        )
    }
}

/// Copy both platform editors share, so the two screens describe the same
/// syncing behavior in the same words.
enum HomeLayoutSettingsCopy {
    static let featuredFooter = "Continue Watching is the full-width hero pinned to the top of Home."
    static let syncingFooter = "Saving the layout to Plex…"
    static let resetFooter = "Clears the Dusk row order and hidden rows from this device and its iCloud peers. Rows stored on Plex keep their server settings."

    static func syncFooter(syncsToPlex: Bool) -> String {
        if syncsToPlex {
            return "The complete layout syncs to your Dusk devices through iCloud. Managed rows are also saved within their Plex library."
        }
        return "The layout syncs to your Dusk devices through iCloud. This server doesn't allow Plex-managed row changes."
    }
}
