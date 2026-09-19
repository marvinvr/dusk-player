import SwiftUI

/// Orders the account's Plex servers and turns individual ones off.
///
/// Dusk connects to every enabled server at once and merges what they return,
/// so this screen answers two questions: which server plays a title that exists
/// on several (the highest one), and which servers Dusk should ignore
/// completely. Edits are written straight to `ServerPriorityStore`.
///
/// The editors differ per platform because the input models do. iOS/iPadOS use
/// native list editing (`EditButton` + `onMove`). tvOS uses per-row position
/// menus — the same pattern as Library Order. **Do not replace the tvOS menus
/// with a focus-driven pick-up**: see the warning at the top of
/// `LibraryOrderSettingsView`.
struct ServerPrioritySettingsView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(ServerConnectionCoordinator.self) private var connections
    @State private var viewModel: ServerPrioritySettingsViewModel?

    var body: some View {
        content
            .background(Color.duskBackground.ignoresSafeArea())
            .duskNavigationTitle("Server Priority")
            .duskNavigationBarTitleDisplayModeInline()
            .task {
                let model = viewModel ?? ServerPrioritySettingsViewModel(
                    plexService: plexService,
                    connections: connections
                )
                viewModel = model
                await model.load()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let viewModel {
            if viewModel.rows.isEmpty {
                if viewModel.isLoading {
                    FeatureLoadingView()
                } else {
                    FeatureErrorView(
                        message: viewModel.accountError ?? Self.noServersMessage,
                        retryTitle: "Check Again"
                    ) {
                        Task { await viewModel.refresh() }
                    }
                }
            } else {
                editor(viewModel)
            }
        } else {
            FeatureLoadingView()
        }
    }

    @ViewBuilder
    private func editor(_ viewModel: ServerPrioritySettingsViewModel) -> some View {
        #if os(tvOS)
        tvEditor(viewModel)
        #else
        iosEditor(viewModel)
        #endif
    }

    // MARK: - iOS

    #if !os(tvOS)
    private func iosEditor(_ viewModel: ServerPrioritySettingsViewModel) -> some View {
        List {
            if !viewModel.hasEnabledServer {
                Section {
                    ServerPriorityNotice(message: Self.nothingEnabledMessage)
                }
                .listRowBackground(Color.duskSurface)
            }

            Section {
                ForEach(viewModel.rows) { row in
                    ServerPriorityRow(row: row, viewModel: viewModel)
                }
                .onMove { offsets, destination in
                    viewModel.move(fromOffsets: offsets, toOffset: destination)
                }
            } header: {
                Text(viewModel.isSingleServer ? "Server" : "Priority")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(Self.footerText(isSingleServer: viewModel.isSingleServer))
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    HStack {
                        Text("Check Again")
                            .foregroundStyle(Color.duskAccent)

                        Spacer()

                        if viewModel.isRefreshing {
                            ProgressView()
                                .tint(Color.duskAccent)
                        }
                    }
                }
                .disabled(viewModel.isRefreshing)
                .duskSuppressTVOSButtonChrome()
            } footer: {
                if let accountError = viewModel.accountError {
                    Text(accountError)
                        .foregroundStyle(Color.duskTextSecondary)
                } else {
                    Text(Self.refreshFooterText)
                        .foregroundStyle(Color.duskTextSecondary)
                }
            }
            .listRowBackground(Color.duskSurface)
        }
        .contentMargins(.top, 12, for: .scrollContent)
        .duskScrollContentBackgroundHidden()
        .toolbar {
            if !viewModel.isSingleServer {
                EditButton()
            }
        }
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private func tvEditor(_ viewModel: ServerPrioritySettingsViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                if !viewModel.hasEnabledServer {
                    Text(Self.nothingEnabledMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.duskTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, TVSettingsMetrics.contentInset)
                }

                ForEach(viewModel.rows) { row in
                    TVSettingsSection(title: row.name) {
                        HStack(spacing: 20) {
                            Text(row.ownership)
                                .font(.headline)
                                .foregroundStyle(Color.duskTextPrimary)

                            Spacer(minLength: 24)

                            Text(row.status)
                                .foregroundStyle(
                                    row.isConnected ? Color.duskAccent : Color.duskTextSecondary
                                )
                        }
                        .frame(minHeight: 72)

                        if !viewModel.isSingleServer {
                            tvRowDivider

                            TVSettingsMenuRow(
                                title: "Position",
                                options: Array(viewModel.rows.indices),
                                selection: positionBinding(viewModel, for: row.id),
                                selectedTitle: ServerPriorityPositionName.label(
                                    for: viewModel.position(of: row.id)
                                )
                            ) {
                                ServerPriorityPositionName.label(for: $0)
                            }
                        }

                        tvRowDivider

                        TVSettingsToggleRow(
                            title: "Use This Server",
                            isOn: enabledBinding(viewModel, for: row.id, isEnabled: row.isEnabled)
                        )
                    }
                }

                TVSettingsSection(
                    title: "All Servers",
                    footer: Self.footerText(isSingleServer: viewModel.isSingleServer)
                ) {
                    TVSettingsActionRow(
                        title: "Check Again",
                        tint: Color.duskAccent,
                        isLoading: viewModel.isRefreshing
                    ) {
                        Task { await viewModel.refresh() }
                    }

                    if let accountError = viewModel.accountError {
                        tvRowDivider

                        Text(accountError)
                            .font(.footnote)
                            .foregroundStyle(Color.duskTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 16)
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.top, 48)
            .padding(.bottom, 88)
        }
    }

    private var tvRowDivider: some View {
        Rectangle()
            .fill(Color.duskTextSecondary.opacity(0.16))
            .frame(height: 1)
    }

    private func positionBinding(
        _ viewModel: ServerPrioritySettingsViewModel,
        for serverID: String
    ) -> Binding<Int> {
        Binding(
            get: { viewModel.position(of: serverID) },
            set: { viewModel.move(serverID, to: $0) }
        )
    }

    private func enabledBinding(
        _ viewModel: ServerPrioritySettingsViewModel,
        for serverID: String,
        isEnabled: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { viewModel.setEnabled($0, for: serverID) }
        )
    }
    #endif

    // MARK: - Copy

    private static let noServersMessage = "No Plex servers found on your account."
    private static let nothingEnabledMessage = "Every server is turned off, so Dusk has nothing to show. Downloads still play. Turn a server back on to bring your libraries back."
    private static let refreshFooterText = "Looks for servers that have come online or been shared with you since Dusk last checked."

    private static func footerText(isSingleServer: Bool) -> String {
        guard !isSingleServer else {
            return "Dusk uses this server for everything. Turning it off leaves Dusk with nothing to show until you turn it back on."
        }
        return "Dusk uses every server that is on and merges what they hold. When the same title is on more than one, the server highest in this list plays it. A server that is off is ignored completely — no libraries, no Continue Watching, no search results."
    }
}

// MARK: - Shared pieces

/// The accent-tinted server glyph, matching the icon containers used by the
/// other settings rows.
private struct ServerPriorityIcon: View {
    let size: CGFloat
    let cornerRadius: CGFloat
    let iconFont: Font

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.duskAccent.opacity(0.14))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "server.rack")
                    .font(iconFont)
                    .foregroundStyle(Color.duskAccent)
            }
    }
}

private struct ServerPriorityNotice: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.duskTextSecondary)

            Text(message)
                .foregroundStyle(Color.duskTextSecondary)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.vertical, 4)
    }
}

// MARK: - iOS row

#if !os(tvOS)
private struct ServerPriorityRow: View {
    let row: ServerPrioritySettingsViewModel.Row
    let viewModel: ServerPrioritySettingsViewModel

    var body: some View {
        HStack(spacing: 14) {
            ServerPriorityIcon(size: 36, cornerRadius: 12, iconFont: .subheadline.weight(.semibold))
                .opacity(row.isEnabled ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(row.isEnabled ? Color.duskTextPrimary : Color.duskTextSecondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(row.ownership)
                        .foregroundStyle(Color.duskTextSecondary)
                        .lineLimit(1)

                    Text("·")
                        .foregroundStyle(Color.duskTextSecondary)

                    Text(row.status)
                        .foregroundStyle(row.isConnected ? Color.duskAccent : Color.duskTextSecondary)
                }
                .font(.caption)
            }

            Spacer(minLength: 12)

            Toggle(
                "Use \(row.name)",
                isOn: Binding(
                    get: { row.isEnabled },
                    set: { viewModel.setEnabled($0, for: row.id) }
                )
            )
            .labelsHidden()
            .tint(Color.duskAccent)
        }
        .padding(.vertical, 4)
    }
}
#endif

// MARK: - tvOS position labels

#if os(tvOS)
/// Ordinal labels for the tvOS position menus. Formatted rather than hardcoded
/// so the list is not capped at a handful of names. `NumberFormatter` is not
/// `Sendable`, so the cached instance is pinned to the main actor.
@MainActor
private enum ServerPriorityPositionName {
    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter
    }()

    static func label(for index: Int) -> String {
        formatter.string(from: NSNumber(value: index + 1)) ?? "\(index + 1)"
    }
}
#endif
