import Foundation

/// When subtitles turn on without the viewer picking a track.
enum SubtitleMode: String, CaseIterable, Identifiable, Sendable {
    /// Only forced subtitles (foreign dialogue, signs), if those are allowed.
    case off
    /// Full subtitles when the audio is not in the subtitle language, forced
    /// subtitles otherwise.
    case auto
    /// Full subtitles in the subtitle language whenever the title has them.
    case always

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .auto: "Auto"
        case .always: "Always"
        }
    }

}

/// The global automatic subtitle rule. A per-show remembered choice
/// (`ShowTrackPreferences`) is resolved before this and always wins; this only
/// decides what an untouched title starts with. Shared by the startup pick on
/// Plex part metadata and the runtime pick on engine tracks, so AVPlayer,
/// VLCKit, remux and AirPlay all agree.
struct SubtitleSelectionPolicy: Equatable, Sendable {
    var mode: SubtitleMode
    /// Normalized code of the subtitle language, or nil when unknown.
    var subtitleLanguage: String?
    /// Normalized code of the preferred audio language; nil means each title
    /// keeps its original audio.
    var audioLanguage: String?
    var forcedSubtitlesEnabled: Bool

    @MainActor
    init(preferences: UserPreferences) {
        self.init(
            mode: preferences.subtitleMode,
            subtitleLanguage: preferences.defaultSubtitleLanguage,
            audioLanguage: preferences.defaultAudioLanguage,
            forcedSubtitlesEnabled: preferences.forcedSubtitlesEnabled
        )
    }

    init(mode: SubtitleMode, subtitleLanguage: String?, audioLanguage: String?, forcedSubtitlesEnabled: Bool) {
        self.mode = mode
        self.subtitleLanguage = PlayerViewModel.normalizedLanguageCode(subtitleLanguage)
        self.audioLanguage = PlayerViewModel.normalizedLanguageCode(audioLanguage)
        self.forcedSubtitlesEnabled = forcedSubtitlesEnabled
    }

    /// True when the playing audio is in the subtitle language, Plex's own
    /// rule for "shown with foreign audio". The audio preference deliberately
    /// does not count: preferring Japanese audio with English subtitles means
    /// wanting the subtitles. Audio with no (or an undetermined) language tag
    /// counts as understood, so Auto never switches full subtitles on for a guess.
    func understands(audioLanguage rawAudioLanguage: String?) -> Bool {
        guard let playing = PlayerViewModel.normalizedLanguageCode(rawAudioLanguage),
              !Self.undeterminedLanguageCodes.contains(playing) else { return true }
        return playing == subtitleLanguage
    }

    private static let undeterminedLanguageCodes: Set<String> = ["und", "zxx", "mul", "mis"]

    /// Picks the automatic subtitle among `tracks` for audio in
    /// `audioLanguage`. Full subtitles prefer a non-forced, non-SDH track in
    /// the subtitle language; forced subtitles look in the subtitle language,
    /// then in the audio's own language, then at untagged forced tracks.
    ///
    /// `serverSelectedStreamID` is the Plex stream the server marks
    /// `selected` (set by another client or a bulk tool such as PASTA). It
    /// only breaks ties: the mode and language rules above still decide
    /// whether and in which language subtitles appear, and a selected forced
    /// track never stands in for wanted full subtitles.
    func preferredTrack(
        in tracks: [SubtitleTrack],
        audioLanguage rawAudioLanguage: String?,
        serverSelectedStreamID: String? = nil
    ) -> SubtitleTrack? {
        let serverSelected = serverSelectedStreamID.flatMap { id in
            tracks.first { $0.plexStreamID == id }
        }
        let wantsFullSubtitles = switch mode {
        case .off: false
        case .auto: !understands(audioLanguage: rawAudioLanguage)
        case .always: true
        }

        if wantsFullSubtitles, let subtitleLanguage,
           let track = Self.ranked(tracks, language: subtitleLanguage, preferForced: false, serverSelected: serverSelected) {
            return track
        }

        guard forcedSubtitlesEnabled else { return nil }
        let forcedTracks = tracks.filter(Self.isForced)
        guard !forcedTracks.isEmpty else { return nil }
        let languages = [subtitleLanguage, PlayerViewModel.normalizedLanguageCode(rawAudioLanguage)].compactMap { $0 }
        for language in languages {
            if let track = Self.ranked(forcedTracks, language: language, preferForced: true, serverSelected: serverSelected) {
                return track
            }
        }
        // An untagged forced track almost always belongs to the file's own
        // audio, so it still counts; tagged ones in other languages never do.
        return forcedTracks
            .filter { PlayerViewModel.normalizedLanguageCode($0.languageCode) == nil }
            .sorted(by: PlayerViewModel.subtitleOrdering(preferForcedTracks: true))
            .first
    }

    private static func ranked(
        _ tracks: [SubtitleTrack],
        language: String,
        preferForced: Bool,
        serverSelected: SubtitleTrack?
    ) -> SubtitleTrack? {
        let matches = tracks.filter { PlayerViewModel.normalizedLanguageCode($0.languageCode) == language }
        if let serverSelected, matches.contains(serverSelected), isForced(serverSelected) == preferForced {
            return serverSelected
        }
        return matches
            .sorted(by: PlayerViewModel.subtitleOrdering(preferForcedTracks: preferForced))
            .first
    }

    private static func isForced(_ track: SubtitleTrack) -> Bool {
        track.isForced || PlayerViewModel.containsForcedMarker(track.displayTitle)
    }
}
