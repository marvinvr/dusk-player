import SwiftUI

#if !os(tvOS)
struct SettingsIOSView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(UserPreferences.self) private var preferences
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(OfflinePlaybackSyncManager.self) private var offlinePlaybackSyncManager
    @Environment(\.openURL) private var openURL
    @State private var presentedAccountURL: URL?
    @State private var confirmsDeletingDownloads = false
    @Binding var path: NavigationPath
    let viewModel: SettingsViewModel

    var body: some View {
        SettingsContainer(path: $path, viewModel: viewModel) {
            settingsContent
        }
        .sheet(isPresented: accountSheetPresented) {
            if let presentedAccountURL {
                DuskSafariView(url: presentedAccountURL)
            }
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

    @ViewBuilder
    private var settingsContent: some View {
        @Bindable var preferences = preferences
        let subtitleLanguageBinding = SettingsSupport.subtitleLanguageBinding(preferences)

        List {
            Section {
                Picker("Max Resolution", selection: $preferences.maxResolution) {
                    ForEach(MaxResolution.allCases) { resolution in
                        Text(resolution.displayName).tag(resolution)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)

                Picker("Subtitles", selection: subtitleLanguageBinding) {
                    ForEach(SettingsSupport.subtitleLanguageOptions, id: \.self) { languageCode in
                        Text(SettingsSupport.subtitleDisplayName(for: languageCode)).tag(languageCode)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)

                Toggle("Forced Only", isOn: $preferences.subtitleForcedOnly)
                    .foregroundStyle(Color.duskTextPrimary)
                    .tint(Color.duskAccent)

                Picker("Audio", selection: $preferences.defaultAudioLanguage) {
                    ForEach(CommonLanguage.allCases) { language in
                        Text(language.displayName).tag(language.code)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)
            } header: {
                Text("Playback Defaults")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.playbackDefaultsFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Toggle("Auto-Skip Intros", isOn: $preferences.autoSkipIntro)
                    .foregroundStyle(Color.duskTextPrimary)
                    .tint(Color.duskAccent)

                Toggle("Auto-Skip Credits", isOn: $preferences.autoSkipCredits)
                    .foregroundStyle(Color.duskTextPrimary)
                    .tint(Color.duskAccent)

                Toggle("Continuous Play", isOn: $preferences.continuousPlayEnabled)
                    .foregroundStyle(Color.duskTextPrimary)
                    .tint(Color.duskAccent)

                if preferences.continuousPlayEnabled {
                    Picker("Next Episode Delay", selection: $preferences.continuousPlayCountdown) {
                        ForEach(ContinuousPlayCountdown.allCases) { countdown in
                            Text(countdown.displayName).tag(countdown)
                        }
                    }
                    .foregroundStyle(Color.duskTextPrimary)

                    Picker(
                        "Pause After",
                        selection: $preferences.continuousPlayPassoutProtectionEpisodeLimit
                    ) {
                        ForEach(SettingsSupport.passoutProtectionEpisodeOptions, id: \.self) { episodeLimit in
                            Text(SettingsSupport.passoutProtectionDisplayName(for: episodeLimit))
                                .tag(episodeLimit as Int?)
                        }
                    }
                    .foregroundStyle(Color.duskTextPrimary)
                }

                Toggle("Double-Tap to Seek", isOn: $preferences.playerDoubleTapSeekEnabled)
                    .foregroundStyle(Color.duskTextPrimary)
                    .tint(Color.duskAccent)

                if preferences.playerDoubleTapSeekEnabled {
                    Picker("Back Jump", selection: $preferences.playerDoubleTapBackwardInterval) {
                        ForEach(PlayerSeekInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    .foregroundStyle(Color.duskTextPrimary)

                    Picker("Forward Jump", selection: $preferences.playerDoubleTapForwardInterval) {
                        ForEach(PlayerSeekInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    .foregroundStyle(Color.duskTextPrimary)
                }
            } header: {
                Text("Playback Behavior")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.playbackBehaviorFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Toggle("Force AVPlayer", isOn: $preferences.forceAVPlayer)
                    .foregroundStyle(Color.duskTextPrimary)
                    .tint(Color.duskAccent)

                Toggle("Force VLCKit", isOn: $preferences.forceVLCKit)
                    .foregroundStyle(Color.duskTextPrimary)
                    .tint(Color.duskAccent)

                Toggle("Player Debug Overlay", isOn: $preferences.playerDebugOverlayEnabled)
                    .foregroundStyle(Color.duskTextPrimary)
                    .tint(Color.duskAccent)
            } header: {
                Text("Playback Advanced")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.playbackAdvancedFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Picker("Download Quality", selection: $preferences.downloadMaxResolution) {
                    ForEach(MaxResolution.allCases) { resolution in
                        Text(resolution.displayName).tag(resolution)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)

                Toggle("Wi-Fi Only", isOn: $preferences.downloadsWifiOnly)
                    .foregroundStyle(Color.duskTextPrimary)
                    .tint(Color.duskAccent)

                Picker("Simultaneous Downloads", selection: $preferences.maximumActiveDownloads) {
                    ForEach(DownloadConcurrency.allCases) { concurrency in
                        Text(concurrency.displayName).tag(concurrency)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)

                Picker("Keep Free", selection: $preferences.downloadFreeSpaceReserve) {
                    ForEach(DownloadFreeSpaceReserve.allCases) { reserve in
                        Text(reserve.displayName).tag(reserve)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)

                HStack {
                    Text("Storage Used")
                        .foregroundStyle(Color.duskTextPrimary)
                    Spacer()
                    Text(formattedBytes(downloadManager.storageUsageBytes))
                        .foregroundStyle(Color.duskTextSecondary)
                }

                if let availableStorageBytes = downloadManager.availableStorageBytes {
                    HStack {
                        Text("Available")
                            .foregroundStyle(Color.duskTextPrimary)
                        Spacer()
                        Text(formattedBytes(availableStorageBytes))
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }

                if offlinePlaybackSyncManager.pendingSyncCount > 0 {
                    HStack {
                        Text("Pending Watch Sync")
                            .foregroundStyle(Color.duskTextPrimary)
                        Spacer()
                        Text("\(offlinePlaybackSyncManager.pendingSyncCount)")
                            .foregroundStyle(Color.duskTextSecondary)
                    }

                    Button {
                        Task {
                            await offlinePlaybackSyncManager.syncPendingActions()
                        }
                    } label: {
                        if offlinePlaybackSyncManager.isSyncing {
                            Label("Syncing Watch Progress", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Label("Sync Watch Progress Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(offlinePlaybackSyncManager.isSyncing)
                    .duskSuppressTVOSButtonChrome()
                }

                Button("Delete All Downloads", role: .destructive) {
                    confirmsDeletingDownloads = true
                }
                .disabled(downloadManager.records.isEmpty)
                .duskSuppressTVOSButtonChrome()
            } header: {
                Text("Downloads")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.downloadsFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                if let server = plexService.connectedServer {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(server.name)
                                .foregroundStyle(Color.duskTextPrimary)
                            Text(viewModel.connectionType)
                                .font(.caption)
                                .foregroundStyle(Color.duskTextSecondary)
                        }

                        Spacer()

                        Circle()
                            .fill(Color.duskAccent)
                            .frame(width: 8, height: 8)
                    }
                } else {
                    Text("Not connected")
                        .foregroundStyle(Color.duskTextSecondary)
                }

                Button {
                    Task { await viewModel.loadServers(using: plexService) }
                } label: {
                    HStack {
                        Text("Change Server")
                            .foregroundStyle(Color.duskAccent)
                        Spacer()
                        if viewModel.isLoadingServers {
                            ProgressView()
                                .tint(Color.duskAccent)
                        }
                    }
                }
                .disabled(viewModel.isLoadingServers)
                .duskSuppressTVOSButtonChrome()
            } header: {
                Text("Server")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                if let error = viewModel.serverError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Picker("Appearance", selection: $preferences.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)
            } header: {
                Text("Appearance")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.appearanceFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Button {
                    viewModel.clearImageCache()
                } label: {
                    HStack {
                        Text("Clear Image Cache")
                        Spacer()
                        Text(viewModel.formattedCacheSize)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }
                .foregroundStyle(Color.duskAccent)
                .duskSuppressTVOSButtonChrome()
            } header: {
                Text("Storage")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(viewModel.storageFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                HStack {
                    Text("Version")
                        .foregroundStyle(Color.duskTextPrimary)
                    Spacer()
                    Text(viewModel.appVersion)
                        .foregroundStyle(Color.duskTextSecondary)
                }

                Link(destination: SettingsSupport.aboutMeURL) {
                    SettingsAboutRow(
                        title: "About Me",
                        subtitle: "marvinvr.ch",
                        systemImage: "person.crop.circle",
                        trailingSystemImage: "arrow.up.right"
                    )
                }
                .foregroundStyle(Color.duskTextPrimary)

                Link(destination: SettingsSupport.githubURL) {
                    SettingsAboutRow(
                        title: "GitHub",
                        subtitle: "github.com/marvinvr/dusk-player",
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        trailingSystemImage: "arrow.up.right"
                    )
                }
                .foregroundStyle(Color.duskTextPrimary)

                Button {
                    openURL(SettingsSupport.feedbackURL)
                } label: {
                    SettingsAboutRow(
                        title: "Feedback",
                        subtitle: "info@getdusk.app",
                        systemImage: "envelope.badge",
                        trailingSystemImage: "paperplane.fill"
                    )
                }
                .duskSuppressTVOSButtonChrome()
            } header: {
                Text("About")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.aboutFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Button {
                    presentedAccountURL = SettingsSupport.plexAccountURL
                } label: {
                    SettingsAboutRow(
                        title: "Manage Plex Account",
                        subtitle: "Open Plex account settings",
                        systemImage: "person.circle",
                        trailingSystemImage: "safari"
                    )
                }
                .foregroundStyle(Color.duskAccent)
                .duskSuppressTVOSButtonChrome()

                Button {
                    presentedAccountURL = SettingsSupport.plexAccountURL
                } label: {
                    SettingsAboutRow(
                        title: "Delete Plex Account",
                        subtitle: "Open the Plex deletion controls",
                        systemImage: "trash",
                        trailingSystemImage: "safari",
                        titleColor: .red
                    )
                }
                .duskSuppressTVOSButtonChrome()

                Button("Sign Out", role: .destructive) {
                    plexService.signOut()
                }
                .duskSuppressTVOSButtonChrome()
            } footer: {
                Text(SettingsSupport.accountManagementFooterText + " " + SettingsSupport.accountFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)
        }
        .duskScrollContentBackgroundHidden()
    }

    private var accountSheetPresented: Binding<Bool> {
        Binding(
            get: { presentedAccountURL != nil },
            set: {
                guard !$0 else { return }
                presentedAccountURL = nil
            }
        )
    }

    private func formattedBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private struct SettingsAboutRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let trailingSystemImage: String
    var titleColor: Color = Color.duskTextPrimary

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.duskAccent.opacity(0.14))
                    .frame(width: 34, height: 34)

                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.duskAccent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(titleColor)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.duskTextSecondary)
            }

            Spacer()

            Image(systemName: trailingSystemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.duskTextSecondary)
        }
        .contentShape(Rectangle())
    }
}
#endif
