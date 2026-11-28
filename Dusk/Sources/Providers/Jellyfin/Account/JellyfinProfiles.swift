import Foundation

/// Jellyfin's `ProfileProviding` (docs/jellyfin/04-architecture.md §7.3): the
/// users saved for the active server, then the ones its login screen lists
/// (`/Users/Public`) that are not saved yet. Choosing an unsaved user asks for
/// its password where Plex asks for a PIN.
struct JellyfinProfiles: ProfileProviding {
    let account: JellyfinAccountProvider

    @MainActor var canSwitch: Bool { all.count > 1 }

    @MainActor var all: [Profile] {
        let state = account.state
        guard let active = state.activeRecord else { return [] }
        let saved = state.records
            .filter { $0.serverID == active.serverID && state.tokens[$0.id] != nil }
            .map(Self.profile(for:))
        let savedIDs = Set(saved.map(\.id))
        let listed = state.publicUsers
            .map { Self.profile(for: $0, on: active) }
            .filter { !savedIDs.contains($0.id) }
        return saved + listed
    }

    @MainActor var current: Profile? {
        account.state.activeRecord.map(Self.profile(for:))
    }

    static func profile(for record: JellyfinAccountRecord) -> Profile {
        Profile(
            id: record.id,
            nativeID: record.userID,
            displayName: record.userName,
            avatarURL: record.hasPrimaryImage ? avatarURL(userID: record.userID, baseURL: record.baseURL) : nil,
            isProtected: false,
            isAdmin: record.policy.isAdministrator,
            isRestricted: false
        )
    }

    static func profile(for user: JellyfinPublicUser, on server: JellyfinAccountRecord) -> Profile {
        Profile(
            id: JellyfinAccountProvider.accountID(for: user, on: server),
            nativeID: user.id,
            displayName: user.name,
            avatarURL: user.hasPrimaryImage ? avatarURL(userID: user.id, baseURL: server.baseURL) : nil,
            isProtected: user.hasPassword,
            isAdmin: false,
            isRestricted: false
        )
    }

    /// `/UserImage?userId=` needs no credential.
    static func avatarURL(userID: String, baseURL: URL) -> URL? {
        let client = JellyfinClient(
            baseURL: baseURL,
            identity: JellyfinClientIdentity(device: "", deviceID: "", version: "")
        )
        return try? client.makeURL(path: "/UserImage", query: [URLQueryItem(name: "userId", value: userID)])
    }
}

// MARK: - Account facets later packages fill in

/// No account-level library layout yet (J-11 maps `OrderedViews` /
/// `MyMediaExcludes`): libraries keep the server's order.
struct JellyfinAccountPreferences: AccountPreferencesProviding {
    @MainActor func libraryLayout() async throws -> AccountLibraryLayout { .neverCustomized }

    @MainActor func saveLibraryLayout(
        _ order: [Library],
        hidden: Set<String>?,
        serverIDs: Set<String>,
        didRead: (AccountLibraryLayout) -> Void
    ) async throws -> AccountLibraryLayout {
        throw MediaServiceError.notImplemented
    }

    @MainActor func languageDefaults() async throws -> AccountLanguageDefaults? { nil }
}

/// No Seerr sign-in yet (J-12: Jellyfin user and password, kept in the Keychain).
struct JellyfinSeerrAuth: SeerrAuthProviding {
    func accepts(_ settings: SeerrPublicSettings) -> Bool { false }
    func login() -> SeerrLogin? { nil }
}
