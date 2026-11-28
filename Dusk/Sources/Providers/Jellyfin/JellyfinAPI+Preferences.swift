import Foundation

/// The account-preference and subtitle-search routes (02 §1, §10; J-11).
extension JellyfinAPI {
    // MARK: User configuration

    /// `/Users/Me`'s `Configuration` as the server sent it, every key kept, so
    /// a write can send back exactly what it read with two arrays changed.
    /// `POST /Users/Configuration` replaces the whole object: a typed DTO would
    /// reset every key it does not know (`CastReceiverId`, `EnableLocalPassword`…).
    static func userConfigurationJSON() -> JellyfinRequest<DuskJSONValue> {
        JellyfinRequest(path: "/Users/Me") { data, context in
            let user = try JellyfinJSON.decode(DuskJSONValue.self, from: data)
            if let userID = context.userID, let id = user["Id"]?.stringValue, !JellyfinID.same(id, userID) {
                throw JellyfinError.unexpectedResponse("token belongs to another user")
            }
            guard let configuration = user["Configuration"], configuration.objectValue != nil else {
                throw JellyfinError.unexpectedResponse("user has no configuration")
            }
            return configuration
        }
    }

    /// Writes the whole configuration (`204`). Needs
    /// `Policy.EnableUserPreferenceAccess`, else `403`.
    static func replaceUserConfiguration(_ configuration: DuskJSONValue) -> JellyfinRequest<JellyfinNoContent> {
        .noContent(.post, "/Users/Configuration", isUserScoped: true, body: .fixed(configuration))
    }

    // MARK: Subtitle search (§10)

    /// `language` is ISO 639-2/B (`eng`, `ger`). `403` without
    /// `Policy.EnableSubtitleManagement`; `[]` without a subtitle plugin.
    static func searchRemoteSubtitles(itemID: String, language: String) -> JellyfinRequest<[JellyfinRemoteSubtitleInfoDTO]> {
        .json(.get, "/Items/\(itemID)/RemoteSearch/Subtitles/\(language)")
    }

    /// Downloads a result onto the server as an external subtitle (`204`).
    /// The provider fetch can take several seconds.
    static func downloadRemoteSubtitle(itemID: String, subtitleID: String) -> JellyfinRequest<JellyfinNoContent> {
        var request = JellyfinRequest<JellyfinNoContent>.noContent(
            .post, "/Items/\(itemID)/RemoteSearch/Subtitles/\(subtitleID)"
        )
        request.timeout = 30
        return request
    }
}

/// `RemoteSubtitleInfo`, one subtitle search result.
struct JellyfinRemoteSubtitleInfoDTO: Decodable, Hashable, Sendable {
    let id: String
    let threeLetterISOLanguageName: String?
    let providerName: String?
    let name: String?
    let format: String?
    let author: String?
    let comment: String?
    let communityRating: Double?
    let downloadCount: Int?
    let isHashMatch: Bool?
    let forced: Bool?
    let hearingImpaired: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case threeLetterISOLanguageName = "ThreeLetterISOLanguageName"
        case providerName = "ProviderName"
        case name = "Name"
        case format = "Format"
        case author = "Author"
        case comment = "Comment"
        case communityRating = "CommunityRating"
        case downloadCount = "DownloadCount"
        case isHashMatch = "IsHashMatch"
        case forced = "Forced"
        case hearingImpaired = "HearingImpaired"
    }
}
