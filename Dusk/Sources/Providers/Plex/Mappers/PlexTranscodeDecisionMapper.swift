import Foundation

// `PlexTranscodeDecisionDTO` → what `MediaService+Playback` acts on.

extension PlexTranscodeDecisionDTO {
    var streamDecisions: MediaService.TranscodeStreamDecisions {
        let media = MediaContainer.metadata?.first?.Media?.first
        let part = media?.Part?.first
        let streams = part?.Stream ?? []
        let video = streams.first { $0.kind == 1 }
        let audio = streams.first { $0.kind == 2 }
        let subtitle = streams.first { $0.kind == 3 }
        return MediaService.TranscodeStreamDecisions(
            container: part?.container ?? media?.container,
            videoDecision: video?.decision,
            videoCodec: video?.codec,
            audioDecision: audio?.decision,
            audioCodec: audio?.codec,
            audioChannels: audio?.channels,
            audioProfile: audio?.profile,
            subtitleDecision: subtitle?.decision,
            subtitleLocation: subtitle?.location
        )
    }

    /// The part Plex plans to direct play (a Live TV session's consumer
    /// playlist), nil for any other decision.
    var directPlayPartKey: String? {
        guard let part = MediaContainer.metadata?.first?.Media?.first?.Part?.first,
              part.decision?.lowercased() == "directplay" else { return nil }
        return part.key?.nilIfEmpty
    }

    var outcome: MediaService.TranscodeDecisionOutcome {
        let general = MediaContainer.generalDecisionCode
        let transcode = MediaContainer.transcodeDecisionCode
        let mde = MediaContainer.mdeDecisionCode

        if [general, transcode, mde].contains(where: { ($0 ?? 0) >= 2000 }) {
            return .failed(MediaContainer.transcodeDecisionText ?? MediaContainer.generalDecisionText)
        }
        if transcode == 1000 || general == 1000 {
            return .directPlayOnly
        }
        if transcode == 1001 || general == 1001 {
            return .transcodeAvailable
        }

        return .transcodeAvailable
    }
}
