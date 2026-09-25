import Foundation

extension PlayerViewModel {
    func selectSubtitle(_ track: SubtitleTrack?) {
        hasAppliedAutomaticSubtitleSelection = true
        hasUserSelectedSubtitleTrack = true

        if let track, track.requiresEngineSwitch, let streamID = track.plexStreamID {
            // A Plex sidecar in an AVPlayer session: the engine cannot mount
            // it, so the coordinator restarts this session on VLCKit at the
            // live position with the stream pre-selected.
            showSubtitlePicker = false
            pendingExternalSubtitleStreamID = streamID
            externalSubtitleRestartHandler?(streamID)
            return
        }

        if usesServerTrackSelection {
            selectedSubtitleTrackID = track?.id
            showSubtitlePicker = false
            plexTrackSelectionHandler?(selectedAudioTrackID, track?.id)
            return
        }
        engine.selectSubtitleTrack(track)
        selectedSubtitleTrackID = engine.selectedSubtitleTrackID
        showSubtitlePicker = false
        plexTrackSelectionHandler?(selectedAudioTrack?.plexStreamID, track?.plexStreamID)
    }

    /// The in-player size picker edits the same stored preference as Settings
    /// (there is no per-session override), then asks the engine to apply it to
    /// the running session.
    func selectSubtitleFontSize(_ size: SubtitleFontSize) {
        showSubtitleSizePicker = false
        guard subtitleFontSize != size else { return }
        subtitleFontSize = size
        userPreferences?.subtitleFontSize = size
        engine.applySubtitleFontSize(size)
    }

    func selectAudio(_ track: AudioTrack) {
        hasAppliedAutomaticAudioSelection = true
        showAudioPicker = false

        if usesServerTrackSelection {
            selectedAudioTrackID = track.id
            plexTrackSelectionHandler?(track.plexStreamID ?? track.id, selectedSubtitleTrackID)
            return
        }

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
        plexTrackSelectionHandler?(track.plexStreamID, selectedSubtitleTrack?.plexStreamID)
    }

    func syncTrackLists() {
        if usesServerTrackSelection {
            audioTracks = sourcePart?.streams
                .filter { $0.streamType == .audio }
                .map(AudioTrack.init(stream:)) ?? []
            subtitleTracks = sourcePart?.streams
                .filter { $0.streamType == .subtitle }
                .map(SubtitleTrack.init(stream:)) ?? []
            selectedAudioTrackID = serverSelectedAudioStreamID
                ?? audioTracks.first(where: { track in
                    sourcePart?.streams.first(where: { $0.id == track.id })?.isSelected ?? false
                })?.id
                ?? audioTracks.first?.id
            selectedSubtitleTrackID = serverSelectedSubtitleStreamID
            return
        }

        attachExternalSubtitlesIfNeeded()
        audioTracks = mergeAudioMetadata(into: engine.availableAudioTracks)
        subtitleTracks = mergeSubtitleMetadata(into: engine.availableSubtitleTracks)
        selectedAudioTrackID = resolvedSelectedAudioTrackID()
        selectedSubtitleTrackID = resolvedSelectedSubtitleTrackID()
    }

    func applyAutomaticTrackSelectionIfNeeded() {
        guard hasConfiguredAutomaticTrackSelection else { return }
        guard !usesServerTrackSelection else {
            hasAppliedAutomaticAudioSelection = true
            hasAppliedAutomaticSubtitleSelection = true
            return
        }

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
            selectedSubtitleTrackID = engine.selectedSubtitleTrackID
            hasAppliedAutomaticSubtitleSelection = true
        } else if shouldReapplyAutomaticSubtitleSelectionForExternalTracks {
            // A mounted sidecar joins the list after the container's own
            // tracks, so give the language preference one more chance to land
            // on it. Only ever once, only while the viewer has not chosen, and
            // only when it actually changes the pick (so it can never turn a
            // running selection off).
            hasReappliedAutomaticSubtitleSelectionForExternalTracks = true
            if let preferredSubtitleTrack = preferredSubtitleTrack(),
               preferredSubtitleTrack.id != selectedSubtitleTrackID {
                engine.selectSubtitleTrack(preferredSubtitleTrack)
                selectedSubtitleTrackID = engine.selectedSubtitleTrackID
            }
        }
    }

    private var shouldReapplyAutomaticSubtitleSelectionForExternalTracks: Bool {
        hasAppliedAutomaticSubtitleSelection &&
            !hasReappliedAutomaticSubtitleSelectionForExternalTracks &&
            !hasUserSelectedSubtitleTrack &&
            pendingExternalSubtitleStreamID == nil &&
            subtitleTracks.contains { $0.isExternal && !$0.requiresEngineSwitch }
    }

    /// Hands the part's Plex sidecar subtitle streams to the engine once it is
    /// actually rendering. Deliberately not done before `load(source:)`:
    /// mounting a slave costs a fetch on the input thread, and nothing about it
    /// should sit in front of playback starting.
    func attachExternalSubtitlesIfNeeded() {
        guard engine.supportsExternalSubtitles, !usesServerTrackSelection else { return }
        guard engine.state == .playing || engine.state == .paused else { return }

        for (stream, url) in externalSubtitleStreams {
            let shouldSelect = pendingExternalSubtitleStreamID == stream.id
            // A stream that is already mounted still has to be revisited when
            // it is the pending selection: the engine then just selects it.
            guard shouldSelect || !attachedExternalSubtitleStreamIDs.contains(stream.id) else { continue }
            attachedExternalSubtitleStreamIDs.insert(stream.id)
            if shouldSelect {
                pendingExternalSubtitleStreamID = nil
                hasAppliedAutomaticSubtitleSelection = true
                hasUserSelectedSubtitleTrack = true
            }
            engine.attachExternalSubtitle(url, select: shouldSelect)
        }
    }

    /// Re-reads the active part after Plex installed a sidecar mid-session,
    /// mounts whatever is new, and selects `streamID` once it is up.
    func reloadExternalSubtitleStreams(part: PlexMediaPart?, selecting streamID: Int?) {
        sourcePart = part
        if let streamID {
            pendingExternalSubtitleStreamID = streamID
        }
        rebuildExternalSubtitleStreamIndex()
        attachExternalSubtitlesIfNeeded()
        syncTrackLists()
    }

    /// Resolves every sidecar subtitle stream of the current part to its
    /// token-bearing URL once, so mounting and labelling can both work off it.
    func rebuildExternalSubtitleStreamIndex() {
        guard let externalSubtitleURLProvider else {
            externalSubtitleStreams = []
            return
        }
        externalSubtitleStreams = (sourcePart?.streams ?? [])
            .filter { $0.streamType == .subtitle && $0.key != nil }
            .compactMap { stream in
                externalSubtitleURLProvider(stream).map { (stream: stream, url: $0) }
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

    /// Tracks automatic selection may choose. A Plex sidecar the current engine
    /// cannot mount is excluded: selecting it restarts the session on VLCKit,
    /// which is the viewer's call, never a language preference's.
    var automaticallySelectableSubtitleTracks: [SubtitleTrack] {
        subtitleTracks.filter { !$0.requiresEngineSwitch }
    }

    func preferredSubtitleTrack() -> SubtitleTrack? {
        if subtitleForcedOnly {
            let forcedTracks = automaticallySelectableSubtitleTracks.filter {
                $0.isForced || Self.containsForcedMarker($0.displayTitle)
            }
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
            from: automaticallySelectableSubtitleTracks,
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

        // Plex's saved selection is metadata, not evidence that the local
        // decoder selected a track. In particular, nil also means explicit Off.
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
                // Plex's codec is authoritative even when the engine's own
                // fourcc check misses a TrueHD variant.
                isDecodable: track.isDecodable && !Self.isLocallyUndecodableAudioCodec(source.codec)
            )
        }
    }

    /// Merges Plex stream metadata onto the engine's subtitle tracks, from two
    /// deliberately disjoint pools.
    ///
    /// Embedded engine tracks are matched against the part's embedded streams
    /// (`key == nil`) by the fuzzy scorer, as before. A Plex sidecar
    /// (`key != nil`) only ever labels a track the engine told us it mounted
    /// from that exact URL (`VLCKitEngine.attachExternalSubtitle`), replacing
    /// libvlc's file-name label with the Plex metadata. Keeping the pools apart
    /// preserves the original invariant: an external stream must never relabel
    /// an embedded engine track with metadata the engine cannot render.
    ///
    /// Sidecars the current engine cannot mount at all (AVPlayer cannot attach
    /// one to a live item without an AVComposition rebuild) are appended as
    /// `requiresEngineSwitch` placeholders instead, so they are still offered —
    /// picking one restarts the session on VLCKit.
    func mergeSubtitleMetadata(into engineTracks: [SubtitleTrack]) -> [SubtitleTrack] {
        let embeddedStreams = sourcePart?.streams.filter {
            $0.streamType == .subtitle && $0.key == nil
        } ?? []

        var remaining = Array(embeddedStreams.enumerated())
        var embeddedPosition = 0
        var merged: [SubtitleTrack] = []

        for track in engineTracks {
            if let externalURL = track.externalURL {
                guard let source = externalSubtitleStreams.first(where: { $0.url == externalURL })?.stream else {
                    merged.append(track)
                    continue
                }
                merged.append(externalSubtitleTrack(id: track.id, stream: source, engineTrack: track))
                continue
            }

            let position = embeddedPosition
            embeddedPosition += 1
            guard !embeddedStreams.isEmpty, let source = popBestMatch(
                for: track,
                at: position,
                from: &remaining,
                score: scoreSubtitleMatch(track:stream:)
            ) else {
                merged.append(track)
                continue
            }

            merged.append(SubtitleTrack(
                id: track.id,
                displayTitle: source.extendedDisplayTitle ?? source.displayTitle ?? track.displayTitle,
                language: source.language ?? track.language,
                languageCode: Self.normalizedLanguageCode(source.languageCode ?? source.languageTag) ?? track.languageCode,
                codec: source.codec ?? track.codec,
                isForced: source.isForced ?? track.isForced,
                isHearingImpaired: source.isHearingImpaired ?? track.isHearingImpaired,
                isExternal: track.isExternal,
                plexStreamID: source.id,
                externalURL: track.externalURL
            ))
        }

        merged.append(contentsOf: unmountableExternalSubtitleTracks())
        return merged
    }

    /// Label for a sidecar the engine actually mounted: Plex metadata over
    /// libvlc's file name, with the Plex stream id kept for AirPlay handoffs.
    private func externalSubtitleTrack(
        id: Int,
        stream: PlexStream,
        engineTrack: SubtitleTrack
    ) -> SubtitleTrack {
        SubtitleTrack(
            id: id,
            displayTitle: stream.extendedDisplayTitle
                ?? stream.displayTitle
                ?? stream.language
                ?? engineTrack.displayTitle,
            language: stream.language ?? engineTrack.language,
            languageCode: Self.normalizedLanguageCode(stream.languageCode ?? stream.languageTag)
                ?? engineTrack.languageCode,
            codec: stream.codec ?? engineTrack.codec,
            isForced: stream.isForced ?? engineTrack.isForced,
            isHearingImpaired: stream.isHearingImpaired ?? engineTrack.isHearingImpaired,
            isExternal: true,
            plexStreamID: stream.id,
            externalURL: engineTrack.externalURL
        )
    }

    /// Placeholder rows for an engine that cannot mount sidecars at all. Ids sit
    /// in their own high range so they cannot collide with engine track ids
    /// (AVPlayer numbers its media-selection options from zero).
    private func unmountableExternalSubtitleTracks() -> [SubtitleTrack] {
        guard !engine.supportsExternalSubtitles else { return [] }
        return externalSubtitleStreams.map(\.stream).enumerated().map { offset, stream in
            SubtitleTrack(
                id: Self.externalSubtitlePlaceholderIDBase + offset,
                displayTitle: stream.extendedDisplayTitle
                    ?? stream.displayTitle
                    ?? stream.language
                    ?? "External Subtitles",
                language: stream.language,
                languageCode: Self.normalizedLanguageCode(stream.languageCode ?? stream.languageTag),
                codec: stream.codec,
                isForced: stream.isForced ?? false,
                isHearingImpaired: stream.isHearingImpaired ?? false,
                isExternal: true,
                plexStreamID: stream.id,
                externalURL: nil,
                requiresEngineSwitch: true
            )
        }
    }

    static let externalSubtitlePlaceholderIDBase = 900_000_000

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
    ///
    /// Streams the local engines cannot decode (TrueHD/MLP) are never the
    /// preselection: opening libvlc on one is a silent start. When such a
    /// stream is dropped from the language scope, a lone decodable sibling is
    /// still returned so libvlc opens on it instead of the container default.
    /// AirPlay passes `excludingLocallyUndecodable: false` — the server
    /// decodes every codec there.
    static func preferredAudioStreamPosition(
        inPart part: PlexMediaPart?,
        preferredLanguage rawPreferredLanguage: String?,
        excludingLocallyUndecodable: Bool = true
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

        let scopedStreams = audioStreams.enumerated().filter { _, stream in
            normalizedLanguageCode(stream.languageCode ?? stream.languageTag) == scopeLanguage
        }
        let candidates = scopedStreams.filter { _, stream in
            !excludingLocallyUndecodable || !isLocallyUndecodableAudioCodec(stream.codec)
        }
        let droppedUndecodable = candidates.count < scopedStreams.count
        guard candidates.count > (preferredLanguage != nil || droppedUndecodable ? 0 : 1) else {
            return nil
        }

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

    /// Plex stream id matching the same pre-start audio policy used for VLCKit
    /// preselection. AirPlay HLS pins the server session to an id rather than a
    /// container-relative elementary-stream position.
    static func preferredAudioStreamID(
        inPart part: PlexMediaPart?,
        preferredLanguage: String?
    ) -> Int? {
        guard let part else { return nil }
        let audioStreams = part.streams.filter { $0.streamType == .audio }
        if let position = preferredAudioStreamPosition(
            inPart: part,
            preferredLanguage: preferredLanguage,
            excludingLocallyUndecodable: false
        ), audioStreams.indices.contains(position) {
            return audioStreams[position].id
        }
        return audioStreams.first(where: { $0.isSelected ?? false })?.id
            ?? audioStreams.first(where: { $0.isDefault ?? false })?.id
            ?? audioStreams.first?.id
    }

    /// Channel count of the stream `preferredAudioStreamID` resolves to, used to
    /// open the tvOS audio session to the right layout before libvlc measures
    /// the route (`PlaybackSource.preferredAudioChannelCount`). Falls back to the
    /// richest audio stream in the part when the winning stream carries no
    /// channel count, so an unlabelled 5.1 track still opens a multichannel
    /// route rather than silently getting folded to stereo.
    static func preferredAudioStreamChannelCount(
        inPart part: PlexMediaPart?,
        preferredLanguage: String?
    ) -> Int? {
        guard let part else { return nil }
        let audioStreams = part.streams.filter { $0.streamType == .audio }
        guard !audioStreams.isEmpty else { return nil }

        // Same pick VLCKit is preselected onto, so a TrueHD 7.1 + AC-3 5.1
        // file opens the route for the 5.1 track that will actually play.
        if let position = preferredAudioStreamPosition(inPart: part, preferredLanguage: preferredLanguage),
           audioStreams.indices.contains(position),
           let channels = audioStreams[position].channels,
           channels > 0 {
            return channels
        }
        if let id = preferredAudioStreamID(inPart: part, preferredLanguage: preferredLanguage),
           let channels = audioStreams.first(where: { $0.id == id })?.channels,
           channels > 0 {
            return channels
        }
        return audioStreams.compactMap { $0.channels }.filter { $0 > 0 }.max()
    }

    /// Initial subtitle stream for server-rendered playback. It mirrors Dusk's
    /// local automatic subtitle rule closely enough to choose before the HLS
    /// session exists; Plex burns the result so all AirPlay receivers agree.
    static func preferredSubtitleStreamID(
        inPart part: PlexMediaPart?,
        preferredLanguage rawPreferredLanguage: String?,
        forcedOnly: Bool
    ) -> Int? {
        guard let part else { return nil }
        let tracks = part.streams
            .filter { $0.streamType == .subtitle }
            .map(SubtitleTrack.init(stream:))
        let preferredLanguage = normalizedLanguageCode(rawPreferredLanguage)

        let candidates: [SubtitleTrack]
        if forcedOnly {
            candidates = tracks.filter { $0.isForced || containsForcedMarker($0.displayTitle) }
        } else if preferredLanguage != nil {
            candidates = tracks
        } else {
            return nil
        }

        let languageMatches = preferredLanguage.map { language in
            candidates.filter { normalizedLanguageCode($0.languageCode) == language }
        } ?? candidates
        return languageMatches
            .sorted(by: subtitleOrdering(preferForcedTracks: forcedOnly))
            .first?
            .id
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

    /// Preference pickers store ISO 639-1 codes (`ro`, `en`). Plex `languageCode`
    /// and VLCKit track language are often ISO 639-2 (`rum`/`ron`, `eng`), so
    /// matching canonicalizes both sides through Foundation. `no` and `nor`
    /// collapse to `nb`; that is only safe because this helper is used on every
    /// compared value.
    static func normalizedLanguageCode(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        guard let raw = value.split(separator: "-").first.map({ String($0).lowercased() }),
              !raw.isEmpty else {
            return nil
        }

        let canonical = Locale.canonicalLanguageIdentifier(from: raw)
            .split(separator: "-")
            .first
            .map { String($0).lowercased() }
        if let canonical, !canonical.isEmpty {
            return canonical
        }
        return raw
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

    /// Plex audio codecs neither local engine can decode: the vendored stock
    /// VLCKit ships without TrueHD/MLP, and AVPlayer never supported them.
    static func isLocallyUndecodableAudioCodec(_ codec: String?) -> Bool {
        guard let codec = codec?.lowercased() else { return false }
        return codec == "truehd" || codec == "mlp"
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
