import Foundation

extension PlayerViewModel {
    func selectSubtitle(_ track: SubtitleTrack?) {
        hasAppliedAutomaticSubtitleSelection = true
        engine.selectSubtitleTrack(track)
        selectedSubtitleTrackID = track?.id
        showSubtitlePicker = false
    }

    func selectAudio(_ track: AudioTrack) {
        hasAppliedAutomaticAudioSelection = true
        showAudioPicker = false

        guard track.isDecodable else {
            // The local engine cannot decode this codec (e.g. TrueHD on the
            // bundled VLCKit build) — selecting the ES would just kill the
            // working audio and leave silence. Restart as a server transcode
            // pinned to this stream so the choice still produces sound.
            transcodeAudioFallbackHandler?(track)
            return
        }

        engine.selectAudioTrack(track)
        selectedAudioTrackID = track.id
    }

    func syncTrackLists() {
        audioTracks = mergeAudioMetadata(into: engine.availableAudioTracks)
        subtitleTracks = mergeSubtitleMetadata(into: engine.availableSubtitleTracks)
        selectedAudioTrackID = resolvedSelectedAudioTrackID()
        selectedSubtitleTrackID = resolvedSelectedSubtitleTrackID()
    }

    func applyAutomaticTrackSelectionIfNeeded() {
        guard hasConfiguredAutomaticTrackSelection else { return }

        // Audio waits for steady-state playback (`sync()` retries every tick):
        // switching the audio ES restarts libvlc's audio output, and doing so
        // during startup/buffering/the resume seek can leave it silent until a
        // manual pause/resume. Steady-state switches are reliable.
        if !hasAppliedAutomaticAudioSelection, !audioTracks.isEmpty,
           engine.isReadyForAutomaticAudioSelection {
            if let preferredAudioTrack = preferredAudioTrack(),
               preferredAudioTrack.id != engine.selectedAudioTrackID {
                engine.selectAudioTrack(preferredAudioTrack)
                selectedAudioTrackID = preferredAudioTrack.id
            }
            hasAppliedAutomaticAudioSelection = true
        }

        // A file whose every audio track is locally undecodable (e.g. a
        // TrueHD-only remux) would direct-play as a silent video. Rescue it
        // once by restarting as a server transcode of the default stream.
        if !hasRequestedUndecodableAudioFallback,
           !audioTracks.isEmpty,
           selectableAudioTracks.isEmpty {
            hasRequestedUndecodableAudioFallback = true
            transcodeAudioFallbackHandler?(nil)
        }

        if !hasAppliedAutomaticSubtitleSelection, !subtitleTracks.isEmpty {
            let preferredSubtitleTrack = preferredSubtitleTrack()
            engine.selectSubtitleTrack(preferredSubtitleTrack)
            selectedSubtitleTrackID = preferredSubtitleTrack?.id
            hasAppliedAutomaticSubtitleSelection = true
        }
    }

    /// Tracks automatic selection may choose: only ones the local engine can
    /// actually decode. The pickers still list every track — selecting an
    /// undecodable one reroutes through the server-transcode fallback in
    /// `selectAudio` instead of silencing playback.
    var selectableAudioTracks: [AudioTrack] {
        audioTracks.filter(\.isDecodable)
    }

    func preferredAudioTrack() -> AudioTrack? {
        let languageMatches: [(offset: Int, element: AudioTrack)]

        if let preferredAudioLanguage {
            languageMatches = selectableAudioTracks.enumerated().filter { _, track in
                Self.normalizedLanguageCode(track.languageCode) == preferredAudioLanguage
            }
            guard !languageMatches.isEmpty else { return nil }
        } else {
            // No preferred language configured: never switch the authored
            // language, but still re-rank between same-language alternatives
            // so the platform codec adjustment below can demote e.g. a
            // container-default TrueHD track in favor of its AC-3/E-AC-3
            // sibling on iPhone. Only step in when there is a real choice.
            let anchorLanguage = defaultAudioAnchorLanguageCode()
            languageMatches = selectableAudioTracks.enumerated().filter { _, track in
                Self.normalizedLanguageCode(track.languageCode) == anchorLanguage
            }
            guard languageMatches.count > 1 else { return nil }
        }

        return languageMatches
            .sorted { lhs, rhs in
                let lhsScore = audioSelectionScore(for: lhs.element, originalIndex: lhs.offset)
                let rhsScore = audioSelectionScore(for: rhs.element, originalIndex: rhs.offset)

                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }

                return lhs.offset < rhs.offset
            }
            .first?
            .element
    }

    /// The language playback would land on with no user preference: the
    /// Plex-selected stream, else the container-default stream, else the
    /// first track. Automatic re-ranking without a configured language stays
    /// inside this group, so it may swap codecs but never the spoken language.
    func defaultAudioAnchorLanguageCode() -> String? {
        let audioStreams = sourcePart?.streams.filter { $0.streamType == .audio } ?? []
        if let anchor = audioStreams.first(where: { $0.isSelected ?? false })
            ?? audioStreams.first(where: { $0.isDefault ?? false })
            ?? audioStreams.first {
            return Self.normalizedLanguageCode(anchor.languageCode ?? anchor.languageTag)
        }

        if let selectedTrackID = engine.selectedAudioTrackID,
           let selectedTrack = audioTracks.first(where: { $0.id == selectedTrackID }) {
            return Self.normalizedLanguageCode(selectedTrack.languageCode)
        }

        return Self.normalizedLanguageCode(audioTracks.first?.languageCode)
    }

    func preferredSubtitleTrack() -> SubtitleTrack? {
        if subtitleForcedOnly {
            let forcedTracks = subtitleTracks.filter { $0.isForced || Self.containsForcedMarker($0.displayTitle) }
            guard !forcedTracks.isEmpty else { return nil }

            if let preferredSubtitleLanguage {
                return rankedSubtitleTrack(
                    from: forcedTracks,
                    preferredLanguage: preferredSubtitleLanguage,
                    preferForcedTracks: true
                )
            }

            return forcedTracks.sorted(by: Self.subtitleOrdering(preferForcedTracks: true)).first
        }

        guard let preferredSubtitleLanguage else { return nil }
        return rankedSubtitleTrack(
            from: subtitleTracks,
            preferredLanguage: preferredSubtitleLanguage,
            preferForcedTracks: false
        )
    }

    func rankedSubtitleTrack(
        from tracks: [SubtitleTrack],
        preferredLanguage: String,
        preferForcedTracks: Bool
    ) -> SubtitleTrack? {
        tracks
            .filter { Self.normalizedLanguageCode($0.languageCode) == preferredLanguage }
            .sorted(by: Self.subtitleOrdering(preferForcedTracks: preferForcedTracks))
            .first
    }

    func resolvedSelectedAudioTrackID() -> Int? {
        if let selectedTrackID = engine.selectedAudioTrackID,
           audioTracks.contains(where: { $0.id == selectedTrackID }) {
            return selectedTrackID
        }

        if let sourceStream = sourcePart?.streams.first(where: {
            $0.streamType == .audio && ($0.isSelected ?? false)
        }), let matchedTrack = bestMatchingAudioTrack(for: sourceStream) {
            return matchedTrack.id
        }

        return audioTracks.first?.id
    }

    func resolvedSelectedSubtitleTrackID() -> Int? {
        if let selectedTrackID = engine.selectedSubtitleTrackID,
           subtitleTracks.contains(where: { $0.id == selectedTrackID }) {
            return selectedTrackID
        }

        if let sourceStream = sourcePart?.streams.first(where: {
            $0.streamType == .subtitle && ($0.isSelected ?? false)
        }), let matchedTrack = bestMatchingSubtitleTrack(for: sourceStream) {
            return matchedTrack.id
        }

        return nil
    }

    func bestMatchingAudioTrack(for stream: PlexStream) -> AudioTrack? {
        bestMatchingTrack(in: audioTracks) { track in
            scoreAudioMatch(track: track, stream: stream)
        }
    }

    func bestMatchingSubtitleTrack(for stream: PlexStream) -> SubtitleTrack? {
        bestMatchingTrack(in: subtitleTracks) { track in
            scoreSubtitleMatch(track: track, stream: stream)
        }
    }

    func bestMatchingTrack<Track>(
        in tracks: [Track],
        score: (Track) -> Int
    ) -> Track? {
        let best = tracks.max { lhs, rhs in
            score(lhs) < score(rhs)
        }

        guard let best, score(best) > 0 else { return nil }
        return best
    }

    func mergeAudioMetadata(into engineTracks: [AudioTrack]) -> [AudioTrack] {
        let sourceStreams = sourcePart?.streams.filter { $0.streamType == .audio } ?? []
        guard !sourceStreams.isEmpty else { return engineTracks }

        var remaining = Array(sourceStreams.enumerated())

        return engineTracks.enumerated().map { index, track in
            guard let source = popBestMatch(
                for: track,
                at: index,
                from: &remaining,
                score: scoreAudioMatch(track:stream:)
            ) else {
                return track
            }

            return AudioTrack(
                id: track.id,
                displayTitle: source.extendedDisplayTitle ?? source.displayTitle ?? track.displayTitle,
                language: source.language ?? track.language,
                languageCode: Self.normalizedLanguageCode(source.languageCode ?? source.languageTag) ?? track.languageCode,
                codec: source.codec ?? track.codec,
                channels: source.channels ?? track.channels,
                channelLayout: source.channelLayout ?? track.channelLayout,
                plexStreamID: source.id,
                isDecodable: track.isDecodable
            )
        }
    }

    func mergeSubtitleMetadata(into engineTracks: [SubtitleTrack]) -> [SubtitleTrack] {
        let sourceStreams = sourcePart?.streams.filter { $0.streamType == .subtitle } ?? []
        guard !sourceStreams.isEmpty else { return engineTracks }

        var remaining = Array(sourceStreams.enumerated())

        return engineTracks.enumerated().map { index, track in
            guard let source = popBestMatch(
                for: track,
                at: index,
                from: &remaining,
                score: scoreSubtitleMatch(track:stream:)
            ) else {
                return track
            }

            return SubtitleTrack(
                id: track.id,
                displayTitle: source.extendedDisplayTitle ?? source.displayTitle ?? track.displayTitle,
                language: source.language ?? track.language,
                languageCode: Self.normalizedLanguageCode(source.languageCode ?? source.languageTag) ?? track.languageCode,
                codec: source.codec ?? track.codec,
                isForced: source.isForced ?? track.isForced,
                isHearingImpaired: source.isHearingImpaired ?? track.isHearingImpaired,
                isExternal: source.key != nil || track.isExternal,
                externalURL: track.externalURL
            )
        }
    }

    func popBestMatch<Track>(
        for track: Track,
        at index: Int,
        from candidates: inout [(offset: Int, element: PlexStream)],
        score: (Track, PlexStream) -> Int
    ) -> PlexStream? {
        guard !candidates.isEmpty else { return nil }

        let rankedCandidates = candidates.enumerated().map { candidateIndex, candidate in
            let positionalBonus = candidate.offset == index ? 2 : 0
            return (
                candidateIndex: candidateIndex,
                totalScore: score(track, candidate.element) + positionalBonus
            )
        }

        let best = rankedCandidates.max { lhs, rhs in
            lhs.totalScore < rhs.totalScore
        }

        let selectedIndex: Int
        if let best, best.totalScore > 0 {
            selectedIndex = best.candidateIndex
        } else if let positionalMatch = candidates.firstIndex(where: { $0.offset == index }) {
            selectedIndex = positionalMatch
        } else {
            selectedIndex = 0
        }

        return candidates.remove(at: selectedIndex).element
    }

    func scoreAudioMatch(track: AudioTrack, stream: PlexStream) -> Int {
        var score = 0

        if let trackLanguage = Self.normalizedLanguageCode(track.languageCode),
           trackLanguage == Self.normalizedLanguageCode(stream.languageCode ?? stream.languageTag) {
            score += 4
        }

        if let trackTitle = Self.normalizedTitle(track.displayTitle),
           trackTitle == Self.normalizedTitle(stream.extendedDisplayTitle ?? stream.displayTitle) {
            score += 3
        }

        if let trackLanguage = Self.normalizedTitle(track.language),
           trackLanguage == Self.normalizedTitle(stream.language) {
            score += 1
        }

        return score
    }

    func audioSelectionScore(for track: AudioTrack, originalIndex: Int) -> Int {
        let isPlexSelected = sourcePart?.streams.contains(where: {
            $0.streamType == .audio &&
                ($0.isSelected ?? false) &&
                scoreAudioMatch(track: track, stream: $0) >= 5
        }) == true

        let isPlexDefault = sourcePart?.streams.contains(where: {
            $0.streamType == .audio &&
                ($0.isDefault ?? false) &&
                scoreAudioMatch(track: track, stream: $0) >= 5
        }) == true

        return Self.audioSelectionScore(
            for: track,
            originalIndex: originalIndex,
            isPlexSelected: isPlexSelected,
            isPlexDefault: isPlexDefault
        )
    }

    /// Shared scoring core for automatic audio selection, used both at
    /// runtime (VLC track list merged with Plex metadata) and before playback
    /// starts (`preferredAudioStreamPosition`, pure Plex metadata).
    static func audioSelectionScore(
        for track: AudioTrack,
        originalIndex: Int,
        isPlexSelected: Bool,
        isPlexDefault: Bool
    ) -> Int {
        var score = 0

        if isPlexSelected {
            score += 1_000
        }

        if isPlexDefault {
            score += 500
        }

        score += (track.channels ?? inferredChannelCount(from: track) ?? 0) * 40
        score += audioCodecPreferenceScore(for: track)
        score += platformAudioCodecAdjustment(for: track)

        if containsCommentaryMarker(track.displayTitle) {
            score -= 2_000
        }

        if containsDescriptiveAudioMarker(track.displayTitle) {
            score -= 1_500
        }

        if (track.channels ?? inferredChannelCount(from: track)) == 2 ||
            containsStereoDownmixMarker(track.displayTitle) {
            score -= 40
        }

        return score - originalIndex
    }

    /// Pre-start twin of `preferredAudioTrack()`, operating on Plex part
    /// metadata alone. Returns the winning stream's position among the part's
    /// audio streams — libvlc's `:audio-track` index — so VLCKit can open
    /// directly on that track instead of switching after playback starts
    /// (switching restarts the audio output, which is fragile mid-startup).
    /// Same policy as the runtime path: scope to the preferred language when
    /// configured (any match counts), otherwise re-rank only within the
    /// default track's language and only when there is a real alternative.
    static func preferredAudioStreamPosition(
        inPart part: PlexMediaPart?,
        preferredLanguage rawPreferredLanguage: String?
    ) -> Int? {
        guard let part else { return nil }
        let audioStreams = part.streams.filter { $0.streamType == .audio }
        guard audioStreams.count > 1 else { return nil }

        let preferredLanguage = normalizedLanguageCode(rawPreferredLanguage)
        let scopeLanguage: String?
        if let preferredLanguage {
            scopeLanguage = preferredLanguage
        } else {
            let anchor = audioStreams.first(where: { $0.isSelected ?? false })
                ?? audioStreams.first(where: { $0.isDefault ?? false })
                ?? audioStreams.first
            scopeLanguage = normalizedLanguageCode(anchor?.languageCode ?? anchor?.languageTag)
        }

        let candidates = audioStreams.enumerated().filter { _, stream in
            normalizedLanguageCode(stream.languageCode ?? stream.languageTag) == scopeLanguage
        }
        guard candidates.count > (preferredLanguage != nil ? 0 : 1) else { return nil }

        return candidates
            .sorted { lhs, rhs in
                let lhsScore = audioSelectionScore(
                    for: AudioTrack(stream: lhs.element),
                    originalIndex: lhs.offset,
                    isPlexSelected: lhs.element.isSelected ?? false,
                    isPlexDefault: lhs.element.isDefault ?? false
                )
                let rhsScore = audioSelectionScore(
                    for: AudioTrack(stream: rhs.element),
                    originalIndex: rhs.offset,
                    isPlexSelected: rhs.element.isSelected ?? false,
                    isPlexDefault: rhs.element.isDefault ?? false
                )

                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }

                return lhs.offset < rhs.offset
            }
            .first?
            .offset
    }

    func scoreSubtitleMatch(track: SubtitleTrack, stream: PlexStream) -> Int {
        var score = 0

        if let trackLanguage = Self.normalizedLanguageCode(track.languageCode),
           trackLanguage == Self.normalizedLanguageCode(stream.languageCode ?? stream.languageTag) {
            score += 4
        }

        if let trackTitle = Self.normalizedTitle(track.displayTitle),
           trackTitle == Self.normalizedTitle(stream.extendedDisplayTitle ?? stream.displayTitle) {
            score += 3
        }

        let trackIsForced = track.isForced || Self.containsForcedMarker(track.displayTitle)
        let streamIsForced = stream.isForced ?? false
        if trackIsForced == streamIsForced {
            score += 2
        }

        let trackIsHI = track.isHearingImpaired || Self.containsHearingImpairedMarker(track.displayTitle)
        let streamIsHI = stream.isHearingImpaired ?? false
        if trackIsHI == streamIsHI {
            score += 1
        }

        return score
    }

    static func subtitleOrdering(preferForcedTracks: Bool) -> (SubtitleTrack, SubtitleTrack) -> Bool {
        { lhs, rhs in
            let lhsForced = lhs.isForced || containsForcedMarker(lhs.displayTitle)
            let rhsForced = rhs.isForced || containsForcedMarker(rhs.displayTitle)
            let lhsHI = lhs.isHearingImpaired || containsHearingImpairedMarker(lhs.displayTitle)
            let rhsHI = rhs.isHearingImpaired || containsHearingImpairedMarker(rhs.displayTitle)

            let lhsScore = subtitleSortScore(
                isForced: lhsForced,
                isHearingImpaired: lhsHI,
                preferForcedTracks: preferForcedTracks
            )
            let rhsScore = subtitleSortScore(
                isForced: rhsForced,
                isHearingImpaired: rhsHI,
                preferForcedTracks: preferForcedTracks
            )

            if lhsScore == rhsScore {
                return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            }

            return lhsScore > rhsScore
        }
    }

    static func subtitleSortScore(
        isForced: Bool,
        isHearingImpaired: Bool,
        preferForcedTracks: Bool
    ) -> Int {
        var score = 0
        score += preferForcedTracks ? (isForced ? 4 : 0) : (isForced ? 0 : 4)
        score += isHearingImpaired ? 0 : 2
        return score
    }

    static func normalizedLanguageCode(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        return value
            .split(separator: "-")
            .first?
            .lowercased()
    }

    static func normalizedTitle(_ value: String?) -> String? {
        guard let value = value?.lowercased(),
              !value.isEmpty else {
            return nil
        }

        let normalized = value
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")

        return normalized.isEmpty ? nil : normalized
    }

    static func containsForcedMarker(_ value: String) -> Bool {
        let normalized = normalizedTitle(value) ?? ""
        return normalized.contains("forced")
    }

    static func containsHearingImpairedMarker(_ value: String) -> Bool {
        let normalized = normalizedTitle(value) ?? ""
        return normalized.contains("sdh")
            || normalized.contains("cc")
            || normalized.contains("hearing impaired")
    }

    static func containsCommentaryMarker(_ value: String) -> Bool {
        let normalized = normalizedTitle(value) ?? ""
        return normalized.contains("commentary")
            || normalized.contains("director commentary")
            || normalized.contains("commentary with")
            || normalized.contains("cast commentary")
            || normalized.contains("crew commentary")
            || normalized.contains("producer commentary")
    }

    static func containsDescriptiveAudioMarker(_ value: String) -> Bool {
        let normalized = normalizedTitle(value) ?? ""
        return normalized.contains("audio description")
            || normalized.contains("descriptive audio")
            || normalized.contains("descriptive video")
            || normalized.contains("visually impaired")
            || normalized.contains("narration")
    }

    static func containsStereoDownmixMarker(_ value: String) -> Bool {
        let normalized = normalizedTitle(value) ?? ""
        return normalized.contains("stereo")
            || normalized.contains("downmix")
            || normalized.contains("2 0")
    }

    static func audioCodecPreferenceScore(for track: AudioTrack) -> Int {
        let normalized = [
            track.codec,
            track.displayTitle,
            track.channelLayout,
        ]
        .compactMap { normalizedTitle($0) }
        .joined(separator: " ")

        let hasAtmos = normalized.contains("atmos") || normalized.contains("joc")
        if hasAtmos && (normalized.contains("eac3") || normalized.contains("e ac3") ||
            normalized.contains("ec 3") ||
            normalized.contains("ddp") || normalized.contains("dolby digital plus")) {
            return 520
        }
        if hasAtmos && (normalized.contains("truehd") || normalized.contains("mlp")) {
            return 500
        }
        if normalized.contains("truehd") || normalized.contains("mlp") {
            return 460
        }
        if normalized.contains("dts hd ma") || normalized.contains("dts hd") ||
            normalized.contains("dtshd") {
            return 430
        }
        if normalized.contains("eac3") || normalized.contains("e ac3") ||
            normalized.contains("ec 3") ||
            normalized.contains("ddp") || normalized.contains("dolby digital plus") {
            return 400
        }
        if normalized.contains("ac3") || normalized.contains("a52") ||
            normalized.contains("dolby digital") {
            return 340
        }
        if normalized.contains("dts") || normalized.contains("dca") {
            return 320
        }
        if normalized.contains("flac") {
            return 260
        }
        if normalized.contains("alac") {
            return 240
        }
        if normalized.contains("aac") {
            return 160
        }
        if normalized.contains("mp3") {
            return 80
        }

        return 0
    }

    /// Platform correction on top of the pure quality ladder above. On tvOS
    /// the ladder is right as-is: lossless bitstreams (TrueHD/MLP, DTS-HD,
    /// PCM) decode to multichannel LPCM over HDMI and are the best possible
    /// pick. On iPhone/iPad the endpoint is a stereo/binaural downmix
    /// whichever track plays, so lossless buys nothing audible while costing
    /// decode CPU, battery, and (for remote streams) several Mbit/s — the
    /// lossy surround sibling (E-AC-3/AC-3/DTS) is the better automatic
    /// default. Sized to outweigh the Plex selected+default bonuses (+1500),
    /// a 7.1-vs-5.1 channel edge (+80), and the ladder gap, so a
    /// same-language lossy surround alternative wins; ranking stays relative,
    /// so a file whose only track is lossless still plays it natively.
    static func platformAudioCodecAdjustment(for track: AudioTrack) -> Int {
        #if os(tvOS)
        return 0
        #else
        return isLosslessBitstreamAudio(track) ? -1_800 : 0
        #endif
    }

    static func isLosslessBitstreamAudio(_ track: AudioTrack) -> Bool {
        let normalized = [
            track.codec,
            track.displayTitle,
            track.channelLayout,
        ]
        .compactMap { normalizedTitle($0) }
        .joined(separator: " ")

        return normalized.contains("truehd")
            || normalized.contains("mlp")
            || normalized.contains("dts hd")
            || normalized.contains("dtshd")
            || normalized.contains("pcm")
    }

    static func inferredChannelCount(from track: AudioTrack) -> Int? {
        let normalized = [
            track.displayTitle,
            track.channelLayout,
        ]
        .compactMap { normalizedTitle($0) }
        .joined(separator: " ")

        if normalized.contains("7 1") || normalized.contains("8ch") || normalized.contains("8 ch") {
            return 8
        }
        if normalized.contains("6 1") || normalized.contains("7ch") || normalized.contains("7 ch") {
            return 7
        }
        if normalized.contains("5 1") || normalized.contains("6ch") || normalized.contains("6 ch") {
            return 6
        }
        if normalized.contains("4 0") || normalized.contains("4ch") || normalized.contains("4 ch") {
            return 4
        }
        if normalized.contains("2 0") || normalized.contains("2ch") || normalized.contains("2 ch") ||
            normalized.contains("stereo") {
            return 2
        }

        return nil
    }
}
