import Foundation

/// The Jellyfin endpoints Dusk uses, as request values for `JellyfinClient`.
/// One factory per call in docs/jellyfin/02-jellyfin-api-mapping.md; each
/// one carries the shape checks for its answer. Modern routes only (03 §10.7).
enum JellyfinAPI {
    typealias Items = JellyfinQueryResult<JellyfinItemDTO>

    // MARK: System and sign-in (§1)

    static func publicSystemInfo() -> JellyfinRequest<JellyfinPublicSystemInfoDTO> {
        .json(.get, "/System/Info/Public", authentication: .none) { info, _ in
            guard !info.id.isEmpty else { throw JellyfinError.unexpectedResponse("server without Id") }
        }
    }

    static func endpointInfo() -> JellyfinRequest<JellyfinEndpointInfoDTO> {
        .json(.get, "/System/Endpoint")
    }

    static func authenticateByName(username: String, password: String) -> JellyfinRequest<JellyfinAuthenticationResultDTO> {
        let body = JellyfinAuthenticateByNameDTO(username: username, password: password)
        return .json(.post, "/Users/AuthenticateByName", authentication: .none, body: .fixed(body),
                     validate: validateAuthentication)
    }

    static func quickConnectEnabled() -> JellyfinRequest<Bool> {
        .json(.get, "/QuickConnect/Enabled", authentication: .none)
    }

    /// Needs the identity header (`400` without); `GET` is `405`.
    static func quickConnectInitiate() -> JellyfinRequest<JellyfinQuickConnectResultDTO> {
        .json(.post, "/QuickConnect/Initiate", authentication: .none) { result, _ in
            guard !result.secret.isEmpty, result.code?.isEmpty == false else {
                throw JellyfinError.unexpectedResponse("Quick Connect without secret or code")
            }
        }
    }

    /// Poll; `authenticated` flips to true once approved. Unknown secret: `404`.
    static func quickConnectState(secret: String) -> JellyfinRequest<JellyfinQuickConnectResultDTO> {
        .json(.get, "/QuickConnect/Connect", query: [URLQueryItem(name: "secret", value: secret)],
              authentication: .none)
    }

    /// Before approval: `404`.
    static func authenticateWithQuickConnect(secret: String) -> JellyfinRequest<JellyfinAuthenticationResultDTO> {
        let body = JellyfinQuickConnectAuthenticateDTO(secret: secret)
        return .json(.post, "/Users/AuthenticateWithQuickConnect", authentication: .none, body: .fixed(body),
                     validate: validateAuthentication)
    }

    /// Token check: `200` or `401`.
    static func currentUser() -> JellyfinRequest<JellyfinUserDTO> {
        .json(.get, "/Users/Me") { user, context in
            if let userID = context.userID, !JellyfinID.same(user.id, userID) {
                throw JellyfinError.unexpectedResponse("token belongs to another user")
            }
        }
    }

    /// Users shown on the login screen. Often `[]` (all hidden).
    static func publicUsers() -> JellyfinRequest<[JellyfinUserDTO]> {
        .json(.get, "/Users/Public", authentication: .none)
    }

    /// Revokes the token (`204`).
    static func logout() -> JellyfinRequest<JellyfinNoContent> {
        .noContent(.post, "/Sessions/Logout")
    }

    static func postCapabilities(_ capabilities: JellyfinClientCapabilitiesDTO = .init()) -> JellyfinRequest<JellyfinNoContent> {
        .noContent(.post, "/Sessions/Capabilities/Full", body: .fixed(capabilities))
    }

    /// `/Users/Configuration?userId=`; needs `Policy.EnableUserPreferenceAccess`.
    static func updateUserConfiguration(_ configuration: JellyfinUserConfigurationDTO) -> JellyfinRequest<JellyfinNoContent> {
        .noContent(.post, "/Users/Configuration", isUserScoped: true, body: .fixed(configuration))
    }

    // MARK: Libraries, browse, details (§2, §3, §6)

    static func userViews() -> JellyfinRequest<Items> {
        .json(.get, "/UserViews", isUserScoped: true) { result, _ in
            try JellyfinItemQuery.validate(result.items)
        }
    }

    static func items(_ query: JellyfinItemQuery) -> JellyfinRequest<Items> {
        .json(.get, "/Items", query: query.queryItems, isUserScoped: true) { result, _ in
            try query.validate(result)
        }
    }

    /// The full item. The answer's id must be the one asked for.
    static func item(id: String) -> JellyfinRequest<JellyfinItemDTO> {
        .json(.get, "/Items/\(id)", isUserScoped: true) { item, _ in
            try validateSameItem(item, id: id)
        }
    }

    static func itemFilters(parentID: String?) -> JellyfinRequest<JellyfinItemFiltersDTO> {
        var query = JellyfinQuery()
        query.add("parentId", parentID)
        return .json(.get, "/Items/Filters", query: query.items, isUserScoped: true)
    }

    static func itemCounts() -> JellyfinRequest<JellyfinItemCountsDTO> {
        .json(.get, "/Items/Counts", isUserScoped: true)
    }

    static func genres(parentID: String?) -> JellyfinRequest<Items> {
        var query = JellyfinQuery()
        query.add("parentId", parentID)
        return .json(.get, "/Genres", query: query.items, isUserScoped: true) { result, _ in
            try JellyfinItemQuery.validate(result.items, includeItemTypes: [.genre], expectsUserData: false)
        }
    }

    static func seasons(seriesID: String, fields: [JellyfinItemField] = []) -> JellyfinRequest<Items> {
        var query = JellyfinQuery()
        query.add("fields", list: fields)
        return .json(.get, "/Shows/\(seriesID)/Seasons", query: query.items, isUserScoped: true) { result, _ in
            try JellyfinItemQuery.validate(result.items, includeItemTypes: [.season])
            if result.items.contains(where: { $0.seriesID.map { !JellyfinID.same($0, seriesID) } ?? false }) {
                throw JellyfinError.unexpectedResponse("season of another series")
            }
        }
    }

    /// Without `seasonID`: every episode of the show (Plex `allLeaves`).
    static func episodes(seriesID: String, seasonID: String? = nil, fields: [JellyfinItemField] = [],
                         startIndex: Int? = nil, limit: Int? = nil) -> JellyfinRequest<Items> {
        var query = JellyfinQuery()
        query.add("seasonId", seasonID)
        query.add("fields", list: fields)
        query.add("startIndex", startIndex)
        query.add("limit", limit)
        return .json(.get, "/Shows/\(seriesID)/Episodes", query: query.items, isUserScoped: true) { result, _ in
            // No season-id check: specials can be listed inside the season
            // they air in while carrying the specials season's id.
            try JellyfinItemQuery.validate(result.items, includeItemTypes: [.episode], limit: limit)
        }
    }

    /// Bare array.
    static func specialFeatures(itemID: String) -> JellyfinRequest<[JellyfinItemDTO]> {
        .json(.get, "/Items/\(itemID)/SpecialFeatures", isUserScoped: true)
    }

    /// Bare array.
    static func localTrailers(itemID: String) -> JellyfinRequest<[JellyfinItemDTO]> {
        .json(.get, "/Items/\(itemID)/LocalTrailers", isUserScoped: true)
    }

    static func similar(itemID: String, limit: Int) -> JellyfinRequest<Items> {
        .json(.get, "/Items/\(itemID)/Similar", query: [URLQueryItem(name: "limit", value: String(limit))],
              isUserScoped: true) { result, _ in
            try JellyfinItemQuery.validate(result.items, limit: limit)
        }
    }

    /// Bare array, nearest parent first.
    static func ancestors(itemID: String) -> JellyfinRequest<[JellyfinItemDTO]> {
        .json(.get, "/Items/\(itemID)/Ancestors", isUserScoped: true)
    }

    /// Cinema pre-rolls; `{Items: []}` without an intros plugin.
    static func intros(itemID: String) -> JellyfinRequest<Items> {
        .json(.get, "/Items/\(itemID)/Intros", isUserScoped: true)
    }

    /// Bare array of every image with its size.
    static func itemImages(itemID: String) -> JellyfinRequest<[JellyfinImageInfoDTO]> {
        .json(.get, "/Items/\(itemID)/Images")
    }

    // MARK: Home rows (§4)

    static func resume(limit: Int, mediaTypes: [JellyfinMediaType] = [.video],
                       fields: [JellyfinItemField] = []) -> JellyfinRequest<Items> {
        var query = JellyfinQuery()
        query.add("mediaTypes", list: mediaTypes)
        query.add("limit", limit)
        query.add("fields", list: fields)
        return .json(.get, "/UserItems/Resume", query: query.items, isUserScoped: true) { result, _ in
            try JellyfinItemQuery.validate(result.items, limit: limit)
        }
    }

    static func nextUp(seriesID: String? = nil, limit: Int, enableResumable: Bool = false,
                       enableRewatching: Bool = false, nextUpDateCutoff: Date? = nil,
                       fields: [JellyfinItemField] = []) -> JellyfinRequest<Items> {
        var query = JellyfinQuery()
        query.add("seriesId", seriesID)
        query.add("limit", limit)
        query.add("enableResumable", enableResumable)
        query.add("enableRewatching", enableRewatching)
        query.add("nextUpDateCutoff", nextUpDateCutoff.map { JellyfinDate($0).raw })
        query.add("fields", list: fields)
        return .json(.get, "/Shows/NextUp", query: query.items, isUserScoped: true) { result, _ in
            try JellyfinItemQuery.validate(result.items, includeItemTypes: [.episode], limit: limit)
            if let seriesID,
               result.items.contains(where: { $0.seriesID.map { !JellyfinID.same($0, seriesID) } ?? false }) {
                throw JellyfinError.unexpectedResponse("next up of another series")
            }
        }
    }

    /// Bare array; episodes come grouped up to `Season` / `Series` items.
    static func latest(parentID: String, limit: Int, groupItems: Bool = true,
                       fields: [JellyfinItemField] = []) -> JellyfinRequest<[JellyfinItemDTO]> {
        var query = JellyfinQuery()
        query.add("parentId", parentID)
        query.add("limit", limit)
        query.add("groupItems", groupItems)
        query.add("fields", list: fields)
        return .json(.get, "/Items/Latest", query: query.items, isUserScoped: true) { items, _ in
            try JellyfinItemQuery.validate(items, limit: limit)
        }
    }

    static func suggestions(limit: Int, mediaTypes: [JellyfinMediaType] = []) -> JellyfinRequest<Items> {
        var query = JellyfinQuery()
        query.add("limit", limit)
        query.add("mediaType", list: mediaTypes)
        return .json(.get, "/Items/Suggestions", query: query.items, isUserScoped: true) { result, _ in
            try JellyfinItemQuery.validate(result.items, limit: limit)
        }
    }

    // MARK: Search (§7)

    static func searchHints(term: String, limit: Int,
                            includeItemTypes: [JellyfinItemKind] = []) -> JellyfinRequest<JellyfinSearchHintResultDTO> {
        var query = JellyfinQuery()
        query.add("searchTerm", term)
        query.add("limit", limit)
        query.add("includeItemTypes", list: includeItemTypes)
        return .json(.get, "/Search/Hints", query: query.items, isUserScoped: true) { result, _ in
            if result.searchHints.count > limit {
                throw JellyfinError.unexpectedResponse("\(result.searchHints.count) hints for limit \(limit)")
            }
        }
    }

    // MARK: Watched state and progress (§8)

    static func userData(itemID: String) -> JellyfinRequest<JellyfinUserDataDTO> {
        .json(.get, "/UserItems/\(itemID)/UserData", isUserScoped: true)
    }

    /// Set position / clear resume (`{"PlaybackPositionTicks": 0}`), offline replay.
    static func updateUserData(itemID: String, _ update: JellyfinUserDataUpdateDTO) -> JellyfinRequest<JellyfinNoContent> {
        .noContent(.post, "/UserItems/\(itemID)/UserData", isUserScoped: true, body: .fixed(update))
    }

    /// Also cascades to every episode for a series or season id. `datePlayed`
    /// carries the real time for offline replay.
    static func markPlayed(itemID: String, datePlayed: Date? = nil) -> JellyfinRequest<JellyfinUserDataDTO> {
        var query = JellyfinQuery()
        query.add("datePlayed", datePlayed.map { JellyfinDate($0).raw })
        return .json(.post, "/UserPlayedItems/\(itemID)", query: query.items, isUserScoped: true) { data, _ in
            if data.played == false { throw JellyfinError.unexpectedResponse("item still unplayed") }
        }
    }

    static func markUnplayed(itemID: String) -> JellyfinRequest<JellyfinUserDataDTO> {
        .json(.delete, "/UserPlayedItems/\(itemID)", isUserScoped: true) { data, _ in
            if data.played == true { throw JellyfinError.unexpectedResponse("item still played") }
        }
    }

    static func setFavorite(itemID: String, _ isFavorite: Bool) -> JellyfinRequest<JellyfinUserDataDTO> {
        .json(isFavorite ? .post : .delete, "/UserFavoriteItems/\(itemID)", isUserScoped: true)
    }

    // MARK: Skip markers (§11)

    static func mediaSegments(itemID: String,
                              types: [JellyfinMediaSegmentType] = []) -> JellyfinRequest<JellyfinQueryResult<JellyfinMediaSegmentDTO>> {
        // Repeated parameter, not a comma list.
        let query = types.map { URLQueryItem(name: "includeSegmentTypes", value: $0.rawValue) }
        return .json(.get, "/MediaSegments/\(itemID)", query: query) { result, _ in
            if result.items.contains(where: { $0.itemID.map { !JellyfinID.same($0, itemID) } ?? false }) {
                throw JellyfinError.unexpectedResponse("segments of another item")
            }
        }
    }

    // MARK: Playback (§10, §8 reporting)

    /// The decision call. `UserId` is filled from the signed-in user.
    static func playbackInfo(itemID: String,
                             _ request: JellyfinPlaybackInfoRequestDTO) -> JellyfinRequest<JellyfinPlaybackInfoResponseDTO> {
        let body = JellyfinRequestBody { context in
            var request = request
            if request.userID == nil { request.userID = context.userID }
            return request
        }
        return .json(.post, "/Items/\(itemID)/PlaybackInfo", isUserScoped: true, body: body) { response, _ in
            if response.mediaSources.isEmpty, response.errorCode == nil {
                throw JellyfinError.unexpectedResponse("PlaybackInfo without media sources")
            }
            if let wanted = request.mediaSourceID,
               response.mediaSources.contains(where: { !JellyfinID.same($0.id, wanted) && $0.liveStreamID == nil }) {
                throw JellyfinError.unexpectedResponse("MediaSourceId not applied")
            }
        }
    }

    static func reportPlaybackStart(_ report: JellyfinPlaybackReportDTO) -> JellyfinRequest<JellyfinNoContent> {
        .noContent(.post, "/Sessions/Playing", body: .fixed(report))
    }

    static func reportPlaybackProgress(_ report: JellyfinPlaybackReportDTO) -> JellyfinRequest<JellyfinNoContent> {
        .noContent(.post, "/Sessions/Playing/Progress", body: .fixed(report))
    }

    static func reportPlaybackStopped(_ report: JellyfinPlaybackReportDTO) -> JellyfinRequest<JellyfinNoContent> {
        .noContent(.post, "/Sessions/Playing/Stopped", body: .fixed(report))
    }

    /// Keeps a server stream's transcode job alive.
    static func pingPlaybackSession(playSessionID: String) -> JellyfinRequest<JellyfinNoContent> {
        .noContent(.post, "/Sessions/Playing/Ping", query: [URLQueryItem(name: "playSessionId", value: playSessionID)])
    }

    /// Ends the ffmpeg job (`204`).
    static func stopEncoding(deviceID: String, playSessionID: String) -> JellyfinRequest<JellyfinNoContent> {
        .noContent(.delete, "/Videos/ActiveEncodings", query: [
            URLQueryItem(name: "deviceId", value: deviceID),
            URLQueryItem(name: "playSessionId", value: playSessionID),
        ])
    }

    /// Bare array; `TranscodingInfo` says whether video and audio were copied.
    static func sessions(deviceID: String) -> JellyfinRequest<[JellyfinSessionInfoDTO]> {
        .json(.get, "/Sessions", query: [URLQueryItem(name: "deviceId", value: deviceID)]) { sessions, _ in
            if sessions.contains(where: { $0.deviceID.map { $0 != deviceID } ?? false }) {
                throw JellyfinError.unexpectedResponse("session of another device")
            }
        }
    }

    // MARK: Playlists (§5)

    static func createPlaylist(_ playlist: JellyfinCreatePlaylistDTO) -> JellyfinRequest<JellyfinPlaylistCreationResultDTO> {
        let body = JellyfinRequestBody { context in
            var playlist = playlist
            if playlist.userID == nil { playlist.userID = context.userID }
            return playlist
        }
        return .json(.post, "/Playlists", body: body)
    }

    static func playlist(id: String) -> JellyfinRequest<JellyfinPlaylistDTO> {
        .json(.get, "/Playlists/\(id)")
    }

    /// Items carry `PlaylistItemId`, the handle for remove and move.
    static func playlistItems(id: String, startIndex: Int? = nil, limit: Int? = nil,
                              fields: [JellyfinItemField] = []) -> JellyfinRequest<Items> {
        var query = JellyfinQuery()
        query.add("startIndex", startIndex)
        query.add("limit", limit)
        query.add("fields", list: fields)
        return .json(.get, "/Playlists/\(id)/Items", query: query.items, isUserScoped: true) { result, _ in
            try JellyfinItemQuery.validate(result.items, limit: limit)
            if result.items.contains(where: { $0.playlistItemID == nil }) {
                throw JellyfinError.unexpectedResponse("playlist entry without PlaylistItemId")
            }
        }
    }

    static func addToPlaylist(id: String, itemIDs: [String]) -> JellyfinRequest<JellyfinNoContent> {
        .noContent(.post, "/Playlists/\(id)/Items", query: [URLQueryItem(name: "ids", value: itemIDs.joined(separator: ","))],
                   isUserScoped: true)
    }

    static func removeFromPlaylist(id: String, entryIDs: [String]) -> JellyfinRequest<JellyfinNoContent> {
        .noContent(.delete, "/Playlists/\(id)/Items",
                   query: [URLQueryItem(name: "entryIds", value: entryIDs.joined(separator: ","))])
    }

    /// Absolute target index, not "after".
    static func movePlaylistItem(id: String, entryID: String, toIndex: Int) -> JellyfinRequest<JellyfinNoContent> {
        .noContent(.post, "/Playlists/\(id)/Items/\(entryID)/Move/\(toIndex)")
    }

    static func updatePlaylist(id: String, _ update: JellyfinUpdatePlaylistDTO) -> JellyfinRequest<JellyfinNoContent> {
        .noContent(.post, "/Playlists/\(id)", body: .fixed(update))
    }

    /// Deletes a playlist or any other item. Needs `CanDelete` on the item
    /// (`Policy.EnableContentDeletion`): without it the server answers `401`
    /// even for the user's own playlist, and `DELETE /Playlists/{id}` is `405`.
    static func deleteItem(id: String) -> JellyfinRequest<JellyfinNoContent> {
        .noContent(.delete, "/Items/\(id)")
    }

    // MARK: Live TV (§15)

    static func liveTVInfo() -> JellyfinRequest<JellyfinLiveTVInfoDTO> {
        .json(.get, "/LiveTv/Info")
    }

    static func guideInfo() -> JellyfinRequest<JellyfinGuideInfoDTO> {
        .json(.get, "/LiveTv/GuideInfo")
    }

    static func channels(limit: Int? = nil, addCurrentProgram: Bool = true,
                         enableFavoriteSorting: Bool = true) -> JellyfinRequest<Items> {
        var query = JellyfinQuery()
        query.add("limit", limit)
        query.add("addCurrentProgram", addCurrentProgram)
        query.add("enableFavoriteSorting", enableFavoriteSorting)
        // Envelope only: channel shapes are unverified (no tuner on jellyfin-demo).
        return .json(.get, "/LiveTv/Channels", query: query.items, isUserScoped: true)
    }

    static func programs(_ programsQuery: JellyfinProgramsQueryDTO) -> JellyfinRequest<JellyfinQueryResult<JellyfinProgramDTO>> {
        let body = JellyfinRequestBody { context in
            var programsQuery = programsQuery
            if programsQuery.userID == nil { programsQuery.userID = context.userID }
            return programsQuery
        }
        // Envelope only: program shapes are unverified (no tuner on jellyfin-demo).
        return .json(.post, "/LiveTv/Programs", body: body)
    }

    static func closeLiveStream(liveStreamID: String) -> JellyfinRequest<JellyfinNoContent> {
        .noContent(.post, "/LiveStreams/Close", query: [URLQueryItem(name: "liveStreamId", value: liveStreamID)])
    }

    // MARK: URLs handed to players and downloaders (§10, §11, §14)

    /// Direct play: `206` with byte ranges. `DirectStreamUrl` is not populated
    /// on 12.4, so the client builds this itself (03 §5.1 item 2).
    static func directStreamPath(itemID: String, mediaSourceID: String) -> (path: String, query: [URLQueryItem]) {
        ("/Videos/\(itemID)/stream", [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: mediaSourceID),
        ])
    }

    /// Original file download (auth; gated by `Policy.EnableContentDownloading`).
    static func downloadPath(itemID: String) -> String {
        "/Items/\(itemID)/Download"
    }

    /// Trickplay sheet `index` at `width` (auth required).
    static func trickplayTilePath(itemID: String, mediaSourceID: String, width: Int,
                                  index: Int) -> (path: String, query: [URLQueryItem]) {
        ("/Videos/\(itemID)/Trickplay/\(width)/\(index).jpg",
         [URLQueryItem(name: "mediaSourceId", value: mediaSourceID)])
    }

    /// Any text subtitle as `format` (`vtt`, `srt`, `ass`); PGS as `sup`.
    /// No auth needed (02 §10 rule 4).
    static func subtitlePath(itemID: String, mediaSourceID: String, streamIndex: Int, format: String) -> String {
        "/Videos/\(itemID)/\(mediaSourceID)/Subtitles/\(streamIndex)/0/Stream.\(format)"
    }

    // MARK: Validation helpers

    static func validateSameItem(_ item: JellyfinItemDTO, id: String) throws {
        guard JellyfinID.same(item.id, id) else {
            throw JellyfinError.unexpectedResponse("asked for one item, got another")
        }
        if item.userData == nil {
            throw JellyfinError.unexpectedResponse("item without UserData; userId was not applied")
        }
    }

    @Sendable
    static func validateAuthentication(_ result: JellyfinAuthenticationResultDTO, _: JellyfinRequestContext) throws {
        guard !result.accessToken.isEmpty, !result.user.id.isEmpty else {
            throw JellyfinError.unexpectedResponse("sign-in without token or user")
        }
    }
}
