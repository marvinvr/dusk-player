import Foundation

/// Jellyfin's `AccountPreferencesProviding` (docs/jellyfin/04-architecture.md
/// §13, §17): the active user's `User.Configuration` on its one server.
///
/// - Library order is `OrderedViews`, hidden libraries are `MyMediaExcludes`,
///   both lists of view ids, the same lists Jellyfin Web's Home settings edit.
///   Views Dusk does not show (Collections, Playlists, music) keep their
///   places, and exclusions of those stay as they are.
/// - A user without `Policy.EnableUserPreferenceAccess` cannot write the
///   configuration (`403`); their order and hidden set are kept on this
///   device instead (`JellyfinLibraryViewsStore`), starting from what the
///   server has.
/// - Language defaults are `AudioLanguagePreference`,
///   `SubtitleLanguagePreference` and `SubtitleMode`.
///
/// Every write re-reads the configuration and sends the whole object back with
/// only the two lists changed: `POST /Users/Configuration` replaces it, and
/// other clients (or Jellyfin Web) may have changed it since.
struct JellyfinAccountPreferences: AccountPreferencesProviding {
    let account: JellyfinAccountProvider

    // MARK: - Library layout

    @MainActor func libraryLayout() async throws -> AccountLibraryLayout {
        let (record, client) = try signedIn()
        let views = try await readViews(record: record, client: client).views
        return views.layout(serverID: record.serverID)
    }

    @MainActor func saveLibraryLayout(
        _ order: [Library],
        hidden: Set<String>?,
        serverIDs: Set<String>,
        didRead: (AccountLibraryLayout) -> Void
    ) async throws -> AccountLibraryLayout {
        let (record, client) = try signedIn()
        // The facade passes only servers whose libraries answered this session.
        guard serverIDs.contains(where: { JellyfinID.same($0, record.serverID) }) else {
            throw MediaServiceError.noServerConnected
        }

        let current = try await readViews(record: record, client: client)
        didRead(current.views.layout(serverID: record.serverID))

        let libraries = order.filter { $0.serverID.map { JellyfinID.same($0, record.serverID) } ?? false }
        // Where every view sits today, the ones Dusk does not show included,
        // so those keep their places. Without it they move behind Dusk's.
        let serverOrder = (try? await client.send(JellyfinAPI.userViews()).items.map(\.id)) ?? []
        let written = current.views.rearranged(
            order: libraries.map { JellyfinID.normalized($0.key) },
            hidden: hidden.map { hidden in
                Set(libraries.filter { hidden.contains($0.id) }.map { JellyfinID.normalized($0.key) })
            },
            serverOrder: serverOrder
        )

        if var configuration = current.configuration {
            configuration["OrderedViews"] = .array(written.ordered.map(DuskJSONValue.string))
            configuration["MyMediaExcludes"] = .array(written.excluded.map(DuskJSONValue.string))
            do {
                _ = try await client.send(JellyfinAPI.replaceUserConfiguration(configuration))
                JellyfinLibraryViewsStore.remove(accountID: record.id)
                remember(written, for: record)
                jellyfinAccountLogger.notice(
                    "Library order: wrote \(written.ordered.count, privacy: .public) views, \(written.excluded.count, privacy: .public) hidden"
                )
                return written.layout(serverID: record.serverID)
            } catch JellyfinError.forbidden {
                // The policy changed since the last refresh: keep it here.
                jellyfinAccountLogger.notice("Library order: the server refused the write; keeping it on this device")
            } catch {
                LibraryOrderStore.logFailure("write", error: error)
                throw error
            }
        }

        JellyfinLibraryViewsStore.save(written, accountID: record.id)
        remember(written, for: record)
        return written.layout(serverID: record.serverID)
    }

    /// The hidden view ids of the active user's server, from the last read or
    /// write, or read now on a cold start. Empty when they cannot be read.
    @MainActor func hiddenViewIDs(serverID: String) async -> Set<String> {
        guard let record = account.record(forServer: serverID) else { return [] }
        if let cached = account.state.libraryViews[record.id] {
            return Set(cached.excluded)
        }
        guard let client = account.client(for: record),
              let read = try? await readViews(record: record, client: client) else { return [] }
        return Set(read.views.excluded)
    }

    // MARK: - Language defaults

    @MainActor func languageDefaults() async throws -> AccountLanguageDefaults? {
        let (_, client) = try signedIn()
        let user = try await client.send(JellyfinAPI.currentUser())
        return user.configuration.map(Self.languageDefaults(from:))
    }

    /// The configuration in Dusk's terms. `PlayDefaultAudioTrack` ("play the
    /// default track regardless of language") is left out: it is on for every
    /// new user, so reading it as "Original" would override Dusk's default for
    /// accounts that never chose anything. Jellyfin's `Default` subtitle mode
    /// (follow the file's flags) says nothing either; `None` and `OnlyForced`
    /// are Dusk's Off, which still shows forced subtitles.
    static func languageDefaults(from configuration: JellyfinUserConfigurationDTO) -> AccountLanguageDefaults {
        let mode = configuration.subtitleMode
        let subtitleMode: SubtitleMode? = if let mode, mode.matches(JellyfinSubtitleMode.none) || mode.matches(.onlyForced) {
            .off
        } else if mode?.matches(.smart) == true {
            .auto
        } else if mode?.matches(.always) == true {
            .always
        } else {
            nil
        }
        return AccountLanguageDefaults(
            audioLanguage: JellyfinLanguageCodes.twoLetter(configuration.audioLanguagePreference),
            subtitleLanguage: JellyfinLanguageCodes.twoLetter(configuration.subtitleLanguagePreference),
            subtitleMode: subtitleMode
        )
    }

    // MARK: - Reading

    @MainActor private func signedIn() throws -> (JellyfinAccountRecord, JellyfinClient) {
        guard let record = account.state.activeRecord, let client = account.client(for: record) else {
            throw MediaServiceError.notAuthenticated
        }
        return (record, client)
    }

    /// The user's views and, when the server may be written, the whole
    /// configuration they came from. Without the permission a list kept on
    /// this device wins over the server's.
    @MainActor private func readViews(
        record: JellyfinAccountRecord,
        client: JellyfinClient
    ) async throws -> (views: JellyfinLibraryViews, configuration: DuskJSONValue?) {
        let writable = record.policy.enableUserPreferenceAccess
        if !writable, let local = JellyfinLibraryViewsStore.load(accountID: record.id) {
            remember(local, for: record)
            return (local, nil)
        }
        let configuration = try await client.send(JellyfinAPI.userConfigurationJSON())
        let views = JellyfinLibraryViews(configuration: configuration)
        remember(views, for: record)
        return (views, writable ? configuration : nil)
    }

    @MainActor private func remember(_ views: JellyfinLibraryViews, for record: JellyfinAccountRecord) {
        account.state.libraryViews[record.id] = views
    }
}

/// `OrderedViews` and `MyMediaExcludes`, as normalised view ids.
struct JellyfinLibraryViews: Codable, Sendable, Hashable {
    var ordered: [String]
    var excluded: [String]

    init(ordered: [String], excluded: [String]) {
        self.ordered = Self.unique(ordered)
        self.excluded = Self.unique(excluded)
    }

    init(configuration: DuskJSONValue) {
        func ids(_ key: String) -> [String] {
            (configuration[key]?.arrayValue ?? []).compactMap(\.stringValue)
        }
        self.init(ordered: ids("OrderedViews"), excluded: ids("MyMediaExcludes"))
    }

    /// The account's order first; excluded views it does not order follow,
    /// hidden (`LibraryOrderArrangement` never places hidden entries).
    func layout(serverID: String) -> AccountLibraryLayout {
        let server = JellyfinID.normalized(serverID)
        let excludedSet = Set(excluded)
        let orderedSet = Set(ordered)
        let entries = ordered.map {
            AccountLibraryLayout.Entry(serverID: server, libraryID: $0, isHidden: excludedSet.contains($0))
        } + excluded.filter { !orderedSet.contains($0) }.map {
            AccountLibraryLayout.Entry(serverID: server, libraryID: $0, isHidden: true)
        }
        return AccountLibraryLayout(entries: entries)
    }

    /// Dusk's libraries in `order`, in the slots Dusk's libraries hold today;
    /// views Dusk does not show (Collections, Playlists) keep theirs.
    /// `serverOrder` is the server's effective order (`/UserViews`), which
    /// also places views the account never ordered; without it, those follow.
    /// `hidden` replaces the exclusions among `order`'s views; nil keeps them.
    /// Exclusions of other views stay.
    func rearranged(order: [String], hidden: Set<String>?, serverOrder: [String] = []) -> JellyfinLibraryViews {
        let order = Self.unique(order)
        let shown = Set(order)
        var base = Self.unique(serverOrder + ordered)
        let placed = Set(base)
        base += order.filter { !placed.contains($0) }
        var next = order.makeIterator()
        let arranged = base.map { shown.contains($0) ? next.next() ?? $0 : $0 }

        guard let hidden = hidden.map({ Set($0.map(JellyfinID.normalized)) }) else {
            return JellyfinLibraryViews(ordered: arranged, excluded: excluded)
        }
        let excluded = excluded.filter { !shown.contains($0) } + order.filter { hidden.contains($0) }
        return JellyfinLibraryViews(ordered: arranged, excluded: excluded)
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.map(JellyfinID.normalized).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// The device-local layout of a user who may not write their configuration
/// (`EnableUserPreferenceAccess` off). New key per Jellyfin account; nothing a
/// Plex install stores is touched.
///
/// - UserDefaults `JellyfinLibraryViews.<accountID>`: `JellyfinLibraryViews` as JSON.
enum JellyfinLibraryViewsStore {
    static let keyPrefix = "JellyfinLibraryViews"

    static func key(accountID: String) -> String { "\(keyPrefix).\(accountID)" }

    static func load(accountID: String, defaults: UserDefaults = .standard) -> JellyfinLibraryViews? {
        guard let data = defaults.data(forKey: key(accountID: accountID)) else { return nil }
        return try? JSONDecoder().decode(JellyfinLibraryViews.self, from: data)
    }

    static func save(_ views: JellyfinLibraryViews, accountID: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(views) else { return }
        defaults.set(data, forKey: key(accountID: accountID))
    }

    static func remove(accountID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(accountID: accountID))
    }
}
