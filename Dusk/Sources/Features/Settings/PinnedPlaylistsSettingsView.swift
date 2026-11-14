import SwiftUI

/// Settings › Home › Pinned Playlists: the playlists pinned to Home for this
/// profile, in Home order. iOS removes with swipe or Edit (and reorders);
/// tvOS removes by selecting a row.
struct PinnedPlaylistsSettingsView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(\.dismiss) private var dismiss

    static let emptyText = "Choose Pin to Home on a playlist to show it on Home."

    private var pins: [PinnedPlaylistStore.Pin] { plexService.pinnedPlaylistPins }

    var body: some View {
        content
            .duskSettingsPageBackground()
            .duskNavigationTitle("Pinned Playlists")
            .duskNavigationBarTitleDisplayModeInline()
            #if os(iOS)
            .toolbar {
                if !pins.isEmpty {
                    EditButton()
                }
            }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        if pins.isEmpty {
            FeatureEmptyStateView(
                systemImage: "pin",
                title: "No Pinned Playlists",
                message: Self.emptyText
            )
            // Fill the page so the background covers it, not just the text.
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    @ViewBuilder
    private var list: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                TVSettingsSection(title: nil, footer: "Select a playlist to unpin it.") {
                    ForEach(Array(pins.enumerated()), id: \.element.id) { index, pin in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.duskTextSecondary.opacity(0.16))
                                .frame(height: 1)
                        }

                        TVSettingsActionRow(
                            title: pin.title,
                            subtitle: serverName(for: pin),
                            detail: "Unpin"
                        ) {
                            unpin(pin)
                        }
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.top, 48)
            .padding(.bottom, 88)
        }
        #else
        List {
            Section {
                ForEach(pins) { pin in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pin.title)
                            .foregroundStyle(Color.duskTextPrimary)
                        if let server = serverName(for: pin) {
                            Text(server)
                                .font(.caption)
                                .foregroundStyle(Color.duskTextSecondary)
                        }
                    }
                    .swipeActions {
                        Button("Unpin", role: .destructive) {
                            unpin(pin)
                        }
                    }
                    #if os(macOS)
                    .contextMenu {
                        Button("Unpin", role: .destructive) {
                            unpin(pin)
                        }
                    }
                    #endif
                }
                .onDelete { offsets in
                    offsets.map { pins[$0] }.forEach(unpin)
                }
                .onMove { source, destination in
                    plexService.pinnedPlaylists.move(
                        fromOffsets: source,
                        toOffset: destination,
                        profileID: plexService.activeProfileID
                    )
                }
            } footer: {
                Text("Pinned playlists appear on Home in this order.")
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .duskSettingsRowBackground()
        }
        .duskSettingsFormBackgroundHidden()
        #endif
    }

    /// Only worth saying when the pins come from more than one server.
    private func serverName(for pin: PinnedPlaylistStore.Pin) -> String? {
        let servers = Set(pins.compactMap(\.id.serverID))
        guard servers.count > 1, let serverID = pin.id.serverID else { return nil }
        return plexService.pool.displayName(for: serverID)
    }

    private func unpin(_ pin: PinnedPlaylistStore.Pin) {
        withAnimation {
            plexService.setPlaylistPinned(false, id: pin.id, title: pin.title)
        }
        #if os(tvOS)
        // The empty state has nothing to focus; without this, focus falls
        // to the tab bar.
        if pins.isEmpty { dismiss() }
        #endif
    }
}
