import SwiftUI

/// Settings › Home › Hidden Rows: a switch per Plex row, grouped by library,
/// built like Hidden Libraries. Home's "Hide Row" turns one off; this is where
/// it comes back.
///
/// The switch is Plex's own "Home" column of Manage Recommendations
/// (`PlexService+HomeRows`), so it is saved on the server and Plex Web and the
/// other Plex apps follow it. Only owned servers are listed: Plex lets nobody
/// else change them.
struct HiddenHomeRowsSettingsView: View {
    @Environment(PlexService.self) private var plexService
    @State private var viewModel: HiddenHomeRowsSettingsViewModel?

    static let footerText = "Turn off a row to hide it from Home. This is saved to your Plex server, so other Plex apps hide it too."
    static let emptyText = "Rows can only be changed on servers you own."

    var body: some View {
        content
            .background(Color.duskBackground.ignoresSafeArea())
            .duskNavigationTitle("Hidden Rows")
            .duskNavigationBarTitleDisplayModeInline()
            .task {
                let model = viewModel ?? HiddenHomeRowsSettingsViewModel(plexService: plexService)
                viewModel = model
                await model.load()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let viewModel {
            if viewModel.isLoading, viewModel.groups.isEmpty {
                FeatureLoadingView()
            } else if let error = viewModel.error, viewModel.groups.isEmpty {
                FeatureErrorView(message: error) {
                    Task { await viewModel.load() }
                }
            } else if viewModel.groups.isEmpty {
                FeatureEmptyStateView(
                    systemImage: "rectangle.stack",
                    title: "No Rows",
                    message: Self.emptyText
                )
            } else {
                editor(viewModel)
            }
        } else {
            FeatureLoadingView()
        }
    }

    @ViewBuilder
    private func editor(_ viewModel: HiddenHomeRowsSettingsViewModel) -> some View {
        let groups = viewModel.groups

        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    TVSettingsSection(
                        title: group.title,
                        footer: index == groups.count - 1 ? Self.footerText : nil
                    ) {
                        ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 {
                                Rectangle()
                                    .fill(Color.duskTextSecondary.opacity(0.16))
                                    .frame(height: 1)
                            }

                            TVSettingsToggleRow(
                                title: row.title,
                                isOn: onHomeBinding(viewModel, row: row, in: group)
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
                    ForEach(group.rows) { row in
                        Toggle(row.title, isOn: onHomeBinding(viewModel, row: row, in: group))
                            .foregroundStyle(Color.duskTextPrimary)
                    }
                } header: {
                    Text(group.title)
                        .foregroundStyle(Color.duskTextSecondary)
                } footer: {
                    if index == groups.count - 1 {
                        Text(Self.footerText)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }
                .listRowBackground(Color.duskSurface)
            }

            if let saveError = viewModel.saveError {
                Section {
                    Text(saveError)
                        .foregroundStyle(Color.duskTextSecondary)
                }
                .listRowBackground(Color.duskSurface)
            }
        }
        .contentMargins(.top, 12, for: .scrollContent)
        .duskScrollContentBackgroundHidden()
        #endif
    }

    private func onHomeBinding(
        _ viewModel: HiddenHomeRowsSettingsViewModel,
        row: PlexManagedHub,
        in group: HiddenHomeRowsSettingsViewModel.LibraryGroup
    ) -> Binding<Bool> {
        Binding(
            get: { viewModel.isOnHome(row, in: group) },
            set: { onHome in Task { await viewModel.setOnHome(onHome, row: row, in: group) } }
        )
    }
}

/// The Manage Recommendations lists of every library Dusk shows on the
/// servers the account owns.
@MainActor
@Observable
final class HiddenHomeRowsSettingsViewModel {
    struct LibraryGroup: Identifiable {
        let library: PlexLibrary
        let title: String
        var rows: [PlexManagedHub]

        var id: String { library.id }
    }

    static let loadErrorMessage = "Couldn't load your Home rows from Plex."
    static let saveErrorMessage = "Couldn't save the change to your Plex server."

    private(set) var groups: [LibraryGroup] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var saveError: String?

    private let plexService: PlexService

    init(plexService: PlexService) {
        self.plexService = plexService
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            _ = try await plexService.ensureLibraryOrderLoaded()
        } catch {
            self.error = Self.loadErrorMessage
            return
        }

        let libraries = plexService.libraryOrder.visibleSections.filter { library in
            guard let serverID = library.serverID,
                  plexService.canManageHomeRows(serverID: serverID) else { return false }
            return [.movie, .show, .video].contains(library.libraryType)
        }
        let labels = ServerLabeling.serverLabels(for: libraries, pool: plexService.pool)
        let service = plexService

        var loaded: [String: [PlexManagedHub]] = [:]
        var failed = false
        await withTaskGroup(of: (String, [PlexManagedHub]?).self) { group in
            for library in libraries {
                group.addTask {
                    let rows = try? await service.getManagedHubs(
                        sectionId: library.key,
                        serverID: library.serverID ?? ""
                    )
                    return (library.id, rows)
                }
            }
            for await (id, rows) in group {
                if let rows { loaded[id] = rows } else { failed = true }
            }
        }

        groups = libraries.compactMap { library in
            guard let rows = loaded[library.id], !rows.isEmpty else { return nil }
            return LibraryGroup(
                library: library,
                title: ServerLabeling.displayTitle(for: library, labels: labels),
                rows: rows
            )
        }
        if failed, groups.isEmpty {
            error = Self.loadErrorMessage
        }
    }

    func isOnHome(_ row: PlexManagedHub, in group: LibraryGroup) -> Bool {
        current(row, in: group)?.promotedToOwnHome ?? row.promotedToOwnHome
    }

    /// Flips the switch at once and puts it back if the server says no.
    func setOnHome(_ onHome: Bool, row: PlexManagedHub, in group: LibraryGroup) async {
        guard let previous = current(row, in: group), previous.promotedToOwnHome != onHome,
              let serverID = group.library.serverID else { return }
        saveError = nil
        replace(previous.withOwnHome(onHome), in: group)
        do {
            try await plexService.setManagedHub(
                previous.withOwnHome(onHome),
                sectionId: group.library.key,
                serverID: serverID
            )
        } catch {
            replace(previous, in: group)
            saveError = Self.saveErrorMessage
        }
    }

    private func current(_ row: PlexManagedHub, in group: LibraryGroup) -> PlexManagedHub? {
        groups.first { $0.id == group.id }?.rows.first { $0.id == row.id }
    }

    private func replace(_ row: PlexManagedHub, in group: LibraryGroup) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == group.id }),
              let rowIndex = groups[groupIndex].rows.firstIndex(where: { $0.id == row.id }) else { return }
        groups[groupIndex].rows[rowIndex] = row
    }
}
