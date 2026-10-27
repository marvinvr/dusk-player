import Foundation
import Testing
@testable import Dusk

@Suite("Automatic subtitle selection policy")
@MainActor
struct SubtitleSelectionPolicyTests {
    /// English full, English SDH, English forced, German full, German forced.
    private static let streams = #"""
        {"id":10,"streamType":2,"languageCode":"eng","codec":"ac3","channels":6},
        {"id":11,"streamType":2,"languageCode":"jpn","codec":"aac","channels":2},
        {"id":20,"streamType":3,"languageCode":"eng","codec":"srt"},
        {"id":21,"streamType":3,"languageCode":"eng","codec":"srt","hearingImpaired":true},
        {"id":22,"streamType":3,"languageCode":"eng","codec":"srt","forced":true},
        {"id":30,"streamType":3,"languageCode":"ger","codec":"srt"},
        {"id":31,"streamType":3,"languageCode":"ger","codec":"pgs","forced":true}
        """#

    private func policy(
        _ mode: SubtitleMode,
        subtitles: String? = "en",
        audio: String? = "en",
        forced: Bool = true
    ) -> SubtitleSelectionPolicy {
        SubtitleSelectionPolicy(mode: mode, subtitleLanguage: subtitles, audioLanguage: audio, forcedSubtitlesEnabled: forced)
    }

    private func pick(_ policy: SubtitleSelectionPolicy, audio: String?, streams: String = streams) throws -> Int? {
        let part = try self.part(streams)
        let tracks = part.streams.filter { $0.streamType == .subtitle }.map(SubtitleTrack.init(stream:))
        return policy.preferredTrack(in: tracks, audioLanguage: audio)?.id
    }

    // MARK: - Modes

    @Test func offShowsOnlyForcedSubtitlesInYourLanguage() throws {
        #expect(try pick(policy(.off), audio: "eng") == 22)
        // Foreign audio does not turn full subtitles on in Off.
        #expect(try pick(policy(.off), audio: "jpn") == 22)
    }

    @Test func offWithoutForcedSubtitlesShowsNothing() throws {
        #expect(try pick(policy(.off, forced: false), audio: "eng") == nil)
        #expect(try pick(policy(.auto, forced: false), audio: "eng") == nil)
    }

    @Test func autoPrefersFullNonSDHSubtitlesForForeignAudio() throws {
        #expect(try pick(policy(.auto), audio: "jpn") == 20)
    }

    @Test func autoShowsForcedSubtitlesWhenAudioIsYourLanguage() throws {
        #expect(try pick(policy(.auto), audio: "eng") == 22)
    }

    @Test func autoComparesAudioWithTheSubtitleLanguageOnly() throws {
        // Japanese audio preferred, English subtitles: the anime case wants
        // the subtitles even though the audio is the preferred one.
        let animeFan = policy(.auto, subtitles: "en", audio: "ja")
        #expect(try pick(animeFan, audio: "jpn") == 20)
        #expect(try pick(animeFan, audio: "eng") == 22)
        // German subtitles with an English audio preference: English audio is
        // still foreign to the subtitle language (Plex's rule).
        #expect(try pick(policy(.auto, subtitles: "de", audio: "en"), audio: "eng") == 30)
    }

    @Test func autoWithOriginalAudioOnlyUnderstandsTheSubtitleLanguage() throws {
        let originalAudio = policy(.auto, subtitles: "de", audio: "")
        #expect(originalAudio.audioLanguage == nil)
        #expect(try pick(originalAudio, audio: "eng") == 30)
        #expect(try pick(originalAudio, audio: "deu") == 31)
    }

    @Test func autoTreatsUntaggedAudioAsUnderstood() throws {
        #expect(try pick(policy(.auto), audio: nil) == 22)
        #expect(try pick(policy(.auto), audio: "und") == 22)
    }

    @Test func alwaysShowsFullSubtitlesEvenForYourLanguage() throws {
        #expect(try pick(policy(.always), audio: "eng") == 20)
        #expect(try pick(policy(.always, subtitles: "de"), audio: "eng") == 30)
    }

    @Test func fullSubtitlesFallBackToSDHThenForced() throws {
        let sdhOnly = #"""
            {"id":21,"streamType":3,"languageCode":"eng","codec":"srt","hearingImpaired":true},
            {"id":22,"streamType":3,"languageCode":"eng","codec":"srt","forced":true}
            """#
        #expect(try pick(policy(.always), audio: "jpn", streams: sdhOnly) == 21)
        let forcedOnly = #"{"id":22,"streamType":3,"languageCode":"eng","codec":"srt","forced":true}"#
        #expect(try pick(policy(.auto), audio: "jpn", streams: forcedOnly) == 22)
    }

    @Test func missingSubtitleLanguageFallsBackToForcedSubtitles() throws {
        let germanOnly = #"""
            {"id":30,"streamType":3,"languageCode":"ger","codec":"srt"},
            {"id":31,"streamType":3,"languageCode":"ger","codec":"srt","forced":true}
            """#
        // No French track: Always cannot help, but forced subtitles for the
        // German audio still appear.
        #expect(try pick(policy(.always, subtitles: "fr", audio: ""), audio: "deu", streams: germanOnly) == 31)
        #expect(try pick(policy(.always, subtitles: "fr", audio: "", forced: false), audio: "deu", streams: germanOnly) == nil)
    }

    @Test func forcedSubtitlesNeverComeFromAnUnrelatedLanguage() throws {
        let frenchForced = #"{"id":40,"streamType":3,"languageCode":"fre","codec":"srt","forced":true}"#
        #expect(try pick(policy(.off), audio: "eng", streams: frenchForced) == nil)
        let untaggedForced = #"{"id":41,"streamType":3,"codec":"srt","displayTitle":"Forced"}"#
        #expect(try pick(policy(.off), audio: "eng", streams: untaggedForced) == 41)
    }

    @Test func forcedMarkerInTitleCountsAsForced() throws {
        let titled = #"""
            {"id":50,"streamType":3,"languageCode":"eng","codec":"srt","displayTitle":"English"},
            {"id":51,"streamType":3,"languageCode":"eng","codec":"srt","displayTitle":"English (Forced)"}
            """#
        #expect(try pick(policy(.off), audio: "eng", streams: titled) == 51)
        #expect(try pick(policy(.auto), audio: "jpn", streams: titled) == 50)
    }

    // MARK: - Server selection (issue #21)

    /// Fansub release: two full English tracks, the server selects the second.
    private static let honorifics = #"""
        {"id":11,"streamType":2,"languageCode":"jpn","codec":"aac","channels":2},
        {"id":60,"streamType":3,"languageCode":"eng","codec":"ass","displayTitle":"English"},
        {"id":61,"streamType":3,"languageCode":"eng","codec":"ass","displayTitle":"English (Honorifics)","selected":true},
        {"id":62,"streamType":3,"languageCode":"eng","codec":"ass","displayTitle":"Signs","forced":true}
        """#

    private func pick(_ policy: SubtitleSelectionPolicy, audio: String?, streams: String, serverSelected: Bool) throws -> Int? {
        let part = try self.part(streams)
        let tracks = part.streams.filter { $0.streamType == .subtitle }.map(SubtitleTrack.init(stream:))
        return policy.preferredTrack(
            in: tracks,
            audioLanguage: audio,
            serverSelectedStreamID: serverSelected ? PlayerViewModel.serverSelectedStreamID(of: .subtitle, inPart: part) : nil
        )?.id
    }

    @Test func serverSelectionBreaksTiesWithinTheWantedLanguage() throws {
        #expect(try pick(policy(.auto), audio: "jpn", streams: Self.honorifics, serverSelected: false) == 60)
        #expect(try pick(policy(.auto), audio: "jpn", streams: Self.honorifics, serverSelected: true) == 61)
        #expect(try pick(policy(.always), audio: "eng", streams: Self.honorifics, serverSelected: true) == 61)
        let part = try self.part(Self.honorifics)
        #expect(PlayerViewModel.preferredSubtitleStreamID(inPart: part, policy: policy(.auto, audio: ""), audioStream: nil) == 61)
    }

    @Test func serverSelectionNeverOverridesModeOrLanguage() throws {
        // Off still shows only forced subtitles, however the server selected.
        #expect(try pick(policy(.off), audio: "jpn", streams: Self.honorifics, serverSelected: true) == 62)
        #expect(try pick(policy(.off, forced: false), audio: "jpn", streams: Self.honorifics, serverSelected: true) == nil)
        // A selected track in another language does not change the language.
        let germanSelected = Self.streams.replacingOccurrences(
            of: #""id":30,"streamType":3"#, with: #""id":30,"selected":true,"streamType":3"#
        )
        #expect(try pick(policy(.always), audio: "eng", streams: germanSelected, serverSelected: true) == 20)
    }

    @Test func selectedForcedTrackDoesNotReplaceWantedFullSubtitles() throws {
        let forcedSelected = Self.streams.replacingOccurrences(
            of: #""id":22,"streamType":3"#, with: #""id":22,"selected":true,"streamType":3"#
        )
        #expect(try pick(policy(.auto), audio: "jpn", streams: forcedSelected, serverSelected: true) == 20)
        // But it does win among forced tracks.
        let twoForced = #"""
            {"id":70,"streamType":3,"languageCode":"eng","codec":"srt","forced":true},
            {"id":71,"streamType":3,"languageCode":"eng","codec":"srt","forced":true,"selected":true}
            """#
        #expect(try pick(policy(.off), audio: "eng", streams: twoForced, serverSelected: true) == 71)
    }

    @Test func serverSelectedSDHTrackWinsOverTheFullTrack() throws {
        let sdhSelected = Self.streams.replacingOccurrences(
            of: #""id":21,"streamType":3"#, with: #""id":21,"selected":true,"streamType":3"#
        )
        #expect(try pick(policy(.always), audio: "eng", streams: sdhSelected, serverSelected: true) == 21)
    }

    // MARK: - Startup pick on Plex metadata

    @Test func startupPickUsesTheAudioThePreferenceOpensOn() throws {
        let part = try self.part(Self.streams)
        // English audio exists, so the session starts English: forced only.
        #expect(PlayerViewModel.preferredSubtitleStreamID(inPart: part, policy: policy(.auto), audioStream: nil) == 22)
        // Japanese preference: the session starts Japanese, so full English.
        #expect(PlayerViewModel.preferredSubtitleStreamID(inPart: part, policy: policy(.auto, audio: "ja"), audioStream: nil) == 20)
    }

    @Test func startupPickFollowsARememberedAudioTrack() throws {
        let part = try self.part(Self.streams)
        let japanese = try #require(part.streams.first { $0.id == 11 })
        #expect(PlayerViewModel.preferredSubtitleStreamID(inPart: part, policy: policy(.auto), audioStream: japanese) == 20)
    }

    @Test func startupPickWithOriginalAudioUsesTheDefaultTrack() throws {
        let part = try self.part(#"""
            {"id":11,"streamType":2,"languageCode":"jpn","codec":"aac","default":true},
            {"id":10,"streamType":2,"languageCode":"eng","codec":"ac3"},
            {"id":20,"streamType":3,"languageCode":"eng","codec":"srt"},
            {"id":22,"streamType":3,"languageCode":"eng","codec":"srt","forced":true}
            """#)
        #expect(PlayerViewModel.preferredSubtitleStreamID(inPart: part, policy: policy(.auto, audio: ""), audioStream: nil) == 20)
    }

    // MARK: - Settings

    @Test func legacySettingsMapOntoTheNewModes() throws {
        #expect(try stored(["defaultSubtitleLanguage": "de", "subtitleForcedOnly": false])
            == .init(language: "de", mode: .always, forcedSubtitlesEnabled: true))
        #expect(try stored(["defaultSubtitleLanguage": "de", "subtitleForcedOnly": true])
            == .init(language: "de", mode: .off, forcedSubtitlesEnabled: true))
        let noneNoForced = try stored(["defaultSubtitleLanguage": "", "subtitleForcedOnly": false])
        #expect(noneNoForced.mode == .off)
        #expect(!noneNoForced.forcedSubtitlesEnabled)
        let noneForced = try stored(["defaultSubtitleLanguage": ""])
        #expect(noneForced.mode == .off)
        #expect(noneForced.forcedSubtitlesEnabled)
    }

    @Test func untouchedSettingsKeepForcedOnlyAndTheDeviceLanguage() throws {
        let fresh = try stored([:])
        #expect(fresh.mode == .off)
        #expect(fresh.forcedSubtitlesEnabled)
        #expect(fresh.language == (UserPreferences.systemPreferredSubtitleLanguageCode ?? "en"))
    }

    @Test func audioLanguageFollowsTheDeviceUntilTheViewerChooses() throws {
        let device = UserPreferences.systemPreferredSubtitleLanguageCode
        #expect(try audioLanguage([:]) == (device ?? "en"))
        #expect(try audioLanguage([:], systemLanguage: "ja") == "ja")
        #expect(try audioLanguage([:], systemLanguage: nil) == "en")
        #expect(try audioLanguage(["defaultAudioLanguage": "de"], systemLanguage: "ja") == "de")
        #expect(try audioLanguage(["defaultAudioLanguage": ""], systemLanguage: "ja") == "")
        #expect(try audioLanguage(["defaultAudioLanguage": "en"], systemLanguage: "ja") == "en")
        #expect(try audioLanguage(["plexAccountAudioLanguage": "fr"], systemLanguage: "ja") == "fr")
        #expect(try audioLanguage(["plexAccountAudioLanguage": ""], systemLanguage: "ja") == "")
        #expect(try audioLanguage(
            ["defaultAudioLanguage": "it", "plexAccountAudioLanguage": "fr"],
            systemLanguage: "ja"
        ) == "it")
    }

    @Test func plexAccountDefaultsApplyOnlyToUntouchedSettings() throws {
        let account: [String: Any] = ["plexAccountSubtitleLanguage": "fr", "plexAccountSubtitleMode": "auto"]
        #expect(try stored(account) == .init(language: "fr", mode: .auto, forcedSubtitlesEnabled: true))
        var chosen = account
        chosen["defaultSubtitleLanguage"] = "it"
        chosen["subtitleMode"] = "always"
        #expect(try stored(chosen) == .init(language: "it", mode: .always, forcedSubtitlesEnabled: true))
        // A legacy Forced Only choice is a choice too.
        chosen = account
        chosen["subtitleForcedOnly"] = true
        #expect(try stored(chosen).mode == .off)
    }

    @Test func plexAccountProfileDecodesLeniently() throws {
        let numeric = try profile(#"{"autoSelectAudio":true,"defaultAudioLanguage":"de","defaultSubtitleLanguage":"en-US","autoSelectSubtitle":1}"#)
        #expect(numeric == .init(audioLanguage: "de", subtitleLanguage: "en", subtitleMode: .auto))
        let strings = try profile(#"{"autoSelectAudio":"0","defaultAudioLanguage":"de","autoSelectSubtitle":"2"}"#)
        #expect(strings == .init(audioLanguage: "", subtitleLanguage: nil, subtitleMode: .always))
        let manual = try profile(#"{"autoSelectSubtitle":0}"#)
        #expect(manual == .init(audioLanguage: nil, subtitleLanguage: nil, subtitleMode: .off))
    }

    // MARK: - Helpers

    private func part(_ streams: String) throws -> PlexMediaPart {
        try JSONDecoder().decode(PlexMedia.self, from: Data("""
            {"id":1,"Part":[{"id":1,"key":"/clip","Stream":[\(streams)]}]}
            """.utf8)).parts[0]
    }

    private func audioLanguage(
        _ values: [String: Any],
        systemLanguage: String? = UserPreferences.systemPreferredSubtitleLanguageCode
    ) throws -> String {
        let suite = "SubtitleSelectionPolicyTests-audio-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
        return UserPreferences.storedAudioLanguage(defaults: defaults, systemLanguage: systemLanguage)
    }

    private func stored(_ values: [String: Any]) throws -> UserPreferences.StoredSubtitleSettings {
        let suite = "SubtitleSelectionPolicyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
        return UserPreferences.storedSubtitleSettings(defaults: defaults)
    }

    private func profile(_ json: String) throws -> PlexAccountLanguageDefaults {
        let profile = try JSONDecoder().decode(PlexAccountLanguageDefaults.Profile.self, from: Data(json.utf8))
        return PlexAccountLanguageDefaults(profile: profile)
    }
}
