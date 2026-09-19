import Foundation

/// Account-level library order, backed by the plex.tv `experience` user setting.
///
/// Plex stores the sidebar order once per *account* (not per server) as a single
/// doubly-stringified JSON blob under the setting id `"experience"`, at
/// `experience.sidebarSettings.pinnedSources`. There is no PMS endpoint for it —
/// the server is never told the order. Writing it means read-modify-write of the
/// entire blob: a partial POST would wipe the user's Plex Web home
/// customization, other servers' pins, and the cloud provider entries.
///
/// Read is best effort. A missing setting, a 404, or an unparseable blob all
/// mean "this account never customized its order" and fall back to
/// `/library/sections` order. Only a genuine transport or auth failure sets
/// `orderUnavailable`.
///
/// Both calls use a short per-request timeout instead of the session's 15s/30s
/// default. Home and Libraries await the read before their first paint, and a
/// LAN-only session — the Plex server answers over the local network while the
/// internet does not — would otherwise hold that paint for the full 15s. Nothing
/// on screen depends on the blob, so timing out only costs the customized order
/// for that launch.
extension PlexService {
    private static let experienceSettingID = "experience"
    private static let accountPath = "/api/v2/user"
    private static let accountSettingsPath = "/api/v2/user/settings"
    /// Per-request timeout for the two plex.tv calls below. See the note above.
    private static let plexTVRequestTimeout: TimeInterval = 6

    /// Cache identity of the current session. The pinned list is per account
    /// token (Plex Home members each have their own) and the sections are the
    /// ones the currently connected servers answered with, so both go in.
    ///
    /// The servers go in **in priority order**, not sorted: the unpinned tail of
    /// the effective order follows server priority, so reordering Server
    /// Priority has to invalidate the cache even though the same servers are
    /// connected.
    var libraryOrderCacheIdentity: String {
        let serverIDs = mergeServerIDs.joined(separator: ",")
        return "\(serverIDs.nilIfEmpty ?? "-")|\(activeProfileID ?? "-")"
    }

    /// Loads `/library/sections` from every connected server and the plex.tv
    /// experience blob, all in parallel, once per `(serverIDs|profileID)`.
    /// Concurrent callers share the same in-flight request set.
    ///
    /// Each server's sections are committed the moment they arrive, so the
    /// library list paints from the first server instead of the slowest. Throws
    /// only when *every* server's `/library/sections` failed; one failing server
    /// must never blank the others' libraries. A plex.tv failure is swallowed
    /// and simply leaves the libraries in plain server order.
    @discardableResult
    func ensureLibraryOrderLoaded(force: Bool = false) async throws -> [PlexLibrary] {
        let identity = libraryOrderCacheIdentity

        if !force, libraryOrder.state == .loaded, libraryOrder.matchesCacheIdentity(identity) {
            return libraryOrder.orderedSections
        }

        if !force, let existing = libraryOrder.loadTask {
            return try await existing.value
        }

        let task = Task { @MainActor [weak self] () throws -> [PlexLibrary] in
            guard let self else { return [] }
            return try await self.performLibraryOrderLoad(identity: identity)
        }
        libraryOrder.loadTask = task

        do {
            let result = try await task.value
            libraryOrder.clearLoadTask(task)
            return result
        } catch {
            libraryOrder.clearLoadTask(task)
            throw error
        }
    }

    /// Re-reads the plex.tv blob only, leaving the cached sections alone. Used
    /// when the Library Order screen opens and before every write, because
    /// plex.tv is last-writer-wins and another client may have reordered since.
    /// Throws on a plex.tv failure.
    func refreshLibraryOrder() async throws {
        let identity = libraryOrderCacheIdentity
        let experience = try await fetchExperienceSettings()
        libraryOrder.apply(experience: experience, identity: identity)
    }

    /// Read-modify-write of the account's pinned sources.
    ///
    /// `ordered` must be EVERY section of every connected server in the new
    /// order, including sections Dusk cannot browse (music, photos) — anything
    /// left out would lose its pin. Writes are serialized; each one re-reads the
    /// blob first and never writes from cache.
    func reorderLibraries(_ ordered: [PlexLibrary]) async throws {
        let previous = libraryOrder.writeTask

        let task = Task { @MainActor [weak self] () throws -> Void in
            // Wait for the predecessor whatever its outcome: a failed write must
            // not skip the queue for the next one.
            _ = await previous?.result
            guard let self else { return }
            try await self.performLibraryReorder(ordered)
        }
        libraryOrder.writeTask = task

        do {
            try await task.value
            libraryOrder.clearWriteTask(task)
        } catch {
            libraryOrder.clearWriteTask(task)
            throw error
        }
    }

    /// Applies the cached order to an already-fetched list, without any
    /// networking. Returns the list unchanged when nothing is cached.
    func effectiveLibraryOrder(for libraries: [PlexLibrary]) -> [PlexLibrary] {
        LibraryOrderArrangement.effectiveOrder(
            libraries: libraries,
            pinnedSources: libraryOrder.pinnedSources,
            machineIdentifiers: libraryOrder.machineIdentifiers
        )
    }

    // MARK: - Load

    private func performLibraryOrderLoad(identity: String) async throws -> [PlexLibrary] {
        let serverIDs = mergeServerIDs
        libraryOrder.beginLoading(serverOrder: serverIDs)

        guard !serverIDs.isEmpty else {
            libraryOrder.finishLoading(
                experience: await loadExperienceSettingsIgnoringFailure(),
                identity: identity
            )
            return []
        }

        // The account blob and every server's sections race each other; the
        // blob is optional, so it is never awaited before the first section
        // commit.
        async let experienceResult = loadExperienceSettingsIgnoringFailure()

        var failures: [String: any Error] = [:]
        for await result in streamAcrossServers({ service, serverID in
            do {
                return Result<[PlexLibrary], any Error>.success(
                    try await service.getLibraries(serverID: serverID)
                )
            } catch {
                return .failure(error)
            }
        }) {
            switch result.value {
            case let .success(sections):
                libraryOrder.applyServerSections(sections, serverID: result.serverID)
            case let .failure(error):
                failures[result.serverID] = error
                libraryOrder.applyServerSections(nil, serverID: result.serverID)
            }
        }

        let experience = await experienceResult

        // Only a total blackout is an error. One failing server leaves the
        // others' libraries on screen and is surfaced as a partial-outage note.
        if failures.count == serverIDs.count, let error = failures.values.first {
            libraryOrder.failLoading(error.localizedDescription)
            throw error
        }

        libraryOrder.finishLoading(experience: experience, identity: identity)
        return libraryOrder.orderedSections
    }

    /// nil = the blob could not be read at all (transport/auth). An empty but
    /// non-nil result means the account simply never customized its order.
    private func loadExperienceSettingsIgnoringFailure() async -> PlexExperienceSettings? {
        do {
            return try await fetchExperienceSettings()
        } catch {
            logLibraryOrderFailure("read", error: error)
            return nil
        }
    }

    // MARK: - plex.tv blob

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
    private func fetchExperienceSettings() async throws -> PlexExperienceSettings {
        guard let token = activeAccountToken?.nilIfEmpty else {
            throw PlexServiceError.notAuthenticated
        }

        let data: Data
        do {
            data = try await rawPlexTVRequest(
                path: Self.accountPath,
                queryItems: [
                    URLQueryItem(name: "includeSubscriptions", value: "1"),
                    URLQueryItem(name: "includeProviders", value: "1"),
                    URLQueryItem(name: "includeSettings", value: "1"),
                    URLQueryItem(name: "includeSharedSettings", value: "1"),
                ],
                accountToken: token,
                timeoutInterval: Self.plexTVRequestTimeout
            )
        } catch PlexServiceError.httpError(statusCode: 404) {
            // No settings record yet: a brand-new account that never ran the
            // Plex first-run wizard.
            plexAuthLogger.notice("Library order: plex.tv has no settings record (404)")
            return .neverCustomized
        }

        guard let response = try? decoder.decode(AccountSettingsResponse.self, from: data),
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

    // MARK: - Write

    private func performLibraryReorder(_ ordered: [PlexLibrary]) async throws {
        guard let token = activeAccountToken?.nilIfEmpty else {
            throw PlexServiceError.notAuthenticated
        }

        // HARD INVARIANT: only servers that actually answered `/library/sections`
        // with sections this session may have their pins rewritten. A server
        // whose fetch failed looks identical to one with no libraries, and
        // writing that would unpin its libraries in every Plex client the
        // account uses. The same goes for a server that answered with nothing
        // (`LibraryOrderStore.machineIdentifiers` leaves it out) and for one
        // that is not connected at all.
        var servers: [String: PlexServer] = [:]
        for serverID in libraryOrder.machineIdentifiers
        where !libraryOrder.failedServerIDs.contains(serverID) {
            guard let server = pool.server(for: serverID) else { continue }
            servers[serverID] = server
        }
        guard !servers.isEmpty else {
            throw PlexServiceError.noServerConnected
        }

        // Never write from cache: plex.tv is last-writer-wins and other clients
        // (or another Dusk device) may have changed the blob since the load.
        try await refreshLibraryOrder()

        let existing = libraryOrder.pinnedSources
        let reordered = LibraryOrderArrangement.writeOrder(
            userOrder: ordered,
            existing: existing,
            servers: servers
        )
        let merged = LibraryOrderArrangement.merged(
            existing: existing,
            reordered: reordered,
            machineIdentifiers: Set(servers.keys)
        )

        // Start from the blob we just read (or an empty object for a fresh
        // account) and touch nothing but pinnedSources / hasCompletedSetup.
        // schemaVersion, homeSettings, reminders, autoPinnedProviders and every
        // unknown key round-trip verbatim; inventing a schemaVersion would
        // disable syncing in other Plex clients.
        var blob = libraryOrder.experienceBlob ?? .object([:])
        if blob.objectValue == nil {
            blob = .object([:])
        }
        var sidebarSettings = blob["sidebarSettings"]?.objectValue ?? [:]
        sidebarSettings["pinnedSources"] = .array(merged.map(\.raw))
        sidebarSettings["hasCompletedSetup"] = .bool(true)
        blob["sidebarSettings"] = .object(sidebarSettings)

        let body = try Self.makeSettingsBody(blob: blob)

        do {
            _ = try await rawPlexTVRequest(
                method: "POST",
                path: Self.accountSettingsPath,
                queryItems: [URLQueryItem(name: "sharedSettings", value: "1")],
                jsonBody: body,
                accountToken: token,
                timeoutInterval: Self.plexTVRequestTimeout
            )
        } catch {
            logLibraryOrderFailure("write", error: error)
            throw error
        }

        // `rawPlexTVRequest` only returns for a 2xx, so this point is success.
        libraryOrder.commitWrite(pinnedSources: merged, blob: blob)
        plexAuthLogger.notice(
            "Library order: wrote \(merged.count, privacy: .public) pinned sources to plex.tv"
        )
    }

    /// Builds the doubly-stringified payload Plex Web posts:
    /// `{"value":"[{\"id\":\"experience\",\"type\":\"json\",\"value\":\"<blob>\",\"hidden\":true}]"}`
    private static func makeSettingsBody(blob: DuskJSONValue) throws -> Data {
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

    /// Logs outcomes only. The blob contains the user's whole Plex sidebar and
    /// the request carries an account token — neither ever reaches the log.
    private func logLibraryOrderFailure(_ stage: String, error: Error) {
        let outcome: String
        if let serviceError = error as? PlexServiceError {
            switch serviceError {
            case .httpError(let statusCode):
                outcome = "HTTP \(statusCode)"
            case .unauthorized, .notAuthenticated:
                outcome = "unauthorized"
            case .networkError:
                outcome = "network error"
            case .decodingError:
                outcome = "decoding error"
            default:
                outcome = "unavailable"
            }
        } else if error is CancellationError {
            outcome = "cancelled"
        } else {
            outcome = "unavailable"
        }

        plexAuthLogger.notice(
            "Library order \(stage, privacy: .public) failed: \(outcome, privacy: .public)"
        )
    }
}
