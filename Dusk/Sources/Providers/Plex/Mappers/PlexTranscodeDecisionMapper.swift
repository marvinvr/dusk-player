import Foundation

// `PlexTranscodeDecisionDTO` → the `StreamDecisions` and `ServerStreamOutcome`
// that `PlexPlayback` hands the delivery ladder.

extension PlexTranscodeDecisionDTO {
    var streamDecisions: StreamDecisions {
        let media = MediaContainer.metadata?.first?.Media?.first
        let part = media?.Part?.first
        let streams = part?.Stream ?? []
        let video = streams.first { $0.kind == 1 }
        let audio = streams.first { $0.kind == 2 }
        let subtitle = streams.first { $0.kind == 3 }
        return StreamDecisions(
            container: part?.container ?? media?.container,
            video: Self.track(video?.decision),
            videoCodec: video?.codec,
            audio: Self.track(audio?.decision),
            audioCodec: audio?.codec,
            audioChannels: audio?.channels,
            audioProfile: audio?.profile,
            subtitle: Self.subtitle(decision: subtitle?.decision, location: subtitle?.location)
        )
    }

    /// Plex's per-track `decision`, compared exactly as Plex spells it.
    static func track(_ decision: String?) -> StreamDecisions.Track? {
        switch decision {
        case nil: nil
        case "copy": .copy
        case "transcode": .convert
        case let other?: .other(other)
        }
    }

    /// `segments-subs` (text segments in the stream) wins over the decision;
    /// a subtitle stream without a decision counts as none.
    static func subtitle(decision: String?, location: String?) -> StreamDecisions.Subtitle? {
        if location == "segments-subs" { return .textSegments }
        switch decision {
        case nil: return nil
        case "ignore": return .ignored
        case let other?: return .other(other)
        }
    }

    /// The part Plex plans to direct play (a Live TV session's consumer
    /// playlist), nil for any other decision.
    var directPlayPartKey: String? {
        guard let part = MediaContainer.metadata?.first?.Media?.first?.Part?.first,
              part.decision?.lowercased() == "directplay" else { return nil }
        return part.key?.nilIfEmpty
    }

    var outcome: ServerStreamOutcome {
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
