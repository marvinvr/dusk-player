import SwiftUI

/// The one place to hide libraries: a switch per library, grouped by server
/// when there are several. A hidden library is gone from Dusk completely — tabs,
/// library lists, Home, search, Siri, the Top Shelf (see `HiddenLibraryFilter`).
///
/// The flag is the Plex account's `pinnedSources[].isHidden`, written through
/// `LibraryOrderSettingsViewModel` like the order, so Plex Web and the other Plex
/// apps hide the library too.
struct HiddenLibrariesSettingsView: View {
    @Environment(PlexService.self) private var plexService
    @State private var viewModel: LibraryOrderSettingsViewModel?

    static let footerText = "Hidden libraries are also hidden in other Plex apps."

    var body: some View {
        content
            .duskSettingsPageBackground()
            .duskNavigationTitle("Hidden Libraries")
            .duskNavigationBarTitleDisplayModeInline()
            .task {
                let model = viewModel ?? LibraryOrderSettingsViewModel(plexService: plexService)
                viewModel = model
                await model.load()
            }
            .onDisappear {
                guard let viewModel else { return }
                // The debounce may still be counting down; leaving the screen
                // must not drop the edit.
                Task { await viewModel.flushPendingWrite() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let viewModel {
            if viewModel.isLoading, viewModel.libraries.isEmpty {
                FeatureLoadingView()
            } else if let error = viewModel.error, viewModel.libraries.isEmpty {
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
    private func editor(_ viewModel: LibraryOrderSettingsViewModel) -> some View {
        let groups = viewModel.hideableLibrariesByServer
        let showsServers = groups.count > 1

        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    TVSettingsSection(
                        title: showsServers ? group.serverName : "Libraries",
                        footer: index == groups.count - 1 ? Self.footerText : nil
                    ) {
                        // Keyed on the library's own id: `PlexLibrary`'s
                        // Hashable conformance only looks at `key`, which two
                        // servers can both hand out.
                        ForEach(Array(group.libraries.enumerated()), id: \.element.id) { index, library in
                            if index > 0 {
                                Rectangle()
                                    .fill(Color.duskTextSecondary.opacity(0.16))
                                    .frame(height: 1)
                            }

                            TVSettingsToggleRow(
                                title: library.title,
                                isOn: visibilityBinding(viewModel, for: library)
                            )
                        }
                    }
                }

                if let saveError = viewModel.saveError {
                    Text(saveError)
                        .font(DuskFont.TV.caption)
                        .foregroundStyle(Color.duskTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, TVSettingsMetrics.contentInset)
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.top, 48)
            .padding(.bottom, 88)
        }
        #else
        SettingsList {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                Section {
                    ForEach(group.libraries, id: \.id) { library in
                        Toggle(isOn: visibilityBinding(viewModel, for: library)) {
                            Label(library.title, systemImage: library.libraryType?.systemImage ?? "folder")
                        }
                        .foregroundStyle(Color.duskTextPrimary)
                    }
                } header: {
                    if showsServers {
                        Text(group.serverName)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                } footer: {
                    if index == groups.count - 1 {
                        Text(Self.footerText)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }
                .duskSettingsRowBackground()
            }

            if let saveError = viewModel.saveError {
                Section {
                    Text(saveError)
                        .foregroundStyle(Color.duskTextSecondary)
                }
                .duskSettingsRowBackground()
            }
        }
        .contentMargins(.top, 12, for: .scrollContent)
        .duskSettingsScrollBackgroundHidden()
        #endif
    }

    private func visibilityBinding(
        _ viewModel: LibraryOrderSettingsViewModel,
        for library: PlexLibrary
    ) -> Binding<Bool> {
        Binding(
            get: { !viewModel.isHidden(library) },
            set: { viewModel.setHidden(!$0, for: library) }
        )
    }
}
