import SwiftUI

struct SettingsIOSView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(UserPreferences.self) private var preferences
    @Binding var path: NavigationPath
    let viewModel: SettingsViewModel

    var body: some View {
        SettingsContainer(path: $path, viewModel: viewModel) {
            settingsContent
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
                    Text("None").tag("")
                    ForEach(CommonLanguage.allCases) { language in
                        Text(language.displayName).tag(language.code)
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
            } header: {
                Text("About")
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Button("Sign Out", role: .destructive) {
                    plexService.signOut()
                }
                .duskSuppressTVOSButtonChrome()
            } footer: {
                Text(SettingsSupport.accountFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)
        }
        .duskScrollContentBackgroundHidden()
    }
}
