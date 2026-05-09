import SwiftUI

struct SettingsTVView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(UserPreferences.self) private var preferences
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(OfflinePlaybackSyncManager.self) private var offlinePlaybackSyncManager
    @State private var confirmsDeletingDownloads = false
    @Binding var path: NavigationPath
    let viewModel: SettingsViewModel

    var body: some View {
        SettingsContainer(path: $path, viewModel: viewModel) {
            settingsContent
        }
        .confirmationDialog(
            "Delete all downloads?",
            isPresented: $confirmsDeletingDownloads,
            titleVisibility: .visible
        ) {
            Button("Delete All Downloads", role: .destructive) {
                downloadManager.deleteAllDownloads()
                offlinePlaybackSyncManager.deleteAllLocalState()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded videos, saved metadata, artwork, pause data, and queue entries will be removed from this device.")
        }
    }

    private var settingsContent: some View {
        @Bindable var preferences = preferences
        let subtitleLanguageBinding = SettingsSupport.subtitleLanguageBinding(preferences)

        return ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                TVSettingsSection(title: "Playback Defaults", footer: SettingsSupport.playbackDefaultsFooterText) {
                    TVSettingsMenuRow(
                        title: "Max Resolution",
                        options: MaxResolution.allCases,
                        selection: $preferences.maxResolution,
                        selectedTitle: preferences.maxResolution.displayName
                    ) { $0.displayName }

                    tvRowDivider

                    TVSettingsMenuRow(
                        title: "Subtitles",
                        options: SettingsSupport.subtitleLanguageOptions,
                        selection: subtitleLanguageBinding,
                        selectedTitle: SettingsSupport.subtitleDisplayName(for: subtitleLanguageBinding.wrappedValue)
                    ) { SettingsSupport.subtitleDisplayName(for: $0) }

                    tvRowDivider

                    TVSettingsToggleRow(title: "Forced Only", isOn: $preferences.subtitleForcedOnly)

                    tvRowDivider

                    TVSettingsMenuRow(
                        title: "Audio",
                        options: SettingsSupport.audioLanguageOptions,
                        selection: $preferences.defaultAudioLanguage,
                        selectedTitle: SettingsSupport.languageDisplayName(for: preferences.defaultAudioLanguage)
                    ) { SettingsSupport.languageDisplayName(for: $0) }
                }

                TVSettingsSection(title: "Playback Behavior", footer: SettingsSupport.playbackBehaviorFooterText) {
                    TVSettingsToggleRow(title: "Auto-Skip Intros", isOn: $preferences.autoSkipIntro)

                    tvRowDivider

                    TVSettingsToggleRow(title: "Auto-Skip Credits", isOn: $preferences.autoSkipCredits)

                    tvRowDivider

                    TVSettingsToggleRow(title: "Continuous Play", isOn: $preferences.continuousPlayEnabled)

                    if preferences.continuousPlayEnabled {
                        tvRowDivider

                        TVSettingsMenuRow(
                            title: "Next Episode Delay",
                            options: ContinuousPlayCountdown.allCases,
                            selection: $preferences.continuousPlayCountdown,
                            selectedTitle: preferences.continuousPlayCountdown.displayName
                        ) { $0.displayName }

                        tvRowDivider

                        TVSettingsMenuRow(
                            title: "Pause After",
                            options: SettingsSupport.passoutProtectionEpisodeOptions,
                            selection: $preferences.continuousPlayPassoutProtectionEpisodeLimit,
                            selectedTitle: SettingsSupport.passoutProtectionDisplayName(
                                for: preferences.continuousPlayPassoutProtectionEpisodeLimit
                            )
                        ) {
                            SettingsSupport.passoutProtectionDisplayName(for: $0)
                        }
                    }
                }

                TVSettingsSection(title: "Playback Advanced", footer: SettingsSupport.playbackAdvancedFooterText) {
                    TVSettingsToggleRow(title: "Force AVPlayer", isOn: $preferences.forceAVPlayer)

                    tvRowDivider

                    TVSettingsToggleRow(title: "Force VLCKit", isOn: $preferences.forceVLCKit)

                    tvRowDivider

                    TVSettingsToggleRow(title: "Player Debug Overlay", isOn: $preferences.playerDebugOverlayEnabled)
                }

                TVSettingsSection(title: "Downloads", footer: SettingsSupport.downloadsFooterText) {
                    TVSettingsMenuRow(
                        title: "Download Quality",
                        options: MaxResolution.allCases,
                        selection: $preferences.downloadMaxResolution,
                        selectedTitle: preferences.downloadMaxResolution.displayName
                    ) { $0.displayName }

                    tvRowDivider

                    TVSettingsToggleRow(title: "Wi-Fi Only", isOn: $preferences.downloadsWifiOnly)

                    tvRowDivider

                    TVSettingsMenuRow(
                        title: "Simultaneous Downloads",
                        options: DownloadConcurrency.allCases,
                        selection: $preferences.maximumActiveDownloads,
                        selectedTitle: preferences.maximumActiveDownloads.displayName
                    ) { $0.displayName }

                    tvRowDivider

                    TVSettingsMenuRow(
                        title: "Keep Free",
                        options: DownloadFreeSpaceReserve.allCases,
                        selection: $preferences.downloadFreeSpaceReserve,
                        selectedTitle: preferences.downloadFreeSpaceReserve.displayName
                    ) { $0.displayName }

                    tvRowDivider

                    HStack(spacing: 20) {
                        Text("Storage Used")
                            .font(.headline)
                            .foregroundStyle(Color.duskTextPrimary)

                        Spacer()

                        Text(formattedBytes(downloadManager.storageUsageBytes))
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                    .frame(minHeight: 72)

                    if let availableStorageBytes = downloadManager.availableStorageBytes {
                        tvRowDivider

                        HStack(spacing: 20) {
                            Text("Available")
                                .font(.headline)
                                .foregroundStyle(Color.duskTextPrimary)

                            Spacer()

                            Text(formattedBytes(availableStorageBytes))
                                .foregroundStyle(Color.duskTextSecondary)
                        }
                        .frame(minHeight: 72)
                    }

                    if offlinePlaybackSyncManager.pendingSyncCount > 0 {
                        tvRowDivider

                        HStack(spacing: 20) {
                            Text("Pending Watch Sync")
                                .font(.headline)
                                .foregroundStyle(Color.duskTextPrimary)

                            Spacer()

                            Text("\(offlinePlaybackSyncManager.pendingSyncCount)")
                                .foregroundStyle(Color.duskTextSecondary)
                        }
                        .frame(minHeight: 72)

                        tvRowDivider

                        TVSettingsActionRow(
                            title: offlinePlaybackSyncManager.isSyncing
                                ? "Syncing Watch Progress"
                                : "Sync Watch Progress Now",
                            tint: Color.duskAccent,
                            isLoading: offlinePlaybackSyncManager.isSyncing
                        ) {
                            guard !offlinePlaybackSyncManager.isSyncing else { return }
                            Task {
                                await offlinePlaybackSyncManager.syncPendingActions()
                            }
                        }
                    }

                    tvRowDivider

                    TVSettingsActionRow(
                        title: "Delete All Downloads",
                        tint: downloadManager.records.isEmpty ? Color.duskTextSecondary : .red,
                        role: .destructive
                    ) {
                        guard !downloadManager.records.isEmpty else { return }
                        confirmsDeletingDownloads = true
                    }
                }

                TVSettingsSection(title: "Server", footer: viewModel.serverError, footerColor: .red) {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Current Server")
                                .font(.headline)
                                .foregroundStyle(Color.duskTextPrimary)

                            if let server = plexService.connectedServer {
                                Text(server.name)
                                    .foregroundStyle(Color.duskTextPrimary)
                                Text(viewModel.connectionType)
                                    .font(.caption)
                                    .foregroundStyle(Color.duskTextSecondary)
                            } else {
                                Text("Not connected")
                                    .foregroundStyle(Color.duskTextSecondary)
                            }
                        }

                        Spacer()

                        Circle()
                            .fill(plexService.connectedServer == nil ? Color.duskTextSecondary : Color.duskAccent)
                            .frame(width: 10, height: 10)
                    }
                    .frame(minHeight: 72)

                    tvRowDivider

                    TVSettingsActionRow(
                        title: "Change Server",
                        tint: Color.duskAccent,
                        showsChevron: true,
                        isLoading: viewModel.isLoadingServers
                    ) {
                        Task { await viewModel.loadServers(using: plexService) }
                    }
                    .disabled(viewModel.isLoadingServers)
                }

                TVSettingsSection(title: "Appearance", footer: SettingsSupport.appearanceFooterText) {
                    TVSettingsMenuRow(
                        title: "Appearance",
                        options: AppearanceMode.allCases,
                        selection: $preferences.appearanceMode,
                        selectedTitle: preferences.appearanceMode.displayName
                    ) { $0.displayName }
                }

                TVSettingsSection(title: "Storage", footer: viewModel.storageFooterText) {
                    TVSettingsActionRow(
                        title: "Clear Image Cache",
                        tint: Color.duskAccent,
                        detail: viewModel.formattedCacheSize
                    ) {
                        viewModel.clearImageCache()
                    }
                }

                TVSettingsSection(title: "About", footer: SettingsSupport.aboutFooterText) {
                    HStack(spacing: 20) {
                        Text("Version")
                            .font(.headline)
                            .foregroundStyle(Color.duskTextPrimary)

                        Spacer()

                        Text(viewModel.appVersion)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                    .frame(minHeight: 72)

                    tvRowDivider

                    TVSettingsExternalLinkRow(
                        title: "About Me",
                        subtitle: "marvinvr.ch"
                    )

                    tvRowDivider

                    TVSettingsExternalLinkRow(
                        title: "GitHub",
                        subtitle: "github.com/marvinvr/dusk-player"
                    )

                    tvRowDivider

                    TVSettingsExternalLinkRow(
                        title: "Feedback",
                        subtitle: "info@getdusk.app"
                    )
                }

                TVSettingsSection(title: "Account", footer: SettingsSupport.accountFooterText) {
                    TVSettingsActionRow(
                        title: "Sign Out",
                        tint: .red,
                        role: .destructive
                    ) {
                        plexService.signOut()
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.vertical, 48)
        }
    }

    private var tvRowDivider: some View {
        Rectangle()
            .fill(Color.duskTextSecondary.opacity(0.16))
            .frame(height: 1)
    }

    private func formattedBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
