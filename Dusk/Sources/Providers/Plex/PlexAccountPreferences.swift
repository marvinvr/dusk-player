import Foundation

/// Plex's `AccountPreferencesProviding`: the plex.tv `experience` user setting
/// (library order and hidden libraries) and the account `profile` (language
/// defaults), both on `GET /api/v2/user`.
///
/// Plex stores the sidebar order once per *account* (not per server) as a single
/// doubly-stringified JSON blob under the setting id `"experience"`, at
/// `experience.sidebarSettings.pinnedSources`. There is no PMS endpoint for it —
/// the server is never told the order. Writing it means read-modify-write of the
/// entire blob: a partial POST would wipe the user's Plex Web home
/// customization, other servers' pins, and the cloud provider entries.
///
/// Both experience calls use a short per-request timeout instead of the
/// session's 15s/30s default. Home and Libraries await the read before their
/// first paint, and a LAN-only session — the Plex server answers over the local
/// network while the internet does not — would otherwise hold that paint for the
/// full 15s. Nothing on screen depends on the blob, so timing out only costs the
/// customized order for that launch.
struct PlexAccountPreferences: AccountPreferencesProviding {
    let client: PlexClient
    /// nil only on the value `PlexAccountProvider.preferences` hands out, which
    /// then refuses every call; see `PlexAccountTransport`.
    let transport: (any PlexAccountTransport)?

    private static let experienceSettingID = "experience"
    private static let accountPath = "/api/v2/user"
    private static let accountSettingsPath = "/api/v2/user/settings"
    /// Per-request timeout for the two experience calls. See the note above.
    private static let plexTVRequestTimeout: TimeInterval = 6

    // MARK: - Library layout

    @MainActor func libraryLayout() async throws -> AccountLibraryLayout {
        try await fetchExperienceSettings().layout
    }

    @MainActor func saveLibraryLayout(
        _ order: [Library],
        hidden: Set<String>?,
        serverIDs: Set<String>,
        didRead: (AccountLibraryLayout) -> Void
    ) async throws -> AccountLibraryLayout {
        let transport = try requireTransport()
        guard let token = transport.activeAccountToken?.nilIfEmpty else {
            throw PlexServiceError.notAuthenticated
        }

        // `serverIDs` holds only servers that answered `/library/sections` with
        // sections this session (the facade's hard invariant); one that is no
        // longer connected drops out here too. Never widen it: writing pins for
        // a server whose sections could not be read would unpin its libraries
        // in every Plex client the account uses.
        var servers: [String: PlexServer] = [:]
        for serverID in serverIDs {
            guard let server = transport.accountServer(for: serverID) else { continue }
            servers[serverID] = server
        }
        guard !servers.isEmpty else {
            throw PlexServiceError.noServerConnected
        }

        // Never write from cache: plex.tv is last-writer-wins and other clients
        // (or another Dusk device) may have changed the blob since the load.
        let experience = try await fetchExperienceSettings()
        didRead(experience.layout)

        let existing = experience.pinnedSources
        let reordered = PlexPinnedSourceArrangement.writeOrder(
            userOrder: order,
            existing: existing,
            servers: servers,
            hidden: hidden
        )
        let merged = PlexPinnedSourceArrangement.merged(
            existing: existing,
            reordered: reordered,
            machineIdentifiers: Set(servers.keys)
        )

        // Start from the blob we just read (or an empty object for a fresh
        // account) and touch nothing but pinnedSources / hasCompletedSetup.
        // schemaVersion, homeSettings, reminders, autoPinnedProviders and every
        // unknown key round-trip verbatim; inventing a schemaVersion would
        // disable syncing in other Plex clients.
        var blob = experience.blob ?? .object([:])
        if blob.objectValue == nil {
            blob = .object([:])
        }
        var sidebarSettings = blob["sidebarSettings"]?.objectValue ?? [:]
        sidebarSettings["pinnedSources"] = .array(merged.map(\.raw))
        sidebarSettings["hasCompletedSetup"] = .bool(true)
        blob["sidebarSettings"] = .object(sidebarSettings)

        let body = try Self.makeSettingsBody(blob: blob)

        do {
            _ = try await transport.rawPlexTVRequest(
                method: "POST",
                path: Self.accountSettingsPath,
                queryItems: [URLQueryItem(name: "sharedSettings", value: "1")],
                formBody: nil,
                jsonBody: body,
                accountToken: token,
                timeoutInterval: Self.plexTVRequestTimeout,
                retriesFreshAuthentication: true,
                bootstrap: false
            )
        } catch {
            LibraryOrderStore.logFailure("write", error: error)
            throw error
        }

        // `rawPlexTVRequest` only returns for a 2xx, so this point is success.
        plexAuthLogger.notice(
            "Library order: wrote \(merged.count, privacy: .public) pinned sources to plex.tv"
        )
        return PlexExperienceSettings(blob: blob, pinnedSources: merged).layout
    }

    // MARK: - Language defaults

    private struct AccountLanguageResponse: Decodable {
        let profile: PlexAccountProfileDTO?
    }

    @MainActor func languageDefaults() async throws -> AccountLanguageDefaults? {
        let transport = try requireTransport()
        guard transport.activeAccountToken != nil else { return nil }
        let account: AccountLanguageResponse = try await transport.plexTVRequest(
            method: "GET",
            path: Self.accountPath,
            queryItems: nil,
            formBody: nil,
            jsonBody: nil,
            accountToken: nil,
            timeoutInterval: nil,
            retriesFreshAuthentication: true,
            bootstrap: false
        )
        return account.profile.map(Self.languageDefaults(from:))
    }

    /// The account profile in Dusk's terms.
    static func languageDefaults(from profile: PlexAccountProfileDTO) -> AccountLanguageDefaults {
        let audioLanguage = profile.defaultAudioLanguage.flatMap(UserPreferences.normalizedLanguageCode(from:))
        let subtitleMode: SubtitleMode? = switch profile.autoSelectSubtitle {
        case 0: .off
        case 1: .auto
        case 2: .always
        default: nil
        }
        return AccountLanguageDefaults(
            audioLanguage: profile.autoSelectAudio == false ? "" : audioLanguage,
            subtitleLanguage: profile.defaultSubtitleLanguage.flatMap(UserPreferences.normalizedLanguageCode(from:)),
            subtitleMode: subtitleMode
        )
    }

    // MARK: - plex.tv experience blob

    private struct AccountSettingsResponse: Decodable {
        struct Setting: Decodable {
            let id: String?
            let value: DuskJSONValue?
        }

        let settings: [Setting]?
    }

    /// `GET /api/v2/user?includeSubscriptions=1&includeProviders=1&includeSettings=1&includeSharedSettings=1`
    ///
    /// `settings` is an array of `{id,type,value,hidden,updatedAt}`; the
    /// `experience` entry's `value` is itself a JSON *string* (double-encoded)
    /// holding the whole blob.
    ///
    /// Throws only on transport/auth failure. A 404, a missing `settings` array,
    /// a missing `experience` entry, or an unparseable value all return
    /// `.neverCustomized`.
    @MainActor private func fetchExperienceSettings() async throws -> PlexExperienceSettings {
        let transport = try requireTransport()
        guard let token = transport.activeAccountToken?.nilIfEmpty else {
            throw PlexServiceError.notAuthenticated
        }

        let data: Data
        do {
            data = try await transport.rawPlexTVRequest(
                method: "GET",
                path: Self.accountPath,
                queryItems: [
                    URLQueryItem(name: "includeSubscriptions", value: "1"),
                    URLQueryItem(name: "includeProviders", value: "1"),
                    URLQueryItem(name: "includeSettings", value: "1"),
                    URLQueryItem(name: "includeSharedSettings", value: "1"),
                ],
                formBody: nil,
                jsonBody: nil,
                accountToken: token,
                timeoutInterval: Self.plexTVRequestTimeout,
                retriesFreshAuthentication: true,
                bootstrap: false
            )
        } catch PlexServiceError.httpError(statusCode: 404) {
            // No settings record yet: a brand-new account that never ran the
            // Plex first-run wizard.
            plexAuthLogger.notice("Library order: plex.tv has no settings record (404)")
            return .neverCustomized
        }

        guard let response = try? transport.decoder.decode(AccountSettingsResponse.self, from: data),
              let setting = response.settings?.first(where: { $0.id == Self.experienceSettingID }),
              let encodedBlob = setting.value?.stringValue,
              let blob = DuskJSONValue.decode(jsonString: encodedBlob) else {
            plexAuthLogger.notice("Library order: no usable experience setting on plex.tv")
            return .neverCustomized
        }

        let pinnedSources = (blob["sidebarSettings"]?["pinnedSources"]?.arrayValue ?? [])
            .compactMap(PlexPinnedSource.init(raw:))

        plexAuthLogger.notice(
            "Library order: read \(pinnedSources.count, privacy: .public) pinned sources from plex.tv"
        )
        return PlexExperienceSettings(blob: blob, pinnedSources: pinnedSources)
    }

    /// Builds the doubly-stringified payload Plex Web posts:
    /// `{"value":"[{\"id\":\"experience\",\"type\":\"json\",\"value\":\"<blob>\",\"hidden\":true}]"}`
    static func makeSettingsBody(blob: DuskJSONValue) throws -> Data {
        let blobString = try blob.jsonString()
        let setting = DuskJSONValue.object([
            "id": .string(experienceSettingID),
            "type": .string("json"),
            "value": .string(blobString),
            "hidden": .bool(true),
        ])
        let settingsArrayString = try DuskJSONValue.array([setting]).jsonString()
        let envelope = DuskJSONValue.object(["value": .string(settingsArrayString)])
        return try DuskJSONValue.makeEncoder().encode(envelope)
    }

    @MainActor private func requireTransport() throws -> any PlexAccountTransport {
        guard let transport else { throw PlexServiceError.notAuthenticated }
        return transport
    }
}

/// The parsed plex.tv `experience` setting.
struct PlexExperienceSettings: Sendable {
    /// The whole blob, or nil when the account has no `experience` setting yet
    /// (or it was unparseable — both mean "never customized").
    var blob: DuskJSONValue?
    /// `sidebarSettings.pinnedSources`, in sidebar order.
    var pinnedSources: [PlexPinnedSource]

    static let neverCustomized = PlexExperienceSettings(blob: nil, pinnedSources: [])

    /// The pinned entries that point at a library section of a server, in
    /// sidebar order. Cloud providers (Discover, Watchlist, VOD, EPG) and
    /// entries without a section are left out; they only matter to a write,
    /// which re-reads the whole blob.
    var layout: AccountLibraryLayout {
        AccountLibraryLayout(entries: pinnedSources.compactMap { source in
            guard source.isPMSLibrary, let directoryID = source.directoryID else { return nil }
            return AccountLibraryLayout.Entry(
                serverID: source.machineIdentifier,
                libraryID: directoryID,
                isHidden: source.isHidden
            )
        })
    }
}

extension PlexAccountProvider {
    /// Nothing reads this yet: the facade builds the routed facet itself
    /// (`MediaService.accountPreferences`), because the routing lives there.
    var preferences: any AccountPreferencesProviding {
        PlexAccountPreferences(client: client, transport: nil)
    }
}
