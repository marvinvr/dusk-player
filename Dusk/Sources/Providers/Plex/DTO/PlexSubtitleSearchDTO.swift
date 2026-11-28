import Foundation

/// One hit of Plex's server-side subtitle search
/// (`GET /library/metadata/{itemID}/subtitles`, a bare `Stream` array).
/// Mapped to `SubtitleSearchResult` by `PlexUserContentMapper`.
///
/// Every field except `key` is optional: the shape varies by server version,
/// agent and provider.
struct PlexSubtitleSearchResultDTO: Decodable, Sendable {
    /// Plex reuses the `Stream` shape here, so `id` is usually a `0`
    /// placeholder rather than a library stream id.
    let rawID: Int?
    let key: String
    let codec: String?
    let title: String?
    let providerTitle: String?
    let sourceTitle: String?
    /// Sent as int, double or string depending on the server; rounded.
    let score: Int?
    let languageCode: String?
    let language: String?
    let isHearingImpaired: Bool?
    let isForced: Bool?
    let format: String?

    enum CodingKeys: String, CodingKey {
        case id, key, codec, title, providerTitle, sourceTitle, score
        case languageCode, language, format
        case isHearingImpaired = "hearingImpaired"
        case isForced = "forced"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        key = try container.decode(String.self, forKey: .key)
        codec = try container.decodeIfPresent(String.self, forKey: .codec)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        providerTitle = try container.decodeIfPresent(String.self, forKey: .providerTitle)
        sourceTitle = try container.decodeIfPresent(String.self, forKey: .sourceTitle)
        score = Self.decodeScore(container: container)
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        isHearingImpaired = container.decodeSubtitleBoolish(forKey: .isHearingImpaired)
        isForced = container.decodeSubtitleBoolish(forKey: .isForced)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        rawID = (try? container.decodeIfPresent(Int.self, forKey: .id))
            ?? Int((try? container.decodeIfPresent(String.self, forKey: .id)) ?? "")
    }

    private static func decodeScore(container: KeyedDecodingContainer<CodingKeys>) -> Int? {
        if let intValue = try? container.decodeIfPresent(Int.self, forKey: .score) {
            return intValue
        }
        if let doubleValue = try? container.decodeIfPresent(Double.self, forKey: .score) {
            return Int(doubleValue.rounded())
        }
        if let stringValue = try? container.decodeIfPresent(String.self, forKey: .score) {
            if let intValue = Int(stringValue) { return intValue }
            if let doubleValue = Double(stringValue) { return Int(doubleValue.rounded()) }
        }
        return nil
    }
}

private extension KeyedDecodingContainer {
    /// Plex sends flag fields as `true`/`false` or as `1`/`0`, and occasionally
    /// as `"1"`.
    func decodeSubtitleBoolish(forKey key: Key) -> Bool? {
        if let boolValue = try? decodeIfPresent(Bool.self, forKey: key) {
            return boolValue
        }
        if let intValue = try? decodeIfPresent(Int.self, forKey: key) {
            return intValue != 0
        }
        if let stringValue = try? decodeIfPresent(String.self, forKey: key) {
            switch stringValue.lowercased() {
            case "1", "true": return true
            case "0", "false": return false
            default: return nil
            }
        }
        return nil
    }
}
