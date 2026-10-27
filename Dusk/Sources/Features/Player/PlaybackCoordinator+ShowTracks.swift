import Foundation
import OSLog

extension PlaybackCoordinator {
    /// Called only by explicit picker/download actions, including selecting Off
    /// again. Engine discovery, automatic selection and recovery never save.
    func rememberShowTrackChoice(type: PlexStreamType, streamID: Int?) {
        // A real pick is the viewer's to keep on the server, so the earlier
        // selection is no longer written back for that half.
        if type == .audio {
            manuallySelectedAudioStreamID = streamID
            automaticServerSelectionRestore?.audioStreamID = nil
        } else if type == .subtitle {
            automaticServerSelectionRestore?.subtitleStreamID = nil
        }
        guard activeLiveTVContext == nil,
              activeItemDetails?.type == .episode,
              let scope = activeShowTrackScope,
              scope.profileID == plexService.activeProfileID,
              let part = debugInfo?.part else { return }
        var remembered = showTrackPreferenceStore.preferences(for: scope) ?? ShowTrackPreferences()
        if type == .subtitle, streamID == nil {
            remembered.subtitles = .off
        } else {
            guard let streamID,
                  let stream = part.streams.first(where: { $0.streamType == type && $0.id == streamID }),
                  let descriptor = ShowTrackDescriptor(stream: stream) else { return }
            if type == .audio {
                remembered.audio = descriptor
            } else if type == .subtitle {
                remembered.subtitles = .track(descriptor)
            } else {
                return
            }
        }
        showTrackPreferenceStore.save(remembered, for: scope)

        // Remux changes already PUT the complete selection before rebuilding
        // HLS (including On → Off → On). Keep that authoritative path intact.
        guard !usesServerTrackSelection, !activePlaybackUsesLocalDownload else { return }
        syncShowStreamsToPlex(
            partID: part.id,
            audioStreamID: type == .audio ? streamID : nil,
            subtitleStreamID: type == .subtitle ? (streamID ?? 0) : nil,
            serverID: scope.serverID
        )
    }

    /// A manual choice belongs to the current item, including movies. After
    /// PiP re-presentation, fall back to the show's remembered choice only
    /// when the viewer has not selected audio during this playback.
    func rememberedShowTrackSelection() -> ExplicitTrackSelection? {
        if let manuallySelectedAudioStreamID {
            return ExplicitTrackSelection(
                audioStreamID: manuallySelectedAudioStreamID,
                subtitleStreamID: activeSubtitleStreamID
            )
        }
        guard activeLiveTVContext == nil,
              activeItemDetails?.type == .episode,
              let scope = activeShowTrackScope,
              scope.profileID == plexService.activeProfileID,
              let part = debugInfo?.part,
              let remembered = showTrackPreferenceStore.preferences(for: scope),
              remembered.hasMatch(in: part) else { return nil }
        return ExplicitTrackSelection(
            audioStreamID: activeAudioStreamID,
            subtitleStreamID: activeSubtitleStreamID
        )
    }

    /// Plex builds a remux from the part's server-side selection, so its
    /// start writes Dusk's automatic pick there. Keeps what the server had
    /// selected before (per half, only where the write changed it) so the
    /// session's end can put it back: an automatic pick must never replace a
    /// choice saved by another client or a bulk tool such as PASTA. The first
    /// write for a part holds the original; later ones are rebuilds.
    func noteAutomaticServerSelectionWrite(
        part: PlexMediaPart,
        audioStreamID: Int?,
        subtitleStreamID: Int?,
        serverID: String?
    ) {
        if let pending = automaticServerSelectionRestore, pending.partID != part.id {
            restoreAutomaticServerSelectionIfNeeded()
        }
        guard automaticServerSelectionRestore == nil else { return }
        let restore = ServerStreamSelectionRestore(
            part: part, writtenAudioStreamID: audioStreamID,
            writtenSubtitleStreamID: subtitleStreamID, serverID: serverID
        )
        automaticServerSelectionRestore = restore.isEmpty ? nil : restore
    }

    func restoreAutomaticServerSelectionIfNeeded() {
        guard let restore = automaticServerSelectionRestore else { return }
        automaticServerSelectionRestore = nil
        guard !restore.isEmpty else { return }
        syncShowStreamsToPlex(
            partID: restore.partID,
            audioStreamID: restore.audioStreamID,
            subtitleStreamID: restore.subtitleStreamID,
            serverID: restore.serverID
        )
    }

    func syncShowStreamsToPlex(partID: Int, audioStreamID: Int?, subtitleStreamID: Int?, serverID: String?) {
        let write = plexService.enqueueStreamSelection(
            partID: partID,
            audioStreamID: audioStreamID,
            subtitleStreamID: subtitleStreamID,
            serverID: serverID
        )
        Task { @MainActor in
            do {
                try await write.value
            } catch {
                // Local preferences survive offline/auth/server failures. Never
                // let a best-effort Plex write interrupt direct playback.
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "Dusk", category: "ShowTracks")
                    .notice("Could not sync track selection to Plex: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// A part's server-side audio/subtitle selection to write back. Nil halves
/// are left alone; a subtitle of 0 clears Plex's subtitle choice.
struct ServerStreamSelectionRestore: Equatable, Sendable {
    let partID: Int
    let serverID: String?
    var audioStreamID: Int?
    var subtitleStreamID: Int?

    var isEmpty: Bool { audioStreamID == nil && subtitleStreamID == nil }

    @MainActor
    init(part: PlexMediaPart, writtenAudioStreamID: Int?, writtenSubtitleStreamID: Int?, serverID: String?) {
        partID = part.id
        self.serverID = serverID
        let originalAudio = PlayerViewModel.serverSelectedStreamID(of: .audio, inPart: part)
        let originalSubtitle = PlayerViewModel.serverSelectedStreamID(of: .subtitle, inPart: part) ?? 0
        // Audio with no recorded selection has nothing to go back to.
        audioStreamID = writtenAudioStreamID != nil && originalAudio != writtenAudioStreamID ? originalAudio : nil
        subtitleStreamID = originalSubtitle != (writtenSubtitleStreamID ?? 0) ? originalSubtitle : nil
    }
}
