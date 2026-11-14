import SwiftUI

/// Settings › Audio & Subtitles: the languages automatic track selection
/// looks for and when subtitles turn on (`SubtitleSelectionPolicy`).
struct AudioSubtitleSettingsView: View {
    @Environment(UserPreferences.self) private var preferences

    var body: some View {
        Group {
            #if os(tvOS)
            tvContent
            #else
            iosContent
            #endif
        }
        .duskSettingsPageBackground()
        .duskNavigationTitle("Audio & Subtitles")
    }

    #if !os(tvOS)
    private var iosContent: some View {
        @Bindable var preferences = preferences

        return SettingsList {
            Section {
                Picker("Language", selection: $preferences.defaultAudioLanguage) {
                    ForEach(SettingsSupport.audioLanguageOptions(including: preferences.defaultAudioLanguage), id: \.self) { code in
                        Text(SettingsSupport.audioLanguageDisplayName(for: code)).tag(code)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)
            } header: {
                Text("Audio")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.audioLanguageFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .duskSettingsRowBackground()

            Section {
                Picker("Show Subtitles", selection: $preferences.subtitleMode) {
                    ForEach(SubtitleMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)

                Picker("Language", selection: $preferences.defaultSubtitleLanguage) {
                    ForEach(SettingsSupport.subtitleLanguageOptions(including: preferences.defaultSubtitleLanguage), id: \.self) { code in
                        Text(SettingsSupport.languageDisplayName(for: code)).tag(code)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)

                Picker("Style", selection: $preferences.subtitleStyle) {
                    ForEach(SubtitleStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)

                Picker("Size", selection: $preferences.subtitleFontSize) {
                    ForEach(SubtitleFontSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)
            } header: {
                Text("Subtitles")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.subtitlesFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .duskSettingsRowBackground()

            Section {
                Toggle("Forced Subtitles", isOn: $preferences.forcedSubtitlesEnabled)
                    .foregroundStyle(Color.duskTextPrimary)
            } header: {
                Text("Advanced")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.subtitlesAdvancedFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .duskSettingsRowBackground()
        }
        .contentMargins(.top, 12, for: .scrollContent)
        .duskSettingsScrollBackgroundHidden()
    }
    #endif

    #if os(tvOS)
    private var tvContent: some View {
        @Bindable var preferences = preferences

        return ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                TVSettingsSection(title: "Audio", footer: SettingsSupport.audioLanguageFooterText) {
                    TVSettingsMenuRow(
                        title: "Language",
                        options: SettingsSupport.audioLanguageOptions(including: preferences.defaultAudioLanguage),
                        selection: $preferences.defaultAudioLanguage,
                        selectedTitle: SettingsSupport.audioLanguageDisplayName(for: preferences.defaultAudioLanguage)
                    ) { SettingsSupport.audioLanguageDisplayName(for: $0) }
                }

                TVSettingsSection(title: "Subtitles", footer: SettingsSupport.subtitlesFooterText) {
                    TVSettingsMenuRow(
                        title: "Show Subtitles",
                        options: SubtitleMode.allCases,
                        selection: $preferences.subtitleMode,
                        selectedTitle: preferences.subtitleMode.displayName
                    ) { $0.displayName }

                    tvRowDivider

                    TVSettingsMenuRow(
                        title: "Language",
                        options: SettingsSupport.subtitleLanguageOptions(including: preferences.defaultSubtitleLanguage),
                        selection: $preferences.defaultSubtitleLanguage,
                        selectedTitle: SettingsSupport.languageDisplayName(for: preferences.defaultSubtitleLanguage)
                    ) { SettingsSupport.languageDisplayName(for: $0) }

                    tvRowDivider

                    TVSettingsMenuRow(
                        title: "Style",
                        options: SubtitleStyle.allCases,
                        selection: $preferences.subtitleStyle,
                        selectedTitle: preferences.subtitleStyle.displayName
                    ) { $0.displayName }

                    tvRowDivider

                    TVSettingsMenuRow(
                        title: "Size",
                        options: SubtitleFontSize.allCases,
                        selection: $preferences.subtitleFontSize,
                        selectedTitle: preferences.subtitleFontSize.displayName
                    ) { $0.displayName }
                }

                TVSettingsSection(title: "Advanced", footer: SettingsSupport.subtitlesAdvancedFooterText) {
                    TVSettingsToggleRow(title: "Forced Subtitles", isOn: $preferences.forcedSubtitlesEnabled)
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
    #endif
}
