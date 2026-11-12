import SwiftUI
import UIKit

#if !os(tvOS)
struct SettingsIOSView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(SeerrService.self) private var seerrService
    @Environment(TraktService.self) private var traktService
    @Environment(IPTVService.self) private var iptvService
    @Environment(UserPreferences.self) private var preferences
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(OfflinePlaybackSyncManager.self) private var offlinePlaybackSyncManager
    @Environment(SupporterStore.self) private var supporterStore
    @Environment(\.openURL) private var openURL
    @State private var presentedAccountURL: URL?
    @State private var confirmsDeletingDownloads = false
    @State private var showsSupporterSheet = false
    @State private var showsIconPicker = false
    let viewModel: SettingsViewModel

    var body: some View {
        SettingsContainer(viewModel: viewModel) {
            settingsContent
        }
        .sheet(isPresented: accountSheetPresented) {
            if let presentedAccountURL {
                DuskSafariView(url: presentedAccountURL)
            }
        }
        .sheet(isPresented: $showsSupporterSheet) {
            SupporterView(context: .settings)
        }
        .sheet(isPresented: $showsIconPicker) {
            AppIconPickerView()
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

        List {
            Section {
                Button {
                    showsSupporterSheet = true
                } label: {
                    SettingsAboutRow(
                        title: supporterStore.isSupporter ? "You're a Supporter" : "Support Dusk",
                        subtitle: supporterStore.hasActiveSubscription
                            ? "Dusk Supporter — thank you for making Dusk possible ❤️"
                            : supporterStore.isSupporter
                            ? "Thank you for making Dusk possible ❤️"
                            : "Free, no ads, no tracking — chip in if you like it",
                        systemImage: "heart.fill",
                        trailingSystemImage: "chevron.right"
                    )
                }
                .duskSuppressTVOSButtonChrome()
            }
            .listRowBackground(Color.duskSurface)

            if plexService.homeUsers.count > 1, let activeUser = plexService.activeHomeUser {
                Section {
                    HStack(spacing: 16) {
                        PlexHomeUserAvatar(user: activeUser, size: 48)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Current User")
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .tracking(0.4)
                                .foregroundStyle(Color.duskTextSecondary)

                            Text(activeUser.displayName)
                                .font(.body.weight(.medium))
                                .foregroundStyle(Color.duskTextPrimary)
                                .lineLimit(1)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 6)

                    Button {
                        viewModel.showHomeUserPicker = true
                    } label: {
                        HStack {
                            Text("Switch User")
                                .foregroundStyle(Color.duskTextPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.duskTextSecondary)
                        }
                    }
                    .duskSuppressTVOSButtonChrome()

                    Toggle("Automatically Sign In", isOn: automaticHomeSignInBinding)
                        .foregroundStyle(Color.duskTextPrimary)
                } header: {
                    Text("Plex Home")
                        .foregroundStyle(Color.duskTextSecondary)
                } footer: {
                    Text("When off, Dusk asks who’s watching whenever it starts.")
                        .foregroundStyle(Color.duskTextSecondary)
                }
                .listRowBackground(Color.duskSurface)
            }

            Section {
                NavigationLink {
                    SeerrSettingsView()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Seerr")
                            .foregroundStyle(Color.duskTextPrimary)
                        Text(seerrService.connectionSubtitle)
                            .font(.caption)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }
                if traktService.isAvailable {
                    NavigationLink {
                        TraktSettingsView()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Trakt")
                                .foregroundStyle(Color.duskTextPrimary)
                            Text(traktService.connectionSubtitle)
                                .font(.caption)
                                .foregroundStyle(Color.duskTextSecondary)
                        }
                    }
                }
            } header: {
                Text("Integrations")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.integrationsFooterText(showsTrakt: traktService.isAvailable))
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                NavigationLink {
                    IPTVSourcesSettingsView()
                } label: {
                    HStack {
                        Text("IPTV Sources")
                            .foregroundStyle(Color.duskTextPrimary)
                        Spacer()
                        Text(SettingsSupport.iptvSourcesSummary(iptvService.sources.count))
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }
            } header: {
                Text("Live TV")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.liveTVFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                NavigationLink {
                    LibraryTabSettingsView()
                } label: {
                    HStack {
                        Text("Navigation Tabs")
                            .foregroundStyle(Color.duskTextPrimary)

                        Spacer()

                        Text(SettingsSupport.libraryTabsSummary(preferences))
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }

                NavigationLink {
                    HiddenLibrariesSettingsView()
                } label: {
                    HStack {
                        Text("Hidden Libraries")
                            .foregroundStyle(Color.duskTextPrimary)

                        Spacer()

                        Text(SettingsSupport.hiddenLibrariesSummary(plexService))
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }

                NavigationLink {
                    ServerPrioritySettingsView()
                } label: {
                    HStack {
                        Text("Server Priority")
                            .foregroundStyle(Color.duskTextPrimary)

                        Spacer()

                        Text(SettingsSupport.serverPrioritySummary(plexService))
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }
            } header: {
                Text("Libraries")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.librariesFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                NavigationLink {
                    HiddenHomeRowsSettingsView()
                } label: {
                    Text("Hidden Rows")
                        .foregroundStyle(Color.duskTextPrimary)
                }

                NavigationLink {
                    PinnedPlaylistsSettingsView()
                } label: {
                    HStack {
                        Text("Pinned Playlists")
                            .foregroundStyle(Color.duskTextPrimary)
                        Spacer()
                        Text(SettingsSupport.pinnedPlaylistsSummary(plexService.pinnedPlaylistPins.count))
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }

                Toggle("Personalized shelves", isOn: $preferences.personalizedShelvesEnabled)
                    .foregroundStyle(Color.duskTextPrimary)
                Toggle("Show Live TV", isOn: $preferences.showsLiveTVOnHome)
                    .foregroundStyle(Color.duskTextPrimary)
            } header: {
                Text("Home")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.homeFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Toggle("Compact Continue Watching", isOn: $preferences.compactHomeContinueWatching)
                    .foregroundStyle(Color.duskTextPrimary)
            } header: {
                Text("Home Advanced")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.homeAdvancedFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Picker("Max Resolution", selection: $preferences.maxResolution) {
                    ForEach(MaxResolution.allCases) { resolution in
                        Text(resolution.displayName).tag(resolution)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)

                Picker("Preferred Version", selection: $preferences.preferredVersion) {
                    ForEach(PreferredMediaVersion.allCases) { version in
                        Text(version.displayName).tag(version)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)

                NavigationLink {
                    AudioSubtitleSettingsView()
                } label: {
                    HStack {
                        Text("Audio & Subtitles")
                            .foregroundStyle(Color.duskTextPrimary)
                            .layoutPriority(1)

                        Spacer()

                        Text(SettingsSupport.audioSubtitlesSummary(preferences))
                            .foregroundStyle(Color.duskTextSecondary)
                            .lineLimit(1)
                    }
                }

                Picker("AI Upscaling", selection: $preferences.videoEnhancementMode) {
                    ForEach(VideoEnhancementMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
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
                if UIDevice.current.userInterfaceIdiom == .phone {
                    Toggle("Always Play in Landscape", isOn: $preferences.alwaysPlayInLandscape)
                        .foregroundStyle(Color.duskTextPrimary)
                }

                Picker("Auto-Skip Intros", selection: $preferences.autoSkipIntroMode) {
                    ForEach(AutoSkipIntroMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)

                Toggle("Auto-Skip Credits", isOn: $preferences.autoSkipCredits)
                    .foregroundStyle(Color.duskTextPrimary)

                Toggle("Continuous Play", isOn: $preferences.continuousPlayEnabled)
                    .foregroundStyle(Color.duskTextPrimary)

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

                Toggle("Episode Buttons", isOn: $preferences.playerEpisodeButtonsEnabled)
                    .foregroundStyle(Color.duskTextPrimary)

                Toggle("Double-Tap to Seek", isOn: $preferences.playerDoubleTapSeekEnabled)
                    .foregroundStyle(Color.duskTextPrimary)

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
                Picker("Preferred Version", selection: $preferences.downloadMaxResolution) {
                    ForEach(MaxResolution.allCases) { resolution in
                        Text(resolution.displayName).tag(resolution)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)

                Toggle("Wi-Fi Only", isOn: $preferences.downloadsWifiOnly)
                    .foregroundStyle(Color.duskTextPrimary)

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
                            await offlinePlaybackSyncManager.syncPendingActions(force: true)
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
                Picker("Appearance", selection: $preferences.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)

                Toggle("Blur Unwatched Episodes", isOn: $preferences.blursUnwatchedEpisodes)
                    .foregroundStyle(Color.duskTextPrimary)

                Button {
                    showsIconPicker = true
                } label: {
                    HStack {
                        Text("App Icon")
                            .foregroundStyle(Color.duskTextPrimary)

                        Spacer()

                        Text(DuskAppIcon.current.displayName)
                            .foregroundStyle(Color.duskTextSecondary)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }
                .duskSuppressTVOSButtonChrome()
            } header: {
                Text("Appearance")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.appearanceFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Toggle("Advanced Playback Controls", isOn: $preferences.playerAdvancedControlsEnabled)
                    .foregroundStyle(Color.duskTextPrimary)

                Toggle("Dolby Atmos & Spatial Audio", isOn: $preferences.spatialAudioRemuxEnabled)
                    .foregroundStyle(Color.duskTextPrimary)

                Toggle("HDR & Dolby Vision", isOn: $preferences.hdrVideoRemuxEnabled)
                    .foregroundStyle(Color.duskTextPrimary)

                Toggle("Dolby Vision 7 → 8.1", isOn: $preferences.dolbyVision7ConversionEnabled)
                    .foregroundStyle(Color.duskTextPrimary)
                    .disabled(!preferences.hdrVideoRemuxEnabled)

                Toggle("Force AVPlayer", isOn: $preferences.forceAVPlayer)
                    .foregroundStyle(Color.duskTextPrimary)

                Toggle("Force VLCKit", isOn: $preferences.forceVLCKit)
                    .foregroundStyle(Color.duskTextPrimary)
            } header: {
                Text("Playback Advanced")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.playbackAdvancedFooterText)
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
                .foregroundStyle(Color.duskTextPrimary)
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
                Toggle("Help Improve Dusk", isOn: $preferences.analyticsEnabled)
                    .foregroundStyle(Color.duskTextPrimary)

                Link(destination: SettingsSupport.privacyPolicyURL) {
                    SettingsAboutRow(
                        title: "Privacy Policy",
                        subtitle: "getdusk.app/privacy",
                        systemImage: "hand.raised",
                        trailingSystemImage: "arrow.up.right"
                    )
                }
                .foregroundStyle(Color.duskTextPrimary)
            } header: {
                Text("Privacy")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.privacyFooterText)
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

                Link(destination: SettingsSupport.redditURL) {
                    SettingsAboutRow(
                        title: "Community",
                        subtitle: "reddit.com/r/DuskPlayer",
                        systemImage: "bubble.left.and.bubble.right",
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
                .foregroundStyle(Color.duskTextPrimary)
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
        .contentMargins(.top, 12, for: .scrollContent)
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

    private var automaticHomeSignInBinding: Binding<Bool> {
        Binding(
            get: { plexService.automaticHomeSignIn },
            set: { plexService.automaticHomeSignIn = $0 }
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
                    .fill(Color.duskTextSecondary.opacity(0.14))
                    .frame(width: 34, height: 34)

                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.duskTextPrimary)
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
