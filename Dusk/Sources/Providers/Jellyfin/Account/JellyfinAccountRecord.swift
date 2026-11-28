import Foundation

/// One Jellyfin user signed in on this device (docs/jellyfin/04-architecture.md
/// §7.1): who, on which server, reached where, and the `DeviceId` its token is
/// bound to. The token itself is in the Keychain (`JellyfinAccountStore`).
///
/// One `DeviceId` holds one token: signing in again with the same id revokes
/// the previous token (03 §10.2). Every record gets its own random id when its
/// sign-in starts, so two users on one device never log each other out.
struct JellyfinAccountRecord: Codable, Sendable, Hashable, Identifiable {
    /// `jellyfin-<serverID>-<userID>`: the account id and the storage scope
    /// (`activeProfileID`) while this user is active (04 §7.3).
    var id: String { Self.accountID(serverID: serverID, userID: userID) }

    /// Normalised (32 lower-case hex characters).
    let serverID: String
    var serverName: String
    var serverVersion: String?
    /// Normalised (32 lower-case hex characters).
    let userID: String
    var userName: String
    /// The address the user typed, as it answered at sign-in.
    var baseURL: URL
    /// The server's own LAN address from `/System/Info/Public`, raced against
    /// `baseURL` by the pool.
    var localAddress: URL?
    let deviceID: String
    var policy: JellyfinPolicySnapshot
    var hasPrimaryImage: Bool

    static func accountID(serverID: String, userID: String) -> String {
        "jellyfin-\(JellyfinID.normalized(serverID))-\(JellyfinID.normalized(userID))"
    }
}

/// The parts of a user's `Policy` Dusk acts on, kept with the record so the
/// last-known permissions hold offline. Refreshed from `/Users/Me` after
/// every launch (`JellyfinAccountProvider.refresh()`).
struct JellyfinPolicySnapshot: Codable, Sendable, Hashable {
    var isAdministrator: Bool
    var enableMediaPlayback: Bool
    var enableContentDownloading: Bool
    var enableSubtitleManagement: Bool
    var enableCollectionManagement: Bool
    var enableLiveTvAccess: Bool
    var enableUserPreferenceAccess: Bool

    /// What a missing policy means: the server defaults for a new user.
    static let serverDefaults = JellyfinPolicySnapshot(
        isAdministrator: false,
        enableMediaPlayback: true,
        enableContentDownloading: true,
        enableSubtitleManagement: false,
        enableCollectionManagement: false,
        enableLiveTvAccess: true,
        enableUserPreferenceAccess: true
    )

    init(
        isAdministrator: Bool,
        enableMediaPlayback: Bool,
        enableContentDownloading: Bool,
        enableSubtitleManagement: Bool,
        enableCollectionManagement: Bool,
        enableLiveTvAccess: Bool,
        enableUserPreferenceAccess: Bool
    ) {
        self.isAdministrator = isAdministrator
        self.enableMediaPlayback = enableMediaPlayback
        self.enableContentDownloading = enableContentDownloading
        self.enableSubtitleManagement = enableSubtitleManagement
        self.enableCollectionManagement = enableCollectionManagement
        self.enableLiveTvAccess = enableLiveTvAccess
        self.enableUserPreferenceAccess = enableUserPreferenceAccess
    }

    init(_ policy: JellyfinUserPolicyDTO?) {
        let defaults = Self.serverDefaults
        self.init(
            isAdministrator: policy?.isAdministrator ?? defaults.isAdministrator,
            enableMediaPlayback: policy?.enableMediaPlayback ?? defaults.enableMediaPlayback,
            enableContentDownloading: policy?.enableContentDownloading ?? defaults.enableContentDownloading,
            enableSubtitleManagement: policy?.enableSubtitleManagement ?? defaults.enableSubtitleManagement,
            enableCollectionManagement: policy?.enableCollectionManagement ?? defaults.enableCollectionManagement,
            enableLiveTvAccess: policy?.enableLiveTvAccess ?? defaults.enableLiveTvAccess,
            enableUserPreferenceAccess: policy?.enableUserPreferenceAccess ?? defaults.enableUserPreferenceAccess
        )
    }

    /// The neutral form (04 §3). Hiding Home rows edits the user's own
    /// `LatestItemsExcludes` (needs `EnableUserPreferenceAccess`); installing subtitles
    /// needs `EnableSubtitleManagement`; playlists are the user's own. A
    /// Jellyfin account is a user on one server, so there is no owner label.
    var permissions: ServerPermissions {
        ServerPermissions(
            canManageHomeRows: enableUserPreferenceAccess,
            canInstallSubtitles: enableSubtitleManagement || isAdministrator,
            canDownload: enableContentDownloading,
            canPlay: enableMediaPlayback,
            canEditPlaylists: true,
            ownerLabel: nil
        )
    }
}

/// Where Jellyfin accounts live on this device. New keys only: nothing a Plex
/// install has stored is read or written here.
///
/// - UserDefaults `JellyfinAccounts`: `[JellyfinAccountRecord]` as JSON.
/// - UserDefaults `JellyfinActiveAccountID`: the active record's id.
/// - Keychain `JellyfinAccessToken.<accountID>`: each record's token.
enum JellyfinAccountStore {
    static let defaultsAccountsKey = "JellyfinAccounts"
    static let defaultsActiveAccountKey = "JellyfinActiveAccountID"
    static let keychainTokenPrefix = "JellyfinAccessToken"

    static func tokenKey(accountID: String) -> String {
        "\(keychainTokenPrefix).\(accountID)"
    }

    static func loadRecords(defaults: UserDefaults = .standard) -> [JellyfinAccountRecord] {
        guard let data = defaults.data(forKey: defaultsAccountsKey),
              let records = try? JSONDecoder().decode([JellyfinAccountRecord].self, from: data) else {
            return []
        }
        return records
    }

    static func saveRecords(_ records: [JellyfinAccountRecord], defaults: UserDefaults = .standard) {
        if records.isEmpty {
            defaults.removeObject(forKey: defaultsAccountsKey)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: defaultsAccountsKey)
        }
    }

    static func activeAccountID(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: defaultsActiveAccountKey)?.nilIfEmpty
    }

    static func saveActiveAccountID(_ id: String?, defaults: UserDefaults = .standard) {
        if let id {
            defaults.set(id, forKey: defaultsActiveAccountKey)
        } else {
            defaults.removeObject(forKey: defaultsActiveAccountKey)
        }
    }

    static func token(accountID: String) -> String? {
        KeychainHelper.load(key: tokenKey(accountID: accountID))
            .flatMap { String(data: $0, encoding: .utf8) }?
            .nilIfEmpty
    }

    static func saveToken(_ token: String, accountID: String) {
        KeychainHelper.save(key: tokenKey(accountID: accountID), data: Data(token.utf8))
    }

    static func deleteToken(accountID: String) {
        KeychainHelper.delete(key: tokenKey(accountID: accountID))
    }
}
