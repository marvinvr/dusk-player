import SwiftUI

struct SettingsTVView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(UserPreferences.self) private var preferences
    @Binding var path: NavigationPath
    let viewModel: SettingsViewModel

    var body: some View {
        SettingsContainer(path: $path, viewModel: viewModel) {
            settingsContent
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
}
