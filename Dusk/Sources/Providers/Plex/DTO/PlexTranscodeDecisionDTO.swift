import Foundation

/// Plex's answer to `/video/:/transcode/universal/decision`. Mapped to
/// `MediaService.TranscodeDecisionOutcome` / `TranscodeStreamDecisions` by
/// `PlexTranscodeDecisionMapper`.
struct PlexTranscodeDecisionDTO: Decodable {
    let MediaContainer: Container

    /// The session Plex planned: Metadata → Media → Part → Stream, where each
    /// stream carries `decision` (copy / transcode / burn) and `location`.
    struct PlannedMetadata: Decodable {
        let Media: [PlannedMedia]?
    }

    struct PlannedMedia: Decodable {
        let container: String?
        let Part: [PlannedPart]?
    }

    struct PlannedPart: Decodable {
        let container: String?
        let key: String?
        let decision: String?
        let Stream: [PlannedStream]?
    }

    struct PlannedStream: Decodable {
        let kind: Int?
        let codec: String?
        let decision: String?
        let location: String?
        let channels: Int?
        let profile: String?

        enum CodingKeys: String, CodingKey {
            case kind = "streamType", codec, decision, location, channels, profile
        }
    }

    struct Container: Decodable {
        let generalDecisionCode: Int?
        let generalDecisionText: String?
        let transcodeDecisionCode: Int?
        let transcodeDecisionText: String?
        let mdeDecisionCode: Int?
        let mdeDecisionText: String?
        let metadata: [PlannedMetadata]?

        enum CodingKeys: String, CodingKey {
            case generalDecisionCode
            case generalDecisionText
            case transcodeDecisionCode
            case transcodeDecisionText
            case mdeDecisionCode
            case mdeDecisionText
            case metadata = "Metadata"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            generalDecisionCode = Self.decodeFlexibleInt(container, key: .generalDecisionCode)
            generalDecisionText = try container.decodeIfPresent(String.self, forKey: .generalDecisionText)
            transcodeDecisionCode = Self.decodeFlexibleInt(container, key: .transcodeDecisionCode)
            transcodeDecisionText = try container.decodeIfPresent(String.self, forKey: .transcodeDecisionText)
            mdeDecisionCode = Self.decodeFlexibleInt(container, key: .mdeDecisionCode)
            mdeDecisionText = try container.decodeIfPresent(String.self, forKey: .mdeDecisionText)
            // Diagnostic only: an unexpected shape must never fail the decision.
            metadata = try? container.decodeIfPresent([PlannedMetadata].self, forKey: .metadata)
        }

        private static func decodeFlexibleInt(
            _ container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) -> Int? {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return Int(value)
            }
            return nil
        }
    }
}
